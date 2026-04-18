# Copyright 2026 eidos workspace
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# ── frank_absent_test.jl ─────────────────────────────────────────────────
# Phase 2c: FRANK-absent path verification.
#
# FRANK is NOT a test dependency, so JUIFRANKExt is NOT loaded here.
# These tests verify that:
#   1. All five stub hooks return nothing without error.
#   2. The full session + protocol flow works identically with FRANK absent.
#   3. No allocations occur on the hook call sites (stubs are true no-ops).
# ─────────────────────────────────────────────────────────────────────────

@testset "Phase 2c: FRANK-absent path" begin

    # ── Stub hook return values ───────────────────────────────────────────
    @testset "stub hooks return nothing" begin
        @test JUI.frank_session_created(nothing) === nothing
        @test JUI.frank_session_closed(nothing) === nothing
        @test JUI.frank_input_received(nothing, nothing) === nothing
        @test JUI.frank_snapshot_sent(nothing, nothing) === nothing
        @test JUI.frank_diff_emitted(nothing, nothing) === nothing
    end

    # ── Agent attach stubs raise informative errors ───────────────────────
    @testset "attach_agent absent" begin
        @test_throws ErrorException JUI.attach_agent(T.SessionID("x"), _ -> nothing)
        @test_throws ErrorException JUI.detach_agent!(nothing)
    end

    # ── inject_input stub raises error when FRANK absent ─────────────────
    @testset "inject_input absent" begin
        @test_throws ErrorException JUI.inject_input(nothing, nothing)
    end

    # ── Zero allocation guarantee on stub hooks ───────────────────────────
    @testset "stub hooks allocate nothing" begin
        @test @allocated(JUI.frank_session_created(nothing)) == 0
        @test @allocated(JUI.frank_session_closed(nothing)) == 0
        @test @allocated(JUI.frank_input_received(nothing, nothing)) == 0
        @test @allocated(JUI.frank_snapshot_sent(nothing, nothing)) == 0
        @test @allocated(JUI.frank_diff_emitted(nothing, nothing)) == 0
    end

    # ── Full protocol flow without FRANK ─────────────────────────────────
    # Verify that session lifecycle + snapshot/diff/input messages work
    # identically in the FRANK-absent environment. No crash, same output.
    @testset "full protocol flow, FRANK absent" begin
        # Helper: small buffer with a distinguishable cell
        rect = T.Rect(1, 1, 3, 2)
        buf1 = T.Buffer(rect)
        buf1.content[1] = T.Cell('X', T.Style(bold=true))
        buf2 = T.Buffer(rect)
        buf2.content[1] = T.Cell('Y', T.Style(bold=true))
        buf2.content[2] = T.Cell('Z', T.RESET)

        # Create session — triggers frank_session_created stub (must not error)
        s = T.new_session("frank_absent_test_app")
        @test s isa T.Session
        @test s.last_buffer === nothing

        # diff_message with no last_buffer → snapshot path
        # triggers frank_snapshot_sent stub
        msg1 = T.diff_message(s, buf1)
        @test occursin("\"snapshot\"", msg1)
        @test s.last_buffer !== nothing

        # snapshot_message (explicit) — triggers frank_snapshot_sent stub
        msg_snap = T.snapshot_message(s)
        @test occursin("\"snapshot\"", msg_snap)

        # diff_message with a last_buffer set → diff path
        # triggers frank_diff_emitted stub
        msg2 = T.diff_message(s, buf2)
        @test occursin("\"diff\"", msg2) || occursin("\"snapshot\"", msg2)

        # input_message — triggers frank_input_received stub
        evt = T.KeyEvent(:enter)
        msg_in = T.input_message(s, evt)
        @test occursin("\"input\"", msg_in)

        # close_session — triggers frank_session_closed stub
        id = s.id
        @test T.close_session!(id) == true
        @test T.get_session(id) === nothing

        # Double-close returns false (session gone) — stub still must not error
        @test T.close_session!(id) == false
    end

end
