## Must not break

- **Every key goes through its owner**: MU and SO toggle `v<v>_mute` and `v<v>_solo` through `set_binary_param` (a MIDI map echoes them, #538; a mute silences in the mix stage and never stops a voice); LK is `toggle_lock(v)` (lock guards against randomize, drift, mutation and scatter, never against an edit, so a sound copied onto a locked voice loads); FZ is `S.lib.freeze.toggle_quantized(v)` (it waits for the beat or bar `quantize_actions` names, and a second press while it waits takes it back) and its LED reads `S.lib.freeze.is_frozen(v)`, the state, never the wait; CL and RN are `clear_pattern(v)` and `randomize_pattern(v)`; a paste is `S.lib.sequencer.replace_pattern(v, steps)`; a voice copy is `S.lib.voice_presets.copy(mark, v)`. The page sends no engine command and sets no param directly.
- **CL and RN act at their hold only**: the press arms `pane.on_hold(x, v, VOICES_PAGE.hold_seconds, ...)`, which runs the operation, `grid_redraw()` and `request_redraw()`; a release before it, a page change of the pane (`end_pane_keys`, ruling 54) or the grid's removal cancels it, and nothing asks for a redraw while it is pending. `hold_seconds` is `GRID_HOLD.scene_save_seconds` (0.5 s): its name is historical (3.7's half-second scene save, which 3.8's SV key replaced) and it is the grids' half-second hold; a rename is left to a package that owns `lib/constants.lua` and the other pages.
- **A paste ends the pasted voice's step gestures on every grid** (`replace_pattern` calls `end_step_gestures`): a step held from before takes no level in the pasted pattern and toggles nothing at its release. A paste carries the step levels only: `replace_pattern` writes `S.patterns[v]` and leaves the voice's step attributes (`S.pattern_steps[v]`: prob, cond, ratchet, notes, the locks, gate, slice) and its `seq_*` params as they are, and it ends the voice's overrides (a playing step lock or note).
- **A lock guards the voice's sound, not its pattern** (`docs/notes/lua/mutation.md`: lock covers params, not patterns, as in 3.7): CL, RN and a paste act on a locked voice's pattern and VC loads into it; tests pin each, so a change of the lock's reach is a decision.
- **The two copies are per port, in `pane.state()`** (`port_state(port).pages.voices`): `patterns = {voice, steps}` (the steps a snapshot taken at the copy press, `PATTERN_LENGTH` of them) and `sound = {voice}` (only the mark: the sound is read at the paste, by `copy`). They survive a page change of either pane, a 256's two panes on the page share them, and they go with the grid (`forget_port`). A press on the copied or marked voice's key is the only way to drop one.
- **A refused voice copy changes nothing**: `copy` returns false (its own flash on VOICE), the mark stays and the target's key stays at 4.
- **The level is a fader line** (`faders(pane)`: line v, `first` 9, eight keys, `v<v>_amp`, the voice's level, ruling 58) set and drawn by the pane engine alone; the page's `press` and `redraw` never see x 9-16 while the line is shown. A voice with no `v<v>_amp` param gets no line (its keys 9-16 are dark and dead).
- **Every key, level and hold is `VOICES_PAGE`'s** (ruling D4); the numbers in the file are pane coordinates and the named levels.
- **`signature(pane)`** is each voice's mute, solo, lock and freeze, and the two copies' voices: mute, solo and freeze redraw the grids from their params' actions, the lock from `toggle_lock`, the copies from the press (`grid_key`), but a scene recall's lock entry sets `S.locked` with no redraw until the recall ends, so the drift tick's follow covers it.
- **Index checks**: a press needs z 1, a whole x in 1-8 and a whole y in 1..`NUM_VOICES`; anything else does nothing. Every action takes the checked voice.

## Owns

- `lib/grid/pages/voices.lua` (`S.lib.grid_pages_voices`): its record (`M.record`, one side, fader lines and a `signature`), registered at `GRID_PAGES.voices`, and `M.VOICES_PAGE` (`keys`, `level_first` 9, `level_keys` 8, `hold_seconds`, `levels`).
- Unit tests: `test/unit/grid_pages_voices_test.lua`, on every arrangement of the pane harness that shows the keys each test needs, with the tests 0e handed on (the 256's copy and paste, clear and randomize, lock, freeze and mute keys, the 128h's and 128v's lock and freeze keys, and the solo part of `grid_core_test.lua`'s "a page change cancels the port's pending holds", as CL's and RN's holds) re-added in pane coordinates.

## Keys and LEDs (design §10.8)

Line v is voice v (1-7); every key acts at its press but CL and RN, which act at their hold; a release does nothing.

| x | Key | Press | Hold | LED |
|---|---|---|---|---|
| 1 | MU | `v<v>_mute` toggled (`set_binary_param`) | - | 15 muted, 4 |
| 2 | SO | `v<v>_solo` toggled (`set_binary_param`) | - | 15 soloed, 4 |
| 3 | LK | `toggle_lock(v)` | - | `lock_level(v)` 12 / 2 |
| 4 | FZ | `S.lib.freeze.toggle_quantized(v)` | - | 15 frozen, 3 |
| 5 | CL | `pane.on_hold(5, v, hold_seconds, ...)` | 0.5 s: `clear_pattern(v)`, grids and screen redrawn | 15 pending (`pane.hold_pending`), 2 |
| 6 | RN | the same | 0.5 s: `randomize_pattern(v)` | 15 / 2 |
| 7 | PC | no copy: copy v's steps; another voice's copy: `replace_pattern(v, steps)` (the copy stays); the copied voice: drop it | - | 15 the copied voice, 4 the others while a copy exists, 2 with none |
| 8 | VC | no mark: mark v; another voice's mark: `voice_presets.copy(mark, v)` (the mark stays); the marked voice: drop it | - | 15 / 4 / 2 |
| 9-16 | lv | a fader line of 8 keys, `v<v>_amp` (the pane engine's) | - | bar 8, value 15 |

`copy` captures the marked voice's sound at the paste, loads it into v (its type, its type's synth keys and the library's sound keys) and keeps v's place, lets go of v in a running scene fade (`S.lib.scenes.release_voice`) and holds the one undo, which ALT+K2 on VOICE on that voice puts back (`S.lib.mutation.hold_voice`). The page has no undo key (`S.lib.mutation.undo_voice` is not called).

The 256's lower strip's mute keys (M1-M7, the pane engine's) and MU are one action in two places. Turned (the 128v), each voice's eight keys run down rows 1-8 of its column and its level up rows 9-16 (row 16 the minimum). On a 64 the left half (x 1-8) is the eight keys and the right half (x 9-16) the level fader across its eight keys; the copies are the port's, so a mark made on the left half is still shown after a switch to the right and back.
