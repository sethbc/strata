-- lib/ui/detent.lua
-- Every encoder and arc ring change of a param goes through here: center
-- detents (a param whose range spans 0 holds at 0 for DETENT.encoder_detents
-- detents, or DETENT.arc_ticks arc ticks, after reaching or crossing it, for
-- at most DETENT.hold_seconds) and
-- ALT+E3 fine adjustment (a control param moves 1 / FINE_DIVISOR of its raw
-- step). delta_with_detent and enc_param_delta are global; pages call
-- enc_param_delta from enc, rings call arc_sweep_param (lib/arc/core.lua).
-- The hold left per param id is local to this module.

return function(S)
  local M = {}
  local DETENT = S.constants.DETENT
  local FINE_DIVISOR = S.constants.FINE_DIVISOR
  local UI_PAGES = S.constants.UI_PAGES

  -- A hold counted in units both kinds of turn use up in whole numbers: a
  -- whole hold is HOLD_UNITS, an encoder detent uses DETENT.arc_ticks of
  -- them and an arc tick DETENT.encoder_detents. So a hold the arc started
  -- and an encoder finishes (or the other way) lasts as long either way
  local HOLD_UNITS = DETENT.encoder_detents * DETENT.arc_ticks

  -- Per param id: {units = the hold units left while it sits at 0, started =
  -- util.time() when it reached 0} (nil: no hold)
  local detent_holds = {}

  -- Whether a move from old to new reaches or passes 0 (old is not 0)
  local function reaches_zero(old, new)
    return (old < 0 and new >= 0) or (old > 0 and new <= 0)
  end

  -- Change a param by an encoder's d detents (as params:delta takes them) or,
  -- with opts.arc_ticks = n, by n arc ticks (d unused: the raw value moves
  -- n / UI_PAGES.ARC_TICKS_PER_SWEEP, control params only). opts.fine (an
  -- encoder only) moves a control param d * quantum / FINE_DIVISOR in raw;
  -- number and option params ignore it and keep whole steps.
  -- A param whose range spans 0 (param_spans_zero) stops at exactly 0 when a
  -- change reaches or crosses it, however large the change (an accelerated
  -- encoder delta of 2-5 included), and holds there for a whole hold: each
  -- later change while it is still 0 uses up |d| detents or |n| ticks, and the
  -- change that uses up more than is left applies in full. A hold ends when
  -- the value is found away from 0 (something else moved it) or
  -- DETENT.hold_seconds after it started (so a hold left over from a turn
  -- long ago never swallows a detent, even if the value is back at 0)
  function delta_with_detent(param_id, d, opts)
    opts = opts or {}
    local param = params:lookup_param(param_id)
    local spec = param.controlspec
    local raw_delta, units  -- raw_delta nil: a whole-step params:delta
    if opts.arc_ticks then
      if not spec then error("delta_with_detent: arc ticks need a control param, not " .. param_id, 2) end
      raw_delta = opts.arc_ticks / UI_PAGES.ARC_TICKS_PER_SWEEP
      units = math.abs(opts.arc_ticks) * DETENT.encoder_detents
    else
      if spec then raw_delta = d * spec.quantum / (opts.fine and FINE_DIVISOR or 1) end
      units = math.abs(d) * DETENT.arc_ticks
    end

    local function apply()
      if raw_delta then
        params:set_raw(param_id, params:get_raw(param_id) + raw_delta)
      else
        params:delta(param_id, d)
      end
    end

    -- a wrapping range has no center to stop at
    if not param_spans_zero(param_id) or (spec and spec.wrap) then
      apply()
      return
    end

    local old = params:get(param_id)
    local hold = detent_holds[param_id]
    if hold then
      detent_holds[param_id] = nil
      if old == 0 and util.time() - hold.started < DETENT.hold_seconds then
        if hold.units - units >= 0 then
          hold.units = hold.units - units  -- still held: the value stays 0
          detent_holds[param_id] = hold
          return
        end
        apply()  -- the hold is used up: this change applies, from 0
        return
      end
      -- moved away from 0 by something else, or expired: the hold has ended
    end

    local new
    if raw_delta then
      new = spec:map(util.clamp(params:get_raw(param_id) + raw_delta, 0, 1))
    else
      new = util.clamp(old + d, param.min, param.max)
    end
    if old ~= 0 and reaches_zero(old, new) then
      params:set(param_id, 0)
      detent_holds[param_id] = {units = HOLD_UNITS, started = util.time()}
    else
      apply()
    end
  end

  -- A page's encoder n turning param_id by d detents: ALT+E3 is fine
  -- adjustment, E2 (with or without ALT) never is. Pages call it from enc for
  -- every param edit
  function enc_param_delta(n, param_id, d)
    delta_with_detent(param_id, d, {fine = n == 3 and S.alt_held})
  end

  return M
end
