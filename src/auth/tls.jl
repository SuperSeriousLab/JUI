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
# ── auth/tls.jl ───────────────────────────────────────────────────────────
# STUB — Phase 3 chunk 2.
# TLS 1.3 server with auto-generated ed25519 cert + SPKI pinning (TOFU).
# ─────────────────────────────────────────────────────────────────────────

export ensure_server_cert, spki_verify

"""
    ensure_server_cert() → (cert_path::String, key_path::String)

Generate a self-signed ed25519 certificate for the JUI server if one does not
already exist. Stores cert at `\$XDG_CONFIG_HOME/jui/server.crt` and key at
`\$XDG_CONFIG_HOME/jui/server.key` (mode 0600).

Returns a tuple `(cert_path, key_path)`.

**STUB** — Not yet implemented. Will be completed in Phase 3 chunk 2.
"""
function ensure_server_cert()
    error("TLS: ensure_server_cert — not yet implemented (Phase 3 chunk 2)")
end

"""
    spki_verify(host::String, spki_hash::String) → Bool

On first connection to `host`, record the server's SPKI hash to
`~/.config/jui/known_servers`. On subsequent connections, verify the
presented SPKI hash matches the pinned value.

**STUB** — Not yet implemented. Will be completed in Phase 3 chunk 2.
"""
function spki_verify(host::String, spki_hash::String)
    error("TLS: spki_verify — not yet implemented (Phase 3 chunk 2)")
end
