## Must not break

- The hints name only keys that act (#419, #420): an empty slot reads `empty  ALT+K3:save` (its recall does nothing but flash `S<n> empty` on the header, from `recall_scene` itself, so a grid key shows it too, and so does any other caller on an empty slot, MIDI included; the scene sequencer skips empty slots before it calls), ALT on a slot `K3:save`, any field (ALT or not) `E2:move E3:edit`.
- The page file sets every record field but the arc fields; SCENES' rings are `lib/arc/scenes.lua`'s (`docs/notes/lua/arc-pages.md`).
- The overwrite prompt is the page's own state, never a flash (#255): the page never starts or ends a `"hints"` flash. The confirmation is `S.scenes_page = {armed_slot, armed_until}`, and it is armed while `armed_slot` is the cursor's slot and `util.time() < armed_until` (2 s after the arming press). While armed, `hints` returns the prompt with or without ALT, so a flash scoped to another page (BUFFER's load reports) cannot hide it. The prompt names the keys that answer it: `K3 again: overwrite S<n>` with ALT held, `ALT+K3: overwrite S<n>` with ALT up (a plain K3 then recalls the slot, as always).
- A second ALT+K3 saves only while armed and no flash covers the hint row (`S.lib.ui_flash.text("hints") == nil`). Under a covering flash (a hints flash showing on SCENES: one with no page, or one scoped to SCENES) the press only arms again: never save without the prompt on screen.
- `draw` and `hints` write no state and never call `S.lib.ui_flash` or `request_redraw()`. The prompt lapses through the record's `animates` (the frame clock draws the page every frame while it returns true): false when nothing is armed, true while armed, and once the arming has lapsed (its time passed, or the cursor left the slot by a route other than `move_cursor`) it disarms and returns true once more, for the frame that takes the prompt off the hint row.
- Every E2 or ring move of the cursor goes through `S.lib.pages_scenes.move_cursor(slot)` (E2 and arc ring 1): it puts `S.cursors.scene` on `slot`, clamped to the slots and fields, and, when the cursor moved, disarms (and asks for a redraw). A move by another route (setting `S.cursors.scene` directly) is never armed, since `armed` compares the slot, and the next frame disarms it, except a move away and back within one frame. The cursor must never carry a confirmation to another slot (Review Focus 5).
- The invariant `"scenes prompt"` (`S.register_invariant`): `armed_slot` is nil or a slot in 1..`NUM_SCENES`.
- Recall goes through the global `recall_scene(slot, time)`, looked up at call time (tests replace it); a save (an empty slot, or the confirmed second ALT+K3) goes through `S.lib.scenes.save(slot)`, which flashes `saved S<n>` in the header. K2 uses `scene_transition_time`, K3 and `arc_button` use 0. Keys do nothing while the cursor is on a field.

## Owns

- `lib/pages/scenes.lua` (`S.lib.pages_scenes`): the SCENES record with draw, hints, enc, key, alt_key, `arc_button` and `layout_states` (every slot and field as cursor, all populated, sequencer on, and `armed` and `armed with ALT`: slot 8 armed through `S.scenes_page`, the second with K1 held, since the renders draw each state with ALT up); `move_cursor(slot)` (a field of `S.lib.pages_scenes`). Its tests: `test/unit/pages_scenes_test.lua`.
- Its cursor is `S.cursors.scene` over the eight slots and `S.constants.SCENES_FIELDS` (`lib/ui/cursors.lua`). The scenes themselves are `lib/scenes.lua`'s (`docs/notes/lua/scenes.md`).

## The page

Two columns of four slots (`SCENES_PAGE.column_x`, rows 8 px apart from y 16): the number, a 5x5 box (filled at the number's level when populated, an outline at level 2 when empty), the current scene at level 15 (`S.lib.scenes.shows_current(slot)`, so the scene a fade goes to blinks between 15 and 4 by fade step, #254) and the rest at 4, `>` at the sequencer position while it runs, and a level 15 outline around the cursor's slot with one clear pixel inside and out (8 px rows leave room for it between the slots). The four fields are a 2x2 block at y 48 and 55, the cursor's at level 15. E3 on a slot edits `scene_transition_time`; on field 10 it sets `scene_sequencer_enabled` by the turn's direction; on 11 and 12 it goes through `enc_param_delta`. Hints: `K2:fade K3:recall` on a slot, `E2:move E3:edit` on a field, `K3:save` with ALT, and the overwrite prompt in place of any of them while armed.

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
