-- test/unit/arc_pages_test.lua
-- The arc's rings on each page (lib/arc/main.lua, voice.lua, seq.lua,
-- fx.lua, lfo.lua, buffer.lua, scenes.lua): mappings, sweeps, whole-step
-- rings, MAIN's ALT rings and drawing
-- Run alone: lua test/run.lua arc_pages

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, PAGE_TITLES, show_page = h.finish_startup, h.PAGE_TITLES, h.show_page
local read_lua_sources, hint_text = h.read_lua_sources, h.hint_text

test("arc rings follow the page; MAIN mapping unchanged", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  context.arc.turn(1, 1, 20); assert_true(params:get("master_density") > 1.0, "ring 1 density on MAIN")
  -- rings drawn (with at least one segment) on each page: SETUP none,
  -- SCENES two (rings 3-4 dark); BUFFER's scan ring (bipolar, at 0) lights
  -- one LED without a segment
  local expected_rings = { MAIN = 4, VOICE = 4, SEQ = 4, FX = 4, LFO = 4, BUFFER = 3, SCENES = 2, SETUP = 0 }
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
  check("BUFFER", { "v" .. voice .. "_buf_pos", "v" .. voice .. "_loop_start", "v" .. voice .. "_loop_length" }, "BUFFER")
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
  for ring, param_id in ipairs({ "v1_buf_pos" }) do
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

-- the setGrainParam sends of one name: {voice, value}
local function grain_sends(context, name)
  local sent = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == name then table.insert(sent, {voice = call.args[1], value = call.args[3]}) end
  end
  return sent
end

local function raw_fraction(id) return params:get_raw(id) end

-- BUFFER's rings, plain and with ALT: [ring] = param id for voice 1
local BUFFER_RING_PARAMS = {
  plain = { "v1_buf_pos", "v1_loop_start", "v1_loop_length", "v1_buf_scan" },
  alt = { "v1_buf_pos", "v1_buf_rate", "scrub_friction", "record_feedback" },
}

test("every BUFFER ring sweeps its param's range in 512 ticks, plain and with ALT", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1); show_page("BUFFER")
  params:set("v1_source", 2)
  -- raw fractions follow the warp (loop_length and buf_rate are exp specs);
  -- loop_start's top stops short of 1, so its end is the value's own maximum
  local function sweep(ring, param_id, where)
    local function raw() return params:get_raw(param_id) end
    params:set_raw(param_id, 0)
    -- loop_start sits at 0 with a whole-slot loop; loop_length starts from its minimum
    for _ = 1, 256 do context.arc.turn(1, ring, 1) end
    assert_near(raw(), 0.5, 2e-3, where .. ": 256 ticks reach the middle")
    for _ = 1, 256 do context.arc.turn(1, ring, 1) end
    local reached = raw()
    if param_id == "v1_loop_start" then
      assert_true(reached > 0.99, where .. ": 512 ticks reach loop_start's top, got " .. reached)
    elseif param_id == "v1_buf_scan" then
      -- the range runs through 0, which holds for 24 ticks (docs/notes/lua/ui/detents-and-fine.md)
      assert_near(reached, 1 - 24 / 512, 4e-3, where .. ": 512 ticks reach the maximum less the 0 detent's hold")
    else
      assert_near(reached, 1, 2e-3, where .. ": 512 ticks reach the maximum")
    end
    for _ = 1, 512 do context.arc.turn(1, ring, -1) end
    assert_near(raw(), 0, 2e-3, where .. ": 512 back reach the minimum")
  end
  for ring, param_id in ipairs(BUFFER_RING_PARAMS.plain) do
    params:set("v1_loop_start", 0); params:set("v1_loop_length", 1)
    sweep(ring, param_id, "BUFFER ring " .. ring)
  end
  key(1, 1)
  for ring = 2, 4 do sweep(ring, BUFFER_RING_PARAMS.alt[ring], "BUFFER ALT ring " .. ring) end
  key(1, 0)
end)

