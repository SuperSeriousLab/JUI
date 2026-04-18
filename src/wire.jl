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
# Phase 2a: Serializable Buffer wire format + InputEvent wire format.
#
# Server-authoritative architecture: widgets never cross the wire.
# Only the Buffer (pure Cell grid) travels DOWN to the client.
# InputEvents travel UP from the client to the server.
#
# JSON3 StructType declarations let Cell/Style/Rect/Buffer round-trip
# through JSON3 without any custom read/write — struct fields map 1:1.
#
# InputEvent direction (client → server):
#   KeyEvent   → WireKeyEvent   (type = "key")
#   MouseEvent → WireMouseEvent (type = "mouse")
#   Resize     → WireResizeEvent (type = "resize") — terminal geometry change
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

# ── InputEvent wire format ────────────────────────────────────────────────
#
# Enums (KeyAction, MouseButton, MouseAction) are stored as their string
# names so the wire format is self-describing and survives enum reorderings.
#
# Tagged-union: each wire struct carries a `type` discriminator string.
#   "key"    → WireKeyEvent
#   "mouse"  → WireMouseEvent
#   "resize" → WireResizeEvent
#
# encode_input / decode_input are the public entry points.

# ── Enum ↔ String helpers ─────────────────────────────────────────────────

_key_action_to_str(a::KeyAction) =
    a == key_press   ? "press"   :
    a == key_repeat  ? "repeat"  : "release"

function _str_to_key_action(s::AbstractString)
    s == "press"   && return key_press
    s == "repeat"  && return key_repeat
    s == "release" && return key_release
    error("unknown KeyAction: $s")
end

_mouse_button_to_str(b::MouseButton) =
    b == mouse_left         ? "left"         :
    b == mouse_middle       ? "middle"       :
    b == mouse_right        ? "right"        :
    b == mouse_none         ? "none"         :
    b == mouse_scroll_up    ? "scroll_up"    :
    b == mouse_scroll_down  ? "scroll_down"  :
    b == mouse_scroll_left  ? "scroll_left"  : "scroll_right"

function _str_to_mouse_button(s::AbstractString)
    s == "left"         && return mouse_left
    s == "middle"       && return mouse_middle
    s == "right"        && return mouse_right
    s == "none"         && return mouse_none
    s == "scroll_up"    && return mouse_scroll_up
    s == "scroll_down"  && return mouse_scroll_down
    s == "scroll_left"  && return mouse_scroll_left
    s == "scroll_right" && return mouse_scroll_right
    error("unknown MouseButton: $s")
end

_mouse_action_to_str(a::MouseAction) =
    a == mouse_press   ? "press"   :
    a == mouse_release ? "release" :
    a == mouse_drag    ? "drag"    : "move"

function _str_to_mouse_action(s::AbstractString)
    s == "press"   && return mouse_press
    s == "release" && return mouse_release
    s == "drag"    && return mouse_drag
    s == "move"    && return mouse_move
    error("unknown MouseAction: $s")
end

# ── WireKeyEvent ──────────────────────────────────────────────────────────

struct WireKeyEvent
    type::String      # always "key"
    key::String       # Symbol name
    char::Int32       # Char as codepoint (JSON-safe integer)
    action::String    # KeyAction name
end
StructTypes.StructType(::Type{WireKeyEvent}) = StructTypes.Struct()

to_wire(e::KeyEvent) = WireKeyEvent("key", string(e.key), Int32(e.char), _key_action_to_str(e.action))

from_wire(w::WireKeyEvent) = KeyEvent(Symbol(w.key), Char(w.char), _str_to_key_action(w.action))

# ── WireMouseEvent ────────────────────────────────────────────────────────

struct WireMouseEvent
    type::String      # always "mouse"
    x::Int
    y::Int
    button::String    # MouseButton name
    action::String    # MouseAction name
    shift::Bool
    alt::Bool
    ctrl::Bool
end
StructTypes.StructType(::Type{WireMouseEvent}) = StructTypes.Struct()

to_wire(e::MouseEvent) = WireMouseEvent(
    "mouse", e.x, e.y,
    _mouse_button_to_str(e.button),
    _mouse_action_to_str(e.action),
    e.shift, e.alt, e.ctrl,
)

from_wire(w::WireMouseEvent) = MouseEvent(
    w.x, w.y,
    _str_to_mouse_button(w.button),
    _str_to_mouse_action(w.action),
    w.shift, w.alt, w.ctrl,
)

# ── WireResizeEvent ───────────────────────────────────────────────────────
# Resize is not a Julia struct in the events.jl hierarchy (the terminal
# handles it internally via check_resize!), but over the wire a remote
# client must be able to notify the server of a geometry change.

struct WireResizeEvent
    type::String   # always "resize"
    cols::Int
    rows::Int
end
StructTypes.StructType(::Type{WireResizeEvent}) = StructTypes.Struct()

# ── Public helpers ────────────────────────────────────────────────────────

"""
    encode_input(evt) → String

Serialize a `KeyEvent`, `MouseEvent`, or `WireResizeEvent` to a JSON string
for transport from the client to the server.

The JSON object carries a `type` discriminator field:
- `"key"`    — `KeyEvent`
- `"mouse"`  — `MouseEvent`
- `"resize"` — terminal geometry notification (use `WireResizeEvent` directly)
"""
function encode_input(e::KeyEvent)::String
    JSON3.write(to_wire(e))
end

function encode_input(e::MouseEvent)::String
    JSON3.write(to_wire(e))
end

function encode_input(e::WireResizeEvent)::String
    JSON3.write(e)
end

"""
    decode_input(s::String) → KeyEvent | MouseEvent | WireResizeEvent

Deserialize a JSON string produced by `encode_input`.  Reads the `type`
discriminator and returns the matching concrete type.
"""
function decode_input(s::String)
    obj = JSON3.read(s)
    t = get(obj, :type, nothing)
    t == "key"    && return from_wire(JSON3.read(s, WireKeyEvent))
    t == "mouse"  && return from_wire(JSON3.read(s, WireMouseEvent))
    t == "resize" && return JSON3.read(s, WireResizeEvent)
    error("decode_input: unknown event type $(repr(t))")
end

# ── Auth handshake wire types (Phase 3 chunk 3b) ──────────────────────────
# One-shot auth envelope exchanged BEFORE any session Buffer/InputEvent traffic.
# Direction:
#   Client → Server : WireAuthMessage    {"type":"auth","token":"<base64url>"}
#   Server → Client : WireAuthOkMessage  {"type":"auth_ok","session":"<sid>"}
#                     [or server closes — no error message, no oracle]

"""
    WireAuthMessage

Client→Server auth handshake message. Sent as a single newline-terminated JSON
line immediately after TLS handshake completes.

Fields:
- `type`  — always `"auth"`
- `token` — base64url-encoded bearer token (generated by `generate_token()`)
"""
struct WireAuthMessage
    type::String    # "auth"
    token::String
end
StructTypes.StructType(::Type{WireAuthMessage}) = StructTypes.Struct()

"""
    WireAuthOkMessage

Server→Client auth success reply. Sent as a single newline-terminated JSON line
on successful token verification. Server closes connection without reply on
failure (deny-by-default, no oracle).

Fields:
- `type`    — always `"auth_ok"`
- `session` — the server's session ID string
"""
struct WireAuthOkMessage
    type::String    # "auth_ok"
    session::String
end
StructTypes.StructType(::Type{WireAuthOkMessage}) = StructTypes.Struct()
