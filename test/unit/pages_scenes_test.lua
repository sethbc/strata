-- test/unit/pages_scenes_test.lua
-- The SCENES page (lib/pages/scenes.lua); its rings are in arc_pages_test.lua
-- Run alone: lua test/run.lua pages_scenes

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, hint_text, tap = h.show_page, h.hint_text, h.tap
local assert_screen_layout = h.assert_screen_layout

local function started_on_scenes()
  local context = load_strata(); finish_startup(context)
  show_page("SCENES")
  return context, local_value("S")
end

-- Hold ALT (K1), press and release key n, let ALT go
local function alt_tap(n)
  key(1, 1); tap(n); key(1, 0)
end

-- The scene's data table (for "unchanged" checks)
local function scene_data(S, slot) return S.scenes[slot].data end

test("SCENES shows eight slots in two columns", function()
  local context, S = started_on_scenes()
  capture_scene(2); capture_scene(3)
  S.current_scene = 3
  S.scene_sequencer_enabled = true; S.scene_sequencer_position = 2
  redraw()
  local function number_entry(slot)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == tostring(slot) and entry.y > 9 and entry.y < 46 then return entry end
    end
  end
  local left_x, right_x
  for slot = 1, 8 do
    local entry = number_entry(slot)
    assert_true(entry, "slot " .. slot .. " number drawn")
    if slot <= 4 then left_x = left_x or entry.x; assert_equal(entry.x, left_x, "slot " .. slot .. " in the left column")
    else right_x = right_x or entry.x; assert_equal(entry.x, right_x, "slot " .. slot .. " in the right column") end
    if slot ~= 1 and slot ~= 5 then assert_true(entry.y > number_entry(slot - 1).y, "rows descend in a column") end
  end
  assert_true(right_x > left_x, "two columns")
  -- a box per slot: filled when populated
  local filled = 0
  for _, rect in ipairs(context.screen.rects) do
    if rect.y > 9 and rect.y < 46 and rect.w == 5 and rect.h == 5 and rect.filled then filled = filled + 1 end
  end
  assert_equal(filled, 2, "slots 2 and 3 draw a filled box")
  -- the current scene is bright, a populated other one dimmer
  assert_equal(number_entry(3).level, 15, "the current scene is level 15")
  assert_true(number_entry(2).level < 15, "another slot is dimmer")
  -- the sequencer position is marked while it runs
  local function marks()
    local n = 0
    for _, entry in ipairs(context.screen.texts) do if entry.text == ">" then n = n + 1 end end
    return n
  end
  assert_equal(marks(), 1, "one sequencer mark while it runs")
  S.scene_sequencer_enabled = false
  redraw()
  assert_equal(marks(), 0, "no mark when it is off")
  assert_screen_layout(context, "SCENES")
end)

-- #254: a 2 s fade has 20 steps of 0.1 s; the first runs inside the recall
test("SCENES blinks the slot a fade goes to, one change per step", function()
  local context = started_on_scenes()
  capture_scene(1); capture_scene(2)
  local function number_level(slot)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == tostring(slot) and entry.y > 9 and entry.y < 46 then return entry.level end
    end
  end
  recall_scene(1, 0); recall_scene(2, 2)
  context.clock.run_for(0.1); redraw()                          -- step 2
  assert_equal(number_level(2), 4, "step 2: the target's slot is dark")
  assert_screen_layout(context, "SCENES while the fading target is dark")
  context.clock.run_for(0.1); redraw()                          -- step 3
  assert_equal(number_level(2), 15, "step 3: the target's slot shows")
  assert_screen_layout(context, "SCENES while the fading target shows")
end)

test("E2 runs through the slots then the fields; E3 edits", function()
  local context, S = started_on_scenes()
  assert_equal(S.cursors.scene, 1, "starts on slot 1")
  enc(2, 1); assert_equal(S.cursors.scene, 2, "E2 moves to the next slot")
  local before = params:get("scene_transition_time")
  enc(3, 2)
  assert_true(params:get("scene_transition_time") > before, "E3 on a slot edits the transition time")
  enc(2, 7); assert_equal(S.cursors.scene, 9, "slot 9 is the first field")
  enc(2, 100); assert_equal(S.cursors.scene, 12, "E2 stops at the last field")
  enc(2, -1)  -- 11: sequence length
  local length = params:get("scene_sequence_length")
  enc(3, -1); assert_equal(params:get("scene_sequence_length"), length - 1, "field 11 is the sequence length")
  enc(2, -1)  -- 10: sequencer on/off
  enc(3, 1); assert_equal(params:get("scene_sequencer_enabled"), 1, "E3 right turns the sequencer on")
  enc(3, -1); assert_equal(params:get("scene_sequencer_enabled"), 0, "E3 left turns it off")
  enc(2, 2)  -- 12: duration
  local duration = params:get("scene_duration")
  enc(3, 1); assert_true(params:get("scene_duration") > duration, "field 12 is the scene duration")
  redraw(); assert_screen_layout(context, "SCENES on a field")
end)

test("K2 recalls with the transition and K3 instantly", function()
  local context, S = started_on_scenes()
  local calls = {}
  local real = recall_scene
  recall_scene = function(slot, time) table.insert(calls, slot .. ":" .. string.format("%g", time)) end
  enc(2, 2); params:set("scene_transition_time", 4)
  tap(2); tap(3)
  recall_scene = real
  assert_equal(table.concat(calls, ","), "3:4,3:0", "K2 uses the transition time, K3 recalls at once")
end)

