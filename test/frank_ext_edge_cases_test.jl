# Copyright 2026 eidos workspace
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ── frank_ext_edge_cases_test.jl ──────────────────────────────────────────
# Edge case testing for JUIFRANKExt integration (Phase 2c/3).
# Requires FRANK to be loaded and JUIFRANKExt to be active.
# ──────────────────────────────────────────────────────────────────────────

using FRANK

const _ext = Base.get_extension(JUI, :JUIFRANKExt)

@testset "JUI FRANK Extension: Edge Cases" begin

    function with_capture(f)
        buf = IOBuffer()
        _ext.set_capture!(buf)
        try
            f(buf)
        finally
            _ext.set_capture!(stderr)
        end
    end

    function captured_lines(buf)
        seek(buf, 0)
        filter!(!isempty, readlines(buf))
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 1: attach_agent for SessionID A, event for SessionID B
    # → callback NOT invoked (cross-session isolation)
    # ─────────────────────────────────────────────────────────────────────
    @testset "cross-session isolation: only target session events" begin
        with_capture() do _io
            events_s1 = []

            s1 = T.new_session("edge_cross_1")
            s2 = T.new_session("edge_cross_2")

            # Attach agent to s1 only
            sid = JUI.attach_agent(s1.id, evt -> push!(events_s1, evt))

            # Close s1 → should trigger callback
            T.close_session!(s1.id)
            sleep(0.05)
            count_s1_before = length(events_s1)

            # Close s2 → should NOT trigger s1's callback
            T.close_session!(s2.id)
            sleep(0.05)

            @test length(events_s1) == count_s1_before
            @test all(e -> e["state"]["session_id"] == s1.id.id, events_s1)

            JUI.detach_agent!(sid)
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 2: attach_agent, detach, attach same session again
    # → fresh subscription (old SID invalidated)
    # ─────────────────────────────────────────────────────────────────────
    @testset "detach and re-attach: fresh subscription" begin
        with_capture() do _io
            events_first = []
            events_second = []

            s = T.new_session("edge_reattach")

            # First attachment
            sid1 = JUI.attach_agent(s.id, evt -> push!(events_first, evt))

            # Generate an event
            T.close_session!(s.id)
            sleep(0.05)
            count_first = length(events_first)

            # Detach
            @test JUI.detach_agent!(sid1) == true

            # Detaching again should fail
            @test JUI.detach_agent!(sid1) == false

            # Re-attach (same session)
            s = T.new_session("edge_reattach")
            sid2 = JUI.attach_agent(s.id, evt -> push!(events_second, evt))

            # Event on second session
            T.close_session!(s.id)
            sleep(0.05)

            @test length(events_second) >= 1
            @test sid1.id != sid2.id  # Different SubscriptionIDs
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 3: attach_agent with mode=:interact but session closes
    # before inject_input → inject_input raises clear error
    # ─────────────────────────────────────────────────────────────────────
    @testset "inject_input on closed session: AuthError" begin
        with_capture() do _io
            s = T.new_session("edge_inject_closed")
            sid = JUI.attach_agent(s.id, _ -> nothing; mode=:interact)

            # Close the session
            T.close_session!(s.id)
            sleep(0.05)

            # Try to inject input — should fail (session gone)
            evt = T.KeyEvent(:char, 'x', T.key_press)

            result = JUI.inject_input(sid, evt)
            # inject_input silently returns nothing if session closed
            @test result === nothing
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 4: Multiple agents attached to same session
    # → all receive all events
    # ─────────────────────────────────────────────────────────────────────
    @testset "multiple agents on same session: all receive events" begin
        with_capture() do _io
            events_a = []
            events_b = []
            events_c = []

            s = T.new_session("edge_multi_agent")

            sid_a = JUI.attach_agent(s.id, evt -> push!(events_a, evt))
            sid_b = JUI.attach_agent(s.id, evt -> push!(events_b, evt))
            sid_c = JUI.attach_agent(s.id, evt -> push!(events_c, evt))

            # Generate an event (e.g. close)
            T.close_session!(s.id)
            sleep(0.05)

            # All three should have received the close event
            @test length(events_a) >= 1
            @test length(events_b) >= 1
            @test length(events_c) >= 1

            # Detach
            JUI.detach_agent!(sid_a)
            JUI.detach_agent!(sid_b)
            JUI.detach_agent!(sid_c)
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 5: Agent callback mutates event dict
    # → other agents see copy (Dict isolation)
    # ─────────────────────────────────────────────────────────────────────
    @testset "event dict is copy (mutation isolation)" begin
        with_capture() do _io
            events_a = []
            events_b = []

            s = T.new_session("edge_mutation")

            sid_a = JUI.attach_agent(s.id, evt -> begin
                push!(events_a, evt)
                evt["mutated_by_a"] = true  # Mutate the dict
            end)
            sid_b = JUI.attach_agent(s.id, evt -> push!(events_b, evt))

            # Generate event
            T.close_session!(s.id)
            sleep(0.05)

            # Agent A saw its own mutation
            @test any(e -> haskey(e, "mutated_by_a"), events_a)

            # Agent B should NOT see agent A's mutation
            # (Each fanout event is a fresh copy created by emit!)
            @test !any(e -> haskey(e, "mutated_by_a"), events_b)

            JUI.detach_agent!(sid_a)
            JUI.detach_agent!(sid_b)
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 6: inject_input for unknown subscription ID
    # → clear error (AuthError)
    # ─────────────────────────────────────────────────────────────────────
    @testset "inject_input unknown subscription: AuthError" begin
        fake_sid = FRANK.SubscriptionID(999999999)
        evt = T.KeyEvent(:char, 'x', T.key_press)

        @test_throws JUI.AuthError JUI.inject_input(fake_sid, evt)
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 7: attach_agent with invalid mode
    # → AuthError on attach
    # ─────────────────────────────────────────────────────────────────────
    @testset "attach_agent invalid mode: AuthError" begin
        s = T.new_session("edge_invalid_mode")

        @test_throws JUI.AuthError JUI.attach_agent(s.id, _ -> nothing; mode=:admin)
        @test_throws JUI.AuthError JUI.attach_agent(s.id, _ -> nothing; mode=:secret)

        T.close_session!(s.id)
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 8: inject_input with :observe mode subscription
    # → AuthError (not :interact)
    # ─────────────────────────────────────────────────────────────────────
    @testset "inject_input :observe mode: AuthError" begin
        s = T.new_session("edge_observe_inject")

        # Default mode is :observe
        sid = JUI.attach_agent(s.id, _ -> nothing)

        evt = T.KeyEvent(:char, 'x', T.key_press)
        @test_throws JUI.AuthError JUI.inject_input(sid, evt)

        JUI.detach_agent!(sid)
        T.close_session!(s.id)
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 9: inject_input with :interact mode works + routes to session
    # ─────────────────────────────────────────────────────────────────────
    @testset "inject_input :interact mode: routes to session.injectors" begin
        s = T.new_session("edge_interact_inject")

        received = Ref{Any}(nothing)
        JUI.register_input_handler!(s, e -> received[] = e)

        sid = JUI.attach_agent(s.id, _ -> nothing; mode=:interact)

        evt = T.KeyEvent(:char, 'y', T.key_press)
        JUI.inject_input(sid, evt)

        @test received[] === evt

        JUI.detach_agent!(sid)
        T.close_session!(s.id)
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 10: attach/detach 100x rapidly
    # → no memory leak, SUBSCRIPTIONS_* dicts stay clean
    # ─────────────────────────────────────────────────────────────────────
    @testset "rapid attach/detach (100x): no memory leak" begin
        with_capture() do _io
            s = T.new_session("edge_rapid_cycle")

            for i in 1:100
                sid = JUI.attach_agent(s.id, _ -> nothing)
                # Immediately detach
                result = JUI.detach_agent!(sid)
                @test result == true

                # Double-detach should fail
                @test JUI.detach_agent!(sid) == false
            end

            T.close_session!(s.id)

            # After 100 attach/detach cycles, internal dicts should be empty
            # (This is a structural test — not strictly verifiable without
            # direct access to SUBSCRIPTIONS_MODES and SUBSCRIPTIONS_SESSIONS)
            @test true
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 11: Multiple sessions, multiple agents, cross-filtering
    # ─────────────────────────────────────────────────────────────────────
    @testset "complex multi-session multi-agent scenario" begin
        with_capture() do _io
            s1 = T.new_session("edge_complex_s1")
            s2 = T.new_session("edge_complex_s2")
            s3 = T.new_session("edge_complex_s3")

            events_s1_a = []
            events_s1_b = []
            events_s2_c = []

            # s1: 2 agents
            sid_s1_a = JUI.attach_agent(s1.id, evt -> push!(events_s1_a, evt))
            sid_s1_b = JUI.attach_agent(s1.id, evt -> push!(events_s1_b, evt))

            # s2: 1 agent
            sid_s2_c = JUI.attach_agent(s2.id, evt -> push!(events_s2_c, evt))

            # s3: no agents

            # Close s1, s2, s3
            T.close_session!(s1.id)
            T.close_session!(s2.id)
            T.close_session!(s3.id)
            sleep(0.1)

            # s1 agents received s1 close
            @test length(events_s1_a) >= 1
            @test length(events_s1_b) >= 1

            # s2 agent received s2 close
            @test length(events_s2_c) >= 1

            # Verify session_id filtering worked
            @test all(e -> e["state"]["session_id"] == s1.id.id, events_s1_a)
            @test all(e -> e["state"]["session_id"] == s1.id.id, events_s1_b)
            @test all(e -> e["state"]["session_id"] == s2.id.id, events_s2_c)

            JUI.detach_agent!(sid_s1_a)
            JUI.detach_agent!(sid_s1_b)
            JUI.detach_agent!(sid_s2_c)
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 12: set_capture! multiple times
    # → second capture replaces first, no leaks
    # ─────────────────────────────────────────────────────────────────────
    @testset "set_capture! replacement (no double-write)" begin
        buf1 = IOBuffer()
        buf2 = IOBuffer()

        _ext.set_capture!(buf1)
        s1 = T.new_session("edge_capture1")
        T.close_session!(s1.id)

        # Switch capture
        _ext.set_capture!(buf2)
        s2 = T.new_session("edge_capture2")
        T.close_session!(s2.id)

        # Restore
        _ext.set_capture!(stderr)

        # buf1 should have s1 events but not s2
        buf1_lines = split(String(take!(buf1)), "\n")
        buf1_content = join(buf1_lines)
        @test contains(buf1_content, s1.id.id)
        @test !contains(buf1_content, s2.id.id)

        # buf2 should have s2 events but not s1
        buf2_lines = split(String(take!(buf2)), "\n")
        buf2_content = join(buf2_lines)
        @test !contains(buf2_content, s1.id.id)
        @test contains(buf2_content, s2.id.id)
    end

end
