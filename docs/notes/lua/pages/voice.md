## Must not break

- The page file sets every record field but the arc fields; VOICE's rings are `lib/arc/voice.lua`'s (`docs/notes/lua/arc-pages.md`).
- The VOICE cursor is `S.cursors.voice`, a row index into `voice_page_rows(S.selected_voice)`; it and its anchor are `lib/ui/cursors.lua`'s (`docs/notes/lua/ui/field-list-and-cursors.md`). Every VOICE handler and the draw read it through `S.lib.pages_voice.sync_cursor()` (which is `S.lib.ui_cursors.sync("voice")`), never directly: it puts the cursor on the anchored param's row when the current rows have it and clamps from the anchored index only when they don't (ruling W7). It is idempotent (it never moves the anchor, so any number of calls from the page, the rings or between `clamp_all` runs give the same cursor) and returns `rows, cursor`. The rings (`lib/arc/voice.lua`) call `S.lib.ui_cursors.sync("voice")` themselves, never the page module.
- The anchor (the param key, the id without `v<i>_`, and its row index) changes only on deliberate moves: E2 (`S.lib.ui_cursors.move("voice", d)`, which anchors where it lands), K2/K3 and `S.lib.pages_voice.place_cursor(index)` (which is `S.lib.ui_cursors.place("voice", index)`). A source or voice change and back (A -> B -> A) therefore returns the cursor to its param, however many redraws and `clamp_all` runs happened in between. Code that puts the cursor on a row from outside VOICE's handlers uses `place_cursor` (or the module's `place`); a bare `S.cursors.voice = index` is taken back to the anchored param by the next sync.
- E3 edits through `enc_param_delta(3, id, d)` (never `params:delta`), so ALT+E3 is fine adjustment and the center detents apply. VOICE has no `alt_enc`: ALT+E2 moves the cursor in whole rows.
- ALT+K2 and ALT+K3 are the record's `alt_key`, reached only through `alt_action`; the plain K2/K3 never reset or lock.
- The arc button (`arc_button`) starts and stops the selected voice (`toggle_voice`, design §7), not K3's next-section jump, and never locks.
- The ring-group marks are drawn only while `S.arc_connected`, beside exactly the rows `voice_page_group(rows, cursor)` returns (those in view).
- Values come from the param itself (`params:string`, trailing spaces dropped), except mod sources (`<n> <list_name>` or `none`), and are cut with `fit_text` to the room after their label (at least `LAYOUT.value_gap` px), so no row overlaps for any voice, source or value. The layout tests draw every voice with every source and the cursor on the first and last row of each section (the record's `layout_states`), plus an arc-marked and a locked state.

## Owns

- `lib/pages/voice.lua` (`S.lib.pages_voice`): the VOICE record (`draw`, `hints`, `enc`, `key`, `alt_key`, `arc_button`, `layout_states`); `M.LAYOUT` (positions), `M.sync_cursor()` and `M.place_cursor(index)` (the page's names for `S.lib.ui_cursors.sync("voice")` and `.place("voice", index)`), `M.row_of(param_id)`.
- Its unit tests: `test/unit/pages_voice_test.lua`. The rows and ring groups it shows are `lib/ui/voice_rows.lua`'s (`voice_page_rows`, `voice_page_group`), tested in `test/unit/ui_cursors_test.lua`; the cursor is `lib/ui/cursors.lua`'s.

## The page

Layout (`M.LAYOUT`):
- y 16: the selected voice at x 0, level 10, as MAIN's list shows it (`<n><+|-> <list_name>`, ` [L]` when locked), cut with `fit_text` to end `line_gap` (6) px before the section text; the cursor's section and its position among the voice's sections (`grain 2/4`; an input voice has three) right-aligned at x 124, level 4.
- Rows through `S.lib.ui_field_list.draw`: 5 visible (`visible`) from y 24 (`first_y`), 7 px apart (`spacing`), so y 24-52; the view keeps one row above the cursor and the scroll marker is field_list's at x 127.
- Section label rows at x 0, level 2. Field rows: the label at x 3 (`field_x`), the value right-aligned at x 124 (`value_right`); the cursor row at level 15, the others at 4.
- While an arc is connected, each row of the cursor's ring group gets a 1×5 px filled rect at x 0 (`mark_x`), y - 4 .. y, level 8.

Keys and encoders:
- E2: `S.lib.ui_cursors.move("voice", d)` (from the synced cursor through field_list's move: section labels take no stop, so E2 at a section's end goes on into the next; clamped at the ends; anchored where it lands).
- E3: `enc_param_delta(3, row.param_id, d)` (option and number rows step whole values).
- K2: the first field of the previous section; in the first section, its own first field. K3: the first field of the next section; in the last section, nothing.
- ALT+K2: `params:set(id, param_default(id))` for the row under the cursor (on the source row this switches the source, and the rows follow). ALT+K3: `toggle_lock(S.selected_voice)`.
- Hints: `K2:prev K3:next`; ALT `K2:reset K3:lock`, or `K3:unlock` when the voice is locked.
- `arc_button`: `toggle_voice(S.selected_voice)`.

Cursor anchoring (ruling W7) is `lib/ui/cursors.lua`'s (`S.lib.ui_cursors.sync`/`place`/`move`, described in `docs/notes/lua/ui/field-list-and-cursors.md`); the page only calls it. With it, grain pitch stays grain pitch when the synth section goes or comes back and on the newly selected voice, pan comes back after a switch to input and back or to Sub and back, and a param the new rows lack (`rq` on an input voice, `index` on voice 1) clamps from the anchored index. `redraw()` runs `clamp_all()` before the page draws, which may move the index; the anchor, not the clamped index, decides. The screen draws before the arc in each frame (`draw_frame`), and the rings sync the cursor themselves, so they follow the same cursor even while the norns menu replaces the screen's redraw. `M.row_of(param_id)` gives a param's row index in the selected voice's rows (the layout states use it).
