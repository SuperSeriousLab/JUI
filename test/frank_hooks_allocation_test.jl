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
# ── frank_hooks_allocation_test.jl ────────────────────────────────────────
# Verify that frank_hooks.jl stubs are true zero-allocation no-ops.
# These tests ensure the @inline stubs compile to code with zero allocations.
# ─────────────────────────────────────────────────────────────────────────

@testset "frank_hooks: zero-allocation guarantee (when FRANK absent)" begin

    # When FRANK is loaded, these tests are skipped (the extension overrides).
    # When FRANK is absent, we test the stubs directly.

    has_frank = Base.get_extension(JUI, :JUIFRANKExt) !== nothing

    if !has_frank
        # ─────────────────────────────────────────────────────────────────
        # Test that each stub is truly @inline and allocates nothing
        # ─────────────────────────────────────────────────────────────────

        @testset "frank_session_created: zero allocations" begin
            dummy_session = nothing
            alloc = @allocated JUI.frank_session_created(dummy_session)
            @test alloc == 0
        end

        @testset "frank_session_closed: zero allocations" begin
            dummy_sid = nothing
            alloc = @allocated JUI.frank_session_closed(dummy_sid)
            @test alloc == 0
        end

        @testset "frank_input_received: zero allocations" begin
            dummy_session = nothing
            dummy_event = nothing
            alloc = @allocated JUI.frank_input_received(dummy_session, dummy_event)
            @test alloc == 0
        end

        @testset "frank_snapshot_sent: zero allocations" begin
            dummy_session = nothing
            dummy_buffer = nothing
            alloc = @allocated JUI.frank_snapshot_sent(dummy_session, dummy_buffer)
            @test alloc == 0
        end

        @testset "frank_diff_emitted: zero allocations" begin
            dummy_session = nothing
            dummy_count = 0
            alloc = @allocated JUI.frank_diff_emitted(dummy_session, dummy_count)
            @test alloc == 0
        end

        @testset "frank_auth_ok: zero allocations" begin
            dummy_sid = nothing
            dummy_details = nothing
            alloc = @allocated JUI.frank_auth_ok(dummy_sid, dummy_details)
            @test alloc == 0
        end

        @testset "frank_auth_reject: zero allocations" begin
            dummy_sid = nothing
            dummy_reason = nothing
            alloc = @allocated JUI.frank_auth_reject(dummy_sid, dummy_reason)
            @test alloc == 0
        end

        # ─────────────────────────────────────────────────────────────────
        # Return values are all nothing
        # ─────────────────────────────────────────────────────────────────

        @testset "return values are nothing" begin
            @test JUI.frank_session_created(nothing) === nothing
            @test JUI.frank_session_closed(nothing) === nothing
            @test JUI.frank_input_received(nothing, nothing) === nothing
            @test JUI.frank_snapshot_sent(nothing, nothing) === nothing
            @test JUI.frank_diff_emitted(nothing, nothing) === nothing
            @test JUI.frank_auth_ok(nothing, nothing) === nothing
            @test JUI.frank_auth_reject(nothing, nothing) === nothing
        end

    else
        @warn "frank_hooks_allocation_test.jl: Skipping zero-allocation tests (FRANK is loaded; extension has overridden stubs)"
    end

end
