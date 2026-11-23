## Must not break

- **The picker is a modal owner** (`S.lib.ui_modal`): open exactly while its own owner is the modal top, but beneath SEQ's step editor as the zones editor allows (a registered invariant, "voice picker"); no key is held on a closed picker. VOICE's K3 opens it only from the `preset` row, so it is never open with another of VOICE's owners.
- **Every count is a name**: the other voices are `NUM_VOICES - 1` rows, the slots `S.lib.voice_presets.VOICE_PRESETS.slots`, the hold `VOICE_PICKER.hold_seconds` (`ALT_HOLD_SECONDS`); every position and text is a field of `VOICE_PICKER` (ruling D4).
- **E2 moves, E3 does nothing**: E2 goes through `S.lib.ui_field_list.move_scroll`, and the cursor and the view's tail are kept while the picker is closed, as the zones editor's are; E3 changes no row and no param.
- **A name is drawn as norns' font can draw it**: a slot's name goes through `S.lib.ui_text.printable` and is cut by `fit_text` to the room left of its type (`type_gap` px), as the scale editor draws a file's name (#551).
- **A press the picker did not see release is forgotten** (#866): its press times are the modal's (`S.lib.ui_modal.held_seconds(owner, n)`), never marks of its own, and the modal forgets them as the norns menu opens (`forget_held_keys`) and when another owner is pushed over the picker (the grid's step editor, which may cover it). ALT+K3's slot (`k3_slot`, nil for a plain K3, set at every K3 press) is data read only while K3's press is still the picker's. So no held clear hint stays animating and no later K3 opens an old slot's entry, after the menu or a covering owner alike.
- **The name entry is SCENES' piece, `S.lib.ui_name_entry`** (#849, `docs/notes/lua/ui/name-entry.md`): norns' `textentry`, opened on ALT+K3's release (the entry cancels on a K2 release, and K3's would reach it), after `forget_held_keys()` (so ALT is not held after it); its own `S.register_menu_close` hook runs the entry's `reconcile()`, which acts only on the picker's entry: when the menu took the one textentry over it forgets the entry and puts Strata's key and enc back, and when the menu only came and went it hands the screen back to the entry; SCENES' entry is left to SCENES. The entry starts from the slot's name (empty for an empty slot) under the heading `preset <nn> name` and passes no `check`, as SCENES' does: a longer name is cut to twelve at the save.
- **Its hint row shows a flash first**: under a modal owner `redraw()` takes the hints from the owner, so `hints` returns `S.lib.ui_flash.text("hints")` while one shows (a refused load or save, flashed by `S.lib.voice_presets` with VOICE's page).
- **ALT+K2's clear decides at the release**, by how long it was held: `hold_seconds` or more on a filled slot clears it (`S.lib.voice_presets.clear`); a quick press does nothing. The owner `animates` while K2 is down (`held_seconds` answers: a plain K2 closes the picker at the press, so a K2 it holds is an ALT+K2), so the hint turns from `K2:hold` to `K2:clear` at the hold time.

## Machines

### voice picker
- **State:** `picker = {open, voice, cursor, tail, k3_slot}` (local to `lib/ui/voice_picker.lua`), read through `S.lib.ui_voice_picker.is_open()`; its presses are the modal's (`S.lib.ui_modal.held_seconds(owner, n)`), `k3_slot` data read only while K3's press is still the picker's. Its name entry is `S.lib.ui_name_entry`'s machine (`docs/notes/lua/ui/name-entry.md`).
- **Invariant:** `voice picker`: the open picker's owner is the modal one (or lies beneath SEQ's step editor), the closed picker's never; its cursor is a row of its list; `k3_slot` is nil while it is closed.
- **Test:** `test/unit/ui_voice_picker_test.lua`: "an owner covered while ALT+K3 is down forgets the press: a later plain K3 tap opens no name entry" (and "an owner covered while ALT+K2 is down shows its plain hint and does not animate", "cleanup closes the picker").

No test runs this table: it is one of the design's modal owners (its section 5, a table and no test). It lists the events that open or close the picker and the keys that act on a row; E2 (the cursor) and E3 (nothing) are its own editing and leave it open, and a cleanup of a closed picker does nothing. Its opens and closes are a row of the owners' table (`docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner).

| State | Event | Next | Effect |
|---|---|---|---|
| closed | K3 on VOICE's `preset` row | open | pushed for the selected voice, the cursor where it was left |
| open | K2 (no ALT) | closed | popped at the press |
| open | K3 (no ALT) | open | a voice's sound copied or a slot's preset loaded, `loaded <name>` flashed |
| open | ALT+K3 released on a slot, its press the picker's | open | the name entry opens (it takes the keys until it closes) |
| open | ALT+K2 released held `hold_seconds` on a filled slot | open | the slot cleared; quicker, nothing |
| open | the grid's step editor pushed over it | open | its presses forgotten: no later release acts on them (#866) |
| open | cleanup (step 138) | closed | popped |

## lib/ui/voice_picker.lua (`S.lib.ui_voice_picker`)

Opened by K3 on VOICE's `preset` row (`lib/pages/voice.lua`) for the selected voice. Fields: `open(voice_idx)`, `close()`, `is_open()`, `reconcile_name_entry()` (its menu-close hook) and `VOICE_PICKER` (the layout and texts). Its cleanup step (`CLEANUP_ORDER.voice_picker`, 138) closes an open picker, so its owner is not left on the modal stack.

The screen: the title `LOAD INTO VOICE <n>` at x 0, y 16 (`title_y`), level 10; five rows (`visible`) from y 24 (`first_y`), 7 px apart, through `S.lib.ui_field_list.draw` (its scroll marker at x 127): `from voice <n>` with the voice's type `list_name` right-aligned at x 124 (`value_right`), then `<nn> <name>` with the preset's type `list_name` (`?` for a type this build lacks), or `<nn> --` for an empty slot. The cursor's row at level 15, the others at 4.

| Row | K3 | ALT+K3 | ALT+K2 held |
|-----|----|--------|-------------|
| a voice | copies its sound into the voice (`S.lib.voice_presets.copy`) | | |
| a filled slot | loads it (`load`) | names it and saves the voice there | clears it |
| an empty slot | nothing, and the flash `empty slot` | names it and saves the voice there | |

K2 (no ALT) closes it at the press. A load or a copy leaves the picker open, so presets can be tried one after another, and flashes `loaded <name>` on its hint row (`VOICE_PICKER.loaded`, through `S.lib.ui_flash` with VOICE's page; a copy's name is `v<n>`); the VOICE `preset` row shows the name. Hints: `K2:back K3:copy` (a voice row), `K2:back K3:load` (a filled slot), `K2:back` (an empty one); with ALT `K2:clear K3:save` (`K3:save` on an empty slot, `E2:row` on a voice row, where ALT's K2 and K3 do nothing, #850); while ALT+K2 is down `K2:hold`, past the hold time `K2:clear` (`K2:cancel` on a row with nothing to clear).

VOICE's record carries the layout states: the `preset` row with a twelve-character name; the picker on a voice row, on slot 1 with a twelve-character name and the type with the widest `list_name`, on slot 64 empty, with ALT held (on slot 1, and on a voice row), with ALT+K2 past the hold time, a refused load's flash (K3 on an empty slot) and a load's flash.

Tests: `test/unit/ui_voice_picker_test.lua`; the `preset` row's own in `test/unit/pages_voice_test.lua`.
