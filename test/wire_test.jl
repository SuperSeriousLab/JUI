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
    rect = Rect(1, 1, 4, 2)
    buf  = Buffer(rect)

    # Cell 1: plain 'A' with default style
    buf.content[1] = Cell('A', RESET)

    # Cell 2: 'B' with Color256 fg + bold
    buf.content[2] = Cell('B', Style(fg=Color256(196), bold=true))

    # Cell 3: 'C' with ColorRGB fg + ColorRGB bg + italic
    buf.content[3] = Cell('C', Style(fg=ColorRGB(0x00, 0xff, 0x80),
                                     bg=ColorRGB(0x10, 0x10, 0x30),
                                     italic=true))

    # Cell 4: 'D' with ColorRGBA fg + underline + strikethrough
    buf.content[4] = Cell('D', Style(fg=ColorRGBA(0xff, 0xd7, 0x00, 0xcc),
                                     underline=true, strikethrough=true))

    # Cell 5: 'E' with hyperlink
    buf.content[5] = Cell('E', Style(hyperlink="https://eidos.local"))

    # Cell 6: wide-char pad sentinel
    buf.content[6] = Cell(JUI.WIDE_CHAR_PAD, RESET)

    # Cell 7: cell with a suffix (combining mark simulation)
    buf.content[7] = Cell('f', Style(dim=true), "\u0301")  # f + combining acute

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
        @test orig == got  "cell[$i] mismatch: orig=$orig got=$got"
    end
end
