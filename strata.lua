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
local NUM_VOICES = S.constants.NUM_VOICES
local NUM_SCENES = S.constants.NUM_SCENES
local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
local NUM_MOD_SLOTS = S.constants.NUM_MOD_SLOTS
local NUM_UI_PAGES = S.constants.NUM_UI_PAGES
local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
local NUM_BUFFERS = S.constants.NUM_BUFFERS
local NUM_LFOS = S.constants.NUM_LFOS
local SOURCE_SYNTH = S.constants.SOURCE_SYNTH
local SOURCE_INPUT = S.constants.SOURCE_INPUT
local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS
local UI_PAGES = S.constants.UI_PAGES
local BUFFER_MUTATION_KEYS = S.constants.BUFFER_MUTATION_KEYS

-- Voices: S.voices (the voice definitions), S.frozen, S.master_density,
-- S.selected_voice and the voice source helpers (lib/voices.lua). The
-- module sets its S fields itself: S.voices is the voices table
include("lib/voices")(S)

-- Screen and arc redraws and the frame clock: request_redraw, draw_frame,
-- start_frame_clock, stop_frame_clock; S.ui_page (lib/ui/frame.lua)
S.lib = S.lib or {}
S.lib.frame = include("lib/ui/frame")(S)

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
-- (add_lfo_params, called from init) (lib/lfos.lua)
S.lib.lfos = include("lib/lfos")(S)

local E1_TICKS_PER_PAGE = S.constants.E1_TICKS_PER_PAGE

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

-- Arc device (the arc vport from arc.connect); SETUP shows S.arc_connected
local arc_device = nil
S.arc_connected = false

-- Grid devices (support multiple grids); SETUP counts S.MAX_GRID_PORTS
S.MAX_GRID_PORTS = 4
S.grids = {}

-- MIDI input: see lib/midi_in.lua (S.midi_device, S.midi_state)

-- Pattern sequencer
S.patterns = {}
local pattern_position = 1
local pattern_playing = false
local pattern_clock = nil

-- Grid UI state
S.grid_page = 1  -- 1=patterns, 2=parameters, 3=scenes, 4=buffers/fx (256 only)
S.param_page = 1
S.grid_voice_select = 1

-- Initialize patterns for each voice
for i = 1, NUM_VOICES do
  S.patterns[i] = {}
  for step = 1, PATTERN_LENGTH do
    S.patterns[i][step] = 0  -- 0=off, 1-15=velocity/brightness
  end
end

-- init's start-up: voice 1 starts at once, voice 2 voice_delay_seconds
-- later; clock is the start-up clock while it waits (cleanup() cancels it).
-- A global table: the main chunk is close to Lua's 200-local limit
STARTUP = {voice_delay_seconds = 0.5, clock = nil}

function cancel_startup_clock()
  if STARTUP.clock then
    clock.cancel(STARTUP.clock)
    STARTUP.clock = nil
  end
end

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

-- Arc functions

-- Arc pages follow the screen page: ARC_PAGE_DELTA[S.ui_page] handles ring
-- turns and ARC_PAGE_REDRAW[S.ui_page] draws the rings between arc_redraw's
-- clear and refresh.

-- A continuous ring: UI_PAGES.ARC_TICKS_PER_SWEEP ticks sweep the control
-- param's whole range. params:delta moves its 0-1 raw value by delta *
-- quantum, so the sweep follows the warp (exp params sweep evenly) and the
-- step only quantizes the value read back. (A global: the main chunk is near
-- Lua's local limit.)
-- Control params only: it reads the param's controlspec.
function arc_sweep_param(param_id, delta)
  local quantum = params:lookup_param(param_id).controlspec.quantum
  params:delta(param_id, delta / (UI_PAGES.ARC_TICKS_PER_SWEEP * quantum))
end

local function arc_main_delta(n, delta)
  if n == 1 then
    -- Ring 1: Master density
    arc_sweep_param("master_density", delta)
  elseif n == 2 then
    -- Ring 2: Selected voice's main parameter
    arc_sweep_param(main_param_id(S.selected_voice), delta)
  elseif n == 3 then
    -- Ring 3: Grain size
    arc_sweep_param("v" .. S.selected_voice .. "_grain_size", delta)
  elseif n == 4 then
    -- Ring 4: Grain density
    arc_sweep_param("v" .. S.selected_voice .. "_grain_density", delta)
  end
end

-- Fill ring n from 0 to fraction (0-1) of a turn. Every ring draws through
-- here: the end angle stays just below a full turn, so a ring at its maximum
-- lights all 64 LEDs instead of none
function arc_ring_fill(arc_port, ring, fraction, level)
  local turn = math.pi * 2
  local clamped = math.max(0, math.min(1, fraction))
  arc_port:segment(ring, 0, math.min(clamped * turn, turn - UI_PAGES.ARC_FULL_TURN_MARGIN), level)
end

local function arc_main_redraw(arc_port)
  -- Every ring is drawn across its param's controlspec range (as the sweep
  -- moves it): density, the selected voice's main param, grain size, grain density
  local v = S.voices[S.selected_voice]
  local prefix = "v" .. S.selected_voice .. "_"
  arc_ring_fill(arc_port, 1, param_fraction("master_density"), 15)
  arc_ring_fill(arc_port, 2, param_fraction(main_param_id(S.selected_voice)), v.active and 15 or 4)
  arc_ring_fill(arc_port, 3, param_fraction(prefix .. "grain_size"), v.active and 12 or 3)
  arc_ring_fill(arc_port, 4, param_fraction(prefix .. "grain_density"), v.active and 12 or 3)
end

