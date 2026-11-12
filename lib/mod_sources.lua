-- lib/mod_sources.lua
-- The modulation source readers (3.4, design §10.1), S.lib.mod_sources,
-- over the registry S.registry.mod_sources (S.register_mod_source,
-- lib/state.lua): get(key), list(section), registered(section) (2a: hidden
-- sources too), sections(), fraction(key) and
-- normalized(key). MOD (lib/pages/mod.lua) and the matrix (lib/matrix.lua)
-- read sources only through here, and fraction and normalized are the only
-- places a source's value is mapped through its range. The registry is
-- read at each call, so a source registers before or after this module
-- loads. Nothing here sends or yields: MOD reads a shown row's source up to
-- 15 times a second.

return function(S)
  local M = {}

  -- The source registered under key, or nil
  function M.get(key)
    for _, record in ipairs(S.registry.mod_sources) do
      if record.key == key then return record end
    end
    return nil
  end

  local function shown(record)
    return record.visible == nil or record.visible() and true or false
  end

  -- The visible sources of a section (every section when it is nil), in
  -- registration order
  function M.list(section)
    local records = {}
    for _, record in ipairs(S.registry.mod_sources) do
      if (section == nil or record.section == section) and shown(record) then records[#records + 1] = record end
    end
    return records
  end

  -- Every source of a section (every section when it is nil), visible or
  -- not, in registration order: MOD's routing view offers them all, the
  -- macros of a bank not shown among them (package 2a, ruling 77)
  function M.registered(section)
    local records = {}
    for _, record in ipairs(S.registry.mod_sources) do
      if section == nil or record.section == section then records[#records + 1] = record end
    end
    return records
  end

  -- The sections, in the order their first source registered
  function M.sections()
    local names, seen = {}, {}
    for _, record in ipairs(S.registry.mod_sources) do
      if not seen[record.section] then
        seen[record.section] = true
        names[#names + 1] = record.section
      end
    end
    return names
  end

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end

  local function bipolar(record) return record.range[1] < 0 end

  -- A finite value's place along the record's range, clamped to 0..1
  local function fraction_of(record, value)
    local low, high = record.range[1], record.range[2]
    return util.clamp((value - low) / (high - low), 0, 1)
  end

  -- The source's value as a fraction of its range, 0..1 (clamped). A value
  -- that is not a finite number reads as no modulation: 0.5 for a bipolar
  -- source, 0 for a unipolar one; an unknown key reads 0
  function M.fraction(key)
    local record = M.get(key)
    if not record then return 0 end
    local value = record.value()
    if not finite(value) then return bipolar(record) and 0.5 or 0 end
    return fraction_of(record, value)
  end

  -- The source's value for a routing (design §10.2): 2 x fraction - 1
  -- (-1..1) for a bipolar source (range[1] < 0), the fraction (0..1) for a
  -- unipolar one; 0 when the value is not a finite number or the key unknown
  function M.normalized(key)
    local record = M.get(key)
    if not record then return 0 end
    local value = record.value()
    if not finite(value) then return 0 end
    local fraction = fraction_of(record, value)
    if bipolar(record) then return 2 * fraction - 1 end
    return fraction
  end

  return M
end
