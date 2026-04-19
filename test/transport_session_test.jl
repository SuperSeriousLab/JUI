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
# ── test/transport_session_test.jl ──────────────────────────────────────────
# Phase 3 chunk 3c: Session pump integration tests.
#
# Tests exercise the full protocol stack:
#   1. Unix socket session: connect → snapshot → input → diff round-trip
#   2. TCP+TLS session:     connect → snapshot → input → diff round-trip
#   3. SessionServer lifecycle: start + stop, session cleanup
#   4. run_tcp! convenience: start server, verify session registered
#
# All tests use a minimal Model (TextInput widget) so the render function
# produces concrete Buffer diffs on each keystroke. No real terminal required.
# ────────────────────────────────────────────────────────────────────────────

# ── Minimal test model ───────────────────────────────────────────────────────

const _SS_COLS = 20
const _SS_ROWS = 3

struct _SessionModel <: T.Model
    widget::T.TextInput
end
_SessionModel() = _SessionModel(T.TextInput(; text="", focused=true))

function T.view(m::_SessionModel, f::T.Frame)
    T.render(m.widget, f.area, f.buffer)
end

function T.update!(m::_SessionModel, evt::T.KeyEvent)
    T.handle_key!(m.widget, evt)
end

T.should_quit(::_SessionModel) = false

# ── Helper: render model into Buffer ─────────────────────────────────────────

function _session_render(sess::T.Session)::T.Buffer
    rect = T.Rect(1, 1, _SS_COLS, _SS_ROWS)
    buf  = T.Buffer(rect)
    gfx  = T.GraphicsRegion[]
    pix  = T.PixelSnapshot[]
    f    = T.Frame(buf, rect, gfx, pix)
    T.view(sess.app, f)
    buf
end

# Helper: read one newline-terminated line from a PipeEndpoint with timeout
function _read_line_timeout(io, timeout_secs::Float64 = 5.0)::String
    result = Ref("")
    done_ch = Channel{Bool}(1)
    @async begin
        try
            result[] = readline(io; keep=false)
        catch
        end
        put!(done_ch, true)
    end
    t0 = time()
    while !isready(done_ch) && (time() - t0) < timeout_secs
        sleep(0.05)
    end
    isready(done_ch) || error("_read_line_timeout: timed out after $(timeout_secs)s")
    result[]
end

# Helper: cells equal
function _bufs_equal(a::T.Buffer, b::T.Buffer)
    a.area == b.area || return false
    length(a.content) == length(b.content) || return false
    for (ca, cb) in zip(a.content, b.content)
        ca == cb || return false
    end
    true
end

# ─────────────────────────────────────────────────────────────────────────────

@testset "Phase 3c: Unix socket session pump" begin
    tmpdir = mktempdir()
    tmprun = mktempdir()
    withenv("XDG_CONFIG_HOME" => tmpdir, "XDG_RUNTIME_DIR" => tmprun) do
        model   = _SessionModel()
        session = T.new_session(model)

        srv = T.start_session_unix_server(session, _session_render)
        @test srv isa T.SessionServer
        @test srv.running

        # Allow accept loop to start
        sleep(0.1)

        # Connect local client
        client_io = T.connect_unix(session.id.id)
        @test isopen(client_io)

        # Read initial snapshot
        snap_line = _read_line_timeout(client_io)
        @test !isempty(snap_line)
        @test occursin("\"snapshot\"", snap_line)

        client_buf = T.apply_snapshot(snap_line)
        @test client_buf isa T.Buffer
        @test client_buf.area == T.Rect(1, 1, _SS_COLS, _SS_ROWS)

        # ── Send input: type 'a' ────────────────────────────────────────────
        key_evt   = T.KeyEvent(:char, 'a', T.key_press)
        input_str = T.input_message(session, key_evt) * "\n"
        write(client_io, input_str)

        # Wait for diff (server's pump interval + processing time)
        sleep(0.15)

        # Read diff from server
        diff_line = _read_line_timeout(client_io)
        @test !isempty(diff_line)
        # Server may send snapshot or diff — both valid
        @test occursin("\"snapshot\"", diff_line) || occursin("\"diff\"", diff_line)

        client_buf = T.apply_diff!(client_buf, diff_line)
        @test client_buf isa T.Buffer

        # The model's widget should have received 'a' via _dispatch_input_line
        # (processed from input_ch in the pump loop — may need a moment)
        sleep(0.1)
        @test T.text(model.widget) == "a"

        # ── Stop server ─────────────────────────────────────────────────────
        close(client_io)
        T.stop_session_server!(srv)
        @test !srv.running

        T.close_session!(session.id)
    end
