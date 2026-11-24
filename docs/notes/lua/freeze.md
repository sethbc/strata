## Must not break

- **Freeze is not the lock.** The lock is `toggle_lock` and its state `S.locked` (the scene field `locked`, since scene format 9); freeze is `v<i>_freeze` (`S.voices[i].values.freeze`), read with `S.lib.freeze.is_frozen` and changed with `S.lib.freeze.toggle`. `lib/freeze.lua` never names `S.locked` or `toggle_lock`, no file under `lib/` names `S.frozen` or a field `frozen` (`.is_frozen` and `.frozen_level` are the audio freeze's), and no Lua function is named `*_freeze(` (`test/unit/engine_sync_test.lua` scans for all three). `[F]` is drawn only by MAIN. No user doc or README sentence says freeze together with lock, `[L]`, params or values unless it contrasts them ("unlike"); `test/unit/docs_test.lua` checks it. Lock is the user's name for `S.locked` wherever it shows (`[L]`, the hints, the grid's lock keys, `toggle_lock`); "freeze" is only 3.2's audio freeze, and no code names the lock with it.
- **A source switch unfreezes.** The `source_change` hook sets `v<i>_freeze` to 0 after a `v<i>_source` action (the engine has unfrozen on its own switch already). A scene recall runs no hooks: it sets the scene's freeze itself, after the source, as a discrete key.
- **The script sets `v<i>_freeze` through `set_binary_param`** (`lib/ui/params.lua`), never a plain `params:set`: `M.toggle`, a grid freeze key's set (`M.toggle_quantized`) and the source switch's unfreeze. norns' `Binary:set` sends no MIDI-map CC, so a controller mapped to the param in PARAMS > MAP would miss the change (#538).
- **The mode's options follow the tier** the engine runs (`S.performance.tier`): `{"hold", "spectral"}` on high, `{"hold"}` on standard, read when the params are added. A spectral mode saved on high (a PSET, a scene) clamps to hold on standard, so the engine never receives `freezeMode` 1 there (it would hold anyway).
- Randomize, mutations and the 256 fader pages never touch either param (a registered record, `fader = false`).
- **A freeze the engine ended itself goes to 0 with no unfreeze sent back** (#858). The engine abandons a hold whose copy never landed (late or with no head from the server `copyAttempts` times, or its span refused; `docs/notes/engine/freeze.md`) and reports it on the `freezeEnded` poll; `freeze_ended` sets `v<i>_freeze` to 0 through `set_binary_param` (its action, the freeze-change hooks, MAIN's `[F]` and the grid follow, and a mapped controller hears it) while the record's `reaches` refuses the `freeze` key for that voice, so the action's send reaches no engine (the engine has unfrozen already; `S.engine_param_values` records the 0). Only a count newer than the voice's last acts, and only on a frozen voice. A known race: a refreeze within milliseconds of the engine abandoning a hold can leave Lua showing the voice unfrozen while the engine holds the new freeze; it heals at the next press.
- **A freeze key sets the value its press asked for, never a toggle** (#864): `M.toggle_quantized` takes the opposite of the voice's freeze at the press and, at the beat or bar, sets that value (nothing when the voice already has it), so a source switch, a hand set or a recall before then never turns the key's unfreeze into a freeze. A second press while the set waits takes it back; nothing else does.

## Machines

### freeze key
- **State:** the voice's freeze (`v<i>_freeze`, `S.voices[i].values.freeze`, read with `S.lib.freeze.is_frozen(i)`) and whether its key's set waits (the action `freeze<i>`, `S.lib.quantize.waiting("freeze<i>")`); the value that waits is the scheduled function's own, held nowhere else.
- **Invariant:** none: every pair of the freeze and a waiting set is legal, and the waiting action's clock is the `quantize` machine's (`lib/quantize.lua`).
- **Test:** `test/unit/freeze_test.lua`: "freeze key: every cell is decided" and its rows (voice 3, `quantize_actions` on bar; the source switch goes between the synth and the input, the recall is of a scene holding the opposite of the voice's freeze on the other source: it sets the scene's source, with no source change hook, then the scene's freeze).

Every cell is a row: no pair of these states and events is impossible.

| State | Event | Next | Effect |
|---|---|---|---|
| `off` | `key` | `off, freeze waits` | a set of 1 waits for the bar; the header flashes `v<i> frz at bar` |
| `off` | `source switch` | `off` | nothing to unfreeze |
| `off` | `hand set 0` | `off` | nothing |
| `off` | `hand set 1` | `on` | frozen at once |
| `off` | `recall` | `on` | the scene's source, then its freeze, at once |
| `off` | `the bar` | `off` | nothing waits |
| `on` | `key` | `on, unfreeze waits` | a set of 0 waits for the bar |
| `on` | `source switch` | `off` | the source change hook unfreezes |
| `on` | `hand set 0` | `off` | unfrozen at once |
| `on` | `hand set 1` | `on` | nothing |
| `on` | `recall` | `off` | the scene's source, then its freeze (0), at once |
| `on` | `the bar` | `on` | nothing waits |
| `off, freeze waits` | `key` | `off` | the waiting set is taken back, its flash ends |
| `off, freeze waits` | `source switch` | `off, freeze waits` | the set still waits; the bar freezes the new source |
| `off, freeze waits` | `hand set 0` | `off, freeze waits` | the set still waits |
| `off, freeze waits` | `hand set 1` | `on, freeze waits` | frozen now; the bar sets nothing |
| `off, freeze waits` | `recall` | `on, freeze waits` | frozen by the scene; the bar sets nothing |
| `off, freeze waits` | `the bar` | `on` | frozen |
| `off, unfreeze waits` | `key` | `off` | the waiting set is taken back |
| `off, unfreeze waits` | `source switch` | `off, unfreeze waits` | the set still waits; the bar sets nothing |
| `off, unfreeze waits` | `hand set 0` | `off, unfreeze waits` | the set still waits; the bar sets nothing |
| `off, unfreeze waits` | `hand set 1` | `on, unfreeze waits` | frozen now; the bar unfreezes |
| `off, unfreeze waits` | `recall` | `on, unfreeze waits` | frozen by the scene; the bar unfreezes |
| `off, unfreeze waits` | `the bar` | `off` | nothing changes (a toggle froze here before #864) |
| `on, freeze waits` | `key` | `on` | the waiting set is taken back |
| `on, freeze waits` | `source switch` | `off, freeze waits` | unfrozen by the hook; the bar freezes the new source |
| `on, freeze waits` | `hand set 0` | `off, freeze waits` | unfrozen now; the bar freezes |
| `on, freeze waits` | `hand set 1` | `on, freeze waits` | the set still waits; the bar sets nothing |
| `on, freeze waits` | `recall` | `off, freeze waits` | unfrozen by the scene; the bar freezes the scene's source |
| `on, freeze waits` | `the bar` | `on` | nothing changes (a toggle unfroze here before #864) |
| `on, unfreeze waits` | `key` | `on` | the waiting set is taken back |
| `on, unfreeze waits` | `source switch` | `off, unfreeze waits` | unfrozen by the hook; the bar sets nothing (it froze the new source before #864) |
| `on, unfreeze waits` | `hand set 0` | `off, unfreeze waits` | unfrozen now; the bar sets nothing |
| `on, unfreeze waits` | `hand set 1` | `on, unfreeze waits` | the set still waits |
| `on, unfreeze waits` | `recall` | `off, unfreeze waits` | unfrozen by the scene; the bar sets nothing |
| `on, unfreeze waits` | `the bar` | `off` | unfrozen |

### voice kind
- **State:** what a voice is to its notes, derived and stored nowhere: its source (`S.voices[i].source`, read with `voice_uses_synth`, `voice_uses_buffer`, `voice_uses_voice`; anything else is the input), its freeze (`S.lib.freeze.is_frozen(i)`) and whether it runs (`S.voices[i].active`). A frozen synth voice is the one kind the freeze makes (`frozen_synth` in `lib/notes.lua`): a frozen buffer, input or voice source voice is still its source's kind. Four places derive it, each for its own reason: `frozen_synth` and `own_pitch` (`lib/notes.lua`), `own_setters` (`lib/midi_in.lua`) and `placement` (`lib/expression.lua`); in the last three a voice source voice is an input voice, as its notes are in the engine (#873, `docs/notes/lua/expression.md`).
- **Invariant:** none: every kind is legal stopped or running; what each holds (a stopped voice no extra note, a running one no parked own note alone) is the `notes` machine's (`docs/notes/lua/notes.md`).
- **Two facts:** `v<i>_freeze` holds what the player asked for and what the engine holds; they part when the engine ends a hold itself (#858: `freezeEnded` sets the param to 0 with nothing sent back) and, for a moment, inside a source switch by hand, where the grain-restart hooks see the new source with the old freeze still 1: a frozen buffer, input or voice source voice switched to its synth source is a frozen synth voice there, so the notes module's hook takes a reference, which its freeze hook drops as the source hook unfreezes the voice.
- **Test:** `test/unit/freeze_test.lua`: "voice kind: every cell is decided" and its rows (voice 3; it enters at 440 Hz, note 69, where a running frozen synth voice takes its reference, then its freq goes to 220 Hz, note 57; a running voice holds an own note and one extra note; the buffer states read slot 1 and the voice source states voice 1's ring, and `source buffer 2` and `source voice 2` switch to slot 2 and voice 2's ring, so the same kind again is a switch too; a recall is an instant recall of a scene captured then, with the one field changed). Each row's check asserts the freeze param, the freeze reference (`S.lib.notes.freeze_reference`), the extra notes held, the `scaleNote` the engine holds for a running voice (the last one sent: a recall's set of the freq resends it, as a hand set does) or that the event sent none to a stopped voice, and that a model of the engine's slots (`test/notes_model.lua`) agrees with Lua's held notes; a recall's source set also counts the `freeze` sends it made (one, the end's sync's, on a running voice whose source the scene changed; none otherwise), which would show the source hooks running in a recall. The row of a frozen synth voice a recall moves to slot 2 drives on: a recall back to the synth source, the freeze kept, makes it a frozen synth voice again, which cuts the extra note and takes a fresh reference (ruling 58, #690).

By hand and in a recall a source set differs in one thing: by hand the source change hooks run (the freeze goes to 0, `scaleNote` is resent) and a running voice is synced at once; in a recall no hook runs, the freeze is the scene's (here the one captured, so a frozen synth voice moved to another source stays frozen there), and a running voice whose source changed is synced at the recall's end, then `S.lib.notes.recall_switched` cuts its extra notes if it ended a frozen synth voice. A freeze set, a start and a stop are the same either way. The table's start and stop by hand are the actions' `run_voice` (crow, ii, OSC: on or off), which reaches the same `toggle_voice` K3 and the grid call directly, and only when the voice is not already as asked; so a start of a running voice and a stop of a stopped one are rows that change nothing, by hand (nothing sent) and in a recall (no start, stop, switch, note or freeze sent). Every cell is a row. The effects name the freeze param, the reference (nil, 69 kept, or 57 taken or read: a stopped frozen synth voice keeps none and gives its freq's note), the extra notes and the `scaleNote` (57, the freq's note; 69, the reference; 60, root C + 60 for a buffer, input or voice source voice).

| State | Event | Next | Effect |
|---|---|---|---|
| `synth, running` | `source synth, by hand` | `synth, running` | the same source: nothing; scaleNote 57 |
| `synth, running` | `source buffer 2, by hand` | `buffer, running` | switched, synced; the extra kept; scaleNote 60 |
| `synth, running` | `source input, by hand` | `input, running` | switched, synced; the extra kept; scaleNote 60 |
| `synth, running` | `source voice 2, by hand` | `voice source, running` | switched, synced; the extra kept; scaleNote 60 |
| `synth, running` | `freeze 1, by hand` | `frozen synth, running` | reference 57 taken; the extra cut; scaleNote 57 |
| `synth, running` | `freeze 0, by hand` | `synth, running` | nothing |
| `synth, running` | `stop, by hand` | `synth, stopped` | the notes forgotten |
| `synth, running` | `source synth, in a recall` | `synth, running` | nothing changes; the freq's set resends scaleNote 57 |
| `synth, running` | `source buffer 2, in a recall` | `buffer, running` | switched, synced at the end; the extra kept; scaleNote 60 |
| `synth, running` | `source input, in a recall` | `input, running` | switched, synced at the end; the extra kept; scaleNote 60 |
| `synth, running` | `source voice 2, in a recall` | `voice source, running` | switched, synced at the end; the extra kept; scaleNote 60 |
| `synth, running` | `freeze 1, in a recall` | `frozen synth, running` | reference 57 taken; the extra cut; scaleNote 57 |
| `synth, running` | `freeze 0, in a recall` | `synth, running` | nothing |
| `synth, running` | `stop, in a recall` | `synth, stopped` | stopped at its entry; the notes forgotten |
| `frozen synth, running` | `source synth, by hand` | `frozen synth, running` | the same source: nothing; reference 69 kept |
| `frozen synth, running` | `source buffer 2, by hand` | `buffer, running` | the source hook unfreezes; reference gone; the extra kept; scaleNote 60 |
| `frozen synth, running` | `source input, by hand` | `input, running` | the source hook unfreezes; reference gone; the extra kept; scaleNote 60 |
| `frozen synth, running` | `source voice 2, by hand` | `voice source, running` | the source hook unfreezes; reference gone; the extra kept; scaleNote 60 |
| `frozen synth, running` | `source synth, in a recall` | `frozen synth, running` | nothing changes; reference 69 kept, scaleNote 69 |
| `frozen synth, running` | `source buffer 2, in a recall` | `buffer, running` | still frozen (the scene's), now a buffer voice; reference gone; the extra kept; scaleNote 60 |
| `frozen synth, running` | `source input, in a recall` | `input, running` | still frozen, now an input voice; reference gone; the extra kept; scaleNote 60 |
| `frozen synth, running` | `source voice 2, in a recall` | `voice source, running` | still frozen, now a voice source voice; reference gone; the extra kept; scaleNote 60 |
| `frozen synth, running` | `freeze 1, by hand` | `frozen synth, running` | nothing; reference 69 kept |
| `frozen synth, running` | `freeze 0, by hand` | `synth, running` | reference gone; the extra kept; scaleNote 57 |
| `frozen synth, running` | `stop, by hand` | `frozen synth, stopped` | the notes and the reference forgotten |
| `frozen synth, running` | `freeze 1, in a recall` | `frozen synth, running` | nothing; reference 69 kept |
| `frozen synth, running` | `freeze 0, in a recall` | `synth, running` | reference gone; the extra kept; scaleNote 57 |
| `frozen synth, running` | `stop, in a recall` | `frozen synth, stopped` | the notes and the reference forgotten |
| `buffer, running` | `source synth, by hand` | `synth, running` | switched, synced; the extra kept; scaleNote 57 |
| `buffer, running` | `source buffer 2, by hand` | `buffer, running` | switched to slot 2, synced; the extra kept; scaleNote 60 |
| `buffer, running` | `source input, by hand` | `input, running` | switched, synced; the extra kept; scaleNote 60 |
| `buffer, running` | `source voice 2, by hand` | `voice source, running` | switched, synced; the extra kept; scaleNote 60 |
| `buffer, running` | `freeze 1, by hand` | `buffer, running` | frozen; the extra kept (its notes are grains already) |
| `buffer, running` | `freeze 0, by hand` | `buffer, running` | nothing |
| `buffer, running` | `stop, by hand` | `buffer, stopped` | the notes forgotten |
| `input, running` | `source synth, by hand` | `synth, running` | switched, synced; the extra kept; scaleNote 57 |
| `input, running` | `source buffer 2, by hand` | `buffer, running` | switched, synced; the extra kept; scaleNote 60 |
| `input, running` | `source input, by hand` | `input, running` | the same source: nothing |
| `input, running` | `source voice 2, by hand` | `voice source, running` | switched, synced; the extra kept; scaleNote 60 |
| `input, running` | `freeze 1, by hand` | `input, running` | frozen; the extra kept |
| `input, running` | `freeze 0, by hand` | `input, running` | nothing |
| `input, running` | `stop, by hand` | `input, stopped` | the notes forgotten |
| `voice source, running` | `source synth, by hand` | `synth, running` | switched, synced; the extra kept; scaleNote 57 |
| `voice source, running` | `source buffer 2, by hand` | `buffer, running` | switched, synced; the extra kept; scaleNote 60 |
| `voice source, running` | `source input, by hand` | `input, running` | switched, synced; the extra kept; scaleNote 60 |
| `voice source, running` | `source voice 2, by hand` | `voice source, running` | switched to voice 2's ring, synced; the extra kept; scaleNote 60 |
| `voice source, running` | `freeze 1, by hand` | `voice source, running` | frozen; the extra kept |
| `voice source, running` | `freeze 0, by hand` | `voice source, running` | nothing |
| `voice source, running` | `stop, by hand` | `voice source, stopped` | the notes forgotten |
| `buffer, running` | `source synth, in a recall` | `synth, running` | switched, synced at the end; unfrozen, so the extra kept; scaleNote 57 |
| `buffer, running` | `source buffer 2, in a recall` | `buffer, running` | switched to slot 2, synced at the end; the extra kept; scaleNote 60 |
| `buffer, running` | `source input, in a recall` | `input, running` | switched, synced at the end; the extra kept; scaleNote 60 |
| `buffer, running` | `source voice 2, in a recall` | `voice source, running` | switched, synced at the end; the extra kept; scaleNote 60 |
| `buffer, running` | `freeze 1, in a recall` | `buffer, running` | frozen; the extra kept |
| `buffer, running` | `freeze 0, in a recall` | `buffer, running` | nothing |
| `buffer, running` | `stop, in a recall` | `buffer, stopped` | the notes forgotten |
| `input, running` | `source synth, in a recall` | `synth, running` | switched, synced at the end; the extra kept; scaleNote 57 |
| `input, running` | `source buffer 2, in a recall` | `buffer, running` | switched, synced at the end; the extra kept; scaleNote 60 |
| `input, running` | `source input, in a recall` | `input, running` | nothing changes |
| `input, running` | `source voice 2, in a recall` | `voice source, running` | switched, synced at the end; the extra kept; scaleNote 60 |
| `input, running` | `freeze 1, in a recall` | `input, running` | frozen; the extra kept |
| `input, running` | `freeze 0, in a recall` | `input, running` | nothing |
| `input, running` | `stop, in a recall` | `input, stopped` | the notes forgotten |
| `voice source, running` | `source synth, in a recall` | `synth, running` | switched, synced at the end; the extra kept; scaleNote 57 |
| `voice source, running` | `source buffer 2, in a recall` | `buffer, running` | switched, synced at the end; the extra kept; scaleNote 60 |
| `voice source, running` | `source input, in a recall` | `input, running` | switched, synced at the end; the extra kept; scaleNote 60 |
| `voice source, running` | `source voice 2, in a recall` | `voice source, running` | switched to voice 2's ring, synced at the end; the extra kept; scaleNote 60 |
| `voice source, running` | `freeze 1, in a recall` | `voice source, running` | frozen; the extra kept |
| `voice source, running` | `freeze 0, in a recall` | `voice source, running` | nothing |
| `voice source, running` | `stop, in a recall` | `voice source, stopped` | the notes forgotten |
| `synth, stopped` | `source synth, by hand` | `synth, stopped` | the same source: nothing |
| `synth, stopped` | `source buffer 2, by hand` | `buffer, stopped` | the engine records it; no sync, no scaleNote |
| `synth, stopped` | `source input, by hand` | `input, stopped` | the engine records it |
| `synth, stopped` | `source voice 2, by hand` | `voice source, stopped` | the engine records it |
| `synth, stopped` | `freeze 1, by hand` | `frozen synth, stopped` | frozen; no reference kept (asked, 57) |
| `synth, stopped` | `freeze 0, by hand` | `synth, stopped` | nothing |
| `synth, stopped` | `start, by hand` | `synth, running` | started; scaleNote 57 |
| `synth, stopped` | `source synth, in a recall` | `synth, stopped` | nothing |
| `synth, stopped` | `source buffer 2, in a recall` | `buffer, stopped` | the engine records it |
| `synth, stopped` | `source input, in a recall` | `input, stopped` | the engine records it |
| `synth, stopped` | `source voice 2, in a recall` | `voice source, stopped` | the engine records it |
| `synth, stopped` | `freeze 1, in a recall` | `frozen synth, stopped` | frozen; no reference kept (asked, 57) |
| `synth, stopped` | `freeze 0, in a recall` | `synth, stopped` | nothing |
| `synth, stopped` | `start, in a recall` | `synth, running` | started after its last entry; scaleNote 57 |
| `frozen synth, stopped` | `source synth, by hand` | `frozen synth, stopped` | the same source: nothing |
| `frozen synth, stopped` | `source buffer 2, by hand` | `buffer, stopped` | the source hook unfreezes |
| `frozen synth, stopped` | `source input, by hand` | `input, stopped` | the source hook unfreezes |
| `frozen synth, stopped` | `source voice 2, by hand` | `voice source, stopped` | the source hook unfreezes |
| `frozen synth, stopped` | `source synth, in a recall` | `frozen synth, stopped` | nothing |
| `frozen synth, stopped` | `source buffer 2, in a recall` | `buffer, stopped` | still frozen (the scene's), now a buffer voice |
| `frozen synth, stopped` | `source input, in a recall` | `input, stopped` | still frozen, now an input voice |
| `frozen synth, stopped` | `source voice 2, in a recall` | `voice source, stopped` | still frozen, now a voice source voice |
| `frozen synth, stopped` | `freeze 1, by hand` | `frozen synth, stopped` | nothing |
| `frozen synth, stopped` | `freeze 0, by hand` | `synth, stopped` | unfrozen |
| `frozen synth, stopped` | `start, by hand` | `frozen synth, running` | started; reference 57 taken at the start; scaleNote 57 |
| `frozen synth, stopped` | `freeze 1, in a recall` | `frozen synth, stopped` | nothing |
| `frozen synth, stopped` | `freeze 0, in a recall` | `synth, stopped` | unfrozen |
| `frozen synth, stopped` | `start, in a recall` | `frozen synth, running` | started after its last entry; reference 57 taken; scaleNote 57 |
| `buffer, stopped` | `source synth, by hand` | `synth, stopped` | the engine records it |
| `buffer, stopped` | `source buffer 2, by hand` | `buffer, stopped` | slot 2, recorded |
| `buffer, stopped` | `source input, by hand` | `input, stopped` | the engine records it |
| `buffer, stopped` | `source voice 2, by hand` | `voice source, stopped` | the engine records it |
| `buffer, stopped` | `freeze 1, by hand` | `buffer, stopped` | frozen, for its start |
| `buffer, stopped` | `freeze 0, by hand` | `buffer, stopped` | nothing |
| `buffer, stopped` | `start, by hand` | `buffer, running` | started; scaleNote 60 |
| `input, stopped` | `source synth, by hand` | `synth, stopped` | the engine records it |
| `input, stopped` | `source buffer 2, by hand` | `buffer, stopped` | the engine records it |
| `input, stopped` | `source input, by hand` | `input, stopped` | the same source: nothing |
| `input, stopped` | `source voice 2, by hand` | `voice source, stopped` | the engine records it |
| `input, stopped` | `freeze 1, by hand` | `input, stopped` | frozen, for its start |
| `input, stopped` | `freeze 0, by hand` | `input, stopped` | nothing |
| `input, stopped` | `start, by hand` | `input, running` | started; scaleNote 60 |
| `voice source, stopped` | `source synth, by hand` | `synth, stopped` | the engine records it |
| `voice source, stopped` | `source buffer 2, by hand` | `buffer, stopped` | the engine records it |
| `voice source, stopped` | `source input, by hand` | `input, stopped` | the engine records it |
| `voice source, stopped` | `source voice 2, by hand` | `voice source, stopped` | voice 2's ring, recorded |
| `voice source, stopped` | `freeze 1, by hand` | `voice source, stopped` | frozen, for its start |
| `voice source, stopped` | `freeze 0, by hand` | `voice source, stopped` | nothing |
| `voice source, stopped` | `start, by hand` | `voice source, running` | started; scaleNote 60 |
| `buffer, stopped` | `source synth, in a recall` | `synth, stopped` | the engine records it |
| `buffer, stopped` | `source buffer 2, in a recall` | `buffer, stopped` | slot 2, recorded |
| `buffer, stopped` | `source input, in a recall` | `input, stopped` | the engine records it |
| `buffer, stopped` | `source voice 2, in a recall` | `voice source, stopped` | the engine records it |
| `buffer, stopped` | `freeze 1, in a recall` | `buffer, stopped` | frozen, for its start |
| `buffer, stopped` | `freeze 0, in a recall` | `buffer, stopped` | nothing |
| `buffer, stopped` | `start, in a recall` | `buffer, running` | started after its last entry; scaleNote 60 |
| `input, stopped` | `source synth, in a recall` | `synth, stopped` | the engine records it |
| `input, stopped` | `source buffer 2, in a recall` | `buffer, stopped` | the engine records it |
| `input, stopped` | `source input, in a recall` | `input, stopped` | nothing |
| `input, stopped` | `source voice 2, in a recall` | `voice source, stopped` | the engine records it |
| `input, stopped` | `freeze 1, in a recall` | `input, stopped` | frozen, for its start |
| `input, stopped` | `freeze 0, in a recall` | `input, stopped` | nothing |
| `input, stopped` | `start, in a recall` | `input, running` | started after its last entry; scaleNote 60 |
| `voice source, stopped` | `source synth, in a recall` | `synth, stopped` | the engine records it |
| `voice source, stopped` | `source buffer 2, in a recall` | `buffer, stopped` | the engine records it |
| `voice source, stopped` | `source input, in a recall` | `input, stopped` | the engine records it |
| `voice source, stopped` | `source voice 2, in a recall` | `voice source, stopped` | voice 2's ring, recorded |
| `voice source, stopped` | `freeze 1, in a recall` | `voice source, stopped` | frozen, for its start |
| `voice source, stopped` | `freeze 0, in a recall` | `voice source, stopped` | nothing |
| `voice source, stopped` | `start, in a recall` | `voice source, running` | started after its last entry; scaleNote 60 |
| `synth, running` | `start, by hand` | `synth, running` | nothing: it runs; scaleNote 57, nothing sent |
| `synth, running` | `start, in a recall` | `synth, running` | nothing: it runs; scaleNote 57; no start, note or freeze sent |
| `frozen synth, running` | `start, by hand` | `frozen synth, running` | nothing: it runs; reference 69 kept, nothing sent |
| `frozen synth, running` | `start, in a recall` | `frozen synth, running` | nothing: it runs; reference 69 kept; no start, note or freeze sent |
| `buffer, running` | `start, by hand` | `buffer, running` | nothing: it runs, nothing sent |
| `buffer, running` | `start, in a recall` | `buffer, running` | nothing: it runs; no start, note or freeze sent |
| `input, running` | `start, by hand` | `input, running` | nothing: it runs, nothing sent |
| `input, running` | `start, in a recall` | `input, running` | nothing: it runs; no start, note or freeze sent |
| `voice source, running` | `start, by hand` | `voice source, running` | nothing: it runs, nothing sent |
| `voice source, running` | `start, in a recall` | `voice source, running` | nothing: it runs; no start, note or freeze sent |
| `synth, stopped` | `stop, by hand` | `synth, stopped` | nothing: it is stopped, nothing sent |
| `synth, stopped` | `stop, in a recall` | `synth, stopped` | nothing: it is stopped; no stop or note sent |
| `frozen synth, stopped` | `stop, by hand` | `frozen synth, stopped` | nothing: it is stopped, nothing sent |
| `frozen synth, stopped` | `stop, in a recall` | `frozen synth, stopped` | nothing: it is stopped; no stop or note sent |
| `buffer, stopped` | `stop, by hand` | `buffer, stopped` | nothing: it is stopped, nothing sent |
| `buffer, stopped` | `stop, in a recall` | `buffer, stopped` | nothing: it is stopped; no stop or note sent |
| `input, stopped` | `stop, by hand` | `input, stopped` | nothing: it is stopped, nothing sent |
| `input, stopped` | `stop, in a recall` | `input, stopped` | nothing: it is stopped; no stop or note sent |
| `voice source, stopped` | `stop, by hand` | `voice source, stopped` | nothing: it is stopped, nothing sent |
| `voice source, stopped` | `stop, in a recall` | `voice source, stopped` | nothing: it is stopped; no stop or note sent |

## Owns

- `lib/freeze.lua` (`S.lib.freeze`): the `freeze` voice-param record, the `source_change` hook, `M.FREEZE` (keys, engine names, section, modes), `M.spectral_offered()`, `M.mode_options()`, `M.is_frozen(voice_idx)`, `M.toggle(voice_idx)` (both bounds-checked: any other value is not frozen, and a toggle of it does nothing), and 3.4's `M.toggle_quantized(voice_idx)`: a set of the value the press asked for (the opposite of the voice's freeze at the press, #864) through `set_binary_param`, scheduled with `S.lib.quantize.schedule("freeze<v>", ...)` (label `v<v> frz`, which fits the header flash as `v7 frz at beat`), so it waits for the beat or bar `quantize_actions` names and acts at once while it is off (a bad index schedules nothing; at the bar a voice that already has the value is left alone); a press while the voice's set waits takes it back (`S.lib.quantize.cancel`, #625) and schedules nothing. The grids' freeze keys call it; `M.toggle` itself, VOICE's row and a mapped CC never wait (`docs/notes/lua/quantize.md`).
- The `freezeEnded` poll (`M.FREEZE.ended_poll`; start step `freeze_poll`, 66, cleanup step `freeze_poll`, 133): its value is `count * NUM_VOICES + voice`, the engine voice (Lua's `voice + 1`) and the voice's freezes the engine ended on its own, counted from 1 (`freezeEndedValue`, `docs/notes/engine/buffers.md`, The polls' encodings). A repeat (a value request resends the last report), an older count, a voice not frozen and a value that is not a finite number at least 0 do nothing. The record's `reaches` is false only for the `freeze` key of the voice whose report is being applied, inside that set.
- Its unit tests: `test/unit/freeze_test.lua`. The engine side: `docs/notes/engine/freeze.md`.

## The params

The record `freeze` (count 2, `S.register_voice_params`):

| Param | Type | Default | Grain key | Scene |
|---|---|---|---|---|
| `v<i>_freeze` | binary, toggle | 0 | `freeze` (0/1) | discrete `{0, 1}`, default 0 |
| `v<i>_freeze_mode` | option `hold`, `spectral` (high) / `hold` (standard) | 1 | `freezeMode` (option − 1) | discrete `{1, 2}`, default 1 |

- The senders reach the engine only while the voice runs; the voice sync sends both after the source (registration order: after history), and a start sends them before its `voiceOn` (#325). A frozen stopped voice is frozen on the engine by its start; one unfrozen while stopped is unfrozen before its grain synth exists.
- `v<i>_freeze`'s action runs the freeze-change hooks (3.5, `S.registry.freeze_change`, `fn(voice_idx, value == 1)`; the notes module's, from 1b, releases a synth voice's extra notes as it freezes), once the value is stored and sent, each through `S.lib.ui_frame.contained_call` (one that raises prints `strata: freeze change hook failed: ` and its traceback once per distinct message per hook, and the rest still run), then redraws the grid (the voices page's FZ keys; the param actions already request the screen's redraw for MAIN's `[F]`).
- The `source_change` hooks run before the source action's sync (`lib/params_setup.lua`), so a switch of a frozen voice sends `freeze` 0 (the hook's, then the sync's) and never the old 1: the engine, which unfroze on its own switch, never freezes the new source for a moment.
- **MIDI**: no code of its own; norns' PARAMS > MAP maps a CC to `v<i>_freeze` like any param.

## Where it shows

- **VOICE**: the mix section ends with `freeze` (and `freeze mode` on high), through the record's `voice_rows` (`when` hides the mode row on standard). E3 toggles and picks, as on any VOICE row.
- **MAIN**: `[F]` on the status row (y 26) after `[L]` and `[T]` (`docs/notes/lua/pages/main.md`).
- **Grid**: the voices page's FZ key (page 6, x 4 of voice v's line, on every layout and the 64's left half) calls `M.toggle_quantized(v)` and lights from `M.is_frozen(v)`: 15 frozen, 3 not, so it shows the state, never a waiting set (`docs/notes/lua/grid/pages/voices.md`).
- `layout_states`: each voice frozen with VOICE's cursor on its freeze row (`test/unit/ui_layout_voice_1_test.lua` to `_3`, the page renders).
