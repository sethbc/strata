## Must not break

- MAIN is found by index (`S.ui_page == UI_PAGES.MAIN_PAGE`), never by its title string.
- No MAIN string between the header and the hint row crosses the divider at x=62: it ends by x=60 or starts at x=65 (the layout tests check it for every voice, source, lock and running state, and the fields at their widest values).
- Every voice-list entry is plain ASCII and at most `7+ pulse [L]` wide (59 px by the harness estimate, so it ends by x=60); a voice type's `MAIN_PARAMS[type].list_name` has at most 5 characters.
- The voice list never scrolls past an end: `place_voice_list()` sets `num_above_selected` to 0 for the first voice, 2 for the last and 1 otherwise, on every `update_voice_list()` and every draw (the selection can move without `update_voice_list`).
- The main parameter comes from `main_param_entry(voice_idx)` (`MAIN_PARAMS`, `BUFFER_MAIN_PARAM`, `INPUT_MAIN_PARAM`), never from an `if v.name ==` chain. E3, arc ring 2 and the details column all use it. The three fields come from `main_fields(voice_idx)`; E3 edits `main_fields(S.selected_voice)[S.main_field]` through `enc_param_delta`.
- K3 and MAIN's `arc_button` are the same function (`start_stop_selected_voice`): start or stop, never lock, never fire a triggered grain.
- Every ALT action goes through the record's `alt_key` (`alt_action`): ALT+K2 undoes only while `undo_available(S.selected_voice)`, else randomizes; ALT+K3 is `toggle_lock`. The ALT hint reads the same two conditions, so it never offers an undo the key would not run.
- A locked voice's fields are drawn at the same levels as an unlocked one's (the selected field 15, the others 4); `[L]` is drawn at 15.
- The name on y 18 is cut with `fit_text` to end `LAYOUT.name_gap` px before the right-aligned source, so the two never overlap. Under the harness estimate RESONATOR and KARPLUS are cut; with the norns font only RESONATOR is (`RESONAT`).

## Owns

- `lib/pages/main.lua` (`S.lib.pages_main`): the MAIN record (`S.registry.pages[UI_PAGES.index.MAIN]`, with `alt_key`, `arc_button` and `layout_states`), `redraw_main`, `main_enc`, `main_key`, `main_alt_key`, `main_hints`, `start_stop_selected_voice` (also `S.lib.pages_main.start_stop_selected_voice`), `S.lib.pages_main.LAYOUT`; the state `S.voice_list` and `S.main_field`; the globals `update_voice_list`, `main_param_id`, `main_param_entry`, `main_param_label`, `main_fields`.
- Its unit tests: `test/unit/pages_main_test.lua`. Its rings: `lib/arc/main.lua` (`docs/notes/lua/arc-pages.md`).

## Keys

`main_enc`, `main_key`, `main_alt_key` (3.1 design §2):
- E2 selects the voice (`S.lib.ui_keys.select_voice_by`), E3 adjusts the field under the cursor (`enc_param_delta`, so ALT+E3 is fine).
- K2 steps the cursor `S.main_field` 1 → 2 → 3 → 1. One cursor for every voice: each voice has three fields, so it never needs clamping.
- K3 starts or stops the selected voice (`toggle_voice`); the arc button does the same.
- ALT+K2: `undo_randomize()` while `undo_available(S.selected_voice)` (the `UNDO_SECONDS` window after a randomize of this voice; `lib/mutation.lua`), else `randomize_voice(S.selected_voice)` (a locked voice is left alone). ALT+K3: `toggle_lock(S.selected_voice)`.
- Hint row: `K2:field K3:start|stop`; with ALT `K2:rand|undo K3:lock|unlock`. The undo window's end redraws the hint without input (the undo clock calls `request_redraw()`).

## Main parameter and fields

- `main_param_id(voice_idx)` returns the param of field 1 and arc ring 2: `v<i>_freq` resonator, `_index` fm, `_fold` folder, `_drift` sub, `_width` pulse, `_decay` karplus, `_ratio` ring.
- `main_param_label(voice_idx)` returns its screen label.
- Both read `main_param_entry(voice_idx)`:
  - the `MAIN_PARAMS` entry for the voice type (param id suffix, screen label, value format; arc ring 2 sweeps it with `arc_sweep_param`);
  - `BUFFER_MAIN_PARAM` (`buf_pos`, label `pos`, `%.2f`) for a buffer source (3.0 design §1);
  - `INPUT_MAIN_PARAM` (`grain_size`, label `size`, `%.2f s`) for the input source (its synth and buffer params do nothing).
- `main_fields(voice_idx)` returns the three ids MAIN shows: `{main_param_id(i), "v<i>_grain_size", "v<i>_grain_density"}` for a synth or buffer voice, `{"v<i>_grain_size", "v<i>_grain_density", "v<i>_grain_pitch"}` for an input voice (its main param already is grain size).
- Field 1's label and format come from `main_param_entry`, the grain fields' from the module's `GRAIN_FIELDS`: `size` `%.2f s`, `dens` `%.0f /s`, `pitch` `%.2fx`.
- Arc ring 2 is drawn to `param_fraction(main_param_id(...))` of a turn, following the warp like the FX and BUFFER rings.

## Voice list

- `update_voice_list()` recreates the `UI.ScrollingList` (`S.voice_list`) on every change.
- Each entry is `<n><+|-> <name>[ [L]]`, plain ASCII, so its width does not depend on how the norns font draws other glyphs:
  - the voice number;
  - active status (`+` running, `-` stopped);
  - the voice type's short name, `MAIN_PARAMS[type].list_name` (`reso`, `fm`, `fold`, `sub`, `pulse`, `karp`, `ring`; at most 5 characters). The details column shows the full name and ON/OFF;
  - lock status (` [L]` suffix).
- Four rows (y 15-48). The norns `ScrollingList` leaves a blank first row when the first entry is selected with one row above the selection, so `place_voice_list()` sets `num_above_selected` per selection (0 first, 2 last, 1 otherwise): voices 1-4 for voice 1, 4-7 for voice 7.

## Layout

Two columns under the header (`draw_header()`, the same on every page: `docs/notes/lua/ui-core.md`), positions in `S.lib.pages_main.LAYOUT`:
- **Left column** (0-60 px): the voice list.
- **Divider** (x=62, y 10-52): a subtle vertical line.
- **Right column** (65-127 px), the selected voice:
  - y=18: the full name (level 15, cut to fit) and the source right-aligned at 127 (`voice_source_label`: `synth`, `buf 1`-`buf 8`, `input`; level 4);
  - y=26: `ON`/`OFF` (level 4) at x=65, `[L]` at x=87 (level 15) when locked, `[T]` at x=105 (level 8) in triggered grain mode. Fixed x, so nothing shifts as they come and go;
  - y=34, 42, 50: the three fields: the cursor `>` at x=65 on the selected one, the label at x=71, the value with its unit right-aligned at 127. The selected field is at 15, the others at 4, locked or not.
- `mod:` (crossmod sources) is not on MAIN; the VOICE page shows them.
- **Hint row** (y=62): see Keys.

`layout_states` (drawn by `test/unit/ui_layout_test.lua` and the page renders): every voice running, locked and triggered with the cursor on field 3, with voice 1 selected; the same with voice 7 on buffer 8; and voice 1 on the input.

Layout tests: `test/unit/pages_main_test.lua` draws the list for every voice, selection and running/locked state, MAIN for buffer- and input-sourced voices, and the fields at their minimum and maximum values for every voice, source and cursor position; `test/unit/ui_layout_test.lua` draws MAIN with every voice, source, ALT state and flash, and the layout states.
