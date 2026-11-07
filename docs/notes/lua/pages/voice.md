## Must not break

- The page file sets every record field but the arc fields; VOICE's rings are `lib/arc/voice.lua`'s (`docs/notes/lua/arc-pages.md`).
- The VOICE cursor is `S.cursors.voice`, a row index into `voice_page_rows(S.selected_voice)`; read it only after `S.lib.ui_cursors.clamp_all()` (`docs/notes/lua/ui-core.md`, Cursors and VOICE rows).

## Owns

- `lib/pages/voice.lua` (`S.lib.pages_voice`): the VOICE record. A stub for now: it draws nothing, its hint row reads `E1:page` and it ignores the encoders and keys (`ignore_page_input`); it has no ALT keys and no `arc_button`.
- Its unit tests: `test/unit/pages_voice_test.lua`. The rows and ring groups it will show are `lib/ui/voice_rows.lua`'s (`voice_page_rows`, `voice_page_group`), tested in `test/unit/ui_cursors_test.lua`.

## The page

Planned for 3.1 (design §5, plan Task 2b): every param of the selected voice in four sections (synth, grain, crossmod, mix) through `S.lib.ui_field_list`, E2 moving `S.cursors.voice`, E3 editing the row's param, K2/K3 jumping sections, ALT+K2 resetting a field to `param_default`, ALT+K3 locking, and the arc's rings following the cursor's group of four.
