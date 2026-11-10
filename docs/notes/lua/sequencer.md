## Must not break

- Pattern steps never create nodes: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)`, a stopped one `toggle_voice`. Never retrigger by toggling a voice off and on.
- Bounds-check every voice and step before indexing `S.patterns`.
- The pattern clock only syncs (`clock.sync`), so external clock sources keep working. `pattern_clock_start` cancels a running clock before starting a new one.
- Anything that changes a pattern or the playhead calls `grid_redraw()`.
- A whole-pattern change (clear, randomize, the 256's paste, a scene recall's restore) goes through `S.lib.sequencer.replace_pattern(voice, steps)`, never a loop over `S.patterns[voice]` of its own: it ends the voice's held step gestures (`S.lib.grid_core.end_step_gestures`, #242), so a step held from before never takes a level in the new pattern.
- Each step runs through `xpcall(play_step, with_traceback)`: an error forgets the clock's own id (`S.pattern_clock = nil`, so the stop never cancels the clock from inside itself), calls `pattern_clock_stop()` and raises the error again (#243). Never leave `S.pattern_playing` true after the clock died.
- Every playhead (each grid layout through `step_brightness`, the 64's column 1, SEQ's playing column) is `S.lib.sequencer.sounding_step()`, never `S.pattern_position`, which is already the next step between steps (#113). It is nil while stopped and before the first step plays, never `PATTERN_LENGTH` on a fresh start.

## Owns

- `lib/sequencer.lua` (`S.lib.sequencer`):
  - `S.patterns` (built fresh by its constructor), the pattern clock state (`S.pattern_position`, `S.pattern_sounding_step`, `S.pattern_playing`, `S.pattern_clock`);
  - `toggle_pattern_step`, `clear_pattern`, `randomize_pattern`, `pattern_toggle`, `pattern_clock_start`, `pattern_clock_stop`, `step_brightness` (global), `S.lib.sequencer.sounding_step()` and `S.lib.sequencer.replace_pattern(voice, steps)`;
  - cleanup step 90: the pattern clock stopped.
- Its unit tests: `test/unit/sequencer_test.lua`. The grid keys that edit patterns are in `docs/notes/lua/grid-core.md` (`step_key`) and each layout's notes.

## Pattern sequencer

- **Storage**: `S.patterns[voice_idx][step]`, `NUM_VOICES` × `PATTERN_LENGTH` steps, values 0-15. The 64 grid shows and edits only steps 1-8, but patterns still play all 16.
- **Playback clock**: `S.pattern_clock` uses `clock.run()` and `clock.sync(1/4)` for tempo-synced 16th notes against norns' global clock. The `tempo` param and the tempo handler are in `docs/notes/lua/params.md`. External clock sources still work because the sequencer only syncs.
- **Position**: `S.pattern_position` is the next step to play (1-`PATTERN_LENGTH`) and wraps around. Each tick records it as `S.pattern_sounding_step`, triggers the step, redraws the grid, then advances the position. Start and stop set `S.pattern_sounding_step` to nil.
- **Sounding step**: `S.lib.sequencer.sounding_step()` is the step the clock played last: `S.pattern_sounding_step` while `S.pattern_playing`, nil while stopped, before the first step plays and for a value outside 1..`PATTERN_LENGTH`. Between steps it is `(S.pattern_position - 2) % PATTERN_LENGTH + 1`, the rule SEQ used before; from the moment a step starts (a voice it starts redraws the grid inside the step) it is that step, and on a start it is 1 at once (`clock.run` resumes at once), never the last step. `step_brightness` and every playhead read it, so a grid redraw between steps (a key press) lights the same step SEQ draws.
- **Triggering**: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)` (an accent in place at the step's level as velocity, one grain in triggered grain mode, no new nodes). A stopped voice is started with `toggle_voice`. Voices start automatically when a step triggers them.
- **Operations**:
  - `toggle_pattern_step(voice, step)`: toggle a step on or off;
  - `clear_pattern(voice)`: reset all steps to 0;
  - `randomize_pattern(voice)`: a random pattern at 50% density (per step `math.random() > 0.5`, then `math.random(8, 15)`, in that order, so seeded tests keep their values);
  - `S.lib.sequencer.replace_pattern(voice, steps)`: steps 1..`PATTERN_LENGTH` take `steps[step]` floored to a whole number and clamped to 0..`MAX_STEP_LEVEL` (a missing or non-number entry is 0), then `end_step_gestures(voice)` runs. A voice outside 1..`NUM_VOICES` or a `steps` that is not a table does nothing. It redraws nothing: callers do. `clear_pattern` and `randomize_pattern` build their steps and write through it, as do the 256's paste (`docs/notes/lua/grid/layout_256.md`) and `recall_scene_instant`'s pattern restore (`docs/notes/lua/scenes.md`).
- **States** (the invariant `"pattern clock"`: `S.pattern_playing == (S.pattern_clock ~= nil)`):

  | State | `S.pattern_playing` | `S.pattern_clock` | `S.pattern_sounding_step` |
  |-------|---------------------|-------------------|---------------------------|
  | stopped | false | nil | nil |
  | playing | true | the running clock's id | nil before the first step plays, then the step played last |

  Transitions: `pattern_clock_start()` (stopped or playing to playing; cancels a running clock first), `pattern_clock_stop()` (to stopped; also cleanup step 90), and the error path (a step raised: `S.pattern_clock = nil`, `pattern_clock_stop()`, error raised again). A step that fails on the clock's first run, which `clock.run` makes at once, leaves the clock id unrecorded, because `clock.run` re-raises before it returns (so no guard is needed around the assignment). On norns `clock.run` resumes the new coroutine at once and re-raises its error, so a first-step error propagates to the caller of `pattern_clock_start`; the stub does the same, and a later step's error is reported by the scheduler.

- Cleanup stops the pattern clock, so no clock coroutine is left behind.

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
