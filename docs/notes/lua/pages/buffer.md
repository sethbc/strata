## Must not break

- While `S.BUFFER_PAGE.file_selector_open` is set, `redraw()` draws the file selector (`fileselect.redraw()`), never the page, so no frame-clock redraw draws over the file list.
- `buffer_key_release` calls `forget_held_keys()` just before `fileselect.enter`: the selector takes the keys, so a key held then would never be released to the script.
- K2, ALT+K2 and ALT+K3 act on release, by how long they were held: the press only notes `util.time()` (`pressed_at`), and the release compares it with `S.BUFFER_PAGE.hold_seconds` (0.5 s). No clock. ALT+K2 and ALT+K3 are the one exception to acting through `alt_action` at the press (design 3.3 §8.1, Question 20): `alt_key` notes the press, `alt_key_release` acts.
- An ALT press releases through `alt_key_release`, never `key_release`, so ALT+K2 never opens the file selector or loads a random file, even when K1 comes up first (K1 down, K2 down, K1 up, K2 up). BUFFER never reads `S.key_press_page[2]` to change what K3 does: the K2+K3 save gesture is gone (ALT+K3 saves), and a K2 pressed with ALT is still in `S.key_press_page`.
- Every key and the arc button act on the slot cursor (`S.buffer_page.slot`), never on the selected voice's buffer: K3 records into it whether or not a voice reads it.
- BUFFER's flashes go through `buffer_page_flash` (the shared "hints" flash, owned by BUFFER), never a clock of the page's own; they show only while BUFFER is up. `draw_hints` cuts a long one to the screen.
- A save (either kind) while the slot is `recording` or `finishing` saves nothing (`buf <n> busy`); the check is in `save_buffer` and `save_buffer_loop`, which `save_cursor_slot` flashes from.
- A save never shows `saved buf <n>` before the engine's `bufferSaveResult` report says the file is written (#127): ALT+K3 shows `saving buf <n>` (`saving buf <n> loop`), and `buffer_save_result` the result.
- `fileselect` is required (`require "fileselect"`), never read as a global.
- The input meter's polls (`amp_in_l`, `amp_in_r`) run only while BUFFER shows: the record's `enter` starts them, `leave` and cleanup step `input_meter` (135) stop them and clear their callbacks, so a value already on its way asks for no redraw. They are looked up with `poll.set` at each `enter`, never kept from an earlier one or from load time (norns replaces its poll objects when it re-registers the polls). A norns without them leaves the meter dark.
- A poll value asks for a redraw only when the drawn level or held peak changes, and of the screen alone (`S.lib.ui_frame.request_screen_redraw()`: no arc ring shows the meter, so it never repaints a connected arc, #434), and none while the file selector is open (#435; the selector's callback asks for the redraw that shows the meter again). The peak's expiry is checked at draw time, so it goes out even with no new poll value.
- Both lists scroll through `S.lib.ui_field_list` (`first_visible`, `move`, `clamp`, and `draw` for the slots): the slots' marker at x 127, the fields' marker on the divider (`draw_marker(..., x = 56)`, level 4 over the divider's 1). No slot text reaches x 127, and nothing in the left column crosses the divider.
- A redraw measures no text it measured before: value, seconds and voices widths are memoized, field labels and slot names are cut once per text and width. The width and label caches hold at most `cache_limit` (256) entries each and are cleared past it (a turn through a long file's start makes a new text at every detent).
- The `start` label always fits whole: the value's resolution follows `start_bands`, each band's widest text fitting beside `start` under a width at least as wide as norns' font (the test takes the stub's width per character, or the font's where wider: `m` is 6 px).
- The page reads the waveform, heads and bookmarks only through `S.lib.waveforms.bins`, `S.lib.playheads` (`position`, `spread`, `record_head`, `cell_of`, `has_audio`, `moving`) and `S.lib.positions` (`bookmark`, `last_recalled`, `recall_bookmark`); it never reads a peaks file and sends no engine command of its own. `draw()` never asks for a redraw: `animates()` (`S.lib.playheads.moving(cursor slot)`) moves the heads at the frame rate.
- Voices' heads, their spreads and the bookmark ticks are drawn only on a slot that reports audio (`S.lib.playheads.has_audio`, the check the grid's position rows read, so the two never disagree), and `animates()` is true only while a head or the record head is drawn (`moving`): an empty slot and a replace take show and animate nothing (#433). It is false while the file selector is open, whatever moves under it (#435).
- A file name is drawn through `S.lib.ui_text.printable` (accented letters plainly, any other character norns' font lacks as `?`) and cut on the text drawn (#551): the slot rows here, the hint row in `draw_hints`. The slot keeps its real name and path for loading and saving.
- The `bm` field recalls through `S.lib.positions.recall_bookmark` only when the shown bookmark changes, so turning past 1 or 4 never restarts the scan again. It shows `-` until the selected voice recalls a bookmark, so the first detent either way lands on bookmark 1, and ALT+E3 recalls the bookmark it shows again (1 from `-`), with no jump to a neighbor first (#431). Each recall goes through `S.lib.quantize.schedule("bookmark<v>", ...)` (3.4, label `v<v> bm <n>`): under `quantize_actions` it waits for the beat or bar, the field keeps showing what plays, and while it waits the next detent (and ALT+E3) steps from the bookmark that waits, kept per voice in the field's own table, so a quick turn of three detents lands three bookmarks on, not one. The `start` field moves the start only through `S.lib.buffers.set_start` (it clamps, does nothing while the slot records, and reloads once E3 rests).

## Owns

- `lib/pages/buffer.lua` (`S.lib.pages_buffer`): the BUFFER record (`draw`, `hints`, `enc`, `alt_enc`, `key`, `key_release`, `alt_key`, `alt_key_release`, `enter`, `leave`, `animates`, `arc_button`, `layout_states`), `redraw_buffer`; `S.BUFFER_PAGE` (layout, levels, `hold_seconds`, the start steps and the file selector state), `S.buffer_page` (the cursors), the file selector (`close_buffer_file_selector`, `release_superseded_file_selector`, global), `buffer_page_flash` (global, on the shared "hints" flash); `S.lib.pages_buffer.INPUT_METER`, `input_meter_segments(amp)`, `slot_seconds_text(seconds)` and the meter state `S.lib.pages_buffer.meter` (`amps`, `peak`, `peak_at`, `shown`, `polls`); cleanup step `input_meter`.
- The buffers themselves (`S.buffers`, `load_buffer`, `clear_buffer`, `save_buffer`, `save_buffer_loop`, `buffer_load_failed`, `S.lib.buffers.set_start`, ...) are `lib/buffers.lua`'s (`docs/notes/lua/buffers.md`); recording (`record_buffer`, `S.lib.record.state`) is `lib/record.lua`'s; random files and filling (`S.lib.files`) are `lib/files.lua`'s; peaks, playheads and positions are `lib/waveforms.lua`'s, `lib/playheads.lua`'s and `lib/positions.lua`'s.
- Its unit tests: `test/unit/pages_buffer_test.lua`. Its rings: `lib/arc/buffer.lua` (`docs/notes/lua/arc-pages.md`).

## Cursors

`S.buffer_page = {slot = 1, field = 1}`: `slot` 1..`NUM_BUFFERS` (E2), `field` 1..11 (ALT+E2, through `ui_field_list.move`). Both clamp at their ends and are put back in range before use. They persist across page changes; the slot cursor does not follow the selected voice.

The fields (`BUFFER_FIELDS`, each `{name, label, value(), param_id() or enc(d), active()?}`; E3 is `enc_param_delta(3, param_id(), d)`, so ALT+E3 is fine adjustment, unless the field has its own `enc`):

| # | Label | Shows | E3 |
|---|---|---|---|
| 1 | `v<sel>` | `voice_source_label`: `synth`, `buf 2`, `input` | `v<sel>_source` |
| 2 | `rec` | `in`, `pre`, `post`, `v1`-`v7` (from `RECORD_SOURCES`) | `record_source` |
| 3 | `dur` / `len` (sync on) | `8.0s`; `16b`, or `<n>b max` when the beats need more than a slot (`n` = whole beats a slot holds at the tempo), `<1b max` when not one beat fits (below 3.75 BPM on a 16 s slot). Both from `S.lib.record.take_length()`, which `record_buffer` sends: a capped take is those `n` beats long (#321) | `record_duration` / `record_beats` |
| 4 | `lvl` | `1.00` | `record_level` |
| 5 | `fb` | `50%` (`99.5%` after a fine step) | `record_feedback` |
| 6 | `loop` | `off`, `on` | `record_loop` |
| 7 | `thr` | `off`, `-24dB` (the option without its space) | `record_threshold` |
| 8 | `sync` | `off`, `beat`, `bar` | `record_sync` |
| 9 | `bm` | `2 0.25`: the selected voice's last recalled bookmark and its position, `-` while it has recalled none; dim unless the voice reads a buffer | steps 1..`NUM_BOOKMARKS` and recalls the one it lands on, only when that changes the bookmark shown (from `-` the first detent either way is 1); ALT+E3 recalls the one shown again (1 from `-`), #431 |
| 10 | `start` | the cursor slot's start at the resolution of its band (`start_bands`): `9.05s` below 10 s, `12.1s` from 10 s, `123s` from 100 s, `20:34` from 1000 s, `123m` from 6000 s, `17h` from 60000 s; or `-` when its file fits a slot (no `file_seconds`, or no start to move: `S.lib.buffers.longest_start(file_seconds, sample_rate)` is 0, so a 96 kHz file of 12 s on a 16 s slot, which holds 8 s of it, has a start, #326) | E3 max(`start_min_step` 0.1 s, the band's step), ALT+E3 the band's step (0.01, 0.1, 1, 1, 60, 3600 s), so every detent changes the shown value; the result rounded to its own band's step, through `set_start`; nothing for a file that fits |
| 11 | `fric` | `100%` | `scrub_friction` |

## Layout

`S.BUFFER_PAGE` holds every position, `S.BUFFER_PAGE.levels` every level.
- Divider at x 56, y 10-52 (level 1), drawn first.
- Left column (x 0-54): four field rows at y 16, 24, 32, 40 (`field_first_y`, `field_spacing` 8, `field_visible` 4), one row above the cursor kept in view (`first_visible`): `>` at x 0 on the cursor's row, the value right-aligned at x 54, the label at x 5 cut (`fit_text`) to end `label_gap` (0) px before the value: the layout estimate is at least as wide as the font everywhere but `m`, so on norns a gap remains. A wide value can still cut its label; `len` beside its widest value (`32b max`, 34 px) and `start` (above) never are. The cursor's row at level 15, the others 4; `bm` while the selected voice reads no buffer 4 under the cursor, 2 elsewhere. The fields' scroll marker on the divider at level 4 (`draw_marker` with `x` 56, track y 10-41).
- Input meter on y 49: `in` at x 5, then eight 3x5 px filled segments from x 17, 1 px apart (x 17-48): lit segments at level 10, the held peak segment (when above the level) at 15, the rest at 1.
- Waveform of the cursor slot: `S.lib.waveforms.bins(slot, 64)`, one column per peak at x 60-123 (`wave_x`, `wave_columns`), column k a vertical line of half-height `round(peak × 8)` around y 19 (`wave_center_y`, `wave_half_height`), inside y 11-27. Level 8 inside the selected voice's loop (the column's middle in `[loop_start, loop_start + loop_length)`) and 3 outside when that voice reads the slot, 6 when it does not; a stroke per run of one level. No peaks (an empty slot, no valid peaks file): a flat line y 19, x 60-123, level 1.
- Heads, after it, at `wave_x - 1 + cell_of(fraction, 64)`, on a slot that reports audio (`has_audio`, #433): each running voice reading the slot (`S.lib.playheads.position`) a line y 11-27, the selected voice's at 15 (drawn last), others 11 (above the loop's waveform at 8), its spread (`S.lib.playheads.spread`, centered on the head, as the engine's draw of ±spread/2) a line on y 28 at level 4; the record head (`S.lib.playheads.record_head`, while the slot records playably) 1x1 px rects every other pixel from y 11 to 27 at level 12.
- Bookmarks of the selected voice when it reads the slot and the slot reports audio: 1x2 px filled rects at y 29-30, level 6, the last recalled (`S.lib.positions.last_recalled`) 15.
- Slots: `S.lib.ui_field_list.draw` with three visible rows from y 37, 7 px apart (y 37, 44, 51), one row above the cursor kept in view, the scroll marker at x 127 (y 31-52). Each row:
  - slot number at x 59;
  - name at x 65: the file name without extension, through `S.lib.ui_text.printable` (#551), cut with `fit_text`, or `-` when the slot has no name, which what it holds says, never its name (a file may be called `empty`, #436): no `path` and not `loaded` (a dub into an empty slot is `take <n>` once it is loaded, #400);
  - right-aligned at x 124: while recording, `ARM` (armed: `S.lib.record.state(slot).phase == "armed"`), `REC` (a replace take, or a recording slot with no state), `DUB` (playable, one-shot) or `LOOP` (playable, loop); else `...` (`PAGE.checking_text`) while the engine checks a long file (`checking_from`), else the length; none for a free slot (`S.lib.buffers.is_free(slot)`: status `"empty"` or `"missing"`, the answer the fill and the grid share, #247; a named load the engine has not reported yet, `"unsettled"`, shows its name and `0.0s`). `slot_seconds_text`: below `minute_from` (59.95 s) `%.1fs` (`16.5s`), from there on `m:ss` (`1:05`, `4:59`, `5:00`);
  - names in other rows end 3 px before the widest length the tier shows (`widest_seconds_width`); on the cursor row the voices reading the slot (`v2 v6`) are right-aligned 3 px before that row's own length or state, at most 25 px (`voices_max_width`) and never into the name's first 12 px (`name_min_width`), dropping whole voices from the end with `+` (`v2+`).
- Row level: the cursor row 15, a loaded or recording slot 6, others 2.
- The bookmark ticks (y 29-30) leave y 31 clear above the first slot row's glyphs (y 32-36); the spread stays on y 28.
- `layout_states`: slot 1 and slot 8 (long names, voices on the cursor slot), long names with every voice on one slot, every slot recording, each field on the cursor at a wide value (`field <name>`), `len 16b max` (40 beats at 120 BPM: `32b max`), the saving, saving loop, saved, saved loop, save failed, busy, empty, load failed, random file, filled and no files flashes (the last through `S.lib.files.random_into` on an empty folder whose path below the audio folder is too long for the row: `no files in another_one/`), the meter with a held peak, every recording state on the cursor slot (`armed`, `take recording`, `take finishing`, `dub recording`, `loop recording`), seven heads on one slot (a peaks file written as the engine writes it, every voice running, voice 1's loop a part of the slot), the record head (3 s into an 8 s playable recording), a long file's start on standard (`9.05s`) and an hour-long file's on a 300 s tier (`20:35`), and three as on a 300 s tier (`as_300_s_tier` sets `S.performance` and gives the duration param a copy of its spec with the 300 s range, never changing the spec it was built with): eight slots of 4:59 with the duration at `300.0s`, a recording beside a 1:05 take read by every voice, and three long files still being checked (`...`).

## Controls

- E2 moves the slot cursor; ALT+E2 the field cursor (`alt_enc` returns true for E2 only). E3 edits the field (table above); ALT+E3 is fine adjustment.
- K3 press and the arc button (`arc_button`): `record_buffer(slot)`: records, stops early while recording (keeping what was captured), cancels while armed; does nothing while `finishing`.
- K2 release: before 0.5 s the file selector for the cursor slot (below); held 0.5 s or more, `S.lib.files.random_into(slot)` (it flashes `buf <n>: <name>` or `no files in <folder>`, the folder as the player knows it: `docs/notes/lua/files.md`, #432). K2's press only notes its time; K3 while K2 is held just records.
- ALT+K2 release: before 0.5 s `clear_buffer(slot)`; after, `S.lib.files.fill_empty()` (it flashes `filled <k> slots`, `filled 1 slot`, or `no files in <folder>`).
- ALT+K3 release: before 0.5 s saves the whole slot (`save_buffer`), after it its loop region (`save_buffer_loop`, trim), shown by `buffer_page_flash(text)`:
  - `buf <n> busy` (and no save) while the slot is `recording` or `finishing`;
  - else `saving buf <n>` (`saving buf <n> loop`) when the save was sent (the slot reports audio, `seconds > 0`);
  - else `buf <n> empty`.
- `buffer_save_result` (`lib/buffers.lua`) flashes `saved buf <n>` (`saved buf <n> loop`) or `buf <n> save failed` when the engine reports how the slot's newest save ended; a report of an older save flashes nothing.
- `buffer_load_failed` flashes `buf <n> load failed`; a playable recording into a slot at another rate flashes `buf <n>: replaced (rate)` (`lib/record.lua`).
- Hints: while a hold key is down (see Held keys below) `buffer_hints` returns its release text instead; else `K2:ld/rnd K3:rec` (`K3:stop` while the cursor slot records or is armed, `K3:...` while it is `finishing`); with ALT `K2:clr/fill K3:sv/trim`.
- `animates()`: false while the file selector is open (#435); else `held_hint() ~= nil` (a hold key is down, so the hint changes at 0.5 s with no clock of the page's own), or `S.lib.playheads.moving(cursor slot)`, true while a running voice reads the slot's audio or it records playably (#433), so `draw_frame` redraws the screen every frame then.

The flash: `buffer_page_flash(text)` = `S.lib.ui_flash.start("hints", text, 1.5, UI_PAGES.index.BUFFER)`. `redraw()` draws it on BUFFER's hint row instead of the key hints while it shows (a failed load reported while another page is up shows if BUFFER comes up within 1.5 s); its clock asks for a redraw when it ends; a new flash cancels the previous clock; cleanup step 140 cancels it (`docs/notes/lua/ui/header-and-flashes.md`).

## Held keys

A key counts as down for the hint (`held_hint()`) while `S.key_press_page[n]` is BUFFER's index and `pressed_at[n]` is set; `S.key_press_alt[n]` picks the plain or ALT texts. Plain K3 records at the press and has no hold. A "hints" flash covers the hold hint (`redraw()` draws the flash first).

| State | `pressed_at[n]` | `S.key_press_page[n]` | `S.key_press_alt[n]` | Hint row |
|-------|-----------------|-----------------------|----------------------|----------|
| up | nil | nil | nil | the page's own hints |
| down short (under 0.5 s) | time | BUFFER | nil (K2) or true (ALT+K2, ALT+K3) | `K2 up: load`, `K2 up: clear` or `K3 up: save` |
| down long (0.5 s or more) | time | BUFFER | as above | `K2 up: random`, `K2 up: fill` or `K3 up: save loop` |
| taken (menu, selector or page change) | may stay set, harmless | nil | nil | the page's own hints |

Transitions: the press (`buffer_key`, `buffer_alt_key`) notes `pressed_at`, the release (`held_long`) clears it, and `forget_held_keys` or a page change clears `S.key_press_page`, which ends the hint even if `pressed_at` is stale (`forget_held_keys` clears `S.key_press_page` and `S.key_press_alt` both; a page change clears both too, by #234). The hint is gated on `S.key_press_page[n]`, so a stale `pressed_at[n]` is harmless.

## Input meter

- `S.lib.pages_buffer.INPUT_METER = {poll_seconds = 0.05, segments = 8, floor_db = -48, db_per_segment = 6, peak_hold_seconds = 1}`.
- `input_meter_segments(amp)` = `clamp(ceil((20 * log10(amp) - floor_db) / db_per_segment), 0, 8)`; 0 for `amp <= 0`, NaN or a non-number. So 0.5 (-6 dB) lights 7, 1 (0 dB) and above 8, 0.001 (-60 dB) none.
- `enter` resets the meter (levels 0, no peak), then for each poll `poll.set(name, callback)`, sets its `time` to `poll_seconds` and starts it. `leave` and cleanup stop them.
- Each value sets that channel's amplitude; the level is the louder channel's segments. A value that changes the drawn level or peak asks for a screen redraw (`S.lib.ui_frame.request_screen_redraw()`, #434), unless the file selector is open (#435). When the level reaches or passes the held peak (or the hold has run out), the peak becomes the level and `peak_at` the time. The draw shows the level, plus the peak segment while `util.time() - peak_at < peak_hold_seconds` and the peak is above the level.

## The file selector (K2 release)

- K2 released before `hold_seconds` calls `fileselect.enter(_path.audio, cb)`. `cb` calls `S.lib.files.note_chosen(path)` (its folder becomes the next random folder) and `load_buffer(slot, path)` unless the path is `"cancel"`, then clears `S.BUFFER_PAGE.file_selector_open` and asks for a redraw (the next frame draws the page).
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
