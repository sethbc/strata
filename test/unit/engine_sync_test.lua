-- test/unit/engine_sync_test.lua
-- Engine sync: starting a voice sends its full state, grain values, source
-- switches (lib/engine_sync.lua)
-- Run alone: lua test/run.lua engine_sync

return function(h)
local test, engine_sources, assert_true, assert_equal = h.test, h.engine_sources, h.assert_true, h.assert_equal
local assert_near, load_strata, local_value = h.assert_near, h.load_strata, h.local_value
local finish_startup, wake, scramble_state = h.finish_startup, h.wake, h.scramble_state
local engine_state_for_voice = h.engine_state_for_voice

test("starting a voice sends its complete state to the engine (C1, C2)", function()
  local context = load_strata()
  finish_startup(context)
  local voices = local_value("voices")
  -- turn everything off, then edit every voice while it is off
  for voice_idx = 1, 7 do
    if voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  params:set("master_density", 1.5)
  context.clear_engine_calls()
  scramble_state(42)
  for _, call in ipairs(context.engine_calls) do
    -- the source is always sent (the engine only records it for a stopped voice)
    assert_equal(call.name, "setGrainSource", "edits to stopped voices are not sent")
  end

  for voice_idx = 1, 7 do
    context.clear_engine_calls()
    toggle_voice(voice_idx)
    local voice = voices[voice_idx]
    local sent = engine_state_for_voice(context.engine_calls, voice_idx - 1)
    assert_true(sent.voice_on ~= nil, "voiceOn sent for voice " .. voice_idx)
    assert_equal(sent.voice_on[2], voice.values.freq, "voiceOn freq (number) for voice " .. voice_idx)
    for _, key in ipairs(voice.param_order) do
      assert_equal(sent.voice[key], voice.values[key], "voice " .. voice_idx .. " setVoiceParam " .. key)
    end
    assert_equal(sent.grain.grainSize, voice.values.grain_size, "voice " .. voice_idx .. " grainSize")
    assert_near(sent.grain.grainDensity, voice.values.grain_density * 1.5, 1e-9, "voice " .. voice_idx .. " grainDensity")
    assert_equal(sent.grain.pitchShift, voice.values.grain_pitch, "voice " .. voice_idx .. " pitchShift")
    assert_equal(sent.grain.posSpread, voice.values.grain_spread, "voice " .. voice_idx .. " posSpread")
    assert_near(sent.grain.windowShape, voice.values.grain_shape, 1e-9, "voice " .. voice_idx .. " windowShape")
    assert_equal(sent.grain.grainMode, voice.values.grain_mode - 1, "voice " .. voice_idx .. " grainMode")
    assert_equal(sent.grain.bufPos, voice.values.buf_pos, "voice " .. voice_idx .. " bufPos")
    assert_equal(sent.grain.bufRate, voice.values.buf_rate, "voice " .. voice_idx .. " bufRate")
    assert_equal(sent.grain.bufScan, voice.values.buf_scan, "voice " .. voice_idx .. " bufScan")
    -- the source goes first, before voiceOn and any other voice state (#325)
    assert_equal(context.engine_calls[1].name, "setGrainSource", "voice " .. voice_idx .. " source synced first")
    assert_equal(context.engine_calls[1].args[2], voice.source - 1, "voice " .. voice_idx .. " source")
    for slot = 1, 3 do
      local slot_state = {source = voice.values["mod_source_" .. slot], amp_amt = voice.values["mod_amp_amt_" .. slot],
        freq_amt = voice.values["mod_freq_amt_" .. slot]}
      local expected_source = slot_state.source == 0 and -1 or slot_state.source - 1
      assert_equal(sent.source[slot], expected_source, "voice " .. voice_idx .. " slot " .. slot .. " source")
      assert_equal(sent.amp_amt[slot], slot_state.amp_amt, "voice " .. voice_idx .. " slot " .. slot .. " amp")
      assert_equal(sent.freq_amt[slot], slot_state.freq_amt, "voice " .. voice_idx .. " slot " .. slot .. " freq")
    end
    assert_equal(sent.speed, voice.values.mod_speed, "voice " .. voice_idx .. " mod speed")
  end
end)

test("voiceOn's grain density is the voice's density times master density as the engine has them", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  if voices[5].active then toggle_voice(5) end
  params:set("v5_grain_density", 20); params:set("master_density", 1.5)
  -- as LFOs on both params would have left them
  local sent_values = local_value("engine_param_values")
  sent_values.master_density = 0.5; sent_values.v5_grain_density = 30
  context.clear_engine_calls(); toggle_voice(5)
  -- a start sends the voice's stored density (its LFO re-applies its own on
  -- its next step) times the master density the engine has: 20 x 0.5, the
  -- grainDensity sent just before voiceOn (#325)
  assert_near(context.calls_named("voiceOn")[1].args[6], 10, 1e-9, "voiceOn grainDensity")
end)

-- The engine keeps a stopped voice's grain values and builds (or re-gates)
-- its grain synth with them inside voiceOn's own bundle. Sent after voiceOn
-- they arrived a moment late, so the first grain played the last run's
-- position, loop, envelope or mode (#325). voiceOn resets the voice-level
-- values (bend, crossmod), so those follow it
-- 3.8 (package 0d): the voice's type goes right after its source, so the
-- engine builds the start's voice synth of the type
test("a start sends setVoiceType after setGrainSource and before voiceOn", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  if S.voices[2].active then toggle_voice(2) end
  params:set("v2_type", S.lib.types.record("ring").index)
  context.clear_engine_calls()
  toggle_voice(2)
  local at = {}
  for index, call in ipairs(context.engine_calls) do at[call.name] = at[call.name] or index end
  assert_equal(at.setVoiceType, at.setGrainSource + 1, "the type right after the source")
  assert_true(at.setVoiceType < at.voiceOn, "and before voiceOn")
  local call = context.engine_calls[at.setVoiceType]
  assert_equal(call.args[1] .. " " .. call.args[2], "1 " .. (S.lib.types.record("ring").index - 1), "voice 1 on ring")
  assert_equal(#context.calls_named("setVoiceType"), 1, "once")
end)

test("a start sends the source and every grain value before voiceOn, the voice-level values after", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  for voice_idx = 1, 7 do
    if voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  scramble_state(42)
  for voice_idx = 1, 7 do
    context.clear_engine_calls()
    toggle_voice(voice_idx)
    local calls, voice_on = context.engine_calls, nil
    for index, call in ipairs(calls) do
      if call.name == "voiceOn" then
        assert_true(voice_on == nil, "voice " .. voice_idx .. ": one voiceOn")
        voice_on = index
      end
    end
    assert_true(voice_on ~= nil, "voice " .. voice_idx .. ": voiceOn sent")
    assert_equal(calls[1].name, "setGrainSource", "voice " .. voice_idx .. ": the source first")
    -- 3.8 (0d): then the type, before every grain value and voiceOn
    assert_equal(calls[2].name, "setVoiceType", "voice " .. voice_idx .. ": the type right after the source")
    assert_equal(calls[2].args[1] .. " " .. calls[2].args[2],
      (voice_idx - 1) .. " " .. (local_value("S").lib.types.of(voice_idx).index - 1), "voice " .. voice_idx .. "'s type")
    local before = {}
    for index = 3, voice_on - 1 do
      assert_equal(calls[index].name, "setGrainParam", "voice " .. voice_idx .. ": only grain values before voiceOn")
      before[calls[index].args[2]] = calls[index].args[3]
    end
    for index = voice_on + 1, #calls do
      assert_true(calls[index].name ~= "setGrainParam" and calls[index].name ~= "setGrainSource",
        "voice " .. voice_idx .. ": no grain value after voiceOn (" .. calls[index].name .. " "
        .. tostring(calls[index].args[2]) .. ")")
    end
    -- voiceOn carries the grain values just sent, so the engine's merge changes nothing
    local args = calls[voice_on].args
    assert_equal(args[5], before.grainSize, "voice " .. voice_idx .. ": voiceOn's grainSize")
    assert_equal(args[6], before.grainDensity, "voice " .. voice_idx .. ": voiceOn's grainDensity")
    assert_equal(args[7], before.pitchShift, "voice " .. voice_idx .. ": voiceOn's pitchShift")
    -- the voice-level values follow voiceOn
    assert_true(#context.calls_named("setVoiceParam") > 0, "voice " .. voice_idx .. ": synth values after voiceOn")
    assert_equal(#context.calls_named("setModSource"), 3, "voice " .. voice_idx .. ": the crossmod slots after voiceOn")
    -- every grain value a running voice's sync sends was among those sent
    -- before voiceOn (the registered voice params' grain keys and syncs too,
    -- so a record added later is covered)
    context.clear_engine_calls()
    sync_voice_values_to_engine(voice_idx)
    for _, call in ipairs(context.engine_calls) do
      if call.name == "setGrainParam" then
        assert_equal(before[call.args[2]], call.args[3], "voice " .. voice_idx .. ": " .. call.args[2] .. " before voiceOn")
      end
    end
  end
end)

-- A start that raises once its voiceOn is sent stops the voice again: the
-- engine and voice.active always agree, so the next toggle starts it, its
-- param senders run and cleanup's loop sees it (#382)
test("a start whose grain-restart hook raises stops the voice again and raises the error (#382)", function()
  local failing = false
  local context = load_strata({ before_init = function()
    local_value("S").register_grain_restart(function(voice_idx)
      if failing and voice_idx == 3 then error("hook failed") end
    end)
  end })
  finish_startup(context)
  local voices = local_value("voices")
  assert_true(not voices[3].active, "voice 3 is stopped")
  failing = true
  context.clear_engine_calls()
  local started, start_error = pcall(toggle_voice, 3)
  assert_true(not started, "the error reaches the caller")
  assert_true(tostring(start_error):find("hook failed", 1, true), "the hook's error: " .. tostring(start_error))
  local voice_on, voice_off
  for index, call in ipairs(context.engine_calls) do
    if call.name == "voiceOn" and call.args[1] == 2 then voice_on = index end
    if call.name == "voiceOff" and call.args[1] == 2 then voice_off = index end
  end
  assert_true(voice_on ~= nil, "voiceOn was sent")
  assert_true(voice_off ~= nil and voice_off > voice_on, "a voiceOff follows the voiceOn")
  assert_equal(voices[3].active, false, "the voice is shown stopped")
  failing = false
  context.clear_engine_calls()
  toggle_voice(3)
  assert_equal(voices[3].active, true, "the next toggle starts it")
  assert_equal(#context.calls_named("voiceOn"), 1, "with one voiceOn")
  assert_equal(#context.calls_named("voiceOff"), 0, "and no voiceOff")
end)

test("a start whose registered sync raises leaves the engine's voice stopped (#382)", function()
  local failing = false
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    local record
    record = {
      name = "failing_sync", count = 1, fader = false,
      add = function(voice_idx)
        S.lib.params_setup.add_voice_param(voice_idx, record, "failing_sync",
          { type = "control", name = "failing sync", controlspec = controlspec.new(0, 1, "lin", 0.01, 0) })
      end,
      sync = function(voice_idx)
        if failing and voice_idx == 3 then error("sync failed") end
      end,
    }
    S.register_voice_params(record)
  end })
  finish_startup(context)
  local voices = local_value("voices")
  assert_true(not voices[3].active, "voice 3 is stopped")
  failing = true
  context.clear_engine_calls()
  local started, start_error = pcall(toggle_voice, 3)
  assert_true(not started, "the error reaches the caller")
  assert_true(tostring(start_error):find("sync failed", 1, true), "the sync's error: " .. tostring(start_error))
  -- the engine's voice runs exactly when its last voiceOn or voiceOff was a voiceOn
  local engine_running = false
  for _, call in ipairs(context.engine_calls) do
    if call.args[1] == 2 and call.name == "voiceOn" then engine_running = true end
    if call.args[1] == 2 and call.name == "voiceOff" then engine_running = false end
  end
  assert_equal(engine_running, false, "the engine's voice is stopped")
  assert_equal(voices[3].active, false, "as Lua shows it")
  failing = false
  toggle_voice(3)
  assert_equal(voices[3].active, true, "the next toggle starts it")
end)

test("the largest grain overlap Lua can send fits the engine's maxGrains", function()
  load_strata()
  local source = engine_sources()
  local max_grains = tonumber(source:match("var <>maxGrains = (%d+);"))
  assert_true(max_grains ~= nil, "the engine declares var <>maxGrains = <n>;")
  local master_max = params:lookup_param("master_density").controlspec.maxval
  for voice_idx = 1, 7 do
    local size_max = params:lookup_param("v" .. voice_idx .. "_grain_size").controlspec.maxval
    local density_max = params:lookup_param("v" .. voice_idx .. "_grain_density").controlspec.maxval
    -- a GrainIn/GrainBuf runs at most maxGrains - 1 grains and drops the rest
    assert_true(size_max * density_max * master_max <= max_grains - 1,
      string.format("voice %d: %.2f s x %d x %.1f = %.0f overlapping grains fit maxGrains %d",
        voice_idx, size_max, density_max, master_max, size_max * density_max * master_max, max_grains))
  end
end)

test("grain mode option is sent, synced and never mutated", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_grain_mode", 2)
  local calls = context.calls_named("setGrainParam"); assert_equal(calls[#calls].args[2], "grainMode"); assert_equal(calls[#calls].args[3], 1)
  params:set("mutation_probability", 1); params:set("mutation_amount", 1); gentle_mutate()
  assert_equal(params:get("v1_grain_mode"), 2)
end)

test("source switching syncs through setGrainSource and swaps the main param", function()
  local context = load_strata(); finish_startup(context)
  context.clear_engine_calls(); params:set("v1_source", 4)      -- buf 3
  local calls = context.calls_named("setGrainSource")
  assert_equal(#calls, 1, "one setGrainSource per switch")
  assert_equal(calls[1].args[1], 0); assert_equal(calls[1].args[2], 3)
  assert_equal(main_param_id(1), "v1_buf_pos"); assert_equal(main_param_entry(1).label, "pos")
  params:set("v1_source", 10); calls = context.calls_named("setGrainSource"); assert_equal(calls[#calls].args[2], 9)
  assert_equal(main_param_id(1), "v1_grain_size", "input source shows grain size (a 3.0 decision: its buffer params are dead too)")
  params:set("v1_source", 1); assert_equal(main_param_id(1), "v1_freq")
  -- a stopped voice's source is sent at once (so voiceOn builds the right synths) and nothing else is
  context.clear_engine_calls(); params:set("v3_source", 5)
  assert_equal(#context.engine_calls, 1, "stopped voice: only the source is sent")
  assert_equal(context.engine_calls[1].name, "setGrainSource")
  assert_equal(context.engine_calls[1].args[1], 2); assert_equal(context.engine_calls[1].args[2], 4)
  toggle_voice(3); params:set("v3_source", 2); toggle_voice(3)          -- on, edit, off
  context.clear_engine_calls(); toggle_voice(3)                          -- on again: synced
  local sent = engine_state_for_voice(context.engine_calls, 2)
  assert_equal(context.calls_named("setGrainSource")[1].args[2], 1, "started voice sends its source")
  assert_equal(sent.grain.bufPos, 0); assert_equal(sent.grain.bufRate, 1); assert_equal(sent.grain.bufScan, 0)
  -- a running voice's switch resends the rest of its state after the source
  context.clear_engine_calls(); params:set("v3_source", 10)
  assert_equal(context.engine_calls[1].name, "setGrainSource")
  assert_equal(#context.calls_named("setGrainSource"), 1, "no second setGrainSource")
  assert_true(#context.calls_named("setVoiceParam") > 0, "running voice: voice state resent")
  assert_equal(engine_state_for_voice(context.engine_calls, 2).grain.bufPos, 0, "grain state resent")
  assert_equal(#context.calls_named("voiceOn"), 0, "switching creates no voice")
end)

test("toggle_lock locks and unlocks a voice", function()
  local context = load_strata()
  finish_startup(context)
  local locked = local_value("locked")
  local before = locked[3] and true or false
  toggle_lock(3); assert_true(locked[3] == not before)
  toggle_lock(3); assert_true(locked[3] == before)
  toggle_lock(99); toggle_lock(0)  -- ignored
  assert_true(locked[99] == nil and locked[0] == nil, "out-of-range voices never grow the table")
  assert_true(toggle_freeze == nil, "toggle_freeze is gone")
end)

-- 3.2's audio freeze (lib/freeze.lua) has its own names: S.lib.freeze.toggle
-- and is_frozen, and [F] on MAIN's status row. The lock's old freeze names
-- stay banned everywhere, and [F] is MAIN's alone.
test("no Lua file says freeze for the lock feature", function()
  local banned = { "toggle_freeze", "%[FREEZE%]", "_freeze%(", "start_or_freeze" }
  for _, source in ipairs(h.read_lua_sources()) do
    if not source.path:match("^test/") then
      local code = source.text:gsub("%-%-[^\n]*", "")
      for _, pattern in ipairs(banned) do
        assert_true(not code:find(pattern), source.path .. " still says " .. pattern)
      end
      if source.path ~= "lib/pages/main.lua" then
        assert_true(not code:find("%[F%]"), source.path .. " says [F] (only MAIN's status row does)")
      end
    end
  end
end)

-- The groundwork before 3.8 (design §1): the lock's state is S.locked and a
-- scene's field locked; "frozen" names only the audio freeze (is_frozen,
-- frozen_level, the freeze hook's argument; 3.8's S.lib.fx_hold.frozen,
-- the delay's audio freeze)
test("the lock is S.locked, and no Lua file names S.frozen or a scene field frozen", function()
  local found = {}
  for _, source in ipairs(h.read_lua_sources()) do
    if not source.path:match("^test/") then
      local code = source.text:gsub("%-%-[^\n]*", ""):gsub("fx_hold%.frozen%(", "fx_hold.audio_frozen(")
      if source.path == "lib/fx_hold.lua" then code = code:gsub("M%.frozen%(", "M.audio_frozen(") end
      if code:find("function toggle_lock%(") then found.toggle_lock = true end
      if code:find("S%.locked%[") then found.state = true end
      assert_true(not code:find("S%.frozen"), source.path .. " names S.frozen")
      assert_true(not code:find("%.frozen%f[^%w_]"), source.path .. " names a field frozen")
      if source.path == "lib/pages/main.lua" and code:find("%[L%]") then found.mark = true end
      if source.path == "lib/freeze.lua" then
        found.freeze_module = true
        assert_true(not code:find("S%.locked"), "lib/freeze.lua never names S.locked")
        assert_true(not code:find("toggle_lock"), "lib/freeze.lua never locks")
      end
    end
  end
  assert_true(found.toggle_lock, "toggle_lock is defined")
  assert_true(found.state, "the lock's state is S.locked")
  assert_true(found.mark, "MAIN shows the lock as [L]")
  assert_true(found.freeze_module, "lib/freeze.lua was scanned")
end)

-- The delay and reverb are bypassed through their bypass params (FX K3),
-- so only the filter keeps a mix to restore (#150)
test("only the filter remembers its last non-zero mix", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  assert_equal(S.fx_last_mix.filter, 1)
  params:set("filter_mix", 0.4); params:set("filter_mix", 0)
  assert_equal(S.fx_last_mix.filter, 0.4)
  params:set("delay_mix", 0.6); params:set("reverb_mix", 0.8)
  assert_equal(S.fx_last_mix.filter, 0.4, "the delay and reverb mixes leave it alone")
  local keys = {}
  for key in pairs(S.fx_last_mix) do table.insert(keys, key) end
  assert_equal(table.concat(keys, " "), "filter", "nothing kept for the delay or the reverb")
end)

test("a grain restart runs the hooks after voiceOn and after a running voice's source switch", function()
  local log, at = {}, {}
  local context = load_strata({ before_init = function(context)
    local_value("S").register_grain_restart(function(voice_idx)
      table.insert(log, voice_idx)
      table.insert(at, #context.engine_calls)
    end)
  end })
  finish_startup(context)
  for voice_idx = 1, 2 do
    if local_value("S").voices[voice_idx].active then toggle_voice(voice_idx) end
  end
  for index in pairs(log) do log[index] = nil; at[index] = nil end
  context.clear_engine_calls()
  toggle_voice(1)
  assert_equal(table.concat(log, ","), "1", "voiceOn runs the hooks once")
  local voice_on_index
  for index, call in ipairs(context.engine_calls) do
    if call.name == "voiceOn" then voice_on_index = index end
  end
  assert_true(at[1] >= voice_on_index, "the hook runs after the engine.voiceOn call")
  params:set("v1_source", 2)
  assert_equal(table.concat(log, ","), "1,1", "a running voice's source switch runs them")
  params:set("v1_source", 2)
  assert_equal(table.concat(log, ","), "1,1", "the same source again runs none")
  params:set("v2_source", 3)
  assert_equal(table.concat(log, ","), "1,1", "a stopped voice's change runs none")
end)

-- 3.4's base override, extra offsets and send budget (design §0.1)

-- The values of every setGrainParam(voice_idx - 1, name, value) sent, in order
local function grain_sends(context, voice_idx, name)
  local values = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == voice_idx - 1 and call.args[2] == name then values[#values + 1] = call.args[3] end
  end
  return values
end

local function last_grain_send(context, voice_idx, name)
  local values = grain_sends(context, voice_idx, name)
  return values[#values]
end

-- Voice 1 running on buffer 1, v1_buf_pos stored 0.7
local function buffer_voice()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  if not S.voices[1].active then toggle_voice(1) end
  params:set("v1_source", 2)
  params:set("v1_buf_pos", 0.7)
  context.clear_engine_calls()
  return context, S
end

test("a base override replaces the stored value under the LFO offsets", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  sync.set_base_override("v1_buf_pos", 0.3)
  assert_near(last_grain_send(context, 1, "bufPos"), 0.3, 1e-9, "setting the override sends it")
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.3, 1e-9, "the base is the override")
  context.clear_engine_calls()
  params:set("v1_buf_pos", 0.5)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "the stored value changes")
  assert_near(last_grain_send(context, 1, "bufPos"), 0.3, 1e-9, "the send carries the override")
  -- an offset on the param (an LFO's through the matrix, since the
  -- groundwork before 3.8) adds to the override: 0.3 + 0.2 x half of 0-1
  sync.set_extra_offset("test", "v1_buf_pos", 0.1)
  send_param_to_engine("v1_buf_pos", params:get("v1_buf_pos"))
  assert_near(last_grain_send(context, 1, "bufPos"), 0.4, 1e-9, "the LFO's offset rides on the override")
  sync.set_extra_offset("test", "v1_buf_pos", nil)
  context.clear_engine_calls()
  sync.clear_base_override("v1_buf_pos")
  assert_near(last_grain_send(context, 1, "bufPos"), 0.5, 1e-9, "clearing sends the stored value")
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.5, 1e-9, "the base is the stored value again")
end)

test("a hand edit clears the override; the drift's write does not", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  sync.set_base_override("v1_buf_pos", 0.3)
  context.clear_engine_calls()
  set_drifted_param("v1_buf_pos", 0.6)
  assert_near(last_grain_send(context, 1, "bufPos"), 0.3, 1e-9, "the drift's write is held under the override")
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.3, 1e-9, "still overridden")
  context.clear_engine_calls()
  enc_param_delta(3, "v1_buf_pos", 1)
  local stored = params:get("v1_buf_pos")
  assert_true(math.abs(stored - 0.6) > 1e-6, "the encoder moved the stored value")
  assert_near(sync.engine_base_value("v1_buf_pos"), stored, 1e-9, "the override is gone")
  assert_near(last_grain_send(context, 1, "bufPos"), stored, 1e-9, "and the engine gets the stored value")
end)

test("extra offsets sum with the LFOs' and clamp once", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  local id = "v1_grain_size"  -- 0.01-0.5
  params:set(id, 0.45)
  context.clear_engine_calls()
  sync.set_extra_offset("a", id, 0.245)
  sync.set_extra_offset("b", id, -0.245)
  assert_equal(#context.engine_calls, 0, "setting an extra sends nothing")
  send_param_to_engine(id, 0.45)
  assert_near(last_grain_send(context, 1, "grainSize"), 0.45, 1e-9, "+0.245 and -0.245, one clamp: 0.45")
  sync.set_extra_offset("b", id, nil)
  assert_equal(#grain_sends(context, 1, "grainSize"), 1, "clearing an extra sends nothing")
  send_param_to_engine(id, 0.45)
  assert_near(last_grain_send(context, 1, "grainSize"), 0.5, 1e-9, "0.45 + 0.245 clamps to 0.5")
  -- with an LFO at full negative depth (-1 x half of 0.49 = -0.245), the
  -- matrix's extra offset since the groundwork before 3.8
  sync.set_extra_offset("test", id, -0.245)
  send_param_to_engine(id, 0.45)
  assert_near(last_grain_send(context, 1, "grainSize"), 0.45, 1e-9, "the extra and the LFO's offset clamp once")
  sync.set_extra_offset("test", id, nil)
  sync.set_extra_offset("a", id, nil)
  send_param_to_engine(id, 0.45)
  assert_near(last_grain_send(context, 1, "grainSize"), 0.45, 1e-9, "no extra left: the value itself")
  -- a value outside the range comes back clamped only while modulated
  sync.set_extra_offset("a", id, 0)
  send_param_to_engine(id, 0.7)
  assert_near(last_grain_send(context, 1, "grainSize"), 0.5, 1e-9, "a param with an extra counts as modulated")
  sync.set_extra_offset("a", id, nil)
end)

-- Run the clocks to the middle of the next budget window (the window is
-- math.floor(util.time() / window_seconds)), clear of either edge's
-- rounding, with nothing sent in it yet
local function mid_window(context)
  local window = local_value("S").constants.ENGINE_BUDGET.window_seconds
  local next_start = (math.floor(util.time() / window) + 1) * window
  context.clock.run_for(next_start + window / 2 - util.time())
end

-- Spend the window's whole budget on reverb sends, outside deferrable
local function spend_budget(S)
  for _ = 1, S.constants.ENGINE_BUDGET.messages_per_window do send_param_to_engine("reverb_mix", 0.25) end
end

test("a deferrable send past the window's budget waits with its newest value", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  assert_equal(S.constants.ENGINE_BUDGET.messages_per_window, 150)
  assert_equal(S.constants.ENGINE_BUDGET.window_seconds, 0.1)
  mid_window(context)
  assert_equal(sync.budget_state().sent, 0, "a new window has spent nothing")
  spend_budget(S)
  assert_equal(sync.budget_state().sent, 150, "every send counts")
  context.clear_engine_calls()
  sync.deferrable(function()
    send_param_to_engine("filter_freq", 1000)
    send_param_to_engine("filter_freq", 2000)
  end)
  assert_equal(#context.calls_named("setFilter"), 0, "past the budget nothing goes")
  assert_equal(sync.budget_state().pending, 1, "one id waits")
  assert_true(S.engine_budget_clock ~= nil, "the flush clock runs while it waits")
  assert_equal(S.deferrable_write, false, "the flag is back")
  context.clock.run_for(0.1)
  local filters = context.calls_named("setFilter")
  assert_equal(#filters, 1, "the next window sends it once")
  assert_equal(filters[1].args[1], 2000, "with the newest value")
  assert_equal(engine_param_value("filter_freq"), 2000, "now the value the engine has")
  assert_equal(sync.budget_state().pending, 0, "nothing waits")
  assert_equal(S.engine_budget_clock, nil, "the flush clock is gone")
  -- a send at the start of the next window goes after the waiting value
  mid_window(context)
  spend_budget(S)
  sync.deferrable(function() send_param_to_engine("filter_freq", 3000) end)
  context.clear_engine_calls()
  context.set_time(util.time() + 0.1)  -- the next window, before the clock wakes
  send_param_to_engine("reverb_mix", 0.3)
  assert_equal(context.engine_calls[1].name, "setFilter", "the waiting value goes first")
  assert_equal(context.engine_calls[1].args[1], 3000)
  assert_equal(context.engine_calls[2].name, "setReverb", "then the new send")
  assert_equal(sync.budget_state().pending, 0, "nothing waits")
  assert_equal(sync.budget_state().sent, 2, "both count against the new window")
  -- never canceled with its resume posted (#654): it ends at its own wake
  assert_true(S.engine_budget_clock ~= nil, "the flush clock runs on to its wake")
  context.clock.advance()
  assert_equal(S.engine_budget_clock, nil, "where it finds nothing waiting and ends")
  assert_equal(#context.calls_named("setFilter"), 1, "having sent nothing more")
end)

test("expected_value is the waiting value, else the delivered one (#591)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  assert_equal(sync.expected_value("no_such_param"), nil, "nothing sent: nil")
  send_param_to_engine("filter_freq", 1000)
  assert_equal(sync.expected_value("filter_freq"), 1000, "sent: the value")
  if not S.voices[3].active then toggle_voice(3) end
  mid_window(context)
  spend_budget(S)
  sync.deferrable(function()
    send_param_to_engine("filter_freq", 2000)
    send_param_to_engine("v3_grain_size", 0.2)
  end)
  assert_equal(engine_param_value("filter_freq"), 1000, "the engine still has the old one")
  assert_equal(sync.expected_value("filter_freq"), 2000, "a value waiting: the waiting one")
  sync_voice_values_to_engine(3)
  assert_equal(sync.expected_value("v3_grain_size"), S.engine_param_values.v3_grain_size,
    "after a voice sync dropped its pending value: what the sync left")
  assert_true(sync.expected_value("v3_grain_size") ~= 0.2, "not the dropped value")
  context.clock.run_for(0.1)
  assert_equal(sync.expected_value("filter_freq"), 2000, "after the flush: the delivered one")
  assert_equal(engine_param_value("filter_freq"), 2000)
end)

test("deferrable restores the flag even when its function raises", function()
  local _, S = buffer_voice()
  local ok = pcall(S.lib.engine_sync.deferrable, function()
    assert_equal(S.deferrable_write, true, "inside: the flag is set")
    error("boom")
  end)
  assert_true(not ok, "the error comes through")
  assert_equal(S.deferrable_write, false, "the flag is back")
end)

test("a send outside deferrable is never deferred and drops the id's pending value", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  mid_window(context)
  spend_budget(S)
  sync.deferrable(function() send_param_to_engine("filter_freq", 1000) end)
  assert_equal(sync.budget_state().pending, 1, "the deferrable send waits")
  context.clear_engine_calls()
  send_param_to_engine("filter_freq", 500)
  assert_equal(#context.calls_named("setFilter"), 1, "past the budget a plain send still goes")
  assert_equal(context.calls_named("setFilter")[1].args[1], 500)
  assert_equal(sync.budget_state().pending, 0, "and the older waiting value is dropped")
  assert_equal(sync.budget_state().sent, 151, "it counts")
  context.clock.run_for(0.2)
  assert_equal(#context.calls_named("setFilter"), 1, "the dropped value never goes")
  assert_equal(S.engine_budget_clock, nil, "and the flush clock ended at its own wake (#654)")
end)

test("a voice sync or start drops the voice's pending deferred sends", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  if not S.voices[3].active then toggle_voice(3) end
  mid_window(context)
  spend_budget(S)
  sync.deferrable(function()
    send_param_to_engine("v3_grain_size", 0.2)
    send_param_to_engine("filter_freq", 1500)
  end)
  assert_equal(sync.budget_state().pending, 2, "both wait")
  sync_voice_values_to_engine(3)
  assert_equal(sync.budget_state().pending, 1, "the sync dropped voice 3's")
  context.clear_engine_calls()
  context.clock.run_for(0.1)
  assert_equal(#grain_sends(context, 3, "grainSize"), 0, "no later grainSize send for voice 3")
  assert_equal(#context.calls_named("setFilter"), 1, "another id's value still goes")
  -- a start drops them too: a value that waited while the voice ran, the
  -- voice stopped and started again before it went (a stopped voice's
  -- send never waits, #642)
  mid_window(context)
  spend_budget(S)
  sync.deferrable(function() send_param_to_engine("v3_grain_size", 0.3) end)
  assert_equal(sync.budget_state().pending, 1, "the running voice's send waits")
  toggle_voice(3)
  assert_equal(sync.budget_state().pending, 1, "a stop leaves it waiting")
  sync.start_voice(3)
  assert_equal(sync.budget_state().pending, 0, "the start dropped it")
  context.clear_engine_calls()
  context.clock.run_for(0.1)
  assert_equal(#grain_sends(context, 3, "grainSize"), 0, "no later grainSize send for voice 3")
end)

-- A waiting value whose sender raises must not kill the flush clock: the
-- values after it still go, and the next wait gets a clock (#637)
-- #654: another clock due in the flush clock's tick (a lower slot, so its
-- resume is delivered first) sends, and so empties the waiting list,
-- after the flush clock's resume is posted. The flush clock must never be
-- canceled then (norns' clock.resume raises on a canceled coroutine): it
-- ends at its own wake
test("a clock in the flush clock's tick that empties the waiting list leaves the flush clock to end at its wake (#654)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  mid_window(context)
  spend_budget(S)
  -- started first, so its slot is below the flush clock's; it wakes at
  -- the next window's start, as the flush clock will
  local window = S.constants.ENGINE_BUDGET.window_seconds
  clock.run(function()
    clock.sleep((math.floor(util.time() / window) + 1) * window - util.time())
    send_param_to_engine("filter_freq", 500)
  end)
  sync.deferrable(function() send_param_to_engine("filter_freq", 1000) end)
  assert_equal(sync.budget_state().pending, 1, "a value waits")
  assert_true(S.engine_budget_clock ~= nil, "for the flush clock")
  context.clear_engine_calls()
  context.clock.run_for(0.1)
  assert_equal(#context.clock.take_errors(), 0, "no resume reaches a canceled flush clock")
  local filters = context.calls_named("setFilter")
  assert_equal(#filters, 2, "the waiting value, then the other clock's")
  assert_equal(filters[1].args[1], 1000)
  assert_equal(filters[2].args[1], 500)
  assert_equal(sync.budget_state().pending, 0, "nothing waits")
  assert_equal(S.engine_budget_clock, nil, "and the flush clock ended at its own wake")
end)

test("a value that waits while the flush clock runs on idle goes at its wake, from the same clock (#654)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  local window = S.constants.ENGINE_BUDGET.window_seconds
  mid_window(context)
  spend_budget(S)
  sync.deferrable(function() send_param_to_engine("filter_freq", 1000) end)
  local flush_clock = S.engine_budget_clock
  send_param_to_engine("filter_freq", 500)   -- outside deferrable: the waiting value is dropped
  assert_equal(sync.budget_state().pending, 0, "nothing waits")
  assert_equal(S.engine_budget_clock, flush_clock, "the flush clock runs on, idle, to its wake")
  sync.deferrable(function() send_param_to_engine("filter_freq", 2000) end)
  assert_equal(sync.budget_state().pending, 1, "a new value waits")
  assert_equal(S.engine_budget_clock, flush_clock, "for the same clock, never a second")
  local wake = (math.floor(util.time() / window) + 1) * window
  context.clear_engine_calls()
  context.clock.advance_until(flush_clock)
  local filters = context.calls_named("setFilter")
  assert_equal(#filters, 1, "the clock sends it at its wake")
  assert_equal(filters[1].args[1], 2000)
  assert_true(util.time() - wake < h.stubs.MATRON_TICK_SECONDS, "at the next window's start")
  assert_equal(S.engine_budget_clock, nil, "and, nothing waiting, ends")
end)

test("a waiting value whose sender raises is reported once, and the flush goes on", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  local real_sender = S.engine_senders.reverb_size
  S.engine_senders.reverb_size = function() error("broken sender") end
  mid_window(context)
  spend_budget(S)
  sync.deferrable(function()
    send_param_to_engine("reverb_size", 0.4)
    send_param_to_engine("filter_freq", 1500)
  end)
  assert_equal(sync.budget_state().pending, 2, "both wait")
  context.clear_engine_calls()
  context.clock.run_for(0.1)
  assert_equal(#context.calls_named("setFilter"), 1, "the value after the broken one still goes")
  assert_equal(sync.budget_state().pending, 0, "nothing waits")
  assert_equal(S.engine_budget_clock, nil, "and the flush clock has ended")
  h.claim_script_errors(context, 1, "strata: engine send reverb_size failed: ", "broken sender")
  mid_window(context)
  spend_budget(S)
  sync.deferrable(function()
    send_param_to_engine("reverb_size", 0.5)
    send_param_to_engine("filter_freq", 1600)
  end)
  assert_true(S.engine_budget_clock ~= nil, "the next wait gets a flush clock")
  context.clock.run_for(0.1)
  assert_equal(#context.calls_named("setFilter"), 2, "which sends what waits")
  assert_equal(#context.take_script_errors(), 0, "a sender's failure is reported once")
  S.engine_senders.reverb_size = real_sender
end)

-- #642: a stopped voice's param sender reaches no engine (it sends only
-- while the voice runs), so a send to it neither counts against the
-- budget nor waits in it; its value is still recorded, as before

local function stop_voice(voice_idx)
  if local_value("S").voices[voice_idx].active then toggle_voice(voice_idx) end
end

test("a send to a stopped voice's param counts nothing and calls nothing; a running voice's counts (#642)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  stop_voice(2)
  mid_window(context)
  context.clear_engine_calls()
  sync.deferrable(function() send_param_to_engine("v2_grain_spread", 0.4) end)
  send_param_to_engine("v2_grain_spread", 0.45)
  assert_equal(sync.budget_state().sent, 0, "neither send counts, deferrable or not")
  assert_equal(#context.engine_calls, 0, "and neither calls the engine")
  assert_equal(sync.expected_value("v2_grain_spread"), 0.45, "the value is recorded, as before")
  -- running: one count per send, as before
  toggle_voice(2)
  context.clear_engine_calls()
  local before = sync.budget_state().sent
  sync.deferrable(function() send_param_to_engine("v2_grain_spread", 0.5) end)
  send_param_to_engine("v2_grain_spread", 0.55)
  assert_equal(sync.budget_state().sent, before + 2, "a running voice's sends count one each")
  local spread = grain_sends(context, 2, "posSpread")
  assert_equal(#spread, 2, "and reach the engine")
  assert_near(spread[2], 0.55, 1e-9)
end)

test("a stopped voice's send counts when its sender reaches the engine: the mute, a sender put in its place (#642)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  stop_voice(2)
  mid_window(context)
  context.clear_engine_calls()
  params:set("v2_mute", 1)
  assert_equal(sync.budget_state().sent, 1, "the mute reaches a stopped voice's stage, so it counts")
  assert_equal(last_grain_send(context, 2, "voiceMute"), 1, "and it is sent")
  params:set("v2_mute", 0)
  local real_sender = S.engine_senders.v2_grain_spread
  local got = {}
  S.engine_senders.v2_grain_spread = function(value) got[#got + 1] = value end
  local before = sync.budget_state().sent
  send_param_to_engine("v2_grain_spread", 0.4)
  assert_equal(got[1], 0.4, "a sender put over the voice's gated one runs")
  assert_equal(sync.budget_state().sent, before + 1, "and its send counts")
  S.engine_senders.v2_grain_spread = real_sender
end)

test("a Lua-run LFO on a stopped voice's param spends no budget; on a running voice's it does (#642)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  stop_voice(2)
  params:set("v2_grain_density", 20)
  local destination
  for index, entry in ipairs(S.LFO_DESTINATIONS) do
    if entry.label == "v2 dens" then destination = index end
  end
  local square
  for index, option in ipairs(params:lookup_param("strata_lfo1_shape").options) do
    if option == "square" then square = index end
  end
  -- LFO 1 held at its top (value +1) on voice 2's density, at depth 50
  local_value("S").lib.matrix.set_home(1, local_value("S").lib.lfos.destination_id(destination))
  params:set("strata_lfo1_shape", square)
  params:set("strata_lfo1_rate", 0.003)
  params:set("strata_lfo1_phase", 0)
  params:set("strata_lfo1_depth", 50)
  mid_window(context)
  context.clear_engine_calls()
  params:set("strata_lfo1", 1)
  local before = sync.budget_state().sent
  context.clock.advance_until(S.lfo_clock)
  assert_equal(sync.budget_state().sent, before, "the stopped voice's LFO send counts nothing")
  assert_equal(#grain_sends(context, 2, "grainDensity"), 0, "and reaches no engine")
  -- 20 + 0.5 x half of 1-100
  assert_near(sync.expected_value("v2_grain_density"), 44.75, 1e-9, "the modulated value is recorded")
  -- the start carries the LFO's offset (the matrix's extra, the groundwork
  -- before 3.8, ruling 18)
  context.clear_engine_calls()
  toggle_voice(2)
  local density = grain_sends(context, 2, "grainDensity")
  assert_equal(#density, 1, "the start sends the density")
  assert_near(density[1], 44.75 * params:get("master_density"), 1e-9, "with the LFO's offset")
  -- the LFO at its bottom: the running voice's send counts one
  params:set("strata_lfo1_phase", 50)
  context.clear_engine_calls()
  before = sync.budget_state().sent
  context.clock.advance_until(S.lfo_clock)
  assert_equal(sync.budget_state().sent, before + 1, "the running voice's LFO send counts one")
  density = grain_sends(context, 2, "grainDensity")
  assert_equal(#density, 1, "and reaches the engine")
  assert_near(density[1], 1 * params:get("master_density"), 1e-9, "20 - 24.75, clamped to 1")
  params:set("strata_lfo1", 0)
end)

test("a window full of a stopped voice's sends leaves room for a running voice's (#642)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  stop_voice(2)
  mid_window(context)
  context.clear_engine_calls()
  sync.deferrable(function()
    for k = 1, S.constants.ENGINE_BUDGET.messages_per_window do
      send_param_to_engine("v2_grain_spread", k / 1000)
    end
    send_param_to_engine("v1_grain_spread", 0.3)
  end)
  local spread = grain_sends(context, 1, "posSpread")
  assert_equal(#spread, 1, "the running voice's send goes in the same window")
  assert_near(spread[1], 0.3, 1e-9)
  assert_equal(sync.budget_state().sent, 1, "it is the one send counted")
  assert_equal(sync.budget_state().pending, 0, "nothing waits")
  assert_equal(S.engine_budget_clock, nil, "and no flush clock runs")
  assert_equal(#grain_sends(context, 2, "posSpread"), 0, "the stopped voice got nothing")
  assert_near(sync.expected_value("v2_grain_spread"), 0.15, 1e-9, "its newest value is recorded")
end)

test("past the budget a stopped voice's send never waits, and its start plays the stored value (#642)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  stop_voice(2)
  params:set("v2_grain_spread", 0.6)
  mid_window(context)
  spend_budget(S)
  context.clear_engine_calls()
  sync.deferrable(function() send_param_to_engine("v2_grain_spread", 0.4) end)
  assert_equal(sync.budget_state().pending, 0, "it does not wait")
  assert_equal(S.engine_budget_clock, nil, "and starts no flush clock")
  assert_equal(sync.budget_state().sent, 150, "nor counts")
  assert_equal(#context.engine_calls, 0, "nor reaches the engine")
  assert_equal(sync.expected_value("v2_grain_spread"), 0.4, "its value is recorded at once")
  toggle_voice(2)
  local spread = grain_sends(context, 2, "posSpread")
  assert_equal(#spread, 1, "the start sends one position spread")
  assert_near(spread[1], 0.6, 1e-9, "the stored one")
  context.clear_engine_calls()
  context.clock.run_for(0.2)
  assert_equal(#grain_sends(context, 2, "posSpread"), 0, "nothing older follows into the started voice")
end)

test("a value that waited for a voice stopped since reaches no engine and counts nothing (#642)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  if not S.voices[2].active then toggle_voice(2) end
  params:set("v2_grain_spread", 0.6)
  mid_window(context)
  spend_budget(S)
  sync.deferrable(function() send_param_to_engine("v2_grain_spread", 0.4) end)
  assert_equal(sync.budget_state().pending, 1, "the running voice's send waits")
  toggle_voice(2)  -- stopped before it goes
  context.clear_engine_calls()
  context.set_time(util.time() + 0.1)  -- the next window, before the clock wakes
  send_param_to_engine("reverb_mix", 0.3)
  assert_equal(sync.budget_state().pending, 0, "the waiting value went first")
  assert_equal(#grain_sends(context, 2, "posSpread"), 0, "to no engine")
  assert_equal(#context.engine_calls, 1, "only the new send reaches the engine")
  assert_equal(sync.budget_state().sent, 1, "and only it counts")
  context.clock.advance()
  assert_equal(S.engine_budget_clock, nil, "the flush clock ended at its own wake (#654)")
  -- a later start plays the stored value, never the one that waited
  toggle_voice(2)
  local spread = grain_sends(context, 2, "posSpread")
  assert_equal(#spread, 1, "the start sends one position spread")
  assert_near(spread[1], 0.6, 1e-9, "the stored one")
  context.clear_engine_calls()
  context.clock.run_for(0.2)
  assert_equal(#grain_sends(context, 2, "posSpread"), 0, "and nothing follows it")
end)

-- #645: the master density's sender sends one grainDensity per running
-- voice, so a send of it counts one per running voice (0 when none runs,
-- and then it never waits), and waits when the window has less room

-- Every voice running (true) or stopped (false), the drift's sends off
local function every_voice(S, running)
  S.drift_metro:stop()
  for v = 1, S.constants.NUM_VOICES do
    if S.voices[v].active ~= running then toggle_voice(v) end
  end
end

local function density_sends(context)
  local count = 0
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "grainDensity" then count = count + 1 end
  end
  return count
end

test("an LFO on the master density at the budget's edge: seven running voices cost seven (#645)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  every_voice(S, true)
  local destination, square
  for index, entry in ipairs(S.LFO_DESTINATIONS) do
    if entry.label == "density" then destination = index end
  end
  for index, option in ipairs(params:lookup_param("strata_lfo1_shape").options) do
    if option == "square" then square = index end
  end
  local_value("S").lib.matrix.set_home(1, local_value("S").lib.lfos.destination_id(destination))
  params:set("strata_lfo1_shape", square)
  params:set("strata_lfo1_rate", 0.003)
  params:set("strata_lfo1_phase", 0)
  params:set("strata_lfo1_depth", 50)
  mid_window(context)
  for _ = 1, 143 do send_param_to_engine("reverb_mix", 0.25) end
  context.clear_engine_calls()
  params:set("strata_lfo1", 1)
  context.clock.advance_until(S.lfo_clock)
  assert_equal(density_sends(context), 7, "the LFO's send reaches all seven voices")
  assert_equal(sync.budget_state().sent, 150, "and costs seven of the window")
  -- the next window: one fewer slot than voices, so a density send waits
  context.set_time(util.time() + 0.1)
  for _ = 1, 144 do send_param_to_engine("reverb_mix", 0.25) end
  context.clear_engine_calls()
  sync.deferrable(function() send_param_to_engine("master_density", 1.2) end)
  assert_equal(density_sends(context), 0, "six slots left for seven messages: it waits")
  assert_equal(sync.budget_state().pending, 1)
  context.set_time(util.time() + 0.1)
  send_param_to_engine("reverb_mix", 0.3)
  assert_equal(density_sends(context), 7, "it goes first in the window after")
  assert_equal(sync.budget_state().sent, 8, "seven for the density, one for the reverb")
  params:set("strata_lfo1", 0)
end)

-- A send larger than the whole window must not block the flush: it goes
-- when the window is empty, and what waits behind it follows (#645's
-- review). The window is shrunk to 5 for this load, so seven running
-- voices' master density is such a send
test("a send larger than the window goes at the next window's start; what waits behind it follows (#645)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  every_voice(S, true)
  local budget = S.constants.ENGINE_BUDGET
  budget.messages_per_window = 5
  mid_window(context)
  for _ = 1, 5 do send_param_to_engine("reverb_mix", 0.25) end
  context.clear_engine_calls()
  sync.deferrable(function()
    send_param_to_engine("master_density", 1.2)   -- seven messages
    send_param_to_engine("filter_freq", 1000)
  end)
  assert_equal(sync.budget_state().pending, 2, "both wait in a full window")
  context.clock.run_for(0.1)
  assert_equal(density_sends(context), 7, "the density goes at the next window's start")
  assert_equal(#context.calls_named("setFilter"), 0, "the filter waits behind it")
  assert_equal(sync.budget_state().sent, 7, "the density took the whole window")
  context.clock.run_for(0.1)
  assert_equal(#context.calls_named("setFilter"), 1, "and goes in the window after")
  assert_equal(sync.budget_state().pending, 0, "nothing waits")
  assert_equal(S.engine_budget_clock, nil, "and the flush clock has ended")
  budget.messages_per_window = 150
end)

test("with no voice running a master density send counts nothing and never waits (#645)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  every_voice(S, false)
  mid_window(context)
  context.clear_engine_calls()
  send_param_to_engine("master_density", 1.1)
  assert_equal(sync.budget_state().sent, 0, "it reaches no voice, so it counts nothing")
  spend_budget(S)
  sync.deferrable(function() send_param_to_engine("master_density", 1.2) end)
  assert_equal(sync.budget_state().pending, 0, "past the budget it does not wait")
  assert_equal(sync.budget_state().sent, 150)
  assert_equal(density_sends(context), 0, "and nothing reached the engine")
  assert_equal(engine_param_value("master_density"), 1.2, "its value is recorded, for the next start")
end)

-- #646: a param with no engine sender reaches no engine, so its sends
-- count nothing and never wait (its value is still recorded)
test("a param with no engine sender counts nothing and never waits (#646)", function()
  local context, S = buffer_voice()   -- voice 1 running
  local sync = S.lib.engine_sync
  local id = "v1_seq_gate_length"
  assert_equal(S.engine_senders[id], nil, "it has no sender")
  local value = params:get(id)
  mid_window(context)
  context.clear_engine_calls()
  send_param_to_engine(id, value)
  sync.deferrable(function() send_param_to_engine(id, value) end)
  assert_equal(sync.budget_state().sent, 0, "neither send counts, deferrable or not")
  spend_budget(S)
  context.clear_engine_calls()
  sync.deferrable(function() send_param_to_engine(id, value) end)
  assert_equal(sync.budget_state().pending, 0, "past the budget it does not wait")
  assert_equal(S.engine_budget_clock, nil, "and starts no flush clock")
  assert_equal(sync.budget_state().sent, 150, "nor counts")
  assert_equal(#context.engine_calls, 0, "nor calls the engine")
  assert_equal(sync.expected_value(id), value, "its value is recorded")
  assert_true(not sync.reaches_engine(id), "the round robin gives it no slot")
end)

-- #703: a sender that is not the engine's (the tape's softcut senders) is
-- still delivered with its offset value, but counts no engine message,
-- never waits and takes no round-robin slot
test("a sender that is not the engine's is delivered, counts nothing and takes no slot (#703)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  local got = {}
  S.engine_senders.not_engine_probe = function(value) got[#got + 1] = value end
  sync.mark_not_engine("not_engine_probe")
  mid_window(context)
  sync.deferrable(function()
    for index = 1, S.constants.ENGINE_BUDGET.messages_per_window do send_param_to_engine("not_engine_probe", index) end
  end)
  assert_equal(#got, 150, "every send was delivered, none waited")
  assert_equal(got[150], 150, "with its value")
  assert_equal(sync.budget_state().sent, 0, "none counted")
  assert_equal(sync.budget_state().pending, 0)
  assert_true(not sync.reaches_engine("not_engine_probe"), "the round robin gives it no slot")
  context.clear_engine_calls()
  sync.deferrable(function() send_param_to_engine("reverb_mix", 0.3) end)
  assert_equal(sync.budget_state().pending, 0, "an engine send after them is not deferred")
  assert_equal(sync.budget_state().sent, 1)
  assert_true(#context.engine_calls > 0, "and reached the engine")
  assert_equal(sync.expected_value("not_engine_probe"), 150, "its value is recorded")
end)

-- #649 (ruling 93): the budget's exception. A discrete switch (a recall's,
-- a transition's end, a morph crossing) goes at once, whole, in recall
-- order, uncounted, even inside deferrable with the window full; a
-- continuous value written beside it waits in the budget
test("a morph crossing at a full window: its discrete switch goes at once, uncounted; its continuous value waits (#649)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local sync = S.lib.engine_sync
  S.drift_metro:stop()
  local synth = S.constants.SOURCE_SYNTH
  -- scene 2: reverb 0.6, voice 3 running on buffer 1 in the overlap cloud;
  -- scene 1 (the state): reverb 0.2, voice 3 stopped on its synth in the
  -- density cloud (3.8 1c: the cloud, a discrete grain key, in place of
  -- 3.7's envelope)
  params:set("reverb_mix", 0.6); params:set("v3_source", synth + 1); params:set("v3_grain_cloud", 2)
  if not S.voices[3].active then toggle_voice(3) end
  capture_scene(2)
  params:set("reverb_mix", 0.2); toggle_voice(3); params:set("v3_source", synth); params:set("v3_grain_cloud", 1)
  capture_scene(1)
  params:set("morph_a", 1); params:set("morph_b", 2)
  params:set("morph", 0.4); context.clock.run_for(0.5)   -- at scene 1's corner
  mid_window(context)
  spend_budget(S)
  context.clear_engine_calls()
  params:set("morph", 0.6)
  context.clock.run_for(0.01)   -- the crossing's apply, in the same window
  local function index_of(name, second)
    for index, call in ipairs(context.engine_calls) do
      if call.name == name and call.args[1] == 2 and (second == nil or call.args[2] == second) then return index end
    end
  end
  local source, envelope, voice_on = index_of("setGrainSource", 1), index_of("setGrainParam", "overlapOn"),
    index_of("voiceOn")
  assert_true(S.voices[3].active and voice_on ~= nil, "the crossing started voice 3 at once")
  assert_true(source ~= nil and source < voice_on, "its source went first")
  assert_true(envelope ~= nil and envelope < voice_on, "its grain values before voiceOn")
  assert_equal(context.engine_calls[envelope].args[3], 1, "at scene 2's cloud")
  assert_equal(sync.budget_state().sent, 150, "none of it counted: the window is where it was")
  assert_equal(#context.calls_named("setReverb"), 0, "the crossing's continuous value waits")
  assert_equal(sync.budget_state().pending, 1)
  context.clock.run_for(0.1)
  local reverb = context.calls_named("setReverb")
  assert_equal(#reverb, 1, "and goes in the next window")
  assert_near(reverb[1].args[1], 0.2 + 0.6 * (0.6 - 0.2), 1e-9, "at the blend")
end)

test("a base override is a finite number; anything else raises naming the param", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  for _, bad in ipairs({ { nil, "nil" }, { "x", "a string" }, { 0 / 0, "NaN" }, { math.huge, "inf" } }) do
    local ok, err = pcall(sync.set_base_override, "v1_buf_pos", bad[1])
    assert_true(not ok, bad[2] .. " is refused")
    assert_true(tostring(err):find("v1_buf_pos", 1, true) ~= nil, "naming the param: " .. tostring(err))
  end
  assert_equal(#context.engine_calls, 0, "nothing refused was sent")
  assert_near(sync.engine_base_value("v1_buf_pos"), 0.7, 1e-9, "and no override is set")
end)

-- The (name, args) of every engine call, one line each
local function call_lines(calls)
  local lines = {}
  for _, call in ipairs(calls) do
    local args = {}
    for index, arg in ipairs(call.args) do args[index] = tostring(arg) end
    lines[#lines + 1] = call.name .. "(" .. table.concat(args, ", ") .. ")"
  end
  return table.concat(lines, "\n")
end

test("a voice sync re-sends the voice's overridden params", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  if not S.voices[2].active then toggle_voice(2) end
  sync.set_base_override("v1_buf_pos", 0.3)
  sync.set_base_override("v2_grain_size", 0.2)
  context.clear_engine_calls()
  sync_voice_values_to_engine(1)
  local sent = grain_sends(context, 1, "bufPos")
  assert_equal(#sent, 2, "the stored value, then the override")
  assert_near(sent[1], 0.7, 1e-9, "the sync's own send is the stored value")
  assert_near(sent[2], 0.3, 1e-9, "the sync ends with the override")
  assert_equal(context.engine_calls[#context.engine_calls].name, "setGrainParam", "the override's send is the last")
  for _, call in ipairs(context.engine_calls) do
    assert_true(call.args[1] ~= 1, "voice 2's params are untouched: " .. call.name)
  end
  -- a start: the first value it sends already carries the override, and
  -- nothing a grain synth needs follows voiceOn (#632, #325)
  toggle_voice(1)
  context.clear_engine_calls()
  toggle_voice(1)
  sent = grain_sends(context, 1, "bufPos")
  assert_equal(#sent, 1, "one bufPos for the start")
  assert_near(sent[1], 0.3, 1e-9, "and it is the override")
  local voice_on, last_grain
  for index, call in ipairs(context.engine_calls) do
    if call.args[1] == 0 and call.name == "voiceOn" then voice_on = index end
    if call.args[1] == 0 and call.name == "setGrainParam" then last_grain = index end
  end
  assert_true(voice_on ~= nil and last_grain < voice_on, "every grain value goes before voiceOn")
  assert_true(#context.calls_named("voiceOn") == 1 and S.voices[1].active, "the voice started")
  assert_near(S.engine_param_values.v1_buf_pos, 0.3, 1e-9, "the override is the value the engine has")
end)

test("a start carries the overrides and extra offsets in its first values, voiceOn's included (#632)", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  toggle_voice(1)
  params:set("v1_grain_size", 0.2)
  sync.set_base_override("v1_grain_pitch", 2)
  sync.set_extra_offset("probe", "v1_grain_size", 0.1)
  sync.set_base_override("v1_freq", 330)
  context.clear_engine_calls()
  toggle_voice(1)
  local on = context.calls_named("voiceOn")[1]
  assert_near(on.args[2], 330, 1e-9, "voiceOn's freq is the override")
  assert_near(on.args[5], 0.3, 1e-9, "its grain size the value with its offset")
  assert_near(on.args[7], 2, 1e-9, "its pitch the override")
  for _, case in ipairs({{"grainSize", 0.3}, {"pitchShift", 2}}) do
    local values = grain_sends(context, 1, case[1])
    assert_equal(#values, 1, case[1] .. ": one value for the start")
    assert_near(values[1], case[2], 1e-9, case[1] .. ": the modulated one")
  end
  for _, call in ipairs(context.calls_named("setVoiceParam")) do
    if call.args[1] == 0 and call.args[2] == "freq" then
      assert_near(call.args[3], 330, 1e-9, "every freq the start sends is the override")
    end
  end
  sync.set_extra_offset("probe", "v1_grain_size", nil)
end)

test("a voice sync re-sends a param that holds an extra offset", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  params:set("v1_grain_size", 0.2)
  sync.set_extra_offset("probe", "v1_grain_size", 0.1)
  context.clear_engine_calls()
  sync_voice_values_to_engine(1)
  local sent = grain_sends(context, 1, "grainSize")
  assert_equal(#sent, 2, "the stored value, then the value with its offset")
  assert_near(sent[1], 0.2, 1e-9)
  assert_near(sent[2], 0.3, 1e-9, "the sync ends with the offset added")
  toggle_voice(1)
  context.clear_engine_calls()
  toggle_voice(1)
  sent = grain_sends(context, 1, "grainSize")
  assert_near(sent[#sent], 0.3, 1e-9, "a start ends with it too")
  sync.set_extra_offset("probe", "v1_grain_size", nil)
end)

test("a sync with no override or offset sends exactly what it sent before", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  context.clear_engine_calls()
  sync_voice_values_to_engine(1)
  local plain = call_lines(context.engine_calls)
  assert_equal(#grain_sends(context, 1, "bufPos"), 1, "one bufPos send")
  toggle_voice(1)
  context.clear_engine_calls()
  toggle_voice(1)
  local plain_start = call_lines(context.engine_calls)
  -- an override and an offset set and cleared again leave nothing behind
  sync.set_base_override("v1_buf_pos", 0.3); sync.clear_base_override("v1_buf_pos")
  sync.set_extra_offset("probe", "v1_grain_size", 0.1); sync.set_extra_offset("probe", "v1_grain_size", nil)
  context.clear_engine_calls()
  sync_voice_values_to_engine(1)
  assert_equal(call_lines(context.engine_calls), plain, "the same sync")
  toggle_voice(1)
  context.clear_engine_calls()
  toggle_voice(1)
  assert_equal(call_lines(context.engine_calls), plain_start, "the same start")
end)

test("toggle_lock runs the lock hooks with the voice and its new state", function()
  local log = {}
  local context = load_strata({ before_init = function()
    local_value("S").register_lock_change(function(voice_idx, locked) log[#log + 1] = voice_idx .. ":" .. tostring(locked) end)
  end })
  finish_startup(context)
  toggle_lock(3); toggle_lock(3)
  assert_equal(table.concat(log, " "), "3:true 3:false", "after each flip, with the new state")
  toggle_lock(99)
  assert_equal(#log, 2, "an ignored voice runs none")
end)

-- 3.5's voice-stop registry (design §0.1): every engine.voiceOff the
-- script sends is followed by the hooks, with the voice's index
test("every voice stop runs the voice-stop hooks", function()
  local log, failing, context = {}, false, nil
  context = load_strata({ before_init = function()
    local S = local_value("S")
    S.register_voice_stop(function(voice_idx)
      local offs = context.calls_named("voiceOff")
      local last = offs[#offs]
      log[#log + 1] = { voice = voice_idx, after_off = last ~= nil and last.args[1] == voice_idx - 1,
        active = S.voices[voice_idx].active }
    end)
    S.register_grain_restart(function(voice_idx)
      if failing and voice_idx == 4 then error("hook failed") end
    end)
  end })
  finish_startup(context)
  local S = local_value("S")
  assert_equal(#log, 0, "starting voices runs none")
  toggle_voice(3)
  assert_equal(#log, 0, "a start runs none")
  toggle_voice(3)
  assert_equal(#log, 1, "a stop runs the hooks once")
  assert_equal(log[1].voice, 3, "with the voice")
  assert_true(log[1].after_off, "after its voiceOff")
  assert_equal(log[1].active, false, "with the voice shown stopped")
  toggle_voice(99)
  assert_equal(#log, 1, "an ignored voice runs none")
  -- a start that fails once voiceOn is sent: its voiceOff, then the hooks
  failing = true
  assert_true(not pcall(toggle_voice, 4), "the start raises")
  failing = false
  assert_equal(#log, 2, "the failed start's voiceOff runs the hooks once")
  assert_equal(log[2].voice, 4)
  assert_true(log[2].after_off, "after its voiceOff")
  -- cleanup's voiceOff for every running voice
  local running = {}
  for voice_idx = 1, S.constants.NUM_VOICES do
    if S.voices[voice_idx].active then running[#running + 1] = tostring(voice_idx) end
  end
  assert_true(#running >= 2, "voices 1 and 2 run")
  log = {}
  cleanup()
  local stopped = {}
  for index, entry in ipairs(log) do
    stopped[index] = tostring(entry.voice)
    assert_true(entry.after_off, "voice " .. entry.voice .. "'s hooks follow its voiceOff")
  end
  assert_equal(table.concat(stopped, " "), table.concat(running, " "), "once per running voice")
end)

-- A voice-stop hook that raises is reported (once per distinct message) and
-- skipped: every stop still completes and the other hooks still run
test("a raising voice-stop hook is reported and skipped on every stop path", function()
  local log, failing_start, later_step_ran = {}, false, false
  local context = load_strata({ before_init = function()
    local S = local_value("S")
    S.register_voice_stop(function(voice_idx) error("stop hook boom " .. voice_idx) end)
    S.register_voice_stop(function(voice_idx) log[#log + 1] = voice_idx end)
    S.register_grain_restart(function(voice_idx)
      if failing_start and voice_idx == 4 then error("start failed") end
    end)
    -- a cleanup step after the voices' (160)
    S.register_cleanup(S.constants.CLEANUP_ORDER.voices_off + 15, function() later_step_ran = true end)
  end })
  finish_startup(context)
  local S = local_value("S")
  local redraws = {}
  local real = { update_voice_list = update_voice_list, request_redraw = request_redraw, grid_redraw = grid_redraw }
  for name, fn in pairs(real) do
    _G[name] = function(...) redraws[#redraws + 1] = name; return fn(...) end
  end
  -- toggle_voice's stop: the voice stops and everything redraws
  toggle_voice(3)
  redraws = {}
  local stopped, stop_error = pcall(toggle_voice, 3)
  for name, fn in pairs(real) do _G[name] = fn end
  assert_true(stopped, "the stop completes: " .. tostring(stop_error))
  assert_equal(S.voices[3].active, false, "the voice is stopped")
  assert_equal(table.concat(log, " "), "3", "the good hook still runs")
  table.sort(redraws)
  assert_equal(table.concat(redraws, " "), "grid_redraw request_redraw update_voice_list", "the list, screen and grid redraw")
  h.claim_script_errors(context, 1, "strata: voice stop hook failed: ", "stop hook boom 3")
  -- the same error again is not printed again
  toggle_voice(3); toggle_voice(3)
  assert_equal(table.concat(log, " "), "3 3")
  assert_equal(#context.take_script_errors(), 0, "a hook's same error is reported once")
  -- a start that failed: its own error is the one raised
  failing_start = true
  local started, start_error = pcall(toggle_voice, 4)
  failing_start = false
  assert_true(not started, "the start raises")
  assert_true(tostring(start_error):find("start failed", 1, true) ~= nil, "its own error: " .. tostring(start_error))
  assert_true(tostring(start_error):find("stop hook boom", 1, true) == nil, "not the hook's")
  assert_equal(table.concat(log, " "), "3 3 4", "the good hook still runs")
  h.claim_script_errors(context, 1, "strata: voice stop hook failed: ", "stop hook boom 4")
  -- cleanup's stop of every voice: every voiceOff goes and the later steps run
  local running = {}
  for voice_idx = 1, S.constants.NUM_VOICES do
    if S.voices[voice_idx].active then running[#running + 1] = voice_idx end
  end
  assert_true(#running >= 2, "voices 1 and 2 run")
  log = {}
  context.clear_engine_calls()
  local cleaned, cleanup_error = pcall(cleanup)
  assert_true(cleaned, "cleanup completes: " .. tostring(cleanup_error))
  local offs = {}
  for _, call in ipairs(context.calls_named("voiceOff")) do offs[#offs + 1] = call.args[1] + 1 end
  assert_equal(table.concat(offs, " "), table.concat(running, " "), "a voiceOff for every running voice")
  assert_equal(table.concat(log, " "), table.concat(running, " "), "the good hook runs for each")
  assert_true(later_step_ran, "the cleanup steps after the voices' still run")
  h.claim_script_errors(context, #running, "strata: voice stop hook failed: ", "stop hook boom " .. running[#running])
end)

-- count_sends (design §6.4): messages sent outside the budget's own path
-- (the notes' sends) count in the current window, and are never deferred
test("count_sends enters direct sends in the budget's window", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  mid_window(context)
  assert_equal(sync.budget_state().sent, 0, "a new window has spent nothing")
  context.clear_engine_calls()
  sync.count_sends(149)
  assert_equal(#context.engine_calls, 0, "counting sends nothing")
  assert_equal(sync.budget_state().sent, 149, "the window holds them")
  sync.deferrable(function() send_param_to_engine("filter_freq", 1000) end)
  assert_equal(#context.calls_named("setFilter"), 1, "one deferrable send still fits the window")
  assert_equal(sync.budget_state().sent, 150)
  sync.deferrable(function() send_param_to_engine("filter_freq", 2000) end)
  assert_equal(#context.calls_named("setFilter"), 1, "the next waits")
  assert_equal(sync.budget_state().pending, 1, "its value waits")
  sync.count_sends(0)
  assert_equal(sync.budget_state().sent, 150, "count_sends(0) changes nothing")
  assert_equal(sync.budget_state().pending, 1)
  for _, bad in ipairs({ -1, 1.5, "2", math.huge, 0 / 0 }) do
    assert_true(not pcall(sync.count_sends, bad), "count_sends(" .. tostring(bad) .. ") raises")
  end
  assert_true(not pcall(sync.count_sends), "count_sends() raises")
  assert_equal(sync.budget_state().sent, 150, "nothing refused counts")
  -- the next window: the waiting value goes first, then a count starts from it
  context.clock.run_for(0.1)
  assert_equal(sync.budget_state().pending, 0, "the waiting value went")
  mid_window(context)
  sync.count_sends(3)
  assert_equal(sync.budget_state().sent, 3, "a count in a new window starts from 0")
  -- a count past the window never defers: it goes over, and the deferrable sends wait
  sync.count_sends(200)
  assert_equal(sync.budget_state().sent, 203)
  context.clear_engine_calls()
  sync.deferrable(function() send_param_to_engine("filter_freq", 3000) end)
  assert_equal(#context.calls_named("setFilter"), 0, "a full window defers the next deferrable send")
  context.clock.run_for(0.1)
  assert_equal(#context.calls_named("setFilter"), 1, "which goes in the next window")
end)

-- 3.7's seams (design §0.2, §0.3; plan rulings 12 and 13): one door for a
-- voice's hit, and a factor on an engine value

test("only S.lib.engine_sync.retrigger calls engine.retrigger", function()
  local callers = {}
  for _, source in ipairs(h.read_lua_sources()) do
    if not source.path:match("^test/") then
      local code = source.text:gsub("%-%-[^\n]*", "")
      local _, count = code:gsub("engine%.retrigger%(", "")
      if count > 0 then callers[#callers + 1] = source.path .. " x" .. count end
    end
  end
  assert_equal(table.concat(callers, ", "), "lib/engine_sync.lua x1", "one call, in lib/engine_sync.lua")
end)

-- A script with a voice_hit hook that logs each hit (voice, then the info's
-- fields) as text, registered after init (the registry is read at each use)
local function hit_log()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local log = {}
  S.register_voice_hit({ name = "probe", hit = function(voice_idx, info)
    log[#log + 1] = string.format("%d %s %.3f slot %d%s", voice_idx, info.source, info.velocity, info.slot,
      info.gate_seconds and string.format(" gate %.3f", info.gate_seconds) or "")
  end })
  return context, S, log
end

local function clear_log(log)
  for index = #log, 1, -1 do log[index] = nil end
end

test("a hit tells the voice_hit hooks once", function()
  local context, S, log = hit_log()
  local sync = S.lib.engine_sync
  assert_true(S.voices[2].active and not S.voices[3].active, "voice 2 runs, voice 3 is stopped")
  context.clear_engine_calls()
  sync.retrigger(2, 0.5, "step")
  local retriggers = context.calls_named("retrigger")
  assert_equal(#retriggers, 1, "one retrigger")
  assert_equal(retriggers[1].args[1], 1); assert_near(retriggers[1].args[2], 0.5, 1e-9)
  assert_equal(table.concat(log, "; "), "2 step 0.500 slot 1", "the hook: voice 2, its velocity, the source, slot 1")
  clear_log(log)
  sync.retrigger(2, 0.25, "step", 0.125)
  assert_equal(table.concat(log, "; "), "2 step 0.250 slot 1 gate 0.125", "a gated step's gate length")
  -- a start that no retrigger follows is a hit; a stop is none
  local hits = {}
  S.registry.voice_hit[#S.registry.voice_hit].hit = function(voice_idx, info)
    hits[#hits + 1] = string.format("%d %s %.3f slot %d", voice_idx, info.source, info.velocity, info.slot)
  end
  context.clear_engine_calls()
  toggle_voice(3)
  assert_equal(table.concat(hits, "; "), "3 start 1.000 slot 1", "a start by hand: one hit, velocity 1")
  assert_equal(#context.calls_named("retrigger"), 0, "and no retrigger")
  sync.start_voice(3)
  assert_equal(#hits, 1, "a start of a running voice takes no effect and tells nobody")
  toggle_voice(3)
  assert_equal(#hits, 1, "a stop is no hit")
  toggle_voice(3, { retrigger_follows = true })
  assert_true(S.voices[3].active, "the start took effect")
  assert_equal(#hits, 1, "a start a retrigger follows tells nobody")
  toggle_voice(3)
  sync.start_voice(3, { retrigger_follows = true })
  assert_equal(#hits, 1, "start_voice takes the same option")
  toggle_voice(3)
  sync.start_voice(3)
  assert_equal(#hits, 2, "and without it tells the hooks")
  -- the hook runs after the start's sends
  toggle_voice(3)
  local sent_before
  S.registry.voice_hit[#S.registry.voice_hit].hit = function()
    local calls = context.calls_named("setModSpeed")
    sent_before = calls[#calls] ~= nil and calls[#calls].args[1] == 2 and S.voices[3].active
  end
  context.clear_engine_calls()
  toggle_voice(3)
  assert_true(sent_before, "the hook runs once the start's sends went and the voice runs")
  -- an action's retrigger
  hits = {}
  S.registry.voice_hit[#S.registry.voice_hit].hit = function(voice_idx, info)
    hits[#hits + 1] = voice_idx .. " " .. info.source
  end
  assert_true(S.lib.io_actions.retrigger(2, 0.5), "an action accents voice 2")
  assert_equal(table.concat(hits, "; "), "2 action", "an action's hit")
end)

test("a MIDI note that starts a voice, a gated step's start and a chord step are each one hit", function()
  local context, S, log = hit_log()
  local function note_on(channel, note)
    context.midi.send(1, { type = "note_on", note = note, vel = 127, ch = channel })
  end
  -- a MIDI note on a stopped voice: the start and its retrigger are one hit
  assert_true(not S.voices[4].active, "voice 4 is stopped")
  note_on(4, 61)
  assert_true(S.voices[4].active, "the note started voice 4")
  assert_equal(table.concat(log, "; "), "4 note 1.000 slot 1", "one hit, source note")
  -- a second MIDI note taking an extra slot: one more
  clear_log(log)
  note_on(4, 64)
  assert_equal(#context.calls_named("noteOn"), 1, "the second note is an extra note")
  assert_equal(table.concat(log, "; "), "4 note 1.000 slot 2", "one more hit, in the extra slot")
  -- a gated stopped voice's first step: its start and retrigger are one hit
  clear_log(log)
  params:set("v5_seq_gate", 2)
  S.patterns[5][1] = 15
  pattern_clock_start()
  assert_true(S.voices[5].active, "the step started voice 5")
  assert_equal(#log, 1, "one hit for a gated start: " .. table.concat(log, "; "))
  assert_true(log[1]:find("^5 step 1%.000 slot 1 gate ") ~= nil, "source step, with its gate length: " .. log[1])
  pattern_clock_stop()
  S.patterns[5][1] = 0
  -- an ungated stopped voice's first step: one hit, the start's
  clear_log(log)
  S.patterns[6][1] = 15
  pattern_clock_start()
  assert_true(S.voices[6].active, "the step started voice 6")
  assert_equal(table.concat(log, "; "), "6 start 1.000 slot 1", "one hit, source start")
  pattern_clock_stop()
  S.patterns[6][1] = 0
  -- a three-note chord step on a running voice: one hit
  clear_log(log)
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "notes", { 0, 4, 7 })
  context.clear_engine_calls()
  pattern_clock_start()
  local extras = 0
  for _, call in ipairs(context.calls_named("noteOn")) do
    if call.args[1] == 0 then extras = extras + 1 end
  end
  assert_equal(extras, 2, "the chord's two further notes played")
  assert_equal(table.concat(log, "; "), "1 step 1.000 slot 1", "one hit for the step, none for its extra notes")
  pattern_clock_stop()
end)

-- Review 0b, Important 1: each MIDI note is a hit (design §0.2), a key
-- played again while its note is held in an extra slot too, as the engine's
-- extraNoteOn accents it; a step's chord replayed at a ratchet is the step's
-- one hit per ratchet, never more
test("a MIDI note played again on a key held in an extra slot is a hit; a ratchet's chord replay is not", function()
  local context, S, log = hit_log()
  local function note_on(channel, note)
    context.midi.send(1, { type = "note_on", note = note, vel = 127, ch = channel })
  end
  note_on(4, 61); note_on(4, 64)
  assert_equal(S.lib.notes.find(4, "midi", 4 * 128 + 64), 2, "64 is held in extra slot 2")
  clear_log(log)
  context.clear_engine_calls()
  note_on(4, 64)
  assert_equal(#context.calls_named("noteOn"), 1, "the replay accents the slot with a noteOn")
  assert_equal(table.concat(log, "; "), "4 note 1.000 slot 2", "and is one hit, in its slot")
  -- a ratchet replays the step's further notes in their extra slots
  clear_log(log)
  S.patterns[1][1] = 15
  S.lib.sequencer.set_step_attr(1, 1, "notes", { 0, 4, 7 })
  S.lib.sequencer.set_step_attr(1, 1, "ratchet", 2)
  context.clear_engine_calls()
  pattern_clock_start()
  context.clock.run_for(0.1)
  pattern_clock_stop()
  local replays = 0
  for _, call in ipairs(context.calls_named("noteOn")) do
    if call.args[1] == 0 then replays = replays + 1 end
  end
  assert_equal(replays, 4, "two further notes started, then replayed at the ratchet")
  assert_equal(table.concat(log, "; "), "1 step 1.000 slot 1; 1 step 1.000 slot 1", "one hit per ratchet")
end)

test("a hook that raises is contained and the others still run", function()
  local context, S, log = hit_log()
  S.register_voice_hit({ name = "boom", hit = function(voice_idx) error("hit hook boom " .. voice_idx) end })
  local later = {}
  S.register_voice_hit({ name = "later", hit = function(voice_idx) later[#later + 1] = voice_idx end })
  context.clear_engine_calls()
  S.lib.engine_sync.retrigger(1, 1, "step")
  assert_equal(#context.calls_named("retrigger"), 1, "the retrigger went")
  assert_equal(#log, 1, "the hook before ran")
  assert_equal(table.concat(later, " "), "1", "the hook after ran")
  h.claim_script_errors(context, 1, "strata: voice hit hook failed: ", "hit hook boom 1")
  S.lib.engine_sync.retrigger(1, 1, "step")
  assert_equal(table.concat(later, " "), "1 1")
  assert_equal(#context.take_script_errors(), 0, "the same error is reported once")
  toggle_voice(3)
  assert_true(S.voices[3].active, "a start whose hook raises still runs")
  assert_equal(table.concat(later, " "), "1 1 3")
  h.claim_script_errors(context, 1, "strata: voice hit hook failed: ", "hit hook boom 3")
end)

test("a factor multiplies the engine's value after the offsets and the clamp", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  local id = "v1_buf_scan"  -- -2 to 2
  params:set(id, 0.5)
  assert_equal(sync.engine_factor(id), 1, "no factor: 1")
  context.clear_engine_calls()
  sync.set_engine_factor("follow", id, 1.5)
  assert_near(last_grain_send(context, 1, "bufScan"), 0.75, 1e-9, "setting a factor resends the param with it")
  assert_near(params:get(id), 0.5, 1e-9, "the stored value stays")
  assert_near(sync.engine_factor(id), 1.5, 1e-9)
  assert_near(engine_param_value(id), 0.75, 1e-9, "the engine's value carries it")
  params:set(id, 0.4)
  assert_near(last_grain_send(context, 1, "bufScan"), 0.6, 1e-9, "an edit's send carries it")
  params:set(id, 0.5)
  -- an extra offset of half the range: 0.5 + 2 clamps to 2, then the factor
  sync.set_extra_offset("probe", id, 2)
  send_param_to_engine(id, params:get(id))
  assert_near(last_grain_send(context, 1, "bufScan"), 3, 1e-9, "the factor multiplies the clamped sum")
  sync.set_extra_offset("probe", id, nil)
  -- two keys multiply
  sync.set_engine_factor("other", id, 2)
  assert_near(sync.engine_factor(id), 3, 1e-9, "the product of every key's")
  assert_near(last_grain_send(context, 1, "bufScan"), 1.5, 1e-9)
  sync.clear_engine_factor("other", id)
  assert_near(last_grain_send(context, 1, "bufScan"), 0.75, 1e-9, "clearing one key resends")
  -- a factor of 1 clears it
  sync.set_engine_factor("follow", id, 1)
  assert_equal(sync.engine_factor(id), 1)
  assert_near(last_grain_send(context, 1, "bufScan"), 0.5, 1e-9, "a factor of 1 sends the stored value")
  sync.set_engine_factor("follow", id, 2)
  sync.set_engine_factor("follow", id, nil)
  assert_equal(sync.engine_factor(id), 1, "nil clears too")
  assert_near(last_grain_send(context, 1, "bufScan"), 0.5, 1e-9)
  context.clear_engine_calls()
  sync.clear_engine_factor("follow", id)
  assert_equal(#context.calls_named("setGrainParam"), 0, "clearing what is not set sends nothing")
  for _, bad in ipairs({ 0, -1, 0 / 0, math.huge, "2" }) do
    assert_true(not pcall(sync.set_engine_factor, "follow", id, bad), "a factor of " .. tostring(bad) .. " raises")
  end
  assert_equal(sync.engine_factor(id), 1, "nothing refused is kept")
end)

test("a start and a voice sync carry the factor", function()
  local context, S = buffer_voice()
  local sync = S.lib.engine_sync
  params:set("v1_buf_scan", 0.5)
  toggle_voice(1)
  assert_true(not S.voices[1].active, "v1 stopped")
  sync.set_engine_factor("follow", "v1_buf_scan", 1.5)
  context.clear_engine_calls()
  toggle_voice(1)
  local scans = grain_sends(context, 1, "bufScan")
  assert_equal(#scans, 1, "the start sends bufScan once")
  assert_near(scans[1], 0.75, 1e-9, "with the factor")
  local scan_at, on_at
  for index, call in ipairs(context.engine_calls) do
    if call.name == "setGrainParam" and call.args[2] == "bufScan" then scan_at = index end
    if call.name == "voiceOn" then on_at = index end
  end
  assert_true(scan_at < on_at, "before voiceOn")
  context.clear_engine_calls()
  sync_voice_values_to_engine(1)
  assert_near(last_grain_send(context, 1, "bufScan"), 0.75, 1e-9, "a sync ends with the factored value")
  sync.clear_engine_factor("follow", "v1_buf_scan")
end)

-- A call as test/fixtures/3.7.0-start-calls.lua writes it: name(args),
-- numbers "%.9g", strings "%q"
local function start_call_line(call)
  local parts = {}
  for index = 1, #call.args do
    local value = call.args[index]
    parts[index] = type(value) == "number" and string.format("%.9g", value) or string.format("%q", tostring(value))
  end
  return call.name .. "(" .. table.concat(parts, ", ") .. ")"
end

-- A start's lines with the run of setVoiceParam after voiceOn and the
-- hooks' two (attackTime, releaseTime) sorted: 3.7.0 sent that run in a
-- pairs() order; nothing else moves
local START_HOOK_SENDS = 2
local function start_canonical(lines)
  local out = {}
  for index, line in ipairs(lines) do out[index] = line end
  local voice_on
  for index, line in ipairs(out) do
    if line:match("^voiceOn%(") then voice_on = index end
  end
  assert_true(voice_on ~= nil, "the start sends voiceOn")
  local first = voice_on + START_HOOK_SENDS + 1
  local last = first - 1
  while out[last + 1] and out[last + 1]:match("^setVoiceParam%(") do last = last + 1 end
  local run = {}
  for index = first, last do run[#run + 1] = out[index] end
  table.sort(run)
  for offset, line in ipairs(run) do out[first + offset - 1] = line end
  return out
end

-- 3.8's package 0g: h.allowed_call_lines on sample lines, a start's
-- (voice 4, its tokens filled from it) and a whole run's (a token entry
-- standing for one entry a voice, its count per voice)
test("the start-call allowances name every difference, and only those", function()
  local allowed_call_lines = h.allowed_call_lines
  local fixture = {
    'setNotePool(4)',
    'setGrainParam(3, "envShape", 0)',
    'setDelay(0.5, 0.3, 0.2)',
    'voiceOn(3, 220, 0.5, 0, 0.1, 20, 1)',
  }
  local build = {
    'setNotePool(4)',
    'setVoiceType(3, 0)',
    'loadPreset(3, "v4")',
    'setDelay(0.5, 0.3, 0.2, 0)',
    'voiceOn(3, 220, 0.5, 0, 0.1, 20, 1)',
  }
  local entries = {
    {kind = "drop", match = '^setVoiceType%(<v0>, 0%)$', count = 1, why = "a test"},
    {kind = "drop", side = "fixture", match = '^setGrainParam%(<v0>, "envShape", 0%)$', count = 1, why = "a test"},
    {kind = "rewrite", match = '^(setDelay%([^,]+, [^,]+, [^,]+), 0%)$', replace = "%1)", count = 1, why = "a test"},
    {kind = "drop", match = '^loadPreset%(<v0>, "v<v>"%)$', count = 1, why = "a test"},
    {kind = "drop", match = '^setReverbFreeze%(', count = 0, why = "a test"},
  }
  local function same(a, b)
    if #a ~= #b then return false end
    for index = 1, #a do
      if a[index] ~= b[index] then return false end
    end
    return true
  end
  local want, got = allowed_call_lines(fixture, build, entries, "voice_4", 4)
  assert_true(same(want, got), "every difference is allowed")
  assert_equal(table.concat(want, " "), "setNotePool(4) setDelay(0.5, 0.3, 0.2) voiceOn(3, 220, 0.5, 0, 0.1, 20, 1)",
    "the fixture's envShape is dropped, the build's rewritten into it")
  assert_equal(#fixture .. " " .. #build, "4 5", "the lines given are left alone")
  -- each entry that makes a difference, left out, fails
  for left_out = 1, #entries do
    if entries[left_out].count > 0 then
      local others = {}
      for index, entry in ipairs(entries) do
        if index ~= left_out then others[#others + 1] = entry end
      end
      assert_true(not same(allowed_call_lines(fixture, build, others, "voice_4", 4)),
        entries[left_out].kind .. " " .. entries[left_out].match .. " left out: the lines differ")
    end
  end
  local function with(index, field, value)
    local copy = {}
    for at, entry in ipairs(entries) do
      copy[at] = entry
      if at == index then
        copy[at] = {}
        for key, item in pairs(entry) do copy[at][key] = item end
        copy[at][field] = value
      end
    end
    return copy
  end
  local function raises(list, voice)
    return not pcall(allowed_call_lines, fixture, build, list, "voice_4", voice == nil and 4 or voice)
  end
  -- the tokens are filled from the start: voice 4 is <v0> 3 and <v> 4
  assert_true(raises(entries, 1), "voice 1's tokens match no line")
  -- a count off by one raises, either way, and count 0 asserts no line
  assert_true(raises(with(1, "count", 2)), "a count one high")
  assert_true(raises(with(1, "count", 0)), "a count one low")
  assert_true(raises(with(5, "match", '^setNotePool%(')), "count 0 on a line that is sent")
  assert_true(raises(with(3, "count", 2)), "a rewrite's count")
  assert_true(raises(with(2, "count", 0)), "a fixture drop's count")
  -- each misuse raises
  assert_true(raises(with(1, "why", nil)), "no why")
  assert_true(raises(with(1, "why", "")), "an empty why")
  assert_true(raises(with(1, "kind", "keep")), "no such kind")
  assert_true(raises(with(1, "match", nil)), "no match")
  assert_true(raises(with(1, "count", nil)), "no count")
  assert_true(raises(with(1, "count", 1.5)), "a count that is no whole number")
  assert_true(raises(with(1, "side", "both")), "no such side")
  assert_true(raises(with(3, "replace", nil)), "a rewrite with no replace")
  assert_true(raises(with(3, "side", "fixture")), "a rewrite of the fixture")
  -- a match is anchored to the whole line: a leading ^ always, and a
  -- trailing $ (unescaped) when count is above 0, a rewrite's included;
  -- each line below would match its entry's count but for the anchor
  local function anchor_error(entry, lines)
    local ok, message = pcall(allowed_call_lines, {}, lines, {entry}, "anchors", 4)
    return ok and "" or tostring(message)
  end
  local function anchored(match, lines, count, kind)
    return anchor_error({kind = kind or "drop", match = match, replace = "%1)", count = count or 1,
      why = "0x: an anchor case"}, lines)
  end
  local half = {'setGrainParam(3, "scanMode", 0.5)'}
  assert_true(anchored('"scanMode", 0', half):find("0x: an anchor case", 1, true) ~= nil,
    "an unanchored match raises, naming its why (it would let scanMode 0.5 pass for 0)")
  assert_true(anchored('^setGrainParam%(3, "scanMode", 0', half) ~= "", "no trailing $ with a count above 0")
  assert_true(anchored('setGrainParam%(3, "scanMode", 0%.5%)$', half) ~= "", "no leading ^")
  assert_equal(anchored('^setGrainParam%(3, "scanMode", 0%.5%)$', half), "", "anchored at both ends, it passes")
  assert_true(anchored('setReverbFreeze%(', {}, 0) ~= "", "count 0 still needs its ^")
  assert_equal(anchored('^setReverbFreeze%(', {}, 0), "", "count 0 may match a prefix")
  assert_true(anchored('^(setDelay%(.-), 0%)', {'setDelay(0.5, 0.3, 0.2, 0)'}, 1, "rewrite") ~= "",
    "a rewrite with no trailing $")
  -- an escaped %$ at the end is a dollar sign, no anchor; %%$ is a percent sign, then the anchor
  assert_true(anchored('^price%(4%$', {'price(4$'}) ~= "", "a pattern ending in %$ is unanchored")
  assert_equal(anchored('^rate%(50%%$', {'rate(50%'}), "", "a pattern ending in %%$ is anchored")
  -- tokens fill digits only, so they neither make nor break the anchor: a
  -- $ before a token is no longer last, and is a dollar sign
  assert_equal(anchored('^setVoiceType%(<v0>, <v0>%)$', {'setVoiceType(3, 3)'}), "", "a token pattern ending in $")
  assert_true(anchored('^setVoiceType%(<v0>, <v0>', {'setVoiceType(3, 3)'}) ~= "", "a token pattern with no $")
  assert_true(anchored('^setVoiceType%(3, 3%)$<v0>', {'setVoiceType(3, 3)$3'}) ~= "", "a $ before a token")
  -- a whole run (no voice given): a token entry stands for one entry a
  -- voice, each matched on its own line, its count per voice
  local NUM_VOICES = h.voice_count()
  local function run_lines(edit)
    local lines = {'setNotePool(4)'}
    for voice = 1, NUM_VOICES do
      lines[#lines + 1] = string.format('loadPreset(%d, "v%d")', voice - 1, voice)
      if edit then edit(lines, voice) end
    end
    return lines
  end
  local per_voice = {{kind = "drop", match = '^loadPreset%(<v0>, "v<v>"%)$', count = 1, why = "a test"}}
  local _, run = allowed_call_lines({'setNotePool(4)'}, run_lines(), per_voice, "a run")
  assert_equal(table.concat(run, " "), "setNotePool(4)", "every voice's line dropped, voice 4's as loadPreset(3, \"v4\")")
  local function run_error(lines)
    local ok, message = pcall(allowed_call_lines, {'setNotePool(4)'}, lines, per_voice, "a run")
    return not ok and tostring(message) or ""
  end
  local swapped = run_lines(function(lines, voice)
    if voice == 4 then lines[#lines] = 'loadPreset(4, "v3")' end
  end)
  assert_true(run_error(swapped):find("voice 4", 1, true) ~= nil, "voice 4's line as another's raises, naming voice 4")
  local doubled = run_lines(function(lines, voice)
    if voice == 4 then lines[#lines + 1] = lines[#lines] end
  end)
  assert_true(run_error(doubled):find("voice 4", 1, true) ~= nil, "a count one high for voice 4 raises, naming it")
  local missing = run_lines(function(lines, voice)
    if voice == NUM_VOICES then lines[#lines] = nil end
  end)
  assert_true(run_error(missing):find("voice " .. NUM_VOICES, 1, true) ~= nil, "the last voice's line missing raises")
  local one_line = {'setNotePool(4)'}
  for _ = 1, NUM_VOICES do one_line[#one_line + 1] = 'loadPreset(0, "v1")' end
  assert_true(run_error(one_line):find("voice 1", 1, true) ~= nil, "seven voices each need their own match")
  -- an entry with no token counts for the run
  local whole = {{kind = "drop", match = '^loadPreset%(%d+, "v%d+"%)$', count = NUM_VOICES, why = "a test"}}
  local _, all = allowed_call_lines({'setNotePool(4)'}, run_lines(), whole, "a run")
  assert_equal(#all, 1, "a plain entry's count is the run's")
end)

-- The differences from 3.7.0 a start makes on purpose: entries for
-- h.allowed_call_lines (test/helpers.lua; docs/notes/test-harness/run-and-helpers.md),
-- applied to each start's lines and the fixture's before the comparison.
-- The package that makes a difference adds its entries in the same commit,
-- as registration lines: a block of its own, opening
-- `-- <id>: <what> (design §n)`, one entry a line, each why beginning
-- "<id>: ". An entry may carry starts = {<label>, ...} (of voice_1, voice_4
-- and buffer_voice_3; all three when absent); <v> and <v0> are filled from
-- the start it is applied to, and count is per start. A match is anchored:
-- it starts with ^, and ends with $ when count is above 0 (a prefix such
-- as '^setReverbFreeze%(' only for count 0), or the helper raises. A package that
-- changes a start message adds an entry to RUN_CALLS_ALLOWED
-- (test/unit/system_37_test.lua) too.
local START_CALLS_ALLOWED = {
  -- 0d: a start sends the voice's type right after its source (design §2.2)
  {kind = "drop", match = '^setVoiceType%(<v0>, <v0>%)$', count = 1,
    why = "0d: a start sends setVoiceType, each voice on its own type, right after setGrainSource (design §2.2)"},
  -- 1a: each voice start sends setGrainParam(<v0>, "dry", 1) (design §7.1)
  {kind = "drop", match = '^setGrainParam%(<v0>, "dry", 1%)$', count = 1,
    why = "1a: each voice start sends the stage's dry level, 1 (design section 7.1)"},
  -- 1c: the grain controls replace envShape (design §4.1, §4.2, §4.4, §4.5)
  {kind = "drop", side = "fixture", match = '^setGrainParam%(<v0>, "envShape", 0%)$', count = 1,
    why = "1c: the five grain envelopes are gone, and with them envShape (design §4.1)"},
  {kind = "drop", match = '^setGrainParam%(<v0>, "windowShape", 0%.57%)$', count = 1,
    why = "1c: a start sends the window's shape, 0.57, the Hann's table: GrainBuf's own window (design §4.1)"},
  {kind = "drop", match = '^setGrainParam%(<v0>, "windowSkew", 0%)$', count = 1,
    why = "1c: a start sends the window's skew, 0 (design §4.1)"},
  {kind = "drop", match = '^setGrainParam%(<v0>, "grainProb", 1%)$', count = 1,
    why = "1c: a start sends the grains' probability, 1: every grain (design §4.2)"},
  {kind = "drop", match = '^setGrainParam%(<v0>, "overlapOn", 0%)$', count = 1,
    why = "1c: a start sends the cloud, 0: the density's (design §4.4)"},
  {kind = "drop", match = '^setGrainParam%(<v0>, "grainOverlap", 2%)$', count = 1,
    why = "1c: a start sends the overlap, 2 at master density 1 (design §4.4)"},
  {kind = "drop", match = '^setGrainParam%(<v0>, "panSpread", 0%.5%)$', count = 1,
    why = "1c: a start sends the pan wander, 0.5, the grain synth's default that no 3.7 start sent (design §4.5)"},
  -- 1d: each voice start sends its input channel, stereo (design §5)
  {kind = "drop", match = '^setGrainParam%(<v0>, "inputChannel", 0%)$', count = 1,
    why = "1d: a start sends the input channel, 0: stereo (design section 5)"},
  -- 2b: the arpeggiator, off (design §4.3)
  {kind = "drop", match = '^setGrainParam%(<v0>, "arpOn", 0%)$', count = 1,
    why = "2b: a start sends the arpeggiator, 0: off (design section 4.3)"},
  {kind = "drop", match = '^setGrainParam%(<v0>, "arpFold", 0%)$', count = 1,
    why = "2b: a start sends the arpeggiator's fold, 0 (design section 4.3)"},
}
local START_LABELS = {voice_1 = true, voice_4 = true, buffer_voice_3 = true}
-- The entries of START_CALLS_ALLOWED that apply to the start label
local function start_allowances(label)
  local entries = {}
  for index, entry in ipairs(START_CALLS_ALLOWED) do
    local applies = entry.starts == nil
    for _, name in ipairs(entry.starts or {}) do
      if not START_LABELS[name] then error("start allowance " .. index .. ": no start " .. tostring(name), 2) end
      applies = applies or name == label
    end
    if applies then entries[#entries + 1] = entry end
  end
  return entries
end

-- The groundwork before 3.8 (design section 2): a start sends 3.7.0's
-- messages, the synth params' run compared as a set, but for
-- START_CALLS_ALLOWED's differences
test("a voice start sends 3.7.0's messages", function()
  math.randomseed(37)
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    if S.voices[voice].active then toggle_voice(voice) end
  end
  params:set("v3_source", 2)  -- buffer 1
  local fixture = dofile(h.repo_root .. "/test/fixtures/3.7.0-start-calls.lua")
  for _, start in ipairs({{"voice_1", 1}, {"voice_4", 4}, {"buffer_voice_3", 3}}) do
    local label, voice = start[1], start[2]
    context.clear_engine_calls()
    toggle_voice(voice)
    assert_true(S.voices[voice].active, label .. " started")
    local lines = {}
    for _, call in ipairs(context.engine_calls) do lines[#lines + 1] = start_call_line(call) end
    -- 0d's difference, before its drop: the type once, right after the source
    local type_line = string.format("setVoiceType(%d, %d)", voice - 1, voice - 1)
    local type_at, type_count = nil, 0
    for index, line in ipairs(lines) do
      if line == type_line then type_at, type_count = index, type_count + 1 end
    end
    assert_equal(type_count, 1, label .. ": " .. type_line .. " once")
    assert_true(lines[type_at - 1]:match("^setGrainSource%(" .. (voice - 1) .. ", ") ~= nil,
      label .. ": right after setGrainSource")
    local recorded, sent = h.allowed_call_lines(fixture[label], lines, start_allowances(label), label, voice)
    local expected, actual = start_canonical(recorded), start_canonical(sent)
    for index = 1, math.max(#expected, #actual) do
      assert_equal(actual[index], expected[index], label .. ": call " .. index)
    end
  end
end)

-- The groundwork before 3.8 (rulings 5 and 9): a start and a sync send from
-- S.lib.params_setup.voice_engine_parts, the synth params in sorted order
local BUILT_IN_PARTS = {"synth", "grain", "crossmod", "bend"}
-- The voice-param records past the built-in ones (package 2a registers
-- synth, grain and crossmod as records too: their parts are BUILT_IN_PARTS')
local function module_records(S)
  local built_in, records = {}, {}
  for _, name in ipairs(BUILT_IN_PARTS) do built_in[name] = true end
  for _, record in ipairs(S.registry.voice_params) do
    if not built_in[record.name] then records[#records + 1] = record end
  end
  return records
end
local GRAIN_PART = {"grainSize", "grainDensity", "pitchShift", "posSpread", "grainMode", "bufPos",
  "bufRate", "bufScan"}

-- A call as "name" or "name:key" for setGrainParam and setVoiceParam
local function call_tag(call)
  if call.name == "setGrainParam" or call.name == "setVoiceParam" then return call.name .. ":" .. call.args[2] end
  return call.name
end

test("voice_engine_parts names synth, grain, crossmod, bend, then the records", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    local parts = S.lib.params_setup.voice_engine_parts(voice)
    local names = {}
    for index, part in ipairs(parts) do
      names[index] = part.name
      assert_equal(type(part.kept), "table", part.name .. ": kept is a list")
      assert_equal(type(part.voice_level), "table", part.name .. ": voice_level is a list")
      for _, list in ipairs({part.kept, part.voice_level}) do
        for _, entry in ipairs(list) do
          local kinds = (entry.grain and 1 or 0) + (entry.voice and 1 or 0) + (entry.send and 1 or 0)
          assert_equal(kinds, 1, part.name .. " " .. tostring(entry.key) .. ": one of grain, voice, send")
        end
      end
    end
    local expected = {}
    for index, name in ipairs(BUILT_IN_PARTS) do expected[index] = name end
    -- (the first three records are the built-in synth, grain and crossmod: package 2a)
    -- the module records (the built-in synth, grain and crossmod records,
    -- package 2a, are the parts listed above)
    for _, record in ipairs(module_records(S)) do expected[#expected + 1] = record.name end
    assert_equal(table.concat(names, ","), table.concat(expected, ","), "voice " .. voice .. "'s parts")
    -- the synth part: the voice's synth keys, sorted, all voice-level
    local synth_keys = {}
    for _, key in ipairs(S.voices[voice].param_order) do synth_keys[#synth_keys + 1] = key end
    table.sort(synth_keys)
    local sent = {}
    for index, entry in ipairs(parts[1].voice_level) do
      sent[index] = entry.key
      assert_equal(entry.voice, entry.key, "a synth key goes out under its own name")
    end
    assert_equal(table.concat(sent, ","), table.concat(synth_keys, ","), "voice " .. voice .. "'s synth keys sorted")
    assert_equal(#parts[1].kept, 0, "nothing of the synth part is kept")
    -- the grain part: the eight, kept, in their fixed order
    local grain = {}
    for index, entry in ipairs(parts[2].kept) do grain[index] = entry.grain end
    assert_equal(table.concat(grain, ","), table.concat(GRAIN_PART, ","), "the grain part's eight in order")
    assert_equal(#parts[2].voice_level, 0, "nothing of the grain part is voice-level")
    -- crossmod: per slot its source and amounts, then the speed; none carried
    local crossmod = {}
    for index, entry in ipairs(parts[3].voice_level) do
      crossmod[index] = entry.key
      assert_equal(entry.carry, false, entry.key .. " carries no start value")
    end
    assert_equal(table.concat(crossmod, ","), "mod_source_1,mod_amp_amt_1,mod_freq_amt_1,mod_source_2,mod_amp_amt_2,"
      .. "mod_freq_amt_2,mod_source_3,mod_amp_amt_3,mod_freq_amt_3,mod_speed", "crossmod's order")
    -- bend: one keyless send
    assert_equal(#parts[4].voice_level, 1, "bend is one send")
    assert_equal(parts[4].voice_level[1].key, nil, "with no key")
    assert_true(parts[4].voice_level[1].send ~= nil, "a send")
  end
end)

test("the synth params go out sorted", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    if S.voices[voice].active then toggle_voice(voice) end
  end
  context.clear_engine_calls()
  toggle_voice(1)
  local tags, voice_on = {}, nil
  for index, call in ipairs(context.engine_calls) do
    tags[index] = call_tag(call)
    if call.name == "voiceOn" then voice_on = index end
  end
  local after = {}
  for index = voice_on + 1, voice_on + 9 do after[#after + 1] = tags[index] end
  assert_equal(table.concat(after, ","), "setVoiceParam:attackTime,setVoiceParam:releaseTime,setVoiceParam:amp,"
    .. "setVoiceParam:freq,setVoiceParam:mod1,setVoiceParam:mod2,setVoiceParam:noise,setVoiceParam:pan,"
    .. "setVoiceParam:rq", "voice 1 after the hooks' two")
end)

test("a sync sends voice_level before kept, per part", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  if not S.voices[1].active then toggle_voice(1) end
  context.clear_engine_calls()
  sync_voice_values_to_engine(1)
  local tags = {}
  for index, call in ipairs(context.engine_calls) do tags[index] = call_tag(call) end
  local expected = {"setVoiceParam:amp", "setVoiceParam:freq", "setVoiceParam:mod1", "setVoiceParam:mod2",
    "setVoiceParam:noise", "setVoiceParam:pan", "setVoiceParam:rq"}
  for _, name in ipairs(GRAIN_PART) do expected[#expected + 1] = "setGrainParam:" .. name end
  for _ = 1, S.constants.NUM_MOD_SLOTS do
    for _, name in ipairs({"setModSource", "setModAmpAmt", "setModFreqAmt"}) do expected[#expected + 1] = name end
  end
  expected[#expected + 1] = "setModSpeed"
  expected[#expected + 1] = "setVoiceParam:bend"
  for index, tag in ipairs(expected) do assert_equal(tags[index], tag, "sync call " .. index) end
  -- then each record's kept part, in registration order: its grain keys by
  -- key, or in its send_order (3.8 1c's grain_controls has one)
  local position = #expected
  for _, record in ipairs(module_records(S)) do
    local keys = {}
    for key in pairs(record.grain_keys or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    if record.send_order then
      keys = {}
      for _, key in ipairs(record.send_order) do
        if record.grain_keys and record.grain_keys[key] then keys[#keys + 1] = key end
      end
    end
    for _, key in ipairs(keys) do
      local grain_key = record.grain_keys[key]
      local name = type(grain_key) == "table" and grain_key.name or grain_key
      local found
      for index = position + 1, #tags do
        if tags[index] == "setGrainParam:" .. name then found = index; break end
      end
      assert_true(found ~= nil, record.name .. "'s " .. key .. " follows the built-in parts, in record order")
      position = found
    end
  end
end)

test("engine_sync.lua reads no S.registry.voice_params", function()
  local source = h.file_text(h.repo_root .. "/lib/engine_sync.lua")
  assert_true(not source:find("registry.voice_params", 1, true), "no read of S.registry.voice_params")
  assert_true(not source:find("registry%.voice_params"), "none at all")
end)

-- 3.8 (package 1d): a voice source j (option SOURCE_VOICE_FIRST + j - 1)
-- is sent as engine source SOURCE_VOICE_FIRST + j - 2; the stub takes the
-- last and refuses the one after it
test("sources 11-17 send setGrainSource 10-16; the stub takes 16 and refuses 17", function()
  local context = load_strata(); finish_startup(context)
  local C = local_value("S").constants
  for read = 1, C.NUM_VOICES do
    context.clear_engine_calls()
    params:set("v1_source", C.SOURCE_VOICE_FIRST + read - 1)
    local calls = context.calls_named("setGrainSource")
    assert_equal(#calls, 1, "one setGrainSource for voice " .. read .. "'s ring")
    assert_equal(calls[1].args[2], C.SOURCE_VOICE_FIRST + read - 2, "voice " .. read .. "'s ring")
  end
  local last = C.SOURCE_VOICE_FIRST + C.NUM_VOICES - 2
  assert_true(pcall(engine.setGrainSource, 0, last), "the stub takes " .. last)
  assert_true(not pcall(engine.setGrainSource, 0, last + 1), "the stub refuses " .. (last + 1))
end)

end
