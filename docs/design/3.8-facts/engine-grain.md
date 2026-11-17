# 3.8 facts: the grain stage and the rings (engine)

Read against `main` at 59a0a0c1 (the groundwork's packages change no grain-stage engine code: `docs/design/3.8-groundwork-design.md:39`, `:222`, so today's engine is the one 3.8 builds on). I prototyped the four grain additions, a second kind of ring per voice and seven new grain sources as uncommitted scratch in this worktree (Appendix), and ran the engine check's `memory` area four times on SuperCollider 3.14.1 (local, port 57852): R0 is `main` as it is, R1 has all four additions in both grain defs with the output rings, R2 has the set that nearly fits plus a sixth fast destination, and R3 has today's grain defs with the output rings. I ran R2 once more on 3.13.0 in Docker. Every figure is **measured** (allocation probes, the memory area alone, probe steps of 0.84 KB per def and 10 KB per case) unless it says **quoted** or **(est.)**. Each table names its version and tier. Nothing here was checked on a device.

## 0. The facts most likely to change the design

1. **"Every voice already writes a ring" is true, but the ring holds only the voice's own synth.** A writer runs at the tail of `voiceGroup` and records `granBuses[i]` before the stage writes its mirror there (`lib/engine/StrataRings.sc:120-132`, `docs/notes/engine/rings.md:4`, `:108`). So a synth voice's ring holds its raw voice synth and its voice-synth notes, before the grains, the filter and the level. A buffer or input voice's ring holds silence. Reading another voice's ring therefore gives that voice's raw synth, and only while it is on its synth source. Chains stop after one hop: a voice that reads another has no synth, so its own ring is silent. To grain another voice's *sound*, each voice needs a second ring that records its post-stage output: the voice tap already exists (`lib/engine/StrataRecord.sc:64`, `StrataMix.sc:171`), but nothing writes it into a ring.
2. **A second reader of a ring costs nothing in the pool.** The reader is the reading voice's own `\strataGrainRing`, the same def an input voice runs, and a `GrainBuf` reads its buffer from ordinary RAM. I measured every voice reading another voice's ring, alone and with the note pool full, on both tiers. Each case leaves as much as or more than the existing case it mirrors (table in 1.9). The only new real-time memory is the output-ring writer, 5.06 KB each, 35 KB for seven. On the high tier a reader's spectral freeze adds one spectral copy writer, as an input voice's does today.
3. **A loop of voices reading each other has no bound today.** I measured one ring grain synth's gain from −6 dB at Lua's defaults to +31 dB at size 0.5 and density 200 with no spread. On a loop the grains read coherently, so the gain is the overlap times half the window's peak, times Balance2's 0.707. The stage multiplies by up to 2 (`voiceLevel`, `StrataMix.sc:54-55`). The only guards, `zeroBadValues` in the writer and in the stage, catch NaN, inf and denormals and nothing large (`StrataRings.sc:110`, `docs/notes/engine/mix.md:8`). A loop with a gain above 1 grows until inf, is zeroed, and then resets the stage over and over. The rule that a grain reads behind the head does make every loop a delayed feedback, of at least 5 ms plus two blocks (est.).
4. **`\strataGrainBuf` cannot take all four additions.** With all four it measures 93.5 KB against its 88 KB limit; `\strataGrainRing` measures 74.2 KB and fits. The additions cost, in the buffer def: window pick 2.5 KB, probability 0.84, channel 0.84 as a control (0 as a read pair), and the arpeggiator 6.7 KB with four orders in the graph, 5.1 without the shuffle, or 2.5 as a bare counter whose order Lua writes into `interval1..8`. Even the cheapest full set (window, probability, counter, channel control) measures 88.48 KB, at the limit (R2, R3, the same on 3.14.1 and 3.13).
5. **The worst cases fail on the high tier with those sets.** With all four additions (R1, 3.14.1), the high all-buffer case with the pool full fails its 1280 KB floor. The high synth -> buffer -> synth case runs the pool dry: the probes' reserve `DelayN` and the spectral writers' late allocations print `alloc failed`, and a `/c_getn` reply fails with "out of real time memory". With the cheapest set and a sixth fast destination (R2, the same on 3.14.1 and 3.13), the high synth -> buffer -> synth case still prints `alloc failed` for the reserve and for one `PV_MagFreeze`. Every other case holds. On today's figures (3820 KB, 236 above the floor, quoted from `docs/status.md`) the high mixed case has room for about 120 KB of new grain-synth memory once the late allocations are counted.
6. **A sixth fast destination (for the window) breaks two node limits.** Scatter goes from 42.1 to 50.6 KB (its limit is 45) and the offset node from 11.8 to 13.5 KB (its limit is 13.5, checked with `<`). The buffer def grows one probe step (0.84 KB) from reading six channels instead of five. Measured on R2, 3.14.1 and 3.13.
7. **The input channel choice can cost nothing.** "Left" is the left input buffer as both `bufL` and `bufR` of the read pair, "right" is the right buffer twice. That is a change to `grainReadPairs` and `returnToInputRing` alone, with no UGen, and it applies to a frozen copy ring the same way (copy L twice). As a control in the def it costs 0.84 KB.
8. **A continuous window is a bank of tables that never change.** GrainBuf latches the envelope buffer *number* per grain, but it reads that buffer's *contents* live on every block of the grain (`server/plugins/GrainUGens.cpp`, `GrainBuf_next_start_new` and `GET_GRAIN_AMP_PARAMS`, SuperCollider develop). Rewriting a table under sounding grains changes them mid-grain. A 16 × 8 bank (shape × skew) of 1024-frame tables is 512 KB of ordinary RAM. Built from `Signal` primitives only, it took 2-3 ms. It got consecutive bufnums (59-186) from `Buffer.allocConsecutive`, with 201 buffers in use of the server's 1024. Its pick per grain costs 2.5 KB a def.
9. **Constant overlap cannot be Lua-only once the size is modulated in the engine.** Grain size is fast destination 2: engine LFOs, scatter and the envelopes move it on the server, as do 3.5's `noteSize` and the size jitter (`StrataModulation.sc:187`ff, `StrataVariation.sc:62-64`). Lua sees only base values, so pairing the two params in Lua keeps the overlap constant only while nothing modulates the size. Lua's density is also whole steps of 1-100 times master density (`lib/params_setup.lua:1041-1051`). Doing it in the graph costs one control and a division (est.); `Impulse.ar(overlap / size)` then meets the 4 ms trigger rule at 250 a second.
10. **The pan wander's Balance2 takes 3 dB off at its center.** Even at depth 0, `Balance2.ar` at position 0 multiplies both channels by `mSine[1024]` = sin(π/4) = 0.707 (`server/plugins/PanUGens.cpp`, `Balance2_next_ak`). A depth param at 0 keeps that cut; dropping the Balance2 makes every voice 3 dB louder. Lua never sends `panSpread`, so every grain synth plays the def default 0.5. The 3.2 and 3.3 check-only copies repeat it.

## 1. Voices that grain each other

### 1.1 Today: who writes and who reads each ring

| Ring | Written by | Holds | Read by |
|---|---|---|---|
| voice ring `i` (4 s, `\voiceL/R`) | `ringWrite<i>`, a `\strataRingWrite` of `granBuses[i]` at the tail of `voiceGroup` (`StrataRings.sc:120-132`; def `:108-115`) | Source 0: the voice synth and its voice-synth notes, which write `granBuses[i]` from the head of `voiceGroup` (`StrataNotes.sc:253`ff, orig.). Sources 1-9: silence, since nothing in `voiceGroup` writes the bus and `In.ar` reads a bus not yet written this cycle as zeros. The stage's mirror lands later, in `processGroup` (`StrataMix.sc:170`; `rings.md:38`). A voice synth released by a switch to a slot or the input still writes for its release (`StrataLifecycle.sc:336-340`). | The voice's own synth-source `\strataGrainRing` at history 0 (`grainReadPairs`, `StrataFreeze.sc:460`ff, orig.), and a frozen synth voice's stream notes (`noteKindFor`, `StrataNotes.sc:153-158`, orig.) |
| input ring (`historySeconds` + 5 s) | `ringWriteInput`, of `inputBus` (`\strataInput`: `SoundIn.ar([0, 1])`, `StrataBuffers.sc:59-66`) | the stereo input | input voices (source 9) and their input notes, at the voice's history |
| copy ring `i` (4 s) | the freeze area alone: `/b_gen copy` of the input span (`copyInputSpan`, `StrataFreeze.sc:405-424`, orig.), and on high a spectral copy writer of `inputBus` (`startCopyWriter`, `:336`) | an input freeze's 4 s | only voice `i`'s input grain synths (`readsInputCopy`) |

Every reader is a `\strataGrainRing` built by `ringGrainReader` (`StrataGrainDefs.sc:298-325`, orig.). It reads the head from the ring's phase bus with `In.kr` and starts each grain the lookback D plus one block behind it (`:305-315`).

- **`ringReaders`** (`StrataRings.sc:52`) maps each `\strataGrainRing` to the voice it plays for. It is set in `startGrainSynth` (`StrataLifecycle.sc:83-85`) and cleared in `forgetGrainReader` (`:249-253`). No engine code reads it; only the checks do (`test/engine_check/freeze.scd:419`, `notes.scd:511`, `lifecycle.scd:277`). It records which voice reads, not which ring, so a "readers of ring j" question has no answer in it today.
- **`grainReadPairs`** (`StrataFreeze.sc:460-474`, orig.) is the one answer to what a ring grain synth reads. For source 0 it gives the voice ring at history 0. For source 9 it gives the input ring at the voice's history, or the copy ring at history 0 once an input freeze's copy is in. For a slot it gives `[]`. `returnToInputRing` (`:489`) alone sends pairs of its own.
- **`setGrainSource`** (`StrataVoices.sc:176-183`) takes 0-9 (`validSource`, `StrataUtil.sc:28-30`; `inputSource` is `numBuffers + 1`, `:26`) and ignores the source the voice already has. A stopped voice only records the new source. A running one gets `replaceGrainSynth` → `switchGrainSynth` (`StrataLifecycle.sc:314`ff). That unfreezes, bumps `ringChanges[voice]`, cuts what was fading, starts the new grain synth placed by source (the synth source's at the head of `processGroup`, any other at the head of the voice's mix group, `:118-121`), releases the old one, starts or releases the voice synth, and restarts the extra notes. The def comes from `grainDefs`: slots get `\strataGrainBuf`, and everything else falls through to `\strataGrainRing` (`StrataGrainDefs.sc:31-34`). A new source value therefore gets the ring def with no change there.

### 1.2 What "voice i's grains read voice j" needs: two rings it could read

