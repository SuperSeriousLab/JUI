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
# ── auth/auth.jl ──────────────────────────────────────────────────────────
# Auth module entry point. Defines the AuthGate interface and wires
# together paths.jl, peer.jl, token.jl, and tls.jl.
#
# AuthGate is an abstract type (trait). Callers dispatch on the concrete
# gate type — no runtime flag, no config switch.
#
# Phase 3 chunk 1: infrastructure only. Transport wiring comes in chunk 3.
# ─────────────────────────────────────────────────────────────────────────

include("paths.jl")
include("peer.jl")
include("token.jl")
include("tls.jl")

# ── AuthGate trait ─────────────────────────────────────────────────────────

"""
    AuthGate

Abstract type for JUI authentication strategies.
Concrete subtypes implement `authorize(gate, conn_or_token)`.

Phase 3 implementations:
- `UnixPeerGate` — OS peer-UID check on a Unix socket fd
- `TCPTokenGate`  — constant-time bearer token comparison for TCP connections
"""
abstract type AuthGate end

"""
    UnixPeerGate <: AuthGate

Authenticates local Unix socket connections by comparing the peer's OS UID
against the server's own UID via `getpeereid(2)`. Zero configuration.
"""
struct UnixPeerGate <: AuthGate end

"""
    TCPTokenGate <: AuthGate

Authenticates TCP connections by comparing a presented bearer token against
a pre-shared token using constant-time comparison.
"""
struct TCPTokenGate <: AuthGate
    token::String  # expected bearer token (loaded from token file at server start)
end

"""
    authorize(gate::AuthGate, conn) → Bool

Verify an incoming connection against an `AuthGate`. Returns `true` if
the connection is authorized, `false` otherwise.

Concrete dispatches:
- `UnixPeerGate`: `conn` is a socket (fd extractable) — calls `check_peer_uid`.
- `TCPTokenGate`: `conn` is a `String` (the presented bearer token) — calls
  `compare_tokens_ct`.
"""
function authorize(gate::AuthGate, conn)
    error("AuthGate.authorize not implemented for $(typeof(gate))")
end

function authorize(::UnixPeerGate, sock)
    return check_peer_uid(sock)
end

function authorize(gate::TCPTokenGate, presented_token::String)
    return compare_tokens_ct(gate.token, presented_token)
end

# ── Re-exports ─────────────────────────────────────────────────────────────
# All public symbols from submodules are re-exported here so callers only
# need to load auth/auth.jl.

export AuthGate, UnixPeerGate, TCPTokenGate, authorize,
       # paths.jl
       jui_runtime_dir, socket_path, token_path, ensure_secure_file, getuid,
       # peer.jl
       peer_uid, check_peer_uid,
       # token.jl
       generate_token, write_token, load_token, compare_tokens_ct,
       # tls.jl
       ensure_server_cert, spki_verify
