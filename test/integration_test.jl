# Copyright 2026 eidos workspace
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# ── integration_test.jl ──────────────────────────────────────────────────
# Phase 2a: Round-trip integration test for the ET wire protocol.
#
# Tests the complete server-authoritative flow WITHOUT real sockets.
# Pure in-memory: session creation → snapshot → input_message → diff →
# apply_diff! → assert client buffer == server buffer.
#
# Widget choice: TextInput — handle_key! mutates .buffer visibly on every
# character keypress, so each keystroke produces a concrete diff.
# Dispatch is direct (handle_key! call, not via App struct) — focus is
# the wire/protocol round-trip, not the app event loop.
# ─────────────────────────────────────────────────────────────────────────

# ── Helper: render TextInput into a fresh Buffer ─────────────────────────

const _WIRE_COLS = 20
const _WIRE_ROWS = 1

function _server_render(widget::T.TextInput)::T.Buffer
    rect = T.Rect(1, 1, _WIRE_COLS, _WIRE_ROWS)
    buf  = T.Buffer(rect)
    T.render(widget, rect, buf)
    buf
end

# ── Helper: cells-equal check ────────────────────────────────────────────

function _bufs_equal(a::T.Buffer, b::T.Buffer)
    a.area == b.area || return false
    length(a.content) == length(b.content) || return false
    for (ca, cb) in zip(a.content, b.content)
        ca == cb || return false
    end
    true
end

# ═════════════════════════════════════════════════════════════════════════
# Testset 1 — single keypress round-trip
# ═════════════════════════════════════════════════════════════════════════

@testset "Phase 2a: integration — single keypress round-trip" begin
    # ── Server side ──
    widget  = T.TextInput(; text="", focused=true)
    session = T.new_session(widget)

    # Initial render: server puts first frame in session.last_buffer via diff_message
    buf_initial = _server_render(widget)
    snap_str    = T.diff_message(session, buf_initial)   # no last_buffer → snapshot
    @test occursin("\"snapshot\"", snap_str)

    # ── Client side: decode snapshot ──
    client_buf = T.apply_snapshot(snap_str)
    @test client_buf isa T.Buffer
    @test client_buf.area == buf_initial.area
    @test _bufs_equal(client_buf, buf_initial)

    # ── Client constructs a KeyEvent and wraps it in an input_message ──
    key_evt = T.KeyEvent(:char, 'h', T.key_press)
    input_str = T.input_message(session, key_evt)
    @test occursin("\"input\"", input_str)
    @test occursin(session.id.id, input_str)

    # ── Server decodes the input message and dispatches to widget ──
    # Verify envelope fields by string inspection (no direct JSON3 in test scope)
    @test occursin("\"type\"", input_str)
    @test occursin("\"event\"", input_str)

    # Decode the outer WireInputMessage via StructTypes-registered type
    wire_msg = T.JSON3.read(input_str, T.WireInputMessage)
    @test wire_msg.type       == "input"
    @test wire_msg.session_id == session.id.id

    decoded_evt = T.decode_input(wire_msg.event)
    @test decoded_evt isa T.KeyEvent
    @test decoded_evt.key  == :char
    @test decoded_evt.char == 'h'

    handled = T.handle_key!(widget, decoded_evt)
    @test handled

    # ── Server re-renders and emits a diff ──
    buf_after_h = _server_render(widget)
    diff_str    = T.diff_message(session, buf_after_h)
    @test occursin("\"diff\"", diff_str)

    # ── Client applies the diff ──
    client_buf = T.apply_diff!(client_buf, diff_str)

    # ── Assert: client buffer == server buffer ──
    @test _bufs_equal(client_buf, buf_after_h)

    # Widget should now contain "h"
    @test T.text(widget) == "h"

    T.close_session!(session.id)
end

# ═════════════════════════════════════════════════════════════════════════
# Testset 2 — multi-step: 3 keystrokes in sequence
# ═════════════════════════════════════════════════════════════════════════

@testset "Phase 2a: integration — multi-step (3 keystrokes)" begin
    widget  = T.TextInput(; text="", focused=true)
    session = T.new_session(widget)

    # Bootstrap: initial snapshot
    snap_str   = T.diff_message(session, _server_render(widget))
    client_buf = T.apply_snapshot(snap_str)

    # Send 'h', 'i', '!' in sequence
    for ch in ('h', 'i', '!')
        # Client → server: input_message
        key_evt   = T.KeyEvent(:char, ch, T.key_press)
        input_str = T.input_message(session, key_evt)

        # Server: decode + dispatch
        wire_msg    = T.JSON3.read(input_str, T.WireInputMessage)
        decoded_evt = T.decode_input(wire_msg.event)
        T.handle_key!(widget, decoded_evt)

        # Server: re-render + diff
        new_buf  = _server_render(widget)
        diff_str = T.diff_message(session, new_buf)

        # Client: apply diff
        client_buf = T.apply_diff!(client_buf, diff_str)

        # Assert: client tracks server after each step
        @test _bufs_equal(client_buf, new_buf)
    end

    @test T.text(widget) == "hi!"

    T.close_session!(session.id)
