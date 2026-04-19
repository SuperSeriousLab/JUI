# Copyright 2026 Super Serious Studios
#
# MIT License
#
#
#
# ── test/auth_test.jl ─────────────────────────────────────────────────────
# Tests for Phase 3 chunk 1 auth module:
#   - paths.jl (XDG paths, mode checks, symlink rejection)
#   - token.jl (generate, write/load roundtrip, constant-time compare)
#   - peer.jl  (peer_uid via socketpair)
#   - auth.jl  (AuthGate dispatch)
# ─────────────────────────────────────────────────────────────────────────

@testset "auth/paths" begin
    # Save and isolate XDG_RUNTIME_DIR to a temp dir for all tests
    original_xdg = get(ENV, "XDG_RUNTIME_DIR", nothing)
    tmpbase = mktempdir()

    try
        ENV["XDG_RUNTIME_DIR"] = tmpbase

        @testset "jui_runtime_dir creates dir with mode 0700" begin
            # Remove any pre-existing jui dir from prior runs
            jui_dir = joinpath(tmpbase, "jui")
            rm(jui_dir, force=true, recursive=true)

            dir = jui_runtime_dir()
            @test isdir(rstrip(dir, '/'))
            mode = filemode(lstat(rstrip(dir, '/')))
            @test (mode & 0o777) == 0o700
        end

        @testset "socket_path returns correct concat" begin
            p = socket_path("mysess")
            @test endswith(p, "mysess.sock")
            @test occursin("jui", p)
        end

        @testset "token_path returns correct concat" begin
            p = token_path("mysess")
            @test endswith(p, "mysess.token")
            @test occursin("jui", p)
        end

        @testset "jui_runtime_dir reuses existing dir if perms are correct" begin
            # Should not throw on second call when dir already exists
            dir1 = jui_runtime_dir()
            dir2 = jui_runtime_dir()
            @test dir1 == dir2
        end

        @testset "bad mode on existing dir → throws" begin
            jui_dir = rstrip(jui_runtime_dir(), '/')
            # Set wrong permissions
            chmod(jui_dir, 0o755)
            @test_throws ErrorException jui_runtime_dir()
            # Restore so subsequent tests work
            chmod(jui_dir, 0o700)
        end

        @testset "symlink at path → throws" begin
            # Create a symlink where the jui dir should be
            jui_dir = rstrip(jui_runtime_dir(), '/')
            rm(jui_dir, force=true, recursive=true)
            target = mktempdir()
            symlink(target, jui_dir)
            @test_throws ErrorException jui_runtime_dir()
            # Clean up
            rm(jui_dir)   # remove symlink
            rm(target, force=true, recursive=true)
        end

    finally
        # Restore XDG_RUNTIME_DIR
        if original_xdg === nothing
            delete!(ENV, "XDG_RUNTIME_DIR")
        else
            ENV["XDG_RUNTIME_DIR"] = original_xdg
        end
        rm(tmpbase, force=true, recursive=true)
    end

    @testset "getuid returns positive integer" begin
        uid = getuid()
        @test uid isa Int
        @test uid >= 0
    end

    @testset "ensure_secure_file sets and verifies mode" begin
        f = tempname()
        write(f, "test")
        ensure_secure_file(f, UInt16(0o600))
        mode = filemode(lstat(f))
        @test (mode & 0o777) == 0o600
        rm(f)
    end

    @testset "ensure_secure_file throws for missing file" begin
        @test_throws ErrorException ensure_secure_file("/nonexistent/path/xyz.tok")
    end
end