-- FX page rings: the param each ring adjusts (each sweeps its range in
-- UI_PAGES.ARC_TICKS_PER_SWEEP ticks)
local ARC_FX_RINGS = {
  {param_id = "filter_freq"},
  {param_id = "filter_res"},
  {param_id = "delay_time"},
  {param_id = "delay_mix"}
}

local function arc_fx_delta(n, delta)
  local ring = ARC_FX_RINGS[n]
  if ring then
    arc_sweep_param(ring.param_id, delta)
  end
end

-- Each ring shows its param across its controlspec (following the warp,
-- so exp params such as filter freq and delay time sweep evenly)
local function arc_fx_redraw(arc_port)
  for n, ring in ipairs(ARC_FX_RINGS) do
    arc_ring_fill(arc_port, n, param_fraction(ring.param_id), 12)
  end
end

-- BUFFER page rings: the selected voice's buffer position and rate, then
-- the recording duration and level. Param id suffixes after "v<i>_" for
-- the voice rings. Each sweeps its range in UI_PAGES.ARC_TICKS_PER_SWEEP ticks.
local ARC_BUFFER_RINGS = {
  {voice_key = "buf_pos"},
  {voice_key = "buf_rate"},
  {param_id = "record_duration"},
  {param_id = "record_level"}
}

local function arc_buffer_ring_param(ring)
  return ring.param_id or ("v" .. S.selected_voice .. "_" .. ring.voice_key)
end

-- Rings 1-2 adjust the voice's buffer params whatever its source (they are
-- ready when it switches to a buffer)
local function arc_buffer_delta(n, delta)
  local ring = ARC_BUFFER_RINGS[n]
  if ring then
    arc_sweep_param(arc_buffer_ring_param(ring), delta)
  end
end

-- Rings 1-2 are bright for a buffer-sourced voice and dim otherwise (the
-- buffer params do nothing then); the recording rings are always lit
local function arc_buffer_redraw(arc_port)
  local uses_buffer = voice_uses_buffer(S.selected_voice)
  for n, ring in ipairs(ARC_BUFFER_RINGS) do
    local level = 12
    if ring.voice_key then
      level = uses_buffer and 15 or 4
    end
    arc_ring_fill(arc_port, n, param_fraction(arc_buffer_ring_param(ring)), level)
  end
end

-- LFO page rings: 1-3 the depth of LFO 1-3 (whole percents), 4 the
-- selected LFO's period (free seconds, swept like every continuous ring, or
-- the clocked rate option in whole steps)
local ARC_LFO = {
  ticks_per_percent = 10,
  ticks_per_rate = 20,
  period_ring = 4
}
local arc_lfo_ticks = {}  -- per ring: ticks not yet worth a whole step

-- Ring 4's carried ticks belong to one LFO's clocked rate: forget them when
-- the selected LFO (E2 on the LFO page) or its mode changes, so they never
-- step another param
function forget_arc_lfo_period_ticks()
  arc_lfo_ticks[ARC_LFO.period_ring] = nil
end

-- Whole steps in a ring's accumulated ticks; the rest is kept for later
local function arc_whole_steps(ring, delta, ticks_per_step)
  local ticks = (arc_lfo_ticks[ring] or 0) + delta
  local steps = ticks >= 0 and math.floor(ticks / ticks_per_step) or -math.floor(-ticks / ticks_per_step)
  arc_lfo_ticks[ring] = ticks - steps * ticks_per_step
  return steps
end

local function lfo_period_param_id(n)
  if params:string("lfo_mode_" .. n) == "clocked" then
    return "lfo_clocked_" .. n
  end
  return "lfo_free_" .. n
end

local function arc_lfo_delta(n, delta)
  if n <= NUM_LFOS then
    local steps = arc_whole_steps(n, delta, ARC_LFO.ticks_per_percent)
    if steps ~= 0 then params:delta("lfo_depth_" .. n, steps) end
  elseif n == ARC_LFO.period_ring then
    local period_id = lfo_period_param_id(S.selected_lfo)
    if period_id == "lfo_free_" .. S.selected_lfo then
      arc_sweep_param(period_id, delta)
    else
      local steps = arc_whole_steps(n, delta, ARC_LFO.ticks_per_rate)
      if steps ~= 0 then params:delta(period_id, steps) end
    end
  end
end

-- Depth rings are bright while their LFO runs
local function arc_lfo_redraw(arc_port)
  for n = 1, NUM_LFOS do
    arc_ring_fill(arc_port, n, param_fraction("lfo_depth_" .. n), S.lib.pages_lfo.lfo_running(n) and 15 or 4)
  end
  arc_ring_fill(arc_port, ARC_LFO.period_ring, param_fraction(lfo_period_param_id(S.selected_lfo)), 12)
end

local function arc_ignore_delta() end
local function arc_draw_nothing() end  -- rings stay off

-- Indexed like UI_PAGES
local ARC_PAGE_DELTA = {arc_main_delta, arc_fx_delta, arc_lfo_delta, arc_buffer_delta, arc_ignore_delta}
local ARC_PAGE_REDRAW = {arc_main_redraw, arc_fx_redraw, arc_lfo_redraw, arc_buffer_redraw, arc_draw_nothing}

-- Arc handlers live on the vport only (as for grids): norns fires both
-- device.delta/key and vports[port].delta/key, so setting them on the device
-- as well would run every turn twice.
local function attach_arc(port)
  if arc_device and arc_device ~= arc.connect(port) then
    -- following another vport now: the old one (e.g. the empty port-1
    -- fallback from init) must not keep handlers for a later arc
    arc_device.delta = nil
    arc_device.key = nil
  end
  arc_device = arc.connect(port)
  arc_device.delta = arc_delta
  arc_device.key = arc_key
  S.arc_connected = arc_device.device ~= nil
