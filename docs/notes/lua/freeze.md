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
- **Test:** `test/unit/freeze_test.lua`: "freeze key: every cell is decided" and its rows (voice 3, `quantize_actions` on bar; the source switch goes between the synth and the input, the recall is of a scene holding the voice frozen on the source it has).

Every cell is a row: no pair of these states and events is impossible.

| State | Event | Next | Effect |
|---|---|---|---|
| `off` | `key` | `off, freeze waits` | a set of 1 waits for the bar; the header flashes `v<i> frz at bar` |
| `off` | `source switch` | `off` | nothing to unfreeze |
| `off` | `hand set 0` | `off` | nothing |
| `off` | `hand set 1` | `on` | frozen at once |
| `off` | `recall` | `on` | the scene's freeze, at once |
| `off` | `the bar` | `off` | nothing waits |
| `on` | `key` | `on, unfreeze waits` | a set of 0 waits for the bar |
| `on` | `source switch` | `off` | the source change hook unfreezes |
| `on` | `hand set 0` | `off` | unfrozen at once |
| `on` | `hand set 1` | `on` | nothing |
| `on` | `recall` | `on` | the scene's freeze |
| `on` | `the bar` | `on` | nothing waits |
| `off, freeze waits` | `key` | `off` | the waiting set is taken back, its flash ends |
| `off, freeze waits` | `source switch` | `off, freeze waits` | the set still waits; the bar freezes the new source |
| `off, freeze waits` | `hand set 0` | `off, freeze waits` | the set still waits |
| `off, freeze waits` | `hand set 1` | `on, freeze waits` | frozen now; the bar sets nothing |
| `off, freeze waits` | `recall` | `on, freeze waits` | the scene's freeze; the bar sets nothing |
| `off, freeze waits` | `the bar` | `on` | frozen |
| `off, unfreeze waits` | `key` | `off` | the waiting set is taken back |
| `off, unfreeze waits` | `source switch` | `off, unfreeze waits` | the set still waits; the bar sets nothing |
| `off, unfreeze waits` | `hand set 0` | `off, unfreeze waits` | the set still waits; the bar sets nothing |
| `off, unfreeze waits` | `hand set 1` | `on, unfreeze waits` | frozen now; the bar unfreezes |
| `off, unfreeze waits` | `recall` | `on, unfreeze waits` | the scene's freeze; the bar unfreezes |
| `off, unfreeze waits` | `the bar` | `off` | nothing changes (a toggle froze here before #864) |
| `on, freeze waits` | `key` | `on` | the waiting set is taken back |
| `on, freeze waits` | `source switch` | `off, freeze waits` | unfrozen by the hook; the bar freezes the new source |
| `on, freeze waits` | `hand set 0` | `off, freeze waits` | unfrozen now; the bar freezes |
| `on, freeze waits` | `hand set 1` | `on, freeze waits` | the set still waits; the bar sets nothing |
| `on, freeze waits` | `recall` | `on, freeze waits` | the set still waits; the bar sets nothing |
| `on, freeze waits` | `the bar` | `on` | nothing changes (a toggle unfroze here before #864) |
| `on, unfreeze waits` | `key` | `on` | the waiting set is taken back |
| `on, unfreeze waits` | `source switch` | `off, unfreeze waits` | unfrozen by the hook; the bar sets nothing (it froze the new source before #864) |
| `on, unfreeze waits` | `hand set 0` | `off, unfreeze waits` | unfrozen now; the bar sets nothing |
| `on, unfreeze waits` | `hand set 1` | `on, unfreeze waits` | the set still waits |
| `on, unfreeze waits` | `recall` | `on, unfreeze waits` | the set still waits; the bar unfreezes |
| `on, unfreeze waits` | `the bar` | `off` | unfrozen |

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
- `layout_states`: each voice frozen with VOICE's cursor on its freeze row (`test/unit/ui_layout_test.lua`, the page renders).
