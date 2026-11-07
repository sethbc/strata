## Must not break

- The page file sets every record field but the arc fields; SCENES' rings are `lib/arc/scenes.lua`'s (`docs/notes/lua/arc-pages.md`).
- A page-owned prompt (such as an overwrite confirmation) goes through `S.lib.ui_flash.start("hints", text, seconds, UI_PAGES.index.SCENES)`, so it shows only while SCENES is up.

## Owns

- `lib/pages/scenes.lua` (`S.lib.pages_scenes`): the SCENES record. A stub for now: it draws nothing, its hint row reads `E1:page` and it ignores the encoders and keys (`ignore_page_input`); it has no ALT keys and no `arc_button`.
- Its unit tests: `test/unit/pages_scenes_test.lua`. Its cursor is `S.cursors.scene` over the eight slots and `S.constants.SCENES_FIELDS` (`lib/ui/cursors.lua`). The scenes themselves are `lib/scenes.lua`'s (`docs/notes/lua/scenes.md`).

## The page

Planned for 3.1 (design §5, plan Task 2f): the eight slots in two columns and the four sequencer fields, K2 recall with the transition, K3 instant recall, ALT+K3 save (asking again before overwriting a populated slot).