end

@testset "Phase 3c: TCP+TLS session pump" begin
    tmpdir = mktempdir()
    tmprun = mktempdir()
    withenv("XDG_CONFIG_HOME" => tmpdir, "XDG_RUNTIME_DIR" => tmprun) do
        model   = _SessionModel()
        session = T.new_session(model)
        token   = T.generate_token()

        srv = T.start_session_tcp_server("127.0.0.1", 0, session, token, _session_render)
        @test srv isa T.SessionServer
        @test srv.running

        port = srv.transport.port
        @test port > 0

        # Allow accept loop to start
        sleep(0.1)

        # Connect client (TLS + auth handshake happens inside connect_tcp)
        ssl_ctx = T.connect_tcp("127.0.0.1", port, token)

        # Read initial snapshot over TLS
        snap_line = T._ssl_readline(ssl_ctx)
        @test !isempty(snap_line)
        @test occursin("\"snapshot\"", snap_line)

        client_buf = T.apply_snapshot(snap_line)
        @test client_buf isa T.Buffer
        @test client_buf.area == T.Rect(1, 1, _SS_COLS, _SS_ROWS)

        # ── Send input: type 'z' ────────────────────────────────────────────
        key_evt   = T.KeyEvent(:char, 'z', T.key_press)
        input_str = T.input_message(session, key_evt) * "\n"
        write(ssl_ctx, input_str)

        # Wait for diff
        sleep(0.15)

        diff_line = T._ssl_readline(ssl_ctx)
        @test !isempty(diff_line)
        @test occursin("\"snapshot\"", diff_line) || occursin("\"diff\"", diff_line)

        client_buf = T.apply_diff!(client_buf, diff_line)
        @test client_buf isa T.Buffer

        sleep(0.1)
        @test T.text(model.widget) == "z"

        # ── Stop ─────────────────────────────────────────────────────────────
        close(ssl_ctx)
        T.stop_session_server!(srv)
        @test !srv.running

        T.close_session!(session.id)
    end
end

@testset "Phase 3c: SessionServer lifecycle" begin
    tmpdir = mktempdir()
    tmprun = mktempdir()
    withenv("XDG_CONFIG_HOME" => tmpdir, "XDG_RUNTIME_DIR" => tmprun) do
        model   = _SessionModel()
        session = T.new_session(model)

        srv = T.start_session_unix_server(session, _session_render)
        @test srv.running

        T.stop_session_server!(srv)
        @test !srv.running

        # Session still alive after server stop (reconnect possible)
        @test T.get_session(session.id) !== nothing

        T.close_session!(session.id)
        @test T.get_session(session.id) === nothing
    end
end

@testset "Phase 3c: run_tcp! convenience" begin
    tmpdir = mktempdir()
    tmprun = mktempdir()
    withenv("XDG_CONFIG_HOME" => tmpdir, "XDG_RUNTIME_DIR" => tmprun) do
        model = _SessionModel()
        token = T.generate_token()

        srv = T.run_tcp!(model, "127.0.0.1", 0, token; cols=_SS_COLS, rows=_SS_ROWS)
        @test srv isa T.SessionServer
        @test srv.running
        @test srv.transport.port > 0
        @test T.get_session(srv.session.id) !== nothing

        # Verify a client can connect and get a snapshot
        port    = srv.transport.port
        ssl_ctx = T.connect_tcp("127.0.0.1", port, token)
        line    = T._ssl_readline(ssl_ctx)
        @test occursin("\"snapshot\"", line)
        close(ssl_ctx)
        sleep(0.1)

        T.stop_session_server!(srv)
        @test !srv.running

        T.close_session!(srv.session.id)
    end
end
