-- test/unit/pages_fx_test.lua
-- The FX page (lib/pages/fx.lua): its rows, E2/E3 and the K3 bypass
-- Run alone: lua test/run.lua pages_fx

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, text_span, PAGE_TITLES, HINT_ROW_Y = h.finish_startup, h.text_span, h.PAGE_TITLES, h.HINT_ROW_Y
local TEXT_HEIGHT, show_page, assert_screen_layout, count_screen_draws = h.TEXT_HEIGHT, h.show_page, h.assert_screen_layout, h.count_screen_draws
local tap = h.tap

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
  params:set("filter_mix", 0.3); params:set("filter_mix", 0)  -- PARAMS menu, scene recall, ...
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

end
