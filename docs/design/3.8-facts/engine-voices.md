# 3.8 design facts: what a voice type costs in the engine, and what a type switch is

Read and measured in a worktree of `main` at 59a0a0c1 (the groundwork is not on it; it changes no engine file but `StrataPositions.sc`, design §"Packages", so everything below holds after it). I ran the memory area as it is (SuperCollider 3.14.1, local, JACK dummy at 48 kHz), then two scratch areas of my own (uncommitted, left in the worktree): `voicetypes` measures each prototype def's pool cost with the memory area's probes, plays it, and times scsynth's CPU; `memtypes` is `memory.scd`'s worst cases run with every voice set to one def, at 4 floor probes (2 at the pool cases) so the flood still measures what is left below a floor. Both scratch areas also ran once on SuperCollider 3.13 in Docker (`test/run_engine_check_313.sh`): every def's size identical, every worst-case figure within one probe step (17 KB). Figures are **measured** (version and tier named), **quoted** (with the source) or **(est.)**; "SC" paths are the working tree of `~/src/supercollider`.

## 0. The facts most likely to change the design

1. **With free types, Karplus on every voice already fails the high tier's floors, and the pool floor on both tiers.** The memory area's cases put Karplus on voice 5 only: 2 of the 14 voice synths of synth -> buffer -> synth and 7 of the 16 pool notes (`test/engine_check/memory.scd:684`, `:426-429`). With all seven voices on `\strataKarplus` (**measured**, 3.14.1, `memtypes`): high synth -> buffer -> synth **3058 KB free, 526 under its 3584 floor**; high pool case about **420-440 KB** (printed 676-693 with one 256 KB probe failing to allocate) against 1280; standard pool case **1080 KB, 200 under 1280**; standard synth -> buffer -> synth 3732 (660 above 3072). Today (the same run, every voice its own def): 3817, 1754, 2412 and 4491 KB.
2. **The budget a type can take if every voice may be it: about 43.6 KB per voice synth on high** (about 36.5 counting the spectral writers' late allocations), from the binding case, high synth -> buffer -> synth (14 voice synths, 233 KB above its floor today). The other cases allow more: high pool case 52.8, standard pool 74.7, standard synth -> buffer -> synth 128.3 KB (section 4). The linear model predicts every measured variant within 15 KB. Every existing def but Karplus (15.2-21.9 KB) fits; Karplus (80.9) does not.
3. **Karplus can shrink by 31 KB, nearly two fifths, at almost no cost**: its two `Pluck` lines are sized from `maxdelaytime: 0.1` (`lib/engine/StrataVoiceDefs.sc:351`, `:361`), which SC rounds to 8192 frames (32 KB each) at 48 kHz (`DelayUGens.cpp:3436-3452`: `ceil(max × SR + 1) + 64`, next power of two). At 0.0839 s it is 4096 frames: **measured 49.7 KB against 80.9** (3.14.1), the lowest pitch 11.9 Hz instead of 10 Hz (Lua's freq floor is 20 Hz, `docs/notes/engine/voices.md:86`). All seven voices on that Karplus: high synth -> buffer -> synth 3513 KB (still 71 under 3584), high pool case 1384 (104 above 1280), standard pool 2041.
4. **The prototypes, per synth (measured, 3.14.1 and 3.13 identical, twenty synths each):** wavetable (`VOsc`) **16.0 KB**, wavetable (`VOsc3`) 17.7, noise texture 27.8, detuned saw 19.4, formant 17.7, additive **41.3 / 68.3 / 123.0 KB at 8 / 16 / 32 partials** (181 / 311 / 573 UGens; about 0.21-0.23 KB a UGen, 3.4 KB a partial with its own drift LFO). Only the additive voice is costly: 16 partials fail the high floors with free types (3244 KB at high synth -> buffer -> synth; 811 at the high pool case), 32 partials exhaust the pool at both pool cases (`/s_new out of real time memory`, `GrainBuf_Ctor: alloc failed`) and are over the grain defs' 88 KB limit; 8 partials fit the budget.
5. **A wavetable costs no pool memory for its tables**: `VOsc`/`VOsc3` read server buffers (`b_alloc`, ordinary RAM), so the bank is RAM only: 8 tables of 2048 samples = 8 × 4096 floats = **128 KB** (measured to allocate and play; the prototype's bank). The tables can be built at alloc without any sclang loop: `Buffer.allocConsecutive(n, server, 4096, 1, { arg b, i; b.sine1Msg(amps[i], true, true, true) })` fills each on the server (`/b_gen sine1`, wavetable flag). `VOsc` needs consecutive bufnums, which the "bufnums never change" rule already gives.
6. **A type switch is a voice-synth replacement only.** Nothing else a voice runs names its def: the ring writer reads the voice bus (`lib/engine/StrataRings.sc:108-131`), the grain synth reads the ring, `\strataMod` reads the voice bus (`StrataLifecycle.sc:21-27`), the stage and the fast-modulation nodes never see the voice synth (no voice def has `fastModIn`). A buffer or input voice has no voice synth at all (`StrataLifecycle.sc:158-167`, `:333-341`): a switch there is a record only, no node.
7. **"Replace, never stack" gives two different bounds for a switch, by whether it cuts or releases the old synth.** Cut (50 ms kill fade into `cuttingSynths`, after `freeCuttingSynths`): a voice holds at most two voice synths, as synth -> buffer -> synth does. Release (into `fadingSynths`, as `switchGrainSynth` releases a voice synth over `grainRelease`, `StrataLifecycle.sc:336-340`): two switches inside 2 s leave the live synth, the released one fading and the one before it cutting, **three voice synths a voice, 21 in all**, a case the memory area has never run. A held chord's notes switched with the voice leave 16 live and 16 cutting voice synths: measured (a scratch third pool case) at 2327 KB free on high today, about 430 with every voice Karplus.
8. **Index = def is assumed in six engine sites and the checks.** `voiceSynthDefs` (`lib/engine/StrataVoices.sc:24-25`), read by `startVoiceSynth` (`StrataLifecycle.sc:10`), `gateVoice`'s re-gate (`:164-165`), `startNoteSynth` (`StrataNotes.sc:260`), `ownNotePairs` (`:498`, `voiceSynthDefs.includes(defName)`: "is a voice def"), `notesUnfrozen` (`:528`), and the voices area's `addDefs` return (`StrataVoices.sc:14`), which is what `controlNameSets` is built from (`lib/Engine_Strata.sc:137-143`): every type's def must be returned there or `controlPairs` sends it nothing. **`gateVoice` re-gates a releasing voice synth without asking what def it is** (`StrataLifecycle.sc:160`): a type changed on a stopped voice whose old synth still releases (up to `releaseTime` 30 s) would bring the old type back, unless a `releasedVoiceType` check is added as `releasedGrainSource` does for grain synths (`:153`).
9. **The checks copy the list instead of reading it**: `test/engine_check.scd:48-49` (`h.voiceDefs`); the memory area's per-def limit is looked up by name with 0 as the default (`memory.scd:254-261`), so a def in the list without a limit fails and a def not in the list is never measured; the pool case hardwires Karplus on voice 5 (`memory.scd:426-429`, `:684-707`); the velocity check allows the pluck impulse by name (`voices.scd:34`); the Lua stub parses `voiceSynthDefs = [...]`, asserts it has `numVoices` names and validates `setVoiceParam` names per voice index against that def (`test/norns_stubs.lua:495-501`, `:668`).
10. **The notes' "Karplus is the costliest note" is stale since 3.7**: `\strataGrainBuf` is 82.6 KB (3.7's package 1a) against Karplus's 80.9, so the costliest note today is a buffer note (`docs/notes/engine/memory.md:12`, `:118`, `docs/notes/engine/notes.md`, Memory). With free types the costliest voice synth, not Karplus, sets the pool case.

## 1. Today: how a voice's def is chosen and started

**What ties index to def.** One literal Array, `voiceSynthDefs = [\strataResonator, \strataFM, \strataFolder, \strataSub, \strataPulse, \strataKarplus, \strataRing]` in `allocVoiceState` (`lib/engine/StrataVoices.sc:24-25`), indexed by the engine voice. The voices area's `addDefs` returns it (`:14`) and `alloc` builds `controlNameSets` from every name an area returns (`lib/Engine_Strata.sc:137-143`); `controlPairs(defName, controls)` sends only the names a def has (`lib/engine/StrataUtil.sc:51-58`).

**Readers of the list:**
- `startVoiceSynth` (`StrataLifecycle.sc:9-14`): `Synth(voiceSynthDefs[voice], [\out, granBuses[voice]] ++ controlPairs(def, voiceControls[voice]) ++ ownNotePairs(voice, def), target: voiceGroup)` (head of `voiceGroup`, before the ring writers at its tail).
- `gateVoice` (`:141-193`): on the synth source, a releasing voice synth is taken back (`:160`) and re-gated with `controlPairs(voiceSynthDefs[voice], ...)` (`:164-165`), or one is started.
- `voiceSynthFreed` (`:214-228`) restarts the voice synth through `startVoiceSynth` if the voice still uses it.
- `switchGrainSynth` (`:314-343`): back to the synth source starts one if missing (`:329-332`); leaving it releases the voice synth over `grainRelease` into `fadingSynths` (`:333-341`).
- `startNoteSynth` (`StrataNotes.sc:253-264`): a synth voice's extra note is `Synth(voiceSynthDefs[voice], ...)` at the head of `voiceGroup` (`:259-262`).
- `ownNotePairs` (`StrataNotes.sc:496-507`) and `notesUnfrozen` (`:525-538`).

**What the commands assume:**
- `voiceOn` (`StrataVoices.sc:80-122`) replaces `voiceControls[voice]` with 13 type-free keys (`freq`, `amp`, `pan`, `bend`, the nine crossmod keys, `:93-98`) and calls `gateVoice`. Lua then sends the synth params with `setVoiceParam`. Nothing in it is per def.
- `retrigger` (`:133-141`) sets `velocity` and `t_trig` on the own voice synth, `t_trig` on every grain synth, and the stage's accent while running. A def without `t_trig` would ignore it: scsynth drops a set of a control a node lacks (SC `server/scsynth/SC_Graph.cpp:833-840`).
- `setVoiceParam` (`:149-152`) stores any name not refused in `voiceControls` (`setVoiceControl`, `:281-293`) and sends it to the voice synth, the voice's voice-synth notes (`setVoiceSynths`, `StrataNotes.sc:203-211`) and, if the grain def or the stage has it, to them. The engine does not check the name against the def; the Lua stub does, per voice index (`test/norns_stubs.lua:668`).
- `noteOn` on a synth voice builds a voice synth of `voiceSynthDefs[voice]` with the note's `freq`, `velocity`, `t_trig` 1 and note controls (`perNoteVoiceControls`: `freq`, `velocity`, `t_trig`, `noteGate`, `noteBend`, `noteAmp`, `noteMain`, `StrataNotes.sc:198`). Every voice def must have these names for its notes to work.

**What every voice def shares** (the 24 controls every def but Sub has; Sub has no `pan`, 23): `out`, `gate`, `freq`, `amp`, `pan`, `modBus1-3`, `modAmpAmt1-3`, `modFreqAmt1-3`, `t_trig`, `velocity`, `bend`, `kill`, `noteGate`, `noteBend`, `noteAmp`, `noteMain`, `attackTime`, `releaseTime`; and the blocks: `voiceEnvelope` (ASR through `openedGate`, times `killFade`, times `notePark`, `StrataVoiceDefs.sc:43-48`), `voiceModulation` (the accent `voiceAccent`, the crossmod sums and clamps, `bend × noteBend`, `voiceLevel`, `:15-21`, `:78-100`), `noteMainValue` on the def's expression control from `noteMainRanges` (`:59-71`, keyed by def name; a docs test compares each entry with Lua's spec, `test/unit/docs_test.lua:2172-2173`). The type-specific params: 1-4 a def (26-28 controls in all; Sub 24).

**What is specific to one def:**
- Karplus: `exciteTrig = Impulse.ar(excite) + (T2A.ar(t_trig) * velocity)` re-plucks on `retrigger` (`StrataVoiceDefs.sc:340`), the one allowance in the velocity check, granted by name (`test/engine_check/voices.scd:34`); its two `Pluck` lines (`:348-365`) are 64 KB of its 80.9.
- Resonator: `resonatorGain`, its voice limiter and the cutoff ceiling (`:171-184`); FM and Ring: `subsonicBlock` (`:216`, `:400`; the rule that any new def that can put energy near 0 Hz blocks it at the source, `docs/notes/engine/voices.md:12`); Pulse: `1.1 - res` (a Lua test reads that line, `test/unit/voices_test.lua:90-100`); Sub: no `pan`.
- Each def's 3.4 ASR times are its `attackTime`/`releaseTime` defaults (`voices.md:16`; checked per def, `voices.scd:440-441`).

**Each def's pool cost and its limit** (quoted, `docs/notes/engine/memory.md:12`; the limits in `memory.scd:254-255`; the figures re-measured here on 3.14.1, memory area alone, identical but FM, 20.2 against 19.4):

| Def | KB (3.13 shard, notes) | KB (3.14.1, measured here) | Limit | UGens | Controls |
|---|---|---|---|---|---|
| `\strataResonator` | 21.9 | 21.9 | 24 | 74 | 28 |
| `\strataFM` | 19.4 | 20.2 | 22 | 76 | 27 |
| `\strataFolder` | 16.0 | 16.0 | 18 | 59 | 26 (counted from its args) |
| `\strataSub` | 15.2 (3.5 final review) | 15.2 | 17 | 54 | 24 |
| `\strataPulse` | 16.9 | 16.9 | 19 | 62 | 27 (counted from its args) |
| `\strataKarplus` | 80.9 | 80.9 | 83 | 62 | 27 |
| `\strataRing` | 17.7 | 17.7 | 20 | 64 | 27 (counted from its args) |
| `\strataMod` | 5.9 | 5.9 | 9.9 | 22 | |

Beside them (measured, 3.14.1): `\strataGrainBuf` 82.6, `\strataGrainRing` 64.0 (63.2 in the notes), the stage 41.29 KB.

## 2. A type per voice in the engine

**What would change for voice i to run any def:**
- The list splits in two: every type's def (returned by `addDefs`, so `controlNameSets` knows each) and each voice's current one (per-voice state, e.g. `areaState[\voices][\types]`; an extension file adds no variable, so the existing `voiceSynthDefs` var can hold the per-voice choice and a literal method the type list).
- `ownNotePairs`' `voiceSynthDefs.includes(defName)` (`StrataNotes.sc:498`) must test the type list.
- `gateVoice` (`StrataLifecycle.sc:149-166`) needs the type a releasing voice synth was built for, as `releasedGrainSource` (`:153`) is for grain synths: a releasing synth of another type is superseded (released over `grainRelease` into `fadingSynths`, as `:149-152` does when the source is no longer the synth), never re-gated.
- `noteMainRanges` (`StrataVoiceDefs.sc:59-62`): one entry per def, and its docs test.
- Nothing else in the engine reads a voice's def (grep of `voiceKey` and def names outside the voices, lifecycle and notes files: only `StrataFreeze.sc:296`, which is the ring writer's).

