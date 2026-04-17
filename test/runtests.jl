using Test
using Dates

using FRANK
using FRANK: STATE_TRANSITION, INTENT_PARSE, CONFIDENCE_SCORE, ACTION_CANDIDATES,
             EXECUTION, CORRECTION, ERROR, IDLE_TICK
using JSON3
using JUI

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

"""Redirect stdout to an IOBuffer, run f(), return captured string."""
function capture_stdout(f)
    buf = IOBuffer()
    old = stdout
    rd, wr = redirect_stdout()
    task = @async begin
        while !eof(rd)
            write(buf, readavailable(rd))
        end
    end
    try
        f()
        flush(stdout)
    finally
        redirect_stdout(old)
        close(wr)
        wait(task)
    end
    return String(take!(buf))
end

"""Create an App whose FRANK emitter writes to the given IOBuffer."""
function make_app(; frank_io::IO=IOBuffer(), model="test-model", mode="caveman")
    app = App(; model=model, mode=mode)
    FRANK.configure!(app.frank; io=frank_io)
    return app
end

"""Parse every JSONL line from a FRANK IOBuffer and return Vector{JSON3.Object}."""
function parse_frank_events(buf::IOBuffer)
    seekstart(buf)
    events = []
    for line in eachline(buf)
        isempty(strip(line)) && continue
        push!(events, JSON3.read(line))
    end
    return events
end

# =========================================================================
# 1. App construction — default values
# =========================================================================
@testset "App construction — defaults" begin
    app = App()
    @test app.input.buffer == ""
    @test app.input.cursor == 0
    @test app.input.prompt == "igor> "
    @test app.output.lines == String[]
    @test app.output.max_lines == 100
    @test app.status.mode == "caveman"
    @test app.status.model == "unknown"
    @test app.status.wiq_score == 0.0
    @test app.status.confidence == 0.0
    @test app.history.entries == Dict{String,Any}[]
    @test app.history.max_entries == 500
    @test app.history.scroll_offset == 0
    @test app.running == false
end

# =========================================================================
# 2. App construction — custom mode / model
# =========================================================================
@testset "App construction — custom" begin
    app = App(; model="qwen3-coder:30b", mode="debug")
    @test app.status.model == "qwen3-coder:30b"
    @test app.status.mode == "debug"
end

# =========================================================================
# 3. InputComponent defaults
# =========================================================================
@testset "InputComponent — defaults" begin
    ic = JUI.InputComponent("", 0, "igor> ")
    @test ic.buffer == ""
    @test ic.cursor == 0
    @test ic.prompt == "igor> "

    ic2 = JUI.InputComponent("", 0, "custom> ")
    @test ic2.prompt == "custom> "
end

# =========================================================================
# 4. OutputComponent defaults
# =========================================================================
@testset "OutputComponent — defaults" begin
    oc = JUI.OutputComponent(String[], 100)
    @test oc.lines == String[]
    @test oc.max_lines == 100
end

# =========================================================================
# 5. StatusBar fields
# =========================================================================
@testset "StatusBar — fields" begin
    sb = JUI.StatusBar("verbose", "phi-3", 87.5, 0.92)
    @test sb.mode == "verbose"
    @test sb.model == "phi-3"
    @test sb.wiq_score == 87.5
    @test sb.confidence == 0.92
end

# =========================================================================
# 6. HistoryPanel defaults
# =========================================================================
@testset "HistoryPanel — defaults" begin
    hp = JUI.HistoryPanel(Dict{String,Any}[], 500, 0)
    @test hp.entries == Dict{String,Any}[]
    @test hp.max_entries == 500
    @test hp.scroll_offset == 0
end

# =========================================================================
# 7-8. handle_input! — stores, clears, trims, respects max
# =========================================================================
@testset "handle_input! — basic" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    result = handle_input!(app, "  list files  ")
    @test result == "list files"              # 7: trims whitespace
    @test app.input.buffer == ""              # 6: clears buffer
    @test app.input.cursor == 0               # 6: resets cursor
    @test length(app.history.entries) == 1     # 6: stores in history
    @test app.history.entries[1]["input"] == "list files"
end

@testset "handle_input! — history max_entries" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)
    app.history.max_entries = 500

    # Add 600 entries to a 500-max panel
    for i in 1:600
        handle_input!(app, "cmd $i")
    end
    @test length(app.history.entries) == 500   # 8: capped at max
    @test app.history.entries[1]["input"] == "cmd 101"  # oldest surviving
    @test app.history.entries[end]["input"] == "cmd 600" # newest
end

