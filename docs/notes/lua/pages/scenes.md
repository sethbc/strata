## Must not break

- The hints name only keys that act (#419, #420): an empty slot reads `empty  ALT+K3:save` (its recall does nothing but flash `S<n> empty`, `S<n> <name> empty` for a named slot, on the header, from `recall_scene` itself, so a grid key shows it too, and so does any other caller on an empty slot, MIDI included; the scene sequencer skips empty slots before it calls), ALT on a slot (empty or not) `K2:name K3:save`, any field (ALT or not) `E2:move E3:edit`.
- The page file sets every record field but the arc fields; SCENES' rings are `lib/arc/scenes.lua`'s (`docs/notes/lua/arc-pages.md`).
- The overwrite prompt is the page's own state, never a flash (#255): the page never starts or ends a `"hints"` flash. The confirmation is `S.scenes_page = {armed_slot, armed_until}`, and it is armed while `armed_slot` is the cursor's slot and `util.time() < armed_until` (2 s after the arming press). While armed, `hints` returns the prompt with or without ALT, so a flash scoped to another page (BUFFER's load reports) cannot hide it. The prompt names the keys that answer it: `K3 again: overwrite S<n>` with ALT held, `ALT+K3: overwrite S<n>` with ALT up (a plain K3 then recalls the slot, as always).
- A second ALT+K3 saves only while armed and no flash covers the hint row (`S.lib.ui_flash.text("hints") == nil`). Under a covering flash (a hints flash showing on SCENES: one with no page, or one scoped to SCENES) the press only arms again: never save without the prompt on screen.
- `draw` and `hints` write no state of `S` and never call `S.lib.ui_flash` or `request_redraw()` (the draw keeps each slot's last name cut in a local, as the hint row does). The prompt lapses through the record's `animates` (the frame clock draws the page every frame while it returns true): false when nothing is armed, true while armed, and once the arming has lapsed (its time passed, or the cursor left the slot by a route other than `move_cursor`) it disarms and returns true once more, for the frame that takes the prompt off the hint row.
- Every E2, ALT+E2 or ring move of the cursor goes through `S.lib.pages_scenes.move_cursor(slot)` (E2, ALT+E2 and arc ring 1): it puts `S.cursors.scene` on `slot`, clamped to the slots and fields, keeps the bank of a slot it lands on in `S.scenes_page.bank` and, when the cursor moved, disarms (and asks for a redraw). A move by another route (setting `S.cursors.scene` directly) is never armed, since `armed` compares the slot, and the next frame disarms it, except a move away and back within one frame. The cursor must never carry a confirmation to another slot (Review Focus 5).
- The sequencer's field is read, never kept (#893): `seq on [none]` while the sequencer is on and `S.lib.scenes.playable_slots(1, scene_sequence_length)` (the list its pass holds a slot over) is empty, else `seq on` or `seq off`.
- The page shows one bank of `SCENE_BANK_SIZE` (8) slots: the cursor's slot's (`S.lib.scenes.bank_of`), and on a field `S.scenes_page.bank`, the bank shown last. A bank is only a view (design Question 15): nothing else changes with it.
- On a slot, ALT+E2 moves to the slot `SCENE_BANK_SIZE` (8) away, only when that slot exists (1-16), and otherwise does nothing: slot 3 to 11 and back, slot 13 up stays, slot 13 down goes to 5; it never lands on a field. On a field row it moves one stop, as E2.
- The invariant `"scenes prompt"` (`S.register_invariant`): `armed_slot` is nil or a slot in 1..`NUM_SCENES`; `naming` is nil or a slot in 1..`NUM_SCENES`, and set exactly while the page keeps an open entry's callback (`NAME_ENTRY.callback`).
- Recall goes through the global `recall_scene(slot, time)`, looked up when the action runs (tests replace it), inside `S.lib.quantize.schedule("scene", fn, "S" .. slot)` (design §8.9: at once today, at the next beat or bar once the quantizer waits); a save (an empty slot, or the confirmed second ALT+K3) goes through `S.lib.scenes.save(slot)`, which flashes `saved S<n>` in the header (`saved S3 dusk` for a named slot, `S.lib.scenes.label`). The quantizer's label stays `"S" .. slot` without the name, so `S16 at bar` always fits. K2 uses `scene_transition_time` as the key is pressed, K3 and `arc_button` use 0. Keys do nothing while the cursor is on a field.
- The name entry is norns' `textentry`, opened through `S.lib.ui_name_entry` (the voice picker's too, #849; `docs/notes/lua/ui/name-entry.md`), with no modal owner: it takes the global `key`, `enc` and `redraw` itself (from play mode) and cancels on a K2 release, so it opens on ALT+K2's release (`alt_key_release`), never the press (the release would cancel it at once), after `forget_held_keys()` (K1's release goes to the entry, so ALT must not stay held). `S.scenes_page.naming` is the slot while an entry is open and nil otherwise: set as it opens, cleared by the entry's callback, which names the slot through `S.lib.scenes.set_name` (a cancel's nil keeps the old name), or by the menu-close hook below. A callback that is no longer the open entry's does nothing.
- `S.lib.pages_scenes.reconcile_name_entry` (a `menu_close` hook, run after every `set_mode(false)`) runs the entry's `reconcile()`: a menu that took the one textentry over forgets the entry (Strata's key and enc back, `naming` cleared through the entry's `on_close`, play mode routed to them), and a menu that came and went over it hands the entry the screen back (`docs/notes/lua/ui/name-entry.md` says how).

## Machines

### scenes prompt
- **State:** the overwrite confirmation, `S.scenes_page.armed_slot` and `armed_until` against `S.cursors.scene` and `util.time()` (read through the page's local `armed()`): idle (no slot), armed (the cursor's slot, before `armed_until`), lapsed (a slot, but the cursor elsewhere or the time passed); the States section below gives each state's fields. Beside it, `S.scenes_page.naming`, the slot the page's name entry is open for: its states are described in `docs/notes/lua/ui/name-entry.md` (`S.lib.ui_name_entry`), and `naming` follows them (set as it opens, cleared by its callback or its reconcile), so it has no table here.
- **Invariant:** `scenes prompt`: `armed_slot` and `naming` are each nil or a slot in 1..`NUM_SCENES`, and `naming` is set exactly while the page keeps an open entry's callback.
- **Test:** `test/unit/pages_scenes_test.lua`: "scenes prompt: every cell is decided" and its rows (SCENES shown, slot 1 holding a scene with the cursor on it, the clock at 100 s; lapsed is armed with 2.5 s passed); "the scenes prompt invariant holds the name entry's slot to its callback".

Every cell is a row. `the slot emptied, then ALT+K3` empties the cursor's slot as a scenes load does for a slot its file lacks; `a frame` is the frame clock's read of the page's `animates()`.

| State | Event | Next | Effect |
|---|---|---|---|
| idle | ALT+K3 on a populated slot | armed | `armed_slot` the slot, `armed_until` now + 2 s; the hint row asks |
| idle | ALT+K3 under a covering hints flash | armed | as above (nothing to confirm yet) |
| idle | the slot emptied, then ALT+K3 | idle | saved at once |
| idle | move_cursor | idle | the cursor moves |
| idle | the arming time passes | idle | nothing |
| idle | the cursor set directly | idle | nothing |
| idle | a frame | idle | `animates()` false |
| armed | ALT+K3 on a populated slot | idle | `disarm()`, then `S.lib.scenes.save(slot)` |
| armed | the slot emptied, then ALT+K3 | idle | `disarm()`, then saved |
| armed | ALT+K3 under a covering hints flash | armed | armed again for 2 s, nothing saved (never save without the prompt on screen) |
| armed | move_cursor | idle | `disarm()`, nothing saved |
| armed | the arming time passes | lapsed | no function runs |
| armed | the cursor set directly | lapsed | no function runs |
| armed | a frame | armed | `animates()` true |
| lapsed | ALT+K3 on a populated slot | armed | armed for the cursor's slot, nothing saved |
| lapsed | ALT+K3 under a covering hints flash | armed | as above |
| lapsed | the slot emptied, then ALT+K3 | idle | `disarm()`, then saved |
| lapsed | move_cursor | idle | `disarm()` |
| lapsed | the arming time passes | lapsed | nothing |
| lapsed | the cursor set directly | lapsed | nothing |
| lapsed | a frame | idle | `animates()` disarms and returns true once, for the frame that takes the prompt off |

## Owns

- `lib/pages/scenes.lua` (`S.lib.pages_scenes`): the SCENES record with draw, hints, enc, alt_enc, key, alt_key, alt_key_release, `arc_button`, `animates` and `layout_states` (every slot and field as cursor, all populated and every slot named with 12 `W`s, the widest name, sequencer on; `armed` and `armed with ALT`: slot 16 armed through `S.scenes_page`, the second with K1 held, since the renders draw each state with ALT up; `sequencer in bank 2`: the mark on slot 12; `sequencer on with nothing to play`: no scene saved, the cursor on `seq on [none]`, #893; `S16 current beside REC`: the header's widest scene beside `REC`); `move_cursor(slot)` and `reconcile_name_entry()` (fields of `S.lib.pages_scenes`); its menu-close hook. Its tests: `test/unit/pages_scenes_test.lua` (the name entry through `test/stub_textentry.lua`, `docs/notes/test-harness/stubs.md`).
- `S.scenes_page`: `armed_slot` and `armed_until` (the overwrite prompt), `bank` (the bank a field shows) and `naming` (the slot the name entry is open for).
- Its cursor is `S.cursors.scene` over the sixteen slots and the seven `S.constants.SCENES_FIELDS`, stops 1-23 (`lib/ui/cursors.lua`). The scenes themselves, their banks and names are `lib/scenes.lua`'s (`docs/notes/lua/scenes.md`).

## The page

One bank of eight slots in two columns of four (`SCENES_PAGE.column_x` 0 and 64, rows 8 px apart from y 16): the slot's number right-aligned to x + 10 (`number_right`, so 9 and 16 line up), a 5x5 box at x + 11 (filled at the number's level when populated, an outline at level 2 when empty), then the slot's name at x + 20 (`name_offset`), cut with `fit_text` to 42 px (`name_width`, 7 of the widest characters), at the number's level. The current scene is at level 15 (`S.lib.scenes.shows_current(slot)`, so the scene a fade goes to blinks between 15 and 4 by fade step, #254) and the rest at 4. While the sequencer runs, `>` (level 10) marks its position in front of that slot's name, which then starts 5 px later (`mark_width`) and is cut 5 px shorter. The cursor's slot has a level 15 outline around its number and box (x .. x + 17), with one clear pixel inside and out (8 px rows leave room for it between the slots). The seven fields (3.7) are rows of two (`fields_per_row`, at `column_x`) with two rows in view at y 48 and 55, the cursor's field at level 15 and the rest at 4: `fade 2.0s`, `seq on`; `len 4`, `dur 16s`; `next 100%`, `prev 0%`; `random 0%` (the chance reads `random` as on SEQ, the groundwork's ruling 30; `random 100%` is 53 px, inside its 64 px column). The sequencer's field reads `seq off`, `seq on`, or `seq on [none]` (59 px, ending at x 123) while it is on and `S.lib.scenes.playable_slots(1, scene_sequence_length)` is empty (#893): the pass's own list, so the field says what the pass does, holding a slot and recalling nothing; the page keeps no record of it, and it shows at the page's next redraw, as the fields' values do. The rows scroll with the cursor's row through `S.lib.ui_field_list.first_visible` (one row above the cursor kept, so stops 17-20 show the first two rows, 21-22 rows 2-3 and 23 rows 3-4; on a slot the first two), and `draw_marker` draws field_list's scroll marker at x 127 from y 42 to 56. E2 moves through stops 1-23; ALT+E2 on a slot moves to the slot 8 away (`SCENE_BANK_SIZE`) when there is one and otherwise does nothing, and on a field row moves one stop; E3 on a slot edits `scene_transition_time` (ALT+E3 finely); on field 18 it sets `scene_sequencer_enabled` by the turn's direction, through `set_binary_param` so a controller mapped to it follows (#538); on 17, 19, 20 and the chances 21-23 it goes through `enc_param_delta` (a chance moves a percent a detent). Of the params the fields show only the sequencer switch redraws from its action (its stop); the transition time, duration, length and the chances have no action that redraws, so a change from a mapped controller shows at the page's next redraw. Hints: `K2:fade K3:recall` on a slot, `E2:move E3:edit` on a field, `K2:name K3:save` with ALT on a slot, and the overwrite prompt in place of any of them while armed.

The name entry (ALT+K2 released on a slot) is `textentry.enter(callback, S.lib.scenes.name(slot), "scene <n> name")`: it starts from the slot's name, and its OK names the slot (cut to 12 printable ASCII characters by `set_name`, which writes the file). An empty slot takes a name too and stays empty. While it is open norns' entry owns the screen and the keys; the arc and the grids still work (a ring can move the cursor; the entry still names the slot it opened for).

## States

The overwrite confirmation (`S.scenes_page`, #255):

| State | `armed_slot` | `armed_until` | Hint row | `animates()` |
|-------|-----|-----|-----|-----|
| idle | nil | 0 | the page's hints | false |
| armed | the cursor's slot (1..`NUM_SCENES`) | a `util.time()` still ahead | ALT held: `K3 again: overwrite S<armed_slot>`; ALT up: `ALT+K3: overwrite S<armed_slot>` (unless a hints flash showing on SCENES covers it) | true |
| lapsed | a slot, but not the cursor's, or with `armed_until` passed | as set | the page's hints | true once: it disarms |

- idle or lapsed to armed, armed to armed: ALT+K3 on a populated slot that is not armed or whose prompt a flash covers (`scenes_alt_key`) sets `armed_slot` to the slot and `armed_until` to now plus 2 s.
- armed to idle: `disarm()`, from the confirming ALT+K3 (then `S.lib.scenes.save(slot)`), an ALT+K3 on an empty slot (which saves at once), and `move_cursor` when the cursor moves.
- armed to lapsed: time passing, or `S.cursors.scene` set directly; no function runs.
- lapsed to idle: `disarm()`, from `animates()` on the next frame while SCENES shows (or `move_cursor`, or an ALT+K3).

The name entry (`S.scenes_page.naming`, the page's `name_entry`, an `S.lib.ui_name_entry` entry):

| State | `naming` | `name_entry.is_open()` | globals `key`, `enc` | global `redraw` |
|-------|-----|-----|-----|-----|
| closed | nil | false | Strata's | Strata's |
| open | the slot (1..`NUM_SCENES`) | true (its callback is `textentry.callback`) | the entry's | `norns.none` |

- closed to open: ALT+K2 released on a slot (`scenes_alt_key_release`): `naming` set, then the entry's `open` (`forget_held_keys()`, the callback and Strata's key and enc kept, then `textentry.enter`).
- open to closed: the entry's callback (OK names the slot, a K2 release cancels: the entry puts the globals back first), or `reconcile_name_entry` when the menu's own entry replaced `textentry.callback` (it puts Strata's key and enc back itself and routes play mode to them).
- open to open: the menu opened and closed over the entry (`reconcile_name_entry` puts `norns.none` back in `redraw` and redraws the entry).
