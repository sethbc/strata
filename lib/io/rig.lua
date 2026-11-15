-- lib/io/rig.lua
-- The rig settings (S.lib.io_rig, 3.6 design §2.3): which ports the
-- controllers and remote devices use, who leads the ii bus, OSC's port and
-- feedback. They describe the rig, not a performance, so they live in
-- data/strata/io.data (through S.lib.data_files), never in a param, a
-- scene or a PSET, and only a row of the IO page (lib/pages/io.lua) changes
-- one. Read at the start step io_rig, written at each change and once more
-- at the cleanup step io_rig_save. See docs/notes/lua/io/rig.md.

return function(S)
  local M = {}

  -- The settings: io.data's name and format version, the keys in the order
  -- the docs list them, and each key's spec: a choice ({values, default})
  -- or a whole number in min..max ({min, max, default}, step the detent's
  -- size, 1 when absent; fine_step its size with ALT+E3), off_at the value
  -- shown as "off"
  local RIG = {
    file = "io.data",
    version = 1,
    backup_suffix = ".bak",
    order = {"ii_bus", "e16_port", "e16_channel", "e16_cc", "e16_encoding", "faders_port", "faders_channel",
      "faders_cc", "faders_hires", "remote_grid_port", "remote_arc_port", "midi_grid", "osc_feedback", "osc_port"},
    specs = {
      ii_bus = {values = {"off", "strata", "teletype"}, default = "off"},
      e16_port = {min = 0, max = 16, default = 0, off_at = 0},
      e16_channel = {min = 1, max = 16, default = 16},
      e16_cc = {min = 0, max = 104, default = 102},       -- the first of the E16's 16 CCs
      e16_encoding = {values = {"rel1", "rel2"}, default = "rel1"},  -- 1 and 127, or 63 and 65
      faders_port = {min = 0, max = 16, default = 0, off_at = 0},
      faders_channel = {min = 1, max = 16, default = 1},
      faders_cc = {min = 0, max = 80, default = 32},      -- the first of 16 faders' CCs
      faders_hires = {values = {"off", "on"}, default = "off"},  -- 14 bits, the low 7 on CC + 32
      remote_grid_port = {min = 0, max = 16, default = 0, off_at = 0},
      remote_arc_port = {min = 0, max = 16, default = 0, off_at = 0},
      midi_grid = {values = {"off", "on"}, default = "off"},
      osc_feedback = {values = {"off", "on"}, default = "off"},
      osc_port = {min = 1, max = 65535, default = 9000, step = 10, fine_step = 1},
    },
  }
  M.RIG = RIG

  local values = {}     -- key -> its value
  local listeners = {}  -- key -> {fn(value, previous), ...}
  local listener_errors = {}  -- contained_call's last message per listener
  local started = false  -- the start step has read io.data (cleanup writes only then)

  local function defaults()
    local result = {}
    for _, key in ipairs(RIG.order) do result[key] = RIG.specs[key].default end
    return result
  end
  values = defaults()

  local function rig_path() return _path.data .. "strata/" .. RIG.file end

  -- Whether value is one of key's values (false for an unknown key)
  local function valid(key, value)
    local spec = RIG.specs[key]
    if not spec then return false end
    if spec.values then
      for _, choice in ipairs(spec.values) do
        if choice == value then return true end
      end
      return false
    end
    return type(value) == "number" and value == value and value % 1 == 0 and value >= spec.min and value <= spec.max
  end

  local function copy(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
  end

  -- Write io.data holding these values: true, or false after one console line
  local function write(with_values)
    util.make_dir(_path.data .. "strata/")
    local written, problem = S.lib.data_files.write(rig_path(), {version = RIG.version, values = with_values})
    if not written then print("strata: " .. RIG.file .. " not saved: " .. tostring(problem)) end
    return written
  end

  function M.get(key)
    return values[key]
  end

  -- Set key to value: refused (false) for an unknown key or a value outside
  -- its spec; otherwise io.data is written first, and only when that
  -- worked does the value change and its listeners hear it (value,
  -- previous), each contained; true. The same value again still goes through
  -- the write (data_files.write leaves identical bytes on disk alone) and tells nobody
  function M.set(key, value)
    if not valid(key, value) then return false end
    local next_values = copy(values)
    next_values[key] = value
    if not write(next_values) then return false end
    local previous = values[key]
    values = next_values
    if previous ~= value then
      for index, fn in ipairs(listeners[key] or {}) do
        S.lib.ui_frame.contained_call(listener_errors, key .. index, "io rig listener " .. key, fn, value, previous)
      end
    end
    request_redraw()
    return true
  end

  -- The value d detents from key's (a choice by d places, a number by d
  -- times its step, fine_step with fine), stopping at the ends; set when it
  -- differs. false for an unknown key or a write that fails, else true
  function M.step(key, d, fine)
    local spec = RIG.specs[key]
    if not spec or type(d) ~= "number" then return false end
    local current, stepped = values[key], nil
    if spec.values then
      local index = 1
      for position, choice in ipairs(spec.values) do
        if choice == current then index = position end
      end
      stepped = spec.values[util.clamp(index + d, 1, #spec.values)]
    else
      local size = fine and (spec.fine_step or 1) or (spec.step or 1)
      stepped = util.clamp(current + d * size, spec.min, spec.max)
    end
    if stepped == current then return true end
    return M.set(key, stepped)
  end

  -- What a row shows for key: a choice as it is, a number in digits, a
  -- port at off_at as "off"
  function M.text(key)
    local spec, value = RIG.specs[key], values[key]
    if spec and spec.off_at ~= nil and value == spec.off_at then return "off" end
    return tostring(value)
  end

  -- fn(value, previous) runs after each change of key, contained (one that
  -- raises prints one line and the next still runs)
  function M.on_change(key, fn)
    if not RIG.specs[key] then error("io_rig.on_change: no rig setting " .. tostring(key), 2) end
    if type(fn) ~= "function" then error("io_rig.on_change: a listener is a function", 2) end
    listeners[key] = listeners[key] or {}
    table.insert(listeners[key], fn)
  end

  -- What is wrong with io.data's value, or nil: version RIG.version with a
  -- values table whose every known key holds a value of its spec (a key
  -- left out takes its default; a key no spec has is dropped)
  local function problem_with(value)
    if type(value) ~= "table" or value.version ~= RIG.version then return "not a version 1 rig file" end
    if type(value.values) ~= "table" then return "no values" end
    for _, key in ipairs(RIG.order) do
      if value.values[key] ~= nil and not valid(key, value.values[key]) then
        return key .. " " .. tostring(value.values[key]) .. " is out of range"
      end
    end
    return nil
  end

  -- The start step: io.data (parsed, never run). No file gives the
  -- defaults; one that is unreadable, another version or holds a value out
  -- of its spec is set aside (io.data.bak, ...) with one console line and
  -- gives the defaults. Listeners are not told: their modules read get() in
  -- their own start steps, which come later
  S.register_start(S.constants.START_ORDER.io_rig, function()
    values = defaults()
    started = true
    local path = rig_path()
    local value, outcome, why = S.lib.data_files.read(path)
    if value == nil and outcome == "missing" then return end
    local problem = value == nil and (why or outcome) or problem_with(value)
    if problem then
      local backup, failure = S.lib.data_files.set_aside(path, RIG.backup_suffix)
      print("strata: " .. RIG.file .. " not used (" .. problem .. "): the rig settings are the defaults; "
        .. (backup and ("kept as " .. backup:match("[^/]*$")) or ("not moved: " .. tostring(failure))))
      return
    end
    for _, key in ipairs(RIG.order) do
      if value.values[key] ~= nil then values[key] = value.values[key] end
    end
  end)

  -- The cleanup step: io.data once more, the session's last write
  S.register_cleanup(S.constants.CLEANUP_ORDER.io_rig_save, function()
    if started then write(values) end
  end)

  -- Every value is one of its spec's
  S.register_invariant("rig", function()
    for _, key in ipairs(RIG.order) do
      if not valid(key, values[key]) then return key .. " is " .. tostring(values[key]) end
    end
    for key in pairs(values) do
      if not RIG.specs[key] then return "an unknown setting " .. tostring(key) end
    end
  end)

  return M
end
