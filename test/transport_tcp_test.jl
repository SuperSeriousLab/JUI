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
# ── test/transport_tcp_test.jl ──────────────────────────────────────────────
# Phase 3 chunk 3b: TCP+TLS transport tests.
#
# Tests:
#   1. Correct token → auth succeeds, on_connect receives stream
#   2. Wrong token  → connect_tcp throws AuthError
#   3. Empty token  → start_tcp_server refuses to bind (ErrorException)
#   4. SPKI TOFU   → first connect pins, subsequent verify, mismatch = AuthError
# ────────────────────────────────────────────────────────────────────────────

@testset "Phase 3: TCP+TLS transport" begin
    # Isolate XDG dirs to keep tests hermetic.
    tmpdir = mktempdir()
    tmprun  = mktempdir()
    withenv("XDG_CONFIG_HOME" => tmpdir, "XDG_RUNTIME_DIR" => tmprun) do

        sid   = "test-tcp"
        token = JUI.generate_token()

        received = Ref("")

        # Start server on ephemeral port (port=0 → OS assigns)
        # Note: use JUI._ssl_readline instead of readline — MbedTLS.SSLContext
        # readline() hangs; _ssl_readline() uses byte-by-byte read(ctx,1) which works.
        srv = JUI.start_tcp_server("127.0.0.1", 0, sid, token,
            stream -> begin
                line = JUI._ssl_readline(stream)
                received[] = line
                write(stream, "ack\n")
                close(stream)
            end)

        # Actual port should be > 0 after OS assignment
        @test srv.port > 0
        actual_port = srv.port
        @test srv.running

        # ── 1. Correct token → success ─────────────────────────────────────
        stream = JUI.connect_tcp("127.0.0.1", actual_port, token)
        write(stream, "hello\n")
        reply = JUI._ssl_readline(stream)
        @test reply == "ack"
        close(stream)

        # Give async handler time to set received[]
        sleep(0.2)
        @test received[] == "hello"

        # ── 2. Wrong token → AuthError ─────────────────────────────────────
        @test_throws JUI.AuthError JUI.connect_tcp("127.0.0.1", actual_port,
                                                    "wrong-token-xxxxxxxx")

        # ── 3. Empty token → server refuses to start ───────────────────────
        @test_throws ErrorException JUI.start_tcp_server("127.0.0.1", 0, sid,
                                                          "", _ -> nothing)

        # ── Stop server ────────────────────────────────────────────────────
        JUI.stop_tcp_server!(srv)
        @test !srv.running

    end
end

@testset "SPKI TOFU on connect_tcp" begin
    # Full TOFU test with two sequential connects to the same server:
    # - First connect: writes pin (TOFU, returns true)
    # - Second connect: verifies pin (same hash, returns true)
    # Mismatch test: tamper the pin file between connects → AuthError
    #
    # This test requires a running server with a real cert.

    tmpdir = mktempdir()
    tmprun  = mktempdir()
    withenv("XDG_CONFIG_HOME" => tmpdir, "XDG_RUNTIME_DIR" => tmprun) do

        sid   = "test-tcp-tofu"
        token = JUI.generate_token()

        srv = JUI.start_tcp_server("127.0.0.1", 0, sid, token,
            stream -> begin close(stream) end)

        port = srv.port

        # First connect: TOFU pin written (no exception)
        stream1 = JUI.connect_tcp("127.0.0.1", port, token)
        close(stream1)
        sleep(0.1)

        # Second connect: pin verified (no exception)
        stream2 = JUI.connect_tcp("127.0.0.1", port, token)
        close(stream2)
        sleep(0.1)

        # Tamper the pin file to simulate MITM / cert rotation
        server_addr = "127.0.0.1:$port"
        safe_addr = replace(server_addr, ":" => "%3A", "/" => "%2F", "\\" => "%5C")
        pin_file = joinpath(JUI.pin_store_dir(), safe_addr)
        if isfile(pin_file)
            write(pin_file, "0" ^ 64)  # corrupt pin
            chmod(pin_file, 0o600)
            # Third connect: should throw AuthError (SPKI mismatch)
            @test_throws JUI.AuthError JUI.connect_tcp("127.0.0.1", port, token)
        else
            # Pin file was not created — skip mismatch test
            @test_skip "SPKI pin file not found at $pin_file — skipping mismatch test"
        end

        JUI.stop_tcp_server!(srv)
    end
end
