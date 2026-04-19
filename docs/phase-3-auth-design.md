# JUI Phase 3 Auth Design

## 1. Summary

JUI Phase 3 adopts a **two-tier auth model**: Unix socket (local) uses OS-level peer credentials with zero user-visible config; TCP (remote) requires a bearer token over TLS with SPKI pinning on first use. FRANK attach stays in-process only for Phase 3 — remote agent attach is explicitly deferred. Auth is **deny-by-default**, hardcoded to one recommended path (no pluggable strategies yet), and lives in a dedicated `src/auth/` module the Transport layer calls. No escape hatch for disabling auth on TCP; local socket is inherently owner-gated so needs no toggle.

## 2. A. Unix Socket Auth

1. **Both.** `chmod 0600` is necessary but insufficient — it protects against casual access, not against a file being pre-created or replaced. Also call `getpeereid(2)` (via `ccall`) after `accept()` and reject if `peer_uid != getuid()`. `SO_PEERCRED` is Linux-specific; `getpeereid` is portable across Linux + macOS/BSD. Use `getpeereid`.
2. **`$XDG_RUNTIME_DIR/jui/$SESSION.sock`** when `XDG_RUNTIME_DIR` is set (tmpfs, mode 0700, auto-cleaned on logout). Fall back to `/tmp/jui-$UID/$SESSION.sock` with the parent dir created mode 0700 and owner-checked before use. Never use bare `/tmp/jui-$SESSION.sock` — path is predictable and squatable.
3. **TOCTOU:** create the parent dir with `mkdir(path, mode=0o700)` and `lstat` it; if it exists, verify `st_uid == getuid() && st_mode == 0o700 && !is_symlink`. Bind the socket inside with `O_EXCL`-equivalent semantics: `unlink` stale socket only after the owner check passes. Set `umask(0o077)` around socket creation. Never follow symlinks.
4. **Peer UID is enough for Phase 3.** Namespace/cgroup checks add complexity without closing a real threat on the target deployment (developer workstation, single-tenant LXC). Flag as Phase 4 if JUI gets deployed inside shared container hosts.

## 3. B. TCP Auth

1. **Token source:** generated at server start, written to `$XDG_RUNTIME_DIR/jui/$SESSION.token` (mode 0600) AND printed to stderr as a one-line FRANK event (`{event:"jui.token", token:"..."}`). Client reads either the file (local ops) or is given the token out-of-band (remote). No env var — env leaks via `/proc/$pid/environ` on multi-user boxes.
2. **TLS + bearer.** Raw TCP + bearer is rejected (token sniffable). mTLS is too operationally heavy for Phase 3 (cert distribution becomes a UX problem). TLS server cert + bearer token is the sweet spot.
3. **Self-signed with SPKI pinning (TOFU).** Server generates an ed25519 keypair at first run, stored at `$XDG_CONFIG_HOME/jui/server.key` (0600) + `server.crt`. Client on first connect records the SPKI hash to `~/.config/jui/known_servers`; subsequent connects verify. Rotation = delete pin, manual re-TOFU. Full CA is out of scope.
4. **Replay protection:** TLS handles stream integrity and replay at the record layer — no app-level nonces needed. Token is session-bound: one token per server lifetime, presented once at handshake. Stream hijack is prevented by TLS, not by re-authing every message.
5. **Auth is one-time at connect.** First message over the TLS stream is `{type:"auth", token:"..."}`; server replies `{type:"auth_ok", session:"..."}` or closes. Subsequent JSON3 messages are unwrapped. No per-message envelope — wasteful and adds parsing surface.

## 4. C. FRANK Attach Auth

1. **In-process only for Phase 3.** `attach_agent(session_id, callback)` stays a Julia function call inside the server process. OS process isolation is the gate.
2. **Remote agent attach = Phase 4.** Explicitly out of scope. Trying to design it now conflates two different trust models (code-in-process vs code-over-wire) and will produce a bad abstraction.
3. N/A (deferred).
4. **Capability model stubbed, not enforced.** `attach_agent(session_id, callback; mode=:observe)` where `mode ∈ (:observe, :interact)`. Phase 3 stores the mode on the subscription and gates `inject_input()` on `mode == :interact`. Enforcement is trivial; designing it now avoids a breaking API change in Phase 4.

## 5. D. Token Lifecycle

1. **128-bit random, base64url-encoded, opaque.** `rand(RandomDevice(), UInt8, 16)` → base64url. No JWT — no claims to carry, no third-party validator.
2. **Client-side storage:** `~/.config/jui/tokens/$server_spki_hash` (0600). Keyed by server identity so multiple JUI servers don't collide. No keyring dependency (portability tax).
3. **Expiry: session-bound.** Token dies when server exits. No wall-clock TTL in Phase 3 — adds rotation complexity without threat reduction for session-length connections. Manual revoke = kill server.
4. **Rotation: on server restart, always.** No in-session rotation Phase 3.