**How Lua could tell the engine** (options the code allows; none chosen):
- **A new command**, e.g. `setVoiceType(voice, type)` `"ii"`, modeled on `setGrainSource` (`StrataVoices.sc:176-183`: a stopped voice records it, a running one is replaced, the same value is a no-op). Costs: a row in AGENTS.md's table (225 words left, `docs/status.md`), the stub's checks, and the stub's per-voice `setVoiceParam` names becoming per type.
- **A handler-only grain param**, as 3.7's `rootNote` (`StrataNotes.sc`, `grainParamHandlers`; `docs/notes/engine/notes.md`): `setGrainParam(voice, "voiceType", n)` handled by an area and never stored or sent. Lua's start already sends every grain param before `voiceOn` (`voices.md:35`), so the first synth is the right type; no new command row. Cost: a voice-level choice on the grain command.
- **`setVoiceParam(voice, "type", n)`** as it is would not work: `voiceOn` resets `voiceControls` (`StrataVoices.sc:93-98`) and Lua sends voice params after `voiceOn`, so each start would build the old type and replace it at once (a cut set per start). It needs a handler table `setVoiceParam` does not have, or a key `voiceOn` keeps.
- **An argument of `voiceOn`** changes its signature `"iffffff"` and still leaves a running voice's switch to another path.

