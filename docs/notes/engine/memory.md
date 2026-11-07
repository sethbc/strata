## Must not break

- norns' scsynth pool is 8192 KB. No grain SynthDef has a `PitchShift` or a delay line, and every `GrainBuf` uses `maxGrains` (128); never size a delay line or table from a control.
- A voice never holds more than its live synths, one fading and one cutting set, however fast switches, stops and starts arrive (`freeCuttingSynths`, `fadeSupersededSynths`).
- The worst case (spaced, in a burst and for fast A -> B -> A -> C recalls) leaves at least **3 MB** of the pool free on the standard tier (twelve 256 KB probes). The high tier's floor is 4 MB (sixteen probes, spectral freeze engaged on every voice), checked once the performance setting and freeze have merged.
- Each grain synth takes under 64 KB of the pool.
- **Buffer memory** (ordinary RAM, not the pool): 8 × 2 mono slot buffers of `bufferSeconds` (≈ 49 MB at 16 s), 7 × 2 voice rings of 4 s (10.8 MB) and an input ring pair of `historySeconds` + 5 s (8.1 MB standard). Allocated once; bufnums never change.

## Real-time memory

Every UGen's delay lines and tables come from scsynth's real-time pool, allocated when a synth starts. norns never raises it: `Crone.sc` boots `Server.local` with `memSize` left at the `ServerOptions` default, **8192 KB** (its `memSize = 2**16` line is commented out). A UGen that cannot get its memory prints `<UGen>_Ctor: alloc failed` and outputs zeros, and a synth whose own node cannot be allocated fails with `/s_new out of real time memory`: either way that voice goes silent with nothing on screen. Buffers (`b_alloc`: the slots and the rings) are not in this pool.

What a grain synth takes, at 48 kHz:
- `GrainBuf` grain tables: about 100 bytes per grain, `maxGrains` (128) per `GrainBuf`, two per synth: about 26 KB per synth (measured: 13.6 KB for one 128-grain `GrainBuf`, whatever its channel count). `maxGrains` is 128 (the UGen's default is 512): the largest overlap Lua can ask for is grain size 0.5 s × density 100 × master density 2 = 100 grains, and a `GrainBuf` runs at most `maxGrains - 1` (beyond that it drops grains and prints `Too many grains!`, on which `test/run_engine_check.sh` fails).
- the rest of the graph: about 250 bytes per UGen (unit structs, inputs and outputs). `\strataGrainRing` has 85 UGens and `\strataGrainBuf` 103.
- 3.1's `\strataGrain` and `\strataGrainBuf` also each had a `PitchShift` (128 KB at its fixed 0.1 s window) and `\strataGrain` a position-spread `DelayC` (128 KB). 3.2 removed both: pitch is the grain rate and the spread is a backward position offset in the ring (`docs/notes/engine/rings.md`).

**Budget** (used KB of the 8192 KB pool, from `/rtMemoryStatus`; measured by `test/engine_check/memory.scd`, whose check lines print them):

| | 3.0.2 / 3.1 (scsynth 3.14) | 3.2 standard (scsynth 3.14.1, local) |
|---|---|---|
| engine idle (effects chain, input, writers; delay 2 s stereo = 1 MB, master `PitchShift` 0.2 s = 256 KB, `FreeVerb2`) | about 1460 | 1526 |
| one synth grain synth | 274 (`\strataGrain`) | 47.6 (`\strataGrainRing`) |
| one buffer grain synth | 152 | 51.4 |
| the worst case (below) | about 6920 (1270 free) | about 2400-2425 (about 5770 free) |

CI runs the same check on SuperCollider 3.13.0 (norns' version); its lines carry its own figures.

- **The worst case**: seven voices at grain size 0.5 and density 200, each switched synth -> buffer -> input -> synth with each switch processed before the next (as E3 detents arrive), then stopped and started. At the last switch every voice holds its live voice, grain and mod synths, the input grain synth in its 2 s release and the buffer grain synth in its 50 ms cut: 21 grain synths and 7 voice synths.
- **Bursts**: switches that arrive inside one 50 ms cut (a chord of grid scene buttons recalls each scene at once and every recall switches each voice; PMAP-mapped `v<i>_source` params) would leave a synth in its kill fade per switch. Every step that makes a new fading set therefore first frees, at once (`freeCuttingSynths`: `/n_free` in a bundle with `/error -1`, since one may have just ended its fade on the server), the synths an earlier cut left in their fade (`cuttingSynths[voice]`, filled by `cutVoiceSynth`, emptied by `onFree`), then cuts the current fading set (`replaceFadingSynths`): a switch (`cutFadingSynths`), and a `voiceOn` that meets releasing synths built for another source (`gateVoice` hands them to `fadingSynths` through `fadeSupersededSynths`, before it starts anything; `releaseVoice` does the same with a superseded synth, which `gateVoice` no longer leaves). A synth freed this way stops without the rest of its 50 ms fade; that only happens to a synth already fading out under a newer one.
- **Recalls** (#46): scenes A = on/synth, B = off/input, C = on/buffer recalled A -> B -> A -> C at once (a grid chord, a fast scene sequencer). The voice holds its live synths, one fading set (at most one grain and one voice synth) and one cutting set, however switches, stops and starts interleave, and A -> B -> A -> C ends with the same synths as the worst case above: it is the real bound. Lua also stops a voice a recall stops before setting its source (see `docs/notes/lua/scenes.md`).

The engine check boots its server with `memSize = 8192` (norns' value, set explicitly), runs the worst case, the burst and the A -> B -> A -> C recalls, and each time starts twelve 256 KB probes (`h.probeFree(12)`: `\strataCheckMemProbe`, a `DelayN` that passes 1 or reads 0 when its allocation failed, on a zeroed bus) at once: all must allocate, so the worst case leaves at least 3 MB free. It also measures each grain SynthDef (ten synths started at once, the pool's free bytes before and after; under 64 KB each) and the idle engine. `test/run_engine_check.sh` also fails on any `alloc failed` in the server output. A new UGen with a delay line or table in a per-voice SynthDef multiplies by up to three grain (or two voice) synths per voice: rerun the check, and keep the headroom.

## The floors, and what 3.5 needs

The floors replace 3.1's 1 MB rule, sized for 3.5's note streams (`docs/design/3.2-design.md` §2.7): a note stream is one grain synth, and under today's lifecycle rule (a switch keeps a full fading set) each note beyond the first adds 21 grain synths and about 14 voice synths across the seven voices.
- The design estimated about 35 KB per stream (24 KB of grain tables plus 11 KB of graph). Measured on scsynth 3.14.1 it is about 48-51 KB (26 KB of tables plus about 21-25 KB of graph), so each extra note costs about 21 × 50 + 250 ≈ 1.3 MB rather than 1.0 MB.
- **Standard** (2 notes): 1.3 MB plus the 1 MB rule = 2.3 MB, inside the 3 MB floor; the measured worst case leaves about 5.7 MB free.
- **High** (4 notes): 3 × 1.3 + 1 = 4.9 MB, more than the 4 MB floor the design set from the 35 KB estimate; three notes (3.6 MB) fit it. The design's 3.6 MB-used estimate for high (2.8 MB plus spectral writers and the FDN reverb) becomes about 3.2 MB from the measured standard figure, leaving about 5 MB: the 3.5 design must re-measure on norns' own scsynth (the hardware check, #6) before it settles the note count.
- If a floor ever fails, find which estimate was wrong before cutting anything.
