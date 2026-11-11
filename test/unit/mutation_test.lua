-- test/unit/mutation_test.lua
-- Drift, randomize and gentle mutation (lib/mutation.lua)
-- Run alone: lua test/run.lua mutation

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local deep_copy, show_page = h.deep_copy, h.show_page

test("grain pitch drift wanders subtly around the user-set pitch (C4)", function()
  local context = load_strata()
  local drift_metro = context.metro.all[1]
  assert_true(drift_metro.running and drift_metro.event == drift_update, "drift metro running")
  params:set("v1_grain_pitch", 1.5)
  math.randomseed(3)
  local max_offset = 0
  for _ = 1, 20000 do
    drift_metro.event()
    max_offset = math.max(max_offset, math.abs(params:get("v1_grain_pitch") - 1.5))
  end
  assert_true(max_offset > 0.001, "pitch actually drifts (" .. max_offset .. ")")
  assert_true(max_offset < 0.06, "drift stays within a few percent (" .. max_offset .. ")")
  -- a new user value becomes the new center
  params:set("v1_grain_pitch", 0.5)
  for _ = 1, 2000 do drift_metro.event() end
  assert_near(params:get("v1_grain_pitch"), 0.5, 0.06, "walk re-centers on the new value")
  -- frozen voices do not drift
  toggle_lock(1)
  local frozen_pitch = params:get("v1_grain_pitch")
  for _ = 1, 100 do drift_metro.event() end
  assert_equal(params:get("v1_grain_pitch"), frozen_pitch, "frozen voice pitch unchanged")
end)

-- drift_writing tells the param actions a write is the drift's: left set
-- after an error, every later edit would stop re-centering the walk
test("drift_update clears drift_writing when a param action raises (#48)", function()
  load_strata()                                                 -- voice 1 starts at once
  local centers = { v1_grain_pitch = "grain_pitch_base", v1_buf_pos = "buf_pos_base" }
  for _, id in ipairs({ "v1_grain_pitch", "v1_buf_pos" }) do
    params:set("v1_source", id == "v1_buf_pos" and 2 or 1)     -- buffer 1: its position drifts too
    params:set(id, 0.5)                                          -- clear of the rails: every step moves it
    local param = params:lookup_param(id)
    local real_action = param.action
    param.action = function() error(id .. " failed") end
    local ok, message = pcall(drift_update)
    assert_true(not ok and tostring(message):find(id .. " failed", 1, true), id .. ": the error is raised")
    assert_true(tostring(message):find("stack traceback:", 1, true), id .. ": with its traceback")
    assert_equal(local_value("drift_writing"), false, id .. ": drift_writing cleared")
    param.action = real_action
    params:set(id, 0.6)
    assert_equal(local_value(centers[id])[1], 0.6, id .. ": a later edit is the drift's new center")
  end
end)

test("randomize and mutate touch buffer params, never source", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_source", 2); local freq = params:get("v1_freq")
  local synth_before = deep_copy(local_value("voices")[1].params)
  math.randomseed(7); randomize_voice(1)
  assert_equal(params:get("v1_freq"), freq, "synth params untouched for a buffer voice")
  assert_true(params:get("v1_buf_rate") ~= 1 or params:get("v1_buf_pos") ~= 0, "buffer params randomized")
  for _ = 1, 20 do
    randomize_voice(1)
    assert_true(params:get("v1_buf_rate") >= 0.5 - 1e-9 and params:get("v1_buf_rate") <= 2 + 1e-9, "rate 0.5-2")
    assert_true(math.abs(params:get("v1_buf_scan")) <= 0.5 + 1e-9, "scan -0.5..0.5")
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  local pos_before = params:get("v1_buf_pos")
  gentle_mutate()
  assert_equal(params:get("v1_source"), 2)
  assert_true(params:get("v1_buf_pos") ~= pos_before, "mutation moves buf_pos")
  for key, value in pairs(synth_before) do
    assert_equal(local_value("voices")[1].params[key], value, "mutation leaves synth " .. key .. " alone")
  end
  -- synth-sourced voices keep mutating synth params, never the source
  params:set("v1_source", 1); local mutated = false
  for _ = 1, 5 do gentle_mutate(); if params:get("v1_freq") ~= freq then mutated = true end end
  assert_true(mutated, "synth source mutates synth params again")
  for _ = 1, 20 do randomize_voice(1); gentle_mutate() end
  assert_equal(params:get("v1_source"), 1, "source never randomized or mutated")
  -- freeze covers buffer params
  params:set("v1_source", 5); toggle_lock(1)
  local frozen_state = deep_copy(local_value("voices")[1].grain)
  randomize_voice(1); gentle_mutate(); for _ = 1, 10 do drift_update() end
  for key, value in pairs(frozen_state) do
    assert_equal(local_value("voices")[1].grain[key], value, "frozen buffer voice keeps " .. key)
  end
end)

