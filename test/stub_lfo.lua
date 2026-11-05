-- stub_lfo.lua
-- Stand-in for norns' lua/lib/lfo.lua, returned by require("lfo") in the
-- harness. The PARAMS it adds (ids, types, ranges, defaults, group size) and
-- their actions mirror LFO:add_params; LFO.new/add/set/get/start/stop keep
-- the library's fields, and reset_phase and set("period") reset and rescale
-- phase_counter as the library does (compared line by line with
-- lib/lfo.lua). There is no lattice: nothing advances on its own, and
-- phase_counter only moves through those two.
-- The test helper lfo_context.tick(instance, raw) runs the value part of the
-- library's process_lfo with `raw` (0..1) as the shape output, so the action
-- receives exactly what the library would send for that point of the cycle.
-- Uses the params/controlspec/util/clock globals installed by norns_stubs.

local lfo_rates = {1/16,1/8,1/4,5/16,1/3,3/8,1/2,3/4,1,1.5,2,3,4,6,8,16,32,64,128,256,512,1024}
local lfo_rates_as_strings = {"1/16","1/8","1/4","5/16","1/3","3/8","1/2","3/4","1","1.5","2","3","4","6","8",
  "16","32","64","128","256","512","1024"}
local lfo_shapes = {"sine", "tri", "square", "random", "up", "down"}
local params_per_entry = 15

local function index_of(list, element)
  for index, value in ipairs(list) do
    if value == element then return index end
  end
  return nil
end

