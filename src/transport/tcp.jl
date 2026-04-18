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
# ── transport/tcp.jl ─────────────────────────────────────────────────────
# Phase 3 chunk 3b: TCP+TLS transport with bearer-token auth handshake
# and client SPKI TOFU pinning.
#
# TLS library: MbedTLS.jl (v1.1.x, MbedTLS_jll binary)
# Rationale: MbedTLS.jl ships a self-contained JLL binary (no system TLS
# dependency), is well-maintained, exposes an IO-compatible SSLContext that
# plugs directly into Julia's stdlib TCPSocket, and already ships with JUI's
# transitive dependency tree. SSLConfig(certfile, keyfile) is a one-liner
# for server setup; SSLConfig(false) (no CA verify) plus SPKI TOFU is the
# correct pattern for our self-signed cert model. Full Julia stdlib
# compatibility: SSLContext <: IO, so readline/println/write work unchanged.
#
# Security model (per docs/phase-3-auth-design.md §B):
#   • TLS 1.3 equivalent via MbedTLS (ECDHE cipher negotiation)
#   • One-shot auth handshake BEFORE any session traffic:
#       Client → {"type":"auth","token":"<base64url>"}\n
#       Server → {"type":"auth_ok","session":"<session_id>"}\n  (on success)
#       Server → close (on failure, no oracle)
#   • Server: TCPTokenGate + constant-time compare (compare_tokens_ct)
#   • Deny-by-default: server refuses to bind without token + cert + key
#   • Client: SPKI TOFU pinning via spki_verify()/spki_unpin!()
#   • 5-second handshake timeout prevents slow-loris hangers
#
# What this file does NOT do (chunk 3c):
#   • Session/protocol message wiring
#   • run!() auto-spawn
# ─────────────────────────────────────────────────────────────────────────

import Sockets
using MbedTLS

export TCPServer, start_tcp_server, stop_tcp_server!, connect_tcp

# ── TCPServer ──────────────────────────────────────────────────────────────

"""
    TCPServer

A running TCP+TLS server bound to `host:port`, accepting connections gated by
bearer token auth. Spawns an accept loop task on start.

Fields:
- `host`       — bind address (e.g. "127.0.0.1")
- `port`       — actual bound port (updated after `listen` when port=0 was requested)
- `session_id` — session identifier string
- `token`      — expected bearer token (constant-time compared on every auth msg)
- `cert_path`  — path to the TLS certificate file (used to build fresh SSLConfig per connection)
- `key_path`   — path to the TLS private key file
- `server`     — the listening `Sockets.TCPServer` handle
- `on_connect` — `(authed_ssl_stream) -> Nothing` — called for each authenticated connection
- `running`    — `true` while accept loop is active
- `task`       — the accept-loop `Task`, or `nothing` before start

Note: `SSLConfig` is created fresh per connection (not stored here). MbedTLS 2.x
`SSLConfig` is not reusable across multiple concurrent TLS handshakes — creating
a new one per `accept` is the correct pattern (as in MbedTLS.jl's own test suite).
"""
mutable struct TCPServer
    host::String
    port::Int
    session_id::String
    token::String
    cert_path::String
    key_path::String
    server::Sockets.TCPServer
    on_connect::Function
    running::Bool
    task::Union{Task, Nothing}
end

# ── Server lifecycle ────────────────────────────────────────────────────────

