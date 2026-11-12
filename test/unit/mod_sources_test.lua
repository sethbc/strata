-- test/unit/mod_sources_test.lua
-- The modulation source readers (lib/mod_sources.lua, S.lib.mod_sources)
-- over the mod_sources registry (S.register_mod_source, lib/state.lua):
-- get, list, sections, fraction and normalized
-- Run alone: lua test/run.lua mod_sources

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value = h.load_strata, h.local_value

-- The readers over a fresh S from lib/state, so the sources 3.4's modules
-- register never join the ones a test registers
local function fresh_sources()
  load_strata()
  local S = include("lib/state")()
  S.constants = local_value("S").constants
  return S, include("lib/mod_sources")(S)
end

local function source(key, section, value, range, visible)
  return { key = key, name = key:sub(1, 2):upper(), section = section, value = value, range = range or { 0, 1 },
    visible = visible }
end

local function keys(records)
  local found = {}
  for _, record in ipairs(records) do found[#found + 1] = record.key end
  return table.concat(found, " ")
end

test("list keeps registration order and leaves out invisible sources", function()
  local S, sources = fresh_sources()
  local shown = false
  local zero = function() return 0 end
  S.register_mod_source(source("a1", "alpha", zero))
  S.register_mod_source(source("b1", "beta", zero))
  S.register_mod_source(source("a2", "alpha", zero, nil, function() return shown end))
  S.register_mod_source(source("a3", "alpha", zero))
  assert_equal(keys(sources.list("alpha")), "a1 a3", "a hidden source is left out")
  assert_equal(keys(sources.list()), "a1 b1 a3", "every section, in registration order")
  shown = true
  assert_equal(keys(sources.list("alpha")), "a1 a2 a3", "shown again in its place")
  assert_equal(keys(sources.list("gamma")), "", "a section with no source lists none")
  assert_equal(table.concat(sources.sections(), " "), "alpha beta", "sections in first-registration order")
  assert_equal(sources.get("b1").key, "b1", "get finds a source by key")
  assert_equal(sources.get("zz"), nil, "and nil for an unknown key")
end)

test("fraction and normalized map a value through its range", function()
  local S, sources = fresh_sources()
  local values = { bipolar = 0, unipolar = 0.25, offset = 0.5 }
  local function reader(key) return function() return values[key] end end
  S.register_mod_source(source("bipolar", "probes", reader("bipolar"), { -1, 1 }))
  S.register_mod_source(source("unipolar", "probes", reader("unipolar"), { 0, 1 }))
  S.register_mod_source(source("offset", "probes", reader("offset"), { -0.5, 1.5 }))
  assert_near(sources.fraction("bipolar"), 0.5, 1e-9, "-1..1 at 0: half")
  assert_near(sources.normalized("bipolar"), 0, 1e-9, "-1..1 at 0: 0")
  values.bipolar = 0.5
  assert_near(sources.fraction("bipolar"), 0.75, 1e-9)
  assert_near(sources.normalized("bipolar"), 0.5, 1e-9, "-1..1 at 0.5: 0.5")
  assert_near(sources.fraction("unipolar"), 0.25, 1e-9, "0..1 at 0.25")
  assert_near(sources.normalized("unipolar"), 0.25, 1e-9, "a unipolar source is its fraction")
  assert_near(sources.normalized("offset"), 0, 1e-9, "-0.5..1.5 at 0.5: 2 x 0.5 - 1")
  values.unipolar = 2
  assert_near(sources.fraction("unipolar"), 1, 1e-9, "a value past the range is clamped")
  assert_near(sources.normalized("unipolar"), 1, 1e-9)
  for _, bad in ipairs({ 0 / 0, math.huge, -math.huge }) do
    values.bipolar, values.unipolar = bad, bad
    assert_equal(sources.normalized("bipolar"), 0, "a value that is not finite: 0 (" .. tostring(bad) .. ")")
    assert_equal(sources.normalized("unipolar"), 0, "unipolar too (" .. tostring(bad) .. ")")
    assert_near(sources.fraction("bipolar"), 0.5, 1e-9, "the fraction of 0 modulation")
    assert_near(sources.fraction("unipolar"), 0, 1e-9, "the fraction of 0 modulation")
  end
  values.unipolar = "x"
  assert_equal(sources.normalized("unipolar"), 0, "a value that is not a number: 0")
  assert_equal(sources.normalized("unknown"), 0, "an unknown key: 0")
  assert_equal(sources.fraction("unknown"), 0, "an unknown key: 0")
end)

end
