# 3.8 facts: the effects chain, shimmer, delay freeze and clear, a reverb freeze, plain sends

Read `lib/engine/StrataEffects.sc`, `StrataMix.sc`, `StrataRecord.sc`, the effects, mix, memory and performance notes, `test/engine_check/{memory,effects,mix}.scd`, `test/norns_stubs.lua` and SuperCollider's sources at tag `Version-3.13.0` (norns' and CI's), against `main` at 59a0a0c1 (the groundwork changes nothing in this area: the fx params are not per-voice values, and no groundwork package touches `StrataEffects.sc` or `StrataMix.sc`). Then measured, in a worktree with uncommitted scratch: prototype defs in `lib/engine/StrataScratchFx.sc`, a variant switch in the effects and mix areas, and an on-demand check area `test/engine_check/fxscratch.scd` (pool sizes by the memory area's allocation probes, and server-timed energy windows); the memory area run once per variant. **Measured** figures say their SuperCollider version; "both versions" means 3.14.1 locally (JACK dummy, port 57851) and 3.13.0 in CI's Docker image, which gave identical pool figures wherever both ran. CPU figures are **measured** on x86 in non-real-time renders (scsynth 3.14.1 `-N`), relative only; nothing here ran on a norns.

## 0. The facts most likely to change the design

1. **Moving the delay's line into two buffers frees 1010-1030 KB at every worst case, with no change to the sound.** `BufDelayC` on two 2^17-frame buffers is bit for bit `DelayC`: the largest difference over 5.5 s of steady pink noise was 0.0, with the time fixed at a fractional 0.30928 s and with it on a 0.5 Hz LFO (feedback 0.4, ping-pong 0.5), measured on both versions. The node drops from 1032.2 KB to 13.5 KB of the pool (with freeze and clear), at the same CPU (0.20 of FreeVerb2's, against `DelayC`'s 0.19). The tightest case, high synth -> buffer -> synth, goes from 3820 to 4830 KB free (1246 KB above its 3.5 MB floor, from 236), and the high pool case from 1750-1760 to 2780, on both versions (§3). The buffers come from ordinary RAM (1 MB), so the 2.7 s cap and its power-of-two rule (`docs/notes/engine/effects.md:16`) stop being a pool limit: a 2^18 buffer gives 5.46 s for 2 MB of RAM and no pool. And clear becomes possible from outside.
2. **A `PitchShift` shimmer costs about 130 KB of the pool per placement at a 0.1 s window, and two of them break the high tier's floor.** With shimmer in both the delay's loop and an outer loop around the reverb, the high synth -> buffer -> synth case fails its 3.5 MB probes (`alloc failed`, on both versions). The arithmetic is 3820 - 265 = about 3555 KB, against 3584. One placement alone leaves about 3690 KB (est.), 106 KB above the floor and nothing counting the spectral writers' late allocations (about 100 KB). Standard keeps 1100 KB or more (4210 KB). `PitchShift`'s line is three windows long, rounded up to a power of two: 0.05 s takes 65.7 KB stereo, 0.1 s 129.8 KB, 0.2 s 257.8 KB (§2). So the roadmap's "may offer it on the high tier only" (`ROADMAP.md:135`) has it backwards for the pool: high is the tier without room.
3. **A shifter on a buffer line costs 12-17 KB of the pool at any window.** A two-tap Doppler shifter (two read heads crossfaded on Hann windows, reading a ring the effect writes) took 12.6 KB stereo. On a buffer delay its taps read the delay's own line: shimmer on the delay costs about 14 KB, against 131 KB for `PitchShift`. With both shimmers on buffers and the delay on a buffer, high synth -> buffer -> synth reads 4790 KB free (3.14.1). CPU depends on how it is built: about 0.48× FreeVerb2 with `DelTapRd` (linear interpolation, triangular gains), 0.83× (cubic, Hann) and 1.23× with `BufRd` and `.wrap`. `PitchShift` stereo is 0.40× at any window (§2).
4. **An outer shimmer loop around either reverb is unstable wherever the shift does not carry energy out of the band.** At ratio 1, FreeVerb2's loop grew at amount 0.3 (+7 to +10 dB over 9 s) and went to infinity at 0.5 and 0.95. Ratio 1.02 at 0.95 grew on both reverbs. An octave up at size 1 and damp 0 grew +54 dB on FreeVerb2. An octave up or down at size 0.8 decayed, faster than the reverb's own tail (both versions). Nothing in the chain catches it. The limiter is in the master, outside the loop, and no `zeroBadValues` sits after the reverb, so a reverb that reaches inf or NaN stays that way until a bypass re-creates it. A loop needs a bound of its own: an in-loop soft clip or limiter, an amount scaled by size, or ratios kept away from 1. The delay's loop with shimmer is stable at feedback 0.95, and frozen (§2, §3).
5. **The delay freeze has to be a control of its own, not feedback 1.** `setDelay`'s feedback is clipped to 0.95 in the def, and both Lua's param and the stub read that limit (`StrataEffects.sc:166`, `lib/params_setup.lua:546-555`, `test/norns_stubs.lua:476-490`). The prototype (`feedback.clip(0, 0.95).max(frozen)`, input × (1 − frozen), both over 20 ms) holds a loop within 0.2-0.4 dB for 9 s at a time of whole samples. At fractional times, `DelayC`'s cubic interpolation darkens the held loop: the 6-24 kHz band loses about 11 dB in 9 s at 0.30928 s. Ping-pong between 0 and 1 collapses the frozen loop to mono in one pass: the cross-feed `[[1 − p, p], [p, 1 − p]]` has eigenvalues 1 and 1 − 2p, and the side signal measured −999 dB within 2 s at p = 0.5. At 0 and 1 it holds (§3).
6. **An exact clear costs nothing: mute the feedback and the return for one delay time.** A `Trig1` window of the delay time plus 5 ms, prototyped on `DelayC`: the return falls silent at once (3 ms), the line refills with the input alone, and the first echo of what comes after the clear plays one delay time later. With the input stopped, the line read −142 dB after the window. Zeroing a buffer line from outside is not exact. `/b_zero` runs in the non-real-time thread (`SC_SequencedCommand.cpp:432-436`), and `/b_fill` in the audio thread (`SC_MiscCmds.cpp:1405-1432`). Both left a recirculating one-block residual of −28 to −39 dB, because the block already in `LocalIn` is written back after the zero unless the feedback is multiplied by exactly 0 in that block (§3).
7. **The FDN can freeze (+3.8 KB), but its fractional line lengths darken a frozen tail, and its level steps at the freeze.** With the input closed, every line's gain at `max(g, frozen)` and the damping at 0, pink noise held within 0.6 dB over 9 s. The 6-24 kHz band fell about 5 dB/s through `DelayL`'s linear interpolation, and held exactly (±0.05 dB) once the lengths were rounded to whole samples. Unlike the delay, the output level stepped at the freeze, by −2.5 to +11.9 dB across eight cases on the two versions. FreeVerb2 cannot freeze: its room is clipped to 1 inside the UGen, where the comb feedback is 0.98 (`ReverbUGens.cpp:676-681`), and size 1 at damp 0 decays 5.7 dB/s (RT60 about 10.5 s, measured) (§4).
8. **Plain sends give back 2.5 KB a stage and change the default voice's dry level by +3.1 dB.** The plain stage measured 38.8 KB against 41.29 (12 UGens fewer: no `In.kr` of `fxMix`, no crossfade products). That is 17.5 KB for seven stages, 10-20 KB at the cases (3.14.1), and 3.2 KB of headroom under the 42 KB limit instead of 0.71. One master filter instead of three would give back 22 KB more (11.0 KB each), but only by moving the filter, since the sends are separate buses (§5). At the defaults (sends 1, delay mix 0, reverb mix 0.3) the dry part goes from 0.7 to 1 (+3.10 dB) and the reverb's return is unchanged. With the delay mix up, the delay's return gains `1/(1 − m_r)` (+3.10 dB at 0.3), and the dry gains `1/((1 − m_d)(1 − m_r))` (+9.1 dB at m_d 0.5).
9. **Every new effect control must survive a bypass lift, start at Lua's default, and be readable by the Lua stub.** A lift re-creates the node from `areaState[\effects][\controls]` only (`StrataEffects.sc:372-377, 383-392, 405-406`). The stub asserts that every SynthDef opens with an `arg` list (`test/norns_stubs.lua:454`) and reads limits from literal `.clip(lo, hi)` (`:476-490`). It also reads commands from `this.setSynth(\key, \control, msg[i])` pairs, and maps `synths[\key] = Synth(\literalName` (`:465-470`): a def name picked at run time, as my scratch does, would break that map. A freeze kept through a bypass holds an empty line after the lift, since the node starts empty (§6).
10. **The effects are single nodes, so none of these costs multiplies by voices or notes.** Every figure above is paid once a tier. Compare a grain or voice def's byte, which counts up to 53 times at the pool case. So the buffer delay's 1 MB is worth about 12 `\strataGrainBuf`s at 82.6 KB. This is the largest single return the pool can give in 3.8 (memory.md:6-12; §1, §3).

