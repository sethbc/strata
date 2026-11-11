## Must not break

- Transient texts go through `S.lib.ui_flash` (one clock per slot, canceled before a new flash in that slot starts, and at cleanup). Never give a page its own flash clock.
- The header has no `dens:`: master density is on FX's first row, MAIN's arc ring 1 and in params.
- `draw_hints` cuts its text to the screen's 128 px (`fit_text`), so a flash naming a long file or folder never leaves the screen; the flash itself keeps its whole text. Only a changed text is measured again.

## Header and flashes

`draw_header()` (`lib/ui/header.lua`), y=8, positions in `S.constants.HEADER`:
- Page title at x 0, level 15. 04B_03 capitals advance about 6 px, so the longest titles, `BUFFER` and `SCENES`, end near x 36.
- Eight page dots: 2×2 filled rects (`dot_size`) at y 4 (`dot_y`) from x 40 (`dots_x`), 4 px apart (`dot_spacing`), so x 40-69. The current page's at level 15 (`current_dot_level`), the rest at 3 (`dot_level`).
- Indicators, each only while active: `[M]` at x 76 (`mutation_x`, level 6) while `mutation_enabled` is 1 (abbreviated to make room for the play mark, `REC` and the scene); the play mark at x 90 (`play_x`) while `S.pattern_playing`; `REC` at x 96 (`rec_x`, level 15) while any `S.buffers[slot].recording` that is not armed (3.3: `S.lib.record.state(slot).phase` other than `"armed"`, or no state), else `ARM` in its place while a slot is armed (waiting for a beat, a bar or a level) and none records.
- The play mark is a filled 3×5 triangle pointing right: three 1-px-wide rects, 5, 3 and 1 px tall, from y 3 (`play_y`), level 15.
- A record with `header_status()` returning a string: the text at x 79 (`status_x`, level 10, cut with `fit_text` to end by x 114) and the play mark at x 73 (`status_play_x`, while patterns play; three clear pixels before the text) replace `[M]`, the play mark and `REC`. Returning nil keeps the indicators. The dots stay.
- Scene indicator `S1`-`S8` (`S.current_scene`) right-aligned at x 127 (`scene_right`): level 10 while the scene sequencer runs, 6 when static, and 2 while `S.lib.scenes.shows_current(S.current_scene)` is false (the scene a fade goes to, after its even steps: it blinks, #254, `docs/notes/lua/scenes.md`).
- No `dens:`: master density left the header.
- The design put these at x 80/94/100; they moved to 76/90/96 (same order and spacing) when the layout test's old width estimate (6 px capitals) put `REC` over a right-aligned `S8`. By norns' font advances (#479) `REC` (13 px) and `ARM` (16 px) from x 96 end by 112, 5 px clear of `S8` (117-127).
- Nothing calls for a redraw on its own here: the indicators' state changes already ask for one (param actions, `grid_key`/`key` around `pattern_toggle`, `buffer_display_changed`).

Flashes (`lib/ui/flash.lua`, `S.lib.ui_flash`):
- Two slots, `"header"` and `"hints"` (`S.lib.ui_flash.slots[slot]`: `text`, `ends_at`, `page`, `clock`). Another slot name is an error.
- `S.lib.ui_flash.start(slot, text, seconds, page)` (seconds default `HEADER.flash_seconds`, 1.5; `page` a `UI_PAGES` index or nil): cancels the slot's running clock, stores the text, the page and `ends_at = util.time() + seconds`, starts a clock that sleeps `seconds`, clears the text and calls `request_redraw()`, and asks for a redraw itself. So one clock per slot runs at a time. A nil text only ends the flash showing (never draws `nil`).
- `S.lib.ui_flash.text(slot)`: the text while `util.time() < ends_at` and, for a flash with a page, while that page is up (`S.ui_page`); else nil (so a clock that wakes late changes nothing on screen, and a page's own message, BUFFER's load reports or SETUP's `setting not saved`, never shows over another page's keys).
- A prompt that waits for the player's answer is the page's own state, returned by its `hints`, never a hints flash, so another page's flash cannot erase it: SCENES' overwrite prompt (`K3 again: overwrite S<n>` with ALT held, `ALT+K3: overwrite S<n>` with ALT up, #255, `docs/notes/lua/pages/scenes.md`).
- `S.lib.ui_flash.cancel_all()`: cleanup step 140 cancels both clocks and clears the texts.
- `header_flash(text)` (global) = `start("header", text, 1.5)`. While it shows, the header draws the text at x 40 (`flash_x`), level 15, cut with `fit_text` to 74 px (`flash_width`, so it ends by x 114, before a right-aligned `S8`), instead of the dots and indicators (and a `header_status`). The title and scene stay.
- A hints flash is cut like any hint row (`draw_hints` fits it to 128 px with `fit_text`), so a long one loses its end on screen while the flash keeps its whole text: keep it short enough to read whole (the layout test draws "K3 again: overwrite S8", SCENES' longest prompt, as a flash on every page).
