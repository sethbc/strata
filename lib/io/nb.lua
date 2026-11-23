-- lib/io/nb.lua
-- The nb host (3.6 design §7, decisions 14 and 21; S.lib.io_nb): each voice
-- can play one player that an installed nb voice mod put in the global
-- note_players, and this module does the eight things an nb host does
-- (docs/design/3.6-facts/checks.md §1), in Strata's own code: it loads no
-- nb file and copies none of nb's. A mod's own methods are found with
-- rawget, so a metatable another host put on a player never answers.
-- Registers the target "nb", a voice-stop hook and a PSET hook; adds the
-- group strata_out_nb (the menu record "out nb" of lib/params_setup.lua).
-- Notes: docs/notes/lua/io/nb.md

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  local NB = {none = "none", midi_prefix = "midi: ", delayed_seconds = 1, sentinel = "nb_sentinel_param",
    selector = "v%d_out_nb", warning = "nb mods send on their own", mark = "[!]", leading_bus = "strata",
    row_label = "nb", group = "strata_out_nb", group_name = "out nb", separator = "strata_nb_players",
    separator_name = "nb players"}
  M.NB = NB

  -- players[key] = the player table listed at init; chosen[voice] = the key
  -- the voice plays (nil for none); uses[key] = the voices choosing it;
  -- notes[voice][id] = {player, note} for each note sent on
  -- activations[key] = the handle (S.lib.clocks, #870) of the clock nb's
  -- default activation runs for the player, whose id the player keeps in
  -- active_routine as nb's base does
  local state = {added = false, players = {}, chosen = {}, uses = {}, notes = {}, errors = {}, activations = {}}
  for voice = 1, NUM_VOICES do state.notes[voice] = {} end

  local function selector(voice) return string.format(NB.selector, voice) end

  local function valid_voice(voice)
    return type(voice) == "number" and voice % 1 == 0 and voice >= 1 and voice <= NUM_VOICES
  end

  -- A method the mod wrote itself, called on the player (duty 3), contained:
  -- a player's error prints once and never ends a param action or a read
  local function call_own(player, key, method, ...)
    local fn = rawget(player, method)
    if type(fn) ~= "function" then return false end
    S.lib.ui_frame.contained_call(state.errors, key .. " " .. method, "nb player " .. key .. " " .. method, fn,
      player, ...)
    return true
  end

  -- The global refcounts (duty 5): created when nil, never replaced
  local function refcounts()
    if type(nb_player_refcounts) ~= "table" then nb_player_refcounts = {} end
    return nb_player_refcounts
  end

  -- nb's activation (duty 6): the player's own active, or is_active and a
  -- clock that calls its own delayed_active a second later while still
  -- active. The clock is S.lib.clocks' (#870): a deactivation stops it,
  -- retired, never canceled, while its resume may be posted
  local function activate(player, key)
    if call_own(player, key, "active") then return end
    player.is_active = true
    local activation = S.lib.clocks.run(function(handle)
      if not handle.sleep(NB.delayed_seconds) then return end
      player.active_routine = nil
      if state.activations[key] == handle then state.activations[key] = nil end
      if player.is_active then call_own(player, key, "delayed_active") end
    end)
    state.activations[key] = activation
    player.active_routine = activation.id
  end

  local function deactivate(player, key)
    if call_own(player, key, "inactive") then return end
    player.is_active = false
    -- a clock another host's base canceled is not stopped again (#870's review)
    if S.lib.clocks.alive(state.activations[key]) then S.lib.clocks.stop(state.activations[key]) end
    state.activations[key] = nil
    player.active_routine = nil
  end

  -- Count a player up or down (duties 4 and 5): the global count, taken as
  -- at least this module's own uses, so another host emptying the table
  -- neither activates a player twice nor deactivates one a voice still plays
  local function count_up(key)
    local player = state.players[key]
    player.name = key
    local counts = refcounts()
    local before = math.max(counts[key] or 0, state.uses[key] or 0)
    state.uses[key] = (state.uses[key] or 0) + 1
    counts[key] = before + 1
    if before == 0 then activate(player, key) end
  end

  local function count_down(key)
    local player = state.players[key]
    local counts = refcounts()
    state.uses[key] = math.max((state.uses[key] or 0) - 1, 0)
    local after = math.max((counts[key] or 0) - 1, state.uses[key])
    -- removed at 0, as nb's own host does: another host activates a player
    -- only when its entry is nil
    counts[key] = after > 0 and after or nil
    if after == 0 then deactivate(player, key) end
  end

  local function player_of(voice)
    local key = state.chosen[voice]
    return key and state.players[key], key
  end

  -- The keyed option's action (each choice and each key set, a PSET read
  -- included): only a change of player counts, so the same key again does
  -- nothing; the voice's notes end first, on the player they started on
  local function choose(voice, key)
    local now = state.players[key] and key or nil
    if now == state.chosen[voice] then return end
    if S.lib.io_targets and S.lib.io_targets.route_changed then S.lib.io_targets.route_changed(voice) end
    local before = state.chosen[voice]
    state.chosen[voice] = now
    if before then count_down(before) end
    if now then count_up(now) end
    request_redraw()
  end

  local function any_chosen()
    for voice = 1, NUM_VOICES do
      if state.chosen[voice] then return true end
    end
    return false
  end

  -- Each chosen player once, in voice order
  local function each_chosen(fn)
    local seen = {}
    for voice = 1, NUM_VOICES do
      local player, key = player_of(voice)
      if player and not seen[key] then
        seen[key] = true
        fn(player, key)
      end
    end
  end

  local function stop_chosen()
    each_chosen(function(player, key) call_own(player, key, "stop_all") end)
  end

  -- The entries of note_players, sorted by name (duty 1: read at init)
  local function entries()
    local names = {}
    if type(note_players) ~= "table" then return names end
    for name, player in pairs(note_players) do
      if type(name) == "string" and type(player) == "table" then names[#names + 1] = name end
    end
    table.sort(names)
    return names
  end

  -- The keys: none, then the players' names, sorted, without nb's own MIDI
  -- players (duty 2) and without a name a PSET cannot keep (one line each,
  -- with the keyed module's own reason: one check, so add never raises here)
  local function listed(names)
    local keys = {NB.none}
    state.players = {}
    for _, name in ipairs(names) do
      local why = S.lib.io_keyed.refuses(name)
      if name == NB.none then why = "the name Strata gives no player" end
      if name:sub(1, #NB.midi_prefix) == NB.midi_prefix then
        why = nil
      elseif why then
        -- one line: %q writes a newline as a backslash and a newline
        local quoted = string.format("%q", name):gsub("\\\n", "\\n")
        print("strata: nb player " .. quoted .. " left out: " .. why)
      else
        keys[#keys + 1] = name
        state.players[name] = note_players[name]
      end
    end
    return keys
  end

  -- The group strata_out_nb (two params a voice: the option and its hidden
  -- key, S.lib.io_keyed), then once per session's paramset the players'
  -- own params behind nb's sentinel (duty 7)
  function M.add_params()
    local names = entries()
    local keys = listed(names)
    state.chosen, state.uses, state.added = {}, {}, true
    for voice = 1, NUM_VOICES do state.notes[voice] = {} end
    -- a stale is_active only comes with a carried-over entry (duty 6)
    for key, player in pairs(state.players) do player.is_active = false end
    params:add_group(NB.group, NB.group_name, 2 * NUM_VOICES)
    for voice = 1, NUM_VOICES do
      S.lib.io_keyed.add(selector(voice), "v" .. voice .. " nb", keys, keys, function(key) choose(voice, key) end)
    end
    -- with no entry there are no params to guard: nothing is added. The
    -- separator ends strata_out_nb in the menu, so a player's own params
    -- never read as Strata's
    if params.lookup[NB.sentinel] or #names == 0 then return end
    params:add_separator(NB.separator, NB.separator_name)
    for _, name in ipairs(names) do call_own(note_players[name], name, "add_params") end
    params:add_binary(NB.sentinel, NB.sentinel)
    params:hide(NB.sentinel)
  end

  -- The target nb
  S.register_note_target({name = "nb",
    routed = function(voice)
      return valid_voice(voice) and state.chosen[voice] ~= nil
    end,
    note_on = function(voice, id, pitch, velocity)
      if not valid_voice(voice) or type(pitch) ~= "number" then return end
      local player, key = player_of(voice)
      if not player then return end
      local note = math.floor(pitch + 0.5)
      state.notes[voice][id] = {player = player, key = key, note = note}
      call_own(player, key, "note_on", note, velocity)
    end,
    note_off = function(voice, id)
      if not valid_voice(voice) then return end
      local record = state.notes[voice][id]
      if not record then return end
      state.notes[voice][id] = nil
      call_own(record.player, record.key, "note_off", record.note)
    end,
    stop_all = function()
      for voice = 1, NUM_VOICES do state.notes[voice] = {} end
      stop_chosen()
    end,
    rows = function(voice)
      if not state.added or not valid_voice(voice) then return {} end
      local rows = {{label = NB.row_label, kind = "param", param_id = selector(voice)}}
      if any_chosen() then rows[2] = {kind = "status", text = NB.warning, id = "nb warning"} end
      return rows
    end,
    status = function()
      if any_chosen() and S.lib.io_rig.get("ii_bus") ~= NB.leading_bus then return NB.mark end
      return nil
    end,
  })

  -- A voice's stop: its player's own stop_all (the core has sent the offs)
  S.register_voice_stop(function(voice)
    if not valid_voice(voice) then return end
    local player, key = player_of(voice)
    if player then call_own(player, key, "stop_all") end
  end)

  -- A PSET load (duty 8): the keys are settled by now (the keyed module's
  -- hook runs first); each chosen player's own stop_all
  S.register_pset_hook({name = "io_nb", read = function()
    if state.added then stop_chosen() end
  end})

  return M
end
