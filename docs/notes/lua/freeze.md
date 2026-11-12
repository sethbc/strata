## Must not break

- **Freeze is not the lock.** The lock is `toggle_lock` and its state `S.frozen` (the scene field `frozen`); freeze is `v<i>_freeze` (`S.voices[i].extras.freeze`), read with `S.lib.freeze.is_frozen` and changed with `S.lib.freeze.toggle`. `lib/freeze.lua` never reads or writes `S.frozen`, and no Lua function is named `*_freeze(` (`test/unit/engine_sync_test.lua` scans for both). `[F]` is drawn only by MAIN. No user doc or README sentence says freeze together with lock, `[L]`, params or values unless it contrasts them ("unlike"); `test/unit/docs_test.lua` checks it.
- **A source switch unfreezes.** The `source_change` hook sets `v<i>_freeze` to 0 after a `v<i>_source` action (the engine has unfrozen on its own switch already). A scene recall runs no hooks: it sets the scene's freeze itself, after the source, as a discrete key.
- **The script sets `v<i>_freeze` through `set_binary_param`** (`lib/ui/params.lua`), never a plain `params:set`: `M.toggle` (every grid freeze key) and the source switch's unfreeze. norns' `Binary:set` sends no MIDI-map CC, so a controller mapped to the param in PARAMS > MAP would miss the change (#538).
- **The mode's options follow the tier** the engine runs (`S.performance.tier`): `{"hold", "spectral"}` on high, `{"hold"}` on standard, read when the params are added. A spectral mode saved on high (a PSET, a scene) clamps to hold on standard, so the engine never receives `freezeMode` 1 there (it would hold anyway).
- Randomize, mutations and the 256 fader pages never touch either param (a registered record, `fader = false`).

## Owns

- `lib/freeze.lua` (`S.lib.freeze`): the `freeze` voice-param record, the `source_change` hook, `M.FREEZE` (keys, engine names, section, modes), `M.spectral_offered()`, `M.mode_options()`, `M.is_frozen(voice_idx)`, `M.toggle(voice_idx)` (both bounds-checked: any other value is not frozen, and a toggle of it does nothing), and 3.4's `M.toggle_quantized(voice_idx)`: `M.toggle` through `S.lib.quantize.schedule("freeze<v>", ...)` (label `v<v> frz`, which fits the header flash as `v7 frz at beat`), so it waits for the beat or bar `quantize_actions` names and acts at once while it is off (a bad index schedules nothing); a press while the voice's toggle waits takes it back (`S.lib.quantize.cancel`, #625) and schedules nothing. The grids' freeze keys call it; `M.toggle` itself, VOICE's row and a mapped CC never wait (`docs/notes/lua/quantize.md`).
- Its unit tests: `test/unit/freeze_test.lua`. The engine side: `docs/notes/engine/freeze.md`.

## The params

The record `freeze` (count 2, `S.register_voice_params`):

| Param | Type | Default | Grain key | Scene |
|---|---|---|---|---|
| `v<i>_freeze` | binary, toggle | 0 | `freeze` (0/1) | discrete `{0, 1}`, default 0 |
| `v<i>_freeze_mode` | option `hold`, `spectral` (high) / `hold` (standard) | 1 | `freezeMode` (option − 1) | discrete `{1, 2}`, default 1 |

- The senders reach the engine only while the voice runs; the voice sync sends both after the source (registration order: after history), and a start sends them before its `voiceOn` (#325). A frozen stopped voice is frozen on the engine by its start; one unfrozen while stopped is unfrozen before its grain synth exists.
- `v<i>_freeze`'s action redraws the grid (the layouts' freeze keys; the param actions already request the screen's redraw for MAIN's `[F]`).
- The `source_change` hooks run before the source action's sync (`lib/params_setup.lua`), so a switch of a frozen voice sends `freeze` 0 (the hook's, then the sync's) and never the old 1: the engine, which unfroze on its own switch, never freezes the new source for a moment.
- **MIDI**: no code of its own; norns' PARAMS > MAP maps a CC to `v<i>_freeze` like any param.

## Where it shows

- **VOICE**: the mix section ends with `freeze` (and `freeze mode` on high), through the record's `voice_rows` (`when` hides the mode row on standard). E3 toggles and picks, as on any VOICE row.
- **MAIN**: `[F]` on the status row (y 26) after `[L]` and `[T]` (`docs/notes/lua/pages/main.md`).
- **Grid**: 256 page 4 column 12, and row 16 columns 1-7 while column 8 of row 16 is held; 128h page 4 column 12; 128v sources page row 14. LEDs 15 frozen, 3 not. The 64 has no room (`docs/notes/lua/grid/layout_256.md`, `layout_128h.md`, `layout_128v.md`).
- `layout_states`: each voice frozen with VOICE's cursor on its freeze row (`test/unit/ui_layout_test.lua`, the page renders).
