module JUI

using FRANK
using Dates

export App, Component, InputComponent, OutputComponent, StatusBar, HistoryPanel
export render!, render_screen!, handle_input!, run!
export term_size, clear_screen!, move_cursor!, set_color!, reset_color!
export append_output!, update_status!

"""JUI v0.1 — Julia TUI framework with native FRANK debug emission.
AI-agent-debuggable by construction: every state change emits a FRANK event."""

# ── ANSI escape codes ─────────────────────────────────────────────────

const ESC = "\e"
const CSI = "\e["

# Named color map → ANSI 256-color codes
# Amber/orange on dark grey palette
const COLORS = Dict{Symbol,Int}(
    :black       => 0,
    :red         => 1,
    :green       => 2,
    :yellow      => 3,
    :blue        => 4,
    :magenta     => 5,
    :cyan        => 6,
    :white       => 7,
    :amber       => 208,   # orange/amber — workspace aesthetic
    :dark_amber  => 172,
    :bright_amber=> 214,
    :dark_grey   => 236,
    :mid_grey    => 240,
    :light_grey  => 248,
    :orange      => 202,
)

# ── Component types ────────────────────────────────────────────────────

abstract type Component end

mutable struct InputComponent <: Component
    buffer::String
    cursor::Int
    prompt::String
end

mutable struct OutputComponent <: Component
    lines::Vector{String}
    max_lines::Int
end

mutable struct StatusBar <: Component
    mode::String          # "caveman" | "normal" | "verbose" | "debug"
    model::String
    wiq_score::Float64
    confidence::Float64
end

mutable struct HistoryPanel <: Component
    entries::Vector{Dict{String,Any}}  # {input, output, confidence, ts}
    max_entries::Int
    scroll_offset::Int
end

mutable struct App
    input::InputComponent
    output::OutputComponent
    status::StatusBar
    history::HistoryPanel
    frank::FrankEmitter
    running::Bool
end

function App(; model::String="unknown", mode::String="caveman")
    App(
        InputComponent("", 0, "igor> "),
        OutputComponent(String[], 100),
        StatusBar(mode, model, 0.0, 0.0),
        HistoryPanel(Dict{String,Any}[], 500, 0),
        FrankEmitter(),
        false
    )
end

# ── Terminal utilities ─────────────────────────────────────────────────

"""Get terminal size as (rows, cols). Falls back to (24, 80)."""
function term_size()
    try
        # Try tput first — portable across systems
        rows_str = strip(read(`tput lines`, String))
        cols_str = strip(read(`tput cols`, String))
        rows = parse(Int, rows_str)
        cols = parse(Int, cols_str)
        return (rows, cols)
    catch
        # Try LINES/COLUMNS env vars
        try
            rows = parse(Int, get(ENV, "LINES", "24"))
            cols = parse(Int, get(ENV, "COLUMNS", "80"))
            return (rows, cols)
        catch
            return (24, 80)
        end
    end
end

"""Clear entire screen and move cursor to top-left."""
function clear_screen!()
    print(stdout, CSI, "2J", CSI, "H")
    flush(stdout)
end

"""Move cursor to (row, col). 1-indexed."""
function move_cursor!(row::Int, col::Int)
    print(stdout, CSI, row, ";", col, "H")
end

"""Set foreground color by name or 256-color index."""
function set_color!(; fg::Union{Symbol,Int,Nothing}=nothing,
                      bg::Union{Symbol,Int,Nothing}=nothing)
    if fg !== nothing
        code = fg isa Symbol ? get(COLORS, fg, 7) : fg
        if code < 8
            print(stdout, CSI, 30 + code, "m")
        else
            print(stdout, CSI, "38;5;", code, "m")
        end
    end
    if bg !== nothing
        code = bg isa Symbol ? get(COLORS, bg, 0) : bg
        if code < 8
            print(stdout, CSI, 40 + code, "m")
        else
            print(stdout, CSI, "48;5;", code, "m")
        end
    end
end

"""Reset all ANSI attributes."""
function reset_color!()
    print(stdout, CSI, "0m")
end

