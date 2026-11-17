-- test/unit/scan_test.lua
-- The scan's modes and tempo follow (lib/scan.lua, S.lib.scan, 3.7 design
-- §2.3, §2.4): the voice-param record scan (scan_mode, follow), the ratio
-- and rate, the step hook's factor and rate sends, the bar sync and
-- pass_seconds. A file's tempo (S.lib.samples.tempo, package 2d) and the
-- own note's region (S.lib.notes.own_region, 2b) are doubles here
-- (plan-common.md, Doubles), installed before init
-- Run alone: lua test/run.lua scan

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- scan_mode's and follow's option indices
local MODE = {wrap = 1, bounce = 2, one_shot = 3}
local FOLLOW = {off = 1, stretch = 2, repitch = 3}

-- Voice 1 (running) on slot 1, holding seconds (default 8); tempos[slot]
-- is the slot's file tempo (the 2d double), nil for none
local function loaded(seconds)
  local tempos = {}
  local context = load_strata({before_init = function()
    local S = local_value("S")
    S.lib.samples.tempo = function(slot) return tempos[slot] end
  end})
  finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = seconds or 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  assert_true(S.voices[1].active, "voice 1 runs")
  return context, S, tempos
end

-- Run the clocks until the LFO clock (the scan's step hook runs in it) has
-- stepped count times (default 1)
local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

-- The values setGrainParam sent for name to engine voice engine_voice
local function grain_values(context, engine_voice, name)
  local values = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == engine_voice and call.args[2] == name then table.insert(values, call.args[3]) end
  end
  return values
end

local function last_grain(context, engine_voice, name)
  local values = grain_values(context, engine_voice, name)
  return values[#values]
end

test("the defaults send scanMode 0 and followRate 1, and no factor", function()
  local context, S = loaded()
  assert_equal(params:get("v1_scan_mode"), MODE.wrap, "scan_mode defaults to wrap")
  assert_equal(params:string("v1_scan_mode"), "wrap")
  assert_equal(params:get("v1_follow"), FOLLOW.off, "follow defaults to off")
  assert_equal(params:string("v1_follow"), "off")
  assert_equal(S.lib.scan.FOLLOW.ratio_threshold, 0.005)
  assert_equal(S.lib.scan.FOLLOW.rate_min, 0.25)
  assert_equal(S.lib.scan.FOLLOW.rate_max, 4)
  assert_equal(S.lib.scan.FOLLOW.bar_beats, 4)
  context.clear_engine_calls()
  toggle_voice(1); toggle_voice(1)
  assert_equal(last_grain(context, 0, "scanMode"), 0, "a start sends scanMode 0")
  assert_equal(last_grain(context, 0, "followRate"), 1, "and followRate 1")
  assert_equal(S.lib.engine_sync.engine_factor("v1_buf_scan"), 1, "no factor on the scan")
  lfo_step(context, 3)
  assert_equal(#context.calls_named("syncScan"), 0, "no sync")
  assert_equal(S.lib.scan.ratio(1), 1); assert_equal(S.lib.scan.rate(1), 1)
end)

test("follow with no tempo is a ratio of 1", function()
  local context, S = loaded()
  params:set("clock_tempo", 90)
  context.clear_engine_calls()
  params:set("v1_follow", FOLLOW.repitch)
  lfo_step(context, 3)
  assert_equal(S.lib.scan.ratio(1), 1, "ratio 1")
  assert_equal(S.lib.scan.rate(1), 1, "rate 1")
  assert_equal(S.lib.engine_sync.engine_factor("v1_buf_scan"), 1, "no factor")
  assert_equal(#grain_values(context, 0, "bufScan"), 0, "no scan sent")
  for _, rate in ipairs(grain_values(context, 0, "followRate")) do assert_equal(rate, 1, "only rate 1") end
end)

test("stretch scales the scan and leaves the rate", function()
  local context, S, tempos = loaded()
  tempos[1] = 120
  params:set("clock_tempo", 90)
  params:set("v1_buf_scan", 1)
  context.clear_engine_calls()
  params:set("v1_follow", FOLLOW.stretch)
  lfo_step(context)
  assert_near(S.lib.scan.ratio(1), 0.75, 1e-9, "90 / 120")
  assert_equal(S.lib.scan.rate(1), 1, "stretch keeps the rate")
  assert_near(last_grain(context, 0, "bufScan"), 0.75, 1e-9, "bufScan 0.75")
  for _, rate in ipairs(grain_values(context, 0, "followRate")) do assert_equal(rate, 1, "followRate stays 1") end
  assert_near(params:get("v1_buf_scan"), 1, 1e-9, "the stored scan never moves")
  assert_near(engine_param_value("v1_buf_rate"), 1, 1e-9, "buf_rate's value untouched")
  assert_equal(#grain_values(context, 0, "bufRate"), 0, "and not sent")
end)

test("repitch scales both, and clamps the rate at 0.25 and 4", function()
  local context, S, tempos = loaded()
  tempos[1] = 120
  params:set("clock_tempo", 90)
  params:set("v1_buf_scan", 1)
  context.clear_engine_calls()
  params:set("v1_follow", FOLLOW.repitch)
  lfo_step(context)
  assert_near(last_grain(context, 0, "followRate"), 0.75, 1e-9, "clock 90 against 120: followRate 0.75")
  assert_near(last_grain(context, 0, "bufScan"), 0.75, 1e-9, "and the scan 0.75")
  tempos[1] = 30
  params:set("clock_tempo", 300)
  lfo_step(context)
  assert_near(last_grain(context, 0, "followRate"), 4, 1e-9, "file 30 against clock 300: followRate 4")
  assert_near(S.lib.engine_sync.engine_factor("v1_buf_scan"), 10, 1e-9, "the scan's factor 10")
  assert_near(last_grain(context, 0, "bufScan"), 10, 1e-9, "the factor is past the param's range")
  tempos[1] = 300
  params:set("clock_tempo", 20)
  lfo_step(context)
  assert_near(last_grain(context, 0, "followRate"), 0.25, 1e-9, "file 300 against clock 20: followRate 0.25")
  assert_near(S.lib.engine_sync.engine_factor("v1_buf_scan"), 20 / 300, 1e-9, "the scan's factor unclamped")
end)

test("a tempo move under 0.5% sends nothing, and a larger one sends within a step", function()
  local context, _, tempos = loaded()
  tempos[1] = 120
  params:set("clock_tempo", 100)
  params:set("v1_buf_scan", 1)
  params:set("v1_follow", FOLLOW.repitch)
  lfo_step(context, 2)
  context.clear_engine_calls()
  tempos[1] = 120.5  -- 0.42%
  lfo_step(context, 4)
  assert_equal(#grain_values(context, 0, "bufScan"), 0, "no scan sent under 0.5%")
  assert_equal(#grain_values(context, 0, "followRate"), 0, "no rate sent under 0.5%")
  tempos[1] = 121  -- 0.83% from the ratio last set
  lfo_step(context)
  assert_near(last_grain(context, 0, "bufScan"), 100 / 121, 1e-9, "the scan within a step")
  assert_near(last_grain(context, 0, "followRate"), 100 / 121, 1e-9, "and the rate")
  assert_equal(#grain_values(context, 0, "bufScan"), 1, "once")
  assert_equal(#grain_values(context, 0, "followRate"), 1, "once")
end)

test("turning follow off puts the factor and the rate back at once", function()
  local context, S, tempos = loaded()
  tempos[1] = 120
  params:set("clock_tempo", 90)
  params:set("v1_buf_scan", 1)
  params:set("v1_follow", FOLLOW.repitch)
  lfo_step(context)
  assert_near(last_grain(context, 0, "followRate"), 0.75, 1e-9)
  context.clear_engine_calls()
  params:set("v1_follow", FOLLOW.off)
  assert_equal(S.lib.engine_sync.engine_factor("v1_buf_scan"), 1, "the factor goes at once")
  assert_near(last_grain(context, 0, "bufScan"), 1, 1e-9, "the scan is resent")
  assert_equal(last_grain(context, 0, "followRate"), 1, "the rate at once")
end)

test("a voice that leaves its buffer stops following at once, running or stopped", function()
  local context, S, tempos = loaded()
  tempos[1] = 120
  tempos[2] = 120
  params:set("clock_tempo", 90)
  params:set("v1_buf_scan", 1)
  params:set("v1_follow", FOLLOW.repitch)
  lfo_step(context)
  assert_near(S.lib.engine_sync.engine_factor("v1_buf_scan"), 0.75, 1e-9)
  context.clear_engine_calls()
  params:set("v1_source", S.constants.SOURCE_SYNTH)  -- no step between the switch and the checks
  assert_equal(S.lib.engine_sync.engine_factor("v1_buf_scan"), 1, "a synth voice has no factor, at once")
  assert_equal(last_grain(context, 0, "followRate"), 1, "and its rate is 1")
  for _, value in ipairs(grain_values(context, 0, "bufScan")) do
    assert_near(value, 1, 1e-9, "no scan with the old factor reaches the engine")
  end
  -- a stopped voice's switch too, so its next start carries no old factor
  params:set("v1_source", S.constants.SOURCE_SYNTH + 2)
  lfo_step(context)
  assert_near(S.lib.engine_sync.engine_factor("v1_buf_scan"), 0.75, 1e-9, "following on buffer 2")
  toggle_voice(1)
  assert_true(not S.voices[1].active)
  params:set("v1_source", S.constants.SOURCE_INPUT)
  assert_equal(S.lib.engine_sync.engine_factor("v1_buf_scan"), 1, "a stopped voice's switch, at once")
end)

test("a recall that takes a stopped voice off its buffer settles its follow at once (#739)", function()
  local context, S, tempos = loaded()
  tempos[1] = 120
  params:set("clock_tempo", 90)
  params:set("v1_follow", FOLLOW.repitch)
  lfo_step(context)
  assert_near(S.lib.engine_sync.engine_factor("v1_buf_scan"), 0.75, 1e-9, "following on buffer 1")
  toggle_voice(1)
  assert_true(not S.voices[1].active, "voice 1 is stopped")
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  capture_scene(1)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  assert_near(S.lib.engine_sync.engine_factor("v1_buf_scan"), 0.75, 1e-9, "back on the buffer: the source hook")
  recall_scene(1, 0)  -- no LFO step after it
  assert_equal(params:get("v1_source"), S.constants.SOURCE_SYNTH, "the recall leaves the buffer")
  assert_equal(S.lib.engine_sync.engine_factor("v1_buf_scan"), 1, "the factor goes with the recall")
  assert_true(not S.voices[1].active, "the voice is still stopped")
end)

-- The budget's window (math.floor(util.time() / window_seconds)): run the
-- clocks to the middle of the next one, then spend it all on reverb sends
-- outside deferrable, so a deferrable send in it waits
local function full_window(context, S)
  local window = S.constants.ENGINE_BUDGET.window_seconds
  local next_start = (math.floor(util.time() / window) + 1) * window
  context.clock.run_for(next_start + window / 2 - util.time())
  for _ = 1, S.constants.ENGINE_BUDGET.messages_per_window do send_param_to_engine("reverb_mix", 0.25) end
end

test("a tempo move under a full budget waits for the next window", function()
  local context, S, tempos = loaded()
  tempos[1] = 120
  params:set("v1_buf_scan", 1)
  params:set("v1_follow", FOLLOW.stretch)
  lfo_step(context)
  full_window(context, S)
  context.clear_engine_calls()
  params:set("clock_tempo", 90)
  lfo_step(context)
  assert_equal(#grain_values(context, 0, "bufScan"), 0, "the scan waits with the window full")
  assert_true(S.lib.engine_sync.budget_state().pending >= 1, "its value waits")
  assert_near(S.lib.engine_sync.engine_factor("v1_buf_scan"), 0.75, 1e-9, "the factor is set")
  context.clock.run_for(S.constants.ENGINE_BUDGET.window_seconds)
  assert_near(last_grain(context, 0, "bufScan"), 0.75, 1e-9, "and goes in the next window")
end)

test("a sync waiting for the budget is dropped when the voice restarts", function()
  local context, S, tempos = loaded()
  tempos[1] = 120
  params:set("v1_buf_scan", 1)
  params:set("v1_follow", FOLLOW.stretch)
  lfo_step(context)
  full_window(context, S)
  context.clear_engine_calls()
  context.clock.set_beat(clock.get_beats() + S.lib.scan.FOLLOW.bar_beats)  -- the next step is a new bar
  lfo_step(context)
  assert_equal(#context.calls_named("syncScan"), 0, "the sync waits with the window full")
  assert_true(S.lib.engine_sync.budget_state().pending >= 1, "its value waits")
  toggle_voice(1); toggle_voice(1)
  context.clear_engine_calls()
  context.clock.run_for(S.constants.ENGINE_BUDGET.window_seconds)
  assert_equal(#context.calls_named("syncScan"), 0, "the restart dropped it: no stale phase lands")
end)

test("a following voice is synced once a bar, and not while held, gliding, frozen, stopped or in one shot", function()
  local context, S, tempos = loaded()
  tempos[1] = 120
  params:set("v1_buf_scan", 1)
  params:set("v1_follow", FOLLOW.stretch)
  lfo_step(context)
  -- 8 beats at 120 BPM (4 s), checking each sync's phase at its step
  local function run_beats(beats)
    -- from just after a bar: the jump back is a bar change of its own, so
    -- one step takes it first
    context.clock.set_beat(0.1)
    lfo_step(context)
    context.clear_engine_calls()
    local phases = {}
    local until_time = util.time() + beats * 60 / 120
    while util.time() < until_time do
      local before = #context.calls_named("syncScan")
      lfo_step(context)
      local calls = context.calls_named("syncScan")
      if #calls > before then
        local call = calls[#calls]
        assert_equal(call.args[1], 0, "voice 1's sync")
        assert_near(call.args[2], S.lib.playheads.phase(1), 1e-9, "the playhead's phase at that step")
        table.insert(phases, call.args[2])
      end
    end
    return #context.calls_named("syncScan"), phases
  end
  local count = run_beats(8)
  assert_equal(count, 2, "two bars, two syncs")
  params:set("v1_scan_mode", MODE.bounce)
  local _, phases = run_beats(8)
  assert_equal(#phases, 2, "bounce is synced too")
  assert_true(phases[1] >= 0 and phases[1] < 2, "a bounce phase is 0-2")
  params:set("v1_scan_mode", MODE.wrap)

  S.lib.positions.hold_scan(1, true)
  assert_equal(run_beats(8), 0, "not while held")
  S.lib.positions.hold_scan(1, false)

  local real_rate = S.lib.positions.scrub_rate
  S.lib.positions.scrub_rate = function() return 0.1 end
  assert_equal(run_beats(8), 0, "not while gliding")
  S.lib.positions.scrub_rate = real_rate

  params:set("v1_freeze", 1)
  assert_equal(run_beats(8), 0, "not while frozen")
  params:set("v1_freeze", 0)

  params:set("v1_scan_mode", MODE.one_shot)
  assert_equal(run_beats(8), 0, "not in one shot")
  params:set("v1_scan_mode", MODE.wrap)

  toggle_voice(1)
  assert_true(not S.voices[1].active)
  assert_equal(run_beats(8), 0, "not while stopped")
  toggle_voice(1)

  params:set("v1_follow", FOLLOW.off)
  assert_equal(run_beats(8), 0, "not without follow")
  params:set("v1_follow", FOLLOW.stretch)
  assert_equal(run_beats(8), 2, "and again once following")
end)

test("pass_seconds is the region's time in one shot and nil otherwise", function()
  local context, S, tempos = loaded(8)
  params:set("v1_buf_scan", 1)
  params:set("v1_scan_mode", MODE.one_shot)
  assert_near(S.lib.scan.pass_seconds(1, 0.25), 2, 1e-9, "an 8 s slot, scan 1, a quarter: 2 s")
  params:set("v1_buf_scan", 2)
  assert_near(S.lib.scan.pass_seconds(1, 0.25), 1, 1e-9, "scan 2: 1 s")
  params:set("v1_buf_scan", -2)
  assert_near(S.lib.scan.pass_seconds(1, 0.25), 1, 1e-9, "backward the same")
  params:set("v1_buf_scan", 1)
  tempos[1] = 80
  params:set("clock_tempo", 120)
  params:set("v1_follow", FOLLOW.stretch)
  lfo_step(context)
  assert_near(S.lib.scan.ratio(1), 1.5, 1e-9)
  assert_near(S.lib.scan.pass_seconds(1, 0.25), 2 / 1.5, 1e-3, "follow at ratio 1.5: 1.333")
  params:set("v1_scan_mode", MODE.wrap)
  assert_equal(S.lib.scan.pass_seconds(1, 0.25), nil, "wrap: nil")
  params:set("v1_scan_mode", MODE.one_shot)
  params:set("v1_buf_scan", 0)
  assert_equal(S.lib.scan.pass_seconds(1, 0.25), nil, "scan 0: nil")
end)

test("a scan mode change restarts the engine's scan and the playhead", function()
  local context, S = loaded(8)
  params:set("v1_buf_pos", 0)
  params:set("v1_buf_scan", 1)
  context.clock.run_for(2)
  assert_true(S.lib.playheads.phase(1) > 0, "the scan has moved")
  context.clear_engine_calls()
  params:set("v1_scan_mode", MODE.bounce)
  local names = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 then table.insert(names, call.args[2]) end
  end
  assert_equal(table.concat(names, " "), "scanMode t_scanReset", "the mode, then the restart")
  assert_equal(last_grain(context, 0, "scanMode"), 1, "bounce is 1")
  assert_near(S.lib.playheads.phase(1), 0, 1e-9, "the playhead restarts")
  params:set("v1_scan_mode", MODE.one_shot)
  assert_equal(last_grain(context, 0, "scanMode"), 2, "one shot is 2")
end)

test("the two options are discrete scene fields and default in a scene without them", function()
  local context, S = loaded()
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "scan" then record = each end end
  assert_true(record ~= nil, "the scan record")
  assert_equal(record.fader, false, "no fader")
  assert_equal(record.discrete.scan_mode[1], 1); assert_equal(record.discrete.scan_mode[2], 3)
  assert_equal(record.discrete.follow[1], 1); assert_equal(record.discrete.follow[2], 3)
  assert_equal(record.scene_defaults.scan_mode, 1); assert_equal(record.scene_defaults.follow, 1)
  params:set("v1_scan_mode", MODE.one_shot)
  params:set("v1_follow", FOLLOW.repitch)
  capture_scene(1)
  assert_equal(S.scenes[1].data.voices[1].values.scan_mode, MODE.one_shot, "captured")
  assert_equal(S.scenes[1].data.voices[1].values.follow, FOLLOW.repitch, "captured")
  local scene = S.scenes[1]
  scene.data.voices[1].values.scan_mode, scene.data.voices[1].values.follow = nil, nil
  fill_scene(scene)
  assert_equal(scene.data.voices[1].values.scan_mode, MODE.wrap, "filled with wrap")
  assert_equal(scene.data.voices[1].values.follow, FOLLOW.off, "filled with off")
  recall_scene_instant(1)
  assert_equal(params:get("v1_scan_mode"), MODE.wrap, "a recall applies them")
  assert_equal(params:get("v1_follow"), FOLLOW.off)
  assert_true(context ~= nil)
end)

test("the scan rows show while the voice reads a buffer", function()
  local _, S = loaded()
  local function ids(voice_idx)
    local found = {}
    for _, row in ipairs(voice_page_rows(voice_idx)) do
      if row.param_id then found[row.param_id] = row.section end
    end
    return found
  end
  assert_equal(ids(1).v1_scan_mode, "synth", "scan mode in the synth section")
  assert_equal(ids(1).v1_follow, "synth", "follow too")
  params:set("v1_source", S.constants.SOURCE_SYNTH)
  assert_equal(ids(1).v1_scan_mode, nil, "a synth voice has none")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  assert_equal(ids(1).v1_follow, nil, "an input voice has none")
end)

-- The Wave 2 landing: follow reads the file's tempo from S.lib.samples at
-- each use and never checks it is there: without it follow fails loudly
test("without the file's settings follow fails loudly", function()
  local _, S, tempos = loaded()
  tempos[1] = 120
  params:set("v1_follow", FOLLOW.stretch)
  assert_true(S.lib.scan.following(1), "voice 1 follows its file's tempo")
  local tempo = S.lib.samples.tempo
  S.lib.samples.tempo = nil
  local ok, err = pcall(S.lib.scan.following, 1)
  S.lib.samples.tempo = tempo
  assert_true(not ok and tostring(err):find("tempo", 1, true) ~= nil, "no S.lib.samples.tempo: an error: " .. tostring(err))
end)

end
