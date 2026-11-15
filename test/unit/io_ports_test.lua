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
