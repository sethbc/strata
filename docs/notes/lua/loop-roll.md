## Must not break

- **The voice's own position runs on under a loop** (design section 4, call 21): `take_position` (`lib/sequencer.lua`) is untouched and runs first at every tick, so the voice's passes, its conditions (`S.lib.conditions`: `A:B`, `first`), a waiting length and a pass's end of the overrides are the voice's own, as with no loop; the loop only chooses the step played. Let go, the voice plays the step it would have reached, in step with the others.
- **The step played is `played_step(voice, step)`'s**, asked right after `take_position` in `begin_voice_step` and in `skip_due_ticks` (the controller's ruling 5a-1: a skipped tick moves the loop's own step too, as it moves the free lanes). The sequencer plays, lights (`S.pattern_sounding_steps`, so `sounding_step`) and gives the following lanes (`S.lib.lanes.read`) the step it returns; a free lane reads its own cell. A late wake moves the loop by the ticks that passed and never plays the steps between. The order in a tick: `take_position`, `played_step`, the lanes' reads, `advance`.
- **Nothing outlives its key**: an unlatched loop carries its key's own `still` (the grid's `pane.still` of the held step key, `docs/notes/lua/grid/keys.md`), asked at every tick: one whose `still` is false (the key's release, a page, side or half change of its pane, an unplug) is dead. No reader sees a dead loop (`loop`, `latched`, the lights), and the next tick (`played_step`) or a write drops it, so the voice plays its own step at that tick. A pattern's replacement (`replace_pattern`, `replace_whole`: a letter's switch, a chain link, a recall, a paste) never ends a `still` and never ends a loop.
- **A loop is never stored**: no param, scene field or PSET field holds it, nor its latch. A stop of the patterns keeps a loop (its key or latch still holds it) and a start plays it from its first step (`start`, called by `start_position`).
- **A loop lies inside the voice's length**: `set_loop` cuts it to 1 and `seq_length` (two keys both past the length make no loop and change nothing: a loop the voice already has, latched or held, and an armed latch stay as they were), and the length's action calls `fit_length`: a length below `lo` ends the loop, latched or not, and one below `hi` cuts it there; a longer length gives nothing back. The gate rule counts the steps inside the length, not the loop (call 10), so a pulse voice looped over empty steps stays open and silent.
- **A roll replays, never plays a step** (5b, design section 4, call 21): its hits are `S.lib.sequencer.replay_hit(voice)`, the voice's last played hit again as a later hit of its step (`first` false, `rolled` true), through every step output: never `begin_voice_step`, never `apply_step`, never a node. So a voice's own note never gets a node from a roll, and the step's locks, note and chord stand as held. It swells at the hit's level in every mode (`modes.own_event` passes a rolled event as it is, move included); the voices output sets the held values again first (`values.set_again`, not where a lock of the last step holds the param), and a gated voice's gate is the event's own, the interval times `v<i>_seq_gate_length`.
- **Under a roll the voice's own steps play nothing** (`S.lib.loop_roll.rolling(voice)` in `begin_voice_step` and `play_voice_hit`): `take_position`, `played_step` (a loop), the lanes' reads and `advance` run as at every tick, so its position, passes and lanes move on and let go it plays the step it would have reached; the step draws nothing and records no outcome, as a skipped tick. A ratchet's later hits stop too.
- **A roll asks its own key at every hit**: `roll(voice, rate, still)` keeps the key's `still` (the grid's `pane.still`), and its clock ends the roll, playing nothing, before any hit at which `still()` is false: a release, a page, side or half change of its pane, an unplug end it at its next hit. A new roll replaces the voice's roll (its clock stopped), so the last pressed rolls and an earlier key's release ends nothing. A pattern's replacement (a letter's switch, an order's next letter, a chain link, a recall, a paste) never ends a roll. No reader sees a dead roll (`rolling` is nil).
- **A roll lives only while the patterns play, within one start**: `roll` with the patterns stopped does nothing, `pattern_clock_stop` ends every roll (ruling 5b-1), so cleanup's own stop (`CLEANUP_ORDER.pattern_clock`) does too: no `CLEANUP_ORDER` entry of its own, and a start (`start_patterns`: the play key, a followed transport start) ends every roll too (the controller's ruling, round 1), since it forgets the kept hits: the voices play their own steps from it, and a key still down rolls nothing until it is pressed again. A roll is never stored: no param, scene field or PSET field.
- **A roll's clock goes through `S.lib.clocks`** (`run`, `stop`): `end_roll` stops it through the helper, so a wake already posted does nothing (no clock error). It sleeps, never syncs: its hits are `max(step_seconds / rate, SEQ.min_ratchet_seconds)` apart (`S.lib.sequencer.step_seconds`, the voice's nominal step), the first at once, each on the roll's grid of times from its first; a late wake plays one hit and moves the grid on by the intervals that passed, never a burst. A roll repaints nothing: the steps' own repaint (`finish_beat`) stays the grid's one a step.
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

