-- test/unit/grid_pages_faders_test.lua
-- Grid page 2, faders (lib/grid/pages/faders.lua, design §10.4, ruling
-- 31): lines 1-4 four faders of the grid voice's fader page or of the
-- shown macro bank, line 5 the fader pages (x 1-10) and the banks (x
-- 12-15), line 6 the voice's type (one key a type, in type order), line 7
-- the voice picker, on every arrangement (h.grid_pane)
-- Run alone: lua test/run.lua grid_pages_faders

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local grid_pane, show_page = h.grid_pane, h.show_page

-- The lines of the page (pane coordinates)
local LINE = {pages = 5, types = 6, voices = 7}
local FADER_LINES = 4
local FIRST_BANK = 12

-- The pane's first and last shown column: a half shows eight
local function shown_columns(pane)
  local first, last
  for x = 1, 16 do
    if pane.shows(x, 1) then
      first = first or x
      last = x
    end
  end
  return first, last
end

local function shown_keys(pane)
  local first, last = shown_columns(pane)
  return last - first + 1
end

-- The pane x of key k (1 the minimum) of a fader line over the shown
-- columns: the 128v's run up (x 1 is its top key)
local function fader_x(pane, k)
  local first, last = shown_columns(pane)
  if pane.arrangement == "128v" then return last - k + 1 end
  return first + k - 1
end

local function faders_pane(context, arrangement, opts)
  local S = local_value("S")
  local pane = grid_pane(context, arrangement, opts)
  pane.show(S.constants.GRID_PAGES.faders)
  return pane
end

-- Each arrangement (or those that show every key of `needs`, {x, y}
-- pairs) on a fresh load, its pane on the faders page
local function each_arrangement(body, needs)
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = faders_pane(context, arrangement)
    local shown = true
    for _, key in ipairs(needs or {}) do shown = shown and pane.shows(key[1], key[2]) end
    if shown then body(context, S, pane, arrangement) end
  end
end

-- The param ids lines 1-4 show of the grid voice's fader page
local function page_ids(S)
  local ids = fader_param_ids(S.grid_voice_select)
  local shown = {}
  for line = 1, FADER_LINES do shown[line] = ids[(S.param_page - 1) * FADER_LINES + line] end
  return shown
end

