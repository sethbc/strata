-- test/unit/io_ii_test.lua
-- The ii bus (lib/io/ii.lua, S.lib.io_ii, 3.6 design §6.1, §6.2, §6.4):
-- one leader, a bounded queue sent through crow, the leaving sequence and
-- Teletype's three calls. Every line is pinned in crow's text form
-- (docs/design/3.6-facts/crow-ii.md §2: crow receives ii["<device>"]["<command>"](args)
-- from the text ii.<device>.<command>(args)). No device is used: the crow stub
-- (test/stub_crow.lua) records each line, and each test registers recording ii
-- devices of its own.
-- Run alone: lua test/run.lua io_ii

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local HANDLERS = {
  "ii.self.call1 = function(a) tell('strata_tt1', a) end",
  "ii.self.call2 = function(a, b) tell('strata_tt2', a, b) end",
  "ii.self.call3 = function(a, b, c) tell('strata_tt3', a, b, c) end",
}
local RESET_EVENTS = "ii.reset_events(ii.self)"

-- Only these devices in the registry (other modules register theirs as
-- they load; the registry is read at each use, so this may follow init)
local function only_devices(S, list)
  for index = #S.registry.ii_devices, 1, -1 do S.registry.ii_devices[index] = nil end
  for _, entry in ipairs(list) do S.register_ii_device(entry) end
end

local function started(devices)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  only_devices(S, devices or {})
  return context, S, S.lib.io_ii
end

-- A device record that counts its ready and release calls (device.readies,
-- device.releases); fields add to the record
local function recording_device(name, fields)
  local device = { name = name, readies = 0, releases = 0 }
  local record = { name = name,
    ready = function() device.readies = device.readies + 1 end,
    release = function() device.releases = device.releases + 1 end }
  for field, value in pairs(fields or {}) do record[field] = value end
  return device, record
end

