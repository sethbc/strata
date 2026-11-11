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
  assert_equal(#rows, 12, "density, drift, 4 filter, 3 delay, 3 reverb rows")
  assert_equal(#all_rows, 16, "plus four section labels")
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  for _, extreme in ipairs({ "max", "min" }) do
    for _, row in ipairs(rows) do
      local min_value, max_value = param_range(row.param_id)
      if row.param_id == "filter_type" then min_value, max_value = 2, 3 end  -- highpass, bandpass
      params:set(row.param_id, extreme == "max" and max_value or min_value)
    end
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
  S.fx_row = row_index("delay_time"); context.screen.clear(); redraw()
  for _, name in ipairs({ "delay", "reverb" }) do
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
  S.fx_row = row_index("delay_time")  -- the view shows the delay and reverb labels
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
  params:set("reverb_bypass", 1)
  context.screen.clear(); redraw()
  found = byp_entries()
  assert_equal(#found, 2, "both rows show byp")
  assert_equal(found[2].y, label_y("reverb"), "the second on the reverb's section row")
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
  -- ALT+K3 does nothing on FX: the hint names no K3 (#419)
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
  local state
  for _, each in ipairs(record.layout_states) do
    if each.name == "delay and reverb bypassed" then state = each end
  end
  assert_true(state ~= nil, "the FX record has the state")
  state.setup(context)
  context.screen.clear(); redraw()
  local count = 0
  for _, entry in ipairs(context.screen.texts) do if entry.text == "byp" then count = count + 1 end end
  assert_equal(count, 2, "byp on both rows")
  assert_screen_layout(context, "FX " .. state.name)
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
  { row = "reverb_size", ids = { "reverb_mix", "reverb_size", "reverb_damp" } },
}
local ALL_FX_IDS = { "master_density", "drift_amount", "filter_type", "filter_freq", "filter_res", "filter_mix",
  "delay_time", "delay_feedback", "delay_mix", "delay_bypass", "reverb_mix", "reverb_size", "reverb_damp", "reverb_bypass" }
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
  reverb_mix = { 0, 0.5 }, reverb_size = { 0.3, 0.95 }, reverb_damp = { 0, 1 },
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

end
