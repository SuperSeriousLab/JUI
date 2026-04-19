# JUI — AI-First Julia TUI Framework

## Vision

JUI is a world-class, AI-agent-debuggable TUI framework for Julia.
It is a hard fork of Tachikoma.jl (MIT, Kahli Burke) adopted as the rendering
substrate. JUI adopts Tachikoma's cell-grid, layout solver, widgets, TaskQueue,
and TestBackend, and adds an AI-agent-first layer on top.

FRANK is the companion debug protocol — like Chrome DevTools, but for terminal UIs.
Agents can inspect live component state, send synthetic input, and subscribe to events.

## Origin

Hard fork of Tachikoma.jl @ commit 2271069, forked 2026-04-17.
Source: https://github.com/kahliburke/Tachikoma.jl

Tachikoma files are MIT licensed (see LICENSE-MIT). JUI additions are Apache 2.0.
Full attribution in NOTICE.

## Architecture

```
JUI (TUI framework — Tachikoma substrate)
  ├── Cell-grid renderer, layout solver, widget library   [from Tachikoma, MIT]
  ├── TaskQueue, TestBackend, animation, sixel graphics   [from Tachikoma, MIT]
  └── AI-agent layer (Phase 2+):
        ├── FRANK instrumentation (optional weak dep)     [JUI addition, Apache 2.0]
        ├── AppState serialization wrapper                [JUI addition, Apache 2.0]
        ├── ET-Transport (Unix socket + TCP)              [JUI addition, Apache 2.0]
        └── Agent attach hooks                            [JUI addition, Apache 2.0]
```

## Status

Phase 1 complete: Tachikoma.jl hard fork adopted as JUI v0.2.0.
Phase 2+ adds AI-agent-first layer on top of Tachikoma substrate.

## Rules

- Julia only.
- FRANK must remain optional (weak dep). JUI works without it.
- Components must be generic — no Igor/WIQ/IgorBrain concepts in core primitives.
- All state changes emit FRANK events when FRANK is loaded.
- Tachikoma-originated files retain their MIT copyright headers — do not remove them.
- New JUI files carry Apache 2.0 headers.
- Do not add FRANK as a hard dependency — it must remain a weak dep (Phase 2c target).
