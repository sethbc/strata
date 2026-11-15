-- test/unit/io_rig_test.lua
-- The rig settings (lib/io/rig.lua, S.lib.io_rig, 3.6 design §2.3): the
-- fifteen keys and their defaults, set's validation and write-first rule,
-- step's ends, io.data read at start (set aside when it cannot be used) and
-- written at cleanup, and that a PSET load or a scene recall leaves them be.
-- Run alone: lua test/run.lua io_rig

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function rig_path(context) return context.data_dir .. "strata/io.data" end

-- Write io.data before init: a value in tab.save's layout, or text as it is
local function with_rig_file(case)
  return function(context)
    os.execute("mkdir -p '" .. context.data_dir .. "strata'")
    local text = type(case) == "string" and case or local_value("S").lib.data_files.encode(case)
    h.write_text(rig_path(context), text)
  end
end

-- The console lines that name io.data
local function rig_lines(context)
  local lines = {}
  for _, line in ipairs(context.printed) do
    if line:find("io.data", 1, true) then lines[#lines + 1] = line end
  end
  return lines
end

local DEFAULTS = {
  ii_bus = "off", e16_port = 0, faders_port = 0, remote_grid_port = 0, remote_arc_port = 0, e16_channel = 16,
  e16_cc = 102, e16_encoding = "rel1", faders_channel = 1, faders_cc = 32, faders_hires = "off", midi_grid = "off",
  osc_feedback = "off", osc_port = 9000,
}

local function assert_defaults(rig, where)
  for key, value in pairs(DEFAULTS) do
    assert_equal(rig.get(key), value, where .. ": " .. key)
  end
end

test("the rig settings start at their defaults", function()
  local context = load_strata(); finish_startup(context)
  local rig = local_value("S").lib.io_rig
  assert_defaults(rig, "no file")
  assert_equal(#rig.RIG.order, 14, "fourteen keys in order")
  local seen = {}
  for _, key in ipairs(rig.RIG.order) do
    assert_true(rig.RIG.specs[key] ~= nil, key .. " has a spec")
    assert_equal(rig.RIG.specs[key].default, DEFAULTS[key], key .. "'s default")
    seen[key] = true
  end
  for key in pairs(DEFAULTS) do assert_true(seen[key], key .. " is in the order") end
  assert_equal(rig.RIG.file, "io.data"); assert_equal(rig.RIG.version, 1)
  assert_equal(#rig_lines(context), 0, "no file: no line")
end)

test("set validates, writes first and tells its listeners", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local rig = S.lib.io_rig
  local heard = {}
  rig.on_change("ii_bus", function(value, previous) heard[#heard + 1] = { value, previous } end)
  assert_equal(rig.set("ii_bus", "strata"), true, "set")
  assert_equal(rig.get("ii_bus"), "strata")
  local value = S.lib.data_files.read(rig_path(context))
  assert_equal(type(value), "table", "io.data written")
  assert_equal(value.version, 1, "version 1")
  assert_equal(value.values.ii_bus, "strata", "the new value")
  assert_equal(value.values.osc_port, 9000, "and every other")
  assert_equal(#heard, 1, "the listener heard once")
  assert_equal(heard[1][1], "strata"); assert_equal(heard[1][2], "off")
  local text = h.file_text(rig_path(context))
  local refused = { { "ii_bus", "both" }, { "e16_cc", 105 }, { "faders_cc", 81 }, { "osc_port", 0 },
    { "osc_port", 65536 }, { "e16_port", 17 }, { "e16_port", 1.5 }, { "e16_port", "1" }, { "e16_channel", 0 },
    { "e16_port", 0 / 0 }, { "nope", 1 }, { "ii_bus", nil } }
  for _, case in ipairs(refused) do
    assert_equal(rig.set(case[1], case[2]), false, "refused: " .. case[1] .. " " .. tostring(case[2]))
  end
  assert_equal(h.file_text(rig_path(context)), text, "nothing written")
  assert_equal(#heard, 1, "no listener told")
  -- a listener that raises is contained; the next one still hears
  local later = 0
  rig.on_change("e16_port", function() error("probe") end)
  rig.on_change("e16_port", function() later = later + 1 end)
  assert_equal(rig.set("e16_port", 4), true)
  assert_equal(later, 1, "the next listener heard")
  h.claim_script_errors(context, 1, "strata: io rig listener ", "probe")
  assert_equal(rig.get("e16_port"), 4)
  -- the same value again: nothing to tell
  assert_equal(rig.set("e16_port", 4), true)
  assert_equal(later, 1, "no change, no listener")
  -- with the write failing: false and nothing changes
  os.execute("mkdir -p '" .. rig_path(context) .. ".part/inside'")  -- the .part is a folder: the write fails
  assert_equal(rig.set("ii_bus", "teletype"), false, "not set")
  assert_equal(rig.get("ii_bus"), "strata", "unchanged")
  assert_equal(#heard, 1, "no listener told")
  assert_equal(S.lib.data_files.read(rig_path(context)).values.ii_bus, "strata", "the file keeps it")
  assert_true(not pcall(rig.on_change, "nope", function() end), "on_change refuses an unknown key")
  assert_true(not pcall(rig.on_change, "ii_bus", 1), "on_change refuses a non-function")
end)

test("step moves a setting through its values and stops at the ends", function()
  local context = load_strata(); finish_startup(context)
  local rig = local_value("S").lib.io_rig
  assert_equal(rig.step("ii_bus", 1), true); assert_equal(rig.get("ii_bus"), "strata")
  rig.step("ii_bus", 1); assert_equal(rig.get("ii_bus"), "teletype")
  assert_equal(rig.step("ii_bus", 1), true, "at the end: nothing to write"); assert_equal(rig.get("ii_bus"), "teletype")
  rig.step("ii_bus", -5); assert_equal(rig.get("ii_bus"), "off", "back to the first")
  rig.step("e16_port", -1); assert_equal(rig.get("e16_port"), 0, "stays at 0")
  rig.step("e16_port", 3); assert_equal(rig.get("e16_port"), 3)
  rig.step("e16_port", 30); assert_equal(rig.get("e16_port"), 16, "stops at 16")
  rig.step("osc_port", 1); assert_equal(rig.get("osc_port"), 9010, "10 a detent")
  rig.step("osc_port", -1, true); assert_equal(rig.get("osc_port"), 9009, "1 a detent with fine")
  rig.step("osc_port", 10000); assert_equal(rig.get("osc_port"), 65535, "stops at 65535")
  assert_equal(rig.step("nope", 1), false, "an unknown key")
  assert_equal(rig.text("e16_port"), "16"); assert_equal(rig.text("faders_port"), "off", "port 0 reads off")
  assert_equal(rig.text("ii_bus"), "off"); assert_equal(rig.text("osc_port"), "65535")
  os.execute("mkdir -p '" .. rig_path(context) .. ".part/inside'")
  assert_equal(rig.step("e16_port", -1), false, "the write fails")
  assert_equal(rig.get("e16_port"), 16, "unchanged")
end)

test("io.data is read at start and written at cleanup", function()
  local values = {}
  for key, value in pairs(DEFAULTS) do values[key] = value end
  values.ii_bus, values.osc_port, values.e16_cc = "teletype", 8000, 0
  local context = load_strata({ before_init = with_rig_file({ version = 1, values = values }) })
  local rig = local_value("S").lib.io_rig
  assert_equal(rig.get("ii_bus"), "teletype"); assert_equal(rig.get("osc_port"), 8000)
  assert_equal(rig.get("e16_cc"), 0)
  assert_equal(#rig_lines(context), 0, "a good file: no line")
  -- a file with a key missing gives that key's default
  values.faders_cc = nil
  load_strata({ before_init = with_rig_file({ version = 1, values = values }) })
  assert_equal(local_value("S").lib.io_rig.get("faders_cc"), 32, "a missing key: its default")
  -- cleanup writes once more
  context = load_strata(); finish_startup(context)
  assert_equal(io.open(rig_path(context), "r"), nil, "nothing written at start")
  cleanup()
  local saved = local_value("S").lib.data_files.read(rig_path(context))
  assert_equal(saved.version, 1, "cleanup wrote io.data")
  assert_equal(saved.values.osc_port, 9000)
end)

test("an unreadable or wrong-version io.data is set aside", function()
  local cases = { "return {", "ran_rig_data = true return {}", { version = 2, values = { ii_bus = "strata" } },
    { version = 1, values = { ii_bus = "both" } }, { version = 1, values = { osc_port = 0 } },
    { version = 1, values = "x" }, { values = { ii_bus = "strata" } } }
  for index, case in ipairs(cases) do
    local context = load_strata({ before_init = with_rig_file(case) })
    local S = local_value("S")
    assert_defaults(S.lib.io_rig, "case " .. index)
    local lines = rig_lines(context)
    assert_equal(#lines, 1, "case " .. index .. ": one line")
    assert_true(lines[1]:find("^strata: io.data") ~= nil, "naming the file: " .. lines[1])
    assert_equal(io.open(rig_path(context), "r"), nil, "case " .. index .. ": moved away")
    local kept = io.open(rig_path(context) .. ".bak", "r")
    assert_true(kept ~= nil, "case " .. index .. ": kept as io.data.bak")
    kept:close()
    assert_true(lines[1]:find("io.data.bak", 1, true) ~= nil, "the line names the backup: " .. lines[1])
  end
  assert_equal(rawget(_G, "ran_rig_data"), nil, "the file was never run")
end)

test("a PSET load and a scene recall change no rig setting", function()
  local context = load_strata(); finish_startup(context)
  local rig = local_value("S").lib.io_rig
  rig.set("e16_port", 3); rig.set("ii_bus", "strata")
  local path = context.data_dir .. "strata-01.pset"
  capture_scene(1)
  params:write(path)
  rig.set("e16_port", 5); rig.set("ii_bus", "teletype")
  params:read(path)
  recall_scene(1, 0)
  assert_equal(rig.get("e16_port"), 5, "the PSET and the scene keep no rig setting")
  assert_equal(rig.get("ii_bus"), "teletype")
  for id in pairs(params.lookup) do
    for _, key in ipairs(rig.RIG.order) do
      assert_true(not id:find(key, 1, true), "no param named for " .. key .. ": " .. id)
    end
  end
end)

end
