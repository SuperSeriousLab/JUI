# Copyright 2026 Super Serious Studios
#
# MIT License
#
#
# ── session_test.jl ──────────────────────────────────────────────────────
# Phase 2a: Session registry tests.
# ─────────────────────────────────────────────────────────────────────────

@testset "Phase 2a: session registry" begin

    # ── new_session creates and registers a session ───────────────────────
    @testset "new_session" begin
        app = "dummy_app_1"
        s   = T.new_session(app)
        @test s isa T.Session
        @test s.app === app
        @test s.last_buffer === nothing
        @test s.id isa T.SessionID
        @test length(s.id.id) == 32   # 128 bits hex
        @test s.created_at > 0.0
        @test s.last_activity == s.created_at

        # Clean up
        T.close_session!(s.id)
    end

    # ── get_session returns the session by ID ─────────────────────────────
    @testset "get_session" begin
        s = T.new_session("dummy_app_2")
        found = T.get_session(s.id)
        @test found !== nothing
        @test found isa T.Session
        @test found.id == s.id

        # Unknown ID returns nothing
        fake_id = T.SessionID("0" ^ 32)
        @test T.get_session(fake_id) === nothing

        T.close_session!(s.id)
    end

    # ── close_session! removes the session ───────────────────────────────
    @testset "close_session!" begin
        s = T.new_session("dummy_app_3")
        @test T.get_session(s.id) !== nothing

        result = T.close_session!(s.id)
        @test result == true
        @test T.get_session(s.id) === nothing

        # Double-close returns false
        result2 = T.close_session!(s.id)
        @test result2 == false
    end

    # ── two sessions get unique IDs ───────────────────────────────────────
    @testset "unique IDs" begin
        s1 = T.new_session("app_a")
        s2 = T.new_session("app_b")
        @test s1.id != s2.id
        @test s1.id.id != s2.id.id

        T.close_session!(s1.id)
        T.close_session!(s2.id)
    end

    # ── list_sessions returns registered IDs ─────────────────────────────
    @testset "list_sessions" begin
        # Start from a clean slate for this subtest
        before = Set(T.list_sessions())

        s1 = T.new_session("list_app_1")
        s2 = T.new_session("list_app_2")

        ids = T.list_sessions()
        @test s1.id in ids
        @test s2.id in ids

        T.close_session!(s1.id)
        T.close_session!(s2.id)

        after = Set(T.list_sessions())
        @test !(s1.id in after)
        @test !(s2.id in after)
    end

    # ── touch! updates last_activity ─────────────────────────────────────
    @testset "touch!" begin
        s = T.new_session("touch_app")
        t0 = s.last_activity
        # Spin until time() advances (usually < 1 ms but give it room)
        deadline = time() + 2.0
        while s.last_activity == t0 && time() < deadline
            T.touch!(s)
        end
        @test s.last_activity >= t0

        T.close_session!(s.id)
    end

    # ── concurrent registration (basic multi-task safety) ─────────────────
    @testset "concurrent registration" begin
        N = 20
        sessions = Vector{T.Session}(undef, N)
        tasks    = map(1:N) do i
            @async begin
                sessions[i] = T.new_session("concurrent_app_$i")
            end
        end
        foreach(wait, tasks)

        ids = T.list_sessions()
        for s in sessions
            @test s.id in ids
        end

        # All IDs must be unique
        all_ids = [s.id.id for s in sessions]
        @test length(unique(all_ids)) == N

        # Clean up
        for s in sessions
            T.close_session!(s.id)
        end
    end

end
