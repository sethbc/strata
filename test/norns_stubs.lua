-- norns_stubs.lua
-- Minimal stand-ins for the norns Lua runtime, used by test/run.lua to load
-- strata.lua off-device. Behaviour mirrors norns' own implementations
-- (lua/core/params/*.lua, controlspec.lua, grid.lua, arc.lua, clock.lua,
-- lib/util.lua, lib/tabutil.lua) wherever the script depends on it:
--   * control params quantize to controlspec.step and only fire their action
--     when the stored value changes
--   * number params clamp (but do not round) and fire on change
--   * clock.run resumes the coroutine immediately; sleep/sync yield
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

---------------------------------------------------------------------------
-- util
---------------------------------------------------------------------------

local function make_util()
  local util = {}
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

local function make_params(util, controlspec)
  local ParamSet = {}
  ParamSet.__index = ParamSet

  local paramset = setmetatable({ params = {}, lookup = {}, action_log = {} }, ParamSet)

  local function new_param(args)
    local param = { id = args.id, name = args.name or args.id, t = args.type, action = args.action or function() end }
    if args.type == "control" then
      param.controlspec = args.controlspec or controlspec.new(0, 1, "lin", 0, 0)
      param.raw = param.controlspec:unmap(param.controlspec.default)
    elseif args.type == "number" then
      param.min = args.min or -2147483648
      param.max = args.max or 2147483647
      param.value = args.default or 0
      param.formatter = args.formatter
    elseif args.type == "binary" then
      param.value = args.default or 0
      param.behavior = args.behavior
    elseif args.type == "trigger" or args.type == "separator" then
      param.value = 0
    else
      error("stub params: unsupported param type " .. tostring(args.type))
    end
    return param
  end

  function ParamSet:add(args)
    assert(args.id, "params:add requires an id")
    if self.lookup[args.id] then
      error("parameter ID collision: " .. args.id)
    end
    local param = new_param(args)
    -- param objects expose :get() for formatters, as in norns
    param.get = function() return ParamSet.get(paramset, param.id) end
    table.insert(self.params, param)
    self.lookup[args.id] = param
    return param
  end

  function ParamSet:add_separator(id, name)
    local separator_id = id or "separator"
    if self.lookup[separator_id] and self.lookup[separator_id].t ~= "separator" then
      error("separator collides with param: " .. separator_id)
    end
    local param = new_param({ id = separator_id, name = name, type = "separator" })
    table.insert(self.params, param)
    self.lookup[separator_id] = param
  end

  function ParamSet:add_number(id, name, min, max, default)
    return self:add { type = "number", id = id, name = name, min = min, max = max, default = default }
  end

  function ParamSet:lookup_param(id)
    local param = self.lookup[id]
    if not param then error("invalid paramset index: " .. tostring(id)) end
    return param
  end

  local function bang(param)
    local value = ParamSet.get(paramset, param.id)
    param.action(value)
  end

  function ParamSet:get(id)
    local param = self:lookup_param(id)
    if param.t == "control" then return param.controlspec:map(param.raw) end
    return param.value
  end

  function ParamSet:set(id, value, silent)
    local param = self:lookup_param(id)
    if type(value) ~= "number" then
      error("params:set(" .. id .. ") with non-number value " .. tostring(value))
    end
    local changed = false
    if param.t == "control" then
      local raw = util.clamp(param.controlspec:unmap(value), 0, 1)
      if param.raw ~= raw then param.raw = raw; changed = true end
    elseif param.t == "number" then
      local clamped = util.clamp(value, param.min, param.max)
      if param.value ~= clamped then param.value = clamped; changed = true end
    elseif param.t == "binary" then
      local clamped = util.clamp(value, 0, 1)
      if param.value ~= clamped then param.value = clamped; changed = true end
    elseif param.t == "trigger" then
      changed = true
    end
    if changed and not silent then bang(param) end
  end

  function ParamSet:delta(id, delta)
    local param = self:lookup_param(id)
    if param.t == "control" then
      local raw = util.clamp(param.raw + delta * param.controlspec.quantum, 0, 1)
      if param.raw ~= raw then param.raw = raw; bang(param) end
    elseif param.t == "number" then
      self:set(id, param.value + delta)
    elseif param.t == "binary" then
      self:set(id, param.value == 1 and 0 or 1)
    end
  end

  function ParamSet:string(id)
    local param = self:lookup_param(id)
    if param.formatter then return param.formatter(param) end
    return tostring(self:get(id))
  end

  function ParamSet:bang()
    for _, param in ipairs(self.params) do
      if param.t ~= "separator" and param.t ~= "trigger" then bang(param) end
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

local function make_clock()
  local clock = { threads = {}, next_id = 1, sleep_log = {} }

  local function resume(coro_id, ...)
    local coro = clock.threads[coro_id]
    if not coro then return end
    local ok, mode, amount = coroutine.resume(coro, ...)
    if not ok then error(mode, 0) end
    if coroutine.status(coro) == "dead" then
      clock.threads[coro_id] = nil
    else
      table.insert(clock.sleep_log, { id = coro_id, mode = mode, amount = amount })
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
  end

  function clock.sleep(seconds)
    return coroutine.yield("sleep", seconds)
  end

  function clock.sync(beats)
    return coroutine.yield("sync", beats)
  end

  -- test helper: resume every pending coroutine once (one scheduler tick)
  function clock.advance()
    local ids = {}
    for coro_id in pairs(clock.threads) do table.insert(ids, coro_id) end
    table.sort(ids)
    for _, coro_id in ipairs(ids) do resume(coro_id) end
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
    function device:segment(ring, from, to, level) self.segments[ring] = { from = from, to = to, level = level } end
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
-- screen / UI
---------------------------------------------------------------------------

local function make_screen()
  local screen = { texts = {}, cursor_x = 0, cursor_y = 0, current_level = 15 }
  function screen.clear() screen.texts = {} end
  function screen.level(level) screen.current_level = level end
  function screen.move(x, y) screen.cursor_x = x; screen.cursor_y = y end
  function screen.text(str)
    table.insert(screen.texts, { x = screen.cursor_x, y = screen.cursor_y, text = tostring(str), align = "left" })
  end
  function screen.text_right(str)
    table.insert(screen.texts, { x = screen.cursor_x, y = screen.cursor_y, text = tostring(str), align = "right" })
  end
  function screen.line() end
  function screen.stroke() end
  function screen.update() end
  function screen.font_size() end
  function screen.font_face() end
  return screen
end

local function make_ui(util)
  local UI = { ScrollingList = {} }
  UI.ScrollingList.__index = UI.ScrollingList
  function UI.ScrollingList.new(x, y, index, entries)
    assert(x and y and index and entries, "UI.ScrollingList.new requires all parameters")
    return setmetatable({ x = x, y = y, index = index, entries = entries,
      num_visible = 5, num_above_selected = 1, active = true }, UI.ScrollingList)
  end
  function UI.ScrollingList:redraw() end
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
  context.clock = make_clock()
  context.metro = make_metro()
  context.grid = make_grid()
  context.arc = make_arc()
  context.screen = make_screen()
  context.UI = make_ui(util)
  context.tab = make_tab()
  context.engine = engine

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
  _G.norns = { state = {} }
  _G._path = { data = options.data_dir }
  package.loaded["ui"] = context.UI
  package.preload["ui"] = function() return context.UI end
  package.loaded["musicutil"] = nil
  package.preload["musicutil"] = function() error("strata.lua should not require musicutil") end

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
