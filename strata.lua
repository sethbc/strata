-- strata.lua
-- ambient granular layers
--
-- E1: page (MAIN FX LFO BUFFER SETUP)
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

-- The modules, in dependency order. Each constructor's table is
-- S.lib.<name> (lib/<dir>/<file>.lua: S.lib.<dir>_<file>); a module adds
-- its records to S.registry (pages, params, grid layouts, cleanup steps) as
-- it loads.

-- Voices: S.voices (the voice definitions), S.frozen, S.master_density,
-- S.selected_voice and the voice source helpers (lib/voices.lua). The
-- module sets its S fields itself: S.voices is the voices table
include("lib/voices")(S)

-- Screen and arc redraws and the frame clock: request_redraw, draw_frame,
-- start_frame_clock, stop_frame_clock; S.ui_page (lib/ui/frame.lua)
S.lib.ui_frame = include("lib/ui/frame")(S)

-- Param -> engine and voice start/sync: send_param_to_engine,
-- engine_param_value, toggle_voice, toggle_freeze, sync_voice_to_engine,
-- sync_voice_values_to_engine; S.engine_senders, S.engine_param_values,
-- S.lfo_last_dest, S.lfo_scaled (lib/engine_sync.lua)
S.lib.engine_sync = include("lib/engine_sync")(S)

-- Sample buffers: S.buffers, recording, loading, clearing and saving, the
-- bufferState and bufferLoadFailed poll handlers (init starts the polls in
-- S.buffer_polls) and buffers.data (lib/buffers.lua)
S.lib.buffers = include("lib/buffers")(S)

