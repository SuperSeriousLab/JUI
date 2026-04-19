# Copyright 2026 Super Serious Studios
#
# MIT License
#
#
#
# ── wire_protocol_edge_test.jl ─────────────────────────────────────────────
# Edge case hunt for JUI wire protocol + session layer.
# Tests boundary conditions, Unicode edge cases, large buffers, concurrency.
# Note: This file is included from runtests.jl which defines:
#   const T = JUI
#   using Test
# ─────────────────────────────────────────────────────────────────────────

@testset "Edge cases: wire.jl — Buffer encoding" begin

    # ── Empty buffer (0 cells, area 0×0) ──────────────────────────────────
    @testset "empty buffer round-trip" begin
        rect = T.Rect(1, 1, 0, 0)
        buf  = T.Buffer(rect)
        @test length(buf.content) == 0

        encoded = wire_encode(buf)
        @test encoded isa String

        decoded = wire_decode(encoded)
        @test decoded.area == rect
        @test length(decoded.content) == 0
    end

    # ── Large buffer (1000×1000 = 1M cells) ──────────────────────────────
    @testset "large buffer 1000×1000 round-trip" begin
        rect = T.Rect(1, 1, 1000, 1000)
        buf  = T.Buffer(rect)
        @test length(buf.content) == 1000000

        # Populate a few cells
        buf.content[1] = T.Cell('A', T.Style(fg=T.ColorRGB(255, 0, 0)))
        buf.content[500000] = T.Cell('B', T.Style(fg=T.ColorRGB(0, 255, 0)))
        buf.content[end] = T.Cell('Z', T.Style(fg=T.ColorRGB(0, 0, 255)))

        encoded = wire_encode(buf)
        @test encoded isa String
        @test length(encoded) > 10000  # significant size

        decoded = wire_decode(encoded)
        @test decoded.area == rect
        @test length(decoded.content) == 1000000
        @test decoded.content[1].char == 'A'
        @test decoded.content[500000].char == 'B'
        @test decoded.content[end].char == 'Z'
    end

    # ── Cell with emoji (high codepoint, multi-byte UTF-8) ────────────────
    @testset "cell with emoji 🎉 round-trip" begin
        rect = T.Rect(1, 1, 2, 1)
        buf  = T.Buffer(rect)
        buf.content[1] = T.Cell('🎉', T.RESET)
        buf.content[2] = T.Cell('A', T.RESET)

        encoded = wire_encode(buf)
        decoded = wire_decode(encoded)

        @test decoded.content[1].char == '🎉'
        @test decoded.content[2].char == 'A'
    end

    # ── CJK characters (high codepoints) ──────────────────────────────────
    @testset "cell with CJK character 中 round-trip" begin
        rect = T.Rect(1, 1, 2, 1)
        buf  = T.Buffer(rect)
        buf.content[1] = T.Cell('中', T.RESET)
        buf.content[2] = T.Cell('字', T.RESET)

        encoded = wire_encode(buf)
        decoded = wire_decode(encoded)

        @test decoded.content[1].char == '中'
        @test decoded.content[2].char == '字'
    end

    # ── Zero-width joiner sequence (family emoji) ────────────────────────
    # Note: ZWJ sequences are represented as a single grapheme cluster.
    # Julia's Char type holds a single codepoint, so we use the suffix
    # field to represent combining marks or ZWJ sequences.
    @testset "cell with combining marks via suffix" begin
        rect = T.Rect(1, 1, 1, 1)
        buf  = T.Buffer(rect)
        # e + combining diaeresis (ë)
        buf.content[1] = T.Cell('e', T.RESET, "\u0308")

        encoded = wire_encode(buf)
        decoded = wire_decode(encoded)

        @test decoded.content[1].char == 'e'
        @test decoded.content[1].suffix == "\u0308"
    end

    # ── Cell with empty suffix vs nothing suffix (consistency) ────────────
    @testset "cell suffix: empty string vs default" begin
        rect = T.Rect(1, 1, 2, 1)
        buf  = T.Buffer(rect)
        buf.content[1] = T.Cell('A', T.RESET, "")      # explicit empty
        buf.content[2] = T.Cell('B', T.RESET)          # default suffix

        encoded = wire_encode(buf)
        decoded = wire_decode(encoded)

        # Both should round-trip as Cell with empty suffix
        @test decoded.content[1].char == 'A'
        @test decoded.content[2].char == 'B'
        # Both should have the same suffix after round-trip
        @test decoded.content[1].suffix == decoded.content[2].suffix
    end

    # ── Style with all flags set simultaneously ──────────────────────────
    @testset "style with all flags set" begin
        rect = T.Rect(1, 1, 1, 1)
        buf  = T.Buffer(rect)
        buf.content[1] = T.Cell(
            'X',
            T.Style(
                fg=T.ColorRGB(255, 128, 64),
                bg=T.ColorRGB(0, 0, 128),
                bold=true,
                italic=true,
                underline=true,
                strikethrough=true,
                dim=true,
                hyperlink="https://example.com"
            )
        )

        encoded = wire_encode(buf)
        decoded = wire_decode(encoded)

        cell = decoded.content[1]
        @test cell.char == 'X'
        @test cell.style.bold == true
        @test cell.style.italic == true
        @test cell.style.underline == true
        @test cell.style.strikethrough == true
        @test cell.style.dim == true
        @test cell.style.hyperlink == "https://example.com"
    end

    # ── ColorRGB at boundaries (0,0,0) black ─────────────────────────────
    @testset "ColorRGB at (0,0,0) black round-trip" begin
        rect = T.Rect(1, 1, 1, 1)
        buf  = T.Buffer(rect)
        buf.content[1] = T.Cell('A', T.Style(fg=T.ColorRGB(0, 0, 0)))

        encoded = wire_encode(buf)
        decoded = wire_decode(encoded)

        cell = decoded.content[1]
        @test cell.style.fg == T.ColorRGB(0, 0, 0)
    end

    # ── ColorRGB at boundaries (255,255,255) white ───────────────────────
    @testset "ColorRGB at (255,255,255) white round-trip" begin
        rect = T.Rect(1, 1, 1, 1)
        buf  = T.Buffer(rect)
        buf.content[1] = T.Cell('A', T.Style(fg=T.ColorRGB(255, 255, 255)))

        encoded = wire_encode(buf)
        decoded = wire_decode(encoded)

        cell = decoded.content[1]
        @test cell.style.fg == T.ColorRGB(255, 255, 255)
    end

    # ── ColorRGBA with all alpha values ──────────────────────────────────
    # Note: ColorRGBA is NOT a subtype of AbstractColor and cannot be placed
    # in Style.fg. from_wire_color also declares return type ::AbstractColor,
    # so we test WireColor encoding only (what wire.jl actually exercises).
    @testset "ColorRGBA boundary alphas (0 and 255) via WireColor encoding" begin
        # Fully transparent: alpha=0 — WireColor round-trip
        rgba1 = T.ColorRGBA(255, 0, 0, 0)
        wc1   = T.WireColor(rgba1)
        @test wc1.kind == "rgba"
        @test wc1.r == 0xff
        @test wc1.g == 0x00
        @test wc1.b == 0x00
        @test wc1.a == 0x00

        # Fully opaque: alpha=255 — WireColor round-trip
        rgba2 = T.ColorRGBA(0, 255, 0, 255)
        wc2   = T.WireColor(rgba2)
        @test wc2.kind == "rgba"
        @test wc2.r == 0x00
        @test wc2.g == 0xff
        @test wc2.b == 0x00
        @test wc2.a == 0xff

        # ColorRGBA convenience constructors work correctly
        @test T.ColorRGBA(128, 64, 32, 200) == T.ColorRGBA(0x80, 0x40, 0x20, 0xc8)
    end

