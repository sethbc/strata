## Must not break

- Peaks are read only in the module's clock loop (`START_ORDER.waveforms`, canceled by `CLEANUP_ORDER.waveforms`), at most one marked slot per `1 / FRAMES_PER_SECOND` tick, never in a draw, a poll callback or `stale`. A test checks that `io.open` waits for the clock.
- A peaks file is used only if its first line is `strata-peaks 1`, its `slot` is the slot's, it holds `WAVEFORM_POINTS` (64) values in 0-1, and `frames / rate` is within 0.01 s of the seconds the slot reports; otherwise the slot has no waveform until its next report. `peaks(slot)` is nil while the slot reports 0 s.
- A read that changes the values requests a redraw, and redraws the grid while one shows page 5. The same values again request nothing.
- The module is a constructor ending with `  return M` and `end`; its table is `S.lib.waveforms`.

## Owns

`lib/waveforms.lua`: peaks of each buffer slot's audio, for the BUFFER page's waveform and the grid's page 5. The engine writes `<data folder>/buf<n>.peaks` (`docs/notes/engine/waveform.md`) before it reports a slot's length.
- `stale(slot)` marks a slot (`lib/buffers.lua`'s `buffer_state_changed` calls it when a slot's seconds change to a non-zero value). The loop also marks a slot every `WAVEFORMS.refresh_seconds` (0.5 s) while `S.lib.record.state(slot).kind == "playable"` (due times advance by the interval, so a late tick never skips a read).
- `peaks(slot)`: the 64 values or nil. `bins(slot, n)`: n values, each the largest of the points it covers (the grid's 16 or 8 columns), or nil.
- `M.read_clock` is the loop's clock id and `M.stop()` stops it (the tests that isolate a clock use it).