test("BUFFER's rings light 64 LEDs at the maximum, none at the minimum; scan is bipolar; plain and ALT", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local device = context.arc.plug(1)
  params:set("v1_source", 2)
  local function lit(ring)
    local count = 0
    for x = 1, 64 do if device:get_led(ring, x) > 0 then count = count + 1 end end
    return count
  end
  local function check(ring, param_id, where)
    params:set("v1_loop_start", 0); params:set("v1_loop_length", 1)
    params:set_raw(param_id, 1); arc_redraw()
    local label = where .. " ring " .. ring .. " (" .. param_id .. ")"
    if param_id == "v1_loop_start" then
      assert_true(lit(ring) >= 63, label .. " at maximum, got " .. lit(ring))
    elseif param_id == "v1_buf_scan" then
      assert_equal(lit(ring), 32, label .. " at maximum fills a half turn clockwise")
    else
      assert_equal(lit(ring), 64, label .. " at maximum")
    end
    params:set_raw(param_id, 0.5); arc_redraw()
    if param_id == "v1_buf_scan" then
      assert_equal(lit(ring), 1, label .. " at 0 lights only the zero LED")
    else
      assert_true(math.abs(lit(ring) - 32) <= 1, label .. " at half lights about 32, got " .. lit(ring))
    end
    params:set_raw(param_id, 0); arc_redraw()
    if param_id == "v1_buf_scan" then
      assert_equal(lit(ring), 32, label .. " at minimum fills a half turn counter-clockwise")
    else
      assert_equal(lit(ring), 0, label .. " at minimum")
    end
  end
  for ring, param_id in ipairs(BUFFER_RING_PARAMS.plain) do check(ring, param_id, "BUFFER") end
  key(1, 1)
  for ring = 1, 3 do check(ring, BUFFER_RING_PARAMS.alt[ring], "BUFFER ALT") end
  -- ALT ring 4 is record_feedback at its fixed level 12
  params:set("record_feedback", 100); arc_redraw()
  assert_equal(lit(4), 64, "BUFFER ALT ring 4 at maximum")
  assert_equal(device.segments[4].level, 12)
  key(1, 0)
end)

