## Must not break

- Never call `redraw()` or `arc_redraw()` from script code. Call `request_redraw()`, and the frame clock draws whatever is dirty at `UI_PAGES.FRAMES_PER_SECOND` (15). Grid redraws stay direct (`grid_redraw()`).
- SEQ animates through the frame clock: `draw_frame` marks the screen dirty each frame while SEQ shows and `S.pattern_playing`, like the LFO page, and never the arc. A page's `draw()` never calls `request_redraw()` to animate itself (that would redraw a connected arc at 15 fps).
- Change a page's draw function (`redraw_main`, `redraw_setup`, ...), never `redraw()`. While `S.BUFFER_PAGE.file_selector_open` is set, `redraw()` draws the file selector, never the page.
- Each page file creates one record at `S.registry.pages[UI_PAGES.index.<PAGE>]` and sets every field but the four arc fields (`arc_delta`, `arc_redraw`, `arc_alt_delta`, `arc_alt_redraw`), which only its `lib/arc/<page>.lua` sets. `strata.lua` includes every page file before every arc file and asserts every `UI_PAGES` name has its record with `draw`, `hints`, `enc` and `key`. A test checks who sets which field.
- A page's `draw()` draws its body only; `redraw()` draws the hint row from the "hints" flash while one shows, else from the record's `hints(alt_held)`. Never call `draw_hints` from a page.
- Transient texts go through `S.lib.ui_flash` (one clock per slot, canceled before a new flash in that slot starts, and at cleanup). Never give a page its own flash clock.
- Every page draws the header at y=8 and the hint row at y=62. No two strings on a row overlap and nothing leaves 128×64. The layout tests check it on every page record with every voice, source, ALT state and flash, and each record's `layout_states` (`test/unit/ui_layout_test.lua`). A page adds layout states only through its record's `layout_states`.
- The layout tests catch only strings that overlap on the same baseline, text off-screen, header rects under header text, the hint row and the MAIN divider. They do not catch strings on nearby baselines that collide, nor text drawn over a rect or a line in the page body: look at the page renders (Page renders below) for those.
- The header has no `dens:`: master density is on FX's first row, MAIN's arc ring 1 and in params.
- A key release acts only on the page where the key went down (`S.key_press_page`). Keys held while the norns menu opens are forgotten.
- Every ALT+K2/ALT+K3 action goes through `alt_action(page, n)`, never a direct `alt_key` call, so the long-press fallback can trigger it. A key pressed with ALT releases through `alt_key_release`, never `key_release`, even when K1 comes up first (on BUFFER, an ALT+K2 release must never open the file selector). `forget_held_keys` clears `S.alt_held` and `S.key_press_alt`.
- Never call `params:delta` from an encoder or a ring: a page's `enc` calls `enc_param_delta(n, id, d)` for every param edit, a ring `arc_sweep_param` or `delta_with_detent` (a test checks `lib/pages/` and `lib/arc/`). Fine adjustment is ALT+E3 only, never ALT+E2 or the arc. A change that reaches or crosses 0 on a range through 0 lands on exactly 0, whatever the size of the delta (an accelerated encoder delta of 2-5 included), and holds there for 3 detents or 24 ticks, but only within `DETENT.hold_seconds` (1 s) of reaching 0: a hold never outlives that, so one left from an old turn never swallows a later detent.
- A page change goes through `S.lib.ui_keys.set_ui_page`, which runs the records' `leave`/`enter` and forgets every carried arc tick (`forget_arc_ticks()`). Never set `S.ui_page` directly.
- `S.cursors.voice` is a row index into `voice_page_rows(S.selected_voice)`, always on a selectable row once clamped. The rows change with the voice's source and with the selected voice, so `redraw()` and `arc_redraw()` start with `S.lib.ui_cursors.clamp_all()`. Code that reads the voice cursor outside a redraw (a ring turn, a key) calls `S.lib.pages_voice.sync_cursor()` first, never `clamp_all()` alone: `clamp_all` only clamps the index and would lose the anchored param (a source change A → B → A must come back to the same param). Code that sets the cursor outside VOICE's handlers calls `S.lib.pages_voice.place_cursor(index)`.
- `unwatch_menu_opening()` puts `_menu.set_mode` back only if it is still Strata's wrapper; otherwise Strata's wrapper becomes a pass-through.
- A failing draw prints its error once per distinct error and the frame clock keeps running.
- The lock is called lock everywhere the user reads it (`[L]`, hints); the state and the scene field keep the name `frozen` (`S.frozen`, `toggle_lock`), so scene files load unchanged.

