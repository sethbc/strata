## Must not break

- **Every key goes through its owner**: MU and SO toggle `v<v>_mute` and `v<v>_solo` through `set_binary_param` (a MIDI map echoes them, #538; a mute silences in the mix stage and never stops a voice); LK is `toggle_lock(v)` (lock guards against randomize, drift, mutation and scatter, never against an edit, so a sound copied onto a locked voice loads); FZ is `S.lib.freeze.toggle_quantized(v)` (it waits for the beat or bar `quantize_actions` names, and a second press while it waits takes it back) and its LED reads `S.lib.freeze.is_frozen(v)`, frozen or not, and blinks (`grid_core.waiting_level()`) while the voice's set waits (`S.lib.freeze.waiting(v)`, #876, #1031); CL and RN are `clear_pattern(v)` and `randomize_pattern(v)`; a paste is `S.lib.sequencer.replace_pattern(v, steps)`; a voice copy is `S.lib.voice_presets.copy(mark, v)`. The page sends no engine command and sets no param directly.
- **CL and RN act at their hold only**: the press arms `pane.on_hold(x, v, VOICES_PAGE.hold_seconds, ...)`, which runs the operation, `grid_redraw()` and `request_redraw()`; a release before it, a page change of the pane (`end_pane_keys`, ruling 54) or the grid's removal cancels it, and nothing asks for a redraw while it is pending. `hold_seconds` is `GRID_HOLD.action_hold_seconds` (0.5 s), the grids' half-second hold, which a gesture recorder's clear waits too.
- **A paste ends the pasted voice's step gestures on every grid** (`replace_pattern` calls `end_step_gestures`): a step held from before takes no level in the pasted pattern and toggles nothing at its release. A paste carries the whole pattern (3.9's 4a): `S.lib.sequencer.replace_whole` writes the levels through `replace_pattern`, then the voice's step attributes (`S.pattern_steps[v]`: prob, cond, ratchet, notes, the locks, gate, slice, the values) and its lane lengths, and leaves its `seq_*` params as they are; it ends the voice's overrides (a playing step lock, note or value) and asks the gate rule.
- **A lock guards the voice's sound, not its pattern** (`docs/notes/lua/mutation.md`: lock covers params, not patterns, as in 3.7): CL, RN and a paste act on a locked voice's pattern and VC loads into it; tests pin each, so a change of the lock's reach is a decision.
- **The two copies are per port, in `pane.state()`** (`port_state(port).pages.voices`): `patterns = {voice, pattern}` (the pattern a snapshot taken at the copy press, `S.lib.sequencer.whole(voice)`: levels, steps and lanes) and `sound = {voice}` (only the mark: the sound is read at the paste, by `copy`). They survive a page change of either pane, a 256's two panes on the page share them, and they go with the grid (`forget_port`). A press on the copied or marked voice's key is the only way to drop one.
- **A refused voice copy changes nothing**: `copy` returns false (its own flash on VOICE), the mark stays and the target's key stays at 4.
- **The level is a fader line** (`faders(pane)`: line v, `first` 9, eight keys, `v<v>_amp`, the voice's level, ruling 58) set and drawn by the pane engine alone; the page's `press` and `redraw` never see x 9-16 while the line is shown. A voice with no `v<v>_amp` param gets no line (its keys 9-16 are dark and dead).
- **Every key, level and hold is `VOICES_PAGE`'s** (ruling D4); the numbers in the file are pane coordinates and the named levels.
- **`signature(pane)`** on side 1 is each voice's lock and the two copies' voices: the lock redraws from `toggle_lock` and the copies from the press (`grid_key`), but a scene recall's lock entry sets `S.locked` with no redraw until the recall ends, so the drift tick's follow covers it. Mute, solo and freeze have no term: their params' actions always redraw the grids (`lib/voice_mix.lua`, `lib/freeze.lua`; a test pins it). On side 2 it is fill and, per voice, the letter played and those used, the order and whether it is on, LP's level, the roll's rate and the mode, so a change no key repainted (a scene recall's letters, a mode set on SEQ, a loop a length cut) shows by the drift tick.
- **Index checks**: a press needs a whole y in 1..`NUM_VOICES`; on side 1 z 1 and a whole x in 1-8, on side 2 a whole x in 1-16 (a release acts for `OR` and `FL` only); anything else does nothing. Every action takes the checked voice.
- **Side 2 has no fader line** (`faders(pane)` is empty there), so x 9-16 reach the page's `press` and `redraw`.
- **Nothing on the perform side outlives its key**: a roll is `S.lib.loop_roll.roll(v, rate, pane.still(x, v))`, and its key's release calls nothing: the press token goes after the page sees the release, so the roll reads as ended (`rolling` nil) once the key is up and its clock ends it at its next hit, playing nothing. A roll another key started since (another rate, another grid) asks only its own key, so a release never ends it; the rate alone cannot tell two grids' keys apart. A press's state on the perform side is per port and pane (the controller's ruling for 5c's review): `FL` holds fill under `"grid:<port>:<pane>:<line>"`, so two panes' FL keys never end each other's hold, with its own `pane.still` (a page change or an unplug drops it at the next LFO step); its release ends that holder only when the key was pressed as `FL` (`press_as`). `OR`'s order being built is kept for its pane, `pane.state().orders[pane][v]`, with `OR`'s own `still`, read only while that still holds: the other pane's letters switch as ever and its `OR` starts a build of its own; only `OR`'s release, pressed as `OR` on that pane, sets it.
- **The waiting letter blinks through the core's blink** (`S.lib.grid_core.waiting_level()`): the core's `blink_signature` counts `"letter <v>"` while a pane shows this page's side 2 and a freeze only while one shows side 1 (`docs/notes/lua/grid-core.md`, LEDs); no param action repaints for a wait.

