## Must not break

- buffers.data holds paths only, never audio. Audio reaches disk only when a take completes (the engine's scratch file) or on an explicit `buf<n>_save`.
- A buffers.data that cannot be loaded is moved aside to `buffers.data.bak`. If that fails, `S.buffer_autosave_blocked` makes cleanup skip the save, so a bad file is never silently overwritten.
- A remembered file that is missing at start keeps its path in `missing_path` and is saved again, so the sample comes back once the file is there. A clear, a load or a new recording in the slot forgets it.
- `S.buffers_restored` counts only the slots the engine's `bufferState` poll confirms holding audio.
- `buffer_load_failed` undoes exactly the load its `bufferLoadFailed` report names (by load number), never a later load, clear or recording.
- `BUFFER_STATE_STRIDE` (top of `lib/buffers.lua`, at the start of a line, where a test finds it) equals the engine's `bufferStateStride`.

## Owns

`lib/buffers.lua` (`S.lib.buffers`):
- the slots' state `S.buffers` (the per-slot fields are the buffers table in `docs/notes/engine.md`, Audio Sources, Lua side), `S.buffer_polls`, `S.buffer_record_clocks`, `S.buffers_restored`, `S.buffer_autosave_blocked`, `S.buffers_loaded`;
- recording, loading, clearing and saving (`record_buffer`, `load_buffer`, `clear_buffer`, `save_buffer`, ...);
- the `bufferState` and `bufferLoadFailed` poll handlers (`S.lib.buffers.buffer_state_changed`, `buffer_load_failed`), whose polls its start step (`START_ORDER.buffer_polls`) starts into `S.buffer_polls` at init;
- buffers.data (`save_buffers_to_disk`, `load_buffers_from_disk`, `buffer_data_file()`);
- two cleanup steps: 40 (save the buffer paths) and 130 (the polls and recording timers).

The BUFFER page is in `docs/notes/lua/ui-and-pages.md`, its arc rings in `docs/notes/lua/arc.md`, grid page 4 in `docs/notes/lua/grid-and-sequencer.md`.

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