"""Print bold text."""
function set_bold!()
    print(stdout, CSI, "1m")
end

"""Print dim text."""
function set_dim!()
    print(stdout, CSI, "2m")
end

# ── Box drawing helpers ────────────────────────────────────────────────

"""Draw a horizontal line of given width with box chars."""
function draw_hline!(col::Int, row::Int, width::Int, left::Char, fill::Char, right::Char;
                     label::String="")
    move_cursor!(row, col)
    set_color!(fg=:dark_amber)
    print(stdout, left)
    if !isempty(label)
        # Insert label after left corner: "─ Label ─────"
        decorated = " $(label) "
        set_bold!()
        set_color!(fg=:amber)
        print(stdout, decorated)
        set_color!(fg=:dark_amber)
        reset_bold = CSI * "22m"
        print(stdout, reset_bold)
        remaining = width - 2 - length(decorated)
        remaining > 0 && print(stdout, fill ^ remaining)
    else
        print(stdout, fill ^ (width - 2))
    end
    print(stdout, right)
    reset_color!()
end

"""Draw the left and right border chars for a content line."""
function draw_borders!(row::Int, width::Int)
    move_cursor!(row, 1)
    set_color!(fg=:dark_amber)
    print(stdout, '│')
    move_cursor!(row, width)
    print(stdout, '│')
    reset_color!()
end

# ── Render per component ───────────────────────────────────────────────

"""Render InputComponent: prompt + buffer with cursor indicator at given row."""
function render!(app::App, comp::InputComponent; row::Int=0, width::Int=80)
    rows, cols = row == 0 ? term_size() : (row, width)
    row == 0 && (row = rows)
    width = width > 0 ? width : cols

    draw_borders!(row, width)
    move_cursor!(row, 2)
    # Content area is width-2 (inside borders)
    content_width = width - 2

    set_color!(fg=:amber, bg=:dark_grey)
    print(stdout, ' ')
    set_bold!()
    set_color!(fg=:bright_amber)
    print(stdout, comp.prompt)
    reset_color!()
    set_color!(fg=:white, bg=:dark_grey)
    print(stdout, comp.buffer)
    # Cursor indicator
    set_color!(fg=:bright_amber)
    print(stdout, '_')
    reset_color!()
    # Fill remaining space
    used = 1 + length(comp.prompt) + length(comp.buffer) + 1  # space + prompt + buffer + cursor
    remaining = content_width - used
    if remaining > 0
        set_color!(bg=:dark_grey)
        print(stdout, ' ' ^ remaining)
        reset_color!()
    end

    emit!(app.frank, "jui.input", FRANK.STATE_TRANSITION,
          Dict{String,Any}("prompt" => comp.prompt, "buffer" => comp.buffer,
                           "cursor" => comp.cursor);
          transition="render")
end

"""Render OutputComponent: scrollable text panel."""
function render!(app::App, comp::OutputComponent; start_row::Int=2, end_row::Int=10, width::Int=80)
    content_height = end_row - start_row + 1
    content_width = width - 2

    # Determine which lines to show (tail of output, scrollable)
    total = length(comp.lines)
    if total <= content_height
        visible = comp.lines
        pad_lines = content_height - total
    else
        first = max(1, total - content_height + 1)
        visible = comp.lines[first:end]
        pad_lines = content_height - length(visible)
    end

    for (i, offset) in enumerate(0:content_height-1)
        r = start_row + offset
        draw_borders!(r, width)
        move_cursor!(r, 2)
        set_color!(fg=:light_grey, bg=:dark_grey)
        if i <= length(visible)
            line = visible[i]
            # Truncate to content width
            display_line = length(line) > content_width ? line[1:content_width] : line
            print(stdout, ' ', display_line)
            fill = content_width - 1 - length(display_line)
            fill > 0 && print(stdout, ' ' ^ fill)
        else
            print(stdout, ' ' ^ content_width)
        end
        reset_color!()
    end

    emit!(app.frank, "jui.output", FRANK.STATE_TRANSITION,
          Dict{String,Any}("line_count" => total,
                           "visible_lines" => length(visible));
          transition="render")
end

