-- test/unit/pages_io_test.lua
-- The IO page (lib/pages/io.lua, 3.6 design §11): the tenth page, its
-- sections in IO_PAGE.sections' order, the five row kinds, its keys, a
-- section that raises, and the page with no section.
-- Run alone: lua test/run.lua pages_io

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, assert_screen_layout, screen_shows, hint_text = h.show_page, h.assert_screen_layout,
  h.screen_shows, h.hint_text
local tap, next_frame = h.tap, h.next_frame

-- The shell's tests register their own sections: the targets core's voice
-- section (lib/io/targets.lua, 3.6's 1a) is taken out first
local function without_registered_sections(S)
  for index = #S.registry.io_sections, 1, -1 do S.registry.io_sections[index] = nil end
end

local function loaded()
  local context = load_strata(); finish_startup(context)
  without_registered_sections(local_value("S"))
  return context, local_value("S")
end

-- A section of n param rows on SETUP's params (any will do), named name
local function plain_section(S, name, n, extra)
  local record = { name = name, title = name, rows = function()
    local rows = {}
    for index = 1, n do
      rows[index] = { label = name .. " " .. index, kind = "param", param_id = "mutation_rate", format = "%.1f s" }
    end
    return rows
  end }
  for field, value in pairs(extra or {}) do record[field] = value end
  S.register_io_section(record)
end

local function title_rows(S)
  local titles = {}
  for _, row in ipairs(S.lib.pages_io.rows()) do
    if row.kind == "title" then titles[#titles + 1] = row.section end
  end
  return titles
end

local function current_row(S)
  return S.lib.pages_io.rows()[S.io_cursor]
end

local function text_entry(context, text)
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == text then return entry end
  end
end

test("IO is the tenth page and moves no other", function()
  local _, S = loaded()
  local C = S.constants
  assert_equal(C.UI_PAGES[10], "IO")
  assert_equal(C.NUM_UI_PAGES, 10)
  assert_equal(C.UI_PAGES.index.SETUP, 9, "SETUP stays the ninth")
  assert_equal(C.UI_PAGES.index.IO, 10)
  assert_equal(S.registry.pages[10].name, "IO")
  enc(1, 40)
  assert_equal(S.ui_page, 10, "E1 turned far stops on IO")
end)

test("sections show in the page's order whatever order they register in", function()
  local _, S = loaded()
  plain_section(S, "tape", 1); plain_section(S, "zzz", 1); plain_section(S, "voice", 1)
  assert_equal(table.concat(title_rows(S), " "), "voice tape zzz")
  assert_equal(S.lib.pages_io.IO_PAGE.sections[1], "voice")
  assert_equal(table.concat(S.lib.pages_io.IO_PAGE.sections, " "),
    "voice midi crow ii wtape controllers remote osc tape")
end)

test("a title row shows its section's status at the right", function()
  local context, S = loaded()
  plain_section(S, "crow", 2, { title = function() return "crow out" end, status = function() return "[--]" end })
  show_page("IO"); redraw()
  local status = text_entry(context, "[--]")
  assert_true(status ~= nil, "the status is drawn")
  assert_equal(status.align, "right"); assert_equal(status.x, 124, "ending at value_right")
  assert_equal(status.y, text_entry(context, "crow out").y, "on the title's row")
  assert_equal(text_entry(context, "crow out").x, 0, "the title at the left")
  assert_screen_layout(context, "IO with a status")
end)

test("E2 moves over the selectable rows and K2 jumps a section", function()
  local context, S = loaded()
  S.register_io_section({ name = "voice", title = "voice", rows = function()
    return { { label = "a", kind = "param", param_id = "mutation_rate" },
      { label = "note", kind = "status", text = "a note" },
      { label = "b", kind = "param", param_id = "mutation_rate" },
      { label = "c", kind = "param", param_id = "mutation_rate" } }
  end })
  plain_section(S, "midi", 2)
  plain_section(S, "crow", 1)
  show_page("IO"); redraw()
  assert_equal(current_row(S).label, "a", "the cursor starts on the first row")
  enc(2, 1); assert_equal(current_row(S).label, "b", "over the status row")
  enc(2, 1); assert_equal(current_row(S).label, "c")
  enc(2, 1); assert_equal(current_row(S).label, "midi 1", "over the next title")
  enc(2, -2); assert_equal(current_row(S).label, "b")
  tap(2); assert_equal(current_row(S).label, "midi 1", "K2: the next section's first row")
  enc(2, 1); tap(2); assert_equal(current_row(S).label, "crow 1")
  tap(2); assert_equal(current_row(S).label, "a", "from the last section: the first")
  assert_screen_layout(context, "IO three sections")
end)

test("E3 edits a param row and steps a rig row; K3 runs an action and opens a detail", function()
  local context, S = loaded()
  local runs = 0
  S.register_io_section({ name = "voice", title = "voice", rows = function()
    return {
      { label = "note off", kind = "param", param_id = "midi_note_off" },
      { label = "follow", kind = "param", param_id = "seq_follow_transport", binary = { [0] = "off", [1] = "on" } },
      { label = "e16 port", kind = "rig", key = "e16_port" },
      { label = "rescan", kind = "action", hint = "scan", run = function() runs = runs + 1 end,
        text = function() return "done" end },
      { label = "cc 1", kind = "detail", text = function() return "ch 3" end, fields = {
        { label = "port", kind = "rig", key = "faders_port" },
        { label = "mode", kind = "param", param_id = "midi_note_off" } } },
    }
  end })
  show_page("IO")
  local rig = S.lib.io_rig
  enc(3, 1); assert_equal(params:get("midi_note_off"), 2, "a param row edits its param")
  enc(2, 1); enc(3, 1); assert_equal(params:get("seq_follow_transport"), 1, "a binary row sets 1")
  enc(3, -1); assert_equal(params:get("seq_follow_transport"), 0, "and 0")
  enc(2, 1); enc(3, 1); assert_equal(rig.get("e16_port"), 1, "a rig row steps its setting")
  redraw(); assert_equal(hint_text(context), "E2:row E3:value K2:section")
  key(1, 1); enc(3, 2); key(1, 0); assert_equal(rig.get("e16_port"), 3, "ALT+E3 steps it too")
  os.execute("mkdir -p '" .. context.data_dir .. "strata/io.data.part/inside'")
  enc(3, 1); next_frame(context)
  assert_equal(rig.get("e16_port"), 3, "not set")
  assert_equal(hint_text(context), "setting not saved", "the hint row says so")
  h.remove_tree(context.data_dir .. "strata/io.data.part")
  S.lib.ui_flash.start("hints", nil)  -- the flash ends
  enc(2, 1); redraw()
  assert_equal(hint_text(context), "E2:row K2:section K3:scan", "an action's hint")
  assert_true(screen_shows(context, "done"), "what it last did")
  enc(3, 1); assert_equal(runs, 0, "E3 runs nothing")
  tap(3); assert_equal(runs, 1, "K3 runs it once")
  enc(2, 1); redraw()
  assert_equal(hint_text(context), "E2:row K2:section K3:open")
  assert_true(screen_shows(context, "ch 3"), "the detail's text")
  tap(3)
  assert_true(S.lib.ui_modal.top() ~= nil, "K3 opens the detail")
  redraw()
  assert_true(screen_shows(context, "port") and screen_shows(context, "mode"), "its fields show")
  assert_screen_layout(context, "IO detail open")
  enc(3, 2); assert_equal(rig.get("faders_port"), 2, "E3 edits the field under its cursor")
  enc(2, 1); enc(3, 1); assert_equal(params:get("midi_note_off"), 3, "the next field")
  tap(2)
  assert_equal(S.lib.ui_modal.top(), nil, "K2 closes it")
  redraw()
  assert_equal(context.screen.texts[1].text, "IO", "the page is back")
  assert_equal(current_row(S).label, "cc 1", "on the detail's row")
end)

test("ALT+E2 selects the voice", function()
  local _, S = loaded()
  plain_section(S, "voice", 2)
  show_page("IO")
  local calls = 0
  local real = S.lib.ui_keys.select_voice_by
  S.lib.ui_keys.select_voice_by = function(d) calls = calls + 1; return real(d) end
  S.selected_voice = 1
  key(1, 1); enc(2, 1); key(1, 0)
  S.lib.ui_keys.select_voice_by = real
  assert_equal(S.selected_voice, 2, "voice 2")
  assert_equal(calls, 1, "through select_voice_by")
  assert_equal(current_row(S).label, "voice 1", "the cursor stays")
end)

test("a section that raises is contained", function()
  local context, S = loaded()
  plain_section(S, "voice", 1)
  S.register_io_section({ name = "crow", title = "crow", rows = function() error("probe rows") end })
  S.register_io_section({ name = "ii", title = "ii", rows = function() return {} end,
    status = function() error("probe status") end })
  show_page("IO")
  redraw(); redraw()
  local errors = 0
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == "error" then errors = errors + 1 end
  end
  assert_equal(errors, 2, "both titles show error")
  assert_true(screen_shows(context, "crow") and screen_shows(context, "ii"), "with their titles")
  assert_true(screen_shows(context, "voice 1"), "the other section draws")
  -- one console line each, not one per draw
  local lines = h.claim_script_errors(context, 2, "strata: io section ")
  assert_true(lines[1]:find("probe rows", 1, true) ~= nil, lines[1])
  assert_true(lines[2]:find("probe status", 1, true) ~= nil, lines[2])
  assert_screen_layout(context, "IO with failing sections")
end)

test("with no section the page says so", function()
  local context, S = loaded()
  show_page("IO"); redraw()
  assert_true(screen_shows(context, "no sections"), "no sections")
  assert_equal(#S.lib.pages_io.rows(), 0)
  enc(2, 1); enc(3, 1); tap(2); tap(3)
  assert_screen_layout(context, "IO empty")
end)

test("show_section puts its section at the top; the layout states cover each section", function()
  local context, S = loaded()
  plain_section(S, "voice", 8); plain_section(S, "osc", 3); plain_section(S, "tape", 6)  -- room below osc
  show_page("IO")
  assert_equal(S.lib.pages_io.show_section("osc"), true)
  assert_equal(current_row(S).label, "osc 1")
  redraw()
  local first = context.screen.texts[2]  -- after the header's title
  assert_equal(first.text, "osc", "the section's title at the top of the list")
  assert_equal(S.lib.pages_io.show_section("nope"), false, "no such section")
  -- a section's own layout states join the page's, after "<name> at the top"
  local ran = 0
  local load_context = load_strata({ before_init = function()
    local script = local_value("S")
    without_registered_sections(script)
    script.register_io_section({ name = "midi", title = "midi", rows = function()
      return { { label = "x", kind = "param", param_id = "mutation_rate" } }
    end, layout_states = { { name = "probe", setup = function() ran = ran + 1 end } } })
  end })
  finish_startup(load_context)
  local states = local_value("S").registry.pages[10].layout_states
  assert_equal(#states, 3, "the page's own, then two of the section's")
  assert_equal(states[1].name, "ALT held")
  assert_equal(states[2].name, "midi at the top")
  assert_equal(states[3].name, "midi: probe")
  show_page("IO")
  states[3].setup(load_context)
  assert_equal(ran, 1, "the section's own setup ran")
  assert_equal(local_value("S").lib.pages_io.rows()[local_value("S").io_cursor].label, "x", "after show_section")
end)

-- A row that comes or goes above the cursor (a device plugged in, in a later
-- package) must not move E3 onto another row: the cursor follows its row
test("the cursor stays on its row when rows above it come and go", function()
  local context, S = loaded()
  local plugged = false
  S.register_io_section({ name = "voice", title = "voice", rows = function()
    local rows = {}
    if plugged then rows[#rows + 1] = { label = "new", kind = "param", param_id = "mutation_amount" } end
    rows[#rows + 1] = { label = "rate", kind = "param", param_id = "mutation_rate" }
    rows[#rows + 1] = { label = "prob", kind = "param", param_id = "mutation_probability" }
    rows[#rows + 1] = { label = "port", kind = "rig", key = "e16_port" }
    return rows
  end })
  show_page("IO")
  enc(2, 1); redraw()
  assert_equal(current_row(S).label, "prob")
  local rate, prob, amount = params:get("mutation_rate"), params:get("mutation_probability"),
    params:get("mutation_amount")
  plugged = true
  redraw()
  enc(3, 1)
  assert_true(params:get("mutation_probability") > prob, "E3 still edits prob")
  assert_equal(params:get("mutation_rate"), rate, "not the row now at its old place")
  assert_equal(params:get("mutation_amount"), amount, "nor the new row")
  assert_equal(current_row(S).label, "prob", "S.io_cursor follows the row")
  assert_screen_layout(context, "IO after a row came above the cursor")
  -- the row gone: the nearest selectable row at or before its old place
  plugged = false
  enc(2, 1); assert_equal(current_row(S).label, "port")
  S.register_io_section({ name = "zzz", title = "zzz", rows = function() return {} end })
  local real_rows = S.registry.io_sections[1].rows
  S.registry.io_sections[1].rows = function()
    local rows = real_rows()
    table.remove(rows)  -- port goes
    return rows
  end
  redraw()
  assert_equal(current_row(S).label, "prob", "the nearest row before it")
end)

-- design §11: each section at the top with and without its device, and a
-- section without its device may show only status rows
test("show_section puts a section of status rows only at the top", function()
  local context, S = loaded()
  plain_section(S, "voice", 8)
  S.register_io_section({ name = "crow", title = "crow", status = function() return "[--]" end, rows = function()
    return { { kind = "status", text = "no crow connected" }, { kind = "status", text = "plug one in" } }
  end })
  plain_section(S, "tape", 6)
  show_page("IO")
  enc(2, 3)
  assert_equal(S.lib.pages_io.show_section("crow"), true, "a registered section")
  assert_equal(current_row(S).label, "voice 8", "the cursor on the nearest selectable row, before it")
  redraw()
  assert_equal(text_entry(context, "crow").y, S.lib.pages_io.IO_PAGE.first_y, "its title at the top of the list")
  assert_screen_layout(context, "IO crow without its device at the top")
  -- the cursor's row is out of view: E3 brings it back and edits nothing
  assert_equal(hint_text(context), "E2:row E3:back")
  local rate = params:get("mutation_rate")
  enc(3, 1); redraw()
  assert_equal(params:get("mutation_rate"), rate, "E3 edits nothing")
  assert_true(screen_shows(context, "voice 8"), "the cursor's row is back in view")
  enc(3, 1)
  assert_true(params:get("mutation_rate") > rate, "the next E3 edits it")
  -- a section first in the list: the nearest selectable row is after it
  S.lib.pages_io.show_section("voice")
  assert_equal(S.lib.pages_io.show_section("crow"), true)
  -- the layout state draws it too
  local load_context = load_strata({ before_init = function()
    local script = local_value("S")
    without_registered_sections(script)
    script.register_io_section({ name = "crow", title = "crow", rows = function()
      return { { kind = "status", text = "no crow connected" } }
    end })
  end })
  finish_startup(load_context)
  show_page("IO")
  local state = local_value("S").registry.pages[10].layout_states[2]
  assert_equal(state.name, "crow at the top")
  state.setup(load_context)
  redraw()
  assert_equal(load_context.screen.texts[2].text, "crow", "alone on the page, at the top")
  assert_screen_layout(load_context, "IO a status-only section alone")
  enc(2, 1); enc(3, 1); tap(2); tap(3)  -- nothing to move to or edit
end)

-- A row is known by its own identity where it has one (its param_id, its
-- rig key, or an id), so a row of the same label coming above the cursor
-- does not move it
test("rows of the same label keep the cursor on its own row", function()
  local context, S = loaded()
  local plugged = false
  local ran = {}
  S.register_io_section({ name = "voice", title = "voice", rows = function()
    local rows = {}
    if plugged then
      rows[#rows + 1] = { label = "level", kind = "param", param_id = "mutation_amount" }
      rows[#rows + 1] = { label = "go", kind = "action", hint = "run", id = "go new", run = function() ran.new = true end }
    end
    rows[#rows + 1] = { label = "level", kind = "param", param_id = "mutation_rate" }
    rows[#rows + 1] = { label = "level", kind = "param", param_id = "mutation_probability" }
    rows[#rows + 1] = { label = "go", kind = "action", hint = "run", id = "go old", run = function() ran.old = true end }
    return rows
  end })
  show_page("IO")
  enc(2, 1); redraw()
  assert_equal(current_row(S).param_id, "mutation_probability")
  local rate, prob, amount = params:get("mutation_rate"), params:get("mutation_probability"),
    params:get("mutation_amount")
  plugged = true
  redraw()
  enc(3, 1)
  assert_true(params:get("mutation_probability") > prob, "E3 still edits the same param")
  assert_equal(params:get("mutation_rate"), rate, "not the row of the same label now at its place")
  assert_equal(params:get("mutation_amount"), amount, "nor the new one")
  -- an action with an id
  plugged = false
  enc(2, 1); redraw()
  assert_equal(current_row(S).id, "go old")
  plugged = true
  redraw(); tap(3)
  assert_true(ran.old and not ran.new, "K3 runs the action the cursor was on")
  -- an id is a string or a number
  S.register_io_section({ name = "zzz", title = "zzz", rows = function()
    return { { label = "x", kind = "action", hint = "run", run = function() end, id = {} } }
  end })
  redraw()
  local rows = S.lib.pages_io.rows()
  assert_equal(rows[#rows].section, "zzz"); assert_equal(rows[#rows].status, "error", "a table id: the section errs")
  h.claim_script_errors(context, 1, "strata: io section zzz rows ", "an id is a string or a number")
end)

-- When the cursor's row is gone and E3 or K3 comes before the next draw, it
-- only puts the cursor on the row in its place, which was never shown lit
test("E3 and K3 on a row that has gone only move the cursor", function()
  local context, S = loaded()
  local gone = nil  -- the label of the row taken away
  local runs = 0
  S.register_io_section({ name = "voice", title = "voice", rows = function()
    local rows = {}
    for _, row in ipairs({
      { label = "rate", kind = "param", param_id = "mutation_rate" },
      { label = "prob", kind = "param", param_id = "mutation_probability" },
      { label = "amount", kind = "param", param_id = "mutation_amount" },
      { label = "act", kind = "action", hint = "run", run = function() runs = runs + 1 end },
      { label = "act 2", kind = "action", hint = "run", run = function() end },
    }) do
      if row.label ~= gone then rows[#rows + 1] = row end
    end
    return rows
  end })
  show_page("IO")
  enc(2, 1); redraw()
  assert_equal(current_row(S).label, "prob")
  local amount = params:get("mutation_amount")
  gone = "prob"
  local asked = 0
  local real_request = request_redraw
  request_redraw = function() asked = asked + 1; return real_request() end
  enc(3, 1)
  request_redraw = real_request
  assert_equal(current_row(S).label, "amount", "the cursor on the row in its place")
  assert_equal(params:get("mutation_amount"), amount, "E3 edited nothing")
  assert_true(asked > 0, "a redraw is asked for")
  enc(3, 1)
  assert_equal(params:get("mutation_amount"), amount, "nor a second E3 before that draw")
  redraw()
  enc(3, 1)
  assert_true(params:get("mutation_amount") > amount, "the next E3, on the row now shown, edits it")
  -- K3 the same: the cursor's row goes, the action in its place does not run
  gone = nil
  redraw(); enc(2, 2); redraw()
  assert_equal(current_row(S).label, "act 2")
  gone = "act 2"
  tap(3)
  assert_equal(runs, 0, "K3 ran nothing")
  assert_equal(current_row(S).label, "act", "the cursor on the row in its place")
  redraw()
  tap(3)
  assert_equal(runs, 1, "the next K3, on the row now shown, runs it")
  redraw()
  assert_screen_layout(context, "IO after the cursor's row went")
end)

test("ALT+E3 on a rig row that has gone only moves the cursor", function()
  local context, S = loaded()
  local gone = false
  S.register_io_section({ name = "remote", title = "remote", rows = function()
    local rows = { { label = "grid port", kind = "rig", key = "remote_grid_port" } }
    if not gone then rows[#rows + 1] = { label = "arc port", kind = "rig", key = "remote_arc_port" } end
    return rows
  end })
  show_page("IO")
  enc(2, 1); redraw()
  assert_equal(current_row(S).key, "remote_arc_port")
  local rig = S.lib.io_rig
  gone = true
  local asked = 0
  local real_request = request_redraw
  request_redraw = function() asked = asked + 1; return real_request() end
  key(1, 1); enc(3, 1); key(1, 0)
  request_redraw = real_request
  assert_equal(current_row(S).key, "remote_grid_port", "the cursor on the row in its place")
  assert_equal(rig.get("remote_grid_port"), 0, "ALT+E3 stepped nothing")
  assert_true(asked > 0, "a redraw is asked for")
  redraw()
  key(1, 1); enc(3, 1); key(1, 0)
  assert_equal(rig.get("remote_grid_port"), 1, "after the draw ALT+E3 steps it")
  assert_screen_layout(context, "IO after a rig row went")
end)

test("leaving IO ends a pinned view", function()
  local context, S = loaded()
  plain_section(S, "voice", 8)
  S.register_io_section({ name = "crow", title = "crow", rows = function()
    return { { kind = "status", text = "no crow connected" } }
  end })
  plain_section(S, "tape", 6)
  show_page("IO")
  S.lib.pages_io.show_section("crow"); redraw()
  assert_equal(hint_text(context), "E2:row E3:back")
  show_page("SETUP"); show_page("IO")
  assert_equal(hint_text(context), "E2:row E3:value K2:section", "the view is back on the cursor's row")
  assert_true(screen_shows(context, current_row(S).label), "which shows")
end)

end
