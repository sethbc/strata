-- test/unit/arc_core_test.lua
-- Arc core (lib/arc/core.lua): the bipolar ring fill, the param fill that
-- picks it, carried ticks per key, the ALT rings and the button hook
-- Run alone: lua test/run.lua arc_core

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page = h.show_page

-- A plugged arc with every LED dark
local function dark_arc(context)
  local device = context.arc.plug(1)
  device:all(0)
  return device
end

-- Assert that LEDs first..last of the ring are at level and every other LED
-- is dark (first > last: no LED lit)
local function assert_lit(device, ring, first, last, level, where)
  for led = 1, 64 do
    local expected = (led >= first and led <= last) and level or 0
    assert_equal(device.rings[ring][led], expected, where .. ": ring " .. ring .. " LED " .. led)
  end
end

test("a bipolar ring fills clockwise from the top for positive values", function()
  local context = load_strata(); finish_startup(context)
  local device = dark_arc(context)
  params:set("v1_pan", 0.5)
  arc_ring_fill_bipolar(device, 1, "v1_pan", 15)
  assert_lit(device, 1, 1, 16, 15, "pan 0.5")
end)

test("a bipolar ring fills counter-clockwise for negative values", function()
  local context = load_strata(); finish_startup(context)
  local device = dark_arc(context)
  params:set("v1_pan", -0.5)
  arc_ring_fill_bipolar(device, 1, "v1_pan", 15)
  assert_lit(device, 1, 49, 64, 15, "pan -0.5")
end)

test("a bipolar ring at zero lights only a dim LED 1", function()
  local context = load_strata(); finish_startup(context)
  local device = dark_arc(context)
  params:set("v1_pan", 0)
  arc_ring_fill_bipolar(device, 2, "v1_pan", 15)
  assert_equal(local_value("ARC_BIPOLAR_ZERO_LEVEL"), 3)
  assert_lit(device, 2, 1, 1, 3, "pan 0")
end)

test("a bipolar ring's zero is the param's own 0, and its ends light every LED on their side", function()
  local context = load_strata(); finish_startup(context)
  local device = dark_arc(context)
  -- -3 to 1: zero sits three quarters of the way round
  params:lookup_param("v1_pan").controlspec = controlspec.new(-3, 1, "lin", 0.01, 0)
  params:set("v1_pan", 1); device:all(0); arc_ring_fill_bipolar(device, 1, "v1_pan", 12)
  assert_lit(device, 1, 1, 16, 12, "the maximum, a quarter turn above 0")
  params:set("v1_pan", -3); device:all(0); arc_ring_fill_bipolar(device, 1, "v1_pan", 12)
  assert_lit(device, 1, 17, 64, 12, "the minimum, three quarters below 0")
  -- -1 to 0: the minimum is a whole turn counter-clockwise (a bare full-turn
  -- segment would light nothing)
  params:lookup_param("v1_pan").controlspec = controlspec.new(-1, 0, "lin", 0.01, 0)
  params:set("v1_pan", -1); device:all(0); arc_ring_fill_bipolar(device, 1, "v1_pan", 12)
  assert_lit(device, 1, 1, 64, 12, "a whole turn below 0")
end)

