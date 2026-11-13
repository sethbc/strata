-- strata.lua
-- ambient granular layers
-- v3.4.0
--
-- E1: page   K1 held: ALT
-- MAIN: E2 voice, E3 field,
--   K2 next field, K3 start/stop,
--   ALT+K2 randomize, ALT+K3 lock
-- VOICE: E2 row, E3 value,
--   K2/K3 prev/next section
-- SEQ: E2 step, E3 level,
--   K2 play/stop, K3 step on/off
-- FX: E2 row, E3 value,
--   K3 bypass/on
-- LFO: K2/K3 select, E2 setting,
--   E3 value, ALT+K3 on/off
-- MOD: E2 row, E3 value,
--   K2 next section, K3 targets,
--   routing, record or LFO page
-- BUFFER: E2 buffer, E3 field,
--   K2 load, K3 record/stop
-- SCENES: E2 slot, K2 fade,
--   K3 recall, ALT+K3 save
-- SETUP: E2 field, E3 value
--
-- MIDI: notes play voices 1-7 on
-- channels 1-7 (or the selected voice)

engine.name = "Strata"

local fileselect = require "fileselect"  -- redraw() draws the open BUFFER file selector

-- The table the script and its lib/ modules share (lib/state.lua): one
-- include per module, by its lib/ path, in this file only
local S = include("lib/state")()

-- Constants (lib/constants.lua)
S.constants = include("lib/constants")
local NUM_UI_PAGES = S.constants.NUM_UI_PAGES
local UI_PAGES = S.constants.UI_PAGES
local E1_TICKS_PER_PAGE = S.constants.E1_TICKS_PER_PAGE

