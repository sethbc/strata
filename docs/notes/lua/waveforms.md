## Must not break

- Peaks are read only in the module's clock loop (`START_ORDER.waveforms`, canceled by `CLEANUP_ORDER.waveforms`), at most one marked slot per `1 / FRAMES_PER_SECOND` tick, never in a draw, a poll callback or `stale`. A test checks that `io.open` waits for the clock.
- A peaks file is used only if its first line is `strata-peaks 1`, its `slot` is the slot's, it holds `WAVEFORM_POINTS` (64) values in 0-1, and `frames / rate` is within 0.01 s of the seconds the slot reports; otherwise the slot has no waveform until its next report. `peaks(slot)` is nil while the slot reports 0 s.
- A read that changes the values requests a redraw, and redraws the grid while one shows page 5. The same values again request nothing.
- **A slot whose length changes has no points until its new file is read** (#401): `buffer_state_changed` calls `changed(slot)` on every change of the slot's seconds, which forgets the points at once (a redraw, and a page-5 grid's) and marks the slot, so no frame draws the old audio's overview at the new length. A playable recording's rereads only mark the slot (`stale`): a dub's waveform never blinks.
- **Each tick runs contained** (#330): the loop calls its tick through `S.lib.ui_frame.contained_call` (key `"tick"`, label `peaks read`), so an error in a read or in the grid redraw it calls prints `strata: peaks read failed: ` with its traceback once per distinct message and never ends the loop; slots marked later are still read.
- The module is a constructor ending with `  return M` and `end`; its table is `S.lib.waveforms`.

## Owns

`lib/waveforms.lua`: peaks of each buffer slot's audio, for the BUFFER page's waveform and the grid's page 5. The engine writes `<data folder>/buf<n>.peaks` (`docs/notes/engine/waveform.md`) before it reports a slot's length.
- `changed(slot)` forgets a slot's points and marks it (`lib/buffers.lua`'s `buffer_state_changed` calls it when a slot's seconds change). `stale(slot)` only marks a slot (`lib/record.lua` calls it when a dub ends). The loop also marks a slot every `WAVEFORMS.refresh_seconds` (0.5 s) while `S.lib.record.state(slot).kind == "playable"` (due times advance by the interval, so a late tick never skips a read). The engine rewrites a recording slot's file only when its overview changed (`docs/notes/engine/waveform.md`, #523), so a reread then finds the same values and requests nothing.
- `peaks(slot)`: the 64 values or nil. `bins(slot, n)`: n values, each the largest of the points it covers (the grid's 16 or 8 columns), or nil.
- `M.read_clock` is the loop's clock id and `M.stop()` stops it (the tests that isolate a clock use it).