## Owns

- `lib/ui/frame.lua` (`S.lib.ui_frame`): `S.ui_page`; `request_redraw`, `draw_frame`, `draw_frame_part`, `draw_error_report` and the frame clock (`start_frame_clock`, `stop_frame_clock`; cleanup step 60). The runtime fields (`screen_dirty`, `arc_dirty`, `frame_clock`, `draw_errors`) are on the shared `S.constants.UI_PAGES` table.
- `lib/ui/params.lua` (`S.lib.ui_params`): `param_range`, `param_spans_zero`, `param_default`, `param_value_fraction`, `param_fraction`.
- `lib/ui/header.lua` (`S.lib.ui_header`): `draw_header`, `draw_hints`. Its positions are `S.constants.HEADER` (`lib/constants.lua`).
- `lib/ui/flash.lua` (`S.lib.ui_flash`): the flashes, `S.lib.ui_flash.start`, `.text`, `.cancel_all`, `.slots`, and `header_flash` (global); cleanup step 140.
- `lib/ui/text.lua` (`S.lib.ui_text`): `S.lib.ui_text.fit_text`.
- `lib/ui/field_list.lua` (`S.lib.ui_field_list`): stateless helpers for a page that is a list of fields with one cursor. Rows are `{label, param_id?, selectable, section?}`; a cursor is a row index at a selectable row. `move` (skips label rows, no wrap), `clamp`, `ordinal`, `first_visible` (one row above the cursor in view), `draw(rows, cursor, spec, draw_row)` (`draw_row(row, y, selected, value_right)`) and `draw_marker` (1 px line at x 127, none when every row fits). FX, VOICE, BUFFER and SETUP use it.
- `lib/ui/keys.lua` (`S.lib.ui_keys`): `S.key_press_page`, `S.alt_held`, `S.key_press_alt`, `forget_held_keys` (global); `set_ui_page` (runs the records' `leave`/`enter` and forgets carried arc ticks), `select_voice_by`, `ignore_page_input` (fields of `S.lib.ui_keys`).
- `lib/ui/alt.lua` (`S.lib.ui_alt`): `alt_action` (global); `set`, `long_press` (fields of `S.lib.ui_alt`). See ALT below.
- `lib/ui/detent.lua` (`S.lib.ui_detent`): `delta_with_detent`, `enc_param_delta` (global); the holds at 0 (local). See Center detents and fine adjustment below.
- `lib/ui/menu_watch.lua` (`S.lib.ui_menu_watch`): the `_menu.set_mode` wrapper (`watch_menu_opening`, `unwatch_menu_opening`, `forget_keys_held_through_menu`; cleanup step 20).
- `lib/ui/voice_rows.lua` (`S.lib.ui_voice_rows`): `voice_page_rows`, `voice_page_group` (global); `first_field_row`, `GROUP_SIZE` (fields).
- `lib/ui/cursors.lua` (`S.lib.ui_cursors`): `S.cursors`; `move`, `clamp_all` (fields).
- The page renders: `test/render_pages.lua` and `test/render_pages.py` (below).

Each page has its own notes file: `docs/notes/lua/pages/main.md`, `voice.md`, `seq.md`, `fx.md`, `lfo.md`, `buffer.md`, `scenes.md`, `setup.md`. The arc's rings for each page are in `docs/notes/lua/arc-pages.md`, the arc's dispatch in `docs/notes/lua/arc-core.md`.

## Pages and dispatch

The screen has `NUM_UI_PAGES` (8, `#UI_PAGES`) pages, named in `UI_PAGES = {"MAIN", "VOICE", "SEQ", "FX", "LFO", "BUFFER", "SCENES", "SETUP"}`. `UI_PAGES.index[name]` is a page's index (`UI_PAGES.index.FX == 4`); `UI_PAGES.MAIN_PAGE` stays 1. `S.ui_page` is the index of the shown page.

Encoders and keys (`strata.lua`):
- `enc(1, d)` selects the page (`S.lib.ui_keys.set_ui_page(util.clamp(S.ui_page + d, 1, NUM_UI_PAGES))`), stopping at MAIN and SETUP. E1 does nothing else. `set_ui_page` does nothing when the page does not change; on a change it calls the old record's `leave()`, forgets every carried arc tick (`forget_arc_ticks()`, so ticks turned on one page never step a param on another), sets `S.ui_page` and calls the new one's `enter()`, if the records have them.
- At init a start step in `strata.lua` (`START_ORDER.e1_settings`) turns E1's acceleration off and sets its sensitivity to `E1_TICKS_PER_PAGE` (4) with `norns.enc.accel(1, false)` / `norns.enc.sens(1, ...)`, so a fast turn steps pages instead of skipping to SETUP. norns resets these on every script load, so cleanup restores nothing.
- `enc(2|3, d)` calls `S.registry.pages[S.ui_page].enc(n, d)`, and `key(n, 1)` (K2, K3) calls `S.registry.pages[S.ui_page].key(n)`. With ALT held both go the ALT way instead (ALT below).
- `key(1, z)` only sets ALT (`S.lib.ui_alt.set(z == 1)`; K1 held is ALT; norns delivers K1 to a script only once held). `forget_held_keys` clears it.
- Master density left E1. It is on the FX page's first row, MAIN's arc ring 1 and in params. The header no longer shows it.

Page records. Each page lives in its own file and creates one record at `S.registry.pages[UI_PAGES.index.<PAGE>]`:
- Required: `name`, `draw()` (the page body only), `hints(alt_held) -> string` (the hint row), `enc(n, d)` (E2, E3), `key(n)` (K2, K3 presses).
- Optional, every one dispatched today:
  - `alt_enc(n, d) -> handled`, `alt_key(n)`, `alt_key_release(n)`: the ALT layer (ALT below);
  - `key_release(n)`: a plain key's release, on the page it went down on;
  - `enter()`, `leave()`: run by `set_ui_page` on a page change;
  - `arc_button()`: the arc's button on this page. `arc_key` (`lib/arc/core.lua`) calls the shown record's `arc_button` on a press, on every page that has one, and requests a redraw; a page without one ignores the button. MAIN's is `start_stop_selected_voice` (K3; VOICE's is `start_or_stop_selected_voice`, and `toggle_lock` locks);
  - `header_status() -> string|nil`: a text that replaces the header's indicators (Header and flashes);
  - `layout_states`: an array of `{name, setup = function(context)}` the layout tests (`test/unit/ui_layout_test.lua`) and the page renders draw, each on a fresh script with the page shown.
