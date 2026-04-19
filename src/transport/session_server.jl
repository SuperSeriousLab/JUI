# Copyright 2026 Super Serious Studios
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ── transport/session_server.jl ──────────────────────────────────────────
# Phase 3 chunk 3c: Session protocol wiring + run_et! / run_tcp! auto-spawn.
#
# Wires the existing wire/protocol layer (snapshot, diff, input) over the
# transport layer (Unix socket or TCP+TLS). Adds:
#
#   SessionServer  — wraps a running UnixServer or TCPServer with session
#                    pump logic: snapshot on attach, diff stream down,
#                    InputEvent stream up.
#
#   start_session_unix_server  — server-side ET entry point (Unix socket)
#   start_session_tcp_server   — server-side remote entry point (TCP+TLS)
#   stop_session_server!       — graceful shutdown
#
#   run_et!    — one-call launch: starts Unix socket server + local client
#                in the same process, runs the app loop, cleans up on exit.
#   run_tcp!   — starts TCP+TLS server; caller manages client connection
#                (remote mode: user swaps TransportURL, API identical).
#
# Session pump protocol (per connection):
#   1. Transport layer auth completes (chunk 3a or 3b) — on_connect fires
#   2. Server sends snapshot (full Buffer) → client
#   3. Server enters diff pump: on each render cycle, emit diff → client
#   4. Client pipe: reads WireInputMessages from client → dispatches to session
#   5. On disconnect: connection closes cleanly, session stays alive (reconnect ok)
#
# All session/buffer operations go through the existing Session registry and
# diff_message / apply_diff! / apply_snapshot APIs from protocol.jl.
# ─────────────────────────────────────────────────────────────────────────

import Sockets

export SessionServer,
       start_session_unix_server, start_session_tcp_server,
       stop_session_server!,
       run_et!, run_tcp!

# ── SessionServer ──────────────────────────────────────────────────────────

"""
    SessionServer

A running session pump server. Wraps either a `UnixServer` or a `TCPServer`
and wires the Buffer diff/snapshot protocol over authenticated connections.

Fields:
- `transport`     — the underlying `UnixServer` or `TCPServer`
- `session`       — the `Session` owning the widget tree
- `diff_interval` — seconds between diff polls (default 1/60 ≈ 16ms)
- `running`       — true while session pump is active
"""
mutable struct SessionServer
    transport::Union{UnixServer, TCPServer}
    session::Session
    diff_interval::Float64
    running::Bool
end

# ── Internal session pump ───────────────────────────────────────────────────

"""
    _session_pump(srv::SessionServer, io, render_fn::Function)

Per-connection session handler. Called inside `on_connect` for each
authenticated client.

Protocol:
1. Render initial frame → `diff_message` (returns snapshot on first call)
   → write as newline-terminated JSON line to `io`.
2. Start input reader task: read newline-terminated JSON lines from `io`,
   decode as WireInputMessage → `decode_input` → dispatch via `render_fn`.
3. Diff pump loop: every `diff_interval` seconds, render frame via
   `render_fn()` → `diff_message` → write JSON line to `io`.
4. Exit when `!srv.running` or `io` closes.

`render_fn(session::Session) → Buffer` — called by the pump to get the
  current Buffer. For the app loop this calls the model's `view` into a Buffer.
"""
function _session_pump(srv::SessionServer, io, render_fn::Function)
    session = srv.session

    # Step 1: initial snapshot — reset last_buffer so reconnecting clients
    # always receive a full snapshot, not a diff from a previous connection.
    session.last_buffer = nothing
    try
        buf_init = render_fn(session)
        snap_str = diff_message(session, buf_init)  # first call → snapshot
        write(io, snap_str * "\n")
    catch e
        @warn "JUI session_pump: initial snapshot failed" exception=(e, catch_backtrace())
        return
    end

    # Step 2: input reader task (client → server)
    input_ch = Channel{String}(64)
    reader_task = @async begin
        try
            while srv.running
                line = _read_line(io)
                isempty(line) && break   # EOF / disconnect
                put!(input_ch, line)
            end
        catch
            # Connection closed — signal pump to exit
        finally
            close(input_ch)
        end
    end

    # Step 3: dispatch loop + diff pump
    try
        while srv.running
            # Drain all pending input messages (non-blocking)
            while isready(input_ch)
                line = take!(input_ch)
                _dispatch_input_line(session, line)
            end

            # Emit diff to client
            try
                new_buf  = render_fn(session)
                diff_str = diff_message(session, new_buf)
                write(io, diff_str * "\n")
            catch e
                @warn "JUI session_pump: diff write failed — disconnecting" exception=(e, catch_backtrace())
                break
            end

            sleep(srv.diff_interval)
        end
    catch e
        @warn "JUI session_pump: pump loop error" exception=(e, catch_backtrace())
    finally
        close(input_ch)
        try; close(io); catch; end
    end

    return nothing
