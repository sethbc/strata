-- lib/notes.lua
-- Notes (3.5, design §2): a voice's NOTE_SLOTS slots, slot 1 its own note
-- and the rest extra notes from a pool every voice shares. Package 0a's
-- skeleton, which nothing calls yet and which sends nothing: the pool
-- setting, kept in data/strata/notes.data (read at the start step
-- notes_load, written by set_pool, through S.lib.data_files), note_values,
-- and every voice at one note (held and pool_used are 0). Registers the
-- invariant "notes". Package 1b adds the allocator, the four note commands,
-- the flush and the hooks. See docs/notes/lua/notes.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NOTE_POOL = S.constants.NOTE_POOL
  local musicutil = require "musicutil"

  -- The module's tunables: notes.data's name and format version, a stolen
  -- note's cut (the engine's fade, seconds; 1b never steals a note younger
  -- than it), the most noteExpression messages one 48 Hz step sends, the
  -- note that plays at rate 1 and the engine's rate range
  local NOTES = {file = "notes.data", version = 1, cut_seconds = 0.05, sends_per_step = 16,
    rate_root_note = 60, rate_range = {0.25, 4}}
  M.NOTES = NOTES

  -- The pool notes.data holds (nil: none read or set, the tier's default)
  local pool_setting = nil

  local function whole_in(value, low, high)
    return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
  end

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end

  local function notes_path() return _path.data .. "strata/" .. NOTES.file end

  -- The running tier's default pool (standard's while the tier is unknown)
  local function tier_default()
    return NOTE_POOL[S.performance and S.performance.tier] or NOTE_POOL.standard
  end

  -- The extra notes the voices share: notes.data's, else the tier's default
  function M.pool()
    if pool_setting ~= nil then return pool_setting end
    return tier_default()
  end

  -- Set the pool, a whole number clamped to 0..NOTE_POOL.max: notes.data is
  -- written first, so a write that fails sets nothing (false), as
  -- S.lib.grid_core.set_rotation does; true once set. false for anything
  -- but a whole number. Sends nothing yet (1b releases the newest extra
  -- notes past a smaller pool, then sends setNotePool)
  function M.set_pool(n)
    if not finite(n) or n % 1 ~= 0 then return false end
    n = util.clamp(n, 0, NOTE_POOL.max)
    util.make_dir(_path.data .. "strata/")
    local written, problem = S.lib.data_files.write(notes_path(), {version = NOTES.version, pool = n})
    if not written then
      print("strata: " .. NOTES.file .. " not saved: " .. tostring(problem))
      return false
    end
    pool_setting = n
    return true
  end

  -- The extra notes voice holds (the count MAIN will show), and those every
  -- voice holds: none until 1b, every voice playing its own note only
  function M.held(voice) return 0 end
  function M.pool_used() return 0 end

  -- What the engine plays for pitch (a MIDI note number, fractional
  -- allowed) on voice: {note = pitch, freq = its frequency clamped to the
  -- voice's freq range, rate = 2 ^ ((pitch - 60) / 12) clamped to the
  -- engine's 0.25-4}; nil for a voice outside 1..NUM_VOICES or a pitch that
  -- is not a finite number. The one place a pitch becomes what the engine
  -- plays (1b: a frozen synth voice's rate from its freeze reference)
  function M.note_values(voice, pitch)
    if not whole_in(voice, 1, NUM_VOICES) or not finite(pitch) then return nil end
    local min_freq, max_freq = param_range("v" .. voice .. "_freq")
    return {
      note = pitch,
      freq = util.clamp(musicutil.note_num_to_freq(pitch), min_freq, max_freq),
      rate = util.clamp(2 ^ ((pitch - NOTES.rate_root_note) / 12), NOTES.rate_range[1], NOTES.rate_range[2]),
    }
  end

  -- The start step: read notes.data (parsed, never run). A version
  -- NOTES.version file whose pool is a whole number in 0..NOTE_POOL.max
  -- sets the pool; no file leaves the tier's default, and so does anything
  -- else (text that does not parse, another version, a bad pool), with one
  -- console line
  S.register_start(S.constants.START_ORDER.notes_load, function()
    pool_setting = nil
    local value, problem, why = S.lib.data_files.read(notes_path())
    if type(value) == "table" and value.version == NOTES.version and whole_in(value.pool, 0, NOTE_POOL.max) then
      pool_setting = value.pool
    elseif value ~= nil or problem == "unreadable" then
      print("strata: " .. NOTES.file .. " not used (" .. tostring(why or "not a note pool setting")
        .. "): the pool is the tier's default, " .. tier_default())
    end
  end)

  -- The pool is a whole number in 0..NOTE_POOL.max, the extra notes held
  -- never exceed it, and a stopped voice holds none
  S.register_invariant("notes", function()
    local pool = M.pool()
    if not whole_in(pool, 0, NOTE_POOL.max) then
      return "the pool is " .. tostring(pool) .. ", not a whole number in 0.." .. NOTE_POOL.max
    end
    if M.pool_used() > pool then return M.pool_used() .. " extra notes are held, past the pool's " .. pool end
    for voice = 1, NUM_VOICES do
      if M.held(voice) > 0 and not S.voices[voice].active then
        return "stopped voice " .. voice .. " holds " .. M.held(voice) .. " extra notes"
      end
    end
  end)

  return M
end
