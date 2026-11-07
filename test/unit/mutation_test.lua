-- test/unit/mutation_test.lua
-- Drift, randomize and gentle mutation (lib/mutation.lua)
-- Run alone: lua test/run.lua mutation

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local deep_copy = h.deep_copy

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
  toggle_freeze(1)
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
  params:set("v1_source", 5); toggle_freeze(1)
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

end
