-- test/unit/ui_layout_test.lua
-- The screen layout on every page: header, hint row, nothing overlapping
-- or off-screen (assert_screen_layout in test/helpers.lua), for every page
-- record with every voice, source, ALT state and flash, and each record's
-- layout_states. Also the page renders' JSON dump (test/render_pages.lua).
-- Run alone: lua test/run.lua ui_layout

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, finish_startup = h.load_strata, h.find_upvalue, h.local_value, h.finish_startup
local text_span, PAGE_TITLES, HINT_ROW_Y, TEXT_HEIGHT = h.text_span, h.PAGE_TITLES, h.HINT_ROW_Y, h.TEXT_HEIGHT
local show_page, assert_screen_layout, next_frame, count_screen_draws = h.show_page, h.assert_screen_layout, h.next_frame, h.count_screen_draws
local tap = h.tap

-- The sources every page is drawn with (v<i>_source options)
local LAYOUT_SOURCES = { { name = "synth", option = 1 }, { name = "buf 1", option = 2 }, { name = "input", option = 10 } }
local LAYOUT_FLASHES = { "no flash", "header flash", "hints flash" }

-- Start the flash `kind` names (LAYOUT_FLASHES): a header flash long enough
-- to need cutting, the longest hints flash a page raises
local function start_layout_flash(S, kind)
  S.lib.ui_flash.cancel_all()
  if kind == "header flash" then
    header_flash("v1 grain density 12.5 Hz, a header flash long enough to be cut")
  elseif kind == "hints flash" then
    S.lib.ui_flash.start("hints", "K3 again: overwrite S16")  -- the longest planned
  end
end

-- Draw every page record's layout_states, each on a fresh script from
-- `load()` (which returns its context), with ALT up and down, and check
-- the layout. Returns the number of states drawn
local function check_layout_states(load)
  load()
  local entries = {}
  for index, record in ipairs(local_value("S").registry.pages) do
    entries[index] = { name = record.name, count = #(record.layout_states or {}) }
  end
  local drawn = 0
  for index, entry in ipairs(entries) do
    for state_index = 1, entry.count do
      for _, alt in ipairs({ false, true }) do
        local context = load()
        show_page(index)
        local state = local_value("S").registry.pages[index].layout_states[state_index]
        assert_true(type(state.setup) == "function", entry.name .. " layout state " .. state_index .. " has a setup")
        state.setup(context)
        key(1, alt and 1 or 0)
        redraw()
        assert_screen_layout(context, string.format("%s state %s%s", entry.name,
          tostring(state.name or state_index), alt and " with ALT" or ""))
      end
      drawn = drawn + 1
    end
  end
  return drawn
end

local function started_script()
  local context = load_strata(); finish_startup(context)
  return context
end

test("every page lays out with every voice, source, ALT state and flash", function()
  local context = started_script()
  local S = local_value("S")
  local _, set_selected = find_upvalue("selected_voice")
  local voices = local_value("voices")
  for page = 1, #PAGE_TITLES do
    for voice_idx = 1, #voices do
      set_selected(voice_idx)
      for _, source in ipairs(LAYOUT_SOURCES) do
        params:set("v" .. voice_idx .. "_source", source.option)
        for _, alt in ipairs({ false, true }) do
          key(1, alt and 1 or 0)
          for _, flash in ipairs(LAYOUT_FLASHES) do
            show_page(page)
            start_layout_flash(S, flash)
            redraw()
            assert_screen_layout(context, string.format("%s, voice %d, %s%s, %s", PAGE_TITLES[page], voice_idx,
              source.name, alt and ", ALT" or "", flash))
          end
        end
      end
    end
  end
  key(1, 0)
  S.lib.ui_flash.cancel_all()
  -- then each record's own states (none until the Wave 2 pages add them)
  local baseline = check_layout_states(started_script)
  local fx_own = 0
  -- a state a record lists is drawn: a probe on FX
  local probed = 0
  local drawn = check_layout_states(function()
    local probe_context = started_script()
    local FX = local_value("S").constants.UI_PAGES.index.FX
    fx_own = #(local_value("S").registry.pages[FX].layout_states or {})
    local_value("S").registry.pages[FX].layout_states = {
      { name = "probe", setup = function() probed = probed + 1; params:set("filter_mix", 0) end } }
    return probe_context
  end)
  assert_equal(drawn, baseline - fx_own + 1, "the probe state is drawn beside the other records' own")
  assert_equal(probed, 2, "with ALT up and down, each on a fresh script")
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
    if not local_value("frozen")[voice_idx] then toggle_lock(voice_idx) end
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
  assert_equal(#pages, 5, "MAIN, VOICE, SEQ, FX and LFO randomize")
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
