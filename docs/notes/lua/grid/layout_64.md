## Must not break

- The 64 has three views, cycled by row 8 column 1's hold: steps 1-8, steps 9-16, positions, steps 1-8. The positions view is grid page 5 (`S.lib.grid_core.set_page(port, 5)`; the steps views are page 1 with `port_state(port).half`), so it is per port; leaving it resets the half to 1. In it rows 1-2 are the grid voice's 16 positions (`S.lib.positions.grid_key(port, S.grid_voice_select, cell, 16, z)`, row 1 cells 1-8, row 2 cells 9-16, releases passed on), row 3 the strip (`strip_key`: columns 1-4 bookmarks, 6 store, 7 hold, 8 whole; column 5 nothing), rows 4-6 dark, row 7 columns 1-7 `select_grid_voice` (LED 15 selected, 6 a buffer voice, 2 other), row 8 as on the steps views except column 1's LED (15 playing, 6 stopped). The step views never call `S.lib.positions`.
- The 64 shows and edits one half of the patterns at a time: steps 1-8 or 9-16 (`visible_steps = math.min(PATTERN_LENGTH, cols)`), chosen per port by `S.lib.grid_core.port_state(port).half` (1 or 2; nil reads as 1). Patterns still play all 16 steps; a key in column x edits step `(half - 1) * 8 + x` and never any other.
- The half lives in `port_state`, so it is per grid and is forgotten when the grid is removed (a grid plugged back shows steps 1-8). Never keep it in a layout local or on `S`.
- Pattern keys go through `step_key` with 8 positions (the column within the shown half), so column 8 sets level 15 and column 4 level 8 in either half. The step toggle on release and the step editor's hold are the core's (`docs/notes/lua/grid-core.md`): a step held 0.3 s in a steps view opens the editor for the step of the shown half; the positions view never calls `step_key`, so it opens none. A half switch ends the port's step gestures (`end_port_step_gestures`), closing an editor a step of the half it leaves opened, so that step's release toggles nothing.
- 3.4 adds no other key (design §11): the recorders, macros and morph are on the screen, the arc and MIDI. The voice keys light a running, silenced voice at 6 through the core's `voice_level`.
- Row 8 column 1 acts on release, not press: a release before `GRID_HOLD.half_toggle_seconds` (0.5 s) plays or stops (`pattern_toggle`). The hold goes through `on_hold` (never a clock of the layout's own), so a release, a grid removal or cleanup cancels it. When it fires it switches the half (ending the port's step gestures with `end_port_step_gestures`, so a step held in the half it leaves never takes a level, #242) and `consume`s the key, so the release does nothing. A release the core never saw pressed does nothing.
- Columns 2-8 of row 8 toggle voices 1-7 (all seven are reachable).
- Column 1's LED: stopped, the shown half (`LAYOUT_64.stopped_levels`: 4 for steps 1-8, 8 for steps 9-16, per port; the half switch redraws, so it shows at once); 15 while the playhead (`S.lib.sequencer.sounding_step()`, step 1 if none has sounded yet; never `S.pattern_position`, the next step) is in the shown half, and while it is in the other half a blink with the beat: 12 on odd quarter notes and 3 on even ones (`LAYOUT_64.steps_per_beat` = 4 sixteenth-note steps per beat, so steps 9-12 light and 13-16 dim). Never blink per step: that strobes at about 8 Hz at 120 BPM. The shown half's playhead is `step_brightness`'s own.
- The geometry and its own LED levels live in the one `LAYOUT_64` table (`S.lib.grid_layout_64.LAYOUT`); the voice keys light at the core's `voice_level` (#526); the positions view is `S.constants.GRID_PAGES.positions` with `GRID_PAGES.position_cells` cells (#451).

## Owns

- `lib/grid/layout_64.lua` (`S.lib.grid_layout_64`): `grid_key_64`, `grid_redraw_64` (global) and `S.lib.grid_layout_64.shown_half(port)`; everything else is local. It registers `S.registry.grid_layouts["64"]`.
- Its unit tests: `test/unit/grid_layout_64_test.lua`.

## Keys

- Rows 1-7: `step_key(port, x, y, z, y, (half - 1) * 8 + x, x, 8)`.
- Positions view (page 5): see the first item of Must not break.
- Row 8: column 1 play / stop on a tap's release, a 0.5 s hold cycles steps 1-8, steps 9-16 and positions; columns 2-8 `toggle_voice(x - 1)` (LED 12 running, 2 stopped).
