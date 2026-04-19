# FRANK Integration Guide

## Overview

FRANK (debug protocol) is an optional diagnostic layer for JUI. When loaded,
it emits structured JSONL events on stderr — one line per event — covering
session lifecycle, input dispatch, snapshots, and diffs. AI agents can subscribe
to this stream at runtime via `attach_agent` to observe session state without
instrumenting application code.

FRANK is a **development and debugging tool**. JUI works identically when
FRANK is absent — no crash, no degraded functionality, zero overhead in
the hot render path. Load it only when you need agent observability or
are debugging session behaviour.

---

## Enable FRANK in your JUI app

**Step 1 — Add FRANK as a dependency.**

```toml
# Project.toml
[weakdeps]
FRANK = "d4e5f6a7-b8c9-4d0e-a1f2-b3c4d5e6f7a8"

[extensions]
JUIFRANKExt = "FRANK"
```

If FRANK is not in a registered Julia registry yet, add it as a path or
direct-URL dependency:

```toml
[sources]
FRANK = {path = "../FRANK"}
```

**Step 2 — Load FRANK before JUI at the call site.**

```julia
using FRANK  # must come before `using JUI` to trigger extension load
using JUI
```

**Step 3 — Verify the extension loaded.**

```julia
julia> using InteractiveUtils; InteractiveUtils.varinfo(JUI)
# JUIFRANKExt should appear in the list
```

Or check stderr at startup — JUI emits a `jui.session / created` FRANK event
the moment the first session is registered, so any FRANK sink will confirm
the wiring is live.

---

## Subscribe to session events (agent attach)

```julia
using JUI
using FRANK  # required to activate JUIFRANKExt

app = MyApp()          # your JUI application struct
session = new_session(app)

# Attach an agent callback — fires on every FRANK event for this session.
# Returns a subscriber ID you use to detach later.
sid = attach_agent(session.id) do event
    comp   = event["component"]
    trans  = event["transition"]
    state  = event["state"]
    println("event: $comp / $trans  session=$(state["session_id"])")
end

# Run your application normally.
run!(session)

# Detach when done. Safe to call even if session is already closed.
detach_agent!(sid)
close_session!(session.id)
```

`attach_agent` is non-blocking. The callback runs synchronously in the FRANK
emission path — keep it fast. If you need async processing, push into a
`Channel` inside the callback and drain it on a separate task.

---

## Event reference

All events use the FRANK v0.1 envelope (`frank_v=1`, `event_type=STATE_TRANSITION`).
The `state` object always contains at least `session_id`.

| Component | Transition | State fields | Description |
|---|---|---|---|
| `jui.session` | `created` | `session_id`, `created_at` | New session registered |
| `jui.session` | `closed` | `session_id` | Session torn down |
| `jui.input` | `input_received` | `session_id`, `event_type` | Client input dispatched (key/mouse/resize) |
| `jui.snapshot` | `snapshot_sent` | `session_id`, `cell_count` | Full Buffer snapshot sent on agent attach |
| `jui.diff` | `diff_emitted` | `session_id`, `cell_count` | Cell-diff batch sent after render cycle |

`event_type` in `jui.input.input_received` is the Julia type name of the input
event — one of `"KeyEvent"`, `"MouseEvent"`, or `"ResizeEvent"`.

`cell_count` in snapshot/diff is the number of cells: `rows × cols` for a
full snapshot, or the number of changed cells for a diff batch.

Raw JSONL example (pretty-printed):

```json
{
  "frank_v": 1,
  "ts": "2026-04-17T09:15:42.301Z",
  "component": "jui.session",
  "event_type": "STATE_TRANSITION",
  "transition": "created",
  "state": {
    "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "created_at": "2026-04-17T09:15:42.299Z"
  }
}
```

---

## Production vs development

FRANK is not a production dependency. In production:

- Do **not** load FRANK (`using FRANK` absent from your entry point).
- JUI extension `JUIFRANKExt` will not activate — zero runtime cost.
- All session, input, snapshot, and diff paths behave identically.
- No FRANK JSONL appears on stderr, so log pipelines are unaffected.

In development / CI:

- Load FRANK before JUI for full observability.
- Pipe stderr to a file or a structured log sink to capture event streams.
- Use `attach_agent` in integration tests to assert lifecycle events without
  relying on timing or stdout scraping.

The weak dependency model (`[weakdeps]` + `[extensions]`) enforces this
separation at the package level — FRANK never becomes a transitive runtime
dependency of downstream JUI consumers.

---

## See also

- FRANK event envelope schema: `spec/frank-v0.1.json` (in the [FRANK repo](https://github.com/SuperSeriousLab/FRANK))
- JUI-specific event type schema: `spec/jui-events-v0.1.json` (in the [FRANK repo](https://github.com/SuperSeriousLab/FRANK))
- Wire protocol design: `JUI/docs/wire-protocol.md`
