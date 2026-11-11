## Must not break

- The page file sets every record field but the arc fields; SEQ's rings are `lib/arc/seq.lua`'s (`docs/notes/lua/arc-pages.md`).
- Pattern edits go through the sequencer's functions or write `S.patterns[voice][step]` within bounds (voice 1..`NUM_VOICES`, step 1..`PATTERN_LENGTH`, level 0..`MAX_STEP_LEVEL`), and call `grid_redraw()`, so the grid follows. They request no screen redraw of their own: `enc` and `key` (strata.lua) request one after every handler, and the arc's `arc_delta` does for ring 2. `lib/sequencer.lua` is consumed, never edited.
- An empty step (0) is drawn as an outline, never as a filled cell at level 0 or 1, so a level-1 step never reads as empty.
- The playing column is `S.lib.sequencer.sounding_step()`, the step that sounded last (nil while stopped and before the first step): the pattern clock plays `S.pattern_position` and then advances it, so never draw from `S.pattern_position`. Every grid layout lights the same step, between steps too (#113).
- While the patterns play, the frame clock redraws SEQ's screen every frame (screen only, never the arc; the rule is in `docs/notes/lua/ui/redraws.md`), so the column moves. `draw()` requests no redraw. When they stop or another page shows, nothing extra draws. While the norns menu is open the frame still calls the global `redraw` (norns.none then), so the page itself never draws and the arc gets no extra frames (tested).
- ALT+K2/ALT+K3 are the record's `alt_key` (reached through `alt_action`), never handled in `key`. ALT+E3 changes `tempo` through `enc_param_delta` (a number param: whole BPM).
- The arc button (`arc_button`) plays/stops, like K2; K3 is the step's on/off (design §7 lists SEQ play/stop for the button).

## Owns

- `lib/pages/seq.lua` (`S.lib.pages_seq`): the SEQ record (`S.registry.pages[UI_PAGES.index.SEQ]`) with `draw`, `hints`, `enc`, `key`, `alt_enc`, `alt_key`, `header_status`, `arc_button` and `layout_states`; its layout constants are the local `SEQ_PAGE` table. The module's table has no fields.
- Its unit tests: `test/unit/pages_seq_test.lua`. Its step cursor is `S.cursors.seq_step` (`lib/ui/cursors.lua`); the row is `S.selected_voice`.

## The page

Drawing (`redraw_seq`, design §5):
- One row per voice, rows 6 px apart from y 13 (the row's top). The voice number at x 0, baseline 5 px below the top, level 15 for the selected voice and 4 for the others; `+` (running) or `-` (stopped) right-aligned at x 127, level 4.
- Sixteen cells of 4×4 px, 6 px apart from x 10 (so x 10-103). A step at level L (1-15) is a filled rect at level L; an empty step a 4×4 outline at level 1.
- The playing column (the sounding step, while the patterns play): outlines at level 4, filled cells at `min(15, L + 4)`.
- The cursor: a 6×6 outline at level 15 around the selected voice's step (`S.cursors.seq_step`, clamped to 1..`PATTERN_LENGTH`).
- `header_status()` returns `"<tempo> bpm"`; `draw_header` draws it at x 79 with the play mark at x 73 while the patterns play (`HEADER.status_x`, `HEADER.status_play_x`; a test in `test/unit/ui_layout_test.lua` compares the two).
- The renders stroke the cells' outlines on whole-pixel rects, as the other pages' lines do; on the OLED cairo centers a 1 px stroke on the path, which the 3.1 hardware check should look at.

Keys:
- E2: `S.lib.ui_cursors.move("seq_step", d)`. E3: the step's level, clamped to 0..`MAX_STEP_LEVEL`.
- K2: `pattern_toggle()`. K3: `toggle_pattern_step(S.selected_voice, step)` (on at 15, or off).
- ALT+E2: `S.lib.ui_keys.select_voice_by(d)` (MAIN's list and the MIDI bend follow). ALT+E3: `enc_param_delta(3, "tempo", d)`.
- ALT+K2: `clear_pattern(S.selected_voice)`. ALT+K3: `randomize_pattern(S.selected_voice)`.
- Hints: `K2:play K3:step E3:level` (`K2:stop` while playing); ALT: `K2:clr K3:rand E3:bpm`.

`layout_states`: the cursor at steps 1 and 16 on voices 1 and 7, every row with levels while playing (`levels-playing`), and 300 BPM while playing (`tempo-300`).

Room for 3.4 (design §5): per-voice length, division, probability and step locks will appear here, as `field_list` rows under the patterns or on a second view.