end

-- The first arc vport (in port order) holding a device, other than
-- skipped_port; nil when there is none
function first_arc_port(skipped_port)
  for candidate = 1, UI_PAGES.ARC_PORTS do
    if candidate ~= skipped_port and arc.connect(candidate).device then
      return candidate
    end
  end
  return nil
end

-- Strata follows one arc: at init the first vport holding a device (port 1
-- preferred by being first); later, a hot-plugged arc connects only while none
-- is connected, and removing the connected arc moves to the first other
-- vport holding one, or disconnects.
function arc_init()
  attach_arc(first_arc_port() or UI_PAGES.ARC_PORT)  -- the first frame draws its rings
end

function arc.add(device)
  local port = device.port or UI_PAGES.ARC_PORT
  if port < 1 or port > UI_PAGES.ARC_PORTS then return end
  if S.arc_connected and arc_device ~= arc.connect(port) then return end  -- already following another arc
  attach_arc(port)
  request_redraw()  -- its rings, and SETUP shows the arc state
  print("arc connected")
end

function arc.remove(device)
  local port = device.port or UI_PAGES.ARC_PORT
  if port < 1 or port > UI_PAGES.ARC_PORTS then return end
  if arc_device ~= arc.connect(port) then return end  -- not the arc Strata follows
  -- norns clears the removed vport only after arc.remove returns: skip it
  local next_port = first_arc_port(port)
  if next_port then
    attach_arc(next_port)
    print("arc disconnected; following the arc on port " .. next_port)
  else
    S.arc_connected = false
    print("arc disconnected")
  end
  request_redraw()  -- the rings of the arc now followed, and SETUP's arc state
end

function arc_delta(n, delta)
  ARC_PAGE_DELTA[S.ui_page](n, delta)
  request_redraw()
end

function arc_key(n, s)
  -- Button press (2025 arc): same as K3 on MAIN, nothing on other pages
  if s == 1 and S.ui_page == UI_PAGES.MAIN_PAGE then
    S.lib.pages_main.start_or_freeze_selected_voice()
    request_redraw()
  end
end

function arc_redraw()
  if arc_device == nil or arc_device.device == nil then return end

  arc_device:all(0)
  ARC_PAGE_REDRAW[S.ui_page](arc_device)
  arc_device:refresh()
end

-- Grid functions
local GRID_LAYOUT = {
  fader_rows = 4,         -- 256-grid parameter page: one fader per row 9-12
  fader_width = 16,       -- fader columns
  fader_first_row = 9,
  param_page_row = 13,
  -- 256-grid BUFFER / FX page (page 4): record (row 1) and clear (row 2)
  -- per buffer slot, one FX fader per row 3-7, one source row per voice 9-15
  buffer_record_row = 1,
  buffer_clear_row = 2,
  fx_fader_ids = {"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"},
  fx_first_row = 3,
  source_first_row = 9    -- voice v's row is 8 + v; column = source option (1 synth, 2-9 buffers, 10 input)
}

-- Pick a grid's layout by its exact size. 16x16 must be matched exactly or
-- an 8x16 grid (rows == 16) would be treated as a 256.
local function grid_layout(grid_port)
  local cols, rows = grid_port.cols, grid_port.rows
  if cols == 16 and rows == 16 then
    return "256"
  elseif cols == 16 and rows == 8 then
    return "128h"
  elseif cols == 8 and rows == 16 then
    return "128v"
  elseif cols == 8 and rows == 8 then
    return "64"
  end
  return nil
end

-- Store a grid port's vport and route its key events to grid_key. Handlers
-- live on the vport only: norns fires both device.key and vports[port].key,
-- so also setting them on the device would run grid_key twice per press.
local function attach_grid(port)
  local grid_port = grid.connect(port)
  S.grids[port] = grid_port
  grid_port.key = function(x, y, z)
    grid_key(port, x, y, z)
  end
  return grid_port
end

function grid_init()
  -- Connect up to 4 grids
  for port = 1, S.MAX_GRID_PORTS do
    if grid.connect(port).device then
      local grid_port = attach_grid(port)
      print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
    end
  end
  grid_redraw()
end

-- Hot-plug. norns passes the raw device here; store its port's vport (as
-- grid_init does) rather than the device, which has no .device field.
function grid.add(device)
  local port = device.port
  if not port then return end  -- device not assigned to a grid port
  local grid_port = attach_grid(port)
  print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
  grid_redraw()
  request_redraw()  -- SETUP lists the connected grids
end

function grid.remove(device)
  local port = device.port
  if not port then return end
  if S.grids[port] then
    S.grids[port].key = nil
    S.grids[port] = nil
  end
  request_redraw()
  print("grid " .. port .. " disconnected")
end

function grid_key(port, x, y, z)
  if z == 0 then return end  -- Only respond to key presses

  local grid_port = S.grids[port]
  if not grid_port then return end

  local layout = grid_layout(grid_port)
  if layout == "256" then
    grid_key_256(x, y, z)
  elseif layout == "128h" then
    grid_key_128h(x, y, z)
  elseif layout == "128v" then
    grid_key_128v(x, y, z)
  elseif layout == "64" then
    grid_key_64(x, y, z)
  end

  grid_redraw()
  request_redraw()
end