return function(lfo_context)
  local LFO = {}
  LFO.__index = LFO
  lfo_context.instances = {}

  local function scale_lfo(target)
    if target.baseline == "min" then
      target.scaled_min = target.min
      target.scaled_max = target.min + target.percentage
      target.mid = util.linlin(target.min, target.max, target.scaled_min, target.scaled_max, (target.min + target.max) / 2)
    elseif target.baseline == "center" then
      target.mid = (target.min + target.max) / 2
      local centroid_mid = math.abs(target.min - target.max) * (target.depth / 2)
      target.scaled_min = util.clamp(target.mid - centroid_mid, target.min, target.max)
      target.scaled_max = util.clamp(target.mid + centroid_mid, target.min, target.max)
    elseif target.baseline == "max" then
      target.mid = (target.min + target.max) / 2
      target.scaled_min = target.max * (1 - target.depth)
      target.scaled_max = target.max
      target.mid = math.abs(util.linlin(target.min, target.max, target.scaled_min, target.scaled_max, target.mid))
    end
  end

  function LFO.new(shape, min, max, depth, mode, period, action, phase, baseline)
    local instance = setmetatable({}, LFO)
    instance.scaled = 0
    instance.raw = 0
    instance.phase_counter = 0
    if shape == "saw" then shape = "up" end
    instance.shape = shape == nil and "sine" or shape
    instance.min = min == nil and 0 or min
    instance.max = max == nil and 1 or max
    instance.depth = depth == nil and 0 or depth
    instance.enabled = 0
    instance.mode = mode == nil and "clocked" or mode
    instance.period = period == nil and 4 or period
    instance.reset_target = "floor"
    instance.baseline = baseline == nil and "min" or baseline
    instance.offset = 0
    instance.ppqn = 96
    instance.controlspec = { warp = "linear", step = 0.01, units = "", quantum = 0.01, wrap = false, formatter = nil }
    instance.action = action == nil and (function(scaled, raw) end) or action
    instance.percentage = math.abs(instance.min - instance.max) * instance.depth
    instance.scaled_min = instance.min
    instance.scaled_max = instance.max
    instance.mid = 0
    instance.rand_value = 0
    instance.phase = phase == nil and 0 or phase
    -- stub bookkeeping
    instance.running = false
    instance.reset_count = 0
    scale_lfo(instance)
    table.insert(lfo_context.instances, instance)
    return instance
  end

  function LFO:add(args)
    return self.new(args.shape, args.min, args.max, args.depth, args.mode, args.period, args.action, args.phase,
      args.baseline)
  end

  function LFO:start(from_parameter)
    if not self.running then
      self:reset_phase()
      self.running = true
      self.enabled = 1
      if not from_parameter and self.parameter_id ~= nil then
        params:set("lfo_" .. self.parameter_id, 2)
      end
    end
  end

  function LFO:stop()
    if self.running then
      self.running = false
      self.enabled = 0
    end
  end

  -- lib/lfo.lua's LFO:reset_phase (the stub also counts the resets)
  function LFO:reset_phase()
    self.reset_count = self.reset_count + 1
    if self.mode == "free" then
      local baseline = clock.get_beat_sec() / self.period
      if self.reset_target == "floor" then
        self.phase_counter = 0.75 / baseline
      elseif self.reset_target == "ceiling" then
        self.phase_counter = 0.25 / baseline
      elseif self.reset_target == "mid: falling" then
        self.phase_counter = 0.5 / baseline
      elseif self.reset_target == "mid: rising" then
        self.phase_counter = baseline
      end
    else
      if self.reset_target == "floor" then
        self.phase_counter = 0.75 * self.period
      elseif self.reset_target == "ceiling" then
        self.phase_counter = 0.25 * self.period
      elseif self.reset_target == "mid: falling" then
        self.phase_counter = 0.5 * self.period
      elseif self.reset_target == "mid: rising" then
        self.phase_counter = self.period
      end
    end
  end

  -- lib/lfo.lua's change_period: a new period keeps the phase, so the
  -- phase counter is rescaled
  local function change_period(target, new_period)
    local new_phase_counter = target.phase_counter + (1 / target.ppqn)
    local new_phase
    local adjusted_phase_counter
    if target.mode == "clocked" then
      new_phase = new_phase_counter / target.period
      adjusted_phase_counter = (new_phase * new_period) - 1 / target.ppqn
    else
      new_phase = new_phase_counter * clock.get_beat_sec() / target.period
      adjusted_phase_counter = (new_phase * new_period / clock.get_beat_sec()) - 1 / target.ppqn
    end
    target.period = new_period
    target.phase_counter = adjusted_phase_counter
  end

  function LFO:set(var, arg)
    if var == nil then
      error("scripted LFO variable required")
    elseif var == "min" or var == "max" then
      self[var] = arg
      self.percentage = math.abs(self.min - self.max) * self.depth
      scale_lfo(self)
    elseif var == "depth" then
      self.depth = arg
      self.percentage = math.abs(self.min - self.max) * arg
      scale_lfo(self)
    elseif var == "baseline" then
      self.baseline = arg
      scale_lfo(self)
    elseif var == "ppqn" then
      -- change_ppqn (the library also sets its sprocket's division; the stub has none)
      self.ppqn = arg
    elseif var == "period" then
      change_period(self, arg)
    elseif arg == nil then
      error("scripted LFO argument required")
    elseif not self[var] then
      error("scripted LFO variable '" .. var .. "' not valid")
    else
      self[var] = arg
    end
  end

  function LFO:get(var)
    if var == nil then
      error("scripted LFO variable required")
    elseif not self[var] then
      error("scripted LFO variable '" .. var .. "' not valid")
    end
    return self[var]
  end

  local function lfo_params_visibility(state, id)
    for _, name in ipairs { "baseline", "phase", "offset", "depth", "scaled", "raw", "mode" } do
      params[state](params, "lfo_" .. name .. "_" .. id)
    end
    if state == "show" then
      if params:get("lfo_mode_" .. id) == 1 then
        params:hide("lfo_free_" .. id)
        params:show("lfo_clocked_" .. id)
      else
        params:hide("lfo_clocked_" .. id)
        params:show("lfo_free_" .. id)
      end
    else
      params:hide("lfo_clocked_" .. id)
      params:hide("lfo_free_" .. id)
    end
    for _, name in ipairs { "shape", "min", "max", "reset", "reset_target" } do
      params[state](params, "lfo_" .. name .. "_" .. id)
    end
    _menu.rebuild_params()
  end

  local function build_lfo_spec(instance, id, bound)
    params:add {
      type = "control",
      id = "lfo_" .. bound .. "_" .. id,
      name = "lfo " .. bound,
      controlspec = controlspec.new(instance.min, instance.max, instance.controlspec.warp, instance.controlspec.step,
        bound == "min" and instance.min or instance.max, instance.controlspec.units, instance.controlspec.quantum,
        instance.controlspec.wrap),
      formatter = instance.controlspec.formatter,
    }
    params:set_action("lfo_" .. bound .. "_" .. id, function(x) instance:set(bound, x) end)
  end

  local function lfo_bang(id)
    for _, name in ipairs { "depth", "min", "max", "baseline", "offset", "mode", "clocked", "free", "shape", "reset",
      "reset_target" } do
      params:lookup_param("lfo_" .. name .. "_" .. id):bang()
    end
  end

  local function change_offset(id, baseline)
    local offset_param = params:lookup_param("lfo_offset_" .. id)
    if baseline == "max" then
      offset_param.min, offset_param.max = -100, 0
    elseif baseline == "center" then
      offset_param.min, offset_param.max = -50, 50
    else
      offset_param.min, offset_param.max = 0, 100
    end
    params:set("lfo_offset_" .. id, 0)
  end

  function LFO:add_params(id, sep, group)
    if id == nil then
      print("! parameter id is required to add LFO parameters")
      return
    end
    if params.lookup["lfo_" .. id] ~= nil then
      print("! params for LFO " .. id .. " already added !")
      return
    end
    local instance = self

    if group then
      params:add_group("lfo_group_" .. id, group, sep ~= nil and params_per_entry + 1 or params_per_entry)
    end
    if sep then
      params:add_separator("lfo_sep_" .. sep, sep)
    end

    params:add_option("lfo_" .. id, "lfo state", {"off", "on"}, instance:get("enabled") + 1)
    params:set_action("lfo_" .. id, function(x)
      if x == 1 then
        lfo_params_visibility("hide", id)
        params:set("lfo_scaled_" .. id, "")
        params:set("lfo_raw_" .. id, "")
        instance:stop()
      elseif x == 2 then
        lfo_params_visibility("show", id)
        instance:start(true)
      end
      instance:set("enabled", x - 1)
      lfo_bang(id)
    end)

    params:add_option("lfo_shape_" .. id, "lfo shape", lfo_shapes, index_of(lfo_shapes, instance:get("shape")))
    params:set_action("lfo_shape_" .. id, function(x)
      instance:set("shape", params:lookup_param("lfo_shape_" .. id).options[x])
    end)

    params:add_number("lfo_depth_" .. id, "lfo depth", 0, 100, instance:get("depth") * 100,
      function(param) return param:get() .. "%" end)
    params:set_action("lfo_depth_" .. id, function(x)
      if x == 0 then
        params:set("lfo_scaled_" .. id, "")
        params:set("lfo_raw_" .. id, "")
      end
      instance:set("depth", x / 100)
    end)

    params:add_number("lfo_phase_" .. id, "lfo phase", 0, 100, instance:get("phase") * 100,
      function(param) return param:get() .. "%" end)
    params:set_action("lfo_phase_" .. id, function(x) instance:set("phase", x / 100) end)

    params:add_number("lfo_offset_" .. id, "lfo offset", -100, 100, instance:get("offset") * 100,
      function(param) return param:get() .. "%" end)
    params:set_action("lfo_offset_" .. id, function(x) instance:set("offset", x / 100) end)

    params:add_text("lfo_scaled_" .. id, "  scaled value", "")
    params:add_text("lfo_raw_" .. id, "  raw value", "")

    build_lfo_spec(instance, id, "min")
    build_lfo_spec(instance, id, "max")

    local baseline_options = {"from min", "from center", "from max"}
    params:add_option("lfo_baseline_" .. id, "lfo baseline", baseline_options,
      index_of(baseline_options, "from " .. instance:get("baseline")))
    params:set_action("lfo_baseline_" .. id, function(x)
      instance:set("baseline", (string.gsub(params:lookup_param("lfo_baseline_" .. id).options[x], "from ", "")))
      change_offset(id, instance:get("baseline"))
      _menu.rebuild_params()
    end)

    local mode_options = {"clocked", "free"}
    params:add_option("lfo_mode_" .. id, "lfo mode", mode_options, index_of(mode_options, instance:get("mode")))
    params:set_action("lfo_mode_" .. id, function(x)
      instance:set("mode", params:lookup_param("lfo_mode_" .. id).options[x])
      instance:set("period", x == 1 and (lfo_rates[params:get("lfo_clocked_" .. id)] * 4) or params:get("lfo_free_" .. id))
      if params:string("lfo_" .. id) == "on" then
        if x == 1 then
          params:hide("lfo_free_" .. id)
          params:show("lfo_clocked_" .. id)
        else
          params:hide("lfo_clocked_" .. id)
          params:show("lfo_free_" .. id)
        end
      end
      _menu.rebuild_params()
    end)

    -- as in the library: a clocked LFO's free-rate default resolves to nil
    -- (lfo_rates is indexed by a string), so the control starts at its minimum
    local current_period_as_rate = instance:get("mode") == "clocked"
      and lfo_rates[lfo_rates_as_strings[instance:get("period")]] or instance:get("period")
    params:add_option("lfo_clocked_" .. id, "lfo rate", lfo_rates_as_strings, index_of(lfo_rates, instance:get("period")))
    params:set_action("lfo_clocked_" .. id, function(x)
      if params:string("lfo_mode_" .. id) == "clocked" then instance:set("period", lfo_rates[x] * 4) end
    end)

    params:add {
      type = "control",
      id = "lfo_free_" .. id,
      name = "lfo rate",
      controlspec = controlspec.new(0.1, 300, "exp", 0.1, current_period_as_rate, "sec"),
    }
    params:set_action("lfo_free_" .. id, function(x)
      if params:string("lfo_mode_" .. id) == "free" then instance:set("period", x) end
    end)

    params:add_trigger("lfo_reset_" .. id, "reset lfo")
    params:set_action("lfo_reset_" .. id, function() instance:reset_phase() end)

    local reset_destinations = {"floor", "ceiling", "mid: rising", "mid: falling"}
    params:add_option("lfo_reset_target_" .. id, "reset lfo to", reset_destinations,
      index_of(reset_destinations, instance:get("reset_target")))
    params:set_action("lfo_reset_target_" .. id, function(x)
      instance:set("reset_target", params:lookup_param("lfo_reset_target_" .. id).options[x])
    end)

    params:hide("lfo_free_" .. id)

    params:lookup_param("lfo_" .. id):bang()
    instance.parameter_id = id
  end

  -- test helper: one process_lfo step with `raw` as the shape output (0..1)
  function lfo_context.tick(instance, raw)
    if instance.enabled ~= 1 then return end
    local min, max = instance.min, instance.max
    local offset = (max - min) * instance.offset
    if instance.shape ~= "random" then instance.raw = raw end
    local value = util.linlin(0, 1, min, min + instance.percentage, raw)
    if instance.depth <= 0 then return end
    if instance.baseline == "center" then
      value = util.linlin(0, 1, instance.scaled_min, instance.scaled_max, raw)
    elseif instance.baseline == "max" then
      value = util.linlin(0, 1, instance.scaled_max, instance.scaled_min, raw)
    end
    if instance.shape == "sine" or instance.shape == "tri" or instance.shape == "up" or instance.shape == "down" then
      instance.scaled = util.clamp(value, min, max) + offset
    elseif instance.shape == "square" then
      local square_value = value >= instance.mid and max or min
      square_value = util.linlin(min, max, instance.scaled_min, instance.scaled_max, square_value)
      square_value = util.clamp(square_value, instance.scaled_min, instance.scaled_max)
      instance.scaled = square_value + offset
      instance.raw = util.linlin(instance.scaled_min, instance.scaled_max, 0, 1, square_value)
    elseif instance.shape == "random" then
      local previous = instance.rand_value
      instance.rand_value = value >= instance.mid and max or min
      if previous ~= instance.rand_value then
        local random_value = util.linlin(min, max, instance.scaled_min, instance.scaled_max,
          math.random(math.floor(min * 100), math.floor(max * 100)) / 100)
        random_value = util.clamp(random_value, min, max)
        instance.scaled = random_value + offset
        instance.raw = util.linlin(instance.scaled_min, instance.scaled_max, 0, 1, random_value)
      end
    end
    instance.action(instance.scaled, instance.raw)
    if instance.parameter_id ~= nil then
      params:set("lfo_scaled_" .. instance.parameter_id, util.round(instance.scaled, 0.01))
      params:set("lfo_raw_" .. instance.parameter_id, util.round(instance.raw, 0.01))
    end
  end

  return LFO
end
