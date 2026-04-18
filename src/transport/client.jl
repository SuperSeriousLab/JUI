# Copyright 2026 eidos workspace
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# ── transport/client.jl ──────────────────────────────────────────────────
# Thin remote client: connect_tcp → receive snapshot/diffs → render to
# the local terminal via ANSI escape sequences. Forwards keyboard input up.
#
# Usage:
#   JUI.run_client("192.168.14.30", 7878, token; cols=220, rows=50)
#
# The token is printed by run_tcp! on the server when it starts.
# On first connect the SPKI cert is pinned (TOFU); subsequent connects
# verify it. Pin is stored in ~/.config/jui/spki_pins/.
# ─────────────────────────────────────────────────────────────────────────

import JSON3

export run_client

function _send_resize(ssl, rows::Int, cols::Int)
    msg = JSON3.write(WireInputMessage("input", "", encode_input(WireResizeEvent("resize", cols, rows)))) * "\n"
    try; write(ssl, msg); catch; end
end

# Copy all cells from src into dst. Both must have the same area dimensions.
function _copy_buf!(dst::Buffer, src::Buffer)
    n = min(length(dst.content), length(src.content))
    copyto!(dst.content, 1, src.content, 1, n)
    # Clear any extra cells if dst is larger
    for i in (n + 1):length(dst.content)
        dst.content[i] = Cell()
    end
end

"""
    run_client(host, port, token; cols=80, rows=24, mouse=true)

Connect to a JUI TCP+TLS session server at `host:port` using `token`.

Renders the remote session to the local terminal using ANSI escape sequences.
Keyboard (and optionally mouse) input is forwarded to the server.

Press Ctrl+C to disconnect.

First connection pins the server's SPKI fingerprint (TOFU). Subsequent
connections verify it — a mismatch aborts with `AuthError`.
"""
function run_client(host::String, port::Int, token::String;
                    cols::Int = 0, rows::Int = 0, mouse::Bool = true)
    # Detect terminal size if not specified
    if cols == 0 || rows == 0
        sz = terminal_size()
        cols = cols == 0 ? sz.cols : cols
        rows = rows == 0 ? sz.rows : rows
    end

    # Auth + TLS
    ssl = connect_tcp(host, port, token)

    # Send client terminal size immediately — server adapts its render rect
    _send_resize(ssl, rows, cols)

    # Read initial snapshot (server re-renders at client size before sending)
    snap_line = _ssl_readline(ssl)
    if isempty(snap_line)
        try; close(ssl); catch; end
        error("run_client: server closed connection before sending snapshot")
    end
    client_buf = apply_snapshot(snap_line)

    # Use server's buffer dimensions (reflects the resize we just sent)
    cols = client_buf.area.width
    rows = client_buf.area.height

    # Enter alt screen, hide cursor, raw mode
    io = stdout
    print(io, ALT_SCREEN_ON, CURSOR_HIDE, CLEAR_SCREEN)
    mouse && print(io, MOUSE_ON)
    flush(io)
    set_raw_mode!(true)

    # Double-buffered Terminal for diffed ANSI output
    t = Terminal(; io, size=(rows=rows, cols=cols))

    # Paint initial snapshot (prev buffer is blank → full repaint)
    _copy_buf!(current_buf(t), client_buf)
    print(io, SYNC_START)
    flush!(t, io)
    print(io, SYNC_END)
    flush(io)
    swap_buffers!(t)

    quit_ch = Channel{Nothing}(1)

    # Input task: poll local stdin → encode → send to server
    input_task = @async begin
        try
            while !isready(quit_ch) && isopen(ssl)
                evt = poll_event(0.05)
                evt === nothing && continue
                if evt isa KeyEvent && evt.key == :ctrl_c
                    put!(quit_ch, nothing)
                    break
                end
                if evt isa KeyEvent || evt isa MouseEvent
                    # session_id not validated server-side; empty string is fine
                    msg = JSON3.write(WireInputMessage("input", "", encode_input(evt))) * "\n"
                    write(ssl, msg)
                end
            end
        catch
        end
    end

    # SIGWINCH: forward terminal resize to server
    Base.Sys.iswindows() || Base.signal_handle(Base.SIGWINCH) do
        sz = terminal_size()
        _send_resize(ssl, sz.rows, sz.cols)
    end

    # Diff receive loop: apply diffs, repaint
    try
        while isopen(ssl) && !isready(quit_ch)
            line = _ssl_readline(ssl)
            isempty(line) && break
            client_buf = apply_diff!(client_buf, line)
            # Resize local terminal object if server sent a new snapshot at new size
            new_cols = client_buf.area.width
            new_rows = client_buf.area.height
            if new_cols != cols || new_rows != rows
                cols = new_cols
                rows = new_rows
                t = Terminal(; io, size=(rows=rows, cols=cols))
                print(io, CLEAR_SCREEN)
            end
            _copy_buf!(current_buf(t), client_buf)
            print(io, SYNC_START)
            flush!(t, io)
            print(io, SYNC_END)
            flush(io)
            swap_buffers!(t)
        end
    finally
        isready(quit_ch) || put!(quit_ch, nothing)
        try; close(ssl); catch; end
        set_raw_mode!(false)
        mouse && print(io, MOUSE_OFF)
        print(io, CURSOR_SHOW, ALT_SCREEN_OFF)
        flush(io)
    end

    wait(input_task)
    nothing
end
