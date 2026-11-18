-- lib/shimmer.lua
-- Shimmer (3.8 design §7.4; S.lib.shimmer): a pitch shifter in the
-- delay's feedback and around the reverb, each with its own amount, at one
-- interval. An fx record (S.register_fx_params), shimmer: shimmer_interval,
-- an option of five pure ratios (an octave down, a fifth, an octave at
-- first, an octave and a fifth, two octaves: a ratio, so it holds in any
-- tuning), and shimmer_delay and shimmer_reverb, 0-1 (0 at first: each
-- effect as without shimmer). One command carries all three
-- (engine.setShimmer(delay, reverb, ratio)), each param sending the other
-- two as the engine has them. The three are scene globals (the interval
-- discrete, switching at a fade's end) and the amounts LFO global
-- destinations; the engine keeps them through a bypass, so a bypass sends
-- nothing. Each action notes the edit (a page randomize may draw it). See
-- docs/notes/lua/shimmer.md and docs/notes/engine/shimmer.md.

return function(S)
  local M = {}

  -- The interval's ratios and names, in the option's order (the names fit
  -- FX's value column), and its default (an octave); the params' ids, the
  -- amounts' names and their LFO labels
  M.SHIMMER = {
    ratios = {0.5, 1.5, 2, 3, 4},
    names = {"oct down", "fifth", "octave", "oct+5th", "2 oct"},
    default_interval = 3,
    interval_id = "shimmer_interval",
    amounts = {
      {id = "shimmer_delay", name = "shimmer delay", lfo_label = "shim dly"},
      {id = "shimmer_reverb", name = "shimmer reverb", lfo_label = "shim rev"},
    },
  }

  local SHIMMER = M.SHIMMER

  -- The ratio of an interval index (an option's index; clamped to the list)
  local function ratio_of(index)
    local whole = math.floor((tonumber(index) or SHIMMER.default_interval) + 0.5)
    return SHIMMER.ratios[util.clamp(whole, 1, #SHIMMER.ratios)]
  end

  -- The interval's ratio now
  function M.ratio()
    return ratio_of(params:get(SHIMMER.interval_id))
  end

  local function percent(param) return string.format("%d %%", math.floor(param:get() * 100 + 0.5)) end

  -- The one sender of all three: the amounts and the interval as the
  -- engine has them (engine_param_value: an LFO's offset included)
  local function send_shimmer()
    engine.setShimmer(engine_param_value(SHIMMER.amounts[1].id), engine_param_value(SHIMMER.amounts[2].id),
      ratio_of(engine_param_value(SHIMMER.interval_id)))
  end

  S.register_fx_params({
    name = "shimmer",
    count = 3,
    add = function()
      params:add{
        type = "option",
        id = SHIMMER.interval_id,
        name = "shimmer interval",
        options = SHIMMER.names,
        default = SHIMMER.default_interval,
        action = function(x)
          note_param_edit(SHIMMER.interval_id)
          send_param_to_engine(SHIMMER.interval_id, x)
        end,
      }
      S.engine_senders[SHIMMER.interval_id] = send_shimmer
      for _, amount in ipairs(SHIMMER.amounts) do
        params:add{
          type = "control",
          id = amount.id,
          name = amount.name,
          controlspec = controlspec.new(0, 1, "lin", 0.01, 0),
          formatter = percent,
          action = function(x)
            note_param_edit(amount.id)
            send_param_to_engine(amount.id, x)
          end,
        }
        S.engine_senders[amount.id] = send_shimmer
      end
    end,
  })

  S.register_scene_field({id = SHIMMER.interval_id, default = SHIMMER.default_interval, discrete = true})
  for _, amount in ipairs(SHIMMER.amounts) do
    S.register_scene_field({id = amount.id, default = 0})
    S.register_lfo_global_destination(amount.lfo_label, amount.id)
  end

  return M
end