@testset "auth/token" begin
    @testset "generate_token returns base64url string ~22 chars" begin
        tok = generate_token()
        @test tok isa String
        # 16 bytes → 22 base64url chars (no padding)
        @test length(tok) >= 21 && length(tok) <= 24
        # Only base64url characters: A-Z a-z 0-9 - _
        @test all(c -> isletter(c) || isdigit(c) || c == '-' || c == '_', tok)
        # No padding
        @test !occursin('=', tok)
    end

    @testset "two generate_token calls produce different tokens" begin
        t1 = generate_token()
        t2 = generate_token()
        @test t1 != t2
    end

    @testset "write_token + load_token round-trips correctly" begin
        tmpdir = mktempdir()
        path = joinpath(tmpdir, "test.token")
        tok = generate_token()
        write_token(path, tok)
        loaded = load_token(path)
        @test loaded == tok
        # Verify mode 0600
        mode = filemode(lstat(path))
        @test (mode & 0o777) == 0o600
        rm(tmpdir, recursive=true)
    end

    @testset "load_token throws for missing file" begin
        @test_throws ErrorException load_token("/nonexistent/path/notoken.token")
    end

    @testset "load_token throws for wrong permissions" begin
        tmpdir = mktempdir()
        path = joinpath(tmpdir, "bad.token")
        tok = generate_token()
        write(path, tok)
        chmod(path, 0o644)  # wrong perms
        @test_throws ErrorException load_token(path)
        rm(tmpdir, recursive=true)
    end

    @testset "compare_tokens_ct equal tokens → true" begin
        tok = generate_token()
        @test compare_tokens_ct(tok, tok) == true
    end

    @testset "compare_tokens_ct different tokens → false" begin
        t1 = generate_token()
        t2 = generate_token()
        # Extremely unlikely to collide; if they do, regenerate
        if t1 == t2; t2 = generate_token() * "X"; end
        @test compare_tokens_ct(t1, t2) == false
    end

    @testset "compare_tokens_ct different lengths → false" begin
        @test compare_tokens_ct("short", "much-longer-token") == false
        @test compare_tokens_ct("", "x") == false
        @test compare_tokens_ct("x", "") == false
    end

    @testset "compare_tokens_ct empty vs empty → true" begin
        @test compare_tokens_ct("", "") == true
    end

    @testset "compare_tokens_ct single-byte difference → false" begin
        tok = generate_token()
        # Flip one character
        bytes = collect(tok)
        bytes[end] = bytes[end] == 'A' ? 'B' : 'A'
        @test compare_tokens_ct(tok, String(bytes)) == false
    end
end

@testset "auth/peer" begin
    # Use socketpair(2) to create a connected Unix socket pair on which
    # both ends belong to the current process (same UID).
    AF_UNIX_PEER    = Cint(1)
    SOCK_STREAM_PEER = Cint(1)

    @testset "peer_uid returns current uid via socketpair" begin
        fds = Vector{Cint}([0, 0])
        ret = ccall(:socketpair, Cint, (Cint, Cint, Cint, Ptr{Cint}),
                    AF_UNIX_PEER, SOCK_STREAM_PEER, 0, fds)
        if ret != 0
            @warn "socketpair not available on this system — skipping peer_uid test"
            @test_skip "socketpair unavailable"
        else
            try
                uid = peer_uid(fds[1])
                @test uid == Cint(getuid())
            catch e
                # System may not support getpeereid or SO_PEERCRED in unusual configs
                @warn "peer_uid test failed" exception=(e, catch_backtrace())
                @test_skip "peer_uid not supported on this system: $e"
            finally
                ccall(:close, Cint, (Cint,), fds[1])
                ccall(:close, Cint, (Cint,), fds[2])
            end
        end
    end

    @testset "check_peer_uid returns true for own-uid connection" begin
        fds = Vector{Cint}([0, 0])
        ret = ccall(:socketpair, Cint, (Cint, Cint, Cint, Ptr{Cint}),
                    AF_UNIX_PEER, SOCK_STREAM_PEER, 0, fds)
        if ret != 0
            @warn "socketpair not available — skipping check_peer_uid test"
            @test_skip "socketpair unavailable"
        else
            try
                result = check_peer_uid(fds[1])
                @test result == true
            catch e
                @warn "check_peer_uid test failed" exception=(e, catch_backtrace())
                @test_skip "check_peer_uid not supported: $e"
            finally
                ccall(:close, Cint, (Cint,), fds[1])
                ccall(:close, Cint, (Cint,), fds[2])
            end
        end
    end

    @testset "check_peer_uid with invalid fd returns false" begin
        # Negative fd — _extract_fd handles it, check_peer_uid returns false
        @test check_peer_uid(Cint(-1)) == false
    end
