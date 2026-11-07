# Task 2f report
Files: lib/pages/scenes.lua (page), test/unit/pages_scenes_test.lua (8 tests, RED 8/8 then GREEN), docs/user/pages/scenes.md, docs/user/scenes.md, docs/notes/lua/pages/scenes.md, changes/3.1-2f-scenes.md.
Outside list: test/unit/ui_layout_test.lua, one assertion (probe drawn == own_states + 1) because the old one assumed no record had layout_states.
Render: two columns of slots, cursor outline, 2x2 fields at y 48/55, hints at 62; nothing clipped after moving columns to x 2/66.
Totals: lua 361/0, luajit 361/0, sync_check pass.
Note: brief says S.lib.cursors.move; merged name is S.lib.ui_cursors.move.

## Fix round 1
- ui_layout_test: assertion is now `drawn == baseline - fx_own + 1` (baseline from the first check_layout_states call, fx_own recorded in the probe). origin/main had no newer commits to merge.
- scenes page: the arm lapses (and its flash is canceled) when armed_slot ~= cursor slot, checked in draw and hints; test "the overwrite flash goes when the cursor leaves the slot by another route".
- "rows descend" now compares each row with the previous one in its column.
- `lua test/run.lua scenes` 43/0; `ui_layout` 4/0; full: lua 362/0, luajit 362/0, sync_check passed.
