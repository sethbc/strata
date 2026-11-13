## Must not break

- Every page draws the header at y=8 and the hint row at y=62. No two strings on a row overlap and nothing leaves 128×64. The layout tests check it on every page record with every voice, source, ALT state and flash, and each record's `layout_states` (`test/unit/ui_layout_test.lua`). A page adds layout states only through its record's `layout_states`.
- The layout tests catch only strings that overlap on the same baseline, text off-screen, header rects under header text, the hint row and the MAIN divider. They do not catch strings on nearby baselines that collide, nor text drawn over a rect or a line in the page body: look at the page renders (Page renders below) for those.

## Layout tests

`assert_screen_layout(context, where)` (`test/helpers.lua`) checks one drawn screen:
- no two strings on a row overlap, and nothing leaves 128×64 (measuring with norns' font advances, `stubs.text_width`: `docs/notes/test-harness/stubs.md`);
- the page title at 0,8, then one page dot per page (nine 2×2 rects at x 36, 40, ..., 68, the first at least 4 px after the title), or, while a header flash shows (`S.lib.ui_flash.text("header")`), its text at 40,8 and no dots;
- a string with a descender (g, j, p, q, y) has no string it overlaps horizontally less than 7 px below it (the font draws 2 px under the baseline; #422);
- no header rect (a dot, the play mark: rects above y 9) lies under a header string;
- a hint row is drawn at y=62;
- on MAIN every string between the header and the hint row ends by x=60 or starts at x=65 or later (never across the divider).

`test/unit/ui_layout_test.lua` runs it on every page record with every voice (1-7), source (synth, buf 1, input), ALT state (up, down) and flash (none, a long header flash, the longest hints flash), then on each record's `layout_states` (each on a fresh script, with ALT up and down). It also keeps the older every-page checks (the widest SETUP page with four grids, the voice list's last row above the hint row). Each page's own layout tests are in its unit file (`pages_main_test.lua`, ...); the header and flash tests in `test/unit/ui_header_test.lua`.
- Keep them passing when adding text. The widths are `stubs.text_width` in `test/norns_stubs.lua` (norns' font advances; it counts UTF-8 characters, not bytes), which the screen stub also uses for `screen.text_extents` (returns width, 8).
- The stub records each string's `x`, `y`, `align` (`left`, `right`, `center`) and `level`, and each rect and line with `filled` (true after `screen.fill()`, false after `screen.stroke()`).
- The stub's `UI.ScrollingList:redraw` is the real one from `lua/lib/ui.lua`, so the list's entries are recorded like any other text (an empty string where the list scrolls past an end).

## Page renders

Run on demand, never in `lua test/run.lua`: `lua test/render_pages.lua <dir>`, then `python3 test/render_pages.py <dir> --font <path to a .ttf>` (Pillow).
- `test/render_pages.lua` loads the script through the stubs (it requires `test/helpers.lua`) and, for each state, on a fresh script after startup, shows the page, runs the state's setup and writes `<page>-<state>.json`: the page and state names and every text (`x`, `y`, `text`, `align`, `level`), rect (`x`, `y`, `w`, `h`, `level`, `filled`) and line (`x1`, `y1`, `x2`, `y2`, `level`, `filled`) the draw made. Its states are its own `STATES` (MAIN synth, buffer, input, ALT and a header flash; VOICE; SEQ playing; FX; LFO; BUFFER and BUFFER recording; SCENES; SETUP), then each page record's `layout_states`. As a module it returns `render_page_states(out_dir)`, which returns the file names it wrote.
- `test/render_pages.py` draws each JSON file as a 128×64 PNG beside it, scaled 4× without smoothing: levels as grays, rects filled or outlined, texts at their baseline (left, right or center) in the `--font` file at 8 px. Without `--font` it uses `~/src/norns/resources/norns.ttf` (norns' 04B_03) when it exists, else Pillow's built-in font.
- The suite's test "the render dump writes one file per page state" (`ui_layout_test.lua`) runs `render_page_states` into a temporary folder: at least 13 files, each well-formed JSON naming a page from `UI_PAGES`, and a render of every page.