-- The voice's param_order in the test's own S lengthened with its own keys
-- until it has `pages` fader pages (the faders that follow it fill the
-- rest); `extra` keys more after that. A probe: the next type switch
-- replaces it
local function probe_pages(S, voice_idx, pages, extra)
  local own = {}
  for index, key in ipairs(S.voices[voice_idx].param_order) do own[index] = key end
  local order = {}
  for index, key in ipairs(own) do order[index] = key end
  S.voices[voice_idx].param_order = order
  local n = 0
  while fader_page_count(voice_idx) < pages do
    n = n + 1
    order[#order + 1] = own[(n - 1) % #own + 1]
  end
  for _ = 1, extra or 0 do
    n = n + 1
    order[#order + 1] = own[(n - 1) % #own + 1]
  end
  assert_equal(fader_page_count(voice_idx), pages, "the probe gives voice " .. voice_idx .. " " .. pages .. " pages")
  grid_redraw()
end

local function type_calls(context)
  local found = {}
  for _, call in ipairs(context.calls_named("setVoiceType")) do found[#found + 1] = call.args[1] .. " " .. call.args[2] end
  return table.concat(found, ", ")
end

local function line_levels(pane, y)
  local levels = {}
  for x = 1, 16 do
    local level = pane.led(x, y)
    if level then levels[#levels + 1] = level end
  end
  return table.concat(levels, " ")
end

test("the faders page is registered at its index", function()
  load_strata()
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.faders]
  assert_true(record ~= nil, "a record at page 2")
  assert_equal(record.name, "faders")
  assert_equal(record.sides, nil, "one side")
  assert_equal(type(record.faders), "function", "it has fader lines")
  assert_equal(type(record.signature), "function", "and a signature")
  assert_equal(S.lib.grid_pages_faders.record, record, "the module keeps its record")
end)

-- 256:11 (I8), re-based on every arrangement
test("the faders set and show the picked voice's params (I8)", function()
  each_arrangement(function(_, S, pane, arrangement)
    local keys = shown_keys(pane)
    pane.tap(2, LINE.voices)
    assert_equal(S.grid_voice_select, 2, arrangement .. ": line 7 key 2 picks voice 2 (fm)")
    local ids = fader_param_ids(2)
    assert_equal(ids[1], "v2_freq", arrangement .. ": its first fader is freq")
    assert_equal(ids[2], "v2_ratio", arrangement)
    assert_equal(ids[3], "v2_index", arrangement)
    pane.tap(fader_x(pane, keys), 1)
    local _, freq_max = param_range("v2_freq")
    assert_near(params:get("v2_freq"), freq_max, 1e-6, arrangement .. ": line 1's top key sets freq to its maximum")
    assert_equal(pane.led(fader_x(pane, keys), 1), 15, arrangement .. ": freq shows at its top key")
    local ratio_min = param_range("v2_ratio")
    pane.tap(fader_x(pane, 1), 2)
    assert_near(params:get("v2_ratio"), ratio_min, 1e-6, arrangement .. ": line 2's bottom key sets ratio to its minimum")
    local middle = keys / 2
    pane.tap(fader_x(pane, middle), 3)
    assert_equal(fader_position("v2_index", keys), middle, arrangement .. ": line 3 key " .. middle .. " on index")
    assert_equal(pane.led(fader_x(pane, middle), 3), 15, arrangement .. ": the value bright")
    assert_equal(pane.led(fader_x(pane, middle - 1), 3), 8, arrangement .. ": the bar below it")
    assert_equal(pane.led(fader_x(pane, middle + 1), 3), 0, arrangement .. ": nothing above it")
    -- the faders are the shown page's: page 2's line 1 is fader 5
    if pane.shows(2, LINE.pages) then
      pane.tap(2, LINE.pages)
      assert_equal(S.param_page, 2, arrangement .. ": line 5 key 2 shows fader page 2")
      pane.tap(fader_x(pane, 1), 1)
      local fifth_min = param_range(ids[5])
      assert_near(params:get(ids[5]), fifth_min, 1e-6, arrangement .. ": page 2's line 1 is fader 5")
    end
  end, {{2, LINE.voices}})
end)

-- 128h:137 (its faders, page selector and voice select) and 128v:204
test("four faders, the page keys and the voice keys light as the page shows them", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first, last = shown_columns(pane)
    local keys = shown_keys(pane)
    local count = fader_page_count(1)
    for x = first, last do
      local expected = 0
      if x <= count and x <= 10 then expected = x == 1 and 15 or 4 end
      if x >= FIRST_BANK and x < FIRST_BANK + S.lib.macros.MACROS.banks then expected = 2 end
      assert_equal(pane.led(x, LINE.pages), expected, arrangement .. ": line 5 key " .. x)
      local voice_level = x <= S.constants.NUM_VOICES and (x == 1 and 15 or 4) or 0
      assert_equal(pane.led(x, LINE.voices), voice_level, arrangement .. ": line 7 key " .. x)
    end
    local ids = page_ids(S)
    for line = 1, FADER_LINES do
      pane.tap(fader_x(pane, keys), line)
      assert_equal(fader_position(ids[line], keys), keys, arrangement .. ": line " .. line .. " is fader " .. line)
    end
    if pane.shows(3, LINE.voices) then
      pane.tap(3, LINE.voices)
      assert_equal(S.grid_voice_select, 3, arrangement .. ": line 7 key 3 picks voice 3")
      assert_equal(pane.led(3, LINE.voices), 15, arrangement)
      assert_equal(pane.led(1, LINE.voices), 4, arrangement)
      local voice3 = page_ids(S)
      pane.tap(fader_x(pane, 1), 1)
      assert_equal(fader_position(voice3[1], keys), 1, arrangement .. ": the faders follow the picked voice")
    end
    if pane.shows(8, LINE.voices) then
      local before = S.grid_voice_select
      pane.tap(8, LINE.voices)
      assert_equal(S.grid_voice_select, before, arrangement .. ": line 7 key 8 picks nothing")
    end
    if pane.shows(3, LINE.pages) and fader_page_count(S.grid_voice_select) >= 3 then
      pane.tap(3, LINE.pages)
      assert_equal(S.param_page, 3, arrangement .. ": line 5 key 3 shows page 3")
      assert_equal(pane.led(3, LINE.pages), 15, arrangement .. ": lit")
      assert_equal(pane.led(1, LINE.pages), 4, arrangement .. ": page 1 dim")
    end
  end)
end)

-- 256:323, re-based
test("a buffer voice's faders", function()
  each_arrangement(function(context, S, pane, arrangement)
    local keys = shown_keys(pane)
    params:set("v1_source", 2)
    local ids = fader_param_ids(1)
    assert_equal(table.concat({ids[1], ids[2], ids[3], ids[4], ids[5]}, " "), "v1_buf_pos v1_buf_rate v1_buf_scan v1_amp v1_pan",
      arrangement .. ": the buffer params, the level and pan (the engine pans buffer voices)")
    assert_equal(ids[6], "v1_grain_size", arrangement .. ": the grain faders follow")
    pane.tap(fader_x(pane, keys), 2)
    local _, rate_max = param_range("v1_buf_rate")
    assert_near(params:get("v1_buf_rate"), rate_max, 1e-6, arrangement .. ": line 2 is buf_rate")
    assert_equal(pane.led(fader_x(pane, keys), 2), 15, arrangement)
    if pane.shows(2, LINE.pages) then
      context.clock.advance()  -- voice 1 running
      assert_true(S.voices[1].active, arrangement .. ": voice 1 runs")
      context.clear_engine_calls()
      pane.tap(2, LINE.pages)
      pane.tap(fader_x(pane, 1), 1)
      assert_near(params:get("v1_pan"), -1, 1e-6, arrangement .. ": page 2's line 1 is pan, its bottom key hard left")
      assert_equal(pane.led(fader_x(pane, 1), 1), 15, arrangement .. ": the pan fader shows it")
      local sent
      for _, call in ipairs(context.calls_named("setVoiceParam")) do
        if call.args[1] == 0 and call.args[2] == "pan" then sent = call.args[3] end
      end
      assert_near(sent, -1, 1e-6, arrangement .. ": a buffer voice's pan reaches the engine")
    end
    params:set("v1_source", 1)
    assert_equal(fader_param_ids(1)[1], "v1_freq", arrangement .. ": the synth faders return")
  end)
end)

-- The plan's risk (and ruling 31): no voice has more than ten fader pages
-- on any source or type today
test("no voice has more than ten fader pages on any source or type", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, record in ipairs(S.lib.types.list()) do
      S.lib.types.set(voice_idx, record.key)
      for _, source in ipairs({1, 2, 10}) do
        params:set("v" .. voice_idx .. "_source", source)
        local count = fader_page_count(voice_idx)
        assert_true(count >= 1 and count <= 10,
          "voice " .. voice_idx .. " " .. record.key .. " source " .. source .. ": " .. count .. " pages")
      end
      params:set("v" .. voice_idx .. "_source", 1)
    end
  end
end)

-- 256:1141, re-based
test("a page key past the voice's last page does nothing", function()
  each_arrangement(function(_, S, pane, arrangement)
    local count = fader_page_count(S.grid_voice_select)
    pane.tap(2, LINE.pages)
    assert_equal(S.param_page, 2, arrangement .. ": page 2 is taken")
    for x = count + 1, 10 do
      if pane.shows(x, LINE.pages) then pane.tap(x, LINE.pages) end
      assert_equal(S.param_page, 2, arrangement .. ": key " .. x .. " is past the voice's " .. count .. " pages")
      if pane.shows(x, LINE.pages) then assert_equal(pane.led(x, LINE.pages), 0, arrangement .. ": and dark") end
    end
    for _, x in ipairs({11, 16}) do
      if pane.shows(x, LINE.pages) then pane.tap(x, LINE.pages) end
    end
    assert_equal(S.param_page, 2, arrangement .. ": keys 11 and 16 do nothing")
    assert_equal(pane.led(2, LINE.pages), 15, arrangement .. ": line 5 still shows page 2")
  end, {{2, LINE.pages}})
end)

-- 128h:1082 and 128v:886, re-based on every arrangement
test("the last page is reached", function()
  each_arrangement(function(_, S, pane, arrangement)
    local count = fader_page_count(1)
    local keys = shown_keys(pane)
    if not pane.shows(count, LINE.pages) then return end
    pane.tap(count, LINE.pages)
    assert_equal(S.param_page, count, arrangement .. ": key " .. count .. " shows the last page")
    local ids = fader_param_ids(1)
    local last_line = (#ids - 1) % FADER_LINES + 1
    assert_equal(page_ids(S)[last_line], ids[#ids], arrangement .. ": the last fader on line " .. last_line)
    assert_equal(ids[#ids], "v1_release", arrangement .. ": the last is the release")
    pane.tap(fader_x(pane, keys), last_line)
    local _, release_max = param_range("v1_release")
    assert_near(params:get("v1_release"), release_max, 1e-6, arrangement .. ": its top key sets it")
  end)
end)

-- Ruling 31: line 5's page keys run to x 10
test("line 5 reaches page 10", function()
  each_arrangement(function(_, S, pane, arrangement)
    local keys = shown_keys(pane)
    probe_pages(S, 1, 10)
    local first, last = shown_columns(pane)
    for x = first, math.min(last, 11) do
      local expected = x == 11 and 0 or (x == 1 and 15 or 4)
      assert_equal(pane.led(x, LINE.pages), expected, arrangement .. ": line 5 key " .. x)
    end
    pane.tap(10, LINE.pages)
    assert_equal(S.param_page, 10, arrangement .. ": key 10 shows page 10")
    assert_equal(pane.led(10, LINE.pages), 15, arrangement .. ": lit")
    local ids = fader_param_ids(1)
    local shown = page_ids(S)
    assert_equal(shown[1], ids[37], arrangement .. ": line 1 shows fader 37")
    pane.tap(fader_x(pane, keys), 1)
    assert_equal(fader_position(ids[37], keys), keys, arrangement .. ": and sets it")
    if pane.shows(11, LINE.pages) then
      pane.tap(11, LINE.pages)
      assert_equal(S.param_page, 10, arrangement .. ": key 11 is no page key")
    end
  end, {{10, LINE.pages}})
end)

-- 256:1182, re-based
test("a fader runs the touch hooks once, as grid", function()
  each_arrangement(function(_, S, pane, arrangement)
    local touches = {}
    S.register_param_touch(function(param_id, source) touches[#touches + 1] = param_id .. ":" .. source end)
    local id = page_ids(S)[1]
    pane.tap(fader_x(pane, 2), 1)
    assert_equal(table.concat(touches, " "), id .. ":grid", arrangement .. ": one touch, from the grid")
  end)
end)

-- The bank part of 256:1241, re-based
test("the bank keys show which banks have targets and set_bank picks one", function()
  each_arrangement(function(_, S, pane, arrangement)
    local banks = S.lib.macros.MACROS.banks
    local function bank_levels()
      local levels = {}
      for bank = 1, banks do levels[bank] = pane.led(FIRST_BANK + bank - 1, LINE.pages) end
      return table.concat(levels, " ")
    end
    assert_equal(bank_levels(), "2 2 2 2", arrangement .. ": the voice's faders shown, no bank has targets")
    S.lib.macros.set_target(5, 1, S.lib.macros.target_ids()[1], 0, 1)
    grid_redraw()
    assert_equal(bank_levels(), "2 6 2 2", arrangement .. ": bank 2 has a target: 6")
    pane.tap(FIRST_BANK + 2, LINE.pages)
    assert_equal(S.lib.macros.bank(), 3, arrangement .. ": key 14 shows bank 3")
    assert_equal(S.lib.ui_flash.text("header"), "macros 9-12", arrangement .. ": with set_bank's flash")
    assert_equal(bank_levels(), "2 6 15 2", arrangement .. ": bank 3 shown, bank 2's targets, banks 1 and 4 empty")
    for _, x in ipairs({11, 16}) do
      if pane.shows(x, LINE.pages) then assert_equal(pane.led(x, LINE.pages), 0, arrangement .. ": key " .. x .. " dark") end
    end
  end, {{FIRST_BANK, LINE.pages}})
end)

test("a bank key shows its four macros, a page key goes back to the voice", function()
  each_arrangement(function(_, S, pane, arrangement)
    local keys = shown_keys(pane)
    local voice_ids = page_ids(S)
    pane.tap(FIRST_BANK, LINE.pages)
    assert_equal(S.lib.macros.bank(), 1, arrangement .. ": key 12 is bank 1")
    assert_equal(pane.led(FIRST_BANK, LINE.pages), 15, arrangement .. ": lit while its macros show")
    assert_equal(pane.led(1, LINE.pages), 4, arrangement .. ": the shown fader page dims while the macros show")
    for line = 1, FADER_LINES do
      pane.tap(fader_x(pane, keys), line)
      assert_near(params:get("macro_" .. line), 1.0, 1e-9, arrangement .. ": line " .. line .. " is macro " .. line)
    end
    pane.tap(FIRST_BANK + 1, LINE.pages)
    pane.tap(fader_x(pane, keys), 1)
    assert_near(params:get("macro_5"), 1.0, 1e-9, arrangement .. ": bank 2: line 1 is macro 5")
    pane.tap(1, LINE.pages)
    assert_equal(S.param_page, 1, arrangement .. ": key 1 shows page 1")
    assert_equal(pane.led(1, LINE.pages), 15, arrangement .. ": lit again")
    assert_equal(pane.led(FIRST_BANK + 1, LINE.pages), 2, arrangement .. ": the bank key dims")
    pane.tap(fader_x(pane, 1), 1)
    assert_equal(fader_position(voice_ids[1], keys), 1, arrangement .. ": line 1 is the voice's fader again")
    assert_near(params:get("macro_5"), 1.0, 1e-9, arrangement .. ": and the macro keeps its value")
    -- a voice key goes back to the voice too
    pane.tap(FIRST_BANK, LINE.pages)
    pane.tap(1, LINE.voices)
    assert_equal(pane.led(FIRST_BANK, LINE.pages), 2, arrangement .. ": a voice key ends the macros")
  end, {{FIRST_BANK, LINE.pages}, {1, LINE.pages}})
end)

-- 256:1342, re-based
test("the macros follow a bank change", function()
  each_arrangement(function(_, S, pane, arrangement)
    local keys = shown_keys(pane)
    local touches = {}
    S.register_param_touch(function(param_id, source) touches[#touches + 1] = param_id .. ":" .. source end)
    pane.tap(FIRST_BANK, LINE.pages)
    pane.tap(fader_x(pane, keys), 1)
    assert_near(params:get("macro_1"), 1.0, 1e-9, arrangement .. ": bank 1: line 1's top key sets macro_1 to 1")
    assert_equal(table.concat(touches, " "), "macro_1:grid", arrangement .. ": as a grid touch")
    S.lib.macros.set_bank(4)
    assert_equal(pane.led(fader_x(pane, 1), 1), 15, arrangement .. ": bank 4 set elsewhere: line 1 shows macro_13")
    assert_equal(pane.led(fader_x(pane, keys), 1), 0, arrangement)
    pane.tap(fader_x(pane, keys), 1)
    assert_near(params:get("macro_13"), 1.0, 1e-9, arrangement .. ": the same key sets macro_13")
    assert_near(params:get("macro_1"), 1.0, 1e-9, arrangement .. ": macro_1 keeps its value")
    params:set("macro_14", 1)
    drift_update()
    assert_equal(pane.led(fader_x(pane, keys), 2), 15, arrangement .. ": macro_14 set elsewhere shows within a tick")
    local before = pane.device.refresh_count
    for _ = 1, 10 do drift_update() end
    assert_equal(pane.device.refresh_count - before, 0, arrangement .. ": ten idle ticks repaint nothing")
  end, {{FIRST_BANK, LINE.pages}})
end)

-- grid_core_test.lua:1300 and mutation_test.lua:524 (#410), re-based
test("the faders follow a param set off the grid within a drift tick (#410)", function()
  each_arrangement(function(_, S, pane, arrangement)
    local keys = shown_keys(pane)
    select_grid_voice(3)  -- stopped: nothing of it drifts
    grid_redraw()
    drift_update()  -- the first look
    local id = page_ids(S)[1]
    assert_equal(id, "v3_freq", arrangement)
    local default_key = fader_position(id, keys)
    assert_equal(pane.led(fader_x(pane, default_key), 1), 15, arrangement .. ": v3_freq's default")
    local spec = params:lookup_param(id).controlspec
    params:set(id, spec.minval)
    if default_key ~= 1 then
      assert_equal(pane.led(fader_x(pane, default_key), 1), 15, arrangement .. ": the set alone redraws no grid")
    end
    drift_update()
    assert_equal(pane.led(fader_x(pane, 1), 1), 15, arrangement .. ": the tick moved the fader to the minimum")
    local before = pane.device.refresh_count
    for _ = 1, 10 do drift_update() end
    assert_equal(pane.device.refresh_count - before, 0, arrangement .. ": ten idle ticks repaint nothing")
    -- 256:144: the faders follow a mutation (each draw lands randomly)
    select_grid_voice(1)
    local freq_min = param_range("v1_freq")
    params:set("v1_freq", freq_min)
    params:set("mutation_probability", 1)
    params:set("mutation_amount", 1)
    local freq_key = 1
    for _ = 1, 40 do
      gentle_mutate()
      freq_key = fader_position("v1_freq", keys)
      if freq_key > 1 then break end
    end
    assert_true(freq_key > 1, arrangement .. ": the mutation moved freq off its minimum")
    drift_update()
    assert_equal(pane.led(fader_x(pane, freq_key), 1), 15, arrangement .. ": the freq fader follows the mutation")
  end)
end)

-- Ruling 63, D4: n is the registry's count
test("a type key sets the type at once and lights it; keys past n are dark", function()
  each_arrangement(function(context, S, pane, arrangement)
    local list = S.lib.types.list()
    local n = #list
    local first, last = shown_columns(pane)
    for x = first, last do
      local expected = x <= n and (x == 1 and 15 or 4) or 0
      assert_equal(pane.led(x, LINE.types), expected, arrangement .. ": line 6 key " .. x .. " of " .. n .. " types")
    end
    context.clear_engine_calls()
    pane.tap(2, LINE.types)
    assert_equal(params:get("v1_type"), list[2].index, arrangement .. ": key 2 sets voice 1 to " .. list[2].key)
    assert_equal(S.lib.types.of(1).key, list[2].key, arrangement .. ": at once")
    assert_equal(type_calls(context), "0 " .. (list[2].index - 1), arrangement .. ": one setVoiceType")
    assert_equal(pane.led(2, LINE.types), 15, arrangement .. ": lit")
    assert_equal(pane.led(1, LINE.types), 4, arrangement .. ": the old type dims")
    for x = n + 1, last do
      if x >= first then pane.tap(x, LINE.types) end
    end
    assert_equal(S.lib.types.of(1).key, list[2].key, arrangement .. ": keys past n do nothing")
    assert_equal(type_calls(context), "0 " .. (list[2].index - 1), arrangement .. ": and send nothing")
    -- the type keys act on the grid voice
    if pane.shows(5, LINE.voices) then
      pane.tap(5, LINE.voices)
      pane.tap(1, LINE.types)
      assert_equal(S.lib.types.of(5).key, list[1].key, arrangement .. ": voice 5 picked: key 1 sets its type")
      assert_equal(S.lib.types.of(1).key, list[2].key, arrangement .. ": voice 1 keeps its own")
    end
  end, {{1, LINE.types}, {2, LINE.types}})
end)

test("a type key that shortens the voice's pages clamps S.param_page", function()
  each_arrangement(function(_, S, pane, arrangement)
    local list = S.lib.types.list()
    probe_pages(S, 1, 10)
    pane.tap(10, LINE.pages)
    assert_equal(S.param_page, 10, arrangement .. ": page 10 shown")
    pane.tap(2, LINE.types)
    local count = fader_page_count(1)
    assert_equal(S.lib.types.of(1).key, list[2].key, arrangement .. ": voice 1 is " .. list[2].key)
    assert_true(count < 10, arrangement .. ": with fewer pages (" .. count .. ")")
    assert_equal(S.param_page, count, arrangement .. ": the page is that type's last")
    assert_equal(pane.led(count, LINE.pages), 15, arrangement .. ": and line 5 lights it")
    assert_equal(pane.led(10, LINE.pages), 0, arrangement .. ": page 10 is dark")
  end, {{10, LINE.pages}, {2, LINE.types}})
end)

-- Ruling 63: the later act stands
test("a grid type key during VOICE's settle wins", function()
  each_arrangement(function(context, S, pane, arrangement)
    local list = S.lib.types.list()
    pane.tap(2, LINE.voices)
    show_page("VOICE")
    S.lib.ui_keys.select_voice_by(1)
    assert_equal(S.selected_voice, 2, arrangement .. ": VOICE shows voice 2")
    S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of("v2_type"))
    assert_equal(S.lib.types.of(2).key, list[2].key, arrangement .. ": voice 2 on its own type")
    context.clear_engine_calls()
    enc(3, 1)
    assert_equal(S.lib.types.pending(2), 3, arrangement .. ": a pending choice of " .. list[3].key)
    context.clock.run_for(0.1)
    pane.tap(4, LINE.types)
    context.clock.run_for(0.5)
    assert_equal(params:get("v2_type"), list[4].index, arrangement .. ": the grid's " .. list[4].key .. " stands")
    assert_equal(S.lib.types.pending(2), nil, arrangement .. ": nothing pending")
    assert_equal(type_calls(context), "1 " .. (list[4].index - 1), arrangement .. ": one setVoiceType, the grid's type's")
  end, {{2, LINE.voices}, {4, LINE.types}})
end)

test("a type set on VOICE shows on line 6 within a drift tick", function()
  each_arrangement(function(context, S, pane, arrangement)
    local list = S.lib.types.list()
    drift_update()
    local signature = S.lib.grid_pane.signature()
    show_page("VOICE")
    S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of("v1_type"))
    enc(3, 1); enc(3, 1)  -- the type row moves one type an encoder event
    context.clock.run_for(S.lib.types.TYPES.settle_seconds)
    assert_equal(S.lib.types.of(1).key, list[3].key, arrangement .. ": VOICE set voice 1 to " .. list[3].key)
    drift_update()
    assert_equal(pane.led(3, LINE.types), 15, arrangement .. ": line 6 lights it")
    assert_equal(pane.led(1, LINE.types), 4, arrangement .. ": and dims the old type")
    assert_true(S.lib.grid_pane.signature() ~= signature, arrangement .. ": the page's signature names the type")
  end, {{1, LINE.types}, {3, LINE.types}})
end)

-- Unmentioned case: the source action clamps S.param_page
test("a source change that shortens the voice's pages shows its last page", function()
  each_arrangement(function(_, S, pane, arrangement)
    params:set("v1_source", 2)
    local buffer_pages = fader_page_count(1)
    if not pane.shows(buffer_pages, LINE.pages) then return end
    pane.tap(buffer_pages, LINE.pages)
    assert_equal(S.param_page, buffer_pages, arrangement .. ": a buffer voice's last page shown")
    params:set("v1_source", 10)
    local input_pages = fader_page_count(1)
    assert_true(input_pages < buffer_pages, arrangement .. ": an input voice has fewer pages")
    assert_equal(S.param_page, input_pages, arrangement .. ": the page clamped to the input voice's last")
    assert_equal(pane.led(input_pages, LINE.pages), 15, arrangement .. ": line 5 lights it")
    assert_equal(pane.led(buffer_pages, LINE.pages), 0, arrangement .. ": the gone page dark")
    local keys = shown_keys(pane)
    local shown = page_ids(S)
    pane.tap(fader_x(pane, keys), 1)
    assert_equal(fader_position(shown[1], keys), keys, arrangement .. ": line 1 is the input voice's page's fader")
    params:set("v1_source", 1)
  end)
end)

-- The draw path reads fader_position outside the faders containment, so
-- faders(pane) names only params that exist
test("a page with fewer than four faders and an empty macro slot draw dark and raise nothing", function()
  each_arrangement(function(context, S, pane, arrangement)
    local keys = shown_keys(pane)
    probe_pages(S, 1, 9, 0)
    local ids = fader_param_ids(1)
    local on_last = (#ids - 1) % FADER_LINES + 1
    if on_last == FADER_LINES then
      probe_pages(S, 1, 10, 1)
      ids = fader_param_ids(1)
      on_last = (#ids - 1) % FADER_LINES + 1
    end
    local count = fader_page_count(1)
    pane.tap(count, LINE.pages)
    assert_true(on_last < FADER_LINES, arrangement .. ": the last page has " .. on_last .. " faders")
    local record = S.registry.grid_pages[S.constants.GRID_PAGES.faders]
    local state = {}
    local probe_pane = {width = 16, offset = 0, state = function() return state end}
    assert_equal(#record.faders(probe_pane), on_last, arrangement .. ": faders(pane) lists only those")
    for line = on_last + 1, FADER_LINES do
      assert_equal(line_levels(pane, line):gsub("[0 ]", ""), "", arrangement .. ": line " .. line .. " dark")
      pane.tap(fader_x(pane, keys), line)
    end
    assert_equal(S.param_page, count, arrangement .. ": a dead line's key does nothing")
    -- a macro list with a hole and an id that is no param
    S.lib.grid_faders.shown_macro_ids = function() return {"macro_1", nil, "macro_none", "macro_4"} end
    pane.tap(FIRST_BANK, LINE.pages)
    local lines = {}
    state.macros = true
    for _, line in ipairs(record.faders(probe_pane)) do lines[#lines + 1] = line.line .. ":" .. line.id end
    assert_equal(table.concat(lines, " "), "1:macro_1 4:macro_4", arrangement .. ": the empty slots are left out")
    for _, line in ipairs({2, 3}) do
      assert_equal(line_levels(pane, line):gsub("[0 ]", ""), "", arrangement .. ": macro line " .. line .. " dark")
      pane.tap(fader_x(pane, keys), line)
    end
    assert_equal(pane.led(fader_x(pane, 1), 1), 15, arrangement .. ": macro_1's line drawn")
    drift_update()
    h.claim_script_errors(context, 0)
  end, {{FIRST_BANK, LINE.pages}, {10, LINE.pages}})
end)

-- The 64's halves (design §10.4): left p1-p8, types 1-8 and the voices;
-- right p9-p10, the banks and types 9-12; the faders across eight keys on
-- both. The type keys are checked with the registry's count and again
-- with a list of twelve (the real types, padded with probes in the test's
-- own S while fewer are registered), so it holds before and after the
-- five type packages
test("the 64's halves: left p1-p8 and types 1-8, right p9-p10, the banks and types 9-12, faders across eight keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = faders_pane(context, "64 left")
  local real_list = S.lib.types.list
  probe_pages(S, 1, 10, 3)  -- page 10 with four faders
  local function check_types(half, n)
    local first = half == 1 and 1 or 9
    for x = first, first + 7 do
      local expected = x <= n and (x == 1 and 15 or 4) or 0
      assert_equal(pane.led(x, LINE.types), expected, "half " .. half .. ": type key " .. x .. " of " .. n)
    end
  end
  -- left
  assert_equal(pane.led(1, LINE.pages), 15, "left: p1 shown")
  for x = 2, 8 do assert_equal(pane.led(x, LINE.pages), 4, "left: p" .. x) end
  for x = 1, 7 do assert_equal(pane.led(x, LINE.voices), x == 1 and 15 or 4, "left: V" .. x) end
  assert_equal(pane.led(8, LINE.voices), 0, "left: line 7 key 8 dark")
  check_types(1, #real_list())
  pane.tap(8, 1)
  assert_equal(fader_position(page_ids(S)[1], 8), 8, "left: key 8 of line 1 sets the top of an eight-key fader")
  assert_equal(pane.led(8, 1), 15, "left: lit")
  assert_equal(pane.led(7, 1), 8, "left: the bar")
  pane.tap(1, 2)
  assert_equal(fader_position(page_ids(S)[2], 8), 1, "left: key 1 its bottom")
  -- right
  pane.show(S.constants.GRID_PAGES.faders, 1, 2)
  for x = 9, 10 do assert_equal(pane.led(x, LINE.pages), 4, "right: p" .. x) end
  assert_equal(pane.led(11, LINE.pages), 0, "right: key 11 dark")
  for bank = 1, S.lib.macros.MACROS.banks do
    assert_equal(pane.led(FIRST_BANK + bank - 1, LINE.pages), 2, "right: bank " .. bank)
  end
  assert_equal(pane.led(16, LINE.pages), 0, "right: key 16 dark")
  for x = 9, 16 do assert_equal(pane.led(x, LINE.voices), 0, "right: line 7 key " .. x .. " dark") end
  check_types(2, #real_list())
  pane.tap(10, LINE.pages)
  assert_equal(S.param_page, 10, "right: p10 shows page 10")
  assert_equal(pane.led(10, LINE.pages), 15, "right: lit")
  pane.tap(16, 3)
  assert_equal(fader_position(page_ids(S)[3], 8), 8, "right: key 16 of line 3 sets the top of an eight-key fader")
  assert_equal(pane.led(16, 3), 15, "right: lit")
  assert_equal(pane.led(15, 3), 8, "right: the bar")
  pane.tap(FIRST_BANK + 1, LINE.pages)
  assert_equal(S.lib.macros.bank(), 2, "right: key 13 shows bank 2")
  pane.tap(9, 1)
  assert_near(params:get("macro_5"), 0, 1e-9, "right: key 9 of line 1 sets macro_5 to its bottom")
  pane.tap(16, 1)
  assert_near(params:get("macro_5"), 1, 1e-9, "right: key 16 its top")
  -- twelve types
  S.lib.types.list = function()
    local list = real_list()
    for index = #list + 1, 12 do list[index] = {key = "probe" .. index, index = index} end
    return list
  end
  grid_redraw()
  check_types(2, 12)
  pane.show(S.constants.GRID_PAGES.faders, 1, 1)
  check_types(1, 12)
  S.lib.types.list = real_list
end)

end