test("ALT+K3 saves an empty slot at once", function()
  local context, S = started_on_scenes()
  enc(2, 3)
  assert_true(not S.scenes[4].populated, "slot 4 starts empty")
  alt_tap(3)
  assert_true(S.scenes[4].populated, "saved without a question")
  redraw()
  assert_true(hint_text(context) ~= "K3 again: overwrite S4", "no confirmation asked")
end)

test("ALT+K3 on a populated slot asks once more within 2 s", function()
  local context, S = started_on_scenes()
  enc(2, 2)
  capture_scene(3)
  local first = scene_data(S, 3)
  alt_tap(3)
  assert_equal(scene_data(S, 3), first, "the first press does not save")
  assert_equal(S.lib.ui_flash.text("header"), nil, "the arming press flashes no save")
  redraw(); assert_equal(hint_text(context), "K3 again: overwrite S3", "hint flash asks again")
  context.clock.run_for(1)
  alt_tap(3)
  assert_true(scene_data(S, 3) ~= first, "the second press within 2 s saves")
  assert_equal(S.lib.ui_flash.text("header"), "saved S3", "the confirming press flashes saved")
  -- after 2 s it asks again instead
  local second = scene_data(S, 3)
  alt_tap(3)
  context.clock.run_for(2.01)
  alt_tap(3)
  assert_equal(scene_data(S, 3), second, "a press after 2 s only arms again")
  redraw(); assert_equal(hint_text(context), "K3 again: overwrite S3", "and asks again")
  -- the prompt shows on SCENES only
  show_page("FX"); assert_true(hint_text(context) ~= "K3 again: overwrite S3", "not on another page")
end)

test("moving the cursor disarms the overwrite", function()
  local context, S = started_on_scenes()
  capture_scene(3); capture_scene(4)
  enc(2, 2)
  alt_tap(3)
  assert_equal(S.scenes_page.armed_slot, 3, "armed on S3")
  local s4 = scene_data(S, 4)
  enc(2, 1)
  alt_tap(3)
  assert_equal(scene_data(S, 4), s4, "S4 is not overwritten by S3's confirmation")
  redraw(); assert_equal(hint_text(context), "K3 again: overwrite S4", "S4 asks for its own")
  alt_tap(3)
  assert_true(scene_data(S, 4) ~= s4, "S4's own second press saves")
end)

test("the overwrite flash goes when the cursor leaves the slot by another route", function()
  local context, S = started_on_scenes()
  capture_scene(3)
  enc(2, 2); alt_tap(3)
  redraw(); assert_equal(hint_text(context), "K3 again: overwrite S3", "armed")
  S.cursors.scene = 6   -- as the arc moves it
  redraw()
  assert_true(hint_text(context) ~= "K3 again: overwrite S3", "no prompt over another slot")
  assert_equal(S.scenes_page.armed_slot, nil, "disarmed")
end)

test("a replaced overwrite prompt never confirms: ALT+K3 asks again", function()
  local context, S = started_on_scenes()
  capture_scene(1)
  local first = scene_data(S, 1)
  alt_tap(3)
  redraw(); assert_equal(hint_text(context), "K3 again: overwrite S1", "armed on S1")
  -- another hint flash (a failed buffer load) replaces the prompt
  buffer_page_flash("buf 2 load failed")
  context.clock.run_for(0.5)
  alt_tap(3)
  assert_equal(scene_data(S, 1), first, "S1 is not overwritten without its prompt showing")
  redraw(); assert_equal(hint_text(context), "K3 again: overwrite S1", "the prompt shows again")
  alt_tap(3)
  assert_true(scene_data(S, 1) ~= first, "a second ALT+K3 under the prompt saves")
end)

test("S.lib.pages_scenes.move_cursor moves, disarms and clears the prompt", function()
  local context, S = started_on_scenes()
  local scenes_page = S.lib.pages_scenes
  capture_scene(3)
  scenes_page.move_cursor(3)
  assert_equal(S.cursors.scene, 3, "moved to slot 3")
  alt_tap(3)
  assert_equal(S.scenes_page.armed_slot, 3, "armed on S3")
  scenes_page.move_cursor(3)
  assert_equal(S.scenes_page.armed_slot, 3, "staying on the slot keeps it armed")
  scenes_page.move_cursor(5)
  assert_equal(S.cursors.scene, 5, "moved to slot 5")
  assert_equal(S.scenes_page.armed_slot, nil, "disarmed")
  assert_true(S.lib.ui_flash.text("hints") == nil, "the prompt is cleared")
  scenes_page.move_cursor(100)
  assert_equal(S.cursors.scene, S.constants.NUM_SCENES + #S.constants.SCENES_FIELDS, "clamped to the last stop")
  scenes_page.move_cursor(-3)
  assert_equal(S.cursors.scene, 1, "clamped to slot 1")
  redraw(); assert_true(context ~= nil, "loaded")
end)

test("SCENES hints", function()
  local context = started_on_scenes()
  assert_equal(hint_text(context), "K2:fade K3:recall", "plain hints")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K3:save", "ALT hints")
  key(1, 0)
end)

test("the arc button recalls the cursor slot instantly", function()
  local context, S = started_on_scenes()
  local calls = {}
  local real = recall_scene
  recall_scene = function(slot, time) table.insert(calls, slot .. ":" .. tostring(time)) end
  enc(2, 4)
  S.registry.pages[S.constants.UI_PAGES.index.SCENES].arc_button()
  recall_scene = real
  assert_equal(table.concat(calls, ","), "5:0", "instant recall of slot 5")
end)

test("ALT+K3 on SCENES flashes saved", function()
  local _, S = started_on_scenes()
  enc(2, 1)
  assert_equal(S.cursors.scene, 2, "the cursor is on empty slot 2")
  alt_tap(3)
  assert_equal(S.lib.ui_flash.text("header"), "saved S2")
end)

end
