## Must not break

- Each part of the UI core has its own notes file under docs/notes/lua/ui/ (listed below), each opening with its own "Must not break" list. Read the one for the part you change.
- The lock is called lock everywhere the user reads it (`[L]`, hints); the state and the scene field keep the name `frozen` (`S.frozen`, `toggle_lock`), so scene files load unchanged.

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
- `lib/ui/menu_watch.lua` (`S.lib.ui_menu_watch`): the `_menu.set_mode` wrapper (`watch_menu_opening`, `unwatch_menu_opening`, `forget_keys_held_through_menu`; cleanup step 20).
- `lib/ui/voice_rows.lua` (`S.lib.ui_voice_rows`): `voice_page_rows`, `voice_page_group` (global); `first_field_row`, `GROUP_SIZE` (fields).
- `lib/ui/cursors.lua` (`S.lib.ui_cursors`): `S.cursors` and the row cursors' anchors; `move`, `sync`, `place`, `clamp_all` (fields).
- The page renders: `test/render_pages.lua` and `test/render_pages.py` (`docs/notes/lua/ui/layout-and-renders.md`).

Each page has its own notes file: `docs/notes/lua/pages/main.md`, `voice.md`, `seq.md`, `fx.md`, `lfo.md`, `buffer.md`, `scenes.md`, `setup.md`. The arc's rings for each page are in `docs/notes/lua/arc-pages.md`, the arc's dispatch in `docs/notes/lua/arc-core.md`.
