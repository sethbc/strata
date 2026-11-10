## Must not break

- `slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_scanReset)` is `Phasor.ar(t_scanReset, (this.scanRate(bufScan, freeze) * (1 - scanHold) + scrubRate) * SampleDur.ir, 0, 1)`: with the three controls at rest it is 3.2's scan, exactly (`"positions: slotScanPhase is 3.2's scan"`).
- **`t_scanReset` is never stored.** Its `grainParamHandlers` entry sends it to the voice's live grain synth (through `setSynth`, so `sendToSynth`) and returns true, so no replacement grain synth starts with a stale trigger (`"positions: t_scanReset restarts the phase and is not stored"`, hazard 5 of the 3.3 plan).
- `scrubRate` and `scanHold` are plain grain controls, stored and sent, so a source switch mid-glide keeps gliding (`"positions: scrubRate and scanHold survive a source switch"`). With `t_scanReset` they are **transient performance state**, the one exception to "the `voices` table is the only source of values": not params, never in a scene or PSET; `lib/positions.lua` sends `scrubRate 0` and `scanHold 0` in each voice's sync, so a started voice never inherits a glide.
- **Every grain start restarts the scan.** A new `\strataGrainBuf` starts its `Phasor` at 0. `gateVoice` (`lib/engine/StrataLifecycle.sc`) adds `\t_scanReset, 1` to the re-gate of a releasing `\strataGrainBuf` (`"lifecycle: a re-gated buffer voice restarts its scan"`). A `voiceOn` on a voice that is running is no start: its scan goes on (`"lifecycle: a voiceOn on a running buffer voice keeps its scan"`). Lua's playhead resets on the same events (`docs/notes/lua/playheads.md`).

## Owns

`lib/engine/StrataPositions.sc` (`strataAreaPositions`, order 150): `slotScanPhase`, called by `slotGrainReader` (`StrataGrainDefs.sc`), and the `t_scanReset` handler. No state, defs or commands. Every `\strataGrainBuf` has the three controls; `\strataGrainRing` declares them and ignores them, so a jump on a ring voice does nothing.

## The scan phase

`scanRate(bufScan, freeze)` is the freeze area's hook: `bufScan × (1 − freeze)`, in fractions of the voice's loop per second (`slotGrainPos` spreads the phase over `loopLast - loopFirst`, the whole valid region when the loop is the whole slot). The phase's rate is that rate × `(1 − scanHold)` plus `scrubRate`:

| Control | Effect | Sent by |
|---|---|---|
| `t_scanReset` | a trigger: the scan phase restarts at 0 | Lua's jumps (`setGrainParam(v, "t_scanReset", 1)`), and `gateVoice` at every re-gate of a releasing slot reader |
| `scrubRate` | added to the scan rate; neither `freeze` nor `scanHold` stops it (a fling goes on with the tape held) | Lua's arc glide |
| `scanHold` | 1 stops the voice's own scan, not the glide | Lua's ALT hold and the grid's hold keys |

The phase's reset is the `Phasor`'s own trigger input, so a reset falls in the block the message lands in. The two rate controls enter the `Phasor`'s rate as control-rate signals; a glide is as smooth as Lua's 1/15 s decay of `scrubRate`.

## The check

`test/engine_check/positions.scd` has two kinds of assertion. The hook runs beside a `Phasor` of the rate it should have and the largest difference (`Peak.ar`, on the server) is read back once: 0 for the scan alone, the scrub alone, both, a hold, a hold with a glide and a freeze with a glide, and across a reset. The real `\strataGrainBuf` runs end to end on a slot of known contents: its left channel is a staircase of its position (64 steps, `Buffer.fill`) and its right channel is 1, so `RunningSum(left) / RunningSum(right)` of the voice's other path is where the grains read, read back with one `/c_get` beside the server's own time (a `Sweep`), so a slope never depends on sclang's clock. The voice runs with `panSpread` and `panJitter` at 0: `panSpread`'s slow `Balance2` drift moves the ratio by far more than the scan does. `test/engine_check/lifecycle.scd` uses the same slot for `gateVoice`'s re-gate.
