-- test/unit/grid_test.lua
-- Grid: every layout's keys and LEDs, the 256's fader pages, hot-plug
-- (lib/grid/)
-- Run alone: lua test/run.lua grid

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value = h.load_strata, h.find_upvalue, h.local_value
local finish_startup, wake, wake_buffer_clock = h.finish_startup, h.wake, h.wake_buffer_clock

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
      if x > 10 then
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

local GRID_SIZES = {
  { name = "256", cols = 16, rows = 16 },
  { name = "128h", cols = 16, rows = 8 },
  { name = "128v", cols = 8, rows = 16 },
  { name = "64", cols = 8, rows = 8 },
}

test("every grid key on every layout and page runs without error", function()
  for _, size in ipairs(GRID_SIZES) do
    local context = load_strata()
    local device = context.grid.plug(1, size.cols, size.rows)
    -- 256 has four pages selected from row 8; other layouts are swept once
    local pages = size.name == "256" and { 1, 2, 3, 4 } or { 1 }
    for _, page in ipairs(pages) do
      for y = 1, size.rows do
        for x = 1, size.cols do
          if size.name == "256" then context.grid.press(1, 12 + page, 8, 1) end
          context.grid.press(1, x, y, 1)
          context.grid.press(1, x, y, 0)
          context.clock.advance()
        end
      end
    end
    assert_true(device.refresh_count > 0, size.name .. " grid was redrawn")
  end
end)

test("grid_redraw draws every layout (I2) and a hot-plugged grid (I3)", function()
  for _, size in ipairs(GRID_SIZES) do
    local context = load_strata()
    local device = context.grid.plug(2, size.cols, size.rows)
    local refreshes = device.refresh_count
    grid_redraw()
    assert_equal(device.refresh_count, refreshes + 1, size.name .. " redraw reaches a hot-plugged grid")
    -- voice 1 is running after init: its status LED must be lit on every layout
    local lit = false
    for x = 1, size.cols do
      for y = 1, size.rows do
        if device:get_led(x, y) >= 12 then lit = true end
      end
    end
    assert_true(lit, size.name .. " layout drew something")
  end
end)

test("grid LEDs follow non-grid state changes (I9) and the played step (M7)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  -- row 14, columns 9-15 show voice on/off; row 16 shows freeze
  toggle_voice(5)
  assert_equal(device:get_led(13, 14), 12, "voice 5 on lights row 14")
  toggle_voice(5)
  assert_equal(device:get_led(13, 14), 2, "voice 5 off dims row 14")
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(1)
  key(3, 1)  -- voice 1 is active: K3 freezes it
  assert_equal(device:get_led(1, 16), 12, "K3 freeze lights row 16")
  context.arc.plug(1)
  context.arc.push(1, 1, 1)
  assert_equal(device:get_led(1, 16), 2, "arc button unfreeze dims row 16")

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
  assert_equal(device:get_led(1, 1), 8, "scene 1 shows as populated, no longer as the current scene")
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

test("hot-plugged grid and arc fire handlers once per event (I3)", function()
  local context = load_strata()
  context.grid.plug(3, 16, 16)
  local calls = 0
  local real_grid_key = grid_key
  grid_key = function(...) calls = calls + 1; return real_grid_key(...) end
  context.grid.press(3, 1, 1, 1)
  assert_equal(calls, 1, "grid_key runs once per press")
  context.grid.unplug(3)
  context.grid.plug(3, 16, 16)
  context.grid.press(3, 1, 2, 1)
  assert_equal(calls, 2, "replugged grid still runs grid_key once per press")
  grid_key = real_grid_key

  -- compared on the raw 0-1 position: the 0.01 step quantizes the value
  local density = params:lookup_param("master_density")
  context.arc.plug(1)
  local before = density.raw
  context.arc.turn(1, 1, 20)  -- one delta of 20 -> 20/512 of the range
  assert_near(density.raw - before, 20 / 512, 1e-9, "a turn is handled once")
  context.arc.unplug(1)
  context.arc.plug(1)
  before = density.raw
  context.arc.turn(1, 1, 20)
  assert_near(density.raw - before, 20 / 512, 1e-9, "replugged arc handles a turn once")
end)

test("play/stop columns 1-4 on row 8 all light with the state (256 and 16x8)", function()
  for _, size in ipairs({ { 16, 16 }, { 16, 8 } }) do
    local context = load_strata()
    local device = context.grid.plug(1, size[1], size[2])
    for x = 1, 4 do
      assert_equal(device:get_led(x, 8), 4, size[2] .. " rows: play column " .. x .. " dim when stopped")
    end
    context.grid.press(1, 4, 8, 1)  -- column 4 starts the pattern
    assert_true(local_value("pattern_playing"), "column 4 plays")
    for x = 1, 4 do
      assert_equal(device:get_led(x, 8), 15, size[2] .. " rows: play column " .. x .. " lit while playing")
    end
    context.grid.press(1, 3, 8, 1)  -- column 3 stops it
    for x = 1, 4 do
      assert_equal(device:get_led(x, 8), 4, size[2] .. " rows: play column " .. x .. " dim after stop")
    end
  end
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
      if x > 10 then assert_equal(device:get_led(x, y), 0, "row " .. y .. " column " .. x .. " dark on page 4") end
    end
  end
  context.grid.press(1, 1, 8, 1); assert_true(local_value("pattern_playing"), "row 8 play on page 4")
  context.grid.press(1, 1, 16, 1); assert_true(local_value("frozen")[1], "row 16 freeze on page 4")
  assert_equal(device:get_led(1, 16), 12, "row 16 shows freeze on page 4")
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
    for x = 11, 16 do assert_equal(device:get_led(x, y), 0, "cols 11-16 dark") end
  end
  -- the selected source wins over "empty"
  params:set("v4_source", 9); assert_equal(device:get_led(9, 12), 15, "selected empty buffer lit 15")
  -- the recording completes: 15 -> 8
  wake_buffer_clock(context, 6); assert_equal(device:get_led(6, 1), 15, "a take waiting for the engine stays lit")
  context.polls.fire("bufferState", 503)  -- the engine reports the take
  assert_equal(device:get_led(6, 1), 8, "finished take shown as loaded")
  clear_buffer(2); assert_equal(device:get_led(2, 1), 2, "cleared buffer dim")
  -- a second row-1 press stops early; row 8 and 16 keep their meaning
  context.grid.press(1, 4, 1, 1); context.grid.press(1, 4, 1, 1)
  assert_equal(#context.calls_named("stopRecord"), 1, "second press stops the recording")
  context.grid.press(1, 3, 16, 1); assert_true(local_value("frozen")[3], "row 16 freezes on page 4")
  context.grid.press(1, 1, 8, 1); assert_true(local_value("pattern_playing"), "row 8 transport on page 4")
  -- the FX faders are still on rows 3-7
  context.grid.press(1, 16, 7, 1); assert_near(params:get("delay_mix"), 1, 1e-6, "row 7 delay mix")
  -- out-of-range columns do nothing
  context.clear_engine_calls()
  context.grid.press(1, 9, 1, 1); context.grid.press(1, 12, 2, 1); context.grid.press(1, 13, 11, 1)
  assert_equal(#context.engine_calls, 0, "columns past the buffers/sources send nothing")
  assert_equal(params:get("v3_source"), 1)
end)

end
