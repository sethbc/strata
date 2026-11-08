## Must not break

- The 64 shows and edits one half of the patterns at a time: steps 1-8 or 9-16 (`visible_steps = math.min(PATTERN_LENGTH, cols)`), chosen per port by `S.lib.grid_core.port_state(port).half` (1 or 2; nil reads as 1). Patterns still play all 16 steps; a key in column x edits step `(half - 1) * 8 + x` and never any other.
- The half lives in `port_state`, so it is per grid and is forgotten when the grid is removed (a grid plugged back shows steps 1-8). Never keep it in a layout local or on `S`.
- Pattern keys go through `step_key` with 8 positions (the column within the shown half), so column 8 sets level 15 and column 4 level 8 in either half.
- Row 8 column 1 acts on release, not press: a release before `GRID_HOLD.half_toggle_seconds` (0.5 s) plays or stops (`pattern_toggle`). The hold goes through `on_hold` (never a clock of the layout's own), so a release, a grid removal or cleanup cancels it. When it fires it switches the half and `consume`s the key, so the release does nothing. A release the core never saw pressed does nothing.
- Columns 2-8 of row 8 toggle voices 1-7 (all seven are reachable).
- Column 1's LED: stopped, the shown half (`LAYOUT_64.stopped_levels`: 4 for steps 1-8, 8 for steps 9-16, per port; the half switch redraws, so it shows at once); 15 while the playhead (`S.lib.sequencer.sounding_step()`, step 1 if none has sounded yet; never `S.pattern_position`, the next step) is in the shown half, and while it is in the other half a blink with the beat: 12 on odd quarter notes and 3 on even ones (`LAYOUT_64.steps_per_beat` = 4 sixteenth-note steps per beat, so steps 9-12 light and 13-16 dim). Never blink per step: that strobes at about 8 Hz at 120 BPM. The shown half's playhead is `step_brightness`'s own.
- The geometry and LED levels live in the one `LAYOUT_64` table (`S.lib.grid_layout_64.LAYOUT`).

## Owns

- `lib/grid/layout_64.lua` (`S.lib.grid_layout_64`): `grid_key_64`, `grid_redraw_64` (global) and `S.lib.grid_layout_64.shown_half(port)`; everything else is local. It registers `S.registry.grid_layouts["64"]`.
- Its unit tests: `test/unit/grid_layout_64_test.lua`.

## Keys

- Rows 1-7: `step_key(port, x, y, z, y, (half - 1) * 8 + x, x, 8)`.
- Row 8: column 1 play / stop on a tap's release, switch the half on a 0.5 s hold; columns 2-8 `toggle_voice(x - 1)` (LED 12 running, 4 stopped).