### roll
- **State:** per voice, `ROLL.rolls[voice]` (a module local: `{rate, still, handle}` or nil; `ROLL.clocks`, handle -> voice, keeps each roll clock from its start until its body ends, or `end_roll` leaves it not running, for the invariant), read as `rolling` while `rolling(voice)` gives a rate (a roll whose key still holds it) and `off` otherwise (a dead roll is `off`). The table follows voice 1 with every step set, the patterns playing (step 1 played), a 128 showing a test page in the fx page's place whose keys 1 to 4 of lines 1 and 2 roll voice 1 at their rate, held by the key's `pane.still` (as 5c's `R1` to `R4` will), and a step output that logs every hit. `rolling` is key 1 then key 3 of line 1 pressed: key 3's roll at rate 3, key 1 still down.
- **Invariant:** `roll`: every roll clock that runs is a rolling voice's roll's (`ROLL.clocks`, each roll clock's handle and voice while its body runs, read against `ROLL.rolls`); a roll exists only while the patterns play, has a rate of 1 to 4 and a `still` function, and its clock runs (`S.lib.clocks.alive`); a replaced or ended roll's clock is stopped with it, so every roll clock that runs is its voice's roll's. Its `still` was true at its last hit, since the clock ends the roll before a hit at which it is false; the rows' checks of the next hit show it.
- **Test:** `test/unit/loop_roll_test.lua`: "roll: every cell is decided" and its rows, "the roll invariant fails on a roll with the patterns stopped", "the roll invariant fails on a roll clock no rolling voice owns" and the named tests beside them ("a start ends a roll, by hand and a followed transport start alike, and the voice plays its own steps", "a late wake plays one rolled hit and keeps the roll's grid", "an error in a rolled hit stops the patterns and is raised again", "a roll replays the last hit at its rate", "a roll is never faster than 20 ms", "the voice's own steps are silent under a roll and its position moves on", "a rolled hit in move swells at the hit's level and sets the held values again", "a roll tells the targets each hit", "a roll before any hit plays nothing", "of two roll keys the last pressed rolls, and the first's release changes nothing", "a page change and an unplug end a roll at its next hit", "a letter's switch under an order leaves a held roll", "a stop and cleanup end a roll", "a roll repaints the grid no more than once a beat"); `test/unit/sequencer_test.lua`: "replay_hit plays the voice's last hit again through every output, at its level" and "step_seconds is the voice's nominal step in seconds".

The events: `a rate set` (line 2's key 2 pressed: a roll at rate 2 by another key), `another rate` (line 1's key 4: rate 4), `the key's release` (line 1's key 3 let go), `an earlier key's release` (line 1's key 1 let go), `a page change` (the pane shows patterns), `an unplug` (the grid of port 1), `a stop` (the patterns), `a replacement` (`replace_pattern` with every step set) and `a hit that would have played` (voice 1's next tick, step 2, set). Where the Effect names the next hit, the row's check runs the clocks on through it.

| State | Event | Next | Effect |
|---|---|---|---|
| `off` | `a rate set` | `rolling` | the roll at 2, its first hit at once |
| `off` | `another rate` | `rolling` | the roll at 4, its first hit at once |
| `off` | `the key's release` | `off` | nothing |
| `off` | `an earlier key's release` | `off` | nothing |
| `off` | `a page change` | `off` | nothing |
| `off` | `an unplug` | `off` | nothing |
| `off` | `a stop` | `off` | nothing |
| `off` | `a replacement` | `off` | nothing |
| `off` | `a hit that would have played` | `off` | the voice plays its own step 2 |
| `rolling` | `a rate set` | `rolling` | the new key's roll at 2 replaces the roll at 3, its first hit at once |
| `rolling` | `another rate` | `rolling` | the roll at 4, its first hit at once |
| `rolling` | `the key's release` | `off` | the roll is dead; its next hit plays nothing, and the voice plays its own step 2 |
| `rolling` | `an earlier key's release` | `rolling` | nothing: the roll asks only its own key |
| `rolling` | `a page change` | `off` | key 3's still ends; its next hit plays nothing, and the voice plays its own step 2 |
| `rolling` | `an unplug` | `off` | the port is forgotten; the same |
| `rolling` | `a stop` | `off` | the roll and its clock end; no hit after it |
| `rolling` | `a replacement` | `rolling` | the roll stays |
| `rolling` | `a hit that would have played` | `rolling` | the position takes step 2, which plays nothing |

## Owns

`lib/loop_roll.lua` (`S.lib.loop_roll`), included after `lib/lanes.lua` and before `lib/sequencer.lua` (whose include runs `start_position` for every voice): the loop (5a) and the roll (5b).

- **`loop(voice) -> lo, hi | nil`**, **`armed(voice)`**, **`latched(voice)`**: reads, never writes; a dead loop is none.
- **`set_loop(voice, a, b, still)`**: ordered, cut to the length; `still` a function of no argument. Anything out of range does nothing. It repaints the grid.
- **`end_loop(voice)`** and **`press_latch(voice)`**: repaint the grid.
- **`played_step(voice, step) -> step`**: with no loop the voice's own `step`; with one, the loop's own next step over `lo..hi` in the voice's direction (`v<i>_seq_direction`): forward from `lo` and wrapping, reverse from `hi`, ping-pong from `lo` turning at both ends (no end played twice; a loop of one step stays on it), random a draw inside. A misstep is the voice's own position's, never the loop's. A loop whose last step a cut left outside it starts again at the direction's first. It repaints nothing: the tick's own repaint (`finish_beat`) shows it, one a beat.
- **`fit_length(voice, length)`**: the length's action (`lib/sequencer.lua`'s seq record).
- **`start(voice)`**: `start_position`'s, the loop back to its first step.

The roll's (5b):

- **`roll(voice, rate, still)`**: rate a whole 1 to 4, `still` a function of no argument; it replaces the voice's roll and plays its first hit at once. Anything out of range, or the patterns stopped, does nothing. It repaints nothing.
- **`end_roll(voice)`**: ends it, its clock stopped through the helper (`pattern_clock_stop` and `start_patterns` call it for every voice).
- **`rolling(voice) -> rate | nil`** and **`interval(voice) -> seconds | nil`** (the seconds between its hits, which `replay_hit` reads for a rolled hit's gate): reads; a dead roll is none.

The sequencer's side (`lib/sequencer.lua`): **`replay_hit(voice) -> boolean`** (false, playing nothing, with the patterns stopped or no hit played since they started; the kept hit is `play.last_hits[voice]`, a copy of the last event `play_outputs` played that was not itself rolled, emptied by `end_clocks` at every start and stop) and **`step_seconds(voice) -> seconds`** (the voice's division at the tempo now). A rolled event is a copy of the kept one with `first` false, `rolled` true, `beat` now, `velocity` its level over 15, `gate_beats` the interval (times the gate length on a gated voice) and, gated, `gate_seconds`.

The patterns page (side 1) makes a loop with its second key and dims a looped voice's set steps outside the loop (`docs/notes/lua/grid/pages/patterns.md`); 5c's perform side reads `loop`, `armed` and `latched` for its `LP` light and calls `press_latch`, and its `R1` to `R4` keys call `roll` with their `pane.still` and read `rolling`.
