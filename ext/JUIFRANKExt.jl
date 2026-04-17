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
# ── ext/JUIFRANKExt.jl ──────────────────────────────────────────────────
# Phase 2c: FRANK integration extension for JUI.
#
# This module is loaded ONLY when both JUI and FRANK are present in the
# host environment. It overrides the @inline no-op stubs in frank_hooks.jl
# with real implementations that emit FRANK JSONL events to stderr.
#
# When FRANK is absent this file is never loaded — zero overhead.
#
# Usage (until FRANK is published to eidos Julia registry in Phase 4):
#   julia --project=. -e 'using Pkg; Pkg.develop(path="../FRANK")'
# ─────────────────────────────────────────────────────────────────────────

__precompile__(false)

module JUIFRANKExt

using JUI
using FRANK

# Single emitter per process. Could be made per-session in a future phase.
const EMITTER = Ref{Union{FrankEmitter, Nothing}}(nothing)

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

# ── Agent attach API ──────────────────────────────────────────────────────

"""
    JUI.attach_agent(session_id, callback) → FRANK.SubscriptionID

Subscribe to FRANK events filtered to the given SessionID.
`callback(event_dict)` is called for every FRANK event where
`state["session_id"] == session_id.id`.

Returns a `FRANK.SubscriptionID` for use with `JUI.detach_agent!`.
Only available when FRANK is loaded.
"""
function JUI.attach_agent(session_id, callback::Function)
    emitter = _emitter()
    filter_fn = (component, event_type, state) ->
        haskey(state, "session_id") && state["session_id"] == session_id.id
    return FRANK.subscribe(emitter, filter_fn, callback)
end

"""
    JUI.detach_agent!(sid) → Bool

Remove the agent subscription identified by `sid`.
Returns `true` if the subscription was found and removed, `false` if already gone.
Only available when FRANK is loaded.
"""
function JUI.detach_agent!(sid)
    emitter = _emitter()
    return FRANK.unsubscribe!(emitter, sid)
end

end # module