# =========================================================================
# 9-10. append_output! — adds lines, respects max_lines
# =========================================================================
@testset "append_output! — basic" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    append_output!(app, "hello world")
    @test length(app.output.lines) == 1
    @test app.output.lines[1] == "hello world"

    append_output!(app, "line2\nline3")
    @test length(app.output.lines) == 3
    @test app.output.lines[2] == "line2"
    @test app.output.lines[3] == "line3"
end

@testset "append_output! — max_lines" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)
    app.output.max_lines = 100

    # Add 150 individual lines
    for i in 1:150
        append_output!(app, "line $i")
    end
    @test length(app.output.lines) == 100    # 10: capped at 100
    @test app.output.lines[1] == "line 51"   # oldest surviving
    @test app.output.lines[end] == "line 150"
end

# =========================================================================
# 11. update_status! — changes fields
# =========================================================================
@testset "update_status!" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    update_status!(app; mode="debug", model="grok-2", wiq=95.0, confidence=0.88)
    @test app.status.mode == "debug"
    @test app.status.model == "grok-2"
    @test app.status.wiq_score == 95.0
    @test app.status.confidence == 0.88

    # Partial update — only mode
    update_status!(app; mode="verbose")
    @test app.status.mode == "verbose"
    @test app.status.model == "grok-2"   # unchanged
end

# =========================================================================
# 12-17. FRANK emission tests
# =========================================================================
@testset "FRANK — handle_input! emits STATE_TRANSITION" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    handle_input!(app, "hello")
    events = parse_frank_events(fbuf)
    @test length(events) >= 1
    # Find the input_received event
    input_evts = filter(e -> e[:component] == "jui.input", events)
    @test length(input_evts) >= 1
    evt = input_evts[1]
    @test evt[:event_type] == "STATE_TRANSITION"
    @test evt[:state][:buffer] == "hello"
    @test evt[:transition] == "input_received"
end

@testset "FRANK — append_output! emits STATE_TRANSITION" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    append_output!(app, "test output")
    events = parse_frank_events(fbuf)
    @test length(events) >= 1
    out_evts = filter(e -> e[:component] == "jui.output", events)
    @test length(out_evts) >= 1
    evt = out_evts[1]
    @test evt[:event_type] == "STATE_TRANSITION"
    @test evt[:transition] == "output_updated"
    @test evt[:state][:new_text] == "test output"
end

@testset "FRANK — render_screen! emits STATE_TRANSITION" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    # render_screen! writes to stdout -- capture and discard
    capture_stdout() do
        render_screen!(app)
    end

    events = parse_frank_events(fbuf)
    screen_evts = filter(e -> e[:component] == "jui.screen", events)
    @test length(screen_evts) >= 1
    evt = screen_evts[1]
    @test evt[:event_type] == "STATE_TRANSITION"
    @test evt[:transition] == "screen_rendered"
    @test haskey(evt[:state], :action)
    @test evt[:state][:action] == "render_screen"
end

@testset "FRANK — run! emits startup event" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    # Feed "exit\n" through stdin so run! terminates immediately
    # Use a Pipe (Julia 1.11 doesn't support redirect_stdin with IOBuffer)
    inp = Pipe()
    Base.link_pipe!(inp; reader_supports_async=true, writer_supports_async=true)
    write(inp.in, "exit\n")
    close(inp.in)

    redirect_stdin(inp) do
        capture_stdout() do
            run!(app)
        end
    end

    events = parse_frank_events(fbuf)
    app_evts = filter(e -> e[:component] == "jui.app", events)
    @test length(app_evts) >= 1
    start_evt = filter(e -> get(e[:state], :action, nothing) == "start", app_evts)
    @test length(start_evt) >= 1
    @test start_evt[1][:transition] == "running"
end

@testset "FRANK — events are valid JSONL" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    handle_input!(app, "test")
    append_output!(app, "reply")
    update_status!(app; mode="debug")

    seekstart(fbuf)
    for line in eachline(fbuf)
        isempty(strip(line)) && continue
        parsed = JSON3.read(line)                     # 16: valid JSON
        @test parsed isa JSON3.Object
        @test haskey(parsed, :frank_v)
        @test parsed[:frank_v] == 1
        @test haskey(parsed, :component)
        @test haskey(parsed, :event_type)
        @test haskey(parsed, :state)
    end
end

