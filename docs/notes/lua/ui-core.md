## Must not break

- Each part of the UI core has its own notes file under docs/notes/lua/ui/ (listed below), each opening with its own "Must not break" list. Read the one for the part you change.
- The lock is called lock everywhere the user reads it (`[L]`, hints); the state and the scene field keep the name `frozen` (`S.frozen`, `toggle_lock`), so scene files load unchanged.
- The zones editor (`lib/ui/zones.lua`, 3.5) edits only params (`mpe_lower_members`, `mpe_upper_members`, `mpe_bend_range`, `v<i>_zone`, `v<i>_zone_low`, `v<i>_zone_high`), every E3 through `enc_param_delta`; it keeps no value of its own. It shows over the page only through `S.lib.ui_modal` (`push` at `open`, `pop` at `close`).
- Its learn waits exactly while its timeout clock runs (`S.zones_learn_clock`) and only while the editor is open; it ends at the second note, K2 (which closes the editor), a new learn, `ZONES_EDITOR.learn_seconds` (10 s) and the cleanup step (`CLEANUP_ORDER.zones_learn`, 117), and every end clears the note tap. Its end never cancels the clock once its resume may be posted (#626): within `ZONES_EDITOR.learn_wake_margin` (0.1 s) of the wake it is retired, as MOD's learn's (`docs/notes/lua/macros.md`). The `zones editor` invariant holds it.
- The note tap is the MIDI module's (`S.lib.midi_in.set_note_tap(fn | nil)`, package 2b's: while a tap is set, every MIDI note on goes to `fn(note)` first and is consumed when `fn` returns true). The editor sets `M.note` as the tap when a learn starts and `nil` when it ends, and calls it at no other time; a test stands in a double for it, and a layout state a do-nothing function.
- Note names are norns' own (`musicutil.note_num_to_name(note, true)`, 60 is `C3`: 0 is `C-2`, 127 is `G8`; plan ruling 28), so the editor names notes as every other norns script does. `C#-2` and `learn` are a column's widest texts.

## Files

The UI core's notes, one file per part:
- [pages-and-dispatch](ui/pages-and-dispatch.md): the page records, `UI_PAGES`, how `enc`, `key` and `redraw()` dispatch, adding a page.
- [header-and-flashes](ui/header-and-flashes.md): `draw_header()`, its positions and indicators, the header and hints flashes.
- [field-list-and-cursors](ui/field-list-and-cursors.md): `S.cursors`, the row cursors' anchors, `voice_page_rows` and its registered rows, the ring groups, `S.lib.ui_field_list`.
- [alt-and-keys](ui/alt-and-keys.md): ALT (K1 held), `alt_action`, key releases and keys held into the norns menu.
- [detents-and-fine](ui/detents-and-fine.md): `delta_with_detent`, `enc_param_delta`, fine adjustment and center detents.
- [redraws](ui/redraws.md): `request_redraw()`, the frame clock, draw errors and who asks for a redraw.
- [layout-and-renders](ui/layout-and-renders.md): the layout tests and the page renders.

## Owns

