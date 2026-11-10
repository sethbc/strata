## Must not break

- The page file sets every record field but the arc fields; SCENES' rings are `lib/arc/scenes.lua`'s (`docs/notes/lua/arc-pages.md`).
- A page-owned prompt (such as an overwrite confirmation) goes through `S.lib.ui_flash.start("hints", text, seconds, UI_PAGES.index.SCENES)`, so it shows only while SCENES is up.
- The overwrite confirmation is `S.scenes_page = {armed_slot, armed_until}`. A second ALT+K3 saves only on the same slot as the first, before `armed_until` (2 s) and while `S.lib.ui_flash.text("hints")` is still that slot's prompt (`K3 again: overwrite S<n>`). If another hints flash replaced the prompt (a failed buffer load, say), the press only arms again and shows the prompt again: never save without the prompt on screen.
- Every E2 or ring move of the cursor goes through `S.lib.pages_scenes.move_cursor(slot)` (E2 and arc ring 1): it puts `S.cursors.scene` on `slot`, clamped to the slots and fields, and, when the cursor moved, disarms and ends the prompt. A move by another route (setting `S.cursors.scene` directly) is caught by `draw` and `hints` comparing the slot, except a move away and back within 2 s. The cursor must never carry a confirmation to another slot (Review Focus 5).
- Recall goes through the global `recall_scene(slot, time)`, looked up at call time (tests replace it); a save (an empty slot, or the confirmed second ALT+K3) goes through `S.lib.scenes.save(slot)`, which flashes `saved S<n>` in the header. K2 uses `scene_transition_time`, K3 and `arc_button` use 0. Keys do nothing while the cursor is on a field.

## Owns

- `lib/pages/scenes.lua` (`S.lib.pages_scenes`): the SCENES record with draw, hints, enc, key, alt_key, `arc_button` and `layout_states` (every slot and field as cursor, all populated, sequencer on, and the armed flash); `move_cursor(slot)` (a field of `S.lib.pages_scenes`). Its tests: `test/unit/pages_scenes_test.lua`.
- Its cursor is `S.cursors.scene` over the eight slots and `S.constants.SCENES_FIELDS` (`lib/ui/cursors.lua`). The scenes themselves are `lib/scenes.lua`'s (`docs/notes/lua/scenes.md`).

## The page

Two columns of four slots (`SCENES_PAGE.column_x`, rows 8 px apart from y 16): the number, a 5x5 box (filled when populated, an outline when empty), the current scene at level 15 (`S.lib.scenes.shows_current(slot)`, so the scene a fade goes to blinks between 15 and 4 by fade step, #254) and the rest at 4, `>` at the sequencer position while it runs, and a level 15 outline around the cursor's slot with one clear pixel inside and out (8 px rows leave room for it between the slots). The four fields are a 2x2 block at y 48 and 55, the cursor's at level 15. E3 on a slot edits `scene_transition_time`; on field 10 it sets `scene_sequencer_enabled` by the turn's direction; on 11 and 12 it goes through `enc_param_delta`. Hints: `K2:fade K3:recall` on a slot, `E2:move E3:edit` on a field, `K3:save` with ALT.