**Values across a switch.** `voiceControls` keeps the old type's keys; `controlPairs` drops the names the new def lacks, but a name two types share with different meanings (`ratio` in FM and Ring, `mod` in Folder and Ring, `width` in Pulse and the saw prototype) carries over until Lua resends the new type's values (Lua is the only source of values, `voices.md:5`).

**What a switch on a running voice is, by state:**
- **Synth source, unfrozen:** the old voice synth leaves (cut or released, below), the new type starts at the head of `voiceGroup` from `voiceControls` and `ownNotePairs`. The ring writer records the voice bus, where both write for the fade (`Out.ar` sums), so the grains crossfade with no grain synth replaced; the mod synth follows the bus (its level now the new type's: the Resonator's crossmod history in `voices.md:88` is the warning); the stage, sends and fast modulation do not change.
- **Its extra notes** (voice synths of the old def): restarted on the new def (cut and started silent, as `restartNotes` does for a source switch, `StrataNotes.sc:593-602`, ruling 45), or left to play the old type until released; the slot record keeps no def (`kind` is only `\voice`, `:153-159`).
- **Frozen synth voice (hold or spectral):** the ring writer is paused or spectral and the ring holds the old type; the new voice synth is inaudible until the unfreeze (it still drives `\strataMod`, as the voice synth does today while frozen), and `notesUnfrozen` restarts ring-stream notes as the current def (`StrataNotes.sc:525-538`). The park (ruling 44) reaches the new synth through `ownNotePairs` in `startVoiceSynth`.
- **Buffer or input voice:** no voice synth (`StrataLifecycle.sc:158`, `:333-341`): the switch is recorded, and the next return to the synth source starts the new type.
- **Stopped voice:** recorded; the releasing-synth case of section 2's `gateVoice` item applies.

