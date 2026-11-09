## Must not break

- `engine.recordBuffer` is sent with the eight arguments of AGENTS.md's table, all from the record params (`record_source - 1`, feedback / 100, threshold as `10^(dB / 20)` or 0, loop 0/1, `delay` from `sync_delay`); the defaults send 3.2's take.
- The record params are PSET-only (never scene fields) and `record_buffer` computes the length: `record_beats` beats at the tempo when sent with sync, else `record_duration`, capped at `S.performance.buffer_seconds`.
- Only reports of the slot's newest recording (`records_sent`) act in the `recordState` handler. A replace take's timer starts at the "recording" report when it can be armed (sync or threshold), else at the send; a playable recording never settles (`finish_buffer_take`) and becomes `take <n>` at "ended". `state.started_at` is set at the "recording" report (and at the send for a recording that cannot be armed).
- `S.finish_buffer_take` stays the tests' handle on the local `finish_buffer_take`; its upvalue `BUFFER_SETTLE` is the table shared with `lib/buffers.lua` (`S.lib.buffers.BUFFER_SETTLE`).
- `S.buffer_record_clocks[slot]` holds both the recording timer and the finishing fallback, and every path that ends a recording (`settle_buffer_slot`, `load_buffer`, `clear_buffer`, the check's fallback in `lib/buffers.lua`, cleanup) cancels it through `S.lib.record.cancel_timer(slot)`.
- `S.lib.record.state(slot)` is nil when the slot is not recording. It is read after `record_buffer` sends the command (1d sets the state before `recording_started`).

## Owns

`lib/record.lua` (`S.lib.record`; included after `lib/buffers.lua`, whose `BUFFER_SETTLE` it reads at include time):
- `record_buffer(slot)` (global), the take timers (`S.buffer_record_clocks`), `finish_buffer_take` (`S.finish_buffer_take`);
- `S.buffers[slot].records_sent` (counted here; the field lives in `lib/buffers.lua`'s table);
- `S.lib.record.state(slot)`: nil when idle, else `{number, kind = "take" | "playable", phase = "armed" | "recording", started_at (nil while armed), seconds, loop}`; `any_recording()`, `any_armed()`;
- `add_params()` (the `strata_record` group, registered after `"buffers"`), the `recordState` poll (start step `record_poll`, cleanup step `record`);
- `S.lib.record.slot_reported(slot, seconds)` (`buffer_state_changed` calls it for a recording slot; it marks a playable recording loaded once it has a length), `S.lib.record.cancel_timer(slot)` and `S.lib.record.stop_all()` (`lib/buffers.lua`'s cleanup step calls it).

`lib/buffers.lua` keeps the slots, loads, clears, saves, the polls' decoding, `settle_buffer_slot` and `confirm_buffer_audio`; it exposes `S.lib.buffers.display_changed()` and the neutral `S.lib.buffers.recording_started(slot)` (`record_buffer` calls it after sending; 1e fills it).
