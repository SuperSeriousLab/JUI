# Copyright 2026 eidos workspace
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# ── wire_test.jl ─────────────────────────────────────────────────────────
# Phase 2a: Round-trip test for Buffer wire format.
#
# Verifies that wire_encode → wire_decode produces a Buffer equal to the
# original. Tests cells with different colors (NoColor, Color256, ColorRGB,
# ColorRGBA), different style flags, and a cell with a suffix.
# ─────────────────────────────────────────────────────────────────────────

@testset "Phase 2a: wire round-trip" begin
    rect = T.Rect(1, 1, 4, 2)
    buf  = T.Buffer(rect)

    # Cell 1: plain 'A' with default style
    buf.content[1] = T.Cell('A', T.RESET)

    # Cell 2: 'B' with Color256 fg + bold
    buf.content[2] = T.Cell('B', Style(fg=Color256(196), bold=true))

    # Cell 3: 'C' with ColorRGB fg + ColorRGB bg + italic
    buf.content[3] = T.Cell('C', Style(fg=T.ColorRGB(0x00, 0xff, 0x80),
                                     bg=T.ColorRGB(0x10, 0x10, 0x30),
                                     italic=true))

    # Cell 4: 'D' with ColorRGB fg + underline + strikethrough
    buf.content[4] = T.Cell('D', Style(fg=T.ColorRGB(0xff, 0xd7, 0x00),
                                     underline=true, strikethrough=true))

    # Cell 5: 'E' with hyperlink
    buf.content[5] = T.Cell('E', Style(hyperlink="https://eidos.local"))

    # Cell 6: wide-char pad sentinel
    buf.content[6] = T.Cell(T.WIDE_CHAR_PAD, T.RESET)

    # Cell 7: cell with a suffix (combining mark simulation)
    buf.content[7] = T.Cell('f', Style(dim=true), "\u0301")  # f + combining acute

    # Encode + decode
    encoded = wire_encode(buf)
    @test encoded isa String
    @test length(encoded) > 10  # sanity: not empty

    decoded = wire_decode(encoded)

    # Area must be identical
    @test decoded.area == buf.area

    # Content length must match
    @test length(decoded.content) == length(buf.content)

    # Each cell must round-trip exactly
    for (i, (orig, got)) in enumerate(zip(buf.content, decoded.content))
        if orig != got
            @info "cell[$i] mismatch" orig got
        end
        @test orig == got
    end
end

# ── Phase 2a: InputEvent wire serialization ───────────────────────────────

@testset "Phase 2a: KeyEvent wire round-trip" begin
    # key_press with a printable char
    e1 = T.KeyEvent(:char, 'a', T.key_press)
    s1 = encode_input(e1)
    @test s1 isa String
    @test occursin("\"key\"", s1)
    r1 = decode_input(s1)
    @test r1 isa T.KeyEvent
    @test r1.key    == e1.key
    @test r1.char   == e1.char
    @test r1.action == e1.action

    # key_repeat with a special symbol
    e2 = T.KeyEvent(:up, '\0', T.key_repeat)
    r2 = decode_input(encode_input(e2))
    @test r2 isa T.KeyEvent
    @test r2.key    == :up
    @test r2.char   == '\0'
    @test r2.action == T.key_repeat

    # key_release with a control key
    e3 = T.KeyEvent(:ctrl_c, '\0', T.key_release)
    r3 = decode_input(encode_input(e3))
    @test r3 isa T.KeyEvent
    @test r3.key    == :ctrl_c
    @test r3.action == T.key_release

    # Unicode char (non-ASCII)
    e4 = T.KeyEvent(:char, '€', T.key_press)
    r4 = decode_input(encode_input(e4))
    @test r4 isa T.KeyEvent
    @test r4.char == '€'

    # Escape key
    e5 = T.KeyEvent(:escape)
    r5 = decode_input(encode_input(e5))
    @test r5 isa T.KeyEvent
    @test r5.key == :escape
    @test r5.action == T.key_press
end

@testset "Phase 2a: MouseEvent wire round-trip" begin
    # Left button press with modifiers
    e1 = T.MouseEvent(10, 5, T.mouse_left, T.mouse_press, true, false, true)
    s1 = encode_input(e1)
    @test s1 isa String
    @test occursin("\"mouse\"", s1)
    r1 = decode_input(s1)
    @test r1 isa T.MouseEvent
    @test r1.x      == 10
    @test r1.y      == 5
    @test r1.button == T.mouse_left
    @test r1.action == T.mouse_press
    @test r1.shift  == true
    @test r1.alt    == false
    @test r1.ctrl   == true

    # Scroll up (no modifiers)
    e2 = T.MouseEvent(1, 1, T.mouse_scroll_up, T.mouse_press, false, false, false)
    r2 = decode_input(encode_input(e2))
    @test r2 isa T.MouseEvent
    @test r2.button == T.mouse_scroll_up

    # Right button drag
    e3 = T.MouseEvent(20, 12, T.mouse_right, T.mouse_drag, false, true, false)
    r3 = decode_input(encode_input(e3))
    @test r3 isa T.MouseEvent
    @test r3.button == T.mouse_right
    @test r3.action == T.mouse_drag
    @test r3.alt    == true

    # Move with no button
    e4 = T.MouseEvent(3, 7, T.mouse_none, T.mouse_move, false, false, false)
    r4 = decode_input(encode_input(e4))
    @test r4 isa T.MouseEvent
    @test r4.button == T.mouse_none
    @test r4.action == T.mouse_move

    # Release: middle button
    e5 = T.MouseEvent(40, 20, T.mouse_middle, T.mouse_release, false, false, false)
    r5 = decode_input(encode_input(e5))
    @test r5 isa T.MouseEvent
    @test r5.button == T.mouse_middle
    @test r5.action == T.mouse_release
end

@testset "Phase 2a: WireResizeEvent wire round-trip" begin
    e1 = T.WireResizeEvent("resize", 220, 50)
    s1 = encode_input(e1)
    @test s1 isa String
    @test occursin("\"resize\"", s1)
    r1 = decode_input(s1)
    @test r1 isa T.WireResizeEvent
    @test r1.cols == 220
    @test r1.rows == 50
    @test r1.type == "resize"

    # Minimal terminal
    e2 = T.WireResizeEvent("resize", 80, 24)
    r2 = decode_input(encode_input(e2))
    @test r2 isa T.WireResizeEvent
    @test r2.cols == 80
    @test r2.rows == 24
end

@testset "Phase 2a: decode_input discriminator" begin
    # Unknown type must throw
    @test_throws ErrorException decode_input("{\"type\":\"unknown\"}")

    # Missing type must throw
    @test_throws Exception decode_input("{\"key\":\"a\"}")
end
