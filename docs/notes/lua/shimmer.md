## Must not break

- **Shimmer is off at its defaults**: both amounts are 0 (`controlspec.new(0, 1, "lin", 0.01, 0)`) and the interval is an octave (index 3, ratio 2), the defs' defaults (`shimmer=0`, `shimmerRatio=2` on `\strataDelay`, `\strataReverb` and `\strataReverbFDN`; a test compares them). A default start sends no `setShimmer` (the engine starts there), so 3.7.0's start messages are unchanged.
- **One sender for all three params** (`send_shimmer`, every id's `S.engine_senders` entry): `engine.setShimmer(engine_param_value("shimmer_delay"), engine_param_value("shimmer_reverb"), ratio)`, the ratio `SHIMMER.ratios[...]` of the interval as the engine has it, so a param moved by an LFO or the matrix reaches the engine with the others as they are. Never `engine.setShimmer` from anywhere else.
- **Each action calls `note_param_edit` before its send** (all three, the interval's too: FX's randomize, 3.8's 4a, may draw any of them), then `send_param_to_engine` (a test sees each edit noted once, by its own id, before its `setShimmer`, #838).
- **A bypass sends no `setShimmer`**: the engine keeps all three through a bypass and creates a lifted node with them (`docs/notes/engine/shimmer.md`).
- **The interval is a ratio, never semitones**, so it holds in any tuning; Lua sends only the five values of `SHIMMER.ratios` (the engine clips 0.5-4).
- The three are scene globals: the interval discrete (it switches at a transition's end), the amounts continuous (a fade crossfades them, each step sent). `validate_scene` and `fill_scene` cover them through the registered scene fields; scene format 10 is not raised.

## What it owns

`lib/shimmer.lua` (`S.lib.shimmer`, included after `lib/fx_hold.lua`) registers one fx record, `{name = "shimmer", count = 3}`, so the fx group ends `delay_freeze`, `delay_clear`, `reverb_freeze` (3.9), `shimmer_interval`, `shimmer_delay`, `shimmer_reverb`.

- `M.SHIMMER`: `ratios = {0.5, 1.5, 2, 3, 4}`, `names = {"oct down", "fifth", "octave", "oct+5th", "2 oct"}` (they fit FX's value column), `default_interval = 3`, `interval_id`, and `amounts` (`shimmer_delay` "shimmer delay", LFO label `shim dly`; `shimmer_reverb` "shimmer reverb", `shim rev`).
- `shimmer_interval`: an option of the names, default 3.
- `shimmer_delay`, `shimmer_reverb`: controls 0-1 in steps of 0.01, shown in percent (`0 %`).
- `M.ratio()`: the interval's ratio now.
- Scene fields: `S.register_scene_field({id = "shimmer_interval", default = 3, discrete = true})`, and the amounts at 0, continuous.
- LFO global destinations `shim dly` and `shim rev` (`S.register_lfo_global_destination`), after 1a's `dly>rev`: every per-voice and macro destination's index is two higher than before.

FX shows the three as its shimmer section (its ALT+K2 draws them, `docs/notes/lua/pages/fx.md`) and the arc's FX ALT rings 3 and 4 turn the amounts (`docs/notes/lua/arc-pages.md`); 4b reads the interval for its keys. All three can be mapped to MIDI from PARAMS > fx.

## Tests (`test/unit/shimmer_test.lua`)

The three params (types, specs, defaults, names, places, the record) and a default send `setShimmer(0, 0, 2)` against the defs' defaults; each param sending the other two as the engine has them (interval 1 gives `args[3] == 0.5`; an LFO offset on an amount); each action noting the edit (a randomize's undo ends) before its `setShimmer` (#838); scene globals (a fade crossfades the amounts, the interval switches at its end, a scene without them filled with their defaults, one outside their ranges invalid); the LFO destinations; a bypass and its lift sending no `setShimmer`; and a source test that every `Synth(\strataDelay`, `Synth(\strataReverb` and `Synth(\strataReverbFDN` in the engine and the engine check passes `\shiftL` and `\shiftR` (`docs/notes/engine/shimmer.md`).