## 6. E. Denied-Attach Behavior

1. **Unix peer UID mismatch:** log FRANK event (`{event:"auth.reject", reason:"peer_uid", uid:N}`), close socket immediately, no error message to peer (no oracle). Server keeps listening.
2. **TCP auth fail:** close connection, FRANK event. **No rate limiting in Phase 3** (explicit non-goal per scope). Flag for Phase 4: simple exponential backoff per source IP.
3. **FRANK attach fail (in-process):** throw `AuthError` to caller. No side channel, no FRANK event (the caller is the agent, it already knows).

## 7. F. Architecture

1. **Hardcoded one path.** Pluggable auth is premature abstraction — we have one threat model and one deployment shape. Revisit if/when a second auth scheme ships.
2. **Deny by default.** Local socket: peer-UID-gated always. TCP: token-gated always, no `--insecure` flag. Server refuses to bind TCP without a generated token+cert.
3. **Dedicated `src/auth/` module.** Transport calls into it. Not in `session.jl` (session is a data object, not a security boundary). Not inside transport (auth policy must be testable in isolation).
4. **No disable flag.** Testing uses the real auth with a test-generated token read from the token file — this is what production does. If a test truly needs to bypass, it mocks the `AuthGate` trait at the module boundary, not via a runtime flag. Runtime flags get shipped to prod.

## 8. File Layout

```
src/auth/
  auth.jl            # module entry, AuthGate interface
  peer.jl            # getpeereid ccall + UID check
  token.jl           # generate, load, compare (constant-time)
  tls.jl             # self-signed cert gen, SPKI pin store
  paths.jl           # XDG-aware path resolution + mode checks
src/transport/
  unix.jl            # calls auth/peer.jl on accept
  tcp.jl             # calls auth/tls.jl + auth/token.jl on accept
test/auth/           # peer mocking, token roundtrip, TLS handshake
```

## 9. Phase 3 MUST Implement

- `getpeereid` ccall + UID reject on Unix socket accept
- XDG-aware socket path with 0700 parent + 0600 socket + symlink checks
- TLS 1.3 server with auto-generated ed25519 cert, SPKI pin file on client
- Bearer token: generate, write to 0600 file, emit FRANK event, verify constant-time
- One-shot auth handshake (`{type:"auth"}`) before any Buffer/InputEvent traffic
- `attach_agent` mode parameter (`:observe` | `:interact`) with `inject_input` gated
- FRANK `auth.reject` / `auth.ok` events
- Deny-by-default: server will not bind TCP without cert+token ready

## 10. Phase 3 MAY Defer

- **Rate limiting / fail2ban:** explicit non-goal.
- **mTLS:** SPKI-pinned self-signed TLS closes the MITM threat; client certs add distribution pain for marginal gain. Phase 4 if multi-user remote attach ships.
- **Remote FRANK attach:** deferred — different trust model, design separately.
- **Token rotation mid-session:** session-bound token is sufficient given TLS.
- **Keyring integration:** file-based storage is adequate and portable.
- **Namespace/cgroup peer checks:** not a threat on target deployment.
- **Wall-clock TTL on tokens:** session-bound suffices.

## 11. Flagged Blind Spots

- **`ccall(:getpeereid)` portability:** Linux glibc exports it; musl and some BSDs require `SO_PEERCRED`/`LOCAL_PEERCRED` fallback. Test on Alpine LXC before shipping.
- **FRANK event stream leaks pre-auth:** if FRANK emits `jui.token` on stderr and stderr is piped to a shared log aggregator, tokens leak. Document: token event goes to stderr only, never to persistent logs; operators who forward stderr must scrub.
- **Session resume after disconnect:** the ET-style session persistence means a reconnecting client with a valid token resumes state. If the token file leaks post-session, an attacker resumes. Mitigation: token file lives in `$XDG_RUNTIME_DIR` (tmpfs, gone on logout).
- **Julia `SecureString` absence:** tokens will sit in Julia `String` objects subject to GC timing. Real memory-scrubbing needs `Base.unsafe_wrap` + manual zero — worth a helper even if imperfect.
- **TLS cert CN/SAN:** self-signed certs need a SAN that matches how the client dials (IP vs hostname). Pin-based TOFU sidesteps hostname verification but the cert still needs *some* SAN or TLS libraries reject it. Spec: SAN = `DNS:jui.local, IP:0.0.0.0` and verification disabled in favor of SPKI pin.
- **Clock skew is irrelevant here** (no JWT, no TTL) — noting for posterity so Phase 4 doesn't forget to reconsider when adding expiry.
- **Signal handling on token file cleanup:** SIGKILL leaves stale token file in `$XDG_RUNTIME_DIR`. Tmpfs cleanup on logout handles it; document the residue window.
