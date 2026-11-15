-- stub_nb.lua
-- Stand-in for nb's note players (sixolet/nb lib/player.lua, as
-- docs/design/3.6-facts/iii-osc-nb-softcut.md section 5 gives its
-- interface): the global `note_players` is the table mods register players
-- in. context.nb.add_player(name) puts a player there, and each method
-- records {method, args...} (self left out) in player.calls:
-- note_on(note, vel, properties), note_off(note), stop_all(), add_params(),
-- count_up(), count_down(), describe(), active(), inactive(),
-- modulate_note(note, key, value), pitch_bend(note, amount), and also
-- play_note, modulate, modulate_voice, set_slew and delayed_active.
-- describe() returns name and the supports flags (false, as player.lua's
-- default), empty modulation lists and params.

local METHODS = { "note_on", "note_off", "stop_all", "add_params", "count_up", "count_down", "describe",
  "active", "inactive", "modulate_note", "pitch_bend", "play_note", "modulate", "modulate_voice",
  "set_slew", "delayed_active" }

return function()
  local helpers = { players = {} }

  function helpers.add_player(name)
    local player = { name = name, calls = {} }
    for _, method in ipairs(METHODS) do
      player[method] = function(_, ...)
        local call = { method }
        for index = 1, select("#", ...) do call[index + 1] = (select(index, ...)) end
        table.insert(player.calls, call)
        if method == "describe" then
          return { name = name, supports_bend = false, supports_slew = false,
            modulate_description = "unknown", note_mod_targets = {}, voice_mod_tarets = {}, params = {} }
        end
      end
    end
    _G.note_players[name] = player
    helpers.players[name] = player
    return player
  end

  return helpers
end
