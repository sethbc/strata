-- stub_osc.lua
-- Stand-in for norns' lua/core/osc.lua (lines 55-123): the global `osc`
-- ({event = nil, send, send_crone, cleanup}) and _norns.osc.event, which
-- calls the script's osc.event(path, args, from) when set and then the
-- built-in handling, as norns does. Helpers: context.osc.sent (each
-- {to, path, args}), context.osc.sent_crone, and
-- context.osc.receive(path, args, from) (from defaults to
-- {"10.0.0.2", 57121}). The built-in /param handling: /param/<id> with
-- args[1] calls params:set(id, args[1]); an unknown id prints and is not
-- fatal, as norns reports an error raised inside the event call. The
-- /param/<pset_id>/<id> form and /remote are not modeled.

return function()
  local helpers = { sent = {}, sent_crone = {} }
  local osc = { event = nil }

  function osc.send(to, path, args)
    table.insert(helpers.sent, { to = to, path = path, args = args })
  end
  function osc.send_crone(path, args)
    table.insert(helpers.sent_crone, { path = path, args = args })
  end
  function osc.cleanup() osc.event = nil end

  local function starts_with(text, prefix) return text:sub(1, #prefix) == prefix end

  local function param_handler(path, args)
    local parts = {}
    for part in path:gmatch("[^/]+") do table.insert(parts, part) end
    if #parts == 2 then
      local value = args[1]
      if value == nil then error("osc parameter value is not set") end
      _G.params:set(parts[2], value)
    end
  end

  function helpers.receive(path, args, from)
    from = from or { "10.0.0.2", 57121 }
    if osc.event ~= nil then osc.event(path, args, from) end
    if starts_with(path, "/param") then
      local ok, err = pcall(param_handler, path, args)
      if not ok then print("osc event error: " .. tostring(err)) end
    end
  end

  helpers.osc = osc
  return helpers
end
