-- test/unit/arc_pages_test.lua
-- The arc's rings on each page (lib/arc/main.lua, fx.lua, lfo.lua,
-- buffer.lua, and the VOICE, SEQ and SCENES stubs): mappings, sweeps and
-- drawing
-- Run alone: lua test/run.lua arc_pages

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, PAGE_TITLES, show_page = h.finish_startup, h.PAGE_TITLES, h.show_page

test("arc rings follow the page; MAIN mapping unchanged", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  context.arc.turn(1, 1, 20); assert_true(params:get("master_density") > 1.0, "ring 1 density on MAIN")
  -- rings drawn (with at least one segment) on each page: SETUP and the stub pages none
  local expected_rings = { MAIN = 4, VOICE = 0, SEQ = 0, FX = 4, LFO = 4, BUFFER = 4, SCENES = 0, SETUP = 0 }
  for page = 1, #PAGE_TITLES do
    show_page(page); arc_redraw()
    local drawn = 0
    for ring in pairs(device.segments) do
      assert_true(ring >= 1 and ring <= 4, "ring " .. tostring(ring) .. " exists (" .. PAGE_TITLES[page] .. ")")
      drawn = drawn + 1
    end
    assert_equal(drawn, expected_rings[PAGE_TITLES[page]], PAGE_TITLES[page] .. " rings drawn")
  end
end)

test("every arc ring lights all 64 LEDs at its maximum, about half at half, none at its minimum", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  local function set_fraction(param_id, fraction)
    local spec = params:lookup_param(param_id).controlspec
    if spec then
      params:set(param_id, spec:map(fraction))
    else
      local minval, maxval = param_range(param_id)
      params:set(param_id, util.linlin(0, 1, minval, maxval, fraction))
    end
  end
  local function lit(ring)
    local count = 0
    for _, level in ipairs(device.segments[ring].leds) do
      if level > 0 then count = count + 1 end
    end
    return count
  end
  local function check(page, ring_params, where)
    show_page(page)
    for ring, param_id in pairs(ring_params) do
      local label = where .. " ring " .. ring .. " (" .. param_id .. ")"
      set_fraction(param_id, 1); arc_redraw()
      assert_equal(lit(ring), 64, label .. " at maximum")
      set_fraction(param_id, 0.5); arc_redraw()
      assert_true(math.abs(lit(ring) - 32) <= 1, label .. " at half lights about 32, got " .. lit(ring))
      set_fraction(param_id, 0); arc_redraw()
      assert_equal(lit(ring), 0, label .. " at minimum")
    end
  end
  local voice = local_value("selected_voice")
  check("MAIN", { "master_density", main_param_id(voice),
             "v" .. voice .. "_grain_size", "v" .. voice .. "_grain_density" }, "MAIN")
  check("FX", { "filter_freq", "filter_res", "delay_time", "delay_mix" }, "FX")
  local lfo = {}
  for n = 1, local_value("NUM_LFOS") do lfo[n] = "lfo_depth_" .. n end
  local selected_lfo = local_value("selected_lfo")
  lfo[4] = "lfo_free_" .. selected_lfo
  check("LFO", lfo, "LFO")
  -- in clocked mode ring 4 shows the rate: an option param with an even
  -- number of rates has no middle index, so only its ends are checked
  params:set("lfo_mode_" .. selected_lfo, 1)
  local clocked_id = "lfo_clocked_" .. selected_lfo
  local _, slowest_rate = param_range(clocked_id)
  params:set(clocked_id, slowest_rate); arc_redraw()
  assert_equal(lit(4), 64, "LFO ring 4 (" .. clocked_id .. ") at maximum")
  params:set(clocked_id, 1); arc_redraw()
  assert_equal(lit(4), 0, "LFO ring 4 (" .. clocked_id .. ") at minimum")
  check("BUFFER", { "v" .. voice .. "_buf_pos", "v" .. voice .. "_buf_rate", "record_duration", "record_level" }, "BUFFER")
end)

test("MAIN rings 1, 3 and 4 are drawn from the param spec, like the other rings", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  show_page("MAIN")
  local voice = local_value("selected_voice")
  local function lit(ring)
    local count = 0
    for _, level in ipairs(device.segments[ring].leds) do
      if level > 0 then count = count + 1 end
    end
    return count
  end
  local rings = { [1] = "master_density", [3] = "v" .. voice .. "_grain_size", [4] = "v" .. voice .. "_grain_density" }
  for ring, param_id in pairs(rings) do
    local param = params:lookup_param(param_id)
    -- a different range: a ring with its own hardcoded range would not follow
    param.controlspec = controlspec.new(0, 10, "lin", 0.01, 5)
    for _, value in ipairs({0, 2.5, 5, 7.5, 10}) do
      params:set(param_id, value); arc_redraw()
      local expected = param_fraction(param_id) >= 1 and 64 or math.floor(param_fraction(param_id) * 64 + 0.5)
      assert_true(math.abs(lit(ring) - expected) <= 1,
        param_id .. " = " .. value .. " lights " .. expected .. " LEDs, got " .. lit(ring))
    end
  end
end)

