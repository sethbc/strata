-- lib/constants.lua
-- The script's constants and fixed tables, as a plain table (the one module
-- that is not a constructor). strata.lua runs
-- `S.constants = include("lib/constants")`, and each module aliases the
-- names it uses as locals. lib/ui/frame.lua adds the frame and draw state
-- to UI_PAGES at run time

local NUM_VOICES = 7
local NUM_SCENES = 8
local PATTERN_LENGTH = 16
local SCENE_DATA_VERSION = 2  -- Scene file format version (written into scenes.data)
local NUM_MOD_SLOTS = 3       -- Cross-modulation slots per voice
local E1_TICKS_PER_PAGE = 4  -- E1 encoder sensitivity (norns.enc.sens)
local LONG_PRESS_SECONDS = 0.6  -- K2/K3 hold for the ALT long-press fallback (lib/ui/alt.lua; unused while K1 is ALT)
local MAX_STEP_LEVEL = 15     -- Pattern step levels are 0 (off) to 15; level / 15 = retrigger velocity
local NUM_BUFFERS = 8         -- Sample buffer slots (engine numBuffers)
local BUFFER_SECONDS = 16     -- Length of each buffer slot (engine bufferSeconds)
local BUFFER_DATA_VERSION = 1 -- Buffer paths file format version (written into buffers.data)
local NUM_LFOS = 3            -- Global LFOs (norns lib/lfo.lua)

-- Grain envelope shapes (v<i>_grain_env option order). Option n is sent to
-- the engine as envShape n - 1: 0 = GrainIn's built-in Hann, 1-4 = the
-- engine's envelope buffers
local GRAIN_ENV_OPTIONS = {"hann", "sine", "perc", "linen", "trap"}

-- Grain modes (v<i>_grain_mode option order), sent as grainMode n - 1:
-- 0 = continuous (grain density grains per second), 1 = triggered (one grain
-- per retrigger: pattern steps and MIDI notes)
local GRAIN_MODE_OPTIONS = {"continuous", "triggered"}

-- Grain sources (v<i>_source option order): the voice's own synth, buffer
-- slots 1..NUM_BUFFERS, then the live input. Option n is sent to the engine
-- as setGrainSource n - 1 (0 = synth, 1-8 = buffer slot, 9 = input).
local SOURCE_SYNTH = 1
local SOURCE_INPUT = NUM_BUFFERS + 2
local SOURCE_OPTIONS = {"synth"}
for slot = 1, NUM_BUFFERS do
  SOURCE_OPTIONS[slot + 1] = "buf " .. slot
end
SOURCE_OPTIONS[SOURCE_INPUT] = "input"

-- The screen pages in E1 order. Each lib/pages/<page>.lua registers its
-- record at S.registry.pages[UI_PAGES.index.<PAGE>]
local UI_PAGES = {"MAIN", "VOICE", "SEQ", "FX", "LFO", "BUFFER", "SCENES", "SETUP"}
local NUM_UI_PAGES = #UI_PAGES  -- Screen pages, selected with E1 (8)
UI_PAGES.index = {}  -- page name -> its index (UI_PAGES.index.FX == 4)
for index, name in ipairs(UI_PAGES) do UI_PAGES.index[name] = index end
UI_PAGES.MAIN_PAGE = UI_PAGES.index.MAIN  -- 1 (arc_key tests the page by index, not by its title)
-- Arc pages follow the screen pages. Every continuous arc ring sweeps its
-- param's whole range in this many ticks: half a turn of the arc's 1024
-- ticks per revolution (monome arc spec; matron passes the deltas through)
UI_PAGES.ARC_TICKS_PER_SWEEP = 512
UI_PAGES.ARC_PORT = 1   -- preferred arc vport (arc.connect's default)
UI_PAGES.ARC_PORTS = 4  -- norns has four arc vports
-- norns' Arc:segment reduces angles modulo 2*pi, so a full turn lights nothing;
-- a ring's fill ends just below it (the margin is far below one LED's 2*pi/64)
UI_PAGES.ARC_FULL_TURN_MARGIN = 1e-6

-- The header every page shares (lib/ui/header.lua, y 8): the eight 2x2 px
-- page dots from dots_x, dot_spacing apart (the current page's at
-- current_dot_level, the rest at dot_level), [M] at mutation_x, the play
-- mark (a filled 3x5 triangle, top row play_y) at play_x, REC at rec_x and
-- the scene right-aligned at scene_right. A page's header_status text
-- replaces the three indicators: the text at status_x, the play mark at
-- status_play_x. A header flash (lib/ui/flash.lua) replaces the dots and
-- indicators for flash_seconds, its text at flash_x cut to flash_width px,
-- so it ends before a right-aligned S8. (The 3.1 design's x 80/94/100 put
-- REC over S8 under the layout test's width estimate; these keep the same
-- order and spacing and fit.)
local HEADER = {dots_x = 40, dot_spacing = 4, dot_size = 2, dot_level = 3, current_dot_level = 15,
  dot_y = 4, mutation_x = 76, play_x = 90, play_y = 3, rec_x = 96, scene_right = 127, status_x = 79,
  status_play_x = 74, flash_x = 40, flash_width = 74, flash_seconds = 1.5}

