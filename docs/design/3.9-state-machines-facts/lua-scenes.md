# Facts: the state machines of scenes, morph, macros, gestures, undo and stored data (Lua)

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

The full report is below the summary instead; Only my probe file exists in the folder: `probes.md`. The repo is unchanged.

## Summary

| # | Machine | Owner | States | Transition bugs | Rec. | Conf. |
|---|---|---|---|---|---|---|
| 1 | Scene fade | `lib/scenes.lua` | 5 | 7 fixed (#48, #253, #254, #518, #584, #859, ruling 45), 2 open (P1, P4) | c + 2 small fixes | high |
| 2 | "Who is writing" flags | scenes, mutation, gestures, side_files | 6 writers | #46, #167, #318, #847; 1 open (P4) | a + one accessor | high |
| 3 | Clock retire-or-cancel | 7 modules | 4 | #626, #588; 4 open (P1, P2, P3, P9) | b (shared helper) | medium-high |
| 4 | Live scenes file status | `lib/scenes.lua` | 7 real | #72, #301, #327, #328, #463, #466, #518, #766; 1 open (P8) | b-lite + a | medium-high |
| 5 | Scene sequencer | `lib/scenes.lua` | 6 | #48, #303, #329, #513, #738, #754 | a | medium |
| 6 | Sound ownership | scenes + morph | 4 | #253, #518, #584, 1g's review | b-lite | medium |
| 7 | Voice preset store and row name | `lib/voice_presets.lua` | 4 + label | #848, #850, #861; 1 open (P10) | fix label; d | high |
| 8 | Gesture recorder | `lib/gestures.lua` | 4 × overdub | #624, #626, #651; 1 open (P9) | c (the exemplar) | high |
| 9 | Data-file lifecycle | `lib/side_files.lua` + 5 | 6 | #590, #648, #651, #847, #848 | a | medium |
| 10 | Morph apply clock | `lib/morph.lua` | 6 | #584, #626, #653, 1g's review | a | medium |
| 11 | Macro apply and learn | `lib/macros.lua` | 3 + 3 | #626 (twice) | d | high |
| 12 | Randomize undo | `lib/mutation.lua` | 4 | 1 open (P2) | d | high |
| 13 | PSET read protocol | params_setup + 7 hooks | 3 | #626, #766, #859 | a | medium |
| 14 | Factory load | `lib/factory.lua` | 4 + 3 | #847, #859, #861 | d | medium |
| 15 | SCENES prompt, performance, lock | pages/scenes, performance | 2-3 | #255, #236 | d | high |

Five things most worth knowing:

1. **Strata already audited its state machines before 3.3** (#232-#258). That left 33 invariants run after every unit test, States tables in the notes, and one exit function for the fade. All of them check states, none check transitions, and every bug above passed the invariants. The cheapest gain is option (c): table-driven tests of events × states, reusing the invariants.
2. **`S.scene_transition_active` says "a fade is running" but four modules read it as "the scene is setting this now".** A hand edit of a loop length during a fade skips its clamp (P4: start 0.5 + length 1 = 1.5, kept after a cancel, and a capture of it validates). One accessor that is true only inside a recall's apply or a fade step's sets fixes it.
3. **The #626 "retire, never cancel" lifecycle is hand-written in seven modules and missing in four clocks.** The fade clock, the scene sequencer's clock, the undo clock and a gesture's 10-minute clock each still raise `bad argument #1 to 'resume'` (P1, P2, P3, P9). It is a console line only, but four copies are still to write.
4. **Derived labels and overloaded fields fail the same way repeatedly.** VOICE's preset name was fixed twice (#850, #861) and still survives an undo of the load (P10). `S.scene_file.problem` holds both the load's outcome and the last write's, so one failed write erases SETUP's "kept as scenes.data.bak" row (P8).
5. **Two states the player cannot see or leave.** A gesture's overdub is shown nowhere, yet it records every hand edit on every page. A fade cannot be stopped in place, and hand edits to fading params are silently pulled back (P5).

---

# Full report

Audit at main `a1c8e8b4` (3.8.0). "Probe Pn" means I ran it with `lua test/run.lua --jobs 1 --dir <probes folder> probe`; "inferred" means read, not run. `lib/history.lua` is the input voice's `history` param, not an undo history: no lifecycle, not a machine.

## What already exists

- **Invariants** (#232): `S.register_invariant` (`lib/state.lua:472`), run after every unit test by `test/helpers.lua:186`, never on the device. Mine: `scene transition` (`lib/scenes.lua:1590`), `scene sequencer` (`:1736`), `morph clock` (`lib/morph.lua:795`), `macro apply`, `macro learn` (`lib/macros.lua:770`, `:789`), `gesture recorders` (`lib/gestures.lua:805`), `factory` (`lib/factory.lua:615`), `scenes prompt` (`lib/pages/scenes.lua:63`).
- **States tables in notes**: the fade (`docs/notes/lua/scenes.md:204-219`), SCENES' prompt and name entry (`docs/notes/lua/pages/scenes.md`), performance (`docs/notes/lua/performance.md`).
- **One exit with a `how`**: `end_scene_transition` (`lib/scenes.lua:388-409`, #253).
- **A model test**: `test/notes_model.lua` (ruling 57, #686), the precedent for checking sequences.
- Source: `docs/decisions/3.3.md:39` ("the state machine fixes, from an audit of the script's state handling").

## 1. Scene fade

1. **Owner** `lib/scenes.lua`. State: `S.scene_transition_active` (:55), `S.scene_transition_clock` (:59), `S.SCENE_TRANSITION.{next_step_due, target, previous, step, released}` (:194, set :733-738), `S.current_scene` (:43), and the fade closure's `targets`, `switches`, `switched`, `released`, `scene_data` (:717-725). Transitions: `recall_scene` (:691-782), `end_scene_transition(how)` (:388-409), `cancel_scene_transition` (:411), `recall_scene_instant` (:799-822), `release_voice` (:1683), `wait_for_scene_transition` (:830).
2. **States**: idle; starting (flag set, `step` nil, clock nil while step 1 runs inside `clock.run`, :739); fading (step 1-20), with the sub-states "switched" once f ≥ 0.5 (:752) and a non-empty `released`; landing (fields cleared, target current, `recall_scene_instant` applying, :775); idle again by one of four `how`s. Meant impossible: flag without target, a clock kept while idle (the invariant). Real but undocumented: a fade canceled after its midpoint has run its through-zero switches while `previous` is current again (:752-755, :395).
3. **Events**:

| Event | From | To | Where |
|---|---|---|---|
| recall(n, t > 0) | idle, fading | fading (ends the old one "superseded") | :711-739 |
| recall(n, 0) | idle, fading | idle | :780 |
| step timer | fading | fading; error → idle "failed" | :747-763 |
| end timer | fading | landing → idle; error → previous current | :775, :810 |
| cancel | fading | idle "canceled" | sequencer overrun :834; any scenes load :1183; PSET hook :1490; `lib/factory.lua:429`; `lib/morph.lua:684`; cleanup :1583 |
| release_voice(v) | fading | fading | `lib/voice_presets.lua:250` |
| capture into target | fading | fading (new table) | :717 |

   Outside readers of the flag: `lib/morph.lua:654`, `lib/loops.lua:63`, `lib/variation.lua:383`, `lib/params_setup.lua:55`, `lib/delay_sync.lua:164`. `S.current_scene` readers: `lib/ui/header.lua:116`, `lib/io/osc.lua:59,82`, `lib/io/actions.lua:59`; outside writer: `lib/morph.lua:687`. Displays go through `shows_current` (`header.lua:119`, `pages/scenes.lua:140`, `grid/core.lua:538`).
4. **Guards**: one exit; `xpcall` per step; the invariant; the notes' States table. Tests in `test/unit/scenes_test.lua` (:616-865, :3934, :4042) are by example, about 20 of them; none enumerates events × states.
5. **History**: `a8023819` (2025-10-24) introduced the flag; `6d7ac3e2` (I6) made fades linear; #48 capture during a fade and the overrun bound; `e18cf3ba` (#253) the single exit; `9bb51546` (#254) the blink; #518; `07728c84` takeovers (#584); `a0c77092` release (ruling 45); `f5ead47d` (#859).
   - Why this shape: the closure holds the snapshot so a capture cannot change the fade's end (#48), and `released` survives the field clearing before the landing (`docs/decisions/3.8.md:222`).
   - Constraints: tests reach the names through `local_value` (79 uses in `scenes_test.lua`; `wake(context, "scene_transition_clock")`, `test/helpers.lua:338`); the 3.3.2 verbatim send comparisons; five outside readers of the flag; inside its clock the id is forgotten, never canceled.
6. **UX**: the target blinks per step on header, SCENES and grid, steady once landed.
   - No key stops a fade in place: `cancel_scene_transition` has no player caller. The way out is another recall or a morph move.
   - P5: a hand edit of a fading param is pulled back (0.95 by hand, 0.34 one step later, 0.6 at the landing). `docs/user/scenes.md:38-42` does not say so.
   - After a cancel the header shows the previous scene steady while the sound is part-faded.
   - Open bugs: P1 (a recall superseding a fade whose step resume is posted raises `bad argument #1 to 'resume'`, :390-392) and P4 (machine 2).
7. **Recommendation (c)**: a table-driven test of the events above from each state, asserting the end state, `S.current_scene` and the invariants. Cost: one test helper and about 35 rows. Nothing can break (code unchanged). Then fix P1 and P4 as their own changes. A full (b) is wrong here: the closure state is deliberate. Bugs 9, blast radius high (every recall path), confidence high.

## 2. "Who is writing" flags (cross-cutting)

1. **Owners**: `S.scene_recall_in_progress` (`lib/scenes.lua:566-584`); `S.scene_transition_active`; `undo_writing` (`lib/mutation.lua:48, 53-58`); `S.drift_writing` (`:309-314`); `S.gesture_playing` (`lib/gestures.lua:113-123`); `reading_only` (`lib/side_files.lua:37, 52-59`).
2. **States**: the writer on the stack is one of hand, recall apply, fade step, undo or randomize, drift, gesture playback, read-only load. Each is a boolean set around writes in an `xpcall`. Only `gesture_playing` and `reading_only` restore the outer value; the others set false (inferred: a nested `apply_entries` would clear the flag early).
3. **Readers**: `scene_recall_in_progress` in `lib/voices.lua:227, 349, 353`, `lib/variation.lua:217, 328, 383`, `lib/loops.lua:63`, `lib/lfos.lua:860`, `lib/engine_sync.lua:522`, `lib/sequencer.lua:1513`, `lib/scenes.lua:935`; `drift_writing` in `lib/voices.lua` (2) and `lib/params_setup.lua` (1); `reading_only` in `lib/scenes.lua:1498, 1504`.
4. **Guards**: each flag has a "cleared after an error" test; no rule lists the writers together.
5. **History**: `34f09418` (one sync per recall, #46); #318; #167; #847 (nested `read_only`). `lib/loops.lua:62-64` has read the fade flag as a writer flag since `46b7e0e5` (3.2).
6. **The bug (P4)**: `scene_transition_active` is true for the whole fade, up to 30 s, so every hand edit in that span looks like a scene's set.
   - Loop length is unclamped: start 0.5, a hand set of length 1 stays 1 (idle: cut to 0.5); it stays after a cancel, and a capture of it validates. #167's premise ("edits always keep the pair valid") is false during a fade. The engine cuts the loop, so only the display and the capture are wrong.
   - A scale or root change during a fade never snaps quantized freqs (`lib/variation.lua:383`).
   - A hand-moved FX fader waits for the fade's next step to redraw the grid, up to 1.5 s (`lib/params_setup.lua:55`, `lib/delay_sync.lua:164`).
7. **Recommendation (a) + one accessor**: a table in `docs/notes/lua/engine-sync.md` of each writer and what each action does under it; and `S.lib.scenes.setting()`, true only inside `apply_entries` or a fade step's set loop, for `lib/loops.lua` and `lib/variation.lua`. Cost: about 15 lines and two tests. Risk: a fade's loop pair must still stand down inside a step (`loops_test.lua` and the #167 test detect it). Bugs 5, blast radius medium, confidence high.

## 3. Clock lifecycle: retire or cancel (cross-cutting)

1. **Owners**, each hand-written: `lib/macros.lua:307-327` (token + `retired`), `:557-573` (learn, with a wake margin), `lib/morph.lua:699-703, 728-749` (token table, no retired list), `lib/gestures.lua:309-336` (`run`, `retired_clocks`), and `lib/sequencer.lua:1055-1064`, `lib/quantize.lua:36-70`, `lib/matrix.lua:706` (other areas).
2. **States**: none; running; retired (waiting for a wake it will ignore); ended. Meant impossible: a retired id that is still the module's clock (the invariants check it).
3. **Events**: start; stop while its resume may be posted → retire; stop otherwise → cancel; wake with an old token → end; cleanup → cancel all.
4. **Guards**: the clock stub delivers posted resumes to canceled coroutines and raises as norns does (`docs/notes/test-harness/clock.md:45`, #588), so a test can see it, but only with `advance(before_delivery)`.
5. **History**: #626 (3.4's review) fixed morph, gestures, quantize and macros (`e021f7cb`, `fd9fd4f9`, `8955c7fa`). No ruling covers the remaining cancels (none found in `docs/decisions/`).
6. **Open**, all confirmed:
   - P1, the fade clock (`lib/scenes.lua:390`);
   - P2, the undo clock (`lib/mutation.lua:61-63`, any edit as the 5 s window ends);
   - P3, the scene sequencer (`lib/scenes.lua:1059`; its settle wait wakes every 0.01 s, so the window recurs);
   - P9, a gesture's 10-minute clock (`lib/gestures.lua:352-357`).
   - The player sees nothing; maiden prints one error.
7. **Recommendation (b)** as one helper, for example `S.lib.clocks.run(fn)` returning `{retire, cancel, alive}` with the token check inside. Cost: touches seven modules and their invariants, so do it module by module, starting with the four unprotected clocks. Constraints: matron's 100 clock slots (a retired 10 s sleep holds one, hence macros' wake margin); tests reach `S.morph_clock`, `S.macro_clock` by name. Detection: the stub's posted-resume delivery. Bugs 1 issue across 4 modules + 4 open, blast radius wide but cosmetic, confidence medium-high. This crosses into the sequencer's and quantize's areas.

## 4. Live scenes file status

1. **Owner** `lib/scenes.lua`: `S.scenes_loaded` (:1078), `S.scene_autosave_blocked` (:1073), `S.scene_file = {problem, backup, unsaved, pset, start_outcome}` (:1092), `SCENE_LOAD.armed_until` (:1097). Transitions: `save_scenes_to_disk` (:1104), `preserve_unloadable_scene_file` (:1150), `read_scenes_file` (:1208), `autosave` (:1265), `request_load` (:1281).
2. **States** (7 real of about 128 representable): not loaded; clean; set aside (`problem` + `backup`); unusable in place (blocked); write failed; unsaved; load prompt armed. Representable and reached: `problem = nil` with `backup` set (P8).
3. **Events**: start load; user save; explicit save (which deliberately overwrites an in-place unusable file, :1121-1124); failed write; request_load twice within 2 s; PSET save, load, delete. Outside readers: `lib/pages/setup.lua:161-175`, `lib/factory.lua:501, 574`, `lib/buffers.lua` (1).
4. **Guards**: about 30 example tests (`scenes_test.lua:1574-1710`), SETUP's layout states (`lib/pages/setup.lua:522-544`), and the notes' prose.
5. **History**: `767277ce` (blocked), `ef66c817` (#72), #301, #327, #328, #463, #466, #518, #766. Constraint: nothing of it may reach the file (ruling 27: a field on a scene would be saved).
6. **UX (P8)**: `problem` holds two facts. After a set-aside it reads `unreadable` with a backup; a failed write makes it `not saved`; the next good write makes it `nil`, and SETUP's "scenes unreadable, kept / as scenes.data.bak" row is gone for the session, though the backup is still on the card.
7. **Recommendation (b-lite)**: split into `load_problem` and `write_problem`, keeping `problem` as a derived read for SETUP; add a States table to `scenes.md`. Cost: about 20 lines; the tests and layout states that set `problem` directly need the derived field kept writable or updated. `S.buffer_file` is its twin (buffers' area). Bugs 9, blast radius low, confidence medium-high.

## 5. Scene sequencer

1. **Owner** `lib/scenes.lua`: `S.scene_sequencer_enabled`, `_position`, `_recall_due`, `_next`, `_clock` (:44-54), local `SEQUENCER_DRAW.move` (:905). Transitions: `scene_sequencer_start` (:944-1053), `_stop` (:1055), `pass` (:957-1028), `draw_next_scene`, `kept_next_scene`, `forget_next_scene` (:919-942).
2. **States**: off; starting (clock made, `sleep(0)` pending so a PSET read can finish); recalling; holding; settling (waiting on a fade, bounded by `overrun_seconds`); advancing. Plus "no playable scene: holding a slot". Two sources of truth: the param and `S.scene_sequencer_enabled` (#329 was their desync).
3. **Outside readers**: `lib/pages/scenes.lua`, `lib/grid/pages/scenes.lua`, `lib/ui/header.lua`; `sequencer_next_slot` (:1716) for the grids.
4. **Guards**: the invariant; an `xpcall` per pass; tests by example. No States table in the notes.
5. **History**: #48, #303 (`recall_due`), #329, #513, `575960b9` (chances), #738 and #754 (one stepper).
6. **UX**: "no playable scene" is a console line only (:993); the screen reads `seq on` and nothing happens.
7. **Recommendation (a)**: a States table beside the fade's. Bugs 6, blast radius medium, confidence medium.

## 6. Sound ownership

1. **State**: `S.current_scene` (0 or n), the fade flag, `takeover_count` (`lib/scenes.lua:93, 706`), and morph's `taken_over()` (`lib/morph.lua:653-655`), `move_held`, `move_scene`, `move_takeovers` (:755-758).
2. **States**: nothing recalled (0); scene n landed; fading to n; morph holds (0 again). "Morph holds" is derived as `current_scene == 0 and not fading`, so it also reads true at start, after a load zeroes the mark (#518), and after a fade from a morph-held state is canceled (inferred: morph's `applied.values` are then stale until its next move, as after a hand edit).
3. **Outside writer**: `lib/morph.lua:687` sets `S.current_scene = 0` directly.
4. **Guards**: tests by example (`morph_test.lua`, #584's).
5. **History**: #253, #518, #584, 1g's review ("a recall wins over a pending move", `1dec97af`).
6. **UX**: after a morph the header shows no scene. P6 confirms a morph move during a fade cancels it and leaves no scene current.
7. **Recommendation (b-lite)**: `S.lib.scenes.release_current()` and `S.lib.scenes.held_by_scene()` so morph neither writes nor re-derives. Cost: about 10 lines. Bugs 4, blast radius low, confidence medium.

## 7. Voice preset store and the row's name

1. **Owner** `lib/voice_presets.lua`: `store = {started, blocked, dropped}` (:76), `loaded` names (:80-86).
2. **States**: store clean; dropped (damaged presets left out, file kept at the first write); blocked. `store.started` is written at :76 and :322 and never read: a dead guard, unlike `live.loaded` in side_files (inferred: a save before the start step would write over an unread file).
3. **The name** is a derived label cleared by subscription: the PSET hook and `scene_recalled` (:85-86), plus the factory's hook list (#861).
4. **Guards**: `voice_presets_test.lua:416-432`.
5. **History**: #848, #850, #861, all 3.8's review.
6. **Open (P10)**: undo the load and the sound is back (freq 110) but the row still reads `glass`; a morph that resets the voice's freq leaves it too. The #850 rule ("never names a sound the voice no longer has") fails a third time.
7. **Recommendation**: carry the previous name in `hold_voice`'s capture and restore it in `undo` (`lib/mutation.lua:181-230`); remove or use `store.started`. Leave the store (d). Bugs 4, blast radius low, confidence high.

## 8. Gesture recorder (the exemplar)

1. **Owner** `lib/gestures.lua`: `S.gestures[k].state` (:79), `overdubbing`, `run`, `clock`, `limit_clock`, `offsets`. Writers of `state`: `press` (:464), `clear` (:488), `set_playing` (:573), `finish_recording` (:361), `fail` (:343), `load_record` (:673), `stop_all` (:709).
2. **States**: `empty`, `recording`, `playing`, `stopped`; overdub only while playing; a loop plays on a metro (free) or a clock (quantized).
3. **Outside readers** only through `M.state(k)` (`lib/pages/mod.lua:662, 1062`, `lib/grid/core.lua:516`); displays are tables keyed by the state (`PRESS_HINTS`, `:778`; `gesture_levels`, `grid/core.lua:478`).
4. **Guards**: the most thorough invariant in the area (:805-849: state against pattern, metro, clock, run, limit clock and play param). Tests by example.
5. **History**: one release old; #624, #626, #651.
6. **UX gap**: overdub is shown nowhere. `describe()` reads `play 2.5 s` either way (:525-539), the ALT hint reads `K3:dub` on or off (:794), and the grid level is "playing". While it is on, every hand edit of a control param on any page goes into the loop (:455).
7. **Recommendation (c)**: with one named state, a transition table test is cheap (7 events × 4 states). Show overdub in `describe()`. Copy this pattern elsewhere. Bugs 4, blast radius low, confidence high.

## 9. Data-file lifecycle across modules

- **Owners**: `lib/side_files.lua:96` (`live.loaded`, `closed`) for macros, gestures, matrix, sequences; scenes (machine 4); voices (machine 7); `notes.data`, `grids.data`, `io.data` (other areas); `factory.data`.
- **States**: unread; ok; missing; set aside; unusable in place; closed (after cleanup's write).
- **The rules differ.** An unusable file that cannot be set aside is: never written (side files, voices; `lib/side_files.lua:153-160`); written by an explicit save (scenes); written at the next change (`notes.data`, `grids.data`: `docs/notes/lua/data-files.md`).
- **UX**: only scenes and buffers reach SETUP. A damaged `gestures.data` or `macros.data` is a console line (`lib/side_files.lua:141, 156`); on the device the recorders are simply empty.
- **History**: #590, #648 (the helper), #651, #847, #848.
- **Recommendation (a)**: one table in `docs/notes/lua/data-files.md`, a row per file and a column per state. Converging the rules is a design decision, not a refactor. Confidence medium.

## 10. Morph apply clock

- **State**: one local `state` table (`lib/morph.lua:65-67`): `moved`, `pending`, `crossing_waits`, `flashed`, `clock` token, `crossed_at`, `applied`.
- **States**: idle; moved (first apply next tick); moving; resting or converging; crossing waits; plan not ready.
- **Transitions**: `note_move` (:755), `next_apply` (:711), `stop_clock` (:699), `forget_applied` (:70).
- **Guards**: the invariant; example tests. Well kept.
- **UX**: with fewer than two valid corners it flashes once per plan (:676-681), then every later move is a silent no-op.
- **Recommendation (a)**: turn the notes' "Applying" prose into a States table. Bugs 4, confidence medium.

## 11. Macro apply clock and learn

`applying.pending`, `apply_clock` (`lib/macros.lua:298-307`); `learning`, `learn_clock` (:550-557). Invariants check both. Learn is visible on the header from every page (`2c65c007`). **(d)**, confidence high.

## 12. Randomize undo

`S.undo`, `undo_clock`, `undo_writing` (`lib/mutation.lua:46-48`). States: none; held draws; held pattern; held voice capture. The only outside reader is `undo_for` (`lib/ui/alt.lua:80`). The clearing rules are a list in `mutation.md`. No transition bug in its history; P2 is machine 3's. **(d)**, confidence high.

## 13. PSET read protocol

- There is no "reading" flag. Three modules instead start their clocks with `clock.sleep(0)` so the hook that runs at the end of the read can retract them: the sequencer (`lib/scenes.lua:1034`), morph (`lib/morph.lua:731`), macros (`lib/macros.lua:371`).
- The hooks run in registry order; the scenes' is registered at include so it runs before morph's (`lib/scenes.lua:1532`).
- **Recommendation (a)**: state the convention once, in `docs/notes/lua/params.md`. Bugs #626, #766, #859. Edge: the dispatcher is `lib/params_setup.lua:309-332`.

## 14. Factory load

`S.factory_clock` (`lib/factory.lua:59, 442-464`); the marker's `pending` and `loaded` across starts (:489-508); the list's `open` and `armed_until` (:516). Steps 3-5 run without a yield. 3.8 ships no set. **(d)**.

## 15. Well kept, leave alone

- SCENES' overwrite prompt and name entry (`lib/pages/scenes.lua:54, 98-106`): the notes name even the "lapsed" state that no function enters. The model for (a).
- Performance (`lib/performance.lua:37-38, 195-216`): a States table exists.
- Lock (`lib/engine_sync.lua:678`, `lib/scenes.lua:500-505`), the mutation metro, the drift: booleans with two writers. (d).
- Three "press twice within 2 s" prompts (`lib/pages/scenes.lua:289`, `lib/scenes.lua:1281`, `lib/factory.lua:574`): small, each tested. (d).

## Agent experience

- `docs/notes/lua/scenes.md` is over 27,000 tokens: one Read call stopped at line 328 of 425, so an agent can miss the PSET and validation sections.
- Its fade States table sits at line 204 under three headings; the sequencer has none.
- A short "Machines" block at the top of each notes file (states, events, invariant name, test name) would let an agent find the transition rules without reading 44 prose bullets.
