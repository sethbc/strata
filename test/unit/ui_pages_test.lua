-- test/unit/ui_pages_test.lua
-- The eight screen pages and their records (S.registry.pages): the page
-- order, E1, enter/leave, the hint row from the record, and who sets
-- which record field (lib/pages/ vs lib/arc/)
-- Run alone: lua test/run.lua ui_pages

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, hint_text, read_lua_sources = h.show_page, h.hint_text, h.read_lua_sources
local sync_check = h.sync_check

-- The record fields an arc file sets; a page file sets every other field
local ARC_FIELDS = { arc_delta = true, arc_redraw = true, arc_alt_delta = true, arc_alt_redraw = true }
local PAGE_FIELDS = { "name", "draw", "hints", "enc", "key", "alt_enc", "alt_key", "key_release",
  "alt_key_release", "enter", "leave", "arc_button", "header_status", "layout_states" }

test("there are eight pages in the 3.1 order", function()
  load_strata()
  local C = local_value("S").constants
  assert_equal(table.concat(C.UI_PAGES, " "), "MAIN VOICE SEQ FX LFO BUFFER SCENES SETUP")
  assert_equal(C.NUM_UI_PAGES, 8)
  assert_equal(C.UI_PAGES.MAIN_PAGE, 1, "MAIN stays page 1")
  for index, name in ipairs(C.UI_PAGES) do
    assert_equal(C.UI_PAGES.index[name], index, "UI_PAGES.index." .. name)
  end
  assert_equal(C.UI_PAGES.index.SCENES, 7)
end)

test("E1 stops at MAIN and SETUP", function()
  load_strata(); enc(1, -3); assert_equal(local_value("ui_page"), 1)
  enc(1, 20); assert_equal(local_value("ui_page"), 8)
  assert_equal(local_value("UI_PAGES")[local_value("ui_page")], "SETUP")
end)

test("every page has a record with the required handlers", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for index, name in ipairs(S.constants.UI_PAGES) do
    local record = S.registry.pages[index]
    assert_true(record, "a record for " .. name)
    assert_equal(record.name, name, "record " .. index .. " name")
    for _, field in ipairs({ "draw", "hints", "enc", "key" }) do
      assert_equal(type(record[field]), "function", name .. "." .. field)
    end
    assert_equal(type(record.hints(false)), "string", name .. " hints")
    assert_equal(type(record.hints(true)), "string", name .. " hints with ALT")
  end
end)

test("page enter and leave run on page changes only", function()
  load_strata()
  local S = local_value("S")
  local counts = { enter = 0, leave = 0 }
  local buffer = S.registry.pages[S.constants.UI_PAGES.index.BUFFER]
  buffer.enter = function() counts.enter = counts.enter + 1 end
  buffer.leave = function() counts.leave = counts.leave + 1 end
  show_page("BUFFER"); show_page("BUFFER")
  assert_equal(counts.enter, 1, "BUFFER entered once")
  assert_equal(counts.leave, 0, "and not left")
  show_page("FX")
  assert_equal(counts.leave, 1, "leaving for FX runs leave once")
  assert_equal(counts.enter, 1, "and no enter")
  enc(1, -20); enc(1, -1)  -- MAIN, then E1 past the first page: no change
  assert_equal(counts.enter, 1); assert_equal(counts.leave, 1)
end)

test("the hint row comes from the page record and follows ALT", function()
  local context = load_strata()
  local S = local_value("S")
  S.registry.pages[S.constants.UI_PAGES.index.FX].hints = function(alt) return alt and "alt" or "plain" end
  show_page("FX")
  redraw(); assert_equal(hint_text(context), "plain")
  key(1, 1)
  redraw(); assert_equal(hint_text(context), "alt")
  key(1, 0)
  redraw(); assert_equal(hint_text(context), "plain", "K1 released")
end)

test("the hint row is drawn once, by redraw, not by the page's draw", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for index, name in ipairs(S.constants.UI_PAGES) do
    show_page(name)
    local hint_rows = 0
    for _, entry in ipairs(context.screen.texts) do
      if entry.x == 0 and entry.y == h.HINT_ROW_Y then hint_rows = hint_rows + 1 end
    end
    assert_equal(hint_rows, 1, name .. " draws one hint row")
    assert_equal(hint_text(context), S.registry.pages[index].hints(false), name .. " hint row is its hints()")
  end
end)

-- The record fields `text` assigns: `<x>.<field> =` and `<field> =` inside
-- a table constructor, with comments and strings blanked out
local function assigned_fields(text)
  local sanitized = sync_check.sanitize_lua(text)
  local fields = {}
  for field in sanitized:gmatch("%.([%a_][%w_]*)%s*=[^=]") do fields[field] = true end
  for field in sanitized:gmatch("[{,]%s*([%a_][%w_]*)%s*=[^=]") do fields[field] = true end
  return fields
end

test("page files never set arc fields and arc files set nothing else", function()
  local page_files, arc_files = 0, 0
  for _, source in ipairs(read_lua_sources()) do
    local fields = assigned_fields(source.text)
    if source.path:match("^lib/pages/") then
      page_files = page_files + 1
      for field in pairs(ARC_FIELDS) do
        assert_true(not fields[field], source.path .. " sets " .. field .. " (only lib/arc/<page>.lua does)")
      end
    elseif source.path:match("^lib/arc/") and source.path ~= "lib/arc/core.lua" then
      arc_files = arc_files + 1
      for _, field in ipairs(PAGE_FIELDS) do
        assert_true(not fields[field], source.path .. " sets the page field " .. field .. " (only lib/pages/<page>.lua does)")
      end
    end
  end
  assert_equal(page_files, 8, "eight page files")
  assert_equal(arc_files, 7, "seven page ring files (SETUP has none)")
end)

test("strata.lua includes every page file, then every arc file", function()
  local text = read_lua_sources()[1].text
  local last_page, first_arc = 0, math.huge
  local includes = {}
  for start, path in text:gmatch('()include%("(lib/[%w_/]+)"%)') do
    includes[path] = true
    if path:match("^lib/pages/") then last_page = math.max(last_page, start) end
    if path:match("^lib/arc/") then first_arc = math.min(first_arc, start) end
  end
  assert_true(last_page < first_arc, "every lib/pages/ include comes before every lib/arc/ include")
  load_strata()
  for _, name in ipairs(local_value("UI_PAGES")) do
    assert_true(includes["lib/pages/" .. name:lower()], "lib/pages/" .. name:lower() .. " is included")
    if name ~= "SETUP" then
      assert_true(includes["lib/arc/" .. name:lower()], "lib/arc/" .. name:lower() .. " is included")
    end
  end
end)
end
