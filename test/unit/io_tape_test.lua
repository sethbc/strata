-- test/unit/io_tape_test.lua
-- The tape loop (lib/io/tape.lua, S.lib.io_tape, 3.6 design §12): two softcut
-- voices loop Strata's output as one stereo tape; every call, its order and
-- its value come from docs/design/3.6-facts/checks.md §8 (softcut's write
-- path, from its C++ source) and iii-osc-nb-softcut.md §4.
-- Run alone: lua test/run.lua io_tape

return function(h)
local test, assert_true, assert_near = h.test, h.assert_true, h.assert_near
-- softcut takes numbers: 4 and 4.0 are the same value
local function assert_equal(actual, expected, message)
  if type(actual) == "number" and type(expected) == "number" then
    assert_near(actual, expected, 1e-9, message)
  else
    h.assert_equal(actual, expected, message)
  end
end
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local TAPE_PARAMS = { "tapeloop", "tapeloop_rec", "tapeloop_length", "tapeloop_rate", "tapeloop_feedback",
  "tapeloop_wear", "tapeloop_level" }

local function started()
  local context = load_strata(); finish_startup(context)
  return context, local_value("S")
end

local function value(context, name, ...) return context.softcut.value(name, ...) end

local function clear_calls(context)
  for index = #context.softcut.calls, 1, -1 do context.softcut.calls[index] = nil end
end

local function index_of(context, name, voice)
  for index, call in ipairs(context.softcut.calls) do
    if call[1] == name and call[2] == voice then return index end
  end
end