test("every continuous arc ring sweeps its param's range in 512 ticks, following the warp", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  local _, set_selected = find_upvalue("selected_voice")
  local function sweep(page, ring, param_id, where)
    show_page(page)
    local spec = params:lookup_param(param_id).controlspec
    -- the param's step quantizes the value; step-0 params land within float error
    local tolerance = spec.step + 1e-6 * (spec.maxval - spec.minval)
    params:set(param_id, spec.minval)
    for _ = 1, 256 do context.arc.turn(1, ring, 1) end
    assert_near(params:get(param_id), spec:map(0.5), tolerance, where .. ": 256 ticks reach the warp's midpoint")
    for _ = 1, 256 do context.arc.turn(1, ring, 1) end
    assert_near(params:get(param_id), spec.maxval, tolerance, where .. ": 512 ticks reach the maximum")
    for _ = 1, 512 do context.arc.turn(1, ring, -1) end
    assert_near(params:get(param_id), spec.minval, tolerance, where .. ": 512 back reach the minimum")
  end
  assert_equal(local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 512, "half of the arc's 1024 ticks per turn")
  -- MAIN: density, every voice's main param, grain size and density
  sweep("MAIN", 1, "master_density", "MAIN ring 1")
  for voice_idx = 1, 7 do
    set_selected(voice_idx)
    sweep("MAIN", 2, main_param_id(voice_idx), "MAIN ring 2, voice " .. voice_idx)
    sweep("MAIN", 3, "v" .. voice_idx .. "_grain_size", "MAIN ring 3, voice " .. voice_idx)
    sweep("MAIN", 4, "v" .. voice_idx .. "_grain_density", "MAIN ring 4, voice " .. voice_idx)
  end
  set_selected(1)
  params:set("v1_source", 3); sweep("MAIN", 2, "v1_buf_pos", "MAIN ring 2, buffer source")
  params:set("v1_source", 10); sweep("MAIN", 2, "v1_grain_size", "MAIN ring 2, input source")
  params:set("v1_source", 1)
  for ring, param_id in ipairs({ "filter_freq", "filter_res", "delay_time", "delay_mix" }) do
    sweep("FX", ring, param_id, "FX ring " .. ring)
  end
  for ring, param_id in ipairs({ "v1_buf_pos", "v1_buf_rate", "record_duration", "record_level" }) do
    sweep("BUFFER", ring, param_id, "BUFFER ring " .. ring)
  end
  -- LFO ring 4 in free mode (the selected LFO's period); its depth rings and
  -- clocked rate keep their whole steps (the arc LFO page test)
  sweep("LFO", 4, "lfo_free_1", "LFO ring 4, free period")
end)

test("arc FX page: rings adjust filter freq/res, delay time/mix and show them", function()
  local context = load_strata()
  local device = context.arc.plug(1)
  show_page("FX")
  local density = params:get("master_density")
  for ring, param_id in ipairs({ "filter_freq", "filter_res", "delay_time", "delay_mix" }) do
    local before = params:get(param_id)
    context.arc.turn(1, ring, 100)
    next_frame(context)
    assert_true(params:get(param_id) > before, "ring " .. ring .. " raises " .. param_id)
    local spec = params:lookup_param(param_id).controlspec
    assert_near(device.segments[ring].to, spec:unmap(params:get(param_id)) * math.pi * 2, 1e-9,
      "ring " .. ring .. " shows " .. param_id)
  end
  assert_equal(params:get("master_density"), density, "density is not on the FX rings")
end)

test("arc BUFFER page: buf_pos, buf_rate, record duration and level", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local device = context.arc.plug(1)
  params:set("v1_source", 2)
  params:set("v1_buf_pos", 0.5); params:set("v1_buf_rate", 1)
  params:set("record_duration", 8); params:set("record_level", 1)
  context.arc.turn(1, 1, 20); assert_near(params:get("v1_buf_pos"), 0.5 + 20 / 512, 1e-6, "ring 1 buf_pos")
  context.arc.turn(1, 2, 100); assert_true(params:get("v1_buf_rate") > 1, "ring 2 buf_rate")
  context.arc.turn(1, 3, 100); assert_true(params:get("record_duration") > 8, "ring 3 record duration")
  context.arc.turn(1, 4, 100); assert_true(params:get("record_level") > 1, "ring 4 record level")
  next_frame(context)
  local ids = { "v1_buf_pos", "v1_buf_rate", "record_duration", "record_level" }
  for ring, param_id in ipairs(ids) do
    assert_near(device.segments[ring].to, param_fraction(param_id) * math.pi * 2, 1e-9, "ring " .. ring .. " shows " .. param_id)
  end
  assert_equal(device.segments[1].level, 15, "buffer voice: ring 1 bright")
  assert_equal(device.segments[3].level, 12)
  -- a synth voice: rings 1-2 still set its buffer params, drawn dim
  params:set("v1_source", 1); local rate = params:get("v1_buf_rate")
  context.arc.turn(1, 2, 100); assert_true(params:get("v1_buf_rate") > rate, "ring 2 still adjusts buf_rate")
  next_frame(context)
  assert_equal(device.segments[1].level, 4, "not buffer-sourced: ring 1 dim")
  assert_equal(device.segments[2].level, 4, "not buffer-sourced: ring 2 dim")
  assert_equal(device.segments[4].level, 12, "record rings stay lit")
  -- the selected voice (picked on MAIN; BUFFER's E2 picks a slot) follows
  show_page("MAIN"); enc(2, 1); show_page("BUFFER")
  local position = params:get("v2_buf_pos"); local voice1_position = params:get("v1_buf_pos")
  context.arc.turn(1, 1, 20)
  assert_true(params:get("v2_buf_pos") > position, "ring 1 follows the selected voice")
  assert_equal(params:get("v1_buf_pos"), voice1_position, "the previous voice's buf_pos is left alone")
end)

test("arc LFO page: rings 1-3 depth, ring 4 period of the selected LFO", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  show_page("LFO")
  context.arc.turn(1, 1, 100); assert_equal(params:get("lfo_depth_1"), 10, "ring 1: 10 ticks per percent")
  context.arc.turn(1, 3, 55); assert_equal(params:get("lfo_depth_3"), 5, "whole percents only")
  context.arc.turn(1, 3, 5); assert_equal(params:get("lfo_depth_3"), 6, "remainder carried")
  next_frame(context)
  assert_near(device.segments[1].to, 0.1 * math.pi * 2, 1e-9, "ring 1 shows depth")
  enc(2, 1)   -- LFO 2
  local period = params:get("lfo_free_2")
  context.arc.turn(1, 4, 100); assert_true(params:get("lfo_free_2") > period, "ring 4: free period")
  assert_equal(params:get("lfo_free_1"), 4, "only the selected LFO")
  next_frame(context)
  assert_near(device.segments[4].to, param_fraction("lfo_free_2") * math.pi * 2, 1e-9, "ring 4 shows the period")
  params:set("lfo_mode_2", 1)   -- clocked
  local rate = params:get("lfo_clocked_2")
  context.arc.turn(1, 4, -40); assert_equal(params:get("lfo_clocked_2"), rate - 2, "ring 4: clocked rate, 20 ticks a step")
  next_frame(context)
  assert_near(device.segments[4].to, param_fraction("lfo_clocked_2") * math.pi * 2, 1e-9)
end)

test("arc LFO ring 4 forgets its carried ticks when the selected LFO or its mode changes", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1); show_page("LFO")
  for n = 1, 3 do params:set("lfo_mode_" .. n, 1) end   -- clocked: 20 ticks a rate step
  local rate_1, rate_2 = params:get("lfo_clocked_1"), params:get("lfo_clocked_2")
  context.arc.turn(1, 4, 15); assert_equal(params:get("lfo_clocked_1"), rate_1, "15 ticks carried for LFO 1")
  enc(2, 1)   -- LFO 2
  context.arc.turn(1, 4, 5)
  assert_equal(params:get("lfo_clocked_2"), rate_2, "LFO 1's carried ticks do not step LFO 2")
  context.arc.turn(1, 4, 15); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "20 of its own ticks do")
  -- away and back again also forgets them
  context.arc.turn(1, 4, 15); enc(2, -1); enc(2, 1)
  context.arc.turn(1, 4, 5); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "reselecting forgets the carry")
  -- the selected LFO's mode changing forgets them
  context.arc.turn(1, 4, 10)   -- 15 carried
  params:set("lfo_mode_2", 2); params:set("lfo_mode_2", 1)
  context.arc.turn(1, 4, 5); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "a mode change forgets the carry")
  -- another LFO's mode changing does not
  context.arc.turn(1, 4, 10)   -- 15 carried
  params:set("lfo_mode_3", 2)
  context.arc.turn(1, 4, 5); assert_equal(params:get("lfo_clocked_2"), rate_2 + 2, "LFO 3's mode leaves LFO 2's carry")
  -- the depth rings keep their own remainders
  context.arc.turn(1, 1, 5); enc(2, 1); context.arc.turn(1, 1, 5)
  assert_equal(params:get("lfo_depth_1"), 1, "ring 1's carry survives a selection change")
end)

test("the stub pages' rings stay dark and ignore turns", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  for _, name in ipairs({ "VOICE", "SEQ", "SCENES" }) do
    show_page(name)
    local before = {}
    for _, param_id in ipairs({ "master_density", "v1_grain_size", "tempo", "midi_device" }) do
      before[param_id] = params:get(param_id)
    end
    for ring = 1, 4 do context.arc.turn(1, ring, 40) end
    for param_id, value in pairs(before) do
      assert_equal(params:get(param_id), value, name .. " rings leave " .. param_id)
    end
    arc_redraw()
    for ring = 1, 4 do
      for led = 1, 64 do
        assert_equal(arc_hardware.rings[ring][led], 0, name .. " ring " .. ring .. " LED " .. led .. " dark")
      end
    end
  end
end)

end
