## Must not break

- Each part of the UI core has its own notes file under docs/notes/lua/ui/ (listed below), each opening with its own "Must not break" list. Read the one for the part you change.
- The lock is called lock everywhere (`[L]`, hints, `S.locked`, `toggle_lock`).
- The zones editor (`lib/ui/zones.lua`, 3.5) edits only params (`mpe_lower_members`, `mpe_upper_members`, `mpe_bend_range`, `v<i>_zone`, `v<i>_zone_low`, `v<i>_zone_high`), every E3 through `enc_param_delta`; it keeps no value of its own. It shows over the page only through `S.lib.ui_modal` (`push` at `open`, `pop` at `close`).
- Its learn waits exactly while its timeout clock runs (`S.zones_learn_clock`) and only while the editor is open; it ends at the second note, K2 (which closes the editor), a new learn, `ZONES_EDITOR.learn_seconds` (10 s), a MIDI reset (the tap's owner told, #900) and the cleanup step (`CLEANUP_ORDER.zones_learn`, 117), and every end clears the note tap. Its clock is the clock helper's (`S.lib.clocks`, #870, `docs/notes/lua/clocks.md`; `S.zones_learn_clock` is its handle's id), so its end never cancels it once its resume may be posted (#626): within the helper's margin (`CLOCKS.sleep_margin`, 0.1 s) of the wake it is retired, as MOD's learn's (`docs/notes/lua/macros.md`). The `zones editor` invariant holds it: a waiting learn has its clock pending (its coroutine alive), the note tap set and the editor open; the open editor's own owner is the modal one, or lies beneath SEQ's step editor (the one owner a grid can push over it); the closed editor's owner never is.
- The note tap is the MIDI module's (`S.lib.midi_in.set_note_tap(owner, fn)` and `clear_note_tap(owner)`, package 2b's, owned since 3.9's #900: while a tap is set, every MIDI note on goes to `fn(note)` first and is consumed when `fn` returns true). The editor sets `M.note` as the tap under `ZONES_EDITOR.tap_owner` when a learn starts (a tap another owner holds refuses it, and no learn waits) and clears its own when it ends, and calls them at no other time; a test stands in a double for them, and a layout state a do-nothing function for the set. `M.note(nil)` is the MIDI module telling the owner it cleared the tap (`reset_midi_input`, cleanup): a waiting learn ends. While SEQ's step editor covers the editor (`S.lib.ui_modal.top()` is not its owner) `M.note` takes no note, which plays as with no tap; uncovered, the learn takes notes again.
- The UI walk (`test/unit/ui_walk_test.lua`, below) stays green: a change to how a key's press is noted, forgotten, released or shown must leave no press mark on a key that is up, after every step and at its end.
- Note names are norns' own (`musicutil.note_num_to_name(note, true)`, 60 is `C3`: 0 is `C-2`, 127 is `G8`; plan ruling 28), so the editor names notes as every other norns script does. `C#-2` and `learn` are a column's widest texts.

## Machines

The zones editor has no topic file, so its entry is in this index, where its notes are (The zones editor, below); every other part's machines are in its own file under docs/notes/lua/ui/.

### zones editor
- **State:** `editor = {open, row, column}`, `learning` (`{voice, which, first}` or nil), `learn_clock.handle` (the learn's timeout clock, a clock helper's handle, `docs/notes/lua/clocks.md`) and `tap_set` (local to `lib/ui/zones.lua`), with `S.zones_learn_clock`, that handle's id; read through `S.lib.ui_zones.is_open()` and `learning()`. Closed, open, open with a learn waiting for its low note or its high.
- **Invariant:** `zones editor`: a learn waits exactly while its clock is pending (its coroutine alive, never a retired one) and the note tap is set, and only while the editor is open; the open editor's owner is the modal one (or lies beneath SEQ's step editor), the closed editor's never; the cursor is on a row and a column.
- **Test:** `test/unit/ui_zones_test.lua`: "the editor's invariant holds its own owner and a waiting learn's clock" (and "a learn ends after 10 s, at K2 and at cleanup, and the note tap is cleared", "the zones learn clock stopped as its wake is posted: no clock error, and nothing more happens", "the zones learn's tap is not cleared by the scale editor", "a MIDI reset tells the zones learn, which ends", "a note while the step editor covers the zones editor is not learned").

No test runs this table: it is one of the design's modal owners (its section 5, a table and no test). It lists the events that open or close the editor or start or end a learn; every other key or turn (E2's row, E3's value, K3's column on a voice row, ALT+K3 off a voice row) is the editor's own editing and leaves its state as it was, and a cleanup of a closed editor does nothing. Its opens and closes are a row of the owners' table (`docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner). A learn's end stops its clock through the helper (`S.lib.clocks.stop`: retired, never canceled, once its wake may be posted, #626, #870).

| State | Event | Next | Effect |
|---|---|---|---|
| closed | K3 on SETUP's `mpe & zones` row | open | pushed |
| open | ALT+K3 on a voice row | learning low | the note tap set, the timeout clock started, `learn v<i> low` in the header |
| open | K2 (no ALT) | closed | popped |
| learning low | a note | learning high | the voice's lowest note set; the note taken |
| learning high | a note | open | the highest set (the two swapped when the second is lower); the learn ends |
| learning low | `ZONES_EDITOR.learn_seconds` (10 s) | open | the learn ends, the lowest unchanged |
| learning high | `ZONES_EDITOR.learn_seconds` | open | the learn ends, the lowest kept |
| learning low | ALT+K3 (a new learn) | learning low | the old learn ended, the new one starts |
| learning high | ALT+K3 | learning low | as above |
| learning low | K2 | closed | the learn ends, popped |
| learning high | K2 | closed | the learn ends, popped |
| open | cleanup (step 117) | open | nothing waits; the owner stays on the stack (#899) |
| learning low | cleanup | open | the learn ends, its clock canceled, the tap cleared; the editor stays open (#899) |
| learning high | cleanup | open | as above |

## Files

The UI core's notes, one file per part:
- [pages-and-dispatch](ui/pages-and-dispatch.md): the page records, `UI_PAGES`, how `enc`, `key` and `redraw()` dispatch, adding a page.
- [header-and-flashes](ui/header-and-flashes.md): `draw_header()`, its positions and indicators, the header and hints flashes.
- [field-list-and-cursors](ui/field-list-and-cursors.md): `S.cursors`, the row cursors' anchors, `voice_page_rows` and its registered rows, the ring groups, `S.lib.ui_field_list`.
- [alt-and-keys](ui/alt-and-keys.md): ALT (K1 held), `alt_action`, key releases and keys held into the norns menu.
- [detents-and-fine](ui/detents-and-fine.md): `delta_with_detent`, `enc_param_delta`, fine adjustment and center detents.
- [redraws](ui/redraws.md): `request_redraw()`, the frame clock, draw errors and who asks for a redraw.
- [layout-and-renders](ui/layout-and-renders.md): the layout tests and the page renders.
- [slice-editor](ui/slice-editor.md): the slice editor (3.7), BUFFER's modal view of a buffer's slices and its file's settings.
- [scale-editor](ui/scale-editor.md): the scale and tuning editor (3.8), SETUP's modal view of the root, the scale, its classes and the tuning.

## Owns

- `lib/ui/frame.lua` (`S.lib.ui_frame`): `S.ui_page`, `S.started` (set by init's first start step, `START_ORDER.started`; until then `redraw`, `key` and `enc` do nothing, #426); `request_redraw`, `S.lib.ui_frame.request_screen_redraw` (the screen alone, #434), `draw_frame`, `draw_frame_part`, `draw_error_report`, `S.lib.ui_frame.contained_call` (the one error containment of every clock step, `docs/notes/lua/ui/redraws.md`) and the frame clock (`start_frame_clock`, `stop_frame_clock`; cleanup step 60). The runtime fields (`screen_dirty`, `arc_dirty`, `frame_clock`, `draw_errors`) are on the shared `S.constants.UI_PAGES` table.
- `lib/ui/params.lua` (`S.lib.ui_params`): `set_binary_param`, `param_range`, `param_spans_zero`, `param_default`, `param_value_fraction`, `param_fraction`.
- `lib/ui/header.lua` (`S.lib.ui_header`): `draw_header`, `draw_hints`, `S.lib.ui_header.hint_fits(text)` (whether the hint row draws a text whole, #432). Its positions are `S.constants.HEADER` (`lib/constants.lua`).
- `lib/ui/flash.lua` (`S.lib.ui_flash`): the flashes, `S.lib.ui_flash.start`, `.text`, `.cancel_all`, `.slots`, `.add_notice` (3.4's standing notices), and `header_flash` (global); cleanup step 140.
- `lib/ui/text.lua` (`S.lib.ui_text`): `S.lib.ui_text.fit_text`, which cuts a whole UTF-8 character at a time and stops when a pass cuts nothing, so a text it cannot shorten (only continuation bytes) comes back as it is instead of looping (#514); `S.lib.ui_text.printable(text)`, a text as norns' font can draw it (#551): norns.ttf has glyphs for printable ASCII and next to nothing else, so printable ASCII stays, the letters of Latin-1 and Latin Extended-A become plain ones (`café` is `cafe`, `ß` is `ss`, `œ` is `oe`), and any other character, control character or byte that is not UTF-8 becomes one `?`. A file name is drawn through it wherever it shows (BUFFER's slot rows, the hint row) and measured as drawn, and loaded and saved by its real name.
- `lib/ui/field_list.lua` (`S.lib.ui_field_list`): stateless helpers for a page that is a list of fields with one cursor (`docs/notes/lua/ui/field-list-and-cursors.md`, Field lists). FX, VOICE, BUFFER and SETUP use it.
- `lib/ui/keys.lua` (`S.lib.ui_keys`): `S.key_press_page`, `S.alt_held`, `S.key_press_alt`, `forget_held_keys` (global); `set_ui_page` (runs the records' `leave`/`enter` and forgets carried arc ticks), `select_voice_by` (fields of `S.lib.ui_keys`).
- `lib/ui/alt.lua` (`S.lib.ui_alt`): `alt_action` (global); `set`, `run_release_hooks` and the randomizing pages' shared ALT+K2, `k2_up`, `k2_held`, `k2_hint`, and `join` (the hint row's parts, a nil left out) (fields of `S.lib.ui_alt`). See `docs/notes/lua/ui/alt-and-keys.md`.
- `lib/ui/detent.lua` (`S.lib.ui_detent`): `delta_with_detent`, `enc_param_delta` (global); `as_turn` and `run_touch_hooks` (fields); the holds at 0 (local). See `docs/notes/lua/ui/detents-and-fine.md`.
- `lib/ui/modal.lua` (`S.lib.ui_modal`, 3.4): the modal screen owner's stack, `push`, `pop`, `top` (fields), and the `modal owner` invariant. See `docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner.
- `lib/ui/zones.lua` (`S.lib.ui_zones`, 3.5): the MPE and zones editor (below): `open`, `close`, `is_open`, `learn`, `cancel_learn`, `learning`, `note`, `ZONES_EDITOR` (fields), `S.zones_learn_clock`, the header notice `learn v<i> low|high`, cleanup step 117 and the `zones editor` invariant. Its unit tests: `test/unit/ui_zones_test.lua`.
- `lib/ui/slice_editor.lua` (`S.lib.ui_slice_editor`, 3.7): the slice editor (`docs/notes/lua/ui/slice-editor.md`).
- `lib/ui/scale_editor.lua` (`S.lib.ui_scale_editor`, 3.8): the scale and tuning editor (`docs/notes/lua/ui/scale-editor.md`).
- `lib/ui/menu_watch.lua` (`S.lib.ui_menu_watch`): the `_menu.set_mode` wrapper (`watch_menu_opening`, `unwatch_menu_opening`, `forget_keys_held_through_menu`; cleanup step 20).
- `lib/ui/name_entry.lua` (`S.lib.ui_name_entry`, #849): the one name entry SCENES and the voice picker open norns' textentry through (`docs/notes/lua/ui/name-entry.md`).
- `lib/ui/voice_rows.lua` (`S.lib.ui_voice_rows`): `voice_page_rows`, `voice_page_group` (global); `first_field_row`, `GROUP_SIZE` (fields).
- `lib/ui/cursors.lua` (`S.lib.ui_cursors`): `S.cursors` and the row cursors' anchors; `move`, `sync`, `place`, `clamp_all` (fields).
- The page renders: `test/render_pages.lua` and `test/render_pages.py` (`docs/notes/lua/ui/layout-and-renders.md`).

Each page has its own notes file: `docs/notes/lua/pages/main.md`, `voice.md`, `seq.md`, `fx.md`, `lfo.md`, `buffer.md`, `scenes.md`, `setup.md`. The arc's rings for each page are in `docs/notes/lua/arc-pages.md`, the arc's dispatch in `docs/notes/lua/arc-core.md`.

## The zones editor

`lib/ui/zones.lua` (`S.lib.ui_zones`, 3.5 design §9.3): a modal owner (`docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner) that SETUP's `mpe & zones` row opens with K3 (`docs/notes/lua/pages/setup.md`). It takes the screen's body, the hints, E2, E3, K2 and K3 over whatever page is up; E1 does nothing and the arc's rings stay off while it is open.
- Rows (`ZONES_EDITOR`: six in view from y 18, 7 px apart, the scroll marker at x 127, as SETUP's): `lower members` (`mpe_lower_members`), `upper members` (`mpe_upper_members`), `bend range` (`mpe_bend_range`, `48 st`), each with its value right-aligned at x 124; then `v1` to `v7`, each with three columns: the zone (`v<i>_zone`: `off`, `lower`, `upper`) from x 20, the lowest note right-aligned at x 94 and the highest at x 124 (`v<i>_zone_low`, `v<i>_zone_high`, named as norns does: `C-2` to `G8`). The defaults read `v1 lower C-2 G8`, `v2 upper C-2 G8` and `off` for the rest.
- Levels: a count row under the cursor at 15, the other rows at 4; on the cursor's voice row the column under the cursor at 15 and the rest of the row at 8. While a learn waits, the column it waits for reads `learn` (15).
- E2 the row (clamped at both ends); K3 on a voice row the next column (zone, low, high, then the zone again; kept across rows and while closed); E3 the value under the cursor (`enc_param_delta`: whole steps, so ALT+E3 turns as E3 does). The zone params' own actions keep a range's lowest at or below its highest (`lib/mpe.lua`). K2 closes (ALT+K2 does nothing); a second `open` or a `close` of a closed editor does nothing.
- ALT+K3 on a voice row: `M.learn(voice)` (refused with the editor closed or for a voice outside 1..`NUM_VOICES`). The next note on (`M.note(note)`, a whole number 0-127, else not taken) sets the voice's lowest note, the one after its highest, swapped when the second is the lower; both are taken (`true`), so neither plays. The lowest is set before the highest, so neither param's action moves the other. A first note above the highest raises the highest with it (`lib/mpe.lua`), and a learn that ends after one note keeps that lowest. While it waits the header says `learn v<i> low` or `learn v<i> high` on every page (a standing notice, `S.lib.ui_flash.add_notice`; at most 56 px, inside the flash's 74).
- `M.learning()`: the voice and `"low"` or `"high"`, or nil.
- Hints: `K2:back E3:value` on a count row, `K2:back K3:column E3:value` on a voice row; with ALT held `E2:row E3:value`, and `E2:row K3:learn E3:value` on a voice row (E3 turns with ALT as without, so the ALT hint names it, #844).
- Its layout states are SETUP's (`docs/notes/lua/pages/setup.md`): opened, v7's high at its widest, a learn waiting for v7's low and for its high.

`test/unit/ui_zones_test.lua`: the rows' defaults and every edit (the counts, the bend range, each column, K3's wrap, E2's ends, the levels); learn (the notice, the column, the two notes in either order, a first note above the highest, notes it refuses, ALT+K3 off a voice row, a closed editor); the ends (10 s, K2, cleanup) and the tap cleared at each; #626's retired clock, and the helper's retire as its wake is posted (#870); K2 and E1 while open; the hints; K3 on a count row changing nothing; every row, column and ALT state at the widest values, and the learn states, inside the layout; the invariant (another owner in its owner's place, the step editor over it, a learn's clock ended under it).

## The UI walk

`test/unit/ui_walk_test.lua` (3.9's package 3a, its design's section 6): an `h.walk` of four seeds and 400 steps over the screen's controls as norns routes them. While the norns menu is open its keys and encoders are the menu's (nothing reaches the script); in play mode they go to `_menu.key` and `norns.encoders.callback`, so a name entry's own key takes them once it is open; while BUFFER's file selector is open they reach the selector, whose `fs.enter` put its own `key` and `enc` in the globals (the stub's does too, #985), never the script; the walk cancels the selector only while it has the keys (not under the open menu). Its ops: K1, K2 and K3 each down and up (a key goes up only if it is down); E1 to E3 by ±1 to ±3; the menu opened and closed; each owner opened from its page as a player does (the keys it needs let go, an owner up closed with K2 first, E1 to the page, the cursor on the owner's row, K3: the zones editor, the scale editor and the factory list on SETUP, the voice picker on VOICE, the slice editor on BUFFER's slices field of slot 1, which holds audio, IO's detail list on the voice section's `midi` row) and closed with K2; SEQ's step editor pushed by a grid step key held 0.35 s on a 128h's patterns page (over whatever is up) and popped by that key's release; SCENES' name entry opened by ALT+K2, finished (`context.textentry.finish`) and canceled (K2's release); BUFFER's file selector opened by K2's quick release and canceled; and `context.clock.run_for` of 0.05 to 0.6 s.

After every op it checks every invariant and its own rules: a key that is physically up has no press mark anywhere (K1 up and `S.alt_held` false; K2 or K3 up and no `S.key_press_page`, `S.key_press_at` or `S.key_press_alt` mark and no owner's press or press time), and a press mark names the page shown (a page change forgets the presses, so a key held across one and back never releases on its page, #234). `reached`: each owner opened (the one its row opens, checked by its own `is_open`; IO's detail list by its invariant's record), a release made under a cover (the grid's step editor on top, pushed over what the press went to: an owner still beneath it, or the bare page; a release on an owner the editor's pop uncovered is not one), a release the menu took, the name entry finished and canceled, the selector canceled, a key or turn the open selector recorded (`context.fileselect.inputs`).

**The end check** (the controller's ruling on 3a): every key let go, the menu closed, the name entry canceled, the selector canceled, the grid's step key let go and every owner closed with K2 (an owner K2 leaves open after twelve presses is a failure); then what animates by right, not by a key, is quieted, with no page change (a page change forgets the very marks the check looks for): the patterns stopped, every LFO off, every recording stopped, every voice playing a buffer stopped (BUFFER's and the slice editor's playheads move), then 3 s pass, so flashes, the scenes prompt and the detent holds lapse. Then four assertions:
1. the press state is a fresh script's: no `S.key_press_page`, `S.key_press_at` or `S.key_press_alt` mark, ALT not held, no press in the modal stack's records and `held_seconds` nil for every owner the walk opened;
2. no owner the walk opened animates, and no page does (each page is shown and drawn once first: the frame that takes a lapsed scenes prompt away asks SCENES' `animates` once more, by design; MOD is first taken back to its list with K2, since its views animate);
3. each page's drawn hint row is its own `hints(false)` (cut as `draw_hints` cuts it): no flash or owner stays on it;
4. those hints are the same with the press marks cleared: no hint names a key that is up.

The page shown at the end is checked before any page change; every other page is then shown through `S.lib.ui_keys.set_ui_page` and checked.

**Why it is not a literal comparison with a fresh script.** The design's end check says each hint equals a fresh script's. Each page's hints read state the walk changes on purpose (the cursors E2 moves, the values E3 turns, the voices, patterns, locks, scenes, recordings, LFOs and views its keys change), so a fresh script's hints would differ on nearly every page with no press lost; a literal comparison would need the walk's whole state copied across, or a walk that changes nothing. The end check and the plan's Review Focus 2 are about a key whose release was lost ("nothing stays held, no hint names a key that is up, nothing animates"), so the four assertions compare the walked script with itself with its press state made a fresh script's. A test in the file ("the ui walk's end check names ...") is their control, and another holds the cover count (a page's press released under the pushed editor counts; a release after its pop does not): a lost ALT+K2 press left on MAIN, a hints flash that never lapses and an owner K2 does not close each fail the check they are for.

