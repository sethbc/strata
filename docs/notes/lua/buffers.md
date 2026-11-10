## Must not break

- buffers.data holds paths only, never audio. Audio reaches disk only when a take completes (the engine's scratch file) or on an explicit `buf<n>_save`.
- A buffers.data that cannot be loaded is moved aside to `buffers.data.bak`. If that fails, `S.buffer_autosave_blocked` makes cleanup skip the save, so a bad file is never silently overwritten.
- A remembered file that is missing at start keeps its path in `missing_path` and is saved again, so the sample comes back once the file is there. A clear, a load or a new recording in the slot forgets it.
- `S.buffers_restored` counts only the slots the engine's `bufferState` poll confirms holding audio.
- `buffer_load_failed` undoes exactly the load its `bufferLoadFailed` report names (by load number), never a later load, clear or recording.
- A save is called saved (console `saved to <path>`, BUFFER `saved buf <n>`) only from its `bufferSaveResult` report, never when `save_buffer` sends it (#127). `buffer_save_result` flashes only for the slot's newest save (by save number), so a late report never speaks for a newer save.
- `BUFFER_STATE_STRIDE` (top of `lib/buffers.lua`, at the start of a line, where a test finds it) equals the engine's `bufferStateStride`.
- `BUFFER_DATA_VERSION` is 2 (`starts`); version 1 files still load, with every start 0. A start reload (`set_start`) is canceled by a load, clear or recording in its slot, and never runs while the slot records.
- A playable recording (a dub) keeps the file's `start`, `sample_rate` and `file_seconds` until its "ended" report makes the slot `take <n>` (start 0, neither field); a canceled one keeps all three (#244). `recording_started` is told the take's kind (`record_buffer` calls it before it sets `recording`, so `S.lib.record.state` cannot say).
- `buffer_state_changed` marks the slot's peaks stale (`S.lib.waveforms.stale`) when its seconds change to a non-zero value, and reads nothing itself.
- Lengths come from `S.performance.buffer_seconds` (16 s standard, up to 300 s high), never a constant: `record_buffer` caps a take at it and the BUFFER page sizes its seconds column from it.

## Owns

`lib/buffers.lua` (`S.lib.buffers`):
- the slots' state `S.buffers` (the per-slot fields are the buffers table in `docs/notes/engine/buffers.md`, Audio Sources: Lua side, with `records_sent` that `lib/record.lua` counts), `S.buffer_polls`, `S.buffers_restored`, `S.buffer_autosave_blocked`, `S.buffers_loaded`;
- loading, clearing and saving (`load_buffer(slot, path, start)`, `clear_buffer`, `save_buffer` (the whole slot: region 0, 1), `save_buffer_loop`, ...); recording is `lib/record.lua`'s (`docs/notes/lua/record.md`);
- the files' start point (`S.lib.buffers.set_start`, `recording_started`, below);
- the `bufferState`, `bufferLoadFailed` and `bufferSaveResult` poll handlers (`S.lib.buffers.buffer_state_changed`, `buffer_load_failed`, `buffer_save_result`), whose polls its start step (`START_ORDER.buffer_polls`) starts into `S.buffer_polls` at init;
- buffers.data (`save_buffers_to_disk`, `load_buffers_from_disk`, `buffer_data_file()`);
- three cleanup steps: 40 (save the buffer paths), 128 (`buffer_start_reload`: the pending start reloads) and 130 (the polls and recording timers).

## Long buffers

On the high tier a slot holds up to `S.performance.buffer_seconds` (60, 120 or 300 s). `record_duration` ranges up to it (its spec reads it at init) and `record_buffer` sends at most that. The engine checks a file longer than 16 s in a routine before the load takes effect: meanwhile the slot keeps its old audio and reports its old length. So `load_buffer` asks norns how long the file is (`audio.file_info(path)`: channels, frames, rate) and, when the engine will check it (`checked_before_load`: a tier above 16 s, and more frames than 16 s at `BUFFER_SETTLE.server_rate`, 48 kHz, counting only what the slot reads: at most `buffer_seconds` at the file's rate and the server's), sets `checking_from` to the length shown before the load (#171). While it is set, `buffer_state_changed` stores each report but settles nothing as long as the report equals it; the first report that differs (the 0 s of the load taking effect, or the new length over an empty slot) clears it and restarts `confirm_since`, and the load then settles as any load does. The BUFFER page shows `...` for the length meanwhile. A clear, a new recording or another load clears it, and `buffer_load_failed` puts back the failed load's state, `checking_from` included (a short load that fails while a long one checks leaves the check running). A file `audio.file_info` cannot open (0 frames) is never marked: the engine rejects it at once.
- **Fallback**: a check no report ends never leaves the row at `...`. The load starts `start_check_fallback` in `buffer_record_clocks[slot]` (which a load, clear, recording and cleanup cancel, and the end of the check cancels too); after `BUFFER_SETTLE.check_fallback_seconds` (30 s) with `checking_load` still that load, the slot gets the state the load replaced (its `pending_loads` entry's `previous`, which is then dropped, so a late failure report for it changes nothing; an empty slot if it is no longer tracked) and the console says so. 30 s is about 45 times a 300 s load on a desktop (0.4-0.65 s, `docs/notes/engine/files.md`), for a Pi's slower FLAC decoding. A failed later load that puts back an earlier check starts that check's fallback again (`buffer_load_failed`).
- **The server rate**: `checked_before_load` assumes 48 kHz (`BUFFER_SETTLE.server_rate`). Lua cannot learn the engine's rate: `performance_active.data` holds the tier, lengths, grain count and reason, and the `bufferState` poll seconds only. norns runs JACK and scsynth at 48 kHz; a file Lua misjudges near the 16 s edge only shows `...` until the engine's first report, or loads as before. A load superseded during its check is dropped without a `bufferLoadFailed` report; a later load that fails leaves the checked one to apply, which is the state `buffer_load_failed` puts back. A remembered 300 s file restored on a 60 s tier loads its first 60 s (the engine caps the read), and the poll reports 60.

## The start point of a long file

`S.buffers[slot].start` (seconds into the slot's file, 0 for a new file) is sent with every load of the slot (`engine.loadBuffer(slot, path, start)`), kept in buffers.data and put back by a failed load (`buffer_state_before_load` and `apply_buffer_state` carry `start`, `sample_rate` and `file_seconds` with the rest). `sample_rate` and `file_seconds` come from `audio.file_info` at each load (nil for a file it cannot open, and after a take or a clear).
- `S.lib.buffers.set_start(slot, seconds)` clamps to `[0, file_seconds - S.performance.buffer_seconds]` and reloads the file there `FILES.restart_seconds` (0.3 s) after the last call: one clock per slot (`M.start_reload_clocks`), restarted by each call, canceled by `load_buffer`, `clear_buffer`, `recording_started` and its cleanup step (`CLEANUP_ORDER.buffer_start_reload`), and cleared by the clock itself before it calls `load_buffer`. It does nothing for a file that fits the slot, for a slot with no file length, and while `S.lib.record.state(slot)` is non-nil.
- `S.lib.buffers.recording_started(slot, playable)` (lib/record.lua's `record_buffer` calls it after it sends `recordBuffer`, with the `playable` it computed) cancels the pending reload either way. A replace take (`playable` false or nil) sets the start to 0 and forgets `sample_rate` and `file_seconds`, since a take is at the server rate and has no file; a playable recording leaves all three, since the slot keeps the file's audio. Its "ended" report (`record_state_changed`, `docs/notes/lua/record.md`) sets them as a replace take does; its "canceled" report changes none of them.
- `buffer_state_before_load(slot)` keeps the slot's state during a playable recording, so a failed load restores the slot as it was; during a replace take the slot still comes back empty.

### States

The file fields across a recording (`S.buffers[slot]`; `recording` and the take's kind are `lib/record.lua`'s):

| State | `start` | `sample_rate`, `file_seconds` | Entered by |
|-------|---------|-------------------------------|------------|
| a file | where the file is read from (0 for a new file) | the file's, from `audio.file_info` (nil if it cannot open) | `load_buffer` |
| a replace take recording | 0 | nil | `recording_started(slot, false)` |
| a playable recording (dub) | the file's, unchanged | the file's, unchanged | `recording_started(slot, true)` |
| a take (`take <n>`) or empty | 0 | nil | the take settling, a dub's "ended" report, `clear_buffer` |

A dub's "canceled" report goes back to the file state with the fields as they were; `set_start` acts only in the file state.

## Trim

`save_buffer_loop(slot)` (global) saves the loop region of the selected voice if it reads the slot, else of the lowest-numbered voice that does, else the whole slot (`engine.saveBuffer(slot, path, start, length)`, fractions), to `<audio>/strata/<YYYYMMDD-HHMMSS>-buf<n>-loop.wav`. Its `pending_saves` entry has `loop = true`, so the result flashes `saved buf <n> loop`.

## Save results

`save_buffer(slot)` returns true when it sends `saveBuffer` (the slot reports audio), false otherwise. It counts the slot's saves in `saves_sent` (the engine counts the same commands, from 1) and keeps `{number, path}` in `pending_saves` (the newest `BUFFER_SETTLE.tracked_saves`, 4: on the high tier a 300 s save takes seconds and saves can overlap, but keeping only the newest 4 is still safe, since the flash depends only on `saves_sent` and dropping an older entry only loses that save's console line), and prints `buffer <n> saving to <path>`. `buffer_save_result(value)` (global; the `bufferSaveResult` poll's callback) decodes `slot = value % NUM_BUFFERS + 1`, then from `floor(value / NUM_BUFFERS)` the `failed` bit (its lowest) and the save number (the rest), ignoring NaN, infinities, negative and fractional values. A number not in `pending_saves` (a repeat, a save never sent, one older than the tracked four) does nothing. Otherwise the entry is removed and the console says `buffer <n> saved to <path>` or `buffer <n>: cannot save <path> (...)`; the BUFFER page flashes `saved buf <n>` or `buf <n> save failed` only when it is the slot's newest save (`number == saves_sent`), so an older save's late report, in either order, never replaces what the newer save shows. Loads, clears and recordings leave `pending_saves` alone: a report is about the file written, not what the slot holds now. Why the engine reports both outcomes is under Save results in `docs/notes/engine/files.md`.

The BUFFER page is in `docs/notes/lua/pages/buffer.md`, its arc rings in `docs/notes/lua/arc-pages.md`, grid page 4 in `docs/notes/lua/grid/layout_256.md`.

## buffers.data

Location: `~/dust/data/strata/buffers.data` (`buffer_data_file()`).
- It sits in the scenes' folder, `S.lib.scenes.scene_data_dir`, which `buffer_data_file()` reads at call time.

Saving (`save_buffers_to_disk()`):
- writes `{version = BUFFER_DATA_VERSION, paths = {[n] = S.buffers[n].path or S.buffers[n].missing_path or ""}, starts = {[n] = S.buffers[n].start}}` (version 2, 3.3; a missing file keeps its start with its path);
- per slot, the loaded file or scratch take, or a remembered file that was missing on start;
- `cleanup()` calls it after the scenes save (step 40), but only once `load_buffers_from_disk()` has run in this session (`S.buffers_loaded`, set when it returns), so a start that failed before init's restore never overwrites the saved paths with empty slots (#72).

Loading (`load_buffers_from_disk()`, from its start step `START_ORDER.buffers_load`, after the scenes load):
- resets `S.buffers_restored` and `S.buffer_autosave_blocked` first;
- `load_buffer`s each non-empty path that `util.file_exists` at its start, clamped to what the file now leaves after a slot's length (version 1, 3.2's, has none: every start is 0; a start that is not a number is 0), and marks the slot `restoring` until it settles (with audio, or empty as `settled_empty = "restore"`, which a late report of audio still adopts and counts);
- `S.buffers_restored` counts only the slots the poll then confirms holding audio.
- A path that exists but that the engine cannot load (unreadable, unsupported, empty or damaged) is reported by `bufferLoadFailed`. The slot goes back to empty and the path is not saved again.
- A path that does not exist (deleted, or on an unmounted drive) is not loaded. The slot stays empty, the console names it, and it is kept in `missing_path`.
- SETUP shows `buffers: k restored`, or `buffers: k ok, m missing` (m = slots with a `missing_path`; "restored" would not fit beside the missing count).

A bad file, handled as the scenes file is:
- `tab.load` runs through `pcall`;
- on an error, a non-table, a version other than 1 or 2 or no `paths` table, the file is moved to `buffers.data.bak` (shared helper `S.lib.scenes.move_aside_unloadable_file(data_file, label)`, defined in `lib/scenes.lua`);
- if the move fails, `S.buffer_autosave_blocked` makes `cleanup()` skip the save.
