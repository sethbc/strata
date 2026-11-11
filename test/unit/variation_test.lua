-- test/unit/variation_test.lua
-- Per-grain variation and scales (lib/variation.lua): the variation params
-- (reverse, pitch, pan and size jitter, interval sets, interval probability,
-- quantize, the custom intervals), their grain keys and sync, scaleNote, the
-- global scale and root (setScale), the freq quantize filter on the encoder
-- and the arc, scenes, the VOICE rows, and what randomize, mutation and the
-- faders leave.
-- Run alone: lua test/run.lua variation

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake

-- The setGrainParam values of one name sent to an engine voice since the
-- engine calls were cleared
local function sent_grain(context, engine_voice, name)
  local sent = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == engine_voice and call.args[2] == name then table.insert(sent, call.args[3]) end
  end
  return sent
end

local function last_grain(context, engine_voice, name)
  local sent = sent_grain(context, engine_voice, name)
  return sent[#sent]
end

-- The intervals last sent to an engine voice: {interval1..intervalCount}
local function sent_intervals(context, engine_voice)
  local count = last_grain(context, engine_voice, "intervalCount")
  if count == nil then return nil end
  local intervals = {}
  for index = 1, count do table.insert(intervals, last_grain(context, engine_voice, "interval" .. index)) end
  return intervals
end

local function option_index(param_id, name)
  for index, option in ipairs(params:lookup_param(param_id).options) do
    if option == name then return index end
  end
  error(param_id .. " has no option " .. name)
end

-- MIDI note number of a frequency (fractional)
local function note_of(freq) return 69 + 12 * math.log(freq / 440) / math.log(2) end
local function freq_of(note) return 440 * 2 ^ ((note - 69) / 12) end

local C_MAJOR = { [0] = true, [2] = true, [4] = true, [5] = true, [7] = true, [9] = true, [11] = true }
local function in_c_major(note) return C_MAJOR[note % 12] == true end

-- The C major tone nearest a fractional note (a tie goes down)
local function nearest_c_major(note)
  local best
  for candidate = math.floor(note) - 2, math.ceil(note) + 2 do
    if in_c_major(candidate) then
      local distance = math.abs(candidate - note)
      if best == nil or distance < best.distance - 1e-9 then best = { note = candidate, distance = distance } end
    end
  end
  return best.note
end

-- The C major tones from low to high, as an index per tone
local function c_major_step(note)
  local step = 0
  for candidate = 0, note do if in_c_major(candidate) then step = step + 1 end end
  return step
end

local VARIATION_DEFAULTS = {
  reverse = 0, pitch_jitter = 0, pan_jitter = 0, size_jitter = 0, intervals = 1, interval_prob = 100,
  quantize = 0, custom_interval_1 = -12, custom_interval_2 = 0, custom_interval_3 = 7, custom_interval_4 = 12,
  custom_interval_5 = 19,
}

test("variation params default to 3.1's sound and reach the engine", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.lib.variation ~= nil, "S.lib.variation is the module's table")
  for voice_idx = 1, S.constants.NUM_VOICES do
    for key, default in pairs(VARIATION_DEFAULTS) do
      local id = "v" .. voice_idx .. "_" .. key
      assert_equal(params:get(id), default, id .. " defaults to " .. default)
      assert_equal(S.voices[voice_idx].extras[key], default, "voice " .. voice_idx .. " stores " .. key)
    end
  end
  assert_equal(params:lookup_param("v1_intervals").options[1], "off")
  assert_equal(#params:lookup_param("v1_intervals").options, 5, "off, octaves, fifths, chord, custom")
  assert_equal(params:get("scale"), 1, "scale off"); assert_equal(params:get("root"), 1, "root C")
  -- a starting voice gets the neutral values after its source
  context.clear_engine_calls()
  toggle_voice(3)
  local expected = { reverseProb = 0, pitchJitter = 0, panJitter = 0, sizeJitter = 0, intervalProb = 1, quantize = 0,
    intervalCount = 0 }
  for name, value in pairs(expected) do
    assert_equal(last_grain(context, 2, name), value, name .. " " .. value .. " on start")
  end
  for index = 1, 8 do assert_equal(last_grain(context, 2, "interval" .. index), 0, "interval" .. index .. " 0") end
  assert_near(last_grain(context, 2, "scaleNote"), note_of(S.voices[3].params.freq), 1e-9, "scaleNote is the freq's note")
  -- the controls reach a running voice as fractions where the param is a percentage
  context.clear_engine_calls()
  params:set("v3_reverse", 50); params:set("v3_interval_prob", 25); params:set("v3_pitch_jitter", 7)
  params:set("v3_pan_jitter", 0.4); params:set("v3_size_jitter", 0.6); params:set("v3_quantize", 1)
  assert_near(last_grain(context, 2, "reverseProb"), 0.5, 1e-9)
  assert_near(last_grain(context, 2, "intervalProb"), 0.25, 1e-9)
  assert_near(last_grain(context, 2, "pitchJitter"), 7, 1e-9)
  assert_near(last_grain(context, 2, "panJitter"), 0.4, 1e-9)
  assert_near(last_grain(context, 2, "sizeJitter"), 0.6, 1e-9)
  assert_equal(last_grain(context, 2, "quantize"), 1)
  -- a stopped voice stores them and gets nothing
  context.clear_engine_calls()
  params:set("v5_reverse", 30)
  assert_equal(#context.calls_named("setGrainParam"), 0, "nothing for a stopped voice")
  assert_equal(S.voices[5].extras.reverse, 30)
end)

test("interval sets send their semitones and count", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  context.clear_engine_calls()
  params:set("v1_intervals", option_index("v1_intervals", "octaves"))
  assert_equal(table.concat(sent_intervals(context, 0), ","), "-12,0,12", "octaves")
  for index = 4, 8 do assert_equal(last_grain(context, 0, "interval" .. index), 0, "the rest 0") end
  params:set("v1_intervals", option_index("v1_intervals", "fifths"))
  assert_equal(table.concat(sent_intervals(context, 0), ","), "-12,-5,0,7,12", "fifths")
  params:set("v1_intervals", option_index("v1_intervals", "custom"))
  assert_equal(table.concat(sent_intervals(context, 0), ","), "-12,0,7,12,19", "custom: its five intervals")
  params:set("v1_custom_interval_3", -24)
  assert_equal(table.concat(sent_intervals(context, 0), ","), "-12,0,-24,12,19", "a custom interval resends")
  params:set("v1_intervals", 1)
  assert_equal(last_grain(context, 0, "intervalCount"), 0, "off -> intervalCount 0")
  -- a custom interval with another set chosen sends nothing new
  context.clear_engine_calls()
  params:set("v1_custom_interval_1", 5)
  assert_equal(#sent_grain(context, 0, "intervalCount"), 0, "not custom: no resend")
  -- the sync sends the set
  params:set("v4_intervals", option_index("v4_intervals", "octaves"))
  context.clear_engine_calls()
  toggle_voice(4)
  assert_equal(table.concat(sent_intervals(context, 3), ","), "-12,0,12", "sent when the voice starts")
end)

test("chord follows the scale's degrees", function()
  local context = load_strata()
  finish_startup(context)
  context.clear_engine_calls()
  params:set("v1_intervals", option_index("v1_intervals", "chord"))
  assert_equal(table.concat(sent_intervals(context, 0), ","), "0,4,7,11", "scale off: 0, 4, 7, 11")
  params:set("scale", option_index("scale", "Natural Minor"))
  assert_equal(table.concat(sent_intervals(context, 0), ","), "0,3,7,10", "minor: 0, 3, 7, 10")
  params:set("scale", option_index("scale", "Major"))
  assert_equal(table.concat(sent_intervals(context, 0), ","), "0,4,7,11", "major")
  params:set("scale", option_index("scale", "Major Pentatonic"))
  assert_equal(table.concat(sent_intervals(context, 0), ","), "0,4,9,14", "pentatonic: its 1st, 3rd, 5th and 7th")
  params:set("root", option_index("root", "D"))
  assert_equal(table.concat(sent_intervals(context, 0), ","), "0,4,9,14", "from the root: the root changes nothing")
end)

test("a quantized freq moves by scale tones on slow encoder and arc turns", function()
  local context = load_strata()
  finish_startup(context)
  params:set("scale", option_index("scale", "Major"))
  params:set("root", 1)
  params:set("v1_quantize", 1)
  params:set("v1_freq", 440)
  assert_near(params:get("v1_freq"), 440, 1e-6, "A4 is in C major")
  local low, high = param_range("v1_freq")
  local octaves = math.log(high / low) / math.log(2)
  -- one detent moves the raw value one quantum, one arc tick 1/ARC_TICKS_PER_SWEEP
  local cases = {
    { name = "E3", step = params:lookup_param("v1_freq").controlspec.quantum * 12 * octaves, turns = 30,
      turn = function(d) enc_param_delta(3, "v1_freq", d) end },
    { name = "arc", step = 12 * octaves / local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, turns = 300,
      turn = function(d) arc_sweep_param("v1_freq", d) end },
  }
  for _, case in ipairs(cases) do
    params:set("v1_freq", 300); params:set("v1_freq", 440)  -- a fresh start on A4
    local start = 69
    local travel, previous_note, first_change = 0, 69, nil
    for _, direction in ipairs({ 1, -1 }) do
      for _ = 1, case.turns do
        case.turn(direction)
        travel = travel + direction * case.step
        local freq = params:get("v1_freq")
        local note = note_of(freq)
        local rounded = math.floor(note + 0.5)
        assert_near(note, rounded, 1e-6, case.name .. ": every value is a whole note (" .. freq .. " Hz)")
        assert_true(in_c_major(rounded), case.name .. ": every value is a C major tone (note " .. rounded .. ")")
        assert_equal(rounded, nearest_c_major(start + travel),
          case.name .. ": the tone nearest the travel (" .. string.format("%.3f", start + travel) .. ")")
        assert_true(math.abs(c_major_step(rounded) - c_major_step(previous_note)) <= 1,
          case.name .. ": never skips a tone in one turn (" .. previous_note .. " -> " .. rounded .. ")")
        assert_near(local_value("S").voices[1].params.freq, freq, 1e-6, case.name .. ": stored as shown")
        if first_change == nil and rounded ~= 69 then first_change = math.abs(travel) end
        previous_note = rounded
      end
      if direction == 1 then
        assert_true(previous_note > 69 + 12, case.name .. ": a long turn up climbs past an octave (" .. previous_note .. ")")
      end
    end
    assert_true(first_change ~= nil and first_change <= 1 + case.step,
      case.name .. ": the value changes within one semitone of travel (" .. tostring(first_change) .. ")")
    assert_true(math.abs(previous_note - 69) <= 2, case.name .. ": turning back returns near the start")
  end
  -- the stored value never left the scale while turning (scaleNote too)
  assert_true(in_c_major(math.floor(local_value("S").lib.variation.scale_note(1) + 0.5)), "scaleNote on a tone")
end)

test("a set after a turn snaps the set value, not the turn's leftover", function()
  local context = load_strata()
  finish_startup(context)
  params:set("scale", option_index("scale", "Major"))
  params:set("v1_quantize", 1)
  params:set("v1_freq", 300); params:set("v1_freq", 440)
  for _ = 1, 3 do arc_sweep_param("v1_freq", 1) end
  assert_near(params:get("v1_freq"), 440, 1e-6, "three arc ticks (0.47 st) stay on A4")
  params:set("v1_freq", freq_of(64.3))
  assert_near(params:get("v1_freq"), freq_of(64), 1e-6, "note 64.3 set after the turn is E4, not F4")
  -- a turn of the largest encoder delta (5 detents) still counts as a turn
  params:set("v1_freq", 300); params:set("v1_freq", 440)
  enc_param_delta(3, "v1_freq", 1)                -- shadow 69.8: A4
  assert_near(params:get("v1_freq"), 440, 1e-6)
  enc_param_delta(3, "v1_freq", 5)                -- shadow 73.8: D5, not 73.0 + the jump's own snap
  assert_near(params:get("v1_freq"), freq_of(74), 1e-6, "a 5-detent turn keeps the shadow")
end)

test("quantize snaps freq on all seven synth voices but never index, fold or the other main params", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  params:set("scale", option_index("scale", "Major"))
  for voice_idx = 1, S.constants.NUM_VOICES do
    local prefix = "v" .. voice_idx .. "_"
    params:set(prefix .. "freq", 450)
    assert_near(params:get(prefix .. "freq"), 450, 1e-6, prefix .. "freq unsnapped while quantize is off")
    params:set(prefix .. "quantize", 1)
    assert_near(params:get(prefix .. "freq"), 440, 1e-6, prefix .. "freq snaps when quantize turns on")
    params:set(prefix .. "freq", 290)
    assert_near(params:get(prefix .. "freq"), freq_of(62), 1e-6, prefix .. "freq 290 Hz snaps to D4")
    assert_near(S.voices[voice_idx].params.freq, freq_of(62), 1e-6, "stored snapped")
    local main_key = S.constants.MAIN_PARAMS[S.voices[voice_idx].name].key
    for _, key in ipairs(S.voices[voice_idx].param_order) do
      if key ~= "freq" then
        local id = prefix .. key
        local low, high = param_range(id)
        local value = low + (high - low) * 0.37
        params:set(id, value)
        assert_near(params:get(id), params:lookup_param(id).controlspec:map(params:lookup_param(id).controlspec:unmap(value)),
          1e-9, id .. " never snaps" .. (key == main_key and " (the main param)" or ""))
      end
    end
    params:set(prefix .. "quantize", 0)
    params:set(prefix .. "freq", 450)
    assert_near(params:get(prefix .. "freq"), 450, 1e-6, prefix .. "freq free again with quantize off")
  end
end)

test("a MIDI note snaps to the scale for a quantized voice only", function()
  local context = load_strata()
  finish_startup(context)
  params:set("scale", option_index("scale", "Major"))
  params:set("v1_quantize", 1)
  context.midi.send(1, { type = "note_on", note = 61, vel = 100, ch = 1 })
  assert_near(params:get("v1_freq"), freq_of(60), 1e-6, "C#4 on a quantized voice plays C4 (a tie goes down)")
  context.midi.send(1, { type = "note_on", note = 66, vel = 100, ch = 1 })
  assert_near(params:get("v1_freq"), freq_of(65), 1e-6, "F#4 plays F4")
  context.midi.send(1, { type = "note_on", note = 64, vel = 100, ch = 1 })
  assert_near(params:get("v1_freq"), freq_of(64), 1e-6, "E4 stays E4")
  context.midi.send(1, { type = "note_on", note = 61, vel = 100, ch = 2 })
  assert_near(params:get("v2_freq"), freq_of(61), 1e-6, "an unquantized voice plays C#4")
  -- a buffer voice's rate follows the snapped note
  params:set("v3_source", 2)
  params:set("v3_quantize", 1)
  context.midi.send(1, { type = "note_on", note = 63, vel = 100, ch = 3 })
  assert_near(params:get("v3_buf_rate"), 2 ^ (2 / 12), 0.006, "D#4 on a quantized buffer voice reads at D4's rate (a 0.01 step)")
  params:set("root", option_index("root", "D#"))
  context.midi.send(1, { type = "note_on", note = 63, vel = 100, ch = 3 })
  assert_near(params:get("v3_buf_rate"), 2 ^ (3 / 12), 0.006, "in D# major, D#4 is a tone")
end)

test("scale and root are discrete scene globals that send setScale", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  context.clear_engine_calls()
  params:set("scale", option_index("scale", "Natural Minor"))
  local calls = context.calls_named("setScale")
  assert_equal(#calls, 1, "one setScale")
  -- minor: 0, 2, 3, 5, 7, 8, 10
  assert_equal(calls[1].args[1], 0); assert_equal(calls[1].args[2], 1 + 4 + 8 + 32 + 128 + 256 + 1024)
  params:set("root", option_index("root", "D"))
  calls = context.calls_named("setScale")
  assert_equal(calls[#calls].args[1], 2, "root D is 2"); assert_equal(calls[#calls].args[2], 1453)
  params:set("scale", 1)
  calls = context.calls_named("setScale")
  assert_equal(calls[#calls].args[1], 2); assert_equal(calls[#calls].args[2], 4095, "off is the chromatic mask")
  -- discrete scene fields: a fade switches them at its end
  local fields = {}
  for _, global in ipairs(S.SCENE_GLOBAL_PARAMS) do fields[global.id] = global end
  assert_true(fields.scale and not fields.scale.continuous and fields.scale.default == 1, "scale: discrete, off")
  assert_true(fields.root and not fields.root.continuous and fields.root.default == 1, "root: discrete, C")
  params:set("scale", option_index("scale", "Dorian")); params:set("root", option_index("root", "F"))
  capture_scene(1)
  assert_equal(S.scenes[1].data.scale, option_index("scale", "Dorian"))
  assert_equal(S.scenes[1].data.root, option_index("root", "F"))
  params:set("scale", 1); params:set("root", 1)
  recall_scene(1, 4); wake(context, "scene_transition_clock")
  assert_equal(params:get("scale"), 1, "midway the scale has not switched")
  context.clock.run_for(5)
  assert_equal(params:get("scale"), option_index("scale", "Dorian"), "the fade's end sets the scale")
  assert_equal(params:get("root"), option_index("root", "F"), "and the root")
  calls = context.calls_named("setScale")
  assert_equal(calls[#calls].args[1], 5, "root F is 5")
end)

test("scaleNote follows a freq change, a root change, a quantize change and a source change", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active, "voice 1 runs")
  context.clear_engine_calls()
  params:set("v1_freq", 220)
  assert_near(last_grain(context, 0, "scaleNote"), 57, 1e-9, "220 Hz is note 57")
  -- a buffer voice's reference is the root's C4 octave
  params:set("v1_source", 2)
  assert_near(last_grain(context, 0, "scaleNote"), 60, 1e-9, "a buffer voice: root C + 60")
  context.clear_engine_calls()
  params:set("root", option_index("root", "D"))
  assert_near(last_grain(context, 0, "scaleNote"), 62, 1e-9, "root D on a buffer voice -> 62")
  params:set("v1_freq", 330)
  assert_near(last_grain(context, 0, "scaleNote"), 62, 1e-9, "a buffer voice's freq leaves it")
  context.clear_engine_calls()
  params:set("v1_source", S.constants.SOURCE_INPUT)
  assert_near(last_grain(context, 0, "scaleNote"), 62, 1e-9, "an input voice: root + 60")
  context.clear_engine_calls()
  params:set("v1_quantize", 1)
  assert_true(#sent_grain(context, 0, "scaleNote") >= 1, "quantize on resends it")
  params:set("v1_source", 1)
  assert_near(last_grain(context, 0, "scaleNote"), note_of(S.voices[1].params.freq), 1e-9, "back on the synth")
  -- the root change reaches every running voice
  toggle_voice(5)
  context.clear_engine_calls()
  params:set("root", option_index("root", "E"))
  assert_equal(#sent_grain(context, 4, "scaleNote"), 1, "voice 5 gets it too")
  assert_equal(#sent_grain(context, 2, "scaleNote"), 0, "a stopped voice gets nothing")
  -- an LFO on freq moves the sent frequency, never scaleNote
  context.clear_engine_calls()
  local dest
  for index, destination in ipairs(S.LFO_DESTINATIONS) do
    if destination.label == "v1 main" then dest = index end  -- the Resonator's main param is freq
  end
  assert_true(dest ~= nil, "v1 main is an LFO destination")
  do
    local lfo = local_value("lfos")[1]
    params:set("strata_lfo1_dest", dest)
    params:set("lfo_depth_1", 100); params:set("lfo_1", 2)
    for _, phase in ipairs({ 1.0, 0.0, 1.0 }) do context.lfo.tick(lfo, phase) end
    assert_true(#context.calls_named("setVoiceParam") > 0, "the LFO moved freq")
    assert_equal(#sent_grain(context, 0, "scaleNote"), 0, "but no scaleNote")
  end
end)

test("variation fields round-trip through a scene", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  local values = {
    reverse = 40, pitch_jitter = 5.5, pan_jitter = 0.7, size_jitter = 0.3, intervals = 5, interval_prob = 60,
    quantize = 1, custom_interval_1 = -24, custom_interval_2 = -3, custom_interval_3 = 2, custom_interval_4 = 17,
    custom_interval_5 = 24,
  }
  for voice_idx = 1, S.constants.NUM_VOICES do
    for key, value in pairs(values) do params:set("v" .. voice_idx .. "_" .. key, value) end
  end
  params:set("scale", option_index("scale", "Lydian")); params:set("root", option_index("root", "G"))
  capture_scene(1)
  local captured_freq = {}
  for voice_idx = 1, S.constants.NUM_VOICES do captured_freq[voice_idx] = params:get("v" .. voice_idx .. "_freq") end
  for voice_idx = 1, S.constants.NUM_VOICES do
    for key, default in pairs(VARIATION_DEFAULTS) do params:set("v" .. voice_idx .. "_" .. key, default) end
    params:set("v" .. voice_idx .. "_freq", 123.4)
  end
  params:set("scale", 1); params:set("root", 1)
  recall_scene_instant(1)
  for voice_idx = 1, S.constants.NUM_VOICES do
    for key, value in pairs(values) do
      local id = "v" .. voice_idx .. "_" .. key
      assert_near(params:get(id), value, 1e-9, id .. " recalled")
      assert_near(S.voices[voice_idx].extras[key], value, 1e-9, id .. " stored")
    end
    assert_near(params:get("v" .. voice_idx .. "_freq"), captured_freq[voice_idx], 1e-6, "freq recalled exactly")
  end
  assert_equal(params:get("scale"), option_index("scale", "Lydian")); assert_equal(params:get("root"), option_index("root", "G"))
  -- the discrete ones are discrete, the rest crossfade
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "variation" then record = each end end
  assert_equal(record.count, 12)
  for _, key in ipairs({ "intervals", "quantize", "custom_interval_1", "custom_interval_5" }) do
    assert_true(record.discrete[key] ~= nil, key .. " is discrete")
  end
  for _, key in ipairs({ "reverse", "pitch_jitter", "pan_jitter", "size_jitter", "interval_prob" }) do
    assert_true(record.discrete[key] == nil, key .. " crossfades")
  end
  for key, default in pairs(VARIATION_DEFAULTS) do
    assert_equal(record.scene_defaults[key], default, key .. "'s migration default is 3.1's sound")
  end
  assert_true(validate_scene(S.scenes[1]), "the scene validates")
end)

test("the custom interval rows show only for the custom set, in a variation section", function()
  load_strata()
  local S = local_value("S")
  local function row_keys(voice_idx)
    local keys = {}
    for _, row in ipairs(voice_page_rows(voice_idx)) do
      if row.section == "variation" and row.param_id then table.insert(keys, (row.param_id:gsub("^v%d+_", ""))) end
    end
    return table.concat(keys, " ")
  end
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, source in ipairs({ S.constants.SOURCE_SYNTH, 2, S.constants.SOURCE_INPUT }) do
      params:set("v" .. voice_idx .. "_source", source)
      params:set("v" .. voice_idx .. "_intervals", 1)
      assert_equal(row_keys(voice_idx), "reverse pitch_jitter pan_jitter size_jitter intervals interval_prob quantize",
        "voice " .. voice_idx .. " without custom")
      params:set("v" .. voice_idx .. "_intervals", 5)
      assert_equal(row_keys(voice_idx), "reverse pitch_jitter pan_jitter size_jitter intervals interval_prob "
        .. "custom_interval_1 custom_interval_2 custom_interval_3 custom_interval_4 custom_interval_5 quantize",
        "voice " .. voice_idx .. " with custom")
    end
  end
  -- the record's layout states draw every voice with the custom rows
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "variation" then record = each end end
  assert_true(#record.layout_states >= S.constants.NUM_VOICES, "a layout state per voice")
end)

test("the variation rows lay out on VOICE", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "variation" then record = each end end
  h.show_page("VOICE")
  for _, state in ipairs(record.layout_states) do
    state.setup(context)
    for _, alt in ipairs({ 0, 1 }) do
      key(1, alt); redraw()
      h.assert_screen_layout(context, "VOICE " .. state.name .. (alt == 1 and " with ALT" or ""))
    end
    key(1, 0)
  end
end)

test("randomize, mutation and the faders leave variation alone", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  local values = { reverse = 12, pitch_jitter = 3, pan_jitter = 0.25, size_jitter = 0.5, intervals = 3,
    interval_prob = 70, custom_interval_2 = 5 }
  for voice_idx = 1, S.constants.NUM_VOICES do
    for key, value in pairs(values) do params:set("v" .. voice_idx .. "_" .. key, value) end
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(11)
  for voice_idx = 1, S.constants.NUM_VOICES do randomize_voice(voice_idx) end
  for _ = 1, 20 do gentle_mutate() end
  for _ = 1, 20 do drift_update() end
  for voice_idx = 1, S.constants.NUM_VOICES do
    for key, value in pairs(values) do
      assert_near(params:get("v" .. voice_idx .. "_" .. key), value, 1e-9, "voice " .. voice_idx .. " " .. key .. " untouched")
    end
    for _, param_id in ipairs(fader_param_ids(voice_idx)) do
      for key in pairs(VARIATION_DEFAULTS) do
        assert_true(param_id ~= "v" .. voice_idx .. "_" .. key, param_id .. " is not a variation param")
      end
    end
  end
  assert_equal(params:get("scale"), 1); assert_equal(params:get("root"), 1)
end)


-- norns reads a PSET in file order, which is the params' order: a voice's
-- quantize must come before its freq, or the filter of the quantize still
-- in force would snap (or leave) the PSET's pitch (#125)
test("a PSET whose quantize differs from the current value loads the voice's exact stored pitch", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  local pset_path = context.data_dir .. "strata-02.pset"
  if not S.voices[1].active then toggle_voice(1) end
  assert_true(S.voices[1].active, "voice 1 runs")
  -- saved: quantize off and a pitch between tones on every voice
  for voice_idx = 1, S.constants.NUM_VOICES do params:set("v" .. voice_idx .. "_freq", 450) end
  params:write(pset_path)
  -- now: C major, quantize on (every freq snapped to A4)
  params:set("scale", option_index("scale", "Major"))
  for voice_idx = 1, S.constants.NUM_VOICES do params:set("v" .. voice_idx .. "_quantize", 1) end
  params:set("scale", 1)
  context.clear_engine_calls()
  params:read(pset_path)
  for voice_idx = 1, S.constants.NUM_VOICES do
    local prefix = "v" .. voice_idx .. "_"
    assert_equal(params:get(prefix .. "quantize"), 0, prefix .. "quantize off, as saved")
    assert_near(params:get(prefix .. "freq"), 450, 1e-9, prefix .. "freq 450 Hz, as saved (quantize on before)")
    assert_near(S.voices[voice_idx].params.freq, 450, 1e-9, prefix .. "freq stored as saved")
  end
  local sent = {}
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 0 and call.args[2] == "freq" then table.insert(sent, call.args[3]) end
  end
  assert_near(sent[#sent], 450, 1e-9, "the running voice plays the saved pitch")

  -- saved: D major, quantize on, freq on a D major tone (C#5, not in C major)
  params:set("scale", option_index("scale", "Major")); params:set("root", 3)
  for voice_idx = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice_idx .. "_quantize", 1); params:set("v" .. voice_idx .. "_freq", freq_of(73))
  end
  params:write(pset_path)
  -- now: C major, quantize off, a pitch between tones
  params:set("root", 1)
  for voice_idx = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice_idx .. "_quantize", 0); params:set("v" .. voice_idx .. "_freq", 450)
  end
  params:read(pset_path)
  for voice_idx = 1, S.constants.NUM_VOICES do
    local prefix = "v" .. voice_idx .. "_"
    assert_equal(params:get(prefix .. "quantize"), 1, prefix .. "quantize on, as saved")
    assert_near(params:get(prefix .. "freq"), freq_of(73), 1e-9, prefix .. "freq C#5, as saved (quantize off before)")
  end
  assert_near(last_grain(context, 0, "scaleNote"), 73, 1e-9, "scaleNote follows the saved pitch")
end)


-- A scale or root change moves a quantized voice's stored freq onto the
-- new scale, so a PSET saved after it holds a tone and loads exactly
test("a scale or root change re-snaps a quantized freq, and a PSET saved after it loads exactly", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  params:set("scale", option_index("scale", "Major"))
  params:set("v1_quantize", 1); params:set("v2_quantize", 0)
  params:set("v1_freq", freq_of(64)); params:set("v2_freq", freq_of(64))       -- E4
  params:set("scale", option_index("scale", "Natural Minor"))
  assert_near(params:get("v1_freq"), freq_of(63), 1e-9, "E4 snaps to Eb4 in C minor (a tie goes down)")
  assert_near(S.voices[1].params.freq, freq_of(63), 1e-9, "stored snapped")
  assert_near(params:get("v2_freq"), freq_of(64), 1e-9, "a voice without quantize keeps E4")
  local pset_path = context.data_dir .. "strata-03.pset"
  params:write(pset_path)
  params:set("v1_freq", freq_of(67))                                            -- G4
  params:read(pset_path)
  assert_near(params:get("v1_freq"), freq_of(63), 1e-9, "the PSET loads its saved Eb4")
  -- a root change too: C minor to D minor moves Eb4 to D4 (a tie goes down)
  params:set("root", 3)
  assert_near(params:get("v1_freq"), freq_of(62), 1e-9, "Eb4 snaps to D4 in D minor")
  -- a scene recall's and a transition's values stand as saved (D4 is in
  -- neither C# minor nor C# major)
  S.scene_recall_in_progress = true
  params:set("root", 2)
  S.scene_recall_in_progress = false
  assert_near(params:get("v1_freq"), freq_of(62), 1e-9, "no re-snap during a scene recall")
  S.scene_transition_active = true
  params:set("scale", option_index("scale", "Major"))
  S.scene_transition_active = false
  assert_near(params:get("v1_freq"), freq_of(62), 1e-9, "nor during a scene transition")
end)

end
