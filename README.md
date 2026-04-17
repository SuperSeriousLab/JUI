# JUI — AI-First Julia TUI Framework

JUI is a world-class, AI-agent-debuggable TUI framework for Julia. It is a hard
fork of [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl) (MIT,
Kahli Burke), adopting its rendering substrate — cell-grid, layout solver, 30+
widgets, TaskQueue, TestBackend, animation, sixel/kitty graphics — as a stable
base on which JUI adds an AI-agent-first layer.

## What JUI Adds (Phases 2–4)

- **FRANK instrumentation**: optional weak dependency; all state changes emit
  structured debug events when FRANK is loaded. Zero overhead otherwise.
- **AppState serialization**: pure data struct, JSON-serializable, prerequisite
  for ET snapshots.
- **ET-Transport**: always-on Unix socket (local) + TCP (remote) in a single
  build, no mode switch.
- **Agent attach hooks**: agents subscribe to FRANK event stream, send synthetic
  input, drive deterministic TUI tests.

## Architecture

```
Application
  └── JUI framework
        ├── Cell-grid renderer, layout solver     [Tachikoma substrate, MIT]
        ├── Widget library (30+ widgets)          [Tachikoma substrate, MIT]
        ├── TaskQueue, TestBackend, animation     [Tachikoma substrate, MIT]
        └── AI-agent layer (Phase 2+):
              ├── FRANK (optional weak dep)       [JUI addition, Apache 2.0]
              ├── AppState serialization          [JUI addition, Apache 2.0]
              ├── ET-Transport                    [JUI addition, Apache 2.0]
              └── Agent attach hooks              [JUI addition, Apache 2.0]
```

## Fork History

JUI is a hard fork of Tachikoma.jl @ commit `2271069`, forked 2026-04-17.

Tachikoma.jl is MIT licensed (Kahli Burke). The MIT license text is in
`LICENSE-MIT`. Full attribution is in `NOTICE`. JUI additions are Apache 2.0
(see `LICENSE`). All files originating from Tachikoma.jl retain their original
MIT copyright headers.

## Quickstart

```julia
using JUI

# Implement the Model protocol
mutable struct MyModel <: JUI.Model
    quit::Bool
end

JUI.should_quit(m::MyModel) = m.quit
JUI.view(m::MyModel, frame::JUI.Frame) = JUI.render(JUI.Block(title="Hello JUI"), frame.area, frame.buf)
function JUI.update!(m::MyModel, evt::JUI.Event)
    evt isa JUI.KeyEvent && evt.char == 'q' && (m.quit = true)
end

JUI.app(MyModel(false))
```

## Development

```bash
git clone http://192.168.14.77:3000/eidos/JUI
cd JUI

# Test (Julia 1.10+)
julia --project=. -e "using Pkg; Pkg.test()"
```

## Roadmap

See `ROADMAP.yaml` for the machine-readable phase plan.

| Phase | Name | Status |
|-------|------|--------|
| 1 | Tachikoma.jl hard fork baseline | complete |
| 2a | AppState pure struct | not started |
| 2b | Renderer decoupled | not started |
| 2c | FRANK instrumentation + agent hooks | not started |
| 3 | ET-Transport | not started |
| 4 | eidos Julia registry publish | not started |

## License

JUI additions: Apache-2.0 (see `LICENSE`)

Tachikoma.jl substrate: MIT (see `LICENSE-MIT`)

Full attribution in `NOTICE`.
