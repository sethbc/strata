## Must not break

- **One message carries the whole state**: `engine.setScatter(depth, rate, destinations, voices)` with the depth as `scatter_depth / 100` (0 while `scatter` is off, which releases the engine's node), the rate in Hz, the destination mask (bit d set while destination d's toggle is on: 0 pitch, 1 position, 2 size, 3 cutoff, 4 amp, the engine's fast destinations) and the voice mask (bit v − 1 set for every unlocked voice). It is sent from every scatter param's engine sender, every lock change and a silent PSET read; never per step (the engine's one scatter node moves the voices itself).
- **Param → engine goes through the senders**: each param's action calls `send_param_to_engine(id, value)`, and `S.engine_senders[id]` sends the whole message; no action calls `engine.setScatter` itself. The message reads the stored values of all eight: no scatter param is an LFO destination, a macro target or a matrix destination, so what is stored is what the engine plays.
- **A locked voice is left alone**, as by the drift and mutation: the lock hook (`S.register_lock_change`) resends the voice mask whenever a lock flips, by `toggle_lock` and by a recall's lock states.
- **A silent PSET read** sets the params without their actions, so the PSET hook `scatter` sends the loaded state once; a read with actions has sent it already (one message per changed param) and the hook sends nothing more.
- `scatter_depth`'s and `scatter_rate`'s actions call `note_param_edit` (MOD's randomize draws them, package 2a).
- 3.3's sound by default: scatter is off, and nothing is sent until a param or a lock changes.
- Every scatter param is a scene field: the depth and the rate crossfade (range-checked by `validate_scene`), the on/off and the destination toggles switch at a fade's end.

## Owns

`lib/scatter.lua` (`S.lib.scatter`, 3.4, package 1e, design §6):
- `add_params()`: the group `strata_scatter` ("scatter", `SCATTER.param_count` 8), in this order: `scatter` (binary toggle, 0), `scatter_depth` (control 0-100 %, step 1, a percent a detent, default 10, shown `10 %`), `scatter_rate` (control 0.01-1 Hz, exponential, default 0.1, shown `0.10 Hz`), `scatter_pitch` and `scatter_pos` (binary toggles, 1), `scatter_size`, `scatter_cutoff` and `scatter_amp` (binary toggles, 0). `lib/params_setup.lua`'s menu record `scatter` calls it, after the macros and morph.
- `affects(voice_idx) -> boolean`: scatter moves the voice now (on, depth above 0, a destination enabled, the voice unlocked); false for a number that is no voice. MAIN's `~` reads it (package 2a).
- `SCATTER`, the module's one table (the param count, the depth's and the rate's ranges and defaults, the destination toggles in bit order).
- The engine senders of the eight params, the lock hook, the PSET hook `scatter` and the eight scene fields.

Scatter keeps no clock, metro, poll or handler, so it registers no cleanup step: `CLEANUP_ORDER.scatter` (125) stays unused (`docs/notes/lua/state-and-voices.md`). norns frees the engine before `cleanup()` (#461), and the engine's node with it.

Elsewhere: the engine's scatter node and its release are the modulation area's (`docs/notes/engine/modulation.md`); the MOD page's scatter rows and the arc's ALT rings are package 2a's.

## Tests

`test/unit/scatter_test.lua`: the params, their order and defaults; the message after each param and each lock change (`setScatter(0.1, 0.1, 3, 127)` on, `123` with voice 3 locked, destinations `19` with amp, depth 0 while off, each toggle's bit, a recall's locks); `affects`; the scene fields (stored, recalled, faded, a depth past 100 % refused); the silent PSET read; the depth and rate ending a randomize's undo.
