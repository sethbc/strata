-- test/unit/io_wtape_test.lua
-- W/ tape's transport (lib/io/wtape.lua, S.lib.io_wtape): six action rows on
-- IO's wtape section, each sending one command (crow-ii.md §2, W/).
-- S.lib.io_ii is a recording double (plan-common.md, Doubles).
-- Run alone: lua test/run.lua io_wtape

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function started(leading)
  local log, state = {}, {leading = leading ~= false}
  local context = load_strata({before_init = function()
    local function record(name)
      return function(...)
        log[#log + 1] = {name, ...}
        return state.leading and state.accept ~= false
      end
    end
    local_value("S").lib.io_ii = {leads = function() return state.leading end,
      send = record("send"), send_off = record("send_off"), send_direct = record("send_direct"),
      add_params = function() end}
  end})
  finish_startup(context)
  return context, local_value("S"), log, state
end

local function line(entry) return table.concat(entry, ",") end

local function row(S, label)
  for _, entry in ipairs(S.lib.pages_io.rows()) do
    if entry.section == "wtape" and entry.label == label then return entry end
  end
end

local function title_status(S)
  for _, entry in ipairs(S.lib.pages_io.rows()) do
    if entry.kind == "title" and entry.section == "wtape" then return entry.status end
  end
end

-- K3 on the row, as a user does: the section at the top, E2 down to the row
local function press(S, label)
  S.lib.ui_keys.set_ui_page(S.constants.UI_PAGES.index.IO)
  S.lib.pages_io.show_section("wtape")
  enc(2, 1); enc(2, -1)  -- the page acts only on a row the user has moved to
  for _ = 1, 6 do
    if S.lib.pages_io.rows()[S.io_cursor].label == label then break end
    enc(2, 1)
  end
  assert_equal(S.lib.pages_io.rows()[S.io_cursor].label, label, "the cursor reached " .. label)
  key(3, 1); key(3, 0)
end

test("each row sends its one command and shows what it sent", function()
  local _, S, log = started()
  assert_equal(#log, 0, "nothing at the start")
  for _, label in ipairs({"record", "play", "reverse", "loop start", "loop end", "loop"}) do
    assert_equal(row(S, label).shown, "-", label .. " before any command")
  end
  press(S, "record")
  assert_equal(line(log[1]), "send,wtape,record,1"); assert_equal(row(S, "record").shown, "on")
  press(S, "record")
  assert_equal(line(log[2]), "send,wtape,record,0"); assert_equal(row(S, "record").shown, "off")
  press(S, "play")
  assert_equal(line(log[3]), "send,wtape,play,1"); assert_equal(row(S, "play").shown, "on")
  press(S, "play")
  assert_equal(line(log[4]), "send,wtape,play,0")
  press(S, "reverse")
  assert_equal(line(log[5]), "send,wtape,reverse"); assert_equal(row(S, "reverse").shown, "sent")
  press(S, "loop start")
  assert_equal(line(log[6]), "send,wtape,loop_start")
  press(S, "loop end")
  assert_equal(line(log[7]), "send,wtape,loop_end")
  press(S, "loop")
  assert_equal(line(log[8]), "send,wtape,loop_active,1"); assert_equal(row(S, "loop").shown, "on")
  press(S, "loop")
  assert_equal(line(log[9]), "send,wtape,loop_active,0")
  assert_equal(#log, 9)
  assert_equal(title_status(S), nil, "no status while the bus leads")
end)

test("while the bus does not lead a row sends nothing and says so", function()
  local _, S, log = started(false)
  press(S, "record")
  assert_equal(#log, 0, "nothing sent")
  assert_equal(row(S, "record").shown, "-", "the text stays")
  assert_equal(S.lib.ui_flash.text("hints"), "ii bus is not strata's")
  assert_equal(title_status(S), "[--]")
end)

test("the section has no params and no target", function()
  local _, S = started()
  for _, record in ipairs(S.registry.note_targets) do assert_true(record.name ~= "wtape") end
  for _, record in ipairs(S.registry.ii_devices) do assert_true(record.name ~= "wtape") end
end)

test("without the ii module the device does nothing and the page draws", function()
  -- the real ii module taken away before init (ruling 6)
  local context = load_strata({before_init = function() local_value("S").lib.io_ii = nil end})
  finish_startup(context)
  local S = local_value("S")
  assert_equal(S.lib.io_ii, nil)
  press(S, "record")
  assert_equal(row(S, "record").shown, "-")
  assert_equal(title_status(S), "[--]")
  local ok, problem = pcall(redraw)
  assert_true(ok, tostring(problem))
end)

test("a command the queue dropped is not shown as sent, and the next press sends the same value", function()
  -- ruling 13: while the bus leads and send returns false the row and its next value stay
  local _, S, log, state = started()
  state.accept = false
  press(S, "play")
  assert_equal(#log, 1, "the line was offered")
  assert_equal(row(S, "play").shown, "-", "not shown as sent")
  assert_equal(S.lib.ui_flash.text("hints"), "ii queue full")
  state.accept = true
  press(S, "play")
  assert_equal(line(log[2]), "send,wtape,play,1", "the same value again")
  assert_equal(row(S, "play").shown, "on")
  state.accept = false
  press(S, "play")
  assert_equal(row(S, "play").shown, "on", "a dropped press leaves the text")
  state.accept = true
  press(S, "play")
  assert_equal(line(log[4]), "send,wtape,play,0", "and the alternation")
  assert_equal(row(S, "play").shown, "off")
  -- a non-alternating row: a dropped press leaves its text, before and after a command
  state.accept = false
  press(S, "reverse")
  assert_equal(row(S, "reverse").shown, "-", "reverse stays - before any command")
  assert_equal(S.lib.ui_flash.text("hints"), "ii queue full")
  S.lib.ui_flash.start("hints", nil)
  state.accept = true
  press(S, "reverse")
  assert_equal(row(S, "reverse").shown, "sent")
  state.accept = false
  press(S, "reverse")
  assert_equal(row(S, "reverse").shown, "sent", "and sent after one")
  assert_equal(S.lib.ui_flash.text("hints"), "ii queue full")
end)

test("the bus leaving and returning mid-sequence", function()
  local _, S, log, state = started()
  press(S, "record")
  assert_equal(line(log[1]), "send,wtape,record,1"); assert_equal(row(S, "record").shown, "on")
  state.leading = false
  press(S, "record")
  assert_equal(#log, 1, "nothing is sent while the bus does not lead")
  assert_equal(row(S, "record").shown, "on", "the text stays on")
  state.leading = true
  press(S, "record")
  assert_equal(line(log[2]), "send,wtape,record,0")
  assert_equal(row(S, "record").shown, "off")
end)

-- The layout states reach the leading look as a player does: through the
-- real leads() (the rig's ii_bus and a crow), the ii section's rig row and
-- K3 (ruling 12). The double's leads() answers from that real state.
local function started_real_bus(with_ii)
  local log = {}
  local context = load_strata({before_init = function()
    local S = local_value("S")
    -- without it the real ii module is taken away before init (ruling 6)
    if not with_ii then S.lib.io_ii = nil; return end
    S.lib.io_ii = {
      leads = function() return S.lib.io_rig.get("ii_bus") == "strata" and S.lib.io_crow.present() end,
      send = function(...) log[#log + 1] = {"send", ...}; return S.lib.io_ii.leads() end,
      send_off = function() return false end, send_direct = function() return false end,
      add_params = function() end}
  end})
  finish_startup(context)
  local S = local_value("S")
  if with_ii then
    for index = #S.registry.io_sections, 1, -1 do
      if S.registry.io_sections[index].name == "ii" then table.remove(S.registry.io_sections, index) end
    end
    S.register_io_section({name = "ii", title = "ii",
      rows = function() return {{kind = "rig", key = "ii_bus", label = "bus"}} end})
  end
  return context, S, log
end

local function wtape_states(S)
  for _, record in ipairs(S.registry.io_sections) do
    if record.name == "wtape" then return record.layout_states end
  end
end

local function state_named(S, name)
  for _, state in ipairs(wtape_states(S)) do if state.name == name then return state end end
  error("no layout state " .. name)
end

test("the not-leading state draws the not-leading look", function()
  local context, S = started_real_bus(true)
  state_named(S, "the bus not leading").setup(context)
  assert_equal(S.lib.io_ii.leads(), false)
  assert_equal(title_status(S), "[--]")
end)

test("the leading states end with the bus leading and show what a player's presses would", function()
  local context, S, log = started_real_bus(true)
  state_named(S, "leading before any command").setup(context)
  assert_true(S.lib.io_ii.leads(), "the bus leads")
  assert_equal(S.lib.io_rig.get("ii_bus"), "strata")
  assert_equal(#log, 0, "nothing sent yet")
  assert_equal(title_status(S), nil)
  assert_equal(row(S, "record").shown, "-")

  context, S, log = started_real_bus(true)
  state_named(S, "leading after commands").setup(context)
  assert_true(S.lib.io_ii.leads(), "the bus leads")
  local lines = {}
  for _, entry in ipairs(log) do lines[#lines + 1] = line(entry) end
  assert_equal(table.concat(lines, "|"), "send,wtape,record,1|send,wtape,play,1|send,wtape,reverse|"
    .. "send,wtape,loop_start|send,wtape,loop_end|send,wtape,loop_active,1")
  assert_equal(row(S, "record").shown, "on"); assert_equal(row(S, "play").shown, "on")
  assert_equal(row(S, "reverse").shown, "sent"); assert_equal(row(S, "loop").shown, "on")
end)

test("the leading states turn the bus setting from wherever it stands", function()
  -- the test may set the rig; the module never does. The value is read, never the row's text
  for _, from in ipairs({"off", "strata", "teletype"}) do
    for _, name in ipairs({"leading before any command", "leading after commands"}) do
      local context, S = started_real_bus(true)
      S.lib.io_rig.set("ii_bus", from)
      state_named(S, name).setup(context)
      assert_equal(S.lib.io_rig.get("ii_bus"), "strata", name .. " from " .. from)
      assert_true(S.lib.io_ii.leads(), name .. " from " .. from .. ": the bus leads")
    end
  end
end)

test("without the ii module each layout state draws and sends nothing", function()
  local context, S = started_real_bus(false)
  for _, state in ipairs(wtape_states(S)) do
    state.setup(context)
    local ok, problem = pcall(redraw)
    assert_true(ok, state.name .. ": " .. tostring(problem))
    assert_equal(title_status(S), "[--]", state.name)
  end
  assert_equal(#context.crow.sent, 0, "nothing reached crow")
end)

test("a layout state raises where the ii section is present and the bus still does not lead", function()
  local context, S = started_real_bus(true)
  S.lib.io_ii.leads = function() return false end  -- a bus that never leads, whatever the row says
  local ok, problem = pcall(state_named(S, "leading before any command").setup, context)
  assert_true(not ok, "raises")
  assert_true(tostring(problem):find("ii_bus", 1, true), tostring(problem))
  -- and without the row the state quietly stays on the not-leading look
  for _, record in ipairs(S.registry.io_sections) do
    if record.name == "ii" then record.rows = function() return {{kind = "status", text = "no bus row"}} end end
  end
  assert_true(pcall(state_named(S, "leading after commands").setup, context), "no row: no raise")
end)
end
