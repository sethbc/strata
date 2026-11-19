-- test/unit/voice_presets_test.lua
-- Voice presets (lib/voice_presets.lua, S.lib.voice_presets, 3.8 design
-- §8): the filter (VOICE_PRESETS.keys), the library in voices.data, and a
-- load, a copy and a save, which take a voice's sound and keep its place
-- Run alone: lua test/run.lua voice_presets

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake
local file_text, write_text = h.file_text, h.write_text

local function loaded(options)
  local context = load_strata(options); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.voice_presets
end

-- A fresh data folder of its own, its strata/ folder made
local function fresh_subdir(name)
  local subdir = "voice-presets-" .. name .. "-" .. math.random(1, 1e9)
  local dir = h.data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  return subdir, dir
end

local function lines_naming(context, text)
  local said = {}
  for _, line in ipairs(context.printed) do
    if line:find(text, 1, true) then said[#said + 1] = line end
  end
  return said
end

local function source_option(S, name)
  for option, option_name in ipairs(S.constants.SOURCE_OPTIONS) do
    if option_name == name then return option end
  end
  error("no source " .. name)
end

test("every voice scene key is in or out", function()
  local _, S, presets = loaded()
  local keys = presets.VOICE_PRESETS.keys
  local unnamed, named = {}, {}
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, record in ipairs(S.lib.types.list()) do
      for _, entry in ipairs((S.lib.params_setup.voice_scene_keys(voice_idx, record.key))) do
        if entry.synth then
          assert_true(record.specs[entry.key] ~= nil, entry.key .. " is a synth key of " .. record.key)
        else
          named[entry.key] = true
          if keys[entry.key] == nil then unnamed[entry.key] = true end
        end
      end
    end
  end
  local missing = {}
  for key in pairs(unnamed) do missing[#missing + 1] = key end
  table.sort(missing)
  assert_equal(table.concat(missing, " "), "", "every shared voice scene key is in or out")
  local stale = {}
  for key, value in pairs(keys) do
    assert_true(value == true or value == false, key .. " is true or false")
    if not named[key] then stale[#stale + 1] = key end
  end
  table.sort(stale)
  assert_equal(table.concat(stale, " "), "", "every key the table names is some voice's scene key")
  local ins, outs = 0, 0
  for _, value in pairs(keys) do if value then ins = ins + 1 else outs = outs + 1 end end
  assert_equal(ins, 39, "thirty-nine keys in")
  assert_equal(outs, 39, "thirty-nine keys out")
  for _, key in ipairs({ "mod_speed", "input_channel", "buf_pos", "mute", "seq_length" }) do
    assert_equal(keys[key], false, key .. " is out")
  end
  for _, key in ipairs({ "reverse", "env_attack", "env_loop", "arp", "dry", "grain_shape", "pan_wander" }) do
    assert_equal(keys[key], true, key .. " is in")
  end
end)

test("a save writes voices.data and a start reads it back", function()
  local subdir, dir = fresh_subdir("save")
  local _, S, presets = loaded({ data_subdir = subdir })
  assert_equal(S.voices[2].name, "fm", "voice 2 starts on fm")
  local saved = presets.save(2, 5, "glass pad")
  assert_true(saved, "the save is made")
  assert_true(util.file_exists(dir .. "voices.data"), "voices.data is written")
  local _, _, again = loaded({ data_subdir = subdir })
  local preset = again.preset(5)
  assert_equal(preset and preset.name, "glass pad", "the name is read back")
  assert_equal(preset and preset.type, "fm", "the type is read back")
  assert_equal(again.preset(4), nil, "an empty slot stays empty")
end)

test("a name keeps printable ASCII, cut to twelve", function()
  local _, S, presets = loaded()
  assert_equal(presets.VOICE_PRESETS.name_max, S.constants.SCENE_NAME_MAX, "a scene name's length")
  assert_true(presets.save(1, 1, "a\tbcdefghijklmnop"), "saved")
  assert_equal(presets.preset(1).name, ("abcdefghijklmnop"):sub(1, S.constants.SCENE_NAME_MAX), "printable, cut")
  assert_true(not presets.save(1, 0, "x"), "slot 0 is no slot")
  assert_true(not presets.save(1, presets.VOICE_PRESETS.slots + 1, "x"), "past the last slot")
  assert_true(not presets.save(0, 1, "x"), "voice 0 is no voice")
end)

test("an unusable voices.data is set aside, never written over", function()
  local subdir, dir = fresh_subdir("garbage")
  write_text(dir .. "voices.data", "garbage")
  local context, _, presets = loaded({ data_subdir = subdir })
  assert_equal(file_text(dir .. "voices.data.bak"), "garbage", "set aside whole")
  assert_equal(#lines_naming(context, "voices.data"), 1, "one console line")
  for slot = 1, presets.VOICE_PRESETS.slots do assert_equal(presets.preset(slot), nil, "slot " .. slot .. " is empty") end
  assert_true(presets.save(3, 2, "fresh"), "a save writes a fresh file")
  assert_true(file_text(dir .. "voices.data") ~= "garbage", "the fresh file")

  -- every backup name taken: the file stays, and a save refuses with a flash
  local blocked_subdir, blocked_dir = fresh_subdir("blocked")
  write_text(blocked_dir .. "voices.data", "garbage")
  write_text(blocked_dir .. "voices.data.bak", "old")
  for number = 2, 9 do write_text(blocked_dir .. "voices.data.bak." .. number, "old") end
  local blocked_context, S, blocked = loaded({ data_subdir = blocked_subdir })
  assert_equal(#lines_naming(blocked_context, "voices.data"), 1, "one console line")
  local saved, why = blocked.save(3, 2, "fresh")
  assert_true(not saved, "the save is refused")
  assert_true(type(why) == "string", "with why")
  assert_true(S.lib.ui_flash.slots.hints.text ~= nil, "a flash shows")
  assert_equal(file_text(blocked_dir .. "voices.data"), "garbage", "never written over")
  assert_equal(blocked.preset(2), nil, "nothing saved")
end)


-- Save voice from_voice's sound into slot, then rewrite the stored preset
-- through edit(stored) and start again on the same data: the new load's
-- context, S and module
local function saved_and_edited(name, from_voice, slot, edit)
  local subdir, dir = fresh_subdir(name)
  local _, S, presets = loaded({ data_subdir = subdir })
  assert_true(presets.save(from_voice, slot, name), "saved")
  local value = S.lib.data_files.read(dir .. "voices.data")
  edit(value.presets[slot])
  assert_true(S.lib.data_files.write(dir .. "voices.data", value), "rewritten")
  return loaded({ data_subdir = subdir })
end

test("a load takes the sound and keeps the place", function()
  local context, S, presets = loaded()
  params:set("v2_grain_size", 0.2); params:set("v2_delay_send", 0.4)
  assert_true(presets.save(2, 1, "fm one"), "an fm preset")
  params:set("v1_source", source_option(S, "buf 1"))
  params:set("v1_buf_pos", 0.3); params:set("v1_seq_length", 5); params:set("v1_mute", 1)
  assert_true(S.voices[1].active, "voice 1 runs")
  assert_true(presets.load(1, 1), "loaded")
  local values = S.voices[1].values
  assert_equal(S.voices[1].name, "fm", "the preset's type")
  assert_near(values.grain_size, 0.2, 1e-9, "the preset's grain size")
  assert_near(values.delay_send, 0.4, 1e-9, "the preset's delay send")
  assert_equal(S.voices[1].source, source_option(S, "buf 1"), "the source kept")
  assert_true(S.voices[1].active, "still running")
  assert_near(values.buf_pos, 0.3, 1e-9, "the buffer position kept")
  assert_equal(values.seq_length, 5, "the pattern's length kept")
  assert_equal(values.mute, 1, "the mute kept")
  assert_equal(presets.loaded_name(1), "fm one", "the row's name")
  assert_true(not presets.load(1, 2), "an empty slot loads nothing")
  assert_equal(#lines_naming(context, "apply_voice"), 0, "no refused apply")
end)

test("a synth key the preset lacks keeps the voice's remembered value", function()
  local _, S, presets = saved_and_edited("lacks", 2, 3, function(stored) stored.values.ratio = nil end)
  params:set("v1_type", S.lib.types.record("fm").index)
  local spec = params:lookup_param("v1_ratio").controlspec
  local edited = spec:map(0.77)
  params:set("v1_ratio", edited)
  edited = params:get("v1_ratio")
  params:set("v1_type", S.lib.types.record("resonator").index)
  assert_true(presets.load(1, 3), "loaded")
  assert_equal(S.voices[1].name, "fm", "the preset's type")
  assert_equal(params:get("v1_ratio"), edited, "the voice's remembered ratio")
end)

test("a key this build lacks is dropped", function()
  local context, S, presets = saved_and_edited("future", 2, 4, function(stored) stored.values.future_key = 1 end)
  assert_true(presets.load(5, 4), "loaded")
  assert_equal(S.voices[5].name, "fm", "the preset's type")
  assert_equal(S.voices[5].values.future_key, nil, "the unknown key is not set")
  assert_equal(#lines_naming(context, "apply_voice"), 0, "no refused apply")
end)

test("a preset of a type this build lacks loads nothing", function()
  local context, S, presets = saved_and_edited("nope", 2, 6, function(stored) stored.type = "nope" end)
  assert_equal(presets.preset(6).type, "nope", "kept in the library")
  local before = h.deep_copy(S.voices[1].values)
  local name = S.voices[1].name
  local printed = #context.printed
  assert_true(not presets.load(1, 6), "nothing loaded")
  assert_equal(#context.printed - printed, 1, "one console line")
  assert_true(S.lib.ui_flash.slots.hints.text ~= nil, "a flash")
  assert_equal(S.voices[1].name, name, "the type unchanged")
  for key, value in pairs(before) do assert_equal(S.voices[1].values[key], value, key .. " unchanged") end
end)

test("copy is a load of the other voice's filtered capture", function()
  local _, S, presets = loaded()
  params:set("v3_grain_size", 0.31); params:set("v3_filter_freq", 1234); params:set("v3_reverb_send", 0.6)
  params:set("v6_seq_length", 7); params:set("v6_buf_pos", 0.6); params:set("v6_mod_speed", 3)
  local out_before = {}
  for key, value in pairs(S.voices[6].values) do
    if presets.VOICE_PRESETS.keys[key] == false then out_before[key] = value end
  end
  local source_before = h.deep_copy(S.lib.scenes.capture_voice(3))
  assert_true(presets.copy(3, 6), "copied")
  assert_equal(S.voices[6].name, S.voices[3].name, "voice 3's type")
  local source_after = S.lib.scenes.capture_voice(3)
  assert_equal(source_after.type, source_before.type, "the source voice keeps its type")
  assert_equal(source_after.active, source_before.active, "and its running state")
  for key, value in pairs(source_before.values) do
    assert_equal(source_after.values[key], value, "the source voice's " .. key .. " unchanged")
  end
  local sound = presets.capture(3)
  -- a control param set again moves by its controlspec's round trip (an ulp)
  for key, value in pairs(sound.values) do
    assert_near(S.voices[6].values[key], value, 1e-9 * math.max(1, math.abs(value)), key .. " is voice 3's")
  end
  for key, value in pairs(out_before) do assert_equal(S.voices[6].values[key], value, key .. " kept") end
  assert_equal(presets.loaded_name(6), presets.VOICE_PRESETS.copy_prefix .. 3, "the row shows v3")
  assert_true(not presets.copy(6, 6), "a voice is not copied into itself")
  assert_true(not presets.copy(0, 6), "no voice 0")
end)

test("a locked voice can be loaded into", function()
  local _, S, presets = loaded()
  assert_true(presets.save(2, 1, "fm"), "saved")
  toggle_lock(4)
  assert_true(S.locked[4], "locked")
  assert_true(presets.load(4, 1), "loaded")
  assert_equal(S.voices[4].name, "fm", "the preset's type")
  assert_true(S.locked[4], "still locked")
end)

test("a load during a fade lets go of the voice", function()
  local context, S, presets = loaded()
  for voice_idx = 1, S.constants.NUM_VOICES do params:set("v" .. voice_idx .. "_grain_size", 0.1) end
  capture_scene(1)
  for voice_idx = 1, S.constants.NUM_VOICES do params:set("v" .. voice_idx .. "_grain_size", 0.4) end
  capture_scene(2)
  params:set("v5_grain_size", 0.27)
  assert_true(presets.save(5, 1, "five"), "a preset of voice 5")
  recall_scene(1, 0)
  recall_scene(2, 2)  -- 20 steps of 0.1 s; the first runs at once
  for _ = 1, 4 do wake(context, "scene_transition_clock") end
  assert_true(S.scene_transition_active, "the fade runs")
  assert_true(presets.load(3, 1), "loaded at step 5")
  assert_true(S.SCENE_TRANSITION.released[3], "voice 3 let go")
  context.clock.run_for(3)
  assert_true(not S.scene_transition_active, "the fade ended")
  assert_equal(S.current_scene, 2, "scene 2 current")
  assert_near(S.voices[3].values.grain_size, 0.27, 1e-9, "voice 3 holds the preset")
  assert_equal(S.voices[3].name, S.voices[5].name, "and its type")
  for voice_idx = 1, S.constants.NUM_VOICES do
    if voice_idx ~= 3 and voice_idx ~= 5 then
      assert_near(S.voices[voice_idx].values.grain_size, 0.4, 1e-9, "voice " .. voice_idx .. " holds scene 2")
    end
  end
end)

test("a load into a buffer voice keeps the buffer and takes the type for later", function()
  local context, S, presets = loaded()
  params:set("v2_ratio", params:lookup_param("v2_ratio").controlspec:map(0.66))
  local ratio = params:get("v2_ratio")
  assert_true(presets.save(2, 1, "fm"), "an fm preset")
  local buffer = source_option(S, "buf 1")
  params:set("v1_source", buffer)
  context.clear_engine_calls()
  assert_true(presets.load(1, 1), "loaded")
  assert_equal(S.voices[1].source, buffer, "the buffer kept")
  assert_equal(params:get("v1_type"), S.lib.types.record("fm").index, "v1_type is fm")
  -- the merged senders reach the engine by type, not by source (0d's
  -- reaches): the type change's one sync sends the running buffer voice's
  -- fm keys, which the engine records for the synth source; none of
  -- another type's keys goes out, and the grain source stays the buffer
  local fm = S.lib.types.record("fm")
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    local key = call.args[2]
    if call.args[1] == 0 and S.lib.types.record("resonator").specs[key] then
      assert_true(fm.specs[key] ~= nil, "only fm's keys are sent: " .. tostring(key))
    end
  end
  for _, call in ipairs(context.calls_named("setGrainSource")) do
    if call.args[1] == 0 then assert_equal(call.args[2], buffer - 1, "the grain source stays the buffer") end
  end
  local typed = false
  for _, call in ipairs(context.calls_named("setVoiceType")) do
    if call.args[1] == 0 then typed = call.args[2] == fm.index - 1 end
  end
  assert_true(typed, "the engine records fm for the voice")
  context.clear_engine_calls()
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  assert_equal(S.lib.types.of(1).key, "fm", "the synth source plays fm")
  local sent = nil
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 0 and call.args[2] == "ratio" then sent = call.args[3] end
  end
  assert_near(sent or -1, ratio, 1e-6, "with the preset's ratio")
end)


-- A fade from scene 1 (every grain size 0.1) to scene 2 (0.4) over 2 s, at
-- its fifth step
local function fade_at_step_five(context, S)
  for voice_idx = 1, S.constants.NUM_VOICES do params:set("v" .. voice_idx .. "_grain_size", 0.1) end
  capture_scene(1)
  for voice_idx = 1, S.constants.NUM_VOICES do params:set("v" .. voice_idx .. "_grain_size", 0.4) end
  capture_scene(2)
  recall_scene(1, 0)
  recall_scene(2, 2)
  for _ = 1, 4 do wake(context, "scene_transition_clock") end
  assert_true(S.scene_transition_active, "the fade runs")
end

test("a refused load during a fade does not let go of the voice", function()
  local context, S, presets = saved_and_edited("refused", 2, 1, function(stored) stored.values.filter_type = 99 end)
  fade_at_step_five(context, S)
  assert_true(not presets.load(3, 1), "a preset whose filter type is out of range is refused")
  assert_true(not S.SCENE_TRANSITION.released[3], "voice 3 is not let go of")
  context.clock.run_for(3)
  assert_true(not S.scene_transition_active, "the fade ended")
  assert_near(S.voices[3].values.grain_size, 0.4, 1e-9, "voice 3 holds scene 2")
end)

test("a refused copy during a fade does not let go of the voice", function()
  local context, S, presets = loaded()
  fade_at_step_five(context, S)
  local apply_voice = S.lib.scenes.apply_voice
  S.lib.scenes.apply_voice = function() return false end  -- an apply the scenes refuse
  local copied = presets.copy(2, 3)
  S.lib.scenes.apply_voice = apply_voice
  assert_true(not copied, "the copy is refused")
  assert_true(not S.SCENE_TRANSITION.released[3], "voice 3 is not let go of")
  context.clock.run_for(3)
  assert_near(S.voices[3].values.grain_size, 0.4, 1e-9, "voice 3 holds scene 2")
end)

test("a write that drops a damaged preset keeps the file as read", function()
  local subdir, dir = fresh_subdir("damaged")
  local _, S0, first = loaded({ data_subdir = subdir })
  assert_true(first.save(2, 1, "good"), "a good preset")
  assert_true(first.save(3, 2, "bad"), "one to damage")
  local value = S0.lib.data_files.read(dir .. "voices.data")
  value.presets[2].name = 7  -- no name: left out at the start
  assert_true(S0.lib.data_files.write(dir .. "voices.data", value), "damaged")
  local as_read = file_text(dir .. "voices.data")
  local context, S, presets = loaded({ data_subdir = subdir })
  assert_equal(#lines_naming(context, "voices.data"), 1, "one console line for the damaged preset")
  assert_equal(presets.preset(2), nil, "the damaged preset left out")
  assert_true(presets.save(4, 3, "third"), "a save into another slot")
  assert_equal(file_text(dir .. "voices.data.bak"), as_read, "the file as read is kept")
  local written = S.lib.data_files.read(dir .. "voices.data")
  local slots = {}
  for slot in pairs(written.presets) do slots[#slots + 1] = slot end
  table.sort(slots)
  assert_equal(table.concat(slots, " "), "1 3", "voices.data holds the two good presets")
  assert_true(presets.save(5, 4, "fourth"), "a later save")
  assert_true(not util.file_exists(dir .. "voices.data.bak.2"), "keeps no second backup")
end)

test("a write that would drop a damaged preset, with no backup name free, is refused", function()
  local subdir, dir = fresh_subdir("damaged-blocked")
  local _, S0, first = loaded({ data_subdir = subdir })
  assert_true(first.save(2, 1, "good"), "a good preset")
  assert_true(first.save(3, 2, "bad"), "one to damage")
  local value = S0.lib.data_files.read(dir .. "voices.data")
  value.presets[2].name = 7
  assert_true(S0.lib.data_files.write(dir .. "voices.data", value), "damaged")
  local as_read = file_text(dir .. "voices.data")
  write_text(dir .. "voices.data.bak", "old")
  for number = 2, 9 do write_text(dir .. "voices.data.bak." .. number, "old") end
  local _, S, presets = loaded({ data_subdir = subdir })
  local saved, why = presets.save(4, 3, "third")
  assert_true(not saved, "the save is refused")
  assert_true(type(why) == "string", "with why")
  assert_true(S.lib.ui_flash.slots.hints.text ~= nil, "a flash shows")
  assert_equal(file_text(dir .. "voices.data"), as_read, "the file is as it was")
  assert_equal(presets.preset(3), nil, "nothing saved")
end)

-- #848: the file as read is set aside only for a write that lands; a
-- write that fails leaves voices.data as it was, and the next write keeps
-- the backup then
test("a failed write that would drop a damaged preset leaves voices.data as read", function()
  local subdir, dir = fresh_subdir("damaged-write-fails")
  local _, S0, first = loaded({ data_subdir = subdir })
  assert_true(first.save(2, 1, "good"), "a good preset")
  assert_true(first.save(3, 2, "bad"), "one to damage")
  local value = S0.lib.data_files.read(dir .. "voices.data")
  value.presets[2].name = 7
  assert_true(S0.lib.data_files.write(dir .. "voices.data", value), "damaged")
  local as_read = file_text(dir .. "voices.data")
  local _, S, presets = loaded({ data_subdir = subdir })
  os.execute("mkdir -p '" .. dir .. "voices.data.part/inside'")  -- the .part is a folder: the write fails
  local saved, why = presets.save(4, 3, "third")
  assert_true(not saved, "the save is refused")
  assert_true(type(why) == "string", "with why")
  assert_equal(file_text(dir .. "voices.data"), as_read, "voices.data is as it was")
  assert_true(not util.file_exists(dir .. "voices.data.bak"), "no backup is left for a write that failed")
  assert_equal(presets.preset(3), nil, "nothing saved")
  h.remove_tree(dir .. "voices.data.part")
  assert_true(presets.save(4, 3, "third"), "the next save writes")
  assert_equal(file_text(dir .. "voices.data.bak"), as_read, "and keeps the file as read")
  assert_equal(S.lib.data_files.read(dir .. "voices.data").presets[3].name, "third", "the new preset written")
end)

end
