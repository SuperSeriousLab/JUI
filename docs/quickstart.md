# JUI Quick-Start

JUI is an AI-agent-first Julia TUI framework. It is a hard fork of
Tachikoma.jl with server-authoritative ET-transport, FRANK diagnostics,
and an agent attach API built in.

## Install from eidos Registry

**Prerequisites:**
1. Git credential helper configured for `192.168.14.77` (standard on eidos dev boxes — see `~/.claude/skills/forgejo/SKILL.md`)
2. **Set `JULIA_PKG_USE_CLI_GIT=true`** — Julia's built-in LibGit2 does NOT use the system git credential helper. Setting this env var makes Pkg shell out to the `git` CLI, which uses the helper correctly.

```bash
# Add to ~/.bashrc or set per-invocation:
export JULIA_PKG_USE_CLI_GIT=true
```

```julia
using Pkg

# Add General registry first (for transitive deps: JSON3, StructTypes, etc.)
Pkg.Registry.add("General")

# Add the eidos registry
Pkg.Registry.add(Pkg.RegistrySpec(
    url = "http://192.168.14.77:3000/eidos/JuliaRegistry.git"
))

# Install — FRANK is an optional weak dep, add it to enable diagnostics
Pkg.add(["JUI", "FRANK"])
```

**Verified install flow** (clean depot, 2026-04-18): `JULIA_PKG_USE_CLI_GIT=true` + General registry + eidos registry → `Pkg.add(["JUI", "FRANK"])` → JUI v0.2.0 + FRANK v0.2.0 installed, JUIFRANKExt auto-activates. ~3 minutes on fresh install (precompilation of Tachikoma substrate).

**Without `JULIA_PKG_USE_CLI_GIT=true`**: Julia's LibGit2 hangs on credential prompts because Forgejo's `REQUIRE_SIGNIN_VIEW` gates even public repos. Workaround: pre-clone the registry and packages via `git` CLI first, then use `file://` URLs — see `scripts/validate-registry-install.sh`.

## Minimal App (Tachikoma-style, local)

```julia
using JUI

# Define your app state
mutable struct Counter
    n::Int
end

# Render function: write widgets into the Buffer
function render!(buf::JUI.Buffer, state::Counter)
    JUI.text!(buf, 1, 1, "Count: $(state.n)  (press q to quit, +/- to change)")
end

# Input handler: return updated state or nothing to quit
function handle(state::Counter, event::JUI.InputEvent)
    if JUI.is_key(event, '+')
        return Counter(state.n + 1)
    elseif JUI.is_key(event, '-')
        return Counter(state.n - 1)
    elseif JUI.is_key(event, 'q')
        return nothing  # signals quit
    end
    return state
end

# Run with ET-transport (Unix socket, local)
run_et!(Counter(0), render!, handle)
```

`run_et!` starts a Unix socket server and connects a local client
automatically. The session is addressable via `SessionID` for agent attach.

## Enable FRANK Diagnostics

If FRANK is loaded before `using JUI`, the `JUIFRANKExt` extension activates
automatically and emits session lifecycle events to stderr as JSONL:

```julia
using FRANK   # must come first
using JUI

# Now session events emit to stderr:
# {"type":"session_create","session_id":"...","ts":"..."}
# {"type":"input_received","session_id":"...","event":"key:+","ts":"..."}
# ...

run_et!(Counter(0), render!, handle)
```

Subscribe to events programmatically:

```julia
using FRANK

FRANK.subscribe!(function(event)
    # event is a Dict with :type, :session_id, :ts, etc.
    if event[:type] == "session_create"
        @info "New session" id=event[:session_id]
    end
end)
```

## Attach an Agent

Agents can observe or interact with a running session:

```julia
using JUI, FRANK

session_id = nothing  # captured from session_create event

FRANK.subscribe!(function(ev)
    if ev[:type] == "session_create"
        global session_id = ev[:session_id]
    end
end)

# Start app in background
t = @async run_et!(Counter(0), render!, handle)

# Wait for session to start
sleep(0.1)

# Attach agent in :observe mode (read-only)
attach_agent(session_id, function(ev)
    println("Agent sees: ", ev[:type])
end; mode = :observe)

# Attach agent in :interact mode (can inject input)
attach_agent(session_id, function(ev) end; mode = :interact)

# Inject synthetic input (requires :interact mode)
inject_input(session_id, JUI.KeyEvent('+'))
```

## Remote TCP Session

For remote access, use `run_tcp!` with TLS + bearer token auth:

```julia
using JUI

# Server side
cert, key = JUI.generate_self_signed()   # generates RSA-2048 cert
token = JUI.random_token()

server = run_tcp!(Counter(0), render!, handle;
    host = "0.0.0.0",
    port = 7878,
    cert = cert,
    key  = key,
    token = token
)

println("Token: ", token)
println("SPKI fingerprint: ", JUI.spki_fingerprint(cert))
```

```julia
# Client side — first connection pins the server cert (TOFU)
using JUI

JUI.connect_tcp("server.local", 7878;
    token = "the-bearer-token",
    spki_fingerprint = "sha256:AAAA..."   # from server output
)
```

## Transport Performance

Measured on the same machine (bench/local_overhead.jl):

| Transport | p50 latency |
|-----------|-------------|
| Unix socket | 9.2 µs |
| TCP loopback | 13.3 µs |

Use Unix socket for local sessions (default). Use TCP only for remote.

## Further Reading

- `docs/wire-protocol.md` — Buffer snapshot + cell-diff protocol spec
- `docs/frank-integration.md` — Full FRANK event schema + subscriber API
- `docs/phase-3-auth-design.md` — Auth model, TOFU pinning, peer UID gate
- `CHANGELOG.md` — Full v0.2.0 feature list