-- Global LFOs: S.lfos, S.selected_lfo, S.lfo_last_raw, S.LFO_DESTINATIONS,
-- apply_lfo, restore_lfo_destination, lfo_phase_estimate and their params
-- (add_lfo_params, which lib/params_setup.lua's lfos record calls)
-- (lib/lfos.lua)
S.lib.lfos = include("lib/lfos")(S)

-- Per-voice drift, randomize and mutations: randomize_voice, drift_update,
-- gentle_mutate; S.drift_metro, S.mutation_metro, S.drift_writing,
-- S.grain_pitch_base, S.buf_pos_base (lib/mutation.lua)
S.lib.mutation = include("lib/mutation")(S)

-- Scenes: S.scenes, S.current_scene, capture, recall and smooth
-- transitions, the scene sequencer, migration, validation and scenes.data;
-- S.scene_sequencer_*, S.scene_transition_*, S.scene_recall_in_progress,
-- S.scene_autosave_blocked, S.SCENE_GLOBAL_PARAMS, S.VOICE_SCENE_DEFAULTS,
-- S.SCENE_BLOCK_DEFAULTS, S.SCENE_TRANSITION (lib/scenes.lua)
S.lib.scenes = include("lib/scenes")(S)

-- MIDI input: attach_midi, midi_init, midi_event, midi_device_name,
-- midi_bend_follow_selection and the hot-plug handlers; S.midi_device,
-- S.midi_state, S.lib.midi_in.MIDI (lib/midi_in.lua)
S.lib.midi_in = include("lib/midi_in")(S)

-- init's params, in PARAMS menu order (S.registry.params), add_voice_params,
-- get_param_spec, redraw_on_param_changes and the tempo-follow handlers
-- (install_tempo_change_handler, restore_tempo_change_handler);
-- S.fx_filter_last_mix (lib/params_setup.lua)
S.lib.params_setup = include("lib/params_setup")(S)

-- Param ranges and fractions: param_range, param_value_fraction,
-- param_fraction (lib/ui/params.lua)
S.lib.ui_params = include("lib/ui/params")(S)

-- What the screen pages share: the header and hint row (draw_header,
-- draw_hints; lib/ui/header.lua), S.lib.ui_text.fit_text (lib/ui/text.lua),
-- S.key_press_page, forget_held_keys and S.lib.ui_keys.ignore_page_input,
-- select_voice_by, set_ui_page (lib/ui/keys.lua), and the norns menu watch
-- (watch_menu_opening, unwatch_menu_opening, forget_keys_held_through_menu;
-- lib/ui/menu_watch.lua)
S.lib.ui_header = include("lib/ui/header")(S)
S.lib.ui_text = include("lib/ui/text")(S)
S.lib.ui_keys = include("lib/ui/keys")(S)
S.lib.ui_menu_watch = include("lib/ui/menu_watch")(S)

-- The screen pages. Each registers its record {name, draw, enc, key,
-- key_release} at its UI_PAGES index in S.registry.pages, which enc, key
-- and redraw below dispatch through: MAIN (S.voice_list, update_voice_list,
-- main_param_id, ...; lib/pages/main.lua), FX (S.FX_PAGE, S.fx_row;
-- lib/pages/fx.lua), LFO (lfo_shape_value; lib/pages/lfo.lua), BUFFER
-- (S.BUFFER_PAGE, buffer_page_flash, the K2 file selector;
-- lib/pages/buffer.lua) and SETUP (setup_enc; lib/pages/setup.lua)
S.lib.pages_main = include("lib/pages/main")(S)
S.lib.pages_fx = include("lib/pages/fx")(S)
S.lib.pages_lfo = include("lib/pages/lfo")(S)
S.lib.pages_buffer = include("lib/pages/buffer")(S)
S.lib.pages_setup = include("lib/pages/setup")(S)
for index, name in ipairs(UI_PAGES) do
  assert(S.registry.pages[index] and S.registry.pages[index].name == name, "no page record for " .. name)
end

-- The arc: S.arc_device, S.arc_connected, arc_sweep_param, arc_ring_fill,
-- arc_init, first_arc_port, arc.add/arc.remove, forget_arc_lfo_period_ticks
-- and the norns entry points arc_delta, arc_key and arc_redraw, which
-- dispatch through the page records' arc_delta and arc_redraw
-- (lib/arc/core.lua). Each page's rings set those two fields on its record
-- (lib/arc/main.lua, fx.lua, lfo.lua, buffer.lua); SETUP has none
S.lib.arc_core = include("lib/arc/core")(S)
S.lib.arc_main = include("lib/arc/main")(S)
S.lib.arc_fx = include("lib/arc/fx")(S)
S.lib.arc_lfo = include("lib/arc/lfo")(S)
S.lib.arc_buffer = include("lib/arc/buffer")(S)

-- The grid: S.grids (one vport per port), S.MAX_GRID_PORTS, the grid UI
-- state (S.grid_page, S.param_page, S.grid_voice_select), GRID_LAYOUT
-- (S.lib.grid_core.GRID_LAYOUT), grid_init, grid.add/grid.remove,
-- select_grid_voice and the norns entry points grid_key and grid_redraw,
-- which dispatch by each grid's exact size through S.registry.grid_layouts
-- (lib/grid/core.lua); the 256's faders (fader_param_ids,
-- set_param_from_column, grid_redraw_faders, ...; lib/grid/faders.lua); and
-- one file per layout, each registering its {key, redraw} record
-- (lib/grid/layout_256.lua, layout_128h.lua, layout_128v.lua, layout_64.lua)
S.lib.grid_core = include("lib/grid/core")(S)
S.lib.grid_faders = include("lib/grid/faders")(S)
S.lib.grid_layout_256 = include("lib/grid/layout_256")(S)
S.lib.grid_layout_128h = include("lib/grid/layout_128h")(S)
S.lib.grid_layout_128v = include("lib/grid/layout_128v")(S)
S.lib.grid_layout_64 = include("lib/grid/layout_64")(S)

-- The pattern sequencer: S.patterns, S.pattern_position, S.pattern_playing,
-- S.pattern_clock, pattern edits, the pattern clock and step_brightness
-- (lib/sequencer.lua)
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

-- Encoders. E1 selects the page; E2 and E3 go to the page record's enc
function enc(n, d)
  if n == 1 then
    S.lib.ui_keys.set_ui_page(util.clamp(S.ui_page + d, 1, NUM_UI_PAGES))
  else
    S.registry.pages[S.ui_page].enc(n, d)
  end
  request_redraw()
end

-- Keys. Presses go to the page record's key handler. A release goes to its
-- key_release only if the key went down on the page still showing, so a
-- key held across a page change does nothing when it comes up.
function key(n, z)
  if z == 1 then
    S.key_press_page[n] = S.ui_page
    S.registry.pages[S.ui_page].key(n)
  else
    local press_page = S.key_press_page[n]
    S.key_press_page[n] = nil
    if press_page == S.ui_page then
      S.registry.pages[S.ui_page].key_release(n)
    end
  end
  request_redraw()
end

-- Redraw
function redraw()
  -- the open file selector owns the screen: norns' own redraw() calls (as
  -- the norns menu closes) and Strata's draw the file list, never the page
  if S.BUFFER_PAGE.file_selector_open then
    fileselect.redraw()
    return
  end
  screen.clear()
  draw_header()
  S.registry.pages[S.ui_page].draw()
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
