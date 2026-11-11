## Must not break

- Pattern steps never create nodes: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)`, a stopped one is started with `S.lib.engine_sync.start_voice(voice)`. Never retrigger by toggling a voice off and on.
- A step redraws once, at its end: `grid_redraw()`, and when it started a voice `update_voice_list()` and `request_redraw()` too, however many voices it started. Its starts go through `start_voice`, which redraws nothing, never through `toggle_voice`, which redraws for each voice (#527).
- Bounds-check every voice and step before indexing `S.patterns`: `toggle_pattern_step` ignores a voice outside 1..`NUM_VOICES` and a step outside 1..`PATTERN_LENGTH` (a test calls it with each, #414).
- Step levels come from `MAX_STEP_LEVEL`, never a written-out 15: a toggled step is `MAX_STEP_LEVEL`, a random one `RANDOM_STEP_FLOOR` (half of it, rounded up: 8) to `MAX_STEP_LEVEL` (#418).
- The pattern clock only syncs (`clock.sync`), so external clock sources keep working. `pattern_clock_start` cancels a running clock before starting a new one.
- The patterns follow an external clock's transport (#530): the start step installs `clock.transport.start` (`pattern_clock_start`) and `clock.transport.stop` (`pattern_clock_stop`), each with `request_redraw()` and only while `params:get("clock_source")` is not the internal clock (1; MIDI 2, Link 3 or crow 4), so PARAMETERS > CLOCK > reset never starts a stopped pattern; each then calls the handler found at install, whatever the source; cleanup step 90 gives the found handlers back if the script's are still installed. A handler never chains to itself (an install while the script's is in place changes nothing).
- Anything that changes a pattern or the playhead calls `grid_redraw()`. Every edit of a voice's pattern (`toggle_pattern_step`, `replace_pattern`, and the writers in SEQ, the arc and the grid's level gesture) calls `S.lib.mutation.note_pattern_edit(voice)`, which ends a pattern undo of that voice; the randomize's and the undo's own writes run under the mutation module's `undo_writing` and do not (#557).
- A whole-pattern change (clear, randomize, the 256's paste, a scene recall's restore) goes through `S.lib.sequencer.replace_pattern(voice, steps)`, never a loop over `S.patterns[voice]` of its own: it ends the voice's held step gestures (`S.lib.grid_core.end_step_gestures`, #242), so a step held from before never takes a level in the new pattern.
- Each step runs through `xpcall(play_step, with_traceback)`: an error forgets the clock's own id (`S.pattern_clock = nil`, so the stop never cancels the clock from inside itself), calls `pattern_clock_stop()`, `update_voice_list()` (MAIN shows the voices the step started before it failed) and `request_redraw()` (the header's play mark and SEQ show it stopped, and SEQ stops animating) and raises the error again (#243). Never leave `S.pattern_playing` true after the clock died.
- Every playhead (each grid layout through `step_brightness`, the 64's column 1, SEQ's playing column) is `S.lib.sequencer.sounding_step()`, never `S.pattern_position`, which is already the next step between steps (#113). It is nil while stopped and before the first step plays, never `PATTERN_LENGTH` on a fresh start.

## Owns

- `lib/sequencer.lua` (`S.lib.sequencer`):
  - `S.patterns` (built fresh by its constructor), the pattern clock state (`S.pattern_position`, `S.pattern_sounding_step`, `S.pattern_playing`, `S.pattern_clock`);
  - `toggle_pattern_step`, `clear_pattern`, `randomize_pattern`, `pattern_toggle`, `pattern_clock_start`, `pattern_clock_stop`, `step_brightness` (global), `S.lib.sequencer.sounding_step()` and `S.lib.sequencer.replace_pattern(voice, steps)`;
  - the transport handlers (a local `transport` table: `start`, `stop` and the handlers found at install);
  - start step 160: the transport handlers installed;
  - cleanup step 90: the pattern clock stopped and the transport handlers given back.
- Its unit tests: `test/unit/sequencer_test.lua`. The grid keys that edit patterns are in `docs/notes/lua/grid-core.md` (`step_key`) and each layout's notes.

## Pattern sequencer

- **Storage**: `S.patterns[voice_idx][step]`, `NUM_VOICES` × `PATTERN_LENGTH` steps, values 0-`MAX_STEP_LEVEL` (15). The 64 grid shows and edits only steps 1-8, but patterns still play all 16.
- **Playback clock**: `S.pattern_clock` uses `clock.run()` and `clock.sync(1/4)` for tempo-synced 16th notes against norns' global clock. The `tempo` param and the tempo handler are in `docs/notes/lua/params.md`. External clock sources still work because the sequencer only syncs.
- **Transport** (#530): norns calls `clock.transport.start` and `clock.transport.stop` when the clock source starts or stops (matron's `clock_start_from_source` and `clock_stop_from_source`, for the source in use only): a MIDI start (on the first clock tick after it) or stop, a Link start or stop with PARAMETERS > CLOCK > link start/stop sync enabled, and PARAMETERS > CLOCK > reset on the internal clock (a start). The patterns follow only an external source (`clock_source` MIDI, Link or crow): on the internal clock both handlers leave them alone, since a reset restarts the beat, not the patterns. A start plays the patterns from step 1 at once, which is the source's beat 0, whether they played or not (a start while playing starts over); a stop stops them; both ask for a redraw (the header's play mark, SEQ) and then call the handler found at install, if any. K2, the grid's play keys and the arc's button still start the patterns at once, wherever the external beat is.
- **Position**: `S.pattern_position` is the next step to play (1-`PATTERN_LENGTH`) and wraps around. Each tick records it as `S.pattern_sounding_step`, triggers the step, redraws (once), then advances the position. Start and stop set `S.pattern_sounding_step` to nil.
- **Sounding step**: `S.lib.sequencer.sounding_step()` is the step the clock played last: `S.pattern_sounding_step` while `S.pattern_playing`, nil while stopped, before the first step plays and for a value outside 1..`PATTERN_LENGTH`. Between steps it is `(S.pattern_position - 2) % PATTERN_LENGTH + 1`, the rule SEQ used before; from the moment a step starts it is that step, and on a start it is 1 at once (`clock.run` resumes at once), never the last step. `step_brightness` and every playhead read it, so a grid redraw between steps (a key press) lights the same step SEQ draws.
- **Triggering**: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)` (an accent in place at the step's level as velocity, one grain in triggered grain mode, no new nodes). A stopped voice is started with `S.lib.engine_sync.start_voice(voice)` (the whole start, `docs/notes/lua/engine-sync.md`, without its redraws). Voices start automatically when a step triggers them. After the loop the step redraws once: `update_voice_list()` and `request_redraw()` if it started any voice, then `grid_redraw()` (#527).
- **Operations**:
  - `toggle_pattern_step(voice, step)`: an empty step on at `MAX_STEP_LEVEL`, a set one off; a voice or step out of range does nothing;
  - `clear_pattern(voice)`: reset all steps to 0;
  - `randomize_pattern(voice)`: a random pattern at 50% density (per step `math.random() > 0.5`, then `math.random(RANDOM_STEP_FLOOR, MAX_STEP_LEVEL)`, 8 to 15, in that order, so seeded tests keep their values);
  - `S.lib.sequencer.replace_pattern(voice, steps)`: steps 1..`PATTERN_LENGTH` take `steps[step]` floored to a whole number and clamped to 0..`MAX_STEP_LEVEL` (a missing or non-number entry is 0), then `end_step_gestures(voice)` runs. A voice outside 1..`NUM_VOICES` or a `steps` that is not a table does nothing. It redraws nothing: callers do. `clear_pattern` and `randomize_pattern` build their steps and write through it, as do the 256's paste (`docs/notes/lua/grid/layout_256.md`) and `recall_scene_instant`'s pattern restore (`docs/notes/lua/scenes.md`).
- **States** (the invariant `"pattern clock"`: `S.pattern_playing == (S.pattern_clock ~= nil)`):

  | State | `S.pattern_playing` | `S.pattern_clock` | `S.pattern_sounding_step` |
  |-------|---------------------|-------------------|---------------------------|
  | stopped | false | nil | nil |
  | playing | true | the running clock's id | nil before the first step plays, then the step played last |

  Transitions: `pattern_clock_start()` (stopped or playing to playing; cancels a running clock first; also an external transport start), `pattern_clock_stop()` (to stopped; also an external transport stop and cleanup step 90), and the error path (a step raised: `S.pattern_clock = nil`, `pattern_clock_stop()`, `update_voice_list()`, `request_redraw()`, error raised again). A step that fails on the clock's first run, which `clock.run` makes at once, leaves the clock id unrecorded, because `clock.run` re-raises before it returns (so no guard is needed around the assignment). On norns `clock.run` resumes the new coroutine at once and re-raises its error, so a first-step error propagates to the caller of `pattern_clock_start`; the stub does the same, and a later step's error is reported by the scheduler.

- Cleanup stops the pattern clock, so no clock coroutine is left behind, and gives the clock back the transport handlers found at install, unless a handler installed after the script's has replaced it (that one stays).

Bounds check before indexing:

```lua
function toggle_pattern_step(voice_idx, step)
  -- bounds checks keep the table from growing
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  if step < 1 or step > PATTERN_LENGTH then return end

  -- safe to access
  S.patterns[voice_idx][step] = ...
end
```