| | (a) j's existing voice ring | (b) j's output ring (new) |
|---|---|---|
| what it holds | j's raw voice synth (and voice-synth notes), only while j is on source 0 | j's tap: everything j sounds dry, after its grains, filter, level, step gate and mute (`StrataMix.sc:167`, `:171`) |
| new nodes | none | one writer per voice, persistent, in the record area's tap group after the master (`StrataRecord.sc:184`); prototype `\strataOutRingWrite`: **5.06 KB** (4.21 KB without its `clip2`) |
| new RAM | none | 7 × 2 × 4 s × 4 B at 48 kHz = 10.8 MB (est.), which `highMemoryBytes` (`StrataPerformance.sc:248-252`) must count, or the high step-down misjudges |
| node order and latency | writer before the reader, as today: one block plus D behind the head | writer after every stage, reader in `processGroup`: the reader's `In.kr` sees the previous block's head, so two blocks plus D (2.7 ms + D at 48 kHz, from `ringGrainReader`'s arithmetic, est.) |
| does j have to run | yes, and on its synth source. A stopped j gives its release tail, then silence | j's stage is persistent (`mix.md:3`), so the ring always runs. It is silent while j is stopped, gated closed or muted, and readers then grain silence |
| chains | one hop (a reader has no voice synth, so its own ring is silent) | any length |
| loops | impossible: A reading B needs B on source 0, and B reading A takes B off it | possible (A↔B, A→A): section 1.5 |

The tap is gated and muted (`voiceGate` multiplies `sig`). The mirror is not gated, but it carries only the other path, so a synth voice's mirror is silent. An ungated whole-output bus would be a new `Out` in the stage, about 0.75 KB (est.), and the stage has 0.71 KB left of its 42 (quoted, `docs/notes/engine/memory.md:10`).

A third way, a voice writer that records the mirror through `InFeedback`, would put a buffer or input voice's processed output into its own voice ring a block late. That breaks the rule that a synth-source grain synth never re-grains a fading buffer or input voice's sound: for about its lookback after a switch back to the synth, the new grain synth would replay the old mirror (`rings.md:38`, the #494/#495 checks in `docs/notes/engine/freeze.md:81`).

### 1.3 Source values, and what the reading voice is

- **Values the code allows.** Engine sources 10-16 (`inputSource + 1 + j`) for "voice j's ring" fall through `grainDefs` to `\strataGrainRing` and through `voicePathBus` to the other path (`StrataMix.sc:46-48`). They place the grain synth in the voice's mix group and get `rateLevel 1` from `startGrainSynth`'s default branch (`StrataLifecycle.sc:72-78`). The prototype needed `validSource`, `ringBuffersFor`, `grainReadPairs`, `noteKindFor` and `perNoteGrainControls`, about 10 lines (Appendix). One value per other voice gives 6; letting `i == j` read its own output gives 7. A single "voice ring" source plus a separate "which voice" control is the other shape. It needs a handler that resends the read pairs, as `history` does (`StrataGrainDefs.sc:52-56`, orig.). Lua's `SOURCE_OPTIONS` (`lib/constants.lua:70-74`) grows. `voice_uses_synth` and `voice_uses_buffer` (`lib/voices.lua:235-242`) put the new sources in the "neither" bucket, which AGENTS.md says is input: every `not voice_uses_synth` style test would need a look.
- **The reading voice** is a voice with no voice synth, like an input voice. `gateVoice` starts a voice synth only for source 0 (`StrataLifecycle.sc:159`), and `switchGrainSynth` releases it (`:333-340`). Its grain synth writes the other path, takes the voice's pan, bend and frequency crossmod (`rateLevel 1`), and the stage mirrors it to `granBuses[i]`, so it still modulates other voices. Its own voice ring records silence.
- **Its extra notes** are ring-grain notes: kind `\input` in the prototype, with `pitchShift` as their pitch (`StrataNotes.sc:153-171`, orig.).

### 1.4 Freeze, source switches and stops

- **Freezing the reader i.** Today a synth voice's freeze pauses or replaces its *own* writer; an input voice's freeze copies into its own copy ring (`freezeVoice`, `StrataFreeze.sc:189-216`, orig.). A voice-ring source cannot pause j's writer, which would freeze j for all of j's readers. The input path generalizes instead: copy the 4 s behind i's read point of j's ring into i's copy ring (`copyInputToCopyRing` with j's ring and j's phase bus in place of the input's, `:367`ff), with the same fade-before-overwrite and `ringChanges` guard. On high, spectral freeze is a spectral copy writer of j's tap into i's copy ring, placed in the tap group (the prototype's `startOutCopyWriter`). That is the same ~80 KB node an input voice runs, and the high runs measured seven of them.
- **Freezing the read voice j.** Under (a), j's hold pauses the ring that i reads. i's grains then read behind a head that no longer moves without i's freeze offset: `ringScanOffset` takes the reader's own `freeze` flag (`StrataFreeze.sc:146-150`, orig.), so a grain longer than D runs across the seam into the oldest audio. i would have to be told (its `freeze` set, or a copy made), or j's hold would have to copy rather than pause. j's spectral freeze keeps its ring moving, so it is harmless to readers. Under (b), j's freeze changes nothing for readers: its frozen sound is still written to its output ring.
- **A switch or stop of j.** Rings only ever append (`rings.md:6`), so readers need no message. Under (a) they hear j's voice synth fade, over its release on a stop or over `grainRelease` (2 s) on a switch away from the synth, then silence. Under (b) they hear j's tap fade. No reader is invalidated, and `ringChanges[j]` guards only j's own copy. A reader's pending copy of j's ring would be guarded by `ringChanges[i]`, as today.

### 1.5 Loops (option (b) only)

- **Gain.** One `\strataGrainRing` on a noise ring, rms out over rms in, both channels, `panSpread` 0, pan 0. Measured on 3.14.1 (R3; R2 on 3.14.1 and 3.13 agree within 0.4 dB):

| size, density, spread | gain |
|---|---|
| 0.1 s, 20/s, 0.5 (the Lua defaults, `lib/voices.lua:33-36`) | −6.1 dB (0.50) |
| 0.1 s, 20/s, 0 | −3.0 dB (0.71) |
| 0.05 s, 10/s, 0.5 | −11.8 dB |
| 0.5 s, 20/s, 0.5 | +0.8 dB |
| 0.5 s, 200/s, 0.5 | +10.9 dB (3.5) |
| 0.5 s, 200/s, 0 | +31.0 dB (35.3) |

  With no spread at rate 1, every grain starts the same D behind the head and reads the same samples, so the grains add coherently: overlap × 0.5 (the Hann's mean) × 0.707 (Balance2): 100 × 0.5 × 0.707 = 35.4. With spread the reads decorrelate and the gain falls toward √(overlap × 0.375) × 0.707 (est.). The stage then multiplies by `voiceLevel`, `amp × (1 + crossmod) × (1 + accent)`, clipped to 0-2 (`amp` is 0-1, default 0.25-0.3, `lib/params_setup.lua:1200`, `lib/voices.lua:25`). The voice filter is unity in its passband. So the loop's gain is the product of each voice's grain gain and level: about 0.02 at the defaults (decays at once), up to about 70 a voice at the extreme.
- **What bounds it.** Nothing short of inf. `zeroBadValues` in the writer and the stage (`StrataRings.sc:110`; `mix.md:8`) zeroes NaN, inf and denormals only. On a NaN or inf from a bank, the stage is replaced in place (`replaceBadVoiceMix`, at most one in flight), and a loop would keep tripping it. The master's limiter is after the loop (`docs/notes/engine/effects.md`). The prototype writer clips at full scale (`clip2(1)`, 0.85 KB), which turns a runaway into a loop that saturates at full scale. That bounds the level but not the sound. A feedback amount or a level-normalized grain output (the overlap from item 6 of section 0) are the other places a bound could go.
- **Delayed feedback: yes.** No grain reads ahead of its head (`rings.md:8`), so every pass is delayed by at least `ringReadMargin` (5 ms) plus two blocks plus history, spread and `max(r − 1, 0) × dur`. The loop is a delay network whose delay changes from grain to grain, never an instant loop. It passes through both voices' filters each time. A self-read (A reads A's output ring) is the same with one voice.

### 1.6 Memory: every voice reading another voice's ring

The voice-ring cases: V1 is the spaced case (synth -> buffer -> ring -> synth, restarted) with another voice's ring where the input was. V2 is every voice switched between three other voices' rings 0.2 s apart (21 `\strataGrainRing`). V3 is synth -> ring -> synth (a cutting set of 14). V4 is V2 with sixteen ring notes live and cutting (53 `\strataGrainRing`). V5 is V3 with sixteen voice-synth notes, Karplus's seven first. All of them run with six LFOs, scatter and sixteen envelope routes, and on high with spectral freeze engaged (seven spectral copy writers in V2 and V4, counted). KB free, memory area alone:

| Case | R0 3.14.1 (`main`) | R3 3.14.1 (today's defs + 7 output writers) | R2 3.14.1 (fit set, 6 dest.) | R2 3.13 | floor |
|---|---|---|---|---|---|
| idle, standard | 6580 | 6550 | 6550 | 6550 | |
| std spaced (input) / V1 (ring) | 4650 / – | 4620 / 4618 | 4500 / 4500 | 4500 / 4500 | 3072 |
| std synth -> buffer -> synth / V3 | 4480 / – | 4450 / 4567 | 4310 / 4432 | 4310 / 4449 | 3072 |
| std all-buffer / V2 all-ring | 4600 / – | 4570 / 4955 | 4430 / 4820 | 4430 / 4820 | 3072 |
| std pool full, all-buffer / V4 all-ring | 1970 / – | 1900 / 2893 | 1580 / 2590 | 1600 / 2590 | 1280 |
| std pool full, s->b->s / V5 | 2420 / – | 2370 / 2809 | 2150 / 2573 | 2150 / 2590 | 1280 |
| high spaced / V1 | 4000 / – | 3970 / 3967 | 3830 / 3832 | 3830 / 3832 | 3584 |
| high synth -> buffer -> synth / V3 | 3820 / – | 3760 / 3899 | 3710* / 3765 | 3710* / 3765 | 3584 |
| high all-buffer / V2 | 4490 / – | 4440 / 4253 | 4320 / 4118 | 4320 / 4135 | 3584 |
| high pool full, all-buffer / V4 | 1850 / – | 1800 / 2202 | 1480 / 1882 | 1480 / 1899 | 1280 |
| high pool full, s->b->s / V5 | 1750 / – | 1700 / 2135 | 1480 / 1916 | 1480 / 1916 | 1280 |

\* The probes' 64 KB reserve and one spectral writer's late allocation printed `alloc failed`, so this figure is not to be trusted: the case is at its floor.

**What is new against a voice reading its own ring.** Per reader, nothing: the reader is the same def as an input voice's. V1 equals the input case within 2 KB on both tiers. On standard every voice-ring case leaves more than the case it mirrors, since a ring reader is lighter than a `\strataGrainBuf` and a reading voice has no voice synth. On high, V2 leaves less than all-buffer (4253 against 4440 in R3): its seven readers each run a spectral copy writer, which a slot voice never does, and an all-input case would cost the same. V2 stays 669 KB above the floor. The only memory the feature adds in every case is option (b)'s seven writers: 30-70 KB in each case from R0 to R3 (7 × 5.06 = 35 KB). Option (a) adds nothing. No voice-ring case is tighter than the existing tightest, high synth -> buffer -> synth.

## 2. An input channel per voice

- **Today.** `\strataInput` writes `SoundIn.ar([0, 1])` to the stereo `inputBus` (`StrataBuffers.sc:59-66`). One writer records it into the input ring pair (`StrataRings.sc:87-88`, `:120-132`). Every input voice's `\strataGrainRing` gets `bufL` = the left ring and `bufR` = the right ring (`grainReadPairs`). The left `GrainBuf` reads `bufL` panned −1 and the right one reads `bufR` panned +1, with the same trigger, rate, position and length (`StrataGrainDefs.sc:253-256`, orig.).
- **As the read pair (no UGen).** Left is `[\bufL, inputL, \bufR, inputL]` and right is `[\bufL, inputR, \bufR, inputR]`. The two `GrainBuf`s then play identical grains, so L = R: a mono source at the center, at the same level per channel as today, with the wander and pan after it. `GrainBuf` latches a grain's buffer at its start (`grain->bufnum`, `GrainUGens.cpp`), so a change reaches only new grains, with no click. The change sits in `grainReadPairs` (the start, the re-gate and `pointAtCopyRing` all send it) and in `returnToInputRing`, which sends its own pairs (`StrataFreeze.sc:489-499`, orig.). It also needs a grain-param handler that keeps the choice and resends the pairs to the own synth and the input notes (`setGrainSynths`), as `history`'s does (`StrataGrainDefs.sc:52-56`, orig.). Notes started later get it through `grainControlPairs`.
- **As a control.** `inputChannel` with two `Select.kr`s on the def's buffers measured **0.84 KB** in either def (4 UGens; 3.14.1 and 3.13). It would also give a buffer voice a mono channel.
- **"Both summed" is not free.** L+R as mono needs a summed ring (a second writer and 4 s × 2 of RAM, or a mono ring) or two more `GrainBuf`s (13.6 KB each, quoted from `memory.md:20`).
- **The input freeze.** The copy takes both channels into the copy ring (`StrataFreeze.sc:420-421`, orig.), so the read-pair choice applies to the copy unchanged (copy L twice). The spectral copy writer runs two FFT chains whatever the choice. A mono writer would save about half its ~80 KB (est.), but the copy ring would then hold one channel, and a channel change while frozen would need a new copy.
- **History** is per voice already, so two input voices can read the same channel at different histories.

## 3. A continuous grain window

- **Today.** `GRAIN_ENV_OPTIONS = {"hann", "sine", "perc", "linen", "trap"}` (`lib/constants.lua:58`) is an option param, sent as `envShape` index − 1 straight from its action while the voice is active (`lib/params_setup.lua:1098`) and at a sync (`lib/engine_sync.lua:729`). It is not a control param, so no LFO, macro or routing can reach it. The handler (`StrataGrainDefs.sc:39-46`, orig.) turns it through `envBufnumFor` (`StrataVoices.sc:266-270`) into `envBuf`: −1 is `GrainBuf`'s built-in Hann, and 1-4 are `envBuffers`. Those are four 1024-frame mono `Buffer.loadCollection`s of `Env.sine`, `Env.perc(0.1, 0.9)`, `Env.linen(0.1, 0.8, 0.1)` and a trapezoid: 16 KB of RAM (`StrataGrainDefs.sc:62-71`, orig.). `envBuf` is engine-owned (`StrataVoices.sc:315-318`).
- **The latch.** `GrainBuf_next_start_new` reads the envelope input at the grain's start into `grain->winType`. Each later block reads `mSndBufs[(int)winType]`'s data live (`GET_GRAIN_AMP_PARAMS` → `GET_GRAIN_WIN_RELAXED`), interpolating linearly at `windowSamples / counter` per sample (`GrainUGens.cpp`, develop; the same code is assumed for 3.13.0, see Unsure). A number out of range prints "Envelope buffer out of range!" and the grain is dropped. The number is truncated to an integer. So a pick per grain is safe, and rewriting a table in use is not.
- **The bank.** Measured: 16 shapes × 8 skews = 128 tables of 1024 frames, 512 KB of RAM, built in 2-3 ms on both versions. `Buffer.allocConsecutive` gave bufnums 59-186 in one block, so the pick is `base + shape × skews + skew`. The engine then held 201 buffers, the highest bufnum 200 (standard tier), of SuperCollider's default `numBuffers` 1024, which norns' `Crone.sc` does not change. The high tier adds 14 FFT buffers (`StrataFreeze.sc:65`). Sizes that are practical: 32 × 16 = 512 tables is 2 MB and fits under 1024 buffers (est. ~585 in all). 32 × 32 does not fit. Tables of 256-512 frames would be smooth enough for linear interpolation (est.).
- **No per-sample sclang loop.** `Signal` has primitive arithmetic, `pow`, `integral`, `hanWindow`, `fill` and `normalize` (`SCClassLibrary/Common/Math/Signal.sc:49`ff, `:117`, the op list). The prototype builds x = `(Signal.newClear(n).fill(1).integral − 1) / (n − 1)`, then `x.pow(log 0.5 / log peak).hanWindow.pow(sharpness)` (peak 0.05-0.95, sharpness 0.25-4). Today's `Env.asSignal` is itself a per-sample sclang loop (`Env.sc:230-235`: `length.do { signal.add(chan.envAt(...)) }`), run four times at alloc. The structure test that enforces the rule looks only at `StrataFiles.sc` (AGENTS.md).
- **Two controls mean a 2D bank.** One pick per grain from two controls is a table per pair. The alternatives are a 1D bank with the skew at Lua rate, which would rewrite tables in use (item 8 of section 0), or crossfading two `GrainBuf`s, which doubles the grain tables (13.6 KB each).
- **Old scenes.** The five shapes have to be points of the bank or map onto it. Hann is `GrainBuf`'s internal window (−1), not a table, so a table Hann differs by its linear interpolation (est. tiny). The prototype keeps `windowShape` −1 meaning "use `envBuf`", which plays today's graph exactly.
- **The pick's cost:** 2.5 KB a def (10 UGens: clips, scaling, rounds, the sum and a `Select.kr`), on 3.14.1 and 3.13.
- **Moving it.** (i) A sixth fast destination: `NUM_FAST_DESTINATIONS` 5 → 6 (`lib/constants.lua:335`; the engine's `numFastDestinations`, `StrataModulation.sc:18`, which a docs test compares) gives 42 channels in `fastModBus`, not 35. Scatter rises to 50.6 KB (limit 45) and the offset node to 13.5 KB (limit 13.5); the LFO and envelope nodes are unchanged. The buffer def gains one probe step for reading six channels. `setScatter`'s destinations mask goes to 0-63, `setFastLfo`, `setFastEnv` and `setFastOffset` take destinations 0-5, `fastModHalfRanges` and its docs test grow, and so does Lua's `FAST_DESTINATIONS` (`lib/lfos.lua:57`). The worst cases with it are R2 above. (ii) A Lua-rate control param: `windowShape` through `setGrainParam`, moved by a Lua LFO at up to 10 Hz, a macro or a routing. The pick still happens per grain, so it needs no new channel and no node.

## 4. Grain probability

- **Where.** On the trigger, after the `Trig1` that holds it for `grainTriggerSeconds` (`StrataGrainDefs.sc:242`, orig.): `trig = trig × (TRand.ar(0, 1, trig) < grainProb)`. `TRand` draws on the held trigger's rising edge and outputs the draw in the same sample, so the gate is the same pulse or nothing. At `grainProb` 1 the draw (0-1, never 1) always passes: today's graph. **0.84 KB** a def (3 UGens), both versions.
- **The 4 ms rule** holds with no change: a dropped grain still holds the `Trig1` window, so there are never more grains than today. Gating before the `Trig1` would also hold the rule (est.).
- **Triggered mode** (one grain per `retrigger`): a dropped grain is a silent hit, while the stage's accent and step gate still open (`retrigger` sends `t_trig` to the stage, `mix.md:34`). Applying it only in continuous mode is one `Select` (est. 0.25 KB).
- **The draws downstream** (rate, pan, size, interval, position spread) latch on the gated trigger, so a dropped grain draws nothing. An arpeggiator counter on the gated trigger counts only sounding grains; on the ungated one it would skip steps. The slot scan's phase runs on its own `Phasor`, not on triggers, so probability never moves it (`slotScanPhase`).

## 5. A grain arpeggiator

- **Today's interval** (`StrataVariation.sc:36-51`, orig.): `pick = TIRand.ar(1, count, trig) × (TRand < intervalProb)`, then `Select.kr(pick, [0, interval1..8])` (`:44-45`). The interval and the pitch jitter add in semitones, and quantize (`quantizedOffset`, `Select.ar`, `:47-48`) snaps the sum before bend. Lua sends `interval1..8` and `intervalCount` from a set (`lib/variation.lua:150-156`; the sets at `:20-27`, ascending, while custom keeps the player's order).
- **The lag of one grain.** `Select.kr` reads its audio-rate `pick` at the start of each block, so a grain gets the pick of the last trigger before its block (quoted, `docs/notes/engine/variation.md:3`). The 4 ms rule allows at most one trigger per 1.33 ms block, so an ordered sequence plays in order, one grain late. A reset (a note start) lands one grain late too. `Select.ar` over eight `K2A`s would remove the lag, at about 2 KB more (est.).
- **The counter.** `PulseCount.ar(trig, t_arpReset) − 1` gives up = `n mod c + 1`, down = `c − n mod c` and up-and-down = `c − |n mod (2c − 2) − (c − 1)|`. Shuffled is `Dseq([Dshuf((1..8), 1)], inf)` on `Demand.ar(trig, ...)`. `Dshuf` reshuffles each time `Dseq` resets it (`DemandUGens.cpp`, `Dshuf_next` with `inNumSamples` 0 → `Dshuf_scramble`) and allocates its 8 indices from the pool. A list of fixed length folded onto `count` is no true shuffle for `count` < 8. Measured per def, both versions:

| arpeggiator | ring def | buffer def | UGens |
|---|---|---|---|
| four orders in the graph (up, down, up and down, shuffle) | +6.74 KB | +6.74 KB | +30 |
| three orders, no shuffle | +5.06 | +5.05 | +24 |
| a bare counter (`interval1..count` in turn; Lua writes the list in the order wanted, and resends a shuffle) | +1.68 | +2.52 | +9 |

  With the bare counter Lua owns the order. Up and down are the set sorted, up-and-down is the sorted list there and back, which fits `interval1..8` for a set of up to 5 (2c − 2 ≤ 8). A shuffle is resent now and then.
- **Through a held chord.** 3.5's notes are a synth each (`StrataNotes.sc:253`ff), and each grain synth has its own `Impulse`, started at its own time, so separate note synths share no grain clock. What the engine can do: one grain synth (the own note's) steps through the chord as intervals. Lua writes the held notes, less the own note, into `interval1..8`: eight values, the same as `NOTE_SLOTS`. Extra notes then make no synths of their own (or are parked). On a synth voice that transposes the voice synth's ring by the grain rate, which shifts its formants (3.2's accepted sound) and is not a chord of voice synths. A ring rate is clipped to ±4 (`ringMaxRate`), so a wide chord at a high `pitchShift` clips. On a buffer voice the intervals multiply `pitchShift`, while `bufRate`, each note's own pitch, stays the own note's. What the engine could not do without a new bus: several note synths taking turns grain by grain. That would need a trigger bus per voice written by the own synth and read by the notes (one block late, a counter and a compare each, est. ~1 KB a synth plus an audio bus a voice), and node order inside the mix group varies (all added at the head).

## 6. Constant overlap

- **What reaches a grain synth.** `grainSize` comes from Lua's `grain_size` (0.01-0.5 s, linear, step 0.01) and `grainDensity` is `grain_density` (1-100, step 1) × `master_density` (0.1-2) (`lib/params_setup.lua:305-313`, `:1024-1052`). So the engine gets 0.1-200 grains a second.
- **In the graph.** `fastMod` sets the size to `grainSize + 0.245 (m2 + noteSize)`, clipped to 0.01-0.5 (`docs/notes/engine/modulation.md:47`). `grainDur` multiplies by `2^(u × sizeJitter)` and `grainBody` caps it at 0.5 s (`StrataGrainDefs.sc:249`, orig.). A slot grain is also capped at its valid region, and a triggered ring grain above rate 2 is shortened (`rings.md:52`). The density is `Impulse.ar(grainDensity)` in continuous mode only (`:242`).
- **The bounds.** No two grains within 4 ms, so at most 250 a second. `maxGrains` 128 a `GrainBuf` (`StrataPerformance.sc:25`) and Lua's largest overlap of 100 (0.5 × 100 × 2; `memory.md:20`). At size 0.01 an overlap of O needs 100·O grains a second, so the 4 ms rule caps O at 2.5 there. At size 0.5, O ≤ 125.
- **What Lua would couple.** The two base values. Fast modulation of the size (an engine LFO, scatter, an envelope, `noteSize`, size jitter) is invisible to Lua, so the overlap drifts with it. Density's whole steps make small densities coarse. An engine-side coupling would compute `Impulse.ar(overlap / modulatedSize)` inside `grainSignal` from the modulated size (est. 2-3 UGens, about 0.75 KB), in continuous mode only.

## 7. The pan wander

- **Where:** `grainSignal`, `sig = Balance2.ar(sig[0], sig[1], LFNoise1.kr(2).range(panSpread.neg, panSpread))`, then `panBalance` for `pan` (`StrataGrainDefs.sc:258-259`, orig.). Both defs share it, with `panSpread=0.5` in both literal `arg` lists (`:109`, `:152`, orig.). Each grain synth (the own and each extra note) wanders on its own `LFNoise1`.
- **Who sends it.** No Lua code sends `panSpread` (a search of `lib/` finds it only in the engine), so it is always 0.5. It is not refused (`engineOwnedControls`, `StrataVoices.sc:314-318`), so `setGrainParam(voice, "panSpread", x)` already stores it in `grainControls` and reaches the own synth and the voice's notes (`setGrainSynths`) with no engine change. A Lua param needs only a sender.
- **The level.** `Balance2` multiplies by `mSine[2048 − ipos]` and `mSine[ipos]` with `ipos = 1024 × pos + 1024`, so at position 0 both channels are ×0.707 (−3 dB), and at ±0.5 one is ×0.38 and the other ×0.92 (`PanUGens.cpp`, `Balance2_next_ak`). A position past ±1 is clipped. So depth 0 means "no wander, −3 dB", and a depth of 0-1 covers the UGen's range.
- **Check-only copies that repeat it:** 3.2's `grainSignal` in `test/engine_check.scd:197`, 3.3's in `test/engine_check/modulation.scd:123`, and the mix area's check controls default it to 0.5 (`test/engine_check/mix.scd:50`). The mix and modulation checks compare the real defs with these to 1e-6, at `panSpread` 0 (`mix.scd:18`). Changing the `Balance2` (to take away the 3 dB, say) means changing the copies or the checks too, and it makes every old scene 3 dB louder.

## 8. The budget together

Each def's pool cost by allocation probes (twenty synths each, steps of 0.84 KB), identical on 3.14.1 (R1, R3) and 3.13.0 (R2) unless noted, five fast destinations:

| Variant | `\strataGrainRing` KB (UGens) | `\strataGrainBuf` KB (UGens) |
|---|---|---|
| today (R0), and "none" (the new controls declared and unused) | 64.04 (157) | 82.58 (247) |
| + window pick | 66.57 (+2.53; 167) | 85.10 (+2.52; 257) |
| + probability | 64.88 (+0.84; 160) | 83.42 (+0.84; 250) |
| + arpeggiator, four orders | 70.78 (+6.74; 187) | 89.32 (+6.74; 277) |
| + arpeggiator, three orders | 69.10 (+5.06; 181) | 87.63 (+5.05; 271) |
| + arpeggiator, bare counter | 65.72 (+1.68; 166) | 85.10 (+2.52; 256) |
| + channel as a control (0 as read pairs) | 64.88 (+0.84; 161) | 83.42 (+0.84; 251) |
| all four (four orders) | **74.15** (204) | **93.53** (294): over 88 |
| window + probability + bare counter + channel control ("fit") | 69.94 (183) | **88.48** (273): at 88 |
| "fit" with the channel as read pairs (est.) | ~69.1 | ~87.6 |
| with a sixth fast destination (R2): none / window / fit / all | 64.04 / 66.57 / 69.94 / 74.99 | 83.42 / 85.10 / 88.48 / 93.53 |

The limit is 88 KB (`memory.md:10`). The other nodes: `\strataRingWrite` 4.21 KB, `\strataOutRingWrite` 5.06 KB, the stage 41.29 KB (unchanged), scatter 42.1 → 50.6 KB and the offset node 11.8 → 13.5 KB with six destinations. Today's figures were read again on 3.14.1: `\strataGrainRing` 64.0 KB, one probe step above `docs/status.md`'s 63.2.

Worst cases (KB free, the memory area alone, 3.14.1; R2 also on 3.13.0, where every figure is the same within 20 KB):

| Case | R0 `main` | R1 all four + 7 writers | R2 fit + 6 dest. + 7 writers | floor |
|---|---|---|---|---|
| std spaced | 4650 | 4420 | 4500 | 3072 |
| std synth -> buffer -> synth | 4480 | 4230 | 4310 | 3072 |
| std all-buffer | 4600 | 4350 | 4430 | 3072 |
| std pool full, all-buffer | 1970 | 1430 | 1580 (3.13: 1600) | 1280 |
| std pool full, s->b->s | 2420 | 1980 | 2150 | 1280 |
| eight recordings, std / high | 4470 / 3810 | 4230 / 3560 | 4310 / 3640 | 3072 |
| high spaced | 4000 | 3750 | 3830 | 3584 |
| high synth -> buffer -> synth | 3820 | 3710*, `alloc failed`, `/c_getn` out of memory | 3710*, `alloc failed` | 3584 |
| high all-buffer | 4490 | 4240 | 4320 | 3584 |
| high pool full, all-buffer | 1850 | **1510, FAIL** | 1480 | 1280 |
| high pool full, s->b->s | 1750 | 1410 | 1480 | 1280 |

\* As printed; the reserve and the spectral writers' late allocations failed, so the case sits at its floor (item 5 of section 0).

A rough sum for the tightest case (est.): high synth -> buffer -> synth has 14 `\strataGrainRing` and 7 `\strataGrainBuf`. Each KB added to both defs costs about 21 KB there; the case has 236 KB above its floor and about 124 once the late allocations are counted (quoted, `docs/status.md`). That leaves room for roughly 5-6 KB a def with nothing else added, before shimmer, voice types and the other 3.8 nodes take their share.

## Where the roadmap or the notes are wrong or silent

- `ROADMAP.md`, "Voices that grain each other": "Every voice already writes a ring" is true, but for a buffer or input voice the ring is silent, and for a synth voice it holds the raw synth, not the voice's sound (`StrataRings.sc:120-132`; `rings.md:38`). "Read another voice's live sound" needs a new ring per voice (1.2). Nor do "the work is in the engine's ring readers" and "the rule that a ring is written only by its own writer" capture it: the rule survives, and the work is a second writer per voice.
- `ROADMAP.md`, same section: "The design measures the memory of a second reader per ring first": a second reader takes no pool memory of its own (1.6). The cost is the writer and the RAM.
- `ROADMAP.md`, same section, is silent on the loop's gain. Nothing in the engine bounds it short of inf (1.5).
- `ROADMAP.md`, "A deeper grain": "one more per-grain draw ... like 3.2's variation draws" is right for probability (0.84 KB). But "four additions to the grain" do not fit `\strataGrainBuf`'s 88 KB together (section 8), and the roadmap is silent on the per-def limit.
- `ROADMAP.md`: "Constant overlap ... Lua couples two params the engine already has." That holds only while the size has no engine-side modulation (6).
- `ROADMAP.md`: "a finer bank of envelope buffers ... the design sizes the bank against the buffer memory". The bank's RAM is trivial (512 KB). Its real limits are the server's 1024 buffers and the rule that a table is never rewritten while grains use it (3).
- `ROADMAP.md`, "An input channel per voice": "a control on the grain synth's read". It can be no control at all: a read pair (2).
- `ROADMAP.md`, "The pan wander": "defaulting to today's width" is silent on the `Balance2`'s −3 dB at the center, which stays at depth 0 (7).
- `docs/notes/engine/variation.md:4` says "about a quarter of a KB each" UGen. The measured steps here are 0.84 KB per 3-4 UGens (0.21-0.28 KB each), and 2.5 KB for the 10 of the window pick: consistent. `memory.md:161`'s 0.23 KB a UGen holds.
- `docs/notes/engine/memory.md:6` says the reserve probes keep "the server from ever running with a full pool". With the prototype on high they failed themselves (`DelayN_Ctor: alloc failed`), and the run reported a figure about 130 KB too high. A case near its floor reads optimistic unless its log is read for `alloc failed`.
- `AGENTS.md` ("No per-sample sclang loop in engine code ... enforced in `StrataFiles.sc`"): `allocEnvelopeBuffers` (`StrataGrainDefs.sc:65-70`, orig.) calls `Env.asSignal`, a per-sample sclang loop (`Env.sc:230-235`). It is small (4 × 1024), but a bank built the same way would be 128 × 1024 iterations.
- `docs/notes/engine/rings.md:7` and the `ringReaders` comment say it holds "every `\strataGrainRing` with its voice". It records the reading voice, not the ring, and no engine code reads it (1.1). Silent on whether a reader of another voice's ring belongs there.

## Unsure

- **3.13.0's `GrainBuf` and `Balance2` source.** I quoted SuperCollider's develop branch at `~/src/supercollider`. The tag `Version-3.13.0` was not read. The behaviors that matter (the envelope buffer number latched per grain, the read-pair latch, the −3 dB center) are long-standing in both, and the gain figures, which rest on the −3 dB, measured the same on 3.13.0. The envelope latch was not measured on 3.13.
- **The voice-ring prototype is memory-only for freeze.** A reader's spectral freeze starts a spectral copy writer of the read voice's tap with no copy and no re-point. Hold makes no copy at all. The sound of a frozen reader and the copy's fade-before-overwrite were not built or checked.
- **Loop behavior** was not run: the gains are one grain synth's on noise, and a loop's growth and the stage's reset under a loop are reasoned from the code (1.5), not measured.
- **The R1/R2 high synth -> buffer -> synth figure** (3710) is not a real reading, because of the reserve's failure. I did not rerun it with fewer probes to find the true free figure; the sum in section 8 is an estimate.
- **The arpeggiator's sound** (the one-grain lag, `Dshuf`'s reshuffle under a changing `count`) was not listened to or checked on the server; only its pool cost was measured.
- **The window bank's shapes** in the prototype (a warped Hann raised to a power) are one family chosen to show the cost. Whether today's five shapes fall on such a bank was not checked.
- **A full run in one sclang** reads about a probe step lower per def (quoted, `memory.md:10`). These figures are the memory area alone, as CI's shard measures them.
- **Device.** Nothing here was run on a norns. The pool arithmetic is norns' (8192 KB, `memSize` set by the check), but CPU (seven readers and seven more writers, the bank's pick) was not measured.

