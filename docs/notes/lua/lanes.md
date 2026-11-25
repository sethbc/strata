## Must not break

- **A step's level is its strength in every mode, and its value A is a field of its own** (`va`; value B is `vb`): no field means two things, and a change of mode reinterprets nothing. In `move` a hit adds no swell (`docs/notes/lua/sequencer/modes.md`), and its level stays what it is; after a change to another mode the same step swells at its level, its `va` untouched.
- **A value is a base override, as a lock is, and it stays** (`lib/sequencer.lua`'s `held_values`, read through `S.lib.sequencer.held_value(voice, target)`). At a played hit, each of lanes A and B whose target (`target`) and step key are set is set on its param and recorded; a hit without one sends nothing for it, so the value holds through any number of plain steps. A hit a condition or a chance holds back sets nothing. It ends, the override cleared and the record with it, only: at the next hit that sets the same target (the new value takes its place); at a stop of the patterns; at a hand edit of the param (the sequencer's own touch hook drops the record, the engine sync's clears the override); at `replace_pattern` (a clear, a randomize, a recall, a chain link); at a change of a target, of the mode, of the source (`S.register_source_change`) or of the type (one call in `lib/voices.lua`'s `type_changed`, ruling 2a-1); at the end of a pass that leaves the voice no set step; and at a length cut below the step that set it (not merely below the last played step: a value from step 1 outlives a cut to 4 after step 9).
- **The sequencer keeps the held values apart from `overrides`** (the last played step's locks and note), and `apply_step`'s clearing loop spares them: an override of the last step this one lacks ends through `values.release`, which sets a held value on that param again (the lock's end: the value comes back) or clears it. A lock on the same param wins for its own step; where a held value ends while a lock holds its param, the override stays the lock's, and at the lock's end there is no value to bring back.
- **Where A and B name one target, A's value is set and B's lane does nothing** (`target(voice, "b")` is nil then).
- **Neither param's own action does the hand's extras**: only `choose_mode` gives a move voice's set steps their random values, and only `choose_target` opens a closed filter (mix 0 to 1, the flash `filter on`), so a recall, a PSET or a scene's transition that sets `move` or `cutoff` changes no step and leaves a stored mix of 0. The params' own actions end the voice's held values and nothing else (the mode's also resends a gated voice's gate length, as before).
- `toggle_pattern_step` turning a step on in `move` gives it `va = math.random(1, MAX_STEP_LEVEL)` where it has none, and keeps one it has; turning it off keeps it.
- Position's values are fractions of the voice's loop, as `v<i>_buf_pos` is (`docs/notes/engine/loops.md`: the engine starts a grain at `loopStart + bufPos × loopLength`), so level 1 is the loop's start and 15 its end whatever the loop; size and cutoff are the param's own scale (`controlspec:map`). Nothing here sends: a value reaches the engine only as a base override (`set_override`, so a synth voice's freq resends `scaleNote` in 2b).

## Machines

### held values
- **State:** voice 1's held value on its position target (`S.lib.sequencer.held_value(1, "position")`) and whether the engine starts from it (`S.lib.engine_sync.engine_base_value("v1_buf_pos")` is its value) or from a lock of the last played step over it: `none`, `a value`, `a lock over a value`. `none` may hold a lock, which is the sequencer's `overrides` (`docs/notes/lua/sequencer.md`, step holds).
- **Invariant:** none of its own: `step holds` (`docs/notes/lua/sequencer.md`) holds it: stopped, no voice holds a value, and every held value's param has a base override (its own, or a lock's over it), so a record never outlives its value.
- **Test:** `test/unit/lanes_test.lua`: "held values: none + hit with a value" (one test a row), and the named tests beside them ("a value ends at a stop, a hand edit, ...", "a lock wins for its step and the value comes back", "a length cut past a lock but not past the value brings the value back").

Each state is a fresh script: voice 1 reading buffer 1 at position 0.2, length 8, steps 1 to 4 set and played (step 3 with `va` 15 for `a value`, and step 4 with a position lock of 0.6 for `a lock over a value`). The hits are step 5's: `hit with a value` (`va` 8, position 0.5), `hit without` (no value, no lock: in `a lock over a value`, the lock's end), `hit with a lock` (0.6), `held back` (`va` 8 at a chance of 0). The ends: `stop`, `hand edit` (an encoder's detent on `v1_buf_pos`: 0.21), `replace`, `target change` (A to size), `mode change` (to accent), `source switch` (buffer 2), `type switch`, `empty pass` (every step cleared, then the wrap), `length cut` (to 2). A source or type switch syncs the running voice, which sends the position it starts from again. Each row checks the position sent last and the one the engine starts from.

| State | Event | Next | Effect |
|---|---|---|---|
| `none` | `hit with a value` | `a value` | 0.5 sent |
| `none` | `hit without` | `none` | nothing sent |
| `none` | `hit with a lock` | `none` | the lock's 0.6 |
| `none` | `held back` | `none` | nothing sent |
| `none` | `stop` | `none` | nothing sent |
| `none` | `hand edit` | `none` | 0.21 |
| `none` | `replace` | `none` | nothing sent |
| `none` | `target change` | `none` | nothing sent |
| `none` | `mode change` | `none` | nothing sent |
| `none` | `source switch` | `none` | the sync's 0.2 |
| `none` | `type switch` | `none` | the sync's 0.2 |
| `none` | `empty pass` | `none` | nothing sent |
| `none` | `length cut` | `none` | nothing sent |
| `a value` | `hit with a value` | `a value` | replaced: 0.5 |
| `a value` | `hit without` | `a value` | nothing sent: it stays at 1 |
| `a value` | `hit with a lock` | `a lock over a value` | the lock wins: 0.6 |
| `a value` | `held back` | `a value` | nothing sent |
| `a value` | `stop` | `none` | 0.2 |
| `a value` | `hand edit` | `none` | 0.21 |
| `a value` | `replace` | `none` | 0.2 |
| `a value` | `target change` | `none` | 0.2 |
| `a value` | `mode change` | `none` | 0.2 |
| `a value` | `source switch` | `none` | 0.2 (then the sync's) |
| `a value` | `type switch` | `none` | 0.2 (then the sync's) |
| `a value` | `empty pass` | `none` | 0.2 at the wrap |
| `a value` | `length cut` | `none` | 0.2 |
| `a lock over a value` | `hit with a value` | `a value` | the lock ends into the new value: 0.5, once |
| `a lock over a value` | `hit without` | `a value` | the lock's end: the value comes back, 1 |
| `a lock over a value` | `hit with a lock` | `a lock over a value` | 0.6 |
| `a lock over a value` | `held back` | `a lock over a value` | nothing sent |
| `a lock over a value` | `stop` | `none` | 0.2 |
| `a lock over a value` | `hand edit` | `none` | 0.21: the lock ends too |
| `a lock over a value` | `replace` | `none` | 0.2 |
| `a lock over a value` | `target change` | `none` | nothing sent: the lock holds its step |
| `a lock over a value` | `mode change` | `none` | nothing sent: the lock holds its step |
| `a lock over a value` | `source switch` | `none` | the sync's 0.6: the lock holds its step |
| `a lock over a value` | `type switch` | `none` | the sync's 0.6: the lock holds its step |
| `a lock over a value` | `empty pass` | `none` | 0.2 at the wrap |
| `a lock over a value` | `length cut` | `none` | 0.2: the value and the lock end |

## Owns

`lib/lanes.lua` (`S.lib.lanes`, 3.9 grid sequencer, package 2a; included right before `lib/sequencer.lua`, whose `seq` record reads its options at include):
- `TARGETS` (`position`, `pitch`, `size`, `cutoff`), `MOVE` (the lanes' params `seq_move_a` and `seq_move_b`, their step keys `va` and `vb`, their first options `auto` and `off`, the param each target moves, a move hit's light with no value A, 4, and the filter's opening: mix 1 and the flash `filter on`), `options(lane)`.
- `target(voice, "a" | "b") -> name | nil`: `auto` is `position` when `voice_uses_buffer(voice)`, else `pitch`; `off` is nil; B is nil where it names A's target.
- `value(voice, target, level) -> param_id, value | nil` for a whole level 1 to 15: position `(level - 1) / 14` on `v<i>_buf_pos`; size and cutoff the param's controlspec `map((level - 1) / 14)` on `v<i>_grain_size` and `v<i>_filter_freq`; nil for `pitch` (package 2b's), another target or level.
- `choose_mode(voice, name)` and `choose_target(voice, "a" | "b", name)`: the hand's paths (consumed by the grid's patterns page, the perform side and SEQ's rows in later packages); an unknown voice, lane or name does nothing.
- `hit_light(voice, step) -> 0..15`: `step_brightness` in every mode but `move`; in `move` a set step inside the voice's length and off its playhead lights at its `va`, or 4 with none (the playhead and the steps past the length light as in every mode). The grid's pages are to use it (packages 3b, 5c); SEQ keeps `step_brightness`.
- Its unit tests: `test/unit/lanes_test.lua`.

`lib/sequencer.lua` holds the rest (`docs/notes/lua/sequencer.md`): the params `v<i>_seq_move_a` (options `auto`, `position`, `pitch`, `size`, `cutoff`; default 1) and `v<i>_seq_move_b` (`off`, then the four; default 1), discrete scene keys of the `seq` record (`count` 11), out of the voice presets (ruling 1a-3, as every seq key); the step keys `va` and `vb` in `ATTR_CHECKS` (whole 1 to 15), so `set_step_attr`, `step_attr`, `valid_steps` and the `steps` scene block take them; `held_value(voice, target)` and `end_held_values(voice)`; the held record (`held_values`, with the functions in one table, `values`: `take`, `release`, `end_held`, `on_param`), part of `step holds`.

## How a hit sets its values

`apply_step` (the step's first hit) first asks `values.take(voice, step)`: for lane A, then B, the target now and the step's key; each pair with a value replaces the held entry on its target (`{level, step, param}`) and is returned as fresh. The clearing loop then ends each override of the last played step that this step neither locks nor sets fresh (`values.release`). The step's locks are set, then each fresh value whose param no lock of the step holds. A held value the step does not set is not sent again. `end_overrides(voice)` ends the held values before the locks (a held value whose param a lock holds is only dropped there, so each param is sent once); the length's action ends the held values set past the new length first, then, when the last played step is past it, the overrides with `keep_held`, so a lock over a value that stays brings the value back in one send.

A held value's param is kept in its entry, since after a source switch a target may name another param (2b's pitch follows the source); the switch ends the values before the voice's sync.
