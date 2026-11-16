## Must not break

- **A skipped step tests nothing and records nothing**: only `begin_voice_step` (`lib/sequencer.lua`) calls `test` and `record`, for a set step it plays or misses; `skip_due_ticks` moves the position and the pass (`next_pass` through `take_position`) and nothing else, so a late wake changes no outcome.
- **A conditioned step** is a set step (level above 0) with a `cond` or a `prob` under 100: its condition is tested first, its probability drawn only if it holds, and `record(voice, played)` follows. A step that is not conditioned records nothing, so `pre` and `nei` read the last conditioned step, played or not.
- **The pass count starts at 1 wherever a voice's position starts** (`start`: a pattern start, a stop, a restart, a division reset's bar: the sequencer's `start_position`), never at a chain link or a scene recall, which keep it as they keep the position.
- **Fill is the latch or a holder**: `fill()` is true while `seq_fill` is 1 or any holder holds. A holder's release ends only its own hold; the latch stays until it is set off. A holder with a check (`hold_fill(holder, true, still)`) holds only while the check is true (a read, which may run in a page's `draw()`, drops nothing); the conditions' LFO step hook (`S.lib.lfos.on_step`, 48 Hz) drops it the first time it is not and calls `grid_redraw()` and `request_redraw()`, so an unplugged grid's hold leaves no stale mark: the grids' keys pass `pressed_as(port, x, y, "fill")`, so a page change or the grid's removal ends their hold with no release. `seq_fill` is `set_save(false)` (ruling 11): never stored on.
- Nothing here is stored or sent: the passes, the outcomes and the holders are never params, scene fields or PSET values (Global Constraints, transient state). It never yields.
- `M.values` is exactly the 78 strings in the edit row's order (`S.lib.pages_seq.turn_step`'s 79 stops with `off`); `valid` is the step attribute's check (`ATTR_CHECKS.cond`), so a scene holding any other string is refused whole.

## Owns

`lib/conditions.lua` (`S.lib.conditions`, 3.7, package 1e, design §5.1 and §5.2):
- `CONDITIONS` (`S.constants.CONDITIONS`): `max_b` (8) and `names` (`first`, `!first`, `pre`, `!pre`, `nei`, `!nei`, `fill`, `!fill`). `values`: the 78 conditions, for B from 2 to `max_b`, for A from 1 to B, `"A:B"` then `"!A:B"`, then the names. `valid(value)`.
- Per voice: `start(voice)` (pass 1, no outcome), `next_pass(voice)`, `pass(voice)`, `record(voice, played)`, `outcome(voice)` (true, false or nil before any), `neighbor(voice)` (`voice - 1`, `NUM_VOICES` for voice 1). A voice outside 1..`NUM_VOICES` reads as pass 1 with no outcome and changes nothing.
- `test(voice, cond)`: whether a step with that condition plays now (nil, or a string that is not one of the 78, plays).
- Fill: `hold_fill(holder, on, still)`, `release_holder(holder)`, `fill()`, and an LFO step hook that drops holders whose check fails. A change of `fill()` by a hold or a release, and every drop, calls `grid_redraw()` and `request_redraw()`; the latch's action (`seq_fill`, `lib/sequencer.lua`) does the same.
- Its unit tests: `test/unit/conditions_test.lua`; how the sequencer plays them: `test/unit/sequencer_test.lua`.

## The conditions

| Value | Holds when |
|---|---|
| `A:B` | `(pass - 1) % B == A - 1`: the A-th of every B passes |
| `first` | the pass is 1 |
| `pre` | the voice's last outcome is true (false before any) |
| `nei` | the neighbor's last outcome is true, whenever it was |
| `fill` | `fill()` |

Each `!` form is the opposite. On a beat two voices share, `nei` reads the neighbor's step only if its clock ran first: a pattern start runs the voices in order, a single voice's restart (a division reset's bar) can put it behind (design, Cost if wrong).

## Holders

The holders are `"grid:<port>"` (the 256's row 8 column 9 and the 128h's row 8 column 4, `docs/notes/lua/grid/layout_256.md`, `layout_128h.md`). The latch is set by SEQ's `fill` row (K3), the `fill` action (`S.lib.io_actions.fill(mode)`, crow's and OSC's) and a controller's mapping of the param (rulings 10 and 11).
