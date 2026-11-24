-- test/unit/ui_walk_test.lua
-- The UI walk (3.9's package 3a, design section 6): seeded random
-- sequences of the screen's controls as norns delivers them (K1, K2 and
-- K3 down and up, E1 to E3), the norns menu opening and closing, each
-- modal owner opened from its page and closed, the grid's step editor
-- pushed over whatever is up and popped, SCENES' name entry finished and
-- canceled, BUFFER's file selector opened and canceled, and time passing.
-- Every invariant is checked after each op, and so are the walk's own
-- rules: a key that is physically up has no press mark anywhere, and a
-- press mark names the page shown. The end check (the controller's
-- ruling on 3a, docs/notes/lua/ui-core.md, The UI walk): every key up
-- and every owner closed, the states that animate by right quieted, then
-- the press state is a fresh script's, nothing animates, and each page's
-- drawn hint row is its own hints, the same with the press marks cleared
-- Run alone: lua test/run.lua ui_walk

return function(h)
local local_value, assert_true = h.local_value, h.assert_true

local WALK = {
  -- a key held this long on a grid step opens the step editor
  -- (GRID_HOLD.step_edit_seconds, 0.3 s)
  editor_hold_seconds = 0.35,
  -- the quiet before the end check: flashes, the scenes prompt and the
  -- detent holds lapse (each lasts at most a few seconds)
  quiet_seconds = 3,
  close_tries = 12,
  last_field = 99,  -- BUFFER's field cursor clamps it to its last field, slices
  -- the owners each opened from its page by K3 on its row (the step
  -- editor is the grid's)
  owners = {"zones", "picker", "scale", "factory", "slice", "io_detail"},
}

-- The page index of a page's name
local function page_index(S, name) return S.constants.UI_PAGES.index[name] end

---------------------------------------------------------------------------
-- norns' routing of the hardware (lua/core/menu.lua): while the menu is
-- open its keys and encoders are the menu's; in play mode they go to
-- _menu.key and norns.encoders.callback, which set_mode(false) copies from
-- the globals key and enc (so a name entry's own key once it took them).
-- While BUFFER's file selector is open they go nowhere: norns' fs.enter
-- puts its own key and enc in the globals, which the stub's does not
-- (#985), so the walk drops them as the selector would take them
---------------------------------------------------------------------------

local function selector_open(state) return state.S.BUFFER_PAGE.file_selector_open end

local function where_input_goes(state)
  if state.context.menu.mode then return "menu" end
  if selector_open(state) then return "selector" end  -- #985
  return "script"
end

local function hardware_key(state, n, z)
  local S = state.S
  local goes = where_input_goes(state)
  state.down[n] = z == 1 or nil
  if z == 1 then
    state.press_went[n] = goes
    -- what the press went to: the top owner, or the bare page
    state.press_top[n] = goes == "script" and (S.lib.ui_modal.top() or "page") or nil
  else
    -- the counts reached names: a release the menu took (its press went to
    -- the script) and one made under a cover: the grid's step editor on top,
    -- pushed over what the press went to (an owner still beneath it, or
    -- the bare page)
    if goes == "menu" and state.press_went[n] == "script" and n ~= 1 then
      state.counts.menu_took_release = state.counts.menu_took_release + 1
    end
    local top, editor = S.lib.ui_modal.top(), S.lib.pages_seq.step_editor_owner
    local pressed = state.press_top[n]
    if goes == "script" and n ~= 1 and top == editor and pressed and pressed ~= editor then
      local beneath = pressed == "page"
      for _, owner in ipairs(h.registered_invariant("modal owner").upvalue("stack")) do
        if owner == pressed then beneath = true end
      end
      if beneath then state.counts.released_under_cover = state.counts.released_under_cover + 1 end
    end
    state.press_went[n], state.press_top[n] = nil, nil
  end
  if goes ~= "script" then return end
  local handler = state.context.menu.key or rawget(_G, "key")
  local entry_was_open = state.context.textentry.open
  handler(n, z)
  -- a name entry's K2 release cancels it (te.key)
  if entry_was_open and not state.context.textentry.open then
    state.counts.name_canceled = state.counts.name_canceled + 1
  end
end

local function hardware_enc(state, n, d)
  if where_input_goes(state) ~= "script" then return end
  local handler = norns.encoders.callback or rawget(_G, "enc")
  handler(n, d)
end

local function hardware_tap(state, n)
  hardware_key(state, n, 1); hardware_key(state, n, 0)
end

-- No takeover is up and no owner is pushed: the page has the controls
local function page_has_controls(state)
  return where_input_goes(state) == "script" and not state.context.textentry.open
    and state.S.lib.ui_modal.top() == nil
end

-- E1 to the page named, as a player turns it (an owner up: E1 does nothing)
-- The keys named let go first (a player lets go before turning to a page)
local function let_go(state, ...)
  for _, n in ipairs({...}) do
    if state.down[n] then hardware_key(state, n, 0) end
  end
end

local function go_to_page(state, name)
  local S = state.S
  hardware_enc(state, 1, page_index(S, name) - S.ui_page)
  return S.ui_page == page_index(S, name)
end

---------------------------------------------------------------------------
-- The owners, each opened by K3 on its page's row
---------------------------------------------------------------------------

local function setup_row(S, label)
  for index, row in ipairs(S.lib.pages_setup.setup_rows()) do
    if row.label == label then S.setup_cursor = index end
  end
end

local OWNER_OPEN = {
  zones = {page = "SETUP", place = function(S) setup_row(S, "mpe & zones") end,
    is_open = function(S) return S.lib.ui_zones.is_open() end},
  scale = {page = "SETUP", place = function(S) setup_row(S, "scale & tuning") end,
    is_open = function(S) return S.lib.ui_scale_editor.is_open() end},
  factory = {page = "SETUP", place = function(S) setup_row(S, "factory sets") end,
    is_open = function(S) return S.lib.factory.is_open() end},
  picker = {page = "VOICE", place = function(S)
    for index, row in ipairs(voice_page_rows(S.selected_voice)) do
      if row.kind == S.lib.ui_voice_rows.PRESET_KIND then S.lib.pages_voice.place_cursor(index) end
    end
  end, is_open = function(S) return S.lib.ui_voice_picker.is_open() end},
  -- slot 1 holds audio (setup); the slices field is BUFFER's last
  slice = {page = "BUFFER", place = function(S) S.buffer_page.slot, S.buffer_page.field = 1, WALK.last_field end,
    is_open = function(S) return S.lib.ui_slice_editor.is_open() end},
  -- IO's detail list has no accessor: its open record is the io detail
  -- invariant's upvalue (lib/pages/io.lua)
  io_detail = {page = "IO", place = function(S) S.lib.pages_io.go_to_row("ui walk", "voice", {id = "midi"}) end,
    is_open = function() return h.registered_invariant("io detail").upvalue("detail").owner ~= nil end},
}

local function open_owner(state, random)
  local S = state.S
  let_go(state, 1, 3)
  -- an owner up first goes back (K2), as a player leaves it for another page
  if where_input_goes(state) == "script" and not state.context.textentry.open and S.lib.ui_modal.top() then
    let_go(state, 2)
    hardware_tap(state, 2)
  end
  if not page_has_controls(state) then return end
  local kind = WALK.owners[random(#WALK.owners)]
  local how = OWNER_OPEN[kind]
  if not go_to_page(state, how.page) then return end
  how.place(S)
  hardware_tap(state, 3)
  local top = S.lib.ui_modal.top()
  if top and how.is_open(S) then
    state.owners[kind] = top
    state.counts["opened_" .. kind] = state.counts["opened_" .. kind] + 1
  end
end

-- K2 closes every owner (on the slice editor's rows view it goes back first)
local function close_owner(state)
  if state.S.lib.ui_modal.top() == nil or state.down[1] or state.down[2] then return end
  hardware_tap(state, 2)
end

---------------------------------------------------------------------------
-- The grid's step editor: a step key held on the patterns page
---------------------------------------------------------------------------

local function push_step_editor(state, random)
  if state.held_step then return end
  local x, y = random(16), random(state.S.constants.NUM_VOICES)
  state.held_step = {x, y}
  state.pane.press(x, y, 1)
  state.context.clock.run_for(WALK.editor_hold_seconds)
  local top = state.S.lib.ui_modal.top()
  if top == state.S.lib.pages_seq.step_editor_owner then
    state.owners.step_editor = top
    state.counts.opened_step_editor = state.counts.opened_step_editor + 1
  end
end

local function pop_step_editor(state)
  if not state.held_step then return end
  state.pane.press(state.held_step[1], state.held_step[2], 0)
  state.held_step = nil
end

---------------------------------------------------------------------------
-- The takeovers: SCENES' name entry (ALT+K2's release) and BUFFER's file
-- selector (K2's quick release)
---------------------------------------------------------------------------

local function open_name_entry(state)
  let_go(state, 1, 2)
  if not page_has_controls(state) then return end
  if not go_to_page(state, "SCENES") then return end
  state.S.lib.pages_scenes.move_cursor(1)
  hardware_key(state, 1, 1); hardware_tap(state, 2); hardware_key(state, 1, 0)
end

local function finish_name_entry(state)
  if not state.context.textentry.open then return end
  state.context.textentry.finish("walk")
  state.counts.name_finished = state.counts.name_finished + 1
end

-- K2's release cancels the entry (te.key)
local function cancel_name_entry(state)
  if not state.context.textentry.open or state.down[2] or where_input_goes(state) ~= "script" then return end
  hardware_tap(state, 2)
end

local function open_file_selector(state)
  let_go(state, 1, 2)
  if not page_has_controls(state) then return end
  if not go_to_page(state, "BUFFER") then return end
  hardware_tap(state, 2)
end

local function cancel_file_selector(state)
  if not selector_open(state) then return end
  state.context.fileselect.close(nil)
  state.counts.selector_canceled = state.counts.selector_canceled + 1
end

---------------------------------------------------------------------------
-- The end check
---------------------------------------------------------------------------

-- The modal stack's press records (lib/ui/modal.lua's locals)
local function modal_presses()
  local invariant = h.registered_invariant("modal owner")
  return invariant.upvalue("pressed"), invariant.upvalue("pressed_at")
end

local PRESS_FIELDS = {"key_press_page", "key_press_at", "key_press_alt"}

-- Where press state is left (empty: a fresh script's)
local function press_marks(state)
  local S = state.S
  local found = {}
  for _, field in ipairs(PRESS_FIELDS) do
    for n, value in pairs(S[field]) do found[#found + 1] = field .. "[" .. tostring(n) .. "] = " .. tostring(value) end
  end
  if S.alt_held then found[#found + 1] = "alt_held" end
  local pressed, pressed_at = modal_presses()
  for n in pairs(pressed) do found[#found + 1] = "the modal's pressed[" .. tostring(n) .. "]" end
  for n in pairs(pressed_at) do found[#found + 1] = "the modal's pressed_at[" .. tostring(n) .. "]" end
  for kind, owner in pairs(state.owners) do
    for n = 2, 3 do
      if S.lib.ui_modal.held_seconds(owner, n) ~= nil then found[#found + 1] = kind .. " holds K" .. n end
    end
  end
  return found
end

-- The physical keys that are up have no press mark anywhere: K1 up, no
-- ALT; K2 or K3 up, no page mark and no owner's press or press time. And
-- a press mark names the page shown: a page change forgets the presses,
-- so a key held across one and back never releases on its page (#234)
local function stale_marks(state)
  local S = state.S
  local problems = {}
  if not state.down[1] and S.alt_held then problems[#problems + 1] = "K1 is up and ALT is held" end
  local pressed, pressed_at = modal_presses()
  for n = 2, 3 do
    if not state.down[n] then
      for _, field in ipairs(PRESS_FIELDS) do
        if S[field][n] ~= nil then problems[#problems + 1] = "K" .. n .. " is up and " .. field .. " is set" end
      end
      if pressed[n] ~= nil then problems[#problems + 1] = "K" .. n .. " is up and an owner holds it" end
      if pressed_at[n] ~= nil then problems[#problems + 1] = "K" .. n .. " is up and an owner has its press time" end
    end
    if S.key_press_page[n] ~= nil and S.key_press_page[n] ~= S.ui_page then
      problems[#problems + 1] = "K" .. n .. "'s press is on page " .. tostring(S.key_press_page[n]) .. ", not the page shown, "
        .. tostring(S.ui_page)
    end
  end
  return problems
end

-- Each page's hints with the press marks cleared (put back after)
local function hints_without_marks(state, record)
  local S = state.S
  local saved = {}
  for _, field in ipairs(PRESS_FIELDS) do
    saved[field] = {}
    for n, value in pairs(S[field]) do saved[field][n] = value; S[field][n] = nil end
  end
  local pressed, pressed_at = modal_presses()
  local saved_pressed, saved_at, saved_alt = {}, {}, S.alt_held
  for n, value in pairs(pressed) do saved_pressed[n] = value; pressed[n] = nil end
  for n, value in pairs(pressed_at) do saved_at[n] = value; pressed_at[n] = nil end
  S.alt_held = false
  local ok, hint = pcall(record.hints, false)
  for _, field in ipairs(PRESS_FIELDS) do
    for n, value in pairs(saved[field]) do S[field][n] = value end
  end
  for n, value in pairs(saved_pressed) do pressed[n] = value end
  for n, value in pairs(saved_at) do pressed_at[n] = value end
  S.alt_held = saved_alt
  if not ok then error(hint, 0) end
  return hint
end

local HINT_ROW_WIDTH = 128  -- lib/ui/header.lua's

-- Every key up, every takeover and owner closed: what a player can always
-- do (K2 closes an owner); problems if it cannot
local function close_everything(state)
  local S, context = state.S, state.context
  local problems = {}
  for n = 3, 1, -1 do
    if state.down[n] then hardware_key(state, n, 0) end
  end
  if context.menu.mode then _menu.set_mode(false) end
  if context.textentry.open then hardware_tap(state, 2) end
  if context.textentry.open then problems[#problems + 1] = "K2 left the name entry open" end
  cancel_file_selector(state)
  pop_step_editor(state)
  for _ = 1, WALK.close_tries do
    if S.lib.ui_modal.top() == nil then break end
    hardware_tap(state, 2)
  end
  if S.lib.ui_modal.top() ~= nil then
    local open = {}
    for kind, owner in pairs(state.owners) do
      if owner == S.lib.ui_modal.top() then open[#open + 1] = kind end
    end
    problems[#problems + 1] = "an owner is left open after " .. WALK.close_tries .. " K2s: "
      .. (#open > 0 and table.concat(open, ", ") or "unknown")
  end
  return problems
end

-- What animates by right, not by a key: the patterns, the LFOs, the
-- recordings, the voices playing a buffer (BUFFER's and the slice
-- editor's playheads move); then time passes. No page changes: a page change forgets the
-- press marks the end check looks for
local function quiet(state)
  local S, context = state.S, state.context
  if S.pattern_playing then pattern_clock_stop() end
  for n = 1, S.constants.NUM_LFOS do
    if S.lib.pages_lfo.lfo_running(n) then set_binary_param(S.lib.lfos.param_id(n), 0) end
  end
  for slot = 1, S.constants.NUM_BUFFERS do
    if S.buffers[slot].recording then record_buffer(slot) end
  end
  for voice = 1, S.constants.NUM_VOICES do
    if S.voices[voice].active and voice_uses_buffer(voice) then toggle_voice(voice) end
  end
  context.clock.run_for(WALK.quiet_seconds)
end

-- The shown page: MOD back to its list (K2, which a view animates in), then
-- assertions 2 to 4, after a frame has drawn it (the frame that takes a
-- lapsed scenes prompt away asks SCENES' animates once more, by design): it
-- does not animate, its drawn hint row is its own hints, and those are the
-- same with the press marks cleared
local function check_shown_page(state, problems)
  local S, context = state.S, state.context
  if S.ui_page == page_index(S, "MOD") then
    for _ = 1, WALK.close_tries do
      if S.mod_page.view == "list" then break end
      hardware_tap(state, 2)
    end
  end
  local record = S.registry.pages[S.ui_page]
  request_redraw()
  h.next_frame(context)
  if record.animates and record.animates() then problems[#problems + 1] = record.name .. " animates" end
  local own = record.hints(false)
  local drawn = h.hint_text(context)
  local expected = S.lib.ui_text.fit_text(S.lib.ui_text.printable(own), HINT_ROW_WIDTH)
  if drawn ~= expected then
    problems[#problems + 1] = record.name .. "'s hint row shows " .. tostring(drawn) .. ", its hints " .. tostring(expected)
  end
  local cleared = hints_without_marks(state, record)
  if cleared ~= own then
    problems[#problems + 1] = record.name .. "'s hints " .. tostring(own) .. " are " .. tostring(cleared)
      .. " with the press marks cleared"
  end
end

-- The end check (docs/notes/lua/ui-core.md, The UI walk): every key up and
-- every owner closed, the rest quieted, then 1. the press state is a fresh
-- script's, 2. no owner and no page animates, 3. each page's drawn hint row
-- is its own hints, 4. the same with the press marks cleared. The shown
-- page is checked before any page change (which forgets its marks)
local function end_check(state)
  local S = state.S
  local problems = close_everything(state)
  quiet(state)
  for _, mark in ipairs(press_marks(state)) do problems[#problems + 1] = "a press mark is left: " .. mark end
  for kind, owner in pairs(state.owners) do
    if owner.animates and owner.animates() then problems[#problems + 1] = kind .. " animates, closed" end
  end
  check_shown_page(state, problems)
  local shown = S.ui_page
  for index = 1, S.constants.NUM_UI_PAGES do
    if index ~= shown then
      S.lib.ui_keys.set_ui_page(index)
      check_shown_page(state, problems)
    end
  end
  return problems
end

---------------------------------------------------------------------------
-- The walk
---------------------------------------------------------------------------

local COUNTERS = {"menu_took_release", "released_under_cover", "name_finished", "name_canceled", "selector_canceled",
  "opened_step_editor"}
for _, kind in ipairs(WALK.owners) do COUNTERS[#COUNTERS + 1] = "opened_" .. kind end

local function new_state(context)
  local counts = {}
  for _, counter in ipairs(COUNTERS) do counts[counter] = 0 end
  return {context = context, S = local_value("S"), down = {}, press_went = {}, press_top = {}, owners = {},
    counts = counts, pane = h.grid_pane(context, "128h")}
end

-- The end check's controls: each of its assertions names the fault it is
-- for, on a script left so by hand
h.test("the ui walk's end check names a press mark left, an animation, a hint row not the page's and an owner left open",
  function()
  local context = h.load_strata(); h.finish_startup(context)
  local state = new_state(context)
  local S = state.S
  local fresh = end_check(state)
  assert_true(#fresh == 0, "a fresh script passes: " .. table.concat(fresh, "; "))
  -- an ALT+K2 press on MAIN the script still holds (its release lost)
  S.lib.ui_keys.set_ui_page(page_index(S, "MAIN"))
  S.key_press_page[2], S.key_press_at[2], S.key_press_alt[2] = page_index(S, "MAIN"), util.time(), true
  -- a hints flash on FX that never lapses
  S.lib.ui_flash.start("hints", "stuck", 1000, page_index(S, "FX"))
  local problems = table.concat(end_check(state), "\n")
  for _, expected in ipairs({"a press mark is left: key_press_page[2]", "MAIN animates",
      "FX's hint row shows stuck", "MAIN's hints K2:cancel are K2:field"}) do
    assert_true(problems:find(expected, 1, true), "names " .. expected .. ":\n" .. problems)
  end
  -- an owner K2 does not close
  S.key_press_page[2], S.key_press_at[2], S.key_press_alt[2] = nil, nil, nil
  S.lib.ui_flash.cancel_all()
  local stuck = {draw = function() end}
  S.lib.ui_modal.push(stuck)
  problems = table.concat(end_check(state), "\n")
  assert_true(problems:find("an owner is left open after", 1, true), "names the owner left open:\n" .. problems)
  S.lib.ui_modal.pop(stuck)
end)

-- released_under_cover counts a release made with the grid's step editor
-- on top, pushed over what its press went to; a release on an owner the
-- editor uncovered by its pop is no cover
h.test("the ui walk counts a release under the step editor as under a cover, and one after its pop as not", function()
  local context = h.load_strata(); h.finish_startup(context)
  local state = new_state(context)
  local S = state.S
  -- a press on the bare page, then the editor pushed over it
  hardware_key(state, 2, 1)
  push_step_editor(state, function(n) return n end)
  assert_true(S.lib.ui_modal.top() == S.lib.pages_seq.step_editor_owner, "the editor is up")
  hardware_key(state, 2, 0)
  assert_true(state.counts.released_under_cover == 1, "the page's press released under the editor: counted")
  -- a press on the editor over the zones editor, the editor popped, the release on the zones editor
  pop_step_editor(state)
  open_owner(state, function() return 1 end)
  assert_true(S.lib.ui_zones.is_open(), "the zones editor is open")
  push_step_editor(state, function(n) return n end)
  hardware_key(state, 3, 1)
  pop_step_editor(state)
  hardware_key(state, 3, 0)
  assert_true(state.counts.released_under_cover == 1, "a release after the cover went: not counted, "
    .. state.counts.released_under_cover)
  close_owner(state)
end)

local function toggle_key(n)
  return function(state) hardware_key(state, n, state.down[n] and 0 or 1) end
end

local function turn(n)
  return function(state, random)
    local amount = random(3)
    hardware_enc(state, n, random(2) == 1 and amount or -amount)
  end
end

h.walk({
  name = "ui walk: keys, encoders, the menu and the owners leave nothing held (3.9, design section 6)",
  seeds = {3, 1789, 40404, 77},
  steps = 400,
  setup = function(context)
    local S = local_value("S")
    -- slot 1 holds audio, so the slice editor opens on it
    load_buffer(1, "/tmp/walk.wav")
    context.polls.fire("bufferState", context.polls.buffer_state_value(1, S.buffers[1].loads_sent, 2))
    return new_state(context)
  end,
  ops = {
    {6, "K1", toggle_key(1)},
    {8, "K2", toggle_key(2)},
    {8, "K3", toggle_key(3)},
    {3, "E1", turn(1)},
    {5, "E2", turn(2)},
    {5, "E3", turn(3)},
    {2, "open menu", function(state) if not state.context.menu.mode then _menu.set_mode(true) end end},
    {5, "close menu", function(state) if state.context.menu.mode then _menu.set_mode(false) end end},
    {8, "open owner", open_owner},
    {4, "close owner", close_owner},
    {3, "push step editor", push_step_editor},
    {3, "pop step editor", pop_step_editor},
    {2, "open name entry", open_name_entry},
    {3, "finish name entry", finish_name_entry},
    {3, "cancel name entry", cancel_name_entry},
    {2, "open file selector", open_file_selector},
    {3, "cancel file selector", cancel_file_selector},
    {4, "time", function(state, random) state.context.clock.run_for(0.04 + 0.01 * random(56)) end},
  },
  after = function(state) return stale_marks(state) end,
  finish = end_check,
  reached = COUNTERS,
  counts = function(state) return state.counts end,
})

end