## Appendix: the prototype (uncommitted, in this worktree)

Files changed: `lib/engine/StrataProto.sc` (new: the bank, the output rings and writers, voice-ring sources 10-16, the check-only variant defs), `lib/engine/StrataGrainDefs.sc` (the defs built by `addGrainDefsNamed` with flags; the probability gate, the window pick and the channel pair), `lib/engine/StrataVariation.sc` (`protoArpPick`), `lib/engine/StrataFreeze.sc`, `StrataNotes.sc`, `StrataRings.sc` and `StrataUtil.sc` (the sources 10-16), `lib/engine/StrataModulation.sc` (`numFastDestinations`, 6 in R2, 5 now), `test/engine_check/memory.scd` (the sizes, the gain and the V1-V5 cases, and a deliberate failure so the runner prints the full output). The flags as left: R3's (none). R1 had `(window: true, prob: true, arp: true, chan: true)` and R2 `(window: true, prob: true, arp: \min, chan: true)` with `numFastDestinations` 6. Logs: `/tmp/claude-1000/-home-sethbc-src-strata/7b6fc544-bdee-4477-ba59-2c1dad21aefd/scratchpad/engine-grain/` (`baseline-314.log`, `proto1-314.log`, `proto2-314.log`, `proto3b-314.log`, `313-r2/run-1.log`).