test("ALT ring 1 holds the scan of the voice selected at each tick, once per voice", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  context.arc.plug(1)
  local S = local_value("S")
  params:set("v1_source", 2); params:set("v2_source", 2)
  context.clear_engine_calls()
  key(1, 1)
  context.arc.turn(1, 1, 1)
  S.selected_voice = 2
  context.arc.turn(1, 1, 1)
  context.arc.turn(1, 1, 1)
  local sent = grain_sends(context, "scanHold")
  assert_equal(#sent, 3, "voice 1 held, voice 1 released, voice 2 held")
  assert_equal(sent[2].voice, 0); assert_equal(sent[2].value, 0)
  assert_equal(sent[3].voice, 1); assert_equal(sent[3].value, 1)
  key(1, 0)
  sent = grain_sends(context, "scanHold")
  assert_equal(#sent, 4); assert_equal(sent[4].voice, 1, "K1 up releases the voice held now")
  assert_equal(sent[4].value, 0)
  S.selected_voice = 1
end)

test("BUFFER's rings are position, loop start, loop length and scan", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  context.arc.plug(1)
  params:set("v1_source", 2)
  params:set("v1_buf_pos", 0); params:set("v1_loop_start", 0); params:set("v1_loop_length", 1)
  local scan_low = params:get("v1_buf_scan")
  context.arc.turn(1, 1, 64); assert_near(params:get("v1_buf_pos"), 0.125, 1e-6, "ring 1 buf_pos")
  context.arc.turn(1, 2, 64); assert_near(params:get("v1_loop_start"), 0.125, 1e-6, "ring 2 loop_start")
  local length_before = raw_fraction("v1_loop_length")
  context.arc.turn(1, 3, -64)
  assert_near(raw_fraction("v1_loop_length"), length_before - 0.125, 1e-6, "ring 3 loop_length (raw fraction)")
  local scan_before = raw_fraction("v1_buf_scan")
  context.arc.turn(1, 4, 64)
  assert_near(raw_fraction("v1_buf_scan"), scan_before + 0.125, 1e-6, "ring 4 buf_scan")
  assert_true(params:get("v1_buf_scan") ~= scan_low, "buf_scan moved")
end)

test("BUFFER's ALT rings are rate, friction and record feedback", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local device = context.arc.plug(1)
  params:set("v1_source", 2)
  key(1, 1)
  local rate_before = raw_fraction("v1_buf_rate")
  context.arc.turn(1, 2, 64)
  assert_near(raw_fraction("v1_buf_rate"), rate_before + 0.125, 1e-6, "ALT ring 2 buf_rate")
  assert_equal(params:get("scrub_friction"), 100)
  context.arc.turn(1, 3, -64); assert_near(params:get("scrub_friction"), 87.5, 1e-6, "ALT ring 3 friction")
  params:set("record_feedback", 0)
  context.arc.turn(1, 4, 256); assert_near(params:get("record_feedback"), 50, 1e-6, "ALT ring 4 feedback")
  next_frame(context)
  assert_near(device.segments[4].to, math.pi, 1e-6, "half the ring")
  assert_equal(device.segments[4].level, 12, "ALT ring 4 always 12")
  assert_equal(device.segments[2].level, 15, "ALT ring 2 bright for a buffer voice")
  params:set("v1_source", 1); next_frame(context)
  assert_equal(device.segments[2].level, 4, "dim for a synth voice")
  assert_equal(device.segments[4].level, 12)
  key(1, 0)
end)

test("ring 1 with ALT holds the scan until K1 comes up, and ALT+K2 or ALT+K3 never does", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  context.arc.plug(1)
  local S = local_value("S")
  params:set("v1_source", 2); params:set("v2_source", 2)
  context.clear_engine_calls()
  key(1, 1)
  context.arc.turn(1, 1, 1)
  local holds = grain_sends(context, "scanHold")
  assert_equal(#holds, 1, "one scanHold")
  assert_equal(holds[1].voice, 0); assert_equal(holds[1].value, 1)
  context.arc.turn(1, 1, 1)
  assert_equal(#grain_sends(context, "scanHold"), 1, "a second tick sends nothing more")
  S.selected_voice = 2
  key(1, 0)
  holds = grain_sends(context, "scanHold")
  assert_equal(#holds, 2); assert_equal(holds[2].voice, 0, "released on the voice it was held on")
  assert_equal(holds[2].value, 0)
  S.selected_voice = 1
  context.clear_engine_calls()
  key(1, 1); key(2, 1); key(2, 0); key(3, 1); key(3, 0); key(1, 0)
  assert_equal(#grain_sends(context, "scanHold"), 0, "ALT+K2 and ALT+K3 never hold")
end)

test("BUFFER's ALT ring 1 holds again after the voice restarted", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  context.arc.plug(1)
  local S = local_value("S")
  params:set("v1_source", 2)
  assert_true(S.voices[1].active, "voice 1 runs")
  context.clear_engine_calls()
  key(1, 1)
  context.arc.turn(1, 1, 1)
  local holds = grain_sends(context, "scanHold")
  assert_equal(#holds, 1); assert_equal(holds[1].voice, 0); assert_equal(holds[1].value, 1, "scanHold 1")
  toggle_voice(1); toggle_voice(1)
  context.clear_engine_calls()
  context.arc.turn(1, 1, 1)
  holds = grain_sends(context, "scanHold")
  assert_equal(#holds, 1, "the restart dropped the hold: the next turn holds again")
  assert_equal(holds[1].voice, 0); assert_equal(holds[1].value, 1)
  key(1, 0)
  holds = grain_sends(context, "scanHold")
  assert_equal(#holds, 2); assert_equal(holds[2].voice, 0); assert_equal(holds[2].value, 0, "K1 up releases it")
end)

test("ring 1 starts a glide below 100% friction", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  context.arc.plug(1)
  params:set("v1_source", 2); params:set("v1_buf_pos", 0.2)
  params:set("scrub_friction", 50)
  context.clear_engine_calls()
  for _ = 1, 10 do context.clock.run_for(0.01); context.arc.turn(1, 1, 8) end
  context.clock.run_for(0.1)
  local rates = grain_sends(context, "scrubRate")
  local peak = 0
  for _, each in ipairs(rates) do peak = math.max(peak, each.value) end
  assert_true(peak > 0, "a scrubRate above 0 was sent")
  params:set("scrub_friction", 100); context.clock.run_for(5); context.clear_engine_calls()
  for _ = 1, 10 do context.clock.run_for(0.01); context.arc.turn(1, 1, 8) end
  context.clock.run_for(0.2)
  assert_equal(#grain_sends(context, "scrubRate"), 0, "100%: none sent")
end)

test("ring fills follow the params' ranges; scan is bipolar", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local device = context.arc.plug(1)
  local function lit(ring)
    local count = 0
    for x = 1, 64 do if device:get_led(ring, x) > 0 then count = count + 1 end end
    return count
  end
  params:set("v1_source", 2)
  params:set("v1_buf_pos", 0.5); params:set("v1_buf_scan", 0)
  next_frame(context)
  for ring = 1, 3 do assert_equal(device.segments[ring].level, 15, "ring " .. ring .. " bright") end
  assert_equal(device:get_led(4, 1), local_value("ARC_BIPOLAR_ZERO_LEVEL"), "ring 4 at 0: the zero LED")
  assert_near(device.segments[1].to, math.pi, 1e-6, "buf_pos 0.5 fills half ring 1")
  assert_equal(lit(4), 1, "scan 0 lights only the zero LED")
  params:set("v1_buf_scan", 2); next_frame(context)
  assert_true(lit(4) > 30, "positive scan fills clockwise")
  params:set("v1_source", 1); next_frame(context)
  for ring = 1, 4 do assert_equal(device.segments[ring].level, 4, "synth voice: ring " .. ring .. " dim") end
  assert_true(lit(4) > 30)
end)

test("arc LFO page: rings 1-3 depth, ring 4 period of the selected LFO", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  show_page("LFO"); for n = 1, 3 do params:set("lfo_depth_" .. n, 0) end   -- LFOs start at 25%
  context.arc.turn(1, 1, 100); assert_equal(params:get("lfo_depth_1"), 10, "ring 1: 10 ticks per percent")
  context.arc.turn(1, 3, 55); assert_equal(params:get("lfo_depth_3"), 5, "whole percents only")
  context.arc.turn(1, 3, 5); assert_equal(params:get("lfo_depth_3"), 6, "remainder carried")
  next_frame(context)
  assert_near(device.segments[1].to, 0.1 * math.pi * 2, 1e-9, "ring 1 shows depth")
  key(3, 1); key(3, 0)   -- LFO 2
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
  key(3, 1); key(3, 0)   -- LFO 2
  context.arc.turn(1, 4, 5)
  assert_equal(params:get("lfo_clocked_2"), rate_2, "LFO 1's carried ticks do not step LFO 2")
  context.arc.turn(1, 4, 15); assert_equal(params:get("lfo_clocked_2"), rate_2 + 1, "20 of its own ticks do")
  -- away and back again also forgets them
  context.arc.turn(1, 4, 15); key(2, 1); key(2, 0); key(3, 1); key(3, 0)
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
  context.arc.turn(1, 1, 5); key(3, 1); key(3, 0); context.arc.turn(1, 1, 5)
  assert_equal(params:get("lfo_depth_1"), 26, "ring 1's carry survives a selection change")
end)

-- LEDs lit on a ring of the arc stub
local function lit(device, ring)
  local count = 0
  for led = 1, 64 do
    if device.rings[ring][led] > 0 then count = count + 1 end
  end
  return count
end

-- A ring drawn from 0 to fraction of a turn (arc_ring_fill)
local function assert_ring_fraction(device, ring, fraction, where)
  if fraction >= 1 then
    assert_equal(lit(device, ring), 64, where .. ": all 64 LEDs at fraction 1")
  elseif fraction <= 0 then
    assert_equal(lit(device, ring), 0, where .. ": no LED at fraction 0")
  else
    assert_true(device.segments[ring], where .. ": drawn")
    assert_near(device.segments[ring].from, 0, 1e-9, where .. ": from the top")
    assert_near(device.segments[ring].to, fraction * math.pi * 2, 1e-9, where .. ": to fraction " .. fraction)
  end
end

local function assert_ring_dark(device, ring, where)
  assert_true(device.segments[ring] == nil, where .. ": no segment")
  assert_equal(lit(device, ring), 0, where .. ": every LED dark")
end

-- Put the VOICE cursor on row index through the VOICE page's place_cursor
-- (which moves its anchor, so sync_cursor keeps it there)
local function place_voice_cursor(index)
  local_value("S").lib.pages_voice.place_cursor(index)
end

test("VOICE's rings read the cursor from the cursor module, not the page", function()
  local file = assert(io.open(h.repo_root .. "/lib/arc/voice.lua", "r")); local source = file:read("*a"); file:close()
  assert_true(not source:find("pages_voice", 1, true), "lib/arc/voice.lua never calls into lib/pages/voice.lua")
  assert_true(source:find('S.lib.ui_cursors.sync("voice")', 1, true), "it syncs through S.lib.ui_cursors")
end)

test("MAIN's ALT rings are pitch, spread, level and pan", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  local S = local_value("S")
  show_page("MAIN")
  S.selected_voice = 1
  local density = params:get("v1_grain_density")
  local master_density = params:get("master_density")
  key(1, 1)
  assert_true(S.alt_held, "K1 held is ALT")
  for ring, param_id in ipairs({ "v1_grain_pitch", "v1_grain_spread", "v1_amp", "v1_pan" }) do
    local before = params:get(param_id)
    context.arc.turn(1, ring, 10)
    assert_true(params:get(param_id) > before, "ALT ring " .. ring .. " raises " .. param_id)
  end
  assert_equal(params:get("v1_grain_density"), density, "ALT ring 4 leaves grain density")
  assert_equal(params:get("master_density"), master_density, "ALT ring 1 leaves master density")
  -- pan spans 0: ring 4 draws bipolar, counter-clockwise below 0
  params:set("v1_pan", -0.5); arc_redraw()
  assert_near(device.segments[4].from, math.pi * 1.5, 1e-9, "pan -0.5 fills from three quarters")
  assert_near(device.segments[4].to, math.pi * 2, 1e-9, "up to the top")
  assert_ring_fraction(device, 3, param_fraction("v1_amp"), "ALT ring 3 shows the level")
  assert_ring_fraction(device, 1, param_fraction("v1_grain_pitch"), "ALT ring 1 shows the pitch")
  key(1, 0)
  assert_true(not S.alt_held, "K1 released")
  local pan = params:get("v1_pan")
  context.arc.turn(1, 4, 40)
  assert_true(params:get("v1_grain_density") > density, "without ALT ring 4 is grain density again")
  assert_equal(params:get("v1_pan"), pan, "and not pan")
  arc_redraw()
  assert_ring_fraction(device, 4, param_fraction("v1_grain_density"), "ring 4 shows grain density")
end)

test("MAIN's ALT pan ring is dark and ignored for Sub", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  local S = local_value("S")
  show_page("MAIN")
  S.selected_voice = 4
  assert_true(S.voices[4].params.pan == nil, "Sub has no pan")
  key(1, 1)
  local before = {}
  for _, row in ipairs(voice_page_rows(4)) do
    if row.param_id then before[row.param_id] = params:get(row.param_id) end
  end
  context.arc.turn(1, 4, 100)
  for param_id, value in pairs(before) do
    assert_equal(params:get(param_id), value, "ALT ring 4 on Sub leaves " .. param_id)
  end
  arc_redraw()
  assert_ring_dark(device, 4, "Sub's ALT ring 4")
  assert_true(device.segments[3], "ALT ring 3 (level) still drawn")
  key(1, 0)
end)

test("an input voice's MAIN ring 3 is grain pitch", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  local S = local_value("S")
  show_page("MAIN")
  S.selected_voice = 1
  params:set("v1_source", 10)   -- input
  local size, pitch = params:get("v1_grain_size"), params:get("v1_grain_pitch")
  context.arc.turn(1, 3, 40)
  assert_true(params:get("v1_grain_pitch") > pitch, "ring 3 raises grain pitch")
  assert_equal(params:get("v1_grain_size"), size, "and leaves grain size (ring 2's)")
  arc_redraw()
  assert_ring_fraction(device, 3, param_fraction("v1_grain_pitch"), "ring 3 shows grain pitch")
  -- back to the synth: ring 3 is grain size again
  params:set("v1_source", 1)
  pitch = params:get("v1_grain_pitch")
  context.arc.turn(1, 3, 40)
  assert_true(params:get("v1_grain_size") > size, "a synth voice's ring 3 is grain size")
  assert_equal(params:get("v1_grain_pitch"), pitch)
end)

test("VOICE rings follow the cursor's group of four", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  local S = local_value("S")
  S.selected_voice = 1
  show_page("VOICE")
  local function row_of(param_id)
    for index, row in ipairs(voice_page_rows(S.selected_voice)) do
      if row.param_id == param_id then return index end
    end
  end
  place_voice_cursor(row_of("v1_grain_density"))
  local group = { "v1_mod2", "v1_grain_size", "v1_grain_density", "v1_grain_pitch" }
  for ring, param_id in ipairs(group) do
    local before = {}
    for _, other in ipairs(group) do before[other] = params:get(other) end
    context.arc.turn(1, ring, 40)
    for _, other in ipairs(group) do
      if other == param_id then
        assert_true(params:get(other) > before[other], "ring " .. ring .. " raises " .. other)
      else
        assert_equal(params:get(other), before[other], "ring " .. ring .. " leaves " .. other)
      end
    end
  end
  arc_redraw()
  for ring, param_id in ipairs(group) do
    assert_ring_fraction(device, ring, param_fraction(param_id), "VOICE ring " .. ring .. " (" .. param_id .. ")")
  end
  -- an option row in the next group: one whole value per 20 ticks
  place_voice_cursor(row_of("v1_grain_env"))
  local env = params:get("v1_grain_env")
  context.arc.turn(1, 2, 19)
  assert_equal(params:get("v1_grain_env"), env, "19 ticks do not step the envelope")
  context.arc.turn(1, 2, 1)
  assert_equal(params:get("v1_grain_env"), env + 1, "the 20th steps it once")
  context.arc.turn(1, 2, -20)
  assert_equal(params:get("v1_grain_env"), env, "20 back step it back")
  -- a number row (a mod source) steps the same way
  local function ring_of(param_id)
    place_voice_cursor(row_of(param_id))
    local rows = voice_page_rows(S.selected_voice)
    local _, row_indices = voice_page_group(rows, S.cursors.voice)
    for ring, index in ipairs(row_indices) do
      if rows[index].param_id == param_id then return ring end
    end
  end
  local ring = ring_of("v1_mod_source_1")
  local source = params:get("v1_mod_source_1")
  context.arc.turn(1, ring, 45)
  assert_equal(params:get("v1_mod_source_1"), source + 2, "45 ticks: two whole steps")
  -- the carry belongs to its param: another voice's row never takes it
  context.arc.turn(1, ring, 10)   -- 15 carried for v1_mod_source_1
  S.selected_voice = 2
  ring = ring_of("v2_mod_source_1")
  local other = params:get("v2_mod_source_1")
  context.arc.turn(1, ring, 5)
  assert_equal(params:get("v2_mod_source_1"), other, "voice 1's carried ticks never step voice 2")
  context.arc.turn(1, ring, 15)
  assert_equal(params:get("v2_mod_source_1"), other + 1, "20 of its own ticks do")
end)

test("an arc ring on a binary VOICE row toggles it once per whole step", function()
  -- a registered binary row, "v<i>_probe_switch", at the end of the mix section
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    local record = { name = "probe", count = 1, scene_defaults = { probe_switch = 0 },
      discrete = { probe_switch = { 0, 1 } }, voice_rows = { section = "mix", rows = { "probe_switch" } },
      fader = false }
    function record.add(voice_idx)
      S.lib.params_setup.add_voice_extra(voice_idx, record, "probe_switch",
        { type = "binary", name = "probe switch", behavior = "toggle", default = 0 })
    end
    S.register_voice_params(record)
  end })
  finish_startup(context)
  local device = context.arc.plug(1)
  local S = local_value("S")
  S.selected_voice = 1
  show_page("VOICE")
  local rows = voice_page_rows(1)
  local index = S.lib.pages_voice.row_of("v1_probe_switch")
  assert_equal(rows[index].kind, "binary")
  place_voice_cursor(index)
  local ring
  local _, row_indices = voice_page_group(rows, S.cursors.voice)
  for n, row_index in ipairs(row_indices) do
    if row_index == index then ring = n end
  end
  assert_true(ring, "the binary row has a ring")
  arc_redraw()
  assert_ring_fraction(device, ring, 0, "off: dark")
  context.arc.turn(1, ring, 19)
  assert_equal(params:get("v1_probe_switch"), 0, "19 ticks do not switch it")
  context.arc.turn(1, ring, 1)
  assert_equal(params:get("v1_probe_switch"), 1, "the 20th turns it on")
  context.arc.turn(1, ring, 60)
  assert_equal(params:get("v1_probe_switch"), 1, "more steps up keep it on")
  arc_redraw()
  assert_ring_fraction(device, ring, 1, "on: the whole ring")
  context.arc.turn(1, ring, -20)
  assert_equal(params:get("v1_probe_switch"), 0, "a step down turns it off")
  context.arc.turn(1, ring, -40)
  assert_equal(params:get("v1_probe_switch"), 0, "and keeps it off")
end)

test("VOICE rings past the last row are dark and ignored", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  local S = local_value("S")
  show_page("VOICE")
  -- the voices and sources whose last ring group is short (from the rows,
  -- so registered rows may move it): 3.1's buffer voice 1 has two rows
  local sources = { S.constants.SOURCE_SYNTH, 2, S.constants.SOURCE_INPUT }
  local short = {}
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, source in ipairs(sources) do
      params:set("v" .. voice_idx .. "_source", source)
      local rows = voice_page_rows(voice_idx)
      local _, group = voice_page_group(rows, #rows)
      if #group < 4 then table.insert(short, { voice = voice_idx, source = source, size = #group }) end
    end
    params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH)
  end
  assert_true(#short > 0, "some voice has a short last group")
  for _, case in ipairs(short) do
    local where = "voice " .. case.voice .. " source " .. case.source
    S.selected_voice = case.voice
    params:set("v" .. case.voice .. "_source", case.source)
    local rows = voice_page_rows(case.voice)
    place_voice_cursor(#rows)
    local _, group = voice_page_group(rows, S.cursors.voice)
    assert_equal(#group, case.size, where .. ": the last group")
    local before = {}
    for _, row in ipairs(rows) do
      if row.param_id then before[row.param_id] = params:get(row.param_id) end
    end
    local density = params:get("master_density")
    for ring = case.size + 1, 4 do context.arc.turn(1, ring, 100) end
    for param_id, value in pairs(before) do
      assert_equal(params:get(param_id), value, where .. ": rings past the group leave " .. param_id)
    end
    assert_equal(params:get("master_density"), density)
    arc_redraw()
    for ring = case.size + 1, 4 do assert_ring_dark(device, ring, where .. ": VOICE ring " .. ring) end
    params:set("v" .. case.voice .. "_source", S.constants.SOURCE_SYNTH)
  end
  -- the rows shrinking under the cursor (buffer -> input on voice 1: the
  -- synth section goes) move the group with it
  S.selected_voice = 1
  params:set("v1_source", 2)
  place_voice_cursor(#voice_page_rows(1))
  params:set("v1_source", S.constants.SOURCE_INPUT)
  context.arc.turn(1, 4, 40)
  arc_redraw()
  local rows = voice_page_rows(1)
  local _, group = voice_page_group(rows, S.cursors.voice)
  local holds_cursor = false
  for _, index in ipairs(group) do holds_cursor = holds_cursor or index == S.cursors.voice end
  assert_true(holds_cursor, "input: the group holds the cursor")
  assert_true(rows[S.cursors.voice].selectable, "on a selectable row")
  for ring = #group + 1, 4 do assert_ring_dark(device, ring, "input: ring " .. ring .. " dark") end
end)

test("SEQ rings move the step, set its level, the tempo and the voice row", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  local S = local_value("S")
  local C = S.constants
  S.selected_voice = 1
  show_page("SEQ")
  S.cursors.seq_step = 1
  context.arc.turn(1, 1, 10)
  assert_equal(S.cursors.seq_step, 2, "ring 1: 10 ticks a step")
  context.arc.turn(1, 1, 5); context.arc.turn(1, 1, 4)
  assert_equal(S.cursors.seq_step, 2, "9 ticks carried")
  context.arc.turn(1, 1, -9)
  assert_equal(S.cursors.seq_step, 2)
  context.arc.turn(1, 1, 1000)
  assert_equal(S.cursors.seq_step, C.PATTERN_LENGTH, "the step stops at the last")
  context.arc.turn(1, 1, -1000)
  assert_equal(S.cursors.seq_step, 1, "and at the first")
  context.arc.turn(1, 1, 10)
  -- ring 2: the step's level, with the grid following
  local grid_redraws = 0
  local real_grid_redraw = grid_redraw
  grid_redraw = function(...) grid_redraws = grid_redraws + 1; return real_grid_redraw(...) end
  S.patterns[1][2] = 0
  context.arc.turn(1, 2, 30)
  grid_redraw = real_grid_redraw
  assert_equal(S.patterns[1][2], 3, "ring 2: 10 ticks a level")
  assert_true(grid_redraws > 0, "a level edit redraws the grid")
  context.arc.turn(1, 2, 1000)
  assert_equal(S.patterns[1][2], C.MAX_STEP_LEVEL, "levels stop at MAX_STEP_LEVEL")
  context.arc.turn(1, 2, -1000)
  assert_equal(S.patterns[1][2], 0, "and at 0 (off)")
  assert_equal(S.patterns[1][1], 0, "only the cursor's step changes")
  -- the level carry belongs to its step
  context.arc.turn(1, 2, 9)
  context.arc.turn(1, 1, 10)   -- step 3
  context.arc.turn(1, 2, 1)
  assert_equal(S.patterns[1][3], 0, "step 2's carried ticks never set step 3")
  -- ring 3: tempo, one BPM per 10 ticks
  local tempo = params:get("tempo")
  context.arc.turn(1, 3, 20)
  assert_equal(params:get("tempo"), tempo + 2, "ring 3: 10 ticks a BPM")
  -- ring 4: the voice row, 20 ticks a voice
  context.arc.turn(1, 4, 19)
  assert_equal(S.selected_voice, 1, "19 ticks keep the voice")
  context.arc.turn(1, 4, 1)
  assert_equal(S.selected_voice, 2, "ring 4: 20 ticks a voice")
  context.arc.turn(1, 4, 1000)
  assert_equal(S.selected_voice, C.NUM_VOICES, "the voice stops at the last")
  S.patterns[C.NUM_VOICES][3] = 0
  context.arc.turn(1, 2, 10)
  assert_equal(S.patterns[C.NUM_VOICES][3], 1, "ring 2 edits the selected voice's row")
end)

test("SEQ and SCENES rings draw their position fractions", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  local S = local_value("S")
  local C = S.constants
  S.selected_voice = 1
  show_page("SEQ")
  S.cursors.seq_step = C.PATTERN_LENGTH
  S.patterns[1][C.PATTERN_LENGTH] = C.MAX_STEP_LEVEL
  arc_redraw()
  assert_ring_fraction(device, 1, 1, "SEQ ring 1 at the last step")
  assert_ring_fraction(device, 2, 1, "SEQ ring 2 at level 15")
  assert_ring_fraction(device, 3, param_fraction("tempo"), "SEQ ring 3 tempo")
  assert_ring_fraction(device, 4, 0, "SEQ ring 4 at voice 1")
  S.cursors.seq_step = 9
  S.selected_voice = 4
  S.patterns[4][9] = 5
  arc_redraw()
  assert_ring_fraction(device, 1, 8 / (C.PATTERN_LENGTH - 1), "SEQ ring 1 at step 9")
  assert_ring_fraction(device, 2, 5 / C.MAX_STEP_LEVEL, "SEQ ring 2 at level 5")
  assert_ring_fraction(device, 4, 3 / (C.NUM_VOICES - 1), "SEQ ring 4 at voice 4")
  show_page("SCENES")
  local stops = C.NUM_SCENES + #C.SCENES_FIELDS
  S.cursors.scene = stops
  arc_redraw()
  assert_ring_fraction(device, 1, 1, "SCENES ring 1 at the last field")
  assert_ring_fraction(device, 2, param_fraction("scene_transition_time"), "SCENES ring 2 transition time")
  assert_ring_dark(device, 3, "SCENES ring 3")
  assert_ring_dark(device, 4, "SCENES ring 4")
  S.cursors.scene = 4
  arc_redraw()
  assert_ring_fraction(device, 1, 3 / (stops - 1), "SCENES ring 1 at slot 4")
  S.cursors.scene = 1
  arc_redraw()
  assert_ring_fraction(device, 1, 0, "SCENES ring 1 at slot 1")
end)

test("SCENES ring 1 moves the cursor and ring 2 the transition time", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  local S = local_value("S")
  local C = S.constants
  show_page("SCENES")
  S.cursors.scene = 1
  context.arc.turn(1, 1, 10)
  assert_equal(S.cursors.scene, 2, "ring 1: 10 ticks a stop")
  context.arc.turn(1, 1, 25)
  assert_equal(S.cursors.scene, 4, "25 ticks: two stops, 5 carried")
  context.arc.turn(1, 1, 5)
  assert_equal(S.cursors.scene, 5, "the carry counts")
  context.arc.turn(1, 1, 1000)
  assert_equal(S.cursors.scene, C.NUM_SCENES + #C.SCENES_FIELDS, "past the slots into the fields, to the last")
  context.arc.turn(1, 1, -1000)
  assert_equal(S.cursors.scene, 1, "back to slot 1")
  local transition = params:get("scene_transition_time")
  context.arc.turn(1, 2, 100)
  assert_true(params:get("scene_transition_time") > transition, "ring 2 raises the transition time")
  local before = params:get("scene_transition_time")
  for _, ring in ipairs({ 3, 4 }) do context.arc.turn(1, ring, 100) end
  assert_equal(params:get("scene_transition_time"), before, "rings 3-4 do nothing")
  assert_equal(S.cursors.scene, 1)
  -- a cursor move disarms an overwrite confirmation, as E2 does
  S.scenes_page.armed_slot = 1
  S.scenes_page.armed_until = util.time() + 10
  context.arc.turn(1, 1, 5)
  assert_equal(S.scenes_page.armed_slot, 1, "a part-turn leaves it armed")
  S.lib.ui_flash.start("hints", "K3 again: overwrite S1", 2, C.UI_PAGES.index.SCENES)
  context.arc.turn(1, 1, 5)
  assert_true(S.scenes_page.armed_slot == nil, "moving the cursor disarms")
  assert_true(S.lib.ui_flash.text("hints") == nil, "and clears the overwrite prompt")
  redraw()
  assert_true(hint_text(context) ~= "K3 again: overwrite S1", "the hint row no longer asks")
end)

test("SCENES ring 1 moves the cursor through the page's move_cursor", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  local S = local_value("S")
  show_page("SCENES")
  local real = S.lib.pages_scenes.move_cursor
  local targets = {}
  S.lib.pages_scenes.move_cursor = function(slot) table.insert(targets, slot); real(slot) end
  context.arc.turn(1, 1, 20)
  S.lib.pages_scenes.move_cursor = real
  assert_equal(table.concat(targets, ","), "3", "two stops from slot 1: move_cursor(3)")
  assert_equal(S.cursors.scene, 3, "the cursor moved")
end)

test("page and arc files keep to their record fields", function()
  local ARC_FIELDS = { arc_delta = true, arc_redraw = true, arc_alt_delta = true, arc_alt_redraw = true }
  local PAGE_FIELDS = { "name", "draw", "hints", "enc", "key", "alt_enc", "alt_key", "key_release",
    "alt_key_release", "enter", "leave", "arc_button", "header_status", "layout_states" }
  local files = { ["lib/arc/main.lua"] = true, ["lib/arc/voice.lua"] = true,
    ["lib/arc/seq.lua"] = true, ["lib/arc/scenes.lua"] = true }
  local seen = 0
  for _, source in ipairs(read_lua_sources()) do
    if files[source.path] then
      seen = seen + 1
      local sanitized = h.sync_check.sanitize_lua(source.text)
      local fields = {}
      for field in sanitized:gmatch("%.([%a_][%w_]*)%s*=[^=]") do fields[field] = true end
      for field in sanitized:gmatch("[{,]%s*([%a_][%w_]*)%s*=[^=]") do fields[field] = true end
      for _, field in ipairs(PAGE_FIELDS) do
        assert_true(not fields[field], source.path .. " sets the page field " .. field)
      end
      assert_true(fields.arc_delta and fields.arc_redraw, source.path .. " sets arc_delta and arc_redraw")
    end
  end
  assert_equal(seen, 4, "the four ring files this package owns")
  load_strata()
  local S = local_value("S")
  for _, name in ipairs({ "MAIN", "VOICE", "SEQ", "SCENES" }) do
    local record = S.registry.pages[S.constants.UI_PAGES.index[name]]
    for field in pairs(ARC_FIELDS) do
      local wanted = name == "MAIN" or (field ~= "arc_alt_delta" and field ~= "arc_alt_redraw")
      assert_equal(type(record[field]), wanted and "function" or "nil", name .. "." .. field)
    end
  end
end)

end
