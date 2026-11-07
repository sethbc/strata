## Must not break

- While `S.BUFFER_PAGE.file_selector_open` is set, `redraw()` draws the file selector (`fileselect.redraw()`), never the page, so no frame-clock redraw draws over the file list.
- `buffer_key_release` calls `forget_held_keys()` just before `fileselect.enter`: the selector takes the keys, so a key held then would never be released to the script.
- ALT+K2 (clear) releases through `alt_key_release` (BUFFER has none), never `key_release`, so it never opens the file selector, even when K1 comes up first (K1 down, K2 down, K1 up, K2 up). BUFFER never reads `S.key_press_page[2]` to change what K3 does: the K2+K3 save gesture is gone (ALT+K3 saves), and a K2 pressed with ALT is still in `S.key_press_page`.
- Every key and the arc button act on the slot cursor (`S.buffer_page.slot`), never on the selected voice's buffer: K3 records into it whether or not a voice reads it.
- BUFFER's flashes go through `buffer_page_flash` (the shared "hints" flash, owned by BUFFER), never a clock of the page's own; they show only while BUFFER is up.
- A save while the slot is `recording` or `finishing` saves nothing (`buf <n> busy`).
- `fileselect` is required (`require "fileselect"`), never read as a global.
- The input meter's polls (`amp_in_l`, `amp_in_r`) run only while BUFFER shows: the record's `enter` starts them, `leave` and cleanup step `input_meter` (135) stop them and clear their callbacks, so a value already on its way asks for no redraw. They are looked up with `poll.set` at each `enter`, never kept from an earlier one or from load time (norns replaces its poll objects when it re-registers the polls). A norns without them leaves the meter dark.
- A poll value asks for a redraw only when the drawn level or held peak changes. The peak's expiry is checked at draw time, so it goes out even with no new poll value.
- The slot list scrolls (six of eight rows visible). Rows and the scroll marker go through `S.lib.ui_field_list.draw`; no slot text reaches x 127 (the marker), and nothing in the left column crosses the divider.
- A redraw measures no text it measured before: slot names are cut once per name and width, the voice name once, and the seconds and voices texts' widths are memoized.

## Owns

- `lib/pages/buffer.lua` (`S.lib.pages_buffer`): the BUFFER record (`draw`, `hints`, `enc`, `alt_enc`, `key`, `key_release`, `alt_key`, `enter`, `leave`, `arc_button`, `layout_states`), `redraw_buffer`; `S.BUFFER_PAGE` (layout and the file selector state), `S.buffer_page` (the cursors), the file selector (`close_buffer_file_selector`, `release_superseded_file_selector`, global), `buffer_page_flash` (global, on the shared "hints" flash); `S.lib.pages_buffer.INPUT_METER`, `input_meter_segments(amp)` and the meter state `S.lib.pages_buffer.meter` (`amps`, `peak`, `peak_at`, `shown`, `polls`); cleanup step `input_meter`.
- The buffers themselves (`S.buffers`, `record_buffer`, `load_buffer`, `clear_buffer`, `save_buffer`, `buffer_load_failed`, ...) are `lib/buffers.lua`'s (`docs/notes/lua/buffers.md`).
- Its unit tests: `test/unit/pages_buffer_test.lua`. Its rings: `lib/arc/buffer.lua` (`docs/notes/lua/arc-pages.md`).

## Cursors

`S.buffer_page = {slot = 1, field = 1}`: `slot` 1..`NUM_BUFFERS` (E2), `field` 1..3 (ALT+E2): source (`v<selected>_source`), duration (`record_duration`), level (`record_level`). Both clamp at their ends and are put back in range before use. They persist across page changes; the slot cursor does not follow the selected voice.

## Layout

