# Facts: the audits' probe tests

Seven scratch unit tests the audits of 2026-11-21 wrote, as they ran against `main` at a1c8e8b4 (3.8.0). They are evidence, not tests of the suite: most print what they find where a test would assert it. Each fix package writes its own failing test first and may start from the probe of its defect. To run one, save its block as `<name>_test.lua` in an empty folder outside the repository and run `lua test/run.lua --jobs 1 --dir <folder> <name>` from the repository's root. A probe that writes a log writes it under `/tmp/strata-probes/` (make the folder first). All seven were run again on 2026-11-21, after the audits, and every defect they show was seen again.

## Scenes, morph, undo and stored data (P1 to P10)

`scenes_probe_test.lua`

```lua
-- Read-only probes for the state machine audit (scenes area). Not part of
-- the repo: run with  lua test/run.lua --jobs 1 --dir <this folder> probe
return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function two_scenes()
  local context = load_strata(); finish_startup(context)
  params:set("reverb_mix", 0.6); capture_scene(2)
  params:set("reverb_mix", 0.2); capture_scene(1)
  return context, local_value("S")
end

local function report(label, value)
  io.stderr:write("PROBE " .. label .. ": " .. tostring(value) .. "\n")
end

-- P1: a recall that supersedes a fade whose step resume is already posted
test("P1 a recall superseding a fade whose resume is posted", function()
  local context, S = two_scenes()
  recall_scene(2, 2)                                   -- a 2 s fade: steps 0.1 s apart
  local id = S.scene_transition_clock
  context.clock.advance_until(id, function() recall_scene(1, 0) end)
  context.clock.run_for(0.5)
  local errors = context.clock.take_errors()
  report("P1 clock errors", #errors .. " " .. tostring(errors[1]))
end)

-- P2: an edit that ends the undo while the undo clock's resume is posted
test("P2 clear_undo with the undo clock's resume posted", function()
  local context, S = two_scenes()
  randomize_voice(2)
  assert_true(S.undo ~= nil, "an undo is held")
  context.clock.run_for(S.constants.UNDO_SECONDS - 0.05)
  assert_true(S.undo ~= nil, "still held just before its end")
  -- step tick by tick until the undo is about to end; cancel in the hook of
  -- the step whose time reaches until_time
  local until_time = S.undo.until_time
  local guard = 0
  while S.undo and guard < 2000 do
    guard = guard + 1
    context.clock.advance(function()
      if S.undo and util.time() >= until_time then clear_undo() end
    end)
  end
  context.clock.run_for(0.2)
  local errors = context.clock.take_errors()
  report("P2 clock errors", #errors .. " " .. tostring(errors[1]))
end)

-- P3: the scene sequencer stopped while its settle wait's resume is posted
test("P3 scene_sequencer_stop with its clock's resume posted", function()
  local context, S = two_scenes()
  params:set("scene_sequence_length", 2)
  params:set("scene_duration", 4)
  params:set("scene_transition_time", 0)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1)
  local id = S.scene_sequencer_clock
  assert_true(id ~= nil, "the sequencer runs")
  context.clock.advance_until(id, function() params:set("scene_sequencer_enabled", 0) end)
  context.clock.run_for(0.5)
  local errors = context.clock.take_errors()
  report("P3 clock errors", #errors .. " " .. tostring(errors[1]))
end)

-- P4: a hand edit of a loop length while a fade runs (scene_transition_active
-- read as "a scene is setting it")
test("P4 a hand edit of loop_length during a fade", function()
  local context, S = two_scenes()
  params:set("v1_loop_start", 0.5)
  params:set("v1_loop_length", 1)
  report("P4 idle: length after a hand set of 1 with start 0.5", params:get("v1_loop_length"))
  params:set("v1_loop_length", 0.25)
  recall_scene(2, 4)                                   -- the scenes hold start 0, length 1
  context.clock.run_for(0.3)
  params:set("v2_loop_start", 0.5)                     -- a voice the fade moves too; use voice 2
  params:set("v2_loop_length", 1)                      -- a hand edit during the fade
  report("P4 fading: v2 start", params:get("v2_loop_start"))
  report("P4 fading: v2 length after a hand set of 1", params:get("v2_loop_length"))
  report("P4 fading: v2 start + length", params:get("v2_loop_start") + params:get("v2_loop_length"))
  cancel_scene_transition()
  report("P4 after cancel: v2 start, length", params:get("v2_loop_start") .. ", " .. params:get("v2_loop_length"))
  capture_scene(3)
  report("P4 a capture of that pair validates", validate_scene(S.scenes[3]))
  context.clock.take_errors()
end)

-- P5: a hand edit of a fading param during a fade is pulled back by the next step
test("P5 a hand edit of a fading param during a fade", function()
  local context, S = two_scenes()
  recall_scene(2, 4)                                   -- reverb 0.2 -> 0.6 over 4 s
  context.clock.run_for(1.05)
  params:set("reverb_mix", 0.95)                       -- the player's hand
  report("P5 after the hand edit", params:get("reverb_mix"))
  context.clock.run_for(0.25)
  report("P5 one step later", params:get("reverb_mix"))
  context.clock.run_for(4)
  report("P5 after the landing", params:get("reverb_mix"))
  context.clock.take_errors()
end)

-- P6: the morph cancels a fade; what is current, what the voices are
test("P6 a morph move during a fade", function()
  local context, S = two_scenes()
  recall_scene(2, 4)
  context.clock.run_for(1.05)
  params:set("morph", 0.1)
  context.clock.run_for(0.5)
  report("P6 transition active", S.scene_transition_active)
  report("P6 current scene", S.current_scene)
  report("P6 reverb", params:get("reverb_mix"))
  context.clock.take_errors()
end)

-- P8: scene_file.problem holds the load's outcome and the last write's
test("P8 a failed write after a set-aside, then a good one", function()
  local dir = h.data_root .. "probe_problem/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  h.write_text(dir .. "scenes.data", "return {")
  local context = load_strata({ data_subdir = "probe_problem" }); finish_startup(context)
  local S = local_value("S")
  report("P8 after the start: problem, backup", tostring(S.scene_file.problem) .. ", " .. tostring(S.scene_file.backup and S.scene_file.backup:match("[^/]*$")))
  S.lib.scenes.save(1)
  report("P8 after a good save: problem, backup", tostring(S.scene_file.problem) .. ", " .. tostring(S.scene_file.backup and S.scene_file.backup:match("[^/]*$")))
  local restore = h.watch_writes("scenes.data", { at = "write", after = 0 })
  S.lib.scenes.save(2)
  restore()
  report("P8 after a failed save: problem, backup", tostring(S.scene_file.problem) .. ", " .. tostring(S.scene_file.backup and S.scene_file.backup:match("[^/]*$")))
  S.lib.scenes.save(3)
  report("P8 after the next good save: problem, backup", tostring(S.scene_file.problem) .. ", " .. tostring(S.scene_file.backup and S.scene_file.backup:match("[^/]*$")))
  context.clock.take_errors()
end)

-- P9: the limit clock of a recording ended by a press with its resume posted
test("P9 a gesture recording ended as its 10-minute clock wakes", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.lib.gestures.press(1)
  for _, hook in ipairs(S.registry.param_touch) do hook("reverb_mix") end
  local id = S.gestures[1].limit_clock
  report("P9 limit clock", id)
  if id then
    context.clock.advance_until(id, function() S.lib.gestures.press(1) end)
    context.clock.run_for(0.2)
  end
  local errors = context.clock.take_errors()
  report("P9 clock errors", #errors .. " " .. tostring(errors[1]))
  report("P9 state", S.lib.gestures.state(1))
  S.lib.gestures.clear(1)
end)

-- P10: the preset row's name after the load is undone, and after a morph
test("P10 the preset row's name after an undo of the load and after a morph apply", function()
  local context, S = two_scenes()
  local presets = S.lib.voice_presets
  params:set("v1_freq", 330)
  assert_true(presets.save(1, 1, "glass"), "saved")
  params:set("v1_freq", 110)
  assert_true(presets.load(1, 1), "loaded")
  report("P10 name after the load", presets.loaded_name(1))
  report("P10 freq after the load", params:get("v1_freq"))
  assert_true(S.lib.mutation.undo(), "the load undone")
  report("P10 freq after the undo", params:get("v1_freq"))
  report("P10 name after the undo", presets.loaded_name(1))
  -- a morph apply between two scenes that differ in voice 1's freq
  assert_true(presets.load(1, 1), "loaded again")
  context.set_time(util.time() + 6)
  params:set("v1_freq", 220); capture_scene(2)
  params:set("v1_freq", 440); capture_scene(1)
  assert_true(presets.load(1, 1), "loaded once more")
  params:set("morph", 1)
  context.clock.run_for(0.6)
  report("P10 freq after the morph to B", params:get("v1_freq"))
  report("P10 name after the morph", presets.loaded_name(1))
  context.clock.take_errors()
end)
end
```

