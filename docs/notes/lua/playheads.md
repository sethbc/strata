## Must not break

- **The estimate restarts where the engine's scan does.** `S.register_grain_restart` resets a voice's phase (a `voiceOn`, a running voice's source switch), `S.lib.positions.jump` after a jump, `S.lib.positions.restart_scan` at a scan mode change (lib/scan.lua), the module's `voice_hit` hook at a hit on a one-shot voice's own note (`info.slot == 1`, as the engine's `positionsHit`), and `S.lib.notes.set_own_region` at every region it sends (package 2b) but a one-shot voice's hit, whose retrigger the hook resets for: one reset per engine restart. A new place that restarts a voice's scan must reset the playhead too.
- **The phase is integrated at the rate the engine has**, a speed over the span in play (the own note's region from `S.lib.notes.own_region`, else the loop; 3.7, ruling 29): `engine_param_value("v<i>_buf_scan") x (1 - frozen) x (1 - scan_held) / (span length x slot seconds) + scrub_rate` spans a second (the glide stays in spans a second). The scan's value carries tempo follow's factor. Anything that changes the hold or the glide's rate first calls `S.lib.playheads.advance(v)` (positions does), so the elapsed time is counted at the old rate.
- **The modes are the engine's** (`slotScanPosition`): wrap wraps `min(buf_pos, 0.999999) + phase`, so `buf_pos` 1 is the span's last start, as the engine plays it (`lastLoopPosition`, #726); bounce keeps the phase over 0-2 and folds the sum; one shot never wraps the phase and holds the sum at the span's edges, and `finished(v)` is true once the sum is strictly past 1 or below 0 (the engine's silence: exactly 1 sounds).
- **A following voice advances in beats** (`S.lib.scan.following(v)`): the beats since its last advance (none for a beat that went back) at `beat_seconds_now()`, so the bar sync (`docs/notes/lua/scan.md`) gives the engine a phase on the beat. `phase(v)` is that phase as `syncScan` takes it.
- `position`, `spread`, `column`, `record_head`, `has_audio` and `moving` are read-only and send nothing. `position` is nil unless a buffer voice runs; `record_head` is nil unless the slot records playably (a replace take plays nothing, an armed take has no head).
- Pages and grids read the waveform, the heads and the bookmarks only through `S.lib.waveforms`, `S.lib.playheads` and `S.lib.positions`, and send no engine command to show them (BUFFER's side: `docs/notes/lua/pages/buffer.md`).
- A failing tick never ends the clock, and a fault in one part of the tick never skips another (`guarded_tick`, see States): a fault in one voice's estimate no longer keeps the tick from releasing a gone grid's hold on another voice. The remaining case: when the held voice's own estimate keeps failing, the release's `advance` (in `set_scan_hold`) raises after the holder is removed, so the holder goes but the hold stays until the voice restarts (a voice sync empties its holders and sends `scanHold 0`); the `"scan holds"` invariant would report it. One clock (`PLAYHEADS.update_hz`, 15), started by the `playheads` start step and canceled by the `playheads` cleanup step (`CLEANUP_ORDER.playheads`). It never draws the screen: BUFFER's `animates()` reads `moving(slot)`.
- The clock redraws the grid (`grid_redraw()`) only when some grid shows positions (the position page, 5, `POSITION_PAGE` in the module, from `S.constants.GRID_PAGES.positions`, or the page its layout record names as `strip_page`: the 128h's page 4 shows the grid voice's strip) and `S.lib.positions.display_signature()` differs from the one at its last look. Its first look at a grid that just arrived draws too, so a change made within the tick of arrival is never missed (#322). Param actions never redraw the position page themselves: the poll catches a changed `buf_pos`, loop, bookmark, a scene fade or an LFO within one tick (a ruling for 3.3: no package owns every param action).
- The 15 Hz clock also ends stale grid holds (`S.lib.positions.end_stale_holds()`); a hold it releases redraws every grid through `S.lib.positions` (the hold key shows the hold on every page that has it), not through the position-page rule above.

## Owns

`lib/playheads.lua` (`S.lib.playheads`): where each running buffer voice's grains start, and the record head.

```
phase       = phase + scan_effective x dt (dt in seconds, or beats x beat_seconds_now while following),
              wrapped to 0-1 in wrap, 0-2 in bounce, unbounded in one shot
position(v) = span start + fraction x span length, where fraction is
              (min(buf_pos, 0.999999) + phase) wrapped (wrap), (buf_pos + phase) folded (bounce)
              or clipped to 0-1 (one shot)
```

- `position(v)` integrates up to now (so it is exact between ticks at the current rate); the clock keeps an LFO-moved scan followed within a tick. The span is the own note's region while it has one (2b's `S.lib.notes.own_region(v)`: the positional `{start, length}`, read as `[1]` and `[2]`; a module without it means none until 2b lands), else the loop; its length is cut at the slot's end, as the engine's `slotSpan` cuts it.
- `phase(v)` (0-1 wrap, 0-2 bounce, one shot as it runs) and `finished(v)` (a one shot that has played out) are nil and false unless a buffer voice runs. The mode is `S.lib.scan.mode(v)`.
- `spread(v)` is `v<i>_grain_spread x` the span's length for a running buffer voice. `cell_of(fraction, columns)` and `column(v, columns)` give a cell 1..columns (a rounding above a cell's edge still counts).
- `record_head(slot)`: from the `S.lib.record.state(slot)` report (`kind` `"playable"`, `phase` `"recording"`, `started_at` at the "recording" report, `seconds` D, `loop`) and the valid length `max(S.buffers[slot].seconds, D)`: elapsed time wrapped over D in loop mode, stopped at D in a one-shot, as a fraction of the valid length.
- `has_audio(slot)`: whether the slot reports audio (`S.buffers[slot].seconds > 0`; false for a bad slot). The one check of whether a head means anything on a slot: BUFFER draws heads, spreads and bookmark ticks only then, and the grid's position rows (`S.lib.positions`' `row_context`) stay dark otherwise (#433). An empty slot and one recording a replace take report none.
- `moving(slot)`: true when something drawn on the slot moves: its record head (`record_head(slot)`, a playable recording), or a running buffer voice reading it while it `has_audio`. A replace take, an armed recording and voices on an empty slot move nothing, so BUFFER's `animates()` stays false then (#433).
- `reset(v)`, `advance(v)` and `clock_id()` (the cleanup test) are the module's other functions.

Tests: `test/unit/playheads_test.lua` (the integration as a speed, an LFO-moved scan, freeze, the hold and the glide, the resets, nil answers, spread, column, an 8 s slot crossed in 8 s at scan 1, bounce's turns, the one shot's stop and its restart at a hit, the own region (a double for 2b's `own_region`), `buf_pos` 1 at the last start (#726), the beats of a following voice (a double for 2d's `tempo`), the record head, `moving`, the grid redraw rule and the cleanup).

## States

| State | Fields | Legal values | Transition |
|-------|--------|--------------|------------|
| the clock | `clock_id` | nil (stopped) or a running clock | `start_clock` (the start step) and `stop_clock` (cleanup) |
| the last error of each tick part | `last_errors[key]`, `key` one of `TICK_PARTS`' `"scan"`, `"holds"`, `"blink"`, `"redraw"` | nil, or the `message` key of that part's error last printed | `guarded_tick`: a part that runs well sets its key nil, a failing one prints its traceback once per distinct message |

- The tick is four parts, in order (`TICK_PARTS`): follow the scans (`advance` per running buffer voice), end the stale grid holds (`end_stale_holds`), count a tick for the waiting-bookmark blink (`S.lib.positions.advance_blink`, #593; the blink's levels are in `docs/notes/lua/positions.md`), and redraw the position-page grids. Each runs through its own `S.lib.ui_frame.contained_call(last_errors, key, "playhead tick", run)` (the frame clock's helper, so both clocks key a repeated error alike), so an error in one (an estimate, `end_stale_holds`, a signature, a redraw) is printed as `strata: playhead tick failed: ...`, never ends the clock and never skips the other parts.
