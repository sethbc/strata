## Must not break

- `grid.add`/`grid.remove`/`arc.add`/`arc.remove`/`midi.add`/`midi.remove` call `request_redraw()`, so SETUP's status lines stay current (drawn on the next frame).
- The MIDI device name is cut with `fit_text` to end by x 124 (the scroll marker owns x 127), so a long norns device name never leaves the screen.
- E3 edits a control or option field through `enc_param_delta` (ALT+E3 fine steps apply). `mutation_enabled` is a binary param with no range, so E3 sets it directly (right = on, left = off); never send it through `enc_param_delta`.
- K3 runs only a save/load field, by calling its record's `run` (a function that calls `save_scenes_to_disk`/`load_scenes_from_disk` as it runs), never a global looked up by name; on every other field it does nothing. The cursor (`S.setup_cursor`) only ever rests on the fields; the status and note rows are `selectable = false`. The fields are looked up through the rows (`setup_rows()[S.setup_cursor]`), since the buffer length field comes and goes.
- The performance fields edit the setting through `S.lib.performance.set_setting` (saved at once to `performance.data`), never a param: no PSET or scene holds them. A change applies at the next start. When `set_setting` returns false (the write failed) the field keeps its old value and SETUP's hint row flashes `setting not saved` (`S.lib.ui_flash`, #236).
- The performance fields' notes go on dim rows below them, indented 8 px: the layout test's width estimate cannot fit `performance` with `high (next start)` on one 124 px row.
- The grid-size line exists only while a grid is connected.
- SETUP has no arc fields: its rings stay dark and ignore turns.

## Owns

- `lib/pages/setup.lua` (`S.lib.pages_setup`): the SETUP record, `redraw_setup`, `setup_key`, `setup_hints`, `setup_enc` (global), `S.setup_cursor`, `layout_states`; on the module, `SETUP_FIELDS`, `SETUP_PAGE` (the page's layout constants: row spacing, note indent, ..., exported for the tests) and `setup_rows()` (the rows as drawn now, for the tests).
- Its unit tests: `test/unit/pages_setup_test.lua`.

## The page

A `S.lib.ui_field_list` page of 9 or 10 fields, their note rows and 4 or 5 status rows, 7 rows visible at y 18-54 (6 px apart), with the scroll marker at x 127:
- Fields (each row starts with its field's `label`): `midi 1: <device>` (label `midi`, then the port, `midi_device`, and the device from `midi_device_name()`), `channels` (`midi_channel_mode`), `mutations` (on/off), `mutation rate` (`%.1f s`), `mutation prob`, `mutation amt` (`%.2f`), `save scenes`, `load scenes`, `performance` (auto, standard, high) and `buffer length` (16, 60, 120, 300 s; shown when the setting or the running tier is high).
- Note rows (level 4, at x 8), below both performance fields (so the view, which keeps one row above the cursor, shows `performance` above `buffer length` when the cursor is on the length): `(next start)` when a shown field differs from the setting this start used (`S.performance_start_setting`) and `may xrun` when the setting is high and `norns.platform` is 2 (CM3) or 3 (Pi 3), joined as `(next start), may xrun`; then `300 s -> 120 s (memory)` (`(meminfo)` when the engine could not read meminfo and took the shortest length, `S.lib.performance.step_down_cause()`) when the high tier runs a shorter length than the unchanged setting asks for. A further dim note row sits directly under the `running:` row when `S.lib.performance.running_note()` says why the running tier is not what the engine decided: `active file not written` or `old active file kept`.
- Status rows (level 10, sizes line level 4): `running: high, 60 s` or `running: standard` (`S.performance`), `grid: n connected`, the sizes (`16x16 16x8`, port order), `arc: connected|none`, `buffers: k restored` or `buffers: k ok, m missing`.
- E2 moves over the fields (the view keeps one row above the cursor, so the status rows show once the cursor is on the last fields), E3 edits (a performance field steps its choices, clamped at the ends), K3 calls the field's `run` (`save_scenes_to_disk` / `load_scenes_from_disk`).
- Hints `E2:field E3:value`, plus `K3:save` or `K3:load` on those fields.
- The saved-scene count is no longer on this page (the SCENES page shows its slots).
- `layout_states`: scrolled to each end, two grids and an arc, buffers missing, a long MIDI device name, and the performance fields: standard, the high setting on a CM3 while standard runs (both notes and the buffer length's `(next start)`), the memory step-down, and the active file not written.
