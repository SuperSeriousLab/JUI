# Copyright 2026 Super Serious Studios
#
# MIT License
#
#
#
# ── auth/token.jl ─────────────────────────────────────────────────────────
# 128-bit bearer token lifecycle: generate, write (atomic, 0600), load,
# and constant-time compare.
# ─────────────────────────────────────────────────────────────────────────

using Base64: base64encode
import Random: RandomDevice

export generate_token, write_token, load_token, compare_tokens_ct

"""
    generate_token() → String

Generate a 128-bit cryptographically random token, base64url-encoded
without padding. Returns a ~22-character ASCII string.

Uses `RandomDevice` (OS entropy source: /dev/urandom on Linux).
"""
function generate_token()::String
    raw = rand(RandomDevice(), UInt8, 16)
    b64 = base64encode(raw)
    # Convert standard base64 → base64url, strip padding
    url = replace(replace(b64, '+' => '-'), '/' => '_')
    return rstrip(url, '=')
end

"""
    write_token(path::String, token::String) → Nothing

Write `token` to `path` atomically with mode 0600:
1. Write to `path.tmp`
2. chmod 0600
3. rename (atomic on POSIX)

Throws on any IO or permission error.
"""
function write_token(path::String, token::String)::Nothing
    tmp = path * ".tmp"
    try
        write(tmp, token)
        chmod(tmp, 0o600)
        mv(tmp, path; force=true)
    catch e
        # Clean up temp file on failure
        try; rm(tmp, force=true); catch; end
        rethrow(e)
    end
    return nothing
end

"""
    load_token(path::String) → String

Read the bearer token from `path`.
Verifies the file exists and has mode 0600.
Throws if missing or if permissions are wrong.
"""
function load_token(path::String)::String
    isfile(path) || error("JUI auth: token file not found: $path")
    st = lstat(path)
    mode = filemode(st)
    if (mode & 0o777) != 0o600
        error("JUI auth: token file has insecure permissions $(string(mode & 0o777, base=8)) (expected 600): $path")
    end
    return strip(read(path, String))
end

"""
    compare_tokens_ct(a::String, b::String) → Bool

Constant-time string comparison to prevent timing oracles.
Returns `true` iff `a` and `b` are byte-for-byte identical.

Length inequality is checked first (length is public / observable), but
the byte loop always runs over the shorter length to prevent short-circuit
on content. The final result encodes both the length check and the XOR
accumulator.
"""
function compare_tokens_ct(a::AbstractString, b::AbstractString)::Bool
    # Length difference is observable via side-channels regardless (attacker
    # can binary-search lengths). We return false on mismatch but do so
    # without leaking content.
    length_ok = (length(a) == length(b))
    # Use the shorter length so we always iterate without bounds errors.
    len = min(length(a), length(b))
    diff = UInt8(0)
    au = codeunits(a)
    bu = codeunits(b)
    # Iterate min(len, ...) without short-circuit
    for i in 1:min(len, length(au), length(bu))
        @inbounds diff |= au[i] ⊻ bu[i]
    end
    return length_ok & (diff == UInt8(0))
end