## 1. The chain today

Order, at the tail of `context.xg` (`StrataEffects.sc:401-421`): `\filter`, `\filterDelay`, `\filterReverb`, `\delay`, `\reverb`, `\master`, then the record area's tap group (`Group.tail(context.xg)`, `StrataRecord.sc:184-186`) with the pre-master tap. Each voice's stage runs earlier, in its mix group in `processGroup` (`StrataMix.sc:179-189`).

| Node | In | Out | Controls (defaults) | Kept at a lift | Pool, measured both versions |
|---|---|---|---|---|---|
| `\strataVoiceMix` ×7 (`StrataMix.sc:141-173`) | its synth and other paths; `fxMix` (2 ch, `In.kr`) | `mainBus` (dry), `delaySend`, `reverbSend`, mirror, tap | voice filter, `delaySend=1`, `reverbSend=1`, amp, crossmod, the modulation area's gate and mute | persistent, never lifted | 41.29 KB, 178 UGens |
| `\strataFilter` ×3 (`:140-145`) | `mainBus` / `delaySend` / `reverbSend` | `filterBus` / `delaySendPost` / `reverbSendPost` | `freq=5000, res=0.5, filterType=0, mix=0` | never freed | 11.0 KB each, 47 UGens |
| `\strataDelay` (`:158-168`) | `delaySendPost` | `delayBus` (m_d·D) | `time=0.375, feedback=0.4, mix=0, pingPong=0, fadeIn=0` | time, feedback, mix, pingPong (`:405`) | 1032.2 KB, 29 UGens (two `DelayC` of 2^17 floats; the effects check measures about 1011 KB freed at a bypass) |
| `\strataReverb` (standard, `:173-178`) | `reverbSendPost` + `delayBus` | `reverbBus` (m_r·R) | `mix=0.3, size=0.8, damp=0.5, fadeIn=0` | mix, size, damp (`:406`) | 104.5 KB, 15 UGens |
| `\strataReverbFDN` (high, `:190-217`) | the same | the same | the same | the same | 209.0 KB, 123 UGens (the notes' "about 202", `effects.md:30`) |
| `\strataMaster` (`:221-247`) | `filterBus`, `delayBus`, `reverbBus`, `fxMix` | `context.out_b` | `amp=0.7, drift=0.01` | never freed | 39.6 KB, 28 UGens: `PitchShift` 0.01 s stereo 17.7 KB, `Limiter` 0.01 s two tables of 3 × 480 floats (`FilterUGens.cpp:3396-3400`, about 11 KB), the rest graph |

So the chain takes about 1210 KB on standard and 1315 KB on high (**measured** per node; the idle engine is 6580 KB free on both versions).

**The gain law** (`voiceOutput`, `StrataMix.sc:252-260`; `masterSum`, `StrataEffects.sc:106-110`). With a voice's sends s_d, s_r and the global mixes m_d, m_r (`fxMix`, lagged 0.05 s, clipped by `liveMix` before broadcast):
- dry: `(1 − s_d·m_d)(1 − s_r·m_r)·x`, onto `mainBus`;
- delay send: `s_d·x`; the delay returns `m_d·D` (`delayBus`);
- reverb send: `s_r·(1 − s_d·m_d)·x`; the reverb's input is the filtered reverb send plus `delayBus`, so `R(Σ s_r(1 − s_d m_d)x + m_d D)`, returned times m_r;
- master: `dry + (1 − m_r)·m_d·D + m_r·R`.

At sends of 1 this is 3.0's serial crossfade chain term for term (`docs/notes/engine/mix.md:36`). The two side effects `docs/user/effects.md:20` describes: a voice with reverb send 0 still has its echoes reverberated (the delay's return feeds the reverb as one source), and a voice with delay send 0 still hears the other voices' echoes in the reverb. The mix readers and the nodes' own mixes move in one bundle (`broadcastFxMix`, `:319-321`).

**The standard reverb.** `FreeVerb2` is one UGen with its eight combs and four allpasses per channel in its unit struct (about 100 KB of the pool, the struct itself). Its room is clipped to 0-1 and becomes comb feedback `0.7 + 0.28·room` (at most 0.98), its damping `0.4·damp` (`ReverbUGens.cpp:676-689`). Nothing inside it can be reached: no feedback input, no access to the combs. Only an outer loop (out → shifted → in) can be added, through a `LocalIn` in `\strataReverb`, which has none today.