-- 16x16 grid layout
function grid_key_256(x, y, z)
  -- Handle page navigation first (always accessible from row 8)
  if y == 8 and x >= 13 and x <= 16 then
    -- Page selection (always accessible)
    S.grid_page = x - 12
    return
  end

  if S.grid_page == 3 then
    -- Scene page
    if y == 1 and x <= NUM_SCENES then
      -- Row 1: Scene recall (instant)
      recall_scene(x, 0)
    elseif y == 2 and x <= NUM_SCENES then
      -- Row 2: Scene recall (with transition)
      recall_scene(x, params:get("scene_transition_time"))
    elseif y == 3 and x <= NUM_SCENES then
      -- Row 3: Scene save
      capture_scene(x)
    elseif y == 5 then
      -- Row 5: Scene sequencer controls
      if x == 1 then
        -- Toggle sequencer
        local enabled = params:get("scene_sequencer_enabled")
        params:set("scene_sequencer_enabled", enabled == 1 and 0 or 1)
      elseif x >= 3 and x <= 2 + NUM_SCENES then
        -- Set sequence length
        params:set("scene_sequence_length", x - 2)
      end
    end
  elseif S.grid_page == 4 then
    -- BUFFER / FX page: buffer rows 1-2, FX faders on rows 3-7, voice
    -- sources on rows 9-15; rows 8 and 16 work as on page 1
    local fx_param_id = GRID_LAYOUT.fx_fader_ids[y - GRID_LAYOUT.fx_first_row + 1]
    local source_voice = y - GRID_LAYOUT.source_first_row + 1
    if y == GRID_LAYOUT.buffer_record_row then
      -- record into buffer x, or stop its recording early
      if x <= NUM_BUFFERS then record_buffer(x) end
    elseif y == GRID_LAYOUT.buffer_clear_row then
      if x <= NUM_BUFFERS then clear_buffer(x) end
    elseif fx_param_id then
      set_param_from_column(fx_param_id, x)
    elseif source_voice >= 1 and source_voice <= NUM_VOICES then
      if x <= #SOURCE_OPTIONS then
        params:set("v" .. source_voice .. "_source", x)
      end
    elseif y == 8 then
      grid_key_256_transport(x)
    elseif y == 16 then
      grid_key_256_freeze(x)
    end
  elseif y >= 1 and y <= NUM_VOICES then
    -- Rows 1-NUM_VOICES: Pattern triggers for each voice
    toggle_pattern_step(y, x)
  elseif y == 8 then
    grid_key_256_transport(x)
  elseif y >= GRID_LAYOUT.fader_first_row and y < GRID_LAYOUT.fader_first_row + GRID_LAYOUT.fader_rows then
    -- Rows 9-12 (parameter page): one fader per row for the selected voice
    if S.grid_page == 2 then
      local fader_index = (S.param_page - 1) * GRID_LAYOUT.fader_rows + (y - GRID_LAYOUT.fader_first_row + 1)
      set_fader_param(S.grid_voice_select, fader_index, x)
    end
  elseif y == GRID_LAYOUT.param_page_row then
    -- Row 13 (parameter page): choose which group of four faders is shown
    if S.grid_page == 2 and x <= fader_page_count(S.grid_voice_select) then
      S.param_page = x
    end
  elseif y == 14 then
    -- Row 14: Voice selection for parameters (columns 1-7), voice
    -- on/off (columns 9-15)
    if x <= NUM_VOICES then
      select_grid_voice(x)
    elseif x >= 9 and x <= 8 + NUM_VOICES then
      toggle_voice(x - 8)
    end
  elseif y == 15 then
    -- Row 15: Pattern operations
    if x <= NUM_VOICES then
      -- Clear pattern for voice
      clear_pattern(x)
    elseif x >= 9 and x <= 8 + NUM_VOICES then
      -- Randomize pattern for voice
      randomize_pattern(x - 8)
    end
  elseif y == 16 then
    grid_key_256_freeze(x)
  end
end

-- 256 row 8: pattern controls (page selection is handled by grid_key_256)
function grid_key_256_transport(x)
  if x <= 4 then
    -- Play/stop
    pattern_toggle()
  elseif x >= 5 and x <= 8 then
    -- Tempo controls
    if x == 5 then params:delta("tempo", -10) end
    if x == 6 then params:delta("tempo", -1) end
    if x == 7 then params:delta("tempo", 1) end
    if x == 8 then params:delta("tempo", 10) end
  end
end

-- 256 row 16: global functions
function grid_key_256_freeze(x)
  if x <= NUM_VOICES then
    -- Freeze voice
    toggle_freeze(x)
  elseif x >= 9 and x <= 16 then
    -- Copy/paste patterns
    -- (Future expansion)
  end
end

-- 16x8 grid layout (128 buttons horizontal)
function grid_key_128h(x, y, z)
  if S.grid_page == 3 then
    -- Scene page
    if y == 1 and x <= NUM_SCENES then
      -- Row 1: Scene recall (instant)
      recall_scene(x, 0)
    elseif y == 2 and x <= NUM_SCENES then
      -- Row 2: Scene recall (with transition)
      recall_scene(x, params:get("scene_transition_time"))
    elseif y == 3 and x <= NUM_SCENES then
      -- Row 3: Scene save
      capture_scene(x)
    elseif y == 5 and x == 1 then
      -- Toggle scene sequencer
      local enabled = params:get("scene_sequencer_enabled")
      params:set("scene_sequencer_enabled", enabled == 1 and 0 or 1)
    elseif y == 4 and x <= NUM_SCENES then
      -- Row 4: Set sequence length
      params:set("scene_sequence_length", x)
    end
  elseif y >= 1 and y <= NUM_VOICES then
    -- Rows 1-7: Pattern triggers
    toggle_pattern_step(y, x)
  end

  -- Row 8: Always accessible (multi-function)
  if y == 8 then
    if x <= 4 then
      pattern_toggle()
    elseif x == 5 then
      S.grid_page = 1  -- Patterns
    elseif x == 6 then
      S.grid_page = 2  -- Parameters
    elseif x == 7 then
      S.grid_page = 3  -- Scenes
    elseif x >= 9 and x <= 8 + NUM_VOICES then
      -- Voice toggle
      toggle_voice(x - 8)
    elseif x == 16 then
      -- Voice selection for parameters
      select_grid_voice(S.grid_voice_select % NUM_VOICES + 1)
    end
  end
