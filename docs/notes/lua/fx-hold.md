## Must not break

- **`delay_freeze` is in no PSET and no scene** (3.8 design §7.3): its save is off (`params:set_save`, so norns' `ParamSet:write` skips it and the read hook's `pset.default` gives it no default), it is no scene field and no LFO destination or macro target. The loop's audio is in neither, as a bypass's is not.
- **A PSET load leaves a freeze as it is** (the plan's ruling 61): no PSET has a line for it, and a load that leaves the delay running sends no `setDelayFreeze`. A PSET that bypasses the delay (`delay_bypass` 1) still ends the freeze (ruling 26 over 61: the node is freed, and a freeze that outlived it would come back unasked at the lift): a read with actions through the bypass's action (below), a silent read, which runs no action, through this module's PSET read hook (`fx_hold`, #883, 3.9's ruling B2: bypass wins), which releases the freeze through `release` (so the engine hears `setDelayFreeze(0)` and a mapped controller its 0) when the read left the delay bypassed and frozen, and does nothing otherwise.
- **The delay is never bypassed and frozen** (the invariant `fx hold`, 3.9): a bypassed delay has no node, and a kept freeze would make a lifted bypass create its node frozen with the input closed. The bypass's release, the refused freeze and the read hook keep it so.
- **A clear releases a freeze first** (#912, 3.9's ruling B2): `delay_clear`'s action calls `release("delay")` before it sends, so a clear on a frozen delay sends `setDelayFreeze(0)`, then `clearDelay()`, the freeze param ends at 0, and the loop refills with what comes in (frozen, the engine would empty the loop and keep it frozen on silence with its input closed, `docs/notes/engine/delay.md`). Every way of clearing goes through the action: FX's clear row, the grid's DC, PARAMS and a MIDI map. A running delay's clear sends `clearDelay()` alone.
- **A bypass ends its effect's freeze first**: the bypass params' action (`lib/voice_mix.lua`) calls `S.lib.fx_hold.release(effect)` before it sends `setBypass`, whatever sets the bypass (a key, PARAMS, MIDI, a PSET), so the calls go `setDelayFreeze(0)`, then `setBypass(0, 1)`, the engine's kept freeze is 0 and a lifted bypass starts empty and unfrozen. `release` checks `offered(effect)` first, so the action calls it for both effects (the reverb has none: below).
- **A freeze set while its effect is bypassed is refused** (the plan's ruling 26): the freeze's action sets the param back to 0 through `set_binary_param`, so a controller mapped to it is echoed the 0 (its light follows the param). That set re-enters the action with 0, which is never refused, and costs one redundant `setDelayFreeze(0)` (the engine keeps 0 through the bypass, as the release before every bypass left it); never a `setDelayFreeze(1)`. `toggle` does nothing at all while bypassed. So a MIDI map or a PARAMS edit never leaves a freeze for a lift.
- **Both params reach the engine only through their senders** (`send_param_to_engine`): `delay_freeze` sends `engine.setDelayFreeze(value)`, `delay_clear` `engine.clearDelay()` (no argument; the trigger's action sends the value 1, so the send budget never holds a nil).
- **`toggle` and `release` go through `set_binary_param`**, so a controller mapped to `delay_freeze` follows (#538).
- The ids are `FX_HOLD`'s; 4a's FX rows and header mark and 4b's grid keys read `offered`, `frozen`, `freezable`, `toggle`, `clear` and `any_frozen`, never a param's presence (the plan's ruling 27).
- **The reverb has no freeze** (3.8's package 3a, ruling 27): the high tier's FDN, frozen, did not hold its level and its tail within 1 dB, so the freeze is cut: no `FX_HOLD.reverb`, no `reverb_freeze` param, no engine command, and `offered("reverb")` is false on every tier (a test pins it). Why: #819 and `docs/notes/engine/effects.md` (the FDN).

## Machines

### delay freeze
- **State:** `delay_bypass` (`S.lib.voice_mix.bypassed("delay")`) and `delay_freeze` (`S.lib.fx_hold.frozen("delay")`): running (neither), frozen, or bypassed. `freezable("delay")` is running or frozen.
- **Invariant:** `fx hold`: never bypassed and frozen.
- **Test:** `test/unit/fx_hold_test.lua`: "the invariant fx hold fails for a delay bypassed and frozen".

| State | Event | Next | Effect |
|---|---|---|---|
| running | freeze (`toggle`, E3, PARAMS, a MIDI map, the grid's DF) | frozen | `setDelayFreeze(1)` |
| running | clear | running | `clearDelay()` |
| running | bypass | bypassed | `setBypass(0, 1)` |
| running | a silent PSET read that bypasses | bypassed | nothing (a silent read sends nothing, and the read hook has no freeze to release) |
| running | a PSET read that leaves the delay running | running | no `setDelayFreeze` |
| frozen | release | running | `setDelayFreeze(0)` |
| frozen | clear | running | `setDelayFreeze(0)`, then `clearDelay()` (#912) |
| frozen | bypass (a key, PARAMS, a MIDI map, a PSET read with actions) | bypassed | `setDelayFreeze(0)`, then `setBypass(0, 1)` |
| frozen | a silent PSET read that bypasses | bypassed | the read hook's `setDelayFreeze(0)` (#883) |
| frozen | a PSET read that leaves the delay running | frozen | no `setDelayFreeze` |
| bypassed | freeze | bypassed | refused: the param back to 0 and one `setDelayFreeze(0)`; `toggle` does nothing |
| bypassed | clear | bypassed | `clearDelay()`, which the engine ignores while bypassed (FX's clear row is the lift there) |
| bypassed | lift | running | `setBypass(0, 0)` |

## What it owns

`lib/fx_hold.lua` (`S.lib.fx_hold`, included after `lib/delay_sync.lua`) registers one fx record, `{name = "hold", count = 2}`, so the fx group ends `delay_sync`, `delay_division`, `delay_pingpong`, `delay_freeze`, `delay_clear`.

- `delay_freeze`: binary toggle, default 0, name `delay freeze`. Its action sends the value and redraws (the screen and the grids, for 4a's and 4b's marks).
- `delay_clear`: a trigger, name `delay clear`, fired with `params:set("delay_clear", 1)` (norns never writes a trigger to a PSET). Its action releases a freeze, then sends `clearDelay()`.
- `M.FX_HOLD = {delay = {freeze_id = "delay_freeze", clear_id = "delay_clear"}}`.
- `M.offered(effect)`: true for `"delay"`, false for anything else (the reverb's freeze is cut).
- `M.frozen(effect)`: offered and its freeze param at 1. `M.any_frozen()`: any effect frozen.
- `M.freezable(effect)`: whether `toggle` would freeze or release it now, offered and not bypassed. `toggle` asks it, and so do FX's ALT+K3 and its `K3:freeze` hint, so the hint never offers what the key would not do (4a's review).
- `M.toggle(effect)`: freezes or releases through `set_binary_param`; nothing unless `freezable(effect)`.
- `M.release(effect)`: nothing for an effect not offered; otherwise sets the freeze param to 0 when it is 1.
- `M.clear()`: `params:set("delay_clear", 1)`.
- The invariant `fx hold` (Machines, above) and the PSET read hook `fx_hold` (registered at include, after the hooks of the modules included before it; it reads only the two params, so its place among them does not matter).

What a frozen delay does is the engine's (`docs/notes/engine/delay.md`): the loop's gain exactly 1, the input closed, the time held (a tempo move or a `delay_time` change under a freeze is sent as usual and waits in the engine for the release), ping-pong snapped. Lua keeps sending `setDelay` while frozen; a release then plays the time Lua last sent. FX marks its `time` row `held` while the delay is frozen (#911, `docs/notes/lua/pages/fx.md`), so the time it shows is read as the one the release plays.

Both are also FX's rows (`freeze` and `clear`, its ALT+K3 freezing the row's effect, `docs/notes/lua/pages/fx.md`), the header's frozen mark (FX's page dot as a bar) reads `any_frozen` (`docs/notes/lua/ui/header-and-flashes.md`), and both can be mapped to MIDI from PARAMS > fx.

## Tests (`test/unit/fx_hold_test.lua`)

The params (type, place, default, no PSET line, no scene field, no LFO destination), each one's send, a bypass ending the freeze first, a freeze refused while bypassed, toggle's MIDI echo, a PSET load leaving a freeze on and off as it was, a PSET that bypasses the delay ending its freeze (one that leaves it running does not), a silent read that leaves it bypassed and frozen releasing the freeze (#883; one that leaves it running keeps it), the invariant `fx hold`, a clear on a frozen delay releasing it first (#912), the reverb not offered on either tier (the cut), a tempo move under a frozen synced delay, and the plan's Review Focus 3: a frozen delay through a tempo move, a sync switch, a bypass and a PSET load.