- Arc fields, set only by `lib/arc/<page>.lua`: `arc_delta(n, d)`, `arc_redraw(arc_port)`, `arc_alt_delta(n, d)`, `arc_alt_redraw(arc_port)` (`docs/notes/lua/arc-core.md`).
- Ownership: the page file sets every field but the arc fields; the arc file sets only those, on `S.registry.pages[UI_PAGES.index.<PAGE>]`. So a page and its rings never edit the same file. `strata.lua` includes every page file before every arc file.
- `ignore_page_input` fills the handlers a page does not use.
- To add a page: add its name to `UI_PAGES` (`NUM_UI_PAGES` follows), write its file and record, include it from `strata.lua` with the other pages, and, if it has rings, an arc file like `lib/arc/fx.lua` included after the pages (`docs/notes/lua/arc-pages.md`). VOICE, SEQ and SCENES already have their page and arc files (stubs), so filling them in adds no include.

`redraw()`:
- `screen.clear(); draw_header(); record.draw(); draw_hints(S.lib.ui_flash.text("hints") or record.hints(S.alt_held)); screen.update()`, with `record = S.registry.pages[S.ui_page]`.
- Except while the BUFFER page's file selector is open (`S.BUFFER_PAGE.file_selector_open`): then it calls `fileselect.redraw()` and returns, so neither norns' own `redraw()` calls nor Strata's frame clock draw the page over the file list (`docs/notes/lua/pages/buffer.md`).
- The hint row (`draw_hints(text)`: level 4, x=0, y=62) is drawn once, by `redraw()`: the "hints" flash while one shows (only on its owning page), else the record's hints.