**The high reverb.** In `\strataReverbFDN`, four `AllpassN` diffusers per channel feed eight `DelayL` lines, each sized by its own constant length (`fdnLineSeconds`, `:127`). The lines go through a `OnePole` damping, a Householder mix and per-line gains, and back through one `LocalIn.ar(8)`/`LocalOut` (`:203-214`). Every line's input and gain can be reached in the graph. Since SuperCollider allows one audio-rate `LocalIn` per SynthDef (`HelpSource/Classes/LocalIn.schelp:12`), any extra loop (a shimmer, a freeze path) must widen that one `LocalIn` (my prototype uses 10 channels), never add a second. The same holds for `\strataDelay`'s `LocalIn.ar(2)`.

## 2. Shimmer, measured

**The shifters** (pool: both versions, identical; CPU: NRT on x86, user seconds of 16 instances over 600 s less the source's, relative to FreeVerb2 = 1.00 (0.104 % of an x86 core per instance); the FDN is 1.33, `DelayC` 0.19):

| Shifter | Pool | CPU vs FreeVerb2 | Sound |
|---|---|---|---|
| (a) `PitchShift`, window 0.01 / 0.02 / 0.05 / 0.1 / 0.2 s, mono | 9.3 / 17.7 / 33.7 / 65.7 / 129.8 KB | 0.20 (any window) | the four-grain shifter the master already runs; a long window combs, as `effects.md:12` says of the drift (the first notch at 2 / ((ratio − 1)·window) Hz: 20 Hz at an octave and 0.1 s, so a dense comb, a phasey shimmer) (est.) |
| (a) the same, stereo | 17.7 / 33.7 / 65.7 / 129.8 / 257.8 KB | 0.40 | |
| (b) grain shifter: `BufWr` ring (`Buffer.alloc`, RAM) + a `GrainBuf` pair at `maxGrains` 128, 40 grains/s of 0.1 s at rate 2 | 28.6 KB (two grain tables of 13.6 KB, memory.md:20) | 1.45 | grains: smooth, but a second grain engine |
| (c) buffer Doppler shifter: `BufWr` ring + two `BufRd` taps a channel (cubic, `.wrap`), Hann gains, stereo | 12.6 KB, any window | 1.23 | two crossfaded read heads: the same family as `PitchShift` (two taps, not four) |
| (c) the same on `DelTapWr`/`DelTapRd` (cubic, Hann) | not measured separately (est. under 15 KB: graph only) | 0.83 | |
| (c) the same, `DelTapRd` linear, triangular gains | (est. under 15 KB) | 0.48 | |
| `FreqShift` stereo | 1.7 KB | 0.54 | a frequency shift (every partial moved by the same Hz): inharmonic, not a pitch shift |

`PitchShift`'s line is `ceil(window·SR·3 + 3) + 64` samples, rounded up to a power of two (`DelayUGens.cpp:4986-4993` at 3.13), and the window is read once, at construction (`:4975`). A window from a control would size the line from a control (`effects.md:16`), so the window must be a literal. The largest window in each pool step: 0.0113 s (8 KB a channel), 0.0224 (16), 0.0451 (32), 0.0906 (64), 0.181 (128).

**Placements** (pool both versions; floors 3.14.1 and 3.13 where said):

| Placement | Def | Pool | Δ against today's node |
|---|---|---|---|
| in the delay's loop, `PitchShift` 0.1 s stereo on `delayed` before `LocalOut` (`\pDelayShimPS`) | `DelayC` + freeze + clear + shifter | 1167.0 KB | +134.8 |
| in a buffer delay's loop, Doppler taps on the delay's own line at `time + d(t)` (`\pDelayShimTaps`) | `BufWr`/`BufRd` line + taps | 27.8 KB (3.13; 27.0 on 3.14.1) | −1004 |
| around FreeVerb2, an outer loop: wet → shifter → LPF 6 kHz, HPF 100 Hz → amount → its input (`\pReverbShimPS`) | `PitchShift` 0.1 s stereo | 237.6 KB | +133.1 |
| the same with a buffer Doppler shifter (`\pReverbShimBuf`) | | 121.3 KB | +16.8 |
| around the FDN, the same outer loop into the diffusers, the loop's two channels on the FDN's `LocalIn` (10 channels) (`\pFdnShimPS`) | | 343.4 KB | +134.4 |
| the same with a buffer Doppler shifter (`\pFdnShimBuf`) | | 225.4 KB | +16.4 |
| inside the FDN, one shifter per line (not built) | 8 mono `PitchShift` 0.1 s | (est.) 8 × 65.7 = 526 KB | does not fit the high tier |

**What the floors read with shimmer running** (memory area alone, KB free; "today" is the 3.7 landing's figures again, identical on my runs):

| Case | today | PitchShift in the delay and around the reverb | buffer delay alone | buffer delay + Doppler shimmers on both |
|---|---|---|---|---|
| standard synth -> buffer -> synth (floor 3072) | 4480 | 4210 (both versions) | 5490 (3.14.1), 5510 (3.13) | 5460 (3.14.1) |
| standard all-buffer, pool full (1280) | 1970 | 1700 (both) | 2980 (both) | 2940 |
| high synth -> buffer -> synth (3584) | 3820 | **fails** (`alloc failed` on both versions; about 3555 by arithmetic) | 4830 (both) | 4790 |
| high synth -> buffer -> synth, pool full (1280) | 1750 (3.14.1), 1760 (3.13) | 1480 (both) | 2780 (both) | 2740 |
| high eight recordings (3072) | 3830 | 3540 (3.14.1), 3560 (3.13) | 4840 (both) | 4800 |
| idle | 6580 | 6310 | 7600 | 7560 |

**Controls.** Each placement needs an interval (a ratio, or semitones converted in Lua) and an amount (a send into the loop, or for the delay a crossfade of the feedback between plain and shifted, as the prototype has). A choice of ratios matters for stability (below). With the Doppler taps, a window, as a literal (it sets the ramp rate, not memory). On a buffer delay the taps read `time + d`, so `time + window` must stay within the buffer: 2.7 s + 0.1 s fits 2^17 frames (2.73 s) only if the time is capped at about 2.63 s, or the buffer is 2^18.

**Stability** (a 0.2 s pink burst, energy in 0.5 s windows, both versions alike):
- In the delay's loop (gain at most `feedback` ≤ 0.95 per pass, times the shifter's): it decays at feedback 0.95 with `PitchShift` at an octave up or down (−15 dB over 9 s, against −10 dB without shimmer) and with the Doppler taps (−14 dB). Frozen (loop gain 1) with shimmer 1 an octave up, it held to within −3 to −7 dB over 9 s: no growth. The shift moves energy up each pass, and the interpolation and `PitchShift`'s windows lose a little.
- Around a reverb, the loop's gain per pass is the amount times the reverb's own gain, which is above 1 for steady input. FreeVerb2's wet was 5-11 dB above its input on steady pink noise (measured, 1 s windows). The loop is stable only while the shift carries energy out through the LPF or HPF. At ratio 2 or 0.5 and size 0.8 it decayed at every amount up to 0.95, its tail a little longer than the plain reverb's (FreeVerb2 at 0.95: −21.6 dB at 1.5 s, against −28.1 dB without shimmer). At ratio 1 it grew at amount 0.3 (+10.4 dB in 9 s, 3.13) and reached inf at 0.5 and 0.95. At 1.02 and 0.95 it grew +122 to +126 dB on FreeVerb2 and +110 to +117 dB on the FDN. At an octave up with size 1 and damp 0 it grew +54 dB on FreeVerb2 (peak 57-67), while the FDN at the same settings decayed.
- What keeps it bounded: nothing today. The master's `Limiter` is after the sum (`:241`), and a loop inside `\strataReverb` reaches inf and then NaN, which the chain never zeroes after the reverb (`zeroBadValues` guards only the filters' inputs, `:142`). The options: a soft clip (`tanh`) or `Limiter` inside the loop (a `Limiter` with a 0.01 s lookahead costs about 6 KB a channel, `FilterUGens.cpp:3396-3400`); an amount clipped by size, or by a gain that keeps amount × the reverb's gain below 1; ratios at least a fifth from 1; and the filters already in the prototype loop. A delay shimmer is bounded by the feedback clip as long as the shifter's gain stays at most 1. The Doppler taps are a convex mix of two reads (their Hann gains sum to 1), so they never exceed the line's peak.

