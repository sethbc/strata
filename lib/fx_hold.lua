-- lib/fx_hold.lua
-- The effects' freezes and the delay's clear (3.8 design §7.2, §7.3;
-- S.lib.fx_hold). An fx record (S.register_fx_params), hold: delay_freeze,
-- a binary toggle that freezes the delay's loop (engine.setDelayFreeze),
-- and delay_clear, a trigger that empties it (engine.clearDelay). Neither
-- is saved in a PSET (delay_freeze's save is off; norns never writes a
-- trigger) or a scene, and neither is an LFO destination: the loop's audio
-- is in neither, as a bypass's is not. A PSET load leaves a freeze as it is
-- (plan ruling 61). A bypass ends its effect's freeze first (the bypass
-- action, lib/voice_mix.lua, calls release), so the engine's kept freeze
-- is 0 at the lift; a freeze set while its effect is bypassed is refused,
-- the param put back to off and echoed to a mapped controller (plan
-- ruling 26). The functions are FX's, the
-- header's and the grids' (packages 4a, 4b): offered, frozen, toggle,
-- release, clear, any_frozen. See docs/notes/lua/fx-hold.md.

return function(S)
  local M = {}

  -- By effect: the freeze's param, and the clear's where it has one
  M.FX_HOLD = {delay = {freeze_id = "delay_freeze", clear_id = "delay_clear"}}

  -- Whether an effect ("delay", "reverb") has a freeze here: the delay's
  -- always, nothing else. The reverb's is cut from 3.8 (package 3a, plan
  -- ruling 27: the high tier's FDN did not hold its level and its tail
  -- within 1 dB; #819), so offered("reverb") is false on every tier
  function M.offered(effect)
    return M.FX_HOLD[effect] ~= nil
  end

  -- Whether an effect is frozen: offered, and its freeze param at 1
  function M.frozen(effect)
    return M.offered(effect) and params:get(M.FX_HOLD[effect].freeze_id) == 1
  end

  -- Whether any effect is frozen (the header's mark)
  function M.any_frozen()
    for effect in pairs(M.FX_HOLD) do
      if M.frozen(effect) then return true end
    end
    return false
  end

  -- Freeze or release an effect, through set_binary_param (a controller
  -- mapped to the param follows, #538). Nothing for an effect not offered
  -- or bypassed
  function M.toggle(effect)
    if not M.offered(effect) or S.lib.voice_mix.bypassed(effect) then return end
    set_binary_param(M.FX_HOLD[effect].freeze_id, M.frozen(effect) and 0 or 1)
  end

  -- Release an effect's freeze, if it is frozen. Nothing for an effect not
  -- offered (the bypass action calls it for both effects)
  function M.release(effect)
    if not M.offered(effect) then return end
    if params:get(M.FX_HOLD[effect].freeze_id) == 1 then set_binary_param(M.FX_HOLD[effect].freeze_id, 0) end
  end

  -- Empty the delay (its trigger)
  function M.clear()
    params:set(M.FX_HOLD.delay.clear_id, 1)
  end

  local delay = M.FX_HOLD.delay
  S.register_fx_params({
    name = "hold",
    count = 2,
    add = function()
      params:add{
        type = "binary",
        id = delay.freeze_id,
        name = "delay freeze",
        behavior = "toggle",
        default = 0,
        action = function(x)
          -- refused while bypassed: back to off through set_binary_param,
          -- so a mapped controller hears the 0. Its set re-enters this
          -- action with 0, which is never refused and sends one redundant
          -- setDelayFreeze(0) (the engine keeps 0 through the bypass)
          if x == 1 and S.lib.voice_mix.bypassed("delay") then
            set_binary_param(delay.freeze_id, 0)
            return
          end
          send_param_to_engine(delay.freeze_id, x)
          request_redraw()
          grid_redraw()
        end,
      }
      params:set_save(delay.freeze_id, false)
      S.engine_senders[delay.freeze_id] = function(value) engine.setDelayFreeze(value) end
      params:add{
        type = "trigger",
        id = delay.clear_id,
        name = "delay clear",
        action = function() send_param_to_engine(delay.clear_id, 1) end,
      }
      S.engine_senders[delay.clear_id] = function() engine.clearDelay() end
    end,
  })

  return M
end