"""
    start_tcp_server(host, port, session_id, token, on_connect) → TCPServer

Bind a TCP+TLS server at `host:port` and start an accept loop.

Deny-by-default checks at entry:
- Refuses to bind if `token` is empty.
- Calls `ensure_server_cert()` to generate cert+key if missing; errors if
  cert or key still absent after generation.

Steps:
1. Deny-by-default checks (empty token, missing cert/key).
2. Load MbedTLS.SSLConfig (server endpoint) from cert+key files.
3. `Sockets.listen(host, port)` → `Base.TCPServer`.
4. Read actual bound port (handles port=0 → OS-assigned ephemeral port).
5. Spawn accept loop task. Returns immediately.

Each accepted connection goes through:
- MbedTLS TLS handshake (server side)
- 5-second auth handshake timeout
- One-shot JSON auth message: `{type:"auth", token:"..."}`
- Constant-time token compare via `TCPTokenGate`
- On match: reply `{type:"auth_ok", session:"..."}` + invoke `on_connect`
- On mismatch/timeout: close, FRANK `auth.reject`
"""
function start_tcp_server(host::String, port::Int, session_id::String,
                           token::String, on_connect::Function)::TCPServer
    # ── Deny-by-default ────────────────────────────────────────────────────
    if isempty(token)
        error("TCPServer: refusing to bind without a token. " *
              "Generate one via generate_token().")
    end

    (cert_path_val, key_path_val) = ensure_server_cert()

    if !isfile(cert_path_val) || !isfile(key_path_val)
        error("TCPServer: refusing to bind without cert+key. " *
              "ensure_server_cert() failed to produce $cert_path_val and $key_path_val")
    end

    # ── Bind TCP listener ───────────────────────────────────────────────────
    addr = Sockets.IPv4(host)
    raw_server = Sockets.listen(addr, port)

    # Retrieve actual bound port (important when port=0 was requested)
    actual_port = Int(Sockets.getsockname(raw_server)[2])

    # Note: SSLConfig is intentionally NOT pre-built here.
    # MbedTLS 2.x SSLConfig is NOT reusable across concurrent TLS handshakes.
    # A fresh SSLConfig(cert, key) is created per accepted connection inside
    # _handle_tcp_connection. This matches the MbedTLS.jl test suite pattern.
    srv = TCPServer(host, actual_port, session_id, token,
                    cert_path_val, key_path_val,
                    raw_server, on_connect, true, nothing)

    # ── Spawn accept loop ───────────────────────────────────────────────────
    srv.task = @async _tcp_accept_loop(srv)

    return srv
end

"""
    stop_tcp_server!(srv::TCPServer)

Gracefully shut down the TCP server: close the listening socket and wait for
the accept task to exit.
"""
function stop_tcp_server!(srv::TCPServer)
    srv.running = false
    try
        close(srv.server)
    catch
        # Already closed — ignore.
    end
    if srv.task !== nothing
        try
            wait(srv.task)
        catch
            # Task may exit with IOError on close — that is the normal shutdown path.
        end
    end
    return nothing
end

# ── Client side ────────────────────────────────────────────────────────────

"""
    connect_tcp(host, port, token) → MbedTLS.SSLContext

Connect to a JUI TCP+TLS server, perform SPKI TOFU verification, send the
bearer token, and return the authenticated TLS stream on success.

Steps:
1. TCP connect to `host:port`.
2. TLS handshake (client side, no CA verify — SPKI TOFU instead).
3. Extract server cert; compute SPKI hash.
4. Call `spki_verify(server_addr, spki_hash)`:
   - First connect (no pin): writes pin, logs loud TOFU notice to stderr.
   - Subsequent connects: verifies match. Mismatch → throws `AuthError`.
5. Send `{"type":"auth","token":"<token>"}\n`.
6. Read server reply. Expect `{"type":"auth_ok","session":"..."}`.
7. On `auth_ok`: return the `SSLContext`. Caller uses it for session traffic.
8. On anything else or closed: throws `AuthError`.

Throws:
- `AuthError` on SPKI pin mismatch, wrong server response, or closed connection.
"""
function connect_tcp(host::String, port::Int, token::String)::MbedTLS.SSLContext
    server_addr = "$host:$port"

    # Step 1: TCP connect
    tcp_sock = Sockets.connect(host, port)

    # Step 2: TLS handshake — client side with no CA verification (SPKI TOFU)
    ssl_conf_client = MbedTLS.SSLConfig(false)  # false = no CA verify
    ssl_ctx = MbedTLS.SSLContext()
    MbedTLS.setup!(ssl_ctx, ssl_conf_client)
    MbedTLS.set_bio!(ssl_ctx, tcp_sock)
    try
        MbedTLS.handshake(ssl_ctx)
    catch e
        try; close(tcp_sock); catch; end
        throw(AuthError("TLS handshake failed connecting to $server_addr: $e"))
    end

    # Step 3+4: Extract SPKI hash from server cert and run TOFU check.
    # We bypass the broken MbedTLS.get_peer_cert Julia wrapper (it calls
    # CRT(ptr) which isn't defined in MbedTLS 2.x Julia bindings) and use
    # ccall directly to get the peer cert raw pointer for DER extraction.
    observed_hash = _spki_hash_from_ssl_ctx(ssl_ctx)

    if !spki_verify(server_addr, observed_hash)
        try; close(ssl_ctx); catch; end
        throw(AuthError(
            "SPKI pin mismatch for $server_addr — possible MITM or legitimate " *
            "cert rotation. Use spki_unpin!(\"$server_addr\") to re-TOFU."
        ))
    end

    # Step 5: Send auth message
    auth_msg = JSON3.write(WireAuthMessage("auth", token)) * "\n"
    try
        write(ssl_ctx, auth_msg)
    catch e
        try; close(ssl_ctx); catch; end
        throw(AuthError("Failed to send auth message to $server_addr: $e"))
    end

    # Step 6: Read server reply
    # Note: readline() hangs on MbedTLS.SSLContext. Use _ssl_readline() instead,
    # which reads byte-by-byte via read(ctx, 1) — the only reliable IO method for
    # MbedTLS 2.x SSLContext with newline-framed messages.
    reply_line = try
        _ssl_readline(ssl_ctx)
    catch e
        try; close(ssl_ctx); catch; end
        throw(AuthError("Failed to read auth reply from $server_addr: $e"))
    end

    if isempty(reply_line)
        try; close(ssl_ctx); catch; end
        throw(AuthError("Server $server_addr closed connection during auth (token rejected)"))
    end

    # Step 7: Parse and validate reply
    reply = try
        JSON3.read(reply_line, WireAuthOkMessage)
    catch
        try; close(ssl_ctx); catch; end
        throw(AuthError("Server $server_addr sent unexpected auth reply: $(repr(reply_line))"))
    end

    if reply.type != "auth_ok"
        try; close(ssl_ctx); catch; end
        throw(AuthError("Server $server_addr auth failed: type=$(reply.type)"))
    end

    return ssl_ctx
