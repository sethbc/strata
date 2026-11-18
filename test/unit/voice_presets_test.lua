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


end