end

"""
    _dispatch_input_line(session::Session, line::String)

Parse a JSON-encoded WireInputMessage line from the client and apply the
inner InputEvent to `session.app` via `handle_key!` / `handle_event!`.

Silently ignores malformed lines (bad client → server protocol is not fatal).
"""
function _dispatch_input_line(session::Session, line::String)
    try
        msg = JSON3.read(line, WireInputMessage)
        msg.type == "input" || return
        evt = decode_input(msg.event)
        frank_input_received(session, evt)
        touch!(session)
        _apply_event_to_session!(session, evt)
    catch e
        @warn "JUI session_pump: bad input line from client" exception=(e, catch_backtrace()) line=line
    end
end

"""
    _apply_event_to_session!(session::Session, evt)

Route an InputEvent to the session's app. For the Phase 3 session pump the
`session.app` is the `Model` instance (same object as on the server). Events
are dispatched via `JUI.update!` (Model protocol).

Resize events update the terminal geometry (not yet wired — deferred to Phase 4
when Terminal is fully remote).
"""
function _apply_event_to_session!(session::Session, evt)
    model = session.app
    if evt isa KeyEvent || evt isa MouseEvent
        try
            update!(model, evt)
        catch e
            @warn "JUI session_pump: update! error" exception=(e, catch_backtrace())
        end
    end
    if evt isa WireResizeEvent && evt.cols > 0 && evt.rows > 0
        session.geometry[] = Rect(1, 1, evt.cols, evt.rows)
        session.last_buffer = nothing  # force full snapshot at new size
        try
            update!(model, evt)  # let model resize TerminalWidget or other state
        catch
        end
    end
    nothing
end

# ── IO line reader for both PipeEndpoint and SSLContext ────────────────────

"""
    _read_line(io) → String

Read a newline-terminated line from `io`. Works for both `Base.PipeEndpoint`
(Unix socket) and `MbedTLS.SSLContext` (TCP+TLS stream).

- For `MbedTLS.SSLContext`: uses `_ssl_readline` (byte-by-byte, workaround for
  readline() hanging on MbedTLS 2.x SSLContext — see transport/tcp.jl).
- For all other IO: uses `readline(io; keep=false)`.
"""
function _read_line(io)::String
    if io isa MbedTLS.SSLContext
        return _ssl_readline(io)
    else
        try
            return readline(io; keep=false)
        catch
            return ""
        end
    end
end

# ── Server constructors ─────────────────────────────────────────────────────

"""
    start_session_unix_server(session::Session, render_fn;
                               diff_interval=1/60) → SessionServer

Start a Unix socket session server for `session`. Each client that connects
and passes peer-UID auth receives a Buffer snapshot followed by a continuous
diff stream. Client keystrokes are decoded and dispatched to `session.app`.

`render_fn(session::Session) → Buffer` — render callback. Called every
`diff_interval` seconds to produce the current frame.

Returns immediately; the accept loop runs in a background task.
"""
function start_session_unix_server(session::Session, render_fn::Function;
                                   diff_interval::Float64 = 1.0/60)::SessionServer
    # Use a Ref so the on_connect closure captures the SessionServer after creation.
    srv_ref = Ref{SessionServer}()

    unix_srv = start_unix_server(session.id.id, function(io)
        _session_pump(srv_ref[], io, render_fn)
    end)

    srv = SessionServer(unix_srv, session, diff_interval, true)
    srv_ref[] = srv
    return srv
end

"""
    start_session_tcp_server(host, port, session::Session, token, render_fn;
                              diff_interval=1/60) → SessionServer

Start a TCP+TLS session server for `session`. Each authenticated client
receives a Buffer snapshot followed by a continuous diff stream. Client
keystrokes are decoded and dispatched to `session.app`.

`render_fn(session::Session) → Buffer` — render callback.

Returns immediately; the accept loop runs in a background task.
"""
function start_session_tcp_server(host::String, port::Int,
                                   session::Session, token::String,
                                   render_fn::Function;
                                   diff_interval::Float64 = 1.0/60)::SessionServer
    srv_ref = Ref{SessionServer}()

    tcp_srv = start_tcp_server(host, port, session.id.id, token, function(ssl_ctx)
        # srv_ref[] is populated before any connection can arrive because
        # the callback is only invoked after TLS + auth handshake, which
        # requires at least one yield after start_tcp_server returns.
        _session_pump(srv_ref[], ssl_ctx, render_fn)
    end)

    srv = SessionServer(tcp_srv, session, diff_interval, true)
    srv_ref[] = srv
    return srv
end