## Header and flashes

`draw_header()` (`lib/ui/header.lua`), y=8, positions in `S.constants.HEADER`:
- Page title at x 0, level 15. 04B_03 capitals advance about 6 px, so the longest titles, `BUFFER` and `SCENES`, end near x 36.
- Eight page dots: 2×2 filled rects (`dot_size`) at y 4 (`dot_y`) from x 40 (`dots_x`), 4 px apart (`dot_spacing`), so x 40-69. The current page's at level 15 (`current_dot_level`), the rest at 3 (`dot_level`).
- Indicators, each only while active: `[M]` at x 76 (`mutation_x`, level 6) while `mutation_enabled` is 1 (abbreviated to make room for the play mark, `REC` and the scene); the play mark at x 90 (`play_x`) while `S.pattern_playing`; `REC` at x 96 (`rec_x`, level 15) while any `S.buffers[slot].recording`.
- The play mark is a filled 3×5 triangle pointing right: three 1-px-wide rects, 5, 3 and 1 px tall, from y 3 (`play_y`), level 15.
- A record with `header_status()` returning a string: the text at x 79 (`status_x`, level 10, cut with `fit_text` to end by x 114) and the play mark at x 73 (`status_play_x`, while patterns play; three clear pixels before the text) replace `[M]`, the play mark and `REC`. Returning nil keeps the indicators. The dots stay.
- Scene indicator `S1`-`S8` (`S.current_scene`) right-aligned at x 127 (`scene_right`): level 10 while the scene sequencer runs, 6 when static.
- No `dens:`: master density left the header.
- The design's x 80/94/100 put `REC` over a right-aligned `S8` under the layout test's width estimate; 76/90/96 keep the same order and spacing and fit.
- Nothing calls for a redraw on its own here: the indicators' state changes already ask for one (param actions, `grid_key`/`key` around `pattern_toggle`, `buffer_display_changed`).

Flashes (`lib/ui/flash.lua`, `S.lib.ui_flash`):
- Two slots, `"header"` and `"hints"` (`S.lib.ui_flash.slots[slot]`: `text`, `ends_at`, `page`, `clock`). Another slot name is an error.
- `S.lib.ui_flash.start(slot, text, seconds, page)` (seconds default `HEADER.flash_seconds`, 1.5; `page` a `UI_PAGES` index or nil): cancels the slot's running clock, stores the text, the page and `ends_at = util.time() + seconds`, starts a clock that sleeps `seconds`, clears the text and calls `request_redraw()`, and asks for a redraw itself. So one clock per slot runs at a time. A nil text only ends the flash showing (never draws `nil`).
- `S.lib.ui_flash.text(slot)`: the text while `util.time() < ends_at` and, for a flash with a page, while that page is up (`S.ui_page`); else nil (so a clock that wakes late changes nothing on screen, and a prompt such as SCENES' "K3 again" never shows over another page's keys).
- `S.lib.ui_flash.cancel_all()`: cleanup step 140 cancels both clocks and clears the texts.
- `header_flash(text)` (global) = `start("header", text, 1.5)`. While it shows, the header draws the text at x 40 (`flash_x`), level 15, cut with `fit_text` to 74 px (`flash_width`, so it ends by x 114, before a right-aligned `S8`), instead of the dots and indicators (and a `header_status`). The title and scene stay.
- A hints flash is not cut: keep its text short enough for the row (the layout test draws "K3 again: overwrite S8" on every page).

