# JUI — AI-Agent-First Julia TUI Framework

JUI is a Julia TUI framework built for applications that want first-class
AI-agent introspection and remote terminal session persistence.

It is a hard fork of [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl)
(MIT, Kahli Burke). The full Tachikoma rendering substrate — cell-grid diff,
layout solver, 30+ widgets, constraint layouts, animations, Kitty/sixel
graphics, recording/export, TestBackend — is preserved. JUI adds:

- **FRANK** — optional DevTools-like protocol for agent introspection
- **ET-Transport** — always-on Unix socket + TCP+TLS, session persistence
  and reconnect over the wire (EternalTerminal / mosh-style)
- **Agent attach API** — subscribe to live session events; `:observe` or
  `:interact` (capability-gated synthetic input)
- **Deny-by-default auth** — Unix peer UID + TLS 1.3 + bearer token + SPKI
  TOFU pinning

Think of it as: a rich TUI framework that an AI agent can attach to,
inspect, drive, and debug — across a network boundary if needed.

## At a glance

- **5856 tests** passing (2 pre-existing env-dependent kitty graphics probes)
- **9.2 µs** p50 round-trip latency on Unix socket transport
  (0.69× vs raw TCP loopback — Unix socket is faster)
- **Zero overhead** when FRANK is absent (`@inline` no-op hooks, 0 bytes
  allocated on hot path)
- **Apache 2.0** (JUI additions) + MIT (Tachikoma substrate)

## Install and Test Yourself

### Prerequisites

1. **Julia 1.10+**
2. **`JULIA_PKG_USE_CLI_GIT=true`** — Julia's built-in LibGit2 does not
   invoke system git credential helpers, which makes `Pkg.Registry.add`
   hang on private Forgejo repos. Setting this env var routes Pkg through
   the `git` CLI, which uses the configured credential helper.
3. **Git credential helper** for `192.168.14.77` — standard on eidos dev
   boxes (`git-credential-eidos` via `eidos-keys`).

### Install from eidos Julia Registry

```bash
export JULIA_PKG_USE_CLI_GIT=true
```

```julia
using Pkg

# General registry supplies transitive deps (JSON3, StructTypes, etc.)
Pkg.Registry.add("General")

# eidos registry supplies JUI + FRANK
Pkg.Registry.add(Pkg.RegistrySpec(
    url = "http://192.168.14.77:3000/eidos/JuliaRegistry.git"
))

# FRANK is an optional weak dep — add it to enable diagnostics
Pkg.add(["JUI", "FRANK"])
```

### Verify your install

One command, three scenarios (FRANK-only, JUI+FRANK with extension
activation, JUI-solo with FRANK correctly absent):

```bash
git clone http://192.168.14.77:3000/eidos/JUI
cd JUI
./scripts/validate-registry-install.sh
```

Expected: `=== All scenarios passed ===` after ~3 minutes of first-time
precompilation. The script uses throwaway depots — it does not pollute
your existing Julia environment.

### Run the test suite (optional)

```bash
cd JUI
julia --project=. -e "using Pkg; Pkg.resolve(); Pkg.test()"
```

Expected: `5856 passed, 2 failed, 2 broken` where the 2 failures are
`_kitty_shm_probe!` tests that require a Kitty-protocol-capable terminal
(absent in typical CI/dev environments).

## Minimal app

```julia
using JUI

mutable struct Counter <: JUI.Model
    n::Int
    quit::Bool
end

JUI.should_quit(c::Counter) = c.quit

function JUI.view(c::Counter, frame::JUI.Frame)
    JUI.render(JUI.Block(title = "Counter — +/- / q"), frame.area, frame.buffer)
    JUI.set_string!(frame.buffer, 2, 2, "Count: $(c.n)")
end

function JUI.update!(c::Counter, evt::JUI.Event)
    if evt isa JUI.KeyEvent
        evt.char == '+' && (c.n += 1)
        evt.char == '-' && (c.n -= 1)
        evt.char == 'q' && (c.quit = true)
    end
end

JUI.app(Counter(0, false))
```

## Agent-attachable session

Run the same app over an ET-transport session that an AI agent can attach
to:

```julia
using JUI, FRANK

# Server side — automatically generates cert + token, opens Unix socket
session = run_et!(Counter(0, false))  # returns when app exits

# From another Julia process (or another host via TCP), an agent
# subscribes to the session event stream:
sid = attach_agent(session.id, function(event)
    @info "agent observed" event
end; mode = :observe)

# Interactive agent (capability-gated) can inject synthetic input:
sid2 = attach_agent(session.id, function(_) end; mode = :interact)
inject_input(sid2, KeyEvent('+'))

detach_agent!(sid)
detach_agent!(sid2)
```

