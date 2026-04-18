#!/usr/bin/env julia
# jui-server — persistent JUI terminal server (SSH replacement)
#
# Starts a shell inside a JUI TerminalWidget and exposes it over TCP+TLS.
# Clients connect with `ssj <host>` (or JUI.run_client directly).
#
# Usage:
#   julia jui-server.jl [--port PORT] [--shell SHELL] [--cmd CMD...]
#
# Environment:
#   JUI_PORT=7878       listening port (default 7878)
#   JUI_TOKEN_FILE      path to write token (default ~/.config/jui/token)
#   JUI_SHELL           shell to run (default $SHELL or /bin/bash)
#
# The token is written to JUI_TOKEN_FILE on startup. `ssj` reads it via SSH.
# The SPKI fingerprint is printed to stderr on first start.

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using JUI

# ── Parse args ─────────────────────────────────────────────────────────
port       = parse(Int, get(ENV, "JUI_PORT", "7878"))
shell      = get(ENV, "JUI_SHELL", get(ENV, "SHELL", "/bin/bash"))
token_file = expanduser(get(ENV, "JUI_TOKEN_FILE", "~/.config/jui/token"))
cmd        = [shell]

i = 1
while i <= length(ARGS)
    arg = ARGS[i]
    if arg == "--port" && i < length(ARGS)
        port = parse(Int, ARGS[i+1]); i += 2
    elseif arg == "--shell" && i < length(ARGS)
        shell = ARGS[i+1]; cmd = [shell]; i += 2
    elseif arg == "--cmd"
        cmd = ARGS[i+1:end]; break
    else
        i += 1
    end
end

# ── Model: full-screen terminal widget ─────────────────────────────────
mutable struct TermServer <: JUI.Model
    term::TerminalWidget
end

JUI.should_quit(m::TermServer) = m.term.exited

function JUI.view(m::TermServer, f::JUI.Frame)
    render(m.term, f.area, f.buffer)
end

function JUI.update!(m::TermServer, evt::JUI.Event)
    evt isa KeyEvent        && handle_key!(m.term, evt)
    evt isa MouseEvent      && handle_mouse!(m.term, evt)
    if evt isa WireResizeEvent && evt.cols > 0 && evt.rows > 0
        pty_resize!(m.term.pty, evt.rows, evt.cols)
    end
end

# ── Token ────────────────────────────────────────────────────────────────
mkpath(dirname(token_file))

# Reuse existing token if present (stable across restarts → ssj cache stays valid)
token = if isfile(token_file)
    String(strip(read(token_file, String)))
else
    t = JUI.generate_token()
    write(token_file, t)
    chmod(token_file, 0o600)
    t
end

# ── Start server ─────────────────────────────────────────────────────────
model = TermServer(TerminalWidget(cmd))
srv = run_tcp!(model, "0.0.0.0", port, token; cols=220, rows=55)

@info "jui-server started" port=port cmd=cmd token_file=token_file
println(stderr, "SPKI fingerprint: ", JUI.spki_hash(srv.transport.cert_path))
println(stderr, "Token: ", token)
println(stderr, "Connect: ssj $(gethostname()) $(port)")

# Block until shell exits
while srv.running && !model.term.exited
    sleep(1)
end

JUI.stop_session_server!(srv)
JUI.close_session!(srv.session.id)
@info "jui-server exited"