## The screen UI

`ui_probe_test.lua`

```lua
-- scratch probes for the lua-ui audit (not part of the repo)
return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, next_frame, finish_startup = h.load_strata, h.local_value, h.next_frame, h.finish_startup
local show_page, hint_text, tap = h.show_page, h.hint_text, h.tap
local function print(text) local f = io.open("/tmp/strata-probes/probe.log", "a"); f:write(text .. "\n"); f:close() end

local function opened()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("VOICE")
  S.selected_voice = 1
  for index, row in ipairs(voice_page_rows(1)) do
    if row.kind == "preset" then S.lib.pages_voice.place_cursor(index) end
  end
  next_frame(context)
  tap(3)
  next_frame(context)
  return context, S, S.lib.ui_voice_picker
end

test("PROBE picker: ALT+K3 press, step editor pushed over, release lost, then a plain K3 tap", function()
  local context, S, picker = opened()
  assert_true(picker.is_open(), "open")
  enc(2, 6)  -- slot 1
  key(1, 1); key(3, 1)            -- ALT+K3 down on slot 1
  S.lib.pages_seq.open_step_editor(1, 1, 1)   -- a grid's held step
  key(3, 0); key(1, 0)            -- releases go to nobody
  S.lib.pages_seq.close_step_editor(1)
  next_frame(context)
  print("PROBE hint after editor closed: [" .. tostring(hint_text(context)) .. "]")
  print("PROBE textentry open before tap: " .. tostring(context.textentry.open))
  key(3, 1)
  print("PROBE textentry open after plain K3 press: " .. tostring(context.textentry.open))
  key(3, 0)
  print("PROBE textentry open after plain K3 release: " .. tostring(context.textentry.open))
  if context.textentry.open then context.textentry.finish(nil) end
end)

test("PROBE picker: ALT+K2 press, step editor pushed over, release lost: the hint", function()
  local context, S, picker = opened()
  enc(2, 6)
  key(1, 1); key(2, 1)
  S.lib.pages_seq.open_step_editor(1, 1, 1)
  key(2, 0); key(1, 0)
  S.lib.pages_seq.close_step_editor(1)
  next_frame(context)
  print("PROBE hint (ALT up, K2 up) right after: [" .. tostring(hint_text(context)) .. "]")
  context.clock.run_for(2)
  next_frame(context)
  print("PROBE hint 2 s later: [" .. tostring(hint_text(context)) .. "]")
  print("PROBE picker open: " .. tostring(picker.is_open()))
end)

test("PROBE seq step editor: ALT+K2 held, editor replaced by a second open, K2 released", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("MAIN")
  S.lib.pages_seq.open_step_editor(1, 1, 1)
  key(1, 1); key(2, 1)
  S.lib.pages_seq.open_step_editor(2, 3, 2)
  key(2, 0); key(1, 0)
  next_frame(context)
  print("PROBE editor hint: [" .. tostring(hint_text(context)) .. "]")
end)

test("PROBE scenes: armed prompt survives a page change and back within 2 s", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SCENES")
  capture_scene(1)
  S.cursors.scene = 1
  key(1, 1); tap(3); key(1, 0)
  next_frame(context)
  print("PROBE scenes hint armed: [" .. tostring(hint_text(context)) .. "]")
  enc(1, -1); enc(1, 1)
  next_frame(context)
  print("PROBE scenes hint after page away and back: [" .. tostring(hint_text(context)) .. "]")
end)

test("PROBE modal: a page change from outside while an owner is pushed", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SETUP")
  S.lib.ui_zones.open()
  S.lib.pages_lfo.show_lfo(2)   -- any outside set_ui_page
  next_frame(context)
  print("PROBE page under the zones editor: " .. S.constants.UI_PAGES[S.ui_page] .. ", zones open: " .. tostring(S.lib.ui_zones.is_open()))
  print("PROBE hint: [" .. tostring(hint_text(context)) .. "]")
  S.lib.ui_zones.close()
end)

test("PROBE cleanup leaves which owners open", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SETUP")
  S.lib.ui_zones.open()
  cleanup()
  print("PROBE after cleanup: zones open " .. tostring(S.lib.ui_zones.is_open()) .. ", modal top " .. tostring(S.lib.ui_modal.top() ~= nil))
  S.lib.ui_zones.close()
end)
end
```

