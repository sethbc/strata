## Must not break

- Pattern steps never create nodes: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)`, a stopped one `toggle_voice`. Never retrigger by toggling a voice off and on.
- Bounds-check every voice and step before indexing `S.patterns`.
- The pattern clock only syncs (`clock.sync`), so external clock sources keep working. `pattern_clock_start` cancels a running clock before starting a new one.
- Anything that changes a pattern or the playhead calls `grid_redraw()`.

## Owns

- `lib/sequencer.lua` (`S.lib.sequencer`):
  - `S.patterns` (built fresh by its constructor), the pattern clock state (`S.pattern_position`, `S.pattern_playing`, `S.pattern_clock`);
  - `toggle_pattern_step`, `clear_pattern`, `randomize_pattern`, `pattern_toggle`, `pattern_clock_start`, `pattern_clock_stop`, `step_brightness`;
  - cleanup step 90: the pattern clock stopped.
- Its unit tests: `test/unit/sequencer_test.lua`. The grid keys that edit patterns are in `docs/notes/lua/grid-core.md` (`step_key`) and each layout's notes.

## Pattern sequencer

- **Storage**: `S.patterns[voice_idx][step]`, `NUM_VOICES` × `PATTERN_LENGTH` steps, values 0-15. The 64 grid shows and edits only steps 1-8, but patterns still play all 16.
- **Playback clock**: `S.pattern_clock` uses `clock.run()` and `clock.sync(1/4)` for tempo-synced 16th notes against norns' global clock. The `tempo` param and the tempo handler are in `docs/notes/lua/params.md`. External clock sources still work because the sequencer only syncs.
- **Position**: `S.pattern_position` is the current step (1-16) and wraps around. Each tick triggers the step, redraws the grid (so the highlight shows the step that just played), then advances.
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
