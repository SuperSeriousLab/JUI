# Copyright 2026 Super Serious Studios
#
# MIT License
#
#
#
# ── protocol.jl ──────────────────────────────────────────────────────────
# Phase 2a: Snapshot / diff / input message helpers.
#
# Wire protocol overview (see docs/wire-protocol.md for full spec):
#
#   DOWN (server → client):
#     snapshot — full Buffer encoding; sent on connect or reconnect.
#     diff     — sparse list of changed cells; sent on each rendered frame.
#
#   UP (client → server):
#     input    — wrapped InputEvent (KeyEvent / MouseEvent / WireResizeEvent).
#
# All messages carry the session_id so a multiplexed transport can route
# them without out-of-band state. Widgets never appear in any message.
#
# Diff algorithm:
#   Iterate both buffer content vectors by linear index. For each position
#   where old[i] != new[i], compute (x, y) from the buffer area geometry
#   and record (x, y, new_cell). The client applies these patches in order.
#   If session.last_buffer is nothing (fresh session / reconnect), a full
#   snapshot is produced instead.
#
# After emitting a diff or snapshot, session.last_buffer is updated to the
# new buffer so the next call has the correct base.
# ─────────────────────────────────────────────────────────────────────────

# ── Wire message structs ──────────────────────────────────────────────────

struct WireSnapshotMessage
    type::String          # always "snapshot"
    session_id::String    # SessionID.id
    buffer::WireBuffer    # full buffer encoding (reuses wire.jl types)
end
StructTypes.StructType(::Type{WireSnapshotMessage}) = StructTypes.Struct()

struct WireDiffCell
    x::Int
    y::Int
    cell::WireCell
end
StructTypes.StructType(::Type{WireDiffCell}) = StructTypes.Struct()

struct WireDiffMessage
    type::String          # always "diff"
    session_id::String    # SessionID.id
    cells::Vector{WireDiffCell}
end
StructTypes.StructType(::Type{WireDiffMessage}) = StructTypes.Struct()

struct WireInputMessage
    type::String          # always "input"
    session_id::String    # SessionID.id
    event::String         # JSON-encoded InputEvent (via encode_input)
end
StructTypes.StructType(::Type{WireInputMessage}) = StructTypes.Struct()

# ── (x, y) from linear buffer index ──────────────────────────────────────

@inline function _buf_xy(buf::Buffer, i::Int)
    # i is 1-based. Linear index maps as:
    #   i = (y - area.y) * area.width + (x - area.x) + 1
    zi = i - 1   # 0-based
    w  = buf.area.width
    x  = buf.area.x + (zi % w)
    y  = buf.area.y + (zi ÷ w)
    (x, y)
end

# ── Server → client ───────────────────────────────────────────────────────

"""
    snapshot_message(session::Session) → String

Encode the current buffer as a full snapshot message. Use when a client
first connects or reconnects (no diff base is available or it would be
too expensive to diff against stale state).

Does NOT update `session.last_buffer`. Call `diff_message` (which upgrades
to a snapshot automatically when `last_buffer === nothing`) if you want
the last_buffer to be updated automatically.

Wire format:
    {"type":"snapshot","session_id":"<hex>","buffer":{...WireBuffer...}}
"""
function snapshot_message(session::Session)::String
    buf = session.last_buffer
    buf === nothing && error("snapshot_message: session.last_buffer is nothing; " *
                             "render a frame into the session before calling this, " *
                             "or use diff_message which handles this case.")
    msg = WireSnapshotMessage("snapshot", session.id.id, WireBuffer(buf))
    frank_snapshot_sent(session, buf)
    JSON3.write(msg)
end

"""
    diff_message(session::Session, new_buffer::Buffer) → String

Compute the cell-level diff between `session.last_buffer` and `new_buffer`.

- If `session.last_buffer` is `nothing`, returns a full **snapshot** message
  (same shape as `snapshot_message`) and updates `session.last_buffer`.
- Otherwise returns a **diff** message carrying only the changed cells.
- Updates `session.last_buffer` to `new_buffer` in both cases.
- Calls `touch!(session)` to update `last_activity`.

Wire formats:
    snapshot: {"type":"snapshot","session_id":"<hex>","buffer":{...}}
    diff:     {"type":"diff","session_id":"<hex>","cells":[{"x":…,"y":…,"cell":{…}},...]}
"""
function diff_message(session::Session, new_buffer::Buffer)::String
    touch!(session)
    sid = session.id.id

    if session.last_buffer === nothing
        # No base: ship a full snapshot
        session.last_buffer = new_buffer
        frank_snapshot_sent(session, new_buffer)
        msg = WireSnapshotMessage("snapshot", sid, WireBuffer(new_buffer))
        return JSON3.write(msg)
    end

    old_buf = session.last_buffer
    cells   = WireDiffCell[]

    n = min(length(old_buf.content), length(new_buffer.content))
    for i in 1:n
        @inbounds old_cell = old_buf.content[i]
        @inbounds new_cell = new_buffer.content[i]
        old_cell == new_cell && continue
        x, y = _buf_xy(new_buffer, i)
        push!(cells, WireDiffCell(x, y, WireCell(new_cell)))
    end

    session.last_buffer = new_buffer
    frank_diff_emitted(session, length(cells))
    msg = WireDiffMessage("diff", sid, cells)
    JSON3.write(msg)
end

# ── Client → server ───────────────────────────────────────────────────────

"""
    input_message(session::Session, evt) → String

Wrap an InputEvent (`KeyEvent`, `MouseEvent`, or `WireResizeEvent`) with the
session_id for upstream transport. The `event` field is the JSON produced by
`encode_input`, embedded as a string so the outer envelope can be routed by
a multiplexer without re-parsing the inner event payload.

Wire format:
    {"type":"input","session_id":"<hex>","event":"<JSON-escaped inner event>"}
"""
function input_message(session::Session, evt)::String
    frank_input_received(session, evt)
    msg = WireInputMessage("input", session.id.id, encode_input(evt))
    JSON3.write(msg)
end

# ── Client-side helpers ───────────────────────────────────────────────────

"""
    apply_snapshot(msg_str::String) → Buffer

Client-side: decode a snapshot message and return the full Buffer.
The client should replace its current render buffer with the result and
redraw all cells.
"""
function apply_snapshot(msg_str::String)::Buffer
    obj = JSON3.read(msg_str)
    get(obj, :type, nothing) == "snapshot" ||
        error("apply_snapshot: expected type=snapshot, got $(get(obj, :type, nothing))")
    wb = JSON3.read(msg_str, WireSnapshotMessage)
    from_wire_buffer(wb.buffer)
end

"""
    apply_diff!(buf::Buffer, msg_str::String) → Buffer

Client-side: decode a diff message and apply the cell patches to `buf`
in place. Returns `buf` for chaining.

If the message is actually a snapshot (server sent one instead of a diff,
e.g. after reconnect), `buf` is replaced entirely — the function returns
a new Buffer built from the snapshot; the caller should reassign the result.
"""
function apply_diff!(buf::Buffer, msg_str::String)::Buffer
    obj = JSON3.read(msg_str)
    t   = get(obj, :type, nothing)

    if t == "snapshot"
        return apply_snapshot(msg_str)
    end

    t == "diff" || error("apply_diff!: expected type=diff or snapshot, got $(repr(t))")
    dm = JSON3.read(msg_str, WireDiffMessage)

    for wdc in dm.cells
        in_bounds(buf, wdc.x, wdc.y) || continue
        idx = buf_index(buf, wdc.x, wdc.y)
        @inbounds buf.content[idx] = from_wire_cell(wdc.cell)
    end

    buf
end