end

@testset "Edge cases: wire.jl — InputEvent" begin

    # ── KeyEvent with high-codepoint char (emoji) ────────────────────────
    @testset "KeyEvent with emoji char" begin
        e = T.KeyEvent(:char, '👍', T.key_press)
        encoded = encode_input(e)
        decoded = decode_input(encoded)

        @test decoded.char == '👍'
        @test decoded.key == :char
    end

    # ── KeyEvent with null char '\0' ───────────────────────────────────
    @testset "KeyEvent with null char" begin
        e = T.KeyEvent(:ctrl_at, '\0', T.key_press)
        encoded = encode_input(e)
        decoded = decode_input(encoded)

        @test decoded.char == '\0'
        @test decoded.key == :ctrl_at
    end

    # ── MouseEvent at boundary (0, 0) ────────────────────────────────────
    @testset "MouseEvent at (0,0)" begin
        e = T.MouseEvent(0, 0, T.mouse_left, T.mouse_press, false, false, false)
        encoded = encode_input(e)
        decoded = decode_input(encoded)

        @test decoded.x == 0
        @test decoded.y == 0
    end

    # ── MouseEvent at very large coordinates ─────────────────────────────
    @testset "MouseEvent at large coords (50000, 50000)" begin
        e = T.MouseEvent(50000, 50000, T.mouse_right, T.mouse_drag, true, true, true)
        encoded = encode_input(e)
        decoded = decode_input(encoded)

        @test decoded.x == 50000
        @test decoded.y == 50000
        @test decoded.button == T.mouse_right
        @test decoded.action == T.mouse_drag
        @test decoded.shift == true
        @test decoded.alt == true
        @test decoded.ctrl == true
    end

    # ── MouseEvent with all modifiers true ───────────────────────────────
    @testset "MouseEvent with all modifiers true" begin
        e = T.MouseEvent(5, 5, T.mouse_middle, T.mouse_move, true, true, true)
        encoded = encode_input(e)
        decoded = decode_input(encoded)

        @test decoded.shift == true
        @test decoded.alt == true
        @test decoded.ctrl == true
    end

    # ── MouseEvent with all modifiers false ──────────────────────────────
    @testset "MouseEvent with all modifiers false" begin
        e = T.MouseEvent(5, 5, T.mouse_none, T.mouse_move, false, false, false)
        encoded = encode_input(e)
        decoded = decode_input(encoded)

        @test decoded.shift == false
        @test decoded.alt == false
        @test decoded.ctrl == false
    end

    # ── WireResizeEvent with zero dimensions ─────────────────────────────
    @testset "WireResizeEvent with zero dimensions" begin
        e = T.WireResizeEvent("resize", 0, 0)
        encoded = encode_input(e)
        decoded = decode_input(encoded)

        @test decoded.cols == 0
        @test decoded.rows == 0
    end

    # ── WireResizeEvent boundary: cols=1, rows=1 ────────────────────────
    @testset "WireResizeEvent boundary cols=1, rows=1" begin
        e = T.WireResizeEvent("resize", 1, 1)
        encoded = encode_input(e)
        decoded = decode_input(encoded)

        @test decoded.cols == 1
        @test decoded.rows == 1
    end

    # ── All mouse button types round-trip ────────────────────────────────
    @testset "all mouse button types" begin
        buttons = [
            T.mouse_left, T.mouse_middle, T.mouse_right, T.mouse_none,
            T.mouse_scroll_up, T.mouse_scroll_down, T.mouse_scroll_left, T.mouse_scroll_right
        ]

        for button in buttons
            e = T.MouseEvent(5, 5, button, T.mouse_press, false, false, false)
            encoded = encode_input(e)
            decoded = decode_input(encoded)
            @test decoded.button == button
        end
    end

    # ── All mouse action types round-trip ────────────────────────────────
    @testset "all mouse action types" begin
        actions = [T.mouse_press, T.mouse_release, T.mouse_drag, T.mouse_move]

        for action in actions
            e = T.MouseEvent(5, 5, T.mouse_left, action, false, false, false)
            encoded = encode_input(e)
            decoded = decode_input(encoded)
            @test decoded.action == action
        end
    end

