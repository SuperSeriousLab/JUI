module JUIColorTypesExt

using JUI
using ColorTypes
using ColorTypes.FixedPointNumbers: N0f8

# ColorTypes → JUI
JUI.to_rgb(c::RGB{N0f8}) =
    JUI.ColorRGB(reinterpret(UInt8, red(c)), reinterpret(UInt8, green(c)), reinterpret(UInt8, blue(c)))
JUI.to_rgb(c::RGB) =
    JUI.ColorRGB(round(UInt8, Float64(red(c)) * 255), round(UInt8, Float64(green(c)) * 255), round(UInt8, Float64(blue(c)) * 255))

JUI.to_rgba(c::RGBA{N0f8}) =
    JUI.ColorRGBA(reinterpret(UInt8, red(c)), reinterpret(UInt8, green(c)), reinterpret(UInt8, blue(c)), reinterpret(UInt8, alpha(c)))
JUI.to_rgba(c::RGBA) =
    JUI.ColorRGBA(round(UInt8, Float64(red(c)) * 255), round(UInt8, Float64(green(c)) * 255), round(UInt8, Float64(blue(c)) * 255), round(UInt8, Float64(alpha(c)) * 255))
JUI.to_rgba(c::RGB{N0f8}) = JUI.ColorRGBA(JUI.to_rgb(c))
JUI.to_rgba(c::RGB) = JUI.ColorRGBA(JUI.to_rgb(c))

# JUI → ColorTypes
JUI.to_colortype(c::JUI.ColorRGB) =
    RGB{N0f8}(reinterpret(N0f8, c.r), reinterpret(N0f8, c.g), reinterpret(N0f8, c.b))
JUI.to_colortype(c::JUI.ColorRGBA) =
    RGBA{N0f8}(reinterpret(N0f8, c.r), reinterpret(N0f8, c.g), reinterpret(N0f8, c.b), reinterpret(N0f8, c.a))

end
