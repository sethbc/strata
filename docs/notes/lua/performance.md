## Must not break

- `read_active` runs in the first params record (`"performance"`, before `"master"`), so `S.performance` holds the running tier before any param is added: every tier-dependent spec reads it as its param is added (`record_duration`'s maximum is `S.performance.buffer_seconds`). The record adds no params.
- A missing or invalid `performance_active.data` gives the standard tier (`STANDARD_PERFORMANCE`) and prints exactly one line, `strata: performance_active.data unreadable, using standard`; never an error, and never a tier the engine did not write. Invalid: a tier other than `standard`/`high`, a length not in the tier's set (standard 16; high 16, 60, 120, 300), a `max_grains` or `history_seconds` other than the tier's (128; 16 or 60), a missing line, a value with trailing words. A number is a run of decimal digits as `tonumber` reads it (`whole_number`: leading zeros allowed); the engine's `wholeNumber` reads every digit string the same way, so a string that sclang's `asInteger` would wrap to a choice (`4294967356`, 2^32 + 60) is refused on both sides (#500; `test/unit/performance_test.lua` and the engine check keep the same texts).
- `S.performance` is replaced by a fresh table, never the constant itself.
- `engine_slot_seconds` (from the `bufferState` poll's slot-length message, slot index `NUM_BUFFERS`) only ever lowers `S.performance.buffer_seconds`, to a length the running tier allows, when the engine's slots are shorter than the active file says (an old file the engine could not replace, #153). It also lowers `record_duration`'s maximum, re-setting the value it read before the range changed (a control param stores its value normalized), and prints one line.
- The setting (`performance.data`) is not a param: no PSET or scene holds it. Only SETUP edits it, through `set_setting`. Each key is read on its own, as the engine reads it: invalid lines are skipped, so a repeated key keeps its last valid value, and a missing file or a key with no valid line gives that key's default (auto, 60 s).
- `set_setting` writes the whole file (`performance <choice>` then `buffer_seconds <n>`, one per line) to `performance.data.part` and renames it into place, so a crash never leaves half a file (the engine's `deleteStaleParts` removes a stale `.part` there at its next start).
- `BUFFER_STATE_STRIDE` (1000, `lib/buffers.lua`) equals the engine's `bufferStateStride`; `BUFFER_SECONDS` is no longer a constant. Code reads `S.performance.buffer_seconds`; only `STANDARD_BUFFER_SECONDS` (16) is a constant.

## Owns

- `lib/performance.lua` (`S.lib.performance`): `read_active`, `engine_slot_seconds`, `parse_active_text` (also the engine stub's validator; the engine's `parseActivePerformance` must read every text the same way, #153), `setting`, `set_setting`, `PERFORMANCE` (the files, choices, defaults and each tier's allowed values), and `S.performance_setting` (the setting as SETUP shows it) and `S.performance_start_setting` (the setting this start used).
- Its unit tests: `test/unit/performance_test.lua`. The SETUP fields are in [pages/setup.md](pages/setup.md).

## How it works

The engine decides the tier at `alloc` and writes `performance_active.data` before the script starts (`docs/notes/engine/performance.md`). Lua never decides: it reads what the engine wrote.
- **`read_active()`** reads `_path.data .. "strata/performance_active.data"` (`key value` lines; the value is the rest of the line, so a reason keeps its spaces; CRLF line ends are fine) into `S.performance = {tier, buffer_seconds, max_grains, history_seconds, reason}`. `reason` is optional (`""`). It then reads the setting as this start used it (`S.performance_start_setting`): the engine read the same file at alloc just before.
- **`setting()`** returns a copy of `{performance, buffer_seconds}`, read from `performance.data` the first time and cached in `S.performance_setting`.
- **`set_setting(key, value)`** (`"performance"`: auto, standard or high; `"buffer_seconds"`: 16, 60, 120 or 300) writes the file and, only when the write worked, updates the cache and requests a redraw, and returns true. An unknown key or value, or a failed write (one console line `strata: cannot write <path>`), returns false and leaves the cache and so `setting()` as it was (#236). It applies at the next start.
- `record_buffer` also caps a take at `S.performance.buffer_seconds` (the param's range already ends there).
- The test harness writes the active file with `h.write_performance_active(fields)` before a `load_strata` (fields in the engine's order, or a string written as it is), and the engine stub's `recordBuffer` limit follows that file (`stubs.active_buffer_seconds`). See [test-harness.md](../test-harness.md).

## States

| Field | Holds | Legal values |
|-------|-------|--------------|
| `S.performance_setting` | the setting as `performance.data` holds it (read from the file on first use) | `{performance, buffer_seconds}` from the choices, or nil until read |
| `S.performance_start_setting` | the setting this start used, copied by `read_active` | the same shape, never changed after the start |
| `S.performance` | the tier the engine runs (`performance_active.data`) | a tier record, never written by `set_setting`; its `reason` is the engine's text, which `running_note()` (`active file not written` for "could not be written", `old active file kept` for "could not be replaced", else nil) and `step_down_cause()` (`meminfo` for "meminfo unreadable", else `memory`) read; both are pure reads and hold no state |

The setting differs from the start setting only after a successful `set_setting` (SETUP then shows `(next start)`). The one transition is `set_setting`: it changes `S.performance_setting` only after `performance.data` is in place, so the cache never names a value the file lacks.