-- The modules, in dependency order (AGENTS.md's module table lists each
-- one's notes file). Each constructor's table is S.lib.<name> (lib/<dir>/<file>.lua:
-- S.lib.<dir>_<file>); a module adds its records to S.registry (pages,
-- params, grid layouts, cleanup steps) as it loads.
S.lib.voices = include("lib/voices")(S)
S.lib.ui_frame = include("lib/ui/frame")(S)
S.lib.engine_sync = include("lib/engine_sync")(S)
S.lib.data_files = include("lib/data_files")(S)
S.lib.side_files = include("lib/side_files")(S)
S.lib.buffers = include("lib/buffers")(S)
S.lib.record = include("lib/record")(S)
S.lib.lfos = include("lib/lfos")(S)
S.lib.mutation = include("lib/mutation")(S)
S.lib.scenes = include("lib/scenes")(S)
S.lib.midi_in = include("lib/midi_in")(S)
S.lib.history = include("lib/history")(S)
S.lib.freeze = include("lib/freeze")(S)
S.lib.loops = include("lib/loops")(S)
S.lib.variation = include("lib/variation")(S)
S.lib.voice_mix = include("lib/voice_mix")(S)
S.lib.performance = include("lib/performance")(S)
S.lib.files = include("lib/files")(S)
S.lib.waveforms = include("lib/waveforms")(S)
S.lib.playheads = include("lib/playheads")(S)
S.lib.positions = include("lib/positions")(S)
S.lib.bookmarks = include("lib/bookmarks")(S)
S.lib.ui_modal = include("lib/ui/modal")(S)
S.lib.quantize = include("lib/quantize")(S)
S.lib.mod_sources = include("lib/mod_sources")(S)
S.lib.macros = include("lib/macros")(S)
S.lib.scatter = include("lib/scatter")(S)
S.lib.morph = include("lib/morph")(S)
S.lib.gestures = include("lib/gestures")(S)
S.lib.input_level = include("lib/input_level")(S)
S.lib.matrix = include("lib/matrix")(S)
S.lib.notes = include("lib/notes")(S)
S.lib.mpe = include("lib/mpe")(S)
S.lib.expression = include("lib/expression")(S)
S.lib.params_setup = include("lib/params_setup")(S)
S.lib.ui_params = include("lib/ui/params")(S)
S.lib.ui_voice_rows = include("lib/ui/voice_rows")(S)
S.lib.ui_cursors = include("lib/ui/cursors")(S)
S.lib.ui_header = include("lib/ui/header")(S)
S.lib.ui_flash = include("lib/ui/flash")(S)
S.lib.ui_text = include("lib/ui/text")(S)
S.lib.ui_field_list = include("lib/ui/field_list")(S)
S.lib.ui_keys = include("lib/ui/keys")(S)
S.lib.ui_alt = include("lib/ui/alt")(S)
S.lib.ui_detent = include("lib/ui/detent")(S)
S.lib.ui_menu_watch = include("lib/ui/menu_watch")(S)

-- The screen pages, in UI_PAGES order: each creates its record at
-- S.registry.pages[UI_PAGES.index.<PAGE>] (every field but the four arc
-- fields; docs/notes/lua/ui/pages-and-dispatch.md lists them), which enc, key and
-- redraw dispatch through
S.lib.pages_main = include("lib/pages/main")(S)
S.lib.pages_voice = include("lib/pages/voice")(S)
S.lib.pages_seq = include("lib/pages/seq")(S)
S.lib.pages_fx = include("lib/pages/fx")(S)
S.lib.pages_lfo = include("lib/pages/lfo")(S)
S.lib.pages_mod = include("lib/pages/mod")(S)
S.lib.pages_buffer = include("lib/pages/buffer")(S)
S.lib.pages_scenes = include("lib/pages/scenes")(S)
S.lib.pages_setup = include("lib/pages/setup")(S)
for index, name in ipairs(UI_PAGES) do
  local record = S.registry.pages[index]
  assert(record and record.name == name, "no page record for " .. name)
  for _, field in ipairs({"draw", "hints", "enc", "key"}) do
    assert(type(record[field]) == "function", name .. "'s page record has no " .. field)
  end
end

-- The arc: after every page file, since each page's rings set only the arc
-- fields (arc_delta, arc_redraw, arc_alt_delta, arc_alt_redraw) on its
-- page record (SETUP has none)
S.lib.arc_core = include("lib/arc/core")(S)
S.lib.arc_main = include("lib/arc/main")(S)
S.lib.arc_voice = include("lib/arc/voice")(S)
S.lib.arc_seq = include("lib/arc/seq")(S)
S.lib.arc_fx = include("lib/arc/fx")(S)
S.lib.arc_lfo = include("lib/arc/lfo")(S)
S.lib.arc_mod = include("lib/arc/mod")(S)
S.lib.arc_buffer = include("lib/arc/buffer")(S)
S.lib.arc_scenes = include("lib/arc/scenes")(S)

-- The grid: the core first, then the faders and one file per layout, each
-- registering its {key, redraw} record in S.registry.grid_layouts
S.lib.grid_core = include("lib/grid/core")(S)
S.lib.grid_faders = include("lib/grid/faders")(S)
S.lib.grid_layout_256 = include("lib/grid/layout_256")(S)
S.lib.grid_layout_128h = include("lib/grid/layout_128h")(S)
S.lib.grid_layout_128v = include("lib/grid/layout_128v")(S)
S.lib.grid_layout_64 = include("lib/grid/layout_64")(S)
S.lib.sequencer = include("lib/sequencer")(S)

-- init's start-up: voice 1 starts at once, voice 2 voice_delay_seconds
-- later; clock is the start-up clock while it waits (cleanup() cancels it).
-- Its start step stays here, since only the script starts voices at init; a
-- global table, where the tests read it
STARTUP = {voice_delay_seconds = 0.5, clock = nil}

function cancel_startup_clock()
  if STARTUP.clock then
    clock.cancel(STARTUP.clock)
    STARTUP.clock = nil
  end
end

S.register_cleanup(S.constants.CLEANUP_ORDER.startup_clock, function()
  cancel_startup_clock()
end)

-- E1 only selects the page: without acceleration, and E1_TICKS_PER_PAGE
-- ticks per page, a fast turn steps through pages instead of jumping to SETUP
S.register_start(S.constants.START_ORDER.e1_settings, function()
  norns.enc.accel(1, false)
  norns.enc.sens(1, E1_TICKS_PER_PAGE)
end)

-- Start with the first two voices: voice 1 at once, voice 2 later
S.register_start(S.constants.START_ORDER.startup_clock, function()
  cancel_startup_clock()
  STARTUP.clock = clock.run(function()
    toggle_voice(1)
    clock.sleep(STARTUP.voice_delay_seconds)
    STARTUP.clock = nil
    -- toggle_voice toggles: leave voice 2 alone if a MIDI note or grid press started it meanwhile
    if not S.voices[2].active then toggle_voice(2) end
  end)
end)

-- Each module registers its own start steps with S.register_start (the
-- metros, the buffer polls, the controllers and MIDI, the scenes and buffers
-- files, the frame clock); S.constants.START_ORDER lists the whole sequence.
-- init adds the params first, so every step can read them. A step that fails
-- stops the rest: the scenes and buffers loads then never set their loaded
-- flags, so cleanup() does not overwrite the files (#72)
function init()
  -- Also keeps S an upvalue of init, where the test harness finds it
  assert(S.registry, "lib/state builds the registries")

  -- Set up params: each S.registry.params record adds its part of the
  -- PARAMS menu, in order (lib/params_setup.lua)
  for _, record in ipairs(S.registry.params) do
    record.add()
  end
  redraw_on_param_changes()

  local steps = {}
  for index, record in ipairs(S.registry.start) do steps[index] = record end
  table.sort(steps, function(first, second) return first.order < second.order end)
  for _, step in ipairs(steps) do
    step.fn()
  end
end

-- Encoders. E1 selects the page (with or without ALT). E2 and E3 go to the
-- page record's enc; with ALT held, to its alt_enc first, and on to enc
-- when it has none or it returns false (not handled). While a modal owner
-- is pushed (S.lib.ui_modal.top(), lib/ui/modal.lua) E2 and E3 go to its
-- enc and E1 does nothing. Before init's first start step (S.started,
-- lib/ui/frame.lua) enc, key and redraw do nothing: norns routes them to
-- the script if its menu closes while the engine loads
function enc(n, d)
  if not S.started then return end
  local owner = S.lib.ui_modal.top()
  if owner then
    if n ~= 1 and owner.enc then owner.enc(n, d) end
  elseif n == 1 then
    S.lib.ui_keys.set_ui_page(util.clamp(S.ui_page + d, 1, NUM_UI_PAGES))
  else
    local record = S.registry.pages[S.ui_page]
    if not (S.alt_held and record.alt_enc and record.alt_enc(n, d)) then
      record.enc(n, d)
    end
  end
  request_redraw()
end

-- Keys. K1 (which norns delivers only once held) is ALT: S.alt_held while
-- it is down (lib/ui/alt.lua). A K2 or K3 press goes to the page record's
-- key handler, or, with ALT held, to alt_action (the record's alt_key) and
-- is marked an ALT press (S.key_press_alt). A release goes only to the page
-- the key went down on, if it still shows (a key held across a page change
-- does nothing when it comes up): an ALT press's to alt_key_release, even
-- if K1 came up first, any other's to key_release (if the record has them).
-- While a modal owner is pushed, K2 and K3 go to S.lib.ui_modal.key
-- instead (a press to the owner's key(n, 1), a release to its key(n, 0)
-- only if it saw the press), and the page forgets the key (a press it saw
-- releases into nothing)
function key(n, z)
  if not S.started then return end
  local owner = S.lib.ui_modal.top()
  if n == 1 then
    S.lib.ui_alt.set(z == 1)
  elseif owner then
    S.key_press_page[n] = nil
    S.key_press_alt[n] = nil
    S.lib.ui_modal.key(n, z)
  elseif z == 1 then
    S.key_press_page[n] = S.ui_page
    if S.alt_held then
      S.key_press_alt[n] = true
      alt_action(S.ui_page, n)
    else
      S.key_press_alt[n] = nil
      S.registry.pages[S.ui_page].key(n)
    end
  else
    local press_page, alt_press = S.key_press_page[n], S.key_press_alt[n]
    S.key_press_page[n] = nil
    S.key_press_alt[n] = nil
    local record = S.registry.pages[S.ui_page]
    if press_page == S.ui_page then
      local release = record.key_release
      if alt_press then release = record.alt_key_release end
      if release then release(n) end
    end
  end
  request_redraw()
end

-- Redraw: the header, the page record's body (draw), then the hint row:
-- the "hints" flash while one shows (lib/ui/flash.lua), else the record's
-- hints(alt_held). While a modal owner is pushed (after the file
-- selector's check) its draw and hints(alt_held) take the page's place
-- under the header. A body or hints that fail still finish the frame
-- (#424): the error prints once (contained_call, key "page"), and the
-- screen shows the header of the page the keys act on and "draw error" on
-- the hint row
function redraw()
  if not S.started then return end
  -- the open file selector owns the screen: norns' own redraw() calls (as
  -- the norns menu closes) and Strata's draw the file list, never the page
  if S.BUFFER_PAGE.file_selector_open then
    fileselect.redraw()
    return
  end
  local owner = S.lib.ui_modal.top()
  S.lib.ui_cursors.clamp_all()  -- rows may have shrunk under a cursor since the last frame
  local record = S.registry.pages[S.ui_page]
  screen.clear()
  draw_header()
  local hints
  local drawn = S.lib.ui_frame.contained_call(UI_PAGES.draw_errors, "page", "page draw", function()
    if owner then
      owner.draw()
      hints = owner.hints and owner.hints(S.alt_held) or ""
    else
      record.draw()
      hints = S.lib.ui_flash.text("hints") or record.hints(S.alt_held)
    end
  end)
  if drawn then
    draw_hints(hints)
  else
    screen.clear()  -- no half-drawn body
    draw_header()
    draw_hints("draw error")
  end
  screen.update()
end

-- Each module registers its own cleanup steps with S.register_cleanup;
-- cleanup runs them in ascending order (S.constants.CLEANUP_ORDER lists the
-- whole sequence). A step that fails stops the rest, so the first ones give
-- norns back what Strata replaced (the tempo handler, the menu's set_mode)
function cleanup()
  local steps = {}
  for index, record in ipairs(S.registry.cleanup) do steps[index] = record end
  table.sort(steps, function(first, second) return first.order < second.order end)
  for _, step in ipairs(steps) do
    step.fn()
  end
end