-- The params the SCENES page lists after the eight slots: its cursor's stops
-- NUM_SCENES + 1 .. NUM_SCENES + #SCENES_FIELDS (9-12; lib/ui/cursors.lua)
local SCENES_FIELDS = {"scene_transition_time", "scene_sequencer_enabled", "scene_sequence_length", "scene_duration"}

-- voices[i].grain keys holding an option index rather than a continuous
-- value, mapped to their option count: smooth transitions switch them at the
-- end instead of crossfading, mutation never touches them, and scenes must
-- store integers from 1 to the option count
local DISCRETE_GRAIN_KEYS = {
  env = #GRAIN_ENV_OPTIONS,
  mode = #GRAIN_MODE_OPTIONS
}

-- voices[i].grain keys gentle_mutate changes for buffer-sourced voices
local BUFFER_MUTATION_KEYS = {"buf_pos", "buf_rate", "buf_scan"}

-- voices[i].grain keys -> param id suffixes
local GRAIN_PARAM_IDS = {
  size = "grain_size",
  density = "grain_density",
  pitch = "grain_pitch",
  spread = "grain_spread",
  env = "grain_env",
  mode = "grain_mode",
  buf_pos = "buf_pos",
  buf_rate = "buf_rate",
  buf_scan = "buf_scan"
}

