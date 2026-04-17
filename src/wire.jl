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
# ── wire.jl ──────────────────────────────────────────────────────────────
# Phase 2a: Serializable Buffer wire format.
#
# Server-authoritative architecture: widgets never cross the wire.
# Only the Buffer (pure Cell grid) travels down to the client.
# InputEvents travel up. This module handles the Buffer direction.
#
# JSON3 StructType declarations let Cell/Style/Rect/Buffer round-trip
# through JSON3 without any custom read/write — struct fields map 1:1.
# ─────────────────────────────────────────────────────────────────────────

using JSON3
using StructTypes

# ── StructType declarations ───────────────────────────────────────────────
#
# JSON3 requires StructTypes.StructType for each type it serializes.
# AbstractColor subtypes use a tagged-union pattern: we define a wrapper
# that carries a "kind" discriminator so decode can reconstruct the correct
# concrete type.

# Rect — plain value struct, fields are all primitives
StructTypes.StructType(::Type{Rect}) = StructTypes.Struct()

# Style — fields include AbstractColor (interface type), so we need a
# concrete wire representation. We use a NamedTuple-based proxy.
# Rather than registering Style directly (AbstractColor fields confuse
# JSON3's reflection), we convert to/from a flat wire struct.

struct WireColor
    kind::String    # "none" | "256" | "rgb" | "rgba"
    code::UInt8     # Color256
    r::UInt8        # ColorRGB / ColorRGBA
    g::UInt8
    b::UInt8
    a::UInt8        # ColorRGBA only
end
StructTypes.StructType(::Type{WireColor}) = StructTypes.Struct()

WireColor(::NoColor)    = WireColor("none",  0x00, 0x00, 0x00, 0x00, 0xff)
WireColor(c::Color256)  = WireColor("256",   c.code, 0x00, 0x00, 0x00, 0xff)
WireColor(c::ColorRGB)  = WireColor("rgb",   0x00, c.r, c.g, c.b, 0xff)
WireColor(c::ColorRGBA) = WireColor("rgba",  0x00, c.r, c.g, c.b, c.a)

function from_wire_color(w::WireColor)::AbstractColor
    w.kind == "none"  && return NoColor()
    w.kind == "256"   && return Color256(w.code)
    w.kind == "rgb"   && return ColorRGB(w.r, w.g, w.b)
    w.kind == "rgba"  && return ColorRGBA(w.r, w.g, w.b, w.a)
    error("unknown WireColor kind: $(w.kind)")
end

struct WireStyle
    fg::WireColor
    bg::WireColor
    bold::Bool
    dim::Bool
    italic::Bool
    underline::Bool
    strikethrough::Bool
    hyperlink::String
end
StructTypes.StructType(::Type{WireStyle}) = StructTypes.Struct()

WireStyle(s::Style) = WireStyle(
    WireColor(s.fg), WireColor(s.bg),
    s.bold, s.dim, s.italic, s.underline, s.strikethrough, s.hyperlink,
)

from_wire_style(w::WireStyle) = Style(
    from_wire_color(w.fg), from_wire_color(w.bg),
    w.bold, w.dim, w.italic, w.underline, w.strikethrough, w.hyperlink,
)

struct WireCell
    char::String    # single grapheme cluster (Char → String for JSON safety)
    style::WireStyle
    suffix::String
end
StructTypes.StructType(::Type{WireCell}) = StructTypes.Struct()

WireCell(c::Cell) = WireCell(string(c.char), WireStyle(c.style), c.suffix)

from_wire_cell(w::WireCell) = Cell(
    only(w.char),           # String → Char (single codepoint guaranteed by encoder)
    from_wire_style(w.style),
    w.suffix,
)

struct WireBuffer
    area::Rect
    content::Vector{WireCell}
end
StructTypes.StructType(::Type{WireBuffer}) = StructTypes.Struct()

WireBuffer(buf::Buffer) = WireBuffer(buf.area, WireCell.(buf.content))

from_wire_buffer(w::WireBuffer) = Buffer(w.area, from_wire_cell.(w.content))

# ── Public API ────────────────────────────────────────────────────────────

"""
    wire_encode(buf::Buffer) → String

Serialize a Buffer to a JSON string for transport to the client.
The client receives only data — no widget state, no server objects.
"""
function wire_encode(buf::Buffer)::String
    JSON3.write(WireBuffer(buf))
end

"""
    wire_decode(s::String) → Buffer

Deserialize a JSON string produced by `wire_encode` back to a Buffer.
"""
function wire_decode(s::String)::Buffer
    w = JSON3.read(s, WireBuffer)
    from_wire_buffer(w)
end