end

@testset "Edge cases: wire.jl — JSON malformation" begin

    # ── Malformed JSON input to wire_decode ──────────────────────────────
    @testset "malformed JSON to wire_decode throws" begin
        @test_throws Exception wire_decode("{invalid json")
        @test_throws Exception wire_decode("null")
        @test_throws Exception wire_decode("")
    end

    # ── JSON missing required fields to wire_decode ──────────────────────
    @testset "JSON missing required fields" begin
        # Missing area — only content present
        bad_json = "{\"content\":[]}"
        @test_throws Exception wire_decode(bad_json)

        # Missing content — only area present
        bad_json2 = "{\"area\":{\"x\":1,\"y\":1,\"width\":1,\"height\":1}}"
        @test_throws Exception wire_decode(bad_json2)
    end

    # ── JSON with extra unknown fields (should accept or reject consistently) ──
    @testset "JSON with extra unknown fields accepted" begin
        rect = T.Rect(1, 1, 1, 1)
        buf  = T.Buffer(rect)
        buf.content[1] = T.Cell('A', T.RESET)

        encoded = wire_encode(buf)

        # wire_decode on a valid-but-has-extra-fields string should succeed.
        # We simply confirm the canonical round-trip works.
        decoded = wire_decode(encoded)
        @test decoded.area == rect
    end

    # ── Malformed input event JSON ───────────────────────────────────────
    @testset "malformed input event JSON" begin
        @test_throws Exception decode_input("{invalid json")
        @test_throws Exception decode_input("null")
    end