"""
    stop_session_server!(srv::SessionServer)

Gracefully shut down the session server. Stops the transport (closing the
listening socket) and marks the pump as stopped so running pumps exit cleanly.
"""
function stop_session_server!(srv::SessionServer)
    srv.running = false
    if srv.transport isa UnixServer
        stop_unix_server!(srv.transport)
    elseif srv.transport isa TCPServer
        stop_tcp_server!(srv.transport)
    end
    return nothing
end

# ── run_et! — single-call local launch ─────────────────────────────────────

"""
    run_et!(model::Model; fps=60, cols=80, rows=24) → nothing

ET (Embedded Transport) mode: start a Unix socket session server for `model`
and connect a local client in the same process. The client reads the snapshot +
diff stream and renders to a `TestBackend` buffer (headless), forwarding
keystrokes from stdin.

This is the primary single-process session mode: one call, no config, no network.

Flow:
1. Create session for `model` → `new_session(model)`.
2. Define `render_fn`: calls `view(model, frame)` into a fresh Buffer.
3. Start `SessionServer` over a Unix socket (`start_session_unix_server`).
4. Connect local client (`connect_unix`).
5. Read the initial snapshot from the stream and apply it to a client Buffer.
6. Spawn stdin→server forward task (keystrokes up) + diff apply loop (frames down).
7. Block until `should_quit(model)` or client disconnects.
8. `stop_session_server!`, `close_session!`.

Note: in a real deployment the client would be a separate process rendering
to the actual terminal. `run_et!` demonstrates the single-process pattern for
testing and embedding. A full PTY-attached loop is Phase 4.
"""
function run_et!(model::Model; fps::Int = 60, cols::Int = 80, rows::Int = 24)
    session = new_session(model)
    rect    = Rect(1, 1, cols, rows)

    render_fn = function (sess::Session)
        buf = Buffer(rect)
        f   = Frame(buf, rect, GraphicsRegion[], PixelSnapshot[])
        Base.invokelatest(view, sess.app, f)
        buf
    end

    srv = start_session_unix_server(session, render_fn; diff_interval = 1.0 / fps)

    # Give the accept loop a moment to bind
    yield()

    client_io = connect_unix(session.id.id)

    # Read initial snapshot
    snap_line  = _read_line(client_io)
    client_buf = isempty(snap_line) ? Buffer(rect) : apply_snapshot(snap_line)

    # Input forward task (stdin → server)
    quit_ch = Channel{Nothing}(1)
    input_task = @async begin
        try
            while !isready(quit_ch) && isopen(client_io)
                if bytesavailable(stdin) > 0
                    evt = try read_event() catch; nothing end
                    evt === nothing && continue
                    # Wrap in WireInputMessage and send up
                    if evt isa KeyEvent || evt isa MouseEvent
                        msg_str = input_message(session, evt) * "\n"
                        write(client_io, msg_str)
                    end
                else
                    sleep(0.01)
                end
            end
        catch
        end
    end

    # Diff apply loop (server → client_buf)
    diff_interval_s = 1.0 / fps
    try
        while !should_quit(model) && isopen(client_io)
            if bytesavailable(client_io) > 0
                line = _read_line(client_io)
                if !isempty(line)
                    client_buf = apply_diff!(client_buf, line)
                end
            else
                sleep(diff_interval_s)
            end
        end
    finally
        close(quit_ch)
        try; close(client_io); catch; end
    end

    stop_session_server!(srv)
    close_session!(session.id)
    nothing
end

"""
    run_tcp!(model::Model, host::String, port::Int, token::String;
             fps=60, cols=80, rows=24) → SessionServer

Start a TCP+TLS session server for `model` at `host:port` with bearer `token`.
Returns the running `SessionServer`. The caller is responsible for stopping it
via `stop_session_server!` and closing the session.

Remote mode: the caller runs `connect_tcp(host, port, token)` from a separate
process/machine to attach a client. The server API is identical to local ET mode.

Example:
```julia
model = MyApp()
srv   = run_tcp!(model, "0.0.0.0", 7878, JUI.generate_token(); cols=120, rows=40)
# ... server runs; clients connect remotely ...
stop_session_server!(srv)
JUI.close_session!(srv.session.id)
```
"""
function run_tcp!(model::Model, host::String, port::Int, token::String;
                  fps::Int = 60, cols::Int = 80, rows::Int = 24)::SessionServer
    session = new_session(model)
    session.geometry[] = Rect(1, 1, cols, rows)

    render_fn = function (sess::Session)
        rect = sess.geometry[]
        buf  = Buffer(rect)
        f    = Frame(buf, rect, GraphicsRegion[], PixelSnapshot[])
        Base.invokelatest(view, sess.app, f)
        buf
    end

    start_session_tcp_server(host, port, session, token, render_fn;
                              diff_interval = 1.0 / fps)
end
