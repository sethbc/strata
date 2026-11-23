-- test/unit/pages_fx_test.lua
-- The FX page (lib/pages/fx.lua): its rows, E2/E3 and the K3 bypass
-- Run alone: lua test/run.lua pages_fx

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, text_span, PAGE_TITLES, HINT_ROW_Y = h.finish_startup, h.text_span, h.PAGE_TITLES, h.HINT_ROW_Y
local TEXT_HEIGHT, show_page, assert_screen_layout, count_screen_draws = h.TEXT_HEIGHT, h.show_page, h.assert_screen_layout, h.count_screen_draws
local tap, hint_text = h.tap, h.hint_text

test("FX page: E2 selects a row, E3 adjusts it, K3 bypasses the filter", function()
  local context = load_strata(); show_page("FX"); enc(2, 3)  -- cursor on filter freq
  enc(2, -3); enc(2, 3)
  params:set("filter_mix", 0.8); key(3, 1); assert_equal(params:get("filter_mix"), 0)
  key(3, 1); assert_near(params:get("filter_mix"), 0.8, 1e-6)
  local before = params:get("filter_freq"); enc(3, 2)
  assert_true(params:get("filter_freq") > before, "row 4 is filter freq")
  -- K3 from a bypassed default turns the filter fully on
  context = load_strata(); show_page("FX"); enc(2, 3)
  key(3, 1); assert_equal(params:get("filter_mix"), 1, "first K3 turns the filter on")
  local function hint_text()
    for _, entry in ipairs(context.screen.texts) do
      if entry.y == 62 then return entry.text end
    end
  end
  redraw(); assert_equal(hint_text(), "K3:filter bypass")
  key(3, 1); redraw(); assert_equal(hint_text(), "K3:filter on")
end)

test("FX page K3 restores the last non-zero filter mix however it was set", function()
  load_strata(); show_page("FX")
  enc(2, 5)                                    -- row 6: filter mix
  enc(3, 50); assert_near(params:get("filter_mix"), 0.5, 1e-6, "E3 sets the mix to 0.5")
  enc(3, -50); assert_equal(params:get("filter_mix"), 0, "E3 brings it to 0")
  key(3, 1); assert_near(params:get("filter_mix"), 0.5, 1e-6, "K3 restores the mix E3 last set")
  params:set("filter_mix", 0); params:set("filter_mix", 0.3); params:set("filter_mix", 0)  -- PARAMS menu, scene recall, ... (a rise)
  key(3, 1); assert_near(params:get("filter_mix"), 0.3, 1e-6, "K3 restores a mix set through params")
end)