## Buffers and recording (P1 to P5)

`buffers_probe_test.lua`

```lua
-- A read-only probe (not part of the repo): confirms three claims of the audit
return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, next_frame = h.show_page, h.next_frame
local out = io.open("/tmp/strata-probes/probe/out.txt", "a")
local function say(text) out:write(text .. "\n"); out:flush() end

local function report(context, slot, seconds)
  local S = local_value("S")
  context.polls.fire("bufferState", context.polls.buffer_state_value(slot, S.buffers[slot].loads_sent, seconds))
end

test("P1: each sensitivity detent while an analysis is awaited sends another analyzeBuffer", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  load_buffer(1, "/tmp/a.wav"); report(context, 1, 2)
  assert_true(S.lib.samples.settings(1) ~= nil, "bound")
  S.lib.samples.set(1, "mode", 3)
  S.lib.slices.make(1)
  say("PROBE P1 after make: analyzeBuffer calls = " .. #context.calls_named("analyzeBuffer")
    .. " analyzing=" .. tostring(S.lib.slices.analyzing(1)))
  local editor = S.lib.ui_slice_editor
  show_page("BUFFER")
  say("PROBE P1 open = " .. tostring(editor.open(1)))
  editor.pick_row("amount")
  for _ = 1, 5 do editor.turn_row("amount", 1) end
  say("PROBE P1 after 5 detents: analyzeBuffer calls = " .. #context.calls_named("analyzeBuffer"))
end)

test("P2: a missing slot draws as an empty one on BUFFER", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.buffers[1].missing_path = "/x/gone.wav"
  show_page("BUFFER"); next_frame(context)
  say("PROBE P2 status = " .. tostring(S.lib.buffers.status(1)) .. " free=" .. tostring(S.lib.buffers.is_free(1)))
  local row = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == S.BUFFER_PAGE.row_first_y then row[#row + 1] = entry.text end
  end
  say("PROBE P2 slot 1 row texts = " .. table.concat(row, " | "))
end)

test("P3: a refused overdub from another page shows nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("MAIN")
  load_buffer(1, "/tmp/a.wav")   -- awaiting the engine
  params:set("record_feedback", 50)
  S.lib.grid_core.record_key(1)
  next_frame(context)
  say("PROBE P3 recordBuffer calls = " .. #context.calls_named("recordBuffer")
    .. " hints flash on MAIN = " .. tostring(S.lib.ui_flash.text("hints"))
    .. " header flash = " .. tostring(S.lib.ui_flash.text("header")))
  -- and a failed load reported while MAIN shows
  context.polls.fire("bufferLoadFailed", (1 * 2 + 0) * 8 + 0)
  next_frame(context)
  say("PROBE P3 after load failed on MAIN: hints = " .. tostring(S.lib.ui_flash.text("hints"))
    .. " status = " .. tostring(S.lib.buffers.status(1)))
  show_page("BUFFER"); next_frame(context)
  say("PROBE P3 then on BUFFER (within 1.5 s): hints = " .. tostring(S.lib.ui_flash.text("hints")))
end)

test("P4: a playable recording with no report stays recording; K3 only repeats stopRecord", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  load_buffer(1, "/tmp/a.wav"); report(context, 1, 4)
  params:set("record_feedback", 50)
  record_buffer(1)
  record_buffer(1); record_buffer(1)
  context.clock.run_for(30)
  say("PROBE P4 status after 2 stops and 30 s with no recordState report = " .. tostring(S.lib.buffers.status(1))
    .. " stopRecord calls = " .. #context.calls_named("stopRecord"))
end)

test("P5: a stopped armed replace take: status, row text, header", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("record_threshold", 3)
  show_page("BUFFER")
  record_buffer(1); record_buffer(1)
  next_frame(context)
  local row = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == S.BUFFER_PAGE.row_first_y then row[#row + 1] = entry.text end
  end
  say("PROBE P5 status = " .. tostring(S.lib.buffers.status(1)) .. " row = " .. table.concat(row, " | ")
    .. " grid record level = " .. tostring(S.lib.grid_core.record_level(1)))
end)
end
```