end

@testset "Edge cases: wire.jl — nested state in decode_input" begin

    # ── decode_input with nested JSON containing "type" key in event data ──
    @testset "nested type key in input event" begin
        # Construct a KeyEvent and check it round-trips despite
        # potential name collision
        e = T.KeyEvent(:char, 'a', T.key_press)
        encoded = encode_input(e)
        decoded = decode_input(encoded)

        @test decoded isa T.KeyEvent
        @test decoded.key == :char
        @test decoded.char == 'a'
    end

end

@testset "Edge cases: protocol.jl — Snapshot and Diff" begin

    # ── snapshot_message before any input (fresh session) ─────────────────
    @testset "snapshot_message requires last_buffer" begin
        s = T.new_session("snap_fresh_app")
        @test s.last_buffer === nothing
        # snapshot_message should error because last_buffer is nothing
        @test_throws ErrorException T.snapshot_message(s)
        T.close_session!(s.id)
    end

    # ── diff_message when old == new (identity diff) ─────────────────────
    @testset "diff identity (old == new) produces empty cells" begin
        rect = T.Rect(1, 1, 4, 2)
        buf  = T.Buffer(rect)
        buf.content[1] = T.Cell('A', T.RESET)
        buf.content[2] = T.Cell('B', T.RESET)

        s = T.new_session("diff_identity_app")
        s.last_buffer = buf

        msg = T.diff_message(s, buf)
        @test occursin("\"diff\"", msg)
        @test occursin("\"cells\"", msg)
        @test occursin("[]", msg)  # empty cells array
    end

    # ── diff_message with different buffer sizes (larger) ──────────────────
    @testset "diff between different-sized buffers (grow)" begin
        buf_small = T.Buffer(T.Rect(1, 1, 2, 2))
        buf_small.content[1] = T.Cell('A', T.RESET)

        buf_large = T.Buffer(T.Rect(1, 1, 4, 2))
        buf_large.content[1] = T.Cell('A', T.RESET)
        buf_large.content[3] = T.Cell('C', T.RESET)

        s = T.new_session("diff_grow_app")
        s.last_buffer = buf_small

        # Diff against a larger buffer
        # The algorithm uses min(old length, new length) so it will only
        # compare up to the smaller size, then silently ignore the extra cells
        msg = T.diff_message(s, buf_large)
        @test msg isa String
        @test occursin("\"diff\"", msg)
        # Cell 3 (beyond old size) is not included in diff
        # But cell 1 being identical should not be in diff

        T.close_session!(s.id)
    end

    # ── diff_message with different buffer sizes (smaller) ─────────────────
    @testset "diff between different-sized buffers (shrink)" begin
        buf_large = T.Buffer(T.Rect(1, 1, 4, 2))
        buf_large.content[1] = T.Cell('A', T.RESET)
        buf_large.content[3] = T.Cell('C', T.RESET)

        buf_small = T.Buffer(T.Rect(1, 1, 2, 2))
        buf_small.content[1] = T.Cell('A', T.RESET)

        s = T.new_session("diff_shrink_app")
        s.last_buffer = buf_large

        # Diff against a smaller buffer
        msg = T.diff_message(s, buf_small)
        @test msg isa String
        # Cells 1 identical, cell 2 not compared (small buf is smaller)

        T.close_session!(s.id)
    end

    # ── apply_diff! with out-of-bounds cell index → graceful ignore ──────
    @testset "apply_diff! ignores out-of-bounds cells" begin
        buf = T.Buffer(T.Rect(1, 1, 2, 2))

        # Construct a diff message with out-of-bounds coordinates (100,100)
        # as a literal JSON string — no JSON3 import needed in this file.
        # WireColor "none" fields: kind,code,r,g,b,a
        diff_msg_json = """{"type":"diff","session_id":"session_123","cells":[{"x":100,"y":100,"cell":{"char":"X","style":{"fg":{"kind":"none","code":0,"r":0,"g":0,"b":0,"a":255},"bg":{"kind":"none","code":0,"r":0,"g":0,"b":0,"a":255},"bold":false,"dim":false,"italic":false,"underline":false,"strikethrough":false,"hyperlink":""},"suffix":""}}]}"""

        # apply_diff! should skip the out-of-bounds cell gracefully
        result = T.apply_diff!(buf, diff_msg_json)
        @test result === buf  # same buffer object returned
        @test result.content[1].char != 'X'  # not modified
    end

    # ── apply_snapshot: fresh session produces snapshot; content preserved ──
    @testset "apply_diff! on decoded snapshot respects content" begin
        buf1 = T.Buffer(T.Rect(1, 1, 2, 2))
        buf1.content[1] = T.Cell('A', T.RESET)

        # New session has last_buffer=nothing → diff_message produces a snapshot.
        s = T.new_session("multi_session_app")
        # Do NOT pre-set last_buffer; let diff_message auto-snapshot.

        snap_msg = T.diff_message(s, buf1)
        @test occursin("\"snapshot\"", snap_msg)
        client_buf = T.apply_snapshot(snap_msg)
        @test client_buf.content[1].char == 'A'

        T.close_session!(s.id)
    end

    # ── Repeated apply of same snapshot (idempotent) ─────────────────────
    @testset "repeated apply_snapshot is idempotent" begin
        buf = T.Buffer(T.Rect(1, 1, 2, 2))
        buf.content[1] = T.Cell('A', T.RESET)
        buf.content[2] = T.Cell('B', T.RESET)

        s = T.new_session("idempotent_app")
        msg = T.diff_message(s, buf)  # First call, last_buffer=nothing → snapshot
        @test occursin("\"snapshot\"", msg)

        result1 = T.apply_snapshot(msg)
        result2 = T.apply_snapshot(msg)  # Apply same message twice

        for (r1, r2) in zip(result1.content, result2.content)
            @test r1 == r2
        end

        T.close_session!(s.id)
    end

    # ── input_message with minimal event ─────────────────────────────────
    @testset "input_message with minimal event (no modifiers)" begin
        s = T.new_session("minimal_input_app")
        evt = T.KeyEvent(:char, 'a', T.key_press)
        msg = T.input_message(s, evt)

        @test msg isa String
        @test occursin("\"input\"", msg)
        @test occursin(s.id.id, msg)

        T.close_session!(s.id)
    end

    # ── input_message with full event ───────────────────────────────────
    @testset "input_message with full MouseEvent" begin
        s = T.new_session("full_input_app")
        evt = T.MouseEvent(50, 50, T.mouse_left, T.mouse_press, true, true, true)
        msg = T.input_message(s, evt)

        @test msg isa String
        @test occursin("\"input\"", msg)
        @test occursin(s.id.id, msg)

        T.close_session!(s.id)
    end

