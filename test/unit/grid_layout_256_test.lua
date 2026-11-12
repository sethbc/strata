-- test/unit/grid_layout_256_test.lua
-- The 16x16 grid layout (lib/grid/layout_256.lua): patterns, the fader
-- page (lib/grid/faders.lua), the scene page and the buffers / FX page
-- Run alone: lua test/run.lua grid_layout_256

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, finish_startup = h.load_strata, h.find_upvalue, h.local_value, h.finish_startup
local wake, wake_buffer_clock = h.wake, h.wake_buffer_clock

test("256-grid parameter page faders set values and show them (I8)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  local press = function(x, y) context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
  press(14, 8)  -- grid page 2 (parameters)
  press(2, 14)  -- select voice 2 (fm)
  local ids = fader_param_ids(2)
  assert_equal(ids[1], "v2_freq", "first fader is freq")
  assert_equal(#ids, 6 + 6 + 9, "fm has 21 faders")
  assert_equal(fader_page_count(2), 6, "fm has 6 fader pages")
  assert_equal(ids[11], "v2_grain_env", "grain envelope follows the other grain faders")
  assert_equal(ids[12], "v2_grain_mode", "grain mode follows the envelope")
  assert_equal(fader_page_count(1), 6, "resonator has 6 fader pages")
  assert_equal(fader_page_count(3), 5, "folder has 5 fader pages")
  assert_equal(fader_page_count(4), 5, "sub has 5 fader pages")

  press(16, 9)  -- page 1 row 1 full right -> freq max
  assert_near(params:get("v2_freq"), 2000, 1, "column 16 sets max")
  press(1, 10)  -- row 2 (ratio) far left -> min
  assert_near(params:get("v2_ratio"), 0.5, 1e-6, "column 1 sets min")
  press(8, 11)  -- row 3 (index) column 8 -> linlin(1, 16, 0, 10, 8)
  assert_near(params:get("v2_index"), 70 / 15, 0.1, "column 8 sets the proportional value")
  -- LEDs: bar at 8 up to the value, value column at 15
  assert_equal(device:get_led(8, 11), 15, "value column bright")
  assert_equal(device:get_led(7, 11), 8, "bar below the value")
  assert_equal(device:get_led(9, 11), 0, "nothing above the value")
  assert_equal(device:get_led(16, 9), 15, "freq at max")
  assert_equal(device:get_led(1, 13), 15, "row 13 shows page 1 selected")

  -- exponential params follow their warp: freq (20-2000 Hz exp)
  press(1, 14)  -- select voice 1 (resonator)
  press(8, 9)   -- freq fader, column 8
  assert_near(params:get("v1_freq"), 20 * (2000 / 20) ^ (7 / 15), 1.0, "column 8 on an exp fader")
  assert_equal(device:get_led(8, 9), 15, "exp fader shows its value at column 8")
  press(4, 14)  -- select voice 4 (sub), freq 40 Hz
  assert_near(params:get("v4_freq"), 40, 1e-9, "sub freq default")
  local sub_column = fader_position("v4_freq")
  assert_true(sub_column > 1, "40 Hz shows above column 1 (got " .. sub_column .. ")")
  assert_equal(device:get_led(sub_column, 9), 15, "sub freq LED at its column")
  press(2, 14)  -- back to voice 2 (fm)
  assert_equal(device:get_led(6, 13), 4, "row 13 shows page 6 available")
  assert_equal(device:get_led(7, 13), 0, "no page 7")

  press(3, 13)  -- page 3: faders 9-12 = grain_pitch, grain_spread, grain_env, grain_mode
  assert_equal(device:get_led(3, 13), 15, "page 3 selected")
  -- grain envelope is an option param: an index fader over its 5 options
  press(16, 11)
  assert_equal(params:get("v2_grain_env"), 5, "envelope fader column 16 -> last option")
  assert_equal(device:get_led(16, 11), 15, "envelope fader shows the last option at column 16")
  press(1, 11)
  assert_equal(params:get("v2_grain_env"), 1, "envelope fader column 1 -> first option")
  press(9, 11)
  assert_equal(params:get("v2_grain_env"), 3, "envelope column 9 -> round(linlin(1,16,1,5,9))")
  assert_equal(fader_position("v2_grain_env"), 9, "option 3 of 5 shows at the middle column")
  assert_equal(device:get_led(9, 11), 15, "envelope fader LED at its option")
  -- grain mode: two options, columns 1-8 continuous, 9-16 triggered
  press(16, 12)
  assert_equal(params:get("v2_grain_mode"), 2, "mode fader column 16 -> triggered")
  press(8, 12)
  assert_equal(params:get("v2_grain_mode"), 1, "mode fader column 8 -> continuous")
  press(9, 12)
  assert_equal(params:get("v2_grain_mode"), 2, "mode fader column 9 -> triggered")
  assert_equal(device:get_led(16, 12), 15, "triggered shows at column 16")
  press(4, 13)  -- page 4: faders 13-16 = source 1, amp mod 1, freq mod 1, source 2
  press(16, 9)  -- mod source 1 -> 7 (number param, rounded)
  assert_equal(params:get("v2_mod_source_1"), 7, "mod source fader rounds to an integer")
  press(9, 9)
  assert_equal(params:get("v2_mod_source_1"), 4, "mod source column 9 -> round(linlin(1,16,0,7,9))")
  press(1, 10)  -- amp mod 1 -> -2
  assert_near(params:get("v2_mod_amp_amt_1"), -2, 1e-6, "amp mod fader min")
  press(16, 8)  -- grid page 4: rows 9-13 hold voice sources, not parameter faders
  for y = 9, 13 do
    local source = params:get("v" .. (y - 8) .. "_source")
    for x = 1, 16 do
      local level = device:get_led(x, y)
      if x == 12 then
        assert_equal(level, 3, "column 12 the freeze key on page 4")
      elseif x > 10 then
        assert_equal(level, 0, "no fader past the source columns on page 4")
      elseif x == source then
        assert_equal(level, 15, "source rows on page 4")
      else
        assert_true(level == 4 or level == 2, "source rows, not fader bars, on page 4")
      end
    end
  end
end)

test("bipolar grid faders have a column that sets exactly 0, and keep both ends (#49)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  -- 16 columns have no center: a plain sweep of -1..1 gives +/-0.07 there
  params:set("v1_source", 2)  -- a buffer voice: its faders include scan and pan
  for _, param_id in ipairs({"v1_pan", "v1_buf_scan", "v1_mod_amp_amt_1", "v1_mod_freq_amt_1"}) do
    local minval, maxval = param_range(param_id)
    local zero_column
    local previous = -math.huge
    for x = 1, 16 do
      set_param_from_column(param_id, x)
      local value = params:get(param_id)
      assert_true(value > previous, param_id .. ": column " .. x .. " sets more than column " .. (x - 1))
      previous = value
      if value == 0 then zero_column = x end
      assert_equal(fader_position(param_id), x, param_id .. ": the value set by column " .. x .. " shows there")
    end
    assert_true(zero_column ~= nil, param_id .. ": a column sets exactly 0")
    assert_equal(zero_column, 9, param_id .. ": column 9 for a symmetric range (README)")
    set_param_from_column(param_id, 1)
    assert_near(params:get(param_id), minval, 1e-9, param_id .. ": column 1 still sets the minimum")
    set_param_from_column(param_id, 16)
    assert_near(params:get(param_id), maxval, 1e-9, param_id .. ": column 16 still sets the maximum")
    params:set(param_id, 0)  -- 0 set elsewhere (PARAMS, a scene) shows at the zero column
    assert_equal(fader_position(param_id), zero_column, param_id .. ": 0 shows at its column")
  end
  -- on the grid: page 2, voice 1, fader page 2 (row 9: pan)
  context.grid.press(1, 14, 8, 1); context.grid.press(1, 1, 14, 1); context.grid.press(1, 2, 13, 1)
  params:set("v1_pan", 1)
  local pan_zero_column = (function()
    for x = 1, 16 do
      set_param_from_column("v1_pan", x)
      if params:get("v1_pan") == 0 then return x end
    end
  end)()
  params:set("v1_pan", 1)
  context.grid.press(1, pan_zero_column, 9, 1)
  assert_equal(params:get("v1_pan"), 0, "the pan fader's zero column centers the pan")
  assert_equal(device:get_led(pan_zero_column, 9), 15, "and the fader shows it there")
  -- unipolar faders keep the plain sweep: column 8 on the exp freq fader
  params:set("v1_source", 1)
  set_param_from_column("v1_freq", 8)
  assert_near(params:get("v1_freq"), 20 * (2000 / 20) ^ (7 / 15), 1.0, "column 8 on an exp fader")
end)

test("grid LEDs follow non-grid state changes (I9) and the played step (M7)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  -- row 14, columns 9-15 show voice on/off; row 16 shows the lock
  toggle_voice(5)
  assert_equal(device:get_led(13, 14), 12, "voice 5 on lights row 14")
  toggle_voice(5)
  assert_equal(device:get_led(13, 14), 2, "voice 5 off dims row 14")
  -- a lock from anywhere (MAIN's K3, the arc button, MIDI, a scene) goes
  -- through toggle_lock, which redraws the grid
  toggle_lock(1)
  assert_equal(device:get_led(1, 16), 12, "a lock lights row 16")
  toggle_lock(1)
  assert_equal(device:get_led(1, 16), 2, "an unlock dims row 16")

  -- the highlighted step is the one that just played
  toggle_pattern_step(1, 1)
  pattern_toggle()
  assert_equal(device:get_led(1, 1), 15, "step 1 highlighted while it plays")
  assert_equal(device:get_led(2, 1), 0, "step 2 not highlighted")
  assert_equal(device:get_led(1, 2), 4, "empty step under the playhead shows dim")
  pattern_toggle()

  -- page 2 faders follow mutations
  context.grid.press(1, 14, 8, 1)  -- grid page 2 (parameters)
  context.grid.press(1, 1, 14, 1)  -- voice 1
  params:set("v1_freq", 20)        -- changes the param without a grid redraw
  params:set("mutation_probability", 1)
  params:set("mutation_amount", 1)
  -- gentle_mutate visits params with pairs(), so which random draw lands on
  -- freq varies between processes; a negative draw clamps freq back to the
  -- minimum. Mutate until it moves (each try has about an even chance).
  local freq_column = 1
  for _ = 1, 40 do
    gentle_mutate()
    freq_column = fader_position("v1_freq")
    if freq_column > 1 then break end
  end
  assert_true(freq_column > 1, "mutation moved freq off the minimum")
  assert_equal(device:get_led(freq_column, 9), 15, "freq fader LED follows the mutation")

  -- grid_redraw with no grids is a no-op
  context.grid.unplug(1)
  assert_equal(next(local_value("grids")), nil, "unplug clears the grids table")
  grid_redraw()
end)

test("grid scene LEDs light the scene a sequenced instant recall loaded at once (#49)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 15, 8, 1)  -- grid page 3 (scenes)
  capture_scene(1); capture_scene(2)
  params:set("scene_sequence_length", 2)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1, 0.001)
  assert_equal(local_value("current_scene"), 1, "the sequencer recalled scene 1")
  -- at 4 s the sequencer moves on and recalls scene 2 instantly
  context.clock.run_for(4, 0.001)
  assert_equal(local_value("current_scene"), 2, "the sequencer recalled scene 2")
  assert_equal(device:get_led(2, 1), 15, "scene 2 is lit")
  assert_equal(device:get_led(1, 1), 10, "scene 1, no longer current, is the scene the sequencer recalls next (#303)")
  params:set("scene_sequencer_enabled", 0)
  -- recalls from outside the grid (MIDI-mapped, the sequencer): an instant
  -- one repaints the grid once, a smooth one lights its scene at once
  local refreshes = device.refresh_count
  recall_scene(1, 0)
  assert_equal(device.refresh_count, refreshes + 1, "an instant recall repaints the grid once")
  assert_equal(device:get_led(1, 1), 15, "scene 1 lit")
  assert_equal(device:get_led(2, 1), 8, "scene 2 no longer")
  recall_scene(2, 2)
  assert_equal(device:get_led(2, 1), 15, "a smooth recall lights its scene as it starts")
  assert_equal(device:get_led(1, 1), 8, "and dims the previous one")
  context.clock.run_for(3, 0.001)
  assert_equal(device:get_led(2, 1), 15, "scene 2 still lit after the fade")
end)

test("grid sequencer LEDs follow a length or start set outside the grid (#49)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 15, 8, 1)  -- grid page 3 (scenes)
  -- row 5: column 1 the sequencer, columns 3-10 the sequence length
  params:set("scene_sequence_length", 6)  -- PARAMS, a CC map or a PSET
  assert_equal(device:get_led(8, 5), 8, "length 6 lights column 8")
  assert_equal(device:get_led(9, 5), 2, "and not column 9")
  params:set("scene_sequence_length", 2)
  assert_equal(device:get_led(4, 5), 8, "length 2 lights column 4")
  assert_equal(device:get_led(5, 5), 2, "the LEDs past it go dark at once")
  params:set("scene_sequencer_enabled", 1)  -- started from PARAMS
  assert_equal(device:get_led(1, 5), 15, "the sequencer LED lights as it starts")
  params:set("scene_sequencer_enabled", 0)
  assert_equal(device:get_led(1, 5), 4, "and dims as it stops")
end)

test("grid page 4 shows FX faders in rows 3-7 and keeps row 8/16", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 16, 8, 1)              -- page 4
  context.grid.press(1, 16, 3, 1); assert_near(params:get("filter_freq"), 20000, 1)
  context.grid.press(1, 1, 7, 1); assert_equal(params:get("delay_mix"), 0)
  assert_equal(device:get_led(16, 3), 15, "filter freq fader at max")
  context.grid.press(1, 8, 4, 1)               -- filter res, column 8
  assert_near(params:get("filter_res"), 7 / 15, 0.01, "column 8 sets the proportional value")
  assert_equal(device:get_led(7, 4), 8, "bar below the value")
  assert_equal(device:get_led(9, 4), 0, "nothing above the value")
  local patterns = local_value("patterns")
  assert_equal(patterns[3][16], 0, "FX fader presses do not toggle pattern steps")
  -- rows 1-2 (buffers, columns 1-8) and 9-15 (sources, columns 1-10) are
  -- the buffer controls; the columns past them stay dark
  for x = 1, 16 do
    for _, y in ipairs({ 1, 2 }) do
      if x > 8 then assert_equal(device:get_led(x, y), 0, "row " .. y .. " column " .. x .. " dark on page 4") end
    end
    for y = 9, 15 do
      if x > 10 and x ~= 12 then assert_equal(device:get_led(x, y), 0, "row " .. y .. " column " .. x .. " dark on page 4") end
    end
  end
  context.grid.press(1, 1, 8, 1); assert_true(local_value("pattern_playing"), "row 8 play on page 4")
  context.grid.press(1, 1, 16, 1); assert_true(local_value("frozen")[1], "row 16 locks on page 4")
  assert_equal(device:get_led(1, 16), 12, "row 16 shows the lock on page 4")
  assert_equal(device:get_led(16, 8), 15, "row 8 shows page 4 selected")
  -- FX changes made elsewhere move the faders
  params:set("delay_mix", 1)
  assert_equal(device:get_led(16, 7), 15, "delay mix fader follows a param change")
end)

