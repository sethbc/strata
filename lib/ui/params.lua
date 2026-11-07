-- lib/ui/params.lua
-- A param's range and a value's place on it (0-1, following a control
-- param's warp), for the arc rings, the grid faders and the code that
-- clamps to a param's range; whether a range spans 0 (the center detents,
-- lib/ui/detent.lua, and the bipolar rings) and a param's default. The
-- functions stay global.

return function(S)
  local M = {}

  -- Range of a control param (controlspec), option param (option indices
  -- 1..count) or number param (min/max)
  function param_range(param_id)
    local param = params:lookup_param(param_id)
    if param.controlspec then
      return param.controlspec.minval, param.controlspec.maxval
    end
    if param.options then  -- option param (norns' param.t is a number, so test the field)
      return 1, param.count
    end
    return param.min, param.max
  end

  -- Whether a control or number param's range runs through 0 (min < 0 <
  -- max): such a param's arc ring fills from 0 (arc_ring_fill_param) and
  -- its encoder and ring changes hold at 0 (delta_with_detent). Option
  -- params never do
  function param_spans_zero(param_id)
    if params:lookup_param(param_id).options then return false end
    local minval, maxval = param_range(param_id)
    return minval < 0 and maxval > 0
  end

  -- A param's default value: a control param's controlspec default (a spec
  -- made without one starts at raw 0, as norns' params/control.lua does, so
  -- that value), or a number or option param's default (an option index)
  function param_default(param_id)
    local param = params:lookup_param(param_id)
    local spec = param.controlspec
    if spec then
      if spec.default ~= nil then return spec.default end
      return spec:map(0)
    end
    return param.default
  end

  -- A value as a fraction (0-1) of a param's range. Control params follow
  -- their controlspec warp (exp for freq, cutoff, mod speed); number params
  -- (mod sources) and option params (grain envelope) are linear.
  function param_value_fraction(param_id, value)
    local spec = params:lookup_param(param_id).controlspec
    if spec then
      return spec:unmap(value)
    end
    local minval, maxval = param_range(param_id)
    return util.linlin(minval, maxval, 0, 1, value)
  end

  -- A param's current value as a fraction (0-1) of its range
  function param_fraction(param_id)
    return param_value_fraction(param_id, params:get(param_id))
  end

  return M
end