## Voices, freeze and effects (A to D)

`voices_probe_test.lua`

```lua
-- audit probes (scratch only; nothing in the repo)
return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

test("PROBE A: a waiting quantized freeze toggle flips whatever state it finds at the bar", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local function run_to_beat(beat)
    context.clock.run_for((beat - clock.get_beats()) * clock.get_beat_sec())
  end
  S.lib.freeze.toggle(3)
  assert_true(S.lib.freeze.is_frozen(3), "frozen first")
  params:set("quantize_actions", 3)
  run_to_beat(1.5)
  S.lib.freeze.toggle_quantized(3)            -- the player asks: unfreeze at the bar
  assert_true(S.lib.quantize.waiting("freeze3"), "waits")
  params:set("v3_source", S.constants.SOURCE_INPUT)   -- a source switch unfreezes now
  io.stderr:write("\n", "PROBE A after source switch: frozen=" .. tostring(S.lib.freeze.is_frozen(3))
    .. " waiting=" .. tostring(S.lib.quantize.waiting("freeze3")))
  run_to_beat(4.02)
  io.stderr:write("\n", "PROBE A at the bar: frozen=" .. tostring(S.lib.freeze.is_frozen(3)))
end)

test("PROBE B: bypass and freeze after a silent param set", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.lib.fx_hold.toggle("delay")
  io.stderr:write("\n", "PROBE B frozen=" .. tostring(S.lib.fx_hold.frozen("delay")))
  params:set("delay_bypass", 1, true)  -- silent, as params:read(n, true) sets
  io.stderr:write("\n", "PROBE B after silent bypass: bypassed=" .. tostring(S.lib.voice_mix.bypassed("delay"))
    .. " frozen=" .. tostring(S.lib.fx_hold.frozen("delay")) .. " freezable=" .. tostring(S.lib.fx_hold.freezable("delay")))
end)

test("PROBE C: clear on a frozen delay, what Lua sends and shows", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.lib.fx_hold.toggle("delay")
  context.engine_calls = context.engine_calls or {}
  local before = #context.engine_calls
  S.lib.fx_hold.clear()
  for i = before + 1, #context.engine_calls do
    local c = context.engine_calls[i]
    io.stderr:write("\n", "PROBE C sent " .. c.name)
  end
  io.stderr:write("\n", "PROBE C frozen after clear=" .. tostring(S.lib.fx_hold.frozen("delay"))
    .. " flash=" .. tostring(S.lib.ui_flash.text("header")))
end)

test("PROBE D: edits to a stopped voice in its release reach no engine; mute does", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  if not S.voices[1].active then toggle_voice(1) end
  toggle_voice(1)  -- stop: the engine releases
  local before = #context.engine_calls
  params:set("v1_amp", 0.1)
  params:set("v1_filter_freq", 300)
  params:set("v1_mute", 1)
  for i = before + 1, #context.engine_calls do
    local c = context.engine_calls[i]
    io.stderr:write("\n", "PROBE D sent " .. c.name .. " " .. tostring(c.args[2]))
  end
end)
end
```

