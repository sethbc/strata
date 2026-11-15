-- stub_e16.lua
-- Stand-in for the scripting environment of an OXI E16 scene
-- (docs/design/3.6-facts/controllers.md section 1, checks.md section 2):
-- require("stub_e16")() returns a device whose run(path) runs a script with
-- the E16's globals as its environment: controller (the script sets
-- controller.onSysex), leds (update, reset), slots (update), page
-- (setTitle), midi (sendCC, sendSysex) and var, plus its own copies of
-- math, string and table. All indexes count from 1, as the E16's do.
-- device.sysex(bytes) calls controller.onSysex with a table of the bytes,
-- 0xF0 first and 0xF7 last, as the firmware does. Records: leds[index] =
-- {value, color} as last set (nil after reset), slots[index] (the text),
-- title, calls (each {name, args...}, in order), sent_cc and sent_sysex.

local function copy_library(source)
  local copy = {}
  for name, value in pairs(source) do copy[name] = value end
  return copy
end

return function()
  local device = { leds = {}, slots = {}, title = nil, calls = {}, sent_cc = {}, sent_sysex = {} }

  local function note(name, ...)
    device.calls[#device.calls + 1] = {name, ...}
  end

  local function check_index(index, name)
    if type(index) ~= "number" or index < 1 or index > 16 or index % 1 ~= 0 then
      error(name .. ": index " .. tostring(index) .. " is not 1 to 16", 3)
    end
  end

  local environment = {
    math = copy_library(math), string = copy_library(string), table = copy_library(table),
    pairs = pairs, ipairs = ipairs, type = type, tostring = tostring, tonumber = tonumber,
    controller = {}, var = {},
    leds = {
      update = function(index, value, color)
        check_index(index, "leds.update")
        if type(value) ~= "number" or value < 0 or value > 16383 then error("leds.update: value 0 to 16383", 2) end
        device.leds[index] = {value = value, color = color or 0}
        note("leds.update", index, value, color or 0)
      end,
      reset = function(index)
        check_index(index, "leds.reset")
        device.leds[index] = nil
        note("leds.reset", index)
      end,
    },
    slots = {
      update = function(index, text)
        check_index(index, "slots.update")
        device.slots[index] = text
        note("slots.update", index, text)
      end,
    },
    page = {
      setTitle = function(text)
        device.title = text
        note("page.setTitle", text)
      end,
    },
    midi = {
      sendCC = function(output, channel, cc, value)
        device.sent_cc[#device.sent_cc + 1] = {output, channel, cc, value}
        note("midi.sendCC", output, channel, cc, value)
      end,
      sendSysex = function(output, bytes)
        if #bytes > 128 then error("midi.sendSysex: at most 128 bytes", 2) end
        device.sent_sysex[#device.sent_sysex + 1] = {output, bytes}
        note("midi.sendSysex", output, bytes)
      end,
    },
  }
  device.environment = environment

  -- Run the script at path with the E16's globals as its environment
  function device.run(path)
    local chunk, problem
    if setfenv then  -- Lua 5.1 and LuaJIT: loadfile has no environment argument
      chunk, problem = loadfile(path)
      if chunk then setfenv(chunk, environment) end
    else
      chunk, problem = loadfile(path, "t", environment)
    end
    if not chunk then error(problem, 2) end
    return chunk()
  end

  -- What the firmware does with a SysEx message: the handler gets the bytes
  function device.sysex(bytes)
    local handler = environment.controller.onSysex
    if handler == nil then return end
    local frame = {}
    for index, byte in ipairs(bytes) do frame[index] = byte end
    return handler(frame)
  end

  return device
end
