-- test/unit/io_walk_test.lua
-- The devices walk (3.9 design section 6, package 3d): a seeded walk of
-- notes against MIDI ports that leave, move and are claimed. Three synths
-- on ports 1 to 3, voice 1 plain on port 1, voice 2 plain on port 2 and
-- voice 3 in an MPE zone on port 3; a keyboard on port 6 plays them. The
-- ops start and end notes (a step's, a played key's, an MPE note's), unplug
-- and plug the synths (a namesake of synth a among them), move one in
-- SYSTEM > DEVICES with the menu's close, let a remote grid or arc claim
-- and release a port, change a route and stop the patterns. The oracle is
-- per device in the MIDI stub, and decided from the walk's own log (what
-- each device got, at which port, and the claims, moves and keys the walk
-- made), never from the modules' state: never more note offs than note
-- ons for a channel and note, nothing of MIDI out's to a port a remote
-- holds, the remote's holds agreeing with the walk's claims, a claim
-- leaves its device sounding nothing, a menu's close sends a device that
-- ends the visit on its port no off but for a note from a port the close
-- tells gone or under an allowance, and at the end, after cleanup(), every
-- device has had as many offs as ons. Its allowances, each counted (a walk
-- that never meets one fails): the two edges docs/notes/lua/io/midi_out.md
-- documents (namesake, away_cut), and two faults the walk found: stranded
-- (#988, mark_stranded) and held_dropped (#996, mark_held_dropped)
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
  note_off_release = 2,
  cut = 1,            -- engine.noteOff's third argument: 1 cuts
  -- the rig's remote ports, in lib/io/remote.lua's KINDS order (the grid
  -- claims a port both name first)
  rig_kinds = {"remote_grid_port", "remote_arc_port"},
  -- the remote's ask for the hello (lib/io/remote.lua's PROTOCOL: CC
  -- version, 2, value 0, on hello_channel 1), sent right after a claim
  remote_ask = {cc = 2, val = 0, ch = 1},
}

