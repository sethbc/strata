## Must not break

- buffers.data holds paths only, never audio. Audio reaches disk only when a take completes (the engine's scratch file) or on an explicit `buf<n>_save`.
- A buffers.data that cannot be loaded is moved aside to `buffers.data.bak`. If that fails, `S.buffer_autosave_blocked` makes cleanup skip the save, so a bad file is never silently overwritten.
- A remembered file that is missing at start keeps its path in `missing_path` and is saved again, so the sample comes back once the file is there. A clear, a load or a new recording in the slot forgets it.
- `S.buffers_restored` counts only the slots the engine's `bufferState` poll confirms holding audio.
- `buffer_load_failed` undoes exactly the load its `bufferLoadFailed` report names (by load number), never a later load, clear or recording.
- A save is called saved (console `saved to <path>`, BUFFER `saved buf <n>`) only from its `bufferSaveResult` report, never when `save_buffer` sends it (#127). `buffer_save_result` flashes only for the slot's newest save (by save number), so a late report never speaks for a newer save.
- `BUFFER_STATE_STRIDE` (top of `lib/buffers.lua`, at the start of a line, where a test finds it) equals the engine's `bufferStateStride`.
- Lengths come from `S.performance.buffer_seconds` (16 s standard, up to 300 s high), never a constant: `record_buffer` caps a take at it and the BUFFER page sizes its seconds column from it.

## Owns

`lib/buffers.lua` (`S.lib.buffers`):
- the slots' state `S.buffers` (the per-slot fields are the buffers table in `docs/notes/engine.md`, Audio Sources, Lua side), `S.buffer_polls`, `S.buffer_record_clocks`, `S.buffers_restored`, `S.buffer_autosave_blocked`, `S.buffers_loaded`;
- recording, loading, clearing and saving (`record_buffer`, `load_buffer`, `clear_buffer`, `save_buffer`, ...);
- the `bufferState`, `bufferLoadFailed` and `bufferSaveResult` poll handlers (`S.lib.buffers.buffer_state_changed`, `buffer_load_failed`, `buffer_save_result`), whose polls its start step (`START_ORDER.buffer_polls`) starts into `S.buffer_polls` at init;
- buffers.data (`save_buffers_to_disk`, `load_buffers_from_disk`, `buffer_data_file()`);
- two cleanup steps: 40 (save the buffer paths) and 130 (the polls and recording timers).

## Long buffers

On the high tier a slot holds up to `S.performance.buffer_seconds` (60, 120 or 300 s). `record_duration` ranges up to it (its spec reads it at init) and `record_buffer` sends at most that. The engine checks a file longer than 16 s in a routine before the load takes effect: meanwhile the slot keeps its old audio and reports its old length, so `load_buffer`'s optimistic name settles on that report (or, over an empty slot, settles empty after `BUFFER_SETTLE.confirm_seconds` and is adopted when the new length arrives, as for a slow read). A load superseded during its check is dropped without a `bufferLoadFailed` report; a later load that fails leaves the checked one to apply, which is the state `buffer_load_failed` puts back. A remembered 300 s file restored on a 60 s tier loads its first 60 s (the engine caps the read), and the poll reports 60.

## Save results

`save_buffer(slot)` returns true when it sends `saveBuffer` (the slot reports audio), false otherwise. It counts the slot's saves in `saves_sent` (the engine counts the same commands, from 1) and keeps `{number, path}` in `pending_saves` (the newest `BUFFER_SETTLE.tracked_saves`, 4: on the high tier a 300 s save takes seconds and saves can overlap, but keeping only the newest 4 is still safe, since the flash depends only on `saves_sent` and dropping an older entry only loses that save's console line), and prints `buffer <n> saving to <path>`. `buffer_save_result(value)` (global; the `bufferSaveResult` poll's callback) decodes `slot = value % NUM_BUFFERS + 1`, then from `floor(value / NUM_BUFFERS)` the `failed` bit (its lowest) and the save number (the rest), ignoring NaN, infinities, negative and fractional values. A number not in `pending_saves` (a repeat, a save never sent, one older than the tracked four) does nothing. Otherwise the entry is removed and the console says `buffer <n> saved to <path>` or `buffer <n>: cannot save <path> (...)`; the BUFFER page flashes `saved buf <n>` or `buf <n> save failed` only when it is the slot's newest save (`number == saves_sent`), so an older save's late report, in either order, never replaces what the newer save shows. Loads, clears and recordings leave `pending_saves` alone: a report is about the file written, not what the slot holds now. Why the engine reports both outcomes is under Save results in `docs/notes/engine/files.md`.

The BUFFER page is in `docs/notes/lua/pages/buffer.md`, its arc rings in `docs/notes/lua/arc-pages.md`, grid page 4 in `docs/notes/lua/grid/layout_256.md`.

## buffers.data

Location: `~/dust/data/strata/buffers.data` (`buffer_data_file()`).
- It sits in the scenes' folder, `S.lib.scenes.scene_data_dir`, which `buffer_data_file()` reads at call time.

Saving (`save_buffers_to_disk()`):
- writes `{version = BUFFER_DATA_VERSION, paths = {[n] = S.buffers[n].path or S.buffers[n].missing_path or ""}}`;
- per slot, the loaded file or scratch take, or a remembered file that was missing on start;
- `cleanup()` calls it after the scenes save (step 40), but only once `load_buffers_from_disk()` has run in this session (`S.buffers_loaded`, set when it returns), so a start that failed before init's restore never overwrites the saved paths with empty slots (#72).

Loading (`load_buffers_from_disk()`, from its start step `START_ORDER.buffers_load`, after the scenes load):
- resets `S.buffers_restored` and `S.buffer_autosave_blocked` first;
- `load_buffer`s each non-empty path that `util.file_exists`, and marks the slot `restoring`;
- `S.buffers_restored` counts only the slots the poll then confirms holding audio.
- A path that exists but that the engine cannot load (unreadable, unsupported, empty or damaged) is reported by `bufferLoadFailed`. The slot goes back to empty and the path is not saved again.
- A path that does not exist (deleted, or on an unmounted drive) is not loaded. The slot stays empty, the console names it, and it is kept in `missing_path`.
- SETUP shows `buffers: k restored`, or `buffers: k ok, m missing` (m = slots with a `missing_path`; "restored" would not fit beside the missing count).

A bad file, handled as the scenes file is:
- `tab.load` runs through `pcall`;
- on an error, a non-table, another version or no `paths` table, the file is moved to `buffers.data.bak` (shared helper `S.lib.scenes.move_aside_unloadable_file(data_file, label)`, defined in `lib/scenes.lua`);
- if the move fails, `S.buffer_autosave_blocked` makes `cleanup()` skip the save.
