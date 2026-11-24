-- test/unit/ui_layout_test.lua
-- The screen layout on every page: header, hint row, nothing overlapping
-- or off-screen (assert_screen_layout in test/helpers.lua). The check of
-- every page record with every voice, source, ALT state and flash, and each
-- record's layout_states, runs in the part files ui_layout_<part>_test.lua
-- (test/layout_parts.lua, #1001); this file checks that they draw every case
-- once, and keeps the older every-page checks and the page renders' JSON
-- dump (test/render_pages.lua).
-- Run alone: lua test/run.lua ui_layout

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, finish_startup = h.load_strata, h.find_upvalue, h.local_value, h.finish_startup
local text_span, PAGE_TITLES, HINT_ROW_Y, TEXT_HEIGHT = h.text_span, h.PAGE_TITLES, h.HINT_ROW_Y, h.TEXT_HEIGHT
local show_page, assert_screen_layout, next_frame, count_screen_draws = h.show_page, h.assert_screen_layout, h.next_frame, h.count_screen_draws
local tap = h.tap

local parts = require("layout_parts")
-- The sources and flashes every page is drawn with (test/layout_parts.lua)
local LAYOUT_SOURCES, LAYOUT_FLASHES = parts.SOURCES, parts.FLASHES

local function started_script() return parts.started_script(h) end

-- A state a record lists is drawn, with ALT up and down, each on a fresh
-- script: a probe on FX, against FX's own states (the part files draw
-- every record's, test/layout_parts.lua)
test("a page record's layout state is drawn with ALT up and down, each on a fresh script", function()
  started_script()
  local FX = local_value("S").constants.UI_PAGES.index.FX
  local baseline = parts.check_layout_states(h, started_script, { FX })
  local fx_own = 0
  local probed = 0
  local drawn = parts.check_layout_states(h, function()
    local probe_context = started_script()
    fx_own = #(local_value("S").registry.pages[FX].layout_states or {})
    local_value("S").registry.pages[FX].layout_states = {
      { name = "probe", setup = function() probed = probed + 1; params:set("filter_mix", 0) end } }
    return probe_context
  end, { FX })
  assert_equal(drawn, baseline - fx_own + 1, "the probe state is drawn beside the other records' own")
  assert_equal(probed, 2, "with ALT up and down, each on a fresh script")
end)

-- #1001: the layout check is split by page across the unit files
-- ui_layout_<part>_test.lua (test/layout_parts.lua), so a run's processes
-- share it. Run with the draws counted, not made, those files together draw
-- what one test's loops drew: every page by every voice, source, ALT state
-- and flash, and each record's layout states with ALT up and down, each
-- exactly once
test("the ui_layout part files draw every page by every voice, source, ALT state and flash, and each layout state, once (#1001)", function()
  started_script()
  local records = local_value("S").registry.pages
  local voice_count = #local_value("voices")
  assert_equal(#records, #PAGE_TITLES, "a page record for each page title")
  local expected, expected_count = {}, 0
  for page = 1, #PAGE_TITLES do
    for voice_idx = 1, voice_count do
      for source = 1, #LAYOUT_SOURCES do
        for _, alt in ipairs({ false, true }) do
          for flash = 1, #LAYOUT_FLASHES do
            expected[string.format("%s, voice %d, %s%s, %s", PAGE_TITLES[page], voice_idx,
              LAYOUT_SOURCES[source].name, alt and ", ALT" or "", LAYOUT_FLASHES[flash])] = true
            expected_count = expected_count + 1
          end
        end
      end
    end
    for state_index = 1, #(records[page].layout_states or {}) do
      for _, alt in ipairs({ false, true }) do
        expected[string.format("%s state %d%s", records[page].name, state_index, alt and " with ALT" or "")] = true
        expected_count = expected_count + 1
      end
    end
  end
  assert_true(expected_count > #PAGE_TITLES * voice_count * #LAYOUT_SOURCES * 2 * #LAYOUT_FLASHES,
    "the pages list layout states")
  local drawn, extra, total = {}, {}, 0
  local function count(where)
    total = total + 1
    if expected[where] then drawn[where] = (drawn[where] or 0) + 1 else extra[#extra + 1] = where end
  end
  local real_case, real_state = parts.draw_case, parts.draw_state
  parts.draw_case = function(_, _, _, case)
    count(string.format("%s, voice %d, %s%s, %s", PAGE_TITLES[case.page], case.voice, case.source.name,
      case.alt and ", ALT" or "", case.flash))
  end
  parts.draw_state = function(_, _, entry, state_index, alt)
    count(string.format("%s state %d%s", entry.name, state_index, alt and " with ALT" or ""))
  end
  local files = {}
  for _, name in ipairs(h.unit_files(h.test_dir .. "/unit")) do
    if name:match("^ui_layout_.+_test%.lua$") then files[#files + 1] = name end
  end
  local ok, problem = pcall(function()
    for _, name in ipairs(files) do
      local bodies = {}
      dofile(h.test_dir .. "/unit/" .. name)(setmetatable({ test = function(_, body) bodies[#bodies + 1] = body end },
        { __index = h }))
      assert_true(#bodies > 0, name .. " registers a test")
      for _, body in ipairs(bodies) do body() end
    end
  end)
  parts.draw_case, parts.draw_state = real_case, real_state
  assert_true(ok, tostring(problem))
  assert_true(#files >= 2, #files .. " part files")
  table.sort(extra)
  assert_equal(table.concat(extra, "; "), "", "the part files draw no case today's loops did not")
  local missing, twice = {}, {}
  for where in pairs(expected) do
    if not drawn[where] then missing[#missing + 1] = where elseif drawn[where] > 1 then twice[#twice + 1] = where end
  end
  table.sort(missing); table.sort(twice)
  assert_equal(#missing, 0, "cases no part file draws: " .. table.concat(missing, "; ", 1, math.min(#missing, 5)))
  assert_equal(#twice, 0, "cases drawn twice: " .. table.concat(twice, "; ", 1, math.min(#twice, 5)))
  assert_equal(total, expected_count, "the part files draw as many cases as today's loops")
end)

-- A JSON value's text is well formed: the next value from `pos`, and the
-- position after it (nil on an error)
local function json_value_end(text, pos)
  pos = text:find("%S", pos) or #text + 1
  local char = text:sub(pos, pos)
  if char == "{" or char == "[" then
    local close = char == "{" and "}" or "]"
    pos = text:find("%S", pos + 1)
    if pos and text:sub(pos, pos) == close then return pos + 1 end
    while pos do
      if char == "{" then
        local key_end = json_value_end(text, pos)
        if not key_end or text:sub(pos, pos) ~= '"' then return nil end
        pos = text:find("%S", key_end)
        if not pos or text:sub(pos, pos) ~= ":" then return nil end
        pos = pos + 1
      end
      pos = json_value_end(text, pos)
      if not pos then return nil end
      pos = text:find("%S", pos)
      if not pos then return nil end
      local separator = text:sub(pos, pos)
      if separator == close then return pos + 1 end
      if separator ~= "," then return nil end
      pos = pos + 1
    end
    return nil
  elseif char == '"' then
    local index = pos + 1
    while index <= #text do
      local c = text:sub(index, index)
      if c == "\\" then index = index + 2
      elseif c == '"' then return index + 1
      elseif c:byte() < 32 then return nil
      else index = index + 1 end
    end
    return nil
  end
  for _, literal in ipairs({ "true", "false", "null" }) do
    if text:sub(pos, pos + #literal - 1) == literal then return pos + #literal end
  end
  local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
  if number and #number > 0 then return pos + #number end
  return nil
end

local function well_formed_json(text)
  local value_end = json_value_end(text, 1)
  return value_end ~= nil and text:find("%S", value_end) == nil
end

test("the render dump writes one file per page state", function()
  assert_true(well_formed_json('{"a":[1,-2.5e3,"x\\"y",true,null],"b":{}}'), "the checker accepts JSON")
  assert_true(not well_formed_json('{"a":[1,}'), "and rejects broken JSON")
  local render = dofile(h.test_dir .. "/render_pages.lua")
  local out_dir = h.data_root .. "renders"
  local written = render.render_page_states(out_dir)
  assert_true(#written >= 13, #written .. " page states written")
  load_strata()
  local pages = {}
  for _, name in ipairs(local_value("UI_PAGES")) do pages[name:lower()] = true end
  local shown = {}
  for _, name in ipairs(written) do
    local page = name:match("^(%a+)%-[%w%-]+%.json$")
    assert_true(page and pages[page], name .. " names a page from UI_PAGES")
    shown[page] = true
    local file = assert(io.open(out_dir .. "/" .. name, "r")); local text = file:read("*a"); file:close()
    assert_true(well_formed_json(text), name .. " is well-formed JSON")
    assert_true(text:find('"page":"' .. page:upper() .. '"', 1, true), name .. " names its page")
    assert_true(text:find('"texts":[{', 1, true), name .. " holds the drawn texts")
  end
  for page in pairs(pages) do assert_true(shown[page], "a render of " .. page) end
end)

-- #860: a state that fails in the dump (its setup, its draw or the cleanup
-- after it, which only the dump runs) fails naming its page and state, with
-- the traceback, so one line of a run's output says which
test("a render dump failure names the page state that failed", function()
  local render = dofile(h.test_dir .. "/render_pages.lua")
  table.insert(render.STATES, 1, { page = "FX", name = "probe fails", setup = function() error("probe raised") end })
  local ok, problem = pcall(render.render_page_states, h.data_root .. "renders-probe")
  assert_true(not ok, "the dump fails")
  problem = tostring(problem)
  assert_true(problem:find("FX state probe fails", 1, true) ~= nil, "it names the page and state: " .. problem)
  assert_true(problem:find("probe raised", 1, true) ~= nil, "and the error: " .. problem)
  assert_true(problem:find("traceback", 1, true) ~= nil, "with its traceback: " .. problem)
  cleanup()
end)

-- #860: a page's states shifted between the count and a state's fresh load
-- (a source edited mid-run) fail the dump, never write one state's draw
-- under another's name
test("a render dump state shifted after the count fails, naming both", function()
  local helpers = require("helpers")  -- the module itself: h is a view of it
  local real_load, loads = helpers.load_strata, 0
  helpers.load_strata = function(...)
    local context = real_load(...)
    loads = loads + 1
    if loads > 1 then  -- every load after the count's: a state slips in first
      for _, record in ipairs(local_value("S").registry.pages) do
        if record.layout_states and #record.layout_states > 0 then
          table.insert(record.layout_states, 1, { name = "intruder", setup = function() end })
          break
        end
      end
    end
    return context
  end
  local ok, render = pcall(dofile, h.test_dir .. "/render_pages.lua")  -- it takes load_strata as it loads
  helpers.load_strata = real_load
  assert_true(ok, tostring(render))
  render.STATES = {}
  local dumped, problem = pcall(render.render_page_states, h.data_root .. "renders-shifted")
  assert_true(not dumped, "the dump fails")
  problem = tostring(problem)
  assert_true(problem:find("intruder", 1, true) ~= nil, "it names the state that ran: " .. problem)
  assert_equal(loads, 2, "at the first state: the count's load and the state's")
  cleanup()
end)

test("every page's header, hints and text stay apart and inside 128x64 (M7)", function()
  local context = load_strata()
  params:set("mutation_enabled", 1)
  params:set("master_density", 2.0)
  capture_scene(8)
  recall_scene(8, 0)
  -- the widest SETUP page: four grids of every size and an arc
  context.grid.plug(1, 16, 16)
  context.grid.plug(2, 16, 8)
  context.grid.plug(3, 8, 16)
  context.grid.plug(4, 8, 8)
  context.arc.plug(1)
  local voices = local_value("voices")
  local _, set_selected = find_upvalue("selected_voice")
  for voice_idx = 1, 7 do
    set_selected(voice_idx)
    if not voices[voice_idx].active then toggle_voice(voice_idx) end
    if not local_value("locked")[voice_idx] then toggle_lock(voice_idx) end
    params:set("v" .. voice_idx .. "_grain_mode", 2)  -- MAIN shows [T]
    for page = 1, #PAGE_TITLES do
      show_page(page)
      assert_screen_layout(context, PAGE_TITLES[page] .. ", voice " .. voice_idx)
    end
  end
  -- UI.ScrollingList draws row i at y + 5 + (i - 1) * 11; its last row must
  -- end above the hint row
  local voice_list = local_value("voice_list")
  local last_row_y = voice_list.y + 5 + (voice_list.num_visible - 1) * 11
  assert_true(last_row_y <= HINT_ROW_Y - TEXT_HEIGHT,
    "voice list's last row (y " .. last_row_y .. ") clears the hint row")
end)

test("every page draws within 128x64 with a header and hint row", function()
  local context = load_strata(); finish_startup(context)
  for page = 1, #PAGE_TITLES do
    show_page(PAGE_TITLES[page])
    local texts = context.screen.texts
    assert_equal(texts[1].text, PAGE_TITLES[page], "page title")
    for _, entry in ipairs(texts) do
      local left, right = text_span(entry)
      assert_true(left >= 0 and right <= 128 and entry.y <= 64, "text inside screen on page " .. page)
    end
  end
end)

-- The SEQ notes give the header status's positions as HEADER has them (#428)
test("the SEQ notes place the header status and play mark where HEADER does (#428)", function()
  load_strata()
  local HEADER = local_value("HEADER")
  local file = assert(io.open(h.repo_root .. "/docs/notes/lua/pages/seq.md"))
  local text = file:read("*a"); file:close()
  local status_x, play_x = text:match("`draw_header` draws it at x (%d+) with the play mark at x (%d+)")
  assert_equal(tonumber(status_x), HEADER.status_x, "the status text's x")
  assert_equal(tonumber(play_x), HEADER.status_play_x, "the play mark's x")
end)

-- #557: every page whose ALT+K2 randomizes lists a layout state with ALT+K2
-- held past the hold time, so the layout check (check_layout_states) draws
-- its K2:cancel or K2:reset hint
test("every randomizing page has a layout state with ALT+K2 held past the hold time (#557)", function()
  load_strata()
  local pages = {}
  for index, record in ipairs(local_value("S").registry.pages) do
    if record.randomize_section then
      local held = {}
      for state_index, state in ipairs(record.layout_states or {}) do
        if state.name and state.name:find("ALT+K2 held past the hold time", 1, true) then held[#held + 1] = state_index end
      end
      pages[#pages + 1] = { index = index, name = record.name, held = held }
    end
  end
  assert_equal(#pages, 6, "MAIN, VOICE, SEQ, FX, LFO and MOD randomize")
  for _, page in ipairs(pages) do
    assert_true(#page.held >= 1, page.name .. " lists a layout state with ALT+K2 held past the hold time")
    for _, state_index in ipairs(page.held) do
      local context = load_strata(); finish_startup(context)
      show_page(page.index)
      local state = local_value("S").registry.pages[page.index].layout_states[state_index]
      state.setup(context)
      context.screen.clear(); redraw()
      local hint = h.hint_text(context) or ""
      assert_true(hint:find("^K2:cancel") or hint:find("^K2:reset"),
        page.name .. ", " .. state.name .. ": the hint is K2:cancel or K2:reset (" .. hint .. ")")
      assert_screen_layout(context, page.name .. " state " .. state.name)
      key(2, 0); key(1, 0)
    end
  end
end)

end
