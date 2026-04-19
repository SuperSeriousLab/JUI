# Copyright 2026 Super Serious Studios
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
# ── ext/JUIFRANKExt.jl ──────────────────────────────────────────────────
# Phase 2c: FRANK integration extension for JUI.
#
# This module is loaded ONLY when both JUI and FRANK are present in the
# host environment. It overrides the @inline no-op stubs in frank_hooks.jl
# with real implementations that emit FRANK JSONL events to stderr.
#
# When FRANK is absent this file is never loaded — zero overhead.
#
# Usage: Pkg.add(["JUI", "FRANK"]) via SuperSeriousLab registry.
# ─────────────────────────────────────────────────────────────────────────

__precompile__(false)

module JUIFRANKExt

using JUI
using FRANK

# Single emitter per process. Could be made per-session in a future phase.
const EMITTER = Ref{Union{FrankEmitter, Nothing}}(nothing)

# ── Subscription mode tracking ────────────────────────────────────────────
# Maps SubscriptionID → mode (:observe or :interact)
const SUBSCRIPTIONS_MODES_LOCK = ReentrantLock()
const SUBSCRIPTIONS_MODES = Dict{FRANK.SubscriptionID, Symbol}()

# Maps SubscriptionID → SessionID (to look up session for inject_input)
const SUBSCRIPTIONS_SESSIONS_LOCK = ReentrantLock()
const SUBSCRIPTIONS_SESSIONS = Dict{FRANK.SubscriptionID, JUI.SessionID}()

function __init__()
    EMITTER[] = FrankEmitter()
    @debug "JUI: FRANK instrumentation enabled"
end

function _emitter()
    e = EMITTER[]
    e === nothing ? FrankEmitter() : e
end

"""
    set_capture!(io::IO)

Redirect FRANK emission to `io` (e.g. an IOBuffer in tests).
Returns the new FrankEmitter so callers can inspect it.
Backward-compatible: the default emitter writes to stderr.
"""
function set_capture!(io::IO)
    EMITTER[] = FrankEmitter(; io=io)
    return EMITTER[]
end

# ── Hook overrides ────────────────────────────────────────────────────────

function JUI.frank_session_created(session)
    emit!(_emitter(), "jui.session", FRANK.STATE_TRANSITION,
          Dict{String,Any}("session_id" => session.id.id,
                           "created_at" => session.created_at);
          transition="created")
    return nothing
end

function JUI.frank_session_closed(session_id)
    emit!(_emitter(), "jui.session", FRANK.STATE_TRANSITION,
          Dict{String,Any}("session_id" => session_id.id);
          transition="closed")
    return nothing
end

function JUI.frank_input_received(session, evt)
    emit!(_emitter(), "jui.input", FRANK.STATE_TRANSITION,
          Dict{String,Any}("session_id" => session.id.id,
                           "event_type" => string(typeof(evt).name.name));
          transition="input_received")
    return nothing
end

function JUI.frank_snapshot_sent(session, buf)
    emit!(_emitter(), "jui.snapshot", FRANK.STATE_TRANSITION,
          Dict{String,Any}("session_id" => session.id.id,
                           "cell_count" => length(buf.content));
          transition="snapshot_sent")
    return nothing
end

function JUI.frank_diff_emitted(session, cell_count)
    emit!(_emitter(), "jui.diff", FRANK.STATE_TRANSITION,
          Dict{String,Any}("session_id" => session.id.id,
                           "cell_count" => cell_count);
          transition="diff_emitted")
    return nothing
end

# ── Auth event hooks (Phase 3 chunk 3a) ──────────────────────────────────

function JUI.frank_auth_ok(session_id, details)
    emit!(_emitter(), "jui.auth", FRANK.STATE_TRANSITION,
          Dict{String,Any}("session_id" => session_id, "details" => details);
          transition="ok")
    return nothing
end

function JUI.frank_auth_reject(session_id, reason)
    emit!(_emitter(), "jui.auth", FRANK.STATE_TRANSITION,
          Dict{String,Any}("session_id" => session_id, "reason" => reason);
          transition="reject")
    return nothing
end

# ── Agent attach API ──────────────────────────────────────────────────────

"""
    JUI.attach_agent(session_id, callback; mode=:observe) → FRANK.SubscriptionID

Subscribe to FRANK events filtered to the given SessionID.
`callback(event_dict)` is called for every FRANK event where
`state["session_id"] == session_id.id`.

`mode` must be `:observe` (read-only, default) or `:interact` (allows
`inject_input` to route events into the session). Any other value raises
`JUI.AuthError`.

Returns a `FRANK.SubscriptionID` for use with `JUI.detach_agent!`.
Only available when FRANK is loaded.
"""
function JUI.attach_agent(session_id, callback::Function; mode::Symbol=:observe)
    mode ∈ (:observe, :interact) ||
        throw(JUI.AuthError("attach_agent: invalid mode $(repr(mode)); " *
                            "must be :observe or :interact"))
    emitter = _emitter()
    filter_fn = (component, event_type, state) ->
        haskey(state, "session_id") && state["session_id"] == session_id.id
    sid = FRANK.subscribe(emitter, filter_fn, callback)
    lock(SUBSCRIPTIONS_MODES_LOCK) do
        SUBSCRIPTIONS_MODES[sid] = mode
    end
    lock(SUBSCRIPTIONS_SESSIONS_LOCK) do
        SUBSCRIPTIONS_SESSIONS[sid] = session_id
    end
    return sid
end

"""
    JUI.detach_agent!(sid) → Bool

Remove the agent subscription identified by `sid`.
Returns `true` if the subscription was found and removed, `false` if already gone.
Only available when FRANK is loaded.
"""
function JUI.detach_agent!(sid)
    emitter = _emitter()
    result = FRANK.unsubscribe!(emitter, sid)
    lock(SUBSCRIPTIONS_MODES_LOCK) do
        delete!(SUBSCRIPTIONS_MODES, sid)
    end
    lock(SUBSCRIPTIONS_SESSIONS_LOCK) do
        delete!(SUBSCRIPTIONS_SESSIONS, sid)
    end
    return result
end

"""
    JUI.inject_input(subscription_id, event)

Inject an input event into a session on behalf of an authorised agent.
The subscription must have been created with `mode=:interact`; `:observe`
subscriptions receive an `AuthError`.

Routes the event to all handlers registered via `register_input_handler!`
on the target session. If no handlers are registered the call is a no-op.
"""
function JUI.inject_input(subscription_id, event)
    # 1. Validate mode
    mode = lock(SUBSCRIPTIONS_MODES_LOCK) do
        get(SUBSCRIPTIONS_MODES, subscription_id, nothing)
    end
    if mode === nothing
        throw(JUI.AuthError("inject_input: unknown subscription_id"))
    end
    mode == :interact ||
        throw(JUI.AuthError("inject_input: subscription mode is :observe; " *
                            "inject_input requires mode=:interact"))

    # 2. Resolve session
    session_id = lock(SUBSCRIPTIONS_SESSIONS_LOCK) do
        get(SUBSCRIPTIONS_SESSIONS, subscription_id, nothing)
    end
    session_id === nothing &&
        throw(JUI.AuthError("inject_input: subscription has no associated session"))

    session = JUI.get_session(session_id)
    session === nothing && return nothing  # session closed — silently drop

    # 3. Call registered injectors
    for handler in session.injectors
        handler(event)
    end
    return nothing
end

end # module
