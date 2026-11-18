## Must not break

- **`delay_freeze` is in no PSET and no scene** (3.8 design §7.3): its save is off (`params:set_save`, so norns' `ParamSet:write` skips it and the read hook's `pset.default` gives it no default), it is no scene field and no LFO destination or macro target. The loop's audio is in neither, as a bypass's is not.
- **A PSET load leaves a freeze as it is** (the plan's ruling 61): no PSET has a line for it, and nothing in this module or the read hook sets or releases a freeze at a load, so a load sends no `setDelayFreeze` of its own. A PSET that bypasses the delay (`delay_bypass` 1) still ends the freeze, through the bypass's action (below; ruling 26 over 61: the node is freed, and a freeze that outlived it would come back unasked at the lift).
- **A bypass ends its effect's freeze first**: the bypass params' action (`lib/voice_mix.lua`) calls `S.lib.fx_hold.release(effect)` before it sends `setBypass`, whatever sets the bypass (a key, PARAMS, MIDI, a PSET), so the calls go `setDelayFreeze(0)`, then `setBypass(0, 1)`, the engine's kept freeze is 0 and a lifted bypass starts empty and unfrozen. `release` checks `offered(effect)` first, so the action calls it for both effects (the reverb's has none until 3.8's package 3a).
- **A freeze set while its effect is bypassed is refused** (the plan's ruling 26): the freeze's action sets the param back to 0 through `set_binary_param`, so a controller mapped to it is echoed the 0 (its light follows the param). That set re-enters the action with 0, which is never refused, and costs one redundant `setDelayFreeze(0)` (the engine keeps 0 through the bypass, as the release before every bypass left it); never a `setDelayFreeze(1)`. `toggle` does nothing at all while bypassed. So a MIDI map or a PARAMS edit never leaves a freeze for a lift.
- **Both params reach the engine only through their senders** (`send_param_to_engine`): `delay_freeze` sends `engine.setDelayFreeze(value)`, `delay_clear` `engine.clearDelay()` (no argument; the trigger's action sends the value 1, so the send budget never holds a nil).
- **`toggle` and `release` go through `set_binary_param`**, so a controller mapped to `delay_freeze` follows (#538).
- The ids are `FX_HOLD`'s; 4a's FX rows and header mark and 4b's grid keys read `offered`, `frozen`, `toggle`, `clear` and `any_frozen`, never a param's presence (the plan's ruling 27).

## What it owns

`lib/fx_hold.lua` (`S.lib.fx_hold`, included after `lib/delay_sync.lua`) registers one fx record, `{name = "hold", count = 2}` (3a makes it 3), so the fx group ends `delay_sync`, `delay_division`, `delay_pingpong`, `delay_freeze`, `delay_clear`.

- `delay_freeze`: binary toggle, default 0, name `delay freeze`. Its action sends the value and redraws (the screen and the grids, for 4a's and 4b's marks).
- `delay_clear`: a trigger, name `delay clear`, fired with `params:set("delay_clear", 1)` (norns never writes a trigger to a PSET).
- `M.FX_HOLD = {delay = {freeze_id = "delay_freeze", clear_id = "delay_clear"}}`.
- `M.offered(effect)`: true for `"delay"`, false for anything else until 3a.
- `M.frozen(effect)`: offered and its freeze param at 1. `M.any_frozen()`: any effect frozen.
- `M.toggle(effect)`: freezes or releases through `set_binary_param`; nothing while the effect is not offered or bypassed.
- `M.release(effect)`: nothing for an effect not offered; otherwise sets the freeze param to 0 when it is 1.
- `M.clear()`: `params:set("delay_clear", 1)`.

What a frozen delay does is the engine's (`docs/notes/engine/delay.md`): the loop's gain exactly 1, the input closed, the time held (a tempo move or a `delay_time` change under a freeze is sent as usual and waits in the engine for the release), ping-pong snapped. Lua keeps sending `setDelay` while frozen; a release then plays the time Lua last sent.

Until 4a there is no FX row for either param: they are in PARAMS > fx and can be mapped to MIDI.

## Tests (`test/unit/fx_hold_test.lua`)

The params (type, place, default, no PSET line, no scene field, no LFO destination), each one's send, a bypass ending the freeze first, a freeze refused while bypassed, toggle's MIDI echo, a PSET load leaving a freeze on and off as it was, a PSET that bypasses the delay ending its freeze (one that leaves it running does not), the reverb not offered, a tempo move under a frozen synced delay, and the plan's Review Focus 3: a frozen delay through a tempo move, a sync switch, a bypass and a PSET load.