test("a scene transition redraws the grid once per step on grid page 4", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 16, 8, 1)              -- page 4: the FX faders
  local fx = { filter_freq = 1000, filter_res = 0.2, filter_mix = 0.6, delay_time = 0.8,
    delay_feedback = 0.7, delay_mix = 0.5 }
  for id, value in pairs(fx) do params:set(id, value) end
  capture_scene(1)
  for id, value in pairs(fx) do params:set(id, value / 2) end
  recall_scene(1, 4)                           -- step 1 runs now
  for step = 2, 20 do
    local refreshes = device.refresh_count
    wake(context, "scene_transition_clock")
    assert_equal(device.refresh_count - refreshes, 1, "one grid redraw at step " .. step)
  end
  wake(context, "scene_transition_clock")                      -- the end: the instant recall
  assert_near(params:get("filter_freq"), 1000, 1, "transition landed")
  -- outside a transition each FX change still moves the faders at once
  local refreshes = device.refresh_count
  params:set("delay_mix", 0.1)
  assert_equal(device.refresh_count - refreshes, 1, "an FX edit redraws the grid")
end)

test("buffer faders replace synth faders for a buffer-sourced voice", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  local press = function(x, y) context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
  press(14, 8); press(1, 14)            -- grid page 2, voice 1 (resonator: 6 fader pages)
  press(6, 13); assert_equal(local_value("param_page"), 6)
  params:set("v1_source", 2)
  local ids = fader_param_ids(1)
  assert_equal(ids[1], "v1_buf_pos"); assert_equal(ids[2], "v1_buf_rate")
  assert_equal(ids[3], "v1_buf_scan"); assert_equal(ids[4], "v1_amp")
  assert_equal(ids[5], "v1_pan", "pan follows the level (the engine pans buffer voices)")
  assert_equal(ids[6], "v1_grain_size", "grain faders follow")
  assert_equal(#ids, 5 + 6 + 9); assert_equal(fader_page_count(1), 5)
  assert_equal(local_value("param_page"), 5, "fader page clamped when the source shrinks the list")
  press(1, 13); press(16, 10)           -- page 1, row 2 = buf_rate max
  assert_near(params:get("v1_buf_rate"), 4, 1e-6, "buf_rate fader")
  assert_equal(device:get_led(16, 10), 15)
  -- page 2, row 1 = pan: column 1 pans hard left, and a running voice's engine gets it
  context.clock.advance()   -- voice 1 running
  context.clear_engine_calls()
  press(2, 13); press(1, 9)
  assert_near(params:get("v1_pan"), -1, 1e-6, "pan fader column 1 = hard left")
  assert_equal(device:get_led(1, 9), 15, "the pan fader shows its value")
  local sent
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 0 and call.args[2] == "pan" then sent = call.args[3] end
  end
  assert_near(sent, -1, 1e-6, "a buffer-sourced voice's pan reaches the engine")
  -- sub has no pan param: its buffer faders end at the level
  params:set("v4_source", 2)
  ids = fader_param_ids(4)
  assert_equal(ids[4], "v4_amp"); assert_equal(ids[5], "v4_grain_size", "sub has no pan fader")
  params:set("v1_source", 1)
  assert_equal(fader_param_ids(1)[1], "v1_freq", "synth faders return")
end)

test("grid page 4 buffer rows record, clear and set sources with LED feedback", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  context.grid.press(1, 5, 1, 1); assert_equal(context.calls_named("recordBuffer")[1].args[1], 4)
  assert_equal(device:get_led(5, 1), 15)
  context.grid.press(1, 3, 10, 1); assert_equal(params:get("v2_source"), 3); assert_equal(device:get_led(3, 10), 15)
  context.grid.press(1, 10, 15, 1); assert_equal(params:get("v7_source"), 10)
  context.grid.press(1, 5, 2, 1); assert_equal(context.calls_named("clearBuffer")[1].args[1], 4)
end)

test("grid page 4 buffer LEDs: row 1 state, row 2, source rows, and non-grid changes", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  load_buffer(2, "/tmp/a.wav")              -- loaded, not from the grid
  params:set("record_duration", 2); params:set("buf6_record", 1)  -- recording, from params
  params:set("v1_source", 3)                -- voice 1 on buf 2
  for slot = 1, 8 do
    local expected = slot == 6 and 15 or (slot == 2 and 8 or 2)
    assert_equal(device:get_led(slot, 1), expected, "row 1 buffer " .. slot)
    assert_equal(device:get_led(slot, 2), 4, "row 2 clear " .. slot)
  end
  for voice_idx = 1, 7 do
    local y = 8 + voice_idx
    local source = params:get("v" .. voice_idx .. "_source")
    for x = 1, 10 do
      local expected
      if x == source then expected = 15
      elseif x >= 2 and x <= 9 and x - 1 ~= 2 and x - 1 ~= 6 then expected = 2
      else expected = 4 end
      assert_equal(device:get_led(x, y), expected, "voice " .. voice_idx .. " source col " .. x)
    end
    for x = 11, 16 do
      if x ~= 12 then assert_equal(device:get_led(x, y), 0, "cols 11 and 13-16 dark") end
    end
  end
  -- the selected source wins over "empty"
  params:set("v4_source", 9); assert_equal(device:get_led(9, 12), 15, "selected empty buffer lit 15")
  -- the recording completes: 15 -> 8
  wake_buffer_clock(context, 6); assert_equal(device:get_led(6, 1), 15, "a take waiting for the engine stays lit")
  context.polls.fire("bufferState", 5003)  -- the engine reports the take
  assert_equal(device:get_led(6, 1), 8, "finished take shown as loaded")
  clear_buffer(2); assert_equal(device:get_led(2, 1), 2, "cleared buffer dim")
  -- a second row-1 press stops early; row 8 and 16 keep their meaning
  context.grid.press(1, 4, 1, 1); context.grid.press(1, 4, 1, 1)
  assert_equal(#context.calls_named("stopRecord"), 1, "second press stops the recording")
  context.grid.press(1, 3, 16, 1); assert_true(local_value("frozen")[3], "row 16 locks on page 4")
  context.grid.press(1, 1, 8, 1); assert_true(local_value("pattern_playing"), "row 8 transport on page 4")
  -- the FX faders are still on rows 3-7
  context.grid.press(1, 16, 7, 1); assert_near(params:get("delay_mix"), 1, 1e-6, "row 7 delay mix")
  -- out-of-range columns do nothing
  context.clear_engine_calls()
  context.grid.press(1, 9, 1, 1); context.grid.press(1, 12, 2, 1); context.grid.press(1, 13, 11, 1)
  assert_equal(#context.engine_calls, 0, "columns past the buffers/sources send nothing")
  assert_equal(params:get("v3_source"), 1)
end)

-- #449: the distinct keys the layout is handed at press, per grid page, from
-- now on (view(port) names it), and how many there are
local function record_presses(layout_name, view)
  local layout = local_value("S").registry.grid_layouts[layout_name]
  local real_key, pressed = layout.key, {}
  layout.key = function(port, x, y, z)
    if z == 1 then
      local shown = view(port)
      pressed[shown] = pressed[shown] or {}
      pressed[shown][x .. "," .. y] = true
    end
    return real_key(port, x, y, z)
  end
  return pressed
end
local function key_count(keys)
  local count = 0
  for _ in pairs(keys or {}) do count = count + 1 end
  return count
end

-- Voice 1 on buffer 1, which holds 16 s, so position keys act (#449)
local function voice_on_loaded_buffer(S)
  S.buffers[1].seconds = 16; S.buffers[1].loaded = true
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
end

-- Counts S.lib.positions.jump calls (a position key that reached a buffer voice)
local function count_jumps(S)
  local counter = { jumps = 0 }
  local real_jump = S.lib.positions.jump
  S.lib.positions.jump = function(...) counter.jumps = counter.jumps + 1; return real_jump(...) end
  return counter
end

test("every 256 grid key on every page runs without error", function()
  local context = load_strata()
  local S = local_value("S")
  local device = context.grid.plug(1, 16, 16)
  local pressed = record_presses("256", function(port) return S.lib.grid_core.page(port) end)
  local counter = count_jumps(S)
  -- all five pages, each key pressed on its page (set before every key: row
  -- 8's page keys move it), with a voice on a loaded buffer
  for page = 1, 5 do
    voice_on_loaded_buffer(S)
    for y = 1, 16 do
      for x = 1, 16 do
        S.lib.grid_core.set_page(1, page)
        assert_equal(S.lib.grid_core.page(1), page, "the sweep is on page " .. page)
        context.grid.press(1, x, y, 1)
        context.grid.press(1, x, y, 0)
        context.clock.advance()
      end
    end
  end
  for page = 1, 5 do assert_equal(key_count(pressed[page]), 256, "page " .. page .. ": all 256 keys pressed") end
  assert_true(counter.jumps > 0, "page 5's position keys reached the buffer voice")
  assert_true(device.refresh_count > 0, "256 grid was redrawn")
end)

test("grid_redraw draws the 256 layout (I2), on a hot-plugged grid too (I3)", function()
  local context = load_strata()
  local device = context.grid.plug(2, 16, 16)
  local refreshes = device.refresh_count
  grid_redraw()
  assert_equal(device.refresh_count, refreshes + 1, "256 redraw reaches a hot-plugged grid")
  -- voice 1 is running after init: its status LED must be lit
  local lit = false
  for x = 1, 16 do
    for y = 1, 16 do
      if device:get_led(x, y) >= 12 then lit = true end
    end
  end
  assert_true(lit, "256 layout drew something")
end)

test("play/stop columns 1-4 on row 8 all light with the state (256)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  for x = 1, 4 do
    assert_equal(device:get_led(x, 8), 4, "16 rows: play column " .. x .. " dim when stopped")
  end
  context.grid.press(1, 4, 8, 1)  -- column 4 starts the pattern
  assert_true(local_value("pattern_playing"), "column 4 plays")
  for x = 1, 4 do
    assert_equal(device:get_led(x, 8), 15, "16 rows: play column " .. x .. " lit while playing")
  end
  context.grid.press(1, 3, 8, 1)  -- column 3 stops it
  for x = 1, 4 do
    assert_equal(device:get_led(x, 8), 4, "16 rows: play column " .. x .. " dim after stop")
  end
end)


-- 3.1: copy/paste on row 16, tempo key feedback, the scene page's
-- sequencer position and the lock keys

local function S_table() return local_value("S") end
local function tap(context, x, y)
  context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0)
end
local function copy_of(steps)
  local copy = {}
  for step, level in ipairs(steps) do copy[step] = level end
  return copy
end

test("row 16 copies a pattern and pastes it onto another voice", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local patterns = local_value("patterns")
  for x = 9, 16 do assert_equal(device:get_led(x, 16), 2, "column " .. x .. " dim with no clipboard") end
  patterns[1][1], patterns[1][4], patterns[1][9] = 15, 7, 1
  local copied = copy_of(patterns[1])
  tap(context, 9, 16)
  local clipboard = S_table().lib.grid_core.port_state(1).clipboard
  assert_equal(clipboard.voice, 1, "column 9 copies voice 1")
  assert_equal(device:get_led(9, 16), 15, "the copied voice's key lights")
  assert_equal(device:get_led(11, 16), 4, "the paste targets show")
  assert_equal(device:get_led(16, 16), 4, "the clear key shows")
  -- the clipboard is a snapshot: a later edit of voice 1 does not change it
  patterns[1][16] = 15
  tap(context, 11, 16)
  for step = 1, 16 do
    assert_equal(patterns[3][step], copied[step], "voice 3 step " .. step .. " pasted")
  end
  assert_true(patterns[3] ~= patterns[1], "the paste copies the levels, not the table")
  assert_equal(patterns[2][1], 0, "voice 2 untouched")
  assert_equal(S_table().lib.grid_core.port_state(1).clipboard.voice, 1, "the clipboard stays")
  tap(context, 15, 16)
  assert_equal(patterns[7][4], 7, "a second paste onto voice 7")
  -- pasting into a voice and then editing it leaves the clipboard alone
  patterns[7][4] = 0
  tap(context, 12, 16)
  assert_equal(patterns[4][4], 7, "the clipboard kept its own levels")
  tap(context, 16, 16)
  assert_equal(S_table().lib.grid_core.port_state(1).clipboard, nil, "column 16 clears the clipboard")
  for x = 9, 16 do assert_equal(device:get_led(x, 16), 2, "column " .. x .. " back to 2") end
  -- with the clipboard empty, column 16 does nothing and a voice key copies again
  tap(context, 16, 16)
  assert_equal(S_table().lib.grid_core.port_state(1).clipboard, nil, "clearing an empty clipboard")
  tap(context, 10, 16)
  assert_equal(S_table().lib.grid_core.port_state(1).clipboard.voice, 2, "column 10 copies voice 2")
end)

test("a paste ends the step-level gesture of the voice it lands on", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  local small = context.grid.plug(2, 16, 8)
  local patterns = local_value("patterns")
  patterns[1][5], patterns[1][6] = 3, 0
  local copied = copy_of(patterns[1])
  tap(context, 9, 16)  -- copy voice 1
  context.grid.press(1, 5, 3, 1)  -- hold voice 3 step 5 (it toggles at its release)
  context.grid.press(2, 6, 3, 1)  -- and step 6 on the 16x8
  context.grid.press(1, 6, 2, 1)  -- hold voice 2 step 6: no paste lands there
  tap(context, 11, 16)  -- paste onto voice 3
  assert_equal(patterns[3][5], copied[5], "the paste set step 5")
  -- a second key on voice 3's row toggles its own step, as with nothing held
  context.grid.press(1, 12, 3, 1)
  assert_equal(patterns[3][5], copied[5], "the held step keeps the pasted level")
  context.grid.press(1, 12, 3, 0); context.grid.press(1, 5, 3, 0)
  assert_equal(patterns[3][12], 15, "the new key toggles step 12")
  assert_equal(patterns[3][5], copied[5], "the held step's release toggles nothing")
  context.grid.press(2, 14, 3, 1)
  assert_equal(patterns[3][6], copied[6], "the 16x8's held step keeps the pasted level")
  context.grid.press(2, 14, 3, 0); context.grid.press(2, 6, 3, 0)
  assert_equal(patterns[3][14], 15, "and its new key toggles step 14")
  assert_equal(patterns[3][6], copied[6], "and its held step's release toggles nothing")
  -- the other voice's gesture still works
  context.grid.press(1, 16, 2, 1)
  assert_equal(patterns[2][6], 15, "voice 2's held step takes column 16's level")
  assert_equal(patterns[2][16], 0, "and the level key does not toggle")
  context.grid.press(1, 16, 2, 0); context.grid.press(1, 6, 2, 0)
  assert_equal(small:get_led(6, 3), patterns[3][6], "the 16x8 shows the pasted step")
end)

test("pasting onto the copied voice changes nothing", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local patterns = local_value("patterns")
  patterns[2][3] = 15
  tap(context, 10, 16)
  patterns[2][5] = 9  -- an edit after the copy
  tap(context, 10, 16)
  assert_equal(patterns[2][5], 9, "the copied voice keeps its own pattern")
  assert_equal(patterns[2][3], 15)
  assert_equal(S_table().lib.grid_core.port_state(1).clipboard.voice, 2, "the clipboard stays on voice 2")
  assert_equal(device:get_led(10, 16), 15, "and stays lit")
end)

test("the clipboard is per grid, works on pages 2, 3 and 4 and goes with the grid", function()
  local context = load_strata(); finish_startup(context)
  local first = context.grid.plug(1, 16, 16)
  local second = context.grid.plug(2, 16, 16)
  local patterns = local_value("patterns")
  patterns[1][2] = 15
  tap(context, 9, 16)
  assert_equal(second:get_led(9, 16), 2, "the other grid has no clipboard")
  context.grid.press(2, 11, 16, 1); context.grid.press(2, 11, 16, 0)
  assert_equal(S_table().lib.grid_core.port_state(2).clipboard.voice, 3, "a key on grid 2 copies there")
  assert_equal(patterns[3][2], 0, "and pastes nothing from grid 1's clipboard")
  tap(context, 14, 8)  -- grid 1 page 2
  tap(context, 12, 16)
  assert_equal(patterns[4][2], 15, "page 2 pastes")
  tap(context, 16, 8)  -- page 4
  tap(context, 13, 16)
  assert_equal(patterns[5][2], 15, "page 4 pastes")
  assert_equal(first:get_led(9, 16), 15, "page 4 shows the clipboard")
  tap(context, 15, 8)  -- page 3, the scenes page, has row 16 too (#442)
  tap(context, 14, 16)
  assert_equal(patterns[6][2], 15, "page 3 pastes")
  context.grid.unplug(1)
  first = context.grid.plug(1, 16, 16)
  assert_equal(S_table().lib.grid_core.port_state(1).clipboard, nil, "unplugging forgets the clipboard")
  assert_equal(first:get_led(9, 16), 2)
end)

test("tempo keys light while held and flash the new tempo in the header", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  params:set("tempo", 120)
  for x = 5, 8 do assert_equal(device:get_led(x, 8), 4, "tempo key " .. x .. " at 4") end
  context.grid.press(1, 8, 8, 1)
  assert_equal(params:get("tempo"), 130, "column 8 adds 10")
  assert_equal(device:get_led(8, 8), 15, "lit while held")
  assert_equal(device:get_led(7, 8), 4, "the others stay at 4")
  assert_equal(S.lib.ui_flash.text("header"), "tempo 130")
  context.grid.press(1, 8, 8, 0)
  assert_equal(device:get_led(8, 8), 4, "back to 4 on release")
  tap(context, 5, 8)
  assert_equal(S.lib.ui_flash.text("header"), "tempo 120", "column 5 subtracts 10")
  tap(context, 6, 8)
  assert_equal(S.lib.ui_flash.text("header"), "tempo 119", "column 6 subtracts 1")
  tap(context, 7, 8)
  assert_equal(S.lib.ui_flash.text("header"), "tempo 120", "column 7 adds 1")
  -- page 4 has the same row 8
  tap(context, 16, 8)
  context.grid.press(1, 6, 8, 1)
  assert_equal(device:get_led(6, 8), 15, "page 4 lights a held tempo key")
  assert_equal(S.lib.ui_flash.text("header"), "tempo 119")
  context.grid.press(1, 6, 8, 0)
  -- the play keys do not flash
  context.clock.run_for(2)
  tap(context, 1, 8)
  assert_equal(S.lib.ui_flash.text("header"), nil, "play/stop shows no tempo")
  tap(context, 1, 8)
end)

-- The internal clock reports a new tempo only once it has ticked (matron's
-- clock thread publishes it from the tick after next), so the flash shows
-- the tempo param the key set; under MIDI or crow the param sets nothing,
-- and the flash shows what the clock runs (#383)
test("256 tempo keys: the flash shows the tempo the key set on the internal clock", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  local S = S_table()
  assert_equal(clock.get_tempo(), 120, "120 BPM to start")
  tap(context, 7, 8)
  assert_equal(clock.get_tempo(), 120, "the clock has not ticked yet")
  assert_equal(S.lib.ui_flash.text("header"), "tempo 121", "the tempo the key set")
  params:set("clock_source", 3)   -- link: the param sets the session tempo
  tap(context, 7, 8)
  assert_equal(S.lib.ui_flash.text("header"), "tempo 122", "link: the tempo the key set")
end)

test("256 tempo keys: under MIDI or crow the flash shows the clock's tempo", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  local S = S_table()
  for _, source in ipairs({ 2, 4 }) do   -- midi, crow
    params:set("clock_source", source)
    clock.tempo = 97                    -- the external source's tempo
    tap(context, 7, 8)
    assert_equal(S.lib.ui_flash.text("header"), "tempo 97", params:string("clock_source") .. ": the clock's tempo")
  end
end)

-- #452: the scene keys show the core's levels (grid_core_test.lua holds
-- the rule: the next slot, the current scene, the blink)
test("256 page 3: the scene keys show the core's levels (#452)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local core = S_table().lib.grid_core
  tap(context, 15, 8)  -- page 3
  capture_scene(1); capture_scene(2); capture_scene(3)
  params:set("scene_sequence_length", 4)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1, 0.001)  -- scene 1 playing, scene 2 next
  context.grid.press(1, 5, 3, 1)
  local seen = {}
  for i = 1, 8 do
    assert_equal(device:get_led(i, 1), core.scene_recall_level(i), "recall key " .. i)
    assert_equal(device:get_led(i, 2), core.scene_fade_level(i), "fade key " .. i)
    assert_equal(device:get_led(i, 3), core.scene_save_level(1, i, 3), "save key " .. i)
    seen[device:get_led(i, 1)] = true
  end
  assert_true(seen[15] and seen[10] and seen[8] and seen[2], "the recall keys show all four levels")
  assert_equal(core.scene_save_level(1, 5, 3), 15, "scene 5's save is pending")
  context.grid.press(1, 5, 3, 0)
  params:set("scene_sequencer_enabled", 0)
end)

-- The levels of a row, columns 1-16, as one string
local function row_levels(device, y)
  local levels = {}
  for x = 1, 16 do levels[x] = device:get_led(x, y) end
  return table.concat(levels, " ")
end

test("256 page 3: rows 8 and 16 work and light as on the other pages (#442)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  tap(context, 15, 8)  -- page 3
  -- row 8: play/stop 4, tempo 4, the page keys (the positions key among
  -- them); row 16: locks 2, the freeze key 4, the clipboard keys 2
  assert_equal(row_levels(device, 8), "4 4 4 4 4 4 4 4 0 0 0 2 2 2 15 2", "row 8 on page 3")
  assert_equal(row_levels(device, 16), "2 2 2 2 2 2 2 4 2 2 2 2 2 2 2 2", "row 16 on page 3")
  tap(context, 1, 8)
  assert_true(S.pattern_playing, "(1,8) plays")
  assert_equal(device:get_led(1, 8), 15, "and lights")
  tap(context, 1, 8)
  assert_true(not S.pattern_playing, "a second press stops")
  params:set("tempo", 120)
  context.grid.press(1, 8, 8, 1)
  assert_equal(params:get("tempo"), 130, "(8,8) adds 10")
  assert_equal(device:get_led(8, 8), 15, "lit while held")
  context.grid.press(1, 8, 8, 0)
  tap(context, 1, 16)
  assert_true(S.frozen[1], "(1,16) locks voice 1")
  assert_equal(device:get_led(1, 16), 12, "and lights at 12")
  context.grid.press(1, 8, 16, 1)  -- hold the freeze key
  tap(context, 2, 16)
  assert_equal(params:get("v2_freeze"), 1, "(2,16) freezes voice 2 while (8,16) is held")
  assert_equal(device:get_led(2, 16), 15, "and shows it")
  context.grid.press(1, 8, 16, 0)
  S.patterns[1][3] = 15
  tap(context, 9, 16)
  assert_equal(S.lib.grid_core.port_state(1).clipboard.voice, 1, "(9,16) copies voice 1")
  assert_equal(device:get_led(9, 16), 15, "the copied voice's key lights")
  tap(context, 11, 16)
  assert_equal(S.patterns[3][3], 15, "(11,16) pastes onto voice 3")
  assert_equal(S.lib.grid_core.page(1), 3, "still on page 3")
end)

test("256 row 15: clear and randomize light at 2 and act only once held half a second (#443)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  for _, page in ipairs({ 1, 2 }) do
    tap(context, 12 + page, 8)
    assert_equal(row_levels(device, 15), "2 2 2 2 2 2 2 0 2 2 2 2 2 2 2 0", "page " .. page .. ": row 15's keys at 2")
  end
  tap(context, 13, 8)  -- page 1
  S.patterns[3][1], S.patterns[3][5] = 15, 9
  tap(context, 3, 15)
  assert_equal(S.patterns[3][1], 15, "a tap on (3,15) clears nothing")
  context.grid.press(1, 3, 15, 1)
  assert_equal(device:get_led(3, 15), 15, "lit 15 while the hold is pending")
  context.clock.run_for(0.4)
  context.grid.press(1, 3, 15, 0)
  assert_equal(S.patterns[3][1], 15, "released at 0.4 s: nothing cleared")
  assert_equal(device:get_led(3, 15), 2, "the release puts it back at 2")
  local real_request_redraw, screen_requests = request_redraw, 0
  request_redraw = function() screen_requests = screen_requests + 1; real_request_redraw() end
  context.grid.press(1, 3, 15, 1)
  local requests_at_press = screen_requests
  context.clock.run_for(0.4)
  assert_equal(screen_requests, requests_at_press, "nothing asks for a screen redraw while the hold is pending")
  context.clock.run_for(0.11)
  request_redraw = real_request_redraw
  assert_equal(S.patterns[3][1], 0, "held 0.5 s: voice 3's pattern is cleared")
  assert_equal(S.patterns[3][5], 0)
  assert_true(screen_requests > requests_at_press, "the screen (SEQ) is asked to show it")
  assert_equal(device:get_led(1, 3), 0, "the grid shows the cleared pattern")
  assert_equal(device:get_led(3, 15), 2, "the key is back at 2 once it has acted")
  context.grid.press(1, 3, 15, 0)
  -- (11,15) on page 2 randomizes voice 3, once held
  local randomized = {}
  local real_randomize = randomize_pattern
  randomize_pattern = function(voice_idx) table.insert(randomized, voice_idx); real_randomize(voice_idx) end
  tap(context, 14, 8)  -- page 2
  tap(context, 11, 15)
  assert_equal(#randomized, 0, "a tap on (11,15) randomizes nothing")
  context.grid.press(1, 11, 15, 1)
  assert_equal(device:get_led(11, 15), 15, "lit 15 while pending")
  context.clock.run_for(0.51)
  assert_equal(table.concat(randomized, " "), "3", "held 0.5 s: voice 3's pattern is randomized")
  assert_equal(device:get_led(11, 15), 2)
  context.grid.press(1, 11, 15, 0)
  assert_equal(#randomized, 1, "the release does nothing more")
  randomize_pattern = real_randomize
end)

test("row 16 columns 1-7 lock voices", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local frozen = local_value("frozen")
  for voice_idx = 1, 7 do
    tap(context, voice_idx, 16)
    assert_true(frozen[voice_idx], "column " .. voice_idx .. " locks voice " .. voice_idx)
    assert_equal(device:get_led(voice_idx, 16), 12, "a locked voice lights at 12")
  end
  tap(context, 3, 16)
  assert_true(not frozen[3], "a second press unlocks")
  assert_equal(device:get_led(3, 16), 2)
  tap(context, 8, 16)
  assert_equal(S_table().lib.grid_core.port_state(1).clipboard, nil, "column 8 does nothing")
  assert_equal(device:get_led(8, 16), 4, "column 8 is the freeze key (not held: 4)")
  tap(context, 14, 8)  -- page 2
  tap(context, 3, 16)
  assert_true(frozen[3], "page 2 locks too")
end)

-- A 256 on port 1, with voices 1 and 2 running
local function freeze_grid()
  local context = load_strata()
  finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  return context, device
end

local function grid_tap(context, x, y)
  context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0)
end

test("256 page 4 column 12 toggles freeze per voice with LED feedback", function()
  local context, device = freeze_grid()
  local S = local_value("S")
  grid_tap(context, 16, 8)  -- page 4
  for voice_idx = 1, S.constants.NUM_VOICES do
    local y = 8 + voice_idx
    assert_equal(device:get_led(12, y), 3, "voice " .. voice_idx .. " not frozen: 3")
    grid_tap(context, 12, y)
    assert_equal(params:get("v" .. voice_idx .. "_freeze"), 1, "column 12 row " .. y .. " freezes voice " .. voice_idx)
    assert_equal(device:get_led(12, y), 15, "frozen: 15")
    assert_equal(params:get("v" .. voice_idx .. "_source"), S.constants.SOURCE_SYNTH, "the source is left alone")
  end
  grid_tap(context, 12, 10)
  assert_equal(params:get("v2_freeze"), 0, "a second press unfreezes")
  assert_equal(device:get_led(12, 10), 3)
  -- a freeze from anywhere else (VOICE, a scene, MIDI) shows at once
  params:set("v2_freeze", 1)
  assert_equal(device:get_led(12, 10), 15, "a param change redraws the grid")
  -- columns 11 and 13-16 stay dark, and nothing else changed
  for _, x in ipairs({11, 13, 14, 15, 16}) do assert_equal(device:get_led(x, 9), 0, "column " .. x .. " dark") end
  assert_true(not local_value("frozen")[1], "freeze is not lock")
end)

test("256 page 1: holding row 16 column 8 turns row 16 columns 1-7 into freeze keys", function()
  local context, device = freeze_grid()
  local S = local_value("S")
  local frozen = local_value("frozen")
  -- without the hold: lock
  grid_tap(context, 1, 16)
  assert_true(frozen[1], "column 1 locks voice 1")
  assert_equal(params:get("v1_freeze"), 0, "and does not freeze it")
  assert_equal(device:get_led(1, 16), 12, "row 16 shows the lock")
  grid_tap(context, 1, 16)
  -- hold column 8: columns 1-7 show and toggle freeze
  context.grid.press(1, 8, 16, 1)
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(device:get_led(voice_idx, 16), 3, "voice " .. voice_idx .. " not frozen: 3")
  end
  grid_tap(context, 3, 16)
  assert_equal(params:get("v3_freeze"), 1, "column 3 freezes voice 3 while column 8 is held")
  assert_true(not frozen[3], "and does not lock it")
  assert_equal(device:get_led(3, 16), 15, "frozen: 15")
  assert_true(device:get_led(8, 16) > 0, "column 8 lights while held")
  context.grid.press(1, 8, 16, 0)
  -- released: lock again, the lock LEDs back
  assert_equal(device:get_led(3, 16), 2, "row 16 shows the lock again")
  grid_tap(context, 3, 16)
  assert_true(frozen[3], "column 3 locks once column 8 is released")
  assert_equal(params:get("v3_freeze"), 1, "the freeze stays")
  -- column 8 alone does nothing
  grid_tap(context, 8, 16)
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice_idx .. "_freeze"), voice_idx == 3 and 1 or 0)
  end
end)

test("256 lights the sounding step between steps, as SEQ does (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local device = context.grid.plug(1, 16, 16)
  local function led(voice_idx, step) return device:get_led(step, voice_idx) end
  S.patterns[1][2] = 9
  grid_redraw()
  assert_equal(led(1, 2), 9, "stopped: the stored level")
  assert_equal(led(2, 1), 0, "stopped: no playhead")
  pattern_toggle()  -- step 1 plays at once
  grid_redraw()
  assert_equal(led(2, 1), 4, "just started: step 1 is the playhead")
  assert_equal(led(2, PATTERN_LENGTH), 0, "never the last step")
  h.wake(context, "pattern_clock")  -- step 2 plays; the position is now 3
  grid_redraw()  -- a redraw between steps (a key press)
  assert_equal(S.pattern_position, 3)
  assert_equal(led(1, 2), 15, "the sounding active step at 15")
  assert_equal(led(2, 2), 4, "the sounding empty step at 4")
  assert_equal(led(2, 3), 0, "not the next step")
  assert_equal(S.lib.sequencer.sounding_step(), 2, "the step SEQ draws")
  pattern_toggle()
  assert_equal(led(1, 2), 9, "stopped: the stored level again")
  assert_equal(led(2, 2), 0)
end)

-- 3.3: page 5, the positions page, and the armed record key
local function page5_grid()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16
  local device = context.grid.plug(1, 16, 16)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v1_loop_length", 1); params:set("v1_loop_start", 0)
  return context, S, device
end

test("256: the key at x 12, y 8 shows page 5 and lights 15 there, 2 elsewhere", function()
  local context, S, device = page5_grid()
  assert_equal(S.lib.grid_core.page(1), 1)
  grid_tap(context, 12, 8)
  assert_equal(S.lib.grid_core.page(1), 5, "page 5")
  assert_equal(device:get_led(12, 8), 15, "lit on page 5")
  grid_tap(context, 13, 8)
  assert_equal(S.lib.grid_core.page(1), 1, "page 1's key is (13, 8)")
  assert_equal(device:get_led(12, 8), 2, "dim elsewhere, as the other page keys (#526)")
end)

test("256: a position press jumps and a held pair sets the loop", function()
  local context, S = page5_grid()
  grid_tap(context, 12, 8)
  grid_tap(context, 5, 1)
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-9, "the jump")
  context.grid.press(1, 5, 1, 1); context.grid.press(1, 9, 1, 1)
  context.grid.press(1, 9, 1, 0); context.grid.press(1, 5, 1, 0)
  assert_near(params:get("v1_loop_start"), 0.25, 1e-9)
  assert_near(params:get("v1_loop_length"), 0.3125, 1e-9, "the raw fraction of the exp spec or the mapped length, whichever the param holds")
  assert_near(params:get("v1_buf_pos"), 0, 1e-9)
end)

test("256: position LEDs follow grid_level for every voice", function()
  local context, S, device = page5_grid()
  grid_tap(context, 12, 8)
  local cells = S.constants.GRID_PAGES.position_cells
  for voice_idx = 1, S.constants.NUM_VOICES do
    for cell = 1, cells do
      assert_equal(device:get_led(cell, voice_idx), S.lib.positions.grid_level(voice_idx, cell, cells),
        "voice " .. voice_idx .. " cell " .. cell)
    end
  end
  for cell = 1, cells do assert_equal(device:get_led(cell, 3), 0, "voice 3 is not a buffer voice") end
  params:set("v1_buf_pos", 0.45)
  S.lib.playheads.reset(1)
  grid_redraw()
  assert_equal(device:get_led(8, 1), 15, "the playhead cell (0.45 of 16 is cell 8)")
  assert_equal(device:get_led(1, 1) < 15, true, "and not the others")
end)

test("256: rows 8 and 16 on page 5 keep their page 1 and 2 actions", function()
  local context, S, device = page5_grid()
  grid_tap(context, 12, 8)
  local playing = S.pattern_playing
  grid_tap(context, 1, 8)  -- transport: play/stop
  assert_equal(S.pattern_playing, not playing, "row 8 columns 1-4 play and stop")
  grid_tap(context, 1, 8)
  local tempo = params:get("tempo")
  grid_tap(context, 7, 8)  -- tempo +1
  assert_equal(params:get("tempo"), tempo + 1, "row 8 tempo keys")
  assert_equal(S.lib.grid_core.page(1), 5, "still page 5")
  grid_tap(context, 2, 16)
  assert_true(S.frozen[2], "row 16 columns 1-7 lock")
  assert_equal(device:get_led(2, 16), 12, "and show it")
  grid_tap(context, 2, 16)
end)

test("256: a synth voice's strip is dark and a store held with a bookmark stores nothing (#445)", function()
  local context, S, device = page5_grid()
  grid_tap(context, 12, 8)
  params:set("v1_source", 1)
  grid_redraw()
  for x = 1, 8 do assert_equal(device:get_led(x, 9), 0, "row 9, column " .. x) end
  context.grid.press(1, 6, 9, 1)
  context.grid.press(1, 2, 9, 1)
  assert_equal(device:get_led(6, 9), 0, "store held: dark")
  assert_equal(device:get_led(2, 9), 0, "the pressed bookmark: dark")
  assert_equal(params:get("v1_bookmark_2"), 0.25, "and the bookmark keeps its value")
  context.grid.press(1, 2, 9, 0); context.grid.press(1, 6, 9, 0)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  grid_redraw()
  assert_equal(device:get_led(6, 9), S.lib.positions.LEVELS.key_up, "a buffer voice's store is up")
end)

test("256: voice v's strip on row 8 + v recalls, stores, holds and restores the whole loop", function()
  local context, S, device = page5_grid()
  grid_tap(context, 12, 8)
  grid_tap(context, 2, 9)
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-9, "bookmark 2")
  params:set("v1_buf_pos", 0.6)
  context.grid.press(1, 6, 9, 1); context.grid.press(1, 3, 9, 1)
  context.grid.press(1, 3, 9, 0); context.grid.press(1, 6, 9, 0)
  assert_near(params:get("v1_bookmark_3"), 0.6, 0.05, "stored at the playhead")
  context.clear_engine_calls()
  context.grid.press(1, 7, 9, 1)
  local held
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "scanHold" then held = call.args[3] end
  end
  assert_equal(held, 1, "scanHold 1 down")
  context.grid.press(1, 7, 9, 0)
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "scanHold" then held = call.args[3] end
  end
  assert_equal(held, 0, "scanHold 0 up")
  params:set("v1_loop_length", 0.5)
  grid_tap(context, 8, 9)
  assert_near(params:get("v1_loop_start"), 0, 1e-9, "whole loop")
  assert_equal(device:get_led(8, 9), S.lib.positions.strip_level(1, "whole"))
  for y = 9, 15 do
    for x = 9, 16 do assert_equal(device:get_led(x, y), 0, "dark " .. x .. "," .. y) end
  end
end)

test("256: pages 1-4 never reach positions", function()
  local context, S = page5_grid()
  local positions = S.lib.positions
  for _, name in ipairs({"grid_key", "strip_key"}) do
    positions[name] = function() error("positions." .. name .. " called") end
  end
  for page = 1, 4 do
    grid_tap(context, 12 + page, 8)
    for y = 1, 16 do for x = 1, 16 do
      if not (y == 8 and x >= 12) then context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
    end end
  end
end)

test("256: an armed slot's record key lights 11", function()
  local context, S, device = page5_grid()
  params:set("record_sync", 3)
  grid_tap(context, 16, 8)
  assert_equal(device:get_led(1, 1), 2, "empty")
  record_buffer(1)
  context.polls.fire("recordState", 32)
  assert_equal(S.lib.record.state(1).phase, "armed")
  assert_equal(S.lib.grid_core.record_level(1), 11)
  grid_redraw()
  assert_equal(device:get_led(1, 1), 11, "armed")
  -- the engine reports recording for take 1 of slot 1: ((1 * 4) + 1) * 8 + 0
  context.polls.fire("recordState", ((1 * 4) + 1) * 8 + 0)
  assert_equal(S.lib.grid_core.record_level(1), 15, "recording")
  context.polls.fire("recordState", ((1 * 4) + 3) * 8 + 0)  -- canceled
  S.buffers[1].loaded = true
  assert_equal(S.lib.grid_core.record_level(1), 8, "loaded")
  S.buffers[1].loaded = false
  assert_equal(S.lib.grid_core.record_level(1), 2, "empty")
end)

-- #447: row 13 takes only the fader pages the voice has
test("256 row 13 past the voice's last fader page leaves the page", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local device = context.grid.plug(1, 16, 16)
  local press = function(x, y) context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
  press(14, 8)  -- page 2
  press(3, 14)  -- voice 3 (folder): 5 fader pages
  press(2, 13)
  assert_equal(S.param_page, 2, "page 2 is taken")
  press(6, 13); press(16, 13)
  assert_equal(S.param_page, 2, "pages 6 and 16 are not the voice's")
  assert_equal(device:get_led(2, 13), 15, "row 13 still shows page 2")
end)

-- The values a controller got on cc, in order, comma-joined
local function cc_echoes(controller, cc)
  local values = {}
  for _, message in ipairs(controller.sent) do
    if message[2] == cc then table.insert(values, message[3]) end
  end
  return table.concat(values, ",")
end
-- #538: norns' Binary:set sends no MIDI-map CC (only ParamSet:delta does),
-- so the sequencer key sets its binary param through set_binary_param
-- (lib/ui/params.lua), and a controller mapped to it in PARAMS > MAP
-- follows. The map is as lua/core/pmap.lua's pmap.new makes it, echo on
test("256 page 3: the sequencer key echoes to a MIDI-mapped controller (#538)", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  local controller = context.midi.plug(1)
  norns.pmap.data.scene_sequencer_enabled = { dev = 1, ch = 1, cc = 40, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  tap(context, 15, 8)   -- page 3, scenes
  tap(context, 1, 5)
  assert_equal(params:get("scene_sequencer_enabled"), 1, "(1,5) turns the sequencer on")
  tap(context, 1, 5)
  assert_equal(params:get("scene_sequencer_enabled"), 0, "and off")
  assert_equal(cc_echoes(controller, 40), "127,0", "the controller hears both")
end)


test("a grid fader runs the touch hooks once, as the grid", function()
  local context = load_strata(); finish_startup(context)
  local log = {}
  local_value("S").register_param_touch(function(param_id, source) log[#log + 1] = param_id .. ":" .. source end)
  set_param_from_column("reverb_mix", 8)
  assert_near(params:get("reverb_mix"), 7 / 15, 0.01, "column 8 sets the param")
  assert_equal(table.concat(log, " "), "reverb_mix:grid", "one touch, from the grid")
end)

-- 3.4 (design §11): page 3's columns 9-16 are scenes 9-16, row 6 columns
-- 3-10 the lengths 9-16
test("256 page 3: scenes 9-16 on columns 9-16, lengths 9-16 on row 6", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  local core = S.lib.grid_core
  tap(context, 15, 8)  -- page 3
  context.grid.press(1, 12, 3, 1)
  assert_equal(device:get_led(12, 3), 15, "a pending save of scene 12 lights at 15")
  context.clock.run_for(0.51)
  context.grid.press(1, 12, 3, 0)
  assert_true(S.scenes[12].populated, "(12,3) held 0.5 s saves scene 12")
  capture_scene(16); S.lib.scenes.set_name(16, "dusk"); grid_redraw()  -- the quantizer's label stays S16
  for i = 9, 16 do
    assert_equal(device:get_led(i, 1), core.scene_recall_level(i), "recall key " .. i)
    assert_equal(device:get_led(i, 2), core.scene_fade_level(i), "fade key " .. i)
    assert_equal(device:get_led(i, 3), core.scene_save_level(1, i, 3), "save key " .. i)
  end
  assert_equal(device:get_led(12, 1), 8, "populated scene 12 at 8")
  assert_equal(device:get_led(13, 1), 2, "empty scene 13 at 2")
  local scheduled = {}
  local real_schedule = S.lib.quantize.schedule
  S.lib.quantize.schedule = function(action_key, fn, label)
    table.insert(scheduled, action_key .. " " .. label); fn(); return true
  end
  tap(context, 16, 1)
  assert_equal(S.current_scene, 16, "(16,1) recalls scene 16 at once")
  assert_equal(device:get_led(16, 1), 15, "and lights it")
  params:set("scene_transition_time", 2)
  tap(context, 12, 2)
  assert_true(S.scene_transition_active and S.SCENE_TRANSITION.target == 12, "(12,2) fades to scene 12")
  S.lib.quantize.schedule = real_schedule
  assert_equal(table.concat(scheduled, ","), "scene S16,scene S12", "both recalls go through the quantizer")
  context.clock.run_for(2.5)
  -- the sequence lengths: row 5 1-8, row 6 9-16, columns 3-10
  tap(context, 10, 6); assert_equal(params:get("scene_sequence_length"), 16, "(10,6) length 16")
  tap(context, 3, 6); assert_equal(params:get("scene_sequence_length"), 9, "(3,6) length 9")
  tap(context, 10, 5); assert_equal(params:get("scene_sequence_length"), 8, "(10,5) still length 8")
  tap(context, 6, 6); assert_equal(params:get("scene_sequence_length"), 12, "(6,6) length 12")
  assert_equal(row_levels(device, 5), "4 0 8 8 8 8 8 8 8 8 0 0 0 0 0 0", "row 5: lengths 1-8 within it")
  assert_equal(row_levels(device, 6), "0 0 8 8 8 8 2 2 2 2 0 0 0 0 0 0", "row 6: 9-12 within it, 13-16 beyond")
  tap(context, 11, 6); tap(context, 2, 6)
  assert_equal(params:get("scene_sequence_length"), 12, "row 6 past columns 3-10 does nothing")
end)

-- 3.4 (design §11): page 1's row 9 holds the gesture recorders (columns
-- 1-4: a press is gestures.press, a 0.5 s hold clears; LEDs empty 2,
-- stopped 5, playing 10, recording 15) and the macro bank keys (columns
-- 13-16: shown 15, a bank with targets 6, empty 2)
test("page 1's row 9 presses and clears the recorders and picks the macro bank", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  local gestures = S.lib.gestures
  assert_equal(row_levels(device, 9):sub(1, 7), "2 2 2 2", "four empty recorders at 2")
  context.grid.press(1, 2, 9, 1)
  assert_equal(gestures.state(2), "empty", "a press alone does nothing (ruling 73)")
  context.grid.press(1, 2, 9, 0)
  assert_equal(gestures.state(2), "recording", "its release starts recorder 2")
  assert_equal(device:get_led(2, 9), 15, "recording: 15")
  tap(context, 8, 10)  -- a macro fader: an event for the recording
  tap(context, 2, 9)
  assert_equal(gestures.state(2), "playing", "a press plays what it recorded")
  assert_equal(device:get_led(2, 9), 10, "playing: 10")
  tap(context, 2, 9)
  assert_equal(gestures.state(2), "stopped")
  assert_equal(device:get_led(2, 9), 5, "stopped: 5")
  context.grid.press(1, 2, 9, 1)
  context.clock.run_for(0.51)
  assert_equal(gestures.state(2), "empty", "held 0.5 s: recorder 2 cleared")
  assert_equal(device:get_led(2, 9), 2)
  context.grid.press(1, 2, 9, 0)
  assert_equal(gestures.state(2), "empty", "the release after the clear does nothing")
  context.grid.press(1, 4, 9, 1); context.clock.run_for(0.3); context.grid.press(1, 4, 9, 0)
  context.clock.run_for(0.5)
  assert_equal(gestures.state(4), "recording", "a release before 0.5 s clears nothing")
  gestures.clear(4)
  -- the bank keys
  assert_equal(row_levels(device, 9):sub(-8), "15 2 2 2", "bank 1 shown, banks 2-4 without targets")
  S.lib.macros.set_target(5, 1, S.lib.macros.target_ids()[1], 0, 1)
  grid_redraw()
  assert_equal(device:get_led(14, 9), 6, "bank 2 has a target: 6")
  tap(context, 15, 9)
  assert_equal(S.lib.macros.bank(), 3, "(15,9) shows bank 3")
  assert_equal(S.lib.ui_flash.text("header"), "macros 9-12", "with set_bank's flash")
  assert_equal(row_levels(device, 9):sub(-8), "2 6 15 2", "bank 3 shown, bank 2's targets, banks 1 and 4 empty")
  for x = 5, 12 do assert_equal(device:get_led(x, 9) > 0, x <= 11, "column " .. x .. (x <= 11 and " lit" or " dark")) end
end)

-- (mute) design §8.14: row 9 columns 5-11 are voices 1-7's mute keys: a
-- release within 0.5 s toggles the mute, a 0.5 s hold the solo, both
-- through set_binary_param; LEDs muted 2, soloed 15, otherwise 8
test("page 1's row 9 columns 5-11 mute a voice on a tap and solo it on a hold", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  assert_equal(row_levels(device, 9):sub(9, 21), "8 8 8 8 8 8 8", "voices 1-7 neither muted nor soloed: 8")
  context.grid.press(1, 5, 9, 1)
  assert_equal(params:get("v1_mute"), 0, "a press alone mutes nothing")
  context.clock.run_for(0.4)
  context.grid.press(1, 5, 9, 0)
  assert_equal(params:get("v1_mute"), 1, "a release within 0.5 s mutes voice 1")
  assert_equal(params:get("v1_solo"), 0, "and solos nothing")
  assert_equal(device:get_led(5, 9), 2, "muted: 2")
  tap(context, 5, 9)
  assert_equal(params:get("v1_mute"), 0, "a second tap unmutes")
  assert_equal(device:get_led(5, 9), 8)
  context.grid.press(1, 7, 9, 1)
  context.clock.run_for(0.51)
  assert_equal(params:get("v3_solo"), 1, "held 0.5 s: voice 3 soloed")
  assert_equal(device:get_led(7, 9), 15, "soloed: 15")
  context.grid.press(1, 7, 9, 0)
  assert_equal(params:get("v3_mute"), 0, "the hold's release mutes nothing")
  assert_equal(device:get_led(5, 9), 8, "voice 1, silenced by the solo but not muted: 8")
  assert_true(S.lib.voice_mix.silenced(1), "voice 1 is silenced")
  tap(context, 7, 9)
  assert_equal(params:get("v3_mute"), 1, "a tap mutes a soloed voice")
  assert_equal(device:get_led(7, 9), 2, "muted and soloed: muted, 2")
  tap(context, 7, 9)
  context.grid.press(1, 7, 9, 1); context.clock.run_for(0.51); context.grid.press(1, 7, 9, 0)
  assert_equal(params:get("v3_solo"), 0, "a second hold unsolos")
  -- a controller mapped to v7_mute hears the tap (#538)
  local controller = context.midi.plug(1)
  norns.pmap.data["v7_mute"] = {dev = 1, cc = 30, ch = 1, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1, echo = true, value = 0}
  tap(context, 11, 9)
  assert_equal(params:get("v7_mute"), 1, "column 11 mutes voice 7")
  assert_equal(cc_echoes(controller, 30), "127", "through set_binary_param")
  norns.pmap.data["v7_mute"] = nil
end)

-- (mute) design §8.14: a silenced running voice's key lights at 6
-- (running 12, stopped 2), through the core's voice_level
test("a silenced voice's key lights at 6 on every layout", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  toggle_voice(3); toggle_voice(5)  -- voices 4, 6 and 7 stay stopped
  assert_equal(device:get_led(11, 14), 12, "voice 3 running: 12")
  params:set("v3_mute", 1)
  assert_equal(device:get_led(11, 14), 6, "voice 3 muted: 6")
  params:set("v3_mute", 0)
  params:set("v5_solo", 1)
  assert_equal(device:get_led(11, 14), 6, "voice 3 silenced by voice 5's solo: 6")
  assert_equal(device:get_led(13, 14), 12, "the soloed voice 5: 12")
  assert_equal(device:get_led(12, 14), 2, "voice 4, stopped and silenced: 2")
  params:set("v5_solo", 0)
  assert_equal(device:get_led(11, 14), 12, "the solo lifted: voice 3 at 12 again")
end)

-- 3.4 (design §4.6, §11): rows 10-13 are the shown bank's four macros,
-- faders as the others (set_param_from_column, LEDs as the fader rows')
test("rows 10-13 write the shown bank's macros and follow a bank change", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  local touches = {}
  S.register_param_touch(function(param_id, source) touches[#touches + 1] = param_id .. ":" .. source end)
  tap(context, 16, 10)
  assert_near(params:get("macro_1"), 1.0, 1e-9, "bank 1: (16,10) sets macro_1 to 1")
  assert_equal(table.concat(touches, " "), "macro_1:grid", "as a grid touch")
  tap(context, 8, 13)
  assert_near(params:get("macro_4"), 7 / 15, 1e-9, "row 13 is macro_4")
  assert_equal(row_levels(device, 10), "8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 15", "macro_1's fader at its value")
  assert_equal(row_levels(device, 13), "8 8 8 8 8 8 8 15 0 0 0 0 0 0 0 0", "macro_4's")
  S.lib.macros.set_bank(4)
  assert_equal(row_levels(device, 10), "15 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "bank 4: row 10 shows macro_13")
  tap(context, 16, 10)
  assert_near(params:get("macro_13"), 1.0, 1e-9, "after set_bank(4) the same key sets macro_13")
  assert_near(params:get("macro_1"), 1.0, 1e-9, "macro_1 keeps its value")
  -- a macro set off the grid shows at the next tick
  params:set("macro_14", 1)
  drift_update()
  assert_equal(device:get_led(16, 11), 15, "macro_14 set elsewhere: its fader follows within a tick")
  local before = device.refresh_count
  for _ = 1, 10 do drift_update() end
  assert_equal(device.refresh_count - before, 0, "ten idle ticks repaint nothing")
  -- page 2 keeps its voice faders on rows 9-12 and its page keys on row 13
  tap(context, 14, 8)
  tap(context, 16, 10)
  assert_near(params:get("macro_13"), 1.0, 1e-9, "page 2's row 10 is not a macro")
  assert_equal(device:get_led(1, 13), 15, "page 2's row 13 shows fader page 1")
end)

-- 3.4 (design §5, §11): page 3's row 4 columns 1-4 the recorders again,
-- row 7 the morph fader, row 9 picks morph_a and row 10 morph_b (chosen
-- 15, populated 6, empty 2)
test("page 3's morph fader and its A and B rows", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  capture_scene(3); capture_scene(16)
  tap(context, 15, 8)  -- page 3
  tap(context, 16, 7)
  assert_near(params:get("morph"), 1.0, 1e-9, "(16,7) moves the morph to 1")
  assert_equal(device:get_led(16, 7), 15)
  tap(context, 1, 7)
  assert_near(params:get("morph"), 0, 1e-9, "(1,7) to 0")
  assert_equal(row_levels(device, 9), "15 2 6 2 2 2 2 2 2 2 2 2 2 2 2 6", "row 9: A is scene 1; 3 and 16 populated")
  assert_equal(row_levels(device, 10), "2 15 6 2 2 2 2 2 2 2 2 2 2 2 2 6", "row 10: B is scene 2")
  tap(context, 3, 9)
  assert_equal(params:get("morph_a"), 3, "(3,9) picks scene 3 as A")
  tap(context, 16, 10)
  assert_equal(params:get("morph_b"), 16, "(16,10) picks scene 16 as B")
  assert_equal(row_levels(device, 9), "2 2 15 2 2 2 2 2 2 2 2 2 2 2 2 6")
  assert_equal(row_levels(device, 10), "2 2 6 2 2 2 2 2 2 2 2 2 2 2 2 15")
  -- picked off the grid (MOD, PARAMETERS, a PSET): shown at the next tick
  params:set("morph_b", 9)
  drift_update()
  assert_equal(device:get_led(9, 10), 15, "morph_b set elsewhere shows within a tick")
  params:set("morph", 0.5)
  drift_update()
  assert_equal(device:get_led(9, 7), 15, "and the morph's position")
  -- row 4's recorders
  tap(context, 3, 4)
  assert_equal(S.lib.gestures.state(3), "recording", "(3,4) presses recorder 3")
  assert_equal(device:get_led(3, 4), 15)
  context.grid.press(1, 3, 4, 1); context.clock.run_for(0.51); context.grid.press(1, 3, 4, 0)
  assert_equal(S.lib.gestures.state(3), "empty", "held 0.5 s: cleared")
  assert_equal(device:get_led(3, 4), 2)
  -- rows 1-3, 5 and 6 keep their scenes, sequencer and lengths
  assert_equal(device:get_led(3, 1), 8, "row 1 still recalls")
  assert_equal(device:get_led(1, 5), 4, "row 5's sequencer key")
end)

-- 3a (design §5.5): set_param_fraction sets a control at a fraction of its
-- range (in its warp's terms) and runs the touch hooks as the grid
test("set_param_fraction sets a control at a fraction of its range, as a grid touch", function()
  local context = load_strata(); finish_startup(context)
  local log = {}
  local_value("S").register_param_touch(function(param_id, source) log[#log + 1] = param_id .. ":" .. source end)
  local faders = local_value("S").lib.grid_faders
  faders.set_param_fraction("reverb_mix", 0.25)
  assert_near(params:get("reverb_mix"), 0.25, 1e-9, "a quarter of 0-1")
  faders.set_param_fraction("filter_freq", 0.5)
  assert_near(params:get("filter_freq"), 20 * 1000 ^ 0.5, 0.01, "half of 20-20000 Hz along its exp warp")
  faders.set_param_fraction("reverb_mix", 1.5)
  assert_near(params:get("reverb_mix"), 1, 1e-9, "a fraction past 1 sets the top")
  assert_equal(table.concat(log, " "), "reverb_mix:grid filter_freq:grid reverb_mix:grid", "each set one touch, from the grid")
end)

-- 3a (design §5.5): page 3's rows 11-15 x columns 12-16 are the XY pad:
-- column 12 is x = 0 and 16 x = 1, row 15 y = 0 and row 11 y = 1; LEDs the
-- cell nearest the position 15, a corner 8 with its scene populated and 2
-- without, the rest 4
test("page 3's pad sets morph and morph y, and lights the position and the corners", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  local function pad_rows()
    local rows = {}
    for y = 11, 15 do
      local levels = {}
      for x = 12, 16 do levels[#levels + 1] = device:get_led(x, y) end
      rows[#rows + 1] = table.concat(levels, " ")
    end
    return table.concat(rows, " / ")
  end
  capture_scene(1); capture_scene(4)          -- A and D hold scenes, B (2) and C (3) are empty
  local touches = {}
  S.register_param_touch(function(param_id, source) touches[#touches + 1] = param_id .. ":" .. source end)
  S.lib.gestures.press(1)                     -- recorder 1 records from the first touch
  tap(context, 15, 8)                         -- page 3
  assert_equal(pad_rows(), "2 4 4 4 8 / 4 4 4 4 4 / 4 4 4 4 4 / 4 4 4 4 4 / 15 4 4 4 2",
    "at (0, 0) A's cell is the position; D populated 8, C and B empty 2")
  tap(context, 14, 13)
  assert_near(params:get("morph"), 0.5, 1e-9, "(14,13): morph 0.5")
  assert_near(params:get("morph_y"), 0.5, 1e-9, "and morph y 0.5")
  assert_equal(pad_rows(), "2 4 4 4 8 / 4 4 4 4 4 / 4 4 15 4 4 / 4 4 4 4 4 / 8 4 4 4 2", "the center lit")
  tap(context, 16, 15)
  assert_near(params:get("morph"), 1, 1e-9, "(16,15): morph 1")
  assert_near(params:get("morph_y"), 0, 1e-9, "morph y 0")
  assert_equal(pad_rows(), "2 4 4 4 8 / 4 4 4 4 4 / 4 4 4 4 4 / 4 4 4 4 4 / 8 4 4 4 15", "B's corner is the position")
  assert_equal(table.concat(touches, " "), "morph:grid morph_y:grid morph:grid morph_y:grid", "each press touches both")
  local recorded, values = {}, {}
  for _, event in ipairs(S.gestures[1].pattern.event) do
    recorded[#recorded + 1] = event.id; values[#values + 1] = event.value
  end
  assert_equal(table.concat(recorded, " "), "morph morph_y morph morph_y", "recorder 1 recorded both axes")
  for index, value in ipairs({ 0.5, 0.5, 1, 0 }) do assert_near(values[index], value, 1e-9, "event " .. index) end
  S.lib.gestures.clear(1)
  -- set off the grid (MOD, a MIDI map, a recorder): shown at the next tick
  params:set("morph_y", 0.3); params:set("morph", 0.1)
  drift_update()
  assert_equal(device:get_led(12, 14), 15, "(0.1, 0.3): the nearest cell is column 12, row 14")
  params:set("morph_d", 2)
  drift_update()
  assert_equal(device:get_led(16, 11), 2, "D picked elsewhere: its empty scene shows")
  for y = 11, 15 do
    for x = 1, 11 do assert_equal(device:get_led(x, y), 0, "(" .. x .. "," .. y .. ") stays dark") end
  end
end)

-- design §8.9: every freeze key toggles through S.lib.freeze.toggle_quantized
test("the 256's freeze keys wait for the beat while quantize_actions is on", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  params:set("quantize_actions", 2)  -- beat
  context.clock.run_for(0.25)  -- half a beat in, at 120 BPM
  tap(context, 16, 8)  -- page 4
  tap(context, 12, 10)
  assert_equal(params:get("v2_freeze"), 0, "page 4's freeze key waits")
  assert_equal(S.lib.ui_flash.text("header"), "v2 frz at beat", "and says so")
  context.grid.press(1, 8, 16, 1); tap(context, 5, 16); context.grid.press(1, 8, 16, 0)
  assert_equal(params:get("v5_freeze"), 0, "row 16's freeze key waits too")
  context.clock.run_for(0.3)
  assert_equal(params:get("v2_freeze"), 1, "at the beat: voice 2 frozen")
  assert_equal(params:get("v5_freeze"), 1, "and voice 5")
  assert_equal(device:get_led(12, 10), 15)
end)

-- design §8.7 and §11: every key 3.3 gave a meaning keeps it; the step
-- keys' toggle moved to their release (pages 1 and 2)
test("the 256's step keys toggle on release on pages 1 and 2", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  for _, page_key in ipairs({13, 14}) do
    tap(context, page_key, 8)
    context.grid.press(1, 6, 7, 1)
    assert_equal(patterns[7][6], 0, "page " .. (page_key - 12) .. ": the press leaves voice 7's step 6")
    context.grid.press(1, 6, 7, 0)
    assert_equal(patterns[7][6], 15, "page " .. (page_key - 12) .. ": the release toggles it")
    patterns[7][6] = 0
  end
end)

-- A release acts only for the key pressed in its role. A step
-- key held into page 3 and let go on recorder 1's cell records nothing; a
-- page 2 fader key on row 9 held into page 1 and let go on a mute key
-- mutes nothing
test("a key held into another page acts there neither as a recorder nor as a mute key", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  local S = S_table()
  local patterns = local_value("patterns")
  context.grid.press(1, 1, 4, 1)  -- page 1: voice 4's step 1
  tap(context, 15, 8)             -- page 3
  context.grid.press(1, 1, 4, 0)  -- let go on recorder 1's cell
  assert_equal(S.lib.gestures.state(1), "empty", "recorder 1 records nothing")
  assert_equal(patterns[4][1], 0, "and the step is untouched")
  tap(context, 14, 8)             -- page 2
  local before = params:get("v1_mute")
  context.grid.press(1, 5, 9, 1)  -- page 2's first fader, column 5
  tap(context, 13, 8)             -- page 1
  context.grid.press(1, 5, 9, 0)  -- let go on voice 1's mute key
  assert_equal(params:get("v1_mute"), before, "voice 1's mute is untouched")
  -- pressed in their roles, both still act at their release
  tap(context, 5, 9)
  assert_equal(params:get("v1_mute"), 1, "a mute key's own tap mutes")
  tap(context, 15, 8); tap(context, 1, 4)
  assert_equal(S.lib.gestures.state(1), "recording", "a recorder key's own tap records")
  S.lib.gestures.clear(1)
end)

end