For remote TCP sessions with TLS + bearer token + SPKI TOFU, see
[`docs/quickstart.md`](docs/quickstart.md#remote-tcp-session).

## Architecture

```
                         Application
                              │
                   ┌──────────┴──────────┐
                   │      JUI.app()      │
                   └──────────┬──────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
   Tachikoma substrate        │             JUI additions
        │                     │                     │
  ┌─────┴─────┐       ┌───────┴───────┐     ┌───────┴────────┐
  │ Cell grid │       │  TaskQueue    │     │ FRANK hooks    │
  │ Layout    │       │  Event loop   │     │  (weak dep)    │
  │ 30+ widgets│──────│               │─────│ AppState serde │
  │ Animation │       │  TestBackend  │     │ ET-Transport   │
  │ Kitty/sixel       │               │     │ Auth + SPKI    │
  └───────────┘       └───────────────┘     │ Agent attach   │
   MIT, preserved     MIT, preserved         └────────────────┘
                                               Apache 2.0, new
```

## Wire Protocol (ET-Transport)

Server-authoritative. Widgets live server-side only. Client = dumb cell
renderer + keystroke pipe.

- **Down (server → client)**: `snapshot_message` on attach, `diff_message`
  thereafter (cell-level diff of Buffer)
- **Up (client → server)**: `input_message` wrapping `KeyEvent`,
  `MouseEvent`, or `Resize`

All messages are newline-delimited JSON via `JSON3.StructType`. Full spec
in [`docs/wire-protocol.md`](docs/wire-protocol.md).

## Auth model (Phase 3)

- **Unix socket** — `chmod 0600` + `getpeereid`/`SO_PEERCRED` peer UID
  check. Socket at `$XDG_RUNTIME_DIR/jui/$SESSION.sock`.
- **TCP** — TLS 1.3 (self-signed ed25519, SPKI TOFU pin) + session-bound
  bearer token, one-shot handshake. Deny-by-default: server refuses to
  bind without cert+token ready.
- **Agent attach** — in-process only in Phase 3; capability model stubbed
  (`:observe` default, `:interact` gates `inject_input`).

Full spec and threat model in
[`docs/phase-3-auth-design.md`](docs/phase-3-auth-design.md).

## Performance

Measured on a single host (`bench/local_overhead.jl`, 1000 round-trips,
128-byte payload, Linux 6.8):

| Transport | p50 | p95 | p99 |
|-----------|-----|-----|-----|
| Unix socket (JUI) | 9.2 µs | 9.6 µs | 13.3 µs |
| TCP loopback (raw) | 13.3 µs | 13.7 µs | 18.0 µs |

Unix transport is faster than raw TCP on loopback (skips TCP stack
entirely). Well below the 2× overhead budget.

## Fork History + License

JUI is a **hard fork** of Tachikoma.jl @ `2271069`, forked 2026-04-17.

- **Tachikoma substrate**: MIT (Kahli Burke). See `LICENSE-MIT`. All
  files originating from Tachikoma retain their MIT copyright headers.
- **JUI additions** (FRANK hooks, ET-Transport, auth, wire protocol):
  Apache-2.0. See `LICENSE`.
- Full attribution in `NOTICE`.

## Project Status

| Phase | Name | Status |
|-------|------|--------|
| 1 | Tachikoma hard fork baseline | ✅ complete |
| 2a | Wire protocol (Buffer + InputEvent) | ✅ complete |
| 2b | Renderer decoupled (inherited from fork) | ✅ complete |
| 2c | FRANK optional weak dep + agent attach | ✅ complete |
| 3 | ET-Transport (Unix + TCP+TLS, auth) | ✅ complete |
| 4 | eidos Julia registry publish | ✅ complete |

`ROADMAP.yaml` is the machine-readable source of truth.

## Documentation

| Doc | Subject |
|-----|---------|
| [`docs/quickstart.md`](docs/quickstart.md) | Install + minimal app + FRANK + remote TCP |
| [`docs/wire-protocol.md`](docs/wire-protocol.md) | Snapshot/diff/input message shapes |
| [`docs/frank-integration.md`](docs/frank-integration.md) | FRANK event schema, subscriber API |
| [`docs/phase-3-auth-design.md`](docs/phase-3-auth-design.md) | Threat model + auth decisions |
| [`CHANGELOG.md`](CHANGELOG.md) | Full v0.2.0 feature list |
| [`NOTICE`](NOTICE) | Fork attribution + licensing |

## Related

- [FRANK](http://192.168.14.77:3000/eidos/FRANK) — the diagnostic protocol
  used by JUI's agent attach API. Standalone, separately versioned.
- [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl) — the upstream
  framework this fork is based on.

## Contributing

This repository lives on eidos Forgejo
(`http://192.168.14.77:3000/eidos/JUI`). Open issues or pull requests
there. The test suite is expected to pass (except the 2 env-dependent
kitty_shm probes) before any merge.
