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

test("K3 bypasses and restores the effect under the cursor", function()
  load_strata(); show_page("FX")
  local S = local_value("S")
  S.fx_row = row_index("delay_time")
  params:set("delay_mix", 0.6); key(3, 1); assert_equal(params:get("delay_mix"), 0)
  key(3, 1); assert_near(params:get("delay_mix"), 0.6, 1e-6)
  load_strata(); show_page("FX"); S = local_value("S")
  S.fx_row = row_index("delay_mix"); key(3, 1)
  assert_near(params:get("delay_mix"), 0.3, 1e-6, "never set: K3 gives 0.3")
  assert_equal(params:get("filter_mix"), 0, "the other effects are untouched")
  load_strata(); show_page("FX"); S = local_value("S")
  S.fx_row = row_index("reverb_size")
  params:set("reverb_mix", 0.8); key(3, 1); assert_equal(params:get("reverb_mix"), 0)
  key(3, 1); assert_near(params:get("reverb_mix"), 0.8, 1e-6)
  load_strata(); show_page("FX"); S = local_value("S")
  S.fx_row = row_index("drift_amount")
  local snapshot = {params:get("filter_mix"), params:get("delay_mix"), params:get("reverb_mix"), params:get("drift_amount")}
  key(3, 1); S.fx_row = row_index("master_density"); key(3, 1)
  assert_equal(params:get("filter_mix"), snapshot[1]); assert_equal(params:get("delay_mix"), snapshot[2])
  assert_equal(params:get("reverb_mix"), snapshot[3]); assert_equal(params:get("drift_amount"), snapshot[4])
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
  S.fx_row = row_index("delay_fdbk") or row_index("delay_feedback")
  params:set("delay_mix", 0.5); assert_equal(hint_text(), "K3:delay bypass")
  params:set("delay_mix", 0); assert_equal(hint_text(), "K3:delay on")
  S.fx_row = row_index("reverb_mix"); params:set("reverb_mix", 0.2)
  assert_equal(hint_text(), "K3:reverb bypass")
  S.fx_row = row_index("master_density"); assert_equal(hint_text(), "E3:value")
  S.fx_row = row_index("drift_amount"); assert_equal(hint_text(), "E3:value")
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
