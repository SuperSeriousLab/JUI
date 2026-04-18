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
#
# TLS library choice: openssl CLI (system binary, OpenSSL 3.x)
#
# Rationale: Neither MbedTLS nor OpenSSL.jl are in JUI's deps, and adding
# either for cert *generation* (a one-time setup operation) would pull in a
# non-trivial transitive dependency. The openssl(1) CLI is universally present
# on the target platform (Linux/macOS developer workstation) and OpenSSL 3.x
# fully supports ed25519 keygen + self-signed X.509 cert gen with SAN. Cert
# generation is a one-time idempotent setup step; shelling out is appropriate.
#
# SPKI hash computation (called per-connection) is done via the openssl CLI as
# well — the operation is: extract SPKI DER from cert, pipe through sha256.
# SHA-256 itself is from Julia's stdlib SHA module (zero extra deps).
#
# TLS 1.3 server socket setup is deferred to chunk 3 (Transport layer).
# This file only covers key/cert management and SPKI TOFU pin store.
# ─────────────────────────────────────────────────────────────────────────

using SHA

export ensure_server_cert, spki_hash, spki_verify, spki_unpin!, pin_store_dir

# ── Constants ──────────────────────────────────────────────────────────────

const _CERT_VALIDITY_DAYS = 3650   # 10 years — long-lived, renewed via manual rotation
const _KEY_ALGO            = "ed25519"
const _CERT_SUBJECT        = "/CN=jui.local"
const _CERT_SAN            = "subjectAltName=DNS:jui.local,IP:0.0.0.0"

# ── Public API ─────────────────────────────────────────────────────────────

"""
    ensure_server_cert() → (cert_path::String, key_path::String)

Generate an ed25519 keypair and self-signed certificate for the JUI server
if they do not already exist, then return their paths.

Files:
- `\$XDG_CONFIG_HOME/jui/server.key` — private key, mode 0600
- `\$XDG_CONFIG_HOME/jui/server.crt` — certificate, mode 0644

Certificate properties:
- Algorithm: ed25519
- Validity: $(string(_CERT_VALIDITY_DAYS)) days
- SAN: DNS:jui.local, IP:0.0.0.0
- Model: TOFU — hostname verification is replaced by SPKI pinning

If both files already exist *and* the key has mode 0600, returns immediately
(idempotent — does not regenerate). If the key exists but has wrong
permissions, corrects them.

Shelling out to `openssl(1)` CLI (OpenSSL 3.x) for cert generation.
This is a one-time setup operation; shell-out is acceptable.
"""
function ensure_server_cert()::Tuple{String,String}
    cert = cert_path()
    key  = key_path()

    if isfile(cert) && isfile(key)
        # Both exist — enforce key mode 0600 and return
        _enforce_key_mode(key)
        return (cert, key)
    end

    # Ensure config dir exists (0700)
    dir = jui_config_dir()

    # Use a temp dir for atomic generation, then move into place
    tmp_dir = mktempdir()
    tmp_key  = joinpath(tmp_dir, "server.key")
    tmp_cert = joinpath(tmp_dir, "server.crt")

    try
        # Step 1: generate ed25519 private key
        ret = run(ignorestatus(`openssl genpkey -algorithm $_KEY_ALGO -out $tmp_key`))
        ret.exitcode == 0 || error("JUI TLS: openssl genpkey failed (exit $(ret.exitcode))")

        # Step 2: self-sign with SAN
        ret = run(ignorestatus(`openssl req -x509 -new -key $tmp_key -out $tmp_cert
            -days $_CERT_VALIDITY_DAYS
            -subj $_CERT_SUBJECT
            -addext $_CERT_SAN`))
        ret.exitcode == 0 || error("JUI TLS: openssl req -x509 failed (exit $(ret.exitcode))")

        # Enforce key permissions before moving
        chmod(tmp_key, 0o600)

        # Atomic move into config dir
        cp(tmp_key,  key,  force=true)
        cp(tmp_cert, cert, force=true)
        chmod(key,  0o600)
        chmod(cert, 0o644)
    finally
        rm(tmp_dir, recursive=true, force=true)
    end

    return (cert, key)
end

"""
    spki_hash(cert_path::String) → String

Compute the SHA-256 hash of the certificate's SubjectPublicKeyInfo (SPKI) DER
bytes and return it as a lowercase hex string (64 characters).

SPKI persists across certificate renewals that reuse the same key, making it
the correct identity anchor for TOFU pinning (not the full cert fingerprint).

Implementation: shells out to `openssl` to extract SPKI DER → pipes into
Julia's stdlib `sha256` for hashing.
"""
function spki_hash(cert_path::String)::String
    isfile(cert_path) || error("JUI TLS: cert not found: $cert_path")

    # Extract SubjectPublicKeyInfo in DER format from the cert
    # openssl x509 -pubkey -noout emits PEM pubkey; openssl pkey -pubin -outform DER
    # converts to raw DER SubjectPublicKeyInfo bytes.
    spki_der = _extract_spki_der(cert_path)

    return bytes2hex(sha256(spki_der))
