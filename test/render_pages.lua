-- test/render_pages.lua
-- Page renders for reviewing the screen by eye, run on demand (never part
-- of `lua test/run.lua`). From the repo root:
--
--   lua test/render_pages.lua /tmp/strata-renders
--   python3 test/render_pages.py /tmp/strata-renders --font ~/src/norns/resources/norns.ttf
--
-- The first command loads the script through the norns stubs (as the unit
-- tests do), draws every page in each of its states and writes one
-- <page>-<state>.json per state into the folder: the page and state names
-- and every text (x, y, text, align, level), rect (x, y, w, h, level,
-- filled) and line (x1, y1, x2, y2, level, filled) the draw made. The
-- second turns each JSON file into a 128x64 PNG, scaled 4x (see its own
-- comment). The states are STATES below, then each page record's
-- layout_states. As a module (test/unit/ui_layout_test.lua) it returns
-- { render_page_states = ..., STATES = ..., encode_json = ... }.

local test_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "test"
package.path = test_dir .. "/?.lua;" .. package.path

local h = require("helpers")
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page = h.show_page

local M = {}

-- The states every review looks at; each is drawn on a fresh load of the
-- script, after startup, with its page shown. `setup(context)` runs after
-- the page is shown
M.STATES = {
  { page = "MAIN", name = "synth" },
  { page = "MAIN", name = "buffer", setup = function(context)
    params:set("v1_source", 3)                      -- voice 1 reads buf 2
    load_buffer(2, "/tmp/strata-render-pad.wav")
    context.polls.fire("bufferState", 106)          -- buf 2 holds 6 s
  end },
  { page = "MAIN", name = "input", setup = function() params:set("v1_source", 10) end },
  { page = "MAIN", name = "alt", setup = function() key(1, 1) end },
  { page = "MAIN", name = "header-flash", setup = function() header_flash("tempo 130") end },
  { page = "VOICE", name = "default" },
  { page = "SEQ", name = "playing", setup = function(context)
    for step = 1, 16, 4 do toggle_pattern_step(1, step) end
    toggle_pattern_step(2, 3)
    pattern_toggle()
    context.clock.run_for(0.5)
  end },
  { page = "FX", name = "default" },
  { page = "LFO", name = "default", setup = function(context)
    params:set("lfo_1", 2)
    context.clock.run_for(0.5)
  end },
  { page = "BUFFER", name = "default", setup = function(context)
    load_buffer(1, "/tmp/strata-render-a-long-file-name.wav")
    context.polls.fire("bufferState", 4)            -- buf 1 holds 4 s
  end },
  { page = "BUFFER", name = "recording", setup = function()
    params:set("v1_source", 2)                      -- voice 1 reads buf 1
    record_buffer(1)
  end },
  { page = "SCENES", name = "default", setup = function() capture_scene(1); capture_scene(3) end },
  { page = "SETUP", name = "default", setup = function(context)
    context.grid.plug(1, 16, 8)
    context.arc.plug(1)
  end },
}

-- A file-name part: lower case, runs of anything but letters and digits
-- as one "-"
local function slug(text)
  return (tostring(text):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""))
end

-- JSON text for plain data: tables with keys 1..n are arrays, others
-- objects (keys sorted, so a file is the same on every run)
local function encode_json(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return tostring(value) end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return "null" end
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then return string.format("%d", value) end
    return string.format("%.17g", value)
  end
  if kind == "string" then
    return '"' .. value:gsub('[%c"\\]', function(char)
      local named = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
      return named[char] or string.format("\\u%04x", char:byte())
    end) .. '"'
  end
  if kind == "table" then
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    if count == #value then
      local items = {}
      for index = 1, #value do items[index] = encode_json(value[index]) end
      return "[" .. table.concat(items, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do table.insert(keys, tostring(key)) end
    table.sort(keys)
    local items = {}
    for _, key in ipairs(keys) do table.insert(items, encode_json(key) .. ":" .. encode_json(value[key])) end
    return "{" .. table.concat(items, ",") .. "}"
  end
  error("cannot encode a " .. kind .. " as JSON")
end
M.encode_json = encode_json

-- What the screen stub recorded for the last draw
local function drawing(context, page, state)
  local screen = context.screen
  local texts, rects, lines = {}, {}, {}
  for _, entry in ipairs(screen.texts) do
    table.insert(texts, { x = entry.x, y = entry.y, text = entry.text, align = entry.align, level = entry.level })
  end
  for _, rect in ipairs(screen.rects) do
    table.insert(rects, { x = rect.x, y = rect.y, w = rect.w, h = rect.h, level = rect.level, filled = rect.filled })
  end
  for _, line in ipairs(screen.lines) do
    table.insert(lines, { x1 = line.x1, y1 = line.y1, x2 = line.x2, y2 = line.y2, level = line.level,
      filled = line.filled })
  end
  return { page = page, state = state, width = 128, height = 64, texts = texts, rects = rects, lines = lines }
end

-- A fresh script, started, on `page` (a UI_PAGES name)
local function fresh_page(page)
  local context = load_strata(); finish_startup(context)
  show_page(page)
  return context
end

local function write_state(out_dir, context, page, state_name)
  redraw()
  local name = slug(page) .. "-" .. slug(state_name) .. ".json"
  local file = assert(io.open(out_dir .. "/" .. name, "w"))
  file:write(encode_json(drawing(context, page, state_name)), "\n")
  file:close()
  return name
end

-- Draw every state and write <page>-<state>.json into out_dir (created if
-- missing). Returns the file names written, in order
function M.render_page_states(out_dir)
  os.execute("mkdir -p '" .. out_dir .. "'")
  local written = {}
  for _, state in ipairs(M.STATES) do
    local context = fresh_page(state.page)
    if state.setup then state.setup(context) end
    table.insert(written, write_state(out_dir, context, state.page, state.name))
    cleanup()
  end
  -- each page record's own states (the layout tests draw them too)
  load_strata()
  local pages = local_value("S").registry.pages
  local counts = {}
  for index, record in ipairs(pages) do counts[index] = { name = record.name, count = #(record.layout_states or {}) } end
  cleanup()
  for index, entry in ipairs(counts) do
    for state_index = 1, entry.count do
      local context = fresh_page(entry.name)
      local state = local_value("S").registry.pages[index].layout_states[state_index]
      if state.setup then state.setup(context) end
      table.insert(written, write_state(out_dir, context, entry.name, state.name or ("state " .. state_index)))
      cleanup()
    end
  end
  return written
end

-- Run as a script: lua test/render_pages.lua <out_dir>
if arg and arg[0] and arg[0]:match("render_pages%.lua$") then
  local out_dir = arg[1]
  if not out_dir then
    h.real_print("usage: lua test/render_pages.lua <out_dir>")
    os.exit(1)
  end
  local ok, written = xpcall(M.render_page_states, debug.traceback, out_dir)
  print = h.real_print
  os.execute("rm -rf '" .. h.data_root .. "'")
  if not ok then
    h.real_print(written)
    os.exit(1)
  end
  h.real_print(string.format("%d page states written to %s", #written, out_dir))
end

return M
