-- test/unit/pages_scenes_test.lua
-- The SCENES page (lib/pages/scenes.lua); its rings are in arc_pages_test.lua
-- Run alone: lua test/run.lua pages_scenes

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, hint_text, tap, next_frame = h.show_page, h.hint_text, h.tap, h.next_frame
local assert_screen_layout, screen_shows = h.assert_screen_layout, h.screen_shows

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

-- The overwrite prompt names the keys that answer it: with ALT up, and
-- with ALT held (the final review's item 8)
local function prompt(slot) return "ALT+K3: overwrite S" .. slot end
local function alt_prompt(slot) return "K3 again: overwrite S" .. slot end

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
  enc(2, 15); assert_equal(S.cursors.scene, 17, "stop 17 is the first field")
  enc(2, 100); assert_equal(S.cursors.scene, 20, "E2 stops at the last field")
  enc(2, -1)  -- 19: sequence length
  local length = params:get("scene_sequence_length")
  enc(3, -1); assert_equal(params:get("scene_sequence_length"), length - 1, "field 19 is the sequence length")
  enc(2, -1)  -- 18: sequencer on/off
  enc(3, 1); assert_equal(params:get("scene_sequencer_enabled"), 1, "E3 right turns the sequencer on")
  enc(3, -1); assert_equal(params:get("scene_sequencer_enabled"), 0, "E3 left turns it off")
  enc(2, 2)  -- 20: duration
  local duration = params:get("scene_duration")
  enc(3, 1); assert_true(params:get("scene_duration") > duration, "field 20 is the scene duration")
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
  assert_true(hint_text(context) ~= prompt(4), "no confirmation asked")
end)

test("ALT+K3 on a populated slot asks once more within 2 s", function()
  local context, S = started_on_scenes()
  enc(2, 2)
  capture_scene(3)
  local first = scene_data(S, 3)
  alt_tap(3)
  assert_equal(scene_data(S, 3), first, "the first press does not save")
  assert_equal(S.lib.ui_flash.text("header"), nil, "the arming press flashes no save")
  redraw(); assert_equal(hint_text(context), prompt(3), "hint flash asks again")
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
  redraw(); assert_equal(hint_text(context), prompt(3), "and asks again")
  -- the prompt shows on SCENES only
  show_page("FX"); assert_true(hint_text(context) ~= prompt(3), "not on another page")
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
  redraw(); assert_equal(hint_text(context), prompt(4), "S4 asks for its own")
  alt_tap(3)
  assert_true(scene_data(S, 4) ~= s4, "S4's own second press saves")
end)

test("the overwrite flash goes when the cursor leaves the slot by another route", function()
  local context, S = started_on_scenes()
  capture_scene(3)
  enc(2, 2); alt_tap(3)
  redraw(); assert_equal(hint_text(context), prompt(3), "armed")
  S.cursors.scene = 6   -- as the arc moves it
  next_frame(context)
  assert_true(hint_text(context) ~= prompt(3), "no prompt over another slot")
  assert_equal(S.scenes_page.armed_slot, nil, "disarmed")
end)