## 3. Delay freeze and clear

**Freeze on `\strataDelay`** (prototype `\pDelayFreezeC`, 1036.4 KB, +4.2 KB and 31 UGens over today's):
- Feedback at 1: `feedback.clip(0, 0.95).max(frozen)`, exactly 1 when frozen. A lerp such as `f + frozen·(1 − f)` need not round to 1.0 in single precision. The 0.95 clip stays for `setDelay`, which Lua and the stub hold to 0.95.
- Input closed: the input times `1 − frozen`, with the freeze lagged 20 ms so neither the input nor the loop steps. `liftFade` stays as it is.
- In the loop there is no filter and no saturation: the master filter for the delay is on the send, before the delay (`\filterDelay`), and the limiter and `tanh` are in the master. So a held loop neither grows nor decays, except through `DelayC`'s interpolation. The loop is `time` plus one block long, because `LocalIn` returns the last block's `LocalOut` (`LocalIn.schelp:18`).
- Measured (steady pink noise, frozen while it plays; energy in 1 s windows, both versions): at 0.375 s (18000 samples) the held loop stayed within 0.2-0.4 dB of itself for 9 s at ping-pong 0 and 1. The step at the freeze (−2.8 to +1.7 dB across cases) is the held 0.38 s sample's own level against the window before. In the 6-24 kHz band at 0.375 s: 0.00 to −0.05 dB over 9 s. At 0.30928 s (14845.4 samples) it lost 10.7-11.0 dB in 9 s, and at 0.3001 s 9.1 dB. Pink noise at 0.30928 s lost only 0.2 dB, its energy being low. Rounding the frozen time to whole samples avoids the loss (est.: the FDN's rounding test, §4, held exactly), at the cost of a step of under half a sample at the freeze. The loss per second grows with passes per second, so a short time darkens faster (est.: about −0.35 dB a pass at 6-24 kHz, from the figures above).
- Ping-pong: the cross-feed (`:163-164`) is the matrix `[[1 − p, p], [p, 1 − p]]` on the two lines' feedback, with eigenvalues 1 (sum) and 1 − 2p (difference). Frozen at p = 0.5, the side signal measured −36.9 to −43.5 dB at 0.3 s and −999 from 1.8 s on, so the loop is held in mono. At p = 1 the sides swap each pass and hold. A design either documents it, or sets the cross-feed to 0 or 1 while frozen.
- The 0.05 s mix lag acts on the return only. A freeze does not need it, and `mix` 0 with a freeze holds the loop silently while the node runs.
- Released (freeze to 0), the loop decays at the kept feedback (measured: −42 to −44 dB 2 s after a release at 0.4).
- Delay shimmer while frozen is stable (§2). Freeze then bypass loses the loop: a lift re-creates the node empty (`:358-362`).

**Clear: the options.**

| Option | What it does | Cost | Measured |
|---|---|---|---|
| Re-create the node, as a lift does (`startDelay(..., \addAfter, 0, 1)` after a free) | a new, empty line; the input fades in over 0.05 s (`liftFade`) | none in the pool (the free and the `/s_new` in one bundle return and take the same 1 MB) | not measured. A free cuts the return at once unless the mix is faded first, as a bypass does (0.05 s + a block). It re-creates every control from the kept values, as a lift does. |
| A window of zero feedback (`t_clear`, `Trig1` of the delay time + 5 ms, on the feedback and the return, the return lagged 3 ms) | the return is silent at once; the line refills with the input only; the first post-clear echo plays one delay time later | 4.2 KB with freeze; works on `DelayC` as it is | steady input: silent from 20 ms to 0.32 s after the clear, the first echo window 3.2 dB under the window before (fresh echoes building), then back to normal. Input stopped before the clear: −142 dB after the window (both versions). Frozen and cleared: an empty frozen loop. A time lengthened during the window could read pre-clear content (est.). |
| A buffer line zeroed from outside: `/b_zero` | `memset` in the NRT thread (`SC_SequencedCommand.cpp:432-436`), asynchronous to the audio | needs the buffer delay (§1 of 0) | silent within 0.3 s but not at once (3.14.1: the 2.02-2.32 s window 11.7 dB down); then a one-block residual recirculating at −26 to −39 dB under the pre-clear level |
| `/b_fill buf 0 frames 0.0` | a loop over the buffer in the audio thread, inside the bundle (`SC_MiscCmds.cpp:1405-1432`) | the same; 2 × 131072 writes in the audio thread (est. under 1 ms on a Pi 4; not measured on a device) | silent at once, the same residual (−28 to −39 dB) |
| either with a 10 ms mute of the feedback in the same bundle | | | b_fill: silent at 5 s, −31 to −35 dB at 6 s; b_zero: −30 to −33 dB. The residual is the block in `LocalIn` written back after the zero: my mute's 3 ms control-rate lag left 0.047 of it in the first block (`0.001^(1/(0.003 × 750))`). An exact external clear needs the feedback × exactly 0 in the block of the fill. |