- `lib/ui/frame.lua` (`S.lib.ui_frame`): `S.ui_page`, `S.started` (set by init's first start step, `START_ORDER.started`; until then `redraw`, `key` and `enc` do nothing, #426); `request_redraw`, `S.lib.ui_frame.request_screen_redraw` (the screen alone, #434), `draw_frame`, `draw_frame_part`, `draw_error_report`, `S.lib.ui_frame.contained_call` (the one error containment of every clock step, `docs/notes/lua/ui/redraws.md`) and the frame clock (`start_frame_clock`, `stop_frame_clock`; cleanup step 60). The runtime fields (`screen_dirty`, `arc_dirty`, `frame_clock`, `draw_errors`) are on the shared `S.constants.UI_PAGES` table.
- `lib/ui/params.lua` (`S.lib.ui_params`): `set_binary_param`, `param_range`, `param_spans_zero`, `param_default`, `param_value_fraction`, `param_fraction`.
- `lib/ui/header.lua` (`S.lib.ui_header`): `draw_header`, `draw_hints`, `S.lib.ui_header.hint_fits(text)` (whether the hint row draws a text whole, #432). Its positions are `S.constants.HEADER` (`lib/constants.lua`).
- `lib/ui/flash.lua` (`S.lib.ui_flash`): the flashes, `S.lib.ui_flash.start`, `.text`, `.cancel_all`, `.slots`, `.add_notice` (3.4's standing notices), and `header_flash` (global); cleanup step 140.
- `lib/ui/text.lua` (`S.lib.ui_text`): `S.lib.ui_text.fit_text`, which cuts a whole UTF-8 character at a time and stops when a pass cuts nothing, so a text it cannot shorten (only continuation bytes) comes back as it is instead of looping (#514); `S.lib.ui_text.printable(text)`, a text as norns' font can draw it (#551): norns.ttf has glyphs for printable ASCII and next to nothing else, so printable ASCII stays, the letters of Latin-1 and Latin Extended-A become plain ones (`café` is `cafe`, `ß` is `ss`, `œ` is `oe`), and any other character, control character or byte that is not UTF-8 becomes one `?`. A file name is drawn through it wherever it shows (BUFFER's slot rows, the hint row) and measured as drawn, and loaded and saved by its real name.
- `lib/ui/field_list.lua` (`S.lib.ui_field_list`): stateless helpers for a page that is a list of fields with one cursor (`docs/notes/lua/ui/field-list-and-cursors.md`, Field lists). FX, VOICE, BUFFER and SETUP use it.
- `lib/ui/keys.lua` (`S.lib.ui_keys`): `S.key_press_page`, `S.alt_held`, `S.key_press_alt`, `forget_held_keys` (global); `set_ui_page` (runs the records' `leave`/`enter` and forgets carried arc ticks), `select_voice_by` (fields of `S.lib.ui_keys`).
- `lib/ui/alt.lua` (`S.lib.ui_alt`): `alt_action` (global); `set`, `run_release_hooks` and the randomizing pages' shared ALT+K2, `k2_down`, `k2_up`, `k2_held`, `k2_hint` (fields of `S.lib.ui_alt`). See `docs/notes/lua/ui/alt-and-keys.md`.
- `lib/ui/detent.lua` (`S.lib.ui_detent`): `delta_with_detent`, `enc_param_delta` (global); `as_turn` and `run_touch_hooks` (fields); the holds at 0 (local). See `docs/notes/lua/ui/detents-and-fine.md`.
- `lib/ui/modal.lua` (`S.lib.ui_modal`, 3.4): the modal screen owner's stack, `push`, `pop`, `top` (fields), and the `modal owner` invariant. See `docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner.
- `lib/ui/zones.lua` (`S.lib.ui_zones`, 3.5): the MPE and zones editor (below): `open`, `close`, `is_open`, `learn`, `cancel_learn`, `learning`, `note`, `ZONES_EDITOR` (fields), `S.zones_learn_clock`, the header notice `learn v<i> low|high`, cleanup step 117 and the `zones editor` invariant. Its unit tests: `test/unit/ui_zones_test.lua`.
- `lib/ui/menu_watch.lua` (`S.lib.ui_menu_watch`): the `_menu.set_mode` wrapper (`watch_menu_opening`, `unwatch_menu_opening`, `forget_keys_held_through_menu`; cleanup step 20).
- `lib/ui/voice_rows.lua` (`S.lib.ui_voice_rows`): `voice_page_rows`, `voice_page_group` (global); `first_field_row`, `GROUP_SIZE` (fields).
- `lib/ui/cursors.lua` (`S.lib.ui_cursors`): `S.cursors` and the row cursors' anchors; `move`, `sync`, `place`, `clamp_all` (fields).
- The page renders: `test/render_pages.lua` and `test/render_pages.py` (`docs/notes/lua/ui/layout-and-renders.md`).

Each page has its own notes file: `docs/notes/lua/pages/main.md`, `voice.md`, `seq.md`, `fx.md`, `lfo.md`, `buffer.md`, `scenes.md`, `setup.md`. The arc's rings for each page are in `docs/notes/lua/arc-pages.md`, the arc's dispatch in `docs/notes/lua/arc-core.md`.

## The zones editor

`lib/ui/zones.lua` (`S.lib.ui_zones`, 3.5 design §9.3): a modal owner (`docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner) that SETUP's `mpe & zones` row opens with K3 (`docs/notes/lua/pages/setup.md`). It takes the screen's body, the hints, E2, E3, K2 and K3 over whatever page is up; E1 does nothing and the arc's rings stay off while it is open.
- Rows (`ZONES_EDITOR`: six in view from y 18, 7 px apart, the scroll marker at x 127, as SETUP's): `lower members` (`mpe_lower_members`), `upper members` (`mpe_upper_members`), `bend range` (`mpe_bend_range`, `48 st`), each with its value right-aligned at x 124; then `v1` to `v7`, each with three columns: the zone (`v<i>_zone`: `off`, `lower`, `upper`) from x 20, the lowest note right-aligned at x 94 and the highest at x 124 (`v<i>_zone_low`, `v<i>_zone_high`, named as norns does: `C-2` to `G8`). The defaults read `v1 lower C-2 G8`, `v2 upper C-2 G8` and `off` for the rest.
- Levels: a count row under the cursor at 15, the other rows at 4; on the cursor's voice row the column under the cursor at 15 and the rest of the row at 8. While a learn waits, the column it waits for reads `learn` (15).
- E2 the row (clamped at both ends); K3 on a voice row the next column (zone, low, high, then the zone again; kept across rows and while closed); E3 the value under the cursor (`enc_param_delta`: whole steps, so ALT+E3 turns as E3 does). The zone params' own actions keep a range's lowest at or below its highest (`lib/mpe.lua`). K2 closes (ALT+K2 does nothing); a second `open` or a `close` of a closed editor does nothing.
- ALT+K3 on a voice row: `M.learn(voice)` (refused with the editor closed or for a voice outside 1..`NUM_VOICES`). The next note on (`M.note(note)`, a whole number 0-127, else not taken) sets the voice's lowest note, the one after its highest, swapped when the second is the lower; both are taken (`true`), so neither plays. The lowest is set before the highest, so neither param's action moves the other. A first note above the highest raises the highest with it (`lib/mpe.lua`), and a learn that ends after one note keeps that lowest. While it waits the header says `learn v<i> low` or `learn v<i> high` on every page (a standing notice, `S.lib.ui_flash.add_notice`; at most 56 px, inside the flash's 74).
- `M.learning()`: the voice and `"low"` or `"high"`, or nil.
- Hints: `K2:back E3:value` on a count row, `K2:back K3:column E3:value` on a voice row; with ALT held `E2:row`, and `E2:row K3:learn` on a voice row.
- Its layout states are SETUP's (`docs/notes/lua/pages/setup.md`): opened, v7's high at its widest, a learn waiting for v7's low and for its high.

`test/unit/ui_zones_test.lua`: the rows' defaults and every edit (the counts, the bend range, each column, K3's wrap, E2's ends, the levels); learn (the notice, the column, the two notes in either order, a first note above the highest, notes it refuses, ALT+K3 off a voice row, a closed editor); the ends (10 s, K2, cleanup) and the tap cleared at each; #626's retired clock; K2 and E1 while open; the hints; every row, column and ALT state at the widest values, and the learn states, inside the layout; the invariant.
