## Must not break

- Never call `redraw()` or `arc_redraw()` from script code. Call `request_redraw()`, and the frame clock draws whatever is dirty at `UI_PAGES.FRAMES_PER_SECOND` (15). Grid redraws stay direct (`grid_redraw()`).
- Change a page's draw function (`redraw_main`, `redraw_setup`, ...), never `redraw()`. While `S.BUFFER_PAGE.file_selector_open` is set, `redraw()` draws the file selector, never the page.
- Each page file creates one record at `S.registry.pages[UI_PAGES.index.<PAGE>]` and sets every field but the four arc fields (`arc_delta`, `arc_redraw`, `arc_alt_delta`, `arc_alt_redraw`), which only its `lib/arc/<page>.lua` sets. `strata.lua` includes every page file before every arc file and asserts every `UI_PAGES` name has its record with `draw`, `hints`, `enc` and `key`. A test checks who sets which field.
- A page's `draw()` draws its body only; `redraw()` draws the hint row from the "hints" flash while one shows, else from the record's `hints(alt_held)`. Never call `draw_hints` from a page.
- Transient texts go through `S.lib.ui_flash` (one clock per slot, canceled before a new flash in that slot starts, and at cleanup). Never give a page its own flash clock.
- Every page draws the header at y=8 and the hint row at y=62. No two strings on a row overlap, nothing leaves 128×64, and no MAIN string crosses the divider (end by x=60 or start at x=65). The layout tests check it.
- A key release acts only on the page where the key went down (`S.key_press_page`). Keys held while the norns menu opens are forgotten.
- `unwatch_menu_opening()` puts `_menu.set_mode` back only if it is still Strata's wrapper; otherwise Strata's wrapper becomes a pass-through.
- A failing draw prints its error once per distinct error and the frame clock keeps running.
- MAIN is found by index (`S.ui_page == UI_PAGES.MAIN_PAGE`), never by its title string.

## Owns