test("randomize and mutation work in normalized space for exponential params", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 (synth source) running
  local spec = params:lookup_param("v1_freq").controlspec
  assert_true(spec.minval == 20 and spec.maxval == 2000 and spec.warp_name == "exp",
    "voice 1 freq is the 20-2000 Hz exponential spec this test covers")
  local midpoint = math.sqrt(spec.minval * spec.maxval)
  math.randomseed(11)
  local below, draws = 0, 2000
  for _ = 1, draws do
    randomize_voice(1)
    if params:get("v1_freq") < midpoint then below = below + 1 end
  end
  local share = below / draws
  assert_true(share > 0.35 and share < 0.65,
    "freq randomize (20-2000 Hz exp) lands below the geometric midpoint about half the time (" .. share .. ")")
  -- a mutation step moves freq by at most amount in normalized distance
  params:set("mutation_probability", 1); params:set("mutation_amount", 0.25)
  local max_step = 0
  for _ = 1, 300 do
    params:set("v1_freq", spec:map(math.random()))
    local before = spec:unmap(params:get("v1_freq"))
    gentle_mutate()
    max_step = math.max(max_step, math.abs(spec:unmap(params:get("v1_freq")) - before))
  end
  assert_true(max_step <= 0.25 + 1e-6, "normalized mutation step within amount (" .. max_step .. ")")
  assert_true(max_step > 0.05, "mutation actually moves freq (" .. max_step .. ")")
end)

test("gentle_mutate skips every grain key in DISCRETE_GRAIN_KEYS", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 running
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  params:set("v1_grain_env", 3); params:set("v1_grain_mode", 2)
  math.randomseed(13)
  for _ = 1, 50 do gentle_mutate() end
  assert_equal(params:get("v1_grain_env"), 3, "envelope shape never mutates")
  assert_equal(params:get("v1_grain_mode"), 2, "grain mode never mutates")
  -- the guard is the table: any grain key marked discrete is left alone
  local discrete = local_value("DISCRETE_GRAIN_KEYS")
  for _, key in ipairs({ "size", "pitch", "spread", "buf_pos", "buf_rate", "buf_scan" }) do discrete[key] = 1 end
  for _, source in ipairs({ 1, 2, 10 }) do   -- synth, buffer, input
    params:set("v1_source", source)
    local before = deep_copy(local_value("voices")[1].grain)
    for _ = 1, 20 do gentle_mutate() end
    for key, value in pairs(before) do
      assert_equal(local_value("voices")[1].grain[key], value, "source " .. source .. ": grain " .. key .. " skipped")
    end
  end
end)

test("buffer position drifts subtly and reverts to the user-set position", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 running
  assert_true(local_value("voices")[1].active, "voice 1 on")
  params:set("v1_source", 2); params:set("v1_buf_pos", 0.4)
  local synth_freq = params:get("v1_freq")
  math.randomseed(3)
  local max_offset = 0
  for _ = 1, 3000 do
    drift_update()
    max_offset = math.max(max_offset, math.abs(params:get("v1_buf_pos") - 0.4))
  end
  assert_true(max_offset > 0, "buf_pos drifts")
  assert_true(max_offset < 0.05, "drift stays subtle (max " .. max_offset .. ")")
  assert_equal(params:get("v1_freq"), synth_freq, "drift leaves synth params alone")
  params:set("v1_buf_pos", 0.8)
  for _ = 1, 3000 do drift_update() end
  assert_true(math.abs(params:get("v1_buf_pos") - 0.8) < 0.05, "a new user position becomes the center")
  -- a synth-sourced voice's position does not drift
  params:set("v1_source", 1); local pos = params:get("v1_buf_pos")
  for _ = 1, 100 do drift_update() end
  assert_equal(params:get("v1_buf_pos"), pos, "synth source: no position drift")
end)

test("mean_reverting_step: one random step plus a pull toward the base, used by both drifts", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 running
  math.randomseed(5); local random = math.random()
  math.randomseed(5)
  assert_near(mean_reverting_step(1.2, 1.0, 0.004, 0.01), 1.2 + (random - 0.5) * 0.004 - 0.2 * 0.01, 1e-12,
    "current + (random - 0.5) * step - (current - base) * reversion")
  -- drift_update's grain pitch and buffer position steps are exactly that
  params:set("v1_source", 2); params:set("v1_grain_pitch", 1.5); params:set("v1_buf_pos", 0.4)
  for _ = 1, 50 do drift_update() end
  local pitch, position = params:get("v1_grain_pitch"), params:get("v1_buf_pos")
  math.randomseed(9); local pitch_random = math.random(); local position_random = math.random()
  math.randomseed(9); drift_update()
  assert_near(params:get("v1_grain_pitch"), pitch + (pitch_random - 0.5) * 0.004 - (pitch - 1.5) * 0.01, 1e-12,
    "grain pitch drift step")
  assert_near(params:get("v1_buf_pos"), position + (position_random - 0.5) * 0.002 - (position - 0.4) * 0.01, 1e-12,
    "buffer position drift step")
end)

-- Randomize undo (one level, UNDO_SECONDS): S.undo holds the values the last
-- randomize replaced, and undo_randomize puts them back through params:set

