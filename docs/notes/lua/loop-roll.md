## Must not break

- **The voice's own position runs on under a loop** (design section 4, call 21): `take_position` (`lib/sequencer.lua`) is untouched and runs first at every tick, so the voice's passes, its conditions (`S.lib.conditions`: `A:B`, `first`), a waiting length and a pass's end of the overrides are the voice's own, as with no loop; the loop only chooses the step played. Let go, the voice plays the step it would have reached, in step with the others.
- **The step played is `played_step(voice, step)`'s**, asked right after `take_position` in `begin_voice_step` and in `skip_due_ticks` (the controller's ruling 5a-1: a skipped tick moves the loop's own step too, as it moves the free lanes). The sequencer plays, lights (`S.pattern_sounding_steps`, so `sounding_step`) and gives the following lanes (`S.lib.lanes.read`) the step it returns; a free lane reads its own cell. A late wake moves the loop by the ticks that passed and never plays the steps between. The order in a tick: `take_position`, `played_step`, the lanes' reads, `advance`.
- **Nothing outlives its key**: an unlatched loop carries its key's own `still` (the grid's `pane.still` of the held step key, `docs/notes/lua/grid/keys.md`), asked at every tick: one whose `still` is false (the key's release, a page, side or half change of its pane, an unplug) is dead. No reader sees a dead loop (`loop`, `latched`, the lights), and the next tick (`played_step`) or a write drops it, so the voice plays its own step at that tick. A pattern's replacement (`replace_pattern`, `replace_whole`: a letter's switch, a chain link, a recall, a paste) never ends a `still` and never ends a loop.
- **A loop is never stored**: no param, scene field or PSET field holds it, nor its latch. A stop of the patterns keeps a loop (its key or latch still holds it) and a start plays it from its first step (`start`, called by `start_position`).
- **A loop lies inside the voice's length**: `set_loop` cuts it to 1 and `seq_length` (one wholly past the length is none), and the length's action calls `fit_length`: a length below `lo` ends the loop, latched or not, and one below `hi` cuts it there; a longer length gives nothing back. The gate rule counts the steps inside the length, not the loop (call 10), so a pulse voice looped over empty steps stays open and silent.
- **The latch** (`press_latch`, 5c's `LP` key): a latched loop ends, and the latch with it; a held loop becomes latched; with no loop the latch is armed, or disarmed if it was. An armed latch makes the next loop latched at once and is no longer armed, so a latch is armed only with no loop. A new loop over a latched one is latched too: the latch holds the voice's loop until `press_latch` or a length below it ends it.

## Machines

### loop
- **State:** per voice, `LOOP.loops[voice]` (a module local: `{lo, hi, still, latched, last, heading}` or nil) and `LOOP.armed[voice]`, read as `none` (no loop that holds and no latch armed), `held` (a loop its key holds), `armed` (no loop, the latch armed) and `latched` (`latched(voice)`). A dead loop reads as `none`. The table follows voice 1 with every step set, the patterns playing (step 1 played), its line on a 128's patterns page, side 1: `held` is key 5 held and key 8 pressed and let go (the loop 5 to 8, held by key 5); `armed` is `press_latch` with no loop; `latched` is `held` then `press_latch`, key 5 still down.
- **Invariant:** `loop`: a loop lies inside 1 to the voice's length with `lo` ≤ `hi` and carries a `still` function and a latch flag; a latch is armed only with no loop; while the patterns play, a loop that has played a step is the step the voice sounds (`S.pattern_sounding_steps`). An unlatched loop's `still` was true at its last tick: `played_step` drops a dead loop before it plays, so every step a loop played came from one that held then; the rows' checks of the next tick show it.
- **Test:** `test/unit/loop_roll_test.lua`: "loop: every cell is decided" and its rows, "the loop invariant fails on a loop past the voice's length" and the named tests beside them; `test/unit/grid_pages_patterns_test.lua`: "two keys of a line loop between them", "neither key toggles and no editor opens", "a page change and an unplug end an unlatched loop at the next tick", "a variation switch leaves a loop, and its key's release still ends it", "on a 64 both keys are in the half shown" and "while a loop is set the voice's set steps outside it light 2".

The events: `second key` (key 5 pressed if it is not down, then key 12 pressed and let go: the loop 5 to 12), `first key's release` (key 5 let go), `page change` (the pane shows voices), `unplug` (the grid of port 1), `press_latch`, `length cut inside` (`v1_seq_length` 6), `length cut below` (4), `replacement` (`replace_pattern` with every step set) and `stop` (the patterns). Where the Effect names the next tick, the row's check runs it: step 2 is the voice's own (a loop made after step 1), step 5 the loop's first.

| State | Event | Next | Effect |
|---|---|---|---|
| `none` | `second key` | `held` | the loop 5 to 12, held by key 5 |
| `none` | `first key's release` | `none` | nothing held; the next tick plays step 2 |
| `none` | `page change` | `none` | nothing |
| `none` | `unplug` | `none` | nothing |
| `none` | `press_latch` | `armed` | the latch armed |
| `none` | `length cut inside` | `none` | nothing |
| `none` | `length cut below` | `none` | nothing |
| `none` | `replacement` | `none` | nothing |
| `none` | `stop` | `none` | nothing |
| `held` | `second key` | `held` | a third key: the loop 5 to 12 |
| `held` | `first key's release` | `none` | the loop is dead; the next tick plays the voice's own step 2 |
| `held` | `page change` | `none` | key 5's still ends; the next tick plays step 2 |
| `held` | `unplug` | `none` | the port is forgotten; the next tick plays step 2 |
| `held` | `press_latch` | `latched` | the loop 5 to 8 latched |
| `held` | `length cut inside` | `held` | cut to 5 to 6; the next tick plays 5 |
| `held` | `length cut below` | `none` | the loop ends; the next tick plays step 2 |
| `held` | `replacement` | `held` | the loop stays, 5 to 8; the next tick plays 5 |
| `held` | `stop` | `held` | the loop stays |
| `armed` | `second key` | `latched` | the loop 5 to 12, latched at once; the latch no longer armed |
| `armed` | `first key's release` | `armed` | nothing held |
| `armed` | `page change` | `armed` | the latch is no key's |
| `armed` | `unplug` | `armed` | the same |
| `armed` | `press_latch` | `none` | disarmed |
| `armed` | `length cut inside` | `armed` | no loop to cut |
| `armed` | `length cut below` | `armed` | the same |
| `armed` | `replacement` | `armed` | nothing |
| `armed` | `stop` | `armed` | nothing |
| `latched` | `second key` | `latched` | the new loop 5 to 12, latched |
| `latched` | `first key's release` | `latched` | the loop outlasts its key; the next tick plays 5 |
| `latched` | `page change` | `latched` | the same |
| `latched` | `unplug` | `latched` | the same |
| `latched` | `press_latch` | `none` | the loop and the latch end; the next tick plays step 2 |
| `latched` | `length cut inside` | `latched` | cut to 5 to 6 |
| `latched` | `length cut below` | `none` | the loop and its latch end; the next tick plays step 2 |
| `latched` | `replacement` | `latched` | the loop stays, 5 to 8 |
| `latched` | `stop` | `latched` | the loop stays |

## Owns

`lib/loop_roll.lua` (`S.lib.loop_roll`), included after `lib/lanes.lua` and before `lib/sequencer.lua` (whose include runs `start_position` for every voice). 5b adds the roll here.

- **`loop(voice) -> lo, hi | nil`**, **`armed(voice)`**, **`latched(voice)`**: reads, never writes; a dead loop is none.
- **`set_loop(voice, a, b, still)`**: ordered, cut to the length; `still` a function of no argument. Anything out of range does nothing. It repaints the grid.
- **`end_loop(voice)`** and **`press_latch(voice)`**: repaint the grid.
- **`played_step(voice, step) -> step`**: with no loop the voice's own `step`; with one, the loop's own next step over `lo..hi` in the voice's direction (`v<i>_seq_direction`): forward from `lo` and wrapping, reverse from `hi`, ping-pong from `lo` turning at both ends (no end played twice; a loop of one step stays on it), random a draw inside. A misstep is the voice's own position's, never the loop's. A loop whose last step a cut left outside it starts again at the direction's first. It repaints nothing: the tick's own repaint (`finish_beat`) shows it, one a beat.
- **`fit_length(voice, length)`**: the length's action (`lib/sequencer.lua`'s seq record).
- **`start(voice)`**: `start_position`'s, the loop back to its first step.

The patterns page (side 1) makes a loop with its second key and dims a looped voice's set steps outside the loop (`docs/notes/lua/grid/pages/patterns.md`); 5c's perform side reads `loop`, `armed` and `latched` for its `LP` light and calls `press_latch`.
