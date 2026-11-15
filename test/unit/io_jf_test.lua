-- test/unit/io_jf_test.lua
-- Just Friends as a target over the ii bus (lib/io/jf.lua, S.lib.io_jf,
-- 3.6 design 6.3). Command names and argument order are crow's descriptor's
-- (docs/design/3.6-facts/crow-ii.md section 2, Just Friends): play_note(pitch
-- volts, level volts), mode(1) for synthesis, mode(0) back. S.lib.io_ii is a
-- double here (the real one is 2b's): it records its calls.
-- Run alone: lua test/run.lua io_jf

return function(h)
local test, assert_true, assert_near = h.test, h.assert_true, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local function assert_equal(actual, expected, message)
  if type(actual) == "number" and type(expected) == "number" then
    assert_near(actual, expected, 1e-9, message)
  else
    h.assert_equal(actual, expected, message)
  end
end

-- plan-common.md's Doubles: leads, send, send_off, send_direct and add_params
local function make_double(state)
  local double = {}
  function double.leads() return state.leads end
  function double.send(device, command, ...) state.calls[#state.calls + 1] = {"send", device, command, ...} end
  function double.send_off(device, command, ...) state.calls[#state.calls + 1] = {"send_off", device, command, ...} end
  function double.send_direct(device, command, ...)
    state.calls[#state.calls + 1] = {"send_direct", device, command, ...}
  end
  function double.add_params()
    local S = local_value("S")
    local count = 0
    for _, device in ipairs(S.registry.ii_devices) do count = count + device.param_count end
    params:add_group("strata_out_ii", "ii", count)
    for _, device in ipairs(S.registry.ii_devices) do device.add_params() end
  end
  return double
end

local function started(with_double)
  local state = {leads = true, calls = {}}
  local context = load_strata({before_init = function()
    if with_double then local_value("S").lib.io_ii = make_double(state) end
  end})
  finish_startup(context)
  local S = local_value("S")
  return context, S, state
end

local function target_of(S)
  for _, target in ipairs(S.registry.note_targets) do
    if target.name == "jf" then return target end
  end
end

local function device_of(S)
  for _, device in ipairs(S.registry.ii_devices) do
    if device.name == "jf" then return device end
  end
end

local function describe(call)
  local parts = {}
  for index = 1, #call do parts[index] = tostring(call[index]) end
  return table.concat(parts, " ")
end

test("with defaults, and while the bus does not lead, nothing is sent and no voice is routed", function()
  -- crow-ii.md section 2: Strata sends ii only while it leads
  local _, S, state = started(true)
  assert_equal(#state.calls, 0, "nothing at init")
  local target = target_of(S)
  assert_true(target ~= nil, "the jf target is registered")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(target.routed(voice), false, "voice " .. voice .. " off by default")
    assert_equal(params:get("v" .. voice .. "_out_jf"), 0)
  end
  assert_equal(params:get("jf_level"), 5, "the level's default")
  params:set("v2_out_jf", 1)
  assert_equal(target.routed(2), true, "on and leading")
  state.leads = false
  assert_equal(target.routed(2), false, "on but the bus does not lead")
  assert_equal(#state.calls, 0, "still nothing sent")
end)

test("a note is one play_note in volts at the level", function()
  -- crow-ii.md section 2 (Just Friends): play_note(pitch volts, level volts); 0 V = note 60
  local _, S, state = started(true)
  local target = target_of(S)
  params:set("v2_out_jf", 1)
  target.note_on(2, "s1", 72, 0.5)
  assert_equal(#state.calls, 1, "one message")
  assert_equal(state.calls[1][1] .. " " .. state.calls[1][2] .. " " .. state.calls[1][3], "send jf play_note")
  assert_equal(state.calls[1][4], 1, "volts")
  assert_equal(state.calls[1][5], 2.5, "level")
  state.calls = {}
  target.note_on(2, "s1", 60, 1)
  assert_equal(state.calls[1][4], 0, "note 60 is 0 V")
  assert_equal(state.calls[1][5], 5, "full velocity at the default level")
  state.calls = {}
  params:set("jf_level", 8)
  target.note_on(2, "s1", 60, 1)
  assert_equal(state.calls[1][5], 8, "level 8")
  state.calls = {}
  target.note_on(2, "s1", 0, 1)
  assert_equal(state.calls[1][4], -5, "the lowest pitch clamps to -5 V")
  state.calls = {}
  target.note_on(2, "s1", 130, 1)
  assert_equal(state.calls[1][4], 5, "the highest clamps to 5 V")
  state.calls = {}
  target.note_off(2, "s1")
  assert_equal(#state.calls, 0, "a note off sends nothing")
end)

test("ready puts Just Friends in its synthesis mode and release puts it back", function()
  -- crow-ii.md section 2: mode(1) picks synthesis (SPEED at sound); mode(0) ends it
  local _, S, state = started(true)
  local device = device_of(S)
  assert_true(device ~= nil, "the jf ii device is registered")
  assert_equal(device.param_count, 8, "seven routes and the level")
  device.ready()
  assert_equal(describe(state.calls[#state.calls]), "send jf mode 1")
  device.release()
  assert_equal(describe(state.calls[#state.calls]), "send_direct jf mode 0")
end)

test("the route's change ends the voice's target notes", function()
  local _, S = started(true)
  local told = {}
  local real = S.lib.io_targets
  S.lib.io_targets = {route_changed = function(voice) told[#told + 1] = voice end, volts = real.volts}
  params:set("v2_out_jf", 1)
  params:set("v2_out_jf", 0)
  S.lib.io_targets = real
  assert_equal(table.concat(told, " "), "2 2", "route_changed(2) on each change")
end)

test("its eight params are PSET-only and its rows show on the voice section", function()
  local _, S = started(true)
  local ids = {"jf_level"}
  for voice = 1, S.constants.NUM_VOICES do ids[#ids + 1] = "v" .. voice .. "_out_jf" end
  assert_equal(#ids, 8)
  for _, id in ipairs(ids) do assert_true(params.lookup[id] ~= nil, id .. " exists") end
  local function is_ours(id) return type(id) == "string" and id:find("^v%d_out_jf$") ~= nil or id == "jf_level" end
  -- not a scene field: captured with the params moved off their defaults, whatever the nesting
  for voice = 1, S.constants.NUM_VOICES do params:set("v" .. voice .. "_out_jf", 1) end
  params:set("jf_level", 9)
  capture_scene(1)
  local function search(tbl, path, seen)
    if seen[tbl] then return end
    seen[tbl] = true
    for key, value in pairs(tbl) do
      assert_true(not is_ours(key), "no scene field " .. path .. "." .. tostring(key))
      if type(value) == "table" then search(value, path .. "." .. tostring(key), seen) end
    end
  end
  search(S.scenes[1], "scene", {})
  -- not an LFO destination, a macro target or on a fader page
  for index, destination in ipairs(S.LFO_DESTINATIONS) do
    assert_true(not is_ours(destination.resolve()), "no LFO destination " .. index)
  end
  for _, id in ipairs(S.lib.macros.target_ids()) do assert_true(not is_ours(id), "no macro target " .. id) end
  for _, target in ipairs(S.registry.macro_targets) do assert_true(not is_ours(target.id), "no registered macro target") end
  local fader_ids = fader_param_ids
  for voice = 1, S.constants.NUM_VOICES do
    for _, id in ipairs(fader_ids(voice)) do assert_true(not is_ours(id), "no fader on voice " .. voice .. ": " .. id) end
    -- not drawn by a randomize (MAIN's voice spec; the mutations draw from the same lists)
    for _, draw in ipairs(S.lib.mutation.voice_spec(voice).draws) do
      assert_true(not is_ours(draw.id), "no randomize draw " .. draw.id)
    end
  end
  assert_equal(params:lookup_param("v1_out_jf").t, params.tBINARY, "a binary toggle")
  local target = target_of(S)
  local rows = target.rows(S.selected_voice)
  assert_equal(#rows, 2)
  assert_equal(rows[1].label, "jf")
  assert_equal(rows[1].param_id, "v" .. S.selected_voice .. "_out_jf")
  assert_equal(rows[1].binary[0], "off")
  assert_equal(rows[1].binary[1], "on")
  assert_equal(rows[2].label, "jf level")
  assert_equal(rows[2].param_id, "jf_level")
  assert_true(S.lib.pages_io.show_section("voice"), "the page shows the voice section")
end)

test("without the ii module the device does nothing and the page draws", function()
  -- ruling 6: on a branch with no S.lib.io_ii the params were never added
  local _, S = started(false)
  assert_equal(S.lib.io_ii, nil, "no ii module")
  local target = target_of(S)
  assert_equal(target.routed(1), false)
  assert_equal(#target.rows(1), 0, "no rows")
  assert_true(params.lookup.v1_out_jf == nil, "no param")
  assert_true(S.lib.pages_io.show_section("voice"), "the page draws")
  target.note_on(1, "s1", 60, 1)
  target.note_off(1, "s1")
  local device = device_of(S)
  device.ready()
  device.release()
end)

end