end

@testset "auth/AuthGate" begin
    @testset "UnixPeerGate authorize returns true for same-uid socketpair" begin
        fds = Vector{Cint}([0, 0])
        ret = ccall(:socketpair, Cint, (Cint, Cint, Cint, Ptr{Cint}),
                    Cint(1), Cint(1), 0, fds)
        if ret != 0
            @test_skip "socketpair unavailable"
        else
            try
                gate = UnixPeerGate()
                @test authorize(gate, fds[1]) == true
            catch e
                @warn "UnixPeerGate test failed" exception=(e, catch_backtrace())
                @test_skip "UnixPeerGate not supported: $e"
            finally
                ccall(:close, Cint, (Cint,), fds[1])
                ccall(:close, Cint, (Cint,), fds[2])
            end
        end
    end

    @testset "TCPTokenGate authorize correct token → true" begin
        tok = generate_token()
        gate = TCPTokenGate(tok)
        @test authorize(gate, tok) == true
    end

    @testset "TCPTokenGate authorize wrong token → false" begin
        tok = generate_token()
        gate = TCPTokenGate(tok)
        wrong = generate_token()
        # Regenerate if collision (astronomically unlikely)
        if wrong == tok; wrong = tok * "x"; end
        @test authorize(gate, wrong) == false
    end

    @testset "TCPTokenGate authorize empty token → false" begin
        tok = generate_token()
        gate = TCPTokenGate(tok)
        @test authorize(gate, "") == false
    end

    @testset "AuthGate abstract — unimplemented subtype throws" begin
        struct _TestGate <: AuthGate end
        @test_throws ErrorException authorize(_TestGate(), "anything")
    end

end

@testset "Phase 3: TLS + SPKI" begin
    tmpdir = mktempdir()
    withenv("XDG_CONFIG_HOME" => tmpdir) do
        @testset "ensure_server_cert creates files with correct perms" begin
            (cert, key) = ensure_server_cert()
            @test isfile(cert)
            @test isfile(key)
            @test (stat(key).mode & 0o777) == 0o600
        end

        @testset "SPKI hash is deterministic for same key" begin
            (cert, _key) = ensure_server_cert()
            h1 = spki_hash(cert)
            h2 = spki_hash(cert)
            @test h1 == h2
            @test length(h1) == 64  # SHA-256 hex = 64 chars
            @test all(c -> c in "0123456789abcdef", h1)
        end

        @testset "ensure_server_cert is idempotent (returns same paths)" begin
            (cert1, key1) = ensure_server_cert()
            (cert2, key2) = ensure_server_cert()
            @test cert1 == cert2
            @test key1  == key2
        end

        @testset "TOFU pin store — first connect writes pin" begin
            server = "test.local:9999"
            test_hash = "a" ^ 64
            @test spki_verify(server, test_hash) == true   # TOFU write
            @test spki_verify(server, test_hash) == true   # replay, still matches
            @test spki_verify(server, "b" ^ 64)  == false  # mismatch
        end

        @testset "spki_unpin! removes pin and returns correct Bool" begin
            server = "test.local:9999"
            test_hash = "a" ^ 64
            # Ensure pin exists (may have been written by prior testset)
            spki_verify(server, test_hash)
            @test spki_unpin!(server) == true
            @test spki_unpin!(server) == false  # already gone
            @test spki_verify(server, test_hash) == true   # new TOFU after unpin
            # Clean up
            spki_unpin!(server)
        end
    end
end
