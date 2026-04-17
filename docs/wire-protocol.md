# JUI Wire Protocol — Phase 2a Specification

## Purpose

JUI uses a **server-authoritative** architecture for remote terminal sessions.
The server owns the full widget tree and the App instance. The client is a
dumb cell renderer: it holds a flat `Buffer` (a grid of `Cell` values) and a
keystroke pipe. Nothing above the `Buffer` layer — no widget objects, no layout
state, no event handlers — ever crosses the wire.

This document specifies the **ET wire** (Embedded Terminal wire): the JSON
message shapes, session lifecycle, and reconnect semantics for Phase 2a.

Transport (TCP / Unix socket / WebSocket) and authentication are **not** part
of Phase 2a scope. They are deferred to Phase 3 (see *Non-goals*).

---

## Message Types

All messages are newline-delimited JSON objects. Each object carries a `type`
discriminator field and a `session_id` field (32 hex characters, 128-bit
opaque identifier).

### `snapshot` — full buffer (server → client)

Sent when a client first connects, or when the server cannot produce a
meaningful diff (e.g. after reconnect or buffer geometry change).

```json
{
  "type": "snapshot",
  "session_id": "a3f8c1d2e4b96701a3f8c1d2e4b96701",
  "buffer": {
    "area": { "x": 1, "y": 1, "width": 80, "height": 24 },
    "content": [
      {
        "char": "H",
        "style": {
          "fg": { "kind": "rgb", "code": 0, "r": 0,   "g": 255, "b": 128, "a": 255 },
          "bg": { "kind": "none","code": 0, "r": 0,   "g": 0,   "b": 0,   "a": 255 },
          "bold": false, "dim": false, "italic": false,
          "underline": false, "strikethrough": false, "hyperlink": ""
        },
        "suffix": ""
      }
    ]
  }
}
```

The `buffer.content` array is row-major, width × height entries. Index
`i` (0-based) maps to column `area.x + (i % area.width)`, row
`area.y + (i / area.width)`.

Color `kind` values: `"none"` (terminal default), `"256"` (xterm-256 palette,
`code` field), `"rgb"` (24-bit, `r`/`g`/`b` fields), `"rgba"` (32-bit, all
four fields).

### `diff` — sparse cell delta (server → client)

Sent on every rendered frame after the initial snapshot. Contains only the
cells that changed since the last snapshot or diff.

```json
{
  "type": "diff",
  "session_id": "a3f8c1d2e4b96701a3f8c1d2e4b96701",
  "cells": [
    {
      "x": 5,
      "y": 3,
      "cell": {
        "char": "X",
        "style": {
          "fg": { "kind": "256", "code": 196, "r": 0, "g": 0, "b": 0, "a": 255 },
          "bg": { "kind": "none","code": 0,   "r": 0, "g": 0, "b": 0, "a": 255 },
          "bold": true, "dim": false, "italic": false,
          "underline": false, "strikethrough": false, "hyperlink": ""
        },
        "suffix": ""
      }
    }
  ]
}
```

`x` and `y` are 1-based terminal coordinates matching the buffer's `area`
origin. An empty `cells` array is valid — it means nothing changed this frame.

### `input` — client keystroke / resize (client → server)

Sent upstream whenever the user presses a key, moves the mouse, or the
terminal geometry changes.

```json
{
  "type": "input",
  "session_id": "a3f8c1d2e4b96701a3f8c1d2e4b96701",
  "event": "{\"type\":\"key\",\"key\":\"char\",\"char\":97,\"action\":\"press\"}"
}
```

The `event` field is a JSON-escaped string containing the inner event payload
as produced by `encode_input`. Inner event `type` values: `"key"`, `"mouse"`,
`"resize"`. The outer envelope is routed by the multiplexer; the inner payload
is decoded by the server's input dispatcher without re-parsing the envelope.

---

## Session Lifecycle

```
Client                              Server
  │                                   │
  │── connect (send session_id?) ────►│ new_session(app) → SessionID
  │◄─ snapshot ───────────────────────│ diff_message(session, initial_buf)
  │                                   │   (returns snapshot because last_buffer=nothing)
  │◄─ diff ────────────────────────── │ diff_message(session, next_buf)
  │◄─ diff ────────────────────────── │ diff_message(session, next_buf)
  │── input (key/mouse/resize) ──────►│ decode via input_message / decode_input
  │◄─ diff ────────────────────────── │ (server re-renders after input)
  │                                   │
  │── disconnect ────────────────────►│ close_session!(id) → registry removed
```

1. **Connect**: The server calls `new_session(app)` and obtains a `Session`.
   The server renders the initial frame into a `Buffer` and stores it on the
   session (`session.last_buffer`). It then calls `diff_message(session, buf)`
   which, because `last_buffer` was `nothing`, produces a `snapshot` message.
   The server sends this snapshot to the client.

2. **Stream**: On every subsequent render tick the server calls
   `diff_message(session, new_buf)`. This compares against the stored
   `last_buffer`, produces a `diff` message (possibly with an empty `cells`
   list if nothing changed), updates `last_buffer`, and returns the JSON.

3. **Input**: The client wraps each event using `input_message(session, evt)`
   and sends it upstream. The server calls `decode_input` on the inner `event`
   field and dispatches to its App's `update!` handler. The server re-renders
   and sends the resulting diff.

4. **Disconnect**: The server calls `close_session!(id)`. The session is
   removed from the registry. The App instance is garbage-collected.

---

## Reconnect Semantics

If the client reconnects with a previously issued `session_id`:

1. The server looks up the session via `get_session(id)`.
2. If found, the server **resets** `session.last_buffer = nothing` so the next
   `diff_message` call will produce a fresh snapshot.
3. The client applies the snapshot with `apply_snapshot` to rebuild its buffer.
4. Streaming resumes normally from that point.

If the session has expired (removed from the registry), the server creates a
new session with `new_session(app)` and sends a new `session_id` to the client
via an application-level reconnect envelope (Phase 3 transport concern).

---

## Client-side Helpers

| Function | Direction | Description |
|---|---|---|
| `apply_snapshot(msg_str)` | client | Decode snapshot; returns a new `Buffer` |
| `apply_diff!(buf, msg_str)` | client | Patch `buf` in place; returns `buf` (or new Buffer if message is a snapshot) |

The client render loop:

```julia
buf = apply_snapshot(initial_msg)
render_all_cells(buf)

while connected
    msg = recv()
    buf = apply_diff!(buf, msg)   # no-op on empty diff
    render_changed_cells(buf)     # client decides how to minimize terminal writes
end
```

---

## Non-goals (Phase 2a)

- **Transport**: No TCP/Unix/WebSocket server is implemented here. Phase 3.
- **Authentication / TLS**: Not in scope. Phase 3. See Phase 3 auth stub in `src/`.
- **Multiplexing**: Multiple sessions per connection — Phase 3.
- **Compression**: `cells` array is uncompressed JSON. Phase 3 may add msgpack
  or zstd framing.
- **Widget state**: Widgets never appear in any wire message in any phase.
  The client holds only `Buffer` (cell grid). This is the core invariant of the
  server-authoritative architecture.
