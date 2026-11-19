## Must not break

- **SV saves only while held in its role on this pane** (`pane.pressed_as(2, 7, "save")`, or x 16 on a half pane showing columns 9-16): a scene key of line 1 or 2 then calls `S.lib.scenes.save(x)` alone, at its press, and recalls nothing. SV released first, the key recalls; a page change of the pane forgets SV's role (`end_pane_keys`, ruling 54); each pane of a 256 has its own SV (its role is its physical key's). There is no save hold (design §10.10): SV replaces 3.7's half-second save key.
- **x 16 of line 7 is SV only on a half pane showing x 16 and not x 2** (the 64's right half, ruling 58); on a full pane it is dark and never takes the role.
- **Every recall goes through the quantizer**, wrapped in a function: `S.lib.quantize.schedule("scene", function() recall_scene(x, 0) end, "S" .. x)` (line 1), and with `params:get("scene_transition_time")` read at the press (line 2). An unwrapped `recall_scene` would recall at once.
- **SQ goes through `set_binary_param`**, so a MIDI map echoes it (#538).
- **The recorders go through `pane.gesture_key(x, 7, z, x - 8)`** on the press and the release: the core's role makes a key act only at the release of a press made as that recorder's key, and its half-second hold clears.
- **The morph's X and Y are fader lines** (`faders(pane)`: line 4 `morph`, line 5 `morph_y`, `S.lib.grid_pane.LINE_KEYS` keys each), set and drawn by the pane engine through `set_param_from_column`, so a recorder records them as grid touches. A missing (renamed) `morph` or `morph_y` raises in `faders` (`params:lookup_param`), inside the faders' containment, which prints it once and leaves the page no fader lines; never on the engine's `draw_line` path, and never a line silently dropped (#853).
- **The corner lives in `pane.state().corner`** (1-4, A at first), per port: a port's two panes on this page share it, and it goes with the port's grid. Never in `port_state` directly.
- **`signature(pane)`** is the corner, `morph_a` to `morph_d`, the sequence length and `scene_sequencer_enabled`, read plainly, so a missing param raises (contained, printed once): the corners' scenes have no action that redraws the grids, so the drift tick's follow shows them.
- **Bounds**: a press needs x in 1..`LINE_KEYS` (line 7 has all sixteen keys); lines 1-3 and 6 name a scene or a length, so they also need x <= `NUM_SCENES`, and the redraw draws them to `min(NUM_SCENES, LINE_KEYS)` and line 7 to `LINE_KEYS` (#853).

## Owns

- `lib/grid/pages/scenes.lua` (`S.lib.grid_pages_scenes`): its record (`M.record`), registered at `GRID_PAGES.scenes`; `M.SCENES_PAGE` (the lines, line 7's keys, the levels).
- Unit tests: `test/unit/grid_pages_scenes_test.lua`, on every arrangement of the pane harness that shows the keys each test needs.

## Keys and LEDs (design §10.5)

| Line | x | Press | Release | LED |
|---|---|---|---|---|
| 1 | 1-16 | SV held: save x; else recall x at once (quantized) | - | `scene_recall_level(x)` 15 / 10 / 8 / 2 |
| 2 | 1-16 | SV held: save x; else recall x with the transition time (quantized) | - | `scene_fade_level(x)` 6 / 2 |
| 3 | 1-16 | `params:set("morph_" .. the corner's letter, x)` | - | 15 the corner's scene, 6 populated, 2 empty |
| 4, 5 | 1-16 | fader lines `morph`, `morph_y` (the engine's) | - | bar 8, value 15 |
| 6 | 1-16 | `scene_sequence_length = x` | - | 8 within, 2 beyond |
| 7 | 1 SQ | `scene_sequencer_enabled` toggled (`set_binary_param`) | - | 15 / 4 (`GRID_LEVELS.picked`, `unpicked`) |
| 7 | 2 SV (16 on a half pane showing 9-16) | `pane.press_as(x, 7, "save")` | its role ends | 15 held in its role, 4 |
| 7 | 4-7 cA-cD | `corner = x - 3` | - | 15 picked, 4 |
| 7 | 9-12 G1-G4 | `pane.gesture_key(x, 7, 1, x - 8)` | `gesture_key(.., 0, ..)`: acts in its role; a 0.5 s hold clears | `gesture_level` 2 / 5 / 10 / 15 |
| 7 | 3, 8, 13-15, 16 on a full pane | nothing | | 0 |

The corner letters are `S.lib.morph.MORPH.corners`, read at each use. Turned (the 128v), the lines run down columns 1-7 and the faders up them; on a 64's halves scenes 1-8, SQ, SV and the corners are on the left, scenes 9-16 and the recorders on the right, and the fader lines are drawn across the half's eight keys. A key of line 6 repaints the grid once (#161): the length's action calls `grid_redraw()`, which waits while `grid_key` handles the key.