-- The param ids randomize_voice sets for voice 1 with its current source
local function randomized_ids()
  local ids = {}
  if voice_uses_synth(1) then
    for key in pairs(local_value("voices")[1].params) do
      if key ~= "amp" then ids[#ids + 1] = "v1_" .. key end
    end
  elseif voice_uses_buffer(1) then
    ids = { "v1_buf_pos", "v1_buf_rate", "v1_buf_scan" }
  end
  ids[#ids + 1] = "v1_grain_size"; ids[#ids + 1] = "v1_grain_pitch"
  table.sort(ids)
  return ids
end

local function stored_ids()
  local ids = {}
  for id in pairs(local_value("undo").values) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

test("undo restores the values a randomize changed", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 (synth source) running
  assert_equal(local_value("UNDO_SECONDS"), 5, "UNDO_SECONDS")
  assert_true(not undo_available(1), "no undo before a randomize")
  assert_equal(undo_randomize(), false, "nothing to undo")
  local before = {}
  for _, id in ipairs(randomized_ids()) do before[id] = params:get(id) end
  local amp = params:get("v1_amp")
  math.randomseed(21); randomize_voice(1)
  assert_true(undo_available(1), "undo available for voice 1")
  assert_true(not undo_available(2), "and for no other voice")
  local undo = local_value("undo")
  assert_equal(undo.voice, 1, "S.undo.voice")
  assert_near(undo.until_time, util.time() + 5, 1e-9, "S.undo.until_time")
  assert_equal(table.concat(stored_ids(), " "), table.concat(randomized_ids(), " "),
    "every param randomize sets is stored, amp is not")
  for id, value in pairs(before) do assert_equal(undo.values[id], value, id .. " stored before the change") end
  assert_true(params:get("v1_freq") ~= before.v1_freq, "the randomize changed freq")
  local engine_calls = #context.engine_calls
  assert_equal(undo_randomize(), true, "undo_randomize reports the undo")
  for id, value in pairs(before) do assert_near(params:get(id), value, 1e-9, id .. " restored") end
  assert_equal(params:get("v1_amp"), amp, "amp untouched")
  assert_true(#context.engine_calls > engine_calls, "the restore reaches the engine (params:set)")
  assert_equal(local_value("undo"), nil, "the undo is cleared")
  assert_true(not undo_available(1), "no second undo")
  assert_equal(undo_randomize(), false, "undo_randomize after the undo does nothing")
end)

test("undo expires after 5 s and requests a redraw", function()
  local context = load_strata(); finish_startup(context)
  randomize_voice(1)
  local start = util.time()
  local real_request_redraw = request_redraw
  local requests = {}
  request_redraw = function() requests[#requests + 1] = util.time(); real_request_redraw() end
  context.clock.run_for(4.9)
  assert_true(undo_available(1), "still available at 4.9 s")
  context.clock.run_for(0.11)
  request_redraw = real_request_redraw
  assert_true(not undo_available(1), "expired after 5 s")
  assert_equal(local_value("undo"), nil, "the expiry clears S.undo")
  local at_expiry = false
  for _, time in ipairs(requests) do
    if math.abs(time - (start + 5)) < 1e-6 then at_expiry = true end
  end
  assert_true(at_expiry, "a redraw is requested at until_time, without input")
  assert_equal(local_value("undo_clock"), nil, "the expiry clock is done")
  -- availability follows util.time() even before the clock runs
  randomize_voice(1)
  context.set_time(util.time() + 5)
  assert_true(not undo_available(1), "not available at until_time")
  assert_equal(undo_randomize(), false, "and not undone")
end)

test("a manual edit of a stored param clears the undo, an edit of another param does not", function()
  local context = load_strata(); finish_startup(context)
  randomize_voice(1)
  params:set("v1_grain_density", 77)                 -- not stored
  assert_true(undo_available(1), "an edit of a param randomize left alone keeps the undo")
  params:set("v1_rq", params:get("v1_rq") == 0.5 and 0.4 or 0.5)
  assert_equal(local_value("undo"), nil, "an edit of a stored param clears it")
  assert_equal(local_value("undo_clock"), nil, "and cancels its expiry clock")
  -- every param a randomize stores reports its edits, for each kind of source
  for _, source in ipairs({ 1, 2, 10 }) do            -- synth, buffer, input
    params:set("v1_source", source)
    for _, id in ipairs(randomized_ids()) do
      randomize_voice(1)
      assert_true(local_value("undo").values[id] ~= nil, "source " .. source .. ": " .. id .. " stored")
      local spec = params:lookup_param(id).controlspec
      params:set(id, spec:map(spec:unmap(params:get(id)) < 0.5 and 0.9 or 0.1))
      assert_equal(local_value("undo"), nil, "source " .. source .. ": an edit of " .. id .. " clears the undo")
    end
  end
end)

test("the drift's pitch writes do not clear the undo; undo restores the stored pitch", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_source", 2)                           -- buffer: the position drifts too
  local pitch, position = params:get("v1_grain_pitch"), params:get("v1_buf_pos")
  math.randomseed(4); randomize_voice(1)
  for _ = 1, 20 do drift_update() end
  assert_true(undo_available(1), "drift writes keep the undo")
  assert_true(undo_randomize(), "undo")
  assert_near(params:get("v1_grain_pitch"), pitch, 1e-9, "the stored pitch is back")
  assert_near(params:get("v1_buf_pos"), position, 1e-9, "the stored position is back")
  assert_near(local_value("grain_pitch_base")[1], pitch, 1e-9, "the drift carries on from the restored pitch")
  assert_near(local_value("buf_pos_base")[1], position, 1e-9, "and the restored position")
end)

test("a randomize of another voice, a recall or a mutation of the voice clears the undo", function()
  local context = load_strata(); finish_startup(context)   -- voices 1 and 2 running
  -- another voice's randomize replaces it (one level)
  randomize_voice(1); randomize_voice(2)
  assert_true(not undo_available(1), "voice 1's undo is gone")
  assert_true(undo_available(2), "voice 2's randomize holds the undo")
  -- a second randomize of the same voice stores the values it replaced
  local first = params:get("v2_grain_size")
  randomize_voice(2)
  assert_equal(local_value("undo").values.v2_grain_size, first, "the latest randomize's previous values")
  -- scene recalls: instant, faded, and recall_scene_instant directly
  capture_scene(1)
  for _, recall in ipairs({
    function() recall_scene(1) end,
    function() recall_scene(1, 2) end,
    function() recall_scene_instant(1) end,
  }) do
    randomize_voice(1); assert_true(undo_available(1), "undo before the recall")
    recall()
    assert_equal(local_value("undo"), nil, "a recall clears the undo")
    cancel_scene_transition()
  end
  -- a mutation step on another voice keeps it; one on the undo's voice clears it
  params:set("mutation_probability", 1); params:set("mutation_amount", 0.5)
  randomize_voice(2); toggle_lock(2)   -- voice 2 locked: only voice 1 mutates
  gentle_mutate()
  assert_true(undo_available(2), "a mutation of another voice keeps the undo")
  toggle_lock(2)
  gentle_mutate()
  assert_equal(local_value("undo"), nil, "a mutation step on the undo's voice clears it")
  -- a mutation step that changes only an unstored param of the voice clears it too
  params:set("v2_source", 10)                           -- input: grain params only
  randomize_voice(2)
  local discrete = local_value("DISCRETE_GRAIN_KEYS")
  discrete.size = 1; discrete.pitch = 1                 -- only grain spread may mutate
  local spread = params:get("v2_grain_spread")
  for _ = 1, 200 do                                     -- spread mutates in a fifth of the steps
    gentle_mutate()
    if params:get("v2_grain_spread") ~= spread then break end
    assert_true(undo_available(2), "a step that changes nothing on the voice keeps the undo")
  end
  discrete.size = nil; discrete.pitch = nil
  assert_true(params:get("v2_grain_spread") ~= spread, "grain spread mutated")
  assert_equal(local_value("undo"), nil, "a mutation of grain spread on the voice clears it")
end)

test("a locked voice is not randomized and keeps an earlier undo", function()
  local context = load_strata(); finish_startup(context)
  randomize_voice(1)
  local undo = local_value("undo")
  toggle_lock(2)
  local size = params:get("v2_grain_size")
  randomize_voice(2)
  assert_equal(params:get("v2_grain_size"), size, "locked voice unchanged")
  assert_true(local_value("undo") == undo and undo_available(1), "voice 1's undo stays")
  assert_true(not undo_available(2), "nothing stored for the locked voice")
  randomize_voice(0); randomize_voice(8)                 -- out of range: ignored
  assert_true(local_value("undo") == undo, "out-of-range voices leave the undo alone")
end)

test("an input voice's undo holds only grain size and pitch", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_source", 10)
  randomize_voice(1)
  assert_equal(table.concat(stored_ids(), " "), "v1_grain_pitch v1_grain_size", "only grain size and pitch")
  params:set("v1_source", 2)
  randomize_voice(1)
  assert_equal(table.concat(stored_ids(), " "), "v1_buf_pos v1_buf_rate v1_buf_scan v1_grain_pitch v1_grain_size",
    "a buffer voice's undo: buffer params, grain size and pitch")
end)

test("the undo flag clears after an error in a param action, and cleanup cancels the expiry clock", function()
  local context = load_strata(); finish_startup(context)
  local param = params:lookup_param("v1_grain_size")
  local real_action = param.action
  param.action = function() error("grain size failed") end
  local ok, message = pcall(randomize_voice, 1)
  assert_true(not ok and tostring(message):find("grain size failed", 1, true), "the error is raised")
  assert_true(tostring(message):find("stack traceback:", 1, true), "with its traceback")
  param.action = real_action
  assert_equal(local_value("undo_writing"), false, "undo_writing cleared")
  randomize_voice(1)
  params:set("v1_grain_size", params:get("v1_grain_size") == 0.2 and 0.3 or 0.2)
  assert_equal(local_value("undo"), nil, "a later edit clears the undo again")
  randomize_voice(1)
  local clock_id = local_value("undo_clock")
  assert_true(clock_id ~= nil, "expiry clock running")
  cleanup()
  assert_equal(local_value("undo_clock"), nil, "cleanup cancels the expiry clock")
  assert_equal(context.clock.threads[clock_id], nil, "the clock is gone")
end)

-- The mutation metro's tick never raises: an error in a step is printed
-- once with its traceback, and the next tick mutates again (#517)
test("an error inside a mutation tick is printed once and the next tick mutates (#517)", function()
  local context = load_strata(); finish_startup(context)   -- voice 1 (synth source) running
  local S = local_value("S")
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  -- the tick draws math.random for every param it considers, whatever it caches
  local real_random = math.random
  local failure = "mutation boom"
  math.random = function(...)
    if failure then error(failure) end
    return real_random(...)
  end
  local function reports()
    local count, traced = 0, false
    for _, line in ipairs(context.printed) do
      if line:find("strata: mutation failed: ", 1, true) == 1 then
        count = count + 1
        traced = traced or line:find("stack traceback", 1, true) ~= nil
      end
    end
    return count, traced
  end
  context.printed = {}
  local ok, problem = pcall(function()
    for _ = 1, 3 do S.mutation_metro.event() end
    local count, traced = reports()
    assert_equal(count, 1, "the same error on every tick prints once")
    assert_true(traced, "with its traceback")
    failure = nil
    math.randomseed(4)
    local freq = params:get("v1_freq")
    S.mutation_metro.event()
    assert_true(params:get("v1_freq") ~= freq, "the next good tick mutates")
    failure = "mutation boom"
    S.mutation_metro.event()
    assert_equal(reports(), 2, "the error after a good tick prints again")
    failure = "another mutation boom"
    S.mutation_metro.event()
    assert_equal(reports(), 3, "a different message prints at once")
  end)
  math.random = real_random
  if not ok then error(problem, 0) end
  h.claim_script_errors(context, 3, "strata: mutation failed: ", "another mutation boom")  -- the three it caused (#473)
end)

-- #318: a mutation step moves a param from its stored value, so it is a
-- turn: a quantized freq walks by scale tones even when each step is less
-- than half a scale step (as a set, each would snap back to its tone)
test("mutation steps walk a quantized freq by scale tones (#318)", function()
  local context = load_strata(); finish_startup(context)   -- voices 1 and 2 run
  local variation = local_value("S").lib.variation
  params:set("scale", 2)                                    -- musicutil's first scale (Major)
  params:set("v1_quantize", 1)
  params:set("v1_freq", 300); params:set("v1_freq", 440)
  params:set("mutation_probability", 1); params:set("mutation_amount", 0.01)  -- steps under 0.8 st
  math.randomseed(5)
  local tones = {}
  for _ = 1, 200 do
    gentle_mutate()
    local note = 69 + 12 * math.log(params:get("v1_freq") / 440) / math.log(2)
    local whole = math.floor(note + 0.5)
    assert_near(note, whole, 1e-6, "every mutated freq is a whole note")
    assert_equal(variation.snap_note(whole), whole, "and a tone of the scale (" .. whole .. ")")
    tones[whole] = true
  end
  local count = 0
  for _ in pairs(tones) do count = count + 1 end
  assert_true(count > 2, "the walk reaches more than two tones (" .. count .. ")")
  assert_equal(local_value("S").turning_param, nil, "no turn is left marked")
end)

-- #410: what the review's mutations of lib/mutation.lua survived
test("mutations never move amp or pan, nor any value of a stopped voice (#410)", function()
  local context = load_strata(); finish_startup(context)   -- voices 1 and 2 run
  local voices = local_value("voices")
  assert_true(voices[1].active and voices[2].active and not voices[3].active, "voices 1 and 2 run, 3 is stopped")
  params:set("v4_source", 2)                                -- a stopped buffer voice too
  local stopped = {}
  for _, voice_idx in ipairs({ 3, 4 }) do stopped[voice_idx] = deep_copy(voices[voice_idx]) end
  local levels = {}
  for voice_idx = 1, 2 do levels[voice_idx] = { amp = voices[voice_idx].params.amp, pan = voices[voice_idx].params.pan } end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(9)
  local moved = false
  for _ = 1, 50 do
    local before = voices[1].params.freq
    gentle_mutate()
    if voices[1].params.freq ~= before then moved = true end
  end
  assert_true(moved, "the running voices mutate")
  for voice_idx = 1, 2 do
    assert_equal(voices[voice_idx].params.amp, levels[voice_idx].amp, "voice " .. voice_idx .. "'s amp never mutates")
    assert_equal(voices[voice_idx].params.pan, levels[voice_idx].pan, "voice " .. voice_idx .. "'s pan never mutates")
  end
  for voice_idx, before in pairs(stopped) do
    for _, part in ipairs({ "params", "grain" }) do
      for key, value in pairs(before[part]) do
        assert_equal(voices[voice_idx][part][key], value, "stopped voice " .. voice_idx .. "'s " .. part .. "." .. key)
      end
    end
  end
end)

test("the drift leaves a stopped voice's grain pitch and buffer position (#410)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  params:set("v3_source", 2)                                -- buffer 1, stopped
  params:set("v3_grain_pitch", 1.5); params:set("v3_buf_pos", 0.5)
  params:set("v1_source", 2)                                -- a running buffer voice drifts both
  params:set("v1_grain_pitch", 1.5); params:set("v1_buf_pos", 0.5)
  math.randomseed(4)
  for _ = 1, 50 do drift_update() end
  assert_equal(voices[3].grain.pitch, 1.5, "a stopped voice's grain pitch does not drift")
  assert_equal(voices[3].grain.buf_pos, 0.5, "nor its buffer position")
  assert_true(voices[1].grain.pitch ~= 1.5 and voices[1].grain.buf_pos ~= 0.5, "a running voice's do")
end)

test("a drift tick brings a param set elsewhere to the 256's fader page (#410)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local press = function(x, y) context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0) end
  press(14, 8)                                              -- grid page 2 (the faders)
  press(2, 14)                                              -- voice 2 (fm): row 11 is its index fader
  assert_true(device:get_led(16, 11) ~= 15, "index is not at its top")
  params:set("v2_index", 10)                                -- E3, MIDI or PARAMS: no grid redraw of its own
  assert_true(device:get_led(16, 11) ~= 15, "the set alone leaves the fader as it was")
  drift_update()
  assert_equal(device:get_led(16, 11), 15, "the next drift tick shows it")
end)

test("the undo's expiry clock forgets its id before it clears the undo, so it never cancels itself (#410)", function()
  local context = load_strata(); finish_startup(context)
  randomize_voice(1)
  local expiry_id = local_value("undo_clock")
  local expiry = context.clock.threads[expiry_id]
  assert_true(expiry ~= nil, "an expiry clock runs")
  local real_cancel, self_canceled = clock.cancel, false
  clock.cancel = function(coro_id, ...)
    if coro_id == expiry_id and coroutine.running() == expiry then self_canceled = true end
    return real_cancel(coro_id, ...)
  end
  context.clock.run_for(5.1)
  clock.cancel = real_cancel
  assert_true(not undo_available(1), "the undo expired")
  assert_true(not self_canceled, "the expiry clock never canceled itself")
  assert_equal(local_value("undo_clock"), nil, "its id is forgotten")
end)

-- #557: one randomize and undo for every page, S.lib.mutation.randomize(spec)
-- and S.lib.mutation.undo(), with the one S.undo naming its page, section
-- and voice

-- A value of param_id other than its current one, so a set runs its action
local function other_value(param_id)
  local param = params:lookup_param(param_id)
  if param.t == params.tOPTION then return param.selected % param.count + 1 end
  if param.t == params.tBINARY then return 1 - params:get(param_id) end
  if param.t == params.tNUMBER then
    return params:get(param_id) < param.max and params:get(param_id) + 1 or params:get(param_id) - 1
  end
  local spec = param.controlspec
  return spec:map(spec:unmap(params:get(param_id)) < 0.5 and 0.9 or 0.1)
end

local function page_index(name) return local_value("S").constants.UI_PAGES.index[name] end

test("randomize records the old values and undo restores them (#557)", function()
  local context = load_strata(); finish_startup(context)
  local mutation = local_value("S").lib.mutation
  local FX = page_index("FX")
  assert_near(params:get("reverb_mix"), 0.3, 1e-9, "reverb mix at its default")
  assert_near(params:get("reverb_size"), 0.8, 1e-9, "reverb size at its default")
  local size_saw_mix
  local engine_calls = #context.engine_calls
  assert_equal(mutation.randomize({ page = FX, section = "reverb", draws = {
    { id = "reverb_mix", draw = function() return 0.45 end },
    { id = "reverb_size", draw = function() size_saw_mix = params:get("reverb_mix"); return 0.9 end },
  } }), true, "randomize reports the randomize")
  assert_near(params:get("reverb_mix"), 0.45, 1e-9, "the first draw is set")
  assert_near(params:get("reverb_size"), 0.9, 1e-9, "the second draw is set")
  assert_near(size_saw_mix, 0.45, 1e-9, "a later draw reads an earlier one's new value")
  assert_true(#context.engine_calls > engine_calls, "the draws reach the engine through the actions")
  local undo = local_value("undo")
  assert_equal(undo.page, FX, "S.undo.page")
  assert_equal(undo.section, "reverb", "S.undo.section")
  assert_equal(undo.voice, nil, "S.undo.voice: FX has none")
  assert_near(undo.values.reverb_mix, 0.3, 1e-9, "the old mix is held")
  assert_near(undo.values.reverb_size, 0.8, 1e-9, "the old size is held")
  assert_near(undo.until_time, util.time() + 5, 1e-9, "S.undo.until_time")
  assert_true(local_value("undo_clock") ~= nil, "the expiry clock runs")
  assert_equal(mutation.undo(), true, "undo reports the undo")
  assert_near(params:get("reverb_mix"), 0.3, 1e-9, "the mix is back")
  assert_near(params:get("reverb_size"), 0.8, 1e-9, "the size is back")
  assert_equal(local_value("undo"), nil, "the undo ends")
  assert_equal(local_value("undo_clock"), nil, "with its expiry clock")
  assert_equal(mutation.undo(), false, "nothing more to undo")
end)

-- A set's action may change a param drawn later: a loop start's cuts a
-- length the new start leaves no room for. randomize holds every drawn
-- param's value before its first set, so the undo restores the length as it
-- was before the randomize, not as the start's action cut it
test("randomize holds every old value before its first set, so undo restores a pair an action changed (#557)", function()
  local context = load_strata(); finish_startup(context)
  local mutation = local_value("S").lib.mutation
  params:set("v2_loop_start", 0); params:set("v2_loop_length", 1)
  assert_true(mutation.randomize({ page = page_index("VOICE"), section = "probe", voice = 2, draws = {
    { id = "v2_loop_start", draw = function() return 0.6 end },    -- its action cuts the length to 0.4
    { id = "v2_loop_length", draw = function() return 0.25 end },
  } }), "randomized")
  assert_near(params:get("v2_loop_start"), 0.6, 1e-9, "the start is set")
  assert_near(params:get("v2_loop_length"), 0.25, 1e-9, "the length is set")
  assert_near(local_value("undo").values.v2_loop_length, 1, 1e-9, "the length held is the one before the randomize")
  assert_true(mutation.undo(), "undo")
  assert_near(params:get("v2_loop_start"), 0, 1e-9, "the start is back")
  assert_near(params:get("v2_loop_length"), 1, 1e-9, "the length is back whole, not cut")
end)

test("a locked voice's spec changes nothing (#557)", function()
  local context = load_strata(); finish_startup(context)
  local mutation = local_value("S").lib.mutation
  local VOICE = page_index("VOICE")
  mutation.randomize({ page = page_index("FX"), section = "delay",
    draws = { { id = "delay_mix", draw = function() return 0.2 end } } })
  local earlier = local_value("undo")
  toggle_lock(2)
  local size = params:get("v2_grain_size")
  local drawn = false
  assert_equal(mutation.randomize({ page = VOICE, section = "grain", voice = 2,
    draws = { { id = "v2_grain_size", draw = function() drawn = true; return 0.4 end } } }), false,
    "a locked voice's randomize reports nothing done")
  assert_equal(params:get("v2_grain_size"), size, "its param is unchanged")
  assert_true(not drawn, "nothing is drawn")
  assert_true(local_value("undo") == earlier, "the earlier undo stays")
  assert_equal(mutation.randomize({ page = VOICE, section = "mix", voice = 1, draws = {} }), false,
    "an empty section reports nothing done")
  assert_true(local_value("undo") == earlier, "and keeps the earlier undo")
end)

test("undo_for is true only on the same page, section and voice within 5 s (#557)", function()
  local context = load_strata(); finish_startup(context)
  local mutation = local_value("S").lib.mutation
  local VOICE, MAIN = page_index("VOICE"), page_index("MAIN")
  assert_true(not mutation.undo_for(VOICE, "grain", 2), "nothing held before a randomize")
  mutation.randomize({ page = VOICE, section = "grain", voice = 2,
    draws = { { id = "v2_grain_size", draw = function() return 0.4 end } } })
  assert_true(mutation.undo_for(VOICE, "grain", 2), "the same page, section and voice")
  assert_true(not mutation.undo_for(VOICE, "crossmod", 2), "another section")
  assert_true(not mutation.undo_for(VOICE, "grain", 1), "another voice")
  assert_true(not mutation.undo_for(MAIN, "grain", 2), "another page")
  assert_true(not undo_available(2), "MAIN's undo_available is MAIN's whole-voice undo only")
  context.set_time(util.time() + 4.9)
  assert_true(mutation.undo_for(VOICE, "grain", 2), "still at 4.9 s")
  context.set_time(util.time() + 0.1)
  assert_true(not mutation.undo_for(VOICE, "grain", 2), "not at 5 s")
  assert_equal(mutation.undo(), false, "and undo does nothing then")
  -- randomize_voice is MAIN's whole-voice spec
  randomize_voice(3)
  assert_true(mutation.undo_for(MAIN, "voice", 3) and undo_available(3), "randomize_voice holds MAIN's undo")
end)

-- The params a page randomize may set besides randomize_voice's (VOICE's
-- grain and crossmod sections, FX's), each ending the undo when edited
local PAGE_RANDOMIZED_IDS = { "v1_grain_density", "v1_grain_spread", "v1_grain_env", "v1_mod_speed",
  "v1_mod_amp_amt_1", "v1_mod_amp_amt_2", "v1_mod_amp_amt_3", "v1_mod_freq_amt_1", "v1_mod_freq_amt_2",
  "v1_mod_freq_amt_3", "master_density", "drift_amount", "filter_type", "filter_freq", "filter_res",
  "delay_time", "delay_feedback", "delay_mix", "reverb_mix", "reverb_size", "reverb_damp" }

test("an edit of a held param ends the undo (#557)", function()
  local context = load_strata(); finish_startup(context)
  local mutation = local_value("S").lib.mutation
  local FX = page_index("FX")
  for _, id in ipairs(PAGE_RANDOMIZED_IDS) do
    mutation.randomize({ page = FX, section = "probe", draws = { { id = id, draw = function() return other_value(id) end } } })
    local other = id == "reverb_damp" and "reverb_size" or "reverb_damp"
    params:set(other, other_value(other))
    assert_true(mutation.undo_for(FX, "probe", nil), id .. ": an edit of a param the undo does not hold keeps it")
    params:set(id, other_value(id))
    assert_equal(local_value("undo"), nil, "an edit of " .. id .. " ends the undo")
  end
end)

-- #538: norns' Binary:set sends no MIDI-map CC, so a binary draw goes
-- through set_binary_param and a controller mapped to it follows
test("a binary draw goes through set_binary_param, echoing to a mapped CC (#557)", function()
  local context = load_strata(); finish_startup(context)
  local mutation = local_value("S").lib.mutation
  local controller = context.midi.plug(1)
  norns.pmap.data.v1_quantize = { dev = 1, ch = 1, cc = 31, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  local function echoes()
    local values = {}
    for _, message in ipairs(controller.sent) do
      if message[2] == 31 then table.insert(values, message[3]) end
    end
    return table.concat(values, ",")
  end
  assert_equal(params:get("v1_quantize"), 0, "quantize starts off")
  mutation.randomize({ page = page_index("VOICE"), section = "variation", voice = 1,
    draws = { { id = "v1_quantize", draw = function() return 1 end } } })
  assert_equal(params:get("v1_quantize"), 1, "the draw is set")
  assert_equal(echoes(), "127", "the controller hears the randomize")
  assert_true(mutation.undo(), "undo")
  assert_equal(params:get("v1_quantize"), 0, "the old value is back")
  assert_equal(echoes(), "127,0", "and the controller hears the undo")
end)

test("a pattern spec restores the exact old steps (#557)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local mutation, SEQ = S.lib.mutation, page_index("SEQ")
  local old = { 15, 0, 8, 0, 12, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 10 }
  S.lib.sequencer.replace_pattern(3, old)
  toggle_lock(3)                                       -- lock covers params, not patterns
  math.randomseed(12)
  assert_equal(mutation.randomize({ page = SEQ, section = "pattern", voice = 3, pattern = 3 }), true,
    "a pattern spec randomizes a locked voice's pattern")
  assert_true(table.concat(S.patterns[3], ",") ~= table.concat(old, ","), "the pattern changed")
  assert_true(mutation.undo_for(SEQ, "pattern", 3), "its undo is held")
  assert_true(mutation.undo(), "undo")
  assert_equal(table.concat(S.patterns[3], ","), table.concat(old, ","), "the exact old steps are back")
  -- a pattern edit of the held voice ends the undo, one of another voice does not
  mutation.randomize({ page = SEQ, section = "pattern", voice = 3, pattern = 3 })
  mutation.note_pattern_edit(2)
  assert_true(mutation.undo_for(SEQ, "pattern", 3), "an edit of another voice's pattern keeps it")
  mutation.note_pattern_edit(3)
  assert_equal(local_value("undo"), nil, "an edit of the held voice's pattern ends it")
end)

-- Every page record with randomize_section: in each of its layout states,
-- every param its spec draws reports an edit to note_param_edit, so an edit
-- ends the undo and never comes back on it (AGENTS.md, Randomize undo). The
-- pages that randomize add the field; this test covers each one
test("every drawn param of every page's randomize_section calls note_param_edit (#557)", function()
  load_strata()
  local S = local_value("S")
  local pages = {}
  for index, name in ipairs(S.constants.UI_PAGES) do
    local record = S.registry.pages[index]
    if record.randomize_section then
      local states = { { name = "as loaded" } }
      for _, state in ipairs(record.layout_states or {}) do states[#states + 1] = state end
      pages[#pages + 1] = { index = index, name = name, states = states }
    end
  end
  assert_true(#pages >= 1 and pages[1].name == "MAIN", "MAIN randomizes")
  for _, page in ipairs(pages) do
    -- per page: one whose sections draw params must have some checked; a
    -- pattern page (its spec a pattern, SEQ) draws none
    local checked, pattern_page = 0, false
    for _, state in ipairs(page.states) do
      local context = load_strata(); finish_startup(context)
      show_page(page.name)
      if state.setup then state.setup(context) end
      local spec = local_value("S").registry.pages[page.index].randomize_section()
      if spec and spec.pattern ~= nil then pattern_page = true end
      local where = page.name .. ", " .. state.name
      local real_note = note_param_edit
      local noted = {}
      note_param_edit = function(param_id) noted[param_id] = true; return real_note(param_id) end
      local ok, problem = pcall(function()
        for _, entry in ipairs(spec and spec.draws or {}) do
          params:set(entry.id, other_value(entry.id))
          assert_true(noted[entry.id], where .. ": an edit of " .. entry.id .. " calls note_param_edit")
          checked = checked + 1
        end
      end)
      note_param_edit = real_note
      if not ok then error(problem, 0) end
    end
    assert_true(pattern_page or checked > 0,
      page.name .. ": a page that randomizes params draws some in one of its states (" .. checked .. " checked)")
  end
end)

end
