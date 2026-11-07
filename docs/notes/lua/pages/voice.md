## Must not break

- The page file sets every record field but the arc fields; VOICE's rings are `lib/arc/voice.lua`'s (`docs/notes/lua/arc-pages.md`).
- The VOICE cursor is `S.cursors.voice`, a row index into `voice_page_rows(S.selected_voice)`. Every VOICE handler and the draw read it through `S.lib.pages_voice.sync_cursor()`, never directly: it re-anchors the cursor on its param when the rows changed under it (a source switch, another selected voice) and only then clamps (ruling W7). Code that reads the cursor outside VOICE's handlers (the rings) calls `sync_cursor()` too, or at least `S.lib.ui_cursors.clamp_all()` (`docs/notes/lua/ui-core.md`, Cursors and VOICE rows).
- Code that puts the cursor on a row from outside VOICE's handlers and `S.lib.ui_cursors.move` uses `S.lib.pages_voice.place_cursor(index)`, which drops the anchor; a bare `S.cursors.voice = index` made while the rows also change is taken back to the old param by the next `sync_cursor`.
- E3 edits through `enc_param_delta(3, id, d)` (never `params:delta`), so ALT+E3 is fine adjustment and the center detents apply. VOICE has no `alt_enc`: ALT+E2 moves the cursor in whole rows.
- ALT+K2 and ALT+K3 are the record's `alt_key`, reached only through `alt_action`; the plain K2/K3 never reset or lock.
- The arc button (`arc_button`) starts and stops the selected voice (`toggle_voice`, design §7), not K3's next-section jump, and never locks.
- The ring-group marks are drawn only while `S.arc_connected`, beside exactly the rows `voice_page_group(rows, cursor)` returns (those in view).
- Values come from the param itself (`params:string`, trailing spaces dropped), except mod sources (`<n> <list_name>` or `none`), and are cut with `fit_text` to the room after their label (at least `LAYOUT.value_gap` px), so no row overlaps for any voice, source or value. The layout tests draw every voice with every source and the cursor on the first and last row of each section (the record's `layout_states`), plus an arc-marked and a locked state.

## Owns

- `lib/pages/voice.lua` (`S.lib.pages_voice`): the VOICE record (`draw`, `hints`, `enc`, `key`, `alt_key`, `arc_button`, `layout_states`); `M.LAYOUT` (positions), `M.sync_cursor()`, `M.place_cursor(index)`.
- Its unit tests: `test/unit/pages_voice_test.lua`. The rows and ring groups it shows are `lib/ui/voice_rows.lua`'s (`voice_page_rows`, `voice_page_group`), tested in `test/unit/ui_cursors_test.lua`; the cursor is `lib/ui/cursors.lua`'s.

## The page

Layout (`M.LAYOUT`):
- y 16: the selected voice at x 0, level 10, as MAIN's list shows it (`<n><+|-> <list_name>`, ` [L]` when locked), cut with `fit_text` to end `line_gap` (6) px before the section text; the cursor's section and its position among the voice's sections (`grain 2/4`; an input voice has three) right-aligned at x 124, level 4.
- Rows through `S.lib.ui_field_list.draw`: 5 visible (`visible`) from y 24 (`first_y`), 7 px apart (`spacing`), so y 24-52; the view keeps one row above the cursor and the scroll marker is field_list's at x 127.
- Section label rows at x 0, level 2. Field rows: the label at x 3 (`field_x`), the value right-aligned at x 124 (`value_right`); the cursor row at level 15, the others at 4.
- While an arc is connected, each row of the cursor's ring group gets a 1×5 px filled rect at x 0 (`mark_x`), y - 4 .. y, level 8.

Keys and encoders:
- E2: `S.lib.ui_cursors.move("voice", d)` (field_list's move: section labels take no stop, so E2 at a section's end goes on into the next; clamped at the ends).
- E3: `enc_param_delta(3, row.param_id, d)` (option and number rows step whole values).
- K2: the first field of the previous section; in the first section, its own first field. K3: the first field of the next section; in the last section, nothing.
- ALT+K2: `params:set(id, param_default(id))` for the row under the cursor (on the source row this switches the source, and the rows follow). ALT+K3: `toggle_lock(S.selected_voice)`.
- Hints: `K2:prev K3:next`; ALT `K2:reset K3:lock`, or `K3:unlock` when the voice is locked.
- `arc_button`: `toggle_voice(S.selected_voice)`.

Cursor anchoring (`sync_cursor`, ruling W7): the module remembers the cursor's param key (its id without the `v<i>_` prefix), its row index and the rows' signature (the row ids in order). When the signature differs from the current rows (the source or the selected voice changed), the cursor goes to the row with the same key if there is one, else to the remembered index; then `field_list.clamp` puts it on a selectable row. So grain pitch stays grain pitch when the synth section appears or goes, and stays on grain pitch of the newly selected voice; a param the new rows lack (`rq` on an input voice, `index` on voice 1) clamps from the old index. `redraw()` runs `clamp_all()` before the page draws, which may already have moved the index; the remembered index, not the clamped one, is the fallback. The screen draws before the arc in each frame (`draw_frame`), so after a switch the rings follow the re-anchored cursor in the same frame. While the norns menu replaces the screen's redraw, the rings see only `clamp_all`'s result until VOICE draws again; a ring turn in the window before the next frame does too, unless the rings call `sync_cursor()`.
