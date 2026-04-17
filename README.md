# JUI — AI-First Julia TUI Framework

JUI is a world-class, AI-agent-debuggable TUI framework for Julia. Every state
change emits a structured debug event via the FRANK protocol so AI agents (and
humans) can inspect live component state, replay event sequences, and build
deterministic TUI tests without mocking the terminal.

## Architecture

```
Application
  └── App (render_screen!)
        ├── OutputComponent   — scrollable text panel
        ├── HistoryPanel      — past command log with confidence coloring
        ├── StatusBar         — mode / model / custom key-value indicators
        └── InputComponent    — prompt + input buffer
              ↕ stderr JSONL
           FRANK (debug protocol — optional weak dep in Phase 2)
```

## FRANK Protocol

FRANK (Forensic Runtime ANalytics Kit) emits structured events to stderr as
JSONL. Each event carries:

```json
{"ts": 1776260000, "source": "jui.input", "level": "STATE_TRANSITION",
 "payload": {"prompt": "app> ", "buffer": "ls", "cursor": 2},
 "transition": "render"}
```

Consumers can subscribe to the stderr stream to:
- Inspect live component state during development
- Drive automated TUI tests (send synthetic input, assert events)
- Record and replay interaction sessions

FRANK emits zero overhead when not loaded (Phase 2 goal — currently a hard dep).

## Quickstart

```julia
using JUI
using FRANK  # optional in Phase 2; currently required

app = App(model="qwen3-coder:30b", mode="normal")
run!(app)
```

### Programmatic use (no event loop)

```julia
app = App()
append_output!(app, "Hello from JUI")
update_status!(app; mode="debug", confidence=0.92)
line = handle_input!(app, "list files")
render_screen!(app)
```

## Components

| Component | Type | Purpose |
|-----------|------|---------|
| `InputComponent` | mutable struct | Prompt + input buffer + cursor |
| `OutputComponent` | mutable struct | Scrollable text output (tail mode) |
| `StatusBar` | mutable struct | Mode/model/WIQ/confidence indicators |
| `HistoryPanel` | mutable struct | Past command log with confidence coloring |

## Color Palette

JUI uses an amber-on-dark-grey aesthetic (ANSI 256-color). Named colors:
`:amber`, `:dark_amber`, `:bright_amber`, `:dark_grey`, `:mid_grey`,
`:light_grey`, `:orange` — plus standard `:red` / `:green` / `:yellow` for
confidence gating.

## Development

```bash
# Clone
git clone http://192.168.14.77:3000/eidos/JUI
cd JUI

# Test (Julia 1.10+)
julia --project=. -e "using Pkg; Pkg.test()"
```

## Roadmap

See `ROADMAP.yaml` for the machine-readable phase plan.

| Phase | Name | Status |
|-------|------|--------|
| 1 | Extracted from Igor monorepo | complete |
| 2 | Generalize primitives + optional FRANK | not started |
| 3 | Publish to eidos Julia registry | not started |

## Documentation

| Document | Purpose |
|----------|---------|
| `CLAUDE.md` | Claude Code instructions + design rules |
| `ROADMAP.yaml` | Machine-readable project phases |

## License

Apache-2.0