## The sequencer (C, F, G)

`sequencer_probe_test.lua`

```lua
return function(h)
local out = io.open("/tmp/strata-probes/probe.out", "a")
local function print(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring((select(i, ...))) end out:write(table.concat(t, " "), "\n") out:flush() end
local test = h.test
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local function setup()
  local context = load_strata(); finish_startup(context)
  return context, local_value("S")
end

test("PROBE C: what shows while a quantized pattern start waits", function()
  local context, S = setup()
  params:set("quantize_actions", 3)  -- bar
  -- run to just after a bar, so a whole bar (2 s at 120) lies ahead
  local beats = clock.get_beats()
  context.clock.run_for(((math.floor(beats / 4) + 1) * 4 - beats) * 0.5 + 0.05)
  S.lib.ui_keys.set_ui_page(S.constants.UI_PAGES.index.SEQ)
  pattern_toggle()
  local record = S.registry.pages[S.constants.UI_PAGES.index.SEQ]
  print("  beat " .. clock.get_beats() .. " waiting:", tostring(S.lib.quantize.waiting("patterns")), "playing:", tostring(S.pattern_playing))
  print("  SEQ hint while it waits: " .. record.hints(false))
  print("  header flash: " .. tostring(S.lib.ui_flash.text("header")))
  print("  grid play key level reads S.pattern_playing = " .. tostring(S.pattern_playing))
  S.lib.ui_flash.start("header", "saved S1", 0.3)
  context.clock.run_for(0.5)
  print("  beat " .. clock.get_beats() .. " after another header flash came and went: header flash = " .. tostring(S.lib.ui_flash.text("header"))
    .. ", still waiting = " .. tostring(S.lib.quantize.waiting("patterns")) .. ", playing = " .. tostring(S.pattern_playing))
  pattern_toggle()
  print("  second press: waiting = " .. tostring(S.lib.quantize.waiting("patterns")) .. ", playing = " .. tostring(S.pattern_playing))
end)

test("PROBE F: the division reset armed, and the chain's place, as the user can read them", function()
  local context, S = setup()
  S.patterns[1][1] = 15
  pattern_clock_start(); context.clock.run_for(0.3)
  params:set("seq_division_reset", 1)
  print("  after seq_division_reset: header flash = " .. tostring(S.lib.ui_flash.text("header")) .. ", hints flash = " .. tostring(S.lib.ui_flash.text("hints")))
  pattern_clock_stop()
end)

test("PROBE G: a failed step output on the device", function()
  local context, S = setup()
  S.patterns[1][1] = 15
  S.register_step_output({name = "broken", play = function() error("boom") end})
  local seen = {}
  local real = _G.print
  _G.print = function(...) seen[#seen + 1] = tostring((...)) end
  pattern_clock_start(); context.clock.run_for(0.6)
  _G.print = real
  print("  printed: " .. #seen .. " line(s): " .. tostring(seen[1] and seen[1]:sub(1, 40)))
  print("  header flash = " .. tostring(S.lib.ui_flash.text("header")) .. ", hints flash = " .. tostring(S.lib.ui_flash.text("hints")) .. ", playing = " .. tostring(S.pattern_playing))
  pattern_clock_stop()
end)
end
```