end

# ── Accept loop ─────────────────────────────────────────────────────────────

"""
    _tcp_accept_loop(srv::TCPServer)

Internal accept task. Loops until `srv.running` is false or the listening
socket is closed.

For each accepted TCP connection:
1. Wrap with MbedTLS server-side SSL context and perform TLS handshake.
2. Apply 5-second timeout for the auth handshake.
3. Read one line: parse as `WireAuthMessage`.
4. Constant-time compare via `TCPTokenGate`.
5. On match: send `WireAuthOkMessage`, emit FRANK `auth.ok`, dispatch `on_connect`.
6. On fail: close, emit FRANK `auth.reject` with reason.

A `Base.IOError` from a closed server is the normal shutdown signal.
One bad connection must not kill the server — errors are caught per-connection.
"""
function _tcp_accept_loop(srv::TCPServer)
    gate = TCPTokenGate(srv.token)

    while srv.running
        tcp_sock = try
            Sockets.accept(srv.server)
        catch e
            if e isa Base.IOError || e isa EOFError
                # Server was closed via stop_tcp_server! — normal shutdown.
                break
            end
            @warn "JUI tcp: accept error (ignoring)" exception=(e, catch_backtrace())
            continue
        end

        # Handle each connection in a separate task — never block the accept loop.
        handler_fn = srv.on_connect
        session_id = srv.session_id
        cert_p     = srv.cert_path
        key_p      = srv.key_path

        @async _handle_tcp_connection(tcp_sock, cert_p, key_p, gate, session_id, handler_fn)
    end
    return nothing
end

