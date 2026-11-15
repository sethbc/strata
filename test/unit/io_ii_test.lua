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

-- Run steps until the queue is empty: every line sent, in order
local function drain(step, ii)
  local sent = {}
  while ii.queued() > 0 do
    for _, line in ipairs(step()) do sent[#sent + 1] = line end
  end
  return sent
end

-- What the queue holds, in order (the lines send and send_off queued)
local function queue_lines(step, ii) return drain(step, ii) end

-- n lines on device "other", each a line of its own (no off is ever owed for them)
local function fill(ii, n, from)
  local lines = {}
  for k = from or 1, (from or 1) + n - 1 do
    assert_true(ii.send("other", "cv", k, 1), "line " .. k .. " queued")
    lines[#lines + 1] = "ii.other.cv(" .. k .. ", 1)"
  end
  return lines
end

-- Ruling 24: the queue sends an off exactly when its line owes one (the line is
-- high on the device, or a send for it waits); an off is never dropped and never
-- displaces a line; a send at 48 waiting is the only loss, and its off is then not owed

test("an off for a line that is still high is queued past a full queue", function()
  -- the re-review's trace: s1's tr(12, 1) reached the ER-301; s2's cv and tr wait in a full queue
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  ii.send("er301", "tr", 12, 1)
  drain(step, ii)
  local expected = fill(ii, 46)
  ii.send("er301", "cv", 12, 2); expected[#expected + 1] = "ii.er301.cv(12, 2)"
  ii.send("er301", "tr", 12, 1); expected[#expected + 1] = "ii.er301.tr(12, 1)"
  assert_equal(ii.queued(), 48)
  assert_equal(ii.send_off("er301", "tr", 12, 0), true)
  expected[#expected + 1] = "ii.er301.tr(12, 0)"
  assert_equal(ii.queued(), 49)
  assert_equal(ii.dropped(), 0, "nothing dropped")
  assert_equal(table.concat(queue_lines(step, ii), "|"), table.concat(expected, "|"), "every line in order, the off last")
end)

test("an on dropped at a full queue owes no off, unless its line is high", function()
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  -- the pair tracked and port 7 known low: its first off went out while Strata watched it
  assert_equal(ii.send_off("er301", "tr", 7, 0), true, "the pair's first off is sent regardless")
  drain(step, ii)
  fill(ii, 48)
  assert_equal(ii.send("er301", "tr", 7, 1), false, "dropped")
  assert_equal(ii.dropped(), 1)
  assert_equal(ii.send_off("er301", "tr", 7, 0), false, "no off is owed")
  assert_equal(ii.queued(), 48, "nothing added")
  assert_equal(ii.dropped(), 1, "and not counted")
  drain(step, ii)
  ii.send("er301", "tr", 7, 1)
  drain(step, ii)  -- port 7 is high
  fill(ii, 48)
  assert_equal(ii.send("er301", "tr", 7, 1), false, "a second on dropped")
  assert_equal(ii.send_off("er301", "tr", 7, 0), true, "the earlier on is still owed its off")
  assert_equal(ii.queued(), 49)
  local sent = queue_lines(step, ii)
  assert_equal(sent[#sent], "ii.er301.tr(7, 0)")
end)

test("an off is never queued twice in a row for one line", function()
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  ii.send("er301", "tr", 3, 1)
  drain(step, ii)
  assert_equal(ii.send_off("er301", "tr", 3, 0), true)
  assert_equal(ii.send_off("er301", "tr", 3, 0), true, "owed, and already waiting")
  assert_equal(ii.queued(), 1, "one entry")
  ii.send("er301", "tr", 3, 1)
  assert_equal(ii.send_off("er301", "tr", 3, 0), true)
  assert_equal(table.concat(queue_lines(step, ii), "|"), "ii.er301.tr(3, 0)|ii.er301.tr(3, 1)|ii.er301.tr(3, 0)",
    "off, on, off")
end)

test("offs go past the bound and a send at 48 waiting is still dropped", function()
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  for k = 1, 10 do ii.send("er301", "tr", k, 1) end
  drain(step, ii)  -- ten ports high
  local expected = {}
  for k = 1, 10 do
    ii.send("er301", "tr", k, 1); expected[#expected + 1] = "ii.er301.tr(" .. k .. ", 1)"
  end
  for _, line in ipairs(fill(ii, 38)) do expected[#expected + 1] = line end
  assert_equal(ii.queued(), 48)
  for k = 1, 10 do
    assert_equal(ii.send_off("er301", "tr", k, 0), true)
    expected[#expected + 1] = "ii.er301.tr(" .. k .. ", 0)"
  end
  assert_equal(ii.queued(), 58)
  assert_equal(ii.dropped(), 0)
  assert_equal(ii.send("other", "cv", 99, 1), false, "a send past the bound")
  assert_equal(ii.dropped(), 1)
  assert_equal(ii.queued(), 58)
  assert_equal(table.concat(queue_lines(step, ii), "|"), table.concat(expected, "|"),
    "every line send answered true for, in order, then the offs")
end)

test("a line send answered true for is always sent while Strata leads", function()
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  local accepted = {}
  for k = 1, 20 do ii.send("er301", "tr", k, 1) end
  drain(step, ii)
  for k = 1, 60 do
    local line = "ii.wtape.loop(" .. k .. ")"
    if ii.send("wtape", "loop", k) then accepted[#accepted + 1] = line end
    if k % 3 == 0 then ii.send_off("er301", "tr", k % 20 + 1, 0) end
  end
  local sent, seen = queue_lines(step, ii), {}
  for _, line in ipairs(sent) do seen[line] = true end
  assert_true(#accepted > 0 and #accepted < 60, "some sends were refused at the bound")
  for _, line in ipairs(accepted) do assert_true(seen[line], line .. " was sent") end
end)

test("the lines' state is cleared with the lead", function()
  local _, record = recording_device("probe")
  local context, S, ii = started({ record })
  local step = stepper(context, S)
  S.register_note_target({ name = "probe",
    routed = function(voice) return voice == 1 end,
    note_on = function() S.lib.io_ii.send("probe", "tr", 3, 1) end,
    note_off = function() S.lib.io_ii.send_off("probe", "tr", 3, 0) end })
  lead(context, S)
  S.lib.notes.play(1, { owner = "midi", key = 60, pitch = 60, velocity = 0.5, park = true, set_own = function() end })
  drain(step, ii)
  context.crow.clear()
  set_bus(S, "off")
  assert_equal(context.crow.sent[1], "ii.probe.tr(3, 0)", "its off in the leaving sequence")
  assert_equal(ii.lines_kept(), 0, "no line state after the lead")
  set_bus(S, "strata")
  assert_equal(ii.lines_kept(), 0, "none at the new lead")
  assert_equal(ii.send_off("probe", "tr", 3, 0), true, "the pair is learned again: its first off is sent")
  drain(step, ii)
  assert_equal(ii.send_off("probe", "tr", 3, 0), false, "then the line is known low")
  assert_equal(ii.queued(), 0)
end)

-- A line made known low by a drained off (its next off is not owed)
local function known_low(step, ii, port)
  ii.send_off("er301", "tr", port, 0)
  drain(step, ii)
  assert_equal(ii.send_off("er301", "tr", port, 0), false, "port " .. port .. " is known low")
end

test("nothing a lead knew about a line is kept into the next lead", function()
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  known_low(step, ii, 9)
  set_bus(S, "off")
  set_bus(S, "strata")
  assert_equal(ii.send_off("er301", "tr", 9, 0), true, "a new lead knows nothing: the off is owed")
  assert_equal(ii.queued(), 1, "and queued")
end)

test("nothing a lead knew about a line is kept across the crow leaving", function()
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  known_low(step, ii, 9)
  context.crow.unplug()
  context.crow.plug()
  assert_true(ii.leads())
  assert_equal(ii.send_off("er301", "tr", 9, 0), true, "a new lead knows nothing: the off is owed")
  assert_equal(ii.queued(), 1, "and queued")
end)

test("a send is refused when 48 lines wait, offs included", function()
  local context, S, ii = started()
  lead(context, S)
  fill(ii, 40)
  for port = 1, 8 do assert_true(ii.send_off("er301", "tr", port, 0), "off " .. port .. " owed") end
  assert_equal(ii.queued(), 48)
  assert_equal(ii.send("other", "cv", 99, 1), false, "40 sends and 8 offs: refused")
  assert_equal(ii.dropped(), 1, "and counted")
  context, S, ii = started()
  lead(context, S)
  fill(ii, 39)
  for port = 1, 8 do ii.send_off("er301", "tr", port, 0) end
  assert_equal(ii.queued(), 47)
  assert_equal(ii.send("other", "cv", 99, 1), true, "39 sends and 8 offs: accepted")
end)

test("a TELEXo envelope note through a full queue gets the offs of the ons it sent", function()
  -- the 2e brief: on cv(n, v), env(n, 1), tr(n, 1); offs tr(n, 0), env(n, 0)
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  -- an earlier note on output 5, whole: both pairs tracked, both lines known low
  for _, command in ipairs({ "env", "tr" }) do ii.send("txo", command, 5, 1) end
  for _, command in ipairs({ "tr", "env" }) do ii.send_off("txo", command, 5, 0) end
  drain(step, ii)
  local expected = fill(ii, 46)
  assert_true(ii.send("txo", "cv", 5, 2.5)); expected[#expected + 1] = "ii.txo.cv(5, 2.5)"
  assert_true(ii.send("txo", "env", 5, 1)); expected[#expected + 1] = "ii.txo.env(5, 1)"
  assert_equal(ii.send("txo", "tr", 5, 1), false, "the trigger's on dropped")
  assert_equal(ii.send_off("txo", "tr", 5, 0), false, "so its off is not owed")
  assert_equal(ii.send_off("txo", "env", 5, 0), true, "the envelope's is")
  expected[#expected + 1] = "ii.txo.env(5, 0)"
  assert_equal(table.concat(queue_lines(step, ii), "|"), table.concat(expected, "|"))
end)

-- Ruling 24's addition: state is kept only for the (device, command) pairs
-- that have had an off this lead; a line of such a pair with no state is unknown
-- (it may have gone high before the pair was learned) and owes its first off

test("lines that never take an off leave no state", function()
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  for k = 1, 1000 do
    ii.send("jf", "play_note", -5 + k / 100, 5)
    if ii.queued() >= 40 then drain(step, ii) end
  end
  drain(step, ii)
  assert_equal(ii.lines_kept(), 0)
end)

test("a pair's first off is sent with no send before it, and the line is then known", function()
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  assert_equal(ii.send_off("er301", "tr", 9, 0), true, "the first off of (er301, tr)")
  assert_equal(table.concat(drain(step, ii), "|"), "ii.er301.tr(9, 0)")
  assert_equal(ii.send_off("er301", "tr", 9, 0), false, "nothing raised it since: not owed")
  assert_equal(ii.queued(), 0)
  assert_equal(ii.lines_kept(), 1, "one line kept")
end)

test("a pair learned while two of its sends wait gives each its off after its own send", function()
  -- both offs owed (each line has a send waiting), each sent after its own send
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  ii.send("er301", "tr", 4, 1)
  ii.send("er301", "tr", 5, 1)
  assert_equal(ii.lines_kept(), 0, "not tracked yet")
  assert_equal(ii.send_off("er301", "tr", 4, 0), true)
  assert_equal(ii.send_off("er301", "tr", 5, 0), true, "owed: its send waits")
  assert_equal(table.concat(drain(step, ii), "|"), "ii.er301.tr(4, 1)|ii.er301.tr(5, 1)|ii.er301.tr(4, 0)|ii.er301.tr(5, 0)",
    "each off after its own send")
end)

test("an on sent before its pair is learned does not use up a later on's count", function()
  -- the round-5 re-review's sequence: note 1's on before the pair is learned, note 2's after it
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  ii.send("er301", "tr", 4, 1)                                   -- note 1 on, the pair not learned
  assert_equal(ii.send_off("er301", "tr", 4, 0), true)          -- note 1 off: the pair learned
  ii.send("other", "cv", 1, 1); ii.send("other", "cv", 2, 1)    -- two fillers
  ii.send("er301", "tr", 4, 1)                                   -- note 2 on, counted
  local sent = step()                                            -- note 1 on, its off, the fillers
  assert_equal(#sent, 4)
  assert_equal(ii.queued(), 1, "note 2's on still waits")
  assert_equal(ii.send_off("er301", "tr", 4, 0), true, "note 2's off is owed")
  assert_equal(ii.queued(), 2, "and queued")
  for _, line in ipairs(drain(step, ii)) do sent[#sent + 1] = line end
  local port = {}
  for _, line in ipairs(sent) do
    if line:find("ii.er301.tr(4,", 1, true) then port[#port + 1] = line end
  end
  assert_equal(table.concat(port, "|"), "ii.er301.tr(4, 1)|ii.er301.tr(4, 0)|ii.er301.tr(4, 1)|ii.er301.tr(4, 0)",
    "port 4 raised twice and lowered twice, last lowered")
end)

test("lines raised before their pair is learned still get their offs", function()
  -- two voices on ports 1 and 2: both triggers reach the ER-301 before either note ends
  local context, S, ii = started()
  local step = stepper(context, S)
  lead(context, S)
  ii.send("er301", "tr", 1, 1)
  ii.send("er301", "tr", 2, 1)
  drain(step, ii)
  assert_equal(ii.send_off("er301", "tr", 1, 0), true, "the pair's first off")
  assert_equal(ii.send_off("er301", "tr", 2, 0), true, "port 2 is unknown, so owed")
  assert_equal(table.concat(drain(step, ii), "|"), "ii.er301.tr(1, 0)|ii.er301.tr(2, 0)", "both gates lowered")
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

test("leaving the bus sends the waiting offs at once, at most 14, and owes the rest", function()
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
  local step = stepper(context, S)
  lead(context, S)
  for k = 1, 30 do
    if k % 3 ~= 0 then ii.send("probe", "tr", k, 1) end
  end
  drain(step, ii)  -- twenty lines high, each owed an off
  local offs = {}
  for k = 1, 30 do
    if k % 3 == 0 then
      ii.send("probe", "on", k)
    else
      ii.send_off("probe", "tr", k, 0)
      offs[#offs + 1] = "ii.probe.tr(" .. k .. ", 0)"
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

-- The last line crow got for each line key of the given lines ("ii.<device>.<command>(<first>, ")
local function last_of_line(context, prefix)
  local last
  for _, line in ipairs(context.crow.sent) do
    if line:find(prefix, 1, true) == 1 then last = line end
  end
  return last
end

test("leaving the bus sends at most 15 lines at once; the offs past 14 are owed and the next lead lowers them", function()
  -- design §3.4: "inside crow's 16" (crow-ii.md §2: crow's leader queue holds 16 and drops the next);
  -- a TELEXo-like device owes two offs a note (tr and env) and releases one line an output, and a
  -- second gate device owes one; a Just Friends-like device's one release line is registered first
  local function releaser(name, lines)
    return {name = name, release = function()
      local ii = local_value("S").lib.io_ii
      for _, args in ipairs(lines) do ii.send_direct(name, (table.unpack or unpack)(args)) end
    end}
  end
  local envelopes = {}
  for n = 1, 7 do envelopes[n] = {"env_act", n, 0} end
  local context, S, ii = started({releaser("jfish", {{"mode", 0}}), releaser("tx", envelopes), {name = "gt"}})
  local step = stepper(context, S)
  assert_equal(ii.II.leave_lines, 15, "the leaving sequence's total, named")
  lead(context, S)
  local raised = {}
  for n = 1, 7 do
    for _, line in ipairs({{"tx", "tr"}, {"tx", "env"}, {"gt", "tr"}}) do
      ii.send(line[1], line[2], n, 1)
      raised[#raised + 1] = "ii." .. line[1] .. "." .. line[2] .. "(" .. n .. ", "
    end
  end
  drain(step, ii)  -- 21 lines high
  for n = 1, 7 do
    ii.send_off("tx", "tr", n, 0); ii.send_off("tx", "env", n, 0); ii.send_off("gt", "tr", n, 0)
  end
  assert_equal(ii.queued(), 21, "21 offs wait")
  context.crow.clear()
  set_bus(S, "off")
  local at_once = context.crow.sent
  assert_equal(#at_once, 15, "fourteen offs and one release line: " .. table.concat(at_once, "|"))
  assert_equal(at_once[15], "ii.jfish.mode(0)", "the first release line fits; the TELEXo-like ones are dropped")
  for index = 1, 14 do assert_true(at_once[index]:find("ii.tx.env_act", 1, true) == nil, "no env_act at " .. index) end
  assert_equal(ii.owed(), 7, "the seven offs past the fourteenth are owed")
  context.clock.run_for(1)
  assert_equal(#at_once, 15, "nothing more while nobody leads")
  set_bus(S, "strata")
  drain(step, ii)
  assert_equal(ii.owed(), 0, "the store is emptied")
  for _, prefix in ipairs(raised) do
    assert_equal(last_of_line(context, prefix), prefix .. "0)", "every raised line ends low: " .. prefix)
  end
end)

test("a line high when crow leaves, its note ending while crow is away, is lowered after ready when crow returns", function()
  -- crow-ii.md §1: a crow that leaves can send nothing; its return under strata makes the devices ready
  local device = {name = "probe", ready = function() local_value("S").lib.io_ii.send("probe", "setup", 1) end}
  local context, S, ii = started({device})
  local step = stepper(context, S)
  S.register_note_target({name = "probe",
    routed = function(voice) return voice == 1 end,
    note_on = function() S.lib.io_ii.send("probe", "tr", 3, 1) end,
    note_off = function() S.lib.io_ii.send_off("probe", "tr", 3, 0) end})
  lead(context, S)
  drain(step, ii)
  S.lib.notes.play(1, {owner = "midi", key = 60, pitch = 60, velocity = 0.5, park = true, set_own = function() end})
  assert_equal(table.concat(drain(step, ii), "|"), "ii.probe.tr(3, 1)", "the gate went high")
  context.crow.unplug()
  S.lib.notes.release(1, "midi", 60)  -- its off while crow is away: nothing to send it through
  assert_equal(ii.owed(), 1, "the off is owed")
  context.crow.clear()
  context.crow.plug()
  assert_equal(context.crow.sent[1], "crow.reset()")
  assert_equal(table.concat(drain(step, ii), "|"), "ii.probe.setup(1)|ii.probe.tr(3, 0)", "ready's line, then the low")
  assert_equal(ii.owed(), 0)

  -- an off waiting in the queue when crow leaves is owed too
  ii.send("probe", "tr", 4, 1); drain(step, ii)
  ii.send_off("probe", "tr", 4, 0)
  context.crow.unplug()
  assert_equal(ii.owed(), 1, "the waiting off is owed")
  context.crow.clear(); context.crow.plug()
  assert_equal(table.concat(drain(step, ii), "|"), "ii.probe.setup(1)|ii.probe.tr(4, 0)")

  -- a line known low whose send waited when crow left (it never reached the device) owes nothing
  ii.send_off("probe", "tr", 5, 0); drain(step, ii)  -- port 5 known low
  ii.send("probe", "tr", 5, 1)
  context.crow.unplug()
  ii.send_off("probe", "tr", 5, 0)
  assert_equal(ii.owed(), 0, "a line still low owes no off")
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
