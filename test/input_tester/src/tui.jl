# ═══════════════════════════════════════════════════════════════════════════════
# Input Tester TUI — displays all keyboard/mouse events in real time
# ═══════════════════════════════════════════════════════════════════════════════

const MAX_HISTORY = 200

struct EventRecord
    count::Int
    event::JUI.Event
    summary::String
end

@kwdef mutable struct InputTesterModel <: JUI.Model
    quit::Bool = false
    tick::Int = 0
    events::Vector{EventRecord} = EventRecord[]
    count::Int = 0
    scroll::Int = 0
    kitty::Bool = false
    terminal_size::Tuple{Int,Int} = (0, 0)
end

JUI.should_quit(m::InputTesterModel) = m.quit
JUI.handle_all_key_actions(::InputTesterModel) = true

function JUI.init!(m::InputTesterModel, t::JUI.Terminal)
    m.kitty = t.kitty_keyboard
    m.terminal_size = (t.size.width, t.size.height)
end

# ── Event summarization ──────────────────────────────────────────────────────

function summarize_event(evt::JUI.KeyEvent)
    parts = String[]
    push!(parts, "KEY")
    if evt.key == :char
        c = evt.char
        if c == ' '
            push!(parts, "<space>")
        elseif isprint(c)
            push!(parts, "'$(c)'")
        else
            push!(parts, "0x$(string(Int(c), base=16, pad=2))")
        end
    elseif evt.key == :ctrl
        push!(parts, "ctrl+$(evt.char)")
    else
        push!(parts, string(evt.key))
    end
    push!(parts, string(evt.action))
    join(parts, "  ")
end

function summarize_event(evt::JUI.MouseEvent)
    "MOUSE  $(evt.button) $(evt.action)  ($(evt.x),$(evt.y))" *
    (evt.shift ? " +shift" : "") *
    (evt.alt ? " +alt" : "") *
    (evt.ctrl ? " +ctrl" : "")
end

summarize_event(evt) = "EVENT  " * repr(evt)

# ── Update ───────────────────────────────────────────────────────────────────

function JUI.update!(m::InputTesterModel, evt::JUI.Event)
    m.count += 1
    summary = summarize_event(evt)
    push!(m.events, EventRecord(m.count, evt, summary))
    while length(m.events) > MAX_HISTORY
        popfirst!(m.events)
    end
    # Auto-scroll to bottom
    m.scroll = max(0, length(m.events))
    # Scroll controls
    if evt isa JUI.KeyEvent
        if evt.key == :pageup
            m.scroll = max(0, m.scroll - 10)
        elseif evt.key == :pagedown
            m.scroll += 10
        end
    end
end

# ── View ─────────────────────────────────────────────────────────────────────

function JUI.view(m::InputTesterModel, f::JUI.Frame)
    m.tick += 1
    buf = f.buffer

    inner = JUI.render(JUI.Block(title="Input Tester",
        border_style=JUI.tstyle(:border)), f.area, buf)

    rows = JUI.split_layout(JUI.Layout(JUI.Vertical,
        [JUI.Fixed(3), JUI.Fixed(1), JUI.Fill(), JUI.Fixed(1)]), inner)
    length(rows) < 4 && return

    header_area, sep_area, log_area, footer_area = rows[1], rows[2], rows[3], rows[4]

    _render_header(buf, header_area, m)
    JUI.render(JUI.Separator(), sep_area, buf)
    _render_log(buf, log_area, m)
    _render_footer(buf, footer_area, m)
end

function _render_header(buf, area, m::InputTesterModel)
    cols = JUI.split_layout(JUI.Layout(JUI.Horizontal,
        [JUI.Percent(35), JUI.Fill()]), area)
    length(cols) < 2 && return
    left, right = cols[1], cols[2]

    # Protocol status
    kitty_label = m.kitty ? "Kitty ON" : "Kitty OFF"
    kitty_style = m.kitty ? JUI.tstyle(:success, bold=true) : JUI.tstyle(:warning)
    JUI.set_string!(buf, left.x, left.y, "Protocol: ", JUI.tstyle(:text_dim))
    JUI.set_string!(buf, left.x + 10, left.y, kitty_label, kitty_style)
    JUI.set_string!(buf, left.x, left.y + 1, "Events: $(m.count)", JUI.tstyle(:accent))
    JUI.set_string!(buf, left.x, left.y + 2,
        "Size: $(m.terminal_size[1])×$(m.terminal_size[2])", JUI.tstyle(:text_dim, dim=true))

    # Latest event detail
    if !isempty(m.events)
        rec = m.events[end]
        evt = rec.event
        JUI.set_string!(buf, right.x, right.y,
            "Latest (#$(rec.count)):", JUI.tstyle(:primary, bold=true))
        if evt isa JUI.KeyEvent
            line2 = "key=:$(evt.key)  char='$(evt.char)' ($(Int(evt.char)))  action=$(evt.action)"
            JUI.set_string!(buf, right.x, right.y + 1, line2, JUI.tstyle(:accent))
        elseif evt isa JUI.MouseEvent
            line2 = "btn=$(evt.button) act=$(evt.action) pos=($(evt.x),$(evt.y))"
            mods = (evt.shift ? "shift " : "") * (evt.alt ? "alt " : "") * (evt.ctrl ? "ctrl" : "")
            JUI.set_string!(buf, right.x, right.y + 1, line2, JUI.tstyle(:accent))
            !isempty(strip(mods)) && JUI.set_string!(buf, right.x, right.y + 2,
                "mods: $mods", JUI.tstyle(:text_dim))
        end
    else
        JUI.set_string!(buf, right.x, right.y,
            "Press any key...", JUI.tstyle(:text_dim, dim=true))
    end
end

function _render_log(buf, area, m::InputTesterModel)
    h = area.height
    h <= 0 && return
    n = length(m.events)
    visible_end = min(n, m.scroll)
    visible_start = max(1, visible_end - h + 1)

    for (row, idx) in enumerate(visible_start:visible_end)
        row > h && break
        rec = m.events[idx]
        evt = rec.event

        num_str = lpad(string(rec.count), 4) * " "
        JUI.set_string!(buf, area.x, area.y + row - 1, num_str,
            JUI.tstyle(:text_dim, dim=true))

        action_style = if evt isa JUI.KeyEvent
            if evt.action == JUI.key_press
                JUI.tstyle(:success)
            elseif evt.action == JUI.key_repeat
                JUI.tstyle(:warning)
            else
                JUI.tstyle(:error)
            end
        else
            JUI.tstyle(:accent)
        end

        summary = rec.summary
        max_w = area.width - 6
        if length(summary) > max_w
            summary = summary[1:max_w]
        end
        JUI.set_string!(buf, area.x + 5, area.y + row - 1, summary, action_style)
    end
end

function _render_footer(buf, area, m::InputTesterModel)
    JUI.render(JUI.StatusBar(
        left=[
            JUI.Span("  PgUp/PgDn ", JUI.tstyle(:accent)),
            JUI.Span("scroll  ", JUI.tstyle(:text_dim)),
        ],
        right=[
            JUI.Span("press=", JUI.tstyle(:text_dim)),
            JUI.Span("green ", JUI.tstyle(:success)),
            JUI.Span("repeat=", JUI.tstyle(:text_dim)),
            JUI.Span("yellow ", JUI.tstyle(:warning)),
            JUI.Span("release=", JUI.tstyle(:text_dim)),
            JUI.Span("red ", JUI.tstyle(:error)),
            JUI.Span(" Ctrl+C quit ", JUI.tstyle(:text_dim, dim=true)),
        ]
    ), area, buf)
end
