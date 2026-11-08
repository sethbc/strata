## Must not break

- Pattern steps never create nodes: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)`, a stopped one `toggle_voice`. Never retrigger by toggling a voice off and on.
- Bounds-check every voice and step before indexing `S.patterns`.
- The pattern clock only syncs (`clock.sync`), so external clock sources keep working. `pattern_clock_start` cancels a running clock before starting a new one.
- Anything that changes a pattern or the playhead calls `grid_redraw()`.
- Every playhead (each grid layout through `step_brightness`, the 64's column 1, SEQ's playing column) is `S.lib.sequencer.sounding_step()`, never `S.pattern_position`, which is already the next step between steps (#113). It is nil while stopped and before the first step plays, never `PATTERN_LENGTH` on a fresh start.

## Owns

- `lib/sequencer.lua` (`S.lib.sequencer`):
  - `S.patterns` (built fresh by its constructor), the pattern clock state (`S.pattern_position`, `S.pattern_sounding_step`, `S.pattern_playing`, `S.pattern_clock`);
  - `toggle_pattern_step`, `clear_pattern`, `randomize_pattern`, `pattern_toggle`, `pattern_clock_start`, `pattern_clock_stop`, `step_brightness` (global) and `S.lib.sequencer.sounding_step()`;
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
  - `randomize_pattern(voice)`: a random pattern at 50% density.
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
