-- lib/constants.lua
-- The script's constants and fixed tables, as a plain table (the one module
-- that is not a constructor). strata.lua runs
-- `S.constants = include("lib/constants")`, and each module aliases the
-- names it uses as locals. lib/ui/frame.lua adds the frame and draw state
-- to UI_PAGES at run time

local NUM_VOICES = 7
local NUM_SCENES = 16  -- Scene slots, in two banks of SCENE_BANK_SIZE (3.4)
local PATTERN_LENGTH = 16
local SCENE_DATA_VERSION = 6  -- Scene file format version (written into scenes.data)
local PSET_FORMAT = 2         -- PSET format, saved in every PSET as the hidden strata_pset_format (none: 1)
-- The Pulse voice's res rises with resonance from scene format 5 and PSET
-- format 2 (3.3, #314): the engine plays the filter's rq as mirror - res
-- (StrataVoiceDefs.sc). A scene or PSET of an older format holds the rq
-- itself, so its res is mirrored as it loads (res' = mirror - res) and
-- sounds the same: 0.1-1 maps onto 1-0.1, on the param's 0.01 grid
local PULSE_RES = {mirror = 1.1, scene_format = 5, pset_format = 2}
local NUM_MOD_SLOTS = 3       -- Cross-modulation slots per voice
local E1_TICKS_PER_PAGE = 4  -- E1 encoder sensitivity (norns.enc.sens)
local MAX_STEP_LEVEL = 15     -- Pattern step levels are 0 (off) to 15; level / 15 = retrigger velocity
local NUM_BUFFERS = 8         -- Sample buffer slots (engine numBuffers)
local STANDARD_BUFFER_SECONDS = 16  -- Length of each buffer slot on the standard tier (engine standardBufferSeconds)
local BUFFER_DATA_VERSION = 2 -- Buffer paths file format version (written into buffers.data)
local NUM_LFOS = 6            -- Global LFOs (lib/lfos.lua; engine numFastLfos)
local NUM_BOOKMARKS = 4       -- Bookmarks per voice (3.3)
local NORNS_SAMPLE_RATE = 48000  -- norns' server rate (JACK, scsynth), the one copy (#516): a slot's frames, a file's seconds in it

-- Record sources (3.3's record_source option order): the live input, the
-- master before and after its effects, then each voice
local RECORD_SOURCES = {"input", "pre-master", "post-master"}
for voice = 1, NUM_VOICES do
  RECORD_SOURCES[#RECORD_SOURCES + 1] = "voice " .. voice
end
-- Synced recording: bars of beats_per_bar beats, started lead_seconds early
local RECORD_SYNC = {beats_per_bar = 4, lead_seconds = 0.25}
local FILES = {restart_seconds = 0.3}       -- lib/files.lua
local WAVEFORMS = {refresh_seconds = 2}   -- lib/waveforms.lua (the engine's peakWriteSeconds, #523)
local PLAYHEADS = {update_hz = 15}          -- lib/playheads.lua
-- The arc scrub's friction glide (lib/positions.lua): ring 1 idle for
-- release_seconds starts a glide at the speed over the last window_seconds,
-- which decays with tau = max_glide_seconds x (1 - friction) and ends below
-- stop_rate (loop fractions a second)
local SCRUB = {release_seconds = 0.08, window_seconds = 0.1, max_glide_seconds = 4, stop_rate = 0.001}

-- The standard performance tier's values. S.performance starts as a copy
-- (lib/params_setup.lua); lib/performance.lua fills it at init, before
-- any param is added. Every tier-dependent spec reads S.performance
-- (record duration, history range), never these
local STANDARD_PERFORMANCE = {tier = "standard", buffer_seconds = STANDARD_BUFFER_SECONDS, max_grains = 128,
  history_seconds = 16}

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
local UI_PAGES = {"MAIN", "VOICE", "SEQ", "FX", "LFO", "MOD", "BUFFER", "SCENES", "SETUP"}
local NUM_UI_PAGES = #UI_PAGES  -- Screen pages, selected with E1 (9)
UI_PAGES.index = {}  -- page name -> its index (UI_PAGES.index.FX == 4)
for index, name in ipairs(UI_PAGES) do UI_PAGES.index[name] = index end
-- Arc pages follow the screen pages. Every continuous arc ring sweeps its
-- param's whole range in this many ticks: a full turn of the arc's 1024
-- ticks per revolution (monome arc spec; matron passes the deltas through),
-- so the lit fill follows the hand (#552; 512 was too fast)
UI_PAGES.ARC_TICKS_PER_SWEEP = 1024
UI_PAGES.ARC_PORT = 1   -- preferred arc vport (arc.connect's default)
UI_PAGES.ARC_PORTS = 4  -- norns has four arc vports
-- norns' Arc:segment reduces angles modulo 2*pi, so a full turn lights nothing;
-- a ring's fill ends just below it (the margin is far below one LED's 2*pi/64)
UI_PAGES.ARC_FULL_TURN_MARGIN = 1e-6

-- The header every page shares (lib/ui/header.lua, y 8): one 2x2 px page
-- dot per page (nine) from dots_x, dot_spacing apart (the current page's at
-- current_dot_level, the rest at dot_level), [M] at mutation_x, the play
-- mark (a filled 3x5 triangle, top row play_y) at play_x, REC at rec_x and
-- the scene right-aligned at scene_right. A page's header_status text
-- replaces the three indicators: the text at status_x, the play mark at
-- status_play_x. A header flash (lib/ui/flash.lua) replaces the dots and
-- indicators for flash_seconds, its text at flash_x cut to flash_width px,
-- so it ends before a right-aligned S16. (The 3.1 design's x 80/94/100 put
-- REC over S8 under the layout test's width estimate; these keep the same
-- order and spacing and fit. 3.4 moves the dots 4 px left, so a ninth
-- clears status_play_x.)
local HEADER = {dots_x = 36, dot_spacing = 4, dot_size = 2, dot_level = 3, current_dot_level = 15,
  dot_y = 4, mutation_x = 76, play_x = 90, play_y = 3, rec_x = 96, scene_right = 127, status_x = 79,
  status_play_x = 73, flash_x = 40, flash_width = 74, flash_seconds = 1.5}

-- The params the SCENES page lists after the sixteen slots: its cursor's
-- stops NUM_SCENES + 1 .. NUM_SCENES + #SCENES_FIELDS (17-20;
-- lib/ui/cursors.lua)
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

-- Grid holds (lib/grid/core.lua): a scene save key must be held this long
-- to save; the 64's half toggle (column 1) switches halves after this hold;
-- a step key held step_edit_seconds opens 3.4's step editor
local GRID_HOLD = {scene_save_seconds = 0.5, half_toggle_seconds = 0.5, step_edit_seconds = 0.3}

-- The grid pages, numbered alike on every layout (#451: the 64 shows 1 and
-- 5), and the cells of a voice's position row on every layout
local GRID_PAGES = {patterns = 1, faders = 2, scenes = 3, sources = 4, positions = 5, count = 5,
  position_cells = 16}

-- The key levels every grid layout shares (#526; lib/grid/core.lua reads
-- them): a voice's on/off key (running, stopped), a page key (shown,
-- other), a pick key (the grid voice or the fader page shown, the others),
-- a lock key and the play keys
local GRID_LEVELS = {voice_running = 12, voice_stopped = 2, page_shown = 15, page_other = 2,
  picked = 15, unpicked = 4, locked = 12, unlocked = 2, playing = 15, stopped = 4}

-- init()'s start steps in the order it runs them, after the params are
-- added and their actions wrapped: each module registers its own with
-- S.register_start(START_ORDER.<step>, fn) (lib/state.lua). The UI first,
-- then the metros and polls, the controllers and MIDI, the files (the
-- scenes before the buffers, which they may use), and the clocks last.
-- Spaced by 10, so a new step can go between two others
local START_ORDER = {
  started = 5,           -- lib/ui/frame.lua: S.started (redraw, key and enc act from here on)
  voice_list = 10,       -- lib/pages/main.lua: MAIN's voice list
  voice_layout_states = 15,  -- lib/pages/voice.lua: the registered voice params' layout states
  e1_settings = 20,      -- strata.lua: E1 steps pages (no acceleration)
  menu_watch = 30,       -- lib/ui/menu_watch.lua: forget held keys as the menu opens
  drift_metro = 40,      -- lib/mutation.lua: created and started
  mutation_metro = 50,   -- lib/mutation.lua: created; its param starts it
  buffer_polls = 60,     -- lib/buffers.lua: bufferState, bufferLoadFailed and bufferSaveResult
  input_level = 62,      -- lib/input_level.lua: the input level polls (3.4)
  record_poll = 65,      -- lib/record.lua: the recordState poll
  arc = 70,              -- lib/arc/core.lua
  grids = 80,            -- lib/grid/core.lua
  midi = 90,             -- lib/midi_in.lua (and the MIDI map's repair)
  scenes_load = 100,     -- lib/scenes.lua: the registered scene fields, then scenes.data (sets S.scenes_loaded)
  macros_load = 105,     -- lib/macros.lua: macros.data (3.4)
  gestures_load = 107,   -- lib/gestures.lua: gestures.data (3.4)
  matrix_load = 108,     -- lib/matrix.lua: matrix.data (3.4)
  notes_load = 109,      -- lib/notes.lua: notes.data, the note pool (3.5)
  buffers_load = 110,    -- lib/buffers.lua: buffers.data (sets S.buffers_loaded)
  startup_clock = 120,   -- strata.lua: voices 1 and 2
  lfo_clock = 125,       -- lib/lfos.lua: the LFO clock (3.4)
  frame_clock = 130,     -- lib/ui/frame.lua
  waveforms = 140,       -- lib/waveforms.lua: the peaks read loop
  playheads = 150,       -- lib/playheads.lua: the playhead clock
  pattern_transport = 160,  -- lib/sequencer.lua: the clock's transport start and stop handlers
}

-- How long a randomize can be undone (lib/mutation.lua, S.undo)
local UNDO_SECONDS = 5

-- A randomizing page's ALT+K2 acts on release (lib/ui/alt.lua, k2_up): a
-- press released within ALT_HOLD_SECONDS randomizes or undoes, a longer one
-- runs the page's hold action
local ALT_HOLD_SECONDS = 0.5

-- Center detents (lib/ui/detent.lua): a param whose range spans 0 holds at
-- 0 for the next encoder_detents encoder detents after reaching or crossing
-- it, or the next arc_ticks arc ticks, within hold_seconds of reaching it
local DETENT = {encoder_detents = 3, arc_ticks = 24, hold_seconds = 1}

-- ALT+E3 fine adjustment: a control param moves 1 / FINE_DIVISOR of its raw
-- step per detent (lib/ui/detent.lua)
local FINE_DIVISOR = 10

-- cleanup()'s steps in the order it runs them: each module registers its
-- own with S.register_cleanup(CLEANUP_ORDER.<step>, fn) (lib/state.lua).
-- The files are saved before anything stops, with the stored values (the
-- LFOs, stopped later, restore their destinations then), MIDI is detached
-- before the voiceOff step, and the controllers go dark last. norns frees
-- the engine before it calls cleanup() (#461), so no engine command a step
-- sends arrives: the voices have already stopped with the engine. Spaced by
-- 10, so a new step can go between two others
local CLEANUP_ORDER = {
  tempo_handler = 10,       -- lib/params_setup.lua: the clock's tempo handler back
  menu_watch = 20,          -- lib/ui/menu_watch.lua: the norns menu's set_mode back
  scenes_save = 30,         -- lib/scenes.lua: scenes.data
  macros_save = 32,         -- lib/macros.lua: macros.data (3.4)
  gestures_save = 34,       -- lib/gestures.lua: gestures.data (3.4)
  matrix_save = 36,         -- lib/matrix.lua: matrix.data (3.4)
  buffer_paths_save = 40,   -- lib/buffers.lua: buffers.data
  startup_clock = 50,       -- strata.lua: init's start-up clock
  frame_clock = 60,         -- lib/ui/frame.lua
  drift_metro = 70,         -- lib/mutation.lua
  mutation_metro = 80,      -- lib/mutation.lua (and its param)
  undo_clock = 85,          -- lib/mutation.lua: the randomize undo's expiry clock
  pattern_clock = 90,       -- lib/sequencer.lua
  gestures = 95,            -- lib/gestures.lua: the recorders' clocks (3.4)
  quantize = 97,            -- lib/quantize.lua: the waiting actions (3.4)
  scene_sequencer = 100,    -- lib/scenes.lua (and its param)
  scene_transition = 110,   -- lib/scenes.lua
  morph_clock = 112,        -- lib/morph.lua (3.4)
  macros = 114,             -- lib/macros.lua: the apply clock (3.4)
  zones_learn = 117,        -- lib/ui/zones.lua: the zones editor's learn timeout clock (3.5)
  matrix = 118,             -- lib/matrix.lua: matrix learn's timeout clock (3.4)
  notes = 119,              -- lib/notes.lua: the expression flush ends (3.5)
  lfos = 120,               -- lib/lfos.lua: stopped, destinations restored
  playheads = 122,          -- lib/playheads.lua: the playhead clock
  scrub_glide = 124,        -- lib/positions.lua: the scrub glides and the scan holds
  waveforms = 126,          -- lib/waveforms.lua: the peaks read loop
  engine_budget = 127,      -- lib/engine_sync.lua: the deferred sends' flush clock (3.4)
  buffer_start_reload = 128,  -- lib/buffers.lua: a long file's pending start reload
  buffer_polls = 130,       -- lib/buffers.lua: the polls and recording timers
  record = 132,             -- lib/record.lua: the recordState poll
  input_meter = 135,        -- lib/input_level.lua: the input level polls
  ui_flash = 140,           -- lib/ui/flash.lua: the header's and hint row's flash clocks
  midi_handler = 150,       -- lib/midi_in.lua
  voices_off = 160,         -- lib/engine_sync.lua: a voiceOff per running voice (reaches no handler on norns)
  grids_dark = 170,         -- lib/grid/core.lua
  arc_dark = 180,           -- lib/arc/core.lua
}

return {
  NUM_VOICES = NUM_VOICES,
  NUM_SCENES = NUM_SCENES,
  PATTERN_LENGTH = PATTERN_LENGTH,
  SCENE_DATA_VERSION = SCENE_DATA_VERSION,
  PSET_FORMAT = PSET_FORMAT,
  PULSE_RES = PULSE_RES,
  NUM_MOD_SLOTS = NUM_MOD_SLOTS,
  NUM_UI_PAGES = NUM_UI_PAGES,
  E1_TICKS_PER_PAGE = E1_TICKS_PER_PAGE,
  MAX_STEP_LEVEL = MAX_STEP_LEVEL,
  NUM_BUFFERS = NUM_BUFFERS,
  STANDARD_BUFFER_SECONDS = STANDARD_BUFFER_SECONDS,
  STANDARD_PERFORMANCE = STANDARD_PERFORMANCE,
  BUFFER_DATA_VERSION = BUFFER_DATA_VERSION,
  NUM_LFOS = NUM_LFOS,
  NUM_BOOKMARKS = NUM_BOOKMARKS,
  NORNS_SAMPLE_RATE = NORNS_SAMPLE_RATE,
  RECORD_SOURCES = RECORD_SOURCES,
  RECORD_SYNC = RECORD_SYNC,
  FILES = FILES,
  WAVEFORMS = WAVEFORMS,
  PLAYHEADS = PLAYHEADS,
  SCRUB = SCRUB,
  WAVEFORM_POINTS = 64,  -- Points of a slot's peak curve (engine waveformPoints)
  NUM_FAST_DESTINATIONS = 5,  -- Engine fast-modulation destinations per voice: pitch, position, size, cutoff, amp (engine numFastDestinations)
  FAST_MOD_NOTE_SLOTS = 1,    -- Fast-modulation note slots per voice: setFastOffset's 0..FAST_MOD_NOTE_SLOTS - 1 (engine fastModNoteSlots; 3.5 keeps 1: per-note values are controls on the note's own synth)
  NOTE_SLOTS = 8,  -- Notes per voice: slot 1 the voice's own, 2-8 from the pool (engine noteSlots)
  NOTE_POOL = {max = 16, standard = 4, high = 8},  -- Extra notes all voices share: the checked maximum (engine notePoolMax) and each tier's default
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
  GRID_HOLD = GRID_HOLD,
  GRID_PAGES = GRID_PAGES,
  GRID_LEVELS = GRID_LEVELS,
  START_ORDER = START_ORDER,
  UNDO_SECONDS = UNDO_SECONDS,
  ALT_HOLD_SECONDS = ALT_HOLD_SECONDS,
  DETENT = DETENT,
  FINE_DIVISOR = FINE_DIVISOR,
  CLEANUP_ORDER = CLEANUP_ORDER,
  -- 3.4 (design §12): fields of this table, never new locals
  NUM_MACROS = 16,        -- Macros (lib/macros.lua)
  MACRO_BANK_SIZE = 4,    -- Macros a bank shows (MOD, the arc)
  MACRO_TARGETS = 8,      -- Targets per macro
  MATRIX_SLOTS = 16,      -- Modulation matrix routings (lib/matrix.lua)
  NUM_GESTURES = 4,       -- Gesture recorders (lib/gestures.lua)
  SCENE_BANK_SIZE = 8,    -- Scene slots a bank shows
  SCENE_NAME_MAX = 12,    -- Characters in a scene name
  -- The deferrable sends' budget (lib/engine_sync.lua): at most
  -- messages_per_window sends per window_seconds; a deferrable send past it
  -- waits for the next window
  ENGINE_BUDGET = {messages_per_window = 150, window_seconds = 0.1},
}
