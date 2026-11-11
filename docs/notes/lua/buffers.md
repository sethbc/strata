## Must not break

- buffers.data holds paths only, never audio. Audio reaches disk only when a take completes (the engine's scratch file) or on an explicit `buf<n>_save`.
- A buffers.data that cannot be loaded is moved aside to `buffers.data.bak`. If that fails, `S.buffer_autosave_blocked` makes cleanup skip the save, so a bad file is never silently overwritten.
- A remembered file that is missing at start keeps its path in `missing_path` and is saved again, so the sample comes back once the file is there. A clear, a load or a new recording in the slot forgets it.
- `S.buffers_restored` counts only the slots the engine's `bufferState` poll confirms holding audio.
- `buffer_load_failed` undoes exactly the load its `bufferLoadFailed` report names (by load number), never a later load, clear or recording.
- The busy check lives in `save_buffer` and `save_buffer_loop` (#246), not in a caller: no `saveBuffer` is sent for a slot that is `recording` or `finishing`, whoever asks (the `buf<n>_save` param, the BUFFER page). Both go through one local `send_save`, which counts and tracks the save.
- A save is called saved (console `saved to <path>`, BUFFER `saved buf <n>`) only from its `bufferSaveResult` report, never when `save_buffer` sends it (#127). `buffer_save_result` flashes only for the slot's newest save (by save number), so a late report never speaks for a newer save.
- `BUFFER_STATE_STRIDE` (top of `lib/buffers.lua`, at the start of a line, where a test finds it) equals the engine's `bufferStateStride`.
- `BUFFER_DATA_VERSION` is 2 (`starts`); version 1 files still load, with every start 0. A start reload (`set_start`) is canceled by a load, clear or recording in its slot, and never runs while the slot records.
- A playable recording (a dub) keeps the file's `start`, `sample_rate` and `file_seconds` until its "ended" report makes the slot `take <n>` (start 0, neither field); a canceled one keeps all three (#244). `recording_started` is told the take's kind (`record_buffer` calls it before it sets `recording`, so `S.lib.record.state` cannot say).
- The poll decoders (`buffer_state_changed`, `buffer_load_failed`, `buffer_save_result`, and `lib/record.lua`'s `record_state_changed`) floor the slot they decode: matron hands every poll value over as a float, and on Lua 5.3 a slot of `3.0` names a take `take 3.0` and its file param `buf3.0_file` (#300). The `"buffer slots"` invariant checks the result: a name of the form `take <number>` is the slot's own `take <n>`, and a path in the scratch folder named `buf*.wav` is `buf<whole number>.wav`.
- `buffer_state_changed` marks the slot's peaks stale (`S.lib.waveforms.stale`) when its seconds change to a non-zero value, and reads nothing itself.
- Lengths come from `S.performance.buffer_seconds` (16 s standard, up to 300 s high), never a constant: `record_buffer` caps a take at it and the BUFFER page sizes its seconds column from it.
- What a slot holds has one answer, `S.lib.buffers.status(slot)` (States, below), derived only: it stores nothing and no field changes for it. Whether a slot is free is `S.lib.buffers.is_free(slot)` (status `"empty"` or `"missing"`), and the fill (`S.lib.files.fill_empty`), BUFFER's seconds column (`slot_is_empty`) and the grid's source and record keys (`source_level`, level 2; `record_level`, from the status) read only it, never a test of their own (#247).

## Owns

`lib/buffers.lua` (`S.lib.buffers`):
- the slots' state `S.buffers` (the per-slot fields are the buffers table in `docs/notes/engine/buffers.md`, Audio Sources: Lua side, with `records_sent` that `lib/record.lua` counts), `S.buffer_polls`, `S.buffers_restored`, `S.buffer_autosave_blocked`, `S.buffers_loaded`;
- what a slot holds, `S.lib.buffers.status(slot)` and `is_free(slot)` (States, below);
- loading, clearing and saving (`load_buffer(slot, path, start)`, `clear_buffer`, `save_buffer` (the whole slot: region 0, 1), `save_buffer_loop`, ...); recording is `lib/record.lua`'s (`docs/notes/lua/record.md`);
- the files' start point (`S.lib.buffers.set_start`, `recording_started`, below);
- the `bufferState`, `bufferLoadFailed` and `bufferSaveResult` poll handlers (`S.lib.buffers.buffer_state_changed`, `buffer_load_failed`, `buffer_save_result`), whose polls its start step (`START_ORDER.buffer_polls`) starts into `S.buffer_polls` at init;
- buffers.data (`save_buffers_to_disk`, `load_buffers_from_disk`, `buffer_data_file()`);
- three cleanup steps: 40 (save the buffer paths), 128 (`buffer_start_reload`: the pending start reloads) and 130 (the polls and recording timers).

## States

`S.lib.buffers.status(slot)` is what the slot holds: the first of these cases that applies, read from `S.buffers[slot]` and the take `S.lib.record.state(slot)` (nil unless `recording`). It is nil only for a slot out of range (`status(0)`, `status(9)`, a non-number); every valid slot has one. `is_free(slot)` is true for `"empty"` and `"missing"` only (false out of range).

| # | Status | Fields that encode it | Entered by | Free |
|---|--------|------------------------|------------|------|
| 1 | `"finishing"` | `finishing` (with `recording`, `confirm_since`): a replace take that ended and waits for the engine's length, whatever the take's phase (an armed replace take stopped with K3 finishes until its "canceled" report) | `finish_buffer_take` (`lib/record.lua`: the take's timer, a stop, an "ended" report) | no |
| 2 | `"armed"` | `recording`, the take's `phase == "armed"` (a delay or a threshold) | `record_buffer` | no |
| 3 | `"loop"`, `"dub"`, `"recording"` | `recording`, with a playable take (`kind == "playable"`) that loops, one that does not, or a replace take (also a recording with no take) | `record_buffer`, the "recording" report (`record_state_changed`) | no |
| 4 | `"loading"` | `confirm_since` set: a load the engine has not confirmed, checking (`checking_from`) or not | `load_buffer` | no |
| 5 | `"loaded"` | `loaded` | `settle_buffer_slot` or `confirm_buffer_audio` from a report of audio, a dub's "ended" report with a length, `buffer_load_failed` putting a loaded state back | no |
| 6 | `"unsettled"` | `settled_empty == "load"` or `"restore"`: a named load (`name` kept) that reported no length yet; a later report of audio adopts it (`"loaded"`) | `settle_buffer_slot` (a 0 s report `BUFFER_SETTLE.confirm_seconds` after the load) | no |
| 7 | `"missing"` | `missing_path` set: a remembered file not found at start, kept for buffers.data | `restore_buffers_from_file` | yes |
| 8 | `"empty"` | none of the above (a canceled take may keep `settled_empty == "take"`, which a later report of audio still adopts) | init, `clear_buffer`, a replace take that settled without audio, a replace take's "canceled" report, a dub's "ended" report that arrives with 0 s (`take <n>`, not loaded), a dub canceled while armed over an unsettled slot (`record_buffer` cleared its `settled_empty`), `buffer_load_failed` with an empty state | yes |

The fields stay what other code and the tests read (`loaded`, `recording`, `finishing`, `seconds`, `name`, ...); `status` adds no field. A dub canceled while armed over an unsettled slot leaves a named, free slot: BUFFER shows its name without a length, and the fill may load over it. `buffer_load_failed` and a check's fallback (`start_check_fallback`) can put back any of cases 4-8 from the state a load replaced (`apply_buffer_state`). A load, a clear and a recording leave a state by setting its fields (`load_buffer`, `clear_buffer`, `record_buffer`); the `"buffer slots"` invariant (`finishing` only with `recording`, `checking_from` only with `confirm_since`, never `settled_empty` with `loaded`) keeps the cases apart.

### The file fields

The file fields across a recording (`S.buffers[slot]`; `recording` and the take's kind are `lib/record.lua`'s):

| State | `start` | `sample_rate`, `file_seconds` | Entered by |
|-------|---------|-------------------------------|------------|
| a file | where the file is read from (0 for a new file) | the file's, from `audio.file_info` (nil if it cannot open) | `load_buffer` |
| a replace take recording | 0 | nil | `recording_started(slot, false)` |
| a playable recording (dub) | the file's, unchanged | the file's, unchanged | `recording_started(slot, true)` |
| a file again, after a canceled dub | the file's, unchanged | the file's, unchanged | a dub's "canceled" report (`record_state_changed` in `lib/record.lua`) |
| a take (`take <n>`) or empty | 0 | nil | a replace take settling (`settle_buffer_slot`; `recording_started` already set the fields), a dub's "ended" report (`record_state_changed`), a replace take's "canceled" report (`record_state_changed`: empty), `clear_buffer` |

## Long buffers

On the high tier a slot holds up to `S.performance.buffer_seconds` (60, 120 or 300 s). `record_duration` ranges up to it (its spec reads it at init) and `record_buffer` sends at most that. The engine checks a file longer than 16 s in a routine before the load takes effect: meanwhile the slot keeps its old audio and reports its old length. So `load_buffer` asks norns how long the file is (`audio.file_info(path)`: channels, frames, rate) and, when the engine will check it (`checked_before_load`: a tier above 16 s, and more frames than 16 s at `BUFFER_SETTLE.server_rate`, 48 kHz, counting only what the slot reads: at most `buffer_seconds` at the file's rate and the server's), sets `checking_from` to the length shown before the load (#171). While it is set, `buffer_state_changed` stores each report but settles nothing as long as the report equals it; the first report that differs (the 0 s of the load taking effect, or the new length over an empty slot) clears it and restarts `confirm_since`, and the load then settles as any load does. The BUFFER page shows `...` for the length meanwhile. A clear, a new recording or another load clears it, and `buffer_load_failed` puts back the failed load's state, `checking_from` included (a short load that fails while a long one checks leaves the check running). A file `audio.file_info` cannot open (0 frames) is never marked: the engine rejects it at once.
- **Fallback**: a check no report ends never leaves the row at `...`. The load starts `start_check_fallback` in `buffer_record_clocks[slot]` (which a load, clear, recording and cleanup cancel, and the end of the check cancels too); after `BUFFER_SETTLE.check_fallback_seconds` (30 s) with `checking_load` still that load, the slot gets the state the load replaced (its `pending_loads` entry's `previous`, which is then dropped, so a late failure report for it changes nothing; an empty slot if it is no longer tracked) and the console says so. 30 s is about 45 times a 300 s load on a desktop (0.4-0.65 s, `docs/notes/engine/files.md`), for a Pi's slower FLAC decoding. A failed later load that puts back an earlier check starts that check's fallback again (`buffer_load_failed`).
- **The server rate**: `checked_before_load` assumes 48 kHz (`BUFFER_SETTLE.server_rate`). Lua cannot learn the engine's rate: `performance_active.data` holds the tier, lengths, grain count and reason, and the `bufferState` poll seconds only. norns runs JACK and scsynth at 48 kHz; a file Lua misjudges near the 16 s edge only shows `...` until the engine's first report, or loads as before. A load superseded during its check is dropped without a `bufferLoadFailed` report; a later load that fails leaves the checked one to apply, which is the state `buffer_load_failed` puts back. A remembered 300 s file restored on a 60 s tier loads its first 60 s (the engine caps the read), and the poll reports 60.

## The start point of a long file

`S.buffers[slot].start` (seconds into the slot's file, 0 for a new file) is sent with every load of the slot (`engine.loadBuffer(slot, path, start)`), kept in buffers.data and put back by a failed load (`buffer_state_before_load` and `apply_buffer_state` carry `start`, `sample_rate` and `file_seconds` with the rest). `sample_rate` and `file_seconds` come from `audio.file_info` at each load (nil for a file it cannot open, and after a take or a clear).
- `S.lib.buffers.set_start(slot, seconds)` clamps to `[0, file_seconds - S.performance.buffer_seconds]` and reloads the file there `FILES.restart_seconds` (0.3 s) after the last call: one clock per slot (`M.start_reload_clocks`), restarted by each call, canceled by `load_buffer`, `clear_buffer`, `recording_started` and its cleanup step (`CLEANUP_ORDER.buffer_start_reload`), and cleared by the clock itself before it calls `load_buffer`. It does nothing for a file that fits the slot, for a slot with no file length, and while `S.lib.record.state(slot)` is non-nil.
- `S.lib.buffers.recording_started(slot, playable)` (lib/record.lua's `record_buffer` calls it after it sends `recordBuffer`, with the `playable` it computed) cancels the pending reload either way. A replace take (`playable` false or nil) sets the start to 0 and forgets `sample_rate` and `file_seconds`, since a take is at the server rate and has no file; a playable recording leaves all three, since the slot keeps the file's audio. Its "ended" report (`record_state_changed`, `docs/notes/lua/record.md`) sets them as a replace take does; its "canceled" report changes none of them.
- `buffer_state_before_load(slot)` keeps the slot's state during a playable recording, so a failed load restores the slot as it was; during a replace take the slot still comes back empty.

`set_start` acts only in the file state (States, The file fields).

`sent_start` is the start of the load last sent for the slot. `set_start` writes `start` at once and reloads 0.3 s later, so during that wait `start` is ahead of the file the engine holds; a load's snapshot (`buffer_state_before_load`) records `sent_start`, so a failed start reload puts the previous start back (#245). It is 0 at init, after `clear_buffer`, a replace take (`recording_started(slot, false)`), a dub's "ended" report and `empty_buffer_state`; `load_buffer` sets it to the start it sends and `apply_buffer_state` to the state's start. `buffers.data` saves `start`. The `"buffer slots"` invariant states that `start == sent_start` unless a start reload is pending (`start_reload_clocks[slot]`). Everything that cancels a reload without sending it keeps that true: a playable recording starting inside the wait sets `start` back to `sent_start` (the new start was never loaded), and the cleanup step that cancels reloads does the same after `buffers.data` is saved, so a script exit inside the 0.3 s saves the new, untried start (the player's last choice), which the next launch then tries. A remembered file missing at startup sets both fields. Loads that fail out of order each put back the start recorded in their own snapshot, so the slot ends at the start of the oldest failed load's predecessor.

## Trim

`save_buffer_loop(slot)` (global) saves the loop region of the selected voice if it reads the slot, else of the lowest-numbered voice that does, else the whole slot (`engine.saveBuffer(slot, path, start, length)`, fractions), to `<audio>/strata/<YYYYMMDD-HHMMSS>-buf<n>-loop.wav`. Its `pending_saves` entry has `loop = true`, so the result flashes `saved buf <n> loop`.

## Save results

`save_buffer(slot)` and `save_buffer_loop(slot)` return true when they send `saveBuffer`, else false and a reason: `"invalid"` (not a slot), `"busy"` (the slot is `recording` or `finishing`; one console line) or `"empty"` (no audio reported). The page flashes from the reason. It counts the slot's saves in `saves_sent` (the engine counts the same commands, from 1) and keeps `{number, path}` in `pending_saves` (the newest `BUFFER_SETTLE.tracked_saves`, 4: on the high tier a 300 s save takes seconds and saves can overlap, but keeping only the newest 4 is still safe, since the flash depends only on `saves_sent` and dropping an older entry only loses that save's console line), and prints `buffer <n> saving to <path>`. `buffer_save_result(value)` (global; the `bufferSaveResult` poll's callback) decodes `slot = value % NUM_BUFFERS + 1`, then from `floor(value / NUM_BUFFERS)` the `failed` bit (its lowest) and the save number (the rest), ignoring NaN, infinities, negative and fractional values. A number not in `pending_saves` (a repeat, a save never sent, one older than the tracked four) does nothing. Otherwise the entry is removed and the console says `buffer <n> saved to <path>` or `buffer <n>: cannot save <path> (...)`; the BUFFER page flashes `saved buf <n>` or `buf <n> save failed` only when it is the slot's newest save (`number == saves_sent`), so an older save's late report, in either order, never replaces what the newer save shows. Loads, clears and recordings leave `pending_saves` alone: a report is about the file written, not what the slot holds now. Why the engine reports both outcomes is under Save results in `docs/notes/engine/files.md`.

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