## The 64's chooser (A to C)

`grid_chooser_probe_test.lua`

```lua
-- probe: a positions key released under the 64's chooser, with the view unchanged
return function(h)
local function PJOIN(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end return table.concat(t, " | ") end
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local grid_pane = h.grid_pane

local function buffer_voices(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16; S.buffers[1].loaded = true
  for voice_idx = 1, 3 do
    params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH + 1)
    params:set("v" .. voice_idx .. "_loop_length", 1); params:set("v" .. voice_idx .. "_loop_start", 0)
  end
  context.clear_engine_calls()
  return S
end

test("PROBE A: a position cell released under the chooser (same view kept) stays an anchor", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.positions, 1, 1)
  left.press(3, 1, 1)                    -- cell 3 held
  left.press(1, 8, 1)                    -- NV held
  context.clock.run_for(0.6)             -- chooser opens
  left.press(3, 1, 0)                    -- cell 3's key comes up under the chooser
  left.press(1, 8, 0)                    -- NV up, nothing picked: the same view
  context.clock.run_for(0.2)             -- playhead clock ticks (end_stale_holds)
  io.stderr:write(PJOIN("PROBE A view", S.lib.grid_core.view(1, 1), "led cell3", left.led(3, 1), "held level", S.lib.positions.LEVELS.held) .. "\n")
  left.tap(6, 1)
  io.stderr:write(PJOIN("PROBE A after tap 6: loop_start", params:get("v1_loop_start"), "loop_length", params:get("v1_loop_length"), "buf_pos", params:get("v1_buf_pos")) .. "\n")
end)

test("PROBE B: HD released under the chooser (same view kept) leaves the scan held", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.positions, 2, 1)
  left.press(7, 1, 1)                    -- HD of voice 1
  io.stderr:write(PJOIN("PROBE B held after press", S.lib.positions.scan_held(1)) .. "\n")
  left.press(1, 8, 1)
  context.clock.run_for(0.6)
  left.press(7, 1, 0)                    -- HD up under the chooser
  left.press(1, 8, 0)
  context.clock.run_for(1)
  io.stderr:write(PJOIN("PROBE B scan held after all keys are up", S.lib.positions.scan_held(1), "holds grid:1", S.lib.positions.holds_scan(1, "grid:1")) .. "\n")
end)

test("PROBE C: SV released under the chooser", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.scenes, 1, 1)
  left.press(2, 7, 1)                    -- SV
  left.press(1, 8, 1)
  context.clock.run_for(0.6)
  left.press(2, 7, 0)
  left.press(1, 8, 0)
  context.clock.run_for(0.2)
  grid_redraw()
  io.stderr:write(PJOIN("PROBE C SV led", left.led(2, 7), "populated1", S.scenes[1].populated) .. "\n")
  left.tap(1, 1)
  io.stderr:write(PJOIN("PROBE C after tap scene 1: populated", S.scenes[1].populated) .. "\n")
end)
end
```

