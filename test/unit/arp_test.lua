-- test/unit/arp_test.lua
-- The arpeggiator (lib/arp.lua, S.lib.arp, 3.8 design §4.3): v<i>_arp's
-- options and its sends (arpOn, arpFold), the list it orders from the
-- interval set or a held chord, the chord path through S.lib.notes.play
-- (MIDI's and a step's), the note hooks, a tuning's fractional intervals,
-- the shuffle and its resends.
-- Run alone: lua test/run.lua arp

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local MODES = {"off", "up", "down", "up-down", "shuffle"}

local function option_index(param_id, name)
  for index, option in ipairs(params:lookup_param(param_id).options) do if option == name then return index end end
  error("no option " .. name .. " in " .. param_id)
end

local function mode(name) return option_index("v1_arp", name) end

-- A started script: voices 1 and 2 run
local function started()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active and S.voices[2].active and not S.voices[3].active, "voices 1 and 2 run")
  return context, S
end

-- The setGrainParam values named name sent to engine voice voice - 1 since the clear, in order
local function grain_values(context, voice, name)
  local values = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == voice - 1 and call.args[2] == name then values[#values + 1] = call.args[3] end
  end
  return values
end

-- The list the engine last got for voice: interval1..intervalCount of the
-- last send (nil: no intervalCount sent since the clear)
local function last_list(context, voice)
  local intervals, count = {}, nil
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == voice - 1 then
      local index = call.args[2]:match("^interval(%d)$")
      if index then intervals[tonumber(index)] = call.args[3] end
      if call.args[2] == "intervalCount" then count = call.args[3] end
    end
  end
  if count == nil then return nil end
  local list = {}
  for index = 1, count do list[index] = intervals[index] end
  return list
end

local function list_text(list)
  if list == nil then return "nil" end
  local texts = {}
  for index, value in ipairs(list) do
    texts[index] = (string.format("%.4f", value):gsub("%.?0+$", ""))
    if texts[index] == "" or texts[index] == "-0" then texts[index] = "0" end
  end
  return "{" .. table.concat(texts, ", ") .. "}"
end

local function assert_list(context, voice, expected, what)
  assert_equal(list_text(last_list(context, voice)), list_text(expected), what)
end

local function sorted(list)
  local copy = {}
  for index, value in ipairs(list) do copy[index] = value end
  table.sort(copy)
  return copy
end

---------------------------------------------------------------------------
-- Step 1: the option and the list
---------------------------------------------------------------------------

test("options and default; arpOn 0/1; arpFold 1 only for up-down", function()
  local context, S = started()
  assert_true(S.lib.arp ~= nil and type(S.lib.arp.ARP) == "table", "S.lib.arp and its ARP")
  local ARP = S.lib.arp.ARP
  assert_equal(table.concat(ARP.modes, ","), table.concat(MODES, ","), "the modes")
  assert_equal(ARP.mode_index.off, 1); assert_equal(ARP.mode_index.up, 2); assert_equal(ARP.mode_index.down, 3)
  assert_equal(ARP.mode_index.up_down, 4); assert_equal(ARP.mode_index.shuffle, 5)
  assert_equal(ARP.shuffle_seconds, 4, "the shuffle's longest wait")
  assert_equal(ARP.max_steps, 8, "the engine's interval1..8")
  for voice = 1, S.constants.NUM_VOICES do
    local id = "v" .. voice .. "_arp"
    local param = params:lookup_param(id)
    assert_true(param ~= nil, id .. " exists")
    assert_equal(param.t, params.tOPTION, id .. " is an option")
    assert_equal(table.concat(param.options, ","), table.concat(MODES, ","), id .. "'s options")
    assert_equal(param_default(id), 1, id .. " is off by default")
    assert_equal(S.voices[voice].values.arp, 1, id .. " is stored")
  end
  -- each mode in turn, off last (a set to the value it holds runs no action)
  for _, index in ipairs({2, 3, 4, 5, 1}) do
    local name = MODES[index]
    context.clear_engine_calls()
    params:set("v1_arp", index)
    assert_equal(table.concat(grain_values(context, 1, "arpOn"), ","), index > 1 and "1" or "0", name .. ": arpOn")
    assert_equal(table.concat(grain_values(context, 1, "arpFold"), ","), name == "up-down" and "1" or "0",
      name .. ": arpFold")
    assert_equal(S.lib.arp.on(1), index > 1, name .. ": on")
    assert_equal(S.lib.arp.mode(1), name, name .. ": mode")
  end
  -- a stopped voice records its choice and sends nothing; its start sends both
  context.clear_engine_calls()
  params:set("v3_arp", ARP.mode_index.up_down)
  assert_equal(#context.calls_named("setGrainParam"), 0, "a stopped voice: nothing sent")
  toggle_voice(3)
  assert_equal(table.concat(grain_values(context, 3, "arpOn"), ","), "1", "the start sends arpOn")
  assert_equal(table.concat(grain_values(context, 3, "arpFold"), ","), "1", "and arpFold")
  local first_on = nil
  for index, call in ipairs(context.engine_calls) do
    if call.name == "voiceOn" and first_on == nil then first_on = index end
  end
  for index, call in ipairs(context.engine_calls) do
    if call.name == "setGrainParam" and (call.args[2] == "arpOn" or call.args[2] == "arpFold") then
      assert_true(index < first_on, call.args[2] .. " goes before voiceOn")
    end
  end
end)

test("no chord, octaves set: up {-12, 0, 12}, down {12, 0, -12}, up-down {-12, 0, 12} with the fold, shuffle a permutation of the set", function()
  local context, S = started()
  params:set("v1_intervals", S.lib.variation.VARIATION.set_index.octaves)
  context.clear_engine_calls()
  params:set("v1_arp", mode("up"))
  assert_list(context, 1, {-12, 0, 12}, "up: ascending")
  params:set("v1_arp", mode("down"))
  assert_list(context, 1, {12, 0, -12}, "down: descending")
  context.clear_engine_calls()
  params:set("v1_arp", mode("up-down"))
  assert_list(context, 1, {-12, 0, 12}, "up-down: ascending")
  assert_equal(table.concat(grain_values(context, 1, "arpFold"), ","), "1", "the engine folds it")
  params:set("v1_arp", mode("shuffle"))
  local list = last_list(context, 1)
  assert_equal(list_text(sorted(list)), list_text({-12, 0, 12}), "shuffle: the set's three, once each")
  assert_equal(#S.lib.arp.list(1, S.lib.variation.interval_set(1)), 3, "list gives the shuffle")
  -- off: the set as it is, as 3.7 sent it
  params:set("v1_intervals", S.lib.variation.VARIATION.set_index.fifths)
  context.clear_engine_calls()
  params:set("v1_arp", mode("off"))
  assert_list(context, 1, {-12, -5, 0, 7, 12}, "off: the set in its own order")
  -- up-down with fifths: ascending too, eight padded with 0s past the count
  context.clear_engine_calls()
  params:set("v1_arp", mode("down"))
  assert_list(context, 1, {12, 7, 0, -5, -12}, "down: fifths descending")
  local padded = grain_values(context, 1, "interval8")
  assert_equal(padded[#padded], 0, "interval8 is 0 past the count")
end)

test("custom set {7, -12, 0}: up sorts it", function()
  local context, S = started()
  params:set("v1_intervals", S.lib.variation.VARIATION.set_index.custom)
  for index, value in ipairs({7, -12, 0, 19, 12}) do params:set("v1_custom_interval_" .. index, value) end
  context.clear_engine_calls()
  params:set("v1_arp", mode("up"))
  assert_list(context, 1, {-12, 0, 7, 12, 19}, "up: the custom set ascending")
  -- a custom interval's change resends the ordered list
  context.clear_engine_calls()
  params:set("v1_custom_interval_1", -24)
  assert_list(context, 1, {-24, -12, 0, 12, 19}, "a custom interval moved: the list ascending again")
end)

test("intervals off and the arpeggiator on: intervalCount 0, the own note alone", function()
  local context, S = started()
  assert_equal(S.voices[1].values.intervals, S.lib.variation.VARIATION.set_index.off, "intervals off")
  context.clear_engine_calls()
  params:set("v1_arp", mode("up"))
  assert_list(context, 1, {}, "an empty list")
  assert_equal(table.concat(grain_values(context, 1, "intervalCount"), ","), "0", "intervalCount 0")
end)

test("a scale change resends the list for the chord set", function()
  local context, S = started()
  params:set("v1_intervals", S.lib.variation.VARIATION.set_index.chord)
  params:set("v1_arp", mode("down"))
  context.clear_engine_calls()
  params:set("scale", option_index("scale", "Major Pentatonic"))
  assert_list(context, 1, {14, 9, 4, 0}, "Major Pentatonic's 0, 4, 9, 14, descending")
  -- a tuning change resends it too (S.lib.variation.tuning_changed's chords)
  params:set("scale", 1)
  context.clear_engine_calls()
  local entry
  for _, built_in in ipairs(S.lib.tuning.built_ins()) do
    if built_in.name == "19 equal" then entry = built_in end
  end
  S.lib.tuning.select(entry)
  local step = 12 / 19
  assert_list(context, 1, {17 * step, 11 * step, 6 * step, 0}, "19 equal's chord, descending")
end)

test("a scene keeps the mode, switches it at a fade's end and refuses one outside 1-5", function()
  local context, S = started()
  params:set("v2_arp", mode("up-down"))
  capture_scene(1)
  assert_equal(S.scenes[1].data.voices[2].values.arp, mode("up-down"), "captured")
  local _, by_key = S.lib.params_setup.voice_scene_keys(2)
  assert_equal(table.concat(by_key.arp.range, ","), "1,5", "arp is discrete, 1 to 5")
  params:set("v2_arp", mode("off"))
  recall_scene(1, 4); h.wake(context, "scene_transition_clock")
  context.clock.run_for(2)
  assert_equal(params:get("v2_arp"), mode("off"), "the mode holds until the fade's end")
  context.clock.run_for(3)
  assert_equal(params:get("v2_arp"), mode("up-down"), "recalled at the end")
  -- a scene missing the key gets the default; one past the range is refused
  -- (fill_scene and validate_scene take a whole scene: name, populated, data)
  local function copy() return S.lib.data_files.decode(S.lib.data_files.encode(S.scenes[1])) end
  local scene = copy()
  assert_true(validate_scene(scene), "the captured scene is valid")
  scene.data.voices[2].values.arp = nil
  fill_scene(scene)
  assert_equal(scene.data.voices[2].values.arp, mode("off"), "fill_scene: off")
  scene = copy()
  scene.data.voices[2].values.arp = 6
  assert_true(not validate_scene(scene), "a mode of 6 is refused")
end)

---------------------------------------------------------------------------
-- Step 2: the chord path
---------------------------------------------------------------------------

local function note_on(context, channel, note, velocity)
  context.midi.send(1, {type = "note_on", note = note, vel = velocity or 100, ch = channel})
end

local function note_off(context, channel, note)
  context.midi.send(1, {type = "note_off", note = note, vel = 0, ch = channel})
end

-- noteOn and noteOff calls on engine voice voice - 1's extra slots (engine slot > 0)
local function extra_calls(context, voice, name)
  local list = {}
  for _, call in ipairs(context.calls_named(name)) do
    if call.args[1] == voice - 1 and call.args[2] > 0 then list[#list + 1] = call end
  end
  return list
end

local function count_named(context, name, voice)
  local n = 0
  for _, call in ipairs(context.calls_named(name)) do
    if voice == nil or call.args[1] == voice - 1 then n = n + 1 end
  end
  return n
end

local function release_mode() params:set("midi_note_off", 2) end

-- One LFO step: a held chord's change reaches the engine there (fix round 1)
local function tick(context, S) context.clock.advance_until(S.lfo_clock) end

test("C-E-G held by MIDI on a running arpeggiating voice: intervals 0, 4, 7, count 3; play returns 1, 0, 0; no noteOn on slots 2-8; pool_used 0", function()
  local context, S = started()
  local notes = S.lib.notes
  assert_equal(notes.NOTES.arp_slot, 0, "the arpeggiator's slot is 0")
  params:set("v1_arp", mode("up"))
  context.clear_engine_calls()
  for _, number in ipairs({60, 64, 67}) do note_on(context, 1, number) end
  tick(context, S)
  assert_list(context, 1, {0, 4, 7}, "the held chord is the list")
  local counts = grain_values(context, 1, "intervalCount")
  assert_equal(counts[#counts], 3, "intervalCount 3")
  assert_equal(#extra_calls(context, 1, "noteOn"), 0, "no noteOn on an extra slot")
  assert_equal(notes.pool_used(), 0, "the pool unused")
  assert_equal(notes.held(1), 1, "one slot: the own note")
  assert_equal(count_named(context, "retrigger", 1), 3, "each key accents the voice once")
  assert_equal(count_named(context, "voiceOn", 1), 0, "and never starts it")
  local held = S.lib.arp.held(1)
  assert_equal(#held, 2, "the arpeggiator holds E and G")
  assert_equal(held[1].pitch, 64); assert_equal(held[2].pitch, 67)
  -- play's returns, on voice 2
  params:set("v2_arp", mode("up"))
  local function play(key, pitch)
    return notes.play(2, {owner = "midi", key = key, pitch = pitch, velocity = 0.5, park = true,
      set_own = function() end})
  end
  assert_equal(play(1, 60), 1, "C: the own note")
  assert_equal(play(2, 64), 0, "E: the arpeggiator's")
  assert_equal(play(3, 67), 0, "G: the arpeggiator's")
  assert_equal(notes.find(2, "midi", 2), nil, "find does not find an arpeggiated note")
  assert_equal(notes.pool_used(), 0)
end)

test("release mode: lifting E resends {0, 7}", function()
  local context, S = started()
  release_mode()
  params:set("v1_arp", mode("up"))
  for _, number in ipairs({60, 64, 67}) do note_on(context, 1, number) end
  tick(context, S)
  context.clear_engine_calls()
  note_off(context, 1, 64)
  tick(context, S)
  assert_list(context, 1, {0, 7}, "E's step gone")
  assert_equal(count_named(context, "noteOff"), 0, "no noteOff")
  assert_true(S.voices[1].active, "the voice runs")
end)

test("latch: the list stays until the next chord's first key", function()
  local context, S = started()
  params:set("v1_arp", mode("up"))
  for _, number in ipairs({60, 64, 67}) do note_on(context, 1, number) end
  tick(context, S)
  context.clear_engine_calls()
  for _, number in ipairs({60, 64, 67}) do note_off(context, 1, number) end
  tick(context, S)
  assert_equal(#context.engine_calls, 0, "the lifts send nothing")
  assert_equal(#S.lib.arp.held(1), 2, "the chord stays")
  -- the next chord's first key replaces it
  note_on(context, 1, 62)
  tick(context, S)
  assert_list(context, 1, {}, "the chord gone: the voice's set, none")
  assert_equal(#S.lib.arp.held(1), 0, "nothing held")
  note_on(context, 1, 65)
  tick(context, S)
  assert_list(context, 1, {0, 3}, "the new chord, from D")
end)

test("lifting C (the own note) leaves the own note sounding: no noteOff on slot 0, list {0, 4, 7} on C's pitch", function()
  local context, S = started()
  release_mode()
  params:set("v1_arp", mode("up"))
  for _, number in ipairs({60, 64, 67}) do note_on(context, 1, number) end
  tick(context, S)
  context.clear_engine_calls()
  note_off(context, 1, 60)
  tick(context, S)
  assert_equal(count_named(context, "noteOff"), 0, "no noteOff: the own note does not park")
  assert_true(S.voices[1].active, "the voice runs")
  assert_equal(list_text(S.lib.arp.list(1, S.lib.variation.interval_set(1))), list_text({0, 4, 7}),
    "the list keeps C as its base")
  assert_list(context, 1, nil, "nothing sent: the list is unchanged")
  -- the next key takes the free slot 1: the own note and the new base
  context.clear_engine_calls()
  note_on(context, 1, 69)
  tick(context, S)
  assert_equal(S.lib.notes.slots(1)[1].pitch, 69, "A is the own note")
  assert_list(context, 1, {-5, -2, 0}, "E and G worked out again from A")
end)

test("turned on with two extra notes sounding: noteOff cut on both slots, their pitches in the list", function()
  local context, S = started()
  for _, number in ipairs({60, 64, 67}) do note_on(context, 1, number) end
  assert_equal(S.lib.notes.pool_used(), 2, "two extra notes")
  context.clear_engine_calls()
  params:set("v1_arp", mode("down"))
  local offs = extra_calls(context, 1, "noteOff")
  assert_equal(#offs, 2, "both slots cut")
  for index, call in ipairs(offs) do
    assert_equal(call.args[2], index, "slot " .. index + 1)
    assert_equal(call.args[3], 1, "a cut")
  end
  assert_equal(S.lib.notes.pool_used(), 0, "the pool free")
  assert_list(context, 1, {7, 4, 0}, "their pitches in the list, down")
  assert_equal(#extra_calls(context, 1, "noteOn"), 0, "no noteOn")
end)

test("turned off: intervalCount 0 with no set; the held keys silent until played again", function()
  local context, S = started()
  release_mode()
  params:set("v1_arp", mode("up"))
  for _, number in ipairs({60, 64, 67}) do note_on(context, 1, number) end
  context.clear_engine_calls()
  params:set("v1_arp", mode("off"))
  assert_list(context, 1, {}, "the list ends")
  assert_equal(table.concat(grain_values(context, 1, "arpOn"), ","), "0", "arpOn 0")
  assert_equal(#S.lib.arp.held(1), 0, "nothing held")
  assert_equal(#extra_calls(context, 1, "noteOn"), 0, "the held keys stay silent")
  context.clear_engine_calls()
  note_off(context, 1, 64)
  assert_equal(count_named(context, "noteOff"), 0, "E's lift ends nothing")
  note_on(context, 1, 64)
  assert_equal(#extra_calls(context, 1, "noteOn"), 1, "played again: an extra note")
end)

test("MIDI out receives C, E and G on and off (the hooks)", function()
  local context, S = started()
  release_mode()
  local device = context.midi.plug(3, "synth")
  params:set("v1_out_port", 3)
  context.clock.advance_until(S.lfo_clock)
  params:set("v1_arp", mode("up"))
  local log = {}
  S.register_note_hook({name = "log",
    started = function(voice, slot, note) log[#log + 1] = "started " .. voice .. " " .. slot .. " " .. note.pitch end,
    ended = function(voice, slot, note) log[#log + 1] = "ended " .. voice .. " " .. slot .. " " .. note.pitch end})
  device.sent = {}
  note_on(context, 1, 60); note_on(context, 1, 64); note_on(context, 1, 67)
  note_off(context, 1, 67); note_off(context, 1, 64)
  assert_equal(table.concat(log, "; "), "started 1 1 60; started 1 0 64; started 1 0 67; ended 1 0 67; ended 1 0 64",
    "the hooks hear each held note, the arpeggiator's with slot 0")
  local texts = {}
  for _, data in ipairs(device.sent) do
    local msg = midi.to_msg(data)
    if msg.type == "note_on" or msg.type == "note_off" then texts[#texts + 1] = msg.type .. " " .. msg.note end
  end
  assert_equal(table.concat(texts, ", "), "note_on 60, note_on 64, note_on 67, note_off 67, note_off 64",
    "MIDI out plays the chord")
end)

test("a 19-tone tuning: E's interval is fractional", function()
  local context, S = started()
  local entry
  for _, built_in in ipairs(S.lib.tuning.built_ins()) do
    if built_in.name == "19 equal" then entry = built_in end
  end
  S.lib.tuning.select(entry)
  params:set("v1_arp", mode("up"))
  context.clear_engine_calls()
  note_on(context, 1, 60); note_on(context, 1, 64)
  tick(context, S)
  local list = last_list(context, 1)
  assert_equal(#list, 2, "two steps")
  assert_near(list[1], 0, 1e-9, "C")
  -- the tuning's own tone (its text holds cents to four places), exactly
  assert_near(list[2], S.lib.tuning.pitch_of_key(64) - S.lib.tuning.pitch_of_key(60), 1e-9, "E: its key's pitch")
  assert_near(list[2], 4 * 12 / 19, 1e-6, "E: four tones of 19 equal")
  assert_true(list[2] % 1 ~= 0, "a fractional interval")
end)

test("MPE notes on an arpeggiating voice: entries without per-note expression", function()
  local context, S = started()
  params:set("v1_arp", mode("up"))
  note_on(context, 1, 60); note_on(context, 1, 64)
  context.clear_engine_calls()
  assert_equal(S.lib.expression.update(1, "midi", 128 + 64, {bend = 2, pressure = 1}), false,
    "the arpeggiated note takes no expression")
  context.clock.advance_until(S.lfo_clock)
  assert_equal(count_named(context, "noteExpression"), 0, "nothing sent for it")
end)

test("a held chord takes at most eight steps, the own note's included", function()
  local context, S = started()
  params:set("v1_arp", mode("up"))
  for number = 60, 70 do note_on(context, 1, number) end
  tick(context, S)
  context.clear_engine_calls()
  note_on(context, 1, 71)
  tick(context, S)
  local list = last_list(context, 1)
  assert_equal(#list, S.lib.arp.ARP.max_steps, "eight steps")
  assert_equal(list_text(list), list_text({0, 5, 6, 7, 8, 9, 10, 11}), "the newest seven kept, up")
  assert_equal(#S.lib.arp.held(1), S.lib.arp.ARP.max_steps - 1, "seven held beside the own note")
end)

test("the note hooks' starts and ends balance across the arpeggiator's paths", function()
  local context, S = started()
  local counts = {started = 0, ended = 0}
  S.register_note_hook({name = "count",
    started = function() counts.started = counts.started + 1 end,
    ended = function() counts.ended = counts.ended + 1 end})
  local notes = S.lib.notes
  local function play(voice, key, pitch, owner)
    return notes.play(voice, {owner = owner or "midi", key = key, pitch = pitch, velocity = 0.5, park = true,
      set_own = function() end})
  end
  play(1, 1, 60); play(1, 2, 64); play(1, 3, 67)              -- extra notes
  params:set("v1_arp", mode("up"))                              -- taken into the list
  play(1, 3, 68); play(1, 4, 70, "seq")                         -- a move, a step's note
  for key = 5, 12 do play(1, key, 60 + key) end                 -- past the room: the oldest go
  notes.release(1, "midi", 12); notes.release_owner(1, "seq")
  notes.release(1, "midi", 1)                                   -- the own note's record goes
  play(1, 11, 71)                                               -- a listed key takes slot 1
  params:set("v1_arp", mode("off"))                             -- the list goes
  play(2, 1, 60); params:set("v2_arp", mode("down")); play(2, 2, 64); play(2, 3, 67)
  toggle_voice(2)                                               -- a stop ends them
  play(1, 20, 60); params:set("v1_arp", mode("up")); play(1, 21, 63)
  notes.forget_owner(1, "midi")
  assert_true(counts.started > 10, "the paths started " .. counts.started .. " notes")
  assert_equal(counts.ended, counts.started, "every start has its end")
end)

---------------------------------------------------------------------------
-- Step 3: the shuffle
---------------------------------------------------------------------------

local function lfo_step(context, S) context.clock.advance_until(S.lfo_clock) end

local function arp_hook(S)
  for _, record in ipairs(S.registry.voice_hit) do
    if record.name == "arp" then return record end
  end
end

-- A shuffling voice 1 on the fifths, every send of its making done
local function shuffling(context, S)
  params:set("v1_intervals", S.lib.variation.VARIATION.set_index.fifths)
  params:set("v1_arp", mode("shuffle"))
  lfo_step(context, S)
  context.clear_engine_calls()
end

local function list_sends(context, voice)
  local n = 0
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == voice - 1 and (call.args[2]:match("^interval%d$") or call.args[2] == "intervalCount") then
      n = n + 1
    end
  end
  return n
end

test("the voice-hit hook sends nothing", function()
  local context, S = started()
  shuffling(context, S)
  local hook = arp_hook(S)
  assert_true(hook ~= nil, "the arp voice-hit hook is registered")
  hook.hit(1, {velocity = 1, source = "step", slot = 1})
  assert_equal(#context.engine_calls, 0, "a hit sends nothing")
end)

test("shuffle: a hit marks the voice and the next LFO step resends (9 messages, counted); 4 s without a hit resends", function()
  local context, S = started()
  shuffling(context, S)
  S.lib.engine_sync.retrigger(1, 1, "action")
  assert_equal(list_sends(context, 1), 0, "the hit itself sends no list")
  local before = S.lib.engine_sync.budget_state().sent
  lfo_step(context, S)
  assert_equal(list_sends(context, 1), S.lib.arp.ARP.max_steps + 1, "the next step resends: 9 messages")
  assert_equal(S.lib.engine_sync.budget_state().sent - before, S.lib.arp.ARP.max_steps + 1, "counted")
  assert_equal(list_text(sorted(last_list(context, 1))), list_text({-12, -5, 0, 7, 12}), "a shuffle of the set")
  context.clear_engine_calls()
  lfo_step(context, S)
  assert_equal(list_sends(context, 1), 0, "no hit: nothing at the next step")
  context.set_time(util.time() + S.lib.arp.ARP.shuffle_seconds - 0.5)
  lfo_step(context, S)
  assert_equal(list_sends(context, 1), 0, "nothing before 4 s")
  context.set_time(util.time() + 0.6)
  lfo_step(context, S)
  assert_equal(list_sends(context, 1), S.lib.arp.ARP.max_steps + 1, "4 s without a hit: resent")
  -- another mode, a stopped voice: no resend
  context.clear_engine_calls()
  params:set("v1_arp", mode("up"))
  context.clear_engine_calls()
  S.lib.engine_sync.retrigger(1, 1, "action")
  context.set_time(util.time() + S.lib.arp.ARP.shuffle_seconds + 1)
  lfo_step(context, S)
  assert_equal(list_sends(context, 1), 0, "up: no reshuffle")
end)

test("the shuffle draws a fresh order: over many hits every place takes more than one value", function()
  local context, S = started()
  math.randomseed(8)
  shuffling(context, S)
  local firsts = {}
  for _ = 1, 40 do
    S.lib.engine_sync.retrigger(1, 1, "action")
    lfo_step(context, S)
    firsts[last_list(context, 1)[1]] = true
  end
  local distinct = 0
  for _ in pairs(firsts) do distinct = distinct + 1 end
  assert_true(distinct > 1, "the first step changes: " .. distinct .. " values")
end)

---------------------------------------------------------------------------
-- Fix round 1: a list is sent only when it changed, once a step
---------------------------------------------------------------------------

test("a chord of four keys in one burst sends its list once, at the next LFO step; the first key's own note at once", function()
  local context, S = started()
  params:set("v1_arp", mode("up"))
  lfo_step(context, S)
  context.clear_engine_calls()
  for _, number in ipairs({60, 64, 67, 71}) do note_on(context, 1, number) end
  assert_near(params:get("v1_freq"), 261.6256, 1e-3, "C is the own note at once")
  assert_equal(count_named(context, "retrigger", 1), 4, "each key accents the voice at once")
  assert_equal(list_sends(context, 1), 0, "no list yet")
  lfo_step(context, S)
  assert_equal(list_sends(context, 1), S.lib.arp.ARP.max_steps + 1, "the list once: nine messages")
  assert_list(context, 1, {0, 4, 7, 11}, "the whole chord")
  context.clear_engine_calls()
  lfo_step(context, S)
  assert_equal(list_sends(context, 1), 0, "none at the step after")
end)

test("seven voices given an eight-key chord in one step send at most 7 x 9 list messages, counted, and none the next", function()
  local context, S = started()
  local NUM_VOICES, ARP = S.constants.NUM_VOICES, S.lib.arp.ARP
  for voice = 1, NUM_VOICES do
    if not S.voices[voice].active then toggle_voice(voice) end
    params:set("v" .. voice .. "_arp", mode("up"))
  end
  lfo_step(context, S)
  context.clear_engine_calls()
  for voice = 1, NUM_VOICES do
    for key = 0, ARP.max_steps - 1 do
      S.lib.notes.play(voice, {owner = "midi", key = key, pitch = 60 + key, velocity = 0.5, park = true,
        set_own = function() end})
    end
  end
  local sent = 0
  for voice = 1, NUM_VOICES do sent = sent + list_sends(context, voice) end
  assert_equal(sent, 0, "no list while the keys arrive")
  context.clear_engine_calls()
  local before = S.lib.engine_sync.budget_state().sent
  lfo_step(context, S)
  sent = 0
  for voice = 1, NUM_VOICES do sent = sent + list_sends(context, voice) end
  assert_equal(sent, NUM_VOICES * (ARP.max_steps + 1), "7 x 9 list messages")
  assert_equal(S.lib.engine_sync.budget_state().sent - before, NUM_VOICES * (ARP.max_steps + 1),
    "each counted in the budget's window")
  context.clear_engine_calls()
  before = S.lib.engine_sync.budget_state().sent
  lfo_step(context, S)
  sent = 0
  for voice = 1, NUM_VOICES do sent = sent + list_sends(context, voice) end
  assert_equal(sent, 0, "none at the next step")
  assert_equal(S.lib.engine_sync.budget_state().sent - before, 0, "nothing counted")
end)

test("a key held again at its pitch sends no list; a restarted voice's start still sends its list", function()
  local context, S = started()
  params:set("v1_arp", mode("up"))
  local function play(key, pitch)
    return S.lib.notes.play(1, {owner = "midi", key = key, pitch = pitch, velocity = 0.5, park = true,
      set_own = function() end})
  end
  play(1, 60); play(2, 64); play(3, 67)
  lfo_step(context, S)
  context.clear_engine_calls()
  play(2, 64)
  lfo_step(context, S)
  assert_equal(list_sends(context, 1), 0, "E again at its pitch: no list")
  assert_equal(count_named(context, "retrigger", 1), 1, "its accent")
  -- a start sends the list the sync holds, whatever was sent before the stop
  toggle_voice(1)
  context.clear_engine_calls()
  toggle_voice(1)
  assert_equal(list_sends(context, 1), S.lib.arp.ARP.max_steps + 1, "the start's sync sends the list")
end)

test("turning the arpeggiator on moves held notes into the list with no off or on at MIDI out; a lift sends its one off", function()
  local context, S = started()
  release_mode()
  local device = context.midi.plug(3, "synth")
  params:set("v1_out_port", 3)
  lfo_step(context, S)
  note_on(context, 1, 60); note_on(context, 1, 64); note_on(context, 1, 67)
  local function notes_sent()
    local texts = {}
    for _, data in ipairs(device.sent) do
      local msg = midi.to_msg(data)
      if msg.type == "note_on" or msg.type == "note_off" then texts[#texts + 1] = msg.type .. " " .. msg.note end
    end
    return table.concat(texts, ", ")
  end
  device.sent = {}
  params:set("v1_arp", mode("up"))
  assert_equal(#S.lib.arp.held(1), 2, "E and G in the list")
  assert_equal(notes_sent(), "", "the targets hear nothing as the notes move")
  note_off(context, 1, 64)
  assert_equal(notes_sent(), "note_off 64", "E's lift: its one off")
end)

end
