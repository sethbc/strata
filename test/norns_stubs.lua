-- norns_stubs.lua
-- Minimal stand-ins for the norns Lua runtime, used by test/run.lua to load
-- strata.lua off-device. Behaviour mirrors norns' own implementations
-- (lua/core/params/*.lua, controlspec.lua, grid.lua, arc.lua, clock.lua,
-- lib/util.lua, lib/tabutil.lua) wherever the script depends on it:
--   * control params quantize to controlspec.step and only fire their action
--     when the stored value changes
--   * number params clamp (but do not round) and fire on change
--   * option params store a floored, clamped index; file params a path
--     string, text params any value; triggers (and trigger binaries) fire on
--     every set; groups count the params that follow them and cannot nest
--   * param.t holds norns' numeric type codes (params.tOPTION etc.)
--   * lfo (stub_lfo.lua), midi (stub_midi.lua), poll, fileselect and musicutil
--     follow lib/lfo.lua, core/midi.lua, core/poll.lua, lib/fileselect.lua and
--     lib/musicutil.lua
--   * clock.run resumes the coroutine immediately; sleep/sync yield;
--     clock.get_beat_sec follows clock_tempo. Two ways to drive the clocks:
--     clock.advance() resumes every pending coroutine once, whatever it is
--     waiting for (one scheduler tick, util.time() stands still);
--     clock.run_for(seconds[, latency]) runs time-ordered, the way norns'
--     scheduler does: it resumes each coroutine when its sleep or sync is
--     due (earliest first, ties in the order they yielded), moving
--     util.time() to that moment, until `seconds` have passed. `latency`
--     (default 0) is a scheduling delay added to every wake-up, so a clock
--     that sleeps many short steps falls behind one that sleeps once
--   * util.time stands still until a test calls context.set_time(seconds)
--   * the screen records texts, lines and rects (for layout checks)
--   * grid/arc device events fire both device.key and vports[port].key
--   * tab.load runs the file chunk unprotected
-- The engine stub validates every engine.* call against the addCommand
-- signatures parsed from lib/Engine_Strata.sc.

local stubs = {}

local function shallow_copy(source)
  local copy = {}
  for key, value in pairs(source) do copy[key] = value end
  return copy
end

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

---------------------------------------------------------------------------
-- engine command signatures (parsed from the SC engine)
---------------------------------------------------------------------------

function stubs.parse_engine_signatures(sc_path)
  local file = assert(io.open(sc_path, "r"))
  local source = file:read("*a")
  file:close()
  local signatures = {}
  for name, signature in source:gmatch('addCommand%(%s*\\(%w+)%s*,%s*"([^"]*)"') do
    signatures[name] = signature
  end
  return signatures
end

-- engine polls (this.addPoll(\name, ...) in the SC engine)
function stubs.parse_engine_polls(sc_path)
  local file = assert(io.open(sc_path, "r"))
  local source = file:read("*a")
  file:close()
  local names = {}
  for name in source:gmatch('addPoll%(%s*\\(%w+)') do table.insert(names, name) end
  for name in source:gmatch('addPoll%(%s*"([^"]+)"') do table.insert(names, name) end
  return names
end

---------------------------------------------------------------------------
-- util
---------------------------------------------------------------------------

local function make_util()
  local util = {}
  -- lib/util.lua: util.time() is the wall clock in seconds. The stub's clock
  -- stands still; tests move it with context.set_time(seconds)
  util.stub_now = 0
  function util.time() return util.stub_now end
  function util.clamp(n, min, max) return math.min(max, math.max(n, min)) end
  function util.linlin(slo, shi, dlo, dhi, f)
    if f <= slo then return dlo
    elseif f >= shi then return dhi
    else return (f - slo) / (shi - slo) * (dhi - dlo) + dlo end
  end
  function util.linexp(slo, shi, dlo, dhi, f)
    if f <= slo then return dlo
    elseif f >= shi then return dhi
    else return (dhi / dlo) ^ ((f - slo) / (shi - slo)) * dlo end
  end
  function util.explin(slo, shi, dlo, dhi, f)
    if f <= slo then return dlo
    elseif f >= shi then return dhi
    else return math.log(f / slo) / math.log(shi / slo) * (dhi - dlo) + dlo end
  end
  function util.round(number, quant)
    if quant == 0 then return number end
    return math.floor(number / (quant or 1) + 0.5) * (quant or 1)
  end
  function util.file_exists(name)
    local file = io.open(name, "r")
    if file ~= nil then io.close(file) return true end
    return false
  end
  function util.make_dir(path)
    os.execute("mkdir -p '" .. path .. "'")
  end
  -- norns runs `ls -pL --group-directories-first`; BSD ls lacks the last flag
  function util.scandir(directory)
    local listing = {}
    local pipe = io.popen('ls -pL "' .. directory .. '" 2>/dev/null')
    for filename in pipe:read("*a"):gmatch("[^\r\n]+") do table.insert(listing, filename) end
    pipe:close()
    return listing
  end
  function util.os_capture(cmd, raw)
    local pipe = io.popen(cmd)
    local output = pipe:read("*a")
    pipe:close()
    if raw then return output end
    output = string.gsub(output, "^%s+", "")
    output = string.gsub(output, "%s+$", "")
    output = string.gsub(output, "[\n\r]+", " ")
    return output
  end
  return util
end

---------------------------------------------------------------------------
-- controlspec
---------------------------------------------------------------------------

local function make_controlspec(util)
  local ControlSpec = {}
  ControlSpec.__index = ControlSpec

  function ControlSpec.new(min, max, warp, step, default, units, quantum, wrap)
    local spec = setmetatable({}, ControlSpec)
    spec.minval = min or 0
    spec.maxval = max or 1
    spec.warp_name = (warp == "exp") and "exp" or "lin"
    spec.step = step or 0
    spec.default = default or spec.minval
    spec.units = units or ""
    spec.quantum = quantum or 0.01
    spec.wrap = wrap or false
    return spec
  end

  function ControlSpec:map(value)
    local clamped = util.clamp(value, 0, 1)
    local mapped
    if self.warp_name == "exp" then
      mapped = util.linexp(0, 1, self.minval, self.maxval, clamped)
    else
      mapped = util.linlin(0, 1, self.minval, self.maxval, clamped)
    end
    return util.round(mapped, self.step)
  end

  function ControlSpec:unmap(value)
    local clamped = util.clamp(util.round(value, self.step), math.min(self.minval, self.maxval),
      math.max(self.minval, self.maxval))
    if self.warp_name == "exp" then
      return util.explin(self.minval, self.maxval, 0, 1, clamped)
    end
    return util.linlin(self.minval, self.maxval, 0, 1, clamped)
  end

  return { new = ControlSpec.new }
end

---------------------------------------------------------------------------
-- params
---------------------------------------------------------------------------

-- norns stores numeric type codes in param.t (lua/core/paramset.lua); params:add
-- still takes the type name as a string. This is the one table of codes: the
-- locals below and ParamSet's tSEPARATOR ... tBINARY are built from it.
local PARAM_TYPE_CODES = {
  separator = 0, number = 1, option = 2, control = 3, file = 4, taper = 5, trigger = 6, group = 7, text = 8,
  binary = 9,
}
stubs.PARAM_TYPE_CODES = PARAM_TYPE_CODES
local codes = PARAM_TYPE_CODES
local tSEPARATOR, tNUMBER, tOPTION, tCONTROL = codes.separator, codes.number, codes.option, codes.control
local tFILE, tTRIGGER, tGROUP, tTEXT, tBINARY = codes.file, codes.trigger, codes.group, codes.text, codes.binary

local function make_params(util, controlspec)
  -- ParamSet.tSEPARATOR etc., reachable as params.tOPTION like in norns
  local ParamSet = {}
  for type_name, code in pairs(PARAM_TYPE_CODES) do
    ParamSet["t" .. type_name:upper()] = code
  end
  ParamSet.__index = ParamSet

  -- open_group counts the params still to come in the current group, like
  -- norns' ParamSet.group (groups cannot nest)
  local paramset = setmetatable({ params = {}, lookup = {}, action_log = {}, open_group = 0 }, ParamSet)

  local bang

  local function new_param(args)
    -- norns prints "unknown type" and adds nothing; the stub fails loudly
    if PARAM_TYPE_CODES[args.type] == nil then
      error("stub params: unknown param type " .. tostring(args.type))
    end
    local param = { id = args.id, name = args.name or args.id, t = PARAM_TYPE_CODES[args.type],
      action = args.action or function() end, hidden = false }
    if args.type == "control" then
      param.controlspec = args.controlspec or controlspec.new(0, 1, "lin", 0, 0)
      param.raw = param.controlspec:unmap(param.controlspec.default)
      param.formatter = args.formatter
    elseif args.type == "number" then
      param.min = args.min or -2147483648
      param.max = args.max or 2147483647
      param.default = args.default or 0
      param.value = param.default
      param.formatter = args.formatter
      param.wrap = args.wrap and param.min ~= param.max or false
    elseif args.type == "option" then
      param.options = {}
      local count = 0
      for key, value in pairs(args.options or {}) do
        param.options[key] = value
        count = count + 1
      end
      param.count = count
      param.default = args.default or 1
      param.selected = param.default
    elseif args.type == "binary" then
      -- norns reads o.behavior before setting it, so the default is always 0
      param.default = args.default or 0
      param.value = param.default
      param.behavior = args.behavior or "trigger"
    elseif args.type == "file" then
      param.path = args.path or "-"
    elseif args.type == "text" then
      param.text = args.text or ""
    elseif args.type == "group" then
      param.n = args.n or 1
    elseif args.type == "trigger" or args.type == "separator" then
      param.value = nil
    else
      error("stub params: unsupported param type " .. tostring(args.type))
    end
    -- param objects expose the norns param methods (get/set/bang/string/delta)
    param.get = function() return ParamSet.get(paramset, param.id) end
    param.set = function(_, value, silent) return ParamSet.set(paramset, param.id, value, silent) end
    param.bang = function() bang(param) end
    param.string = function() return ParamSet.string(paramset, param.id) end
    param.delta = function(_, delta) return ParamSet.delta(paramset, param.id, delta) end
    return param
  end

  -- separators and groups may reuse their own kind's id; any other collision is an error
  local function register(param)
    local existing = paramset.lookup[param.id]
    if existing then
      if param.t == tSEPARATOR or param.t == tGROUP then
        if existing.t ~= param.t then
          error((param.t == tGROUP and "group" or "separator") .. " collides with param: " .. param.id)
        end
      else
        error("parameter ID collision: " .. param.id)
      end
    end
    table.insert(paramset.params, param)
    paramset.lookup[param.id] = param
    paramset.open_group = paramset.open_group - 1
    return param
  end

  function ParamSet:add(args)
    assert(args.id, "params:add requires an id")
    if args.type == "group" then
      return self:add_group(args.id, args.name, args.n)
    end
    return register(new_param(args))
  end

  function ParamSet:add_separator(id, name)
    register(new_param({ id = id or "separator", name = name, type = "separator" }))
  end

  function ParamSet:add_group(id, name, n)
    id = id or "group"
    local count = type(name) == "number" and name or (n or 1)
    if self.open_group >= 1 then
      error("stub params: paramset cannot nest GROUPs (" .. id .. " inside an open group)")
    end
    local group_name = type(name) ~= "number" and name or id
    register(new_param({ id = id, name = group_name, type = "group", n = count }))
    self.open_group = count
  end

  function ParamSet:add_number(id, name, min, max, default, formatter, wrap)
    return self:add { type = "number", id = id, name = name, min = min, max = max, default = default,
      formatter = formatter, wrap = wrap }
  end

  function ParamSet:add_option(id, name, options, default)
    return self:add { type = "option", id = id, name = name, options = options, default = default }
  end

  function ParamSet:add_control(id, name, spec, formatter)
    return self:add { type = "control", id = id, name = name, controlspec = spec, formatter = formatter }
  end

  function ParamSet:add_file(id, name, path)
    return self:add { type = "file", id = id, name = name, path = path }
  end

  function ParamSet:add_text(id, name, text)
    return self:add { type = "text", id = id, name = name, text = text }
  end

  function ParamSet:add_trigger(id, name)
    return self:add { type = "trigger", id = id, name = name }
  end

  function ParamSet:add_binary(id, name, behavior, default)
    return self:add { type = "binary", id = id, name = name, behavior = behavior, default = default }
  end

  function ParamSet:lookup_param(id)
    local param = self.lookup[id] or (type(id) == "number" and self.params[id])
    if not param then error("invalid paramset index: " .. tostring(id)) end
    return param
  end

  function ParamSet:set_action(id, func)
    self:lookup_param(id).action = func
  end

  function ParamSet:hide(id) self:lookup_param(id).hidden = true end
  function ParamSet:show(id) self:lookup_param(id).hidden = false end
  function ParamSet:visible(id) return not self:lookup_param(id).hidden end

  bang = function(param)
    if param.t == tSEPARATOR or param.t == tGROUP then return end
    if param.t == tTRIGGER then param.action(); return end
    if param.t == tBINARY and param.behavior == "trigger" then
      param.action(1)
      param.value = 0
      return
    end
    param.action(ParamSet.get(paramset, param.id))
  end

  function ParamSet:get(id)
    local param = self:lookup_param(id)
    if param.t == tCONTROL then return param.controlspec:map(param.raw) end
    if param.t == tOPTION then return param.selected end
    if param.t == tFILE then return param.path end
    if param.t == tTEXT then return param.text end
    if param.t == tGROUP then return param.n end
    return param.value
  end

  local function require_number(id, value)
    if type(value) ~= "number" then
      error("params:set(" .. id .. ") with non-number value " .. tostring(value), 3)
    end
  end

  -- each type follows its lua/core/params/*.lua set(): actions fire only on a
  -- change, except triggers (and trigger-behaviour binaries), which always fire
  function ParamSet:set(id, value, silent)
    local param = self:lookup_param(id)
    local changed = false
    if param.t == tCONTROL then
      require_number(id, value)
      local raw = util.clamp(param.controlspec:unmap(value), 0, 1)
      if param.raw ~= raw then param.raw = raw; changed = true end
    elseif param.t == tNUMBER then
      require_number(id, value)
      if param.wrap then
        local range = param.max - param.min + 1
        while value > param.max do value = value - range end
        while value < param.min do value = value + range end
      end
      local clamped = util.clamp(value, param.min, param.max)
      if param.value ~= clamped then param.value = clamped; changed = true end
    elseif param.t == tOPTION then
      require_number(id, value)
      local selected = util.clamp(math.floor(value), 1, param.count)
      if param.selected ~= selected then param.selected = selected; changed = true end
    elseif param.t == tBINARY then
      if value == nil then value = 1 end
      require_number(id, value)
      if param.behavior == "trigger" then
        changed = value > 0
      else
        local state = value > 0 and 1 or 0
        if param.value ~= state then param.value = state; changed = true end
      end
    elseif param.t == tTRIGGER then
      -- norns' Trigger:set has no silent argument
      bang(param)
      return
    elseif param.t == tFILE then
      if type(value) ~= "string" then
        error("params:set(" .. id .. ") file param needs a path string, got " .. tostring(value), 2)
      end
      if param.path ~= value then param.path = value; changed = true end
    elseif param.t == tTEXT then
      if param.text ~= value then param.text = value; changed = true end
    end
    if changed and not silent then bang(param) end
  end

  function ParamSet:delta(id, delta)
    local param = self:lookup_param(id)
    if param.t == tCONTROL then
      local raw = util.clamp(param.raw + delta * param.controlspec.quantum, 0, 1)
      if param.raw ~= raw then param.raw = raw; bang(param) end
    elseif param.t == tNUMBER then
      self:set(id, param.value + delta)
    elseif param.t == tOPTION then
      local step = delta < 0 and math.floor(delta) or math.ceil(delta)
      self:set(id, param.selected + step)
    elseif param.t == tBINARY then
      if param.behavior == "momentary" then
        self:set(id, delta)
      elseif param.behavior == "toggle" then
        if delta ~= 0 then self:set(id, param.value == 0 and 1 or 0) end
      elseif delta ~= 0 then
        bang(param)
      end
    end
  end

  function ParamSet:string(id)
    local param = self:lookup_param(id)
    if param.formatter then return param.formatter(param) end
    if param.t == tOPTION then return param.options[param.selected] end
    if param.t == tFILE then
      if param.path == "-" then return "-" end
      return param.path:match("[^/]*$")
    end
    if param.t == tTEXT then return param.text end
    if param.t == tTRIGGER then return "" end
    if param.t == tGROUP then return param.name end
    return tostring(self:get(id))
  end

  -- like norns: everything but triggers (and idle trigger binaries) bangs
  function ParamSet:bang()
    for _, param in ipairs(self.params) do
      if param.t ~= tTRIGGER and not (param.t == tBINARY and param.behavior == "trigger" and param.value == 0) then
        bang(param)
      end
    end
  end

  -- system params that exist before any script runs
  paramset:add { type = "number", id = "clock_tempo", name = "tempo", min = 1, max = 300, default = 120 }
  paramset:add { type = "control", id = "reverb", name = "reverb", controlspec = controlspec.new(0, 1, "lin", 1, 1) }

  return paramset
end

---------------------------------------------------------------------------
-- clock
---------------------------------------------------------------------------

local function make_clock(util)
  -- wake_at[id] = {time, order}: when a pending coroutine's sleep or sync is
  -- due (util.time() seconds), and a counter for ties (first yielded first)
  local clock = { threads = {}, next_id = 1, sleep_log = {}, wake_at = {} }
  local wake_order = 0

  -- lua/core/clock.lua yields (mode, time); matron schedules a sleep at
  -- now + time and a sync at the next multiple of `beats` on the beat
  -- timeline (clock_scheduler.cc: ceil((beat + epsilon) / sync) * sync).
  -- The stub's beat timeline is util.time() / clock.get_beat_sec()
  local function wake_time(mode, amount)
    local now = util.time()
    if mode == "sleep" then return now + (amount or 0) end
    if mode == "sync" then
      local beat_sec = clock.get_beat_sec()
      local beats = amount or 1
      local next_beat = math.ceil((now / beat_sec + 1e-7) / beats) * beats
      return next_beat * beat_sec
    end
    return now
  end

  local function resume(coro_id, ...)
    local coro = clock.threads[coro_id]
    if not coro then return end
    clock.wake_at[coro_id] = nil
    local ok, mode, amount = coroutine.resume(coro, ...)
    if not ok then error(mode, 0) end
    if coroutine.status(coro) == "dead" then
      clock.threads[coro_id] = nil
    else
      table.insert(clock.sleep_log, { id = coro_id, mode = mode, amount = amount })
      if clock.threads[coro_id] == coro then  -- not cancelled from inside
        wake_order = wake_order + 1
        clock.wake_at[coro_id] = { time = wake_time(mode, amount), order = wake_order }
      end
    end
  end

  function clock.run(func, ...)
    local coro_id = clock.next_id
    clock.next_id = clock.next_id + 1
    clock.threads[coro_id] = coroutine.create(func)
    resume(coro_id, ...)
    return coro_id
  end

  function clock.cancel(coro_id)
    clock.threads[coro_id] = nil
    clock.wake_at[coro_id] = nil
  end

  function clock.sleep(seconds)
    return coroutine.yield("sleep", seconds)
  end

  function clock.sync(beats)
    return coroutine.yield("sync", beats)
  end

  -- lua/core/clock.lua: seconds per beat at the current tempo
  function clock.get_beat_sec()
    return 60 / params:get("clock_tempo")
  end

  -- test helper: resume every pending coroutine once (one scheduler tick)
  function clock.advance()
    local ids = {}
    for coro_id in pairs(clock.threads) do table.insert(ids, coro_id) end
    table.sort(ids)
    for _, coro_id in ipairs(ids) do resume(coro_id) end
  end

  -- test helper: run the clocks time-ordered for `seconds`. Each step resumes
  -- the coroutine due first (by wake time, then yield order), at its wake
  -- time plus `latency` (never earlier than util.time()), and moves
  -- util.time() there. Coroutines started or rescheduled meanwhile join in.
  -- util.time() ends at the start time plus `seconds`
  function clock.run_for(seconds, latency)
    latency = latency or 0
    local end_time = util.time() + seconds
    local resumes = 0
    while true do
      local due_id, due
      for coro_id, wake in pairs(clock.wake_at) do
        if not due or wake.time < due.time or (wake.time == due.time and wake.order < due.order) then
          due_id, due = coro_id, wake
        end
      end
      if not due or due.time + latency > end_time then break end
      resumes = resumes + 1
      if resumes > 1e6 then error("clock.run_for: a coroutine never sleeps", 2) end
      util.stub_now = math.max(util.time(), due.time + latency)
      resume(due_id)
    end
    util.stub_now = end_time
  end

  -- test helper: resume one coroutine
  function clock.resume_thread(coro_id) resume(coro_id) end

  function clock.pending_count()
    local count = 0
    for _ in pairs(clock.threads) do count = count + 1 end
    return count
  end

  return clock
end

---------------------------------------------------------------------------
-- metro
---------------------------------------------------------------------------

local function make_metro()
  local metro = { all = {} }
  function metro.init()
    local timer = { time = 1, running = false, event = nil }
    function timer:start() self.running = true end
    function timer:stop() self.running = false end
    table.insert(metro.all, timer)
    return timer
  end
  return metro
end

---------------------------------------------------------------------------
-- grid / arc (vports + devices, mirroring lua/core/grid.lua and arc.lua)
---------------------------------------------------------------------------

local function make_led_device(cols, rows)
  local device = { cols = cols, rows = rows, leds = {}, refresh_count = 0, port = nil }
  function device:all(level)
    for x = 1, self.cols do
      self.leds[x] = {}
      for y = 1, self.rows do self.leds[x][y] = level end
    end
  end
  function device:led(x, y, level)
    if x < 1 or x > self.cols or y < 1 or y > self.rows then
      error(string.format("grid led out of bounds: %d,%d on %dx%d", x, y, self.cols, self.rows))
    end
    if type(level) ~= "number" or level < 0 or level > 15 then
      error("grid led level out of range: " .. tostring(level))
    end
    self.leds[x] = self.leds[x] or {}
    self.leds[x][y] = level
  end
  function device:refresh() self.refresh_count = self.refresh_count + 1 end
  function device:get_led(x, y) return (self.leds[x] and self.leds[x][y]) or 0 end
  device:all(0)
  return device
end

local function wrap_method(method)
  return function(self, ...)
    if self.device then return self.device[method](self.device, ...) end
  end
end

local function make_grid()
  local grid = { vports = {}, devices = {} }
  for port = 1, 4 do
    grid.vports[port] = {
      name = "none", device = nil, key = nil, cols = 0, rows = 0,
      led = wrap_method("led"), all = wrap_method("all"), refresh = wrap_method("refresh"),
    }
  end
  function grid.connect(port) return grid.vports[port or 1] end
  function grid.add(device) end
  function grid.remove(device) end

  -- test helper: plug a device of the given size into a port
  function grid.plug(port, cols, rows)
    local device = make_led_device(cols, rows)
    device.port = port
    grid.devices[port] = device
    local vport = grid.vports[port]
    vport.device = device
    vport.cols = cols
    vport.rows = rows
    vport.name = "grid " .. port
    if grid.add then grid.add(device) end
    return device
  end

  function grid.unplug(port)
    local device = grid.devices[port]
    if not device then return end
    if grid.remove then grid.remove(device) end
    grid.devices[port] = nil
    local vport = grid.vports[port]
    vport.device = nil
    vport.cols = 0
    vport.rows = 0
  end

  -- test helper: deliver a key event the way _norns.grid.key does
  function grid.press(port, x, y, z)
    local device = grid.devices[port]
    assert(device, "no grid on port " .. port)
    if device.key then device.key(x, y, z) end
    if device.port and grid.vports[device.port].key then
      grid.vports[device.port].key(x, y, z)
    end
  end

  return grid
end

local function make_arc()
  local util = make_util()
  local arc = { vports = {}, devices = {} }
  for port = 1, 4 do
    arc.vports[port] = {
      name = "none", device = nil, delta = nil, key = nil,
      led = wrap_method("led"), all = wrap_method("all"), refresh = wrap_method("refresh"),
      segment = wrap_method("segment"),
    }
  end
  function arc.connect(port) return arc.vports[port or 1] end
  function arc.add(device) end
  function arc.remove(device) end

  function arc.plug(port)
    local device = { port = port, segments = {}, refresh_count = 0, cleared = 0 }
    function device:all(level)
      self.cleared = self.cleared + 1
      self.segments = {}
    end
    -- Port of norns' Arc:segment (lua/core/arc.lua): angles reduce modulo 2*pi and
    -- each of the 64 LEDs gets round(overlap / LED width * level), so a full
    -- turn (0 -> 2*pi) lights nothing, as on a real arc. `leds` holds the levels
    function device:segment(ring, from, to, level)
      local tau = math.pi * 2
      local function overlap(a, b, c, d)
        if a > b then
          return overlap(a, tau, c, d) + overlap(0, b, c, d)
        elseif c > d then
          return overlap(a, b, c, tau) + overlap(a, b, 0, d)
        else
          return math.max(0, math.min(b, d) - math.max(a, c))
        end
      end
      local leds = {}
      local led_width = tau / 64
      for i = 1, 64 do
        local o = overlap(from % tau, to % tau, led_width * (i - 1) % tau, led_width * i % tau)
        leds[i] = util.round(o / led_width * level)
      end
      self.segments[ring] = { from = from, to = to, level = level, leds = leds }
    end
    function device:led() end
    function device:refresh() self.refresh_count = self.refresh_count + 1 end
    arc.devices[port] = device
    arc.vports[port].device = device
    if arc.add then arc.add(device) end
    return device
  end

  function arc.unplug(port)
    local device = arc.devices[port]
    if not device then return end
    if arc.remove then arc.remove(device) end
    arc.devices[port] = nil
    arc.vports[port].device = nil
  end

  function arc.turn(port, ring, delta)
    local device = arc.devices[port]
    if device.delta then device.delta(ring, delta) end
    if device.port and arc.vports[device.port].delta then arc.vports[device.port].delta(ring, delta) end
  end

  function arc.push(port, button, state)
    local device = arc.devices[port]
    if device.key then device.key(button, state) end
    if device.port and arc.vports[device.port].key then arc.vports[device.port].key(button, state) end
  end

  return arc
end

---------------------------------------------------------------------------
-- encoders (norns.enc.accel/sens, mirroring lua/core/encoders.lua)
---------------------------------------------------------------------------

local function make_encoders()
  -- lua/core/script.lua resets every script to accel on, sensitivity 2
  local encoders = { accel = { true, true, true }, sens = { 2, 2, 2 }, tick = { 0, 0, 0 } }
  local api = {}
  function api.accel(n, enabled)
    for k = 1, 3 do
      if n == 0 or n == k then encoders.accel[k] = enabled; encoders.tick[k] = 0 end
    end
  end
  function api.sens(n, sensitivity)
    for k = 1, 3 do
      if n == 0 or n == k then
        encoders.sens[k] = math.min(16, math.max(1, sensitivity)); encoders.tick[k] = 0
      end
    end
  end
  encoders.api = api

  -- test helper: one hardware encoder event the way encoders.process_with_accel
  -- handles it; `interval` is the time since the previous event on that encoder
  function encoders.deliver(n, delta, interval)
    if encoders.accel[n] then
      if interval < 0.005 then delta = delta * 6
      elseif interval < 0.01 then delta = delta * 4
      elseif interval < 0.02 then delta = delta * 3
      elseif interval < 0.03 then delta = delta * 2
      end
    end
    encoders.tick[n] = encoders.tick[n] + delta
    if math.abs(encoders.tick[n]) >= encoders.sens[n] then
      local value = encoders.tick[n] / encoders.sens[n]
      value = (value > 0) and math.floor(value) or math.ceil(value)
      _G.enc(n, value)
      encoders.tick[n] = math.fmod(encoders.tick[n], encoders.sens[n])
    end
  end

  return encoders
end

---------------------------------------------------------------------------
-- screen / UI
---------------------------------------------------------------------------

-- Approximate advance of norns' default font (04B_03 at size 8): capitals
-- about 6 px, brackets/colon/period about 4 px, everything else 5 px. The
-- stub's screen.text_extents and the layout tests both use it. It counts
-- UTF-8 characters, not bytes, so a multi-byte glyph such as "●" is one.
function stubs.text_width(text)
  local width = 0
  for char in text:gmatch("[^\128-\191][\128-\191]*") do
    if char:match("%u") then
      width = width + 6
    elseif char:match("[%[%]%.:]") then
      width = width + 4
    else
      width = width + 5
    end
  end
  return width
end

local function make_screen()
  local screen = { texts = {}, lines = {}, rects = {}, cursor_x = 0, cursor_y = 0, current_level = 15 }
  function screen.clear() screen.texts = {}; screen.lines = {}; screen.rects = {} end
  function screen.level(level) screen.current_level = level end
  function screen.move(x, y) screen.cursor_x = x; screen.cursor_y = y end
  -- each drawn string is recorded with its position, alignment and level
  local function record_text(str, align)
    table.insert(screen.texts, { x = screen.cursor_x, y = screen.cursor_y, text = tostring(str),
      align = align, level = screen.current_level })
  end
  function screen.text(str) record_text(str, "left") end
  function screen.text_right(str) record_text(str, "right") end
  function screen.text_center(str) record_text(str, "center") end
  -- lua/core/screen.lua: text_extents(str) returns width, height
  function screen.text_extents(str) return stubs.text_width(tostring(str)), 8 end
  -- lines and rectangles are recorded too (from/to points, x/y/w/h), so
  -- tests can check that drawings stay in their area
  function screen.line(x, y)
    table.insert(screen.lines, { x1 = screen.cursor_x, y1 = screen.cursor_y, x2 = x, y2 = y,
      level = screen.current_level })
    screen.cursor_x = x; screen.cursor_y = y
  end
  function screen.rect(x, y, w, h)
    table.insert(screen.rects, { x = x, y = y, w = w, h = h, level = screen.current_level })
  end
  function screen.stroke() end
  function screen.fill() end
  function screen.update() end
  function screen.font_size() end
  function screen.font_face() end
  return screen
end

local function make_ui(util, screen)
  local UI = { ScrollingList = {} }
  UI.ScrollingList.__index = UI.ScrollingList
  function UI.ScrollingList.new(x, y, index, entries)
    assert(x and y and index and entries, "UI.ScrollingList.new requires all parameters")
    return setmetatable({ x = x, y = y, index = index, entries = entries,
      num_visible = 5, num_above_selected = 1, text_align = "left", active = true }, UI.ScrollingList)
  end
  -- lua/lib/ui.lua's ScrollingList:redraw, unchanged: row i at
  -- y + 5 + (i - 1) * 11, the selected entry at level 15 and the rest at 3,
  -- an empty string where the scroll offset runs past either end
  function UI.ScrollingList:redraw()
    local num_entries = #self.entries
    local scroll_offset = self.index - 1 - math.max(self.index - (num_entries - 2), 0)
    scroll_offset = scroll_offset - util.linlin(num_entries - self.num_above_selected, num_entries,
      self.num_above_selected, 0, self.index - 1) -- For end of list

    for i = 1, self.num_visible do
      if self.active and self.index == i + scroll_offset then screen.level(15)
      else screen.level(3) end
      screen.move(self.x, self.y + 5 + (i - 1) * 11)
      local entry = self.entries[i + scroll_offset] or ""
      if self.text_align == "center" then
        screen.text_center(entry)
      elseif self.text_align == "right" then
        screen.text_right(entry)
      else
        screen.text(entry)
      end
    end
    screen.fill()
  end
  return UI
end

---------------------------------------------------------------------------
-- tab (tabutil save/load)
---------------------------------------------------------------------------

local function make_tab()
  local tab = {}

  -- simple serializer; only round-trip fidelity matters for the tests
  local function serialize(value, indent)
    local value_type = type(value)
    if value_type == "table" then
      local keys = {}
      for key in pairs(value) do table.insert(keys, key) end
      table.sort(keys, function(left, right)
        if type(left) == type(right) then return left < right end
        return type(left) == "number"
      end)
      local parts = {}
      for _, key in ipairs(keys) do
        local key_text = type(key) == "number" and ("[" .. key .. "]") or ("[" .. string.format("%q", key) .. "]")
        table.insert(parts, indent .. "  " .. key_text .. " = " .. serialize(value[key], indent .. "  "))
      end
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    elseif value_type == "string" then
      return string.format("%q", value)
    else
      return tostring(value)
    end
  end

  function tab.save(tbl, filename)
    local file, err = io.open(filename, "wb")
    if err then return err end
    file:write("return " .. serialize(tbl, ""))
    file:close()
  end

  -- like norns: the loaded chunk runs unprotected
  function tab.load(filename)
    local chunk, err = loadfile(filename)
    if err then return nil, err end
    return chunk()
  end

  return tab
end

---------------------------------------------------------------------------
-- poll (lua/core/poll.lua)
---------------------------------------------------------------------------

-- polls CroneAudioContext registers before any engine loads
local SYSTEM_POLLS = { "cpu_peak", "cpu_avg", "amp_in_l", "amp_in_r", "amp_out_l", "amp_out_r",
  "pitch_in_l", "pitch_in_r" }

local function make_poll(engine_polls)
  local poll = { polls = {} }
  local function register(name)
    local entry = { name = name, callback = nil, time = 0.25, running = false }
    function entry:start() self.running = true end
    function entry:stop() self.running = false end
    poll.polls[name] = entry
  end
  for _, name in ipairs(SYSTEM_POLLS) do register(name) end
  for _, name in ipairs(engine_polls or {}) do register(name) end

  -- like norns: only registered polls exist; anything else returns nil
  function poll.set(name, callback)
    local entry = poll.polls[name]
    if entry then entry.callback = callback end
    return entry
  end

  -- test helper: deliver a value the way a running poll does
  function poll.fire(name, value)
    local entry = poll.polls[name]
    assert(entry, "no poll named " .. tostring(name))
    if entry.running and entry.callback then entry.callback(value) end
  end

  return poll
end

---------------------------------------------------------------------------
-- fileselect (lib/fileselect.lua): records the request instead of a menu.
-- A module, not a global: scripts get it from require "fileselect", as
-- norns' own files do. From play mode the real fs.enter calls
-- norns.menu.init(), whose _menu.set_mode(false) puts the script's redraw
-- back in the global `redraw` and calls it; fs.exit does the same before it
-- calls the callback with the chosen path or "cancel". The stub makes those
-- redraw() calls too, but does not reroute key/enc (tests keep pressing the
-- script's keys while the selector is "open"). fs.redraw draws the file
-- list; the stub counts the calls in `redraws` and draws nothing.
---------------------------------------------------------------------------

local function make_fileselect()
  local fileselect = { last = nil, redraws = 0 }
  local entered = false  -- tests reset `last`; the real module keeps its list
  local function menu_init_redraw()
    if not norns.menu.status() and type(redraw) == "function" then redraw() end
  end
  function fileselect.redraw()
    -- the real one draws fs.list, which fs.enter sets up
    assert(entered, "fileselect.redraw before fileselect.enter")
    fileselect.redraws = fileselect.redraws + 1
  end
  function fileselect.enter(folder, callback, filter)
    entered = true
    fileselect.last = { folder = folder, callback = callback, filter = filter }
    menu_init_redraw()
    fileselect.redraw()
  end
  -- Test helper: close the selector the way fs.exit does, with `path`
  -- chosen, or cancelled when path is nil
  function fileselect.close(path)
    local request = assert(fileselect.last, "the file selector is not open")
    menu_init_redraw()
    request.callback(path or "cancel")
  end
  return fileselect
end

---------------------------------------------------------------------------
-- install / reset
---------------------------------------------------------------------------

-- Installs fresh stubs as globals. Returns a context table with handles to
-- the recorders and helpers.
function stubs.install(options)
  local util = make_util()
  local controlspec = make_controlspec(util)
  local context = {
    signatures = options.signatures,
    engine_calls = {},
    printed = {},
  }

  local engine = { name = nil }
  setmetatable(engine, {
    __index = function(_, command_name)
      return function(...)
        local args = { ... }
        local count = select("#", ...)
        local signature = context.signatures[command_name]
        if not signature then
          error("engine." .. command_name .. " has no matching addCommand in Engine_Strata.sc", 2)
        end
        if count ~= #signature then
          error(string.format("engine.%s called with %d args, signature \"%s\" expects %d",
            command_name, count, signature, #signature), 2)
        end
        for index = 1, #signature do
          local type_code = signature:sub(index, index)
          local value = args[index]
          if type_code == "i" and not is_integer(value) then
            error(string.format("engine.%s arg %d must be an integer, got %s", command_name, index, tostring(value)), 2)
          elseif type_code == "f" and type(value) ~= "number" then
            error(string.format("engine.%s arg %d must be a number, got %s", command_name, index, tostring(value)), 2)
          elseif type_code == "s" and type(value) ~= "string" then
            error(string.format("engine.%s arg %d must be a string, got %s", command_name, index, tostring(value)), 2)
          end
        end
        table.insert(context.engine_calls, { name = command_name, args = args })
      end
    end,
  })

  context.util = util
  context.controlspec = controlspec
  context.params = make_params(util, controlspec)
  context.clock = make_clock(util)
  function context.set_time(seconds) util.stub_now = seconds end
  context.metro = make_metro()
  context.grid = make_grid()
  context.arc = make_arc()
  context.screen = make_screen()
  context.UI = make_ui(util, context.screen)
  context.tab = make_tab()
  context.engine = engine
  context.midi = require("stub_midi")()
  context.lfo = {}
  context.lfo.library = require("stub_lfo")(context.lfo)
  context.fileselect = make_fileselect()
  context.polls = make_poll(options.engine_polls)
  context.musicutil = {
    -- same formula as lib/musicutil.lua
    note_num_to_freq = function(note_num) return 13.75 * (2 ^ ((note_num - 9) / 12)) end,
  }
  -- _menu.mode is true while the norns menu (K1) owns the keys and screen
  context.menu = { rebuilds = 0, mode = false }
  context.encoders = make_encoders()
  function context.menu.rebuild_params() context.menu.rebuilds = context.menu.rebuilds + 1 end
  -- lua/core/menu.lua: _menu.set_mode(true) opens the menu (K1, a script
  -- error), set_mode(false) returns to the script. The real one also swaps
  -- the key/enc/redraw handlers; the stub only tracks the mode
  function context.menu.set_mode(mode) context.menu.mode = mode end

  _G.engine = engine
  _G.util = util
  _G.controlspec = controlspec
  _G.params = context.params
  _G.clock = context.clock
  _G.metro = context.metro
  _G.grid = context.grid
  _G.arc = context.arc
  _G.screen = context.screen
  _G.tab = context.tab
  _G.midi = context.midi
  _G.fileselect = nil  -- lib/fileselect.lua is a module (package.preload below)
  _G.poll = context.polls
  _G._menu = context.menu
  _G.norns = { state = {}, enc = context.encoders.api,
    -- lua/core/menu.lua: norns.menu.status() returns _menu.mode
    menu = { status = function() return context.menu.mode end } }
  _G._path = { data = options.data_dir, audio = options.data_dir .. "audio/" }
  util.make_dir(_G._path.audio)
  package.loaded["ui"] = context.UI
  package.preload["ui"] = function() return context.UI end
  package.loaded["musicutil"] = nil
  package.preload["musicutil"] = function() return context.musicutil end
  package.loaded["lfo"] = nil
  package.preload["lfo"] = function() return context.lfo.library end
  package.loaded["fileselect"] = nil
  package.preload["fileselect"] = function() return context.fileselect end

  if options.quiet then
    _G.print = function(...)
      local parts = {}
      for index = 1, select("#", ...) do parts[index] = tostring((select(index, ...))) end
      table.insert(context.printed, table.concat(parts, "\t"))
    end
  end

  function context.clear_engine_calls() context.engine_calls = {} end
  function context.calls_named(name)
    local matches = {}
    for _, call in ipairs(context.engine_calls) do
      if call.name == name then table.insert(matches, call) end
    end
    return matches
  end

  return context
end

stubs.shallow_copy = shallow_copy

return stubs
