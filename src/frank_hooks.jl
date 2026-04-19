# Copyright 2026 Super Serious Studios
#
# MIT License
#
#
#
# ── frank_hooks.jl ───────────────────────────────────────────────────────
# Phase 2c: Stub hooks for FRANK optional weak dependency.
#
# When FRANK is NOT loaded these stubs are called. They are @inline no-ops
# that return nothing — zero allocation, zero overhead in the hot path.
#
# When FRANK IS loaded, ext/JUIFRANKExt.jl overrides each of these with a
# real implementation that emits a FRANK JSONL event to stderr.
#
# These functions are NOT exported from JUI but ARE accessible as
# JUI.frank_session_created etc. so the extension module can override them.
# ─────────────────────────────────────────────────────────────────────────

# Stub hooks — overridden by ext/JUIFRANKExt.jl when FRANK is loaded.
# All stubs are @inline no-ops. Zero overhead in FRANK-absent path.

@inline frank_session_created(::Any) = nothing
@inline frank_session_closed(::Any) = nothing
@inline frank_input_received(::Any, ::Any) = nothing   # session, event
@inline frank_snapshot_sent(::Any, ::Any) = nothing    # session, buffer
@inline frank_diff_emitted(::Any, ::Any) = nothing     # session, cell_count

# ── Auth event hooks (Phase 3 chunk 3a) ──────────────────────────────────
# Called on every Unix socket accept: ok (peer UID matched) or reject.
# Overridden by ext/JUIFRANKExt.jl when FRANK is loaded; no-ops otherwise.
@inline frank_auth_ok(::Any, ::Any) = nothing      # session_id, details::Dict
@inline frank_auth_reject(::Any, ::Any) = nothing  # session_id, reason::Dict

# ── Agent attach API stubs ────────────────────────────────────────────────
# These raise informative errors in the FRANK-absent path.
# JUIFRANKExt overrides them with real FRANK.subscribe/unsubscribe! calls.

"""
    attach_agent(session_id, callback) → SubscriptionID

Subscribe to FRANK events for `session_id`. Requires FRANK to be loaded.
"""
function attach_agent(session_id, callback::Function)
    error("FRANK not loaded — agent attach unavailable. " *
          "Install FRANK package or use Pkg.develop(path=\"../FRANK\").")
end

"""
    detach_agent!(sid) → Bool

Remove an agent subscription by ID. Requires FRANK to be loaded.
"""
function detach_agent!(sid)
    error("FRANK not loaded — agent attach unavailable. " *
          "Install FRANK package or use Pkg.develop(path=\"../FRANK\").")
end

"""
    inject_input(subscription_id, event)

Inject an input event into a session on behalf of an authorised agent.
The subscription must have been created with `mode=:interact`; `:observe`
subscriptions will receive an `AuthError`.

Requires FRANK to be loaded. In the FRANK-absent path, raises an error.
"""
function inject_input(subscription_id, event)
    error("FRANK not loaded — inject_input unavailable.")
end
