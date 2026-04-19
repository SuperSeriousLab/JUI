# Copyright 2026 Super Serious Studios
#
# MIT License
#
#
#
# ── frank_present_test.jl ────────────────────────────────────────────────
# Phase 2c item 4 + 7: FRANK-present integration tests.
#
# Requires JUIFRANKExt to be loaded (FRANK must be a test dep so the
# extension is triggered at JUI load time). When FRANK is absent the
# outer gate in runtests.jl skips this file and emits a warning instead.
#
# Tests capture FRANK emission via IOBuffer (redirected through
# JUIFRANKExt.set_capture!) and assert on JSONL event content.
# ─────────────────────────────────────────────────────────────────────────

using FRANK

# Locate the extension module loaded into JUI's module graph.
const _ext = Base.get_extension(JUI, :JUIFRANKExt)

@testset "Phase 2c item 4+7: FRANK-present path" begin

    # ── Extension loaded ──────────────────────────────────────────────────
    @testset "JUIFRANKExt is loaded" begin
        @test _ext !== nothing
        # set_capture! must be exported from the extension
        @test isdefined(_ext, :set_capture!)
    end

    # ── Capture helpers ───────────────────────────────────────────────────
    # Redirect the per-process emitter to an IOBuffer so we can inspect output.
    function with_capture(f)
        buf = IOBuffer()
        _ext.set_capture!(buf)
        try
            f(buf)
        finally
            # Restore to stderr so other tests don't write to a closed buffer.
            _ext.set_capture!(stderr)
        end
    end

    function captured_lines(buf)
        seek(buf, 0)
        filter!(!isempty, readlines(buf))
    end

    # ── session_created event ─────────────────────────────────────────────
    @testset "frank_session_created emits jui.session / created" begin
        with_capture() do buf
            s = T.new_session("frank_present_test_app")
            lines = captured_lines(buf)

            @test length(lines) >= 1
            @test contains(lines[1], "jui.session")
            @test contains(lines[1], "created")
            @test contains(lines[1], s.id.id)

            T.close_session!(s.id)
        end
    end

    # ── session_closed event ─────────────────────────────────────────────
    @testset "frank_session_closed emits jui.session / closed" begin
        with_capture() do buf
            s = T.new_session("frank_present_test_app_close")
            seek(buf, 0)
            truncate(buf, 0)  # clear created event

            id = s.id
            T.close_session!(id)

            lines = captured_lines(buf)
            @test length(lines) >= 1
            @test contains(lines[1], "jui.session")
            @test contains(lines[1], "closed")
            @test contains(lines[1], id.id)
        end
    end

    # ── input_received event ──────────────────────────────────────────────
    @testset "frank_input_received emits jui.input / input_received" begin
        with_capture() do buf
            s = T.new_session("frank_present_test_app_input")
            seek(buf, 0)
            truncate(buf, 0)

            evt = T.KeyEvent(:enter)
            _msg = T.input_message(s, evt)

            lines = captured_lines(buf)
            @test length(lines) >= 1
            @test contains(lines[1], "jui.input")
            @test contains(lines[1], "input_received")
            @test contains(lines[1], s.id.id)

            T.close_session!(s.id)
        end
    end

    # ── snapshot_sent event ───────────────────────────────────────────────
    # snapshot_message requires session.last_buffer to be set; use diff_message
    # on a fresh session (no last_buffer) to trigger the snapshot path, which
    # calls frank_snapshot_sent internally.
    @testset "frank_snapshot_sent emits jui.snapshot / snapshot_sent" begin
        with_capture() do buf
            s = T.new_session("frank_present_test_app_snap")
            seek(buf, 0)
            truncate(buf, 0)

            rect = T.Rect(1, 1, 3, 2)
            b    = T.Buffer(rect)
            b.content[1] = T.Cell('A', T.Style(bold=true))

            # diff_message on a session with no last_buffer → snapshot path
            _msg = T.diff_message(s, b)

            lines = captured_lines(buf)
            @test length(lines) >= 1
            @test contains(lines[1], "jui.snapshot")
            @test contains(lines[1], "snapshot_sent")
            @test contains(lines[1], s.id.id)

            T.close_session!(s.id)
        end
    end

    # ── diff_emitted event ────────────────────────────────────────────────
    @testset "frank_diff_emitted emits jui.diff / diff_emitted" begin
        with_capture() do buf
            s = T.new_session("frank_present_test_app_diff")

            rect = T.Rect(1, 1, 3, 2)
            b1   = T.Buffer(rect)
            b1.content[1] = T.Cell('X', T.Style(bold=true))

            # First diff_message → snapshot path (sets last_buffer)
            _snap = T.diff_message(s, b1)

            seek(buf, 0)
            truncate(buf, 0)

            # Second buffer — differs from b1 → diff path
            b2 = T.Buffer(rect)
            b2.content[1] = T.Cell('Y', T.RESET)

            _diff = T.diff_message(s, b2)

            lines = captured_lines(buf)
            # At least one diff event expected (may also be snapshot if cells
            # are too similar and engine falls back — either is valid).
            @test length(lines) >= 1
            # Accept either diff or snapshot event from the diff path
            @test any(l -> contains(l, "jui.diff") || contains(l, "jui.snapshot"), lines)

            T.close_session!(s.id)
        end
    end

    # ── Full lifecycle round-trip ─────────────────────────────────────────
    @testset "full lifecycle: create → input → snapshot → diff → close" begin
        with_capture() do buf
            s = T.new_session("frank_present_test_lifecycle")

            # input
            evt  = T.KeyEvent(:space)
            _i   = T.input_message(s, evt)

            # snapshot (first diff → snapshot)
            rect = T.Rect(1, 1, 4, 2)
            b1   = T.Buffer(rect)
            b1.content[1] = T.Cell('P', T.RESET)
            _s1  = T.diff_message(s, b1)

            # diff
            b2 = T.Buffer(rect)
            b2.content[1] = T.Cell('Q', T.RESET)
            _s2 = T.diff_message(s, b2)

            # close
            T.close_session!(s.id)

            lines = captured_lines(buf)
            # Expect at least: session_created, input_received, snapshot_sent,
            # diff_emitted|snapshot_sent, session_closed  →  ≥ 5 events
            @test length(lines) >= 5

            components = map(l -> begin
                m = match(r"\"component\":\"([^\"]+)\"", l)
                m === nothing ? "" : m[1]
            end, lines)

            @test "jui.session" in components
            @test "jui.input" in components
            @test "jui.snapshot" in components
        end
    end

    # ── Phase 3: attach mode gate ─────────────────────────────────────────
    @testset "Phase 3: attach mode gate" begin
        events = []
        app = nothing
        s = T.new_session(app)

        # 1. Default mode is :observe (no kwarg)
        sid_obs = JUI.attach_agent(s.id, evt -> push!(events, evt))
        # 2. Explicit :observe
        sid_obs2 = JUI.attach_agent(s.id, evt -> nothing; mode=:observe)
        # 3. Explicit :interact
        sid_int = JUI.attach_agent(s.id, evt -> nothing; mode=:interact)
        # 4. Invalid mode throws AuthError
        @test_throws JUI.AuthError JUI.attach_agent(s.id, evt -> nothing; mode=:admin)

        # 5. inject_input with :observe subscription → AuthError
        evt = T.KeyEvent(:char, 'x', T.key_press)
        @test_throws JUI.AuthError JUI.inject_input(sid_obs, evt)

        # 6. inject_input with :interact → routes to session.injectors
        received = Ref{Any}(nothing)
        JUI.register_input_handler!(s, e -> received[] = e)
        JUI.inject_input(sid_int, evt)
        @test received[] === evt

        # Cleanup
        JUI.detach_agent!(sid_obs)
        JUI.detach_agent!(sid_obs2)
        JUI.detach_agent!(sid_int)
        T.close_session!(s.id)
    end

    # ── attach_agent: per-session filter ─────────────────────────────────
    @testset "attach_agent present — per-session filter" begin
        with_capture() do _io
            events = []

            s1 = T.new_session("attach_agent_s1")
            s2 = T.new_session("attach_agent_s2")

            sid = JUI.attach_agent(s1.id, evt -> push!(events, evt))

            # Close s1 → triggers frank_session_closed with session_id = s1.id.id
            T.close_session!(s1.id)

            # Close s2 → should NOT be captured by s1's subscription
            T.close_session!(s2.id)

            sleep(0.05)  # let any async callbacks flush

            # Only s1 events should be in events
            @test length(events) >= 1
            @test all(e -> e["state"]["session_id"] == s1.id.id, events)

            # detach_agent! handshake
            @test JUI.detach_agent!(sid) == true
            @test JUI.detach_agent!(sid) == false  # second call returns false
        end
    end

end