**The buffer delay, measured** (`\pDelayBufC`: `BufDelayC.ar([bufL, bufR], lineIn, lagTime)` on two `Buffer.alloc(server, 2 ** 17, 1)`):
- Pool: 13.5 KB (60 UGens with freeze and clear), against 1032.2 (both versions). Floors: +1010 to +1030 KB at every case on both versions (table in §2). Standard synth -> buffer -> synth: 4480 → 5490/5510. High: 3820 → 4830. High pool: 1750/1760 → 2780. Idle: 6580 → 7600.
- Sound: identical to `DelayC`. Largest difference 0.0 over 5.5 s, fixed and LFO-modulated time, feedback 0.4, ping-pong 0.5 (3.14.1, two runs). Both use the same cubic interpolation helper on a power-of-two line. `BufDelayC` clips the delay to `PREVIOUSPOWEROFTWO(bufSamples) − 1` (`DelayUGens.cpp:2146-2149`), so its buffer should be a power of two. A `BufWr`/`BufRd` line (needed for Doppler taps) is not identical: −21.7 dB under modulation and −54 dB fixed, as `BufRd`'s index interpolation differs from `DelayC`'s time interpolation. Its CPU is 0.55× FreeVerb2's, against 0.20. `DelTapWr`/`DelTapRd` costs 0.22× (not compared for sameness).
- Freeze on it holds as on `DelayC` (within 0.15 dB over 9 s).
- What it touches: two buffers allocated in the effects area's `allocState` (ordinary RAM, 1 MB; `Buffer.alloc` is synced before `start`, `lib/Engine_Strata.sc:135-145`; "bufnums never change" holds), freed in `free`. A bypass no longer returns 1 MB: the "the delay's 1 MB" lines in `docs/user/effects.md:26`, `effects.md:36` and the check (`checkBypassMemory`, `effects.scd:872-884`, which requires 900-1100 KB) change. The 2.7 s cap becomes a choice, not the pool's (`effects.md:16`, `lib/delay_sync.lua:23`).

## 4. A reverb freeze

- **FreeVerb2:** no freeze input and no reachable loop (§1). Room 1 is comb feedback 0.98, and damping stays in the loop (`ReverbUGens.cpp:676-689`). Measured on 3.14.1 (a 0.05 s burst, energy windows): size 1 at damp 0 fell 53.7 dB from 0.6 to 10 s (5.7 dB/s, RT60 about 10.5 s), and at damp 0.5 by 54.1 dB. The FDN at size 1 and damp 0 fell 57.5 dB (RT60 about 9.8 s). So "size 1" is a long tail, not a freeze. An outer loop at gain about 1 would sustain it, and grows (§2, ratio 1).
- **The FDN** (`\pFdnFreeze`, 212.8 KB, +3.8 KB and 25 UGens): input × (1 − frozen) before the diffusers, each line's gain `.max(frozen)`, damping × (1 − frozen), the freeze lagged 20 ms. Measured (steady noise until the freeze, both versions): pink noise held within 0.6 dB over 9 s, with the drift on or off. The 6-24 kHz band fell 48 dB in 9 s with the drift on and 44.5 dB with it off, from `DelayL`'s linear interpolation at fractional lengths (`fdnLineSeconds × (0.6 + 0.4·size)`). With the lengths rounded to whole samples (check-only `\sFdnFreezeRound`, drift off), the band held to ±0.05 dB. The drifting lines (3 and 7, `LFNoise1`) cannot be rounded without steps, so a frozen FDN would hold them still.
- The level at the freeze: the output stepped by −2.5 and −2.5 (rounded lengths, and today's with drift on), −1.9, −1.3, +5.3 and +5.3 (rounded, the 6-24 kHz band), +10.5 and +11.9 dB (today's lengths), then held, across 3.14.1 and 3.13. The sign and size changed with the run and the version. The likely cause (est.): the diffusers (`AllpassN`, decay 19 × their delay, 0.1-0.5 s) keep emptying their stored input into a network that has just become lossless. Closing the input after the diffusers would test it (not done).
- Releasing an FDN freeze returns it to its decay (measured: −64 dB under the pre-freeze level 2.2 s after the release).
- Cost and tier: freeze needs no line, so it costs 3.8 KB, on high only. The standard reverb has no equivalent short of a different standard reverb.

## 5. Plain sends