### The engine changes (the worktree diff of `lib/`)

```diff
diff --git a/lib/engine/StrataFreeze.sc b/lib/engine/StrataFreeze.sc
index c8f740ad..455b7c44 100644
--- a/lib/engine/StrataFreeze.sc
+++ b/lib/engine/StrataFreeze.sc
@@ -211,7 +211,9 @@
                 this.replaceRingWriter(voice, \strataRingWriteSpectral, granBuses[voice])
             } { this.pauseRingWriter(voice) };
         }
-        { source == this.inputSource } { this.copyInputToCopyRing(voice) };
+        { source == this.inputSource } { this.copyInputToCopyRing(voice) }
+        // SCRATCH: memory only, a spectral writer of the read voice's tap
+        { this.voiceRingSource(source) } { if (mode == \spectral) { this.startOutCopyWriter(voice, this.voiceRingOf(source)) } };
         // a slot: the grain synth's freeze control stops its scan (scanRate)
     }
 
@@ -243,7 +245,8 @@
         { source == this.inputSource } {
             this.stopCopyWriter(voice);
             this.returnToInputRing(voice);
-        };
+        }
+        { this.voiceRingSource(source) } { this.stopOutCopyWriter(voice) };
     }
 
     // The freeze param's unfreeze: what unfreezeVoice sends (the readers set
@@ -467,6 +470,8 @@
                 history = grainControls[voice][\history] ? 0;
             };
         }
+        // SCRATCH: another voice's output ring, at history 0
+        { this.voiceRingSource(source) } { ring = this.ringBuffersFor(voice, source) }
         { ^[] };
         ^[\bufL, ring[0].bufnum, \bufR, ring[1].bufnum, \phaseBus, ring[2].index, \history, history]
     }
diff --git a/lib/engine/StrataGrainDefs.sc b/lib/engine/StrataGrainDefs.sc
index 4f477833..bd135c04 100644
--- a/lib/engine/StrataGrainDefs.sc
+++ b/lib/engine/StrataGrainDefs.sc
@@ -100,11 +100,17 @@
     // \strataGrainBuf's reader takes them (slotGrainReader); the ring def
     // declares and ignores them, as it does the loop's.
     addGrainDefs {
+        this.addGrainDefsNamed(\strataGrainRing, \strataGrainBuf, this.protoFlags);
+    }
+
+    // SCRATCH (3.8 design): the two defs under any names, with the
+    // prototype's additions the flags ask for
+    addGrainDefsNamed { arg ringName, bufName, flags;
         // Granular processor for a ring: the voice's own (synth source) or
         // the input's (input source), each written by a strataRingWrite
         // (StrataRings.sc) whose frame position is on phaseBus. Grains start
         // behind the write head (ringGrainReader).
-        SynthDef(\strataGrainRing, {
+        SynthDef(ringName, {
             arg out, gate=1, bufL=0, bufR=0, phaseBus=0, bufScan=0,
             grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
             envBuf = -1, grainMode=0, t_trig=0, bend=1, kill=0, pan=0, rateLevel=1,
@@ -117,7 +123,8 @@
             intervalCount=0, intervalProb=1, quantize=0, scaleNote=60,
             loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0,
             noteGate=1, noteBend=1, noteAmp=1, notePos=0, noteSize=0, velocity=1, t_accent=0, noteRate=1,
-            scanMode=0, regionStart=0, regionLength=0, followRate=1, slotGain=1, t_scanSync=0, scanSyncPhase=0;
+            scanMode=0, regionStart=0, regionLength=0, followRate=1, slotGain=1, t_scanSync=0, scanSyncPhase=0,
+            windowShape = -1, windowSkew=0.5, grainProb=1, arpOrder=0, t_arpReset=0, inputChannel=0;
             var recHeadBus = \recHeadBus.kr(areaState[\record][\idleHead].index);
             var fastModIn = \fastModIn.kr(areaState[\modulation][\silentFastModBus].index);
             var m = this.fastModRead(fastModIn);
@@ -131,9 +138,12 @@
                 intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
                 intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote,
                 fastMod: m, noteRate: noteRate, noteSize: noteSize, noteBend: noteBend,
-                noteGate: noteGate, noteAmp: noteAmp, velocity: velocity, t_accent: t_accent
+                noteGate: noteGate, noteAmp: noteAmp, velocity: velocity, t_accent: t_accent,
+                flags: flags, windowShape: windowShape, windowSkew: windowSkew, grainProb: grainProb,
+                arpOrder: arpOrder, t_arpReset: t_arpReset
             );
-            this.grainBody(controls, this.areaCall(\ringGrainReader, bufL, bufR, phaseBus, posSpread, history, bufScan, freeze));
+            var chosen = this.protoChannelPair(bufL, bufR, inputChannel, flags);
+            this.grainBody(controls, this.areaCall(\ringGrainReader, chosen[0], chosen[1], phaseBus, posSpread, history, bufScan, freeze));
         }).add;
 
         // Granular processor for a buffer slot (bufnumL/R). bufPos (0-1) and
@@ -147,7 +157,7 @@
         // engine: b_alloc keeps a loaded file's rate, and norns' scsynth has
         // no b_setSampleRate. While the slot is empty or being recorded
         // (bufFrames 0) the output fades out (hasAudio).
-        SynthDef(\strataGrainBuf, {
+        SynthDef(bufName, {
             arg out, gate=1, bufnumL=0, bufnumR=0, bufFrames=1, bufRateScale=1, bufPos=0, bufRate=1, bufScan=0,
             grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
             envBuf = -1, grainMode=0, t_trig=0, bend=1, kill=0, pan=0, rateLevel=1,
@@ -160,7 +170,8 @@
             intervalCount=0, intervalProb=1, quantize=0, scaleNote=60,
             loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0,
             noteGate=1, noteBend=1, noteAmp=1, notePos=0, noteSize=0, velocity=1, t_accent=0,
-            scanMode=0, regionStart=0, regionLength=0, followRate=1, slotGain=1, t_scanSync=0, scanSyncPhase=0;
+            scanMode=0, regionStart=0, regionLength=0, followRate=1, slotGain=1, t_scanSync=0, scanSyncPhase=0,
+            windowShape = -1, windowSkew=0.5, grainProb=1, arpOrder=0, t_arpReset=0, inputChannel=0;
             var recHeadBus = \recHeadBus.kr(areaState[\record][\idleHead].index);
             var fastModIn = \fastModIn.kr(areaState[\modulation][\silentFastModBus].index);
             var m = this.fastModRead(fastModIn);
@@ -179,9 +190,12 @@
                 intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
                 intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote,
                 fastMod: m, noteRate: 1, noteSize: noteSize, noteBend: noteBend,
-                noteGate: noteGate, noteAmp: noteAmp, velocity: velocity, t_accent: t_accent
+                noteGate: noteGate, noteAmp: noteAmp, velocity: velocity, t_accent: t_accent,
+                flags: flags, windowShape: windowShape, windowSkew: windowSkew, grainProb: grainProb,
+                arpOrder: arpOrder, t_arpReset: t_arpReset
             );
-            this.grainBody(controls, this.areaCall(\slotGrainReader, bufnumL, bufnumR, bufFrames, bufRateScale, this.fastModPosition(bufPos, m, notePos),
+            var chosen = this.protoChannelPair(bufnumL, bufnumR, inputChannel, flags);
+            this.grainBody(controls, this.areaCall(\slotGrainReader, chosen[0], chosen[1], bufFrames, bufRateScale, this.fastModPosition(bufPos, m, notePos),
                 bufRate, bufScan, posSpread, freeze, loopStart, loopLength, scrubRate, scanHold, t_scanReset, recHeadBus, scan));
         }).add;
     }
@@ -222,7 +236,7 @@
     // Returns (sig: the stereo signal, fade: its fade).
     grainSignal { arg controls, reader;
         var c = this.fastMod(controls), env, modSigs, rateMod, bendRate, grainMode, mode, trig;
-        var vary, rate, dur, read, panOffset, left, right, sig;
+        var vary, rate, dur, read, panOffset, left, right, sig, envBuf;
 
         env = EnvGen.kr(Env.asr(0.1, 1, grainRelease), this.openedGate(c[\gate]), doneAction: 2) * this.killFade(c[\kill]);
 
@@ -240,20 +254,26 @@
         // (Trig1 holds the trigger high for grainTriggerSeconds and ignores
         // any other meanwhile: every grain input reads its rising edge)
         trig = Trig1.ar(Select.ar(mode, [Impulse.ar(c[\grainDensity]), T2A.ar(c[\t_trig])]), this.grainTriggerSeconds);
+        // SCRATCH: grain probability, a draw on the held trigger gating it
+        if (c[\flags] !? { arg f; f[\prob] == true } ? false) {
+            trig = trig * (TRand.ar(0, 1, trig) < c[\grainProb]);
+        };
 
         vary = (
             reverseProb: c[\reverseProb], pitchJitter: c[\pitchJitter], intervals: c[\intervals],
-            intervalCount: c[\intervalCount], intervalProb: c[\intervalProb], quantize: c[\quantize], scaleNote: c[\scaleNote]
+            intervalCount: c[\intervalCount], intervalProb: c[\intervalProb], quantize: c[\quantize], scaleNote: c[\scaleNote],
+            arp: c[\flags] !? { arg f; f[\arp] } ? false, arpOrder: c[\arpOrder], t_arpReset: c[\t_arpReset]
         );
         rate = this.grainRate(trig, c[\pitchShift], bendRate, vary);
         dur = this.grainDur(trig, c[\grainSize], c[\sizeJitter]).min(this.grainMaxSeconds);
         read = reader.value(trig, rate, dur, mode);
 
         panOffset = this.grainPan(trig, c[\panJitter]);
+        envBuf = this.protoWindowPick(c);
         left = GrainBuf.ar(2, trig, read[\dur], read[\bufL], read[\rate], read[\pos], 2,
-            (panOffset - 1).clip(-1, 1), c[\envBuf], maxGrains);
+            (panOffset - 1).clip(-1, 1), envBuf, maxGrains);
         right = GrainBuf.ar(2, trig, read[\dur], read[\bufR], read[\rate], read[\pos], 2,
-            (panOffset + 1).clip(-1, 1), c[\envBuf], maxGrains);
+            (panOffset + 1).clip(-1, 1), envBuf, maxGrains);
         sig = left + right;
         sig = Balance2.ar(sig[0], sig[1], LFNoise1.kr(2).range(c[\panSpread].neg, c[\panSpread]));
         sig = this.panBalance(sig, c[\pan]);
@@ -378,4 +398,28 @@
                 level: level)
         }
     }
+
+    // SCRATCH: the input channel (0 both, 1 left, 2 right) as the read
+    // pair: left reads the left buffer in both GrainBufs, right the right
+    protoChannelPair { arg bufL, bufR, inputChannel, flags;
+        var channel;
+        if ((flags !? { arg f; f[\chan] == true } ? false).not) { ^[bufL, bufR] };
+        channel = inputChannel.round.clip(0, 2);
+        ^[Select.kr(channel, [bufL, bufL, bufR]), Select.kr(channel, [bufR, bufL, bufR])]
+    }
+
+    // SCRATCH: the continuous window: windowShape (0-1, plus a sixth fast
+    // destination's offset when the engine has one) and windowSkew (0-1)
+    // pick one table of the bank (shapes x skews, consecutive bufnums);
+    // windowShape < 0 keeps envBuf (today's five shapes). GrainBuf reads
+    // its envelope buffer number once per grain (it latches it)
+    protoWindowPick { arg c;
+        var state = areaState[\proto], shapes = this.protoShapes, skews = this.protoSkews, base, shape, m = c[\fastMod];
+        if ((c[\flags] !? { arg f; f[\window] == true } ? false).not or: { state[\bank].isNil }) { ^c[\envBuf] };
+        base = state[\bank][0].bufnum;
+        shape = c[\windowShape];
+        if (m.size > 5) { shape = shape + (0.5 * m[5]) };
+        ^Select.kr(c[\windowShape] >= 0, [c[\envBuf],
+            base + ((shape.clip(0, 1) * (shapes - 1)).round * skews) + (c[\windowSkew].clip(0, 1) * (skews - 1)).round])
+    }
 }
diff --git a/lib/engine/StrataModulation.sc b/lib/engine/StrataModulation.sc
index 1db7f2ba..1c0490f1 100644
--- a/lib/engine/StrataModulation.sc
+++ b/lib/engine/StrataModulation.sc
@@ -15,7 +15,7 @@
     // Fast destinations per voice: 0 pitch, 1 position, 2 size, 3 cutoff,
     // 4 amp. Lua's S.constants.NUM_FAST_DESTINATIONS is the same number (a
     // docs test compares them)
-    numFastDestinations { ^5 }
+    numFastDestinations { ^5 }  // SCRATCH: R2 measured 6 (a sixth for the window)
 
     // Note slots per voice on fastModBus: one, the voice's (3.5 keeps it at
     // one, design 3.5 Question 1: a note's own values are its synth's
diff --git a/lib/engine/StrataNotes.sc b/lib/engine/StrataNotes.sc
index 036c11e6..617e978c 100644
--- a/lib/engine/StrataNotes.sc
+++ b/lib/engine/StrataNotes.sc
@@ -152,7 +152,7 @@
     // its buffer slot or of the input
     noteKindFor { arg voice;
         var source = grainSource[voice];
-        if (source == this.inputSource) { ^\input };
+        if ((source == this.inputSource) or: { this.voiceRingSource(source) }) { ^\input };  // SCRATCH: voice rings
         if (source.inclusivelyBetween(1, numBuffers)) { ^\buffer };
         if (this.frozenSynthVoice(voice)) { ^\stream };
         ^\voice
@@ -218,7 +218,7 @@
     perNoteGrainControls { arg voice;
         var names = [\noteGate, \noteBend, \noteAmp, \notePos, \noteSize, \noteRate, \velocity, \t_accent,
             \regionStart, \regionLength];
-        if (grainSource[voice] == this.inputSource) { ^names ++ [\pitchShift] };
+        if ((grainSource[voice] == this.inputSource) or: { this.voiceRingSource(grainSource[voice]) }) { ^names ++ [\pitchShift] };
         if (grainSource[voice].inclusivelyBetween(1, numBuffers)) { ^names ++ [\bufRate, \scaleNote] };
         ^names
     }
diff --git a/lib/engine/StrataRings.sc b/lib/engine/StrataRings.sc
index 374b26d5..e3a567b2 100644
--- a/lib/engine/StrataRings.sc
+++ b/lib/engine/StrataRings.sc
@@ -62,7 +62,9 @@
         var rings = areaState[\rings];
         case
         { source == 0 } { ^[rings[\voiceL][voice], rings[\voiceR][voice], rings[\phaseBuses][voice]] }
-        { source == this.inputSource } { ^[rings[\inputL], rings[\inputR], rings[\phaseBuses][numVoices]] };
+        { source == this.inputSource } { ^[rings[\inputL], rings[\inputR], rings[\phaseBuses][numVoices]] }
+        // SCRATCH: voice j's output ring
+        { this.voiceRingSource(source) } { ^this.outRingFor(this.voiceRingOf(source)) };
         ^nil
     }
 
diff --git a/lib/engine/StrataUtil.sc b/lib/engine/StrataUtil.sc
index da503e60..6837a755 100644
--- a/lib/engine/StrataUtil.sc
+++ b/lib/engine/StrataUtil.sc
@@ -26,7 +26,7 @@
     inputSource { ^numBuffers + 1 }
 
     validSource { arg source;
-        ^source.isInteger and: { (source >= 0) and: { source <= this.inputSource } }
+        ^source.isInteger and: { (source >= 0) and: { source <= (this.inputSource + numVoices) } }  // SCRATCH: 10-16 voice rings
     }
 
     voiceRunning { arg voice;
diff --git a/lib/engine/StrataVariation.sc b/lib/engine/StrataVariation.sc
index 155a6ed9..f26f1a67 100644
--- a/lib/engine/StrataVariation.sc
+++ b/lib/engine/StrataVariation.sc
@@ -41,7 +41,8 @@
         var count = intervalCount.round.clip(0, 8);
         var chance = vary[\intervalProb] * (count > 0);
         // 0: no interval this grain; 1..count: that interval
-        var pick = TIRand.ar(1, count.max(1), trig) * (TRand.ar(0, 1, trig) < chance);
+        var pick = this.protoArpPick(trig, count, chance, vary,
+            TIRand.ar(1, count.max(1), trig) * (TRand.ar(0, 1, trig) < chance));
         var interval = Select.kr(pick, [0] ++ vary[\intervals]);
         var offset = (TRand.ar(-1, 1, trig) * vary[\pitchJitter]) + interval;
         var semitones = Select.ar(vary[\quantize] > 0.5,
@@ -62,4 +63,31 @@
     grainDur { arg trig, grainSize, sizeJitter;
         ^grainSize * (2 ** (TRand.ar(-1, 1, trig) * sizeJitter))
     }
+
+    // SCRATCH (3.8 design): the arpeggiator, a counter on the grain
+    // trigger stepping through the first count intervals in an order:
+    // 0 random (today's draw, pick), 1 up, 2 down, 3 up and down, 4 shuffled
+    // (Dshuf, reshuffled every eight grains, folded onto count)
+    protoArpPick { arg trig, count, chance, vary, pick;
+        var order, n, c, span, up, down, upDown, orders;
+        if ((vary[\arp] ? false) == false) { ^pick };
+        n = PulseCount.ar(trig, vary[\t_arpReset]) - 1;
+        // the least: the engine steps through interval1..count in turn,
+        // and Lua writes them in the order (up, down, up and down as a
+        // list of at most 8, a shuffle resent now and then)
+        if (vary[\arp] == \min) {
+            ^Select.ar(vary[\arpOrder] > 0.5, [pick, (n.mod(count.max(1)) + 1) * (count > 0)])
+        };
+        order = vary[\arpOrder].round.clip(0, 4);
+        c = count.max(1);
+        span = ((2 * c) - 2).max(1);
+        up = n.mod(c) + 1;
+        down = c - n.mod(c);
+        upDown = c - (n.mod(span) - (c - 1)).abs;
+        orders = [up, down, upDown];
+        if (vary[\arp] != \noShuffle) {
+            orders = orders ++ [(Demand.ar(trig, vary[\t_arpReset], Dseq([Dshuf((1..8), 1)], inf)) - 1).mod(c) + 1];
+        };
+        ^Select.ar(order > 0, [pick, Select.ar(order - 1, orders) * (TRand.ar(0, 1, trig) < chance)])
+    }
 }
```

