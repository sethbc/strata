## Must not break

- **The freezes are in no PSET and no scene** (3.8 design §7.3; 3.9's reverb freeze design §4): `delay_freeze` and `reverb_freeze` have their save off (`params:set_save`, so norns' `ParamSet:write` skips them and the read hook's `pset.default` gives them no default), and neither is a scene field, an LFO destination or a macro target. The held audio is in neither, as a bypass's is not.
- **A PSET load leaves a freeze as it is** (the plan's ruling 61): no PSET has a line for it, and a load that leaves its effect running sends no freeze. A PSET that bypasses the effect (`delay_bypass` or `reverb_bypass` 1) still ends its freeze (ruling 26 over 61: the node is freed, and a freeze that outlived it would come back unasked at the lift): a read with actions through the bypass's action (below), a silent read, which runs no action, through this module's PSET read hook (`fx_hold`, #883, 3.9's ruling B2: bypass wins), which releases each effect's freeze through `release` (so the engine hears `setDelayFreeze(0)` or `setReverbFreeze(0)` and a mapped controller its 0) when the read left that effect bypassed and frozen, and does nothing otherwise.
- **No effect is ever bypassed and frozen** (the invariant `fx hold`, 3.9): a bypassed effect has no node, and a kept freeze would make a lifted bypass create its node frozen with the input closed. The bypass's release, the refused freeze and the read hook keep it so. "Frozen" is `frozen(effect)`, which reads the param only where the freeze is offered, so the standard tier's `reverb_freeze` (refused there) is never frozen.
- **A clear releases the delay's freeze first** (#912, 3.9's ruling B2): `delay_clear`'s action calls `release("delay")` before it sends, so a clear on a frozen delay sends `setDelayFreeze(0)`, then `clearDelay()`, the freeze param ends at 0, and the loop refills with what comes in (frozen, the engine would empty the loop and keep it frozen on silence with its input closed, `docs/notes/engine/delay.md`). Every way of clearing goes through the action: FX's clear row, the grid's DC, PARAMS and a MIDI map. A running delay's clear sends `clearDelay()` alone. The reverb has no clear (a bypass empties it), and a clear leaves a frozen reverb frozen.
- **A bypass ends its effect's freeze first**: the bypass params' action (`lib/voice_mix.lua`) calls `S.lib.fx_hold.release(effect)` before it sends `setBypass`, whatever sets the bypass (a key, PARAMS, MIDI, a PSET), so the calls go `setDelayFreeze(0)`, then `setBypass(0, 1)` (the reverb's: `setReverbFreeze(0)`, then `setBypass(1, 1)`), the engine's kept freeze is 0 and a lifted bypass starts empty and unfrozen. `release` checks `offered(effect)` first, so on the standard tier the reverb's bypass sends its bypass alone.
- **A freeze set where it cannot act is refused** (the plan's ruling 26; the reverb freeze design's call 1): a freeze set to 1 while its effect is bypassed, or the reverb's on the standard tier (`offered("reverb")` false), is set back to 0 by its action through `set_binary_param`, so a controller mapped to it is echoed the 0 (its light follows the param). That set re-enters the action with 0, which is never refused, and costs one redundant `setDelayFreeze(0)` or `setReverbFreeze(0)` (the engine keeps 0 through a bypass and on the standard tier); never a freeze of 1. `toggle` does nothing at all there. So a MIDI map or a PARAMS edit never leaves a freeze for a lift.
- **The params reach the engine only through their senders** (`send_param_to_engine`): `delay_freeze` sends `engine.setDelayFreeze(value)`, `delay_clear` `engine.clearDelay()` (no argument; the trigger's action sends the value 1, so the send budget never holds a nil), `reverb_freeze` `engine.setReverbFreeze(value)`.
- **`toggle` and `release` go through `set_binary_param`**, so a controller mapped to a freeze follows (#538).
- **`offered("reverb")` reads the tier at each call**, never at include: `S.performance` is set by `lib/params_setup.lua`, included after this module, and is nil at its include. The tier does not change while the script runs (a new performance setting takes a restart).
- The ids are `FX_HOLD`'s; 4a's FX rows and header mark and 4b's grid keys read `offered`, `frozen`, `freezable`, `toggle`, `clear` and `any_frozen`, never a param's presence or the tier (the plan's ruling 27): `reverb_freeze` exists on both tiers.
- No Lua field is named `frozen` (`test/unit/engine_sync_test.lua` refuses one; `M.frozen` is the function).

## Machines

### fx hold
- **State:** for each effect, its bypass (`S.lib.voice_mix.bypassed(effect)`) and its freeze (`S.lib.fx_hold.frozen(effect)`): running (neither), frozen, or bypassed; the reverb's also standard, the standard tier, where its freeze is not offered (bypassed or not). `freezable(effect)` is running or frozen.
- **Invariant:** `fx hold`: no effect is bypassed and frozen.
- **Test:** `test/unit/fx_hold_test.lua`: "the invariant fx hold fails for a delay bypassed and frozen" and "the invariant fx hold fails for a reverb bypassed and frozen"; the reverb's table runs as "reverb freeze: every cell is decided" and its rows (`h.transition_table`; each state sets the tier after the load and writes the two PSETs the reads load, one that bypasses the reverb and one that leaves it running; each row's check is the `setReverbFreeze` and `setBypass` calls it sent).

The reverb's table (3.9, #819): the delay's events but the clear, each a set of a param (freeze and release `reverb_freeze` 1 and 0, bypass and lift `reverb_bypass` 1 and 0) or a PSET read; a set to the value a param already holds runs no action, so it sends nothing. Every cell is a row: no pair is impossible. It is the entry's first table, so the test compares it with its rows ("reverb freeze: the notes' table equals these rows"; `h.notes_table` reads only a heading's first table). The delay's table follows; no test runs it as a table (its rows are the delay's tests above).

| State | Event | Next | Effect |
|---|---|---|---|
| running | freeze | frozen | `setReverbFreeze(1)` |
| running | release | running | nothing |
| running | bypass | bypassed | `setBypass(1, 1)` |
| running | lift | running | nothing |
| running | silent bypassing read | bypassed | `setBypass(1, 1)`, from the engine params' read hook (#965) |
| running | running read | running | nothing |
| frozen | freeze | frozen | nothing |
| frozen | release | running | `setReverbFreeze(0)` |
| frozen | bypass | bypassed | `setReverbFreeze(0)`, then `setBypass(1, 1)` |
| frozen | lift | frozen | nothing |
| frozen | silent bypassing read | bypassed | the read hook's `setReverbFreeze(0)`, then the engine params' hook's `setBypass(1, 1)` |
| frozen | running read | frozen | no `setReverbFreeze` |
| bypassed | freeze | bypassed | refused: the param back to 0 and one `setReverbFreeze(0)`; `toggle` does nothing |
| bypassed | release | bypassed | nothing |
| bypassed | bypass | bypassed | nothing |
| bypassed | lift | running | `setBypass(1, 0)` |
| bypassed | silent bypassing read | bypassed | nothing |
| bypassed | running read | running | `setBypass(1, 0)`, from the bypass's action |
| standard | freeze | standard | refused: the param back to 0 and one `setReverbFreeze(0)`, which the engine keeps as 0 |
| standard | release | standard | nothing |
| standard | bypass | standard | `setBypass(1, 1)` alone (`release` does nothing where the freeze is not offered) |
| standard | lift | standard | nothing |
| standard | silent bypassing read | standard | `setBypass(1, 1)` |
| standard | running read | standard | nothing |

The delay's table (a freeze or a release here is `toggle`, E3, PARAMS, a MIDI map or the grid's DF):

| State | Event | Next | Effect |
|---|---|---|---|
| running | freeze | frozen | `setDelayFreeze(1)` |
| running | clear | running | `clearDelay()` |
| running | bypass | bypassed | `setBypass(0, 1)` |
| running | a silent PSET read that bypasses | bypassed | `setBypass(0, 1)`, from the engine params' read hook (#965; this hook has no freeze to release) |
| running | a PSET read that leaves the delay running | running | no `setDelayFreeze` |
| frozen | release | running | `setDelayFreeze(0)` |
| frozen | clear | running | `setDelayFreeze(0)`, then `clearDelay()` (#912) |
| frozen | bypass (a key, PARAMS, a MIDI map, a PSET read with actions) | bypassed | `setDelayFreeze(0)`, then `setBypass(0, 1)` |
| frozen | a silent PSET read that bypasses | bypassed | the read hook's `setDelayFreeze(0)` (#883), then the engine params' hook's `setBypass(0, 1)` (#965) |
| frozen | a PSET read that leaves the delay running | frozen | no `setDelayFreeze` |
| bypassed | freeze | bypassed | refused: the param back to 0 and one `setDelayFreeze(0)`; `toggle` does nothing |
| bypassed | clear | bypassed | `clearDelay()`, which the engine ignores while bypassed (FX's clear row is the lift there) |
| bypassed | lift | running | `setBypass(0, 0)` |

## What it owns

`lib/fx_hold.lua` (`S.lib.fx_hold`, included after `lib/delay_sync.lua`) registers one fx record, `{name = "hold", count = 3}`, so the fx group's registered params run `delay_sync`, `delay_division`, `delay_pingpong`, `delay_freeze`, `delay_clear`, `reverb_freeze`, then shimmer's.

- `delay_freeze`: binary toggle, default 0, name `delay freeze`. Its action sends the value and redraws (the screen and the grids, for 4a's and 4b's marks).
- `delay_clear`: a trigger, name `delay clear`, fired with `params:set("delay_clear", 1)` (norns never writes a trigger to a PSET). Its action releases a freeze, then sends `clearDelay()`.
- `reverb_freeze` (3.9, #819): binary toggle, default 0, name `reverb freeze`, on both tiers, so the param list does not depend on the tier. Its action refuses a 1 while the reverb is bypassed or not offered, otherwise sends the value and redraws, as the delay's.
- `M.FX_HOLD = {delay = {freeze_id = "delay_freeze", clear_id = "delay_clear"}, reverb = {freeze_id = "reverb_freeze"}}` (the reverb has no clear).
- `M.offered(effect)`: true for `"delay"`; for `"reverb"`, true only while `S.performance` is set and its `tier` is `"high"` (the FDN; `FreeVerb2` has none); false for anything else.
- `M.frozen(effect)`: offered and its freeze param at 1. `M.any_frozen()`: any effect frozen.
- `M.freezable(effect)`: whether `toggle` would freeze or release it now, offered and not bypassed. `toggle` asks it, and so do FX's ALT+K3 and its `K3:freeze` hint, so the hint never offers what the key would not do (4a's review).
- `M.toggle(effect)`: freezes or releases through `set_binary_param`; nothing unless `freezable(effect)`.
- `M.release(effect)`: nothing for an effect not offered; otherwise sets the freeze param to 0 when it is 1.
- `M.clear()`: `params:set("delay_clear", 1)`.
- The invariant `fx hold` (Machines, above; its message names the effect, its bypass and its freeze param) and the PSET read hook `fx_hold` (registered at include, after the hooks of the modules included before it and before the engine params' hook, so a release goes out before that hook's `setBypass`; it reads only the bypass and freeze params, the delay's first).

What a frozen delay does is the engine's (`docs/notes/engine/delay.md`): the loop's gain exactly 1, the input closed, the time held (a tempo move or a `delay_time` change under a freeze is sent as usual and waits in the engine for the release), ping-pong snapped. Lua keeps sending `setDelay` while frozen; a release then plays the time Lua last sent. FX marks its `time` row `held` while the delay is frozen (#911, `docs/notes/lua/pages/fx.md`), so the time it shows is read as the one the release plays.

What a frozen reverb does is the engine's too (`docs/notes/engine/reverb.md`): within 20 ms the input closes after the diffusers (shimmer's loop with it), the loop's gain goes to exactly 1 through whole-sample reads, and the size is held; `damp` stays live on the output, shading the held tail. Lua keeps sending `setReverb` while frozen; a size sent meanwhile waits in the engine, and FX marks the `size` row `held` (the design's call 2); `damp` has no mark.

The freezes are also FX's rows (`freeze` and `clear`, its ALT+K3 freezing the row's effect, `docs/notes/lua/pages/fx.md`) and the grid's DF, DC and RF (`docs/notes/lua/grid/pages/fx.md`); the header's frozen mark (FX's page dot as a bar) reads `any_frozen` (`docs/notes/lua/ui/header-and-flashes.md`), and all three params can be mapped to MIDI from PARAMS > fx.

## Tests (`test/unit/fx_hold_test.lua`)

The delay's params (type, place, default, no PSET line, no scene field, no LFO destination), each one's send, a bypass ending the freeze first, a freeze refused while bypassed, toggle's MIDI echo, a PSET load leaving a freeze on and off as it was, a PSET that bypasses the delay ending its freeze (one that leaves it running does not), a silent read that leaves it bypassed and frozen releasing the freeze (#883; one that leaves it running keeps it), the invariant `fx hold`, a clear on a frozen delay releasing it first (#912), a tempo move under a frozen synced delay, and the plan's Review Focus 3: a frozen delay through a tempo move, a sync switch, a bypass and a PSET load. The reverb's (3.9, #819), loaded on the high tier through `h.write_performance_active`: offered there only, and on the standard tier `toggle` and `release` send nothing; `reverb_freeze` in no PSET, scene, LFO destination or macro target, after `delay_clear`; a set refused on the standard tier and while bypassed (the param back at 0, a mapped controller echoed 0, no `setReverbFreeze(1)`); a bypass ending it first; a PSET load leaving it, one that bypasses ending it, a silent read that leaves it bypassed and frozen releasing it; the invariant for the reverb; `delay_clear` leaving a frozen reverb frozen; and its table (Machines, above).
