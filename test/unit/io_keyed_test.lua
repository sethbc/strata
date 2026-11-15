-- test/unit/io_keyed_test.lua
-- A choice kept by key (lib/io/keyed.lua, S.lib.io_keyed): an option param
-- for the menu and the screen, and a hidden text param holding the chosen
-- key, which is what a PSET keeps, so a list that grows never moves a
-- saved choice.
-- Run alone: lua test/run.lua io_keyed

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function started()
  local context = load_strata(); finish_startup(context)
  return context, local_value("S")
end

local KEYS, LABELS = {"off", "a", "b"}, {"off", "A", "B"}

-- A keyed probe param; the keys its action was called with
local function probe(S)
  local got = {}
  S.lib.io_keyed.add("probe_pick", "probe pick", KEYS, LABELS, function(key) got[#got + 1] = key end)
  return got
end

-- A PSET of the script as it is, with the probe's lines replaced by lines
-- (each id's own line, in the order given; nil leaves the id out)
local function pset_with(context, name, lines)
  local path = context.data_dir .. name .. ".pset"
  params:write(path)
  local file = io.open(path, "r")
  local text = file:read("*a")
  file:close()
  local kept = {}
  for line in text:gmatch("[^\n]+") do
    if not line:find('^"probe_pick') then kept[#kept + 1] = line end
  end
  for _, line in ipairs(lines) do kept[#kept + 1] = line end
  file = io.open(path, "w")
  file:write(table.concat(kept, "\n") .. "\n")
  file:close()
  return path
end

test("add makes an option and a hidden key after it, the first key the default", function()
  local _, S = started()
  probe(S)
  local option, key = params:lookup_param("probe_pick"), params:lookup_param("probe_pick_key")
  assert_equal(params.lookup["probe_pick_key"], params.lookup["probe_pick"] + 1, "the key directly after the option")
  assert_equal(option.t, params.tOPTION)
  assert_equal(table.concat(option.options, " "), "off A B", "one label per key")
  assert_equal(key.t, params.tTEXT)
  assert_true(key.hidden, "the key is hidden")
  assert_equal(params:get("probe_pick"), 1)
  assert_equal(params:get("probe_pick_key"), "off")
  assert_equal(S.lib.io_keyed.key("probe_pick"), "off")
end)

test("choosing an option stores its key, then calls the action", function()
  local _, S = started()
  local got = probe(S)
  params:set("probe_pick", 3)
  assert_equal(params:get("probe_pick_key"), "b")
  assert_equal(table.concat(got, " "), "b", "the action once, with the key")
  assert_equal(S.lib.io_keyed.key("probe_pick"), "b")
end)

test("setting the key selects its option silently and calls the action", function()
  local _, S = started()
  local got = probe(S)
  params:set("probe_pick_key", "a")
  assert_equal(params:get("probe_pick"), 2, "its option selected")
  assert_equal(table.concat(got, " "), "a", "the action once: the option's own did not run")
  assert_equal(S.lib.io_keyed.key("probe_pick"), "a")
end)

test("a key the list lacks shows the first option, is kept, and acts as the first", function()
  local context, S = started()
  local got = probe(S)
  params:set("probe_pick", 3)
  params:set("probe_pick_key", "a later key")
  assert_equal(params:get("probe_pick"), 1, "the first option for display")
  assert_equal(params:get("probe_pick_key"), "a later key", "the text kept")
  assert_equal(got[#got], "off", "the action gets the first key")
  assert_equal(S.lib.io_keyed.key("probe_pick"), "off")
  local path = context.data_dir .. "written.pset"
  params:write(path)
  local file = io.open(path, "r")
  local text = file:read("*a")
  file:close()
  assert_true(text:find('"probe_pick_key": a later key', 1, true) ~= nil, "a PSET keeps the key")
end)

test("a PSET keeps the key, not the index, and ends on the key's choice in either order", function()
  local context, S = started()
  local got = probe(S)
  params:set("probe_pick", 3)
  local path = context.data_dir .. "plain.pset"
  params:write(path)
  local file = io.open(path, "r")
  local text = file:read("*a")
  file:close()
  assert_true(text:find('"probe_pick_key": b', 1, true) ~= nil, "the key is written")
  assert_true(text:find('"probe_pick":', 1, true) == nil, "the option's index is not")
  params:set("probe_pick", 2)
  params:read(path)
  assert_equal(S.lib.io_keyed.key("probe_pick"), "b", "read back")
  assert_equal(params:get("probe_pick"), 3)
  for _, lines in ipairs({{'"probe_pick_key": b', '"probe_pick": 2'}, {'"probe_pick": 2', '"probe_pick_key": b'}}) do
    params:set("probe_pick", 1)
    params:read(pset_with(context, "both", lines))
    assert_equal(S.lib.io_keyed.key("probe_pick"), "b", "the key's choice: " .. table.concat(lines, ", "))
    assert_equal(params:get("probe_pick"), 3, "its option shown")
    assert_equal(got[#got], "b", "the last action had the key's choice")
  end
end)

test("a PSET without the key puts the first key back", function()
  local context, S = started()
  local got = probe(S)
  params:set("probe_pick", 3)
  params:read(pset_with(context, "older", {}))
  assert_equal(S.lib.io_keyed.key("probe_pick"), "off")
  assert_equal(params:get("probe_pick"), 1)
  assert_equal(got[#got], "off")
end)

end
