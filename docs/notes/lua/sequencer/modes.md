## Must not break

- This file holds the sequencer's step mode, the gate rule and the one writer of a step's level (3.9's grid sequencer, package 1b, design section 1); the rest of the sequencer, and the rules that span it, are in `docs/notes/lua/sequencer.md`.
- **The mode is `v<i>_seq_gate`**, its id unchanged and its options only ever appended (`SEQ.modes`): 1 `accent` (3.8's `off`), 2 `gate` (3.8's `on`, `SEQ.gate_on`), 3 `move`, 4 `pulse`, the default (`SEQ.default_mode`, and `scene_defaults.seq_gate`). A scene or PSET saved in 3.8 keeps its 1 or 2 and plays as it did: accent swells, gate is gated with the patterns stopped too. The chain carries no mode (`SEQ.chain_keys`).
- **The gate rule is one function of what exists, with nothing stored** (`modes.rule(option, voice)`, `S.lib.sequencer.gate_wanted(voice)`): `seqGate` is 1 for a `gate` voice, 1 for a `pulse` voice exactly while the patterns play and `has_set_step(voice)` (a set step inside the voice's length), else 0. The sequencer keeps no record of what the engine was sent.
- **One sender of `seqGate`**: the mode param's own (the `seq` record's grain key `seqGate`, whose `value` is `modes.rule(option, voice)`; `lib/engine_sync.lua` and `lib/params_setup.lua` call a key's `value` with the value and the voice). `S.lib.sequencer.send_gate_rule(voice)` is `send_param_to_engine` of the mode and nothing else, so it reaches a running voice only; a stopped voice is sent nothing, and its start sends the rule's answer with its other grain keys. It is sent when the answer moves: by `set_level` and `replace_pattern` (the answer before and after the write), at the patterns' start (for every voice, after `S.pattern_playing` is set and before the first hit) and at their stop (after the outputs' stop), and by the length's action on a `pulse` voice; a mode change sends it through the param's own action (`add_voice_param`'s send), never twice. An `accent` or `gate` voice is sent nothing at a start or a stop, so a 3.8 scene sends what it sent (`test/fixtures/3.8.0-scene-calls.lua`).
- **One writer of a level**: `S.lib.sequencer.set_level(voice, step, level)` (a whole level 0..`MAX_STEP_LEVEL`; a voice, step or level out of range does nothing) writes `S.patterns`, calls `S.lib.mutation.note_pattern_edit`, sends the rule when its answer moved and calls `grid_redraw()`. `toggle_pattern_step`, the grid's level gesture (`lib/grid/core.lua`), SEQ's encoder, its edit view's level row (`turn_step`) and reset row, the arc's level ring, and the layout states of SEQ and SETUP write through it; `replace_pattern` writes a whole pattern. A test scans `lib/` and `strata.lua` for any other write ("no code but set_level and replace_pattern writes S.patterns"): only the include-time fill is exempt.
- **A move hit** is the voice's own retrigger at velocity 0 (`modes.own_event`: the `voices` output plays a copy of the event at velocity 0, its retrigger, chord and slice included), so it adds no swell and plucks no string but still reaches what listens to hits (the envelope routes, a one-shot's scan restart, a triggered grain). The event every other output gets carries velocity 1 (`hit_event`) and the step's level. A stopped `move` voice is started by its first hit, as an `accent` one is (the start is the hit). A move voice is never gated.
- **A gated hit is the rule's**: `gated(voice)` is `gate_wanted(voice) == 1`, so a pulse voice's hits are gated hits (the start followed by its retrigger, `gateSeconds` before the hit, the event's `gate_beats` the gate's length: a pulse voice's outside notes take its gate length, `lib/io/targets.lua`). Lua's envelope model holds a hit for the voice's gate length while `gate_wanted(voice) == 1` (`lib/envelopes.lua`'s `hold_for`), as the engine's hold reads `seqGate`.

## Machines

### step gate
- **State:** voice 3's mode (`S.lib.sequencer.step_mode(3)`), whether it has a hit (`has_set_step(3)`: its only step 12 set, or none), whether the patterns play (`S.pattern_playing`) and whether the voice runs (`S.voices[3].active`), named `<mode>/<hit|none>/<playing|stopped>/<on|off>`; what the engine was last sent is the stub's last `setGrainParam(2, "seqGate", x)` (ruling 1b-2), not a state of Lua's.
- **Invariant:** `step gate`: for a running voice, the mode the engine sync last sent for `v<i>_seq_gate` (`S.lib.engine_sync.expected_value`; after a start, which records none, the stored mode the start sent) gives the grain key `gate_wanted(voice)`. It is what Lua can see: it fails on a mode change that was never sent; the rows check what the engine got.
- **Test:** `test/unit/sequencer_test.lua`: "step gate: pulse/hit/playing/on + stop" (one test a row), "the step gate invariant fails on a mode the engine was not sent", and the named tests beside them ("a fresh voice given a step pulses once the patterns play", "each of the five writers of a level asks the rule", ...).

Each state is a fresh script: the mode set, step 12 set through `set_level` (hit), voice 3 started by hand (on), the patterns started (playing), in that order. The events: `toggle` (`toggle_pattern_step(3, 12)`) and `grid level` (step 12's key held and column 14 pressed on a 16×16 grid: level 13, never 0), two of the writers of a level; SEQ's encoder, its level and reset rows and the arc's ring end in the same `set_level` call, and "each of the five writers of a level asks the rule", the scan and the grid and arc unit tests pin their routing (review round 1); `length cut` (the length to 11, below step 12), `start` and `stop` (the patterns), `accent`, `gate`, `move` and `pulse` (the mode chosen), `replaced, a step` and `replaced, none` (`replace_pattern` with step 12 at 15, or empty), `a pass` (two seconds: sixteen 1/16 steps, so a stopped voice with a hit is started by it) and `voice started` and `voice stopped` (by hand; nothing when it already is). Every cell is a row. Each row's check asserts the rule's answer against the model (1 for gate, 1 for pulse with a hit while playing, else 0), the engine's last `seqGate` for a running voice against it, and exactly the `seqGate` the event sent, which the Effect column gives: the answer when it moved on a running voice; the param's own send when a running voice's mode changed, or its length while in pulse (sent whether the answer moved or not); the start's grain keys when the event started the voice; nothing to a stopped voice.

| State | Event | Next | Effect |
|---|---|---|---|
| `accent/hit/playing/off` | `a pass` | `accent/hit/playing/on` | the start's `seqGate 0` |
| `accent/hit/playing/off` | `accent` | `accent/hit/playing/off` | nothing |
| `accent/hit/playing/off` | `gate` | `gate/hit/playing/off` | nothing |
| `accent/hit/playing/off` | `grid level` | `accent/hit/playing/off` | nothing |
| `accent/hit/playing/off` | `length cut` | `accent/none/playing/off` | nothing |
| `accent/hit/playing/off` | `move` | `move/hit/playing/off` | nothing |
| `accent/hit/playing/off` | `pulse` | `pulse/hit/playing/off` | nothing |
| `accent/hit/playing/off` | `replaced, a step` | `accent/hit/playing/off` | nothing |
| `accent/hit/playing/off` | `replaced, none` | `accent/none/playing/off` | nothing |
| `accent/hit/playing/off` | `start` | `accent/hit/playing/off` | nothing |
| `accent/hit/playing/off` | `stop` | `accent/hit/stopped/off` | nothing |
| `accent/hit/playing/off` | `toggle` | `accent/none/playing/off` | nothing |
| `accent/hit/playing/off` | `voice started` | `accent/hit/playing/on` | the start's `seqGate 0` |
| `accent/hit/playing/off` | `voice stopped` | `accent/hit/playing/off` | nothing |
| `accent/hit/playing/on` | `a pass` | `accent/hit/playing/on` | nothing |
| `accent/hit/playing/on` | `accent` | `accent/hit/playing/on` | nothing |
| `accent/hit/playing/on` | `gate` | `gate/hit/playing/on` | `seqGate 1` |
| `accent/hit/playing/on` | `grid level` | `accent/hit/playing/on` | nothing |
| `accent/hit/playing/on` | `length cut` | `accent/none/playing/on` | nothing |
| `accent/hit/playing/on` | `move` | `move/hit/playing/on` | `seqGate 0` |
| `accent/hit/playing/on` | `pulse` | `pulse/hit/playing/on` | `seqGate 1` |
| `accent/hit/playing/on` | `replaced, a step` | `accent/hit/playing/on` | nothing |
| `accent/hit/playing/on` | `replaced, none` | `accent/none/playing/on` | nothing |
| `accent/hit/playing/on` | `start` | `accent/hit/playing/on` | nothing |
| `accent/hit/playing/on` | `stop` | `accent/hit/stopped/on` | nothing |
| `accent/hit/playing/on` | `toggle` | `accent/none/playing/on` | nothing |
| `accent/hit/playing/on` | `voice started` | `accent/hit/playing/on` | nothing |
| `accent/hit/playing/on` | `voice stopped` | `accent/hit/playing/off` | nothing |
| `accent/hit/stopped/off` | `a pass` | `accent/hit/stopped/off` | nothing |
| `accent/hit/stopped/off` | `accent` | `accent/hit/stopped/off` | nothing |
| `accent/hit/stopped/off` | `gate` | `gate/hit/stopped/off` | nothing |
| `accent/hit/stopped/off` | `grid level` | `accent/hit/stopped/off` | nothing |
| `accent/hit/stopped/off` | `length cut` | `accent/none/stopped/off` | nothing |
| `accent/hit/stopped/off` | `move` | `move/hit/stopped/off` | nothing |
| `accent/hit/stopped/off` | `pulse` | `pulse/hit/stopped/off` | nothing |
| `accent/hit/stopped/off` | `replaced, a step` | `accent/hit/stopped/off` | nothing |
| `accent/hit/stopped/off` | `replaced, none` | `accent/none/stopped/off` | nothing |
| `accent/hit/stopped/off` | `start` | `accent/hit/playing/off` | nothing |
| `accent/hit/stopped/off` | `stop` | `accent/hit/stopped/off` | nothing |
| `accent/hit/stopped/off` | `toggle` | `accent/none/stopped/off` | nothing |
| `accent/hit/stopped/off` | `voice started` | `accent/hit/stopped/on` | the start's `seqGate 0` |
| `accent/hit/stopped/off` | `voice stopped` | `accent/hit/stopped/off` | nothing |
| `accent/hit/stopped/on` | `a pass` | `accent/hit/stopped/on` | nothing |
| `accent/hit/stopped/on` | `accent` | `accent/hit/stopped/on` | nothing |
| `accent/hit/stopped/on` | `gate` | `gate/hit/stopped/on` | `seqGate 1` |
| `accent/hit/stopped/on` | `grid level` | `accent/hit/stopped/on` | nothing |
| `accent/hit/stopped/on` | `length cut` | `accent/none/stopped/on` | nothing |
| `accent/hit/stopped/on` | `move` | `move/hit/stopped/on` | `seqGate 0` |
| `accent/hit/stopped/on` | `pulse` | `pulse/hit/stopped/on` | `seqGate 0` |
| `accent/hit/stopped/on` | `replaced, a step` | `accent/hit/stopped/on` | nothing |
| `accent/hit/stopped/on` | `replaced, none` | `accent/none/stopped/on` | nothing |
| `accent/hit/stopped/on` | `start` | `accent/hit/playing/on` | nothing |
| `accent/hit/stopped/on` | `stop` | `accent/hit/stopped/on` | nothing |
| `accent/hit/stopped/on` | `toggle` | `accent/none/stopped/on` | nothing |
| `accent/hit/stopped/on` | `voice started` | `accent/hit/stopped/on` | nothing |
| `accent/hit/stopped/on` | `voice stopped` | `accent/hit/stopped/off` | nothing |
| `accent/none/playing/off` | `a pass` | `accent/none/playing/off` | nothing |
| `accent/none/playing/off` | `accent` | `accent/none/playing/off` | nothing |
| `accent/none/playing/off` | `gate` | `gate/none/playing/off` | nothing |
| `accent/none/playing/off` | `grid level` | `accent/hit/playing/off` | nothing |
| `accent/none/playing/off` | `length cut` | `accent/none/playing/off` | nothing |
| `accent/none/playing/off` | `move` | `move/none/playing/off` | nothing |
| `accent/none/playing/off` | `pulse` | `pulse/none/playing/off` | nothing |
| `accent/none/playing/off` | `replaced, a step` | `accent/hit/playing/off` | nothing |
| `accent/none/playing/off` | `replaced, none` | `accent/none/playing/off` | nothing |
| `accent/none/playing/off` | `start` | `accent/none/playing/off` | nothing |
| `accent/none/playing/off` | `stop` | `accent/none/stopped/off` | nothing |
| `accent/none/playing/off` | `toggle` | `accent/hit/playing/off` | nothing |
| `accent/none/playing/off` | `voice started` | `accent/none/playing/on` | the start's `seqGate 0` |
| `accent/none/playing/off` | `voice stopped` | `accent/none/playing/off` | nothing |
| `accent/none/playing/on` | `a pass` | `accent/none/playing/on` | nothing |
| `accent/none/playing/on` | `accent` | `accent/none/playing/on` | nothing |
| `accent/none/playing/on` | `gate` | `gate/none/playing/on` | `seqGate 1` |
| `accent/none/playing/on` | `grid level` | `accent/hit/playing/on` | nothing |
| `accent/none/playing/on` | `length cut` | `accent/none/playing/on` | nothing |
| `accent/none/playing/on` | `move` | `move/none/playing/on` | `seqGate 0` |
| `accent/none/playing/on` | `pulse` | `pulse/none/playing/on` | `seqGate 0` |
| `accent/none/playing/on` | `replaced, a step` | `accent/hit/playing/on` | nothing |
| `accent/none/playing/on` | `replaced, none` | `accent/none/playing/on` | nothing |
| `accent/none/playing/on` | `start` | `accent/none/playing/on` | nothing |
| `accent/none/playing/on` | `stop` | `accent/none/stopped/on` | nothing |
| `accent/none/playing/on` | `toggle` | `accent/hit/playing/on` | nothing |
| `accent/none/playing/on` | `voice started` | `accent/none/playing/on` | nothing |
| `accent/none/playing/on` | `voice stopped` | `accent/none/playing/off` | nothing |
| `accent/none/stopped/off` | `a pass` | `accent/none/stopped/off` | nothing |
| `accent/none/stopped/off` | `accent` | `accent/none/stopped/off` | nothing |
| `accent/none/stopped/off` | `gate` | `gate/none/stopped/off` | nothing |
| `accent/none/stopped/off` | `grid level` | `accent/hit/stopped/off` | nothing |
| `accent/none/stopped/off` | `length cut` | `accent/none/stopped/off` | nothing |
| `accent/none/stopped/off` | `move` | `move/none/stopped/off` | nothing |
| `accent/none/stopped/off` | `pulse` | `pulse/none/stopped/off` | nothing |
| `accent/none/stopped/off` | `replaced, a step` | `accent/hit/stopped/off` | nothing |
| `accent/none/stopped/off` | `replaced, none` | `accent/none/stopped/off` | nothing |
| `accent/none/stopped/off` | `start` | `accent/none/playing/off` | nothing |
| `accent/none/stopped/off` | `stop` | `accent/none/stopped/off` | nothing |
| `accent/none/stopped/off` | `toggle` | `accent/hit/stopped/off` | nothing |
| `accent/none/stopped/off` | `voice started` | `accent/none/stopped/on` | the start's `seqGate 0` |
| `accent/none/stopped/off` | `voice stopped` | `accent/none/stopped/off` | nothing |
| `accent/none/stopped/on` | `a pass` | `accent/none/stopped/on` | nothing |
| `accent/none/stopped/on` | `accent` | `accent/none/stopped/on` | nothing |
| `accent/none/stopped/on` | `gate` | `gate/none/stopped/on` | `seqGate 1` |
| `accent/none/stopped/on` | `grid level` | `accent/hit/stopped/on` | nothing |
| `accent/none/stopped/on` | `length cut` | `accent/none/stopped/on` | nothing |
| `accent/none/stopped/on` | `move` | `move/none/stopped/on` | `seqGate 0` |
| `accent/none/stopped/on` | `pulse` | `pulse/none/stopped/on` | `seqGate 0` |
| `accent/none/stopped/on` | `replaced, a step` | `accent/hit/stopped/on` | nothing |
| `accent/none/stopped/on` | `replaced, none` | `accent/none/stopped/on` | nothing |
| `accent/none/stopped/on` | `start` | `accent/none/playing/on` | nothing |
| `accent/none/stopped/on` | `stop` | `accent/none/stopped/on` | nothing |
| `accent/none/stopped/on` | `toggle` | `accent/hit/stopped/on` | nothing |
| `accent/none/stopped/on` | `voice started` | `accent/none/stopped/on` | nothing |
| `accent/none/stopped/on` | `voice stopped` | `accent/none/stopped/off` | nothing |
| `gate/hit/playing/off` | `a pass` | `gate/hit/playing/on` | the start's `seqGate 1` |
| `gate/hit/playing/off` | `accent` | `accent/hit/playing/off` | nothing |
| `gate/hit/playing/off` | `gate` | `gate/hit/playing/off` | nothing |
| `gate/hit/playing/off` | `grid level` | `gate/hit/playing/off` | nothing |
| `gate/hit/playing/off` | `length cut` | `gate/none/playing/off` | nothing |
| `gate/hit/playing/off` | `move` | `move/hit/playing/off` | nothing |
| `gate/hit/playing/off` | `pulse` | `pulse/hit/playing/off` | nothing |
| `gate/hit/playing/off` | `replaced, a step` | `gate/hit/playing/off` | nothing |
| `gate/hit/playing/off` | `replaced, none` | `gate/none/playing/off` | nothing |
| `gate/hit/playing/off` | `start` | `gate/hit/playing/off` | nothing |
| `gate/hit/playing/off` | `stop` | `gate/hit/stopped/off` | nothing |
| `gate/hit/playing/off` | `toggle` | `gate/none/playing/off` | nothing |
| `gate/hit/playing/off` | `voice started` | `gate/hit/playing/on` | the start's `seqGate 1` |
| `gate/hit/playing/off` | `voice stopped` | `gate/hit/playing/off` | nothing |
| `gate/hit/playing/on` | `a pass` | `gate/hit/playing/on` | nothing |
| `gate/hit/playing/on` | `accent` | `accent/hit/playing/on` | `seqGate 0` |
| `gate/hit/playing/on` | `gate` | `gate/hit/playing/on` | nothing |
| `gate/hit/playing/on` | `grid level` | `gate/hit/playing/on` | nothing |
| `gate/hit/playing/on` | `length cut` | `gate/none/playing/on` | nothing |
| `gate/hit/playing/on` | `move` | `move/hit/playing/on` | `seqGate 0` |
| `gate/hit/playing/on` | `pulse` | `pulse/hit/playing/on` | `seqGate 1` |
| `gate/hit/playing/on` | `replaced, a step` | `gate/hit/playing/on` | nothing |
| `gate/hit/playing/on` | `replaced, none` | `gate/none/playing/on` | nothing |
| `gate/hit/playing/on` | `start` | `gate/hit/playing/on` | nothing |
| `gate/hit/playing/on` | `stop` | `gate/hit/stopped/on` | nothing |
| `gate/hit/playing/on` | `toggle` | `gate/none/playing/on` | nothing |
| `gate/hit/playing/on` | `voice started` | `gate/hit/playing/on` | nothing |
| `gate/hit/playing/on` | `voice stopped` | `gate/hit/playing/off` | nothing |
| `gate/hit/stopped/off` | `a pass` | `gate/hit/stopped/off` | nothing |
| `gate/hit/stopped/off` | `accent` | `accent/hit/stopped/off` | nothing |
| `gate/hit/stopped/off` | `gate` | `gate/hit/stopped/off` | nothing |
| `gate/hit/stopped/off` | `grid level` | `gate/hit/stopped/off` | nothing |
| `gate/hit/stopped/off` | `length cut` | `gate/none/stopped/off` | nothing |
| `gate/hit/stopped/off` | `move` | `move/hit/stopped/off` | nothing |
| `gate/hit/stopped/off` | `pulse` | `pulse/hit/stopped/off` | nothing |
| `gate/hit/stopped/off` | `replaced, a step` | `gate/hit/stopped/off` | nothing |
| `gate/hit/stopped/off` | `replaced, none` | `gate/none/stopped/off` | nothing |
| `gate/hit/stopped/off` | `start` | `gate/hit/playing/off` | nothing |
| `gate/hit/stopped/off` | `stop` | `gate/hit/stopped/off` | nothing |
| `gate/hit/stopped/off` | `toggle` | `gate/none/stopped/off` | nothing |
| `gate/hit/stopped/off` | `voice started` | `gate/hit/stopped/on` | the start's `seqGate 1` |
| `gate/hit/stopped/off` | `voice stopped` | `gate/hit/stopped/off` | nothing |
| `gate/hit/stopped/on` | `a pass` | `gate/hit/stopped/on` | nothing |
| `gate/hit/stopped/on` | `accent` | `accent/hit/stopped/on` | `seqGate 0` |
| `gate/hit/stopped/on` | `gate` | `gate/hit/stopped/on` | nothing |
| `gate/hit/stopped/on` | `grid level` | `gate/hit/stopped/on` | nothing |
| `gate/hit/stopped/on` | `length cut` | `gate/none/stopped/on` | nothing |
| `gate/hit/stopped/on` | `move` | `move/hit/stopped/on` | `seqGate 0` |
| `gate/hit/stopped/on` | `pulse` | `pulse/hit/stopped/on` | `seqGate 0` |
| `gate/hit/stopped/on` | `replaced, a step` | `gate/hit/stopped/on` | nothing |
| `gate/hit/stopped/on` | `replaced, none` | `gate/none/stopped/on` | nothing |
| `gate/hit/stopped/on` | `start` | `gate/hit/playing/on` | nothing |
| `gate/hit/stopped/on` | `stop` | `gate/hit/stopped/on` | nothing |
| `gate/hit/stopped/on` | `toggle` | `gate/none/stopped/on` | nothing |
| `gate/hit/stopped/on` | `voice started` | `gate/hit/stopped/on` | nothing |
| `gate/hit/stopped/on` | `voice stopped` | `gate/hit/stopped/off` | nothing |
| `gate/none/playing/off` | `a pass` | `gate/none/playing/off` | nothing |
| `gate/none/playing/off` | `accent` | `accent/none/playing/off` | nothing |
| `gate/none/playing/off` | `gate` | `gate/none/playing/off` | nothing |
| `gate/none/playing/off` | `grid level` | `gate/hit/playing/off` | nothing |
| `gate/none/playing/off` | `length cut` | `gate/none/playing/off` | nothing |
| `gate/none/playing/off` | `move` | `move/none/playing/off` | nothing |
| `gate/none/playing/off` | `pulse` | `pulse/none/playing/off` | nothing |
| `gate/none/playing/off` | `replaced, a step` | `gate/hit/playing/off` | nothing |
| `gate/none/playing/off` | `replaced, none` | `gate/none/playing/off` | nothing |
| `gate/none/playing/off` | `start` | `gate/none/playing/off` | nothing |
| `gate/none/playing/off` | `stop` | `gate/none/stopped/off` | nothing |
| `gate/none/playing/off` | `toggle` | `gate/hit/playing/off` | nothing |
| `gate/none/playing/off` | `voice started` | `gate/none/playing/on` | the start's `seqGate 1` |
| `gate/none/playing/off` | `voice stopped` | `gate/none/playing/off` | nothing |
| `gate/none/playing/on` | `a pass` | `gate/none/playing/on` | nothing |
| `gate/none/playing/on` | `accent` | `accent/none/playing/on` | `seqGate 0` |
| `gate/none/playing/on` | `gate` | `gate/none/playing/on` | nothing |
| `gate/none/playing/on` | `grid level` | `gate/hit/playing/on` | nothing |
| `gate/none/playing/on` | `length cut` | `gate/none/playing/on` | nothing |
| `gate/none/playing/on` | `move` | `move/none/playing/on` | `seqGate 0` |
| `gate/none/playing/on` | `pulse` | `pulse/none/playing/on` | `seqGate 0` |
| `gate/none/playing/on` | `replaced, a step` | `gate/hit/playing/on` | nothing |
| `gate/none/playing/on` | `replaced, none` | `gate/none/playing/on` | nothing |
| `gate/none/playing/on` | `start` | `gate/none/playing/on` | nothing |
| `gate/none/playing/on` | `stop` | `gate/none/stopped/on` | nothing |
| `gate/none/playing/on` | `toggle` | `gate/hit/playing/on` | nothing |
| `gate/none/playing/on` | `voice started` | `gate/none/playing/on` | nothing |
| `gate/none/playing/on` | `voice stopped` | `gate/none/playing/off` | nothing |
| `gate/none/stopped/off` | `a pass` | `gate/none/stopped/off` | nothing |
| `gate/none/stopped/off` | `accent` | `accent/none/stopped/off` | nothing |
| `gate/none/stopped/off` | `gate` | `gate/none/stopped/off` | nothing |
| `gate/none/stopped/off` | `grid level` | `gate/hit/stopped/off` | nothing |
| `gate/none/stopped/off` | `length cut` | `gate/none/stopped/off` | nothing |
| `gate/none/stopped/off` | `move` | `move/none/stopped/off` | nothing |
| `gate/none/stopped/off` | `pulse` | `pulse/none/stopped/off` | nothing |
| `gate/none/stopped/off` | `replaced, a step` | `gate/hit/stopped/off` | nothing |
| `gate/none/stopped/off` | `replaced, none` | `gate/none/stopped/off` | nothing |
| `gate/none/stopped/off` | `start` | `gate/none/playing/off` | nothing |
| `gate/none/stopped/off` | `stop` | `gate/none/stopped/off` | nothing |
| `gate/none/stopped/off` | `toggle` | `gate/hit/stopped/off` | nothing |
| `gate/none/stopped/off` | `voice started` | `gate/none/stopped/on` | the start's `seqGate 1` |
| `gate/none/stopped/off` | `voice stopped` | `gate/none/stopped/off` | nothing |
| `gate/none/stopped/on` | `a pass` | `gate/none/stopped/on` | nothing |
| `gate/none/stopped/on` | `accent` | `accent/none/stopped/on` | `seqGate 0` |
| `gate/none/stopped/on` | `gate` | `gate/none/stopped/on` | nothing |
| `gate/none/stopped/on` | `grid level` | `gate/hit/stopped/on` | nothing |
| `gate/none/stopped/on` | `length cut` | `gate/none/stopped/on` | nothing |
| `gate/none/stopped/on` | `move` | `move/none/stopped/on` | `seqGate 0` |
| `gate/none/stopped/on` | `pulse` | `pulse/none/stopped/on` | `seqGate 0` |
| `gate/none/stopped/on` | `replaced, a step` | `gate/hit/stopped/on` | nothing |
| `gate/none/stopped/on` | `replaced, none` | `gate/none/stopped/on` | nothing |
| `gate/none/stopped/on` | `start` | `gate/none/playing/on` | nothing |
| `gate/none/stopped/on` | `stop` | `gate/none/stopped/on` | nothing |
| `gate/none/stopped/on` | `toggle` | `gate/hit/stopped/on` | nothing |
| `gate/none/stopped/on` | `voice started` | `gate/none/stopped/on` | nothing |
| `gate/none/stopped/on` | `voice stopped` | `gate/none/stopped/off` | nothing |
| `move/hit/playing/off` | `a pass` | `move/hit/playing/on` | the start's `seqGate 0` |
| `move/hit/playing/off` | `accent` | `accent/hit/playing/off` | nothing |
| `move/hit/playing/off` | `gate` | `gate/hit/playing/off` | nothing |
| `move/hit/playing/off` | `grid level` | `move/hit/playing/off` | nothing |
| `move/hit/playing/off` | `length cut` | `move/none/playing/off` | nothing |
| `move/hit/playing/off` | `move` | `move/hit/playing/off` | nothing |
| `move/hit/playing/off` | `pulse` | `pulse/hit/playing/off` | nothing |
| `move/hit/playing/off` | `replaced, a step` | `move/hit/playing/off` | nothing |
| `move/hit/playing/off` | `replaced, none` | `move/none/playing/off` | nothing |
| `move/hit/playing/off` | `start` | `move/hit/playing/off` | nothing |
| `move/hit/playing/off` | `stop` | `move/hit/stopped/off` | nothing |
| `move/hit/playing/off` | `toggle` | `move/none/playing/off` | nothing |
| `move/hit/playing/off` | `voice started` | `move/hit/playing/on` | the start's `seqGate 0` |
| `move/hit/playing/off` | `voice stopped` | `move/hit/playing/off` | nothing |
| `move/hit/playing/on` | `a pass` | `move/hit/playing/on` | nothing |
| `move/hit/playing/on` | `accent` | `accent/hit/playing/on` | `seqGate 0` |
| `move/hit/playing/on` | `gate` | `gate/hit/playing/on` | `seqGate 1` |
| `move/hit/playing/on` | `grid level` | `move/hit/playing/on` | nothing |
| `move/hit/playing/on` | `length cut` | `move/none/playing/on` | nothing |
| `move/hit/playing/on` | `move` | `move/hit/playing/on` | nothing |
| `move/hit/playing/on` | `pulse` | `pulse/hit/playing/on` | `seqGate 1` |
| `move/hit/playing/on` | `replaced, a step` | `move/hit/playing/on` | nothing |
| `move/hit/playing/on` | `replaced, none` | `move/none/playing/on` | nothing |
| `move/hit/playing/on` | `start` | `move/hit/playing/on` | nothing |
| `move/hit/playing/on` | `stop` | `move/hit/stopped/on` | nothing |
| `move/hit/playing/on` | `toggle` | `move/none/playing/on` | nothing |
| `move/hit/playing/on` | `voice started` | `move/hit/playing/on` | nothing |
| `move/hit/playing/on` | `voice stopped` | `move/hit/playing/off` | nothing |
| `move/hit/stopped/off` | `a pass` | `move/hit/stopped/off` | nothing |
| `move/hit/stopped/off` | `accent` | `accent/hit/stopped/off` | nothing |
| `move/hit/stopped/off` | `gate` | `gate/hit/stopped/off` | nothing |
| `move/hit/stopped/off` | `grid level` | `move/hit/stopped/off` | nothing |
| `move/hit/stopped/off` | `length cut` | `move/none/stopped/off` | nothing |
| `move/hit/stopped/off` | `move` | `move/hit/stopped/off` | nothing |
| `move/hit/stopped/off` | `pulse` | `pulse/hit/stopped/off` | nothing |
| `move/hit/stopped/off` | `replaced, a step` | `move/hit/stopped/off` | nothing |
| `move/hit/stopped/off` | `replaced, none` | `move/none/stopped/off` | nothing |
| `move/hit/stopped/off` | `start` | `move/hit/playing/off` | nothing |
| `move/hit/stopped/off` | `stop` | `move/hit/stopped/off` | nothing |
| `move/hit/stopped/off` | `toggle` | `move/none/stopped/off` | nothing |
| `move/hit/stopped/off` | `voice started` | `move/hit/stopped/on` | the start's `seqGate 0` |
| `move/hit/stopped/off` | `voice stopped` | `move/hit/stopped/off` | nothing |
| `move/hit/stopped/on` | `a pass` | `move/hit/stopped/on` | nothing |
| `move/hit/stopped/on` | `accent` | `accent/hit/stopped/on` | `seqGate 0` |
| `move/hit/stopped/on` | `gate` | `gate/hit/stopped/on` | `seqGate 1` |
| `move/hit/stopped/on` | `grid level` | `move/hit/stopped/on` | nothing |
| `move/hit/stopped/on` | `length cut` | `move/none/stopped/on` | nothing |
| `move/hit/stopped/on` | `move` | `move/hit/stopped/on` | nothing |
| `move/hit/stopped/on` | `pulse` | `pulse/hit/stopped/on` | `seqGate 0` |
| `move/hit/stopped/on` | `replaced, a step` | `move/hit/stopped/on` | nothing |
| `move/hit/stopped/on` | `replaced, none` | `move/none/stopped/on` | nothing |
| `move/hit/stopped/on` | `start` | `move/hit/playing/on` | nothing |
| `move/hit/stopped/on` | `stop` | `move/hit/stopped/on` | nothing |
| `move/hit/stopped/on` | `toggle` | `move/none/stopped/on` | nothing |
| `move/hit/stopped/on` | `voice started` | `move/hit/stopped/on` | nothing |
| `move/hit/stopped/on` | `voice stopped` | `move/hit/stopped/off` | nothing |
| `move/none/playing/off` | `a pass` | `move/none/playing/off` | nothing |
| `move/none/playing/off` | `accent` | `accent/none/playing/off` | nothing |
| `move/none/playing/off` | `gate` | `gate/none/playing/off` | nothing |
| `move/none/playing/off` | `grid level` | `move/hit/playing/off` | nothing |
| `move/none/playing/off` | `length cut` | `move/none/playing/off` | nothing |
| `move/none/playing/off` | `move` | `move/none/playing/off` | nothing |
| `move/none/playing/off` | `pulse` | `pulse/none/playing/off` | nothing |
| `move/none/playing/off` | `replaced, a step` | `move/hit/playing/off` | nothing |
| `move/none/playing/off` | `replaced, none` | `move/none/playing/off` | nothing |
| `move/none/playing/off` | `start` | `move/none/playing/off` | nothing |
| `move/none/playing/off` | `stop` | `move/none/stopped/off` | nothing |
| `move/none/playing/off` | `toggle` | `move/hit/playing/off` | nothing |
| `move/none/playing/off` | `voice started` | `move/none/playing/on` | the start's `seqGate 0` |
| `move/none/playing/off` | `voice stopped` | `move/none/playing/off` | nothing |
| `move/none/playing/on` | `a pass` | `move/none/playing/on` | nothing |
| `move/none/playing/on` | `accent` | `accent/none/playing/on` | `seqGate 0` |
| `move/none/playing/on` | `gate` | `gate/none/playing/on` | `seqGate 1` |
| `move/none/playing/on` | `grid level` | `move/hit/playing/on` | nothing |
| `move/none/playing/on` | `length cut` | `move/none/playing/on` | nothing |
| `move/none/playing/on` | `move` | `move/none/playing/on` | nothing |
| `move/none/playing/on` | `pulse` | `pulse/none/playing/on` | `seqGate 0` |
| `move/none/playing/on` | `replaced, a step` | `move/hit/playing/on` | nothing |
| `move/none/playing/on` | `replaced, none` | `move/none/playing/on` | nothing |
| `move/none/playing/on` | `start` | `move/none/playing/on` | nothing |
| `move/none/playing/on` | `stop` | `move/none/stopped/on` | nothing |
| `move/none/playing/on` | `toggle` | `move/hit/playing/on` | nothing |
| `move/none/playing/on` | `voice started` | `move/none/playing/on` | nothing |
| `move/none/playing/on` | `voice stopped` | `move/none/playing/off` | nothing |
| `move/none/stopped/off` | `a pass` | `move/none/stopped/off` | nothing |
| `move/none/stopped/off` | `accent` | `accent/none/stopped/off` | nothing |
| `move/none/stopped/off` | `gate` | `gate/none/stopped/off` | nothing |
| `move/none/stopped/off` | `grid level` | `move/hit/stopped/off` | nothing |
| `move/none/stopped/off` | `length cut` | `move/none/stopped/off` | nothing |
| `move/none/stopped/off` | `move` | `move/none/stopped/off` | nothing |
| `move/none/stopped/off` | `pulse` | `pulse/none/stopped/off` | nothing |
| `move/none/stopped/off` | `replaced, a step` | `move/hit/stopped/off` | nothing |
| `move/none/stopped/off` | `replaced, none` | `move/none/stopped/off` | nothing |
| `move/none/stopped/off` | `start` | `move/none/playing/off` | nothing |
| `move/none/stopped/off` | `stop` | `move/none/stopped/off` | nothing |
| `move/none/stopped/off` | `toggle` | `move/hit/stopped/off` | nothing |
| `move/none/stopped/off` | `voice started` | `move/none/stopped/on` | the start's `seqGate 0` |
| `move/none/stopped/off` | `voice stopped` | `move/none/stopped/off` | nothing |
| `move/none/stopped/on` | `a pass` | `move/none/stopped/on` | nothing |
| `move/none/stopped/on` | `accent` | `accent/none/stopped/on` | `seqGate 0` |
| `move/none/stopped/on` | `gate` | `gate/none/stopped/on` | `seqGate 1` |
| `move/none/stopped/on` | `grid level` | `move/hit/stopped/on` | nothing |
| `move/none/stopped/on` | `length cut` | `move/none/stopped/on` | nothing |
| `move/none/stopped/on` | `move` | `move/none/stopped/on` | nothing |
| `move/none/stopped/on` | `pulse` | `pulse/none/stopped/on` | `seqGate 0` |
| `move/none/stopped/on` | `replaced, a step` | `move/hit/stopped/on` | nothing |
| `move/none/stopped/on` | `replaced, none` | `move/none/stopped/on` | nothing |
| `move/none/stopped/on` | `start` | `move/none/playing/on` | nothing |
| `move/none/stopped/on` | `stop` | `move/none/stopped/on` | nothing |
| `move/none/stopped/on` | `toggle` | `move/hit/stopped/on` | nothing |
| `move/none/stopped/on` | `voice started` | `move/none/stopped/on` | nothing |
| `move/none/stopped/on` | `voice stopped` | `move/none/stopped/off` | nothing |
| `pulse/hit/playing/off` | `a pass` | `pulse/hit/playing/on` | the start's `seqGate 1` |
| `pulse/hit/playing/off` | `accent` | `accent/hit/playing/off` | nothing |
| `pulse/hit/playing/off` | `gate` | `gate/hit/playing/off` | nothing |
| `pulse/hit/playing/off` | `grid level` | `pulse/hit/playing/off` | nothing |
| `pulse/hit/playing/off` | `length cut` | `pulse/none/playing/off` | nothing |
| `pulse/hit/playing/off` | `move` | `move/hit/playing/off` | nothing |
| `pulse/hit/playing/off` | `pulse` | `pulse/hit/playing/off` | nothing |
| `pulse/hit/playing/off` | `replaced, a step` | `pulse/hit/playing/off` | nothing |
| `pulse/hit/playing/off` | `replaced, none` | `pulse/none/playing/off` | nothing |
| `pulse/hit/playing/off` | `start` | `pulse/hit/playing/off` | nothing |
| `pulse/hit/playing/off` | `stop` | `pulse/hit/stopped/off` | nothing |
| `pulse/hit/playing/off` | `toggle` | `pulse/none/playing/off` | nothing |
| `pulse/hit/playing/off` | `voice started` | `pulse/hit/playing/on` | the start's `seqGate 1` |
| `pulse/hit/playing/off` | `voice stopped` | `pulse/hit/playing/off` | nothing |
| `pulse/hit/playing/on` | `a pass` | `pulse/hit/playing/on` | nothing |
| `pulse/hit/playing/on` | `accent` | `accent/hit/playing/on` | `seqGate 0` |
| `pulse/hit/playing/on` | `gate` | `gate/hit/playing/on` | `seqGate 1` |
| `pulse/hit/playing/on` | `grid level` | `pulse/hit/playing/on` | nothing |
| `pulse/hit/playing/on` | `length cut` | `pulse/none/playing/on` | `seqGate 0` |
| `pulse/hit/playing/on` | `move` | `move/hit/playing/on` | `seqGate 0` |
| `pulse/hit/playing/on` | `pulse` | `pulse/hit/playing/on` | nothing |
| `pulse/hit/playing/on` | `replaced, a step` | `pulse/hit/playing/on` | nothing |
| `pulse/hit/playing/on` | `replaced, none` | `pulse/none/playing/on` | `seqGate 0` |
| `pulse/hit/playing/on` | `start` | `pulse/hit/playing/on` | nothing |
| `pulse/hit/playing/on` | `stop` | `pulse/hit/stopped/on` | `seqGate 0` |
| `pulse/hit/playing/on` | `toggle` | `pulse/none/playing/on` | `seqGate 0` |
| `pulse/hit/playing/on` | `voice started` | `pulse/hit/playing/on` | nothing |
| `pulse/hit/playing/on` | `voice stopped` | `pulse/hit/playing/off` | nothing |
| `pulse/hit/stopped/off` | `a pass` | `pulse/hit/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `accent` | `accent/hit/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `gate` | `gate/hit/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `grid level` | `pulse/hit/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `length cut` | `pulse/none/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `move` | `move/hit/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `pulse` | `pulse/hit/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `replaced, a step` | `pulse/hit/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `replaced, none` | `pulse/none/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `start` | `pulse/hit/playing/off` | nothing |
| `pulse/hit/stopped/off` | `stop` | `pulse/hit/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `toggle` | `pulse/none/stopped/off` | nothing |
| `pulse/hit/stopped/off` | `voice started` | `pulse/hit/stopped/on` | the start's `seqGate 0` |
| `pulse/hit/stopped/off` | `voice stopped` | `pulse/hit/stopped/off` | nothing |
| `pulse/hit/stopped/on` | `a pass` | `pulse/hit/stopped/on` | nothing |
| `pulse/hit/stopped/on` | `accent` | `accent/hit/stopped/on` | `seqGate 0` |
| `pulse/hit/stopped/on` | `gate` | `gate/hit/stopped/on` | `seqGate 1` |
| `pulse/hit/stopped/on` | `grid level` | `pulse/hit/stopped/on` | nothing |
| `pulse/hit/stopped/on` | `length cut` | `pulse/none/stopped/on` | `seqGate 0` |
| `pulse/hit/stopped/on` | `move` | `move/hit/stopped/on` | `seqGate 0` |
| `pulse/hit/stopped/on` | `pulse` | `pulse/hit/stopped/on` | nothing |
| `pulse/hit/stopped/on` | `replaced, a step` | `pulse/hit/stopped/on` | nothing |
| `pulse/hit/stopped/on` | `replaced, none` | `pulse/none/stopped/on` | nothing |
| `pulse/hit/stopped/on` | `start` | `pulse/hit/playing/on` | `seqGate 1` |
| `pulse/hit/stopped/on` | `stop` | `pulse/hit/stopped/on` | nothing |
| `pulse/hit/stopped/on` | `toggle` | `pulse/none/stopped/on` | nothing |
| `pulse/hit/stopped/on` | `voice started` | `pulse/hit/stopped/on` | nothing |
| `pulse/hit/stopped/on` | `voice stopped` | `pulse/hit/stopped/off` | nothing |
| `pulse/none/playing/off` | `a pass` | `pulse/none/playing/off` | nothing |
| `pulse/none/playing/off` | `accent` | `accent/none/playing/off` | nothing |
| `pulse/none/playing/off` | `gate` | `gate/none/playing/off` | nothing |
| `pulse/none/playing/off` | `grid level` | `pulse/hit/playing/off` | nothing |
| `pulse/none/playing/off` | `length cut` | `pulse/none/playing/off` | nothing |
| `pulse/none/playing/off` | `move` | `move/none/playing/off` | nothing |
| `pulse/none/playing/off` | `pulse` | `pulse/none/playing/off` | nothing |
| `pulse/none/playing/off` | `replaced, a step` | `pulse/hit/playing/off` | nothing |
| `pulse/none/playing/off` | `replaced, none` | `pulse/none/playing/off` | nothing |
| `pulse/none/playing/off` | `start` | `pulse/none/playing/off` | nothing |
| `pulse/none/playing/off` | `stop` | `pulse/none/stopped/off` | nothing |
| `pulse/none/playing/off` | `toggle` | `pulse/hit/playing/off` | nothing |
| `pulse/none/playing/off` | `voice started` | `pulse/none/playing/on` | the start's `seqGate 0` |
| `pulse/none/playing/off` | `voice stopped` | `pulse/none/playing/off` | nothing |
| `pulse/none/playing/on` | `a pass` | `pulse/none/playing/on` | nothing |
| `pulse/none/playing/on` | `accent` | `accent/none/playing/on` | `seqGate 0` |
| `pulse/none/playing/on` | `gate` | `gate/none/playing/on` | `seqGate 1` |
| `pulse/none/playing/on` | `grid level` | `pulse/hit/playing/on` | `seqGate 1` |
| `pulse/none/playing/on` | `length cut` | `pulse/none/playing/on` | `seqGate 0` |
| `pulse/none/playing/on` | `move` | `move/none/playing/on` | `seqGate 0` |
| `pulse/none/playing/on` | `pulse` | `pulse/none/playing/on` | nothing |
| `pulse/none/playing/on` | `replaced, a step` | `pulse/hit/playing/on` | `seqGate 1` |
| `pulse/none/playing/on` | `replaced, none` | `pulse/none/playing/on` | nothing |
| `pulse/none/playing/on` | `start` | `pulse/none/playing/on` | nothing |
| `pulse/none/playing/on` | `stop` | `pulse/none/stopped/on` | nothing |
| `pulse/none/playing/on` | `toggle` | `pulse/hit/playing/on` | `seqGate 1` |
| `pulse/none/playing/on` | `voice started` | `pulse/none/playing/on` | nothing |
| `pulse/none/playing/on` | `voice stopped` | `pulse/none/playing/off` | nothing |
| `pulse/none/stopped/off` | `a pass` | `pulse/none/stopped/off` | nothing |
| `pulse/none/stopped/off` | `accent` | `accent/none/stopped/off` | nothing |
| `pulse/none/stopped/off` | `gate` | `gate/none/stopped/off` | nothing |
| `pulse/none/stopped/off` | `grid level` | `pulse/hit/stopped/off` | nothing |
| `pulse/none/stopped/off` | `length cut` | `pulse/none/stopped/off` | nothing |
| `pulse/none/stopped/off` | `move` | `move/none/stopped/off` | nothing |
| `pulse/none/stopped/off` | `pulse` | `pulse/none/stopped/off` | nothing |
| `pulse/none/stopped/off` | `replaced, a step` | `pulse/hit/stopped/off` | nothing |
| `pulse/none/stopped/off` | `replaced, none` | `pulse/none/stopped/off` | nothing |
| `pulse/none/stopped/off` | `start` | `pulse/none/playing/off` | nothing |
| `pulse/none/stopped/off` | `stop` | `pulse/none/stopped/off` | nothing |
| `pulse/none/stopped/off` | `toggle` | `pulse/hit/stopped/off` | nothing |
| `pulse/none/stopped/off` | `voice started` | `pulse/none/stopped/on` | the start's `seqGate 0` |
| `pulse/none/stopped/off` | `voice stopped` | `pulse/none/stopped/off` | nothing |
| `pulse/none/stopped/on` | `a pass` | `pulse/none/stopped/on` | nothing |
| `pulse/none/stopped/on` | `accent` | `accent/none/stopped/on` | `seqGate 0` |
| `pulse/none/stopped/on` | `gate` | `gate/none/stopped/on` | `seqGate 1` |
| `pulse/none/stopped/on` | `grid level` | `pulse/hit/stopped/on` | nothing |
| `pulse/none/stopped/on` | `length cut` | `pulse/none/stopped/on` | `seqGate 0` |
| `pulse/none/stopped/on` | `move` | `move/none/stopped/on` | `seqGate 0` |
| `pulse/none/stopped/on` | `pulse` | `pulse/none/stopped/on` | nothing |
| `pulse/none/stopped/on` | `replaced, a step` | `pulse/hit/stopped/on` | nothing |
| `pulse/none/stopped/on` | `replaced, none` | `pulse/none/stopped/on` | nothing |
| `pulse/none/stopped/on` | `start` | `pulse/none/playing/on` | nothing |
| `pulse/none/stopped/on` | `stop` | `pulse/none/stopped/on` | nothing |
| `pulse/none/stopped/on` | `toggle` | `pulse/hit/stopped/on` | nothing |
| `pulse/none/stopped/on` | `voice started` | `pulse/none/stopped/on` | nothing |
| `pulse/none/stopped/on` | `voice stopped` | `pulse/none/stopped/off` | nothing |