end

-- 8x16 grid layout (128 buttons vertical)
function grid_key_128v(x, y, z)
  if x >= 1 and x <= NUM_VOICES then
    -- Columns 1-7: Pattern triggers
    if y <= PATTERN_LENGTH then
      toggle_pattern_step(x, y)
    end
  elseif x == 8 then
    -- Column 8: Controls
    if y >= 1 and y <= NUM_VOICES then
      toggle_voice(y)
    elseif y == 9 then
      pattern_toggle()
    elseif y >= 10 and y <= 9 + NUM_VOICES then
      -- Voice selection for parameters
      select_grid_voice(y - 9)
    end
  end
end

-- 8x8 grid layout (64 buttons)
function grid_key_64(x, y, z)
  if y >= 1 and y <= NUM_VOICES then
    -- Rows 1-7: Pattern triggers (only steps 1-8 fit on this grid)
    toggle_pattern_step(y, x)
  elseif y == 8 then
    -- Row 8: Controls
    if x == 1 then
      pattern_toggle()
    elseif x >= 3 and x <= 7 then
      toggle_voice(x - 2)
    end
  end
end

function toggle_pattern_step(voice_idx, step)
  -- Bounds checking to prevent array expansion
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  if step < 1 or step > PATTERN_LENGTH then return end

  if S.patterns[voice_idx][step] == 0 then
    S.patterns[voice_idx][step] = 15  -- Full brightness
  else
    S.patterns[voice_idx][step] = 0
  end
end

function clear_pattern(voice_idx)
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  for step = 1, PATTERN_LENGTH do
    S.patterns[voice_idx][step] = 0
  end
end

function randomize_pattern(voice_idx)
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  for step = 1, PATTERN_LENGTH do
    if math.random() > 0.5 then
      S.patterns[voice_idx][step] = math.random(8, 15)
    else
      S.patterns[voice_idx][step] = 0
    end
  end
end

-- A buffer-sourced voice's first faders: its buffer params, then its level
-- and pan (voice_level_fader_keys; the other synthesis params do nothing
-- while the synth is off)
local BUFFER_FADER_KEYS = {"buf_pos", "buf_rate", "buf_scan"}
-- The six grain params (envelope shape and grain mode are option params,
-- shown as index faders)
local GRAIN_FADER_KEYS = {"grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_env", "grain_mode"}

local function append_fader_ids(ids, prefix, keys)
  for _, key in ipairs(keys) do
    table.insert(ids, prefix .. key)
  end
end

-- The synthesis params every source applies: level, and pan for the voices
-- that have it (sub has none). The engine pans buffer and input grains too.
function voice_level_fader_keys(voice_idx)
  local keys = {"amp"}
  if S.voices[voice_idx].params.pan ~= nil then table.insert(keys, "pan") end
  return keys
end

-- Ordered param IDs for the 256-grid fader page: the voice's synthesis
-- params (param_order), or BUFFER_FADER_KEYS and the level and pan for a
-- buffer source, then the grain params, then the nine crossmod slot values
-- (source, amp mod, freq mod for each slot). An input source has no buffer
-- params, and of its synth params only the level and pan do anything: its
-- faders start with the grain params, then the level and pan.
function fader_param_ids(voice_idx)
  local prefix = "v" .. voice_idx .. "_"
  local ids = {}
  if voice_uses_synth(voice_idx) then
    append_fader_ids(ids, prefix, S.voices[voice_idx].param_order)
    append_fader_ids(ids, prefix, GRAIN_FADER_KEYS)
  elseif voice_uses_buffer(voice_idx) then
    append_fader_ids(ids, prefix, BUFFER_FADER_KEYS)
    append_fader_ids(ids, prefix, voice_level_fader_keys(voice_idx))
    append_fader_ids(ids, prefix, GRAIN_FADER_KEYS)
  else
    append_fader_ids(ids, prefix, GRAIN_FADER_KEYS)
    append_fader_ids(ids, prefix, voice_level_fader_keys(voice_idx))
  end
  for slot = 1, NUM_MOD_SLOTS do
    table.insert(ids, prefix .. "mod_source_" .. slot)
    table.insert(ids, prefix .. "mod_amp_amt_" .. slot)
    table.insert(ids, prefix .. "mod_freq_amt_" .. slot)
  end
  return ids
end