test("with the tape off softcut and the mixer are never touched", function()
  -- checks.md §8: nothing is sent to softcut until the tape is on
  local context = started()
  assert_equal(#context.softcut.calls, 0, "after init")
  assert_equal(context.audio.levels.eng_cut, nil, "the mixer's engine level")
  for _, id in ipairs(TAPE_PARAMS) do
    if id ~= "tapeloop" then
      local param = params:lookup_param(id)
      if param.controlspec then params:set(id, param.controlspec.maxval) else params:set(id, 0) end
    end
  end
  assert_equal(#context.softcut.calls, 0, "after every tape param but tapeloop moved")
  assert_equal(context.audio.levels.eng_cut, nil, "the mixer's engine level still")
  assert_equal(context.audio.levels.adc_cut, nil)
  assert_equal(context.audio.levels.tape_cut, nil)
end)

test("the tape's params are one group of seven with their defaults", function()
  started()
  assert_equal(params:get("tapeloop"), 0)
  assert_equal(params:get("tapeloop_rec"), 1)
  assert_equal(params:get("tapeloop_length"), 4)
  assert_equal(params:get("tapeloop_rate"), 1)
  assert_equal(params:get("tapeloop_feedback"), 0.5)
  assert_near(params:get("tapeloop_wear"), 0.2, 1e-9)
  assert_near(params:get("tapeloop_level"), 0.7, 1e-9)
  local range = params:lookup_param("tapeloop_length").controlspec
  assert_equal(range.minval, 0.25); assert_equal(range.maxval, 60)
  range = params:lookup_param("tapeloop_rate").controlspec
  assert_equal(range.minval, -2); assert_equal(range.maxval, 2)
  assert_equal(params:lookup_param("strata_tape").n, 7, "the group's count is its params")
end)

test("turning the tape on sets two voices up as one stereo loop", function()
  -- checks.md §8: the values and their order, verbatim
  local context = started()
  params:set("tapeloop", 1)
  for v = 1, 2 do
    assert_equal(value(context, "enable", v), 1, "enable " .. v)
    assert_equal(value(context, "buffer", v), v, "buffer " .. v)
    assert_equal(value(context, "loop", v), 1)
    assert_equal(value(context, "loop_start", v), 0)
    assert_equal(value(context, "loop_end", v), 4)
    assert_equal(value(context, "fade_time", v), 0.02)
    assert_equal(value(context, "position", v), 0)
    assert_equal(value(context, "rate_slew_time", v), 0.2)
    assert_equal(value(context, "rate", v), 1)
    assert_near(value(context, "level", v), 0.7, 1e-9)
    assert_equal(value(context, "level_input_cut", v, v), 1)
    assert_equal(value(context, "rec", v), 1)
    assert_equal(value(context, "play", v), 1)
    assert_equal(value(context, "rec_level", v), 1)
    assert_equal(value(context, "pre_level", v), 0)
    assert_near(value(context, "level_cut_cut", v, v), 0.5 / 1.2, 1e-9)
    assert_near(value(context, "pre_filter_fc", v), 6982, 1)
    assert_equal(value(context, "pre_filter_fc_mod", v), 0)
    assert_equal(value(context, "pre_filter_rq", v), 1.414)
    assert_equal(value(context, "pre_filter_lp", v), 1)
    assert_equal(value(context, "pre_filter_dry", v), 0)
    assert_equal(value(context, "post_filter_dry", v), 1)
    assert_true(index_of(context, "pre_filter_fc_mod", v) < index_of(context, "pre_filter_fc", v),
      "the mod amount is sent before the cutoff (checks.md §8)")
    assert_true(index_of(context, "buffer", v) < index_of(context, "enable", v), "enable comes last")
  end
  assert_equal(value(context, "pan", 1), -1)
  assert_equal(value(context, "pan", 2), 1)
  assert_equal(context.audio.levels.eng_cut, 1, "the loop holds Strata's output")
  assert_equal(context.audio.levels.adc_cut, 0, "and not the inputs")
  assert_equal(context.audio.levels.tape_cut, 0)
  for _, call in ipairs(context.softcut.calls) do
    assert_true(call[2] == 1 or call[2] == 2, call[1] .. " names voice 1 or 2 only")
  end
end)

test("turning the tape on makes voice 1's calls in the brief's order, then voice 2's, the mixer last", function()
  -- checks.md §8 (the order matters: fc_mod before fc; enable last)
  local context = started()
  local mixer = {}
  for _, name in ipairs({ "level_eng_cut", "level_adc_cut", "level_tape_cut" }) do
    local real = audio[name]
    audio[name] = function(level) mixer[#mixer + 1] = { name, #context.softcut.calls }; return real(level) end
  end
  params:set("tapeloop", 1)
  local voice_names = { "buffer", "pan", "loop", "loop_start", "loop_end", "fade_time", "position",
    "rate_slew_time", "rate", "level", "level_input_cut", "pre_level", "level_cut_cut", "rec_level",
    "pre_filter_fc_mod", "pre_filter_fc", "pre_filter_rq", "pre_filter_lp", "pre_filter_dry",
    "post_filter_dry", "rec", "play", "enable" }
  local sequence = {}
  for _, call in ipairs(context.softcut.calls) do sequence[#sequence + 1] = call[1] .. ":" .. tostring(call[2]) end
  local expected = {}
  for voice = 1, 2 do
    for _, name in ipairs(voice_names) do expected[#expected + 1] = name .. ":" .. voice end
  end
  assert_equal(table.concat(sequence, " "), table.concat(expected, " "), "voice 1's calls, then voice 2's")
  assert_equal(#mixer, 3, "three mixer calls")
  local total = #context.softcut.calls
  assert_equal(mixer[1][1], "level_eng_cut"); assert_equal(mixer[2][1], "level_adc_cut")
  assert_equal(mixer[3][1], "level_tape_cut")
  for _, call in ipairs(mixer) do assert_equal(call[2], total, call[1] .. " comes after every softcut call") end
end)

test("a 3.5 PSET read while the tape is on turns it off and puts the mixer back", function()
  local context = started()
  local path = context.data_dir .. "tape35on.pset"
  params:write(path)
  local file = io.open(path, "r"); local text = file:read("a"); file:close()
  local kept = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if not line:find("tapeloop", 1, true) then kept[#kept + 1] = line end
  end
  file = io.open(path, "w"); file:write(table.concat(kept, "\n")); file:close()
  params:set("tapeloop", 1)
  assert_equal(context.audio.levels.eng_cut, 1, "the loop is on")
  params:read(path)
  assert_equal(params:get("tapeloop"), 0, "the PSET has no line, so the tape goes to its default, off")
  for v = 1, 2 do assert_equal(value(context, "enable", v), 0, "voice " .. v .. " disabled") end
  assert_near(context.audio.levels.eng_cut, util.dbamp(params:get("cut_input_eng")), 1e-9, "the mixer is back")
end)

test("a PSET read while the tape runs leaves norns' input and tape out of the loop", function()
  -- norns' cut_input_* params are in a PSET (lua/core/audio.lua:875-897, saved), and their
  -- actions set the mixer: one that differs puts the input back into the loop unless re-applied
  local context = started()
  params:set("tapeloop", 1)
  params:set("cut_input_adc", -6); params:set("cut_input_tape", -3)
  local path = context.data_dir .. "tape_on_other_levels.pset"
  params:write(path)
  params:set("tapeloop", 0)
  params:set("cut_input_adc", 0); params:set("cut_input_tape", -math.huge)
  params:set("tapeloop", 1)
  assert_equal(context.audio.levels.adc_cut, 0, "the loop holds no input")
  params:read(path)
  assert_equal(params:get("tapeloop"), 1, "the tape still runs")
  assert_near(params:get("cut_input_adc"), -6, 1e-9, "norns' own param read from the PSET")
  assert_equal(context.audio.levels.adc_cut, 0, "the input stays out of the loop")
  assert_equal(context.audio.levels.tape_cut, 0, "and the tape")
  assert_equal(context.audio.levels.eng_cut, 1, "Strata's output at full")
  params:set("tapeloop", 0)
  assert_near(context.audio.levels.adc_cut, util.dbamp(-6), 1e-9, "off: norns' level, as the PSET set it")
end)

test("each param reaches both voices while the tape is on", function()
  local context = started()
  params:set("tapeloop", 1)
  audio.level_eng_cut(0.4)  -- a system mixer adjustment while the tape runs
  params:set("tapeloop_rec", 0)
  params:set("tapeloop_length", 8)
  params:set("tapeloop_rate", -1)
  params:set("tapeloop_feedback", 0.8)
  params:set("tapeloop_level", 0.3)
  for v = 1, 2 do
    assert_equal(value(context, "loop_end", v), 8)
    assert_equal(value(context, "rate", v), -1)
    assert_near(value(context, "level_cut_cut", v, v), 0.8 / 1.2, 1e-9)
    assert_near(value(context, "level", v), 0.3, 1e-9)
    assert_equal(value(context, "level_input_cut", v, v), 0, "record off closes the input")
    assert_equal(value(context, "rec_level", v), 1, "feedback is still written")
    assert_equal(value(context, "play", v), 1)
  end
  params:set("tapeloop_wear", 1)
  for v = 1, 2 do assert_near(value(context, "pre_filter_fc", v), 800, 1e-6) end
  params:set("tapeloop_wear", 0)
  for v = 1, 2 do assert_near(value(context, "pre_filter_fc", v), 12000, 1e-6) end
  params:set("tapeloop_rec", 1)
  for v = 1, 2 do assert_equal(value(context, "level_input_cut", v, v), 1, "record on reopens the input") end
  assert_equal(context.audio.levels.eng_cut, 0.4, "the record switch leaves the mixer alone")
end)

test("starting the tape with record off closes the inputs and writes the repeats", function()
  local context = started()
  params:set("tapeloop_rec", 0)
  params:set("tapeloop_feedback", 1)
  params:set("tapeloop", 1)
  for v = 1, 2 do
    assert_equal(value(context, "level_input_cut", v, v), 0, "input closed at start")
    assert_equal(value(context, "rec_level", v), 1, "feedback can reach the buffer")
    assert_equal(value(context, "level_cut_cut", v, v), 1 / 1.2)
    assert_equal(value(context, "rec", v), 1)
    assert_equal(value(context, "play", v), 1)
  end
end)

test("turning the tape off, and cleanup, disable both voices and put the mixer back", function()
  local context = started()
  params:set("cut_input_eng", -6); params:set("cut_input_adc", 0); params:set("cut_input_tape", -3)
  params:set("tapeloop", 1)
  params:set("tapeloop", 0)
  for v = 1, 2 do assert_equal(value(context, "enable", v), 0, "off disables voice " .. v) end
  assert_near(context.audio.levels.eng_cut, util.dbamp(-6), 1e-9)
  assert_near(context.audio.levels.adc_cut, 1, 1e-9)
  assert_near(context.audio.levels.tape_cut, util.dbamp(-3), 1e-9)
  -- cleanup with the tape on
  params:set("tapeloop", 1)
  assert_equal(context.audio.levels.eng_cut, 1)
  cleanup()
  for v = 1, 2 do assert_equal(value(context, "enable", v), 0, "cleanup disables voice " .. v) end
  assert_near(context.audio.levels.eng_cut, util.dbamp(-6), 1e-9)
  assert_near(context.audio.levels.tape_cut, util.dbamp(-3), 1e-9)
end)

test("the tape's four are macro targets and nothing else of it is", function()
  local _, S = started()
  local targets = {}
  for _, id in ipairs(S.lib.macros.target_ids()) do targets[id] = true end
  for _, id in ipairs({ "tapeloop_level", "tapeloop_rate", "tapeloop_feedback", "tapeloop_wear" }) do
    assert_true(targets[id], id .. " is a macro target")
  end
  for _, id in ipairs({ "tapeloop", "tapeloop_rec", "tapeloop_length" }) do
    assert_true(not targets[id], id .. " is not")
  end
end)

test("a macro's modulation reaches the loop through all four targets", function()
  -- the path an LFO or a matrix routing on a macro moves its targets through:
  -- an extra offset, then send_param_to_engine; their senders reach softcut
  -- and no engine command, so lfos_test.lua skips them (TAPE.macro_targets)
  local context, S = started()
  local wear_cutoff = 12000 * (800 / 12000) ^ 0.5
  local cases = {
    tapeloop_level = {base = 0.7, offset = -0.2, call = "level", expected = 0.5, voices = false},
    tapeloop_rate = {base = 1, offset = -0.5, call = "rate", expected = 0.5, voices = false},
    tapeloop_feedback = {base = 0.5, offset = 0.2, call = "level_cut_cut", expected = 0.7 / 1.2, voices = true},
    tapeloop_wear = {base = 0.2, offset = 0.3, call = "pre_filter_fc", expected = wear_cutoff, voices = false},
  }
  for _, id in ipairs(S.lib.io_tape.TAPE.macro_targets) do
    assert_true(cases[id] ~= nil, id .. " has a case here")
  end
  for id, case in pairs(cases) do
    params:set("tapeloop", 1)
    clear_calls(context)
    S.lib.engine_sync.set_extra_offset("macro", id, case.offset)
    send_param_to_engine(id, case.base)
    for v = 1, 2 do
      local got = case.voices and value(context, case.call, v, v) or value(context, case.call, v)
      assert_near(got, case.expected, 1e-6, id .. " reaches " .. case.call .. " of voice " .. v .. " with the offset value")
    end
    S.lib.engine_sync.set_extra_offset("macro", id, nil)
    params:set("tapeloop", 0)
    clear_calls(context)
    S.lib.engine_sync.set_extra_offset("macro", id, case.offset)
    send_param_to_engine(id, case.base)
    S.lib.engine_sync.set_extra_offset("macro", id, nil)
    assert_equal(#context.softcut.calls, 0, id .. ": with the tape off nothing is sent")
  end
end)

test("the tape's senders count no engine message and take no round-robin slot (#703)", function()
  local context, S = started()
  local sync = S.lib.engine_sync
  local ids = S.lib.io_tape.TAPE.macro_targets
  for _, id in ipairs(ids) do assert_true(not sync.reaches_engine(id), id .. " reaches no engine") end
  params:set("tapeloop", 1)
  sync.deferrable(function()
    for index = 1, 150 do send_param_to_engine("tapeloop_level", index / 200) end
  end)
  assert_equal(sync.budget_state().sent, 0, "150 tape sends count nothing")
  sync.deferrable(function() send_param_to_engine("reverb_mix", 0.3) end)
  assert_equal(sync.budget_state().pending, 0, "an engine send after them is undeferred")
  for v = 1, 2 do assert_near(value(context, "level", v), 0.75, 1e-9, "the last tape send reached softcut") end
  params:set("tapeloop", 0)
  clear_calls(context)
  sync.deferrable(function() send_param_to_engine("tapeloop_level", 0.3) end)
  assert_equal(#context.softcut.calls, 0, "with the tape off nothing is called")
  assert_equal(sync.budget_state().sent, 1, "and (from the reverb send above) nothing more is counted")
end)

test("cleanup with the tape never on touches neither softcut nor the mixer", function()
  local context = started()
  cleanup()
  assert_equal(#context.softcut.calls, 0, "softcut")
  assert_equal(context.audio.levels.eng_cut, nil, "the engine level")
  assert_equal(context.audio.levels.adc_cut, nil, "the adc level")
  assert_equal(context.audio.levels.tape_cut, nil, "the tape level")
end)

test("IO's tape section has the seven rows, the binary two reading off and on, the rest as the menu shows them", function()
  local _, S = started()
  local rows = {}
  for _, row in ipairs(S.lib.pages_io.rows()) do
    if row.section == "tape" and row.kind == "param" then rows[#rows + 1] = row end
  end
  assert_equal(#rows, 7, "seven param rows")
  local ids = {}
  for index, row in ipairs(rows) do ids[index] = row.param_id end
  assert_equal(table.concat(ids, " "), table.concat(TAPE_PARAMS, " "), "in the params' order")
  assert_equal(rows[1].shown, "off"); assert_equal(rows[2].shown, "on")
  params:set("tapeloop", 1); params:set("tapeloop_rec", 0)
  rows = {}
  for _, row in ipairs(S.lib.pages_io.rows()) do
    if row.section == "tape" and row.kind == "param" then rows[#rows + 1] = row end
  end
  assert_equal(rows[1].shown, "on"); assert_equal(rows[2].shown, "off")
  -- item 6: feedback, wear and level read as the PARAMS menu shows them
  for _, index in ipairs({ 5, 6, 7 }) do
    assert_equal(rows[index].shown, params:string(rows[index].param_id), rows[index].param_id .. " as the menu shows it")
  end
  assert_equal(rows[7].shown, "70 %")
end)

test("no tape param is in a scene", function()
  local _, S = started()
  local function snapshot()
    capture_scene(1)
    local keys = {}
    for key, v in pairs(S.scenes[1]) do keys[#keys + 1] = key .. "=" .. (type(v) == "table" and "t" or tostring(v)) end
    table.sort(keys)
    local ids = {}
    for key in pairs(S.scenes[1].params or S.scenes[1]) do ids[#ids + 1] = key end
    return table.concat(keys, ","), ids
  end
  local before = snapshot()
  for _, id in ipairs({ "tapeloop_length", "tapeloop_rate", "tapeloop_feedback", "tapeloop_wear", "tapeloop_level" }) do
    params:set(id, params:lookup_param(id).controlspec.maxval)
  end
  local after, ids = snapshot()
  assert_equal(after, before, "a scene captured with the tape params moved equals one captured before")
  for _, key in ipairs(ids) do assert_true(not tostring(key):find("^tapeloop"), "no scene field " .. tostring(key)) end
end)

test("a 3.5 PSET loads with the tape off", function()
  local context = started()
  local path = context.data_dir .. "tape35.pset"
  params:write(path)
  local file = io.open(path, "r"); local text = file:read("a"); file:close()
  local kept = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if not line:find("tapeloop", 1, true) then kept[#kept + 1] = line end
  end
  file = io.open(path, "w"); file:write(table.concat(kept, "\n")); file:close()
  params:set("tapeloop_length", 9)
  params:read(path)
  assert_equal(params:get("tapeloop"), 0, "the tape is off")
  -- params_setup.lua (#628): a Strata param the PSET has no line for goes to its default, not the session's value
  assert_equal(params:get("tapeloop_length"), 4, "the tape params with no line go to their defaults")
  assert_equal(#context.softcut.calls, 0, "softcut is untouched")
  assert_equal(context.audio.levels.eng_cut, nil)
end)

end
