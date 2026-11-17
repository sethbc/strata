## Must not break

- An action never creates a node for a voice's own note: `retrigger` calls `S.lib.sequencer.note_gate(voice)` (the voice's own gate length, not the last step's, #639, as `lib/midi_in.lua` does) and then `engine.retrigger(voice - 1, velocity)` (through `S.lib.engine_sync.retrigger(voice, velocity, "action")`, 3.7's hit door) on a running voice only, and does nothing for a stopped one; starting a voice goes through `toggle_voice` (`S.lib.engine_sync.start_voice`).
- A scene recall goes through the quantizer's `"scene"` action (`S.lib.quantize.schedule`) with the scene transition time, as a scene key does; `recall_scene` is called only inside the scheduled function, never outside it.
- Freeze, mute and fill's latch (`seq_fill`) go through `set_binary_param`, a macro through `params:set("macro_<m>", ...)`; the module sets no other param, and it sends no engine command of its own but `engine.retrigger`, through `S.lib.engine_sync.retrigger` (`toggle_voice`, `record_buffer` and `set_binary_param` reach the engine on their own).
- Every action returns true when it acted; an out-of-range argument does nothing, returns false and prints one line, `strata: <action> ignored: <why>`. A retrigger of a stopped voice returns false with no line.
- The module registers no start step, cleanup step, param or invariant, and calls the later globals (`toggle_voice`, `recall_scene`, `set_binary_param`, `record_buffer`, `pattern_clock_start`, `pattern_clock_stop`) only inside its functions.

## What it owns

`lib/io/actions.lua` (`S.lib.io_actions`): the actions crow's trigger inputs, OSC's addresses and a Teletype's calls share. Voice 0 means the selected voice. A scene is "saved" when `S.scenes[n].populated`.

| Function | Does |
|---|---|
| `recall_scene(n)` | n 1 to 16 with a saved scene |
| `next_scene()` | the next playable scene after `S.current_scene` (the stepper at 100, 0, 0: an empty or invalid slot is passed over), wrapping; with none, `no scene can play` |
| `run_voice(voice, mode)` | mode 0 stops, 1 starts, 2 toggles; a voice already as asked is left alone |
| `retrigger(voice, velocity)` | velocity clamped to 0..1 |
| `freeze(voice, mode)`, `mute(voice, mode)` | mode 0 off, 1 on, 2 toggle |
| `macro(m, value)` | m 1 to 16, value clamped to 0..1 |
| `patterns(mode)` | 0 stops, 1 plays, 2 toggles |
| `record()` | `record_buffer(S.buffer_page.slot)`, BUFFER's K3 |
| `fill(mode)` | 3.7 (ruling 10): `seq_fill`, fill's latch: mode 0 off, 1 on, 2 toggle (crow's `fill` trigger toggles; OSC's `/strata/fill`). A key's hold of fill is the grids' (`S.lib.conditions.hold_fill`), never an action's |

Tests: `test/unit/io_actions_test.lua`.
