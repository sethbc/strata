-- test/unit/io_walk_test.lua
-- The devices walk (3.9 design section 6, package 3d): a seeded walk of
-- notes against MIDI ports that leave, move and are claimed. Three synths
-- on ports 1 to 3, voice 1 plain on port 1, voice 2 plain on port 2 and
-- voice 3 in an MPE zone on port 3; a keyboard on port 6 plays them. The
-- ops start and end notes (a step's, a played key's, an MPE note's), unplug
-- and plug the synths (a namesake of synth a among them), move one in
-- SYSTEM > DEVICES with the menu's close, let a remote grid or arc claim
-- and release a port, change a route and stop the patterns. The oracle is
-- per device in the MIDI stub: never more note offs than note ons for a
-- channel and note, nothing of MIDI out's to a port while a remote holds
-- it, a claim leaves its device sounding nothing, a menu visit that leaves
-- a device on its port cuts no note a voice holds there, and at the end,
-- after cleanup(), every device has had as many offs as ons. Its
-- allowances, each counted (a walk that never meets one fails): the two
-- edges docs/notes/lua/io/midi_out.md documents (namesake, away_cut), and
-- stranded, a fault the walk found (mark_stranded, below)
-- Run alone: lua test/run.lua io_walk

return function(h)
local local_value = h.local_value

local WALK = {
  synths = {{label = "a", name = "synth a", port = 1}, {label = "b", name = "synth b", port = 2},
    {label = "c", name = "synth c", port = 3}},
  -- a second device named as synth a: norns gives a device the name it
  -- reports unless one connected has it, so the two are never connected
  -- together (lua/core/vport.lua's get_unique_device_name)
  twin = {label = "a's namesake", name = "synth a"},
  routes = {{port = 1, channel = 1}, {port = 2, channel = 2}, {port = 3, mpe = true, members = 3}},
  keys = {port = 6, name = "keys", first = 47, span = 26},
  move_ports = 5,     -- the menu moves a synth to ports 1 to 5, the voices route to 0 to 5
  place_from = 7,     -- the end check puts a device on no port at the first free port from 7
  mode_mpe = 2,       -- v<i>_out_mode: plain, mpe
  note_off_modes = 2, -- midi_note_off: latch, release
}

-- lib/io/midi_out.lua's own state table (an upvalue of its stop), as the
-- table `midi out note` of io_midi_out_test.lua reads it
local function midi_out_state(S)
  for index = 1, math.huge do
    local name, value = debug.getupvalue(S.lib.io_midi_out.stop, index)
    if name == nil then break end
    if name == "state" then return value end
  end
  error("io_midi_out has no state upvalue")
end

-- The module that sent: the innermost lib/ file on the stack ("io/midi_out",
-- "io/remote"), or "test"
local function sender()
  for level = 3, 60 do
    local info = debug.getinfo(level, "S")
    if not info then break end
    local module = info.source:match("/lib/(.-)%.lua$")
    if module then return module end
  end
  return "test"
end

local function problem(state, text) state.problems[#state.problems + 1] = text end

local function ledger(device, channel)
  device.open[channel] = device.open[channel] or {}
  return device.open[channel]
end

local function open_total(device)
  local total = 0
  for _, notes in pairs(device.open) do
    for _, count in pairs(notes) do total = total + count end
  end
  return total
end

-- A note off on a device: it closes one of the device's own note ons, or,
-- with none open there, the allowance `namesake` (midi_out.md, "Two edges
-- stay"): owed offs are kept by the device's name, so a device of the same
-- name gets the offs owed to an unplugged namesake; it is credited to that
-- namesake, which must be unplugged and have the note open
local function heard_off(state, device, channel, note)
  local open = ledger(device, channel)
  if (open[note] or 0) > 0 then
    open[note] = open[note] - 1
    if open[note] == 0 and device.stranded and device.stranded[channel] then device.stranded[channel][note] = nil end
    return
  end
  for _, other in ipairs(state.devices) do
    if other ~= device and other.name == device.name and other.stub == nil then
      local theirs = ledger(other, channel)
      if (theirs[note] or 0) > 0 then
        theirs[note] = theirs[note] - 1
        state.counts.allowed_namesake = state.counts.allowed_namesake + 1
        return
      end
    end
  end
  problem(state, device.label .. ": note_off " .. note .. " ch " .. channel .. " beyond its note ons")
end

-- The allowance `stranded`, a fault the walk found (no documented edge): a
-- note sent mid-menu to a device at a port it visits, the device moved on
-- (or back) before the close. The close tells only the ports whose device
-- changed over the visit, so a port empty before and after is told nothing
-- and the note's record stays live, naming the device, on a port it has
-- left; the note's end (or any note on that port) sets it aside, owed to
-- the device, which gets the off only at its next arrival or the next
-- menu close. After each close the walk marks each such record's channel
-- and note on its device: one note on held open there is allowed until
-- the device has its off
local function mark_stranded(state)
  for _, voice_notes in pairs(midi_out_state(state.S).notes) do
    for _, record in pairs(voice_notes) do
      for _, device in ipairs(state.devices) do
        if not record.departed and not record.held and device.stub and device.stub.port
          and record.device == device.name and record.port ~= device.stub.port then
          device.stranded[record.channel] = device.stranded[record.channel] or {}
          device.stranded[record.channel][record.note] = true
        end
      end
    end
  end
end

-- The notes a device still sounds, a problem `why`, but one note on a
-- stranded channel and note (counted)
local function still_sounding(state, device, why)
  local found = {}
  for channel, notes in pairs(device.open) do
    for note, count in pairs(notes) do
      if count == 1 and device.stranded[channel] and device.stranded[channel][note] then
        state.counts.allowed_stranded = state.counts.allowed_stranded + 1
      elseif count ~= 0 then
        found[#found + 1] = "note " .. note .. " ch " .. channel .. " (" .. count .. ")"
      end
    end
  end
  table.sort(found)
  if #found > 0 then problem(state, device.label .. ": " .. why .. ": " .. table.concat(found, ", ")) end
end

-- Every message a device's stub gets is logged, with the port, whether a
-- remote held it and the module that sent it; MIDI out's notes go to the
-- device's own ledger
local function watch(state, device, stub)
  local send = stub.send
  stub.send = function(self, data)
    send(self, data)
    local msg = state.context.midi.to_msg(self.sent[#self.sent])
    local port = self.port
    local held = port ~= nil and state.S.lib.io_remote.holds(port)
    local from = sender()
    device.log[#device.log + 1] = {msg = msg, port = port, from = from}
    if from == "io/remote" then return end
    if held then
      problem(state, device.label .. ": " .. tostring(msg.type) .. " from " .. from .. " to port " .. port
        .. ", which a remote holds")
    end
    if msg.type == "note_on" then
      local open = ledger(device, msg.ch)
      open[msg.note] = (open[msg.note] or 0) + 1
    elseif msg.type == "note_off" then
      heard_off(state, device, msg.ch, msg.note)
    end
  end
end

local function vports(state) return state.context.midi.vports end

-- Where norns puts an arriving device (lua/core/midi.lua's Midi.new and
-- update_devices): the port whose vport has its name, else the first
-- named "none"
local function arrival_port(state, name)
  for port, vport in ipairs(vports(state)) do
    if vport.name == name then return port end
  end
  for port, vport in ipairs(vports(state)) do
    if vport.name == "none" and vport.device == nil then return port end
  end
end

-- The device plugged in where norns puts it, watched from its arrival on
-- (the arrival pays its owed offs inside midi.add)
local function plug(state, device)
  local midi = state.context.midi
  local add = midi.add
  midi.add = function(stub)
    watch(state, device, stub)
    if add then add(stub) end
  end
  local ok, result = pcall(midi.plug, arrival_port(state, device.name), device.name)
  midi.add = add
  if not ok then error(result, 0) end
  device.stub = result
end

local function connected(state, device)
  if device.stub == nil then return false end
  for _, other in ipairs(state.devices) do
    if other ~= device and other.name == device.name and other.stub ~= nil then return false end
  end
  return true
end

-- SYSTEM > DEVICES' K3 (lua/core/menu/devices.lua): port `to` takes the
-- device's name, every other vport of that name becomes "none", then
-- update_devices(); a device that was on `to` is left on no port
local function place(state, device, to)
  local midi = state.context.midi
  for port, vport in ipairs(vports(state)) do
    if vport.name == device.name then midi.reassign(port, to); return end
  end
  vports(state)[to].name = device.name
  midi.update_devices()
end

local function synth_ports(state)
  local ports = {}
  for _, device in ipairs(state.devices) do
    ports[device.label] = device.stub and device.stub.port or false
  end
  return ports
end

local function key_down(state, random)
  state.context.midi.send(WALK.keys.port, {type = "note_on", ch = random(#WALK.routes),
    note = WALK.keys.first + random(WALK.keys.span), vel = 30 + random(97)})
end

local function key_up(state, random)
  local down = {}
  for channel, channel_notes in pairs(state.S.midi_state.note_voice) do
    for note in pairs(channel_notes) do down[#down + 1] = {channel, note} end
  end
  table.sort(down, function(x, y) return x[1] * 128 + x[2] < y[1] * 128 + y[2] end)
  local key = down[random(#down + 1)] or {random(#WALK.routes), WALK.keys.first + random(WALK.keys.span)}
  state.context.midi.send(WALK.keys.port, {type = "note_off", ch = key[1], note = key[2], vel = 0})
end

local function settled(state) state.context.clock.advance_until(state.S.lfo_clock) end

-- The live note records of MIDI out, as a set
local function live_records(state)
  local live = {}
  for _, notes in pairs(midi_out_state(state.S).notes) do
    for _, record in pairs(notes) do
      if not record.departed and not record.held then live[record] = true end
    end
  end
  return live
end

-- The allowance `away_cut` (midi_out.md, "Two edges stay"): a note still
-- held on a port that was settled while its device was away (a note on the
-- port starting or ending while the menu was open) is set aside, so the
-- close cuts it when the device is back on its port, though the voice
-- still holds it. Every other off the close sends a device that ends the
-- visit on its port, for a note a voice still holds, is a problem
local function check_close(state, starts, moved, marks, live_at_open)
  local notes = midi_out_state(state.S).notes
  local ends = synth_ports(state)
  for _, device in ipairs(state.devices) do
    local port = starts[device.label]
    if port and ends[device.label] == port then
      for index = marks[device.label] + 1, #device.log do
        local entry = device.log[index]
        if entry.from ~= "io/remote" and entry.msg.type == "note_off" then
          for _, voice_notes in pairs(notes) do
            for _, record in pairs(voice_notes) do
              if record.device == device.name and record.port == port and record.channel == entry.msg.ch
                and record.note == entry.msg.note then
                if record.departed and moved[device.label] and live_at_open[record] then
                  state.counts.allowed_away_cut = state.counts.allowed_away_cut + 1
                else
                  problem(state, device.label .. ": the menu's close cut note " .. record.note .. " ch "
                    .. record.channel .. ", which voice " .. record.voice .. " holds, on the port it never left")
                end
              end
            end
          end
        end
      end
    end
  end
end

local function pick(list, random) return list[random(#list)] end

local function on_port(state)
  local list = {}
  for _, device in ipairs(state.devices) do
    if device.stub and device.stub.port then list[#list + 1] = device end
  end
  return list
end

local function device_at(state, port)
  for _, device in ipairs(state.devices) do
    if device.stub and device.stub.port == port then return device end
  end
end

-- The menu opened, a synth moved to another port of 1 to 5 (a synth there
-- left on no port), maybe a synth on no port given one, keys played while
-- it is open, maybe the synth moved back, and the menu closed
local function menu_visit(state, random)
  local starts, moved, marks = synth_ports(state), {}, {}
  local live_at_open = live_records(state)
  local function note_moves()
    for label, port in pairs(synth_ports(state)) do
      if port ~= starts[label] then moved[label] = true end
    end
  end
  _menu.set_mode(true)
  local candidates = on_port(state)
  local mover = #candidates > 0 and pick(candidates, random)
  local from = mover and mover.stub.port
  if mover then
    local to = random(WALK.move_ports - 1)
    if to >= from then to = to + 1 end
    place(state, mover, to)
    note_moves()
  end
  for _, device in ipairs(state.devices) do
    if connected(state, device) and device.stub.port == nil and random(2) == 1 then
      place(state, device, random(WALK.move_ports)); note_moves()
    end
  end
  for _ = 1, random(4) - 1 do
    if random(2) == 1 then key_down(state, random) else key_up(state, random) end
  end
  if mover and random(3) > 1 and mover.stub.port ~= from then place(state, mover, from); note_moves() end
  for _, device in ipairs(state.devices) do marks[device.label] = #device.log end
  _menu.set_mode(false)
  check_close(state, starts, moved, marks, live_at_open)
  mark_stranded(state)
end

local RIG_KINDS = {"remote_grid_port", "remote_arc_port"}

local function claim(state, random)
  local remote, port = state.S.lib.io_remote, random(WALK.move_ports)
  local device = device_at(state, port)
  local was_held = remote.holds(port)
  local sounding = device and open_total(device) or 0
  state.S.lib.io_rig.set(pick(RIG_KINDS, random), port)
  if device and not was_held and remote.holds(port) then
    if sounding > 0 then state.counts.claim_sounding = state.counts.claim_sounding + 1 end
    still_sounding(state, device, "a remote's claim of port " .. port .. " left sounding")
  end
end

-- An MPE setup's first three messages, from MIDI out, among the entries
-- of a device's log from first on
local function got_setup(device, first)
  local log = device.log
  for index = first, #log - 2 do
    local x, y, z = log[index].msg, log[index + 1].msg, log[index + 2].msg
    if log[index].from == "io/midi_out" and x.type == "cc" and x.cc == 101 and x.val == 0
      and y.type == "cc" and y.cc == 100 and y.val == 6 and z.type == "cc" and z.cc == 6 and z.val > 0 then
      return true
    end
  end
  return false
end

local function release(state, random)
  local marks = {}
  for _, device in ipairs(state.devices) do marks[device] = #device.log + 1 end
  local set = {}
  for _, kind in ipairs(RIG_KINDS) do
    if state.S.lib.io_rig.get(kind) > 0 then set[#set + 1] = kind end
  end
  state.S.lib.io_rig.set(pick(#set > 0 and set or RIG_KINDS, random), 0)
  for _, device in ipairs(state.devices) do
    if got_setup(device, marks[device]) then state.counts.setup_after_release = state.counts.setup_after_release + 1 end
  end
end

-- A route's field changed: the port (two times in three one a synth is
-- on, else any of 0 to 5), the channel, the members or the mode
local ROUTE_FIELDS = {
  function(voice, random, state)
    local devices, port = on_port(state), random(WALK.move_ports + 1) - 1
    if #devices > 0 and random(3) > 1 then port = math.min(pick(devices, random).stub.port, WALK.move_ports) end
    params:set("v" .. voice .. "_out_port", port)
  end,
  function(voice, random) params:set("v" .. voice .. "_out_channel", random(4)) end,
  function(voice, random) params:set("v" .. voice .. "_out_members", random(15)) end,
  function(voice, random) params:set("v" .. voice .. "_out_mode", random(WALK.mode_mpe)) end,
}

local OPS = {
  {6, "time", function(state, random) state.context.clock.run_for(0.02 * random(25)) end},
  {4, "key down", key_down},
  {4, "key up", key_up},
  {1.5, "patterns", function(state)
    if state.S.pattern_playing then pattern_clock_stop() else pattern_clock_start() end
  end},
  {1.5, "unplug", function(state, random)
    local candidates = on_port(state)
    if #candidates == 0 then return end
    local device = pick(candidates, random)
    if open_total(device) > 0 then state.counts.outlived = state.counts.outlived + 1 end
    state.context.midi.unplug(device.stub.port)
    device.stub = nil
  end},
  {2, "plug", function(state, random)
    local candidates = {}
    for _, device in ipairs(state.devices) do
      local free = device.stub == nil
      for _, other in ipairs(state.devices) do
        if other ~= device and other.name == device.name and other.stub ~= nil then free = false end
      end
      if free then candidates[#candidates + 1] = device end
    end
    if #candidates > 0 then plug(state, pick(candidates, random)) end
  end},
  {1.5, "menu", menu_visit},
  {1.5, "claim", claim},
  {1.5, "release", release},
  {2, "route", function(state, random)
    pick(ROUTE_FIELDS, random)(random(#WALK.routes), random, state)
    settled(state)
  end},
}

-- The end check: every device on a port again (a device on no port given
-- a free one in the menu, the namesake unplugged so synth a can return,
-- the synths plugged in), then cleanup(); every device has had as many
-- note offs as note ons, but for the allowances
local function finish(state)
  local free = WALK.place_from
  _menu.set_mode(true)
  for _, device in ipairs(state.devices) do
    if device.stub and device.stub.port == nil then
      while vports(state)[free].device ~= nil or vports(state)[free].name ~= "none" do free = free + 1 end
      place(state, device, free)
    end
  end
  _menu.set_mode(false)
  mark_stranded(state)
  if state.twin.stub then state.context.midi.unplug(state.twin.stub.port); state.twin.stub = nil end
  for _, device in ipairs(state.devices) do
    if device ~= state.twin and device.stub == nil then plug(state, device) end
  end
  cleanup()
  for _, device in ipairs(state.devices) do
    still_sounding(state, device, "more note ons than offs after cleanup")
  end
  local problems = state.problems
  state.problems = {}
  return problems
end

-- The oracle's own check (and the file's plain test: h.walk registers its
-- seeds' tests itself): an off beyond a device's ons is a problem, and one
-- is credited to a namesake only while that namesake is unplugged and has
-- the note open
h.test("the devices walk's ledger names an off beyond its ons and credits a namesake only while it is away", function()
  local a = {label = "a", name = "synth a", open = {}, log = {}}
  local twin = {label = "twin", name = "synth a", open = {}, log = {}}
  local state = {devices = {a, twin}, problems = {}, counts = {allowed_namesake = 0}}
  ledger(a, 1)[60] = 1
  heard_off(state, twin, 1, 60)
  h.assert_equal(state.counts.allowed_namesake, 1, "a's off, owed by name, reached its namesake")
  h.assert_equal(open_total(a), 0, "credited to a")
  h.assert_equal(#state.problems, 0)
  a.stub = {}  -- plugged in: no longer a namesake's debt
  ledger(a, 1)[61] = 1
  heard_off(state, twin, 1, 61)
  h.assert_equal(#state.problems, 1, "an off beyond the twin's ons, a plugged in: " .. tostring(state.problems[1]))
  heard_off(state, a, 2, 62)
  h.assert_equal(#state.problems, 2, "an off a device never had the on of")
end)

h.walk({
  name = "devices: every MIDI device gets an off for each on while ports leave, move and are claimed",
  seeds = {2026, 3939, 77, 51423},
  steps = 400,
  setup = function(context, random)
    local S = local_value("S")
    local state = {context = context, S = S, devices = {}, problems = {},
      counts = {outlived = 0, claim_sounding = 0, setup_after_release = 0, allowed_namesake = 0, allowed_away_cut = 0,
        allowed_stranded = 0}}
    for _, synth in ipairs(WALK.synths) do
      state.devices[#state.devices + 1] = {label = synth.label, name = synth.name, open = {}, log = {}, stranded = {}}
    end
    state.twin = {label = WALK.twin.label, name = WALK.twin.name, open = {}, log = {}, stranded = {}}
    state.devices[#state.devices + 1] = state.twin
    for index, synth in ipairs(WALK.synths) do
      vports(state)[synth.port].name = synth.name
      plug(state, state.devices[index])
    end
    context.midi.plug(WALK.keys.port, WALK.keys.name)
    params:set("midi_device", WALK.keys.port)
    params:set("midi_note_off", random(WALK.note_off_modes))
    for voice, route in ipairs(WALK.routes) do
      params:set("v" .. voice .. "_out_port", route.port)
      if route.channel then params:set("v" .. voice .. "_out_channel", route.channel) end
      if route.mpe then
        params:set("v" .. voice .. "_out_members", route.members)
        params:set("v" .. voice .. "_out_mode", WALK.mode_mpe)
      end
      for step = 1, S.constants.PATTERN_LENGTH do
        if random(3) == 1 then
          S.patterns[voice][step] = S.constants.MAX_STEP_LEVEL
          local chord = {}
          for k = 1, random(3) do chord[k] = (k - 1) * 4 + random(3) - 2 end
          S.lib.sequencer.set_step_attr(voice, step, "notes", chord)
        end
      end
    end
    settled(state)
    pattern_clock_start()
    return state
  end,
  ops = OPS,
  after = function(state)
    local problems = state.problems
    state.problems = {}
    return problems
  end,
  finish = finish,
  -- a note that outlived its device (unplugged while it sounded), a
  -- remote's claim of a port with a note sounding, a zone's setup after a
  -- remote let its port go, and each allowance met
  reached = {"outlived", "claim_sounding", "setup_after_release", "allowed_namesake", "allowed_away_cut",
    "allowed_stranded"},
  counts = function(state) return state.counts end,
})

end
