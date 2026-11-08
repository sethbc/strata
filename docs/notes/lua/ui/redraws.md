## Must not break

- Never call `redraw()` or `arc_redraw()` from script code. Call `request_redraw()`, and the frame clock draws whatever is dirty at `UI_PAGES.FRAMES_PER_SECOND` (15). Grid redraws stay direct (`grid_redraw()`).
- SEQ animates through the frame clock: `draw_frame` marks the screen dirty each frame while SEQ shows and `S.pattern_playing`, like the LFO page, and never the arc. A page's `draw()` never calls `request_redraw()` to animate itself (that would redraw a connected arc at 15 fps).
- A failing draw prints its error once per distinct error and the frame clock keeps running.

## Redraws

Issue #11. Nothing in Strata calls `redraw()` or `arc_redraw()` directly.
- Anything that changes what the screen or the arc shows calls the global `request_redraw()`, which sets `UI_PAGES.screen_dirty` and `UI_PAGES.arc_dirty`.
- The frame clock (`UI_PAGES.frame_clock`, `start_frame_clock()` in init's last start step, `stop_frame_clock()` in `cleanup`, after the start-up clock) sleeps `1 / UI_PAGES.FRAMES_PER_SECOND` (15) and runs `draw_frame()`.
- `draw_frame()` clears each dirty flag and calls the global `redraw()` and/or `arc_redraw()`. A burst of arc turns, encoder steps, MIDI or param changes costs one screen draw and one arc redraw per frame, and an idle frame draws nothing.
- Both flags start set, so the first frame draws the screen and any arc connected at start.
- On the LFO page, and on SEQ while `S.pattern_playing`, `draw_frame` marks the screen dirty every frame (screen only, never the arc), so the dots and the playing column move. Neither page has a clock of its own.

Draw errors:
- Each draw runs through `draw_frame_part(part, draw)` (`part` is `"screen"` or `"arc"`): an `xpcall` with `draw_error_report`, which returns a key and the error with its traceback.
- The key: a string error is its own key; a table error (a new table each time) is keyed by its `message` field (also what is printed), or else by its type.
- An error is printed to the console with its traceback and the clock keeps running. The flag was already cleared, so the failed draw is not retried; the next `request_redraw()` draws again.
- `UI_PAGES.draw_errors[part]` holds the key last printed, so a draw that keeps failing with the same error (e.g. on the LFO page, which draws every frame) prints it once instead of 15 times a second.
- Another message prints, and a good draw clears the key, so the same error after a good frame prints again (issue #49).

norns' swaps still apply, because `draw_frame` calls the global `redraw`:
- while the norns menu is open the global is `norns.none` (norns calls `redraw()` itself as the menu closes);
- while the BUFFER file selector is open, `redraw()` draws the selector, never the page;
- norns' own `redraw()` calls still draw the page at once.

Who asks for a redraw:
- Every param action, through `redraw_on_param_changes()` (`lib/params_setup.lua`; run once in `init` after the last param is added; a param added, or an action set with `params:set_action`, after it runs does not request redraws). It wraps each param's action so it calls `request_redraw()` after it.
  - So PARAMS edits, PARAMS > MAP CCs, pset loads, scene fades and recalls, mutations, MIDI notes (they set freq or buf_rate) and the LFO page's E3/K2/K3 all arrive through param actions.
  - Left out: text params (the LFO library writes each LFO's scaled and raw values into `lfo_scaled_<n>`/`lfo_raw_<n>` on every step, shown nowhere), and the drift's 10 Hz writes (`S.drift_writing`; grain pitch is shown nowhere).
  - `drift_update` requests a redraw itself when it moves the selected voice's buffer position, which MAIN and the BUFFER arc ring show. Other voices' positions are shown nowhere, so they ask for none.
- Explicit calls cover state that is not a param: `enc`, `key`, `arc_delta`, `arc_key`, `grid_key`, `toggle_voice`, `toggle_lock`, `randomize_voice`, `gentle_mutate`, each smooth-transition step, `recall_scene` and the end of `recall_scene_instant` (lock and running states), the scene sequencer, `buffer_display_changed`/`buffer_state_changed`, a flash's start and end (`S.lib.ui_flash.start` and its clock) and the BUFFER file selector's callback, and the grid/arc/MIDI hot-plug callbacks.
