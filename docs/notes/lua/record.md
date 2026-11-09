## Must not break

- `engine.recordBuffer` is sent with the eight arguments of AGENTS.md's table: `feedback`, `source`, `threshold`, `loop` and `delay` are 0 (3.2's take) until the record package.
- `S.finish_buffer_take` stays the tests' handle on the local `finish_buffer_take`; its upvalue `BUFFER_SETTLE` is the table shared with `lib/buffers.lua` (`S.lib.buffers.BUFFER_SETTLE`).
- `S.buffer_record_clocks[slot]` holds both the recording timer and the finishing fallback, and every path that ends a recording (`settle_buffer_slot`, `load_buffer`, `clear_buffer`, the check's fallback in `lib/buffers.lua`, cleanup) cancels it through `S.lib.record.cancel_timer(slot)`.
- `S.lib.record.state(slot)` is nil when the slot is not recording. It is read after `record_buffer` sends the command (1d sets the state before `recording_started`).

## Owns

`lib/record.lua` (`S.lib.record`; included after `lib/buffers.lua`, whose `BUFFER_SETTLE` it reads at include time):
- `record_buffer(slot)` (global), the take timers (`S.buffer_record_clocks`), `finish_buffer_take` (`S.finish_buffer_take`);
- `S.buffers[slot].records_sent` (counted here; the field lives in `lib/buffers.lua`'s table);
- `S.lib.record.state(slot)`: nil when idle, else `{number, kind = "take", phase = "recording", started_at, seconds, loop = false}` while a slot records;
- `S.lib.record.slot_reported(slot, seconds)` (neutral; `buffer_state_changed` calls it for a recording slot), `S.lib.record.cancel_timer(slot)` and `S.lib.record.stop_all()` (`lib/buffers.lua`'s cleanup step calls it).

`lib/buffers.lua` keeps the slots, loads, clears, saves, the polls' decoding, `settle_buffer_slot` and `confirm_buffer_audio`; it exposes `S.lib.buffers.display_changed()` and the neutral `S.lib.buffers.recording_started(slot)` (`record_buffer` calls it after sending; 1e fills it).
