## Must not break

- The page file sets every record field but the arc fields; SEQ's rings are `lib/arc/seq.lua`'s (`docs/notes/lua/arc-pages.md`).
- Pattern edits go through the sequencer's functions (`docs/notes/lua/sequencer.md`) and call `grid_redraw()`, so the grid follows.

## Owns

- `lib/pages/seq.lua` (`S.lib.pages_seq`): the SEQ record. A stub for now: it draws nothing, its hint row reads `E1:page` and it ignores the encoders and keys (`ignore_page_input`); it has no ALT keys, no `header_status` and no `arc_button`.
- Its unit tests: `test/unit/pages_seq_test.lua`. Its step cursor is `S.cursors.seq_step` (`lib/ui/cursors.lua`).

## The page

Planned for 3.1 (design §5, plan Task 2l): one row of 16 cells per voice at the step levels, the step cursor, E3 setting a step's level, K2 play/stop, the tempo in the header through `header_status()`.