test("arc_ring_fill_param picks the bipolar fill for ranges through zero", function()
  local context = load_strata(); finish_startup(context)
  local device = dark_arc(context)
  local calls = {}
  local plain, bipolar = arc_ring_fill, arc_ring_fill_bipolar
  arc_ring_fill = function(...) calls[#calls + 1] = "plain"; return plain(...) end
  arc_ring_fill_bipolar = function(...) calls[#calls + 1] = "bipolar"; return bipolar(...) end
  local ok, err = pcall(function()
    assert_true(param_spans_zero("v1_mod_amp_amt_1"), "amp mod -2 to 2 spans 0")
    assert_true(not param_spans_zero("filter_res"), "filter res 0 to 1 does not")
    assert_true(not param_spans_zero("v1_grain_env"), "an option param never does")
    params:set("v1_mod_amp_amt_1", -1)
    arc_ring_fill_param(device, 1, "v1_mod_amp_amt_1", 15)
    assert_equal(calls[#calls], "bipolar", "amp mod is drawn bipolar")
    assert_lit(device, 1, 49, 64, 15, "amp mod -1")
    params:set("filter_res", 0.25)
    arc_ring_fill_param(device, 2, "filter_res", 15)
    assert_equal(calls[#calls], "plain", "filter res fills from 0")
    assert_lit(device, 2, 1, 16, 15, "filter res 0.25")
  end)
  arc_ring_fill, arc_ring_fill_bipolar = plain, bipolar
  if not ok then error(err, 0) end
end)

test("carried arc ticks are kept per key and forgotten on a page change", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  assert_equal(arc_whole_steps("a", 15, 10), 1, "15 ticks: one step, 5 carried")
  assert_equal(arc_whole_steps("a", 5, 10), 1, "the carried 5 and 5 more")
  assert_equal(arc_whole_steps("c", -15, 10), -1, "negative turns step down")
  assert_equal(arc_whole_steps("c", -5, 10), -1, "and carry their remainder")
  arc_whole_steps("b", 9, 10)
  arc_whole_steps("d", 9, 10)
  forget_arc_ticks("d")
  assert_equal(arc_whole_steps("d", 1, 10), 0, "forget_arc_ticks drops its key's carry")
  assert_equal(arc_whole_steps("b", 0, 10), 0, "and leaves the other keys")
  show_page("FX")
  assert_equal(arc_whole_steps("b", 1, 10), 0, "a page change forgets every carry")
  local S = local_value("S")
  S.arc_ticks["lfo:4"] = 7
  forget_arc_lfo_period_ticks()
  assert_equal(S.arc_ticks["lfo:4"], nil, "forget_arc_lfo_period_ticks forgets the LFO period ring's key")
end)

test("ALT switches to the page's ALT rings", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  local S = local_value("S")
  local fx = S.registry.pages[S.constants.UI_PAGES.index.FX]
  local alt_turns, alt_draws = {}, 0
  fx.arc_alt_delta = function(n, delta) alt_turns[#alt_turns + 1] = n .. ":" .. delta end
  fx.arc_alt_redraw = function(arc_port)
    assert_equal(arc_port, S.arc_device, "the ALT rings draw on the followed arc")
    alt_draws = alt_draws + 1
  end
  show_page("FX")
  local res = params:get("filter_res")
  S.alt_held = true
  context.arc.turn(1, 2, 20)
  assert_equal(table.concat(alt_turns, " "), "2:20", "the turn goes to arc_alt_delta")
  assert_equal(params:get("filter_res"), res, "and not to the FX ring")
  arc_redraw()
  assert_equal(alt_draws, 1, "arc_redraw draws the ALT rings")
  S.alt_held = false
  context.arc.turn(1, 2, 20)
  assert_true(params:get("filter_res") > res, "without ALT ring 2 is filter res again")
  arc_redraw()
  assert_equal(alt_draws, 1, "and the FX rings are drawn")
  -- a page without ALT rings keeps its own under ALT
  show_page("MAIN")
  local density = params:get("master_density")
  S.alt_held = true
  context.arc.turn(1, 1, 20)
  S.alt_held = false
  assert_true(params:get("master_density") > density, "MAIN has no ALT rings: ring 1 stays density")
end)

test("the arc button calls the page's arc_button", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  local S = local_value("S")
  local fx = S.registry.pages[S.constants.UI_PAGES.index.FX]
  local presses = 0
  fx.arc_button = function() presses = presses + 1 end
  show_page("FX")
  context.arc.push(1, 1, 1)
  assert_equal(presses, 1, "a press calls arc_button")
  context.arc.push(1, 1, 0)
  assert_equal(presses, 1, "a release does not")
  -- MAIN's arc_button is K3: start the selected voice (then lock it)
  show_page("MAIN")
  assert_equal(type(S.registry.pages[S.constants.UI_PAGES.MAIN_PAGE].arc_button), "function", "MAIN has an arc_button")
  S.selected_voice = 3
  assert_true(not S.voices[3].active, "voice 3 starts stopped")
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_true(S.voices[3].active, "the button starts the selected voice on MAIN")
  -- a page without arc_button ignores the button
  show_page("SETUP")
  local before = S.voices[3].active
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_equal(S.voices[3].active, before, "SETUP ignores the button")
  assert_equal(presses, 1)
end)
end
