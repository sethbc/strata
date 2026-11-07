-- strata.lua
-- ambient granular layers
--
-- E1: page (MAIN VOICE SEQ FX LFO
--     BUFFER SCENES SETUP)
-- MAIN: E2 select voice, E3 main param,
--       K2 randomize, K3 start/freeze
-- FX: E2 select row, E3 adjust,
--     K3 filter bypass/on
-- LFO: E2 select LFO, E3 depth,
--      K2 destination, K3 on/off
-- SETUP: E2 MIDI port, E3 channel mode
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

-- The modules, in dependency order (docs/notes/lua.md, Modules, lists what
-- each owns). Each constructor's table is S.lib.<name> (lib/<dir>/<file>.lua:
-- S.lib.<dir>_<file>); a module adds its records to S.registry (pages,
-- params, grid layouts, cleanup steps) as it loads.
S.lib.voices = include("lib/voices")(S)
S.lib.ui_frame = include("lib/ui/frame")(S)
S.lib.engine_sync = include("lib/engine_sync")(S)
S.lib.buffers = include("lib/buffers")(S)
S.lib.lfos = include("lib/lfos")(S)
S.lib.mutation = include("lib/mutation")(S)
S.lib.scenes = include("lib/scenes")(S)
S.lib.midi_in = include("lib/midi_in")(S)
S.lib.params_setup = include("lib/params_setup")(S)
S.lib.ui_params = include("lib/ui/params")(S)
S.lib.ui_voice_rows = include("lib/ui/voice_rows")(S)
S.lib.ui_cursors = include("lib/ui/cursors")(S)
S.lib.ui_header = include("lib/ui/header")(S)
S.lib.ui_text = include("lib/ui/text")(S)
S.lib.ui_field_list = include("lib/ui/field_list")(S)
S.lib.ui_keys = include("lib/ui/keys")(S)
S.lib.ui_alt = include("lib/ui/alt")(S)
S.lib.ui_menu_watch = include("lib/ui/menu_watch")(S)

-- The screen pages, in UI_PAGES order: each creates its record at
-- S.registry.pages[UI_PAGES.index.<PAGE>] (every field but the four arc
-- fields; docs/notes/lua/ui-and-pages.md lists them), which enc, key and
-- redraw dispatch through
S.lib.pages_main = include("lib/pages/main")(S)
S.lib.pages_voice = include("lib/pages/voice")(S)
S.lib.pages_seq = include("lib/pages/seq")(S)
S.lib.pages_fx = include("lib/pages/fx")(S)
S.lib.pages_lfo = include("lib/pages/lfo")(S)
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
-- It stays here, beside init, the one function that starts it; a global
-- table, where the tests read it
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

function init()
  -- Also keeps S an upvalue of init, where the test harness finds it
  assert(S.registry, "lib/state builds the registries")

  -- Set up params: each S.registry.params record adds its part of the
  -- PARAMS menu, in order (lib/params_setup.lua)
  for _, record in ipairs(S.registry.params) do
    record.add()
  end
  redraw_on_param_changes()

  -- UI setup
  update_voice_list()
  -- E1 only selects the page: without acceleration, and 4 ticks per page,
  -- a fast turn steps through pages instead of jumping to SETUP
  norns.enc.accel(1, false)
  norns.enc.sens(1, E1_TICKS_PER_PAGE)
  -- forget held keys the moment the norns menu opens
  watch_menu_opening()
  
  -- Start the per-voice drift
  S.drift_metro = metro.init()
  S.drift_metro.time = 0.1
  S.drift_metro.event = drift_update
  S.drift_metro:start()

  -- Initialize mutation system
  S.mutation_metro = metro.init()
  S.mutation_metro.time = params:get("mutation_rate")
  S.mutation_metro.event = gentle_mutate
  -- Don't start automatically - controlled by mutation_enabled param

  -- Valid seconds per buffer slot, and failed loads, from the engine
  S.buffer_polls.state = poll.set("bufferState", S.lib.buffers.buffer_state_changed)
  if S.buffer_polls.state then
    S.buffer_polls.state:start()
  else
    print("bufferState poll not found")
  end
  S.buffer_polls.load_failed = poll.set("bufferLoadFailed", buffer_load_failed)
  if S.buffer_polls.load_failed then
    S.buffer_polls.load_failed:start()
  else
    print("bufferLoadFailed poll not found")
  end

  -- Connect arc
  arc_init()

  -- Connect grids
  grid_init()

  -- Listen for MIDI
  midi_init()

  -- Load saved scenes from disk
  load_scenes_from_disk()

  -- Reload the buffers remembered on exit (after the scenes, which may use them)
  load_buffers_from_disk()

  -- Start with first two voices (delayed)
  cancel_startup_clock()
  STARTUP.clock = clock.run(function()
    toggle_voice(1)
    clock.sleep(STARTUP.voice_delay_seconds)
    STARTUP.clock = nil
    -- toggle_voice toggles: leave voice 2 alone if a MIDI note or grid press started it meanwhile
    if not S.voices[2].active then toggle_voice(2) end
  end)

  start_frame_clock()
end

-- Encoders. E1 selects the page (with or without ALT). E2 and E3 go to the
-- page record's enc; with ALT held, to its alt_enc first, and on to enc
-- when it has none or it returns false (not handled)
function enc(n, d)
  if n == 1 then
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
function key(n, z)
  if n == 1 then
    S.lib.ui_alt.set(z == 1)
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

-- Redraw: the header, the page record's body (draw), then the hint row
-- from its hints(alt_held)
function redraw()
  -- the open file selector owns the screen: norns' own redraw() calls (as
  -- the norns menu closes) and Strata's draw the file list, never the page
  if S.BUFFER_PAGE.file_selector_open then
    fileselect.redraw()
    return
  end
  S.lib.ui_cursors.clamp_all()  -- rows may have shrunk under a cursor since the last frame
  local record = S.registry.pages[S.ui_page]
  screen.clear()
  draw_header()
  record.draw()
  draw_hints(record.hints(S.alt_held))
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