### `lib/engine/StrataProto.sc` (new)

```supercollider
// StrataProto.sc -- SCRATCH, never committed: the 3.8 design's grain-stage
// measurements (docs/design/3.8-facts/engine-grain.md). A window bank (shapes x skews of
// 1024-frame tables, allocated consecutively, built with Signal
// primitives only), each voice's output ring (4 s, the voice's tap written
// by a writer in the record area's tap group, after the master) and the
// sources 10-16 (inputSource + 1 + j: voice j's output ring). The flags
// say which additions the real grain defs carry; addProtoDefs builds
// check-only variants for the per-addition sizes.

+ Engine_Strata {
    strataAreaProto {
        ^(
            order: 200,
            allocState: { this.areaCall(\allocProto) },
            addDefs: { this.areaCall(\addProtoDefs); [] },
            start: { this.areaCall(\startProtoWriters) },
            stop: { this.areaCall(\stopProtoWriters) },
            free: { this.areaCall(\freeProto) },
            effectKeys: this.protoWriterKeys
        )
    }

    protoShapes { ^16 }
    protoSkews { ^8 }
    protoTableFrames { ^1024 }

    // voice j's output ring as a source: inputSource + 1 + j (10-16)
    voiceRingSource { arg source;
        ^source.isInteger and: { source.inclusivelyBetween(this.inputSource + 1, this.inputSource + numVoices) }
    }
    voiceRingOf { arg source; ^source - this.inputSource - 1 }

    protoWriterKeys { ^numVoices.collect({ arg voice; ("outWrite" ++ voice).asSymbol }) }
    protoOutCopyKeys { ^numVoices.collect({ arg voice; ("outCopyWrite" ++ voice).asSymbol }) }

    protoFlags { ^areaState[\proto][\flags] ? (window: true, prob: true, arp: true, chan: true) }

    allocProto {
        var state = areaState[\proto], server = context.server, frames = this.protoTableFrames;
        var count = this.protoShapes * this.protoSkews, started = Main.elapsedTime, x;
        state[\flags] = (window: false, prob: false, arp: false, chan: false);  // R1: all four; R2: window, prob, arp \min, chan; R3: none
        state[\bank] = Buffer.allocConsecutive(count, server, frames, 1);
        // x: 0..1 over the table (a running sum of ones: primitives only)
        x = (Signal.newClear(frames).fill(1.0).integral - 1.0) / (frames - 1);
        this.protoShapes.do({ arg shape;
            this.protoSkews.do({ arg skew;
                // skew: the peak at 0.05..0.95 of the grain (x warped so
                // that p maps to 0.5); shape: the Hann raised to 0.25..4
                // (broad and flat-topped to narrow)
                var peak = 0.05 + (0.9 * skew / (this.protoSkews - 1));
                var sharp = 0.25 * (16 ** (shape / (this.protoShapes - 1)));
                var table = x.pow(0.5.log / peak.log).hanWindow.pow(sharp);
                state[\bank][(shape * this.protoSkews) + skew].setn(0, table.asArray);
            });
        });
        state[\bankSeconds] = Main.elapsedTime - started;
        state[\outL] = Array.fill(numVoices, { Buffer.alloc(server, server.sampleRate * this.ringSeconds, 1) });
        state[\outR] = Array.fill(numVoices, { Buffer.alloc(server, server.sampleRate * this.ringSeconds, 1) });
        state[\outPhase] = Array.fill(numVoices, { Bus.control(server, 1) });
        state[\outPhase].do({ arg bus; bus.set(0) });
        state[\writers] = [];
    }

    // The output ring a voice-ring source reads
    outRingFor { arg ringVoice;
        var state = areaState[\proto];
        ^[state[\outL][ringVoice], state[\outR][ringVoice], state[\outPhase][ringVoice]]
    }

    addProtoDefs {
        // The output ring writer: strataRingWrite's graph on a voice's tap,
        // its input bounded at full scale (clip2) so a loop of voices
        // reading each other saturates instead of running away to inf
        SynthDef(\strataOutRingWrite, {
            arg in, bufL, bufR, phaseOut;
            var sig = In.ar(in, 2).collect({ arg channel; this.zeroBadValues(channel).clip2(1) });
            var phase = Phasor.ar(Impulse.ar(0), 1, 0, BufFrames.kr(bufL), In.kr(phaseOut));
            BufWr.ar(sig[0], bufL, phase);
            BufWr.ar(sig[1], bufR, phase);
            Out.kr(phaseOut, A2K.kr(phase));
        }).add;
        // check-only variants of the grain defs, one addition each
        [
            [\none, (window: false, prob: false, arp: false, chan: false)],
            [\window, (window: true, prob: false, arp: false, chan: false)],
            [\prob, (window: false, prob: true, arp: false, chan: false)],
            [\arp, (window: false, prob: false, arp: true, chan: false)],
            [\arpNoShuf, (window: false, prob: false, arp: \noShuffle, chan: false)],
            [\chan, (window: false, prob: false, arp: false, chan: true)],
            [\arpMin, (window: false, prob: false, arp: \min, chan: false)],
            [\fit, (window: true, prob: true, arp: \min, chan: true)],
            [\all, (window: true, prob: true, arp: true, chan: true)]
        ].do({ arg pair;
            this.addGrainDefsNamed(("protoRing_" ++ pair[0]).asSymbol, ("protoBuf_" ++ pair[0]).asSymbol, pair[1]);
        });
    }

    startProtoWriters {
        var state = areaState[\proto], tapGroup = areaState[\record][\tapGroup];
        state[\writers] = this.protoWriterKeys.collect({ arg key, voice;
            var ring = this.outRingFor(voice);
            var writer = Synth(\strataOutRingWrite, [\in, areaState[\record][\voiceTaps][voice],
                \bufL, ring[0], \bufR, ring[1], \phaseOut, ring[2]], tapGroup, \addToTail);
            synths[key] = writer;
            writer
        });
    }

    stopProtoWriters {
        (this.protoWriterKeys ++ this.protoOutCopyKeys).do({ arg key;
            var synth = synths.removeAt(key);
            if (synth.notNil) { this.sendToSynth(synth.freeMsg); synth.free(false) };
        });
        areaState[\proto][\writers] = [];
    }

    freeProto {
        var state = areaState[\proto];
        ((state[\outL] ? []) ++ (state[\outR] ? []) ++ (state[\bank] ? [])).do({ arg buffer; buffer !? { buffer.free } });
        (state[\outPhase] ? []).do({ arg bus; bus.free });
    }

    // A spectral freeze of a voice-ring source (memory only: no copy, no
    // re-point): a spectral writer of voice j's tap into the voice's copy
    // ring, in the tap group, as an input voice's copy writer is of the input
    startOutCopyWriter { arg voice, ringVoice;
        var key = this.protoOutCopyKeys[voice], ring = this.copyRingFor(voice);
        var fft = areaState[\freeze][\spectralBuffers][voice];
        if (fft.isNil or: { synths[key].notNil } or: { areaState[\freeze][\stopped] ? false }) { ^this };
        synths[key] = Synth(\strataRingWriteSpectral, [\in, areaState[\record][\voiceTaps][ringVoice],
            \bufL, ring[0], \bufR, ring[1], \phaseOut, ring[2], \fftL, fft[0], \fftR, fft[1]],
            areaState[\record][\tapGroup], \addToTail);
    }

    stopOutCopyWriter { arg voice;
        synths.removeAt(this.protoOutCopyKeys[voice]) !? { arg writer;
            this.sendToSynth(writer.freeMsg);
            writer.free(false);
        };
    }
}
```