end

# ═════════════════════════════════════════════════════════════════════════
# Testset 3 — reconnect: discard client buffer, re-snapshot, resume diffs
# ═════════════════════════════════════════════════════════════════════════

@testset "Phase 2a: integration — reconnect via re-snapshot" begin
    widget  = T.TextInput(; text="ab", focused=true)
    session = T.new_session(widget)

    # Initial snapshot to prime session.last_buffer
    snap1_str  = T.diff_message(session, _server_render(widget))
    client_buf = T.apply_snapshot(snap1_str)
    @test T.text(widget) == "ab"

    # Send 'c' → server processes → diff → client applies
    T.handle_key!(widget, T.KeyEvent(:char, 'c', T.key_press))
    buf_abc  = _server_render(widget)
    diff_str = T.diff_message(session, buf_abc)
    client_buf = T.apply_diff!(client_buf, diff_str)
    @test _bufs_equal(client_buf, buf_abc)

    # ── Simulate reconnect: client discards its buffer ──
    # Client re-requests snapshot by "resetting" session.last_buffer to nothing.
    # In a real protocol the client sends a reconnect request; here we replicate
    # the server's response: force a fresh snapshot by clearing last_buffer.
    session.last_buffer = nothing

    snap2_str      = T.diff_message(session, _server_render(widget))
    @test occursin("\"snapshot\"", snap2_str)   # must get snapshot, not diff

    client_buf_new = T.apply_snapshot(snap2_str)
    @test _bufs_equal(client_buf_new, buf_abc)  # same server state

    # Resume: send 'd' and verify diffs continue correctly
    T.handle_key!(widget, T.KeyEvent(:char, 'd', T.key_press))
    buf_abcd = _server_render(widget)
    diff2    = T.diff_message(session, buf_abcd)
    @test occursin("\"diff\"", diff2)

    client_buf_new = T.apply_diff!(client_buf_new, diff2)
    @test _bufs_equal(client_buf_new, buf_abcd)
    @test T.text(widget) == "abcd"

    T.close_session!(session.id)
end

# ═════════════════════════════════════════════════════════════════════════
# Testset 4 — idempotency: applying the same diff twice
# ═════════════════════════════════════════════════════════════════════════

@testset "Phase 2a: integration — idempotency (double diff apply)" begin
    # Note: applying the same diff twice IS idempotent for cell-patch diffs
    # because each patch unconditionally overwrites. The client buffer ends
    # up in the same state as applying it once.
    widget  = T.TextInput(; text="", focused=true)
    session = T.new_session(widget)

    snap_str   = T.diff_message(session, _server_render(widget))
    client_buf = T.apply_snapshot(snap_str)

    # Type 'x'
    T.handle_key!(widget, T.KeyEvent(:char, 'x', T.key_press))
    buf_x    = _server_render(widget)
    diff_str = T.diff_message(session, buf_x)

    # Apply once
    client_buf = T.apply_diff!(client_buf, diff_str)
    @test _bufs_equal(client_buf, buf_x)

    # Apply same diff a second time — should still equal the target state
    client_buf = T.apply_diff!(client_buf, diff_str)
    @test _bufs_equal(client_buf, buf_x)

    T.close_session!(session.id)
end

# ═════════════════════════════════════════════════════════════════════════
# Testset 5 — empty diff: no state change → zero changed cells
# ═════════════════════════════════════════════════════════════════════════

@testset "Phase 2a: integration — empty diff (no state change)" begin
    widget  = T.TextInput(; text="hello", focused=true)
    session = T.new_session(widget)

    buf_hello  = _server_render(widget)
    snap_str   = T.diff_message(session, buf_hello)   # primes last_buffer
    client_buf = T.apply_snapshot(snap_str)

    # Server renders same state again (no keypress)
    buf_same = _server_render(widget)
    diff_str = T.diff_message(session, buf_same)

    # Diff message should carry an empty cells list
    @test occursin("\"diff\"", diff_str)
    @test occursin("[]", diff_str)   # zero changed cells

    # Client applies (no-op diff) — state unchanged
    client_buf = T.apply_diff!(client_buf, diff_str)
    @test _bufs_equal(client_buf, buf_hello)

    T.close_session!(session.id)
end