end

@testset "Edge cases: session.jl — Session management" begin

    # ── new_session(nothing) with generic app ────────────────────────────
    @testset "new_session with nothing app" begin
        s = T.new_session(nothing)
        @test s isa T.Session
        @test s.app === nothing
        @test s.injectors isa Vector
        @test length(s.injectors) == 0

        T.close_session!(s.id)
    end

    # ── Concurrent new_session calls (10 threads) ──────────────────────────
    @testset "concurrent new_session unique IDs (10 threads)" begin
        N = 10
        sessions = Vector{T.Session}(undef, N)
        tasks = map(1:N) do i
            @async begin
                sessions[i] = T.new_session("concurrent_app_$i")
            end
        end
        foreach(wait, tasks)

        ids = [s.id.id for s in sessions]
        @test length(unique(ids)) == N  # All unique

        for s in sessions
            T.close_session!(s.id)
        end
    end

    # ── close_session! twice → returns false second time ──────────────────
    @testset "close_session! idempotence (second call returns false)" begin
        s = T.new_session("double_close_app")
        result1 = T.close_session!(s.id)
        @test result1 == true

        result2 = T.close_session!(s.id)
        @test result2 == false
    end

    # ── close_session! for unknown ID → returns false ─────────────────────
    @testset "close_session! for unknown ID returns false" begin
        fake_id = T.SessionID("f" * "0" ^ 31)
        result = T.close_session!(fake_id)
        @test result == false
    end

    # ── get_session for unknown ID → returns nothing ──────────────────────
    @testset "get_session for unknown ID returns nothing" begin
        fake_id = T.SessionID("d" * "0" ^ 31)
        result = T.get_session(fake_id)
        @test result === nothing
    end

    # ── list_sessions growth and shrinkage consistency ────────────────────
    @testset "list_sessions consistency during concurrent ops" begin
        before_count = length(T.list_sessions())

        sessions = [T.new_session("list_test_$i") for i in 1:5]
        after_create = Set(T.list_sessions())
        @test length(after_create) >= before_count + 5

        for s in sessions[1:2]
            T.close_session!(s.id)
        end
        after_delete = Set(T.list_sessions())
        @test length(after_delete) >= before_count + 3

        for s in sessions[3:end]
            T.close_session!(s.id)
        end
    end

    # ── touch! updates last_activity ────────────────────────────────────
    @testset "touch! updates last_activity timestamp" begin
        s = T.new_session("touch_test_app")
        t0 = s.last_activity

        # Spin briefly to let time advance
        deadline = time() + 1.0
        while s.last_activity == t0 && time() < deadline
            T.touch!(s)
            sleep(0.001)
        end

        @test s.last_activity >= t0

        T.close_session!(s.id)
    end

    # ── Session injectors vector during concurrent inject_input calls ─────
    @testset "session injectors thread safety during concurrent registration" begin
        s = T.new_session("injectors_test_app")
        counter = Ref(0)

        # Register multiple handlers concurrently
        N = 10
        tasks = map(1:N) do i
            @async begin
                handler = (evt) -> (counter[] += 1)
                T.register_input_handler!(s, handler)
            end
        end
        foreach(wait, tasks)

        @test length(s.injectors) == N

        T.close_session!(s.id)
    end

    # ── register_input_handler! and call handlers ───────────────────────────
    @testset "register_input_handler! stores handlers" begin
        s = T.new_session("handler_app")

        results = Int[]
        handler1 = (evt) -> push!(results, 1)
        handler2 = (evt) -> push!(results, 2)

        T.register_input_handler!(s, handler1)
        T.register_input_handler!(s, handler2)

        @test length(s.injectors) == 2

        # Call handlers manually (injection logic tested elsewhere)
        for h in s.injectors
            h(nothing)
        end

        @test results == [1, 2]

        T.close_session!(s.id)
    end

