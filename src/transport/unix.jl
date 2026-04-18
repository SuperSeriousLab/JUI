# Copyright 2026 eidos workspace
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
# ── transport/unix.jl ────────────────────────────────────────────────────
# Phase 3 chunk 3a: Unix socket transport with peer-UID auth gate.
#
# Server binds to socket_path(session_id) under jui_runtime_dir() (mode 0700,
# owner-checked). Socket is chmod'd 0600 after bind. Each accepted connection
# is authenticated via UnixPeerGate (getpeereid/SO_PEERCRED). Unauthorised
# peers are silently closed; FRANK emits auth.ok / auth.reject on every accept.
#
# Julia stdlib: `listen(path)` → Sockets.PipeServer
#               `accept(server)` → Base.PipeEndpoint
#               `connect(path)` → Base.PipeEndpoint
#
# TCP + TLS transport is chunk 3b — not in this file.
# ─────────────────────────────────────────────────────────────────────────

import Sockets

export UnixServer, start_unix_server, stop_unix_server!, connect_unix

# ── UnixServer ─────────────────────────────────────────────────────────────

"""
    UnixServer

A running Unix socket server bound to `path`, accepting connections gated by
peer-UID auth (`UnixPeerGate`). Spawns an accept loop task on start.

Fields:
- `path`       — socket file path (from `socket_path(session_id)`)
- `server`     — the listening `Sockets.PipeServer` handle
- `session_id` — session identifier string
- `on_connect` — `(client_sock) -> Nothing` — called for each authenticated connection
- `running`    — `true` while accept loop is active
- `task`       — the accept-loop `Task`, or `nothing` before start

Note: Julia's Unix socket API uses `Sockets.PipeServer` (from `listen(path::String)`)
and `Base.PipeEndpoint` (sockets returned by `accept` / `connect`).
"""
mutable struct UnixServer
    path::String
    server::Sockets.PipeServer
    session_id::String
    on_connect::Function
    running::Bool
    task::Union{Task, Nothing}
end

# ── Server lifecycle ────────────────────────────────────────────────────────

"""
    start_unix_server(session_id, on_connect) → UnixServer

Bind a Unix socket at `socket_path(session_id)` and start an accept loop.

Steps:
1. Ensure `jui_runtime_dir()` exists with mode 0700 and owner check.
2. Remove stale socket file if present (safe: parent dir is owner-verified).
3. `listen(path)` → `Sockets.PipeServer`.
4. `chmod(path, 0o600)` — extra lock-down beyond the 0700 parent dir.
5. Spawn accept loop task. Returns immediately.

Each accepted connection is vetted by `check_peer_uid`. Authorised
connections call `on_connect(sock)` in a separate task. Rejected peers
are closed immediately with no response (no oracle).

FRANK `auth.ok` / `auth.reject` events are emitted on every accept.
"""
function start_unix_server(session_id::String, on_connect::Function)::UnixServer
    # Step 1 — ensure parent dir is owner-secure (throws on violation)
    jui_runtime_dir()

    path = socket_path(session_id)

    # Step 2 — remove stale socket file if present
    # Safe: parent dir has already been owner-verified above.
    if ispath(path)
        rm(path, force=true)
    end

    # Step 3 — bind the listening socket
    server = Sockets.listen(path)

    # Step 4 — restrict socket file to owner-only
    # jui_runtime_dir() already guarantees 0700 parent; belt-and-suspenders.
    chmod(path, 0o600)

    srv = UnixServer(path, server, session_id, on_connect, true, nothing)

    # Step 5 — spawn accept loop
    srv.task = @async _accept_loop(srv)

    return srv
end

"""
    stop_unix_server!(srv::UnixServer)

Gracefully shut down the Unix server: close the listening socket, wait for
the accept task to exit, and unlink the socket path.
"""
function stop_unix_server!(srv::UnixServer)
    srv.running = false
    # Close the listening socket — this will cause accept() to throw IOError,
    # which the accept loop catches and uses as its exit signal.
    try
        close(srv.server)
    catch
        # already closed or never started — ignore
    end
    # Wait for the accept task to finish (it will exit on IOError from closed server)
    if srv.task !== nothing
        try
            wait(srv.task)
        catch
            # Task may have exited with an error — that's fine, we're shutting down
        end
    end
    # Unlink the socket file
    try
        rm(srv.path, force=true)
    catch
    end
    return nothing
end

# ── Client side ────────────────────────────────────────────────────────────

"""
    connect_unix(session_id) → Base.PipeEndpoint

Connect to the Unix server socket for `session_id`.
Returns the connected `Base.PipeEndpoint`. Throws if the socket does not exist
or connection is refused.
"""
function connect_unix(session_id::String)::Base.PipeEndpoint
    path = socket_path(session_id)
    return Sockets.connect(path)
end

# ── Accept loop ─────────────────────────────────────────────────────────────

"""
    _accept_loop(srv::UnixServer)

Internal accept task. Loops until `srv.running` is false or the listening
socket is closed.

For each accepted connection:
- `check_peer_uid(sock)` → true  → emit FRANK `auth.ok`, dispatch `on_connect(sock)` in a new task
- `check_peer_uid(sock)` → false → emit FRANK `auth.reject`, close socket immediately (no oracle)

A `Base.IOError` from a closed server is the normal shutdown signal; exits cleanly.
Any other exception is logged and the loop continues (one bad connection must not
kill the server).
"""
function _accept_loop(srv::UnixServer)
    while srv.running
        sock = try
            Sockets.accept(srv.server)
        catch e
            if e isa Base.IOError || e isa EOFError
                # Server was closed (stop_unix_server!) — normal shutdown
                break
            end
            @warn "JUI unix: accept error (ignoring)" exception=(e, catch_backtrace())
            continue
        end

        # Auth check
        if check_peer_uid(sock)
            frank_auth_ok(srv.session_id,
                          Dict{String,Any}("transport" => "unix",
                                           "peer_uid"  => getuid()))
            # Dispatch handler in a separate task so we don't block the accept loop
            handler_fn = srv.on_connect
            @async try
                handler_fn(sock)
            catch e
                @warn "JUI unix: on_connect handler error" exception=(e, catch_backtrace())
            end
        else
            frank_auth_reject(srv.session_id,
                              Dict{String,Any}("transport" => "unix",
                                               "reason"    => "peer_uid"))
            # Close immediately — no message, no oracle
            try
                close(sock)
            catch
            end
        end
    end
    return nothing
end
