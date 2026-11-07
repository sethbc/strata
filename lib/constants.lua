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
-- test asserts, so the widest entry, "+ pulse [F]", ends well left of the
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
  pattern_clock = 90,       -- lib/sequencer.lua
  scene_sequencer = 100,    -- lib/scenes.lua (and its param)
  scene_transition = 110,   -- lib/scenes.lua
  lfos = 120,               -- lib/lfos.lua: stopped, destinations restored
  buffer_polls = 130,       -- lib/buffers.lua: the polls and recording timers
  buffer_page_flash = 140,  -- lib/pages/buffer.lua: the hint row's flash clock
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
  DISCRETE_GRAIN_KEYS = DISCRETE_GRAIN_KEYS,
  BUFFER_MUTATION_KEYS = BUFFER_MUTATION_KEYS,
  GRAIN_PARAM_IDS = GRAIN_PARAM_IDS,
  MAIN_PARAMS = MAIN_PARAMS,
  BUFFER_MAIN_PARAM = BUFFER_MAIN_PARAM,
  INPUT_MAIN_PARAM = INPUT_MAIN_PARAM,
  CLEANUP_ORDER = CLEANUP_ORDER,
}