- `lib/ui/frame.lua` (`S.lib.ui_frame`): `S.ui_page`; `request_redraw`, `draw_frame`, `draw_frame_part`, `draw_error_report` and the frame clock (`start_frame_clock`, `stop_frame_clock`; cleanup step 60). The runtime fields (`screen_dirty`, `arc_dirty`, `frame_clock`, `draw_errors`) are on the shared `S.constants.UI_PAGES` table.
- `lib/ui/params.lua` (`S.lib.ui_params`): `param_range`, `param_value_fraction`, `param_fraction`.
- `lib/ui/header.lua` (`S.lib.ui_header`): `draw_header`, `draw_hints`. Its positions are `S.constants.HEADER` (`lib/constants.lua`).
- `lib/ui/flash.lua` (`S.lib.ui_flash`): the flashes, `S.lib.ui_flash.start`, `.text`, `.cancel_all`, `.slots`, and `header_flash` (global); cleanup step 140.
- `lib/ui/text.lua` (`S.lib.ui_text`): `S.lib.ui_text.fit_text`.
- `lib/ui/keys.lua` (`S.lib.ui_keys`): `S.key_press_page`, `S.alt_held`, `forget_held_keys` (global); `set_ui_page` (runs the records' `leave`/`enter`), `select_voice_by`, `ignore_page_input` (fields of `S.lib.ui_keys`).
- `lib/ui/menu_watch.lua` (`S.lib.ui_menu_watch`): the `_menu.set_mode` wrapper (`watch_menu_opening`, `unwatch_menu_opening`, `forget_keys_held_through_menu`; cleanup step 20).
- `lib/pages/main.lua`, `lib/pages/voice.lua`, `lib/pages/seq.lua`, `lib/pages/fx.lua`, `lib/pages/lfo.lua`, `lib/pages/buffer.lua`, `lib/pages/scenes.lua`, `lib/pages/setup.lua` (`S.lib.pages_main`, `S.lib.pages_voice`, ...): one screen page each and its `S.registry.pages` record.
  - VOICE, SEQ, SCENES: stubs for now (draw nothing, hint `E1:page`, ignore input).
  - MAIN: `S.voice_list`, `update_voice_list`, `main_param_id`, `main_param_entry`, `main_param_label`.
  - FX: `S.FX_PAGE`, `S.fx_row`.
  - LFO: `LFO_PAGE` (local).
  - BUFFER: `S.BUFFER_PAGE`, the file selector, `buffer_page_flash` (on the shared "hints" flash).
  - SETUP: `setup_enc` (global).

The arc's rings for each page are in `docs/notes/lua/arc.md`.

## Pages and dispatch

The screen has `NUM_UI_PAGES` (8, `#UI_PAGES`) pages, named in `UI_PAGES = {"MAIN", "VOICE", "SEQ", "FX", "LFO", "BUFFER", "SCENES", "SETUP"}`. `UI_PAGES.index[name]` is a page's index (`UI_PAGES.index.FX == 4`); `UI_PAGES.MAIN_PAGE` stays 1. `S.ui_page` is the index of the shown page.

Encoders and keys (`strata.lua`):
- `enc(1, d)` selects the page (`S.lib.ui_keys.set_ui_page(util.clamp(S.ui_page + d, 1, NUM_UI_PAGES))`), stopping at MAIN and SETUP. E1 does nothing else. `set_ui_page` does nothing when the page does not change; on a change it calls the old record's `leave()` and the new one's `enter()`, if they have them.
- `init` turns E1's acceleration off and sets its sensitivity to `E1_TICKS_PER_PAGE` (4) with `norns.enc.accel(1, false)` / `norns.enc.sens(1, ...)`, so a fast turn steps pages instead of skipping to SETUP. norns resets these on every script load, so cleanup restores nothing.
- `enc(2|3, d)` calls `S.registry.pages[S.ui_page].enc(n, d)`, and `key(n, 1)` (K2, K3) calls `S.registry.pages[S.ui_page].key(n)`.
- `key(1, z)` only sets `S.alt_held` (K1 held is ALT; norns delivers K1 to a script only once held). `forget_held_keys` clears it.
- Master density left E1. It is on the FX page's first row, MAIN's arc ring 1 and in params. The header no longer shows it.

Page records. Each page lives in its own file and creates one record at `S.registry.pages[UI_PAGES.index.<PAGE>]`:
- Required: `name`, `draw()` (the page body only), `hints(alt_held) -> string` (the hint row), `enc(n, d)` (E2, E3), `key(n)` (K2, K3 presses).
- Optional: `alt_enc(n, d) -> handled`, `alt_key(n)`, `key_release(n)`, `alt_key_release(n)`, `enter()`, `leave()`, `arc_button()`, `header_status() -> string|nil`, `layout_states` (an array of `{name, setup = function(context)}` the layout tests also draw). The dispatch for the ALT fields, `arc_button` and `header_status` comes with the tasks that use them; today `key_release`, `enter` and `leave` are dispatched.
- Arc fields, set only by `lib/arc/<page>.lua`: `arc_delta(n, d)`, `arc_redraw(arc_port)`, `arc_alt_delta(n, d)`, `arc_alt_redraw(arc_port)`.
- Ownership: the page file sets every field but the arc fields; the arc file sets only those, on `S.registry.pages[UI_PAGES.index.<PAGE>]`. So a page and its rings never edit the same file. `strata.lua` includes every page file before every arc file.
- `ignore_page_input` fills the handlers a page does not use.
- To add a page: add its name to `UI_PAGES` (`NUM_UI_PAGES` follows), write its file and record, include it from `strata.lua` with the other pages, and, if it has rings, an arc file like `lib/arc/fx.lua` included after the pages (`docs/notes/lua/arc.md`). VOICE, SEQ and SCENES already have their page and arc files (stubs), so filling them in adds no include.

`redraw()`:
- `screen.clear(); draw_header(); record.draw(); draw_hints(S.lib.ui_flash.text("hints") or record.hints(S.alt_held)); screen.update()`, with `record = S.registry.pages[S.ui_page]`.
- Except while the BUFFER page's file selector is open (`S.BUFFER_PAGE.file_selector_open`): then it calls `fileselect.redraw()` and returns, so neither norns' own `redraw()` calls nor Strata's frame clock draw the page over the file list.
- The hint row (`draw_hints(text)`: level 4, x=0, y=62) is drawn once, by `redraw()`: the "hints" flash while one shows (on whatever page is up), else the record's hints.

## Header and flashes

`draw_header()` (`lib/ui/header.lua`), y=8, positions in `S.constants.HEADER`:
- Page title at x 0, level 15.
- Eight page dots: 2×2 filled rects (`dot_size`) at y 4 (`dot_y`) from x 40 (`dots_x`), 4 px apart (`dot_spacing`), so x 40-69. The current page's at level 15 (`current_dot_level`), the rest at 3 (`dot_level`).
- Indicators, each only while active: `[M]` at x 76 (`mutation_x`, level 6) while `mutation_enabled` is 1; the play mark at x 90 (`play_x`) while `S.pattern_playing`; `REC` at x 96 (`rec_x`, level 15) while any `S.buffers[slot].recording`.
- The play mark is a filled 3×5 triangle pointing right: three 1-px-wide rects, 5, 3 and 1 px tall, from y 3 (`play_y`), level 15.
- A record with `header_status()` returning a string: the text at x 79 (`status_x`, level 10, cut with `fit_text` to end by x 114) and the play mark at x 74 (`status_play_x`, while patterns play) replace `[M]`, the play mark and `REC`. Returning nil keeps the indicators. The dots stay.
- Scene indicator `S1`-`S8` right-aligned at x 127 (`scene_right`): level 10 while the scene sequencer runs, 6 when static.
- The design's x 80/94/100 put `REC` over a right-aligned `S8` under the layout test's width estimate; 76/90/96 keep the same order and spacing and fit.
- Nothing calls for a redraw on its own here: the indicators' state changes already ask for one (param actions, `grid_key`/`key` around `pattern_toggle`, `buffer_display_changed`).

Flashes (`lib/ui/flash.lua`, `S.lib.ui_flash`):
- Two slots, `"header"` and `"hints"` (`S.lib.ui_flash.slots[slot]`: `text`, `ends_at`, `clock`). Another slot name is an error.
- `S.lib.ui_flash.start(slot, text, seconds)` (seconds default `HEADER.flash_seconds`, 1.5): cancels the slot's running clock, stores the text and `ends_at = util.time() + seconds`, starts a clock that sleeps `seconds`, clears the text and calls `request_redraw()`, and asks for a redraw itself. So one clock per slot runs at a time.
- `S.lib.ui_flash.text(slot)`: the text while `util.time() < ends_at`, else nil (so a clock that wakes late changes nothing on screen).
- `S.lib.ui_flash.cancel_all()`: cleanup step 140 cancels both clocks and clears the texts.
- `header_flash(text)` (global) = `start("header", text, 1.5)`. While it shows, the header draws the text at x 40 (`flash_x`), level 15, cut with `fit_text` to 74 px (`flash_width`, so it ends by x 114, before a right-aligned `S8`), instead of the dots and indicators (and a `header_status`). The title and scene stay.
- `buffer_page_flash(text)` = `start("hints", text, 1.5)`. `redraw()` draws the "hints" flash on the hint row of any page (a failed load reported while another page is up shows there too).

## Key releases and the norns menu

Releases:
- `key(n, 1)` records `S.key_press_page[n] = S.ui_page`.
- `key(n, 0)` clears it and calls the page record's `key_release(n)` only if the key went down on the page still shown, so a key held across a page change does nothing when released.
- Only BUFFER has a `key_release`; on every other page releases do nothing.
- "K2 is held on this page" is `S.key_press_page[2] == S.ui_page`.

Keys held into the menu:
- The norns menu (K1, PARAMS, its file selector) takes every key while open (`_menu.key` is the menu's handler), so a key released there never reaches `key()`.
- `forget_keys_held_through_menu()`, called at the end of `drift_update` (the 10 Hz `S.drift_metro` tick), clears `S.key_press_page` and `S.buffer_saved_during_k2` whenever `norns.menu.status()` is true.
- Without it, a K2 released in the menu would stay held and every BUFFER K3 would save instead of record.
- It also runs the moment the menu opens. Every way into the menu (K1, a script error, a keyboard's menu key) calls `_menu.set_mode(true)`, which `lua/core/menu.lua` and `keyboard.lua` look up on `_menu` at each call.
- So `watch_menu_opening()` (from `init`) wraps it in `menu_watch.wrapper`: call norns' function, then `forget_keys_held_through_menu()` when `mode == true`.
- The wrapper holds norns' function and `forget_keys_held_through_menu` as upvalues (no script-global lookup).
- `unwatch_menu_opening()`, cleanup's second step (after the tempo handler, before anything that can fail), puts `menu_watch.original_set_mode` back only if `_menu.set_mode` is still Strata's wrapper. Otherwise (something wrapped it later) it leaves that wrapper in place and turns Strata's into a pass-through (`menu_watch.active = false`).
- The 10 Hz tick stays as a fallback.
- norns has no key-state query.
- A file selector opened from play mode, as BUFFER K2 does, keeps `norns.menu.status()` false and takes the keys through the global `key`. It opens on K2's release, so only a K3 held at that moment can be released there. `buffer_key_release` therefore calls `forget_held_keys()` just before `fileselect.enter`. `forget_held_keys` is a global: it clears `S.key_press_page` and `S.buffer_saved_during_k2`, and is also the body of `forget_keys_held_through_menu`.

## Redraws

Issue #11. Nothing in Strata calls `redraw()` or `arc_redraw()` directly.
- Anything that changes what the screen or the arc shows calls the global `request_redraw()`, which sets `UI_PAGES.screen_dirty` and `UI_PAGES.arc_dirty`.
- The frame clock (`UI_PAGES.frame_clock`, `start_frame_clock()` at the end of `init`, `stop_frame_clock()` in `cleanup`, after the start-up clock) sleeps `1 / UI_PAGES.FRAMES_PER_SECOND` (15) and runs `draw_frame()`.
- `draw_frame()` clears each dirty flag and calls the global `redraw()` and/or `arc_redraw()`. A burst of arc turns, encoder steps, MIDI or param changes costs one screen draw and one arc redraw per frame, and an idle frame draws nothing.
- Both flags start set, so the first frame draws the screen and any arc connected at start.
- On the LFO page `draw_frame` marks the screen dirty every frame, so the dots move. The LFO page has no clock of its own.

Draw errors:
- Each draw runs through `draw_frame_part(part, draw)` (`part` is `"screen"` or `"arc"`): an `xpcall` with `draw_error_report`, which returns a key and the error with its traceback.
- The key: a string error is its own key; a table error (a new table each time) is keyed by its `message` field (also what is printed), or else by its type.
- An error is printed to the console with its traceback and the clock keeps running. The flag was already cleared, so the failed draw is not retried; the next `request_redraw()` draws again.
- `UI_PAGES.draw_errors[part]` holds the key last printed, so a draw that keeps failing with the same error (e.g. on the LFO page, which draws every frame) prints it once instead of 15 times a second.
- Another message prints, and a good draw clears the key, so the same error after a good frame prints again (issue #49).

norns' swaps still apply, because `draw_frame` calls the global `redraw`:
- while the norns menu is open the global is `norns.none` (norns calls `redraw()` itself as the menu closes);
- while the BUFFER file selector is open, `redraw()` draws the selector, never the page;
- norns' own `redraw()` calls still draw the page at once.

Who asks for a redraw:
- Every param action, through `redraw_on_param_changes()` (`lib/params_setup.lua`; run once in `init` after the last param is added; a param added, or an action set with `params:set_action`, after it runs does not request redraws). It wraps each param's action so it calls `request_redraw()` after it.
  - So PARAMS edits, PARAMS > MAP CCs, pset loads, scene fades and recalls, mutations, MIDI notes (they set freq or buf_rate) and the LFO page's E3/K2/K3 all arrive through param actions.
  - Left out: text params (the LFO library writes each LFO's scaled and raw values into `lfo_scaled_<n>`/`lfo_raw_<n>` on every step, shown nowhere), and the drift's 10 Hz writes (`S.drift_writing`; grain pitch is shown nowhere).
  - `drift_update` requests a redraw itself when it moves the selected voice's buffer position, which MAIN and the BUFFER arc ring show. Other voices' positions are shown nowhere, so they ask for none.
- Explicit calls cover state that is not a param: `enc`, `key`, `arc_delta`, `arc_key` (MAIN), `grid_key`, `toggle_voice`, `toggle_freeze`, `randomize_voice`, `gentle_mutate`, each smooth-transition step, `recall_scene` and the end of `recall_scene_instant` (freeze and running states), the scene sequencer, `buffer_display_changed`/`buffer_state_changed`, a flash's start and end (`S.lib.ui_flash.start` and its clock) and the BUFFER file selector's callback, and the grid/arc/MIDI hot-plug callbacks.

## MAIN

`redraw_main`, `main_enc`, `main_key`: the original screen.
- E2 selects the voice, E3 adjusts its main parameter.
- K2 randomizes. K3 starts a stopped voice or freezes/unfreezes a running one (`start_or_freeze_selected_voice`; it never stops a voice).

Main parameter:
- `main_param_id(voice_idx)` returns the param E3 and arc ring 2 adjust: `v<i>_freq` resonator, `_index` fm, `_fold` folder, `_drift` sub, `_width` pulse, `_decay` karplus, `_ratio` ring.
- `main_param_label(voice_idx)` returns its screen label.
- Both read `main_param_entry(voice_idx)`:
  - the `MAIN_PARAMS` entry for the voice type (param id suffix, screen label, value format; arc ring 2 sweeps it with `arc_sweep_param`);
  - `BUFFER_MAIN_PARAM` (`buf_pos`, label `pos`, `%.2f`) for a buffer source (3.0 design §1);
  - `INPUT_MAIN_PARAM` (`grain_size`, label `size`, `%.2f s`) for the input source (its synth and buffer params do nothing).
- Use them instead of `if v.name ==` chains. Arc ring 2 is drawn to `param_fraction(main_param_id(...))` of a turn, following the warp like the FX and BUFFER rings.

Voice list:
- `update_voice_list()` recreates the `UI.ScrollingList` (`S.voice_list`) on every change.
- Each entry is plain ASCII, so its width does not depend on how the norns font draws other glyphs:
  - active status (`+` running, `-` stopped);
  - the voice type's short name, `MAIN_PARAMS[type].list_name` (`reso`, `fm`, `fold`, `sub`, `pulse`, `karp`, `ring`; at most 5 characters). The details column shows the full name and ON/OFF;
  - freeze status (` [F]` suffix).
- The widest entry, `+ pulse [F]`, is 54 px by the harness estimate, so it ends 8 px before the divider.
- The list puts the selected voice on row 2 (y=26, the ON/OFF row) except at the ends of the list (`num_above_selected` = 1), so entries must stay left of x=60 or they overlap the details.

Layout (two columns):
- **Header** (y=8, `draw_header()`, the same on every page; see Header and flashes): page title at x=0 (04B_03 capitals advance ~6 px, so the longest titles `BUFFER` and `SCENES` end near x=36), page dots from x=40, `[M]` at x=76, the play mark at x=90, `REC` at x=96, scene indicator `S1`-`S8` right-aligned at x=127.
- **Left column** (0-60 px): the scrolling voice list (4 visible at a time, rows y=15-48).
- **Right column** (65-128 px): the selected voice's details (name, status, main parameter at y=42/50). `[FREEZE]` is right-aligned at x=127 on the status row (y=26), `[TRIG]` (triggered grain mode) right-aligned at x=127 on the main-parameter label row (y=42).
- **Divider** (x=62): a subtle vertical line between the columns.
- **Hint row** (y=62): `K2:rand K3:freeze|start`.

Header indicators:
- `S1` to `S8` at the top right shows the current scene (`S.current_scene`): level 10 while the scene sequencer runs, 6 when static.
- The mutation indicator is abbreviated to `[M]` to make room for the play mark, `REC` and the scene indicator.

Layout tests (`test/unit/pages_test.lua`, through `assert_screen_layout` in `test/helpers.lua`), on every page and for every selected voice:
- no two strings on a row overlap, and nothing leaves 128×64 (estimating 6 px per capital, 4 per bracket/colon/period, 5 otherwise);
- the page title at 0,8, then the eight page dots (2×2 rects at x 40, 44, ..., 68, the first at least 4 px after the title), or, while a header flash shows (`S.lib.ui_flash.text("header")`), its text at 40,8 and no dots;
- no header rect (a dot, the play mark: rects above y 9) lies under a header string;
- a hint row is drawn at y=62;
- the voice list's last row ends above the hint row;
- on MAIN every string between the header and the hint row ends by x=60 or starts at x=65 or later (never across the divider);
- a separate test draws the list for every voice, selection and running/frozen state.
- Keep them passing when adding text. The width estimate is `stubs.text_width` in `test/norns_stubs.lua` (it counts UTF-8 characters, not bytes), which the screen stub also uses for `screen.text_extents` (returns width, 8).
- The stub records each string's `x`, `y`, `align` (`left`, `right`, `center`) and `level`, and each rect and line with `filled` (true after `screen.fill()`, false after `screen.stroke()`).
- The header and flash tests are in `test/unit/ui_header_test.lua`.
- The stub's `UI.ScrollingList:redraw` is the real one from `lua/lib/ui.lua`, so the list's entries are recorded like any other text (an empty string where the list scrolls past an end).

## FX

`redraw_fx`, `fx_enc`, `fx_key`:
- A scrolling list of `S.FX_PAGE.rows` (`{label, param_id, format}`; `format` is a `string.format` pattern, or nil for the param's own string): density, tape drift, filter type/freq/res/mix, delay time/fdbk/mix, reverb mix/size/damp.
- `S.FX_PAGE.visible_rows` (5) rows at y=18-50 (`first_row_y` 18, `row_spacing` 8). Label at x=0, value right-aligned at x=127. The selected row (`S.fx_row`) at level 15, the others at 4. The view keeps one row above the selection.
- E2 selects the row, E3 is `params:delta` on its param.
- K3 toggles `filter_mix` between 0 and `S.fx_filter_last_mix`, which the `filter_mix` param action records whenever the mix is set above 0 (from E3, PARAMS, scenes or K3; initially 1).
- Hint: `K3:filter bypass` when the mix is above 0, else `K3:filter on`.

## BUFFER

`redraw_buffer`, `buffer_enc`, `buffer_key`, `buffer_key_release`.

Layout:
- Left column (x 0-60): the selected voice's name (y 18), `src: <voice_source_label>` (y 26), `dur:` record duration (y 42) and `lvl:` record level (y 50).
- Divider at x 62.
- Right column, eight rows (`S.BUFFER_PAGE.row_first_y` 14, `row_spacing` 6, so y 14-56):
  - slot number at x 65 (`slot_x`);
  - name at x 71 (`name_x`): the file name without extension, cut by `fit_text` with `screen.text_extents` to `S.BUFFER_PAGE.name_max_width` 31 px, whole UTF-8 characters at a time. `buffer_display_name` caches the cut name in `S.buffers[slot].display_name` until `name` changes, so a redraw measures nothing;
  - seconds (`%.1fs`) or `REC`, right-aligned at x 127.
- Row level: the selected voice's buffer (`voice_buffer_slot`) 15, loaded or recording 8, empty 2.

Controls:
- E2 is `select_voice_by` (shared with MAIN), E3 `params:delta("v<i>_source", d)`.
- K3 press: `record_buffer(slot)` (toggles: stops early while recording), or `save_buffer(slot)` when K2 is held on this page (`S.buffer_saved_during_k2` then makes the K2 release do nothing).
- The save is confirmed by `buffer_page_flash(text)`:
  - `buf <n> busy` (and no `save_buffer` call) while the slot is `recording` or `finishing`;
  - else `saved buf <n>` when the slot reports audio (`seconds > 0`, the rule `save_buffer` saves by);
  - else `buf <n> empty`.
- `buffer_load_failed` flashes `buf <n> load failed` when the engine reports a failed load (see the buffers table in `docs/notes/engine.md`).
- With no buffer source (synth, input) K2 and K3 do nothing.
- Hints: `K2:load K3:rec K2+3:save` (`K3:stop` while the slot records, `K3:...` while it is `finishing`), or `K2:- K3:- E3:source`.

The flash: `buffer_page_flash(text)` starts the shared "hints" flash for 1.5 s (see Header and flashes). `redraw()` draws it on the hint row instead of the key hints while it shows; its clock asks for a redraw when it ends; a new flash cancels the previous clock; cleanup step 140 cancels it.

### The file selector (K2 release)

- K2 release calls `fileselect.enter(_path.audio, cb)`. `cb` calls `load_buffer(slot, path)` unless the path is `"cancel"`, then clears `S.BUFFER_PAGE.file_selector_open` and asks for a redraw (the next frame draws the page).
- `fileselect` is `lib/pages/buffer.lua`'s `local fileselect = require "fileselect"`. `strata.lua` requires it too, for `redraw()`, as norns' own `core/menu.lua` does: the library is a module, not a global.
- `buffer_key_release` sets the flag just before `fileselect.enter`. While it is set, `redraw()` calls `fileselect.redraw()` (lib/fileselect.lua's `fs.redraw`, which draws the file list) instead of the page.
- Why the flag: from play mode `fs.enter` calls `norns.menu.init()`, whose `_menu.set_mode(false)` puts Strata's `redraw` back in the global. Without the flag, the selector's own `redraw()` call and every frame-clock redraw (asked for by `key()`, buffer polls, sequencer steps, MIDI, grid/arc events) would draw over the file list.
- Drawing the selector rather than nothing also covers the norns menu opened and closed over it (K1 twice): `set_mode(false)` clears the screen and calls `redraw()`, which then shows the list again instead of leaving the screen blank.
- norns calls the callback on a choice and on a cancel alike (`fs.exit`, after its own `redraw()`), so the flag always clears.
- The callback calls `close_buffer_file_selector()`, which clears the flag, `S.BUFFER_PAGE.file_selector_callback` and the saved handlers, and asks for a redraw.
- If `fileselect.enter` raises (it runs in an `xpcall` with `with_traceback`), no callback will come:
  - Strata's `key`/`enc` go back in the globals, and `close_buffer_file_selector()` runs;
  - unless the menu is open, `pcall(norns.menu.init)` routes play mode again. Every realistic failure point in `fs.enter` comes after its `norns.menu.init()` has routed `fs.key`/`fs.enc`, and keys reach the script through `_menu.key`/`norns.encoders.callback`, which only `set_mode(false)` copies from the globals, as `fs.exit` relies on;
  - then the error is raised again.

A second selector (issue #49):
- norns has a single selector (`lua/lib/fileselect.lua`'s module state).
- From play mode `fs.enter` stores Strata's `key`/`enc`/`redraw` in `fs.key_restore`..., puts `fs.key`/`fs.enc` in the globals, and `norns.menu.init()` hands them to play mode (`_menu.key = key`, `norns.encoders.callback = enc`).
- If the menu is opened over it (K1) and a PARAMS file param (or TAPE) calls `fs.enter` from menu mode, that call overwrites `fs.callback` and the restore fields with the menu's.
- Its `fs.exit` restores the menu's handlers only. Strata's callback never comes, and the globals keep `fs.key`/`fs.enc`, which `set_mode(false)` would give play mode as the menu closes (a later exit from that stale selector would even install the PARAMS menu's handlers as the script's).
- So `buffer_key_release` records the callback (`S.BUFFER_PAGE.file_selector_callback`) and Strata's `key`/`enc` (`S.BUFFER_PAGE.script_key`/`script_enc`).
- `menu_watch.wrapper` calls `release_superseded_file_selector()` before norns' `set_mode(false)`, in a `pcall` that prints an error, so it can never stop the menu closing.
- On a real menu-to-play change (`norns.menu.status()` still true as `set_mode(false)` starts), while the flag is set and `fileselect.callback` is set but no longer Strata's, it puts Strata's `key` and `enc` back in the globals (norns' `set_mode(false)` then gives them to play mode) and calls `close_buffer_file_selector()`.
- The selector's own `set_mode(false)` calls (from `norns.menu.init` in `fs.enter`/`fs.exit`) run in play mode and change nothing.
- A norns whose fileselect keeps no `callback` field releases nothing (the flag may then stay set after a menu selector, as before #49), so an internals change can never break BUFFER K2 itself.

## LFO

`redraw_lfo`, `lfo_enc`, `lfo_key`:
- One row per LFO. Row top = `LFO_PAGE.row_first_y` (16) + (n - 1) × `LFO_PAGE.row_spacing` (15), so rows fill y 16-57.
- `L<n>` at x 0 (baseline top + 7; level 15 for `S.selected_lfo`, 4 otherwise).
- One cycle of the shape as a 64-px polyline from x `LFO_PAGE.wave_x` (12) to 75: value 1 at the row top and 0 at top + `LFO_PAGE.wave_height` (10), level 6 running / 2 off, from `lfo_shape_value(shape, phase)` (a mirror of the library's shape math; random is drawn as two held steps).
- While the LFO runs and has sent a value, a 3×3 dot at x = 12 + `lfo_phase_estimate(n)` × 63, y from `S.lfo_last_raw[n]`.
- Right-aligned at x 127: the destination label (baseline top + 5) and `on|off <depth>%` (top + 11).
- Hints `E3:depth K2:dest K3:on|off`.
- E2 selects `S.selected_lfo`, E3 `params:delta("lfo_depth_<n>", d)` (percent), K2 steps `strata_lfo<n>_dest` (wrapping to none), K3 toggles `lfo_<n>` between 1 and 2.
- The page has no clock of its own: `draw_frame` marks the screen dirty on every frame while it is shown (15 fps), so the dots move. `cleanup` stops the frame clock with `stop_frame_clock()`.

## SETUP

`redraw_setup`, `setup_enc`, `setup_key`:
- Grid count and sizes (in port order), arc connected/none, `scenes: k/8 saved`.
- `buffers: k restored` (`S.buffers_restored`, engine-confirmed), or `buffers: k ok, m missing` when remembered files were missing.
- `midi <port>: <device>` (y 48; `midi_device_name()` cut with `fit_text` to end by x 127, so long norns device names fit) and `ch: <channel mode>` (y 54, level 4).
- Rows y 18-54, 6 px apart.
- E2 is `params:delta("midi_device", d)`, E3 `params:delta("midi_channel_mode", d)`, K3 calls `save_scenes_to_disk()`.
- Hints `E2:port E3:ch K3:save`.
- `setup_enc` is a global function.
- `grid.add`/`grid.remove`/`arc.add`/`arc.remove`/`midi.add`/`midi.remove` call `request_redraw()`, so SETUP stays current (drawn on the next frame).