-- The lines crow got that start "ii."
local function ii_lines(context)
  local lines = {}
  for _, line in ipairs(context.crow.sent) do
    if line:sub(1, 3) == "ii." then lines[#lines + 1] = line end
  end
  return lines
end

local function lines_since(context, from)
  local lines = {}
  for index = from + 1, #context.crow.sent do lines[#lines + 1] = context.crow.sent[index] end
  return lines
end

-- Run the clocks until the LFO clock has stepped once more; the lines that
-- step sent (a hook registered after the module's runs after its own)
local function stepper(context, S)
  local steps = 0
  S.lib.lfos.on_step(function() steps = steps + 1 end)
  return function()
    local before, from = steps, #context.crow.sent
    while steps == before do context.clock.run_for(1 / 480) end
    return lines_since(context, from)
  end
end

local function set_bus(S, value) assert_true(S.lib.io_rig.set("ii_bus", value), "the rig takes ii_bus " .. value) end

local function lead(context, S)
  context.crow.plug()
  set_bus(S, "strata")
  assert_true(S.lib.io_ii.leads(), "Strata leads")
end

local function printed(fn)
  local lines, real = {}, print
  print = function(...) lines[#lines + 1] = table.concat({ ... }, " ") end
  local ok, failure = pcall(fn)
  print = real
  if not ok then error(failure, 0) end
  return lines
end

local function ii_section(S)
  for _, record in ipairs(S.registry.io_sections) do
    if record.name == "ii" then return record end
  end
end

test("under off and teletype Strata sends no ii command", function()
  -- crow-ii.md §4: monome calls crow and Teletype both leading "not currently supported", and
  -- "multiple leaders sending messages can lead to i2c not working until you power cycle"; §3: Teletype is leader only, and crow forwards CROW.C1 to C3 to
  -- norns through ii.self.call1 to call3, which these handlers set
  local device, record = recording_device("probe")
  local context, S, ii = started({ record })
  context.crow.plug()
  assert_equal(ii.send("jf", "play_note", 1, 5), false, "off: send refuses")
  assert_equal(ii.send_off("jf", "play_note", 1, 0), false)
  assert_equal(ii.send_direct("jf", "mode", 1), false)
  assert_equal(ii.queued(), 0)
  context.clock.run_for(1)
  assert_equal(device.readies, 0, "off: no ready")
  assert_equal(#ii_lines(context), 0, "off: no ii line")
  local running = S.voices[3].active
  context.crow.fire("strata_tt2", 3, 2)
  assert_equal(S.voices[3].active, running, "off: a Teletype call does nothing")

  set_bus(S, "teletype")
  assert_true(not ii.leads(), "teletype: Strata does not lead")
  assert_equal(ii.send("jf", "play_note", 1, 5), false, "teletype: send refuses")
  context.clock.run_for(1)
  assert_equal(device.readies, 0, "teletype: no ready")
  assert_equal(table.concat(ii_lines(context), "|"), table.concat(HANDLERS, "|"), "teletype: only the three handlers")
end)

test("with no crow nothing is queued or sent", function()
  local device, record = recording_device("probe")
  local context, S, ii = started({ record })
  set_bus(S, "strata")
  assert_true(not ii.leads(), "no crow: Strata does not lead")
  assert_equal(ii.send("jf", "play_note", 1, 5), false)
  assert_equal(ii.queued(), 0)
  assert_equal(device.readies, 0, "no ready without a crow")
  cleanup()
  assert_equal(device.releases, 0, "no release without a crow")
end)

test("send builds crow's text for the descriptor's command", function()
  -- crow-ii.md §2: Just Friends' play_note, the ER-301's tr, W/ tape's reverse
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  context.clock.run_for(0.2)  -- a window of its own for the three lines below
  assert_equal(ii.send("jf", "play_note", 0.5, 5), true)
  assert_equal(ii.send("er301", "tr", 3, 1), true)
  assert_equal(ii.send("wtape", "reverse"), true)
  assert_equal(ii.queued(), 3)
  local lines = step()
  assert_equal(table.concat(lines, "|"), "ii.jf.play_note(0.5, 5)|ii.er301.tr(3, 1)|ii.wtape.reverse()")
  assert_equal(S.lib.io_crow.budget_state().sent, 3, "each line counted in crow's window")
  assert_equal(ii.queued(), 0)
  ii.send("jf", "play_note", -1.25, 0.33333)
  assert_equal(step()[1], "ii.jf.play_note(-1.25, 0.3333)", "numbers through S.lib.io_crow.number")
end)

test("the queue sends 4 a step in order and drops the newest past 48", function()
  -- crow-ii.md §2: crow's own leader queue holds 16 and drops what comes when it is full, so Strata
  -- spreads its messages over the steps itself
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  for k = 1, 60 do ii.send("jf", "play_note", k, 5) end
  assert_equal(ii.queued(), 48)
  assert_equal(ii.dropped(), 12)
  local sent = {}
  for _ = 1, 12 do
    local lines = step()
    assert_equal(#lines, 4, "four lines a step")
    for _, line in ipairs(lines) do sent[#sent + 1] = line end
  end
  assert_equal(ii.queued(), 0)
  for k = 1, 48 do assert_equal(sent[k], "ii.jf.play_note(" .. k .. ", 5)", "in the order sent") end
  assert_equal(#step(), 0, "nothing more")
  assert_equal(ii_section(S).status(), "12 dropped")
end)

test("devices are made ready when Strata starts to lead and released when it stops", function()
  -- crow-ii.md §4: Just Friends was unstable when it got notes before jf.mode(1) (crow issue #220),
  -- so a device's ready comes as the lead starts; §1: crow's reset at each connect leaves the bus's
  -- devices as they were, but a crow that left can send nothing, so its return makes them ready again
  local device, record
  device, record = recording_device("probe", { release = function()
    device.releases = device.releases + 1
    assert_true(local_value("S").lib.io_ii.send_direct("probe", "mode", 0), "send_direct while still leading")
  end })
  local context, S, ii = started({ record })
  lead(context, S)
  assert_equal(device.readies, 1, "ready once")
  context.crow.unplug()
  assert_true(not ii.leads(), "a crow that leaves ends the lead")
  assert_equal(device.releases, 0, "a crow that leaves gets no release")
  context.crow.plug()
  assert_true(ii.leads())
  assert_equal(device.readies, 2, "ready again with the crow back")
  context.crow.clear()
  set_bus(S, "off")
  assert_equal(device.releases, 1, "released once")
  assert_true(not ii.leads())
  assert_equal(table.concat(context.crow.sent, "|"), "ii.probe.mode(0)", "the release's send_direct reached crow at once")
  set_bus(S, "strata")
  assert_equal(device.readies, 3)
  cleanup()
  assert_equal(device.releases, 2, "cleanup while leading releases")
end)

test("leaving the bus sends the waiting offs at once, at most 14, and drops the rest", function()
  -- crow-ii.md §2: crow's leader queue holds 16 messages and drops the next when full, so the offs
  -- sent at once stay under it with the release's line; §4: crow leads only while it has a command
  -- to send, so the offs go before the bus is given up
  local device, record
  device, record = recording_device("probe", { release = function()
    device.releases = device.releases + 1
    device.leading_at_release = local_value("S").lib.io_ii.leads()
    local_value("S").lib.io_ii.send_direct("probe", "mode", 0)
  end })
  local context, S, ii = started({ record })
  lead(context, S)
  local offs = {}
  for k = 1, 30 do
    if k % 3 == 0 then
      ii.send("probe", "on", k)
    else
      ii.send_off("probe", "off", k)
      offs[#offs + 1] = "ii.probe.off(" .. k .. ")"
    end
  end
  assert_equal(#offs, 20)
  context.crow.clear()
  set_bus(S, "off")
  local expected = {}
  for k = 1, 14 do expected[k] = offs[k] end
  expected[15] = "ii.probe.mode(0)"
  assert_equal(table.concat(context.crow.sent, "|"), table.concat(expected, "|"),
    "the first fourteen offs in order, then the release's line")
  assert_equal(ii.queued(), 0)
  assert_true(device.leading_at_release, "leads() still true at the release")
  assert_true(not ii.leads(), "and false after")
  context.crow.clear()
  context.clock.run_for(1)
  assert_equal(#context.crow.sent, 0, "nothing more on later steps")
end)

test("a note sounding when the bus leaves gets its low before the bus is given up", function()
  local _, record = recording_device("probe", { release = function()
    local_value("S").lib.io_ii.send_direct("probe", "mode", 0)
  end })
  local context, S = started({ record })
  local step = stepper(context, S)
  S.register_note_target({ name = "probe",
    routed = function(voice) return voice == 1 end,
    note_on = function() S.lib.io_ii.send("probe", "tr", 1, 1) end,
    note_off = function() S.lib.io_ii.send_off("probe", "tr", 1, 0) end })
  lead(context, S)
  S.lib.notes.play(1, { owner = "midi", key = 60, pitch = 60, velocity = 0.5, park = true, set_own = function() end })
  assert_equal(step()[1], "ii.probe.tr(1, 1)", "the note's on")
  context.crow.clear()
  set_bus(S, "off")
  assert_equal(table.concat(context.crow.sent, "|"), "ii.probe.tr(1, 0)|ii.probe.mode(0)", "the low, then the release")
end)

test("Teletype's three calls reach their actions", function()
  -- crow-ii.md §3: CROW.C1 to C3 call ii.self.call1 to call3 with whole numbers
  local context, S = started()
  context.crow.plug()
  set_bus(S, "teletype")
  capture_scene(3)
  S.current_scene = 1
  context.crow.fire("strata_tt1", 3)
  assert_equal(S.current_scene, 3, "scene 3 scheduled (quantize off: it ran)")
  if S.voices[2].active then toggle_voice(2) end
  context.crow.fire("strata_tt2", 2, 1)
  assert_true(S.voices[2].active, "voice 2 started")
  S.selected_voice = 4
  local running = S.voices[4].active
  context.crow.fire("strata_tt2", 0, 2)
  assert_equal(S.voices[4].active, not running, "the selected voice toggled")
  context.clear_engine_calls()
  context.crow.fire("strata_tt3", 1, 2, 127)
  local retriggers = context.calls_named("retrigger")
  assert_equal(#retriggers, 1)
  assert_equal(retriggers[1].args[1], 1); assert_equal(retriggers[1].args[2], 1)
  local frozen = params:get("v2_freeze")
  context.crow.fire("strata_tt3", 2, 2, 2)
  assert_equal(params:get("v2_freeze"), 1 - frozen, "v2_freeze toggled")
  context.crow.fire("strata_tt3", 3, 5, 1)
  assert_equal(params:get("v5_mute"), 1)
  context.crow.fire("strata_tt3", 4, 9, 16383)
  assert_equal(params:get("macro_9"), 1)
  local playing = S.pattern_playing
  context.crow.fire("strata_tt3", 5, 0, 2)
  assert_equal(S.pattern_playing, not playing, "the patterns toggled")
end)

test("a Teletype call out of range does nothing but print one line", function()
  local context, S = started()
  context.crow.plug()
  set_bus(S, "teletype")
  capture_scene(1)
  local function snapshot()
    local parts = { tostring(S.current_scene), tostring(S.pattern_playing) }
    for voice = 1, S.constants.NUM_VOICES do
      parts[#parts + 1] = tostring(S.voices[voice].active) .. params:get("v" .. voice .. "_freeze")
        .. params:get("v" .. voice .. "_mute")
    end
    for m = 1, S.constants.NUM_MACROS do parts[#parts + 1] = tostring(params:get("macro_" .. m)) end
    return table.concat(parts, " ")
  end
  local before = snapshot()
  context.clear_engine_calls()
  local calls = { { "strata_tt1", 0 }, { "strata_tt1", 17 }, { "strata_tt2", 8, 1 }, { "strata_tt2", 2, 3 },
    { "strata_tt3", 6, 1, 1 }, { "strata_tt3", 4, 17, 0 }, { "strata_tt3", 1, 2, 128 }, { "strata_tt3", 4, 3, 16384 },
    { "strata_tt3", 1, 2, -1 } }
  for _, call in ipairs(calls) do
    local lines = printed(function() context.crow.fire((table.unpack or unpack)(call)) end)
    assert_equal(#lines, 1, table.concat(call, " ") .. ": one line")
    assert_true(lines[1]:find("^strata: .* ignored: ") ~= nil, "Strata's own line: " .. tostring(lines[1]))
  end
  assert_equal(#context.engine_calls, 0, "no engine call")
  assert_equal(snapshot(), before, "nothing changed")
end)

test("the handlers are sent again at each crow setup and removed when the bus leaves teletype", function()
  local context, S = started()
  context.crow.plug()
  context.crow.clear()
  set_bus(S, "teletype")
  assert_equal(table.concat(context.crow.sent, "|"), table.concat(HANDLERS, "|"), "the three lines at once")
  context.crow.unplug()
  context.crow.plug()
  assert_equal(table.concat(context.crow.sent, "|"), table.concat(HANDLERS, "|") .. "|crow.reset()|"
    .. table.concat(HANDLERS, "|"), "after crow's reset, the three again")
  assert_equal(context.crow.function_assignments, 0, "no function through the proxy")
  context.crow.clear()
  set_bus(S, "off")
  assert_equal(table.concat(context.crow.sent, "|"), RESET_EVENTS)
  set_bus(S, "teletype")
  set_bus(S, "strata")
  for _, line in ipairs(context.crow.sent) do
    assert_true(not line:find("call4", 1, true) and not line:find("query", 1, true), "no call4 or query: " .. line)
  end
  assert_equal(context.crow.sent[#context.crow.sent], RESET_EVENTS, "teletype to strata removes them too")
end)

test("the group is the devices' params, and absent with none", function()
  local function add(prefix, count)
    return function()
      for k = 1, count do params:add_number(prefix .. k, prefix .. k, 0, 1, 0) end
    end
  end
  load_strata({ before_init = function()
    only_devices(local_value("S"), { { name = "a", param_count = 3, add_params = add("probe_a", 3) },
      { name = "b", param_count = 2, add_params = add("probe_b", 2) } })
  end })
  assert_equal(params:lookup_param("strata_out_ii").n, 5)
  local first = params.lookup["strata_out_ii"]
  assert_equal(params.lookup["probe_a1"], first + 1, "a's params follow the group")
  assert_equal(params.lookup["probe_b2"], first + 5, "then b's")
  load_strata({ before_init = function() only_devices(local_value("S"), { { name = "c" } }) end })
  assert_equal(params.lookup["strata_out_ii"], nil, "no group when the count is 0")
end)

-- The lines printed so far that contain text
local function printed_with(context, text)
  local lines = {}
  for _, line in ipairs(context.printed) do
    if line:find(text, 1, true) then lines[#lines + 1] = line end
  end
  return lines
end

test("a device whose add_params raises leaves the group whole and the next device's params added", function()
  local context = load_strata({ before_init = function()
    only_devices(local_value("S"), {
      { name = "a", param_count = 3, add_params = function()
        params:add_number("probe_a1", "probe a1", 0, 1, 0)
        error("a's second param")
      end },
      { name = "b", param_count = 2, add_params = function()
        for k = 1, 2 do params:add_number("probe_b" .. k, "probe b" .. k, 0, 1, 0) end
      end } })
  end })
  finish_startup(context)
  h.claim_script_errors(context, 1, "strata: ii device a add_params failed: ", "a's second param")
  assert_equal(params:lookup_param("strata_out_ii").n, 5, "the group keeps the summed count")
  local first = params.lookup["strata_out_ii"]
  assert_equal(params.lookup["probe_a1"], first + 1)
  for n = 1, 2 do
    local id = "a_unused_" .. n
    assert_equal(params.lookup[id], first + 1 + n, id .. " fills a's place")
    assert_true(params:lookup_param(id).hidden, id .. " is hidden")
  end
  assert_equal(params.lookup["probe_b1"], first + 4, "b's params follow, all there")
  assert_equal(params.lookup["probe_b2"], first + 5)
  local lines = printed_with(context, "ii device a added")
  assert_equal(#lines, 1, "one line names the device and the two counts")
  assert_equal(lines[1], "strata: ii device a added 1 of its 3 params: 2 hidden in their place")
end)

test("a device that adds more params than it declares prints its line", function()
  local context = load_strata({ before_init = function()
    only_devices(local_value("S"), {
      -- two separators past its count: the stub refuses any other param after a full group, as a
      -- wrong count would put it outside the group on norns' menu
      { name = "big", param_count = 2, add_params = function()
        for k = 1, 2 do params:add_number("probe_big" .. k, "probe big" .. k, 0, 1, 0) end
        for k = 3, 4 do params:add_separator("probe_big" .. k, "probe big" .. k) end
      end } })
  end })
  finish_startup(context)
  assert_equal(params:lookup_param("strata_out_ii").n, 2)
  local lines = printed_with(context, "ii device big added")
  assert_equal(#lines, 1)
  assert_equal(lines[1], "strata: ii device big added 4 params, more than its 2: the out ii group ends before the last 2")
end)

test("the bus row reads off, strata leads and teletype leads as it is turned on the page", function()
  local context, S = started()
  h.show_page("IO")
  assert_true(S.lib.pages_io.show_section("ii"))
  local function shown()
    local row = S.lib.pages_io.rows()[S.io_cursor]
    assert_equal(row.key, "ii_bus", "the cursor is on the bus row")
    return row.shown
  end
  assert_equal(shown(), "off")
  enc(3, 1); assert_equal(shown(), "strata leads")
  enc(3, 1); assert_equal(shown(), "teletype leads")
  enc(3, -2); assert_equal(shown(), "off")
end)

test("a second crow setup while Strata leads makes no device ready again", function()
  -- norns keeps one crow: a second one plugged in calls norns.crow.add again with no remove (crow-ii.md §1)
  local device, record = recording_device("probe")
  local context, S, ii = started({ record })
  lead(context, S)
  ii.send("probe", "on", 1)
  context.crow.plug()
  assert_true(ii.leads())
  assert_equal(device.readies, 1, "ready once")
  assert_equal(ii.queued(), 1, "the queue kept")
end)

test("the section's status is redrawn when the crow leaves while IO shows it", function()
  local context, S = started()
  context.crow.plug()
  h.show_page("IO")
  S.lib.pages_io.show_section("ii")
  h.assert_drawn_on_next_frame(context, nil, "the crow leaving", function() context.crow.unplug() end)
  assert_true(h.screen_shows(context, "[--]"), "the title shows [--]")
end)

test("IO's ii section: the bus leader row and its status", function()
  local context, S, ii = started()
  local section = ii_section(S)
  assert_true(section ~= nil, "the ii section")
  local rows = section.rows()
  assert_equal(#rows, 1)
  assert_equal(rows[1].kind, "rig"); assert_equal(rows[1].key, "ii_bus"); assert_equal(rows[1].label, "bus leader")
  assert_equal(section.status(), "[--]", "no crow")
  context.crow.plug()
  assert_equal(section.status(), nil, "a crow, nothing dropped")
end)

end