-- The module that sent: the innermost frame whose source is a file under
-- the script's lib/ folder, from the repository's root as the includes
-- name it ("io/midi_out", "io/remote"), or "test"
local function sender(state)
  local prefix = state.lib_prefix
  for level = 3, 60 do
    local info = debug.getinfo(level, "S")
    if not info then break end
    if info.source:sub(1, #prefix) == prefix then return (info.source:sub(#prefix + 1):gsub("%.lua$", "")) end
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

-- A device's notes the walk excuses from its balance until their off
-- comes, each with its allowance's name (`stranded`, `held_dropped`)
local function excused(device, channel, note)
  return device.stranded[channel] and device.stranded[channel][note]
end

local function excuse(device, channel, note, allowance)
  device.stranded[channel] = device.stranded[channel] or {}
  device.stranded[channel][note] = device.stranded[channel][note] or allowance
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
    if open[note] == 0 and device.stranded[channel] then device.stranded[channel][note] = nil end
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

-- The notes a device still sounds, a problem `why`, but one note on an
-- excused channel and note (counted under its allowance)
local function still_sounding(state, device, why)
  local found = {}
  for channel, notes in pairs(device.open) do
    for note, count in pairs(notes) do
      local allowance = count == 1 and excused(device, channel, note)
      if allowance then
        state.counts["allowed_" .. allowance] = state.counts["allowed_" .. allowance] + 1
      elseif count ~= 0 then
        found[#found + 1] = "note " .. note .. " ch " .. channel .. " (" .. count .. ")"
      end
    end
  end
  table.sort(found)
  if #found > 0 then problem(state, device.label .. ": " .. why .. ": " .. table.concat(found, ", ")) end
end

local function vports(state) return state.context.midi.vports end

local function device_at(state, port)
  for _, device in ipairs(state.devices) do
    if device.stub and device.stub.port == port then return device end
  end
end

-- The walk's own record of the remotes' claims: state.rig[kind] is the
-- port the walk set (the rig's), state.claimed[kind] the port it holds.
-- A kind holds its rig port from the moment a telling finds a device there
-- that the other kind does not hold (its set, the device's arrival, the
-- other's release) until the device there is told gone (an unplug, or a
-- menu's close finding another holder) or the rig moves it
local function held(state, port)
  for _, kind in ipairs(WALK.rig_kinds) do
    if state.claimed[kind] == port then return true end
  end
  return false
end

local function connect_all(state)
  for _, kind in ipairs(WALK.rig_kinds) do
    local port = state.rig[kind]
    if state.claimed[kind] == nil and port > 0 and device_at(state, port) and not held(state, port) then
      state.claimed[kind] = port
    end
  end
end

-- The remote's ask on port: the first kind (in KINDS order) whose rig port
-- it is and that holds none has claimed it
local function claim_on_ask(state, port)
  if held(state, port) then return end
  for _, kind in ipairs(WALK.rig_kinds) do
    if state.claimed[kind] == nil and state.rig[kind] == port then
      state.claimed[kind] = port
      return
    end
  end
end

local function let_go(state, port)
  for _, kind in ipairs(WALK.rig_kinds) do
    if state.claimed[kind] == port then state.claimed[kind] = nil end
  end
end

-- Every message a device's stub gets is logged, with the port and the
-- module that sent it; MIDI out's notes go to the device's own ledger, and
-- one of its messages to a port the walk's claims hold is a problem
local function watch(state, device, stub)
  local send = stub.send
  stub.send = function(self, data)
    send(self, data)
    local msg = state.context.midi.to_msg(self.sent[#self.sent])
    local port, from = self.port, sender(state)
    device.log[#device.log + 1] = {msg = msg, port = port, from = from}
    if from == "io/remote" then
      -- the remote asks for the hello right after its claim returns, so its
      -- claim is the walk's from here, inside the telling that made it
      local ask = WALK.remote_ask
      if port ~= nil and msg.type == "cc" and msg.cc == ask.cc and msg.val == ask.val and msg.ch == ask.ch then
        claim_on_ask(state, port)
      end
      return
    end
    if port ~= nil and held(state, port) then
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
-- (the arrival pays its owed offs inside midi.add); a remote whose rig
-- port it is claims it once it has arrived
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
  connect_all(state)
end

local function unplug(state, device)
  let_go(state, device.stub.port)
  state.context.midi.unplug(device.stub.port)
  device.stub = nil
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

-- Each port's device (its label), 1 to 16
local function holders(state)
  local found = {}
  for port = 1, #vports(state) do
    local device = device_at(state, port)
    found[port] = device and device.label or false
  end
  return found
end

local function log_marks(state)
  local marks = {}
  for _, device in ipairs(state.devices) do marks[device.label] = #device.log end
  return marks
end

-- A key on a random channel (voice 1 to 3), and its channel
local function key_down(state, random, channel)
  channel = channel or random(#WALK.routes)
  state.context.midi.send(WALK.keys.port, {type = "note_on", ch = channel,
    note = WALK.keys.first + random(WALK.keys.span), vel = 30 + random(97)})
  return channel
end

local function key_up(state, random)
  local down = {}
  for channel, channel_notes in pairs(state.S.midi_state.note_voice) do
    for note in pairs(channel_notes) do down[#down + 1] = {channel, note} end
  end
  table.sort(down, function(x, y) return x[1] * 128 + x[2] < y[1] * 128 + y[2] end)
  local held_key = down[random(#down + 1)]
  local key = held_key or {random(#WALK.routes), WALK.keys.first + random(WALK.keys.span)}
  state.context.midi.send(WALK.keys.port, {type = "note_off", ch = key[1], note = key[2], vel = 0})
  return key[1], held_key ~= nil
end

local function settled(state) state.context.clock.advance_until(state.S.lfo_clock) end

local function pick(list, random) return list[random(#list)] end

local function on_port(state)
  local list = {}
  for _, device in ipairs(state.devices) do
    if device.stub and device.stub.port then list[#list + 1] = device end
  end
  return list
end

-- The last note on from MIDI out to the device for channel and note in
-- its log before index, and where it is in the log
local function last_on(device, channel, note, before)
  for index = before - 1, 1, -1 do
    local entry = device.log[index]
    if entry.from == "io/midi_out" and entry.msg.type == "note_on" and entry.msg.ch == channel
      and entry.msg.note == note then
      return entry, index
    end
  end
end

-- A menu visit: the walk's record of it (the holders, ports and log marks
-- at its open; each key played while it was open, with where every device
-- was then)
local function open_menu(state)
  _menu.set_mode(true)
  return {holders = holders(state), starts = synth_ports(state), marks = log_marks(state), keys = {}}
end

-- A key played while the menu is open: where every device was then, and
-- the ports of the voices whose notes it started or ended there. Its own
-- voice's (its channel's) route, but for a key up that ends nothing: one
-- that releases no held key, or any key up with the note off mode latch
-- (lib/midi_in.lua's end_key keeps a latched note sounding). And the route
-- of each voice the engine was told to cut a note of during the key (a
-- full pool's oldest held extra note anywhere, lib/notes.lua's play, or the
-- voice's note cap): the walk reads the engine stub's calls, not a module
local function play_in_menu(state, visit, random, toward, key_is_down)
  local calls = state.context.engine_calls
  local first = #calls + 1
  local down = key_is_down or random(2) == 1
  local channel, released
  if down then channel = key_down(state, random, toward) else channel, released = key_up(state, random) end
  local routes = {}
  local function route_of(voice) routes[params:get("v" .. voice .. "_out_port")] = true end
  if down or (released and params:get("midi_note_off") == WALK.note_off_release) then route_of(channel) end
  for index = first, #calls do
    local call = calls[index]
    if call.name == "noteOff" and call.args[3] == WALK.cut then route_of(call.args[1] + 1) end
  end
  visit.keys[#visit.keys + 1] = {ports = synth_ports(state), marks = log_marks(state), routes = routes}
end

-- Edge 1's condition, from the walk's own keys: a key played while the
-- menu was open, after the log's index (the note's on), while the device
-- was away from its start port, that started or ended a note of a voice
-- routed to that port (which settles the port)
local function played_while_away(visit, device, start, after)
  for _, key in ipairs(visit.keys) do
    if key.ports[device.label] ~= start and key.marks[device.label] >= after and key.routes[start] then
      return true
    end
  end
  return false
end

-- Whether the close tells port's device gone: it had one at the open, and
-- another (or none) at the close (lib/io/ports.lua's reconcile: departures
-- first; only a departure sets a port's notes aside)
local function told_gone(visit, now, port)
  return visit.holders[port] ~= false and now[port] ~= visit.holders[port]
end

-- A menu's close sends a device that ends the visit on the port it began
-- it on a note off only for a note it got at another port that the close
-- tells gone (that port's device at the open left it), or under an
-- allowance: `away_cut` (midi_out.md, "Two edges stay": a note on a port
-- that was settled while its device was away, by a key played while the
-- menu was open, is set aside, so the close cuts it when the device is
-- back, though the voice may still hold it) or `stranded` (#988: a
-- stranded note's off, paid at a later close)
local function check_close(state, visit, now, close_marks, stranded_before)
  local ends = synth_ports(state)
  for _, device in ipairs(state.devices) do
    local start = visit.starts[device.label]
    if start and ends[device.label] == start then
      for index = close_marks[device.label] + 1, #device.log do
        local entry = device.log[index]
        local channel, note = entry.msg.ch, entry.msg.note
        if entry.from == "io/midi_out" and entry.msg.type == "note_off" then
          local on, at = last_on(device, channel, note, close_marks[device.label] + 1)
          local allowance = stranded_before[device.label][channel .. " " .. note]
          if on and on.port ~= start and told_gone(visit, now, on.port) then
            state.counts.told_gone = state.counts.told_gone + 1
          elseif allowance then
            state.counts["allowed_" .. allowance] = state.counts["allowed_" .. allowance] + 1
          elseif on and on.port == start and played_while_away(visit, device, start, at) then
            state.counts.allowed_away_cut = state.counts.allowed_away_cut + 1
          else
            problem(state, device.label .. ": the menu's close sent note_off " .. note .. " ch " .. channel
              .. " to it on port " .. start .. ", which it ended the visit on, though it got the note on port "
              .. (on and tostring(on.port) or "(none)") .. ", which the close tells nothing, and no key was played"
              .. " while it was away from there")
          end
        end
      end
    end
  end
end

-- The allowance `stranded`, #988 (a fault the walk found, no documented
-- edge): a note sent mid-menu to a device at a port it visits, the device
-- moved on (or back) before the close. The close tells only the ports
-- whose device changed over the visit, so a port whose holder at the close
-- is its holder at the open is told nothing and the note stays on a port
-- its device has left; its end (or any note on that port) sets it aside,
-- owed to the device, which gets the off only at its next arrival or the
-- next menu close. Decided from the walk's own log: a note on sent to the
-- device mid-visit at port P, still open at the close, with the device not
-- on P at the close and P's holder at the close its holder at the open.
-- One note held open there is allowed until the device has its off
local function mark_stranded(state, visit, now)
  for _, device in ipairs(state.devices) do
    local at = device.stub and device.stub.port
    for index = visit.marks[device.label] + 1, #device.log do
      local entry = device.log[index]
      local port, channel, note = entry.port, entry.msg.ch, entry.msg.note
      if entry.from == "io/midi_out" and entry.msg.type == "note_on" and port ~= nil and at ~= port
        and now[port] == visit.holders[port] and (ledger(device, channel)[note] or 0) > 0 then
        excuse(device, channel, note, "stranded")
      end
    end
  end
end

-- The allowance `held_dropped` (#996, a fault the walk found, no documented
-- edge): the close pays a device's owed offs where it is (MIDI out's
-- reconcile_owed takes the debt), and sends nothing to a port a remote
-- holds, so a device on a held port at the visit's open and its close
-- loses the offs of the notes it got in the visit at another port while
-- that port was free and that the close owes it (that port told gone, or
-- settled by a key while the device was away): they sound on until the
-- device is told the note again. Decided from the walk's own log and
-- claims: a note open on such a device whose last on came in the visit at
-- another port the close owes it
local function mark_held_dropped(state, visit, now, close_marks)
  for _, device in ipairs(state.devices) do
    local at = device.stub and device.stub.port
    -- on the held port at the open as at the close (a holder that changes
    -- is told: the claim ends and the arrival pays before the remote claims
    -- again), and the note's on inside the visit
    if at and held(state, at) and visit.starts[device.label] == at then
      for channel, notes in pairs(device.open) do
        for note, count in pairs(notes) do
          local on, index = last_on(device, channel, note, close_marks[device.label] + 1)
          if count > 0 and on and on.port ~= at and index > visit.marks[device.label]
            and (told_gone(visit, now, on.port) or played_while_away(visit, device, on.port, index)) then
            excuse(device, channel, note, "held_dropped")
          end
        end
      end
    end
  end
end

-- The menu closed: a claimed port whose holder changed over the visit is
-- told gone (its claim ends inside the close), a rig port that has a
-- device after it is claimed; then the close's check and the stranded marks
local function close_menu(state, visit)
  local now = holders(state)
  for _, kind in ipairs(WALK.rig_kinds) do
    local port = state.claimed[kind]
    if port and now[port] ~= visit.holders[port] then state.claimed[kind] = nil end
  end
  local stranded_before = {}
  for _, device in ipairs(state.devices) do
    local copy = {}
    for channel, notes in pairs(device.stranded) do
      for note, allowance in pairs(notes) do copy[channel .. " " .. note] = allowance end
    end
    stranded_before[device.label] = copy
  end
  local close_marks = log_marks(state)
  _menu.set_mode(false)
  connect_all(state)
  check_close(state, visit, now, close_marks, stranded_before)
  mark_stranded(state, visit, now)
  mark_held_dropped(state, visit, now, close_marks)
end

-- The menu opened, maybe keys played before anything moves, a synth moved
-- to another port of 1 to 5 (a synth there left on no port), maybe a synth
-- on no port given one, keys played, maybe the synth moved back, and the
-- menu closed
local function menu_visit(state, random)
  local visit = open_menu(state)
  for _ = 1, random(3) - 1 do play_in_menu(state, visit, random) end  -- every device still on its port
  local candidates = on_port(state)
  local mover = #candidates > 0 and pick(candidates, random)
  local from = mover and mover.stub.port
  if mover then
    local to = random(WALK.move_ports - 1)
    if to >= from then to = to + 1 end
    -- half the time onto another synth's port, which leaves that synth on
    -- no port, so the close tells the port gone if the mover goes back
    local others = {}
    for _, device in ipairs(on_port(state)) do
      if device ~= mover and device.stub.port <= WALK.move_ports then others[#others + 1] = device.stub.port end
    end
    if #others > 0 and random(2) == 1 then to = pick(others, random) end
    place(state, mover, to)
  end
  for _, device in ipairs(state.devices) do
    if connected(state, device) and device.stub.port == nil and random(2) == 1 then
      place(state, device, random(WALK.move_ports))
    end
  end
  -- the keys go half the time to a voice routed to the mover's new port,
  -- when one is: notes the moved synth gets where it visits
  local toward
  for voice = 1, #WALK.routes do
    if mover and mover.stub.port and params:get("v" .. voice .. "_out_port") == mover.stub.port then toward = voice end
  end
  for _ = 1, random(5) - 1 do play_in_menu(state, visit, random, random(2) == 1 and toward or nil) end
  if mover and random(3) > 1 and mover.stub.port ~= from then place(state, mover, from) end
  close_menu(state, visit)
end

-- A held synth's visit: a synth on a port the walk's claims hold moved, in
-- the menu, to the port a voice is routed to (a synth there left on no
-- port), a key played on that voice, the synth moved back, the close: the
-- close owes it the note (that port told gone when a synth was there), on
-- the held port it came back to (#996)
local function held_visit(state, random)
  local movers = {}
  for _, device in ipairs(on_port(state)) do
    if held(state, device.stub.port) then movers[#movers + 1] = device end
  end
  if #movers == 0 then return end
  local mover = pick(movers, random)
  local from, targets = mover.stub.port, {}
  for voice = 1, #WALK.routes do
    local port = params:get("v" .. voice .. "_out_port")
    if port > 0 and port ~= from and not held(state, port) then targets[#targets + 1] = {voice = voice, port = port} end
  end
  if #targets == 0 then return end
  local target = pick(targets, random)
  local visit = open_menu(state)
  place(state, mover, target.port)
  play_in_menu(state, visit, random, target.voice, true)
  place(state, mover, from)
  close_menu(state, visit)
end

-- The port of a voice in MPE mode (its zone's), or nil
local function zone_port(state)
  for voice = 1, #WALK.routes do
    local port = params:get("v" .. voice .. "_out_port")
    if params:get("v" .. voice .. "_out_mode") == WALK.mode_mpe and port > 0 then return port end
  end
end

-- The rig's grid or arc port set to one of 1 to 5, half the time the MPE
-- zone's, so its release sends the zone's setup
local function claim(state, random)
  local kind, port = pick(WALK.rig_kinds, random), random(WALK.move_ports)
  local zone = zone_port(state)
  if zone and random(2) == 1 then port = zone end
  local device = device_at(state, port)
  local was_held = held(state, port)
  local sounding = device and open_total(device) or 0
  state.claimed[kind] = nil  -- the rig moves it: its old port is let go inside the set
  local before = state.rig[kind]
  state.rig[kind] = port  -- before the set: its claim's ask comes inside it
  if not state.S.lib.io_rig.set(kind, port) then state.rig[kind] = before end
  connect_all(state)
  if device and not was_held and held(state, port) then
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
  local marks, set = log_marks(state), {}
  for _, kind in ipairs(WALK.rig_kinds) do
    if state.rig[kind] > 0 then set[#set + 1] = kind end
  end
  local kind = pick(#set > 0 and set or WALK.rig_kinds, random)
  state.claimed[kind] = nil
  local before = state.rig[kind]
  state.rig[kind] = 0
  if not state.S.lib.io_rig.set(kind, 0) then state.rig[kind] = before end
  connect_all(state)  -- the other kind, if its rig names the port, takes it straight back
  for _, device in ipairs(state.devices) do
    if got_setup(device, marks[device.label] + 1) then
      state.counts.setup_after_release = state.counts.setup_after_release + 1
    end
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
    unplug(state, device)
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
  {2, "menu", menu_visit},
  {1, "held visit", held_visit},
  {1.5, "claim", claim},
  {1.5, "release", release},
  {2, "route", function(state, random)
    pick(ROUTE_FIELDS, random)(random(#WALK.routes), random, state)
    settled(state)
  end},
}

-- The end check: every device on a port again (a device on no port given
-- a free one in the menu, opened only for it; the namesake unplugged so
-- synth a can return; the synths plugged in), then cleanup(); every device
-- has had as many note offs as note ons, but for the allowances
local function finish(state)
  local free, away = WALK.place_from, {}
  for _, device in ipairs(state.devices) do
    if device.stub and device.stub.port == nil then away[#away + 1] = device end
  end
  if #away > 0 then
    local visit = open_menu(state)
    for _, device in ipairs(away) do
      while vports(state)[free].device ~= nil or vports(state)[free].name ~= "none" do free = free + 1 end
      place(state, device, free)
    end
    close_menu(state, visit)
  end
  if state.twin.stub then unplug(state, state.twin) end
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
  local a = {label = "a", name = "synth a", open = {}, log = {}, stranded = {}}
  local twin = {label = "twin", name = "synth a", open = {}, log = {}, stranded = {}}
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

-- The allowance held_dropped is #996's case alone: a device on the held
-- port at the visit's open as at its close, with the note's on inside the
-- visit at a port the close tells gone. A device that came to the held
-- port in the visit (its arrival pays before the remote claims again), or
-- a note hung before the visit, is not excused
h.test("the devices walk excuses a note as held_dropped only where #996 drops it", function()
  local function excused_when(start_port, on_inside_visit)
    local device = {label = "a", name = "synth a", open = {[1] = {[60] = 1}}, stranded = {}, stub = {port = 3},
      log = {{from = "io/midi_out", port = 1, msg = {type = "note_on", ch = 1, note = 60}}}}
    local state = {devices = {device}, claimed = {remote_grid_port = 3}}
    local visit = {starts = {a = start_port}, marks = {a = on_inside_visit and 0 or 1},
      holders = {[1] = "b", [3] = "a"}, keys = {}}
    mark_held_dropped(state, visit, {[1] = false, [3] = "a"}, {a = 1})
    return excused(device, 1, 60)
  end
  h.assert_equal(excused_when(3, true), "held_dropped", "on the held port all the visit, the note got in it")
  h.assert_equal(excused_when(4, true), nil, "the device came to the held port in the visit")
  h.assert_equal(excused_when(3, false), nil, "the note's on came before the visit")
end)

h.walk({
  name = "devices: every MIDI device gets an off for each on while ports leave, move and are claimed",
  seeds = {2026, 3939, 77, 51423},
  steps = 400,
  setup = function(context, random)
    local S = local_value("S")
    local state = {context = context, S = S, devices = {}, problems = {}, rig = {}, claimed = {},
      lib_prefix = "@" .. h.repo_root .. "/lib/",
      counts = {outlived = 0, claim_sounding = 0, setup_after_release = 0, allowed_namesake = 0, allowed_away_cut = 0,
        allowed_stranded = 0, allowed_held_dropped = 0, told_gone = 0}}
    -- the includes' chunk names start at the repository's root
    local source = debug.getinfo(S.lib.io_midi_out.stop, "S").source
    if source ~= state.lib_prefix .. "io/midi_out.lua" then
      error("the devices walk: lib/io/midi_out.lua is " .. source .. ", not under " .. state.lib_prefix)
    end
    for _, kind in ipairs(WALK.rig_kinds) do state.rig[kind] = S.lib.io_rig.get(kind) end
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
  -- the problems the op's messages raised, and the remote's holds against
  -- the walk's own record of the claims
  after = function(state)
    local problems = state.problems
    state.problems = {}
    for port = 1, #vports(state) do
      local holds = state.S.lib.io_remote.holds(port)
      if holds ~= held(state, port) then
        problems[#problems + 1] = "port " .. port .. ": the remote " .. (holds and "holds" or "does not hold")
          .. " it, the walk's claims say " .. (holds and "not" or "held")
      end
    end
    return problems
  end,
  finish = finish,
  -- a note that outlived its device (unplugged while it sounded), a
  -- remote's claim of a port with a note sounding, a zone's setup after a
  -- remote let its port go, a close's off for a note at a port it tells
  -- gone, and each allowance met
  reached = {"outlived", "claim_sounding", "setup_after_release", "told_gone", "allowed_namesake", "allowed_away_cut",
    "allowed_stranded", "allowed_held_dropped"},
  counts = function(state) return state.counts end,
})

end