function fader_page_count(voice_idx)
  return math.ceil(#fader_param_ids(voice_idx) / GRID_LAYOUT.fader_rows)
end

-- A fader whose range spans 0 (pan, buffer scan, the crossmod amounts) has
-- a zero column: the column nearest 0's place on the range, never an end
-- one. 16 columns have no center, so a plain sweep would give +/-0.07 for
-- pan there and never 0. nil for any other range.
function fader_zero_column(param_id)
  local minval, maxval = param_range(param_id)
  if not (minval < 0 and maxval > 0) then return nil end
  local last_column = GRID_LAYOUT.fader_width
  local column = util.round(param_value_fraction(param_id, 0) * (last_column - 1) + 1)
  return util.clamp(column, 2, last_column - 1)
end

-- The fraction of its range (in the warp's terms) column x (1-16) sets.
-- Columns sweep the range evenly; a fader with a zero column sweeps each
-- side of 0 evenly over its own columns instead, so column 1 is still the
-- minimum, the zero column 0 and column 16 the maximum.
function fader_column_fraction(param_id, x)
  local last_column = GRID_LAYOUT.fader_width
  local zero_column = fader_zero_column(param_id)
  if not zero_column then return (x - 1) / (last_column - 1) end
  local zero_fraction = param_value_fraction(param_id, 0)
  if x <= zero_column then
    return util.linlin(1, zero_column, 0, zero_fraction, x)
  end
  return util.linlin(zero_column, last_column, zero_fraction, 1, x)
end

-- Grid column x (1-16) sets a param across its range. Control params follow
-- their controlspec warp; number params (mod sources) and option params
-- (grain envelope, as an option index) map linearly to integers. A zero
-- column sets exactly 0.
function set_param_from_column(param_id, x)
  local spec = params:lookup_param(param_id).controlspec
  local value = 0
  if x ~= fader_zero_column(param_id) then
    local fraction = fader_column_fraction(param_id, x)
    if spec then
      value = spec:map(fraction)
    else
      local minval, maxval = param_range(param_id)
      value = util.round(util.linlin(0, 1, minval, maxval, fraction))
    end
  end
  params:set(param_id, value)
end

-- Column x on one of the parameter page's faders
function set_fader_param(voice_idx, fader_index, x)
  local param_id = fader_param_ids(voice_idx)[fader_index]
  if not param_id then return end
  set_param_from_column(param_id, x)
end

-- Grid column (1-16) that shows a fader param's current value: the inverse
-- of fader_column_fraction, so 0 shows at a zero column
function fader_position(param_id)
  local last_column = GRID_LAYOUT.fader_width
  local fraction = param_fraction(param_id)
  local zero_column = fader_zero_column(param_id)
  if not zero_column then
    return util.round(fraction * (last_column - 1) + 1)
  end
  local zero_fraction = param_value_fraction(param_id, 0)
  if fraction <= zero_fraction then
    return util.round(util.linlin(0, zero_fraction, 1, zero_column, fraction))
  end
  return util.round(util.linlin(zero_fraction, 1, zero_column, last_column, fraction))
end

function select_grid_voice(voice_idx)
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  S.grid_voice_select = voice_idx
  S.param_page = util.clamp(S.param_page, 1, fader_page_count(voice_idx))
end

function pattern_toggle()
  if pattern_playing then
    pattern_clock_stop()
  else
    pattern_clock_start()
  end
end

function pattern_clock_start()
  if pattern_clock then
    clock.cancel(pattern_clock)
  end

  pattern_playing = true
  pattern_position = 1

  pattern_clock = clock.run(function()
    while pattern_playing do
      -- Trigger voices that have active steps
      for voice_idx = 1, NUM_VOICES do
        if S.patterns[voice_idx][pattern_position] > 0 then
          if S.voices[voice_idx].active then
            -- Voice is already running: accent it in place, at the step's
            -- level (1-15) as velocity. A step must never create new synth
            -- nodes (toggling would stack whole voice/grain/mod chains
            -- through their long release tails).
            engine.retrigger(voice_idx - 1, S.patterns[voice_idx][pattern_position] / MAX_STEP_LEVEL)
          else
            -- Voice is off - turn it on
            toggle_voice(voice_idx)
          end
        end
      end

      -- Show the step that just played, then advance
      grid_redraw()
      pattern_position = pattern_position % PATTERN_LENGTH + 1

      -- Wait for next step based on tempo
      clock.sync(1/4)  -- 16th notes
    end
  end)
end

function pattern_clock_stop()
  pattern_playing = false
  if pattern_clock then
    clock.cancel(pattern_clock)
    pattern_clock = nil
  end
  grid_redraw()
end

-- LED level for a pattern step: its stored level, or at the playhead 15 for
-- an active step and 4 for an empty one
function step_brightness(voice_idx, step)
  local level = S.patterns[voice_idx][step]
  if pattern_playing and step == pattern_position then
    return level > 0 and 15 or 4
  end
  return level
end

function grid_redraw()
  if next(S.grids) == nil then return end  -- no grids: nothing to do

  for _, grid_port in pairs(S.grids) do
    if grid_port.device then
      local layout = grid_layout(grid_port)

      grid_port:all(0)

      if layout == "256" then
        grid_redraw_256(grid_port)
      elseif layout == "128h" then
        grid_redraw_128h(grid_port)
      elseif layout == "128v" then
        grid_redraw_128v(grid_port)
      elseif layout == "64" then
        grid_redraw_64(grid_port)
      end

      grid_port:refresh()
    end
  end
end

function grid_redraw_256(grid_device)
  if S.grid_page == 3 then
    -- Scene page
    -- Row 1: Scene recall (instant)
    for i = 1, NUM_SCENES do
      local brightness = S.scenes[i].populated and 8 or 2
      if S.current_scene == i then brightness = 15 end
      grid_device:led(i, 1, brightness)
    end

    -- Row 2: Scene recall (with transition)
    for i = 1, NUM_SCENES do
      local brightness = S.scenes[i].populated and 6 or 2
      grid_device:led(i, 2, brightness)
    end

    -- Row 3: Scene save
    for i = 1, NUM_SCENES do
      grid_device:led(i, 3, 4)
    end

    -- Row 5: Scene sequencer controls
    if S.scene_sequencer_enabled then
      grid_device:led(1, 5, 15)  -- Sequencer on
      -- Show next scene in sequence
      if S.scene_sequencer_position >= 1 and S.scene_sequencer_position <= NUM_SCENES then
        grid_device:led(S.scene_sequencer_position, 1, 15)
      end
    else
      grid_device:led(1, 5, 4)  -- Sequencer off
    end

    -- Sequence length indicators
    local seq_length = params:get("scene_sequence_length")
    for i = 1, NUM_SCENES do
      grid_device:led(i + 2, 5, i <= seq_length and 8 or 2)
    end

    grid_redraw_256_page_row(grid_device)
  elseif S.grid_page == 4 then
    -- BUFFER / FX page: buffer rows 1-2, FX faders on rows 3-7, voice
    -- sources on rows 9-15, rows 8 and 16 as on page 1
    grid_redraw_256_buffers(grid_device)
    for index, param_id in ipairs(GRID_LAYOUT.fx_fader_ids) do
      grid_redraw_fader_row(grid_device, GRID_LAYOUT.fx_first_row + index - 1, param_id)
    end
    grid_redraw_256_sources(grid_device)
    grid_redraw_256_transport(grid_device)
    grid_redraw_256_freeze(grid_device)
  else
    -- Patterns/parameters pages
    -- Draw patterns (rows 1-NUM_VOICES)
    for voice_idx = 1, NUM_VOICES do
      for step = 1, PATTERN_LENGTH do
        local brightness = step_brightness(voice_idx, step)
        grid_device:led(step, voice_idx, brightness)
      end
    end

    grid_redraw_256_transport(grid_device)

    -- Rows 9-13 (parameter page): faders and fader page selection
    if S.grid_page == 2 then
      grid_redraw_faders(grid_device)
    end

    -- Row 14: Voice status
    for i = 1, NUM_VOICES do
      grid_device:led(i, 14, i == S.grid_voice_select and 15 or 4)
      grid_device:led(i + 8, 14, S.voices[i].active and 12 or 2)
    end

    grid_redraw_256_freeze(grid_device)
  end
end

-- 256 page 4, rows 1-2: buffer state (15 recording, 8 loaded, 2 empty)
-- above each slot's clear key
function grid_redraw_256_buffers(grid_device)
  for slot = 1, NUM_BUFFERS do
    local buffer = S.buffers[slot]
    local level = 2
    if buffer.recording then
      level = 15
    elseif buffer.loaded then
      level = 8
    end
    grid_device:led(slot, GRID_LAYOUT.buffer_record_row, level)
    grid_device:led(slot, GRID_LAYOUT.buffer_clear_row, 4)
  end
end

-- 256 page 4, rows 9-15: each voice's source (selected 15, others 4, empty
-- buffers 2)
function grid_redraw_256_sources(grid_device)
  for voice_idx = 1, NUM_VOICES do
    local y = GRID_LAYOUT.source_first_row + voice_idx - 1
    for source = 1, #SOURCE_OPTIONS do
      local level = 4
      local slot = source - SOURCE_SYNTH
      if source == S.voices[voice_idx].source then
        level = 15
      elseif S.lib.buffers.valid_buffer_slot(slot) and not (S.buffers[slot].loaded or S.buffers[slot].recording) then
        level = 2
      end
      grid_device:led(source, y, level)
    end
  end
end

-- 256 row 8, columns 13-16: page indicators
function grid_redraw_256_page_row(grid_device)
  for i = 1, 4 do
    grid_device:led(12 + i, 8, i == S.grid_page and 15 or 2)
  end
end

-- 256 row 8: pattern controls, tempo and page indicators
function grid_redraw_256_transport(grid_device)
  -- columns 1-4 all act as play/stop
  for x = 1, 4 do
    grid_device:led(x, 8, pattern_playing and 15 or 4)
  end

  -- Tempo indicators
  grid_device:led(5, 8, 2)
  grid_device:led(6, 8, 2)
  grid_device:led(7, 8, 2)
  grid_device:led(8, 8, 2)

  grid_redraw_256_page_row(grid_device)
end

-- 256 row 16: freeze status
function grid_redraw_256_freeze(grid_device)
  for i = 1, NUM_VOICES do
    grid_device:led(i, 16, S.frozen[i] and 12 or 2)
  end
end

-- One fader on row y: a bar (brightness 8) up to the param's current value,
-- with the value's own column at 15
function grid_redraw_fader_row(grid_device, y, param_id)
  local position = fader_position(param_id)
  for x = 1, position - 1 do
    grid_device:led(x, y, 8)
  end
  grid_device:led(position, y, 15)
end

-- Fader rows 9-12 for the selected voice's fader page. Row 13 shows the
-- fader pages, selected at 15.
function grid_redraw_faders(grid_device)
  local ids = fader_param_ids(S.grid_voice_select)
  for row = 1, GRID_LAYOUT.fader_rows do
    local param_id = ids[(S.param_page - 1) * GRID_LAYOUT.fader_rows + row]
    if param_id then
      grid_redraw_fader_row(grid_device, GRID_LAYOUT.fader_first_row + row - 1, param_id)
    end
  end
  for page = 1, fader_page_count(S.grid_voice_select) do
    grid_device:led(page, GRID_LAYOUT.param_page_row, page == S.param_page and 15 or 4)
  end
end

function grid_redraw_128h(grid_device)
  if S.grid_page == 3 then
    -- Scene page (simplified for 128h layout)
    -- Row 1: Scene recall (instant)
    for i = 1, NUM_SCENES do
      local brightness = S.scenes[i].populated and 8 or 2
      if S.current_scene == i then brightness = 15 end
      grid_device:led(i, 1, brightness)
    end

    -- Row 2: Scene recall (with transition)
    for i = 1, NUM_SCENES do
      local brightness = S.scenes[i].populated and 6 or 2
      grid_device:led(i, 2, brightness)
    end

    -- Row 3: Scene save
    for i = 1, NUM_SCENES do
      grid_device:led(i, 3, 4)
    end

    -- Row 5: Scene sequencer controls
    if S.scene_sequencer_enabled then
      grid_device:led(1, 5, 15)  -- Sequencer on
    else
      grid_device:led(1, 5, 4)  -- Sequencer off
    end

    -- Sequence length indicators (simplified)
    local seq_length = params:get("scene_sequence_length")
    for i = 1, NUM_SCENES do
      grid_device:led(i, 4, i <= seq_length and 8 or 2)
    end
  else
    -- Pattern/parameter pages
    -- Draw patterns (rows 1-NUM_VOICES)
    for voice_idx = 1, NUM_VOICES do
      for step = 1, PATTERN_LENGTH do
        local brightness = step_brightness(voice_idx, step)
        grid_device:led(step, voice_idx, brightness)
      end
    end
  end

  -- Row 8: Controls (always visible)
  -- columns 1-4 all act as play/stop
  for x = 1, 4 do
    grid_device:led(x, 8, pattern_playing and 15 or 4)
  end

  -- Page indicators (3 pages now)
  grid_device:led(5, 8, S.grid_page == 1 and 15 or 4)
  grid_device:led(6, 8, S.grid_page == 2 and 15 or 4)
  grid_device:led(7, 8, S.grid_page == 3 and 15 or 4)

  -- Voice status
  for i = 1, NUM_VOICES do
    grid_device:led(i + 8, 8, S.voices[i].active and 12 or 2)
  end

  -- Voice selection indicator
  grid_device:led(16, 8, 8)
end

function grid_redraw_128v(grid_device)
  -- Draw patterns (columns 1-NUM_VOICES)
  for voice_idx = 1, NUM_VOICES do
    for step = 1, PATTERN_LENGTH do
      local brightness = step_brightness(voice_idx, step)
      grid_device:led(voice_idx, step, brightness)
    end
  end

  -- Column 8: Controls
  for i = 1, NUM_VOICES do
    grid_device:led(8, i, S.voices[i].active and 12 or 4)
  end
  grid_device:led(8, 9, pattern_playing and 15 or 4)

  -- Voice selection
  for i = 1, NUM_VOICES do
    grid_device:led(8, 9 + i, (i == S.grid_voice_select) and 15 or 2)
  end
end

function grid_redraw_64(grid_device)
  -- Draw patterns (rows 1-7). Only the first 8 steps of each 16-step
  -- pattern fit; the sequencer still plays all PATTERN_LENGTH steps.
  local visible_steps = math.min(PATTERN_LENGTH, grid_device.cols)
  for voice_idx = 1, NUM_VOICES do
    for step = 1, visible_steps do
      local brightness = step_brightness(voice_idx, step)
      grid_device:led(step, voice_idx, brightness)
    end
  end

  -- Row 8: Controls
  grid_device:led(1, 8, pattern_playing and 15 or 4)
  for i = 1, 5 do
    grid_device:led(i + 2, 8, S.voices[i].active and 12 or 4)
  end
end

function cleanup()
  restore_tempo_change_handler()

  -- Give the norns menu its own set_mode back first, before anything below
  -- can fail
  unwatch_menu_opening()

  -- Save scenes to disk before exiting, unless that would overwrite a scenes
  -- file that failed to load and could not be moved aside
  if S.scene_autosave_blocked then
    print("scenes not auto-saved: " .. S.lib.scenes.scene_data_file .. " could not be loaded")
  else
    save_scenes_to_disk()
  end

  -- Remember each buffer's file or scratch take for the next start
  if S.buffer_autosave_blocked then
    print("buffer paths not auto-saved: " .. S.lib.buffers.buffer_data_file() .. " could not be loaded")
  else
    save_buffers_to_disk()
  end

  -- Stop metros and clocks
  cancel_startup_clock()
  stop_frame_clock()
  if S.drift_metro then S.drift_metro:stop() end

  -- Sync mutation metro state with param
  if S.mutation_metro then
    S.mutation_metro:stop()
    -- Ensure param matches actual state
    params:set("mutation_enabled", 0)
  end

  pattern_clock_stop()

  -- Stop the scene sequencer through its param so param and state agree
  params:set("scene_sequencer_enabled", 0)
  scene_sequencer_stop()

  -- Cancel any active transition clock
  cancel_scene_transition()

  -- Stop the LFOs (through their state params, like the library's menu) and
  -- give their destinations back their stored values
  for n = 1, NUM_LFOS do
    S.lfos[n]:stop()
    params:set("lfo_" .. n, 1)
    restore_lfo_destination(n)
  end

  -- Stop the buffer polls and recording timers (the engine finishes or
  -- frees any recording itself)
  if S.buffer_polls.state then S.buffer_polls.state:stop() end
  if S.buffer_polls.load_failed then S.buffer_polls.load_failed:stop() end
  for slot = 1, NUM_BUFFERS do
    S.lib.buffers.cancel_buffer_recording_timer(slot)
  end
  cancel_buffer_page_flash_clock()

  -- Stop listening to MIDI before the voices go off
  if S.midi_device then S.midi_device.event = nil end

  -- Turn off all voices
  for i = 1, NUM_VOICES do
    if S.voices[i].active then
      engine.voiceOff(i - 1)
    end
  end

  -- Leave connected controllers dark
  for _, grid_port in pairs(S.grids) do
    grid_port:all(0)
    grid_port:refresh()
  end
  if arc_device then
    arc_device:all(0)
    arc_device:refresh()
  end
end