## Outside devices (1 to 3)

`io_probe_test.lua`

```lua
-- Scratch probes for the lua-io audit (not part of the repo)
return function(h)
local function print(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end io.stderr:write(table.concat(t, " ") .. "\n") end
local test, assert_true = h.test, h.assert_true
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function io_row_texts(S, section)
  local out = {}
  for _, row in ipairs(S.lib.pages_io.rows()) do
    if row.section == section then
      local text = row.text
      if type(text) == "function" then text = text() end
      out[#out + 1] = tostring(row.kind) .. ":" .. tostring(row.label) .. "=" .. tostring(text) .. " status=" .. tostring(row.status)
    end
  end
  return table.concat(out, " ; ")
end

test("PROBE 1 txo: an envelope setup refused by a full queue", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  context.crow.plug()
  assert_true(S.lib.io_rig.set("ii_bus", "strata"))
  local ii = S.lib.io_ii
  assert_true(ii.leads(), "leads")
  for k = 1, 60 do ii.send("filler", "probe", k) end
  print("P1 queued", ii.queued(), "dropped", ii.dropped())
  local before = ii.dropped()
  params:set("v1_out_txo", 3)
  params:set("v1_out_txo_cv", 2)
  print("P1 dropped by the txo setup", ii.dropped() - before)
  for _ = 1, 60 do context.clock.advance_until(S.lfo_clock) end
  local got = {}
  for _, line in ipairs(context.crow.sent) do if line:match("ii%.txo") then got[#got + 1] = line end end
  print("P1 txo lines crow got after the drain: [" .. table.concat(got, " | ") .. "]")
  -- a later time change shows what the module believes is active
  local from = #context.crow.sent
  params:set("txo_attack", 25)
  for _ = 1, 10 do context.clock.advance_until(S.lfo_clock) end
  local later = {}
  for index = from + 1, #context.crow.sent do later[#later + 1] = context.crow.sent[index] end
  print("P1 after txo_attack 25: [" .. table.concat(later, " | ") .. "]")
end)

test("PROBE 2 ii: a gate high when crow leaves, then the bus turned off", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  context.crow.plug()
  assert_true(S.lib.io_rig.set("ii_bus", "strata"))
  local ii = S.lib.io_ii
  ii.send("er301", "cv", 3, 1); ii.send("er301", "tr", 3, 1)
  for _ = 1, 3 do context.clock.advance_until(S.lfo_clock) end
  context.crow.unplug()
  print("P2 leads after unplug", ii.leads(), "owed", ii.owed())
  ii.send_off("er301", "tr", 3, 0)
  print("P2 owed after the note's off", ii.owed())
  S.lib.io_rig.set("ii_bus", "off")
  context.crow.plug()
  local from = #context.crow.sent
  for _ = 1, 5 do context.clock.advance_until(S.lfo_clock) end
  local n = 0
  for index = from + 1, #context.crow.sent do if context.crow.sent[index]:match("^ii%.") then n = n + 1 end end
  print("P2 under off with crow back: ii lines", n, "owed still", ii.owed())
  print("P2 ii section: " .. io_row_texts(S, "ii"))
  for _, row in ipairs(S.lib.pages_io.rows()) do
    if row.section == "ii" and row.kind == "title" then
      for k, v in pairs(row) do print("P2 title field", k, type(v) == "function" and "fn" or tostring(v)) end
    end
  end
end)

test("PROBE 3 midi out: a voice routed to a port a remote holds", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  context.midi.plug(3, "synth")
  assert_true(S.lib.io_rig.set("remote_grid_port", 3))
  print("P3 owner of 3", S.lib.io_ports.owner(3), "remote status", S.lib.io_remote.status("grid"), "holds", S.lib.io_remote.holds(3))
  params:set("v1_out_port", 3)
  context.clock.advance_until(S.lfo_clock)
  print("P3 voice section: " .. io_row_texts(S, "voice"))
  for _, row in ipairs(S.lib.pages_io.rows()) do
    if row.kind == "title" and (row.section == "midi" or row.section == "voice") then
      print("P3 title", row.section, "label", tostring(row.label), "value", tostring(row.value), "status", tostring(row.status))
    end
  end
end)
end
```
