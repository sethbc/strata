# Task 1.2 report: header, page dots, indicators and flashes

Status: DONE. Branch `feat/3.1-wave1-header`, commit edb5dda (pushed; no PR opened).

## Changes per file

- `lib/ui/flash.lua` (new, `S.lib.ui_flash`): slots `"header"` and `"hints"` (`M.slots[slot] = {text, ends_at, clock}`); `start(slot, text, seconds)` cancels the slot's clock, stores text and `ends_at`, runs a clock that sleeps, clears the text and calls `request_redraw()`, and also requests a redraw at start; `text(slot)` returns the text while `util.time() < ends_at`; `cancel_all()` (cleanup step 140, `CLEANUP_ORDER.ui_flash`); global `header_flash(text)` = `start("header", text, 1.5)`. An unknown slot asserts.
- `lib/ui/header.lua`: `draw_header` without `dens:`. Draws the title, then either the header flash (x 40, cut with `fit_text` to 74 px) or the eight dots (2x2 filled rects, y 4, from x 40, 4 px apart, current 15 / others 3) plus either the record's `header_status()` (text at 79, cut to end by 114; play mark at 74 while playing) or the indicators (`[M]` 76 level 6, play mark at 90 = three 1-px column rects 5/3/1 tall from y 3, filled, level 15; `REC` 96 level 15 while any `S.buffers[i].recording`). The scene stays at 127.
- `lib/constants.lua`: `HEADER` with the brief's values plus two y values the brief left open (`dot_y = 4`, `play_y = 3`), exported as `S.constants.HEADER`. `CLEANUP_ORDER.buffer_page_flash = 140` renamed to `ui_flash = 140` (same order: the step moved to lib/ui/flash.lua).
- `strata.lua`: include of lib/ui/flash at the named anchor (right after `S.lib.ui_header`); `redraw()` draws `S.lib.ui_flash.text("hints") or record.hints(S.alt_held)` (W4).
- `lib/pages/buffer.lua` (W4): `buffer_page_flash(text)` = `S.lib.ui_flash.start("hints", text, HEADER.flash_seconds)`. Removed `flash_*` fields from `S.BUFFER_PAGE`, `cancel_buffer_page_flash_clock`, its cleanup registration and the flash branch in `buffer_hints`. Rewrote the stale comment (~line 33) about redraw_buffer.
- `test/norns_stubs.lua`: `screen.fill()`/`screen.stroke()` mark the lines and rects drawn since the last fill/stroke/clear `filled = true/false` (nil before).
- `test/helpers.lua`: `assert_screen_layout` drops the `dens:` check. It now checks the title at 0,8, then eight dot rects at x 40..68 (the first at least 4 px after the title), or the flash text at 40,8 and no dots while `S.lib.ui_flash.text("header")` is set, and that no header rect (y+h <= 9) lies under a y-8 string.
- `test/unit/ui_header_test.lua` (new): 11 tests (constants; dots; [M]/play/REC; header_status; header flash 1.5 s with redraw request; replacement + one clock at a time + custom seconds + cleanup; unknown slot; BUFFER hint flash, moved from pages_test.lua and adapted to `S.lib.ui_flash.slots.hints.clock`; hints flash on every page; long flash cut with S8; stub filled/outlined).
- `test/unit/pages_test.lua`: removed the moved BUFFER flash test (left a pointer comment). The "eight buffer rows" test now counts only entries below the header (`entry.y > 8`), because slot 7 recording now puts `REC` at x 96 in the header.
- `test/unit/structure_test.lua`: MODULE_HOMES (`header_flash` in lib/ui/flash.lua; `cancel_buffer_page_flash_clock` removed); cleanup-order step "buffer page flash" renamed "flashes", watching both flash clocks.
- Docs: `docs/notes/lua/ui-and-pages.md` (Owns, Must not break, redraw, new "Header and flashes" section, layout-test list, BUFFER flash), `docs/notes/lua/state-and-voices.md` (step 140), `docs/notes/lua/test-harness.md` (filled marks), `docs/notes/lua/mutation.md` ([M] x 76), `docs/user/controls.md` (header description), CLAUDE.md (module table row, header/flash rule in the UI section). `changes/3.1-wave1-header.md`.

## TDD evidence

RED (`lua test/run.lua ui_header` before implementing): 11 tests, 11 failures. For example: `HEADER` nil, "eight page dots: expected 8, got 0", "the header no longer shows dens:", `header_flash` nil, `ui_flash` nil, "MAIN shows the hints flash: expected buf 2 load failed, got K2:rand K3:freeze", "a filled rect: expected true, got nil".
GREEN: `ui_header` 11/11. Two test-only fixes along the way: the frame after the flash ends lands at about 1.533 s, so the tests call `next_frame` after `run_for(1.51)` before reading the drawn screen.

## Totals

- `lua test/run.lua`: 249 tests, 0 failures
- `luajit test/run.lua`: 249 tests, 0 failures
- `lua test/sync_check.lua`: passed

## Decisions and concerns

- Behavior change (follows the plan's redraw() contract): the "hints" flash now shows on the hint row of whatever page is up, not only on BUFFER. For example, a `buf N load failed` report shows on MAIN. The changelog fragment says so.
- On a page with `header_status`, the play mark at 74 shows only while patterns play, as the play mark does everywhere. The design's "The header shows ▶ and the tempo on this page" could be read as always showing it; Wave 2c can change this if it means always.
- The status text is cut to end at x 114 (`flash_x + flash_width - status_x` = 35 px), the same limit as a flash. "300 bpm" fits exactly.
- `HEADER` has two keys beyond the brief's table (`dot_y`, `play_y`). Every listed value is as specified.
- No request_redraw was added for pattern start/stop: every caller (grid_key, key) already requests one. A future caller from a clock or MIDI must request its own.
- Files touched outside the brief's list, all minimal: `lib/constants.lua` (HEADER and the cleanup line), `strata.lua` (dispatch W4), `test/unit/pages_test.lua` and `test/unit/structure_test.lua` (needed by the moved flash state), docs as listed. Parallel tasks editing `lib/constants.lua`, `pages_test.lua` or `structure_test.lua` may hit small, mechanical merge conflicts.
