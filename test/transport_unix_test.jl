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
# ── test/transport_unix_test.jl ──────────────────────────────────────────
# Phase 3 chunk 3a: Unix socket transport tests.
#
# The reject-foreign-UID path requires fork+setuid and is deferred to a
# multi-UID integration env. Documented below with @test_skip.
# ─────────────────────────────────────────────────────────────────────────

@testset "Phase 3: Unix socket transport" begin
    # Isolate XDG_RUNTIME_DIR to keep tests hermetic — each test run gets
    # its own tmpdir so there is no cross-test socket path collision.
    tmpdir = mktempdir()
    withenv("XDG_RUNTIME_DIR" => tmpdir) do

        # ── 1. Server starts, binds, is accepting ───────────────────────
        received = String[]
        sid = "test-session-unix"

        srv = JUI.start_unix_server(sid, sock -> begin
            line = readline(sock)
            push!(received, line)
            write(sock, "ack\n")
            close(sock)
        end)

        # Socket path should exist
        @test isfile(srv.path) || ispath(srv.path)

        # Socket file should have mode 0600
        @test (stat(srv.path).mode & 0o777) == 0o600

        # srv.running should be true
        @test srv.running

        # ── 2. Same-UID client connects — peer gate passes ──────────────
        client = JUI.connect_unix(sid)
        write(client, "hello\n")
        ack = readline(client)
        @test ack == "ack"
        close(client)

        # Give the async handler time to push to received
        sleep(0.15)
        @test "hello" in received

        # ── 3. Stop server — verify cleanup ────────────────────────────
        JUI.stop_unix_server!(srv)
        @test !ispath(srv.path)
        @test !srv.running

    end

    # ── 4. Reject foreign UID ──────────────────────────────────────────────
    # Testing the reject path requires connecting from a different OS UID,
    # which needs fork(2) + setuid(2) — not available in a standard Julia
    # test harness without root or a secondary OS user account.
    # This is exercised in the multi-UID integration environment (CI with a
    # secondary sudoer). Skip in unit tests.
    @testset "reject foreign UID" begin
        @test_skip "Requires multi-UID test harness; exercised in integration env only"
    end
end
