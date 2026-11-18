-- test/unit/io_ports_test.lua
-- The MIDI ports (lib/io/ports.lua, S.lib.io_ports): the listeners on each
-- port, the hot-plug and menu changes, the handlers found installed, the
-- claims and the output vports
-- Run alone: lua test/run.lua io_ports

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value = h.load_strata, h.local_value

local function note_on(context, port, note)
  context.midi.send(port, { type = "note_on", note = note, vel = 100, ch = 1 })
end

-- The "midi ports" invariant's answer now: nil while it holds
local function ports_invariant(S)
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "midi ports" then return record.fn() end
  end
  error("no midi ports invariant")
end

test("listeners on a port run in registration order, each contained", function()
  local context = load_strata()
  local S = local_value("S")
  local ports = S.lib.io_ports
  local heard = {}
  local function listener(label)
    return function(data) heard[#heard + 1] = label .. " " .. data[2] end
  end
  assert_equal(midi.vports[2].event, nil, "no listener: no event")
  ports.listen(2, "a", listener("a"))
  ports.listen(2, "b", listener("b"))
  assert_equal(type(midi.vports[2].event), "function", "a listener: the dispatcher")
  note_on(context, 2, 60)
  assert_equal(table.concat(heard, ", "), "a 60, b 60", "in the order the names were registered")
  heard = {}
  ports.listen(2, "a", function() error("a listener's error") end)
  note_on(context, 2, 61)
  h.claim_script_errors(context, 1, "strata: midi port 2 listener a failed: ", "a listener's error")
  assert_equal(table.concat(heard, ", "), "b 61", "a raising listener: one console line, and the next still runs")
  heard = {}
  ports.listen(2, "a", listener("a2"))
  note_on(context, 2, 62)
  assert_equal(table.concat(heard, ", "), "a2 62, b 62", "the same name again keeps its place")
  heard = {}
  ports.unlisten(2, "a")
  note_on(context, 2, 63)
  assert_equal(table.concat(heard, ", "), "b 63", "unlistened: b only")
  assert_equal(ports_invariant(S), nil, "the invariant holds")
  ports.unlisten(2, "b")
  assert_equal(midi.vports[2].event, nil, "the last listener gone: no event")
  ports.unlisten(2, "b")
  assert_equal(ports.listen(17, "a", listener("a")), nil, "a port outside 1 to 16 does nothing")
  assert_equal(ports.listen(0, "a", listener("a")), nil, "nor port 0")
  ports.unlisten(17, "a")
  assert_equal(ports_invariant(S), nil, "and the invariant still holds")
end)

test("a message on another port reaches no listener", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  local heard = 0
  ports.listen(2, "a", function() heard = heard + 1 end)
  note_on(context, 3, 60)
  assert_equal(heard, 0, "port 3's note reaches nothing on port 2")
  note_on(context, 2, 60)
  assert_equal(heard, 1, "port 2's does")
end)

test("the midi ports invariant names a port whose event and listeners disagree", function()
  load_strata()
  local S = local_value("S")
  h.allow_broken_invariants("the test breaks the midi ports invariant on purpose")
  S.lib.io_ports.listen(6, "a", function() end)
  local dispatcher = midi.vports[6].event
  S.lib.io_ports.unlisten(6, "a")
  midi.vports[6].event = dispatcher
  assert_true(ports_invariant(S) ~= nil, "the dispatcher on a port with no listener is reported")
  midi.vports[6].event = nil
  S.lib.io_ports.listen(6, "a", function() end)
  midi.vports[6].event = nil
  assert_true(ports_invariant(S) ~= nil, "a listener with no event is reported")
end)

test("an on_change hook hears the port and the device's name, and nothing else", function()
  -- #758: a departure once passed a third argument (the name of the device
  -- that left), which no hook reads any more
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  local heard = {}
  ports.on_change("test", function(...)
    local port, name = ...
    heard[#heard + 1] = port .. " " .. tostring(name) .. " " .. select("#", ...)
  end)
  context.midi.plug(2, "synth a")
  assert_equal(table.concat(heard, ", "), "2 synth a 2", "an arrival: two arguments")
  heard = {}
  context.midi.unplug(2)
  assert_equal(table.concat(heard, ", "), "2 nil 2", "a departure: two arguments")
  context.midi.plug(2, "synth a")
  context.midi.plug(4, "synth b")
  heard = {}
  _menu.set_mode(true)
  context.midi.reassign(2, 3)
  context.midi.reassign(4, 2)
  _menu.set_mode(false)
  assert_equal(table.concat(heard, ", "), "2 nil 2, 4 nil 2, 2 synth b 2, 3 synth a 2",
    "a move in SYSTEM > DEVICES: departures first, then arrivals, each with two arguments")
end)

test("on_change tells of an arrival, a departure and a move made in the menu", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  local changes = {}
  ports.on_change("test", function(port, name) changes[#changes + 1] = port .. " " .. tostring(name) end)
  context.midi.plug(3, "box")
  assert_equal(table.concat(changes, ", "), "3 box", "an arrival")
  assert_equal(ports.device(3), "box", "the port's device")
  changes = {}
  context.midi.unplug(3)
  assert_equal(table.concat(changes, ", "), "3 nil", "a departure")
  assert_equal(ports.device(3), nil, "no device")
  context.midi.plug(3, "box")
  changes = {}
  _menu.set_mode(true); context.midi.reassign(3, 5)
  assert_equal(#changes, 0, "nothing until the menu closes")
  _menu.set_mode(false)
  assert_equal(table.concat(changes, ", "), "3 nil, 5 box", "the move, as the menu closes")
  assert_equal(ports.device(5), "box", "the device on its new port")
  changes = {}
  _menu.set_mode(true); _menu.set_mode(false)
  assert_equal(#changes, 0, "a menu visit that moves nothing tells nothing")
  assert_equal(ports.device(17), nil, "no device outside 1 to 16")
end)

test("a port names no device while its device's removal is told (#704)", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  context.midi.plug(2, "box")
  assert_equal(ports.claim(2, "a"), true, "a holds port 2")
  local seen = {}
  ports.on_claim("b", function(port, owner)
    if port == 2 and owner == nil then seen[#seen + 1] = "claim hook " .. tostring(ports.device(2)) end
  end)
  ports.on_change("a", function(port, name)
    if port ~= 2 or name ~= nil then return end
    seen[#seen + 1] = "change hook " .. tostring(ports.device(2))
    ports.release(2, "a")
  end)
  context.midi.unplug(2)
  assert_equal(table.concat(seen, ", "), "change hook nil, claim hook nil", "nil in the hook and in the release it runs")
  assert_equal(ports.device(2), nil, "nil after the unplug")
  context.midi.plug(2, "box")
  assert_equal(ports.device(2), "box", "plugged again: named")
end)

-- run_set contains a change hook's error (one console line, the next hook
-- runs), so this pins only that: the removal still ends normally and the next
-- device is named. The protected call in removed, whose clear a raise must
-- not skip, is reached only by the kept handler (the next test)
test("a removal hook that raises leaves the port naming its next device", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  context.midi.plug(2, "box")
  ports.on_change("bad", function(port, name) if name == nil then error("a removal hook's error") end end)
  context.midi.unplug(2)
  h.claim_script_errors(context, 1, "strata: midi change hook bad failed: ", "a removal hook's error")
  local during
  ports.on_change("bad", function(port, name) if name ~= nil then during = ports.device(port) end end)
  context.midi.plug(2, "next")
  assert_equal(during, "next", "named during its add hooks")
  assert_equal(ports.device(2), "next", "and once they return")
end)

test("a kept remove handler that raises leaves no port marked (#704)", function()
  local context = load_strata({before_init = function()
    midi.remove = function() error("a kept remove's error") end  -- found at start: the kept handler
  end})
  local ports = local_value("S").lib.io_ports
  context.midi.plug(2, "box")
  local ran, problem = pcall(context.midi.unplug, 2)
  assert_equal(ran, false, "the error surfaces, as before this task")
  assert_true(tostring(problem):find("a kept remove's error", 1, true) ~= nil, "with its own message: " .. tostring(problem))
  local during
  ports.on_change("probe", function(port, name) if name ~= nil then during = ports.device(port) end end)
  context.midi.plug(2, "next")
  assert_equal(during, "next", "named during its add hooks")
  assert_equal(ports.device(2), "next", "and once they return")
end)

test("a device moved in the menu is named at its new port while the hooks run", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  context.midi.plug(2, "box")
  local seen = {}
  ports.on_change("test", function(port, name) seen[#seen + 1] = port .. " " .. tostring(ports.device(port)) end)
  _menu.set_mode(true); context.midi.reassign(2, 5)
  _menu.set_mode(false)
  assert_equal(table.concat(seen, ", "), "2 nil, 5 box", "as before this task")
end)

test("the hot-plug handlers found installed still run, after the listeners, and come back at cleanup", function()
  local calls = {}
  local found_add = function(device) calls[#calls + 1] = "found add " .. device.name end
  local found_remove = function(device) calls[#calls + 1] = "found remove " .. device.name end
  local context = load_strata({ before_init = function()
    midi.add, midi.remove = found_add, found_remove
  end })
  local ports = local_value("S").lib.io_ports
  ports.on_change("test", function(port, name) calls[#calls + 1] = "change " .. port .. " " .. tostring(name) end)
  context.midi.plug(4, "x")
  assert_equal(table.concat(calls, ", "), "change 4 x, found add x", "an arrival: the listeners, then the found add")
  calls = {}
  context.midi.unplug(4)
  assert_equal(table.concat(calls, ", "), "change 4 nil, found remove x", "a departure: the same order")
  ports.listen(5, "a", function() end)
  cleanup()
  assert_equal(midi.add, found_add, "cleanup puts the found add back")
  assert_equal(midi.remove, found_remove, "and the found remove")
  assert_equal(midi.vports[5].event, nil, "and clears every event it set")
end)

-- #700: the nbout mod puts a facade in the global midi in each script's
-- pre-init hook (nbout lib/mod.lua:86-139): its metatable's __index gives
-- vports as a fresh copy with one more entry, and everything else from
-- norns' real module; it has no __newindex. norns' startup loaded the real
-- module (midi = require 'core/midi'), so package.loaded holds it, and its
-- hot-plug calls the real module's add and remove only. Each test here runs
-- its body through under_midi_facade, which, whatever the body does, puts
-- package.loaded back as it found it and the global midi back to the real
-- module a facade wrapped (as nbout's cleanup does), so the checks run after
-- the test see this load's ports (the grid core's tests have the same pair,
-- under_grid_facade and grid_facade)
local midi_facade_reals = setmetatable({}, {__mode = "k"})  -- facade -> the module it wraps
local function under_midi_facade(body)
  local kept_loaded = package.loaded["core/midi"]
  local ran, problem = pcall(body)
  local global = rawget(_G, "midi")
  package.loaded["core/midi"], _G.midi = kept_loaded, midi_facade_reals[global] or global
  if not ran then error(problem, 0) end
end

-- The facade over context.midi, as the global midi and with the stub module
-- in package.loaded, set up as nbout's pre-init hook does (before_init):
-- facade.fake is the facade, facade.found_add and found_remove the real
-- module's handlers when it went in. As nbout's, its vports is a fresh copy
-- at each read, with a seventeenth entry of its own (a device named "nb");
-- facade.reads counts each key read through it by lib/io/ports.lua, and
-- facade.port_reads each read of vports, devices or connect by any of the
-- script's files (strata.lua, lib/), as "<file> <key>"
local MIDI_PORT_KEYS = {vports = true, devices = true, connect = true}
local function script_file(source)
  return source:match("/lib/.+%.lua$") or source:match("/strata%.lua$")
end
local function midi_facade()
  local facade = {reads = {}, port_reads = {}}
  local function before_init(context)
    local real = context.midi
    facade.found_add, facade.found_remove = real.add, real.remove
    facade.fake = setmetatable({}, {__index = function(_, key)
      local caller = debug.getinfo(2, "S").source
      if caller:sub(-#"lib/io/ports.lua") == "lib/io/ports.lua" then
        facade.reads[key] = (facade.reads[key] or 0) + 1
      end
      local file = script_file(caller)
      if file and MIDI_PORT_KEYS[key] then facade.port_reads[#facade.port_reads + 1] = file .. " " .. key end
      if key == "vports" then
        local copy = {}
        for _, vport in ipairs(real.vports) do copy[#copy + 1] = vport end
        copy[#copy + 1] = {name = "nb", connected = true, device = {name = "nb", port = #copy + 1}}
        return copy
      end
      return real[key]
    end})
    midi_facade_reals[facade.fake] = real
    package.loaded["core/midi"] = real
    _G.midi = facade.fake
  end
  -- the keys read through the facade by the ports, as "key count" sorted
  function facade.read_keys()
    local keys = {}
    for key, count in pairs(facade.reads) do keys[#keys + 1] = tostring(key) .. " " .. count end
    table.sort(keys)
    return table.concat(keys, ", ")
  end
  return facade, before_init
end

test("under nbout's facade over midi, hot-plug still reaches the ports and cleanup puts back the found handlers", function()
  under_midi_facade(function()
    local facade, before_init = midi_facade()
    local context = load_strata({ before_init = before_init })
    local ports = local_value("S").lib.io_ports
    local changes = {}
    ports.on_change("test", function(port, name) changes[#changes + 1] = port .. " " .. tostring(name) end)
    context.midi.plug(3, "box")
    assert_equal(table.concat(changes, ", "), "3 box", "an arrival reaches the listeners")
    context.midi.unplug(3)
    assert_equal(table.concat(changes, ", "), "3 box, 3 nil", "and a departure")
    ports.listen(2, "a", function() end)
    assert_true(context.midi.vports[2].event ~= nil, "a listener's event is on norns' own vport")
    cleanup()
    assert_equal(context.midi.add, facade.found_add, "cleanup puts the found add back on norns' module")
    assert_equal(context.midi.remove, facade.found_remove, "and the found remove")
    assert_equal(next(facade.fake), nil, "the facade's own fields were never written")
  end)
end)

test("under nbout's facade the ports read norns' own vports only, and never its seventeenth", function()
  under_midi_facade(function()
    local facade, before_init = midi_facade()
    local context = load_strata({ before_init = before_init })
    local S = local_value("S")
    local ports = S.lib.io_ports
    local changes = {}
    ports.on_change("test", function(port, name) changes[#changes + 1] = port .. " " .. tostring(name) end)
    context.midi.plug(3, "box")
    changes = {}
    _menu.set_mode(true); context.midi.reassign(3, 5); _menu.set_mode(false)
    assert_equal(table.concat(changes, ", "), "3 nil, 5 box", "a move in the menu: the departure, then the arrival")
    assert_equal(ports.out(5), context.midi.vports[5], "out gives norns' own vport")
    assert_equal(ports.device(5), "box", "device names the device on it")
    assert_equal(ports.device(3), nil, "and none on the port it left")
    assert_equal(ports.out(17), nil, "no seventeenth port to send through")
    assert_equal(ports.device(17), nil, "nor a device on it")
    assert_equal(ports.listen(17, "a", function() end), nil, "nor one to listen to")
    ports.listen(5, "a", function() end)
    assert_equal(ports_invariant(S), nil, "the invariant holds")
    ports.unlisten(5, "a")
    ports.listen(6, "b", function() end)
    cleanup()
    for _, change in ipairs(changes) do assert_true(not change:match("^17 "), "port 17 is never reported") end
    assert_equal(facade.read_keys(), "", "the ports read nothing through the facade")
  end)
end)

-- #700: outside the ports module nothing reads the ports through the
-- global, so under nbout's facade the midi device param stops at norns'
-- sixteen, a MAP echo reaches the real vport, and the facade's ports are
-- never read
test("under nbout's facade the midi device param stops at norns' 16th port", function()
  under_midi_facade(function()
    local facade, before_init = midi_facade()
    local context = load_strata({ before_init = before_init })
    h.finish_startup(context)
    local _, maximum = param_range("midi_device")
    assert_equal(maximum, 16, "norns' own ports, never the facade's count")
    params:set("midi_device", 17)
    assert_equal(params:get("midi_device"), 16, "no seventeenth port")
    context.clear_engine_calls()
    context.midi.send(16, { type = "note_on", note = 69, vel = 100, ch = 1 })
    assert_equal(#context.calls_named("retrigger"), 1, "a device on port 16 plays")
    assert_equal(table.concat(facade.port_reads, ", "), "", "no file read the facade's ports")
  end)
end)

test("under nbout's facade a MAP echo reaches the mapped port's own vport", function()
  under_midi_facade(function()
    local facade, before_init = midi_facade()
    local context = load_strata({ before_init = before_init })
    h.finish_startup(context)
    local controller = context.midi.plug(3, "faders")
    norns.pmap.data.mutation_enabled = { dev = 3, ch = 1, cc = 44, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
      echo = true, value = 0 }
    set_binary_param("mutation_enabled", 1)
    local sent = controller.sent[#controller.sent]
    assert_equal(sent and table.concat(sent, " "), "176 44 127", "the CC goes to port 3's device")
    norns.pmap.data.mutation_enabled.dev = 9
    set_binary_param("mutation_enabled", 0)
    assert_equal(#controller.sent, 1, "a map to a port with no device sends nothing to it")
    assert_equal(table.concat(facade.port_reads, ", "), "", "no file read the facade's ports")
  end)
end)

test("a claimed port has one owner", function()
  load_strata()
  local ports = local_value("S").lib.io_ports
  local claims = {}
  ports.on_claim("test", function(port, owner) claims[#claims + 1] = port .. " " .. tostring(owner) end)
  assert_equal(ports.owner(4), nil, "no owner at first")
  assert_equal(ports.claim(4, "e16"), true, "a free port is claimed")
  assert_equal(ports.claim(4, "faders"), false, "a held port is refused to another name")
  assert_equal(ports.claim(4, "e16"), true, "its owner claims it again")
  assert_equal(ports.owner(4), "e16", "the owner")
  ports.release(4, "faders")
  assert_equal(ports.owner(4), "e16", "another name's release changes nothing")
  ports.release(4, "e16")
  assert_equal(ports.owner(4), nil, "the owner's release frees it")
  assert_equal(table.concat(claims, ", "), "4 e16, 4 nil", "one call per change of owner")
  assert_equal(ports.claim(17, "x"), false, "a port outside 1 to 16 is never claimed")
  assert_equal(ports.owner(17), nil, "and has no owner")
end)

test("on_settled hears a port once its arrival or release has reached every hook, a claim made by one included", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  local heard = {}
  local function note(text) heard[#heard + 1] = text end
  ports.on_settled("b", function(port) note("settled b " .. port) end)
  ports.on_change("hook", function(port, name) note("change " .. port .. " " .. tostring(name)) end)
  local take_back = true
  ports.on_claim("hook", function(port, owner)
    note("claim " .. port .. " " .. tostring(owner))
    -- a release that another name claims straight back, once, as remote's arc does
    if owner == nil and port == 5 and take_back then
      take_back = false
      ports.claim(5, "second")
    end
  end)
  ports.on_settled("a", function(port) note("settled a " .. port) end)
  context.midi.plug(3, "box")
  assert_equal(table.concat(heard, ", "), "change 3 box, settled b 3, settled a 3",
    "an arrival: after every change hook, in the order the names were registered")
  heard = {}
  context.midi.unplug(3)
  assert_equal(table.concat(heard, ", "), "change 3 nil", "nothing for a departure")
  heard = {}
  ports.claim(4, "first")
  assert_equal(table.concat(heard, ", "), "claim 4 first", "nothing for a claim")
  heard = {}
  ports.release(4, "first")
  assert_equal(table.concat(heard, ", "), "claim 4 nil, settled b 4, settled a 4", "a release, after its claim hooks")
  ports.claim(5, "first")
  heard = {}
  ports.release(5, "first")
  assert_equal(table.concat(heard, ", "), "claim 5 nil, claim 5 second, settled b 5, settled a 5",
    "a release taken straight back settles once, after the claim made inside it")
  heard = {}
  context.midi.plug(3, "box")
  _menu.set_mode(true); context.midi.reassign(3, 6); _menu.set_mode(false)
  assert_equal(table.concat(heard, ", "), "change 3 box, settled b 3, settled a 3, change 3 nil, change 6 box, settled b 6, settled a 6",
    "a move in the menu settles its arrival only")
  heard = {}
  ports.on_settled("b", function() error("a settled hook's error") end)
  ports.release(5, "second")
  h.claim_script_errors(context, 1, "strata: midi settled hook b failed: ", "a settled hook's error")
  assert_equal(table.concat(heard, ", "), "claim 5 nil, settled a 5", "a raising hook: one line, and the next still runs")
  heard = {}
  ports.release(17, "x"); ports.release(0, "x"); ports.claim(17, "x")
  assert_equal(#heard, 0, "nothing for a port outside 1 to 16")
end)

test("a reconcile settles each moved port once, after every move it tells", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  context.midi.plug(2, "synth a")
  context.midi.plug(4, "synth b")
  local heard = {}
  ports.on_change("hook", function(port, name) heard[#heard + 1] = "change " .. port .. " " .. tostring(name) end)
  ports.on_settled("hook", function(port) heard[#heard + 1] = "settled " .. port end)
  _menu.set_mode(true)
  context.midi.reassign(2, 3)
  context.midi.reassign(4, 2)
  _menu.set_mode(false)
  assert_equal(table.concat(heard, ", "), "change 2 nil, change 4 nil, change 2 synth b, change 3 synth a, settled 2, settled 3",
    "every departure and arrival told first, then each arrived port settles once, in the order told")
end)

test("a release inside a departure's hooks settles once, after every change hook", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  context.midi.plug(3, "box")
  ports.claim(3, "probe")
  local heard = {}
  ports.on_change("releaser", function(port, name)
    heard[#heard + 1] = "change releaser " .. port .. " " .. tostring(name)
    if port == 3 and name == nil then ports.release(3, "probe") end
  end)
  ports.on_change("later", function(port, name) heard[#heard + 1] = "change later " .. port .. " " .. tostring(name) end)
  ports.on_settled("hook", function(port) heard[#heard + 1] = "settled " .. port .. " " .. tostring(ports.device(port)) end)
  context.midi.unplug(3)
  assert_equal(table.concat(heard, ", "), "change releaser 3 nil, change later 3 nil, settled 3 nil",
    "the release settles once, after the departure's last hook, the port naming no device")
end)

test("a settled hook that claims or releases a port settles each port once", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  ports.claim(6, "probe")
  local heard, acted = {}, false
  ports.on_settled("actor", function(port)
    heard[#heard + 1] = "settled actor " .. port
    if port == 3 and not acted then
      acted = true
      ports.claim(3, "taker")
      ports.release(6, "probe")
    end
  end)
  ports.on_settled("watcher", function(port) heard[#heard + 1] = "settled watcher " .. port end)
  context.midi.plug(3, "box")
  assert_equal(table.concat(heard, ", "), "settled actor 3, settled watcher 3, settled actor 6, settled watcher 6",
    "port 3 settles once (its claim settles nothing); the release made there settles port 6 once, after port 3")
  assert_equal(ports.owner(3), "taker", "the claim stands")
end)

test("a release made inside a claim's hook settles after every hook of that claim has run", function()
  local context = load_strata()
  local ports = local_value("S").lib.io_ports
  ports.claim(6, "probe")
  local heard = {}
  ports.on_claim("first", function(port, owner)
    if port == 3 and owner == "taker" then
      heard[#heard + 1] = "first 3"
      ports.release(6, "probe")
    end
  end)
  ports.on_claim("second", function(port, owner)
    if port == 3 and owner == "taker" then heard[#heard + 1] = "second 3" end
  end)
  ports.on_settled("probe", function(port) heard[#heard + 1] = "settled " .. port end)
  context.midi.plug(3, "box")
  heard = {}
  assert_true(ports.claim(3, "taker"), "port 3 claimed")
  assert_equal(table.concat(heard, ", "), "first 3, second 3, settled 6",
    "port 6 settles once, after the claim's last hook; the claim settles nothing of its own")
end)

test("out gives the port's vport and nil outside 1 to 16", function()
  load_strata()
  local ports = local_value("S").lib.io_ports
  assert_equal(ports.out(3), midi.vports[3], "port 3's vport")
  assert_equal(ports.out(16), midi.vports[16], "port 16's")
  assert_equal(ports.out(0), nil, "no port 0")
  assert_equal(ports.out(17), nil, "no port 17")
  assert_equal(ports.out(1.5), nil, "no fractional port")
end)


test("a hot-plug handler that wrapped the module's still reaches the found one after cleanup", function()
  local calls = {}
  local found_add = function(device) calls[#calls + 1] = "found add " .. device.name end
  local found_remove = function(device) calls[#calls + 1] = "found remove " .. device.name end
  local context = load_strata({ before_init = function()
    midi.add, midi.remove = found_add, found_remove
  end })
  local ports = local_value("S").lib.io_ports
  ports.on_change("test", function(port, name) calls[#calls + 1] = "change " .. port .. " " .. tostring(name) end)
  -- a mod wraps the module's handlers after init
  local ours_add, ours_remove = midi.add, midi.remove
  local wrapper_add = function(device) calls[#calls + 1] = "wrapper add"; ours_add(device) end
  local wrapper_remove = function(device) calls[#calls + 1] = "wrapper remove"; ours_remove(device) end
  midi.add, midi.remove = wrapper_add, wrapper_remove
  cleanup()
  assert_equal(midi.add, wrapper_add, "cleanup leaves the wrapper installed")
  assert_equal(midi.remove, wrapper_remove, "both wrappers")
  context.midi.plug(4, "x")
  context.midi.unplug(4)
  assert_equal(table.concat(calls, ", "), "wrapper add, found add x, wrapper remove, found remove x",
    "the chain reaches the found handlers, and no listener runs after cleanup")
end)


-- The start step run again in the same instance, after a cleanup that left
-- a wrapper installed over the module's handlers: it never keeps a chain
-- that leads back to the module, so a plug runs each handler once
test("the start step run again after a wrapped cleanup never chains the module to itself", function()
  local calls = {}
  local found_add = function(device) calls[#calls + 1] = "found add " .. device.name end
  local found_remove = function(device) calls[#calls + 1] = "found remove " .. device.name end
  local context = load_strata({ before_init = function()
    midi.add, midi.remove = found_add, found_remove
  end })
  local S = local_value("S")
  S.lib.io_ports.on_change("test", function(port, name) calls[#calls + 1] = "change " .. port .. " " .. tostring(name) end)
  local ours_add, ours_remove = midi.add, midi.remove
  midi.add = function(device) calls[#calls + 1] = "wrapper add"; ours_add(device) end
  midi.remove = function(device) calls[#calls + 1] = "wrapper remove"; ours_remove(device) end
  cleanup()
  local start_step
  for _, record in ipairs(S.registry.start) do
    if record.order == S.constants.START_ORDER.io_ports then start_step = record.fn end
  end
  assert_true(start_step ~= nil, "the ports' start step is registered")
  start_step()
  local plugged = pcall(context.midi.plug, 4, "x")
  assert_true(plugged, "a plug returns")
  local unplugged = pcall(context.midi.unplug, 4)
  assert_true(unplugged, "an unplug returns")
  assert_equal(table.concat(calls, ", "),
    "wrapper add, change 4 x, found add x, wrapper remove, change 4 nil, found remove x", "each handler once")
end)

end