**What the memory rule gives.** The rule is "live synths, one fading and one cutting set" (`memory.md:4`; `replaceFadingSynths`, `StrataLifecycle.sc:379-384`). A switch that cuts the old voice synth (after freeing the voice's cutting set) keeps a voice at two voice synths at most, the state synth -> buffer -> synth already measures. A switch that releases it into the fading set allows live + fading + cutting = three voice synths a voice (21) after two switches within `grainRelease` (2 s); the memory area has no such case and the cutting-set bound in `probeHeadroom` (`memory.scd:501-503`) would need one. **(est.)** With today's mix of defs, 7 more voice synths at the high synth -> buffer -> synth case cost about 7 × 27 = 189 KB of its 233 KB of room.

## 3. The prototypes, measured

Each carries every shared control and the note controls of section 1 and uses `voiceEnvelope` and `voiceModulation`, so its figure compares with the existing defs (only `noteMainValue` is replaced by the same formula with a literal range, `scratchMainValue`). Each played at 110 and 2000 Hz for 2 s (peak 0.02-0.36, no bad value; levels are not matched to the existing voices, the noise voice is the quietest at 0.02-0.035). Sources in the appendix. Pool KB by the memory area's method (twenty synths, the small probes that fit with and without them; resolution 0.85 KB), **measured** on 3.14.1, every run identical (four runs; the Karplus variant two), and **identical on 3.13** (one run in Docker, every def to 0.1 KB):

| Def | KB | UGens | Controls | Notes |
|---|---|---|---|---|
| wavetable, `VOsc` (2 oscillators) | **16.0** | 56 | 28 | morph, morphRate, morphDepth, detune; tables in RAM |
| wavetable, `VOsc3` (6 oscillators) | 17.7 | 64 | 28 | the same |
| additive, 8 partials | **41.3** | 181 | 28 | tilt, stretch, oddEven, drift; `SinOsc` bank, per-partial drift LFO and Nyquist mute |
| additive, 16 partials | **68.3** | 311 | 28 | |
| additive, 32 partials | **123.0** | 573 | 28 | over 88 KB, the grain defs' limit |
| noise texture | **27.8** | 110 | 30 | pink noise and `Dust2`, lowpass, four `Resonz` |
| detuned saw (extra) | 19.4 | 74 | 28 | three `VarSaw` a channel, `RLPF` |
| formant (extra) | 17.7 | 66 | 27 | two `Formant` a channel |
| Karplus, `Pluck` max 0.0839 s | **49.7** | 62 | 27 | the existing def but the two max delays |

The two extras are here because they are the cheapest plausible types that the roster lacks (a saw pad and a vocal timbre), and like the wavetable they show what a def costs without a delay line: 16-20 KB, the size of the six small existing defs. The additive cost is the graph: about 0.21-0.23 KB a UGen, about 3.4 KB a partial with its own drift LFO, comparison and level product (est. from the three: (68.3 − 41.3) / 8 and (123.0 − 68.3) / 16). `DynKlang` expands to the same `SinOsc` bank; `Klang` is one UGen but computes its coefficients once, in its constructor (SC `server/plugins/OscUGens.cpp:2750-2757`), so bend, crossmod and notes could not move it.

**The wavetable bank.** 8 tables × 2048 samples, stored as 4096 floats (wavetable format) = 128 KB of ordinary RAM; filled on the server (`/b_gen sine1` with the wavetable flag, in `allocConsecutive`'s completion message, `SCClassLibrary/Common/Control/Buffer.sc:40`, `:524`), so no sclang loop at all. `Signal.sineFill` (one primitive `addSine` per harmonic, `Signal.sc:155-163`) and `asWavetable` (a primitive, `:53-57`) are the sclang path for tables computed in Lua's or sclang's terms. **(est.)** A table with 64 harmonics aliases above about 375 Hz; band-limited copies per octave (10 octaves) would be 1.3 MB of RAM for 8 tables, and `VOsc` would need the octave picked by frequency (it interpolates only between neighboring bufnums).

**CPU** (scsynth's own CPU time from `/proc/<pid>/task/*/schedstat` over 8 s, idle against N synths of one def; **measured** on this machine, 3.14.1; only relative; the server's `avgCPU` under the JACK dummy read 7-40 % idle from one window to the next on this shared machine and was dropped):

| Def | % of a core per synth, 20 synths | 40 synths | against Karplus (40) | 3.13 in Docker, 40 synths |
|---|---|---|---|---|
| `\strataKarplus` | 0.118 | 0.112 | 1.00 | 0.106 |
| `\strataResonator` | 0.117 | 0.107 | 0.96 | 0.101 |
| `\strataFM` | 0.061 | 0.055 | 0.49 | 0.052 |
| `\strataSub` | 0.044 | 0.040 | 0.36 | 0.040 |
| Karplus, max 0.0839 s | 0.116 | 0.114 | 1.02 | 0.104 |
| wavetable `VOsc` | 0.045 | 0.043 | 0.38 | 0.036 |
| wavetable `VOsc3` | 0.064 | 0.059 | 0.53 | 0.057 |
| additive 8 | 0.111 | 0.104 | 0.93 | 0.111 |
| additive 16 | 0.189 | 0.169 | 1.51 | 0.183 |
| additive 32 | 0.324 | 0.275 | 2.46 | 0.331 |
| noise texture | 0.193 | 0.177 | 1.58 | 0.183 |
| detuned saw | 0.095 | 0.092 | 0.82 | 0.096 |
| formant | 0.047 | 0.052 | 0.46 | 0.051 |

The idle engine took 3.0-3.5 % of a core (2.7-2.9 % in Docker on 3.13, where additive 32 is 3.1 Karplus). So the costliest prototype in CPU (additive 32) is about 2.5 Karplus, the noise voice (four `Resonz` on stereo noise) about 1.6, additive 16 about 1.5; the wavetable is as cheap as Sub. The cost that limits a type is the pool, not CPU, on this machine; a CM3's figure would need the device (#6).

## 4. The worst cases with free types

**Measured** with `memtypes` on 3.14.1 (KB free; floors 3072 standard, 3584 high, 1280 for the pool cases; a figure marked * had a 256 KB probe fail to allocate and overstates by about 256; "exh." means the pool ran out: `/s_new out of real time memory` and `GrainBuf_Ctor: alloc failed`, so the figure means nothing). "Voice notes live and cutting" is a scratch third pool case: synth -> buffer -> synth with the pool full, then every note cut and played again inside the hold (16 live and 16 cutting voice-synth notes, what a type switch that restarts a held chord leaves).

| Case | today's defs | all Karplus | all Karplus 0.0839 | all additive 16 | all additive 32 |
|---|---|---|---|---|---|
| standard, spaced | 4659 | 4305 | 4524 | 4390 | 4002 |
| standard, recalls | 4609 | 4289 | 4457 | 4373 | 3952 |
| standard, synth -> buffer -> synth | 4491 | 3732 | 4171 | 3918 | 3159 |
| standard, all-buffer | 4609 | 4609 | 4609 | 4609 | 4609 |
| standard, eight recordings | 4466 | 4095 | 4331 | 4196 | 3809 |
| standard, pool all-buffer | 1956 | 1956 | 1956 | 1956 | 1956 |
| standard, pool synth -> buffer -> synth | 2412 | **1080** | 2041 | 1485 | exh. |
| standard, voice notes live and cutting | 2951 | **1046** | 2529 | 1636 | exh. |
| high, spaced | 4019 | 3648 | 3867 | 3732 | 3345 |
| high, recalls | 4524 | 4171 | 4356 | 4272 | 3850 |
| high, synth -> buffer -> synth | 3817 | **3058** | **3513** | **3244** | **2485** |
| high, all-buffer | 4491 | 4508 | 4508 | 4508 | 4491 |
| high, eight recordings | 3809 | 3438 | 3674 | 3522 | 3337 |
| high, pool all-buffer | 1839 | 1855 | 1855 | 1855 | 1855 |
| high, pool synth -> buffer -> synth | 1754 | **676*** | 1384 | **811** | exh. |
| high, voice notes live and cutting | 2327 | **693*** | 1906 | **1013** | exh. |

(The memory area's own run, 12 and 14 probes, read today's 4480, 3820, 2420 and 1750 KB for the standard and high synth -> buffer -> synth and pool cases: the 4-probe method agrees within 10 KB.)

**(i) All Karplus.** The cases do not assume it: they hold 2 Karplus among their 14 voice synths and 7 among 16 notes. All seven voices Karplus costs 14 × 80.9 − 377.6 = 755 KB at synth -> buffer -> synth (measured 759 high, 759 standard) and about 1330 at the pool cases.

**(ii) The costliest prototype**, additive at 32 partials: synth -> buffer -> synth 1332 KB lower than today on both tiers (standard 3159, 87 above its floor; high 2485, 1099 under); both pool cases exhausted.

**Room per voice synth before each floor fails**, if every voice is the same type X (measured room today over the case's count; today's voice synths: 2 × (21.9 + 20.2 + 16.0 + 15.2 + 16.9 + 80.9 + 17.7) = 377.6 KB at synth -> buffer -> synth; plus the pool's 16 notes, 7 × 80.9 + 166.0 = 732.3 KB):

| Case | voice synths | room today | largest X |
|---|---|---|---|
| high, synth -> buffer -> synth | 14 | 233 | **43.6 KB** (36.5 counting about 100 KB of spectral late allocations, `memory.md:254`) |
| high, pool synth -> buffer -> synth | 30 | 474 | 52.8 KB |
| high, voice notes live and cutting | 46 | 1047 | 62.8 KB |
| standard, pool synth -> buffer -> synth | 30 | 1132 | 74.7 KB |
| standard, voice notes live and cutting | 46 | 1671 | 76.4 KB |
| standard, synth -> buffer -> synth | 14 | 1419 | 128.3 KB |

The model predicts each measured variant within 15 KB (Karplus 0.0839 at high synth -> buffer -> synth: 3499 predicted, 3513 measured; additive 16 at the high pool case: 815 and 811). If X is over 82.6 KB, the pool's cutting buffer notes are no longer the costliest cutting note and the voice-notes case binds instead. These are per-voice-synth figures; a design that lets only some voices take a costly type has the difference to spend (a type of size X on k voices costs 2k × (X − the def it replaces) at synth -> buffer -> synth).

**What the per-def limit lines would need.** `voiceDefLimitsKB` (`memory.scd:254-255`) is by name, each limit the def's 3.13 size + 2 KB rounded up (ruling 22, `memory.md:12`); a new def needs its entry and its name in `test/engine_check.scd:48-49`, or it is never measured (a name in the list without an entry fails at limit 0, `memory.scd:261`). The pool cases need recasting around the costliest type on any voice (the Karplus-on-voice-5 count and the `[23, 14, 30, 9]` check, `memory.scd:684-707`), and a type switch case (a release-type switch's 21 voice synths, or the voice-notes case above) if the design allows it.

## 5. What else a type touches in the engine

- **`\strataMod`** (`StrataVoiceDefs.sc:110-124`): reads the voice bus, not the def; unchanged. Its output depends on the type's level (`Amplitude.kr` × 0.7), so a type's level sets how hard it crossmodulates (the Resonator's case, `voices.md:88`).
- **The ring writer** (`StrataRings.sc:108-131`): reads `granBuses[voice]`; unchanged. The spectral writer (`StrataFreeze.sc:108-127`) the same.
- **Freeze**: no def read; `notesUnfrozen` restarts notes as the current def (`StrataNotes.sc:528`, `:532-537`).
- **`retrigger`** (`StrataVoices.sc:133-141`): type-free; a type that re-excites on a trigger (a noise burst, a struck resonator) needs the Karplus-style allowance in the velocity check, which is granted by def name (`voices.scd:34`).
- **The engine check's sites that name defs or the index = def list** (lines matching the def names, `voiceSynthDefs` or `voiceDefs`): `test/engine_check.scd` 5 (the list, `allDefs`, `engineVoiceDefs`: `:48-53`), `voices.scd` 26 (the velocity allowance, the Resonator's level and limiter checks, per-def ASR times, the Sub and Pulse probes, loops over every def), `lifecycle.scd` 10 (`engine.voiceSynthDefs[voice]` at `:130`, `:141`, `:935`, `:992`; `\strataResonator` at `:418`), `memory.scd` 6, `notes.scd` 4 (`:660`, `:678`, `:965`, `:1135`), `structure.scd` 3, `rings.scd` 1 (`:199`, voice 2's def). Lua: `test/norns_stubs.lua` 12, `test/unit/docs_test.lua` 12 (`:194-197` voice 0 is Resonator and voice 6 Ring; `:428-431` patches the list's last name; `:756`; `:2172-2173`), `test/unit/voices_test.lua` 4.

## Where the roadmap or the notes are wrong or silent

- `ROADMAP.md` (3.8, More voice types) asks what "each new SynthDef costs in real-time memory against 3.5's notes per voice", but the existing roster already breaks the floors once types are free: the cost question is about every voice holding the costliest def, Karplus included (section 4).
- `docs/notes/engine/memory.md:12` gives `\strataFM` 19.4 KB (3.5's package 1a); it measures 20.2 KB today on 3.13 and on 3.14.1, under its 22 KB limit.
- `docs/notes/engine/memory.md:12`, `:118` and `docs/notes/engine/notes.md` (Memory: "Karplus is the costliest note (80.9 KB ... against `\strataGrainBuf`'s 73.3 KB)"): stale since 3.7's package 1a made `\strataGrainBuf` 82.6 KB (`memory.md:165`).
- `docs/notes/engine/memory.md:12`: "Karplus's two 0.1 s `Pluck` lines" are sized by `maxdelaytime` rounded to a power of two (`DelayUGens.cpp:3436-3452`); the notes never say that 0.0839 s halves them.
- `docs/notes/engine/memory.md:4`: the rule "one fading and one cutting set" allows three voice synths a voice once a switch can release a voice synth while a synth source stays live; only source switches exist today, and they never leave two voice synths live-and-fading, so the memory area's cutting-set bound (`memory.scd:501-503`) was never stated for it.
- `docs/notes/engine/memory.md:104` says a `Pluck` "takes its memory when it first runs (the next block)"; in SC it allocates in its constructor (`Pluck_Ctor`, `DelayUGens.cpp:5575-5581`). The measurement waits past both, so no figure changes.
- `ROADMAP.md` names a wavetable voice without saying where tables come from: built-in tables cost RAM only (128 KB for 8), but tables from user files are a loading path the engine does not have (`docs/notes/engine/files.md` covers slots only).

## Unsure

- **No device figure.** Every KB figure is scsynth's own allocation and matches across 3.13 and 3.14.1 where both were run (3.13 in Docker, `memtypes`, one run: every figure of section 4's table within one probe step, 17 KB, of 3.14.1's; high synth -> buffer -> synth 3817, 3058, 3513, 3244 and 2485 KB, identical; standard pool synth -> buffer -> synth 2428, 1097, 2058, 1485); CPU is this machine only. norns' CM3 (standard tier) and Pi 4 CPU for 7 voices of additive 16 or 32 partials is not measured: #6.
- **The spectral writers' late allocations** in the additive-32 high run: in its eight-recordings case `PV_MagFreeze_next: alloc failed` printed 11 times at 3337 KB free as printed, which no other variant showed; I did not find why (a slower server meeting the flood before the writers' first frame is my guess, unchecked).
- **The figures marked *** have one 256 KB floor probe failing; the true free is about the figure less 256 (one `DelayN_Ctor: alloc failed` line before each), not measured more finely.
- **A release-type switch's 21 voice synths** is an estimate: no such switch exists to measure.
- **Levels**: the prototypes' levels and crossmod output are not matched to the existing voices; the sound check only proves each plays and stays finite.
- SC source lines are from the working tree of `~/src/supercollider` (I could not run git there to pin a tag); `Pluck` and `DelayUnit_AllocDelayLine` read the same in the 3.13 behavior the memory figures show (80.9 KB on both versions).

## Appendix: the prototypes' sources (scratch, uncommitted)

In `lib/engine/StrataVoiceDefs.sc` of the worktree, called at the end of `addVoiceDefs`; the bank in `allocVoiceState` (`lib/engine/StrataVoices.sc`); the Karplus variant is `\strataKarplus` with `maxdelaytime: 0.0839` in both `Pluck`s.

```supercollider
// lib/engine/StrataVoices.sc, allocVoiceState (scratch)
        // SCRATCH: the wavetable prototype's bank, eight consecutive
        // wavetables of 2048 samples (4096 floats each), filled on the
        // server by b_gen sine1 (normalize, wavetable, clear): no sclang loop
        areaState[\voices][\wavetables] = Buffer.allocConsecutive(8, context.server, 4096, 1, { arg buffer, index;
            buffer.sine1Msg([
                [1], [1, 0.5], [1, 0.5, 0.33, 0.25], (1..8).reciprocal, (1..16).collect({ arg k; if (k.odd) { 1 / k } { 0 } }),
                (1..32).reciprocal, (1..12).collect({ arg k; (k - 6).abs.neg.exp }), (1..64).collect({ arg k; k.sqrt.reciprocal })
            ][index], true, true, true)
        });

// lib/engine/StrataVoiceDefs.sc, from the end of addVoiceDefs (scratch)
        // SCRATCH (3.8 fact gathering, never committed): prototype voice types
        this.addScratchVoiceTypeDefs;
    }

    // SCRATCH: the prototype voice types' names, in the order the scratch
    // area measures them
    scratchVoiceTypeNames {
        ^[\strataScratchKarplusShort, \strataScratchWavetable, \strataScratchWavetable3, \strataScratchAdditive8, \strataScratchAdditive16,
            \strataScratchAdditive32, \strataScratchNoise, \strataScratchSaw, \strataScratchFormant]
    }

    // SCRATCH: noteMainValue with a literal range (the prototypes are not in
    // noteMainRanges)
    scratchMainValue { arg value, noteMain, low, high;
        ^(value + (noteMain.lag(this.noteLag) * ((high - low) / 2))).clip(low, high)
    }

    // SCRATCH: an additive voice of n partials: tilt (the expression control,
    // 0-3: each partial k at k ** -tilt), stretch (-1..1: partial k at
    // k ** (1 + 0.05 x stretch)), oddEven (0 odd only, 0.5 all, 1 even
    // only, the fundamental always), drift (the partials' amplitude
    // shimmer rate); partials above 0.45 x SR are muted; odd-index
    // partials left, even-index right, then Balance2
    addScratchAdditive { arg name, n;
        SynthDef(name, {
            arg out, gate=1, freq=110, tilt=1, stretch=0, oddEven=0.5, drift=0.2, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=4, releaseTime=8;
            var env, modulation, modFreq, modAmp, tiltValue, oddLevel, evenLevel, partials, amps, norm, left, right, sig;
            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];
            tiltValue = this.scratchMainValue(tilt, noteMain, 0, 3);
            oddLevel = (2 - (2 * oddEven)).clip(0, 1);
            evenLevel = (2 * oddEven).clip(0, 1);
            partials = (1..n).collect({ arg k;
                var ratio = if (k == 1) { 1 } { k ** (1 + (0.05 * stretch)) };
                var level = if (k == 1) { 1 } { if (k.odd) { oddLevel } { evenLevel } };
                var partialFreq = modFreq * ratio;
                var a = (k ** tiltValue.neg) * level * (partialFreq < (SampleRate.ir * 0.45))
                    * LFNoise1.kr(drift * (0.5 + (k * 0.037))).range(0.5, 1);
                [SinOsc.ar(partialFreq, 0, a), a]
            });
            amps = partials.collect(_[1]);
            norm = amps.sum.max(0.001).reciprocal;
            left = partials.select({ arg p, i; i.even }).collect(_[0]).sum;
            right = partials.select({ arg p, i; i.odd }).collect(_[0]).sum;
            sig = Balance2.ar(left * norm, right * norm, pan);
            Out.ar(out, sig * env * modAmp);
        }).add;
    }

    addScratchVoiceTypeDefs {
        var tables = areaState[\voices][\wavetables], base = tables[0].bufnum, count = tables.size;

        // SCRATCH: a wavetable voice, VOsc over the bank (count consecutive
        // wavetables): morph (0-1, the expression control) picks the place
        // in the bank, wandered by an LFO (morphRate, morphDepth) and the
        // amplitude crossmod; two oscillators detuned for width
        SynthDef(\strataScratchWavetable, {
            arg out, gate=1, freq=110, morph=0.3, morphRate=0.05, morphDepth=0.2, detune=0.003, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var env, modulation, modSig, modFreq, modAmp, position, sig;
            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];
            position = (this.scratchMainValue(morph, noteMain, 0, 1) + (LFNoise1.kr(morphRate) * morphDepth) + (modSig * 0.2)).clip(0, 1);
            sig = VOsc.ar(base + (position * (count - 1.001)), modFreq * [1, 1 + detune]);
            sig = Balance2.ar(sig[0], sig[1], pan);
            Out.ar(out, sig * env * modAmp * 0.5);
        }).add;

        // SCRATCH: the same with VOsc3 (three detuned oscillators a channel)
        SynthDef(\strataScratchWavetable3, {
            arg out, gate=1, freq=110, morph=0.3, morphRate=0.05, morphDepth=0.2, detune=0.003, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var env, modulation, modSig, modFreq, modAmp, position, sig;
            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];
            position = (this.scratchMainValue(morph, noteMain, 0, 1) + (LFNoise1.kr(morphRate) * morphDepth) + (modSig * 0.2)).clip(0, 1);
            sig = [1, -1].collect({ arg side;
                VOsc3.ar(base + (position * (count - 1.001)), modFreq, modFreq * (1 + (detune * side)), modFreq * (1 + (2 * detune * side)))
            });
            sig = Balance2.ar(sig[0], sig[1], pan);
            Out.ar(out, sig * env * modAmp * 0.3);
        }).add;

        // (the Karplus variant: \strataKarplus's text with both maxdelaytime: 0.0839, omitted)
        this.addScratchAdditive(\strataScratchAdditive8, 8);
        this.addScratchAdditive(\strataScratchAdditive16, 16);
        this.addScratchAdditive(\strataScratchAdditive32, 32);

        // SCRATCH: a noise or texture voice: pink noise and dust (grit, at
        // density a second, per channel) through a lowpass (color) and a
        // resonant bank of four Resonz at freq x spread ** k (q, the
        // expression control), the bank mixed with the plain noise (body)
        SynthDef(\strataScratchNoise, {
            arg out, gate=1, freq=200, color=0.5, density=8, grit=0.3, q=0.05, spread=1.5, body=0.7, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var env, modulation, modFreq, modAmp, rq, source, bank, sig;
            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];
            rq = this.scratchMainValue(q, noteMain, 0.005, 1);
            source = (PinkNoise.ar([1, 1]) * (1 - grit)) + (Dust2.ar([density, density * 1.1]) * grit * 4);
            source = LPF.ar(source, color.linexp(0, 1, 200, 16000));
            bank = [1, 0.6, 0.4, 0.25].collect({ arg level, k;
                Resonz.ar(source, (modFreq * (spread ** k)).min(SampleRate.ir * 0.45), rq, level)
            }).sum * rq.reciprocal.sqrt * LFNoise1.kr(0.1).range(0.6, 1);
            sig = (bank * body) + (source * (1 - body) * 0.3);
            sig = Balance2.ar(sig[0], sig[1], pan);
            Out.ar(out, sig * env * modAmp);
        }).add;

        // SCRATCH: a detuned saw pad: three VarSaws a channel through a
        // wandering RLPF (width, the expression control; detune, cutoff, res)
        SynthDef(\strataScratchSaw, {
            arg out, gate=1, freq=110, width=0.5, detune=0.004, cutoff=1500, res=0.3, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var env, modulation, modFreq, modAmp, w, sig;
            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];
            w = this.scratchMainValue(width, noteMain, 0.05, 0.95);
            sig = [1, -1].collect({ arg side;
                [0, 1, 2].collect({ arg k; VarSaw.ar(modFreq * (1 + (detune * side * k)), 0, w) }).sum * 0.33
            });
            sig = RLPF.ar(sig, (cutoff * LFNoise1.kr(0.1).range(0.5, 2)).clip(100, 8000), 1.1 - res.clip(0.1, 1));
            sig = Balance2.ar(sig[0], sig[1], pan);
            Out.ar(out, sig * env * modAmp * 0.5);
        }).add;

        // SCRATCH: a vowel voice: two Formant UGens a channel at formant
        // frequencies that move between vowels (vowel, the expression
        // control, 0-1), bandwidth bw
        SynthDef(\strataScratchFormant, {
            arg out, gate=1, freq=110, vowel=0.5, bw=0.5, wander=0.1, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var env, modulation, modFreq, modAmp, v, f1, f2, sig;
            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];
            v = (this.scratchMainValue(vowel, noteMain, 0, 1) + (LFNoise1.kr(wander) * 0.2)).clip(0, 1);
            f1 = v.linexp(0, 1, 300, 800);
            f2 = v.linexp(0, 1, 2300, 1100);
            sig = [1, 1.003].collect({ arg detuneRatio;
                (Formant.ar(modFreq * detuneRatio, f1, f1 * bw) + (Formant.ar(modFreq * detuneRatio, f2, f2 * bw) * 0.5)) * 0.5
            });
            sig = Balance2.ar(sig[0], sig[1], pan);
            Out.ar(out, sig * env * modAmp);
        }).add;
    }
}
```
