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
# ── auth/paths.jl ─────────────────────────────────────────────────────────
# XDG-aware path resolution for JUI runtime dirs, socket paths, and token
# paths. Enforces 0700 parent directory, owner check, and symlink rejection
# per docs/phase-3-auth-design.md §A.
# ─────────────────────────────────────────────────────────────────────────

export jui_runtime_dir, socket_path, token_path, ensure_secure_file, getuid,
       jui_config_dir, cert_path, key_path

"""
    getuid() → Int

Return the effective UID of the current process via libc getuid.
"""
function getuid()::Int
    return Int(ccall(:getuid, Cuint, ()))
end

"""
    jui_runtime_dir() → String

Return the JUI runtime directory path:
- `\$XDG_RUNTIME_DIR/jui/` when XDG_RUNTIME_DIR is set
- `/tmp/jui-\$UID/` otherwise

Creates the directory with mode 0700 if it does not exist.
Verifies: uid == getuid(), mode == 0700, not a symlink.
Throws a descriptive error on any check failure.
"""
function jui_runtime_dir()::String
    uid = getuid()
    base = get(ENV, "XDG_RUNTIME_DIR", "")
    if isempty(base)
        dir = "/tmp/jui-$uid"
    else
        dir = joinpath(base, "jui")
    end

    if ispath(dir)
        # Path exists — verify it is safe to use
        st = lstat(dir)  # lstat: do NOT follow symlinks
        if islink(st)
            error("JUI auth: runtime dir is a symlink — refusing to use: $dir")
        end
        if !isdir(st)
            error("JUI auth: runtime dir path exists but is not a directory: $dir")
        end
        # Check ownership: st_uid must equal our UID
        stat_uid = Int(stat_uid_of(dir))
        if stat_uid != uid
            error("JUI auth: runtime dir owned by uid $stat_uid, expected $uid: $dir")
        end
        # Check mode: must be 0700
        mode = filemode(st)
        if (mode & 0o777) != 0o700
            error("JUI auth: runtime dir has insecure permissions $(string(mode & 0o777, base=8)) (expected 700): $dir")
        end
    else
        # Does not exist — create with 0700
        try
            mkdir(dir, mode=0o700)
        catch e
            # Race: another process may have created it between the ispath check
            # and mkdir. Re-verify rather than fail.
            ispath(dir) || rethrow(e)
            return jui_runtime_dir()   # tail recurse to verify
        end
    end

    return dir * "/"
end

"""
    socket_path(session_id::String) → String

Return the Unix socket path for a given session ID.
"""
function socket_path(session_id::String)::String
    return jui_runtime_dir() * "$session_id.sock"
end

"""
    token_path(session_id::String) → String

Return the bearer token file path for a given session ID.
"""
function token_path(session_id::String)::String
    return jui_runtime_dir() * "$session_id.token"
end

"""
    ensure_secure_file(path::String, mode::UInt16 = 0o600) → Nothing

Set the permissions on `path` to `mode` and verify they were applied.
Throws if the file does not exist or if chmod fails.
"""
function ensure_secure_file(path::String, mode::UInt16 = UInt16(0o600))::Nothing
    isfile(path) || error("JUI auth: secure file does not exist: $path")
    chmod(path, mode)
    actual = filemode(lstat(path))
    if (actual & 0o777) != (mode & 0o777)
        error("JUI auth: failed to set mode $(string(mode & 0o777, base=8)) on $path (got $(string(actual & 0o777, base=8)))")
    end
    return nothing
end

# ── TLS config paths (Phase 3 chunk 2) ────────────────────────────────────

"""
    jui_config_dir() → String

Return the JUI config directory path:
- `\$XDG_CONFIG_HOME/jui/` when XDG_CONFIG_HOME is set
- `~/.config/jui/` otherwise

Creates the directory with mode 0700 if it does not exist.
"""
function jui_config_dir()::String
    base = get(ENV, "XDG_CONFIG_HOME", "")
    if isempty(base)
        base = joinpath(homedir(), ".config")
    end
    dir = joinpath(base, "jui")
    if !isdir(dir)
        mkpath(dir)
        chmod(dir, 0o700)
    end
    return dir * "/"
end

"""
    cert_path() → String

Return the TLS certificate file path: `\$XDG_CONFIG_HOME/jui/server.crt`.
"""
function cert_path()::String
    return jui_config_dir() * "server.crt"
end

"""
    key_path() → String

Return the TLS private key file path: `\$XDG_CONFIG_HOME/jui/server.key`.
"""
function key_path()::String
    return jui_config_dir() * "server.key"
end

# ── Internal helpers ───────────────────────────────────────────────────────

"""
    stat_uid_of(path::String) → Cuint

Return the st_uid (owner UID) of `path` without following symlinks.
Uses a direct ccall to lstat(2) to extract st_uid portably.
"""
function stat_uid_of(path::String)::Cuint
    # Julia's stat() follows symlinks; lstat() does not. We use ccall directly
    # to get the raw stat struct and extract st_uid.
    # We use the Julia internal stat structure via Base.Filesystem.lstat.
    s = Base.Filesystem.lstat(path)
    # Base.StatStruct exposes .uid on Julia 1.9+
    return Cuint(s.uid)
end