"""Render StatusBar: single line showing mode, model, WIQ, confidence."""
function render!(app::App, comp::StatusBar; row::Int=0, width::Int=80)
    content_width = width - 2

    draw_borders!(row, width)
    move_cursor!(row, 2)
    set_color!(bg=:dark_grey)

    # Build status string
    set_color!(fg=:amber)
    print(stdout, ' ')
    set_bold!()
    print(stdout, '[')
    set_color!(fg=:bright_amber)
    print(stdout, comp.mode)
    set_color!(fg=:amber)
    print(stdout, ']')
    print(stdout, CSI, "22m")  # unbold

    set_color!(fg=:mid_grey)
    print(stdout, " | ")

    set_color!(fg=:dark_amber)
    print(stdout, "model: ")
    set_color!(fg=:light_grey)
    print(stdout, comp.model)

    set_color!(fg=:mid_grey)
    print(stdout, " | ")

    set_color!(fg=:dark_amber)
    print(stdout, "WIQ:")
    wiq_str = string(round(Int, comp.wiq_score))
    # Color WIQ by value
    if comp.wiq_score >= 100
        set_color!(fg=:green)
    elseif comp.wiq_score >= 75
        set_color!(fg=:yellow)
    else
        set_color!(fg=:red)
    end
    print(stdout, wiq_str)

    set_color!(fg=:mid_grey)
    print(stdout, " | ")

    set_color!(fg=:dark_amber)
    print(stdout, "conf:")
    conf_str = string(round(comp.confidence; digits=2))
    if comp.confidence >= 0.85
        set_color!(fg=:green)
    elseif comp.confidence >= 0.5
        set_color!(fg=:yellow)
    else
        set_color!(fg=:red)
    end
    print(stdout, conf_str)

    reset_color!()
    set_color!(bg=:dark_grey)
    # Calculate used width and fill remainder
    status_text = " [$(comp.mode)] | model: $(comp.model) | WIQ:$(wiq_str) | conf:$(conf_str)"
    fill = content_width - length(status_text)
    fill > 0 && print(stdout, ' ' ^ fill)
    reset_color!()

    emit!(app.frank, "jui.status", FRANK.STATE_TRANSITION,
          Dict{String,Any}("mode" => comp.mode, "model" => comp.model,
                           "wiq" => comp.wiq_score, "confidence" => comp.confidence);
          transition="render")
end

"""Render HistoryPanel: scrollable list of past commands with confidence."""
function render!(app::App, comp::HistoryPanel; start_row::Int=2, end_row::Int=5, width::Int=80)
    content_height = end_row - start_row + 1
    content_width = width - 2

    entries = comp.entries
    total = length(entries)

    # Apply scroll offset, show most recent at bottom
    if total <= content_height
        visible = entries
    else
        last_idx = total - comp.scroll_offset
        first_idx = max(1, last_idx - content_height + 1)
        visible = entries[first_idx:min(last_idx, total)]
    end

    for i in 1:content_height
        r = start_row + i - 1
        draw_borders!(r, width)
        move_cursor!(r, 2)
        set_color!(bg=:dark_grey)
        if i <= length(visible)
            entry = visible[i]
            conf = get(entry, "confidence", 0.0)
            input_text = get(entry, "input", "")
            output_text = get(entry, "output", "")

            # Format: "0.92 list files -> ls"
            set_color!(fg=:dark_amber, bg=:dark_grey)
            print(stdout, ' ')
            # Confidence color
            if conf >= 0.85
                set_color!(fg=:green)
            elseif conf >= 0.5
                set_color!(fg=:yellow)
            else
                set_color!(fg=:red)
            end
            conf_str = lpad(string(round(conf; digits=2)), 4)
            print(stdout, conf_str)
            set_color!(fg=:mid_grey)
            print(stdout, ' ')
            set_color!(fg=:light_grey)
            print(stdout, input_text)
            if !isempty(output_text)
                set_color!(fg=:dark_amber)
                print(stdout, " -> ")
                set_color!(fg=:amber)
                print(stdout, output_text)
            end
            # Fill remainder
            line_content = " $(conf_str) $(input_text)" * (isempty(output_text) ? "" : " -> $(output_text)")
            fill = content_width - length(line_content)
            fill > 0 && print(stdout, ' ' ^ fill)
        else
            print(stdout, ' ' ^ content_width)
        end
        reset_color!()
    end

    emit!(app.frank, "jui.history", FRANK.STATE_TRANSITION,
          Dict{String,Any}("total_entries" => total,
                           "visible" => length(visible),
                           "scroll_offset" => comp.scroll_offset);
          transition="render")
