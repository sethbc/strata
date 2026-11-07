## Must not break

- While `S.BUFFER_PAGE.file_selector_open` is set, `redraw()` draws the file selector (`fileselect.redraw()`), never the page, so no frame-clock redraw draws over the file list.
- `buffer_key_release` calls `forget_held_keys()` just before `fileselect.enter`: the selector takes the keys, so a key held then would never be released to the script.
- A K2 pressed with ALT releases through `alt_key_release`, never `key_release`, so it never opens the file selector, even when K1 comes up first.
- BUFFER's flashes go through `buffer_page_flash` (the shared "hints" flash, owned by BUFFER), never a clock of the page's own; they show only while BUFFER is up.
- A save while the slot is `recording` or `finishing` saves nothing (`buf <n> busy`).
- `fileselect` is required (`require "fileselect"`), never read as a global.

## Owns

- `lib/pages/buffer.lua` (`S.lib.pages_buffer`): the BUFFER record (with `key_release`), `redraw_buffer`, `buffer_enc`, `buffer_key`, `buffer_key_release`, `buffer_hints`, `buffer_display_name`; `S.BUFFER_PAGE`, the file selector (`close_buffer_file_selector`, `release_superseded_file_selector`, global), `buffer_page_flash` (global, on the shared "hints" flash).
- The buffers themselves (`S.buffers`, `record_buffer`, `load_buffer`, `save_buffer`, `buffer_load_failed`, ...) are `lib/buffers.lua`'s (`docs/notes/lua/buffers.md`).
- Its unit tests: `test/unit/pages_buffer_test.lua`. Its rings: `lib/arc/buffer.lua` (`docs/notes/lua/arc-pages.md`).

## Layout

`redraw_buffer`, `buffer_enc`, `buffer_key`, `buffer_key_release`.
- Left column (x 0-60): the selected voice's name (y 18), `src: <voice_source_label>` (y 26), `dur:` record duration (y 42) and `lvl:` record level (y 50).
- Divider at x 62.
- Right column, eight rows (`S.BUFFER_PAGE.row_first_y` 14, `row_spacing` 6, so y 14-56):
  - slot number at x 65 (`slot_x`);
  - name at x 71 (`name_x`): the file name without extension, cut by `fit_text` with `screen.text_extents` to `S.BUFFER_PAGE.name_max_width` 31 px, whole UTF-8 characters at a time. `buffer_display_name` caches the cut name in `S.buffers[slot].display_name` until `name` changes, so a redraw measures nothing;
  - seconds (`%.1fs`) or `REC`, right-aligned at x 127.
- Row level: the selected voice's buffer (`voice_buffer_slot`) 15, loaded or recording 8, empty 2.

## Controls

- E2 is `select_voice_by` (shared with MAIN), E3 `enc_param_delta(3, "v<i>_source", d)`.
- K3 press: `record_buffer(slot)` (toggles: stops early while recording), or `save_buffer(slot)` when K2 is held on this page (`S.buffer_saved_during_k2` then makes the K2 release do nothing).
- The save is confirmed by `buffer_page_flash(text)`:
  - `buf <n> busy` (and no `save_buffer` call) while the slot is `recording` or `finishing`;
  - else `saved buf <n>` when the slot reports audio (`seconds > 0`, the rule `save_buffer` saves by);
  - else `buf <n> empty`.
- `buffer_load_failed` flashes `buf <n> load failed` when the engine reports a failed load (see the buffers table in `docs/notes/engine.md`).
- With no buffer source (synth, input) K2 and K3 do nothing.
- Hints: `K2:load K3:rec K2+3:save` (`K3:stop` while the slot records, `K3:...` while it is `finishing`), or `K2:- K3:- E3:source`. No ALT keys yet (an ALT+K2 does nothing, and its release opens nothing).

The flash: `buffer_page_flash(text)` = `S.lib.ui_flash.start("hints", text, 1.5, UI_PAGES.index.BUFFER)`. `redraw()` draws it on BUFFER's hint row instead of the key hints while it shows (a failed load reported while another page is up shows if BUFFER comes up within 1.5 s); its clock asks for a redraw when it ends; a new flash cancels the previous clock; cleanup step 140 cancels it (`docs/notes/lua/ui-core.md`).

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