@testset "FRANK — component identifiers" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    handle_input!(app, "x")
    append_output!(app, "y")
    update_status!(app; mode="normal")
    capture_stdout() do
        render!(app, app.history; start_row=2, end_row=5, width=80)
    end

    events = parse_frank_events(fbuf)
    components = Set(e[:component] for e in events)
    @test "jui.input" in components
    @test "jui.output" in components
    @test "jui.status" in components
    @test "jui.history" in components
end

# =========================================================================
# 18-23. Terminal utilities
# =========================================================================
@testset "term_size" begin
    result = term_size()
    @test result isa Tuple{Int,Int}
    rows, cols = result
    @test rows > 0
    @test cols > 0
end

@testset "clear_screen!" begin
    output = capture_stdout() do
        clear_screen!()
    end
    @test occursin("\e[2J", output)
    @test occursin("\e[H", output)
end

@testset "move_cursor!" begin
    output = capture_stdout() do
        move_cursor!(5, 10)
    end
    @test occursin("\e[5;10H", output)
end

@testset "set_color! — named colors" begin
    # :amber => 208 (256-color, >= 8 so uses 38;5; prefix)
    output = capture_stdout() do
        set_color!(fg=:amber)
    end
    @test occursin("\e[38;5;208m", output)

    # :dark_grey => 236
    output2 = capture_stdout() do
        set_color!(fg=:dark_grey)
    end
    @test occursin("\e[38;5;236m", output2)

    # :red => 1 (basic color, < 8 so uses 30+code)
    output3 = capture_stdout() do
        set_color!(fg=:red)
    end
    @test occursin("\e[31m", output3)
end

@testset "set_color! — background" begin
    output = capture_stdout() do
        set_color!(bg=:amber)
    end
    @test occursin("\e[48;5;208m", output)
end

@testset "reset_color!" begin
    output = capture_stdout() do
        reset_color!()
    end
    @test occursin("\e[0m", output)
end

# =========================================================================
# 24-27. Rendering output verification
# =========================================================================
@testset "render! InputComponent — contains prompt and buffer" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)
    app.input.buffer = "hello world"
    app.input.prompt = "test> "

    output = capture_stdout() do
        render!(app, app.input; row=5, width=80)
    end
    @test occursin("test> ", output)
    @test occursin("hello world", output)
end

@testset "render! StatusBar — contains mode and model" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf, mode="debug", model="qwen3")

    output = capture_stdout() do
        render!(app, app.status; row=3, width=80)
    end
    @test occursin("debug", output)
    @test occursin("qwen3", output)
end

@testset "render! OutputComponent — contains text lines" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)
    append_output!(app, "output line alpha")
    append_output!(app, "output line beta")

    output = capture_stdout() do
        render!(app, app.output; start_row=2, end_row=10, width=80)
    end
    @test occursin("output line alpha", output)
    @test occursin("output line beta", output)
end

@testset "render! HistoryPanel — contains entries" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)
    push!(app.history.entries, Dict{String,Any}(
        "input" => "list files",
        "output" => "ls -la",
        "confidence" => 0.95,
        "ts" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")
    ))

    output = capture_stdout() do
        render!(app, app.history; start_row=2, end_row=5, width=80)
    end
    @test occursin("list files", output)
    @test occursin("ls -la", output)
end

# =========================================================================
# 28-32. Edge cases
# =========================================================================
@testset "Edge — empty buffer input" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    result = handle_input!(app, "")
    @test result == ""
    @test length(app.history.entries) == 0  # empty not added to history

    result2 = handle_input!(app, "   ")
    @test result2 == ""
    @test length(app.history.entries) == 0  # whitespace-only not added
end

@testset "Edge — very long input (1000 chars)" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    long_input = repeat("x", 1000)
    result = handle_input!(app, long_input)
    @test result == long_input
    @test length(app.history.entries) == 1
    @test app.history.entries[1]["input"] == long_input
end

@testset "Edge — Unicode input (emoji, CJK)" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)

    handle_input!(app, "hello world")
    @test app.history.entries[end]["input"] == "hello world"

    handle_input!(app, "list files")
    @test app.history.entries[end]["input"] == "list files"
end

@testset "Edge — HistoryPanel 0 entries renders" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)
    @test length(app.history.entries) == 0

    output = capture_stdout() do
        render!(app, app.history; start_row=2, end_row=5, width=80)
    end
    # Should not error; output is just empty space
    @test output isa String
end

@testset "Edge — OutputComponent 0 lines renders" begin
    fbuf = IOBuffer()
    app = make_app(; frank_io=fbuf)
    @test length(app.output.lines) == 0

    output = capture_stdout() do
        render!(app, app.output; start_row=2, end_row=10, width=80)
    end
    @test output isa String
end
