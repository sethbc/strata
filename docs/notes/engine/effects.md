## Must not break

- **Limiter before the tanh saturator** in `\strataMaster`. The engine check asserts the order.
- **`\strataFilter`**: never compare a UGen with `==` (that is object identity); use `BinaryOpUGen('==', ...)`. A type change crossfades over 20 ms.
- **NaN guard**: `\strataFilter` replaces bad values on `mainBus` (`zeroBadValues`) before the delay and the reverb.
- The filter and delay SynthDef defaults equal the Lua param defaults: the script never bangs its params.
- The effects chain's synths (`effectKeys`) never end on their own, so `setSynth` sends to them plainly.

## The effect SynthDefs

- `\strataFilter` - Master multimode filter (`in, out, freq=5000, res=0.5, filterType=0, mix=0`), whose input first goes through the NaN/inf guard (see Signal safety in `docs/notes/engine/voices.md`): `RLPF`/`RHPF`/`BPF` at rq `1 - res * 0.95`, all three running, each weighted by `BinaryOpUGen('==', type, index).lag(0.02)` (`type = filterType.round.clip(0, 2)`; the weights sum to 1 once settled), so a type change crossfades over 20 ms instead of stepping (`Select.ar` jumped between the antiphase lowpass and highpass outputs; the engine check measures the largest sample step across type changes on a sine). Never compare a UGen with `==` directly: that is object identity in sclang, not a UGen. `mix` crossfades dry to filtered (0 = bypass)
- `\strataDelay` - Master stereo delay (`in, out, time=0.375, feedback=0.4, mix=0`): `DelayC` (max 2 s, `time.lag(0.1)`) fed by the input plus `LocalIn`, with the delayed signal times `feedback` sent back through `LocalOut`; `mix` crossfades dry to delayed
- The filter and delay SynthDef defaults equal the Lua param defaults: the script never bangs its params, so the engine starts from these values
- `\strataReverb` - Global reverb processor; outputs `FreeVerb2` only (it already crossfades dry/wet by `mix`)
- `\strataMaster` - Master output with drift, then `Limiter.ar(sig, 0.95)` to catch filter resonance and delay feedback peaks, then the tanh saturation. The limiter must stay before the saturator: `(sig * 2).tanh * 0.5` bounds its output to ±0.5, so a limiter after it could never act (the engine check asserts the order). Drift (master and Sub) is an LFO at a fixed slow rate scaled by the drift amount: tape drift 0 = none; the Sub drift param's minimum stays 0.001

**NaN guard before the effects**: `\strataFilter` (first in the effects chain) replaces any NaN, inf or denormal sample on `mainBus` with 0 (`CheckBadValues` per channel into a `Select`), so a voice that blows up can never poison the delay feedback or the reverb combs; normal samples pass unchanged. The engine check injects 50 ms of inf and NaN on `mainBus` (delay feeding back, reverb on) and finds no bad value at the master output afterward. The voices' own guards are under Signal safety in `docs/notes/engine/voices.md`.
