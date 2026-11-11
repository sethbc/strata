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
    assert_equal(sent.voice_on[2], voice.params.freq, "voiceOn freq (number) for voice " .. voice_idx)
    for key, value in pairs(voice.params) do
      assert_equal(sent.voice[key], value, "voice " .. voice_idx .. " setVoiceParam " .. key)
    end
    assert_equal(sent.grain.grainSize, voice.grain.size, "voice " .. voice_idx .. " grainSize")
    assert_near(sent.grain.grainDensity, voice.grain.density * 1.5, 1e-9, "voice " .. voice_idx .. " grainDensity")
    assert_equal(sent.grain.pitchShift, voice.grain.pitch, "voice " .. voice_idx .. " pitchShift")
    assert_equal(sent.grain.posSpread, voice.grain.spread, "voice " .. voice_idx .. " posSpread")
    assert_equal(sent.grain.envShape, voice.grain.env - 1, "voice " .. voice_idx .. " envShape")
    assert_equal(sent.grain.grainMode, voice.grain.mode - 1, "voice " .. voice_idx .. " grainMode")
    assert_equal(sent.grain.bufPos, voice.grain.buf_pos, "voice " .. voice_idx .. " bufPos")
    assert_equal(sent.grain.bufRate, voice.grain.buf_rate, "voice " .. voice_idx .. " bufRate")
    assert_equal(sent.grain.bufScan, voice.grain.buf_scan, "voice " .. voice_idx .. " bufScan")
    -- the source goes first, before voiceOn and any other voice state (#325)
    assert_equal(context.engine_calls[1].name, "setGrainSource", "voice " .. voice_idx .. " source synced first")
    assert_equal(context.engine_calls[1].args[2], voice.source - 1, "voice " .. voice_idx .. " source")
    for slot = 1, 3 do
      local slot_state = voice.crossmod["slot" .. slot]
      local expected_source = slot_state.source == 0 and -1 or slot_state.source - 1
      assert_equal(sent.source[slot], expected_source, "voice " .. voice_idx .. " slot " .. slot .. " source")
      assert_equal(sent.amp_amt[slot], slot_state.amp_amt, "voice " .. voice_idx .. " slot " .. slot .. " amp")
      assert_equal(sent.freq_amt[slot], slot_state.freq_amt, "voice " .. voice_idx .. " slot " .. slot .. " freq")
    end
    assert_equal(sent.speed, voice.crossmod.speed, "voice " .. voice_idx .. " mod speed")
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
    local before = {}
    for index = 2, voice_on - 1 do
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
        S.lib.params_setup.add_voice_extra(voice_idx, record, "failing_sync",
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

-- lib/constants.lua's text with NUM_MOD_SLOTS set to slots
local function constants_with_mod_slots(slots)
  local file = assert(io.open(h.repo_root .. "/lib/constants.lua"))
  local source = file:read("*a")
  file:close()
  local patched, count = source:gsub("local NUM_MOD_SLOTS = 3", "local NUM_MOD_SLOTS = " .. slots)
  assert(count == 1, "lib/constants.lua sets NUM_MOD_SLOTS once")
  return patched
end

-- The ids of voice_idx's params after its cross-modulation separator, up to
-- its mod speed, in menu order
local function crossmod_menu(voice_idx)
  local ids, inside = {}, false
  for _, param in ipairs(params.params) do
    if param.t == params.tSEPARATOR and param.name == "voice " .. voice_idx .. " cross-modulation" then
      inside = true
    elseif inside then
      table.insert(ids, param.id)
      if param.id == "v" .. voice_idx .. "_mod_speed" then break end
    end
  end
  return ids
end

-- The cross-modulation params are one loop over NUM_MOD_SLOTS, as the
-- voice sync, the VOICE rows and the scenes are (#392)
test("the crossmod params follow NUM_MOD_SLOTS, as the voice sync does (#392)", function()
  local context = load_strata({ module_sources = { ["lib/constants"] = constants_with_mod_slots(2) } })
  finish_startup(context)
  assert_equal(table.concat(crossmod_menu(4), " "), "v4_mod_source_1 v4_mod_amp_amt_1 v4_mod_freq_amt_1 "
    .. "v4_mod_source_2 v4_mod_amp_amt_2 v4_mod_freq_amt_2 v4_mod_speed", "two slots in the menu")
  assert_equal(params.lookup["v4_mod_source_3"], nil, "no third slot")
  context.clear_engine_calls()
  toggle_voice(4)
  local slots = {}
  for _, call in ipairs(context.calls_named("setModSource")) do table.insert(slots, call.args[2]) end
  assert_equal(table.concat(slots, " "), "1 2", "a start sends the two slots")
  context.clear_engine_calls()
  params:set("v4_mod_amp_amt_2", 0.5); params:set("v4_mod_freq_amt_2", -0.5); params:set("v4_mod_source_2", 6)
  assert_equal(table.concat(context.calls_named("setModAmpAmt")[1].args, " "), "3 2 0.5", "slot 2's amp mod")
  assert_equal(table.concat(context.calls_named("setModFreqAmt")[1].args, " "), "3 2 -0.5", "slot 2's freq mod")
  assert_equal(table.concat(context.calls_named("setModSource")[1].args, " "), "3 2 5",
    "slot 2's source: voice 6 as engine voice 5")
end)

-- The three slots' params as the menu has always had them (saved PSETs and
-- the params tests hold them): ids, names, kinds, ranges, defaults, the
-- source's text and each one's engine call
test("each crossmod slot has its source, amp mod and freq mod params, sent to its slot (#392)", function()
  local context = load_strata(); finish_startup(context)
  assert_equal(table.concat(crossmod_menu(2), " "), "v2_mod_source_1 v2_mod_amp_amt_1 v2_mod_freq_amt_1 "
    .. "v2_mod_source_2 v2_mod_amp_amt_2 v2_mod_freq_amt_2 v2_mod_source_3 v2_mod_amp_amt_3 v2_mod_freq_amt_3 "
    .. "v2_mod_speed", "three slots, then the speed")
  local voices = local_value("voices")
  assert_true(voices[2].active, "voice 2 runs")
  for slot = 1, 3 do
    local source_id = "v2_mod_source_" .. slot
    local source = params:lookup_param(source_id)
    assert_equal(source.t, params.tNUMBER, source_id .. " is a number")
    assert_equal(source.name, "mod source " .. slot)
    assert_equal(source.min, 0, source_id .. " min"); assert_equal(source.max, 7, source_id .. " max")
    assert_equal(source.default, 0, source_id .. " default")
    assert_equal(params:string(source_id), "none", source_id .. " text at 0")
    for _, kind in ipairs({ { "amp", "amp mod " }, { "freq", "freq mod " } }) do
      local amount_id = "v2_mod_" .. kind[1] .. "_amt_" .. slot
      local amount = params:lookup_param(amount_id)
      assert_equal(amount.t, params.tCONTROL, amount_id .. " is a control")
      assert_equal(amount.name, kind[2] .. slot)
      local spec = amount.controlspec
      assert_equal(spec.minval, -2, amount_id .. " min"); assert_equal(spec.maxval, 2, amount_id .. " max")
      assert_equal(spec.warp_name, "lin", amount_id .. " warp")
      assert_equal(spec.step, 0.01, amount_id .. " step"); assert_equal(spec.default, 0, amount_id .. " default")
    end
    context.clear_engine_calls()
    params:set(source_id, 3)
    assert_equal(params:string(source_id), "voice 3", source_id .. " text at 3")
    params:set("v2_mod_amp_amt_" .. slot, 1.25); params:set("v2_mod_freq_amt_" .. slot, -0.75)
    assert_equal(table.concat(context.calls_named("setModSource")[1].args, " "), "1 " .. slot .. " 2")
    assert_equal(table.concat(context.calls_named("setModAmpAmt")[1].args, " "), "1 " .. slot .. " 1.25")
    assert_equal(table.concat(context.calls_named("setModFreqAmt")[1].args, " "), "1 " .. slot .. " -0.75")
    local slot_state = voices[2].crossmod["slot" .. slot]
    assert_equal(slot_state.source, 3); assert_equal(slot_state.amp_amt, 1.25); assert_equal(slot_state.freq_amt, -0.75)
  end
  -- a stopped voice's slot is stored, not sent
  assert_true(not voices[5].active, "voice 5 is stopped")
  context.clear_engine_calls()
  params:set("v5_mod_source_2", 4); params:set("v5_mod_amp_amt_2", 1); params:set("v5_mod_freq_amt_2", 1)
  assert_equal(#context.engine_calls, 0, "nothing sent for a stopped voice")
  assert_equal(voices[5].crossmod.slot2.source, 4); assert_equal(voices[5].crossmod.slot2.amp_amt, 1)
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

test("grain envelope option reaches the engine and is synced on start", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_grain_env", 3)
  local calls = context.calls_named("setGrainParam"); local last = calls[#calls]
  assert_equal(last.args[2], "envShape"); assert_equal(last.args[3], 2)
  toggle_voice(3); params:set("v3_grain_env", 5); toggle_voice(3)       -- on, edit, off
  context.clear_engine_calls(); toggle_voice(3)                          -- on again: synced
  local sent = engine_state_for_voice(context.engine_calls, 2)
  assert_equal(sent.grain.envShape, 4)
  capture_scene(1); params:set("v1_grain_env", 1)
  recall_scene(1, 2); wake(context, "scene_transition_clock")
  assert_equal(params:get("v1_grain_env"), 1, "transition does not interpolate env")
  recall_scene(1, 0); assert_equal(params:get("v1_grain_env"), 3)
  -- an option param floors fractional values, so check the fade list directly
  for _, target in ipairs(scene_transition_targets(local_value("scenes")[1].data)) do
    assert_true(not target.id:find("_grain_env$"), target.id .. " is not crossfaded")
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
  local frozen = local_value("frozen")
  local before = frozen[3] and true or false
  toggle_lock(3); assert_true(frozen[3] == not before)
  toggle_lock(3); assert_true(frozen[3] == before)
  toggle_lock(99); toggle_lock(0)  -- ignored
  assert_true(frozen[99] == nil and frozen[0] == nil, "out-of-range voices never grow the table")
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

test("the lock keeps its lock names and the freeze module never touches S.frozen", function()
  local found = {}
  for _, source in ipairs(h.read_lua_sources()) do
    if not source.path:match("^test/") then
      local code = source.text:gsub("%-%-[^\n]*", "")
      if code:find("function toggle_lock%(") then found.toggle_lock = true end
      if code:find("S%.frozen%[") then found.state = true end
      if source.path == "lib/pages/main.lua" and code:find("%[L%]") then found.mark = true end
      if source.path == "lib/freeze.lua" then
        found.freeze_module = true
        assert_true(not code:find("frozen%s*%["), "lib/freeze.lua never reads or writes S.frozen")
        assert_true(not code:find("S%.frozen"), "lib/freeze.lua never names S.frozen")
        assert_true(not code:find("toggle_lock"), "lib/freeze.lua never locks")
      end
    end
  end
  assert_true(found.toggle_lock, "toggle_lock is defined")
  assert_true(found.state, "the lock's state is S.frozen")
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

end
