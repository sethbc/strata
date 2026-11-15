-- stub_crow.lua
-- Stand-in for norns' lua/core/crow.lua and lua/core/crow/quote.lua, ported:
-- the global `crow` proxy (an index chain called sends "<chain>(<quoted
-- args>)", an assignment "<chain>=<quoted value>", a function assigned
-- registers an event key and sends norns' forwarding stub), and norns.crow
-- (dev, add, remove, receive, events, send, connected). norns writes
-- string.format and utf8.char; the stub uses string.char so LuaJIT runs it.
-- crow.public and norns.crow.public are not modeled (reading raises); the
-- global quote is core/crow/quote.lua's, as norns defines it.
-- Test helpers (the table require("stub_crow")() returns as `helpers`):
-- plug(), unplug(), fire(event, ...), clear(), and the records sent (lines
-- kept only while plugged, as norns.crow.send drops them otherwise),
-- function_assignments (a count, plugged or not) and resets.

-- core/crow/quote.lua
local quote_module = { OPTIMIZE_LENGTH = false }

function quote_module.key(ix)
  local fstr = (type(ix) == "number") and "[%g]" or "[%q]"
  return string.format(fstr, ix)
end

function quote_module.quote(val, ...)
  if ... ~= nil then
    local t = { quote_module.quote(val) }
    for _, v in ipairs { ... } do table.insert(t, quote_module.quote(v)) end
    return table.concat(t, ",")
  elseif type(val) == "string" then return string.format("%q", val)
  elseif type(val) == "number" then return string.format("%.6g", val)
  elseif type(val) ~= "table" then return tostring(val)
  else
    local t = {}
    for k, v in pairs(val) do table.insert(t, quote_module.key(k) .. "=" .. quote_module.quote(v)) end
    return string.format("{%s}", table.concat(t, ","))
  end
end

setmetatable(quote_module, { __call = function(_, ...) return quote_module.quote(...) end })

-- norns' crow.public and norns.crow.public (core/crow/public.lua, the
-- public-parameter protocol) are not ported: reading either raises, so a
-- script cannot send text through the proxy by accident
local NOT_MODELED = "crow.public is not modeled by the crow stub (test/stub_crow.lua)"

return function()
  local quote = quote_module
  local helpers = { sent = {}, function_assignments = 0, resets = 0 }
  local norns_crow = setmetatable({}, { __index = function(_, ix)
    if ix == "public" then error(NOT_MODELED, 2) end
  end })
  local crow = {}

  -- core/crow.lua's norns.crow
  norns_crow.send = function(cmd)
    if norns_crow.dev then table.insert(helpers.sent, cmd) end
  end
  function norns_crow.connected() return norns_crow.dev ~= nil end

  function norns_crow.register_event(fn)
    local count = 0
    for _ in pairs(norns_crow.events) do count = count + 1 end
    local n = count + 1
    local c = ""
    if n <= 26 then c = string.char(n + 64)
    elseif n <= 52 then c = string.char(n + 70)
    else print("ERROR: can't register event. out of indices. only 52 handlers allowed.")
    end
    norns_crow.events[c] = fn
    return c
  end

  function norns_crow.reset_events()
    norns_crow.events = setmetatable({
      identity = function(...) print("crow identity: " .. ...) end,
      version = function(...) print("crow version: " .. ...) end,
      ready = function() end,
      pub = function() end,
      pupdate = function() end,
      pubview = function() end,
      change = function() end,
    }, {
      __index = function(_, ix)
        return function(...) print("unused event: ^^" .. ix .. "(" .. quote(...) .. ")") end
      end,
    })
  end

  norns_crow.clock_enable = function()
    norns_crow.send [[
    input[1].change = function()
      tell('change',1,1)
    end
    input[1].mode('change',2,0.1,'rising')
  ]]
  end

  function norns_crow.init()
    crow.reset()
    norns_crow.reset_events()
    norns_crow.add = function(id, name)
      crow.reset()
      print(">>>>>> norns.crow.add / " .. id .. " / " .. name)
    end
    norns_crow.remove = function(id) print(">>>>>> norns.crow.remove " .. id) end
    norns_crow.receive = function(...) print("crow:", ...) end
  end

  -- core/crow.lua's crow namespace
  function crow.version() crow "^^v" end
  function crow.identity() crow "^^i" end
  function crow.reset()
    helpers.resets = helpers.resets + 1
    crow "crow.reset()"
  end
  function crow.kill() crow "^^k" end
  function crow.clear() crow "^^c" end
  function crow.send(...) crow(...) end

  local crow_sub = {
    __index = function(self, ix)
      self.str = self.str .. quote.key(ix)
      return self
    end,
    __newindex = function(self, ix, val)
      local sval
      if type(val) == "function" then
        helpers.function_assignments = helpers.function_assignments + 1
        local n = norns_crow.register_event(val)
        sval = "function(...)_c.tell(" .. quote(n) .. ",quote(...))end"
      else
        sval = quote(val)
      end
      norns_crow.send(self.str .. quote.key(ix) .. "=" .. sval)
    end,
    __call = function(self, ...)
      local nargs = select("#", ...)
      local qt = nargs > 0 and quote(...) or ""
      norns_crow.send(self.str .. "(" .. qt .. ")")
    end,
  }

  crow.__newindex = function(_, ix, val) norns_crow.send(ix .. "=" .. quote(val)) end
  crow.__index = function(_, ix)
    if ix == "public" then error(NOT_MODELED, 2) end
    return setmetatable({ str = ix }, crow_sub)
  end
  crow.__call = function(_, ...) norns_crow.send(...) end
  setmetatable(crow, crow)

  -- norns.crow.init() resets crow, so the count starts again after it
  norns_crow.init()
  helpers.resets = 0

  -- _norns.crow.add / remove (core/crow.lua), with the clock_source check
  function helpers.plug(id, name, dev)
    id, name, dev = id or 1, name or "crow", dev or "crow stub device"
    norns_crow.dev = dev
    norns_crow.add(id, name, dev)
    local params = rawget(_G, "params")
    if params and params.lookup and params.lookup["clock_source"] and params:string("clock_source") == "crow" then
      norns_crow.clock_enable()
    end
  end

  function helpers.unplug(id)
    norns_crow.dev = nil
    norns_crow.remove(id or 1)
  end

  function helpers.fire(event, ...) return norns_crow.events[event](...) end

  function helpers.clear()
    for index = #helpers.sent, 1, -1 do helpers.sent[index] = nil end
  end

  helpers.crow, helpers.norns_crow, helpers.quote = crow, norns_crow, quote
  return helpers
end
