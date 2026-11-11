## Must not break

- **The estimate restarts where the engine's scan does.** `S.register_grain_restart` resets a voice's phase (a `voiceOn`, a running voice's source switch), and `S.lib.positions.jump` resets it after a jump. A new place that restarts a voice's scan must reset the playhead too.
- **The phase is integrated at the rate the engine has**: `engine_param_value("v<i>_buf_scan") x (1 - frozen) x (1 - scan_held) + scrub_rate` (loop fractions a second, never slot seconds). Anything that changes the hold or the glide's rate first calls `S.lib.playheads.advance(v)` (positions does), so the elapsed time is counted at the old rate.
- `position`, `spread`, `column` and `record_head` are read-only and send nothing. `position` is nil unless a buffer voice runs; `record_head` is nil unless the slot records playably (a replace take plays nothing, an armed take has no head).
- A failing tick never ends the clock, and a fault in one part of the tick never skips another (`guarded_tick`, see States): a fault in one voice's estimate no longer keeps the tick from releasing a gone grid's hold on another voice. The remaining case: when the held voice's own estimate keeps failing, the release's `advance` (in `set_scan_hold`) raises after the holder is removed, so the holder goes but the hold stays until the voice restarts (a voice sync empties its holders and sends `scanHold 0`); the `"scan holds"` invariant would report it. One clock (`PLAYHEADS.update_hz`, 15), started by the `playheads` start step and canceled by the `playheads` cleanup step (`CLEANUP_ORDER.playheads`). It never draws the screen: BUFFER's `animates()` reads `moving(slot)`.
- The clock redraws the grid (`grid_redraw()`) only when some grid shows the position page (5, `POSITION_PAGE` in the module) and `S.lib.positions.display_signature()` changed since its last redraw. Param actions never redraw the position page themselves: the poll catches a changed `buf_pos`, loop, bookmark, a scene fade or an LFO within one tick (a ruling for 3.3: no package owns every param action).
- The 15 Hz clock also ends stale grid holds (`S.lib.positions.end_stale_holds()`); a hold it releases redraws every grid through `S.lib.positions` (the hold key shows the hold on every page that has it), not through the position-page rule above.

## Owns

`lib/playheads.lua` (`S.lib.playheads`): where each running buffer voice's grains start, and the record head.

```
phase       = (phase + scan_effective x dt) wrapped to 0-1, from the last tick or reset
position(v) = loop_start + ((buf_pos + phase) wrapped) x loop_length
```

- `position(v)` integrates up to now (so it is exact between ticks at the current rate); the clock keeps an LFO-moved scan followed within a tick. `buf_pos` wraps with the phase: `buf_pos` 1 is the loop's start again, as the engine's `Phasor` wraps.
- `spread(v)` is `v<i>_grain_spread x loop_length` for a running buffer voice. `cell_of(fraction, columns)` and `column(v, columns)` give a cell 1..columns (a rounding above a cell's edge still counts).
- `record_head(slot)`: from the `S.lib.record.state(slot)` report (`kind` `"playable"`, `phase` `"recording"`, `started_at` at the "recording" report, `seconds` D, `loop`) and the valid length `max(S.buffers[slot].seconds, D)`: elapsed time wrapped over D in loop mode, stopped at D in a one-shot, as a fraction of the valid length.
- `moving(slot)`: true when the slot's recording state is `"recording"` (not armed) or a running buffer voice reads it.
- `reset(v)`, `advance(v)` and `clock_id()` (the cleanup test) are the module's other functions.

Tests: `test/unit/playheads_test.lua` (the integration, an LFO-moved scan, freeze, the hold and the glide, the resets, nil answers, spread, column, the record head, `moving`, the grid redraw rule and the cleanup).

## States

| State | Fields | Legal values | Transition |
|-------|--------|--------------|------------|
| the clock | `clock_id` | nil (stopped) or a running clock | `start_clock` (the start step) and `stop_clock` (cleanup) |
| the last error of each tick part | `last_errors[key]`, `key` one of `TICK_PARTS`' `"scan"`, `"holds"`, `"redraw"` | nil, or the `message` key of that part's error last printed | `guarded_tick`: a part that runs well sets its key nil, a failing one prints its traceback once per distinct message |

- The tick is three parts, in order (`TICK_PARTS`): follow the scans (`advance` per running buffer voice), end the stale grid holds (`end_stale_holds`), and redraw the position-page grids. Each runs through its own `S.lib.ui_frame.contained_call(last_errors, key, "playhead tick", run)` (the frame clock's helper, so both clocks key a repeated error alike), so an error in one (an estimate, `end_stale_holds`, a signature, a redraw) is printed as `strata: playhead tick failed: ...`, never ends the clock and never skips the other parts.