end

# ── Screen layout composition ──────────────────────────────────────────

"""Compose all 4 components into the full screen layout.

Layout (top to bottom):
  Row 1:         top border with "Output" label
  Row 2..O:      OutputComponent content
  Row O+1:       separator with "History" label
  Row O+2..H:    HistoryPanel content
  Row H+1:       separator
  Row H+2:       StatusBar
  Row H+3:       separator
  Row H+4:       InputComponent
  Row H+5:       bottom border
"""
function render_screen!(app::App)
    rows, cols = term_size()
    width = cols

    # Layout proportions
    # Reserve: 1 top border + 1 history sep + 1 status sep + 1 input sep + 1 status + 1 input + 1 bottom = 7 chrome lines
    chrome = 7
    available = rows - chrome
    # Give history 30% of available, output gets the rest (minimum 3 lines each)
    history_height = max(3, min(div(available, 3), 8))
    output_height = max(3, available - history_height)

    # Calculate row positions
    output_top_border = 1
    output_start = 2
    output_end = output_start + output_height - 1
    history_border = output_end + 1
    history_start = history_border + 1
    history_end = history_start + history_height - 1
    status_border = history_end + 1
    status_row = status_border + 1
    input_border = status_row + 1
    input_row = input_border + 1
    bottom_border = input_row + 1

    # Draw top border
    draw_hline!(1, output_top_border, width, '\u250C', '\u2500', '\u2510'; label="Output")

    # Render output panel
    render!(app, app.output; start_row=output_start, end_row=output_end, width=width)

    # History separator
    draw_hline!(1, history_border, width, '\u251C', '\u2500', '\u2524'; label="History")

    # Render history panel
    render!(app, app.history; start_row=history_start, end_row=history_end, width=width)

    # Status separator
    draw_hline!(1, status_border, width, '\u251C', '\u2500', '\u2524')

    # Render status bar
    render!(app, app.status; row=status_row, width=width)

    # Input separator
    draw_hline!(1, input_border, width, '\u251C', '\u2500', '\u2524')

    # Render input
    render!(app, app.input; row=input_row, width=width)

    # Bottom border
    draw_hline!(1, bottom_border, width, '\u2514', '\u2500', '\u2518')

    flush(stdout)

    # Emit full state via FRANK
    emit!(app.frank, "jui.screen", FRANK.STATE_TRANSITION,
          Dict{String,Any}(
              "action" => "render_screen",
              "terminal_size" => Dict("rows" => rows, "cols" => cols),
              "layout" => Dict(
                  "output_rows" => output_height,
                  "history_rows" => history_height,
                  "total_rows" => bottom_border
              ),
              "status" => Dict(
                  "mode" => app.status.mode,
                  "model" => app.status.model,
                  "wiq" => app.status.wiq_score,
                  "confidence" => app.status.confidence
              ),
              "history_count" => length(app.history.entries),
              "output_lines" => length(app.output.lines),
              "input_buffer" => app.input.buffer
          );
          transition="screen_rendered")
end

# ── Input handling ─────────────────────────────────────────────────────

