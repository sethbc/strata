## Must not break

- **`S.lib.notes` will be the only module that calls `noteOn`, `noteOff`, `noteExpression` and `setNotePool`** (design §2.2). In 3.5's package 0a it is a skeleton: nothing calls it and it sends nothing. Package 1b adds the allocator, the four commands, the flush and the hooks.
- **The pool is device-level**: kept in data/strata/notes.data, read at the start step and written by `set_pool`; a PSET or a scene never changes it, and it is never a param.
- **`set_pool` writes first** (as `S.lib.grid_core.set_rotation` does): the pool changes only when the write succeeded, and a write that fails leaves the old value and returns false.
- notes.data is read only through `S.lib.data_files.read` and written only through `S.lib.data_files.write` (`docs/notes/lua/data-files.md`).
- **`note_values` is the one place a pitch becomes what the engine plays**: every player's note goes through it (1b), and 3.8's tunings change it alone.
- **Every voice plays one note until 1b**: `held(voice)` and `pool_used()` are 0.

## Owns

`lib/notes.lua` (`S.lib.notes`, 3.5, package 0a, design §0.1, §2), included after `lib/matrix.lua`, with its table `NOTES` (`M.NOTES`):
- `NOTES`: `file` (`"notes.data"`), `version` (1), `cut_seconds` (0.05: a stolen note's cut, the engine's fade; 1b never steals a note younger than it), `sends_per_step` (16: the most `noteExpression` messages a 48 Hz step sends, 1b), `rate_root_note` (60: the note at rate 1) and `rate_range` (`{0.25, 4}`, the engine's rate clip).
- `pool()`: the extra notes every voice shares: notes.data's value, else the running tier's default (`S.constants.NOTE_POOL[S.performance.tier]`: 4 on standard, 8 on high; standard's while the tier is unknown).
- `set_pool(n)`: a whole number, clamped to 0..`NOTE_POOL.max` (16), written to notes.data as `{version = 1, pool = n}` (the folder made first), then set; true. false, with nothing set, for anything but a whole number (a string, a fraction, NaN, ±inf) and for a write that fails (with one line, `strata: notes.data not saved: <why>`). It sends nothing yet: 1b releases the newest extra notes past a smaller pool and sends `setNotePool`.
- `held(voice)` and `pool_used()`: 0 (the extra notes a voice holds, the count MAIN will show; those all voices hold).
- `note_values(voice, pitch)`: `{note = pitch, freq, rate}` for a MIDI note number (fractional allowed): `freq` is `musicutil.note_num_to_freq(pitch)` clamped to the voice's `v<i>_freq` range (20-2000 Hz), `rate` is `2 ^ ((pitch - 60) / 12)` clamped to 0.25-4. nil for a voice outside 1..`NUM_VOICES` or a pitch that is not a finite number. 1b adds a frozen synth voice's rate, from its freeze reference (design §2.4).
- The start step `notes_load` (`START_ORDER.notes_load`, 109, after the matrix's load): reads notes.data (parsed, never run). A version 1 file whose `pool` is a whole number in 0..`NOTE_POOL.max` sets the pool. No file leaves the tier's default with no line. Anything else (text that does not parse, another version, a bad or missing pool) leaves the default too, with one line: `strata: notes.data not used (<why>): the pool is the tier's default, <n>`. A file it cannot use is written over at the next `set_pool`, with no backup, as grids.data is.
- The invariant `"notes"`: the pool is a whole number in 0..`NOTE_POOL.max`, the extra notes held never exceed it, and a stopped voice holds none. 1b adds each slot record's checks and a voice's cap.
- No cleanup step yet, and no `CLEANUP_ORDER.notes`: the skeleton has nothing to stop, and the structure test requires every order to have a step and every step an observable effect.

The constants it reads are `S.constants.NOTE_SLOTS` (8: slot 1 the voice's own note, 2-8 from the pool; the engine's `noteSlots`) and `S.constants.NOTE_POOL` (`max` 16, the engine's `notePoolMax`; `standard` 4 and `high` 8, each tier's default).

The hooks 1b registers are in `lib/state.lua`: `S.register_voice_stop(fn(voice_idx))` (a voice's notes forgotten after every `voiceOff`, `docs/notes/lua/engine-sync.md`) and `S.register_freeze_change(fn(voice_idx, frozen))` (a synth voice's extra notes released when it freezes, `docs/notes/lua/freeze.md`). Its sends will be counted in the engine budget's window through `S.lib.engine_sync.count_sends(n)`, never deferred.

Tests: `test/unit/notes_test.lua` (the tier's default on standard and high, notes.data's pool; `set_pool`'s clamps, its write, what it refuses and a write that fails; a file read back at the next start; nine unusable files, each giving the default and one line, none run; `note_values`' note, frequency, rate, their clamps and refusals). `test/unit/structure_test.lua` logs the start step's read of notes.data.