## Owns

- `lib/grid/pages/voices.lua` (`S.lib.grid_pages_voices`): its record (`M.record`, two sides, fader lines on side 1 and a `signature`), registered at `GRID_PAGES.voices`, `M.VOICES_PAGE` (`keys`, `level_first` 9, `level_keys` 8, `hold_seconds`, `levels`) and `M.PERFORM` (side 2's `keys`, `modes`, the roles `"perform order"` and `"perform fill"`, `levels`).
- Unit tests: `test/unit/grid_pages_voices_test.lua`, on every arrangement of the pane harness that shows the keys each test needs, with the tests 0e handed on (the 256's copy and paste, clear and randomize, lock, freeze and mute keys, the 128h's and 128v's lock and freeze keys, and the solo part of `grid_core_test.lua`'s "a page change cancels the port's pending holds", as CL's and RN's holds) re-added in pane coordinates.

## Keys and LEDs (design §10.8)

Side 1: line v is voice v (1-7); every key acts at its press but CL and RN, which act at their hold; a release does nothing.

| x | Key | Press | Hold | LED |
|---|---|---|---|---|
| 1 | MU | `v<v>_mute` toggled (`set_binary_param`) | - | 15 muted, 4 |
| 2 | SO | `v<v>_solo` toggled (`set_binary_param`) | - | 15 soloed, 4 |
| 3 | LK | `toggle_lock(v)` | - | `lock_level(v)` 12 / 2 |
| 4 | FZ | `S.lib.freeze.toggle_quantized(v)` | - | 15 frozen, 3; blinking (`grid_core.waiting_level()`) while the voice's set waits (`S.lib.freeze.waiting(v)`, #876, #1031) |
| 5 | CL | `pane.on_hold(5, v, hold_seconds, ...)` | 0.5 s: `clear_pattern(v)`, grids and screen redrawn | 15 pending (`pane.hold_pending`), 2 |
| 6 | RN | the same | 0.5 s: `randomize_pattern(v)` | 15 / 2 |
| 7 | PC | no copy: copy v's whole pattern (`whole(v)`); another voice's copy: `replace_whole(v, pattern)` (the copy stays); the copied voice: drop it | - | 15 the copied voice, 4 the others while a copy exists, 2 with none |
| 8 | VC | no mark: mark v; another voice's mark: `voice_presets.copy(mark, v)` (the mark stays); the marked voice: drop it | - | 15 / 4 / 2 |
| 9-16 | lv | a fader line of 8 keys, `v<v>_amp` (the pane engine's) | - | bar 8, value 15 |

`copy` captures the marked voice's sound at the paste, loads it into v (its type, its type's synth keys and the library's sound keys) and keeps v's place, lets go of v in a running scene fade (`S.lib.scenes.release_voice`) and holds the one undo, which ALT+K2 on VOICE on that voice puts back (`S.lib.mutation.hold_voice`). The page has no undo key.

The 256's lower strip's mute keys (M1-M7, the pane engine's) and MU are one action in two places. Turned (the 128v), each voice's eight keys run down rows 1-8 of its column and its level up rows 9-16 (row 16 the minimum). On a 64 the left half (x 1-8) is the eight keys and the right half (x 9-16) the level fader across its eight keys; the copies are the port's, so a mark made on the left half is still shown after a switch to the right and back.

## The perform side (side 2; 3.9's 5c, design section 4)

The page's lit key pressed again (the 8×8's chooser rows 3 and 4) shows it. Line v is voice v; every key acts at its press but `OR` and `FL`, which act at their release too.

| x | Key | Press | Release | LED |
|---|---|---|---|---|
| 1, 2 | MU, SO | as side 1's | - | 15 on, 4 |
| 3-6 | A-D | `S.lib.pattern_letters.switch(v, letter)` (it waits for the bar while the patterns play; a second tap of the waiting letter switches at once; it turns the order off); while `OR` is held, the letter is added to the order built (up to `VARIATIONS.max_order`, eight) and nothing switches | - | the waiting letter blinks (`waiting_level()`), 15 the playing one, 4 a used one (`used`), 2 one never used |
| 7 | OR | pressed as `"perform order"`: a new order, empty | with a letter tapped: `set_order(v, letters)` (on, from its first letter at the next bar); with none: `set_order_on(v, not on)` | 10 while held, 15 on, 4 an order kept off, 2 none |
| 8 | LP | `S.lib.loop_roll.press_latch(v)` | - | 15 latched, 6 a loop held and not latched, 10 armed with no loop, 2 off |
| 9-12 | R1-R4 | `roll(v, rate, pane.still(x, v))`, rate 1-4 (with the patterns stopped nothing) | nothing (the key's still ends its own roll) | 15 while `rolling(v)` is its rate, 4 |
| 13-15 | PU, MV, AC | `S.lib.lanes.choose_mode(v, "pulse" / "move" / "accent")` | - | `S.lib.grid_pages_patterns.mode_level(v, name)`: the mode 15, the others 4, a `gate` voice's pulse 8 |
| 16 | FL | pressed as `"perform fill"`: `hold_fill("grid:<port>:<pane>:<v>", true, pane.still(x, v))` | pressed as `FL`: `hold_fill(holder, false)` | 15 while fill is on (`S.lib.conditions.fill()`, however it was turned on), 4 |

Each pane's and line's `FL` has its own holder, so letting one go leaves another line's hold, the other pane's, the strip's FL and the latch. On the 8×8 the left half is MU, SO, the letters, `OR` and `LP` (so an order is built in one half), the right half the rolls, the mode keys and `FL`. Turned (the 128v), each voice's sixteen keys run down its column.

Test: `test/unit/grid_pages_voices_test.lua`, from "the lit page key flips to the perform side" to "the 64 shows mutes, letters, OR and LP on the left half and the rolls, the mode and FL on the right", on every arrangement that shows the keys each needs; the blink's gate is `test/unit/grid_core_test.lua`'s "a waiting letter blinks only on the voices page's side 2, a waiting freeze only on its side 1".
