## Must not break

- A step key goes through `pane.step_key`, never the core's `step_key` with a physical key, so the release toggle, the second key over the keys shown (16, or 8 on a 64's half) and the step editor's hold are the core's on every layout: side 1's line y is voice y with the default second key (the level); side 2's line 1 is the picked voice with a function second key (`hits_second`: the level, or value A in move). A lane's cell (side 2's lines 2-6) goes through `pane.cell_key` alone, its id `"patterns <voice> <lane>"`, so a tap acts at its release and a second key of the line sets the held cell (`docs/notes/lua/grid/keys.md`).
- Every level a step gets goes through `S.lib.sequencer.set_level` and every lane value through `S.lib.sequencer.set_step_attr` (`M.set_from_position`, the tap); a step's value (value A or B in a lane that follows, value A from the hits line in move) written on a step that is off turns it on at 15 through `set_level` (`value_turns_on`, the controller's ruling for 3b's review: a value on an off step is never played nor shown), while a free lane's cell, which is no step's, leaves the hits alone; a mode and a target through `S.lib.lanes.choose_mode` and `choose_target`, so the hand's extras (a random value A for move, a closed filter opened for cutoff) happen here as on SEQ; a lane length through `S.lib.lanes.set_length`, the voice's through its `seq_length` param.
- The picked voice (`M.voice(port)`, `M.pick`), the lanes' last values and LN's arming are the port's page state (`pane.state()`'s table, `port_state(port).pages.patterns`): shared by both panes of a 256, forgotten with the port. The picked voice is never `S.selected_voice` nor `S.grid_voice_select`.
- LN's arming holds the pane it was armed on and that pane's count of page changes then (`S.lib.grid_core.page_changes(port, pane)`, moved by every page or side change, the 8×8's chooser's among them, never by a half change; the controller's ruling for 3b's review, which replaces ruling 3b-2's page and side compare), and reads as disarmed once the count has moved. So any way off side 2 disarms it, and a half change of the 8×8 keeps it. The step view is no page change (the count does not move): an LN armed before it is still armed after it, its keys the bars meanwhile. Its lights replace the lane lines' only while armed.
- The value rules are module functions (`value_for_position`, `set_from_position`, `value_light`, `cell_light`, `mode_level`), so 3.9's step view (3c) and perform side (5c) read and set the same values the lane side does.
- No fader lines, no signature: the patterns' changes redraw the grids from the sequencer and the lanes.
- The step view (3.9's 3c) is the core's `step_view(port)` naming this pane, read at every press and draw (`STEP_VIEW.of`), never a state of the page: while it does, the pane's keys and lights are the view's alone, and its bars set values through the same functions as side 2 (`set_level`, `set_from_position`, `set_step_attr`), so a value A or B written on an off step turns it on there too. A free lane's bar (`S.lib.lanes.length` set) is dark and its keys do nothing: its cells belong to no step.

## Machines

### patterns LN
- **State:** per port, the page state's `ln` (`{pane, changes}` while armed), read through `M.ln_armed(port, pane)`: armed on that pane while its count of page changes (`S.lib.grid_core.page_changes`) is still `changes`. The table follows a 64 on port 1 showing side 2's left half, voice 1 picked; the lane key is (5, 2), lane A; the voice key is voice 3's (x 12 of line 7, on the right half, the left half shown again after it).
- **Invariant:** none: the arming is read against the core's count of the pane's page changes, so no state of its own can disagree with what the pane shows.
- **Test:** `test/unit/grid_pages_patterns_test.lua`: "patterns LN: every cell is decided" and its rows; on every arrangement, "LN armed lights the lengths; the next lane key sets one and disarms; the same key again sets it back to following", "LN on line 1 sets the voice's length", "LN stays armed across a 64's half change; a page or a side change disarms" and "LN is disarmed after the 8x8's chooser goes to another page and back to side 2"; the count: `test/unit/grid_core_test.lua`'s "a pane's page changes count a page or side change, never a half change (3.9's 3b)".

`off` is LN not armed on the pane, `armed` armed. A side or page change's check comes back to side 2 through side 1, as a player does; `chooser away and back` is the 8×8's chooser to sources and then to patterns' side 2 (left half), with no draw of patterns between.

| State | Event | Next | Effect |
|---|---|---|---|
| `off` | `LN tap` | `armed` | LN lights 15 and the lane lines show the lengths (the hits 8, a following lane 3) |
| `off` | `lane key` | `off` | a cell key: its tap gives cell 5 value A 15 and turns step 5 on |
| `off` | `voice key` | `off` | voice 3 picked |
| `off` | `side change` | `off` | nothing armed |
| `off` | `page change` | `off` | nothing armed |
| `off` | `half change` | `off` | nothing armed |
| `off` | `unplug` | `off` | the port's state is forgotten |
| `off` | `chooser away and back` | `off` | nothing armed |
| `armed` | `LN tap` | `off` | LN again disarms |
| `armed` | `lane key` | `off` | lane A's length is 5; no cell tapped |
| `armed` | `voice key` | `armed` | voice 3 picked; LN stays armed for it |
| `armed` | `side change` | `off` | the pane shows side 1; back on side 2, LN is off |
| `armed` | `page change` | `off` | the pane shows voices; back on side 2 through side 1, LN is off |
| `armed` | `half change` | `armed` | the right half's lane keys set lengths: gate's 12 |
| `armed` | `chooser away and back` | `off` | the count moved twice; back on side 2's left half, LN is off |
| `armed` | `unplug` | `off` | the port's state is forgotten; plugged back, LN is off |

## Owns

- `lib/grid/pages/patterns.lua` (`S.lib.grid_pages_patterns`): its record (`M.record`, `sides = 2`), registered at `GRID_PAGES.patterns`; `LANE_SIDE` (side 2's lines, keys and lights); `voice(port)`, `pick(port, voice)`; `ln_armed(port, pane)`; the value functions above; the step view's draw and keys (`STEP_VIEW`).
- Unit tests: `test/unit/grid_pages_patterns_test.lua`, on every arrangement of the pane harness.

## Keys and LEDs (design §10.3; 3.9's design section 4)

**Side 1.** Lines 1-7 are voices 1-7, x 1-16 their steps. A press picks the line's voice for side 2 and makes the key the voice's held step (it toggles at its release); a second key of the line sets the held step's level; a 0.3 s hold opens the step editor and its release closes it (`docs/notes/lua/grid-core.md`, Step keys). Every step lights `S.lib.lanes.hit_light` (`step_brightness` but in move, where a hit lights its value A); the picked voice's empty steps that would be dark light 1 inside its length, and stay dark past it, so the length shows (the controller's ruling for 3b's review). On a 64 the half shown draws its eight.

**Side 2**, the picked voice:

- **Line 1, the hits**: a tap toggles, a 0.3 s hold opens the step editor, and a second key sets the held step's level from its place (`level_for_position`), in move its value A (the level stays its strength). Lit by `hit_light`.
- **Lines 2-6, the lanes** (value A, value B, chance, repeats, gate; `S.lib.lanes.LANES` in order). A second key sets the held cell: value A and B the level; chance `round(level × 100 / 15)`; repeats `max(1, round(position × 4 / positions))`; gate the level's place of fifteen equal steps on `v<i>_seq_gate_length`'s spec (`spec:map((level - 1) / 14)`). The value set is the port's last for that lane. A tap clears a cell that holds a value, and gives an empty one the port's last value for the lane (before any: 15 for value A and B, 53 for chance, 2 for repeats, the voice's gate length for gate). Lights: value A and B their level; chance `max(1, round(prob × 15 / 100))`, 15 for a set step with no `prob`, dark for an empty one; repeats 4, 8, 11, 15; gate `1 + round(spec:unmap(gate) × 14)`. The cell the lane read last (a free lane's `S.lib.lanes.sounding`, a following lane's the hits' `sounding_step`, only while the voice plays) at 15 if it holds something and 4 if not; a cell past the lane's length (a free lane's own, a following lane's the voice's) at 1 if it holds something; where B names A's target (B not off and `S.lib.lanes.target(v, "b")` nil) value B's cells that hold something light 2 and the rest are dark.
- **Line 7, the utility line**: x 1 `pulse`, 2 `move`, 3 `accent` (`choose_mode`; lit by `mode_level`: the mode 15, the others 4, a `gate` voice's `pulse` 8); x 4 `LN` (armed 15, else 4); x 5-8 the targets position, pitch, size, cutoff (A's 15, 10 while A is `auto`; B's option 8; the others 2): a tap sets A's through `choose_target`, and with `B` held (`press_as`, role `"patterns B"`) B's, B's own key setting B `off`; x 9 `B` (15 held, 8 while B has a target, 2 off); x 10-16 voices 1-7 (the picked one 15, the others 4): a tap picks. Every utility key acts at its press.
- **LN armed**: each lane line lights 8 up to its length (the hits up to the voice's `seq_length`), a following lane 3 up to the voice's; the next press of a lane's line (lines 1-6) is consumed and sets that lane's length to its x (`set_length`, nil when x is its length already; line 1 the voice's `seq_length`) and disarms. A held key's release taps and toggles nothing then. The utility keys act as ever while armed.

**The step view** (3.9's 3c, design section 4; the machine: `docs/notes/lua/grid/keys.md`, `step view`). While the step editor is open from a key of the port and the pane shows side 2 (the key's own pane if it does, else a 256's other pane), lines 1-6 are bars for the editor's voice and step: line 1 its level (dark while it is off), lines 2-6 its value A, value B, chance, repeats and gate as side 2's cells show them (chance 100 for a set step with no `prob`; nil dark). Each lights `STEP_VIEW.lit` (10) from the first key shown to its value's key, the first position (1..the keys shown) whose `value_for_position` is at least the value, and is dark beyond; line 7 is dark. A press on a bar sets the value from its position as side 2's second key does (line 1 the level by `level_for_position`, in every mode; a lane by `set_from_position`, kept as the port's last for the lane); a press on a lane's own value key clears the cell (value A and B none, chance 100, repeats 1, gate the voice's; all nil). Line 1 never clears. A free lane's bar is dark and its keys do nothing; line 7's keys do nothing. A held lane cell opens nothing: only the hits keys (side 1, side 2's line 1) are step keys. On a 64 the bars span the half shown, eight keys.

Utility keys x 5-8 are the targets only below `B`'s x (`x < b_x`). On a 64, side 2's left half shows the modes, `LN` and the targets, its right half `B` and the voices: target B cannot be set from an 8×8's grid (`B` and the targets are never shown together).
