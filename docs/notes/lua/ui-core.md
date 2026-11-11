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

- `lib/ui/frame.lua` (`S.lib.ui_frame`): `S.ui_page`; `request_redraw`, `draw_frame`, `draw_frame_part`, `draw_error_report` and the frame clock (`start_frame_clock`, `stop_frame_clock`; cleanup step 60). The runtime fields (`screen_dirty`, `arc_dirty`, `frame_clock`, `draw_errors`) are on the shared `S.constants.UI_PAGES` table.
- `lib/ui/params.lua` (`S.lib.ui_params`): `set_binary_param`, `param_range`, `param_spans_zero`, `param_default`, `param_value_fraction`, `param_fraction`.
- `lib/ui/header.lua` (`S.lib.ui_header`): `draw_header`, `draw_hints`. Its positions are `S.constants.HEADER` (`lib/constants.lua`).
- `lib/ui/flash.lua` (`S.lib.ui_flash`): the flashes, `S.lib.ui_flash.start`, `.text`, `.cancel_all`, `.slots`, and `header_flash` (global); cleanup step 140.
- `lib/ui/text.lua` (`S.lib.ui_text`): `S.lib.ui_text.fit_text`.
- `lib/ui/field_list.lua` (`S.lib.ui_field_list`): stateless helpers for a page that is a list of fields with one cursor (`docs/notes/lua/ui/field-list-and-cursors.md`, Field lists). FX, VOICE, BUFFER and SETUP use it.
- `lib/ui/keys.lua` (`S.lib.ui_keys`): `S.key_press_page`, `S.alt_held`, `S.key_press_alt`, `forget_held_keys` (global); `set_ui_page` (runs the records' `leave`/`enter` and forgets carried arc ticks), `select_voice_by`, `ignore_page_input` (fields of `S.lib.ui_keys`).
- `lib/ui/alt.lua` (`S.lib.ui_alt`): `alt_action` (global); `set` (a field of `S.lib.ui_alt`). See `docs/notes/lua/ui/alt-and-keys.md`.
- `lib/ui/detent.lua` (`S.lib.ui_detent`): `delta_with_detent`, `enc_param_delta` (global); the holds at 0 (local). See `docs/notes/lua/ui/detents-and-fine.md`.
- `lib/ui/menu_watch.lua` (`S.lib.ui_menu_watch`): the `_menu.set_mode` wrapper (`watch_menu_opening`, `unwatch_menu_opening`, `forget_keys_held_through_menu`; cleanup step 20).
- `lib/ui/voice_rows.lua` (`S.lib.ui_voice_rows`): `voice_page_rows`, `voice_page_group` (global); `first_field_row`, `GROUP_SIZE` (fields).
- `lib/ui/cursors.lua` (`S.lib.ui_cursors`): `S.cursors` and the row cursors' anchors; `move`, `sync`, `place`, `clamp_all` (fields).
- The page renders: `test/render_pages.lua` and `test/render_pages.py` (`docs/notes/lua/ui/layout-and-renders.md`).

Each page has its own notes file: `docs/notes/lua/pages/main.md`, `voice.md`, `seq.md`, `fx.md`, `lfo.md`, `buffer.md`, `scenes.md`, `setup.md`. The arc's rings for each page are in `docs/notes/lua/arc-pages.md`, the arc's dispatch in `docs/notes/lua/arc-core.md`.
