## Must not break

- The scene sequencer skips an empty or invalid slot at once (#513, #754): a pass moves the position to the first playable slot from it; only a sequence with no playable scene in it holds a slot for the scene duration, so the clock never spins. `S.lib.scenes.sequencer_next_slot` skips them the same way.
- **One stepper** (the groundwork's design §5): the scene sequencer, the pattern chain (`lib/sequencer.lua`) and the next-scene action (`lib/io/actions.lua`) list their slots only through `S.lib.scenes.playable_slots` and draw only through `S.lib.scenes.next_slot`, so an invalid scene is never drawn on any of them (#738, #754). `next_slot` looks up `S.lib.chance.pick` at each call (a test replaces it).
- **Validity is the cache's, never a draw's** (ruling 27): the local `checked[slot] = {data, valid}` is set at `capture_scene` and at a file load, and `S.lib.scenes.playable` checks once a data table it has not seen (one written into `S.scenes` outside this module: only tests do), so no draw calls `validate_scene` for a scene it has seen. Nothing of the cache is written to the file (`save_scenes_to_disk` writes `S.scenes` itself, so a field on a scene would be saved). A test that needs an invalid scene writes a fresh table into `S.scenes[n]`: an in-place edit of a captured scene keeps the cached `true`. `recall_scene` and morph keep their own `validate_scene` calls.
- An error in a pass of the sequencer's loop outside its recall (a param read, the wait, a redraw) stops the sequencer through its param, as the pattern clock does: the clock forgets its own id first, sets `scene_sequencer_enabled` to 0 through `set_binary_param` (so a controller mapped to it follows, #538) and calls `scene_sequencer_stop`, then raises the error again (#329). Cleanup step 100's stop stays a plain `params:set` (norns is tearing the script down). The recall's own errors are printed and the sequencer goes on. The `scene sequencer` invariant holds `S.scene_sequencer_enabled == (S.scene_sequencer_clock ~= nil)`, with that clock's coroutine not dead.
- **The next scene is drawn once** (3.7, design §5.4): each pass calls `S.lib.scenes.next_slot(position, playable_slots(1, length), chances)` exactly once, right after its recall has returned (never inside the apply, while `S.scene_recall_in_progress` is set), and keeps the slot in `S.scene_sequencer_next`. A kept slot is redrawn only when it can no longer play (past the length, empty or invalid): a length or chance changed during the wait draws nothing. Every slot kept can play: when the position itself cannot (a repeat of it could not), `next_slot` makes no pick and 3.6's advance stands in (the first playable slot after the position, wrapping from 1 past the length), with no random draw, so a redraw happens at most once however often the grids ask (1f's review). A `"repeat"` move recalls nothing; every other move recalls its slot, even the one playing (plan ruling 36). At 100, 0, 0 no random number is drawn, so 3.6's order holds. `S.scene_sequencer_next` is nil while the sequencer is off (the `scene sequencer` invariant).
- The three chances (`scene_chance_next`, `scene_chance_previous`, `scene_chance_random`) are PSET settings, never scene fields.
- The sequencer never cuts a transition short. It waits for the transition's end, bounded by `SCENE_TRANSITION.overrun_seconds` measured from the fade's progress, never from its start.

## Machines

### scene sequencer
- **State:** `S.scene_sequencer_enabled`, `S.scene_sequencer_clock` (the id; the handle is the local `sequencer_handle`), `S.scene_sequencer_position`, `S.scene_sequencer_recall_due`, `S.scene_sequencer_next` and the local `SEQUENCER_DRAW.move`; the param `scene_sequencer_enabled` starts and stops it. No accessor names the state; `S.lib.scenes.sequencer_next_slot()` names the slot it recalls next.
- **Invariant:** `scene sequencer`: a recall is due and a next slot kept only while the sequencer runs, and it runs exactly while its clock is held, a coroutine not dead.
- **Two facts:** `S.scene_sequencer_position` is the slot to recall next while `S.scene_sequencer_recall_due` is set (after the start and each advance) and the scene playing after the recall, through its hold; `sequencer_next_slot` reads the two apart by the flag.
- **Test:** `test/unit/scenes_test.lua`: "the scene sequencer's clock stopped as its wake is posted: no clock error, and nothing more happens".

The six states (3.9, #948), a table with no test yet: the examples above it in the test file cover its rows one by one. Recalling and advancing run inside one resume of the clock, with no wait: only the start's tick, the hold and the settling wait are where it waits. "No playable scene" is holding with nothing recalled (the pass prints `scene sequencer: no playable scene in slots 1-<length>` and holds the slot for the duration). The param and `S.scene_sequencer_enabled` are one fact kept twice: the action starts or stops the clock, a silent PSET read reconciles the clock after loading the slots, and the error stop sets the param first (#329).

| State | Event | Next | Effect |
|---|---|---|---|
| off | the param to 1 | starting | the clock made, the position 1, a recall due, the draw forgotten |
| starting | its tick (`handle.sleep(0)`) | recalling | a PSET read that set the param has finished |
| recalling | the recall returns | holding | the next slot drawn once and kept (`next_slot`), the screen and grids redrawn |
| recalling | the recall raises | holding | printed with its traceback; the scene holds its duration and the sequencer goes on |
| recalling | no playable scene in the sequence | holding | nothing recalled, the slot held for the duration |
| recalling | the draw was a repeat | holding | nothing recalled: the scene holds another duration |
| holding | the hold ends, no fade runs | advancing | `max(scene_duration, transition_time)` slept |
| holding | the hold ends, a fade runs | settling | it waits, `SCENE_TRANSITION.settle_seconds` at a time |
| settling | the fade ends | advancing | the flag clear |
| settling | the fade overruns | advancing | a step `overrun_seconds` late: the fade is canceled, with a console line |
| advancing | the position set | recalling | the kept slot if it can still play, else drawn again, else the next slot wrapped; a recall due |
| starting, holding or settling | the param to 0 | off | stopped through the clock helper (retired while its wake may be posted, else canceled); the draw forgotten |
| recalling, settling or advancing | an error in the pass outside its recall (a param read, the wait, a redraw) | off | the clock forgets its id, the param goes to 0 (`set_binary_param`), the stop, the error raised again (#329) |
| any but off | cleanup step 100 | off | the clock canceled at once, then the param and `scene_sequencer_stop()` |
| any but off | `scene_sequencer_start()` again (a restart) | starting | the running clock stopped first, a new one made from position 1: one clock |

## Scene sequencer

`scene_sequencer_start()`:

```lua
function scene_sequencer_start()
  local handle = S.lib.clocks.run(function(handle)
    if not handle.sleep(0) then return end  -- start on the next scheduler tick (after a PSET read)
    while S.scene_sequencer_enabled do
      -- one pass, under xpcall (an error stops the sequencer through its param, #329)
      if not plays(S.scene_sequencer_position, length) then  -- an empty or invalid slot is skipped at once (#513, #754)
        S.scene_sequencer_position = following(S.scene_sequencer_position, M.playable_slots(1, length))
          or S.scene_sequencer_position
      end
      if SEQUENCER_DRAW.move ~= "repeat" then recall_scene(S.scene_sequencer_position, transition_time) end
      draw_next_scene(length)  -- S.lib.scenes.next_slot, once, into S.scene_sequencer_next
      local held = math.max(scene_duration, transition_time)
      if not handle.sleep(held) then return end         -- stopped during the hold: it ends here
      if not wait_for_scene_transition(handle) then return end
      -- the kept slot if it can still play in the sequence as it is now, else
      -- drawn again; with no scene in the sequence, the next slot, wrapped
      S.scene_sequencer_position = kept_next_scene(length_now) or ...
    end
  end)
  S.scene_sequencer_clock = handle.id  -- the handle is kept in a local
end
```

Timing:
- Everything that does not fade is applied only by the `recall_scene_instant` at the end of the fade, and the next recall cancels a running fade first. So the sequencer never cuts a transition short.
- A scene lasts `max(scene_duration, transition_time)`.
- Then the sequencer waits, checking every `SCENE_TRANSITION.settle_seconds` (0.01 s), until `S.scene_transition_active` clears. The fade's 20 sleeps add up scheduling delay, so with equal times the sequencer would otherwise wake first.
- It also waits for a transition started by a manual recall.
- A manual recall still cancels a running transition (the sequencer's or its own).
- An empty or invalid slot is skipped at once (#513, #754): the pass recalls the first playable slot from the position (`following` over `playable_slots(1, length)`, wrapping within the sequence), so the scene after it follows the last scene's hold. With no playable scene in the sequence the pass holds the slot for `scene_duration` (no transition starts, nothing is recalled) and prints `scene sequencer: no playable scene in slots 1-<length>`, so the clock never spins.

The bounded wait (`wait_for_scene_transition`), so a transition whose clock is gone cannot stop the sequencer:
- A transition whose next step (or end) is `SCENE_TRANSITION.overrun_seconds` (1 s) late is canceled (`cancel_scene_transition`, with a console message), and the sequencer moves on.
- The bound follows the fade's progress, not its start. The transition clock records in `SCENE_TRANSITION.next_step_due` the `util.time()` at which its next step or its end is due: set when the transition starts and before each step's sleep, nil when no transition runs.
- So a healthy fade whose 21 wake-ups each run late under load (60 ms each puts a 16 s fade's end 1.3 s past its transition time) is never cut short, and one that stalls is caught `overrun_seconds` after its next step was due.
- The same applies to a transition the sequencer did not start (a manual recall's) or one left running because the sequencer's own recall failed validation.

Errors:
- An error in the sequencer's own recall (an instant recall, or the first fade step, which runs inside the sequencer's clock) is caught there with `xpcall` and printed with its traceback (`scene sequencer: scene <n> failed: ...`). The sequencer keeps going.
- That is safe: the recall has already cleared `S.scene_transition_active`, `S.scene_transition_clock` and `S.scene_recall_in_progress`, and the next scene may recall fine (stopping would end a long ambient run over one bad action).
- A failing scene still holds for its duration, so a repeating error prints at most once per scene.
- Errors in later fade steps are raised in the transition's clock, not the sequencer's.
- An error anywhere else in a pass (a param read, `wait_for_scene_transition`, the advance's redraws) stops the sequencer through its param (#329): each pass runs under `xpcall` with `with_traceback`; on an error the clock sets `S.scene_sequencer_clock` to nil first (so the stop never cancels it from inside), sets `scene_sequencer_enabled` to 0 through `set_binary_param` (a mapped controller gets its CC), calls `scene_sequencer_stop()` if that left it on, and raises the error again. So the header, SCENES, the grids and the state agree that it stopped, and one switch starts it again.

The next scene (3.7, design §5.4, decision 12):
- The playable slots of 1..`scene_sequence_length` (`playable_slots(1, length)`: populated and valid), in order, are the stepper's list (`next_slot`), the position its current slot, and `scene_chance_next`, `scene_chance_previous` and `scene_chance_random` (0-100, defaults 100, 0, 0, after the length in PARAMS) its chances (`docs/notes/lua/chance.md`). Next past the last playable slot is the first, previous before the first the last, random any other playable slot; what the three leave is a repeat.
- The draw is made right after the recall (with no playable scene in the sequence, as its hold begins: `next_slot` returns nil for the empty list), and kept with its move in the local `SEQUENCER_DRAW`. The pass after a `"repeat"` recalls nothing and holds the scene for another `scene_duration` (no transition); every other move recalls its slot, the one playing too (one playable slot, the playing one, at 100, 0, 0 is `"next"` to itself, recalled again as in 3.6; with random or all at 0 it is a repeat, held).
- After the wait the position becomes the kept slot when it is still inside the length and playable; otherwise the pick is made again over the sequence as it is now (`kept_next_scene`, which `sequencer_next_slot` calls too, so the grids light the slot that will play; it never draws while a recall applies). A pick made again from a position that can no longer play (past a shortened sequence, or emptied by a scenes load) is no pick: `next_slot` takes 3.6's advance, the first playable slot after the position (wrapped to 1 past the length), as a `"next"` move with no draw. With no playable scene in the sequence the position moves on to the next slot, wrapped, as before 3.7.
- Two cases differ from 3.6 at the defaults, on purpose (1f's review ruling): a sequence lengthened during a hold keeps the drawn slot (4 to 6 on scene 4 plays 1, 3.6 played 5), and a scene saved into a skipped slot during the hold waits for the next round (1 and 3 saved, 1 playing, saving 2 plays 3, 3.6 played 2; a test pins it). The kept slot still plays and the light already shows it.
- Start, stop and the error stop forget the draw (`forget_next_scene`).

Length and PSET loads:
- The sequencer advances with the `scene_sequence_length` it reads after the wait, so a sequence shortened while a scene plays drops a kept slot past its end and draws again: at the defaults that wraps to the first scene (it never jumps to the new last scene). A lengthened one keeps the slot it drew.
- Its clock does nothing until the next scheduler tick (`handle.sleep(0)`). norns' `params:read` (a PSET load from the PARAMS menu) sets params one by one in file order, and `scene_sequencer_enabled` comes before the transition time, duration, length, FX, LFO and voice params. Started inside the read, the sequencer would recall scene 1 with the old transition time and the PSET's later lines would then overwrite it. On the next tick the read has finished.
- `scene_sequencer_start` and `pattern_clock_start` end their running clock before starting a new one (tests check that a restart leaves one clock). The sequencer's runs on the clock helper (3.9, #870, `docs/notes/lua/clocks.md`): a start or a stop stops it through `S.lib.clocks.stop`, which retires it while its wake may be posted (its settle wait wakes every 0.01 s, always inside the margin) and cancels it farther off; a retired clock's wait returns false at its wake and the pass and the clock return, doing nothing more. Every wait of its body (`handle.sleep(0)`, the hold, `wait_for_scene_transition(handle)`'s settle sleeps) is its handle's.
- A silent PSET read skips the enable action. After the scenes side file is read, the scenes hook compares the loaded switch (off when its line is missing) with `S.scene_sequencer_enabled`. A change runs the same start or stop. Matching states leave the clock, its scheduled wake and its next draw in place (#1099).
- The `scene_sequencer_enabled` param action starts and stops the sequencer. Cleanup step 100 cancels its clock at once (`S.lib.clocks.cancel`: the script ends), then stops it through that param, then `scene_sequencer_stop()`.
