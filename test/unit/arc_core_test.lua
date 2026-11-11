-- test/unit/arc_core_test.lua
-- Arc core (lib/arc/core.lua): the bipolar ring fill, the param fill that
-- picks it, carried ticks per key, the ALT rings and the button hook
-- Run alone: lua test/run.lua arc_core

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, show_page = h.load_strata, h.local_value, h.finish_startup, h.show_page
local find_upvalue, next_frame, PAGE_TITLES = h.find_upvalue, h.next_frame, h.PAGE_TITLES

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
  show_page("LFO")
  local depth = params:get("lfo_depth_1")
  S.alt_held = true
  context.arc.turn(1, 1, 100)
  S.alt_held = false
  assert_true(params:get("lfo_depth_1") > depth, "LFO has no ALT rings: ring 1 stays lfo depth")
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
  -- MAIN's arc_button is K3: it starts a stopped selected voice
  show_page("MAIN")
  assert_equal(type(S.registry.pages[S.constants.UI_PAGES.index.MAIN].arc_button), "function", "MAIN has an arc_button")
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

test("Strata follows one arc: any port, the first one plugged, removal of that one disconnects", function()
  local function screen_has(context, text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  local function setup_text(context)
    local page = local_value("ui_page")
    show_page("SETUP"); enc(2, 20); redraw()
    local result = screen_has(context, "arc: connected") and "connected" or (screen_has(context, "arc: none") and "none" or "?")
    show_page(page)
    return result
  end
  -- the only arc is on port 2
  local context = load_strata(); finish_startup(context)
  context.arc.plug(2)
  assert_equal(setup_text(context), "connected", "arc on port 2 connects")
  local density = params:lookup_param("master_density")
  local before = density.raw
  context.arc.turn(2, 1, 20)
  assert_near(density.raw - before, 20 / local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 1e-9, "arc on port 2 works")
  context.arc.unplug(2)
  assert_equal(setup_text(context), "none", "removing it disconnects")

  -- already plugged at start: found on its port
  context = load_strata(); finish_startup(context)
  context.arc.plug(3)
  context.arc.unplug(3)
  context.arc.vports[4].device = {port = 4, segments = {}, all = function() end, refresh = function() end, segment = function() end, led = function() end}
  arc_init()
  assert_true(context.arc.vports[4].delta ~= nil, "init attaches the vport holding a device")

  -- port 2 first, then port 1: Strata stays on 2
  context = load_strata(); finish_startup(context)
  density = params:lookup_param("master_density")
  context.arc.plug(2)
  context.arc.plug(1)
  assert_equal(context.arc.vports[1].delta, nil, "a second arc gets no handler")
  context.arc.unplug(1)
  assert_equal(setup_text(context), "connected", "removing the other arc keeps Strata's")
  before = density.raw
  context.arc.turn(2, 1, 20)
  assert_near(density.raw - before, 20 / local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 1e-9, "still handled on port 2")
  context.arc.unplug(2)
  assert_equal(setup_text(context), "none", "removing Strata's arc disconnects")

  -- port 1 first, then 2
  context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  context.arc.plug(2)
  assert_equal(context.arc.vports[2].delta, nil, "no handler on the second arc")
  context.arc.unplug(2)
  assert_equal(setup_text(context), "connected", "removing another port's arc keeps Strata's arc")
  context.arc.unplug(1)
  assert_equal(setup_text(context), "none", "removing Strata's arc disconnects it")

  -- two arcs: unplugging the followed one moves to the other (#49). norns
  -- clears the removed vport only after arc.remove returns, so it is skipped
  context = load_strata(); finish_startup(context)
  density = params:lookup_param("master_density")
  context.arc.plug(1)
  local second_arc = context.arc.plug(3)
  context.arc.unplug(1)
  assert_equal(setup_text(context), "connected", "the other arc is followed")
  assert_true(context.arc.vports[3].delta ~= nil, "its vport gets the handlers")
  assert_equal(context.arc.vports[1].delta, nil, "the removed arc's vport keeps none")
  before = density.raw
  context.arc.turn(3, 1, 20)
  assert_near(density.raw - before, 20 / local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 1e-9, "turning the other arc works")
  local refreshes = second_arc.refresh_count
  next_frame(context)
  assert_equal(second_arc.refresh_count, refreshes + 1, "its rings are drawn")
  context.arc.plug(1)
  assert_equal(context.arc.vports[1].delta, nil, "an arc plugged back in is not followed")
  context.arc.unplug(3)
  assert_true(context.arc.vports[1].delta ~= nil, "until the followed one goes")
  context.arc.unplug(1)
  assert_equal(setup_text(context), "none", "removing the last arc disconnects")
end)

test("the arc button finds MAIN by its page index, not its title", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1); show_page("MAIN")
  local pages = local_value("UI_PAGES")
  assert_equal(pages.index.MAIN, 1, "MAIN is page 1")
  assert_equal(pages[pages.index.MAIN], "MAIN")
  local _, set_selected = find_upvalue("selected_voice"); set_selected(3)
  local voices = local_value("voices")
  assert_true(not voices[3].active, "voice 3 starts stopped")
  local title = pages[1]
  pages[1] = "HOME"   -- a renamed title must not change what the button does
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  pages[1] = title
  assert_true(voices[3].active, "the button starts the selected voice on page 1")
end)

test("the arc keeps drawing while the norns menu is open (#49)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  next_frame(context)
  _menu.set_mode(true)
  -- norns' set_mode(true) swaps the global redraw for norns.none (the stub only tracks the mode)
  local script_redraw = redraw
  local screen_draws = 0
  redraw = function() screen_draws = screen_draws + 1 end
  local arc_refreshes = arc_hardware.refresh_count
  local density = params:get("master_density")
  params:set("master_density", density / 2)  -- PARAMS, a CC map or an LFO while the menu is open
  next_frame(context)
  assert_equal(arc_hardware.refresh_count, arc_refreshes + 1, "the frame draws the arc's rings")
  assert_equal(screen_draws, 1, "and calls the global redraw, which is norns.none in the menu")
  redraw = script_redraw
  _menu.set_mode(false)
end)

-- SYSTEM > DEVICES moves an arc through update_devices() only, never arc.add
-- or arc.remove (#256)
test("an arc moved to another port in SYSTEM > DEVICES is followed once the menu closes", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  context.arc.plug(1)
  _menu.set_mode(true)
  context.arc.reassign(1, 3)
  _menu.set_mode(false)
  assert_true(S.arc_connected, "the moved arc is connected")
  local density = params:lookup_param("master_density")
  local before = density.raw
  show_page("MAIN")
  context.arc.turn(3, 1, 20)
  assert_near(density.raw - before, 20 / local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 1e-9, "a ring turn on port 3 moves its param")
  -- the arc's vport emptied (its name given to a port with no device), with
  -- no other arc
  _menu.set_mode(true)
  arc.connect(3).name = "none"
  context.arc.update_devices()
  _menu.set_mode(false)
  assert_true(not S.arc_connected, "no arc is connected")
  show_page("SETUP"); enc(2, 20); redraw()
  assert_true(h.screen_shows(context, "arc: none"), "SETUP shows arc: none")
end)

-- norns' menu takes the screen, keys and encoders only (lua/core/menu.lua's
-- set_mode swaps redraw, key and the encoder callback); arc and grid input
-- stays with the script, so both keep showing what changes (#169)
test("with the menu open the arc's own turns and the grid stay live, and the rings are right after", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  local grid_hardware = context.grid.plug(1, 16, 16)
  show_page("MAIN"); next_frame(context)
  _menu.set_mode(true)
  local script_redraw = redraw
  redraw = function() end   -- norns.none while the menu is open
  local density = params:get("master_density")
  local arc_refreshes = arc_hardware.refresh_count
  context.arc.turn(1, 1, 64)
  assert_true(params:get("master_density") > density, "an arc turn in the menu still edits its ring's param")
  next_frame(context)
  assert_equal(arc_hardware.refresh_count, arc_refreshes + 1, "and the ring redraws on the next frame")
  local shown = {}
  for led = 1, 64 do shown[led] = arc_hardware.rings[1][led] end
  local grid_refreshes = grid_hardware.refresh_count
  params:set("scene_sequence_length", 6)   -- PARAMS while the menu is open
  assert_equal(grid_hardware.refresh_count, grid_refreshes + 1, "the grid repaints as it does outside the menu")
  redraw = script_redraw
  _menu.set_mode(false)
  -- the menu closing changes nothing on the arc: the rings already show the value
  request_redraw(); next_frame(context)
  for led = 1, 64 do
    assert_equal(arc_hardware.rings[1][led], shown[led], "ring 1 LED " .. led .. " after the menu closes")
  end
end)

-- #437: a device norns gave no vport is on no vport at all
test("an arc with no port is neither followed nor taken for port 1's", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local printed = {}
  local real_print = print
  print = function(...) printed[#printed + 1] = table.concat({...}, " ") end
  arc.add({port = nil})
  print = real_print
  assert_equal(#printed, 0, "arc.add of a portless device prints nothing")
  assert_true(not S.arc_connected, "and attaches nothing")
  context.arc.plug(1)
  assert_true(S.arc_connected, "an arc on port 1 is followed")
  print = function(...) printed[#printed + 1] = table.concat({...}, " ") end
  arc.remove({port = nil})
  print = real_print
  assert_true(S.arc_connected, "removing a portless device leaves the followed arc")
  assert_equal(#printed, 0, "and prints nothing")
  h.check_invariants()
end)

end