### The memory check's scratch additions (in `test/engine_check/memory.scd`)

```supercollider
// SCRATCH (3.8 design): the prototype's sizes, by allocation probes: the
// ring writers, each grain def variant (one addition each), and the bank
var checkProtoSizes = {
    var privateBus = Bus.audio(server, 2), group = Group.after(engine.processGroup);
    var ring = engine.ringBuffersFor(0, 0), lines = List.new, bank = engine.areaState[\proto][\bank];
    var variants = [\none, \window, \prob, \arp, \arpNoShuf, \chan, \all];
    var phaseBuses = 20.collect({ Bus.control(server, 1) });
    var writerArgs = { arg index; [\in, privateBus, \bufL, ring[0], \bufR, ring[1], \phaseOut, phaseBuses[index]] };
    var used = engine.areaState.values.asArray.collect({ arg state; state.values.asArray }).flatten
        ++ engine.buffersL ++ engine.buffersR ++ engine.envBuffers;
    var bufnums = used.flatten.select({ arg each; each.isKindOf(Buffer) }).collect(_.bufnum);
    lines.add("strataRingWrite % KB".format(sizeOf.({ arg index; Synth(\strataRingWrite, writerArgs.(index), group) }).round(0.01)));
    lines.add("strataOutRingWrite % KB".format(sizeOf.({ arg index; Synth(\strataOutRingWrite, writerArgs.(index), group) }).round(0.01)));
    variants.do({ arg variant;
        var ringName = ("protoRing_" ++ variant).asSymbol, bufName = ("protoBuf_" ++ variant).asSymbol;
        var common = [\out, privateBus, \grainSize, 0.5, \grainDensity, 200, \windowShape, 0.5, \arpOrder, 1, \intervalCount, 3,
            \grainProb, 0.5, \inputChannel, 1];
        var r = sizeOf.({ Synth(ringName, common ++ [\bufL, ring[0], \bufR, ring[1], \phaseBus, ring[2]], group) });
        var b = sizeOf.({ Synth(bufName, common ++ [\bufnumL, engine.buffersL[0], \bufnumR, engine.buffersR[0]], group) });
        lines.add("% ring % KB (% UGens) buf % KB (% UGens)".format(variant, r.round(0.01),
            SynthDescLib.global.at(ringName).def.children.size, b.round(0.01), SynthDescLib.global.at(bufName).def.children.size));
    });
    lines.add("real strataGrainRing % UGens, strataGrainBuf % UGens".format(
        SynthDescLib.global.at(\strataGrainRing).def.children.size, SynthDescLib.global.at(\strataGrainBuf).def.children.size));
    lines.add("bank % tables, bufnums % .. % (consecutive: %), built in % s; engine buffers found: %, highest bufnum %; numBuffers %".format(
        bank.size, bank.first.bufnum, bank.last.bufnum, bank.collect(_.bufnum).differentiate.drop(1).every(_ == 1),
        engine.areaState[\proto][\bankSeconds].round(0.001), bufnums.size, bufnums.maxItem, server.options.numBuffers));
    lines.do({ arg line; ("PROTO size: " ++ line).postln });
    group.free; privateBus.free; phaseBuses.do(_.free);
};
// SCRATCH (3.8 design): the gain of one ring grain synth (the loop's
// factor per voice when voices read each other): noise into a private 4 s
// ring, the real \strataGrainRing reading it, the rms of its output over
// the rms of its input (each channel, the mean of the two), per setting
var checkProtoGain = {
    var group = Group.after(engine.processGroup), inBus = Bus.audio(server, 2), outBus = Bus.audio(server, 2);
    var meter = Bus.control(server, 4), phase = Bus.control(server, 1);
    var frames = server.sampleRate * 4, bufL = Buffer.alloc(server, frames), bufR = Buffer.alloc(server, frames);
    var settings = [
        // [size, density, spread, envShape (-1 Hann), label]
        [0.1, 20, 0.5, "the defaults (size 0.1, density 20, spread 0.5)"],
        [0.1, 20, 0.0, "size 0.1, density 20, spread 0"],
        [0.5, 20, 0.5, "size 0.5, density 20, spread 0.5"],
        [0.5, 200, 0.0, "size 0.5, density 200, spread 0"],
        [0.5, 200, 0.5, "size 0.5, density 200, spread 0.5"],
        [0.05, 10, 0.5, "size 0.05, density 10, spread 0.5"]
    ];
    var noise, writer, meterSynth;
    phase.set(0);
    SynthDef(\protoGainNoise, { arg out; Out.ar(out, [WhiteNoise.ar(0.1), WhiteNoise.ar(0.1)]) }).add;
    SynthDef(\protoGainMeter, { arg inA, inB, out;
        var a = In.ar(inA, 2), b = In.ar(inB, 2);
        Out.kr(out, A2K.kr(Integrator.ar((a ++ b).squared, 1)));
    }).add;
    server.sync;
    noise = Synth(\protoGainNoise, [\out, inBus], group, \addToHead);
    writer = Synth(\strataRingWrite, [\in, inBus, \bufL, bufL, \bufR, bufR, \phaseOut, phase], group, \addToTail);
    server.sync; 4.5.wait;
    settings.do({ arg setting;
        var grain, meterNode, first, second, inPower, outPower;
        grain = Synth(\strataGrainRing, [\out, outBus, \bufL, bufL, \bufR, bufR, \phaseBus, phase,
            \grainSize, setting[0], \grainDensity, setting[1], \posSpread, setting[2], \panSpread, 0, \rateLevel, 0, \pan, 0], group, \addToTail);
        meterNode = Synth(\protoGainMeter, [\inA, inBus, \inB, outBus, \out, meter], group, \addToTail);
        server.sync; 1.0.wait;
        first = h.readBus(meter);
        2.0.wait;
        second = h.readBus(meter);
        inPower = (second[0] - first[0]) + (second[1] - first[1]);
        outPower = (second[2] - first[2]) + (second[3] - first[3]);
        ("PROTO gain: % : % dB (rms out / rms in, %)".format(setting[3], (10 * log10(outPower / inPower)).round(0.1),
            (outPower / inPower).sqrt.round(0.01))).postln;
        grain.free; meterNode.free; server.sync; 0.6.wait;
    });
    noise.free; writer.free; server.sync;
    group.free; inBus.free; outBus.free; meter.free; phase.free; bufL.free; bufR.free;
};
// ... and inside checkMemoryWorstCase, after the pool cases (both tiers):
        h.stopAllVoices(target);
        // SCRATCH (3.8 design): voices that grain each other. Sources
        // inputSource + 1 + j read voice j's output ring (its tap, written
        // in the tap group); each voice reads another voice's ring
        target.numVoices.do({ arg voice; command.(\setGrainParam, voice, \freeze, 0.0) });
        server.sync; 0.6.wait;
        // V1: the spaced case with another voice's ring where the input was
        startAll.value;
        server.sync; 0.2.wait;
        [{ arg voice; voice + 1 }, { arg voice; ringOf.(voice, 0) }, { 0 }].do({ arg sourceOf, step;
            if (step > 0) { 0.2.wait; server.sync };
            if (step == 2) { holdVoices.value };
            switchAll.(sourceOf);
        });
        target.numVoices.do({ arg voice; command.(\voiceOff, voice) });
        startAll.value;
        engage.value(command);
        probeHeadroom.("V1 synth -> buffer -> another voice's ring -> synth, 0.2 s apart and restarted", "voice-ring worst case", nil,
            { arg fits, freeKB; protoFigures.add([target.tier, "V1 spaced, ring for input", freeKB.round(1), fits]) });
        h.stopAllVoices(target);
        target.numVoices.do({ arg voice; command.(\setGrainParam, voice, \freeze, 0.0) });
        server.sync; 0.6.wait;
        // V2: every voice switched between three other voices' rings
        target.numVoices.do({ arg voice; command.(\setGrainSource, voice, ringOf.(voice, 0)) });
        startAll.value;
        server.sync; 0.2.wait;
        2.do({ arg step;
            if (step > 0) { 0.2.wait; server.sync; holdVoices.value };
            target.numVoices.do({ arg voice; command.(\setGrainSource, voice, ringOf.(voice, step + 1)) });
        });
        engage.value(command);
        probeHeadroom.("V2 every voice switched between three other voices' rings 0.2 s apart", "all-ring worst case", nil,
            { arg fits, freeKB;
                var names = h.synthNames(target.context.xg);
                protoFigures.add([target.tier, "V2 all-ring", freeKB.round(1), fits, names.count(_ == \strataGrainRing),
                    names.count(_ == \strataRingWriteSpectral)]) });
        h.stopAllVoices(target);
        target.numVoices.do({ arg voice; command.(\setGrainParam, voice, \freeze, 0.0) });
        target.numVoices.do({ arg voice; command.(\setGrainSource, voice, 0) });
        server.sync; 0.6.wait;
        // V3: synth -> another voice's ring -> synth
        startAll.value;
        server.sync; 0.2.wait;
        switchAll.({ arg voice; ringOf.(voice, 0) });
        0.2.wait; server.sync;
        holdVoices.value;
        switchAll.({ 0 });
        engage.value(command);
        probeHeadroom.("V3 synth -> another voice's ring -> synth 0.2 s apart", "voice-ring worst case", nil,
            { arg fits, freeKB; protoFigures.add([target.tier, "V3 synth -> ring -> synth", freeKB.round(1), fits]) }, 2 * target.numVoices);
        h.stopAllVoices(target);
        target.numVoices.do({ arg voice; command.(\setGrainParam, voice, \freeze, 0.0) });
        server.sync; 0.6.wait;
        // V4: V2 with sixteen ring notes live and cutting
        command.(\setNotePool, target.notePoolMax);
        target.numVoices.do({ arg voice; command.(\setGrainSource, voice, ringOf.(voice, 0)) });
        startAll.value;
        server.sync; 0.2.wait;
        2.do({ arg step;
            if (step > 0) { 0.2.wait; server.sync; holdVoices.value };
            target.numVoices.do({ arg voice; command.(\setGrainSource, voice, ringOf.(voice, step + 1)) });
        });
        poolNotes.([3, 3, 2, 2, 2, 2, 2]).do({ arg pair; playPoolNote.(*pair) });
        poolNotes.([3, 3, 2, 2, 2, 2, 2]).do({ arg pair; command.(\noteOff, pair[0], pair[1], 0) });
        poolNotes.([3, 3, 2, 2, 2, 2, 2]).do({ arg pair; playPoolNote.(*pair) });
        engage.value(command);
        probeHeadroom.("V4 all-ring with sixteen ring notes live and cutting", "all-ring worst case with the pool full", 5,
            { arg fits, freeKB;
                var names = h.synthNames(target.context.xg);
                protoFigures.add([target.tier, "V4 all-ring, pool full", freeKB.round(1), fits, poolHeld.value,
                    names.count(_ == \strataGrainRing), names.count(_ == \strataRingWriteSpectral)]) },
            target.numVoices + target.notePoolMax);
        h.stopAllVoices(target);
        target.numVoices.do({ arg voice; command.(\setGrainParam, voice, \freeze, 0.0) });
        target.numVoices.do({ arg voice; command.(\setGrainSource, voice, 0) });
        server.sync; 0.6.wait;
        // V5: V3 with sixteen voice synth notes, Karplus's seven first
        startAll.value;
        target.numVoices.do({ arg voice; command.(\setGrainParam, voice, \freeze, 0.0) });
        poolNotes.([2, 2, 2, 1, 1, 7, 1]).do({ arg pair; playPoolNote.(*pair) });
        server.sync; 0.2.wait;
        switchAll.({ arg voice; ringOf.(voice, 0) });
        0.2.wait; server.sync;
        holdVoices.value;
        switchAll.({ 0 });
        engage.value(command);
        probeHeadroom.("V5 synth -> another voice's ring -> synth, sixteen voice synth notes (Karplus's seven first)", "voice-ring worst case with the pool full", 5,
            { arg fits, freeKB;
                var names = h.synthNames(target.context.xg);
                protoFigures.add([target.tier, "V5 synth -> ring -> synth, pool full", freeKB.round(1), fits, poolHeld.value, poolKarplus.value,
                    [names.count(_ == \strataGrainBuf), names.count(_ == \strataGrainRing), names.count({ arg name; h.voiceDefs.includes(name) })]]) },
            (2 * target.numVoices) + target.notePoolMax);
```
