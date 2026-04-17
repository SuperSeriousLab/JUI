# JUI — AI-First Julia TUI Framework

## Vision

JUI is a world-class, AI-agent-debuggable TUI framework for Julia.
FRANK is the companion debug protocol — like Chrome DevTools, but for terminal UIs.
Agents can inspect live component state, send synthetic input, and subscribe to events.

## Architecture

```
JUI (TUI framework)
  └── FRANK (optional debug protocol — attaches at runtime, zero overhead when absent)
```

## Status

Extracted from Igor monorepo. Pre-standalone — component API still Igor-coupled.
Roadmap: generalize primitives, make FRANK optional weak dep, publish to eidos registry.

## Rules

- Julia only.
- FRANK must remain optional (weak dep). JUI works without it.
- Components must be generic — no Igor/WIQ/IgorBrain concepts in core primitives.
- All state changes emit FRANK events when FRANK is loaded.