"""
    _handle_tcp_connection(tcp_sock, cert_path, key_path, gate, session_id, on_connect)

Per-connection handler. Called in its own @async task.
Performs TLS handshake + auth handshake, then dispatches on_connect.

Creates a fresh `SSLConfig(cert_path, key_path)` per connection — MbedTLS 2.x
`SSLConfig` is not reusable across concurrent TLS handshakes.
"""
function _handle_tcp_connection(tcp_sock, cert_path::String, key_path::String,
                                 gate::TCPTokenGate, session_id::String,
                                 on_connect::Function)
    # ── TLS handshake (server side) — fresh SSLConfig per connection ────────
    # MbedTLS.SSLConfig is not thread-safe / reusable across handshakes.
    # Create a new one for each accepted connection (matches MbedTLS.jl test suite).
    ssl_conf = MbedTLS.SSLConfig(cert_path, key_path)
    ssl_ctx = MbedTLS.SSLContext()
    MbedTLS.setup!(ssl_ctx, ssl_conf)
    MbedTLS.associate!(ssl_ctx, tcp_sock)

    tls_ok = try
        MbedTLS.handshake(ssl_ctx)
        true
    catch e
        frank_auth_reject(session_id,
            Dict{String,Any}("transport" => "tcp",
                             "reason"    => "tls_handshake",
                             "error"     => string(e)))
        try; close(ssl_ctx); catch; end
        false
    end
    tls_ok || return nothing

    # ── Auth handshake with 5-second timeout ───────────────────────────────
    auth_result = _auth_handshake_with_timeout(ssl_ctx, gate, session_id, 5.0)

    if auth_result
        # Success — FRANK event + dispatch handler
        frank_auth_ok(session_id,
            Dict{String,Any}("transport" => "tcp",
                             "session"   => session_id))
        try
            on_connect(ssl_ctx)
        catch e
            @warn "JUI tcp: on_connect handler error" exception=(e, catch_backtrace())
        end
    else
        # Failure already logged inside _auth_handshake_with_timeout
        try; close(ssl_ctx); catch; end
    end

    return nothing
end

"""
    _auth_handshake_with_timeout(ssl_ctx, gate, session_id, timeout_secs) → Bool

Perform the one-shot bearer token handshake over `ssl_ctx`.
Returns `true` on success, `false` on any failure (with FRANK event emitted).

The handshake must complete within `timeout_secs` seconds from entry.
A Channel-based async approach is used for the timeout so the accept loop
is never blocked by a slow/malicious client.
"""
function _auth_handshake_with_timeout(ssl_ctx::MbedTLS.SSLContext,
                                       gate::TCPTokenGate,
                                       session_id::String,
                                       timeout_secs::Float64)::Bool
    result_ch = Channel{Union{Bool, String}}(1)

    # Read auth message in a separate task — the timeout closes the channel.
    # Note: readline() hangs on MbedTLS.SSLContext — use _ssl_readline().
    reader = @async begin
        try
            line = _ssl_readline(ssl_ctx)
            put!(result_ch, line)
        catch e
            put!(result_ch, false)
        end
    end

    # Timeout watchdog
    watchdog = @async begin
        sleep(timeout_secs)
        # If channel is empty, reader is still running — inject failure sentinel
        if isready(result_ch) == false
            put!(result_ch, false)
        end
    end

    raw = take!(result_ch)

    # Cancel reader/watchdog (best-effort — tasks will exit on next IO/sleep)
    # We don't forcibly kill them; they self-terminate on ssl_ctx close.

    if raw === false
        frank_auth_reject(session_id,
            Dict{String,Any}("transport" => "tcp",
                             "reason"    => "handshake_timeout"))
        return false
    end

    line = raw::String

    if isempty(line)
        frank_auth_reject(session_id,
            Dict{String,Any}("transport" => "tcp",
                             "reason"    => "handshake_timeout"))
        return false
    end

    # Parse auth message
    msg = try
        JSON3.read(line, WireAuthMessage)
    catch
        frank_auth_reject(session_id,
            Dict{String,Any}("transport" => "tcp",
                             "reason"    => "malformed_auth_msg"))
        return false
    end

    if msg.type != "auth"
        frank_auth_reject(session_id,
            Dict{String,Any}("transport" => "tcp",
                             "reason"    => "bad_auth_type",
                             "got"       => msg.type))
        return false
    end

    # Constant-time token compare
    if !authorize(gate, msg.token)
        frank_auth_reject(session_id,
            Dict{String,Any}("transport" => "tcp",
                             "reason"    => "token_mismatch"))
        return false
    end

    # Send success reply
    ok_msg = JSON3.write(WireAuthOkMessage("auth_ok", session_id)) * "\n"
    try
        write(ssl_ctx, ok_msg)
    catch e
        frank_auth_reject(session_id,
            Dict{String,Any}("transport" => "tcp",
                             "reason"    => "write_error",
                             "error"     => string(e)))
        return false
    end

    return true
end

# ── IO helpers for MbedTLS.SSLContext ──────────────────────────────────────