"""Process a line of input. Updates buffer, returns the completed line.
Line-mode: treats each call as a complete line (Enter already pressed)."""
function handle_input!(app::App, raw::String)
    line = strip(raw)

    emit!(app.frank, "jui.input", FRANK.STATE_TRANSITION,
          Dict{String,Any}("raw" => raw, "buffer" => line);
          transition="input_received")

    # Update input component state
    app.input.buffer = ""
    app.input.cursor = 0

    # Add to history if non-empty
    if !isempty(line)
        entry = Dict{String,Any}(
            "input" => line,
            "output" => "",
            "confidence" => app.status.confidence,
            "ts" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")
        )
        push!(app.history.entries, entry)

        # Trim history if over limit
        while length(app.history.entries) > app.history.max_entries
            popfirst!(app.history.entries)
        end

        emit!(app.frank, "jui.history", FRANK.STATE_TRANSITION,
              Dict{String,Any}("action" => "append",
                               "entry" => entry,
                               "total" => length(app.history.entries));
              transition="history_appended")
    end

    return line
end

"""Append output text to the output panel."""
function append_output!(app::App, text::String)
    for line in split(text, '\n')
        push!(app.output.lines, String(line))
    end

    # Trim to max_lines
    while length(app.output.lines) > app.output.max_lines
        popfirst!(app.output.lines)
    end

    emit!(app.frank, "jui.output", FRANK.STATE_TRANSITION,
          Dict{String,Any}("action" => "append",
                           "new_text" => text,
                           "total_lines" => length(app.output.lines));
          transition="output_updated")
end

"""Update the status bar fields."""
function update_status!(app::App; mode::Union{String,Nothing}=nothing,
                        model::Union{String,Nothing}=nothing,
                        wiq::Union{Float64,Nothing}=nothing,
                        confidence::Union{Float64,Nothing}=nothing)
    mode !== nothing && (app.status.mode = mode)
    model !== nothing && (app.status.model = model)
    wiq !== nothing && (app.status.wiq_score = wiq)
    confidence !== nothing && (app.status.confidence = confidence)

    emit!(app.frank, "jui.status", FRANK.STATE_TRANSITION,
          Dict{String,Any}("mode" => app.status.mode, "model" => app.status.model,
                           "wiq" => app.status.wiq_score,
                           "confidence" => app.status.confidence);
          transition="status_updated")
end

# ── Main loop ──────────────────────────────────────────────────────────

"""Main event loop. Reads stdin line-by-line, renders, loops until exit/quit."""
function run!(app::App)
    app.running = true

    emit!(app.frank, "jui.app", FRANK.STATE_TRANSITION,
          Dict{String,Any}("action" => "start", "mode" => app.status.mode);
          transition="running")

    # Initial render
    clear_screen!()
    append_output!(app, "Igor TUI ready. Type commands or 'exit' to quit.")
    render_screen!(app)

    try
        while app.running
            # Position cursor at input area for readline
            rows, cols = term_size()
            # Move cursor to input line content area (after prompt + cursor indicator)
            # We just let Julia's readline handle cursor positioning on its own line
            # Print prompt on a fresh line below the TUI frame
            print(stdout, "\r")
            set_color!(fg=:bright_amber)
            print(stdout, app.input.prompt)
            reset_color!()
            flush(stdout)

            # Read a line from stdin
            raw = try
                readline(stdin)
            catch e
                if e isa EOFError || e isa InterruptException
                    ""
                else
                    rethrow(e)
                end
            end

            # EOF check
            if isempty(raw) && eof(stdin)
                app.running = false
                break
            end

            # Process input
            line = handle_input!(app, raw)

            # Check for exit commands
            if line in ("exit", "quit", "q")
                app.running = false
                append_output!(app, "Shutting down...")
                render_screen!(app)
                break
            end

            # For now, echo input as output (JUI is just the UI framework,
            # the brain layer will replace this with actual command translation)
            if !isempty(line)
                append_output!(app, "> $(line)")
            end

            # Re-render
            clear_screen!()
            render_screen!(app)
        end
    catch e
        if !(e isa InterruptException)
            rethrow(e)
        end
    finally
        # Restore terminal
        reset_color!()
        clear_screen!()
        move_cursor!(1, 1)
        println(stdout, "Igor exited.")
        flush(stdout)

        emit!(app.frank, "jui.app", FRANK.STATE_TRANSITION,
              Dict{String,Any}("action" => "shutdown",
                               "history_count" => length(app.history.entries),
                               "output_lines" => length(app.output.lines));
              transition="shutdown")

        app.running = false
    end
end

end # module
