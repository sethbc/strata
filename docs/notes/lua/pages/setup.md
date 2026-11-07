## Must not break

- `grid.add`/`grid.remove`/`arc.add`/`arc.remove`/`midi.add`/`midi.remove` call `request_redraw()`, so SETUP's status lines stay current (drawn on the next frame).
- The MIDI device name is cut with `fit_text` to end by x 124 (the scroll marker owns x 127), so a long norns device name never leaves the screen.
- E3 edits a control or option field through `enc_param_delta` (ALT+E3 fine steps apply). `mutation_enabled` is a binary param with no range, so E3 sets it directly (right = on, left = off); never send it through `enc_param_delta`.
- K3 runs only a save/load field; on every other field it does nothing. The cursor (`S.setup_cursor`) only ever rests on the eight fields; the status rows are `selectable = false`.
- The grid-size line exists only while a grid is connected.
- SETUP has no arc fields: its rings stay dark and ignore turns.

## Owns

- `lib/pages/setup.lua` (`S.lib.pages_setup`): the SETUP record, `redraw_setup`, `setup_key`, `setup_hints`, `setup_enc` (global), `S.setup_cursor`, `layout_states`.
- Its unit tests: `test/unit/pages_setup_test.lua`.

## The page

A `S.lib.ui_field_list` page of 8 fields and 3 or 4 status rows, 7 rows visible at y 18-54 (6 px apart), with the scroll marker at x 127:
- Fields: `midi 1: <device>` (port, `midi_device`; the device from `midi_device_name()`), `channels` (`midi_channel_mode`), `mutations` (on/off), `mutation rate` (`%.1f s`), `mutation prob`, `mutation amt` (`%.2f`), `save scenes`, `load scenes`.
- Status rows (level 10, sizes line level 4): `grid: n connected`, the sizes (`16x16 16x8`, port order), `arc: connected|none`, `buffers: k restored` or `buffers: k ok, m missing`.
- E2 moves over the fields (the view keeps one row above the cursor, so the status rows show once the cursor is on the last fields), E3 edits, K3 calls `save_scenes_to_disk` / `load_scenes_from_disk`.
- Hints `E2:field E3:value`, plus `K3:save` or `K3:load` on those fields.
- The saved-scene count is no longer on this page (the SCENES page shows its slots).
- `layout_states`: scrolled to each end, two grids and an arc, buffers missing, a long MIDI device name.