`S.BUFFER_PAGE` holds every position.
- Left column (x 0-54): the selected voice's name in capitals at y 16 (cut to the column with `fit_text`); the three fields at y 24, 32, 40 (`field_first_y`, `field_spacing` 8): `>` at x 0 on the field cursor's row, the label (`src`, `dur`, `lvl`) at x 5, the value right-aligned at x 54 (`voice_source_label`, `%.1fs`, `%.2f`). The cursor's row at level 15, the others 4.
- Input meter on y 49: `in` at x 5, then eight 3x5 px filled segments from x 17, 1 px apart (x 17-48): lit segments at level 10, the held peak segment (when above the level) at 15, the rest at 1.
- Divider at x 56, y 10-52 (level 1).
- Right column: `S.lib.ui_field_list.draw` with six visible rows from y 16, 7 px apart (y 16-51), one row above the cursor kept in view, the scroll marker at x 127 (y 10 to 52). Each row:
  - slot number at x 59;
  - name at x 65: the file name without extension, cut with `fit_text`, or `-` when the slot has no name (`name == "empty"`);
  - seconds (`%.1fs`) or `REC`, right-aligned at x 124; none for an empty slot (no name, no reported audio, not recording);
  - names in other rows end 3 px before the widest seconds column (`16.0s`); on the cursor row the voices reading the slot (`v2 v6`, built from `voice_buffer_slot`) are right-aligned 3 px before that row's own seconds, at most 25 px (`voices_max_width`) and never into the name's first 12 px (`name_min_width`), dropping whole voices from the end with `+` when they do not fit (`v2+`), and the name gets what is left. Under the layout test's width estimate a two-voice list always shortens to `v2+`; the norns font is narrower.
- Row level: the cursor row 15, a loaded or recording slot 6, others 2.
- `layout_states`: slot 1 and slot 8 (long names, voices on the cursor slot), each field, long names with every voice on one slot, every slot recording, the saved, busy, empty and load-failed flashes, the meter with a held peak.

## Controls

- E2 moves the slot cursor; ALT+E2 the field cursor (`alt_enc` returns true for E2 only). E3 is `enc_param_delta(3, <field param>, d)`, so ALT+E3 is fine adjustment (it only shows on the level: the duration's 0.5 s step and the source's options keep whole steps).
- K3 press and the arc button (`arc_button`): `record_buffer(slot)` (toggles: stops early while recording; does nothing while `finishing`).
- K2 release: the file selector for the cursor slot (below). K2's press does nothing; K3 while K2 is held just records.
- ALT+K2 (`alt_key(2)`): `clear_buffer(slot)`.
- ALT+K3 (`alt_key(3)`): saves, confirmed by `buffer_page_flash(text)`:
  - `buf <n> busy` (and no `save_buffer` call) while the slot is `recording` or `finishing`;
  - else `saved buf <n>` when the slot reports audio (`seconds > 0`, the rule `save_buffer` saves by);
  - else `buf <n> empty`.
- `buffer_load_failed` flashes `buf <n> load failed` when the engine reports a failed load (see the buffers table in `docs/notes/engine.md`).
- Hints: `K2:load K3:rec` (`K3:stop` while the cursor slot records, `K3:...` while it is `finishing`); with ALT `K2:clear K3:save`.

The flash: `buffer_page_flash(text)` = `S.lib.ui_flash.start("hints", text, 1.5, UI_PAGES.index.BUFFER)`. `redraw()` draws it on BUFFER's hint row instead of the key hints while it shows (a failed load reported while another page is up shows if BUFFER comes up within 1.5 s); its clock asks for a redraw when it ends; a new flash cancels the previous clock; cleanup step 140 cancels it (`docs/notes/lua/ui-core.md`).

## Input meter

- `S.lib.pages_buffer.INPUT_METER = {poll_seconds = 0.05, segments = 8, floor_db = -48, db_per_segment = 6, peak_hold_seconds = 1}`.
- `input_meter_segments(amp)` = `clamp(ceil((20 * log10(amp) - floor_db) / db_per_segment), 0, 8)`; 0 for `amp <= 0`, NaN or a non-number. So 0.5 (-6 dB) lights 7, 1 (0 dB) and above 8, 0.001 (-60 dB) none.
- `enter` resets the meter (levels 0, no peak), then for each poll `poll.set(name, callback)`, sets its `time` to `poll_seconds` and starts it. `leave` and cleanup stop them.
- Each value sets that channel's amplitude; the level is the louder channel's segments. When the level reaches or passes the held peak (or the hold has run out), the peak becomes the level and `peak_at` the time. The draw shows the level, plus the peak segment while `util.time() - peak_at < peak_hold_seconds` and the peak is above the level.

## The file selector (K2 release)

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
