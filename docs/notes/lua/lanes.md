## Must not break

- **A step's level is its strength in every mode, and its value A is a field of its own** (`va`; value B is `vb`): no field means two things, and a change of mode reinterprets nothing. In `move` a hit adds no swell (`docs/notes/lua/sequencer/modes.md`), and its level stays what it is; after a change to another mode the same step swells at its level, its `va` untouched.
- **A value is a base override, as a lock is, and it stays** (`lib/sequencer.lua`'s `held_values`, read through `S.lib.sequencer.held_value(voice, target)`). At a played hit, each of lanes A and B whose target (`target`) is set and whose read at the tick holds a value (`last_read`, 2c) is set on its param and recorded; a hit without one sends nothing for it, so the value holds through any number of plain steps. A hit a condition or a chance holds back sets nothing. It ends, the override cleared and the record with it, only: at the next hit that sets the same target (the new value takes its place); at a stop of the patterns; at any set of the param the sequencer does not make, a hand edit's included (fx2, #1047, the maintainer's rule: `S.lib.sequencer.param_set`, which every voice param's action calls after its send, so a morph, a transition, OSC, a MIDI map, a mutation step, a randomize or its undo is heard; norns runs an action only when the value changes, so a voice's start or sync, which sends without setting, ends nothing; the drift's writes, under `S.drift_writing`, end nothing: the script's own wander walks under the value, as an LFO never sets its destination, the controller's ruling; a lock of the last played step keeps its step, as before; the sequencer's touch hook, for an edit that runs no action, drops a record still there); at `replace_pattern` (a clear, a randomize, a recall, a chain link); at a change of a target, of the mode, of the source (one call in `lib/voices.lua`'s `v<i>_source` action, before its hooks and outside their recall guard, so a morph's switch, which sets the source inside a recall's setting, ends them too: fix round 1, in place of ruling 2a-1's `S.register_source_change`) or of the type (one call in `lib/voices.lua`'s `type_changed`, ruling 2a-1); at a jump, for a position value (`S.lib.positions.jump` calls `end_held_value(voice, "position")` before its `params:set`, so the grid's position page, `recall_bookmark` and a step's bookmark are heard at once, and a step's own bookmark wins over that step's value); at the end of a pass that leaves the voice no set step; and at a length cut below the step that set it (not merely below the last played step: a value from step 1 outlives a cut to 4 after step 9); and, for a pitch value, when a MIDI note lands on the voice's own note (`own_note_taken` ends it, 2b).
- **The sequencer keeps the held values apart from `overrides`** (the last played step's locks and note), and `apply_step`'s clearing loop spares them: an override of the last step this one lacks ends through `values.release`, which sets a held value on that param again (the lock's end: the value comes back) or clears it. A lock on the same param wins for its own step; where a held value ends while a lock holds its param, the override stays the lock's, and at the lock's end there is no value to bring back.
- **Where A and B name one target, A's value is set and B's lane does nothing** (`target(voice, "b")` is nil then).
- **Neither param's own action does the hand's extras**: only `choose_mode` gives a move voice's set steps their random values, and only `choose_target` opens a closed filter (mix 0 to 1, the flash `filter on`), so a recall, a PSET or a scene's transition that sets `move` or `cutoff` changes no step and leaves a stored mix of 0. The params' own actions end the voice's held values and nothing else (the mode's also resends a gated voice's gate length, as before).
- `toggle_pattern_step` turning a step on in `move` gives it `va = math.random(1, MAX_STEP_LEVEL)` where it has none, and keeps one it has; turning it off keeps it.
- **Pitch is a value on the note path** (2b): `value(voice, "pitch", level)` is `S.lib.sequencer.note_value(voice, level - 8)`, the voice's own pitch (its note param's stored value) moved by `level - 8` degrees through `degree_semitones` (the tuning's steps), clamped to the param's range, on the param a step's note moves for the source (`note_param`: a synth voice's `v<i>_freq`, a buffer voice's `v<i>_buf_rate`, an input voice's `v<i>_grain_pitch`). Level 8 is the voice's own pitch. It is set through `set_override`, so a synth voice's `scaleNote` is resent once where a step's note resends it, and never sent again while it holds. A synth voice's pitch value is heard through its ring, behind the write head by the lookback (the grains' position spread), as a step's note is.
- **A step's note and chord count their degrees from the pitch value the step stands on** (`values.pitch_level`: the step's own pitch value, else the held one), the sum clipped to -14 to 14 before `degree_semitones` (which gives nil past 14), so the event's `semitones` and `pitches` and the chord's notes all sit on the value. On an input voice a `pitch` lock is the note's own param: the lock wins for its step (the value adds no degrees there, and the lock is the chord's base), and when it ends the value comes back. On a synth or buffer voice the lock is on the grain pitch and the value on freq or rate: the two add, as a note and a pitch lock add.
- **A pitch value gives way to a held MIDI key** (2b): while a MIDI key down holds the voice's own note (`other_owns_slot_1`, so a latched key gives way to the step as for a step's note), a hit's pitch value is neither set nor recorded, and `own_note_taken` ends a held one when a MIDI note lands on slot 1, so MIDI's pitch plays. Nothing brings it back but the next hit that sets one; the key's release does not. A first note that ends up an extra note (`end_note_override`) gives the param back to the held pitch value, not to the stored value.
- Position's values are fractions of the voice's loop, as `v<i>_buf_pos` is (`docs/notes/engine/loops.md`: the engine starts a grain at `loopStart + bufPos × loopLength`), so level 1 is the loop's start and 15 its end whatever the loop; size and cutoff are the param's own scale (`controlspec:map`). Nothing here sends: a value reaches the engine only as a base override (`set_override`, so a synth voice's freq resends `scaleNote`).
- **A lane with no length follows; a lane with a length of 1 to 16 is free** (2c, design section 2, Following and free). The five lanes (`LANES`: `a`, `b`, `chance`, `repeats`, `gate`) have the sixteen steps' own keys as their cells (`STEP_KEYS`: `va`, `vb`, `prob`, `ratchet`, `gate`), so no lane has a second store. A following lane is read at the step the hit plays, whatever the direction, the misstep or the hits' length, exactly as before 2c. A free lane is read at its own position, which `start` puts at 1 on every `start_position` (a pattern start, a restart, a division reset's bar, a stop, and the include's `end_clocks`, so the module is included before the sequencer and `start` reads nothing of it) and `advance` moves forward by one, wrapping at its length, on every tick the voice takes: a played one (`begin_voice_step`, right after the tick's reads) and a skipped one (`skip_due_ticks`, after `take_position`). A free lane never takes the direction, the misstep or the hits' length.
- **Each lane is read once a tick, at its begin** (`read`, which records the cell it read: `sounding`), and the rest of the tick reads that cell through `last_read` (the value the cell holds now), after `advance` has moved the position on: the chance draw, the ratchet's count, `values.take` and `values.pitch_level` for A and B, the gate's `gate_beats` and `gateSeconds` at every hit (`M.gate_seconds` with a step), a ratchet's later hits included. So a ratchet's hits share their step's cell, and an edit of that cell between them is heard at the next hit, as an edit of a step was before 2c. A tick on a step with no level reads too, so `sounding` is every tick's cell (the lights); a skipped tick reads nothing. A held value's `step` is the step played, whatever cell it came from, so a length cut ends it by that step.
- **The passes are the hits'**: `A:B`, `first`, a waiting length and the ends of a step's holds read the hits' position and pass, whatever the lanes' lengths. A step's condition, locks, note, bookmark and slice are no lanes: they are read at the step played.
- **A length set** (`set_length`): a following lane freed starts at 1; a free one keeps its position, and wraps to 1 when the new length is below it; `nil` makes it follow (its position is dropped). A length that is no whole 1 to 16, a lane that is none (`hits` among them: its length is the voice's `seq_length`) or a voice out of range does nothing. A change ends the voice's pattern undo (`note_pattern_edit`, as a step's edit does) and redraws the grid; `set_lengths` sets all five (a lane it does not name, or names with no whole 1 to 16, follows).
- **The lengths are a pattern's, in the scene block `lanes`** (design section 6): per voice a table of the free lanes' lengths by name; its default, seven empty tables, so a scene without the block follows everywhere; its check refuses a name that is no lane, a length that is no whole 1 to 16, a voice out of range and a voice missing. A recall applies it (to every voice but a fade's released ones, which keep their lengths: `apply_block`'s `skip`, #1050) before the `steps` block (`apply_block`: a recall applies the blocks in their registry's order, and `lib/lanes.lua` is included, and registers its block, before `lib/sequencer.lua`) and a chain link does too (`load_chain_scene`, ruling 2c-2, calls `apply_block` before `set_all_steps`; nothing depends on the order, which the tests keep); a chain start's undo holds and puts back the lengths with the patterns (`lib/mutation.lua`'s `capture_patterns`, ruling 2c-3). A clear, a randomize and `replace_pattern` leave them, as they leave a step's settings; a paste (the voices page's PC), a letter's switch and the chain start's undo bring their pattern's own (4a: `S.lib.sequencer.replace_whole` calls `set_lengths`); voice presets and PSETs carry none (PSETs only through their scenes).

## Machines

### held values
- **State:** voice 1's held value on its position target (`S.lib.sequencer.held_value(1, "position")`) and whether the engine starts from it (`S.lib.engine_sync.engine_base_value("v1_buf_pos")` is its value) or from a lock of the last played step over it: `none`, `a value`, `a lock over a value`; then (2b) its held pitch value, heard (`a pitch value`: `v1_freq`'s base is its value), and a MIDI key down holding its own note with no value (`a held key`). `none` may hold a lock, which is the sequencer's `overrides` (`docs/notes/lua/sequencer.md`, step holds).
- **Invariant:** none of its own: `step holds` (`docs/notes/lua/sequencer.md`) holds it: stopped, no voice holds a value, and every held value's param has a base override (its own, or a lock's over it), so a record never outlives its value.
- **Test:** `test/unit/lanes_test.lua`: "held values: none + hit with a value" (one test a row), and the named tests beside them ("a value ends at a stop, a hand edit, ...", "a lock wins for its step and the value comes back", "a length cut past a lock but not past the value brings the value back", "a jump ends a held position value: ...", "a morph that switches the source ends the held value", fx2's "OSC's /param on a held pitch value ends it, ...", "a morph moving a held position ends the value, ...", "a transition's write of a held position ends the value at its first step", "a voice's stop and start, and its sync, end no held value: ..." and "the drift ends no held value: ...", and 2b's "pitch level 8 is the voice's own pitch, ...", "a pitch value resends scaleNote once", "a pitch value gives way to a held MIDI key and comes back at the next hit that sets it", "on a synth voice a pitch lock adds to a pitch value; on an input voice it wins"; `test/unit/sequencer_test.lua`'s "a chord sits on a held pitch value" and "a value of +7 under a note of +14 plays degree 14").

Each state is a fresh script: voice 1 reading buffer 1 at position 0.2, length 8, steps 1 to 4 set and played (step 3 with `va` 15 for `a value`, and step 4 with a position lock of 0.6 for `a lock over a value`). The hits are step 5's: `hit with a value` (`va` 8, position 0.5), `hit without` (no value, no lock: in `a lock over a value`, the lock's end), `hit with a lock` (0.6), `held back` (`va` 8 at a chance of 0). The ends: `stop`, `hand edit` (an encoder's detent on `v1_buf_pos`: 0.21), `replace`, `target change` (A to size), `mode change` (to accent), `source switch` (buffer 2), `type switch`, `empty pass` (from step 4 the steps turned off one by one, a tick apart, the value's own step 3 first, then the wrap), `length cut` (to 2). A source or type switch syncs the running voice, which sends the position it starts from again. Each row checks the position sent last and the one the engine starts from; the four rows where a value ends under a lock also follow the lock to its end (a hit without), which sends 0.2. 2b's states make voice 1 a synth voice at 220 Hz instead (the scale off, so a degree is a semitone): `a pitch value` is step 3's `va` 15 there, 329.63 Hz (seven up), and `a held key` is that and then MIDI note 62 down on voice 1's channel (293.66 Hz, the key's own pitch, now the stored freq: apart from the value's, so a value left under the key shows). Its events: `MIDI key` (note 62 down), `MIDI release` (note 62 up: in the default latch mode the note sounds on, its key up, so it no longer keeps the own note), `chord` (step 5 with notes 0 and 2), `freq edit` (an encoder's detent on `v1_freq`) and `hit with a pitch lock` (step 5 with a `pitch` lock of 1.5, which on a synth or buffer voice is the grain pitch's, not freq's). Their rows check the freq sent last and the one the engine plays; `hit with a value` there is level 8, the voice's own 220 Hz. fx2's events (#1047) set the param the state's voice holds its value on (`v1_buf_pos` to 0.21 on the buffer voice, `v1_freq` to 300 Hz on the synth voice) from outside the sequencer: `OSC set` (`/param/<id>`, norns' own handler), `MIDI map` (a CC of 27 on a PARAMS > MAP mapping, norns' `set_raw`), `scene set` (`S.lib.scenes.set_value`, a morph's and a transition's setter), `drift` (one `drift_update`: the position and the grain pitch walk) and `mutation step` (one `gentle_mutate` at probability 1).

| State | Event | Next | Effect |
|---|---|---|---|
| `none` | `hit with a value` | `a value` | 0.5 sent |
| `none` | `hit without` | `none` | nothing sent |
| `none` | `hit with a lock` | `none` | the lock's 0.6 |
| `none` | `held back` | `none` | nothing sent |
| `none` | `stop` | `none` | nothing sent |
| `none` | `hand edit` | `none` | 0.21 |
| `none` | `replace` | `none` | nothing sent |
| `none` | `target change` | `none` | nothing sent |
| `none` | `mode change` | `none` | nothing sent |
| `none` | `source switch` | `none` | the sync's 0.2 |
| `none` | `type switch` | `none` | the sync's 0.2 |
| `none` | `empty pass` | `none` | nothing sent |
| `none` | `length cut` | `none` | nothing sent |
| `a value` | `hit with a value` | `a value` | replaced: 0.5 |
| `a value` | `hit without` | `a value` | nothing sent: it stays at 1 |
| `a value` | `hit with a lock` | `a lock over a value` | the lock wins: 0.6 |
| `a value` | `held back` | `a value` | nothing sent |
| `a value` | `stop` | `none` | 0.2 |
| `a value` | `hand edit` | `none` | 0.21 |
| `a value` | `replace` | `none` | 0.2 |
| `a value` | `target change` | `none` | 0.2 |
| `a value` | `mode change` | `none` | 0.2 |
| `a value` | `source switch` | `none` | 0.2 (then the sync's) |
| `a value` | `type switch` | `none` | 0.2 (then the sync's) |
| `a value` | `empty pass` | `none` | 0.2 at the wrap |
| `a value` | `length cut` | `none` | 0.2 |
| `a lock over a value` | `hit with a value` | `a value` | the lock ends into the new value: 0.5, once |
| `a lock over a value` | `hit without` | `a value` | the lock's end: the value comes back, 1 |
| `a lock over a value` | `hit with a lock` | `a lock over a value` | 0.6 |
| `a lock over a value` | `held back` | `a lock over a value` | nothing sent |
| `a lock over a value` | `stop` | `none` | 0.2 |
| `a lock over a value` | `hand edit` | `none` | 0.21: the lock ends too |
| `a lock over a value` | `replace` | `none` | 0.2 |
| `a lock over a value` | `target change` | `none` | nothing sent: the lock holds its step; at its end 0.2 |
| `a lock over a value` | `mode change` | `none` | nothing sent: the lock holds its step; at its end 0.2 |
| `a lock over a value` | `source switch` | `none` | the sync's 0.6: the lock holds its step; at its end 0.2 |
| `a lock over a value` | `type switch` | `none` | the sync's 0.6: the lock holds its step; at its end 0.2 |
| `a lock over a value` | `empty pass` | `none` | 0.2 at the wrap |
| `a lock over a value` | `length cut` | `none` | 0.2: the value and the lock end |
| `none` | `MIDI key` | `a held key` | nothing sent |
| `none` | `MIDI release` | `none` | nothing sent: no key was down |
| `none` | `chord` | `none` | nothing sent |
| `a value` | `MIDI key` | `a value` | nothing sent: a position value does not give way |
| `a value` | `MIDI release` | `a value` | nothing sent |
| `a value` | `chord` | `a value` | nothing sent: it stays at 1 |
| `a lock over a value` | `MIDI key` | `a lock over a value` | nothing sent |
| `a lock over a value` | `MIDI release` | `a lock over a value` | nothing sent |
| `a lock over a value` | `chord` | `a value` | the lock's end: the value comes back, 1 |
| `a pitch value` | `hit with a value` | `a pitch value` | replaced: 220 Hz (level 8) |
| `a pitch value` | `hit without` | `a pitch value` | nothing sent: it stays at 329.63 Hz |
| `a pitch value` | `hit with a lock` | `a pitch value` | no freq sent: a position lock |
| `a pitch value` | `held back` | `a pitch value` | nothing sent |
| `a pitch value` | `stop` | `none` | 220 Hz |
| `a pitch value` | `hand edit` | `a pitch value` | no freq sent: another param |
| `a pitch value` | `replace` | `none` | 220 Hz |
| `a pitch value` | `target change` | `none` | 220 Hz |
| `a pitch value` | `mode change` | `none` | 220 Hz |
| `a pitch value` | `source switch` | `none` | 220 Hz |
| `a pitch value` | `type switch` | `none` | 220 Hz (then the sync's) |
| `a pitch value` | `empty pass` | `none` | 220 Hz at the wrap |
| `a pitch value` | `length cut` | `none` | 220 Hz |
| `a pitch value` | `MIDI key` | `a held key` | the value gives way: the key's 293.66 Hz |
| `a pitch value` | `MIDI release` | `a pitch value` | nothing sent: no key was down |
| `a pitch value` | `chord` | `a pitch value` | the chord sits on it: note 0 at 329.63 Hz, note 2 an extra note at 66 |
| `a held key` | `hit with a value` | `a held key` | nothing sent: the value gives way, nothing recorded |
| `a held key` | `hit without` | `a held key` | nothing sent |
| `a held key` | `hit with a lock` | `a held key` | no freq sent |
| `a held key` | `held back` | `a held key` | nothing sent |
| `a held key` | `stop` | `a held key` | nothing sent |
| `a held key` | `hand edit` | `a held key` | no freq sent |
| `a held key` | `replace` | `a held key` | nothing sent |
| `a held key` | `target change` | `a held key` | nothing sent |
| `a held key` | `mode change` | `a held key` | nothing sent |
| `a held key` | `source switch` | `a held key` | the sync's 293.66 Hz |
| `a held key` | `type switch` | `a held key` | the sync's 293.66 Hz |
| `a held key` | `empty pass` | `a held key` | nothing sent |
| `a held key` | `length cut` | `a held key` | nothing sent |
| `a held key` | `MIDI key` | `a held key` | nothing sent |
| `a held key` | `MIDI release` | `none` | nothing sent: the value does not come back |
| `a held key` | `chord` | `a held key` | no freq sent: the chord's first note gives way |
| `none` | `freq edit` | `none` | no position sent |
| `a value` | `freq edit` | `a value` | no position sent: another param |
| `a lock over a value` | `freq edit` | `a lock over a value` | no position sent |
| `a pitch value` | `freq edit` | `none` | the value ends: the edited freq sent last and played |
| `a held key` | `freq edit` | `a held key` | the edited freq sent last and played |
| `none` | `hit with a pitch lock` | `none` | no position sent |
| `a value` | `hit with a pitch lock` | `a value` | no position sent: it stays at 1 |
| `a lock over a value` | `hit with a pitch lock` | `a value` | the position lock's end: the value comes back, 1 |
| `a pitch value` | `hit with a pitch lock` | `a pitch value` | no freq sent: the lock adds on the grain pitch, 1.5 |
| `a held key` | `hit with a pitch lock` | `a held key` | no freq sent: the grain pitch's 1.5 |
| `none` | `OSC set` | `none` | the set 0.21 sent and played |
| `none` | `MIDI map` | `none` | the mapped position sent and played |
| `none` | `scene set` | `none` | the set 0.21 sent and played |
| `none` | `drift` | `none` | the walked position sent and played |
| `none` | `mutation step` | `none` | the mutated position sent and played |
| `a value` | `OSC set` | `none` | the value ends (#1047): the set 0.21 sent last and played |
| `a value` | `MIDI map` | `none` | the value ends: the mapped position sent last and played |
| `a value` | `scene set` | `none` | the value ends: the set 0.21 sent last and played |
| `a value` | `drift` | `a value` | the drift walks the stored position under the value: 1 still plays |
| `a value` | `mutation step` | `none` | the value ends: the mutated position sent last and played |
| `a lock over a value` | `OSC set` | `none` | the value ends, the lock keeps its step (0.6); at its end the set 0.21 plays |
| `a lock over a value` | `MIDI map` | `none` | the value ends, the lock keeps its step; at its end the mapped position plays |
| `a lock over a value` | `scene set` | `none` | the value ends, the lock keeps its step; at its end the set 0.21 plays |
| `a lock over a value` | `drift` | `a lock over a value` | the lock's 0.6 still plays |
| `a lock over a value` | `mutation step` | `none` | the value ends, the lock keeps its step; at its end the mutated position plays |
| `a pitch value` | `OSC set` | `none` | the value ends: the set 300 Hz sent last and played |
| `a pitch value` | `MIDI map` | `none` | the value ends: the mapped freq sent last and played |
| `a pitch value` | `scene set` | `none` | the value ends: the set 300 Hz sent last and played |
| `a pitch value` | `drift` | `a pitch value` | no freq sent: the drift walks the grain pitch, another param |
| `a pitch value` | `mutation step` | `none` | the value ends: the mutated freq sent last and played |
| `a held key` | `OSC set` | `a held key` | the set 300 Hz sent last and played |
| `a held key` | `MIDI map` | `a held key` | the mapped freq sent last and played |
| `a held key` | `scene set` | `a held key` | the set 300 Hz sent last and played |
| `a held key` | `drift` | `a held key` | no freq sent |
| `a held key` | `mutation step` | `a held key` | the mutated freq sent last and played |

### lane position
- **State:** voice 1's lane A (2c): `following` (no length: `length(1, "a")` and `position(1, "a")` are nil), or free with a length of 5 and its position (the cell its next read reads): `free at 1`, `free inside` (cell 3), `free at its end` (cell 5).
- **Invariant:** none of its own: the position is written only by `set_length` (1, or 1 when the new length is below it), `start` (1) and `advance` (`position % length + 1`), so it stays inside 1 to the length, which the table's `state_of` checks at every row ("free outside its length" is no state).
- **Test:** `test/unit/lanes_test.lua`: "lane position: following + tick played" (one test a row), and the named tests beside them ("a free lane keeps its own position", "a free lane moves on a skipped tick", "a free chance lane is drawn at its own cell", "a free repeats lane ratchets at its own cell", "a free gate lane sets gateSeconds from its own cell", "conditions count the hits' passes whatever the lanes' lengths", "sounding is the cell last read", "the lanes block fills an old scene with no lengths, ...", "set_lengths makes a lane it names badly follow", "a chain link applies the lane lengths, before the steps", "a recall applies the lanes block before the steps block"; and `test/unit/mutation_test.lua`'s "a chain start's undo puts the lane lengths back (2c)" and "a chain start that changes only a lane length holds its undo (2c)").

Each state is a fresh script, voice 1 reading buffer 1 with all sixteen steps set, the patterns started (tick 1 played, at step 1); the free states set lane A's length to 5 then (it starts at 1), then play none, two or four ticks more. The events: `tick played` (the voice's next tick), `tick skipped` (its next wake held back a step: the tick due is skipped and the next one played), `voice started` (the patterns stopped and started again: `start_position`, then tick 1), `length set` (8), `length set below` (2) and `set back to following` (nil). Each row checks the cell lane A read last (`sounding`) and the step the hits played, or the length. Two cells cannot happen: `following` + `length set below` (a following lane has no position, so no length is below it: any length starts it at 1) and `free at 1` + `length set below` (a length is at least 1).

| State | Event | Next | Effect |
|---|---|---|---|
| `following` | `tick played` | `following` | read at the step played: step 2 |
| `following` | `tick skipped` | `following` | read at step 3, the step played |
| `following` | `voice started` | `following` | read at step 1 |
| `following` | `length set` | `free at 1` | its next read is cell 1 |
| `following` | `set back to following` | `following` | nothing |
| `free at 1` | `tick played` | `free inside` | cell 1 read at step 2 |
| `free at 1` | `tick skipped` | `free inside` | it moved on at the skipped tick: cell 2 read at step 3 |
| `free at 1` | `voice started` | `free inside` | cell 1 read at step 1 |
| `free at 1` | `length set` | `free at 1` | 8 long, still at 1 |
| `free at 1` | `set back to following` | `following` | its position dropped |
| `free inside` | `tick played` | `free inside` | cell 3 read at step 4 |
| `free inside` | `tick skipped` | `free at its end` | cell 4 read at step 5 |
| `free inside` | `voice started` | `free inside` | back to 1: cell 1 read at step 1 |
| `free inside` | `length set` | `free inside` | 8 long, still at cell 3 |
| `free inside` | `length set below` | `free at 1` | 2 is below cell 3: it wraps to 1 |
| `free inside` | `set back to following` | `following` | its position dropped |
| `free at its end` | `tick played` | `free at 1` | cell 5 read at step 6, then the wrap |
| `free at its end` | `tick skipped` | `free inside` | it wrapped at the skipped tick: cell 1 read at step 7 |
| `free at its end` | `voice started` | `free inside` | cell 1 read at step 1 |
| `free at its end` | `length set` | `free inside` | 8 long, at cell 5 of 8 |
| `free at its end` | `length set below` | `free at 1` | 2 is below cell 5: it wraps to 1 |
| `free at its end` | `set back to following` | `following` | its position dropped |

## Owns

`lib/lanes.lua` (`S.lib.lanes`, 3.9 grid sequencer, package 2a; included right before `lib/sequencer.lua`, whose `seq` record reads its options at include):
- `TARGETS` (`position`, `pitch`, `size`, `cutoff`), `MOVE` (the lanes' params `seq_move_a` and `seq_move_b`, their step keys `va` and `vb`, their first options `auto` and `off`, the param each target moves, a move hit's light with no value A, 4, and the filter's opening: mix 1 and the flash `filter on`), `options(lane)`.
- `target(voice, "a" | "b") -> name | nil`: `auto` is `position` when `voice_uses_buffer(voice)`, else `pitch`; `off` is nil; B is nil where it names A's target.
- `value(voice, target, level) -> param_id, value | nil` for a whole level 1 to 15: position `(level - 1) / 14` on `v<i>_buf_pos`; size and cutoff the param's controlspec `map((level - 1) / 14)` on `v<i>_grain_size` and `v<i>_filter_freq`; pitch `S.lib.sequencer.note_value(voice, level - 8)` (2b); nil for another target or level. `MOVE.own_pitch_level` is 8.
- `choose_mode(voice, name)` and `choose_target(voice, "a" | "b", name)`: the hand's paths (consumed by the grid's patterns page, the perform side and SEQ's rows in later packages); an unknown voice, lane or name does nothing.
- `hit_light(voice, step) -> 0..15`: `step_brightness` in every mode but `move`; in `move` a set step inside the voice's length and off its playhead lights at its `va`, or 4 with none (the playhead and the steps past the length light as in every mode). The grid's pages are to use it (packages 3b, 5c); SEQ keeps `step_brightness`.
- 2c's lane lengths: `LANES` and `STEP_KEYS`; `length(voice, lane) -> 1..16 | nil` (nil follows), `set_length(voice, lane, n | nil)`, `lengths(voice) -> table` (a copy, lane -> length for each free lane) and `set_lengths(voice, table)` (the whole-pattern door of 4a: all five set, a lane the table does not name, or names with no whole 1 to 16, follows); `position(voice, lane) -> 1..length | nil` (the cell a free lane's next read reads; nil while it follows: the table's `state_of`); `read(voice, lane, hit_step) -> value | nil` (once a tick: the step key at `hit_step` while the lane follows, at its position while free; it records the cell), `sounding(voice, lane) -> 1..16 | nil` (the cell last read, for the lights; nil from a start until the first read) and `last_read(voice, lane) -> value | nil` (the value that cell holds now, the rest of the tick's reading); `start(voice)` (every free lane to 1, nothing read; called from `start_position`) and `advance(voice)` (every free lane on by one, wrapping); `apply_block(block)`, `valid_block(block)` (the block's check; 4a holds a stored letter's lanes to it, `docs/notes/lua/pattern-letters.md`) and the scene block `lanes`. The lengths, positions and cells read live in one local table, `lane_state`, read only through these.
- Its unit tests: `test/unit/lanes_test.lua`.

`lib/sequencer.lua` holds the rest (`docs/notes/lua/sequencer.md`): the params `v<i>_seq_move_a` (options `auto`, `position`, `pitch`, `size`, `cutoff`; default 1) and `v<i>_seq_move_b` (`off`, then the four; default 1), discrete scene keys of the `seq` record (`count` 11), out of the voice presets (ruling 1a-3, as every seq key); the step keys `va` and `vb` in `ATTR_CHECKS` (whole 1 to 15), so `set_step_attr`, `step_attr`, `valid_steps` and the `steps` scene block take them; `held_value(voice, target)`, `end_held_values(voice)` and `end_held_value(voice, target)` (`lib/positions.lua`'s jump, for position; `own_note_taken`, for pitch); 2b's `note_value(voice, degrees) -> param_id, value | nil`; the held record (`held_values`, with the functions in one table, `values`: `take`, `release`, `end_held`, `on_param`, and 2b's `step_level`, `pitch_level` and `midi_keeps_own`, which is `other_owns_slot_1`), part of `step holds`.

## How a hit sets its values

`apply_step` (the step's first hit) first asks `values.take(voice, step)`: for lane A, then B, the target now and the lane's read at the tick (`S.lib.lanes.last_read`: the step's key while the lane follows, its own cell's while free, 2c); each pair with a value replaces the held entry on its target (`{level, step, param}`) and is returned as fresh. The clearing loop then ends each override of the last played step that this step neither locks nor sets fresh (`values.release`). The step's locks are set, then each fresh value whose param no lock of the step holds. A held value the step does not set is not sent again. `end_overrides(voice)` ends the held values before the locks (a held value whose param a lock holds is only dropped there, so each param is sent once); the length's action ends the held values set past the new length first, then, when the last played step is past it, the overrides with `keep_held`, so a lock over a value that stays brings the value back in one send.

A held value's param is kept in its entry, since after a source switch a target may name another param (pitch follows the source); the switch ends the values before the voice's sync.

A pitch value (2b) is worked out before `apply_step`: the tick asks `values.pitch_level(voice)` once, and `step_semitones` (the step's notes plus `level - 8`, clipped) and `step_inputs` (its `pitch_value`, which `step_pitches` plays where no lock holds the note param and the step has no chord) both take it, so the hits' events, the chord and the overrides come from one reckoning. `apply_step` then takes the value as any other (`values.take`); where the step has notes, the chord's first note is the note param's override (`wanted`), the value's own send standing down for it, and its degrees already hold the value's.
