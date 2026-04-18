# JUI Changelog

## v0.2.0 — 2026-04-17

### Fork + Server-Authoritative Architecture

- **Hard fork of Tachikoma.jl** (commit 2271069) as rendering substrate (MIT → Apache 2.0 additions). Full attribution in NOTICE + LICENSE-MIT.
- **Wire protocol**: serializable Buffer (cell grid) + InputEvents via JSON3. Buffer is a pure `Cell` grid — no widget serialization required.
- **Session registry**: `SessionID → server-side App + last_buffer`. Sessions are opaque UUIDs assigned at connect time.
- **Snapshot + cell-diff protocol**: server-authoritative, client is a dumb renderer. Snapshot on attach, diffs on subsequent frames.
- **FRANK integration** (optional weak dep via Julia 1.9+ package extension `JUIFRANKExt`): session lifecycle events emitted when FRANK is loaded — `session_create`, `session_close`, `input_received`, `diff_emitted`, `snapshot_sent`. Zero overhead when FRANK is absent.
- **Agent attach API**: `attach_agent(session_id, callback; mode=:observe|:interact)` via FRANK fanout subscription. `:interact` mode enables `inject_input` capability. `:observe` mode is read-only.
- **ET-Transport**: Unix socket (peer-UID gated via `SO_PEERCRED`/`getpeereid`) + TCP (TLS 1.3 + bearer token + SPKI TOFU). Single build — no mode switch, no compile flags.
- **Auth**: deny-by-default, constant-time token compare, peer UID check on Unix socket. `AuthGate` abstraction covers both transports.
- **`inject_input`**: capability-gated synthetic input injection for interactive agents. Gate checked at call site, not at attach.
- **`run_et!`**: convenience entry point — starts Unix socket server + connects local client. `run_tcp!` for remote TCP sessions.
- **Benchmark**: Unix transport 9.2 µs p50, TCP loopback 13.3 µs p50 (ratio 0.69x — Unix faster). See `bench/local_overhead.jl`.
- **Tests**: 5323 passing. Coverage includes: auth module (39 tests), Unix transport (7 tests), TCP+TLS (8 tests), session wiring (34 tests), FRANK extension (loaded + absent paths), Tachikoma-inherited widget suite.

### Registry

Published to eidos Julia registry: `http://192.168.14.77:3000/eidos/JuliaRegistry.git`

Install with:
```julia
using Pkg
Pkg.Registry.add(Pkg.RegistrySpec(url="http://192.168.14.77:3000/eidos/JuliaRegistry.git"))
Pkg.add("JUI")
```