test("FX page rows stay apart and inside 128x64 at every row and value", function()
  local context = load_strata()
  params:set("mutation_enabled", 1)
  capture_scene(8); recall_scene(8, 0)
  show_page("FX")
  local all_rows = local_value("FX_PAGE").rows
  local rows = {}
  for _, row in ipairs(all_rows) do
    if row.selectable ~= false then rows[#rows + 1] = row end
  end
  assert_equal(#rows, 21, "density, drift, 4 filter, 7 delay, 5 reverb, 3 shimmer rows")
  assert_equal(#all_rows, 26, "plus five section labels")
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  for _, extreme in ipairs({ "max", "min" }) do
    for _, row in ipairs(rows) do
      if not row.param_id then goto next_row end  -- a hold row: the freeze is drawn on and off below
      local min_value, max_value = param_range(row.param_id)
      if row.param_id == "filter_type" then min_value, max_value = 2, 3 end  -- highpass, bandpass
      params:set(row.param_id, extreme == "max" and max_value or min_value)
      ::next_row::
    end
    params:set("delay_freeze", extreme == "max" and 1 or 0)
    enc(2, -100)
    for row = 1, #rows do
      assert_true(local_value("FX_PAGE").rows[local_value("fx_row")] == rows[row], "E2 steps one selectable row")
      redraw()
      assert_screen_layout(context, "FX row " .. row .. ", " .. extreme)
      assert_true(screen_has(rows[row].label), "selected row " .. rows[row].label .. " is visible")
      enc(2, 1)
    end
    assert_equal(local_value("FX_PAGE").rows[local_value("fx_row")], rows[#rows], "E2 stops at the last row")
  end
end)

local function row_index(param_id)
  for index, row in ipairs(local_value("FX_PAGE").rows) do
    if row.param_id == param_id then return index end
  end
end

local function text_with_level(context, text)
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == text then return entry end
  end
end

test("FX section labels take no cursor stop", function()
  local context = load_strata(); show_page("FX")
  local S = local_value("S")
  S.fx_row = row_index("drift_amount")
  enc(2, 1)
  assert_equal(S.fx_row, row_index("filter_type"), "the filter label is skipped")
  enc(2, -1)
  assert_equal(S.fx_row, row_index("drift_amount"), "and skipped going back")
  S.fx_row = row_index("master_density"); enc(2, -5)
  assert_equal(S.fx_row, row_index("master_density"), "the master label above density takes no stop")
  context.screen.clear(); redraw()
  for _, name in ipairs({ "master" }) do
    local entry = text_with_level(context, name)
    assert_true(entry ~= nil, name .. " label drawn")
    assert_equal(entry.level, 2, name .. " label at level 2")
  end
  -- the delay's five rows put the reverb's label out of view from delay time
  for _, each in ipairs({ { "delay", "delay_time" }, { "reverb", "reverb_mix" } }) do
    local name = each[1]
    S.fx_row = row_index(each[2]); context.screen.clear(); redraw()
    local entry = text_with_level(context, name)
    assert_true(entry ~= nil, name .. " label drawn")
    assert_equal(entry.level, 2, name .. " label at level 2")
  end
end)

test("FX shows mixes, feedback and damping in percent", function()
  local context = load_strata(); show_page("FX")
  local S = local_value("S")
  params:set("filter_mix", 0.5); params:set("delay_feedback", 0.4)
  params:set("reverb_mix", 0.3); params:set("reverb_damp", 0.5); params:set("delay_mix", 0.6)
  for _, id in ipairs({ "filter_mix", "delay_feedback", "delay_mix", "reverb_mix", "reverb_damp" }) do
    S.fx_row = row_index(id); context.screen.clear(); redraw()
    local expected = ({ filter_mix = "50%", delay_feedback = "40%", delay_mix = "60%",
      reverb_mix = "30%", reverb_damp = "50%" })[id]
    assert_true(h.screen_shows(context, expected), id .. " shows " .. expected)
  end
end)

test("FX draws a scroll marker at x 127", function()
  local context = load_strata(); show_page("FX")
  context.screen.clear(); redraw()
  assert_equal(#context.screen.lines, 1, "one marker line")
  assert_equal(context.screen.lines[1].x1, 127)
  local S = local_value("S")
  local top = context.screen.lines[1].y1
  S.fx_row = row_index("reverb_damp"); context.screen.clear(); redraw()
  assert_true(context.screen.lines[1].y1 > top, "the marker moves down with the view")
end)

test("K3 on the FX delay and reverb rows toggles the bypass; the filter row keeps its mix toggle", function()
  local context = load_strata(); show_page("FX")
  local S = local_value("S")
  for _, effect in ipairs({ "delay", "reverb" }) do
    for _, param_id in ipairs(effect == "delay" and { "delay_time", "delay_feedback", "delay_mix" }
      or { "reverb_mix", "reverb_size", "reverb_damp" }) do
      S.fx_row = row_index(param_id)
      params:set(effect .. "_mix", 0.6)
      context.clear_engine_calls()
      key(3, 1); key(3, 0)
      assert_equal(params:get(effect .. "_bypass"), 1, "K3 on " .. param_id .. " bypasses the " .. effect)
      assert_near(params:get(effect .. "_mix"), 0.6, 1e-6, "and keeps its mix")
      local calls = context.calls_named("setBypass")
      assert_equal(#calls, 1, "one setBypass"); assert_equal(calls[1].args[2], 1)
      key(3, 1); key(3, 0)
      assert_equal(params:get(effect .. "_bypass"), 0, "a second K3 lifts it")
      assert_near(params:get(effect .. "_mix"), 0.6, 1e-6, "at the same mix")
    end
  end
  -- the filter: 3.1's mix toggle, and never a bypass param
  S.fx_row = row_index("filter_res")
  params:set("filter_mix", 0.7); key(3, 1)
  assert_equal(params:get("filter_mix"), 0, "K3 on a filter row sets its mix to 0")
  key(3, 1); assert_near(params:get("filter_mix"), 0.7, 1e-6, "and back")
  assert_equal(params:get("delay_bypass") + params:get("reverb_bypass"), 0, "the filter K3 bypasses no effect")
  -- the master rows do nothing
  S.fx_row = row_index("drift_amount")
  local snapshot = {params:get("filter_mix"), params:get("delay_mix"), params:get("reverb_mix"), params:get("drift_amount")}
  key(3, 1); S.fx_row = row_index("master_density"); key(3, 1)
  assert_equal(params:get("filter_mix"), snapshot[1]); assert_equal(params:get("delay_mix"), snapshot[2])
  assert_equal(params:get("reverb_mix"), snapshot[3]); assert_equal(params:get("drift_amount"), snapshot[4])
  assert_equal(params:get("delay_bypass") + params:get("reverb_bypass"), 0, "nor any bypass")
end)

test("a bypassed row shows byp and keeps its mix", function()
  local context = load_strata(); show_page("FX")
  local S = local_value("S")
  S.fx_row = row_index("delay_time")  -- the view shows the delay's label
  local function byp_entries()
    local found = {}
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == "byp" then table.insert(found, entry) end
    end
    return found
  end
  local function label_y(name)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == name and entry.level == 2 then return entry.y end
    end
  end
  context.screen.clear(); redraw()
  assert_equal(#byp_entries(), 0, "nothing is bypassed: no byp")
  params:set("delay_mix", 0.45); params:set("delay_bypass", 1)
  context.screen.clear(); redraw()
  local found = byp_entries()
  assert_equal(#found, 1, "the delay row shows byp")
  assert_equal(found[1].y, label_y("delay"), "on the delay's section row")
  assert_equal(found[1].level, 4, "at level 4")
  assert_true(h.screen_shows(context, "45%"), "the delay mix still shows its value")
  -- the delay's five rows (3.7) keep the reverb's label out of this view
  params:set("reverb_bypass", 1)
  S.fx_row = row_index("reverb_mix")
  context.screen.clear(); redraw()
  found = byp_entries()
  assert_equal(#found, 1, "the reverb row shows byp")
  assert_equal(found[1].y, label_y("reverb"), "on the reverb's section row")
  assert_screen_layout(context, "FX delay and reverb bypassed")
  -- a mix of 0 is not a bypass
  params:set("delay_bypass", 0); params:set("reverb_bypass", 0); params:set("delay_mix", 0)
  context.screen.clear(); redraw()
  assert_equal(#byp_entries(), 0, "a mix of 0 shows no byp")
end)

test("FX hints name the effect", function()
  local context = load_strata(); show_page("FX")
  local S = local_value("S")
  local function hint_text()
    context.screen.clear(); redraw()
    for _, entry in ipairs(context.screen.texts) do
      if entry.y == 62 then return entry.text end
    end
  end
  S.fx_row = row_index("delay_feedback")
  params:set("delay_mix", 0.5); assert_equal(hint_text(), "K3:delay bypass")
  params:set("delay_mix", 0); assert_equal(hint_text(), "K3:delay bypass", "a mix of 0 is still not bypassed")
  params:set("delay_bypass", 1); assert_equal(hint_text(), "K3:delay on")
  S.fx_row = row_index("reverb_mix"); params:set("reverb_mix", 0.2)
  assert_equal(hint_text(), "K3:reverb bypass")
  params:set("reverb_bypass", 1); assert_equal(hint_text(), "K3:reverb on")
  S.fx_row = row_index("filter_mix"); params:set("filter_mix", 0.4)
  assert_equal(hint_text(), "K3:filter bypass")
  params:set("filter_mix", 0); assert_equal(hint_text(), "K3:filter on")
  S.fx_row = row_index("master_density"); assert_equal(hint_text(), "E3:value")
  S.fx_row = row_index("drift_amount"); assert_equal(hint_text(), "E3:value")
  -- both effects bypassed: ALT+K3 freezes nothing, so the hint names no K3
  -- (#419); the filter and master rows have no freeze
  key(1, 1)
  for _, id in ipairs({"delay_feedback", "reverb_mix", "filter_mix", "master_density"}) do
    S.fx_row = row_index(id)
    assert_equal(hint_text(), "K2:rand E3:fine", "ALT on " .. id .. " offers the randomize and the fine turn")
  end
  key(1, 0)
end)

test("FX layout states include the delay and reverb bypassed", function()
  local context = load_strata(); show_page("FX")
  local S = local_value("S")
  local record = S.registry.pages[S.constants.UI_PAGES.index.FX]
  -- each section's byp in view: the delay's five rows (3.7) keep the two
  -- section rows out of one view
  for _, name in ipairs({ "delay and reverb bypassed", "reverb bypassed in view" }) do
    local state
    for _, each in ipairs(record.layout_states) do
      if each.name == name then state = each end
    end
    assert_true(state ~= nil, "the FX record has the state " .. name)
    state.setup(context)
    context.screen.clear(); redraw()
    local count = 0
    for _, entry in ipairs(context.screen.texts) do if entry.text == "byp" then count = count + 1 end end
    assert_equal(count, 1, name .. ": byp on the section row in view")
    assert_screen_layout(context, "FX " .. state.name)
  end
end)

test("FX layout states find their rows by param id, wherever the rows sit (#114)", function()
  local context = load_strata(); show_page("FX")
  local S = local_value("S")
  local record = S.registry.pages[S.constants.UI_PAGES.index.FX]
  -- a row inserted at the top moves every index: a hard-coded one lands elsewhere
  table.insert(S.FX_PAGE.rows, 1, {label = "extra", selectable = false})
  local expected = {["first row"] = "master_density", ["filter freq"] = "filter_freq",
    ["delay and reverb bypassed"] = "delay_time"}
  for _, state in ipairs(record.layout_states) do
    if expected[state.name] then
      state.setup(context)
      assert_equal(S.FX_PAGE.rows[S.fx_row].param_id, expected[state.name], state.name .. " selects its row")
    end
  end
  table.remove(S.FX_PAGE.rows, 1)
end)

-- ALT+E3 turns a control param finely, but an option (the filter type)
-- keeps whole steps: its row offers no fine turn, as SETUP's rows do
test("FX's ALT hint offers E3:fine only on a row that turns finely", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("FX")
  local function select_row(param_id)
    for index, row in ipairs(S.FX_PAGE.rows) do
      if row.param_id == param_id then S.fx_row = index end
    end
    context.screen.clear(); redraw()
  end
  key(1, 1)
  select_row("filter_type")
  local before = params:get("filter_type")
  enc(3, 1)
  assert_equal(params:get("filter_type"), before + 1, "ALT+E3 on the type steps a whole option")
  select_row("filter_type")
  assert_true(not (hint_text(context) or ""):find("fine", 1, true),
    "the type row offers no fine turn: " .. tostring(hint_text(context)))
  assert_screen_layout(context, "FX ALT on the filter type")
  select_row("filter_freq")
  assert_equal(hint_text(context), "K2:rand E3:fine", "the freq row turns finely")
  key(1, 0)
end)

test("ALT+E3 on FX is fine", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("FX")
  for index, row in ipairs(S.FX_PAGE.rows) do
    if row.param_id == "filter_freq" then S.fx_row = index end
  end
  assert_equal(S.FX_PAGE.rows[S.fx_row].param_id, "filter_freq", "FX has a filter_freq row")
  local r0 = params:get_raw("filter_freq")
  key(1, 1); enc(3, 1); key(1, 0)
  assert_near(params:get_raw("filter_freq") - r0, 0.001, 1e-9, "ALT+E3 on FX is fine")
  r0 = params:get_raw("filter_freq")
  enc(3, 1)
  assert_near(params:get_raw("filter_freq") - r0, 0.01, 1e-9, "E3 on FX is a whole step")
end)

test("FX changes reach the screen and arc on the next frame (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  show_page("FX"); enc(2, 3)
  h.assert_drawn_on_next_frame(context, arc_hardware, "params:set of an FX param", function()
    params:set("filter_freq", 1234)
  end)
  assert_true(h.screen_shows(context, "1234 Hz"), "FX shows the new filter freq")
end)

test("FX acts once per K3 press; the release does nothing", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX"); enc(2, 3)
  local mix = params:get("filter_mix")
  key(3, 1); key(3, 0)
  assert_true(params:get("filter_mix") ~= mix, "FX K3 press bypasses once, the release does not undo it")
end)

-- FX's K3 on the filter mix row restores the mix the player had (#235)
local function filter_mix_row()
  local context = load_strata(); show_page("FX")
  enc(2, 5)  -- row 6: filter mix
  return context
end

test("K3 restores the filter mix it had before it was turned down a step at a time", function()
  filter_mix_row()
  params:set("filter_mix", 0.8)
  local turns = 0
  while params:get("filter_mix") > 0 and turns < 200 do enc(3, -1); turns = turns + 1 end
  assert_equal(params:get("filter_mix"), 0, "E3 brought the mix to 0")
  key(3, 1); assert_near(params:get("filter_mix"), 0.8, 1e-6, "K3 restores 0.8, not the last step before 0")
end)

test("K3 restores the mix a scene fade took to 0", function()
  local context = filter_mix_row()
  params:set("filter_mix", 0.6); capture_scene(1)
  params:set("filter_mix", 0); capture_scene(2)
  recall_scene(1, 0); recall_scene(2, 2)
  context.clock.run_for(3)
  assert_equal(params:get("filter_mix"), 0, "the fade ended at 0")
  key(3, 1); assert_near(params:get("filter_mix"), 0.6, 1e-6, "K3 restores the mix the fade started from")
end)

test("K3 off keeps the mix as it was at the press", function()
  filter_mix_row()
  params:set("filter_mix", 0.8); params:set("filter_mix", 0.3)
  key(3, 1); assert_equal(params:get("filter_mix"), 0)
  key(3, 1); assert_near(params:get("filter_mix"), 0.3, 1e-6, "K3 off recorded 0.3")
end)

test("turned down to 0.3 and later to 0, K3 restores the last mix it rose to", function()
  filter_mix_row()
  params:set("filter_mix", 0.8); params:set("filter_mix", 0.3); params:set("filter_mix", 0)
  key(3, 1); assert_near(params:get("filter_mix"), 0.8, 1e-6, "decision 1's known cost")
end)

test("a PSET load sets the restore value when it raises the mix; a lower loaded mix leaves it", function()
  filter_mix_row()
  local filter_mix = params:lookup_param("filter_mix")
  params:set("filter_mix", 0.6); filter_mix:bang()
  assert_near(local_value("S").fx_last_mix.filter, 0.6, 1e-6, "a load that raises the mix sets the restore value")
  params:set("filter_mix", 0.4); filter_mix:bang()
  assert_near(local_value("S").fx_last_mix.filter, 0.6, 1e-6, "a lower loaded mix is a fall and leaves it")
  params:set("filter_mix", 0); filter_mix:bang()
  key(3, 1); assert_near(params:get("filter_mix"), 0.6, 1e-6, "K3 restores 0.6")
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
-- so K3 on the delay's and reverb's rows sets its binary param through set_binary_param
-- (lib/ui/params.lua), and a controller mapped to it in PARAMS > MAP
-- follows. The map is as lua/core/pmap.lua's pmap.new makes it, echo on
test("K3 on FX's delay and reverb bypass echoes to a MIDI-mapped controller (#538)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local controller = context.midi.plug(1)
  norns.pmap.data.delay_bypass = { dev = 1, ch = 1, cc = 45, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  norns.pmap.data.reverb_bypass = { dev = 1, ch = 1, cc = 46, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  show_page("FX")
  for _, case in ipairs({ { row = "delay_time", id = "delay_bypass", cc = 45 },
    { row = "reverb_size", id = "reverb_bypass", cc = 46 } }) do
    for index, row in ipairs(S.FX_PAGE.rows) do
      if row.param_id == case.row then S.fx_row = index end
    end
    key(3, 1); key(3, 0)
    assert_equal(params:get(case.id), 1, "K3 bypasses: " .. case.id)
    key(3, 1); key(3, 0)
    assert_equal(params:get(case.id), 0, "and lifts it: " .. case.id)
    assert_equal(cc_echoes(controller, case.cc), "127,0", "the controller hears both: " .. case.id)
  end
end)


-- #557: ALT+K2 randomizes the section under the cursor (acting on release)
local FX_SECTIONS = {
  { row = "master_density", ids = { "master_density", "drift_amount" } },
  { row = "filter_freq", ids = { "filter_type", "filter_freq", "filter_res" } },
  { row = "delay_time", ids = { "delay_time", "delay_feedback", "delay_mix" } },
  { row = "reverb_size", ids = { "reverb_mix", "reverb_size", "reverb_damp", "delay_to_reverb" } },
  { row = "shimmer_delay", ids = { "shimmer_interval", "shimmer_delay", "shimmer_reverb" } },
}
local ALL_FX_IDS = { "master_density", "drift_amount", "filter_type", "filter_freq", "filter_res", "filter_mix",
  "delay_time", "delay_feedback", "delay_mix", "delay_bypass", "delay_freeze", "reverb_mix", "reverb_size",
  "reverb_damp", "delay_to_reverb", "reverb_bypass", "shimmer_interval", "shimmer_delay", "shimmer_reverb" }
local function fx_snapshot()
  local out = {}
  for _, id in ipairs(ALL_FX_IDS) do out[id] = params:get(id) end
  return out
end
local function select_fx_row(param_id)
  local S = local_value("S")
  for index, row in ipairs(S.FX_PAGE.rows) do
    if row.param_id == param_id then S.fx_row = index end
  end
end
local FX_RANGES = {
  master_density = { 0.5, 1.5 }, drift_amount = { 0, 0.03 }, filter_freq = { 100, 10000 }, filter_res = { 0, 0.7 },
  delay_time = { 0.05, 1.0 }, delay_feedback = { 0, 0.7 }, delay_mix = { 0, 0.5 },
  reverb_mix = { 0, 0.5 }, reverb_size = { 0.3, 0.95 }, reverb_damp = { 0, 1 }, delay_to_reverb = { 0.3, 1 },
  shimmer_delay = { 0, 0.5 }, shimmer_reverb = { 0, 0.4 },
}

test("ALT+K2 randomizes the selected row's section only", function()
  for _, section in ipairs(FX_SECTIONS) do
    local context = load_strata(); finish_startup(context)
    show_page("FX")
    params:set("filter_mix", 0.4)
    local inside = {}
    for _, id in ipairs(section.ids) do inside[id] = true end
    select_fx_row(section.row)
    local before = fx_snapshot()
    math.randomseed(11)
    key(1, 1); key(2, 1); key(2, 0); key(1, 0)
    local after = fx_snapshot()
    local changed = 0
    for _, id in ipairs(ALL_FX_IDS) do
      if inside[id] then
        if after[id] ~= before[id] then changed = changed + 1 end
        local range = FX_RANGES[id]
        if range then
          assert_true(after[id] >= range[1] - 1e-6 and after[id] <= range[2] + 1e-6, id .. " in its range")
        end
      else
        assert_equal(after[id], before[id], section.row .. ": " .. id .. " is outside the section")
      end
    end
    assert_true(changed >= 1, section.row .. ": the section changed")
    -- every drawn param takes more than one value over a few seeds (a draw
    -- that returned a constant would pass the check above)
    local values = {}
    for _, id in ipairs(section.ids) do values[id] = { [after[id]] = true } end
    key(1, 1); key(2, 1); key(2, 0); key(1, 0)  -- undo
    for seed = 21, 26 do
      math.randomseed(seed)
      key(1, 1); key(2, 1); key(2, 0)  -- randomize
      for _, id in ipairs(section.ids) do values[id][params:get(id)] = true end
      key(2, 1); key(2, 0); key(1, 0)  -- undo
    end
    for _, id in ipairs(section.ids) do
      local distinct = 0
      for _ in pairs(values[id]) do distinct = distinct + 1 end
      assert_true(distinct > 1, section.row .. ": " .. id .. " takes more than one value")
    end
    key(1, 1); key(2, 1); key(2, 0); key(1, 0)  -- randomize again so the undo below has one to undo
    math.randomseed(11)
    key(1, 1); key(2, 1); key(2, 0); key(1, 0)
    for _, id in ipairs(ALL_FX_IDS) do
      assert_equal(params:get(id), before[id], section.row .. ": the quick second press undoes " .. id)
    end
  end
end)

test("the filter mix and the bypasses never change", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  params:set("filter_mix", 0.4); params:set("delay_bypass", 1); params:set("reverb_bypass", 1)
  for _, row in ipairs({ "filter_freq", "delay_time", "reverb_size", "master_density" }) do
    select_fx_row(row)
    for seed = 1, 5 do
      math.randomseed(seed)
      key(1, 1); key(2, 1); key(2, 0); key(1, 0)
      assert_equal(params:get("filter_mix"), 0.4, "filter mix kept")
      assert_equal(params:get("delay_bypass"), 1, "delay bypass kept")
      assert_equal(params:get("reverb_bypass"), 1, "reverb bypass kept")
    end
  end
end)

local function shown(context)
  context.screen.clear(); redraw()
  return hint_text(context)
end

test("the FX hint is K2:rand or K2:undo, and fits", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  select_fx_row("filter_freq")
  key(1, 1)
  assert_equal(shown(context), "K2:rand E3:fine")
  select_fx_row("filter_type")
  assert_equal(shown(context), "K2:rand")
  key(2, 1); key(2, 0)
  assert_equal(shown(context), "K2:undo")
  select_fx_row("filter_freq")
  assert_equal(shown(context), "K2:undo E3:fine")
  context.screen.clear(); redraw()
  assert_screen_layout(context, "FX ALT hint K2:undo E3:fine")
  key(2, 1); context.clock.run_for(0.5)
  assert_equal(shown(context), "K2:cancel E3:fine", "a held press shows cancel")
  assert_screen_layout(context, "FX ALT hint K2:cancel E3:fine")
  key(2, 0); key(1, 0)
end)

-- K1 let go before K2: the release still randomizes or cancels, so the
-- hint row keeps K2's release hint, alone, until K2 comes up
test("K2's release hint stays after K1 comes up first (#557)", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  select_fx_row("filter_freq")
  local plain = shown(context)
  key(1, 1); key(2, 1); key(1, 0)
  assert_equal(shown(context), "K2:rand", "K1 up, K2 down: the quick release's hint")
  context.clock.run_for(0.5)
  assert_equal(shown(context), "K2:cancel", "held past the hold time: letting go cancels")
  key(2, 0)
  assert_equal(shown(context), plain, "K2 up: the plain hints")
end)

-- 3.7 (design §6, rulings 15 and 34): the delay's rows time, fdbk, mix,
-- sync and ping; while synced the time row shows and turns the division
test("the delay's time row shows and edits the division while synced; K3 is still the bypass", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  local S = local_value("S")
  local labels = {}
  for index = row_index("delay_time"), row_index("delay_time") + 4 do labels[#labels + 1] = S.FX_PAGE.rows[index].label end
  assert_equal(table.concat(labels, " "), "time fdbk level sync ping", "the delay section's rows")
  assert_equal(S.FX_PAGE.rows[row_index("delay_pingpong")].effect, "delay")
  -- sync: E3 turns it on and off
  select_fx_row("delay_sync")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "off"), "sync shows off")
  enc(3, 1); assert_equal(params:get("delay_sync"), 1, "E3 up turns sync on")
  enc(3, 1); assert_equal(params:get("delay_sync"), 1, "and a further turn up keeps it on")
  enc(3, -1); assert_equal(params:get("delay_sync"), 0, "E3 down turns it off")
  enc(3, 1)
  assert_equal(shown(context), "K3:delay bypass", "K3 on the sync row is the delay's bypass")
  key(3, 1); key(3, 0)
  assert_equal(params:get("delay_bypass"), 1, "K3 on the sync row bypasses the delay")
  assert_equal(params:get("delay_sync"), 1, "and leaves sync")
  key(3, 1); key(3, 0)
  assert_equal(params:get("delay_bypass"), 0)
  -- time: the division while synced
  select_fx_row("delay_time")
  local time = params:get("delay_time")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "1/8D"), "the time row shows the division")
  enc(3, 1)
  assert_equal(params:get("delay_division"), 8, "E3 on the time row turns the division")
  assert_near(params:get("delay_time"), time, 1e-9, "and leaves delay_time")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "1/4T"), "the new division shows")
  key(1, 1)
  assert_equal(shown(context), "K2:rand K3:freeze", "ALT offers no fine turn for a division (3.8: the freeze)")
  key(1, 0)
  key(3, 1); key(3, 0)
  assert_equal(params:get("delay_bypass"), 1, "K3 on the time row is still the bypass")
  key(3, 1); key(3, 0)
  -- halved: the division and what plays
  params:set("delay_division", 12); params:set("clock_tempo", 30)
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "1 bar>1/2"), "a halved division shows what plays")
  -- sync off: the time row is delay_time again
  params:set("delay_sync", 0)
  enc(3, 1)
  assert_true(params:get("delay_time") > time, "unsynced, E3 turns delay_time")
  assert_equal(params:get("delay_division"), 12, "and leaves the division")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, string.format("%.3f s", params:get("delay_time"))), "the time in seconds")
  -- ping: a percent
  params:set("delay_pingpong", 0.37)
  select_fx_row("delay_pingpong")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "37%"), "ping-pong in percent")
  enc(3, 1)
  assert_near(params:get("delay_pingpong"), 0.38, 1e-6, "E3 turns ping-pong")
end)

test("FX lays out with the delay synced and halved", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  local S = local_value("S")
  local record = S.registry.pages[S.constants.UI_PAGES.index.FX]
  local state
  for _, each in ipairs(record.layout_states) do
    if each.name == "delay synced and halved" then state = each end
  end
  assert_true(state ~= nil, "the FX record has the state")
  state.setup(context)
  assert_equal(S.FX_PAGE.rows[S.fx_row].param_id, "delay_time", "the cursor on the time row")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "1 bar>1/4"), "the widest label shows")
  assert_screen_layout(context, "FX " .. state.name)
end)

-- 3.8 (package 4a, design §7.6): the delay's freeze and clear, the
-- delay-to-reverb amount and a shimmer section. The reverb's freeze was cut
-- from 3.8 (#819): FX reaches it only through S.lib.fx_hold.offered("reverb").
-- A later package may add it behind that seam, so these tests also build it
-- in the stub session: FX_HOLD's reverb record and a binary param of its
-- id, the id written once here
local REVERB_FREEZE_ID = "reverb_freeze"
local function plant_reverb_freeze(S)
  params:add{ type = "binary", id = REVERB_FREEZE_ID, name = "reverb freeze", behavior = "toggle", default = 0,
    action = function() request_redraw() end }
  S.lib.fx_hold.FX_HOLD.reverb = { freeze_id = REVERB_FREEZE_ID }
end

-- The FX_PAGE.rows index of the hold row of an effect ("freeze", "clear")
local function hold_row_index(effect, hold)
  for index, row in ipairs(local_value("FX_PAGE").rows) do
    if row.effect == effect and row.hold == hold then return index end
  end
end

local function select_row_index(index)
  local_value("S").fx_row = index
end

local function shown_hint(context)
  context.screen.clear(); redraw()
  return hint_text(context)
end

-- Every call a params function gets naming `id` raises, until the returned
-- function puts them back (a cut freeze's param is read by nothing)
local function forbid_param(id)
  local names = { "get", "set", "lookup_param", "string", "get_raw", "set_raw", "delta", "t", "set_action" }
  local own = {}
  for _, name in ipairs(names) do
    own[name] = rawget(params, name)
    local real = params[name]
    params[name] = function(self, param_id, ...)
      if param_id == id then error("the cut param " .. id .. " was reached through params:" .. name, 2) end
      return real(self, param_id, ...)
    end
  end
  return function()
    for _, name in ipairs(names) do params[name] = own[name] end
  end
end

test("FX lists master, filter, delay, reverb and shimmer in order", function()
  load_strata()
  local rows = local_value("FX_PAGE").rows
  local expected = {
    { "master", "master" }, { "density", "master", "master_density" }, { "drift", "master", "drift_amount" },
    { "filter", "filter" }, { "type", "filter", "filter_type" }, { "freq", "filter", "filter_freq" },
    { "res", "filter", "filter_res" }, { "mix", "filter", "filter_mix" },
    { "delay", "delay" }, { "time", "delay", "delay_time" }, { "fdbk", "delay", "delay_feedback" },
    { "level", "delay", "delay_mix" }, { "sync", "delay", "delay_sync" }, { "ping", "delay", "delay_pingpong" },
    { "freeze", "delay", hold = "freeze" }, { "clear", "delay", hold = "clear" },
    { "reverb", "reverb" }, { "level", "reverb", "reverb_mix" }, { "size", "reverb", "reverb_size" },
    { "damp", "reverb", "reverb_damp" }, { "from delay", "reverb", "delay_to_reverb" },
    { "freeze", "reverb", hold = "freeze" },
    { "shimmer", "shimmer" }, { "interval", "shimmer", "shimmer_interval" },
    { "delay", "shimmer", "shimmer_delay" }, { "reverb", "shimmer", "shimmer_reverb" },
  }
  assert_equal(#rows, 26, "26 rows")
  local labels, params_rows = 0, 0
  for index, want in ipairs(expected) do
    local row = rows[index]
    local where = "row " .. index .. " (" .. want[1] .. ")"
    assert_equal(row.label, want[1], where .. " label")
    assert_equal(row.section, want[2], where .. " section")
    if row.selectable == false then
      labels = labels + 1
      assert_equal(row.param_id, nil, where .. ": a label has no param")
    else
      params_rows = params_rows + 1
      assert_equal(row.param_id, want[3], where .. " param")
      assert_equal(row.hold, want.hold, where .. " hold")
      if want.hold then assert_equal(row.effect, want[2], where .. ": a hold row names its effect") end
    end
  end
  assert_equal(labels, 5, "five section labels")
  assert_equal(params_rows, 21, "21 param rows: 2 + 4 + 7 + 5 + 3")
  assert_equal(local_value("FX_PAGE").frozen_text, "frz")
  -- the delay's and reverb's labels carry their bypass and freeze
  for _, index in ipairs({ 9, 17 }) do
    assert_equal(rows[index].bypass, rows[index].section, rows[index].label .. " shows its bypass")
    assert_equal(rows[index].freeze, rows[index].section, rows[index].label .. " shows its freeze")
  end
  for _, row in ipairs(rows) do
    if row.section == "shimmer" then assert_equal(row.effect, nil, "a shimmer row has no effect for K3") end
  end
end)

test("FX works with the reverb freeze cut", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  -- a cut 3a leaves the build without the param: removed from the stub's
  -- params if a build has it
  local index = params.lookup[REVERB_FREEZE_ID]
  if index then table.remove(params.params, index); params.lookup[REVERB_FREEZE_ID] = nil end
  S.lib.fx_hold.FX_HOLD.reverb = nil
  assert_true(not S.lib.fx_hold.offered("reverb"), "the reverb's freeze is not offered")
  local restore = forbid_param(REVERB_FREEZE_ID)
  local ok, err = pcall(function()
    show_page("FX")
    params:set("mutation_enabled", 1)
    local rows = S.FX_PAGE.rows
    for row_index = 1, #rows do
      if rows[row_index].selectable ~= false then
        select_row_index(row_index)
        for _, alt in ipairs({ 0, 1 }) do
          key(1, alt); context.screen.clear(); redraw()
          assert_screen_layout(context, "FX, the reverb freeze cut, row " .. row_index .. (alt == 1 and ", ALT" or ""))
        end
        key(1, 0)
      end
    end
    local freeze_row = hold_row_index("reverb", "freeze")
    select_row_index(freeze_row)
    context.screen.clear(); redraw()
    local freeze_text
    for _, entry in ipairs(context.screen.texts) do
      if entry.y and entry.text == "--" then freeze_text = entry end
    end
    assert_true(freeze_text ~= nil, "the reverb's freeze row shows --")
    for _, param_id in ipairs({ "reverb_mix", "reverb_size", "reverb_damp", "delay_to_reverb" }) do
      select_row_index(row_index(param_id))
      context.clear_engine_calls()
      key(1, 1); key(3, 1); key(3, 0); key(1, 0)
      assert_equal(#context.engine_calls, 0, "ALT+K3 on " .. param_id .. " sends nothing")
    end
    select_row_index(freeze_row)
    context.clear_engine_calls()
    key(1, 1); key(3, 1); key(3, 0); key(1, 0)
    enc(3, 1); enc(3, -1)
    assert_equal(#context.engine_calls, 0, "ALT+K3 and E3 on the reverb's freeze row send nothing")
    -- the header on every page, with the delay frozen and not
    for _, frozen in ipairs({ 0, 1 }) do
      params:set("delay_freeze", frozen)
      for page = 1, #PAGE_TITLES do show_page(page); redraw() end
    end
  end)
  restore()
  assert_true(ok, tostring(err))
end)

test("K3 on the clear row clears; on every other delay and reverb row it bypasses", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  select_row_index(hold_row_index("delay", "clear"))
  context.clear_engine_calls()
  key(3, 1); key(3, 0)
  assert_equal(#context.calls_named("clearDelay"), 1, "one clearDelay()")
  assert_equal(#context.calls_named("clearDelay")[1].args, 0, "with no argument")
  assert_equal(#context.calls_named("setBypass"), 0, "no setBypass")
  assert_equal(params:get("delay_bypass"), 0, "the delay keeps running")
  local rows = local_value("FX_PAGE").rows
  for index, row in ipairs(rows) do
    if (row.effect == "delay" or row.effect == "reverb") and row.hold ~= "clear" then
      select_row_index(index)
      context.clear_engine_calls()
      key(3, 1); key(3, 0)
      assert_equal(params:get(row.effect .. "_bypass"), 1, "K3 on " .. row.label .. " bypasses the " .. row.effect)
      assert_equal(#context.calls_named("clearDelay"), 0, "and clears nothing")
      key(3, 1); key(3, 0)
      assert_equal(params:get(row.effect .. "_bypass"), 0, "a second K3 lifts it")
    end
  end
end)

test("ALT+K3 freezes and releases the row's effect; nothing on a bypassed effect, on the shimmer rows, or on a reverb not offered", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("FX")
  local function alt_k3() key(1, 1); key(3, 1); key(3, 0); key(1, 0) end
  for _, param_id in ipairs({ "delay_time", "delay_pingpong" }) do
    select_row_index(row_index(param_id))
    context.clear_engine_calls()
    alt_k3()
    assert_equal(params:get("delay_freeze"), 1, "ALT+K3 on " .. param_id .. " freezes the delay")
    local calls = context.calls_named("setDelayFreeze")
    assert_equal(#calls, 1, "one setDelayFreeze"); assert_equal(calls[1].args[1], 1)
    alt_k3()
    assert_equal(params:get("delay_freeze"), 0, "and a second releases it")
    assert_equal(context.calls_named("setDelayFreeze")[2].args[1], 0)
  end
  select_row_index(hold_row_index("delay", "clear"))
  alt_k3(); assert_equal(params:get("delay_freeze"), 1, "the clear row is a delay row"); alt_k3()
  -- a reverb not offered: nothing
  select_row_index(row_index("reverb_size"))
  context.clear_engine_calls(); alt_k3()
  assert_equal(#context.engine_calls, 0, "ALT+K3 on a reverb not offered sends nothing")
  -- the shimmer and filter and master rows: nothing
  for _, param_id in ipairs({ "shimmer_interval", "shimmer_delay", "shimmer_reverb", "filter_freq", "master_density" }) do
    select_row_index(row_index(param_id))
    context.clear_engine_calls(); alt_k3()
    assert_equal(#context.engine_calls, 0, "ALT+K3 on " .. param_id .. " sends nothing")
    assert_equal(params:get("delay_freeze"), 0, "and freezes nothing")
  end
  -- a reverb offered (the seam a later package may fill): ALT+K3 freezes it
  plant_reverb_freeze(S)
  select_row_index(row_index("reverb_damp"))
  alt_k3()
  assert_equal(params:get(REVERB_FREEZE_ID), 1, "ALT+K3 on a reverb row freezes an offered reverb")
  assert_equal(params:get("delay_freeze"), 0, "and leaves the delay")
  alt_k3()
  assert_equal(params:get(REVERB_FREEZE_ID), 0, "and releases it")
  -- bypassed: nothing
  params:set("reverb_bypass", 1)
  alt_k3()
  assert_equal(params:get(REVERB_FREEZE_ID), 0, "a bypassed reverb does not freeze")
end)

test("ALT+K3 on a bypassed delay does nothing", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  params:set("delay_bypass", 1)
  for _, index in ipairs({ row_index("delay_feedback"), hold_row_index("delay", "freeze") }) do
    select_row_index(index)
    context.clear_engine_calls()
    key(1, 1)
    local hint = shown_hint(context)
    assert_true(not hint:find("K3", 1, true), "the hint has no K3: " .. hint)
    key(3, 1); key(3, 0); key(1, 0)
    assert_equal(#context.engine_calls, 0, "ALT+K3 sends nothing")
    assert_equal(params:get("delay_freeze"), 0, "delay_freeze stays 0")
  end
end)

test("E3 turns a freeze row on and off", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("FX")
  select_row_index(hold_row_index("delay", "freeze"))
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "off"), "the freeze row shows off")
  enc(3, 1); assert_equal(params:get("delay_freeze"), 1, "E3 up freezes")
  enc(3, 1); assert_equal(params:get("delay_freeze"), 1, "a further turn up keeps it")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "on"), "the freeze row shows on")
  enc(3, -1); assert_equal(params:get("delay_freeze"), 0, "E3 down releases")
  plant_reverb_freeze(S)
  select_row_index(hold_row_index("reverb", "freeze"))
  enc(3, 1); assert_equal(params:get(REVERB_FREEZE_ID), 1, "an offered reverb's row freezes")
  enc(3, -1); assert_equal(params:get(REVERB_FREEZE_ID), 0)
end)

test("a frozen effect's section row shows frz at level 4", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("FX")
  local function entries(text)
    local found = {}
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then table.insert(found, entry) end
    end
    return found
  end
  local function label_y(name)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == name and entry.level == 2 then return entry.y end
    end
  end
  select_row_index(row_index("delay_time"))
  context.screen.clear(); redraw()
  assert_equal(#entries("frz"), 0, "nothing frozen: no frz")
  params:set("delay_freeze", 1)
  context.screen.clear(); redraw()
  local found = entries("frz")
  assert_equal(#found, 1, "the delay's section row shows frz")
  assert_equal(found[1].y, label_y("delay"), "on the delay's section row")
  assert_equal(found[1].level, 4, "at level 4")
  assert_screen_layout(context, "FX delay frozen")
  params:set("delay_freeze", 0)
  plant_reverb_freeze(S)
  params:set(REVERB_FREEZE_ID, 1)
  select_row_index(row_index("reverb_mix"))
  context.screen.clear(); redraw()
  found = entries("frz")
  assert_equal(#found, 1, "the reverb's section row shows frz")
  assert_equal(found[1].y, label_y("reverb"), "on the reverb's section row")
  assert_equal(found[1].level, 4, "at level 4")
end)

-- #911's mark: a frozen loop keeps the length it froze at, so the time row
-- shows `held` beside its label (level 4, after the label) while the
-- delay is frozen, in seconds and synced, and the value it shows is the
-- one the release plays
test("the time row is marked while the delay is frozen", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("FX")
  local FX = local_value("FX_PAGE")
  assert_equal(FX.held_text, "held")
  local function entry_of(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return entry end
    end
  end
  select_row_index(row_index("delay_time"))
  context.screen.clear(); redraw()
  assert_true(entry_of("held") == nil, "a running delay's time row has no mark")
  S.lib.fx_hold.toggle("delay")
  context.screen.clear(); redraw()
  local mark, label = entry_of("held"), entry_of("time")
  assert_true(mark ~= nil, "a frozen delay's time row shows held")
  assert_equal(mark.y, label.y, "on the time row")
  assert_equal(mark.level, FX.bypass_level, "at level 4")
  assert_true(mark.x >= FX.param_x + screen.text_extents("time"), "after the label")
  assert_true(h.screen_shows(context, string.format("%.3f s", params:get("delay_time"))),
    "the row still shows the time the release plays")
  assert_screen_layout(context, "FX the time row held")
  -- off the cursor too, and synced
  select_row_index(row_index("delay_feedback"))
  context.screen.clear(); redraw()
  assert_true(entry_of("held") ~= nil, "the mark shows on the row off the cursor")
  params:set("delay_sync", 1)
  select_row_index(row_index("delay_time"))
  context.screen.clear(); redraw()
  assert_true(entry_of("held") ~= nil and h.screen_shows(context, S.lib.delay_sync.label()),
    "a synced time row is marked beside its division")
  assert_screen_layout(context, "FX the synced time row held")
  S.lib.fx_hold.toggle("delay")
  context.screen.clear(); redraw()
  assert_true(entry_of("held") == nil, "released, the mark goes")
end)

test("the reverb's freeze row shows -- where it is not offered, and E3 does nothing there", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("FX")
  select_row_index(hold_row_index("reverb", "freeze"))
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "--"), "the row shows --")
  context.clear_engine_calls()
  enc(3, 1); enc(3, -1)
  assert_equal(#context.engine_calls, 0, "E3 sends nothing")
  assert_equal(shown_hint(context), "K3:reverb bypass", "K3 is the reverb's bypass")
  -- offered: on and off
  plant_reverb_freeze(S)
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "off"), "an offered reverb's row shows off")
  assert_true(not h.screen_shows(context, "--"), "and no --")
end)

-- A clear does nothing on a bypassed delay (the engine's "nothing while
-- bypassed"), so there the clear row offers none: it shows --, and K3 is the
-- bypass as on every other delay row (#419: the hint names only what acts)
test("on a bypassed delay the clear row shows --, and K3 lifts the bypass", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  params:set("delay_bypass", 1)
  select_row_index(hold_row_index("delay", "clear"))
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "--"), "the clear row shows --")
  assert_true(not h.screen_shows(context, "K3"), "and no K3")
  assert_equal(shown_hint(context), "K3:delay on", "the hint is the lift")
  context.clear_engine_calls()
  key(3, 1); key(3, 0)
  assert_equal(#context.calls_named("clearDelay"), 0, "no clearDelay")
  assert_equal(params:get("delay_bypass"), 0, "K3 lifts the bypass")
  assert_equal(#context.calls_named("setBypass"), 1, "one setBypass")
  assert_equal(shown_hint(context), "K3:clear", "running again, the row clears")
end)

test("the clear row shows K3; its hint is K3:clear", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  select_row_index(hold_row_index("delay", "clear"))
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "K3"), "the clear row shows K3")
  assert_equal(shown_hint(context), "K3:clear")
  context.clear_engine_calls()
  enc(3, 1); enc(3, -1)
  assert_equal(#context.engine_calls, 0, "E3 does nothing on the clear row")
  assert_screen_layout(context, "FX the clear row")
end)

test("with ALT on a delay or reverb row the hint is K2:rand K3:freeze E3:fine, or K3:unfreeze while frozen", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("FX")
  key(1, 1)
  select_row_index(row_index("delay_feedback"))
  assert_equal(shown_hint(context), "K2:rand K3:freeze E3:fine")
  params:set("delay_freeze", 1)
  assert_equal(shown_hint(context), "K2:rand K3:unfreeze E3:fine")
  select_row_index(hold_row_index("delay", "freeze"))
  assert_equal(shown_hint(context), "K2:rand K3:unfreeze", "a binary row turns no finer")
  select_row_index(row_index("delay_feedback"))
  key(2, 1); context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
  local widest = shown_hint(context)
  assert_equal(widest, "K2:cancel K3:unfreeze E3:fine", "the widest ALT hint")
  assert_equal(screen.text_extents(widest), 122, "measures 122 px")
  assert_screen_layout(context, "FX ALT on a frozen delay row")
  key(2, 0)
  -- a reverb not offered: no K3; offered, K3:freeze
  select_row_index(row_index("reverb_size"))
  assert_equal(shown_hint(context), "K2:rand E3:fine", "no K3 on a reverb not offered")
  plant_reverb_freeze(S)
  assert_equal(shown_hint(context), "K2:rand K3:freeze E3:fine")
  params:set(REVERB_FREEZE_ID, 1)
  assert_equal(shown_hint(context), "K2:rand K3:unfreeze E3:fine")
  -- the shimmer rows: no K3
  select_row_index(row_index("shimmer_delay"))
  assert_equal(shown_hint(context), "K2:rand E3:fine", "no K3 on shimmer")
  key(1, 0)
end)

test("K3 and the hint do nothing on the shimmer rows", function()
  local context = load_strata(); finish_startup(context)
  show_page("FX")
  for _, param_id in ipairs({ "shimmer_interval", "shimmer_delay", "shimmer_reverb" }) do
    select_row_index(row_index(param_id))
    assert_equal(shown_hint(context), "E3:value", param_id .. ": E3:value")
    context.clear_engine_calls()
    key(3, 1); key(3, 0)
    assert_equal(#context.engine_calls, 0, "K3 on " .. param_id .. " sends nothing")
  end
  params:set("shimmer_interval", 4); params:set("shimmer_delay", 1)
  select_row_index(row_index("shimmer_interval"))
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "oct+5th"), "the interval's name")
  assert_true(h.screen_shows(context, "100%"), "an amount in percent")
  enc(3, -1); assert_equal(params:get("shimmer_interval"), 3, "E3 turns the interval")
end)

test("ALT+K2 on shimmer draws the interval (uniform), delay 0-0.5 and reverb 0-0.4", function()
  local cases = {
    { row = "shimmer_delay", ranges = { shimmer_delay = { 0, 0.5 }, shimmer_reverb = { 0, 0.4 } },
      option = "shimmer_interval" },
    { row = "reverb_size", ranges = { reverb_mix = { 0, 0.5 }, reverb_size = { 0.3, 0.95 }, reverb_damp = { 0, 1 },
      delay_to_reverb = { 0.3, 1 } } },
  }
  for _, case in ipairs(cases) do
    local context = load_strata(); finish_startup(context)
    show_page("FX")
    params:set("filter_mix", 0.4)
    params:set("delay_freeze", 1)
    local seen = {}
    for seed = 1, 40 do
      select_row_index(row_index(case.row))
      math.randomseed(seed)
      context.clear_engine_calls()
      key(1, 1); key(2, 1); key(2, 0); key(1, 0)
      for id, range in pairs(case.ranges) do
        local value = params:get(id)
        assert_true(value >= range[1] - 1e-6 and value <= range[2] + 1e-6, id .. " in its range: " .. value)
      end
      if case.option then seen[params:get(case.option)] = true end
      assert_equal(params:get("delay_freeze"), 1, "the freeze is never drawn")
      assert_equal(params:get("filter_mix"), 0.4, "nor the filter's mix")
      assert_equal(params:get("delay_bypass") + params:get("reverb_bypass"), 0, "nor a bypass")
      assert_equal(#context.calls_named("clearDelay"), 0, "nor the clear")
      assert_equal(#context.calls_named("setDelayFreeze"), 0, "and no freeze is sent")
      key(1, 1); key(2, 1); key(2, 0); key(1, 0)  -- undo
    end
    if case.option then
      for option = 1, #params:lookup_param(case.option).options do
        assert_true(seen[option], case.option .. " draws option " .. option)
      end
    end
  end
end)

-- The reverb frozen on high is not a layout state (the library plants no
-- test param; on this build its freeze is not offered): the test plants the
-- freeze behind fx_hold's seam, on a high tier, and freezes it with toggle
test("FX lays out with a reverb frozen on high where its freeze is offered", function()
  h.write_performance_active({ tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_equal(S.performance.tier, "high", "the high tier")
  plant_reverb_freeze(S)
  show_page("FX")
  S.lib.fx_hold.toggle("reverb")
  assert_equal(params:get(REVERB_FREEZE_ID), 1, "toggle freezes the offered reverb")
  for _, param_id in ipairs({ "reverb_mix", "delay_to_reverb" }) do
    select_row_index(row_index(param_id))
    for _, alt in ipairs({ 0, 1 }) do
      key(1, alt); context.screen.clear(); redraw()
      local count = 0
      for _, entry in ipairs(context.screen.texts) do if entry.text == "frz" then count = count + 1 end end
      if param_id == "reverb_mix" then assert_equal(count, 1, "frz on the reverb's section row") end
      assert_screen_layout(context, "FX reverb frozen on high, " .. param_id .. (alt == 1 and ", ALT" or ""))
    end
    key(1, 0)
  end
  select_row_index(row_index("reverb_mix"))
  key(1, 1)
  assert_equal(shown_hint(context), "K2:rand K3:unfreeze E3:fine", "ALT offers the release")
  key(1, 0)
end)

test("FX's 3.8 layout states lay out", function()
  for _, case in ipairs({
    { name = "delay frozen", frz = 1 },
    { name = "the clear row", shows = "K3" },
    { name = "ALT on a frozen delay row", hint = "K2:cancel K3:unfreeze E3:fine" },
    { name = "shimmer at oct+5th and 100%", shows = "oct+5th" },
    { name = "last row", shows = "oct down" },  -- the widest interval name, 38 px
  }) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    show_page("FX")
    for _, each in ipairs(S.registry.pages[S.constants.UI_PAGES.index.FX].layout_states) do
      assert_true(not each.name:find("reverb frozen", 1, true), "no layout state freezes the reverb")
    end
    local record = S.registry.pages[S.constants.UI_PAGES.index.FX]
    local state
    for _, each in ipairs(record.layout_states) do
      if each.name == case.name then state = each end
    end
    assert_true(state ~= nil, "the FX record has the state " .. case.name)
    state.setup(context)
    context.screen.clear(); redraw()
    if case.frz then
      local count = 0
      for _, entry in ipairs(context.screen.texts) do if entry.text == "frz" then count = count + 1 end end
      assert_equal(count, case.frz, case.name .. ": frz shown " .. case.frz)
    end
    if case.shows then assert_true(h.screen_shows(context, case.shows), case.name .. " shows " .. case.shows) end
    if case.hint then assert_equal(hint_text(context), case.hint, case.name .. "'s hint") end
    assert_screen_layout(context, "FX " .. case.name)
    key(2, 0); key(1, 0)
  end
end)

end