test("a replaced overwrite prompt never confirms: ALT+K3 asks again", function()
  local context, S = started_on_scenes()
  capture_scene(1)
  local first = scene_data(S, 1)
  alt_tap(3)
  redraw(); assert_equal(hint_text(context), prompt(1), "armed on S1")
  -- a hints flash with no page covers the prompt
  S.lib.ui_flash.start("hints", "tempo 120")
  context.clock.run_for(0.5)
  alt_tap(3)
  assert_equal(scene_data(S, 1), first, "S1 is not overwritten without its prompt showing")
  context.clock.run_for(1.1); redraw(); assert_equal(hint_text(context), prompt(1), "the prompt shows again")
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
  redraw(); assert_equal(hint_text(context), "empty  ALT+K3:save", "the prompt is cleared (slot 5 is empty)")
  scenes_page.move_cursor(100)
  assert_equal(S.cursors.scene, S.constants.NUM_SCENES + #S.constants.SCENES_FIELDS, "clamped to the last stop")
  scenes_page.move_cursor(-3)
  assert_equal(S.cursors.scene, 1, "clamped to slot 1")
  redraw(); assert_true(context ~= nil, "loaded")
end)

-- #255: the prompt is the page's own hint, not a "hints" flash
local PROMPT_S1, ALT_PROMPT_S1 = prompt(1), alt_prompt(1)

test("the overwrite prompt is the page's hint while armed and lapses after 2 s", function()
  local context, S = started_on_scenes()
  capture_scene(1)
  local first = scene_data(S, 1)
  context.set_time(100); alt_tap(3)
  redraw(); assert_equal(hint_text(context), PROMPT_S1, "the hint row asks")
  key(1, 1); redraw(); assert_equal(hint_text(context), ALT_PROMPT_S1, "with ALT held: K3 again"); key(1, 0)
  assert_equal(scene_data(S, 1), first, "nothing saved")
  assert_true(S.lib.ui_flash.text("hints") == nil, "no hints flash carries it")
  local UI_PAGES = local_value("UI_PAGES")
  key(1, 1); next_frame(context)
  assert_true(not UI_PAGES.screen_dirty, "nothing else asks for the next frame")
  context.set_time(102.1); next_frame(context)
  assert_equal(hint_text(context), "K2:name K3:save", "the frame after 2 s draws, without the prompt")
  key(1, 0)
  assert_true(S.scenes_page.armed_slot == nil, "and disarms")
  local record = S.registry.pages[S.constants.UI_PAGES.index.SCENES]
  assert_equal(record.animates(), false, "the call after the disarming frame stops the animation")
  alt_tap(3); alt_tap(3)
  assert_true(scene_data(S, 1) ~= first, "two presses within 2 s save")
  assert_equal(S.lib.ui_flash.text("header"), "saved S1", "the header flashes saved")
end)

test("a flash from another page neither erases the prompt nor confirms through it", function()
  local context, S = started_on_scenes()
  capture_scene(1)
  local first = scene_data(S, 1)
  context.set_time(100); alt_tap(3)
  buffer_page_flash("buf 1 load failed")
  redraw(); assert_equal(hint_text(context), PROMPT_S1, "BUFFER's flash leaves the prompt showing")
  -- a "hints" flash with no page covers the row on SCENES
  S.lib.ui_flash.start("hints", "tempo 120")
  alt_tap(3)
  assert_equal(scene_data(S, 1), first, "no save while the prompt is covered")
  assert_equal(S.scenes_page.armed_slot, 1, "armed again")
  assert_equal(S.scenes_page.armed_until, util.time() + 2, "for another 2 s")
  context.clock.run_for(2.1)
  assert_true(S.lib.ui_flash.text("hints") == nil, "the flash has ended")
  alt_tap(3)
  assert_equal(scene_data(S, 1), first, "the first press after it only arms")
  alt_tap(3)
  assert_true(scene_data(S, 1) ~= first, "the second saves")
end)

test("drawing SCENES asks for no redraw and ends no flash", function()
  local context, S = started_on_scenes()
  local UI_PAGES = local_value("UI_PAGES")
  capture_scene(3)
  enc(2, 2); alt_tap(3)
  S.cursors.scene = 6   -- off the armed slot, as no move_cursor did
  S.lib.ui_flash.start("hints", "tempo 120")
  UI_PAGES.screen_dirty = false
  redraw()
  assert_equal(S.lib.ui_flash.text("hints"), "tempo 120", "the flash still shows")
  assert_equal(hint_text(context), "tempo 120", "on the hint row")
  assert_true(not UI_PAGES.screen_dirty, "the draw asks for no redraw")
  S.registry.pages[S.constants.UI_PAGES.index.SCENES].hints(false)
  assert_equal(S.lib.ui_flash.text("hints"), "tempo 120", "nor do the hints end it")
  assert_true(not UI_PAGES.screen_dirty, "or ask for a redraw")
end)

test("the overwrite prompt names the keys that answer it, with ALT held and with ALT up", function()
  local context, S = started_on_scenes()
  capture_scene(1)
  local first = scene_data(S, 1)
  alt_tap(3)
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K3 again: overwrite S1", "ALT held: K3 again overwrites")
  key(1, 0); redraw()
  assert_equal(hint_text(context), "ALT+K3: overwrite S1", "ALT up: ALT+K3 overwrites")
  local recalls = {}
  local real = recall_scene
  recall_scene = function(slot, time) table.insert(recalls, slot .. ":" .. string.format("%g", time)) end
  tap(3)
  recall_scene = real
  assert_equal(table.concat(recalls, ","), "1:0", "a plain K3 still recalls")
  assert_equal(scene_data(S, 1), first, "and overwrites nothing")
  alt_tap(3)
  assert_true(scene_data(S, 1) ~= first, "ALT+K3 within 2 s overwrites")
end)

test("SCENES hints", function()
  local context, S = started_on_scenes()
  -- an empty slot: recall does nothing, so the hint names the key that does (#420)
  assert_equal(hint_text(context), "empty  ALT+K3:save", "an empty slot says so and names the save")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:name K3:save", "ALT on a slot: name and save (an empty slot takes a name)")
  key(1, 0)
  S.lib.scenes.save(1); redraw()
  assert_equal(hint_text(context), "K2:fade K3:recall", "a saved slot: fade and recall")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:name K3:save", "ALT on a saved slot")
  -- the fields: ALT+K2 and ALT+K3 return at once, so neither is offered (#419)
  key(1, 0)
  enc(2, 16); redraw()
  assert_equal(hint_text(context), "E2:move E3:edit", "a field")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "E2:move E3:edit", "ALT on a field offers no K3")
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


test("recalling an empty scene says so on the header, from the page and from a grid key (#420)", function()
  local context, S = started_on_scenes()
  tap(3)
  assert_equal(S.lib.ui_flash.text("header"), "S1 empty", "K3 on an empty slot")
  S.lib.ui_flash.start("header", nil)
  recall_scene(3, 0)  -- what a grid recall key calls
  assert_equal(S.lib.ui_flash.text("header"), "S3 empty", "a grid's recall key")
  assert_equal(S.current_scene, 0, "and recalls nothing")
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
-- so E3 on the sequencer field sets its binary param through set_binary_param
-- (lib/ui/params.lua), and a controller mapped to it in PARAMS > MAP
-- follows. The map is as lua/core/pmap.lua's pmap.new makes it, echo on
test("E3 on SCENES' sequencer field echoes to a MIDI-mapped controller (#538)", function()
  local context, S = started_on_scenes()
  local controller = context.midi.plug(1)
  norns.pmap.data.scene_sequencer_enabled = { dev = 1, ch = 1, cc = 43, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  S.lib.pages_scenes.move_cursor(18)   -- the sequencer on/off field
  enc(3, 1)
  assert_equal(params:get("scene_sequencer_enabled"), 1, "E3 right turns the sequencer on")
  enc(3, -1)
  assert_equal(params:get("scene_sequencer_enabled"), 0, "E3 left turns it off")
  assert_equal(cc_echoes(controller, 43), "127,0", "the controller hears both")
end)

-- 3.4 (design §9.4): sixteen slots in two banks of eight, with names

-- The slot numbers SCENES draws above the fields, in drawing order
local function drawn_slot_numbers(context)
  local numbers = {}
  for _, entry in ipairs(context.screen.texts) do
    local number = tonumber(entry.text)
    if number and entry.y > 9 and entry.y < 46 then table.insert(numbers, number) end
  end
  return table.concat(numbers, " ")
end

test("the cursor stops at 16 slots and four fields, and ALT+E2 jumps a bank", function()
  local context, S = started_on_scenes()
  enc(2, 15); assert_equal(S.cursors.scene, 16, "E2 reaches slot 16")
  enc(2, 1); assert_equal(S.cursors.scene, 17, "then the first field")
  enc(2, 100); assert_equal(S.cursors.scene, 20, "and stops at the fourth field")
  S.lib.pages_scenes.move_cursor(3)
  key(1, 1)
  enc(2, 1); assert_equal(S.cursors.scene, 11, "ALT+E2 right: slot 3 to slot 11, the same place in bank 2")
  enc(2, -1); assert_equal(S.cursors.scene, 3, "ALT+E2 left: back to slot 3")
  enc(2, -1); assert_equal(S.cursors.scene, 3, "no slot eight before slot 3: it stays")
  S.lib.pages_scenes.move_cursor(13)
  enc(2, 1); assert_equal(S.cursors.scene, 13, "no slot eight after slot 13: it stays, off the fields")
  enc(2, -1); assert_equal(S.cursors.scene, 5, "slot 13 left: slot 5")
  S.lib.pages_scenes.move_cursor(17)
  enc(2, 1); assert_equal(S.cursors.scene, 18, "on a field row ALT+E2 moves one stop, as E2")
  enc(2, -1); assert_equal(S.cursors.scene, 17, "back one stop")
  enc(2, -1); assert_equal(S.cursors.scene, 16, "and from the first field to slot 16")
  key(1, 0)
  -- a jump is a cursor move: it disarms a pending overwrite
  capture_scene(4)
  S.lib.pages_scenes.move_cursor(4); alt_tap(3)
  assert_equal(S.scenes_page.armed_slot, 4, "armed on S4")
  key(1, 1); enc(2, 1); key(1, 0)
  assert_equal(S.cursors.scene, 12, "jumped to slot 12")
  assert_equal(S.scenes_page.armed_slot, nil, "and disarmed")
  key(1, 1); enc(3, 1); key(1, 0)
  assert_equal(S.cursors.scene, 12, "ALT+E3 never moves the cursor")
end)

test("the page shows the bank of the cursor's slot", function()
  local context, S = started_on_scenes()
  capture_scene(2); capture_scene(12)
  S.lib.scenes.set_name(2, "dawn"); S.lib.scenes.set_name(12, "dusk")
  redraw()
  assert_equal(drawn_slot_numbers(context), "1 2 3 4 5 6 7 8", "slot 1: bank 1")
  assert_true(screen_shows(context, "dawn"), "with slot 2's name")
  assert_true(not screen_shows(context, "dusk"), "and no bank 2 name")
  S.lib.pages_scenes.move_cursor(12); redraw()
  assert_equal(drawn_slot_numbers(context), "9 10 11 12 13 14 15 16", "slot 12: bank 2")
  assert_true(screen_shows(context, "dusk"), "with slot 12's name")
  assert_true(not screen_shows(context, "dawn"), "and no bank 1 name")
  S.lib.pages_scenes.move_cursor(17); redraw()
  assert_equal(drawn_slot_numbers(context), "9 10 11 12 13 14 15 16", "a field shows the last bank shown")
  S.lib.pages_scenes.move_cursor(2); S.lib.pages_scenes.move_cursor(20); redraw()
  assert_equal(drawn_slot_numbers(context), "1 2 3 4 5 6 7 8", "bank 1 after a slot of bank 1")
  assert_screen_layout(context, "SCENES on a field under bank 1")
end)

test("ALT+K2's release opens the name entry; its text names the slot and a cancel keeps the old name", function()
  local context, S = started_on_scenes()
  local te = context.textentry.library
  local script_key, script_enc, script_redraw = key, enc, redraw
  S.lib.pages_scenes.move_cursor(3)
  key(1, 1); key(2, 1)
  assert_true(not context.textentry.open, "nothing opens on the press")
  assert_equal(S.scenes_page.naming, nil, "nothing is being named")
  key(2, 0)
  assert_true(context.textentry.open, "the release opens the entry")
  assert_equal(te.heading, "scene 3 name", "headed with the slot")
  assert_equal(te.txt, "", "starting from the slot's name")
  assert_equal(S.scenes_page.naming, 3, "slot 3 is being named")
  assert_equal(S.alt_held, false, "ALT is forgotten: K1's release goes to the entry")
  assert_true(key == te.key and enc == te.enc, "the globals key and enc are the entry's")
  assert_true(redraw == norns.none, "and redraw draws nothing of Strata's")
  key(1, 0)                                                       -- the entry's: it ignores K1
  assert_true(context.textentry.open, "K1's release leaves the entry open")
  context.textentry.finish("dusk")
  assert_equal(S.lib.scenes.name(3), "dusk", "the text names the slot")
  assert_true(key == script_key and enc == script_enc and redraw == script_redraw, "the script's key, enc and redraw are back")
  assert_equal(S.scenes_page.naming, nil, "nothing is being named")
  assert_true(not S.scenes[3].populated, "an empty slot takes a name and stays empty")
  -- opened again on the named slot, a K2 release inside the entry cancels
  key(1, 1); key(2, 1); key(2, 0)
  assert_equal(te.txt, "dusk", "the entry starts from the slot's name")
  key(1, 0)
  key(2, 1); key(2, 0)                                            -- the entry's K2
  assert_true(not context.textentry.open, "a K2 release cancels the entry")
  assert_equal(S.lib.scenes.name(3), "dusk", "the name is unchanged")
  assert_equal(S.scenes_page.naming, nil, "nothing is being named")
  assert_true(key == script_key and enc == script_enc and redraw == script_redraw, "the script has its keys again")
  -- a field takes no name
  S.lib.pages_scenes.move_cursor(17)
  key(1, 1); tap(2); key(1, 0)
  assert_true(not context.textentry.open, "ALT+K2 on a field opens nothing")
  -- the page works on after the entry
  enc(2, -1)
  assert_equal(S.cursors.scene, 16, "E2 moves the cursor again")
end)

test("a name entry the norns menu took over is forgotten when the menu closes", function()
  local context, S = started_on_scenes()
  local te = context.textentry.library
  local script_key, script_enc = key, enc
  S.lib.pages_scenes.move_cursor(2)
  key(1, 1); key(2, 1); key(2, 0)
  assert_equal(S.scenes_page.naming, 2, "slot 2 is being named")
  -- K1 opens the norns menu; PARAMS names a PSET through the one textentry
  _menu.set_mode(true)
  local pset_name
  te.enter(function(text) pset_name = text end, "pset", "PSET NAME: 1")
  context.textentry.finish("mine")
  assert_equal(pset_name, "mine", "the menu's entry called the menu back")
  assert_equal(S.scenes_page.naming, 2, "Strata's entry has not called back")
  _menu.set_mode(false)                                           -- K1 back to play mode
  assert_equal(S.scenes_page.naming, nil, "the entry is forgotten as the menu closes")
  assert_true(key == script_key and enc == script_enc, "the script's key and enc are back")
  assert_true(_menu.key == script_key and norns.encoders.callback == script_enc,
    "and play mode routes the keys and encoders to them")
  assert_equal(S.lib.scenes.name(2), "", "slot 2 keeps its name")
  -- the page works again, a new entry too
  enc(2, 1); assert_equal(S.cursors.scene, 3, "E2 moves the cursor")
  key(1, 1); key(2, 1); key(2, 0); key(1, 0)
  assert_equal(S.scenes_page.naming, 3, "ALT+K2 opens a new entry")
  context.textentry.finish("noon")
  assert_equal(S.lib.scenes.name(3), "noon", "which names its slot")
end)

test("the norns menu opened and closed over the name entry leaves it open and drawn", function()
  local context, S = started_on_scenes()
  local te = context.textentry.library
  local script_key, script_redraw = key, redraw
  S.lib.pages_scenes.move_cursor(5)
  key(1, 1); key(2, 1); key(2, 0)
  -- norns' set_mode(false) puts the script's redraw back and draws it, while
  -- the entry keeps the keys: the entry takes the screen back
  _menu.set_mode(true)
  local drawn = te.redraws
  _menu.set_mode(false)
  assert_equal(S.scenes_page.naming, 5, "the entry is still open")
  assert_true(key == te.key, "and keeps the keys")
  assert_true(redraw == norns.none, "Strata's redraw draws nothing over it")
  assert_true(te.redraws > drawn, "the entry is drawn again")
  next_frame(context)
  context.textentry.finish("rain")
  assert_equal(S.lib.scenes.name(5), "rain", "it names its slot")
  assert_true(key == script_key and redraw == script_redraw, "and gives the script its key and redraw back")
end)

test("SCENES' keys and the arc button recall through the quantizer", function()
  local context, S = started_on_scenes()
  capture_scene(11)
  S.lib.scenes.set_name(11, "dusk")   -- the quantizer's label stays S<n>, without the name
  local scheduled, recalls = {}, {}
  local real_schedule, real_recall = S.lib.quantize.schedule, recall_scene
  S.lib.quantize.schedule = function(action_key, fn, label)
    table.insert(scheduled, { action_key = action_key, fn = fn, label = label })
    return false
  end
  recall_scene = function(slot, time) table.insert(recalls, slot .. ":" .. string.format("%g", time)) end
  S.lib.pages_scenes.move_cursor(11); params:set("scene_transition_time", 4)
  tap(2); tap(3)
  S.registry.pages[S.constants.UI_PAGES.index.SCENES].arc_button()
  assert_equal(#scheduled, 3, "K2, K3 and the arc button each schedule a recall")
  assert_equal(#recalls, 0, "and none recalls before the quantizer runs it")
  for index, action in ipairs(scheduled) do
    assert_equal(action.action_key, "scene", "action " .. index .. " has the key scene")
    assert_equal(action.label, "S11", "and the label S11")
    action.fn()
  end
  S.lib.quantize.schedule, recall_scene = real_schedule, real_recall
  assert_equal(table.concat(recalls, ","), "11:4,11:0,11:0", "K2 fades, K3 and the button recall at once")
end)

-- The scenes prompt invariant also ties the name entry's slot to its kept
-- callback: naming is nil or a slot, and set exactly while an entry is open
test("the scenes prompt invariant holds the name entry's slot to its callback", function()
  local context, S = started_on_scenes()
  local invariant
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "scenes prompt" then invariant = record.fn end
  end
  assert_true(invariant, "the invariant is registered")
  assert_equal(invariant(), nil, "it holds with no entry open")
  S.scenes_page.naming = 3
  assert_true(type((invariant())) == "string", "naming set with no entry open breaks it")
  S.scenes_page.naming = nil
  S.lib.pages_scenes.move_cursor(4)
  key(1, 1); key(2, 1); key(2, 0)
  assert_equal(S.scenes_page.naming, 4, "an entry is open for slot 4")
  assert_equal(invariant(), nil, "it holds while the entry is open")
  S.scenes_page.naming = nil
  assert_true(type((invariant())) == "string", "an open entry with naming cleared breaks it")
  S.scenes_page.naming = 17
  assert_true(type((invariant())) == "string", "naming outside 1-16 breaks it")
  S.scenes_page.naming = 4
  context.textentry.finish("noon")
  assert_equal(invariant(), nil, "it holds once the entry has called back")
end)

end
