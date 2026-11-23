-- lib/io/crow.lua
-- crow (3.6, design §5), S.lib.io_crow: the only way Strata speaks to crow.
-- Every line goes out as text, one crow.send(line) a line, and every
-- handler crow needs is a line of crow-side Lua that calls tell with a
-- fixed event name (strata_in, strata_change; the ii bus adds its own
-- through on_event): no function is ever assigned through the crow proxy,
-- so norns' 45 event keys are never used. Every line counts in one budget
-- (CROW.lines_per_window per CROW.window_seconds): send_now always sends,
-- send_value waits for the next window when the count is full (the newest
-- line per key wins). Inputs are modulation sources (crow1, crow2) or
-- triggers of the shared actions (S.lib.io_actions); outputs follow a
-- modulation source, a voice's pitch or gate (the note target crow), or
-- pulse on norns' clock. With every param at its default nothing is sent.
-- Notes: docs/notes/lua/io/crow.md

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  local CROW = {lines_per_window = 32, window_seconds = 0.1, stream_seconds = 0.02, slew_seconds = 0.02,
    change_volts = 1, change_hysteresis = 0.1, follow_fraction = 1 / 200, pulse_seconds = 0.01,
    pulse_volts = 5, gate_volts = 5}
  M.CROW = CROW

  -- The jacks, the params' options and the texts
  local SPEC = {
    inputs = 2, outputs = 4, param_count = 24,  -- an output's source is two params (S.lib.io_keyed)
    modes = {"off", "cv", "trigger"},
    input_ranges = {"-5..5", "0..5", "0..10"},
    output_ranges = {"0..5", "0..10", "-5..5"},
    actions = {"retrigger", "next scene", "freeze", "record", "patterns", "fill"},
    divisions = {"1/16", "1/8", "1/4", "1/2", "1", "2", "4"},
    division_beats = {1 / 16, 1 / 8, 1 / 4, 1 / 2, 1, 2, 4},
    division_default = 5,
    clock_source_crow = 4,  -- norns' clock_source option crow; clock_crow_out is off at 1, output n at n + 1
    absent = "[--]", norns_clock = "clock (norns)", approximate = " ~", selected_voice = "sel",
    zero_volt_note = 60, notes_per_volt = 12,
  }

  -- "-5..5" -> {-5, 5}
  local function parse_range(text)
    local low, high = text:match("^(%-?%d+)%.%.(%-?%d+)$")
    return {tonumber(low), tonumber(high)}
  end

  -- source_keys and source_labels: the output sources' keys and labels;
  -- source_by_key: what each is ({kind, key, voice}), built at add_params.
  -- set_up: the jacks Strata has sent a setting since crow's last reset
  -- (only those get an off line)
  local state = {started = false, stopped = false, source_keys = {}, source_labels = {}, source_by_key = {},
    input_volts = {}, input_ranges = {}, last_volts = {}, notes = {}, clocks = {}, applied_source = {},
    owners = {input = false, output = 0}, errors = {}, set_up = {input = {}, output = {}}}
  for voice = 1, NUM_VOICES do state.notes[voice] = {} end
  local budget = {window = -math.huge, sent = 0, pending = {}, order = {}, clock = nil}
  local hooks = {events = {}, event_order = {}, setup = {}, gone = {}}

  local function in_id(n, field) return "crow_in" .. n .. "_" .. field end
  local function out_id(n, field) return "crow_out" .. n .. "_" .. field end

  -- A param's value, or nil when it is not added (before init's params)
  local function param_value(id)
    if not params.lookup[id] then return nil end
    return params:get(id)
  end

  function M.present() return norns.crow.dev ~= nil end

  -- A number as a line writes it: at most four decimals, no trailing zeros
  -- or point, never -0 (plan ruling 20); anything not finite is 0
  function M.number(value)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return "0" end
    local text = string.format("%.4f", value)
    text = text:gsub("0+$", "")
    text = text:gsub("%.$", "")
    if text == "-0" then text = "0" end
    return text
  end
  local number = M.number

  ---------------------------------------------------------------------------
  -- The budget (lib/engine_sync.lua's pattern): a window counter, the
  -- newest line per key waiting, a flush clock that ends at its own wake
  ---------------------------------------------------------------------------

  local function current_window() return math.floor(util.time() / CROW.window_seconds) end

  local function deliver(line)
    budget.sent = budget.sent + 1
    crow.send(line)
  end

  local function flush_pending()
    while #budget.order > 0 and budget.sent < CROW.lines_per_window do
      local key = table.remove(budget.order, 1)
      local line = budget.pending[key]
      budget.pending[key] = nil
      deliver(line)
    end
  end

  local function enter_window(window)
    if window <= budget.window then return end
    budget.window, budget.sent = window, 0
    flush_pending()
  end

  local function drop_pending(key)
    if budget.pending[key] == nil then return end
    budget.pending[key] = nil
    for index, waiting in ipairs(budget.order) do
      if waiting == key then
        table.remove(budget.order, index)
        break
      end
    end
  end

  local function drop_all_pending()
    budget.pending, budget.order = {}, {}
  end

  -- Never stopped while the script runs (#654, as the engine budget's):
  -- it ends at its own wake once nothing waits. A clock of S.lib.clocks
  -- (#870), its handle in budget.clock, canceled only by the cleanup step
  local function start_flush_clock()
    if budget.clock then return end
    budget.clock = S.lib.clocks.run(function(handle)
      while #budget.order > 0 do
        local next_window = math.max(current_window(), budget.window) + 1
        if not handle.sleep(math.max(0, next_window * CROW.window_seconds - util.time())) then return end
        enter_window(math.max(current_window(), next_window))
      end
      budget.clock = nil
    end)
  end

  -- With a crow: count the line in the window and send it (true); without
  -- one, or after the cleanup step, false
  function M.send_now(line)
    if state.stopped or not M.present() then return false end
    enter_window(current_window())
    deliver(line)
    return true
  end

  -- A followed value: sent while the window's count is under the limit
  -- (true), otherwise it waits as key's line, the newest winning, in the
  -- order the keys first waited, for the next window (false)
  function M.send_value(key, line)
    if state.stopped or not M.present() then return false end
    enter_window(current_window())
    if budget.sent < CROW.lines_per_window then
      drop_pending(key)
      deliver(line)
      return true
    end
    if budget.pending[key] == nil then table.insert(budget.order, key) end
    budget.pending[key] = line
    start_flush_clock()
    return false
  end

  -- For tests: this window's lines and the keys waiting
  function M.budget_state()
    local sent = budget.sent
    if current_window() > budget.window then sent = 0 end
    return {sent = sent, pending = #budget.order}
  end

  -- For tests: the module's clocks that run (a copy), by their ids
  function M.clocks()
    local outputs = {}
    for n, handle in pairs(state.clocks) do outputs[n] = handle.id end
    return {flush = budget.clock and budget.clock.id, outputs = outputs}
  end

  ---------------------------------------------------------------------------
  -- The jacks
  ---------------------------------------------------------------------------

  -- norns' own crow clock: input 1 under clock source crow, the output
  -- clock_crow_out names (crow-ii.md §1)
  local function norns_input(n)
    return n == 1 and param_value("clock_source") == SPEC.clock_source_crow
  end
  local function norns_output(n)
    return param_value("clock_crow_out") == n + 1
  end
  local function owned_output()
    local value = param_value("clock_crow_out")
    return value and value > 1 and value - 1 or 0
  end

  local function input_mode(n) return SPEC.modes[param_value(in_id(n, "mode")) or 1] end

  local OFF = {kind = "off"}
  -- Output n's source, by the key its param keeps (a key the list lacks is off)
  local function source_of(n)
    if not params.lookup[out_id(n, "source")] then return OFF end
    return state.source_by_key[S.lib.io_keyed.key(out_id(n, "source"))] or OFF
  end

  local function output_range(n)
    return parse_range(SPEC.output_ranges[param_value(out_id(n, "range")) or 1])
  end

  local function clamp_to_range(n, volts)
    local range = output_range(n)
    return math.max(range[1], math.min(range[2], volts))
  end

  local function volts_line(n, volts) return "output[" .. n .. "].volts = " .. number(volts) end

  local function pitch_volts(n, pitch)
    return clamp_to_range(n, (pitch - SPEC.zero_volt_note) / SPEC.notes_per_volt)
  end

  -- Input n's lines: its handler and its mode call; off is mode none, only
  -- for a jack Strata set up since crow's last reset
  local function input_lines(n)
    if norns_input(n) then return {} end
    local mode, jack = input_mode(n), "input[" .. n .. "]"
    if mode == "cv" then
      return {jack .. ".stream = function(v) tell('strata_in', " .. n .. ", v) end",
        jack .. ".mode('stream', " .. number(CROW.stream_seconds) .. ")"}
    elseif mode == "trigger" then
      return {jack .. ".change = function(s) tell('strata_change', " .. n .. ", s and 1 or 0) end",
        jack .. ".mode('change', " .. number(CROW.change_volts) .. ", " .. number(CROW.change_hysteresis)
          .. ", 'rising')"}
    elseif state.set_up.input[n] then
      return {jack .. ".mode('none')"}
    end
    return {}
  end

  -- Output n's lines for its source; off sends 0 V, only for a jack Strata
  -- set up since crow's last reset. A gate always sends its level (0 V
  -- with no note), so a jack moved off a sounding voice never stays high
  local function output_lines(n)
    if norns_output(n) then return {} end
    local source, jack = source_of(n), "output[" .. n .. "]"
    if source.kind == "mod" then
      return {jack .. ".slew = " .. number(CROW.slew_seconds)}
    elseif source.kind == "pitch" or source.kind == "gate" then
      local lines = {jack .. ".slew = 0"}
      local notes = state.notes[source.voice]
      if source.kind == "gate" then
        lines[2] = volts_line(n, #notes > 0 and CROW.gate_volts or 0)
      elseif #notes > 0 then
        lines[2] = volts_line(n, pitch_volts(n, notes[#notes].pitch))
      end
      return lines
    elseif source.kind == "clock" then
      return {jack .. ".action = pulse(" .. number(CROW.pulse_seconds) .. ", " .. number(CROW.pulse_volts) .. ")"}
    elseif state.set_up.output[n] then
      return {volts_line(n, 0)}
    end
    return {}
  end

  -- Stopped through S.lib.clocks (#870): retired, never canceled, while
  -- its resume may be posted; the cleanup step cancels (at_cleanup)
  local function stop_output_clock(n, at_cleanup)
    if state.clocks[n] then
      if at_cleanup then S.lib.clocks.cancel(state.clocks[n]) else S.lib.clocks.stop(state.clocks[n]) end
      state.clocks[n] = nil
    end
  end

  -- One norns clock per clock output: output[n]() every division; a clock
  -- of S.lib.clocks, its handle in state.clocks[n]
  local function start_output_clock(n)
    stop_output_clock(n)
    local beats = SPEC.division_beats[param_value(out_id(n, "div")) or SPEC.division_default]
    state.clocks[n] = S.lib.clocks.run(function(handle)
      while handle.sync(beats) do
        if not norns_output(n) then M.send_now("output[" .. n .. "]()") end
      end
    end)
  end

  local function active()
    return state.started and not state.stopped and M.present()
  end

  -- Send lines for a jack, noting whether it is now set up (a setting) or
  -- not (its off line)
  local function send_jack(kind, n, lines, setting)
    for _, line in ipairs(lines) do M.send_now(line) end
    if #lines > 0 then state.set_up[kind][n] = setting end
  end

  -- Send input n's lines again (its mode or range changed, or the setup)
  local function apply_input(n)
    if input_mode(n) ~= "cv" then state.input_volts[n] = nil end
    local range = parse_range(SPEC.input_ranges[param_value(in_id(n, "range")) or 1])
    state.input_ranges[n][1], state.input_ranges[n][2] = range[1], range[2]
    if not active() then return end
    send_jack("input", n, input_lines(n), input_mode(n) ~= "off")
  end

  -- Send output n's lines again and restart its clock
  local function apply_output(n)
    stop_output_clock(n)
    state.last_volts[n] = nil
    if not active() then return end
    send_jack("output", n, output_lines(n), source_of(n).kind ~= "off")
    if source_of(n).kind == "clock" and not norns_output(n) then start_output_clock(n) end
  end

  -- Every line the current settings need (after crow.reset, so an off jack sends none)
  function M.setup()
    for n = 1, SPEC.inputs do apply_input(n) end
    for n = 1, SPEC.outputs do apply_output(n) end
  end

  -- norns' clock taking or giving back a jack (seen at each step): a jack
  -- given back gets its lines again, one taken loses its clock
  local function follow_owners()
    local input = norns_input(1)
    if input ~= state.owners.input then
      state.owners.input = input
      if not input then apply_input(1) end
    end
    local output = owned_output()
    if output ~= state.owners.output then
      local previous = state.owners.output
      state.owners.output = output
      if output > 0 then stop_output_clock(output) end
      if previous > 0 then apply_output(previous) end
    end
  end

  local function remember_owners()
    state.owners.input, state.owners.output = norns_input(1), owned_output()
  end

  ---------------------------------------------------------------------------
  -- Events, setup and gone hooks
  ---------------------------------------------------------------------------

  local function install_event(name)
    local fn = hooks.events[name]
    norns.crow.events[name] = function(...)
      S.lib.ui_frame.contained_call(state.errors, "event " .. name, "crow event " .. name, fn, ...)
    end
  end

  local function install_events()
    for _, name in ipairs(hooks.event_order) do install_event(name) end
  end

  -- fn runs for each ^^name(...) line crow sends; set at once and again after each add
  function M.on_event(name, fn)
    assert(type(name) == "string" and type(fn) == "function", "S.lib.io_crow.on_event: a name and a function")
    if hooks.events[name] == nil then table.insert(hooks.event_order, name) end
    hooks.events[name] = fn
    if not state.stopped then install_event(name) end
  end

  local function add_hook(list, kind, name, fn)
    assert(type(name) == "string" and type(fn) == "function", "S.lib.io_crow." .. kind .. ": a name and a function")
    for _, entry in ipairs(list) do
      if entry.name == name then
        entry.fn = fn
        return
      end
    end
    table.insert(list, {name = name, fn = fn})
  end

  -- fn() runs after setup at each add (and at the start with a crow there)
  function M.on_setup(name, fn) add_hook(hooks.setup, "on_setup", name, fn) end
  -- fn() runs when crow goes
  function M.on_gone(name, fn) add_hook(hooks.gone, "on_gone", name, fn) end

  local function run_hooks(list, kind)
    for _, entry in ipairs(list) do
      S.lib.ui_frame.contained_call(state.errors, kind .. " " .. entry.name, "crow " .. kind .. " " .. entry.name,
        entry.fn)
    end
  end

  local function set_up()
    M.setup()
    run_hooks(hooks.setup, "setup")
  end

  -- norns.crow.add: norns' default reset (counted), then the settings' lines
  local function crow_added()
    if state.stopped then return end
    install_events()
    if M.present() then
      enter_window(current_window())
      budget.sent = budget.sent + 1
      crow.reset()
      state.set_up = {input = {}, output = {}}
    end
    remember_owners()
    set_up()
    request_redraw()
  end

  -- norns.crow.remove: what waits is dropped, the output clocks end
  local function crow_removed()
    if state.stopped then return end
    drop_all_pending()
    for n = 1, SPEC.outputs do stop_output_clock(n) end
    for n = 1, SPEC.inputs do state.input_volts[n] = nil end
    run_hooks(hooks.gone, "gone")
    request_redraw()
  end

  ---------------------------------------------------------------------------
  -- Inputs
  ---------------------------------------------------------------------------

  local TRIGGER_ACTIONS = {
    function(voice) S.lib.io_actions.retrigger(voice, 1) end,
    function() S.lib.io_actions.next_scene() end,
    function(voice) S.lib.io_actions.freeze(voice, 2) end,
    function() S.lib.io_actions.record() end,
    function() S.lib.io_actions.patterns(2) end,
    function() S.lib.io_actions.fill(2) end,
  }

  local function valid_input(n)
    return type(n) == "number" and n >= 1 and n <= SPEC.inputs and n == math.floor(n)
  end

  M.on_event("strata_in", function(n, volts)
    if not valid_input(n) or state.stopped or norns_input(n) or input_mode(n) ~= "cv" then return end
    if type(volts) == "number" and volts == volts then state.input_volts[n] = volts end
  end)

  M.on_event("strata_change", function(n, rising)
    if not valid_input(n) or state.stopped or norns_input(n) or input_mode(n) ~= "trigger" then return end
    if rising ~= 1 and rising ~= true then return end
    local action = TRIGGER_ACTIONS[param_value(in_id(n, "action")) or 1]
    action(param_value(in_id(n, "voice")) or 0)
  end)

  -- crow1 and crow2: an input in cv mode, over its range param's volts
  for n = 1, SPEC.inputs do
    state.input_ranges[n] = parse_range(SPEC.input_ranges[1])
    S.register_mod_source({key = "crow" .. n, name = "CR" .. n, section = "crow", range = state.input_ranges[n],
      value = function() return state.input_volts[n] end,
      describe = function()
        local volts = state.input_volts[n]
        return volts and string.format("%.2f V", volts) or "--"
      end,
      visible = function() return input_mode(n) == "cv" end})
  end

  ---------------------------------------------------------------------------
  -- Outputs: followed sources, from the LFO clock's step
  ---------------------------------------------------------------------------

  local function follow(n)
    local source = source_of(n)
    if source.kind ~= "mod" or norns_output(n) then return end
    local range = output_range(n)
    local span = range[2] - range[1]
    local volts = range[1] + S.lib.mod_sources.fraction(source.key) * span
    local last = state.last_volts[n]
    if last ~= nil and math.abs(volts - last) <= span * CROW.follow_fraction then return end
    state.last_volts[n] = volts
    M.send_value("out" .. n, volts_line(n, volts))
  end

  S.lib.lfos.on_step(function()
    if not active() then return end
    follow_owners()
    for n = 1, SPEC.outputs do follow(n) end
  end)

  ---------------------------------------------------------------------------
  -- The note target crow: one note at a time per voice, the newest
  ---------------------------------------------------------------------------

  local function voice_outputs(voice, fn)
    for n = 1, SPEC.outputs do
      local source = source_of(n)
      if source.voice == voice and not norns_output(n) then fn(n, source.kind) end
    end
  end

  local function valid_voice(voice)
    return type(voice) == "number" and state.notes[voice] ~= nil
  end

  local function forget_note(notes, id)
    for index, note in ipairs(notes) do
      if note.id == id then
        table.remove(notes, index)
        return index
      end
    end
    return nil
  end

  S.register_note_target({name = "crow",
    routed = function(voice)
      for n = 1, SPEC.outputs do
        if source_of(n).voice == voice and not norns_output(n) then return true end
      end
      return false
    end,
    note_on = function(voice, id, pitch)
      if not valid_voice(voice) or type(pitch) ~= "number" then return end
      local notes = state.notes[voice]
      forget_note(notes, id)
      local first = #notes == 0
      table.insert(notes, {id = id, pitch = pitch})
      voice_outputs(voice, function(n, kind)
        if kind == "pitch" then
          M.send_now(volts_line(n, pitch_volts(n, pitch)))
        elseif first then
          M.send_now(volts_line(n, CROW.gate_volts))
        end
      end)
    end,
    note_off = function(voice, id)
      if not valid_voice(voice) then return end
      local notes = state.notes[voice]
      local count = #notes
      local index = forget_note(notes, id)
      if not index then return end
      voice_outputs(voice, function(n, kind)
        if kind == "pitch" and index == count and #notes > 0 then
          M.send_now(volts_line(n, pitch_volts(n, notes[#notes].pitch)))
        elseif kind == "gate" and #notes == 0 then
          M.send_now(volts_line(n, 0))
        end
      end)
    end,
    stop_all = function()
      for voice = 1, NUM_VOICES do
        if #state.notes[voice] > 0 then
          state.notes[voice] = {}
          voice_outputs(voice, function(n, kind)
            if kind == "gate" then M.send_now(volts_line(n, 0)) end
          end)
        end
      end
    end,
    rows = function() return {} end,
  })

  ---------------------------------------------------------------------------
  -- Params (PSET-only, group strata_crow)
  ---------------------------------------------------------------------------

  local function build_sources()
    state.source_keys, state.source_labels, state.source_by_key = {}, {}, {}
    local function add(key, kind)
      state.source_keys[#state.source_keys + 1] = key
      state.source_labels[#state.source_labels + 1] = key
      state.source_by_key[key] = kind
    end
    add("off", OFF)
    for _, record in ipairs(S.lib.mod_sources.registered()) do add(record.key, {kind = "mod", key = record.key}) end
    for voice = 1, NUM_VOICES do add("v" .. voice .. " pitch", {kind = "pitch", voice = voice}) end
    for voice = 1, NUM_VOICES do add("v" .. voice .. " gate", {kind = "gate", voice = voice}) end
    add("clock", {kind = "clock"})
  end

  -- A route to a voice's pitch or gate changed: the targets core ends that
  -- voice's notes (lib/io/targets.lua, when it is loaded)
  local function routes_changed(n, previous)
    local voices = {}
    local before, now = state.source_by_key[previous or "off"], source_of(n)
    if before and before.voice then voices[before.voice] = true end
    if now.voice then voices[now.voice] = true end
    local targets = S.lib.io_targets
    if not (targets and targets.route_changed) then return end
    for voice = 1, NUM_VOICES do
      if voices[voice] then targets.route_changed(voice) end
    end
  end

  function M.add_params()
    build_sources()
    params:add_group("strata_crow", "crow", SPEC.param_count)
    for n = 1, SPEC.inputs do
      local function changed() apply_input(n) end
      local name = "in " .. n .. " "
      params:add_option(in_id(n, "mode"), name .. "mode", SPEC.modes, 1)
      params:add_option(in_id(n, "range"), name .. "range", SPEC.input_ranges, 1)
      params:add_option(in_id(n, "action"), name .. "action", SPEC.actions, 1)
      params:add{type = "number", id = in_id(n, "voice"), name = name .. "voice", min = 0, max = NUM_VOICES,
        default = 0, formatter = function(param)
          local voice = param:get()
          return voice == 0 and SPEC.selected_voice or tostring(voice)
        end}
      -- the action and the voice are read at each rise: no line
      for _, field in ipairs({"mode", "range"}) do params:set_action(in_id(n, field), changed) end
    end
    for n = 1, SPEC.outputs do
      local function changed() apply_output(n) end
      local name = "out " .. n .. " "
      -- kept by key, so a source registered by a later release never moves a saved choice
      S.lib.io_keyed.add(out_id(n, "source"), name .. "source", state.source_keys, state.source_labels, function(key)
        local previous = state.applied_source[n]
        state.applied_source[n] = key
        apply_output(n)
        routes_changed(n, previous)
      end)
      params:add_option(out_id(n, "range"), name .. "range", SPEC.output_ranges, 1)
      params:add_option(out_id(n, "div"), name .. "div", SPEC.divisions, SPEC.division_default)
      params:set_action(out_id(n, "range"), changed)
      params:set_action(out_id(n, "div"), changed)
    end
  end

  ---------------------------------------------------------------------------
  -- IO's crow section
  ---------------------------------------------------------------------------

  local function input_row(n)
    local label = "in " .. n
    if norns_input(n) then
      return {kind = "status", id = label, text = label .. "  " .. SPEC.norns_clock}
    end
    return {label = label, kind = "detail", id = label,
      text = function() return params:string(in_id(n, "mode")) .. "  " .. params:string(in_id(n, "range")) end,
      fields = {{label = "mode", kind = "param", param_id = in_id(n, "mode")},
        {label = "range", kind = "param", param_id = in_id(n, "range")},
        {label = "action", kind = "param", param_id = in_id(n, "action")},
        {label = "voice", kind = "param", param_id = in_id(n, "voice")}}}
  end

  -- An output following an LFO the engine runs follows Lua's model of it (decision 20): ~
  local function approximate(n)
    local source = source_of(n)
    if source.kind ~= "mod" then return false end
    local lfo = tonumber(source.key:match("^lfo(%d+)$"))
    return lfo ~= nil and S.lib.lfos.is_engine_run(lfo)
  end

  local function output_row(n)
    local label = "out " .. n
    if norns_output(n) then
      return {kind = "status", id = label, text = label .. "  " .. SPEC.norns_clock}
    end
    return {label = label, kind = "detail", id = label,
      text = function()
        return params:string(out_id(n, "source")) .. "  " .. params:string(out_id(n, "range"))
          .. (approximate(n) and SPEC.approximate or "")
      end,
      fields = {{label = "source", kind = "param", param_id = out_id(n, "source")},
        {label = "range", kind = "param", param_id = out_id(n, "range")},
        {label = "div", kind = "param", param_id = out_id(n, "div")}}}
  end

  local function plug(context) context.crow.plug() end
  local function set_option(id, text)
    for index, name in ipairs(params:lookup_param(id).options) do
      if name == text then params:set(id, index) end
    end
  end

  S.register_io_section({name = "crow", title = "crow",
    rows = function()
      local rows = {}
      for n = 1, SPEC.inputs do rows[#rows + 1] = input_row(n) end
      for n = 1, SPEC.outputs do rows[#rows + 1] = output_row(n) end
      return rows
    end,
    status = function()
      if not M.present() then return SPEC.absent end
      return nil
    end,
    layout_states = {
      {name = "without a crow", setup = function() end},
      {name = "with a crow", setup = function(context)
        plug(context)
        set_option(in_id(1, "mode"), "trigger")
        set_option(out_id(1, "source"), "v1 pitch")
        set_option(out_id(2, "source"), "pressure7")
        set_option(out_id(2, "range"), "-5..5")
      end},
      {name = "a detail list open", setup = function(context)
        plug(context)
        key(3, 1); key(3, 0)
      end},
      {name = "an output marked ~", setup = function(context)
        plug(context)
        for index, destination in ipairs(S.LFO_DESTINATIONS) do
          if destination.fast then
            S.lib.matrix.set_home(1, destination.key)
            break
          end
        end
        set_option(out_id(1, "source"), "lfo1")
      end},
      {name = "norns' clock on its jacks", setup = function(context)
        plug(context)
        params:set("clock_source", SPEC.clock_source_crow)
        params:set("clock_crow_out", 2)
      end},
    }})

  ---------------------------------------------------------------------------
  -- Start and cleanup
  ---------------------------------------------------------------------------

  -- The hot-plug handlers, set directly (norns restores its own at script
  -- clear); with a crow already there, its setup (norns' script clear has
  -- reset it)
  S.register_start(S.constants.START_ORDER.io_crow, function()
    state.started = true
    for n = 1, SPEC.outputs do state.applied_source[n] = S.lib.io_keyed.key(out_id(n, "source")) end
    remember_owners()
    norns.crow.add = function() crow_added() end
    norns.crow.remove = function() crow_removed() end
    install_events()
    if M.present() then set_up() end
  end)

  local function any_set()
    for n = 1, SPEC.inputs do
      if (param_value(in_id(n, "mode")) or 1) ~= 1 then return true end
    end
    for n = 1, SPEC.outputs do
      if source_of(n).kind ~= "off" then return true end
    end
    return false
  end

  -- The outputs to 0 V and the inputs off (only when some crow param is
  -- set), every clock ended, and the handlers made to do nothing, so a crow
  -- plugged in after cleanup gets no line (#468)
  S.register_cleanup(S.constants.CLEANUP_ORDER.io_crow, function()
    if not state.started or state.stopped then return end
    drop_all_pending()
    if budget.clock then
      S.lib.clocks.cancel(budget.clock)
      budget.clock = nil
    end
    for n = 1, SPEC.outputs do stop_output_clock(n, true) end
    if any_set() then
      for n = 1, SPEC.outputs do
        if not norns_output(n) then M.send_now(volts_line(n, 0)) end
      end
      for n = 1, SPEC.inputs do
        if not norns_input(n) then M.send_now("input[" .. n .. "].mode('none')") end
      end
    end
    state.stopped = true
    norns.crow.add = function() end
    norns.crow.remove = function() end
    for _, name in ipairs(hooks.event_order) do norns.crow.events[name] = function() end end
  end)

  return M
end