What a conventional mixer (dry at full level, sends as sends, mixes as return levels) changes:
- **The stage** (`StrataMix.sc:252-260`): `voiceOutput` becomes `Out(out, sig)`, `Out(delaySendOut, sig·s_d)`, `Out(reverbSendOut, sig·s_r)`. The `In.kr(fxMixIn, 2)` and its lag go, so `fxMixIn` leaves `mixBusControls` (`:111-117`) and `stageControls`. Measured: 38.8 KB against 41.29 KB (both versions), 166 UGens against 178.
- **The effects:** `masterSum` (`StrataEffects.sc:106-110`) loses `(1 − m_r)` on the delay return and its `In.kr(fxMix + 1)`. Whether the delay still feeds the reverb (`\strataReverb`'s `delayIn`, `:175`, and the FDN's, `:193`) becomes a choice: a conventional mixer would give the delay return a reverb send, or none. `fxMix` and `broadcastFxMix`, `liveMix` and the one-bundle rule (`effects.md:4`) lose every reader but the record area's pre-master tap. That tap is `masterSum` itself (`StrataRecord.sc:82-83`), so it follows. The nodes' own `mix` controls become the return levels; a bypass still sets them to 0.
- **Three master filters or one:** the filter is linear, so three on three buses equal one on their sum before the effects (`effects.md:27`). That holds whatever the gain law, as long as the sends are separate buses. One filter does the same job only if it moves: onto the master sum (it then filters the returns too, a different sound), or onto the dry bus alone (the effects then hear unfiltered sends). Two `\strataFilter`s less gives back 22.0 KB (measured 11.0 KB each).
- **Commands:** `setReverb` and `setDelay` keep their signatures; their `mix` becomes a return level. `setFilter` is unchanged with three filters. The per-voice sends (`delaySend`, `reverbSend`, `grainParamHandlers`, `StrataMix.sc:25-32`) are unchanged in name and range. A conventional mixer has no fully-wet setting: at m_d = m_r = 1 today's dry is 0, a plain mixer's is 1. Fully wet would need a dry level per voice or globally (a new param, or the stage's `amp`).
- **Level at the defaults** (sends 1, delay mix 0, reverb mix 0.3; Lua's defaults, `lib/params_setup.lua:558-575`): dry 0.7 → 1, **+3.10 dB**. The reverb's return is unchanged (its input is `x` either way while m_d = 0). The delay is silent at mix 0. With delay mix m_d and reverb mix m_r, today → plain: dry `(1 − m_d)(1 − m_r)` → 1; the delay return `m_d(1 − m_r)` → m_d (+3.10 dB at m_r 0.3); the reverb's input from the voice `(1 − m_d)` → 1 (+6.0 dB at m_d 0.5), and from the delay `m_d·D` → whatever the design keeps. To keep today's default balance, the reverb's default return would be 0.3/0.7 = 0.43 and the master 3.1 dB lower (est.).
- **Checks that compare with 3.0's chain:** `test/engine_check/effects.scd`, `checkChain30` (`:492-549`, 58 lines with its comment; two calls, `:1094-1096`), `checkDrySends` (`:551-588`, 38 lines, which asserts the crossfade gains 0.02 and 0.2), the check-only `\strataCheck30Delay` and `\strataCheck30Reverb` (`:96-107`; `\strataCheck30Filter`, `:83-95`, is also #305's reference and stays) and `\strataCheckChainSource`/`\strataCheckMasterSum` (`:108-120`). Then the harness's `voiceOutput32` (`test/engine_check.scd:112-120`, 9 lines), which every `mix.scd` comparison of the sends uses with today's law at the default mixes (`mix.scd:96, 137, 385, 590-591, 624-625`). `modulation.scd:212` calls `engine.voiceOutput` and follows. `record.scd:247-307` compares the pre-master tap with `masterSum` and follows. `structure.scd:84` lists the `fxMix` bus, and `memory.scd:155` passes `fxMixIn`. In the docs: `effects.md:4` ("Sends at 1 are 3.0's chain"), `mix.md:31, 36`, AGENTS.md's invariant "Sends reproduce 3.0's chain", and `docs/user/effects.md:20`.
- **What the pool gets back:** with the plain stage, the cases read +10 to +20 KB (3.14.1: high synth -> buffer -> synth 3830, standard 4500, high pool 1760), and one master filter would add 22 KB. Under 45 KB in all, a twentieth of the buffer delay's return.

## 6. Commands and defaults

- `setDelay(time, feedback, mix, pingPong)`, `"ffff"` (`StrataEffects.sc:282-292`): ignores a non-finite argument (`fastModValuesFinite`), keeps all four (`keepEffectControls`), then in one bundle sets the node (mix × `effectLive`) and broadcasts `fxMix`. `setReverb(mix, size, damp)`, `"fff"` (`:257-263`): the same, with no finiteness check. `setBypass(effect, bypassed)`, `"ii"` (`:295-298`): 0 delay, 1 reverb; a bypass frees after `bypassFadeTime`; a lift re-creates from the kept controls at mix 0 with `fadeIn` 1 (`:334-367`). While bypassed, `setDelay`/`setReverb` keep their values and the broadcast stays 0.
- **The defaults rule:** the kept controls start from the SynthDefs' defaults (`effectDefaults`, `:395-399, 405-406`), which must equal Lua's param defaults, because the script never bangs its params (`effects.md:14`). A Lua test compares them, and the engine check reads a fresh engine's nodes (#364). So a new control has a SynthDef default equal to its Lua param's. It joins the `effectDefaults` list of its effect, and joins `keepEffectControls` in its command so a lift keeps it (3.7's facts, `docs/design/3.7-facts/engine.md:14`).
- **Freeze:** a new command or a changed signature. `setDelay` would become `"fffff"` with a freeze argument every send repeats. A command of its own, say `setDelayFreeze(frozen)` `"i"`, is kept the same way and sent to the node with `setSynth`. Lua's freeze state must not be `delay_feedback` (clip 0.95). Whether it is a scene field is the design's (a bypass is not, `docs/user/effects.md:30`).
- **Clear:** a trigger with no state, e.g. `clearDelay()` with signature `""` (norns allows an empty format: `~/src/norns/sc/engines/Engine_PolySub.sc:136`; the stub reads `"([^"]*)"`, `test/norns_stubs.lua:214`). For the window clear it sets `t_clear` (never kept). For a buffer line it sends `/b_fill` and an unlagged feedback mute in one bundle. While bypassed there is nothing to clear.
- **Shimmer:** an amount and an interval per placement, kept through a bypass. They go on `setDelay`/`setReverb` (wider signatures) or a `setShimmer(effect, amount, ratio)` `"iff"`. A ratio's limits go in a literal `.clip(lo, hi)` in the def for the stub. A window is a literal, never a control.
- **The table and the stub:** every new `addCommand` needs its AGENTS.md row with ranges, and matching `engine.*` calls (`test/sync_check.lua`; AGENTS.md has 225 words left, `docs/status.md:40`). The stub reads the FX controls from `this.setSynth(\delay, \control, msg[i])` pairs in the command body. It maps `synths[\delay] = Synth(\strataDelay` literally (`norns_stubs.lua:465-470`), so a tier-chosen def name must keep each `Synth(\name` literal, as `startReverb` does with its `if` (`:387-391`). Every SynthDef must open with an `arg` list, or the stub fails at load (`:452-454`).

## Where the roadmap or the notes are wrong or silent

- `ROADMAP.md:135`: "a pitch shifter is a delay line ... may offer it on the high tier only". A buffer-based shifter's line is ordinary RAM: 12-17 KB of pool, any window (§2). And for a `PitchShift` the pool argues the other way: standard has about 1400 KB above its floor, high 236 (two `PitchShift` shimmers fail high and pass standard, measured). CPU is the high tier's argument, not memory.
- `ROADMAP.md:170`: "feedback at one and its input closed ... clear empties it at once". `DelayC`'s line cannot be emptied from outside: clear is a mute window or a buffer line (§3). The roadmap is also silent on ping-pong collapsing a frozen loop to mono, and on interpolation darkening it at fractional times.
- `ROADMAP.md:170`: "A reverb freeze is possible only in the high tier's reverb". True. It is silent on the darkening (5 dB/s at 6-24 kHz unless the lengths are whole samples) and on the level step at the freeze (§4).
- `ROADMAP.md:130` and `docs/design/3.7-facts/revisit.md:124-126`: "I did not measure what the stage would get back": 2.5 KB a stage (§5). And "the master filter runs three times" is the price of filtering before the effects, under either gain law, not of the crossfade.
- `docs/notes/engine/effects.md:16` and `:36`, `docs/user/effects.md:26`: the 1 MB and the 2.729 s cap are `DelayC`'s, not the delay's: a buffer line removes both (§3).
- `docs/notes/engine/memory.md:28` and `docs/design/3.7-facts/engine.md:224` give the master's pool cost as its `PitchShift`'s 16 KB. `\strataMaster` measures 39.6 KB: its `Limiter` takes about 11 KB more (`FilterUGens.cpp:3396-3400`).
- `docs/notes/engine/effects.md:30`: the FDN "about 202 KB"; it measures 209.0 KB on both versions with ten nodes (the check's single-node reading is coarser).
- `docs/notes/engine/effects.md:8` says the filters' NaN guards keep a voice from poisoning "the delay feedback or the reverb for good". That holds for bad input only. A loop the effect builds itself (shimmer) can produce inf or NaN downstream of every guard (§2).
- Silent everywhere: one audio-rate `LocalIn` per SynthDef (`LocalIn.schelp:12`), which shapes any shimmer or freeze loop in `\strataDelay` and `\strataReverbFDN`. And the stub's requirement of an `arg` list on every SynthDef (`test/norns_stubs.lua:454`).

## Unsure

- CPU on a norns: every CPU figure is x86 NRT, relative to FreeVerb2. On a CM3 or Pi 4 the ratios should hold roughly (est.); absolute load needs #6.
- `/b_fill`'s time in the audio thread on a CM3 (2 × 131072 writes): not measured on a device.
- `/b_zero`'s latency: it took effect within the first 0.3 s window but not at once. The NRT thread's timing was not resolved further.
- The FDN's level step at freeze (−2.5 to +11.9 dB): the diffusers' cause is an estimate. I did not test closing the input after the diffusers.
- The `DelTapRd`-based Doppler shifters' pool cost: not measured (graph only, est. under 15 KB). Their sound against `PitchShift`'s was not compared by measurement.
- One `PitchShift` placement on high (about 3690 KB, est. from the defs' sizes): not run as its own variant. The two-placement run fails, and the arithmetic of the defs matched every variant I ran within 10-20 KB.
- NRT renders of defs with `PitchShift` ended with scsynth 3.14.1 signal 11 at exit, after the render had finished. The real-time engine checks with the same UGen ran clean on both versions, so I take it as NRT teardown only.
- The re-create-the-node clear was not built or measured.

## Appendix: the prototypes' source

Scratch, uncommitted, in the worktree: `lib/engine/StrataScratchFx.sc` (below), the variant hooks in `lib/engine/StrataEffects.sc` (`allocScratchFxBuffers`/`freeScratchFxBuffers` in `allocEffectBuses`/`freeEffects`, `addScratchFxDefs` at the end of `addEffectDefs`, `Synth(this.scratchDelayDef, ... ++ this.scratchDelayArgs ...)` in `startDelay`, `Synth(this.scratchReverbDef, args ++ this.scratchReverbArgs, ...)` in `startReverb`) and `lib/engine/StrataMix.sc` (`\pVoiceMixPlain` for variant `plain`). Also `test/engine_check/fxscratch.scd` (on demand: `STRATA_ENGINE_CHECK_AREAS=fxscratch`, `STRATA_FXSCRATCH_PART=sizes|behavior`) and `\fxscratch` in `test/engine_check.scd`'s `areaOrder` and `onDemandAreas`. Variants run with `STRATA_SCRATCH_FX=none|bufdelay|shimps|shimbuf|plain` (Docker runs read `scratchFxDefault`).

```supercollider
+ Engine_Strata {
    scratchFxDefault { ^"none" }

    scratchFxVariant {
        var text = "STRATA_SCRATCH_FX".getenv;
        if (text.isNil or: { text.isEmpty }) { text = this.scratchFxDefault };
        ^text.asSymbol
    }

    allocScratchFxBuffers {
        var state = areaState[\effects], server = context.server;
        state[\scratchDelayBufs] = 2.collect({ Buffer.alloc(server, 2 ** 17, 1) });
        state[\scratchShiftBufs] = 2.collect({ Buffer.alloc(server, 2 ** 14, 1) });
    }

    freeScratchFxBuffers {
        var state = areaState[\effects];
        (state[\scratchDelayBufs] ++ state[\scratchShiftBufs]).do({ arg buf; buf !? { buf.free } });
    }

    // Two Hann-windowed read heads half a period apart (gains sum to 1)
    scratchDopplerRead { arg buf, writeFrame, frames, ratio, window, offset;
        var saw = LFSaw.ar((1 - ratio) / window, [0, 1]).range(0, 1);
        var delay = offset + (saw * window);
        var gains = (saw * pi).sin.squared;
        ^(BufRd.ar(1, buf, (writeFrame - (delay * SampleRate.ir)).wrap(0, frames), 1, 4) * gains).sum
    }

    // kind: \delayC, \bufDelayC, \bufWr; shimmer: nil, \ps, \taps (\bufWr only)
    scratchDelayBody { arg kind, shimmer;
        var in = \in.kr(0), out = \out.kr(0), time = \time.kr(0.375), feedback = \feedback.kr(0.4), mix = \mix.kr(0);
        var pingPong = \pingPong.kr(0), fadeIn = \fadeIn.kr(0), freeze = \freeze.kr(0), clear = \t_clear.tr(0);
        var shimmerAmount = \shimmer.kr(0).clip(0, 1).lag(0.05), ratio = \shimmerRatio.kr(2).clip(0.25, 4), window = 0.1;
        var bufs = [\bufL.kr(0), \bufR.kr(0)];
        var frozen = freeze.clip(0, 1).lag(0.02);
        var lagTime = time.lag(0.1).clip(0.01, 2.7);
        var clearSeconds = \clearSeconds.kr(0);
        var clearGain = (1 - Trig1.kr(clear, ((clearSeconds <= 0) * lagTime) + clearSeconds + 0.005)).lag(0.003);
        var input = In.ar(in, 2) * this.liftFade(fadeIn) * (1 - frozen), returned = LocalIn.ar(2);
        var cross = pingPong.clip(0, 1).lag(0.05), keep = 1 - cross;
        var loopGain = feedback.clip(0, 0.95).max(frozen);
        var lineIn = [
            input[0] + (input[1] * cross) + (returned[0] * keep) + (returned[1] * cross),
            (input[1] * keep) + (returned[1] * keep) + (returned[0] * cross)
        ];
        var delayed, fed, frames, phase;
        delayed = switch (kind,
            \delayC, { DelayC.ar(lineIn, 2.7, lagTime) },
            \bufDelayC, { BufDelayC.ar(bufs, lineIn, lagTime) },
            \bufWr, {
                frames = BufFrames.ir(bufs[0]);
                phase = Phasor.ar(0, 1, 0, frames);
                bufs.collect({ arg buf, index;
                    BufWr.ar(lineIn[index], buf, phase);
                    BufRd.ar(1, buf, (phase - (lagTime * SampleRate.ir)).wrap(0, frames), 1, 4)
                })
            });
        fed = switch (shimmer,
            \ps, { delayed + ((PitchShift.ar(delayed, window, ratio, 0, 0) - delayed) * shimmerAmount) },
            \taps, {
                delayed + ((bufs.collect({ arg buf; this.scratchDopplerRead(buf, phase, frames, ratio, window, lagTime) })
                    - delayed) * shimmerAmount)
            },
            { delayed });
        LocalOut.ar(fed * loopGain * clearGain);
        Out.ar(out, delayed * clearGain * mix.clip(0, 1).lag(this.fxMixLag));
    }

    // An outer shimmer loop around a reverb (\freeverb or \fdn), shifter \ps or \buf
    scratchShimmerLoop { arg shifter, reverb;
        var amount = \shimmer.kr(0).clip(0, 0.95).lag(0.05), ratio = \shimmerRatio.kr(2).clip(0.25, 4), window = 0.1;
        var bufs = [\shiftL.kr(0), \shiftR.kr(0)];
        var size = \size.kr(0.8), damp = \damp.kr(0.5);
        var feedback = LocalIn.ar(if (reverb == \fdn) { 10 } { 2 }), loop, in, wet, lineOut, shifted, frames, phase;
        loop = if (reverb == \fdn) { feedback.copyRange(8, 9) } { feedback };
        in = (In.ar(\in.kr(0), 2) + In.ar(\delayIn.kr(0), 2)) * this.liftFade(\fadeIn.kr(0));
        if (reverb == \fdn) {
            #wet, lineOut = this.scratchFdnCore(in + loop, size, damp, 0, 1, feedback.copyRange(0, 7));
        } {
            wet = FreeVerb2.ar((in + loop)[0], (in + loop)[1], 1, size, damp);
            lineOut = [];
        };
        shifted = if (shifter == \ps) { PitchShift.ar(wet, window, ratio, 0, 0) } {
            frames = BufFrames.ir(bufs[0]);
            phase = Phasor.ar(0, 1, 0, frames);
            bufs.collect({ arg buf, index;
                BufWr.ar(wet[index], buf, phase);
                this.scratchDopplerRead(buf, phase, frames, ratio, window, ControlDur.ir * 2)
            })
        };
        LocalOut.ar(lineOut ++ (HPF.ar(LPF.ar(shifted, 6000), 100) * amount));
        Out.ar(\out.kr(0), wet * \mix.kr(0.3).clip(0, 1).lag(this.fxMixLag));
    }

    // The FDN's core with freeze; returns [wet, the eight LocalOut channels]
    scratchFdnCore { arg sig, size, damp, frozen, driftOn, feedback;
        var room = size.clip(0, 1).lag(0.1), damping = damp.clip(0, 1).lag(0.1) * 0.4 * (1 - frozen);
        var feedbackBase = 0.7 + (0.28 * room), reference = 1378 * SampleDur.ir;
        var drift = [0, 0, LFNoise1.kr(0.31) * 0.0006, 0, 0, 0, LFNoise1.kr(0.43) * 0.0005, 0] * driftOn;
        var lengths = this.fdnLineSeconds * (0.6 + (0.4 * room)) + drift;
        var diffused, lines, sum;
        diffused = (sig * (1 - frozen)).collect({ arg channel, side;
            this.fdnDiffuserSeconds[side].inject(channel, { arg each, time; AllpassN.ar(each, time, time, time * 19) })
        });
        lines = 8.collect({ arg index;
            var line = DelayL.ar((diffused[index % 2] * 0.25) + feedback[index], this.fdnLineSeconds[index] + 0.002,
                lengths[index] - ControlDur.ir);
            OnePole.ar(line, damping)
        });
        sum = lines.sum * (2 / 8);
        ^[[lines[0] + lines[2] + lines[4] + lines[6], lines[1] + lines[3] + lines[5] + lines[7]],
            lines.collect({ arg line, index; (line - sum) * (feedbackBase ** (lengths[index] / reference)).max(frozen) })]
    }

    addScratchFxDefs {
        SynthDef(\pDelayFreezeC, { this.scratchDelayBody(\delayC, nil) }).add;
        SynthDef(\pDelayBufC, { this.scratchDelayBody(\bufDelayC, nil) }).add;
        SynthDef(\pDelayBufWr, { this.scratchDelayBody(\bufWr, nil) }).add;
        SynthDef(\pDelayShimPS, { this.scratchDelayBody(\delayC, \ps) }).add;
        SynthDef(\pDelayShimTaps, { this.scratchDelayBody(\bufWr, \taps) }).add;
        SynthDef(\pReverbShimPS, { this.scratchShimmerLoop(\ps, \freeverb) }).add;
        SynthDef(\pReverbShimBuf, { this.scratchShimmerLoop(\buf, \freeverb) }).add;
        SynthDef(\pFdnShimPS, { this.scratchShimmerLoop(\ps, \fdn) }).add;
        SynthDef(\pFdnShimBuf, { this.scratchShimmerLoop(\buf, \fdn) }).add;
        SynthDef(\pFdnFreeze, {
            var frozen = \freeze.kr(0).clip(0, 1).lag(0.02), wet, lineOut;
            var sig = (In.ar(\in.kr(0), 2) + In.ar(\delayIn.kr(0), 2)) * this.liftFade(\fadeIn.kr(0));
            #wet, lineOut = this.scratchFdnCore(sig, \size.kr(0.8), \damp.kr(0.5), frozen, \drift.kr(1), LocalIn.ar(8));
            LocalOut.ar(lineOut);
            Out.ar(\out.kr(0), wet * \mix.kr(0.3).clip(0, 1).lag(this.fxMixLag));
        }).add;
        // \pVoiceMixPlain: \strataVoiceMix (StrataMix.sc:141-172) verbatim but
        // its last lines, where this.voiceOutput(sig, ...) becomes:
        //   Out.ar(c[\out], sig);
        //   Out.ar(\delaySendOut.kr(this.mixBus(\delaySend).index), sig * c[\delaySend].clip(0, 1).lag(this.fxMixLag));
        //   Out.ar(\reverbSendOut.kr(this.mixBus(\reverbSend).index), sig * c[\reverbSend].clip(0, 1).lag(this.fxMixLag));
    }
    // (scratchDelayDef/Args and scratchReverbDef/Args pick the variant's def
    // and its extra args: bufdelay \pDelayBufC; shimps \pDelayShimPS and
    // \pReverbShimPS or \pFdnShimPS at shimmer 0.5; shimbuf \pDelayShimTaps and
    // \pReverbShimBuf or \pFdnShimBuf at shimmer 0.5)
}
```

Check-only defs in `test/engine_check/fxscratch.scd`: the measured shifters (`\sPS1`, `\sPS2`: `PitchShift.ar(In.ar(in, n), window, 2, 0, 0)`; `\sGrainShift`: `BufWr` of both channels at a `Phasor` over a 2^14-frame ring, then `GrainBuf.ar(1, Impulse.ar(40), 0.1, buf, 2, ((phase / frames) - 0.2).wrap(0, 1), 4, 0, -1, maxGrains)` per channel; `\sDoppler`: `BufWr` plus `scratchDopplerRead(buf, phase, frames, 2, 0.1, ControlDur.ir * 2)` per channel; `\sFreqShift`). And `\sFdnFreezeRound`: the FDN core with drift off and `lengths = ((fdnLineSeconds × (0.6 + 0.4·size) − ControlDur.ir) × SampleRate.ir).round / SampleRate.ir`. The analysis defs are `\sEnergyWin` (mean energy and side energy in six server-timed windows, by `Integrator.ar`) and `\sDiffPeak` (the peak |a − b|). The NRT CPU bench (`make_scores.scd`, `run_bench.sh`) is in the scratch folder `/tmp/claude-1000/-home-sethbc-src-strata/7b6fc544-bdee-4477-ba59-2c1dad21aefd/scratchpad/engine-effects/bench/`, with every log (`mem-<variant>-3141.log`, `d313-<variant>/run-1.log`, `fx-*.log`) one folder up.
