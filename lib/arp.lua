-- lib/arp.lua
-- The arpeggiator (3.8, design §4.3): per voice an option, v<i>_arp (off,
-- up, down, up-down, shuffle), one registered voice-param record "arp".
-- The engine steps a voice's grains through interval1..intervalCount in
-- turn while arpOn is 1 (arpFold plays the list there and back: up-down);
-- this module orders the list S.lib.variation sends (list): ascending for
-- up and up-down, descending for down, a fresh shuffle at each of the
-- voice's hits and at least every ARP.shuffle_seconds. With no chord held
-- the list is the voice's interval set; on an arpeggiating voice a held
-- chord is the list (S.lib.notes.play hands its further notes here, hold):
-- {0} and each held pitch less the own note's, never a slot. See
-- docs/notes/lua/arp.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  M.ARP = {
    name = "arp",
    section = "grain",
    modes = {"off", "up", "down", "up-down", "shuffle"},
    mode_index = {off = 1, up = 2, down = 3, up_down = 4, shuffle = 5},
    shuffle_seconds = 4,
    max_steps = S.constants.NOTE_SLOTS,  -- the engine's interval1..8
  }
  local ARP = M.ARP

  local function valid_voice(voice)
    return type(voice) == "number" and voice % 1 == 0 and voice >= 1 and voice <= NUM_VOICES
  end

  -- The voice's mode index (off before init)
  local function mode_index(voice)
    local values = valid_voice(voice) and S.voices[voice].values
    return values and values.arp or ARP.mode_index.off
  end

  -- Whether voice arpeggiates (its option not off)
  function M.on(voice) return mode_index(voice) ~= ARP.mode_index.off end

  -- The voice's mode by name ("off", "up", "down", "up-down", "shuffle")
  function M.mode(voice) return ARP.modes[mode_index(voice)] end

  -- Per voice: the shuffle's order (a permutation of 1..n); the held notes
  -- (entries[v], oldest first: {owner, key, pitch, velocity}, never the own
  -- note's); the base, the own note's pitch the held steps are measured from
  -- (kept after the own note's record goes, until the next own note)
  local shuffles, entries, bases = {}, {}, {}
  -- the shuffle's last draw (util.time()) and the voices a hit marked since
  local shuffled_at, marked = {}, {}
  for voice = 1, NUM_VOICES do entries[voice] = {} end

  -- The hooks hear a held note (S.lib.notes.run_note_hooks, slot NOTES.arp_slot)
  local function tell(field, voice, entry)
    S.lib.notes.run_note_hooks(field, {voice = voice, slot = S.lib.notes.NOTES.arp_slot, owner = entry.owner,
      key = entry.key, pitch = entry.pitch, velocity = entry.velocity})
  end

  -- The base: the own note's pitch (kept; a parked one's too, which the
  -- arpeggiator turned on finds under the extra notes it takes), else the
  -- one kept, else the voice's pitch now
  local function base_of(voice)
    local own = S.lib.notes.slots(voice)[1]
    if own and own.slot == 1 then bases[voice] = own.pitch end
    return bases[voice] or S.lib.notes.own_pitch(voice)
  end

  -- The held chord's steps: 0 (the own note) and each held pitch less the base
  local function chord_steps(voice)
    local base, steps = base_of(voice), {0}
    for _, entry in ipairs(entries[voice]) do steps[#steps + 1] = entry.pitch - base end
    return steps
  end

  -- A fresh permutation of 1..n (Fisher-Yates)
  local function permutation(n)
    local order = {}
    for index = 1, n do order[index] = index end
    for index = n, 2, -1 do
      local other = math.random(index)
      order[index], order[other] = order[other], order[index]
    end
    return order
  end

  -- The list voice's grains step through: set's semitones (fractional
  -- allowed) ordered by the voice's mode, at most ARP.max_steps; off, set
  -- as it is (3.7's interval draw)
  function M.list(voice, set)
    if not M.on(voice) then return set end
    if #entries[voice] > 0 then set = chord_steps(voice) end
    local list = {}
    for index = 1, math.min(#set, ARP.max_steps) do list[index] = set[index] end
    table.sort(list)
    local index = mode_index(voice)
    if index == ARP.mode_index.down then
      local descending = {}
      for position = #list, 1, -1 do descending[#descending + 1] = list[position] end
      return descending
    elseif index == ARP.mode_index.shuffle then
      local order = shuffles[voice]
      if order == nil or #order ~= #list then
        order = permutation(#list)
        shuffles[voice], shuffled_at[voice] = order, util.time()
      end
      local shuffled = {}
      for position, from in ipairs(order) do shuffled[position] = list[from] end
      return shuffled
    end
    return list
  end

  -- arpFold to a running voice: 1 for up-down
  local function fold(voice) return mode_index(voice) == ARP.mode_index.up_down and 1 or 0 end
  local function send_fold(voice) engine.setGrainParam(voice - 1, "arpFold", fold(voice)) end

  -- The list again to a running voice: interval1..8 and intervalCount
  -- (S.lib.variation.send_intervals), counted in the engine budget's window
  local function resend(voice)
    if not S.voices[voice].active then return end
    S.lib.variation.send_intervals(voice)
    S.lib.engine_sync.count_sends(ARP.max_steps + 1)
  end

  local function find(voice, owner, key)
    for index, entry in ipairs(entries[voice]) do
      if entry.owner == owner and entry.key == key then return index end
    end
    return nil
  end

  -- A held note joins the list: played = S.lib.notes.play's checked note
  -- (owner, key, pitch, velocity). The same owner and key again is
  -- re-pitched in place (the hooks hear a move); a new one past the list's
  -- room (ARP.max_steps, the own note's step included) takes the place of
  -- the oldest. The list is resent, and a note not the sequencer's accents
  -- the voice (a step's chord is its step's hit). What play returns:
  -- NOTES.arp_slot
  function M.hold(voice, played)
    local NOTES = S.lib.notes.NOTES
    if not valid_voice(voice) then return nil end
    base_of(voice)
    local list, index = entries[voice], find(voice, played.owner, played.key)
    if index then
      list[index].pitch, list[index].velocity = played.pitch, played.velocity
      tell("moved", voice, list[index])
    else
      if #list >= ARP.max_steps - 1 then tell("ended", voice, table.remove(list, 1)) end
      local entry = {owner = played.owner, key = played.key, pitch = played.pitch, velocity = played.velocity}
      list[#list + 1] = entry
      tell("started", voice, entry)
    end
    resend(voice)
    if played.owner ~= NOTES.step_owner then S.lib.engine_sync.retrigger(voice, played.velocity, "note") end
    return NOTES.arp_slot
  end

  -- The held notes that match(entry) leave the list, the hooks hearing each
  -- end; when send and any left, the list is resent. The number that left
  local function drop(voice, match, send)
    local list, dropped = entries[voice], 0
    for index = #list, 1, -1 do
      if match(list[index]) then
        local entry = table.remove(list, index)
        tell("ended", voice, entry)
        dropped = dropped + 1
      end
    end
    if send and dropped > 0 then resend(voice) end
    return dropped
  end

  -- owner's held note key leaves the list (resent): true when one did
  function M.release(voice, owner, key)
    if not valid_voice(voice) then return false end
    return drop(voice, function(entry) return entry.owner == owner and entry.key == key end, true) > 0
  end

  -- Every held note of owner leaves the list (resent when any did)
  function M.release_owner(voice, owner)
    if not valid_voice(voice) then return end
    drop(voice, function(entry) return entry.owner == owner end, true)
  end

  -- A reset's way (S.lib.notes.forget_owner): as release_owner, the list
  -- holding no slot to release
  function M.forget_owner(voice, owner) M.release_owner(voice, owner) end

  -- Every held note leaves the list, sending nothing (the voice's stop, or
  -- the arpeggiator turned off, whose action resends), and the base and
  -- the shuffle go
  function M.clear(voice)
    if not valid_voice(voice) then return end
    drop(voice, function() return true end, false)
    bases[voice], shuffles[voice] = nil, nil
  end

  -- Copies of voice's held notes, oldest first: {owner, key, pitch, velocity}
  function M.held(voice)
    local copies = {}
    if not valid_voice(voice) then return copies end
    for index, entry in ipairs(entries[voice]) do
      copies[index] = {owner = entry.owner, key = entry.key, pitch = entry.pitch, velocity = entry.velocity}
    end
    return copies
  end

  -- The own note played at pitch (S.lib.notes' play_own): the new base,
  -- and a held chord's steps resent from it when it moved
  function M.own_note(voice, pitch)
    if not valid_voice(voice) then return end
    local moved = bases[voice] ~= pitch
    bases[voice] = pitch
    if moved and M.on(voice) and #entries[voice] > 0 then resend(voice) end
  end

  -- Turned on: the voice's held extra notes join the list (their slots cut,
  -- S.lib.notes.take_extras); turned off: the list's held notes go
  local function mode_changed(voice)
    if M.on(voice) then
      base_of(voice)
      for _, taken in ipairs(S.lib.notes.take_extras(voice)) do
        if find(voice, taken.owner, taken.key) == nil then
          entries[voice][#entries[voice] + 1] = taken
          tell("started", voice, taken)
        end
      end
    else
      M.clear(voice)
    end
  end

  -- VOICE's layout tests and page renders: each voice on each mode, the
  -- cursor on its row, the pan wander above it at its widest
  local layout_states = {}
  for voice = 1, NUM_VOICES do
    for index, name in ipairs(ARP.modes) do
      table.insert(layout_states, {
        name = string.format("v%d arp %s", voice, name),
        setup = function()
          local prefix = "v" .. voice .. "_"
          S.selected_voice = voice
          params:set(prefix .. "pan_wander", S.lib.grain.GRAIN.percent)
          params:set(prefix .. ARP.name, index)
          S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(prefix .. ARP.name))
        end,
      })
    end
  end

  local record
  record = {
    name = ARP.name,
    count = 1,
    add = function(voice)
      S.lib.params_setup.add_voice_param(voice, record, ARP.name, {type = "option", name = ARP.name,
        options = ARP.modes, default = ARP.mode_index.off,
        action = function()
          mode_changed(voice)
          if not S.voices[voice].active then return end
          send_fold(voice)
          S.lib.variation.send_intervals(voice)
        end})
    end,
    grain_keys = {arp = {name = "arpOn", value = function(x) return x > ARP.mode_index.off and 1 or 0 end,
      carry = false}},
    -- a start (before voiceOn) and a running voice's sync: the fold
    sync = function(voice) send_fold(voice) end,
    scene_defaults = {arp = ARP.mode_index.off},
    discrete = {arp = {ARP.mode_index.off, #ARP.modes}},
    voice_rows = {section = ARP.section, rows = {ARP.name}},
    layout_states = layout_states,
    fader = false,
  }
  S.register_voice_params(record)

  -- The shuffle: a hit only marks its voice (a hook never sends); the LFO
  -- clock's step draws a shuffling running voice a fresh order and resends
  -- its list when a hit marked it or ARP.shuffle_seconds passed since its
  -- last draw. A resend is ARP.max_steps + 1 messages, counted, never deferred
  S.register_voice_hit({name = ARP.name, hit = function(voice) marked[voice] = true end})
  local function shuffle_step()
    local now = util.time()
    for voice = 1, NUM_VOICES do
      local due = marked[voice] or now - (shuffled_at[voice] or -math.huge) >= ARP.shuffle_seconds
      marked[voice] = nil
      if due and S.voices[voice].active and mode_index(voice) == ARP.mode_index.shuffle then
        -- a list of fewer than two steps has no other order: nothing to send
        local steps = #entries[voice] > 0 and #entries[voice] + 1 or #S.lib.variation.interval_set(voice)
        if steps > 1 then
          shuffles[voice] = nil
          resend(voice)
        else
          shuffled_at[voice] = now
        end
      end
    end
  end

  -- Only a running arpeggiating voice holds notes in its list, at most
  -- ARP.max_steps - 1 (the own note's step beside them), each owner and key
  -- once, none also in a slot of S.lib.notes
  S.register_invariant(ARP.name, function()
    for voice = 1, NUM_VOICES do
      local list = entries[voice]
      if #list > 0 and not (S.voices[voice].active and M.on(voice)) then
        return "voice " .. voice .. " holds arpeggiated notes but is stopped or not arpeggiating"
      end
      if #list > ARP.max_steps - 1 then return "voice " .. voice .. " holds " .. #list .. " arpeggiated notes" end
      for index, entry in ipairs(list) do
        if find(voice, entry.owner, entry.key) ~= index then
          return "voice " .. voice .. " holds " .. entry.owner .. " key " .. tostring(entry.key) .. " twice"
        end
        if S.lib.notes.find(voice, entry.owner, entry.key) then
          return "voice " .. voice .. "'s " .. entry.owner .. " key " .. tostring(entry.key) .. " is in a slot too"
        end
      end
    end
  end)

  -- The start step: the shuffle joins the LFO clock's step hooks once,
  -- after those registered at include time (as the notes flush does)
  local hooked = false
  S.register_start(S.constants.START_ORDER.arp, function()
    if hooked then return end
    hooked = true
    S.lib.lfos.on_step(shuffle_step)
  end)

  return M
end