"""
    _ssl_readline(ctx::MbedTLS.SSLContext; maxbytes=4096) → String

Read a newline-terminated line from an MbedTLS SSLContext.

`Base.readline` and `Base.readuntil` hang on MbedTLS 2.x SSLContext because
they rely on `read(io, Char)` patterns that don't work correctly with MbedTLS's
internal buffering. The only reliable approach is `read(ctx, 1)` byte-by-byte,
which maps to a single `mbedtls_ssl_read` call per byte and correctly yields
to the Julia scheduler between reads.

Returns the line content WITHOUT the trailing newline.
Returns `""` on EOF (connection closed before newline).
"""
function _ssl_readline(ctx::MbedTLS.SSLContext; maxbytes::Int = 8_388_608)::String
    buf = UInt8[]
    while length(buf) < maxbytes
        b = try
            read(ctx, 1)
        catch
            return String(buf)  # EOF or error → return what we have
        end
        isempty(b) && break
        b[1] == UInt8('\n') && break
        push!(buf, b[1])
    end
    return String(buf)
end

# ── SPKI hash extraction from TLS peer cert ────────────────────────────────

"""
    _spki_hash_from_ssl_ctx(ctx::MbedTLS.SSLContext) → String

Extract the SPKI (SubjectPublicKeyInfo) SHA-256 hash from the server cert
received during the TLS handshake. Returns a lowercase 64-character hex string.

Workaround for a bug in MbedTLS.jl 2.x Julia bindings: `MbedTLS.get_peer_cert`
calls `CRT(ptr)` but the `CRT` struct only has a zero-arg constructor — the
`CRT(::Ptr{Cvoid})` form is missing. We bypass the broken wrapper by:
  1. Calling `mbedtls_ssl_get_peer_cert` via ccall to get the raw `mbedtls_x509_crt*`
  2. Reading the DER bytes directly from the struct's `.raw` field (offset-based)
  3. Writing DER to a temp file and delegating to `spki_hash()` for SPKI extraction

mbedtls_x509_crt struct layout (empirically verified on Linux x86_64, MbedTLS 2.x JLL):
  At offset 0:  mbedtls_x509_buf raw = { int tag; ...padding...; size_t len; uchar *p; }
  raw.len at byte offset 16 (size_t, 8 bytes)
  raw.p   at byte offset 24 (uchar*, 8 bytes)
These offsets were verified by matching raw_len against the known cert DER length.
"""
function _spki_hash_from_ssl_ctx(ctx::MbedTLS.SSLContext)::String
    # Step 1: Get raw peer cert pointer (borrowed — owned by ssl context, do NOT free)
    peer_ptr = ccall((:mbedtls_ssl_get_peer_cert, MbedTLS.libmbedtls),
                     Ptr{Cvoid}, (Ptr{Cvoid},), ctx.data)

    if peer_ptr == C_NULL
        error("JUI tcp: server did not send a certificate during TLS handshake")
    end

    # Step 2: Read DER bytes from mbedtls_x509_crt.raw field
    # Empirically verified offsets on Linux x86_64 MbedTLS 2.x JLL:
    #   raw.len at offset 16 (size_t)
    #   raw.p   at offset 24 (unsigned char*)
    raw_len = unsafe_load(Ptr{Csize_t}(peer_ptr + 16))
    raw_p   = unsafe_load(Ptr{Ptr{UInt8}}(peer_ptr + 24))

    if raw_p == C_NULL || raw_len == 0
        error("JUI tcp: peer cert raw DER buffer is empty — cannot compute SPKI hash")
    end

    der_bytes = unsafe_wrap(Vector{UInt8}, raw_p, raw_len; own=false) |> copy

    # Step 3: Write DER to temp file, convert to PEM, delegate to spki_hash()
    tmp_der = tempname() * ".crt.der"
    tmp_pem = tempname() * ".crt.pem"
    try
        write(tmp_der, der_bytes)
        ret = run(ignorestatus(`openssl x509 -inform DER -in $tmp_der -out $tmp_pem`))
        ret.exitcode == 0 ||
            error("JUI tcp: failed to convert peer cert DER→PEM (exit $(ret.exitcode))")
        return spki_hash(tmp_pem)
    finally
        rm(tmp_der, force=true)
        rm(tmp_pem, force=true)
    end
end
