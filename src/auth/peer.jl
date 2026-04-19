# Copyright 2026 Super Serious Studios
#
# MIT License
#
#
#
# ── auth/peer.jl ──────────────────────────────────────────────────────────
# Unix socket peer credential check via getpeereid(2).
# Portable: Linux glibc + macOS/BSD use getpeereid.
# Fallback to SO_PEERCRED (Linux-specific) if getpeereid symbol is absent
# (e.g. musl libc on Alpine).
# ─────────────────────────────────────────────────────────────────────────

export peer_uid, check_peer_uid

# SO_PEERCRED Linux constants
const SO_PEERCRED = Cint(17)
const SOL_SOCKET  = Cint(1)

# ucred struct layout on Linux x86-64 (pid, uid, gid — each 4 bytes)
struct UCred
    pid::Cuint
    uid::Cuint
    gid::Cuint
end

"""
    peer_uid(sock_fd::Cint) → Cint

Return the UID of the peer connected on Unix socket file descriptor `sock_fd`.

Uses `getpeereid(2)` (portable: Linux glibc, macOS, BSD).
Falls back to `SO_PEERCRED` getsockopt on Linux if `getpeereid` is not
available (musl libc, Alpine).

Throws on error.
"""
function peer_uid(sock_fd::Cint)::Cint
    uid_ref = Ref{Cuint}(0)
    gid_ref = Ref{Cuint}(0)

    # Try getpeereid first (portable)
    ret = try
        ccall(:getpeereid, Cint, (Cint, Ptr{Cuint}, Ptr{Cuint}),
              sock_fd, uid_ref, gid_ref)
    catch
        Cint(-2)  # sentinel: symbol not found
    end

    if ret == Cint(0)
        return Cint(uid_ref[])
    end

    # getpeereid failed or is unavailable — try SO_PEERCRED (Linux only)
    @static if Sys.islinux()
        cred = Ref(UCred(0, 0, 0))
        optlen = Ref{Cuint}(sizeof(UCred))
        rc = ccall(:getsockopt, Cint,
                   (Cint, Cint, Cint, Ptr{UCred}, Ptr{Cuint}),
                   sock_fd, SOL_SOCKET, SO_PEERCRED, cred, optlen)
        if rc == Cint(0)
            return Cint(cred[].uid)
        end
        errno_ptr = ccall(:__errno_location, Ptr{Cint}, ())
        errno_val = unsafe_load(errno_ptr)
        error("JUI auth: SO_PEERCRED getsockopt failed (errno=$errno_val) on fd=$sock_fd")
    end

    # Non-Linux and getpeereid failed
    error("JUI auth: getpeereid not available and SO_PEERCRED is Linux-only; cannot check peer UID (ret=$ret, fd=$sock_fd)")
end

"""
    check_peer_uid(sock) → Bool

Check whether the peer on Unix socket `sock` has the same UID as the current
process. Returns `true` iff UIDs match.

`sock` may be any object with a `.handle` field (Sockets.UnixSocket) or
a raw `Cint` fd. If the fd cannot be extracted, returns `false`.
"""
function check_peer_uid(sock)::Bool
    fd = _extract_fd(sock)
    fd < Cint(0) && return false
    try
        puid = peer_uid(fd)
        return puid == Cint(getuid())
    catch e
        @warn "JUI auth: check_peer_uid failed" exception=(e, catch_backtrace())
        return false
    end
end

# ── Internal ───────────────────────────────────────────────────────────────

"""Extract a raw Cint fd from a Julia socket or fd value."""
function _extract_fd(sock)::Cint
    if sock isa Cint
        return sock
    elseif sock isa Integer
        return Cint(sock)
    elseif sock isa Base.RawFD
        # RawFD is an opaque wrapper — reinterpret as Int32 to get the fd number.
        return Cint(reinterpret(Int32, sock))
    end
    # Julia Base.PipeEndpoint / TCPSocket / Sockets types: libuv-backed handles.
    # Base._fd(sock) returns a RawFD; extract the int via reinterpret.
    try
        rfd = Base._fd(sock)
        return Cint(reinterpret(Int32, rfd))
    catch end
    @warn "JUI auth: could not extract fd from $(typeof(sock))"
    return Cint(-1)
end