end

"""
    pin_store_dir() → String

Return the SPKI pin store directory: `\$XDG_CONFIG_HOME/jui/known_servers/`.
Creates the directory (mode 0700) if it does not exist.
"""
function pin_store_dir()::String
    base = jui_config_dir()
    dir  = joinpath(base, "known_servers")
    if !isdir(dir)
        mkpath(dir)
        chmod(dir, 0o700)
    end
    return dir * "/"
end

"""
    spki_verify(server_addr::String, observed_spki_hash::String) → Bool

TOFU SPKI pinning for a server identified by `server_addr` (e.g. `"host:port"`).

- First connect (no pin file): writes `observed_spki_hash` to the pin store and
  returns `true` (Trust On First Use).
- Subsequent connects: reads the stored hash and returns `observed_spki_hash ==
  pinned_hash`.
- Mismatch: returns `false`. Caller is responsible for closing the connection
  and emitting a FRANK `auth.reject` event.

Pin files are stored at `\$XDG_CONFIG_HOME/jui/known_servers/<server_addr>`.
`server_addr` is sanitised (`:` → `%3A`, path separators stripped) so it is
safe to use as a filename.
"""
function spki_verify(server_addr::String, observed_spki_hash::String)::Bool
    pin_file = _pin_file_path(server_addr)

    if !isfile(pin_file)
        # TOFU: first connect — write pin
        _write_pin(pin_file, observed_spki_hash)
        return true
    end

    # Subsequent connect — compare
    stored = _read_pin(pin_file)
    return stored == observed_spki_hash
end

"""
    spki_unpin!(server_addr::String) → Bool

Remove the SPKI pin for `server_addr`, forcing re-TOFU on the next connection.
Returns `true` if the pin existed and was removed, `false` if it was already
absent (idempotent, no error).
"""
function spki_unpin!(server_addr::String)::Bool
    pin_file = _pin_file_path(server_addr)
    if isfile(pin_file)
        rm(pin_file)
        return true
    end
    return false
end

# ── Internal helpers ───────────────────────────────────────────────────────

"""
    _enforce_key_mode(key_path) → nothing

Ensure the private key file has mode 0600. Corrects if wrong.
"""
function _enforce_key_mode(key::String)::Nothing
    actual = filemode(lstat(key)) & 0o777
    if actual != 0o600
        chmod(key, 0o600)
    end
    return nothing
end

"""
    _extract_spki_der(cert_path) → Vector{UInt8}

Shell out to openssl to extract SubjectPublicKeyInfo DER bytes from a PEM cert.
Uses `read(cmd)` for clean byte capture without ignorestatus complications.
"""
function _extract_spki_der(cert_path::String)::Vector{UInt8}
    # Two-step pipeline via temp file (avoids /dev/stdin portability issues):
    #   1. openssl x509 -pubkey -noout → PEM public key into temp file
    #   2. openssl pkey -pubin -outform DER → raw DER SubjectPublicKeyInfo bytes
    tmp = tempname() * ".pem"
    try
        ret = run(ignorestatus(`openssl x509 -in $cert_path -pubkey -noout -out $tmp`))
        ret.exitcode == 0 || error("JUI TLS: openssl x509 -pubkey failed (exit $(ret.exitcode))")

        # read(Cmd) → Vector{UInt8}, throws ProcessFailedException on non-zero exit
        return read(`openssl pkey -pubin -outform DER -in $tmp`)
    catch e
        e isa ProcessFailedException && error("JUI TLS: openssl pkey -outform DER failed: $e")
        rethrow(e)
    finally
        rm(tmp, force=true)
    end
end

"""
    _pin_file_path(server_addr) → String

Return the pin file path for a server address, sanitising it to be
filesystem-safe.
"""
function _pin_file_path(server_addr::String)::String
    # Sanitise: replace colon and path separators with safe equivalents
    safe = replace(server_addr, ":" => "%3A", "/" => "%2F", "\\" => "%5C")
    return pin_store_dir() * safe
end

"""
    _write_pin(pin_file, hash) → nothing

Write the SPKI hash to the pin file with mode 0600.
"""
function _write_pin(pin_file::String, hash::String)::Nothing
    # Ensure parent dir exists
    dir = dirname(pin_file)
    isdir(dir) || mkpath(dir)
    write(pin_file, hash)
    chmod(pin_file, 0o600)
    return nothing
end

"""
    _read_pin(pin_file) → String

Read and return the stored SPKI hash from a pin file (strips trailing whitespace).
"""
function _read_pin(pin_file::String)::String
    return strip(read(pin_file, String))
end
