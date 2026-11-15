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
      return function(...) log[#log + 1] = {name, ...}; return state.leading end
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
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_equal(S.lib.io_ii, nil)
  press(S, "record")
  assert_equal(row(S, "record").shown, "-")
  assert_equal(title_status(S), "[--]")
  local ok, problem = pcall(redraw)
  assert_true(ok, tostring(problem))
end)
end
