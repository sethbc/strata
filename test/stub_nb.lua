-- stub_nb.lua
-- Stand-in for the note players voice mods register for nb (sixolet/nb),
-- from the 3.6 fact checks (issue 698): a mod puts a plain table,
-- with only the methods it wrote and no metatable, in the global
-- `note_players` (in its script_pre_init hook). nb's own host supplies the
-- rest (name, refcount, count_up, count_down, default active, empty
-- defaults), so the stub does not: a player here has exactly the methods
-- a test names and nothing else.
-- context.nb.add_player(name, methods) puts such a player in note_players;
-- methods is a list of names, default {"note_on", "note_off", "add_params"}.
-- Each method records {method, args...} (self left out) in player.calls.
-- describe, when named, returns name and the supports flags (false) and
-- empty modulation lists, as nb's base player does. player.name is not set
-- (a host sets it). nb_player_refcounts, the global nb's host creates, is
-- nil after an install and does not survive the next one.

return function()
  local helpers = { players = {} }

  function helpers.add_player(name, methods)
    local player = { calls = {} }
    for _, method in ipairs(methods or { "note_on", "note_off", "add_params" }) do
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
