## Must not break

- A step key goes through `pane.step_key(x, y, z, y, x)` (line y is voice y, x its step), never the core's `step_key` with a physical key, so the release toggle, the level gesture over the keys shown (16, or 8 on a 64's half) and the step editor's hold are the core's on every layout.
- Its LEDs are `step_brightness(voice, step)`, as SEQ draws them, so the sounding step between steps shows (#113).
- One side; no fader lines, no signature: the patterns' changes redraw the grids from the sequencer.

## Owns

- `lib/grid/pages/patterns.lua` (`S.lib.grid_pages_patterns`): its record (`M.record`), registered at `GRID_PAGES.patterns`.
- Unit tests: `test/unit/grid_pages_patterns_test.lua`, on every arrangement of the pane harness.

## Keys and LEDs (design §10.3)

Lines 1-7 are voices 1-7, x 1-16 their steps. A press makes the key the voice's held step (it toggles at its release), a second key of the line sets the held step's level, a 0.3 s hold opens the step editor and its release closes it (`docs/notes/lua/grid-core.md`, Step keys). The page draws `step_brightness` for every voice and step; on a 64 the half shown draws its eight.