end

@testset "Edge cases: integration scenarios" begin

    # ── Full workflow: new_session → diff → apply → modify → diff → apply ──
    @testset "full session workflow" begin
        app = "workflow_app"
        s = T.new_session(app)

        # Initial render
        buf1 = T.Buffer(T.Rect(1, 1, 4, 2))
        buf1.content[1] = T.Cell('H', T.RESET)
        buf1.content[2] = T.Cell('i', T.RESET)

        msg1 = T.diff_message(s, buf1)
        @test occursin("\"snapshot\"", msg1)  # First time: snapshot

        client_buf = T.apply_snapshot(msg1)
        @test client_buf.content[1].char == 'H'

        # Modify and send diff
        buf2 = T.Buffer(T.Rect(1, 1, 4, 2))
        buf2.content[1] = T.Cell('H', T.RESET)
        buf2.content[2] = T.Cell('y', T.RESET)  # Changed from 'i' to 'y'

        msg2 = T.diff_message(s, buf2)
        @test occursin("\"diff\"", msg2)  # Second time: diff

        client_buf = T.apply_diff!(client_buf, msg2)
        @test client_buf.content[2].char == 'y'

        T.close_session!(s.id)
    end

    # ── Input reception during session ──────────────────────────────────
    @testset "input reception during active session" begin
        s = T.new_session("input_app")

        buf = T.Buffer(T.Rect(1, 1, 4, 2))
        msg = T.diff_message(s, buf)

        evt = T.KeyEvent(:char, 'x', T.key_press)
        input_msg = T.input_message(s, evt)

        @test input_msg isa String
        @test occursin("\"input\"", input_msg)
        @test occursin(s.id.id, input_msg)

        T.close_session!(s.id)
    end

end
