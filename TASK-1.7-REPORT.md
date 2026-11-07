# Task 1.7 report
Renames: toggle_freeze->toggle_lock; grid_key_256_freeze/grid_redraw_256_freeze->_lock; M.start_or_freeze_selected_voice->start_or_lock_selected_voice (lib/pages_main field, not global); MAIN [F]/[FREEZE]->[L]/[LOCK], hint "lock". S.fx_filter_last_mix -> S.fx_last_mix.{filter,delay,reverb}; fx.lua K3 reads .filter.
Tests added in test/unit/engine_sync_test.lua (3). Tests updated in mutation, pages, scenes, ui, midi_in, structure tests. No formal RED run recorded. 273 tests, 0 failures (lua, luajit); sync_check passes.
Not touched: lib/arc/core.lua (no freeze name there), scene format.