-- Per voice type, on MAIN: the synthesis param E3 and arc ring 2 adjust
-- (param id suffix, screen label and screen value format; the arc ring sweeps
-- the param's range in UI_PAGES.ARC_TICKS_PER_SWEEP ticks, like every ring),
-- and the short name the voice list shows (at most 5 characters, which a
-- test asserts, so the widest entry, "+ pulse [L]", ends well left of the
-- divider at x 62)
local MAIN_PARAMS = {
  resonator = {key = "freq", label = "freq", format = "%.0f Hz", list_name = "reso"},
  fm = {key = "index", label = "index", format = "%.1f", list_name = "fm"},
  folder = {key = "fold", label = "fold", format = "%.1f", list_name = "fold"},
  sub = {key = "drift", label = "drift", format = "%.3f", list_name = "sub"},
  pulse = {key = "width", label = "width", format = "%.2f", list_name = "pulse"},
  karplus = {key = "decay", label = "decay", format = "%.1f s", list_name = "karp"},
  ring = {key = "ratio", label = "ratio", format = "%.2f", list_name = "ring"}
}

-- A buffer-sourced voice shows and adjusts its buffer position instead; an
-- input-sourced voice its grain size (its synth and buffer params do nothing)
local BUFFER_MAIN_PARAM = {key = "buf_pos", label = "pos", format = "%.2f"}
local INPUT_MAIN_PARAM = {key = "grain_size", label = "size", format = "%.2f s"}

-- init()'s start steps in the order it runs them, after the params are
-- added and their actions wrapped: each module registers its own with
-- S.register_start(START_ORDER.<step>, fn) (lib/state.lua). The UI first,
-- then the metros and polls, the controllers and MIDI, the files (the
-- scenes before the buffers, which they may use), and the clocks last.
-- Spaced by 10, so a new step can go between two others
local START_ORDER = {
  voice_list = 10,       -- lib/pages/main.lua: MAIN's voice list
  e1_settings = 20,      -- strata.lua: E1 steps pages (no acceleration)
  menu_watch = 30,       -- lib/ui/menu_watch.lua: forget held keys as the menu opens
  drift_metro = 40,      -- lib/mutation.lua: created and started
  mutation_metro = 50,   -- lib/mutation.lua: created; its param starts it
  buffer_polls = 60,     -- lib/buffers.lua: bufferState and bufferLoadFailed
  arc = 70,              -- lib/arc/core.lua
  grids = 80,            -- lib/grid/core.lua
  midi = 90,             -- lib/midi_in.lua
  scenes_load = 100,     -- lib/scenes.lua: scenes.data (sets S.scenes_loaded)
  buffers_load = 110,    -- lib/buffers.lua: buffers.data (sets S.buffers_loaded)
  startup_clock = 120,   -- strata.lua: voices 1 and 2
  frame_clock = 130,     -- lib/ui/frame.lua
}

-- How long a randomize can be undone (lib/mutation.lua, S.undo)
local UNDO_SECONDS = 5

-- Center detents (lib/ui/detent.lua): a param whose range spans 0 holds at
-- 0 for the next encoder_detents encoder detents after reaching or crossing
-- it, or the next arc_ticks arc ticks
local DETENT = {encoder_detents = 3, arc_ticks = 24}

-- ALT+E3 fine adjustment: a control param moves 1 / FINE_DIVISOR of its raw
-- step per detent (lib/ui/detent.lua)
local FINE_DIVISOR = 10

-- cleanup()'s steps in the order it runs them: each module registers its
-- own with S.register_cleanup(CLEANUP_ORDER.<step>, fn) (lib/state.lua).
-- The files are saved before anything stops, with the stored values (the
-- LFOs, stopped later, restore their destinations then), MIDI is detached
-- before the voices go off, and the controllers go dark last. Spaced by 10, so a new step can go
-- between two others
local CLEANUP_ORDER = {
  tempo_handler = 10,       -- lib/params_setup.lua: the clock's tempo handler back
  menu_watch = 20,          -- lib/ui/menu_watch.lua: the norns menu's set_mode back
  scenes_save = 30,         -- lib/scenes.lua: scenes.data
  buffer_paths_save = 40,   -- lib/buffers.lua: buffers.data
  startup_clock = 50,       -- strata.lua: init's start-up clock
  frame_clock = 60,         -- lib/ui/frame.lua
  drift_metro = 70,         -- lib/mutation.lua
  mutation_metro = 80,      -- lib/mutation.lua (and its param)
  undo_clock = 85,          -- lib/mutation.lua: the randomize undo's expiry clock
  pattern_clock = 90,       -- lib/sequencer.lua
  scene_sequencer = 100,    -- lib/scenes.lua (and its param)
  scene_transition = 110,   -- lib/scenes.lua
  lfos = 120,               -- lib/lfos.lua: stopped, destinations restored
  buffer_polls = 130,       -- lib/buffers.lua: the polls and recording timers
  ui_flash = 140,           -- lib/ui/flash.lua: the header's and hint row's flash clocks
  midi_handler = 150,       -- lib/midi_in.lua
  voices_off = 160,         -- lib/engine_sync.lua
  grids_dark = 170,         -- lib/grid/core.lua
  arc_dark = 180,           -- lib/arc/core.lua
}

return {
  NUM_VOICES = NUM_VOICES,
  NUM_SCENES = NUM_SCENES,
  PATTERN_LENGTH = PATTERN_LENGTH,
  SCENE_DATA_VERSION = SCENE_DATA_VERSION,
  NUM_MOD_SLOTS = NUM_MOD_SLOTS,
  NUM_UI_PAGES = NUM_UI_PAGES,
  E1_TICKS_PER_PAGE = E1_TICKS_PER_PAGE,
  LONG_PRESS_SECONDS = LONG_PRESS_SECONDS,
  MAX_STEP_LEVEL = MAX_STEP_LEVEL,
  NUM_BUFFERS = NUM_BUFFERS,
  BUFFER_SECONDS = BUFFER_SECONDS,
  BUFFER_DATA_VERSION = BUFFER_DATA_VERSION,
  NUM_LFOS = NUM_LFOS,
  GRAIN_ENV_OPTIONS = GRAIN_ENV_OPTIONS,
  GRAIN_MODE_OPTIONS = GRAIN_MODE_OPTIONS,
  SOURCE_SYNTH = SOURCE_SYNTH,
  SOURCE_INPUT = SOURCE_INPUT,
  SOURCE_OPTIONS = SOURCE_OPTIONS,
  UI_PAGES = UI_PAGES,
  HEADER = HEADER,
  SCENES_FIELDS = SCENES_FIELDS,
  DISCRETE_GRAIN_KEYS = DISCRETE_GRAIN_KEYS,
  BUFFER_MUTATION_KEYS = BUFFER_MUTATION_KEYS,
  GRAIN_PARAM_IDS = GRAIN_PARAM_IDS,
  MAIN_PARAMS = MAIN_PARAMS,
  BUFFER_MAIN_PARAM = BUFFER_MAIN_PARAM,
  INPUT_MAIN_PARAM = INPUT_MAIN_PARAM,
  START_ORDER = START_ORDER,
  UNDO_SECONDS = UNDO_SECONDS,
  DETENT = DETENT,
  FINE_DIVISOR = FINE_DIVISOR,
  CLEANUP_ORDER = CLEANUP_ORDER,
}