## Cursors and VOICE rows

`S.cursors` (`lib/ui/cursors.lua`) holds the cursors more than one page or ring set uses:
- `voice`: a row index into `voice_page_rows(S.selected_voice)` (a `field_list` cursor). It starts on the first selectable row (row 2: row 1 is the first section's label).
- `seq_step`: 1..`PATTERN_LENGTH`.
- `scene`: 1..`NUM_SCENES + #SCENES_FIELDS` (12): the eight scene slots, then the four `S.constants.SCENES_FIELDS` params (`scene_transition_time`, `scene_sequencer_enabled`, `scene_sequence_length`, `scene_duration`).

`S.lib.ui_cursors.move(name, d)` moves one by `d` stops, clamped at its ends (no wrap): `voice` through `S.lib.ui_field_list.move` on the selected voice's rows (section labels take no stop), the others with `util.clamp`. An unknown name is an error. `S.lib.ui_cursors.clamp_all()` puts each cursor back on a real stop: `voice` through `field_list.clamp` (the nearest selectable row at or before it, else the first), the others within their range. `redraw()` and `arc_redraw()` run it first, so a source switched by the grid, MIDI or a scene recall, or another selected voice, never leaves the cursor past the end or on a label row. Neither function requests a redraw: their callers (`enc`, `key`, `arc_delta`) do.

`voice_page_rows(voice_idx)` (global, `lib/ui/voice_rows.lua`) lists every param of a voice in four sections, each opened by a label row `{label = <section>, section = <section>, selectable = false}`. A field row is `{label = <param name>, param_id, section, selectable = true, kind}`, `kind` being `"control"`, `"number"` or `"option"` from the param's type.
- `synth`: `param_order` without `amp` and `pan`; for a buffer source `buf_pos`, `buf_rate`, `buf_scan`; for the input source the section, label included, is left out.
- `grain`: `grain_size`, `grain_density`, `grain_pitch`, `grain_spread`, `grain_env`, `grain_mode`.
- `crossmod`: `mod_speed`, then per slot `mod_source_<s>`, `mod_amp_amt_<s>`, `mod_freq_amt_<s>`.
- `mix`: `source`, `amp`, and `pan` when the voice has one (Sub has none).

The rows are built on each call from the voice's current source, so they follow a source change at once. Voice 1 has 28 rows (24 fields); a voice index outside 1..`NUM_VOICES` is an error. The 256's fader pages keep their own list (`fader_param_ids`).

`voice_page_group(rows, cursor) -> group, row_indices` (global) gives the arc's ring group: with `k` the cursor's position among the selectable rows (`field_list.ordinal`), `group = ceil(k / 4)` and `row_indices` the row indices of selectable rows `4 * group - 3 .. 4 * group`, fewer in a last group that is not full (voice 2 has 23 fields: its sixth group is source, amp, pan). VOICE's screen marks these rows and the rings 1-4 edit them in order.

## ALT

`lib/ui/alt.lua` (`S.lib.ui_alt`). ALT is K1 held: norns delivers K1 to a script only after `KEY1_HOLD_TIME` (0.25 s, `lua/core/menu.lua`), and a shorter press opens the norns menu, so K1 is a hold-only key (3.1 design §2).
- `S.lib.ui_alt.set(held)` sets `S.alt_held` and requests a redraw (the hint row shows the page's ALT layer, `record.hints(true)`, and the arc switches to its ALT rings). `key(1, z)` calls it.
- `alt_action(page, n)` (global) runs `S.registry.pages[page].alt_key(n)` and returns true, or returns false and does nothing when `n` is not 2 or 3, `page` is not a page index, or the record has no `alt_key`. It takes the page as an argument, so a caller can name a page that is not showing.
- `key(n, 1)` with ALT held records the key's page (`S.key_press_page[n]`), marks it an ALT press (`S.key_press_alt[n] = true`) and calls `alt_action(S.ui_page, n)`; the record's `key` never runs. Without ALT it clears the mark and calls `key(n)`. A page without `alt_key` ignores ALT+K2/ALT+K3: they never fall through to `key`.
- `key(n, 0)` clears both marks and, if the key went down on the page still showing, calls `alt_key_release(n)` for an ALT press and `key_release(n)` otherwise (each only if the record has it). The press decides, not the state of K1 at release: K1 down, K2 down, K1 up, K2 up releases through `alt_key_release`, so BUFFER's K2 release never opens the file selector after an ALT+K2; K2 down, K1 down, K2 up releases through `key_release`.
- `enc(2|3, d)` with ALT held calls `alt_enc(n, d)` first; when the record has none or it returns false or nil (not handled), `enc(n, d)` runs. `enc(1, d)` steps the page with or without ALT and never reaches the record.
- `forget_held_keys` (as the norns menu or the file selector takes the keys) clears `S.alt_held` and every `S.key_press_alt` mark with `S.key_press_page`.

The long-press fallback (design §2): if the hardware check rejects K1 as ALT, a `LONG_PRESS_SECONDS` (0.6, `lib/constants.lua`) hold of K2 or K3 takes its ALT action. Only the hook is built: `S.lib.ui_alt.long_press(n)` is what the hold timer would call. If key `n` (2 or 3) is still down on the page showing and is not already an ALT press, it marks it one, calls `alt_action(S.ui_page, n)`, requests a redraw and returns true (its release then goes to `alt_key_release`); otherwise it returns false. Nothing calls it while K1 works as ALT. Switching to the fallback means starting a `LONG_PRESS_SECONDS` clock on each K2/K3 press that calls it (canceled on release and in cleanup), and moving each page's press actions to release where a long press must not also run them.

## Center detents and fine adjustment

`lib/ui/detent.lua` (`S.lib.ui_detent`), with `param_spans_zero` and `param_default` in `lib/ui/params.lua`. Every encoder and ring change of a param goes through `delta_with_detent(param_id, d, opts)` (global); never `params:delta`.
- Pages: `enc_param_delta(n, param_id, d)` (global) is `delta_with_detent(param_id, d, {fine = n == 3 and S.alt_held})`. Every page's `enc` calls it for a param edit (MAIN, FX, LFO and BUFFER E3, SETUP E2 and E3), so fine adjustment reaches E3 only: ALT+E2 stays whole steps.
- Rings: `arc_sweep_param(id, ticks)` (`lib/arc/core.lua`) is `delta_with_detent(id, nil, {arc_ticks = ticks})`; the LFO page's whole-value rings call `delta_with_detent(id, steps)`.
- The change. Encoders: `d` detents, as `params:delta` takes them. A control param's raw value moves `d * quantum` through `params:set_raw` (what `Control:delta` does), or `d * quantum / FINE_DIVISOR` (10) with `opts.fine`; number and option params go through `params:delta` in whole steps and ignore `fine`. Arc (`opts.arc_ticks = n`, control params only): the raw value moves `n / UI_PAGES.ARC_TICKS_PER_SWEEP`. A param's `controlspec.step` still rounds the value read back, so a coarse param moves more slowly under fine adjustment, not more finely.
- The detent, for a param whose range spans 0 (`param_spans_zero`: a control or number param with `min < 0 < max`; option params and wrapping specs never): a change from a non-zero value whose result is 0 or has the other sign sets exactly 0 (`params:set(id, 0)`) and starts a hold, however large the change. While the hold lasts and the value is still 0, each change uses up `|d|` detents or `|n|` ticks and leaves the value at 0; the change that uses up more than is left ends the hold and applies in full, from 0. A hold ends too when the value is found away from 0 (something else moved it), and when `DETENT.hold_seconds` (1 s) have passed since it started (`util.time()` is stored with the hold): an expired hold swallows nothing, so a value set back to 0 by something else (two scene recalls, say) never keeps an old hold.
- A hold is `DETENT.encoder_detents` (3) detents or `DETENT.arc_ticks` (24) ticks within `DETENT.hold_seconds` (1 s) (`lib/constants.lua`). Holds are kept per param id in units both turn kinds use up in whole numbers (a whole hold is 3 × 24; a detent uses 24, a tick 3), so a hold the arc starts and an encoder finishes lasts as long.
- `param_default(id)`: a control param's `controlspec.default` (a spec without one: `spec:map(0)`, where norns starts it), or a number or option param's `default`.

## Key releases and the norns menu

Releases:
- `key(n, 1)` records `S.key_press_page[n] = S.ui_page`.
- `key(n, 0)` clears it and calls the page record's `key_release(n)` (or `alt_key_release(n)` for an ALT press, ALT above) only if the key went down on the page still shown, so a key held across a page change does nothing when released.
- Only BUFFER has a `key_release` today; on every other page releases do nothing.
- "K2 is held on this page" is `S.key_press_page[2] == S.ui_page`.

Keys held into the menu:
- The norns menu (K1, PARAMS, its file selector) takes every key while open (`_menu.key` is the menu's handler), so a key released there never reaches `key()`.
- `forget_keys_held_through_menu()`, called at the end of `drift_update` (the 10 Hz `S.drift_metro` tick), clears `S.key_press_page`, `S.key_press_alt` and `S.alt_held` whenever `norns.menu.status()` is true.
- Without it, a key released in the menu would stay held on the page it went down on.
- It also runs the moment the menu opens. Every way into the menu (K1, a script error, a keyboard's menu key) calls `_menu.set_mode(true)`, which `lua/core/menu.lua` and `keyboard.lua` look up on `_menu` at each call.
- So `watch_menu_opening()` (from its start step, `START_ORDER.menu_watch`) wraps it in `menu_watch.wrapper`: call norns' function, then `forget_keys_held_through_menu()` when `mode == true`.
- The wrapper holds norns' function and `forget_keys_held_through_menu` as upvalues (no script-global lookup).
- `unwatch_menu_opening()`, cleanup's second step (after the tempo handler, before anything that can fail), puts `menu_watch.original_set_mode` back only if `_menu.set_mode` is still Strata's wrapper. Otherwise (something wrapped it later) it leaves that wrapper in place and turns Strata's into a pass-through (`menu_watch.active = false`).
- The 10 Hz tick stays as a fallback.
- norns has no key-state query.
- A file selector opened from play mode, as BUFFER K2 does, keeps `norns.menu.status()` false and takes the keys through the global `key`. It opens on K2's release, so only a K3 or K1 (ALT) held at that moment can be released there. `buffer_key_release` therefore calls `forget_held_keys()` just before `fileselect.enter`. `forget_held_keys` is a global: it clears `S.key_press_page`, `S.key_press_alt` and `S.alt_held`, and is also the body of `forget_keys_held_through_menu`.

## Redraws

Issue #11. Nothing in Strata calls `redraw()` or `arc_redraw()` directly.
- Anything that changes what the screen or the arc shows calls the global `request_redraw()`, which sets `UI_PAGES.screen_dirty` and `UI_PAGES.arc_dirty`.
- The frame clock (`UI_PAGES.frame_clock`, `start_frame_clock()` in init's last start step, `stop_frame_clock()` in `cleanup`, after the start-up clock) sleeps `1 / UI_PAGES.FRAMES_PER_SECOND` (15) and runs `draw_frame()`.
- `draw_frame()` clears each dirty flag and calls the global `redraw()` and/or `arc_redraw()`. A burst of arc turns, encoder steps, MIDI or param changes costs one screen draw and one arc redraw per frame, and an idle frame draws nothing.
- Both flags start set, so the first frame draws the screen and any arc connected at start.
- On the LFO page, and on SEQ while `S.pattern_playing`, `draw_frame` marks the screen dirty every frame (screen only, never the arc), so the dots and the playing column move. Neither page has a clock of its own.

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
- Explicit calls cover state that is not a param: `enc`, `key`, `arc_delta`, `arc_key`, `grid_key`, `toggle_voice`, `toggle_lock`, `randomize_voice`, `gentle_mutate`, each smooth-transition step, `recall_scene` and the end of `recall_scene_instant` (lock and running states), the scene sequencer, `buffer_display_changed`/`buffer_state_changed`, a flash's start and end (`S.lib.ui_flash.start` and its clock) and the BUFFER file selector's callback, and the grid/arc/MIDI hot-plug callbacks.

## Layout tests

`assert_screen_layout(context, where)` (`test/helpers.lua`) checks one drawn screen:
- no two strings on a row overlap, and nothing leaves 128×64 (estimating 6 px per capital, 4 per bracket/colon/period, 5 otherwise);
- the page title at 0,8, then the eight page dots (2×2 rects at x 40, 44, ..., 68, the first at least 4 px after the title), or, while a header flash shows (`S.lib.ui_flash.text("header")`), its text at 40,8 and no dots;
- no header rect (a dot, the play mark: rects above y 9) lies under a header string;
- a hint row is drawn at y=62;
- on MAIN every string between the header and the hint row ends by x=60 or starts at x=65 or later (never across the divider).

`test/unit/ui_layout_test.lua` runs it on every page record with every voice (1-7), source (synth, buf 1, input), ALT state (up, down) and flash (none, a long header flash, the longest hints flash), then on each record's `layout_states` (each on a fresh script, with ALT up and down). It also keeps the older every-page checks (the widest SETUP page with four grids, the voice list's last row above the hint row). Each page's own layout tests are in its unit file (`pages_main_test.lua`, ...); the header and flash tests in `test/unit/ui_header_test.lua`.
- Keep them passing when adding text. The width estimate is `stubs.text_width` in `test/norns_stubs.lua` (it counts UTF-8 characters, not bytes), which the screen stub also uses for `screen.text_extents` (returns width, 8).
- The stub records each string's `x`, `y`, `align` (`left`, `right`, `center`) and `level`, and each rect and line with `filled` (true after `screen.fill()`, false after `screen.stroke()`).
- The stub's `UI.ScrollingList:redraw` is the real one from `lua/lib/ui.lua`, so the list's entries are recorded like any other text (an empty string where the list scrolls past an end).

## Page renders

Run on demand, never in `lua test/run.lua`: `lua test/render_pages.lua <dir>`, then `python3 test/render_pages.py <dir> --font <path to a .ttf>` (Pillow).
- `test/render_pages.lua` loads the script through the stubs (it requires `test/helpers.lua`) and, for each state, on a fresh script after startup, shows the page, runs the state's setup and writes `<page>-<state>.json`: the page and state names and every text (`x`, `y`, `text`, `align`, `level`), rect (`x`, `y`, `w`, `h`, `level`, `filled`) and line (`x1`, `y1`, `x2`, `y2`, `level`, `filled`) the draw made. Its states are its own `STATES` (MAIN synth, buffer, input, ALT and a header flash; VOICE; SEQ playing; FX; LFO; BUFFER and BUFFER recording; SCENES; SETUP), then each page record's `layout_states`. As a module it returns `render_page_states(out_dir)`, which returns the file names it wrote.
- `test/render_pages.py` draws each JSON file as a 128×64 PNG beside it, scaled 4× without smoothing: levels as grays, rects filled or outlined, texts at their baseline (left, right or center) in the `--font` file at 8 px. Without `--font` it uses `~/src/norns/resources/norns.ttf` (norns' 04B_03) when it exists, else Pillow's built-in font.
- The suite's test "the render dump writes one file per page state" (`ui_layout_test.lua`) runs `render_page_states` into a temporary folder: at least 13 files, each well-formed JSON naming a page from `UI_PAGES`, and a render of every page.
