# Copyright 2026 Super Serious Studios
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# ── protocol_test.jl ─────────────────────────────────────────────────────
# Phase 2a: Snapshot / diff / input message protocol tests.
# ─────────────────────────────────────────────────────────────────────────

# Helper: build a small buffer with some non-default cells
function _make_test_buf(cols=4, rows=2)
    rect = T.Rect(1, 1, cols, rows)
    buf  = T.Buffer(rect)
    buf.content[1] = T.Cell('A', T.Style(fg=T.ColorRGB(0xff, 0x00, 0x00), bold=true))
    buf.content[2] = T.Cell('B', T.Style(fg=T.Color256(196)))
    buf.content[3] = T.Cell('C', T.RESET)
    buf
end

@testset "Phase 2a: protocol — snapshot" begin

    # ── snapshot_message + apply_snapshot round-trip ─────────────────────
    @testset "snapshot round-trip" begin
        buf = _make_test_buf()
        s   = T.new_session("snap_app")
        s.last_buffer = buf   # set manually; diff_message does this normally

        msg = T.snapshot_message(s)
        @test msg isa String
        @test occursin("\"snapshot\"", msg)
        @test occursin(s.id.id, msg)

        restored = T.apply_snapshot(msg)
        @test restored isa T.Buffer
        @test restored.area == buf.area
        @test length(restored.content) == length(buf.content)
        for (i, (orig, got)) in enumerate(zip(buf.content, restored.content))
            @test orig == got
        end

        T.close_session!(s.id)
    end

    # ── snapshot_message errors when last_buffer is nothing ──────────────
    @testset "snapshot requires last_buffer" begin
        s = T.new_session("snap_nothing_app")
        @test_throws ErrorException T.snapshot_message(s)
        T.close_session!(s.id)
    end

end

@testset "Phase 2a: protocol — diff" begin

    # ── diff between identical buffers → empty cells list ────────────────
    @testset "diff identical buffers" begin
        buf = _make_test_buf()
        s   = T.new_session("diff_identical_app")
        s.last_buffer = buf

        msg = T.diff_message(s, buf)
        @test msg isa String
        @test occursin("\"diff\"", msg)
        @test occursin("\"cells\"", msg)
        @test occursin("[]", msg)   # no changed cells

        T.close_session!(s.id)
    end

    # ── diff between two different buffers produces correct cell list ─────
    @testset "diff different buffers" begin
        buf1 = _make_test_buf()
        buf2 = _make_test_buf()
        # Change cell [2]: B → Z
        new_cell = T.Cell('Z', T.Style(fg=T.ColorRGB(0x00, 0xff, 0x00)))
        buf2.content[2] = new_cell

        s = T.new_session("diff_changed_app")
        s.last_buffer = buf1

        msg = T.diff_message(s, buf2)
        @test msg isa String
        @test occursin("\"diff\"", msg)
        # The diff must mention 'Z' (changed cell) and not 'A' (unchanged)
        @test occursin("\"Z\"", msg)
        @test !occursin("\"A\"", msg)

        # last_buffer must be updated to buf2
        @test s.last_buffer === buf2

        T.close_session!(s.id)
    end

    # ── first diff_message (last_buffer nothing) returns snapshot ─────────
    @testset "diff with no last_buffer returns snapshot" begin
        buf = _make_test_buf()
        s   = T.new_session("diff_no_base_app")
        @test s.last_buffer === nothing

        msg = T.diff_message(s, buf)
        @test msg isa String
        @test occursin("\"snapshot\"", msg)
        # last_buffer must now be set
        @test s.last_buffer === buf

        T.close_session!(s.id)
    end

    # ── apply_diff! on snapshot + diff equals the target buffer ──────────
    @testset "apply_diff! reconstruction" begin
        buf_initial = _make_test_buf()
        s = T.new_session("reconstruction_app")

        # First call → snapshot
        snap_msg = T.diff_message(s, buf_initial)
        client_buf = T.apply_snapshot(snap_msg)
        @test client_buf.area == buf_initial.area

        # Modify one cell and emit a diff
        buf_next = _make_test_buf()
        buf_next.content[3] = T.Cell('X', T.Style(fg=T.Color256(21), italic=true))
        diff_msg = T.diff_message(s, buf_next)
        @test occursin("\"diff\"", diff_msg)

        # Apply diff to client buffer
        client_buf = T.apply_diff!(client_buf, diff_msg)

        for (i, (expected, got)) in enumerate(zip(buf_next.content, client_buf.content))
            @test expected == got
        end

        T.close_session!(s.id)
    end

    # ── apply_diff! handles a snapshot message (reconnect path) ──────────
    @testset "apply_diff! with snapshot message" begin
        buf = _make_test_buf()
        s   = T.new_session("reconnect_app")

        # Simulate reconnect: emit snapshot via diff_message (last_buffer=nothing)
        snap_msg = T.diff_message(s, buf)
        @test occursin("\"snapshot\"", snap_msg)

        # Client applies it through apply_diff! (not apply_snapshot)
        dummy_buf = T.Buffer(T.Rect(1, 1, 4, 2))
        result    = T.apply_diff!(dummy_buf, snap_msg)

        for (expected, got) in zip(buf.content, result.content)
            @test expected == got
        end

        T.close_session!(s.id)
    end

end

@testset "Phase 2a: protocol — input_message" begin

    # ── input_message wraps a KeyEvent correctly ──────────────────────────
    @testset "input KeyEvent" begin
        s   = T.new_session("input_key_app")
        evt = T.KeyEvent(:char, 'q', T.key_press)
        msg = T.input_message(s, evt)

        @test msg isa String
        @test occursin("\"input\"", msg)
        @test occursin(s.id.id, msg)
        @test occursin("\"event\"", msg)
        # The inner event JSON must be present (escaped inside the string value)
        @test occursin("key", msg)

        T.close_session!(s.id)
    end

    # ── input_message wraps a MouseEvent correctly ────────────────────────
    @testset "input MouseEvent" begin
        s   = T.new_session("input_mouse_app")
        evt = T.MouseEvent(10, 5, T.mouse_left, T.mouse_press, false, false, false)
        msg = T.input_message(s, evt)

        @test msg isa String
        @test occursin("\"input\"", msg)
        @test occursin(s.id.id, msg)
        @test occursin("mouse", msg)

        T.close_session!(s.id)
    end

    # ── input_message wraps a WireResizeEvent correctly ───────────────────
    @testset "input WireResizeEvent" begin
        s   = T.new_session("input_resize_app")
        evt = T.WireResizeEvent("resize", 120, 40)
        msg = T.input_message(s, evt)

        @test msg isa String
        @test occursin("\"input\"", msg)
        @test occursin(s.id.id, msg)
        @test occursin("resize", msg)

        T.close_session!(s.id)
    end

end
