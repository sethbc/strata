# Strata roadmap

The order and scope of the releases from 3.1 to 3.8 and 4.0. 3.1 to 3.4 have shipped (Shipped, below); **3.5, polyphony and MPE, is next.** `docs/status.md` has the open items.

Date: 2026-11-07
Status: brainstorm, reviewed 2026-11-07; cross-release decisions added 2026-11-08 (see "Cross-release decisions (2026-11-08)"). Added 2026-11-11, at the maintainer's request: releases 3.7 (rhythm) and 3.8 (sound), with fourteen features from a review of four hardware granular instruments, and in 3.6 the iii scripts and program change. It sets the order and scope of the releases after 3.0.2. It is not a build plan: each release gets its own design document (like `docs/design/3.0-design.md`) and an implementation plan before any code is written.
Builds on: Strata 3.0.2, the UI review of 2026-11-07 (summarized in the 3.1 section, since removed) and a survey of other norns granular scripts (glut, angl, mangl, rangl, twine, twins, granchild, grains, graintopia, silos, haze, Pappus, oooooo, barcode, amen, cheat codes 2, sam).

## Intent

The goal is for Strata to be the most complete granular script on norns. Strata is already alone in combining seven synth voices, cross-modulation, scenes with a sequencer, and grid and arc. It is behind in three places:
- **Reach.** Much of it can't be played from the norns alone. Stopping voices, scenes and patterns need a grid, and the small grids get much less than the 256.
- **Live and sampled audio in performance.** Other scripts have freeze, reverse grains, loop regions, overdub, resampling, grid rows that set the play position, and arc scrub gestures.
- **Expression.** There are no chords and no MPE.

The development norns is a shield with a Raspberry Pi 4 (8 GB). 3.0.2 has run on it, without detailed measurements: everything runs and there is plenty of headroom. A CM3 norns must keep working.

## Goals

1. 3.1: everything playable from the norns alone, with grid and arc as accelerators. The small grids catch up with the 256.
2. 3.2: a hardware performance setting, and a deeper grain engine with real freeze, reverse grains, per-grain variation, scales, loop regions and live-input history.
3. 3.3: buffers as instruments. Overdub, resampling, waveforms, play-position grids and arc gestures.
4. 3.4: modulation and sequencing. Scene morphing, macros, more and faster LFOs, gesture recorders and a deeper step sequencer.
5. 3.5: polyphony inside each voice, and MPE for the LinnStrument (128 and 200), Osmose and Exquis.
6. 3.6: integration. crow, Just Friends and other ii (i2c) devices reached through crow, MIDI out, transport, OSC, dedicated controller layouts, and iii scripts for grids and arcs that run them.
7. 3.7: rhythm (added 2026-11-11). Sample slices, buffers that follow the tempo and carry a key, scan modes, trig conditions, pattern directions, scene chains with chance, a synced delay, and envelope and random-sequence modulators.
8. 3.8: sound (added 2026-11-11). More voice types, a deeper grain (a continuous window, grain probability, a grain arpeggiator, constant overlap), voices that grain each other, an input channel per voice, microtuning with a scale editor, shimmer, a delay freeze and per-voice sound presets.
9. 4.0: a full code review of the whole project once 3.8 is out (a pre-4.0 release), then 4.0 with its fixes and a set of factory presets.

## Non-goals

- More than seven voices, or voice banks. "More voices" means polyphony inside each voice (decided 2026-11-07). Banks of 14 voices were the rejected alternative and could come back after 3.5.
- Using softcut as a grain source. SuperCollider can't read softcut's buffers. softcut may appear in 3.6 as an output layer, never as a source.
- Replacing norns' own CC learn, PSET or TAPE.

## Anti-goals

- Breaking a CM3 norns. Every feature works on the standard tier, perhaps with smaller limits, and the default `auto` setting never picks the high tier on a CM3 or a Pi 3.
- Making old scenes unloadable. Every release that adds scene fields bumps `SCENE_DATA_VERSION` with defaults that sound like the previous release.
- Changing what a grid row means on a layout that already has it, unless a release says so and the README is updated in the same change.
- Hiding state. Anything that changes the sound shows on the screen with its unit.

## Constraints (all releases)

- Everything in AGENTS.md still applies: Lua and engine in sync, the command table, named constants, `send_param_to_engine`, replace-never-stack, the tests and the docs check.
- **scsynth's real-time pool is 8192 KB on every norns, Pi 4 included, whatever the board's RAM.** It is a fixed area scsynth reserves at boot for the delay lines and tables of running synths. norns' `Crone.sc` boots the server with `memSize` at SuperCollider's default (8192 KB), and a script can't change it: the server is already running when the script starts. When it runs out, a UGen silently outputs zeros, so a voice goes quiet with nothing on screen. A user can raise it on their own norns by editing `Crone.sc`, but a norns update undoes that and other users don't have it, so Strata must fit in 8192 KB. Buffers (`b_alloc`) are not in that pool: they come from ordinary RAM, where the development Pi 4 has 8 GB.
- **scsynth is single-threaded.** A Pi 4 has about twice a CM3's per-core speed, not four times.
- **Lua's 200-local limit.** `strata.lua` is 5063 lines and its main chunk uses 184 locals. 3.1 started by splitting it into modules.
- **CI** compiles the engine against norns' `sc/core` without sc3-plugins. Any UGen from sc3-plugins (JPverb, Greyhole, ...) means adding sc3-plugins to CI and checking that norns ships the same version.
- matron polls carry one float, so any engine-to-Lua data stream (meters, playheads, waveforms) must be encoded as `bufferState` is, or written to a file.

## Order and why

| Release | Theme | Touches | Risk |
|---|---|---|---|
| 3.1 | Playable from the norns alone | Lua only (plus a module split) | Low |
| 3.2 | Performance setting, one grain path | Engine rework, Lua | High |
| 3.3 | Buffers as instruments | Engine and Lua | Medium |
| 3.4 | Modulation and sequencing | Mostly Lua, some engine | Medium |
| 3.5 | Polyphony and MPE | Engine and Lua | High |
| 3.6 | Integration | Mostly Lua | Low to medium |
| 3.7 | Rhythm: slices, tempo-aware buffers, scan modes, sequencer and scene-chain depth, modulators | Engine and Lua | Medium |
| 3.8 | Sound: voice types, a deeper grain, voice-to-voice graining, microtuning, shimmer, voice presets | Engine and Lua | Medium to high |
| pre-4.0 | Full code review of the whole project | Everything (review fixes only) | Low to medium |
| 4.0 | Release of the reviewed code | Everything | Low |

- 3.1 comes first. Every later release adds controls, and 3.1's page model is what gives them room. It needs no engine work.
- 3.2's grain-engine rework comes before 3.3 and 3.5. Freeing memory per voice makes polyphony affordable, and the unified grain path gives buffer, input and synth voices the same features.
- 3.3 comes before 3.4 (2026-11-08): 3.4 builds on 3.3's scene version, its bookmarks and its per-voice mix stage. The brainstorm's "3.4 can move ahead of 3.3" no longer holds.
- 3.7 and 3.8 (added 2026-11-11) come after 3.6: slices and trig conditions build on 3.4's sequencer and 3.3's positions, and new voice types, microtuning and voice presets on 3.5's note allocation, so neither is designed before those have shipped. Each gets its own design first, like every release.
- The full review comes last, after 3.8, when every planned feature is in, so it reviews the code 4.0 ships.

## Development approach (all releases)

The code and documents are restructured for agent-driven development, and every release is planned to run as parallel as possible (decided 2026-11-07). In practice:
- **The restructure is done.** 3.1 split the script into modules with registries, one file per page, grid layout and arc page, with tests and notes per module, changelog fragments and engine checks on a configurable port; 3.2 did the same for the engine (class-extension files under lib/engine/, one check area and notes file each). AGENTS.md describes the result and `docs/workflow.md` how packages run through agents.
- **Every release design ends with work packages.** Each lists the files it owns, the interfaces it depends on, its tests, and which packages run at the same time, grouped in waves.
- **Releases can overlap.** Once 3.1's restructure is merged, Lua-only work in a later release (for example 3.4's sequencer or 3.6's controller layouts) can run alongside engine work in another, because they touch different files.

---

## Shipped: 3.1 to 3.4

| Release | Theme | Design | Shipped |
|---|---|---|---|
| 3.1 | Playable from the norns alone | `docs/design/3.1-design.md` | 3.1.0, 2026-11-07 |
| 3.2 | Performance setting, one grain path | `docs/design/3.2-design.md` | 3.2.0, 2026-11-09 |
| 3.3 | Buffers as instruments | `docs/design/3.3-design.md` | 3.3.0, 2026-11-11 |
| 3.4 | Modulation and sequencing | `docs/design/3.4-design.md` | 3.4.0, 2026-11-12 |

Their sections of this roadmap were removed on 2026-11-12: each release's design replaced its section, CHANGELOG.md and `docs/history.md` say what shipped, and git history keeps the text (the file was docs/design/3.1-3.6-roadmap.md until then). A release that ships moves from its section below to this table.

---

## 3.5: Polyphony and MPE

### Decided

Each of the seven voices plays several notes at once on its own synth (decided 2026-11-07). A chord on a LinnStrument sounds on one voice, each note with its own pitch, pressure and slide.

### Engine

- **Synth voices:** one voice synth per note, all writing the voice's bus. One grain stage per voice processes the chord, cheap because the grain stage doesn't multiply. The crossmod synth keeps reading the voice bus.
- **Buffer and input voices:** one grain stream per note, each with its own rate (pitch), affordable after 3.2's memory savings.
- **Built on 3.3 and 3.4** (cross-release decisions, 2026-11-08): every note's grain stream feeds its voice's one per-voice mix stage (3.3), so filter and sends never multiply with notes. Per-note expression goes on 3.4's fast-modulation bus: 3.5 raises its note slots from one to the tier's note limit and writes pressure and slide into each note's block (pitch, position, size and amp per note); the cutoff stays per voice, because the filter is (the 3.5 design decides what MPE on cutoff means). Voice-wide engine LFOs and scatter keep acting on the whole voice; how they reach every note slot is 3.5's choice, inside 3.4's addressing.
- Note limits by tier: for example 2 on standard and 6 on high, measured in the 3.5 engine check against the worst case (seven voices, full chords, switching).
- Voice stealing: oldest note first, with a short kill fade, never stacking (the replace-never-stack rule extends to notes).
- `voiceOn`/`voiceOff` gain note-level commands (`noteOn`, `noteOff`, `noteParam` for per-note bend, pressure and slide). This is a large command-table change, designed with the sync check.

### MIDI and MPE

- **MPE zones:** lower or upper zone, a master channel and member channels. Per-note pitchbend range (48 semitones default), pressure (channel pressure on the member channel), slide (CC74). Global messages on the master channel.
- **14-bit and high resolution:** the Osmose's MPE+ and 14-bit CC74 if available.
- **Note to voice assignment** (decided 2026-11-07): two MPE modes, plus the existing ones.
  - **Selected voice (default):** every note goes to the selected voice.
  - **Split zones:** keyboard zones, each playing one voice (natural on the LinnStrument's split). The 3.5 design decides how zones are set: note ranges on SETUP, or learned by playing the lowest and highest note of each zone.
  - The existing channel-per-voice and omni modes stay for non-MPE controllers.
- **Expression mapping,** per voice: pressure and slide each drive a chosen target (amp, brightness or main param, grain size, grain density, position, filter cutoff) with a depth. Defaults for the target MPE controllers: pressure to amp, slide to the main param.
- **Pattern steps** and the sequencer's notes (3.4) play through the same note allocation. 3.4 already stores each step's notes as a list, so 3.5's chords need no format change: Strata's `voices` step output (3.4) plays the whole list, and SEQ and the step editor gain chord editing.
- **MPE pressure and slide** register as 3.4 modulation sources, so MOD shows them with no MOD change.

### UI

- MAIN's voice list shows the held note count per voice.
- VOICE gets a "notes" section: limit, stealing, expression mapping.
- SETUP gets the MPE settings.
- An arc page shows per-note pressure as ring segments, a stretch goal.

---

## 3.6: Integration

### crow

- **Inputs:** two CV inputs as modulation sources (LFO-style destinations with depth) or as triggers (retrigger a voice, advance the scene sequencer, freeze, record). Each registers as a 3.4 modulation source, so 3.4's modulation matrix routes it to any destination with a depth, with no matrix change.
- **Outputs:** four outputs, each assignable to an LFO, a voice envelope follower, pattern gates of a voice, the clock, or a macro. LFOs and macros are read through the 3.4 modulation source registry; pattern gates come from a step output.
- A CROW section on SETUP or its own page.

### ii devices (through crow)

crow, Just Friends, W/, ER-301, TELEXo, Teletype and the Disting NT are all in scope.

- **Just Friends:** pattern steps and MIDI notes also play JF voices (synthesis mode), polyphony mapped to JF's six voices. JF's geode mode can follow the pattern clock. The pattern side is one 3.4 step output; its events carry the step's whole chord.
- **W/:** synth mode played like JF (another step output), and tape mode as an external loop recorder (record and play controlled from Strata's scenes and keys).
- **ER-301:** pattern triggers and CV (`SC.TR`/`SC.CV` ports), for example to fire ER-301 sample players in step with Strata.
- **TELEXo:** gates, CVs and envelopes per voice (`TO.TR`, `TO.CV`, `TO.ENV`), for example one TXo output per Strata voice following its level or its pattern.
- **Disting NT:** notes and parameter changes over i2c (if its i2c follower support covers what Strata needs, otherwise over USB MIDI, which norns can also drive).
- **Teletype:** the other direction. Teletype addresses crow as an ii follower (`CROW.*` ops), and crow can pass those messages on to norns, so Teletype scripts could recall scenes, start voices, freeze or retrigger in Strata.
- **Faderpunk and Faderbank** (added 2026-11-11, #555; Controllers, below): where a fader controller offers i2c (which of them does, and how, is to be checked in the 3.6 design), its faders can reach Strata over this bus, through crow, as well as over USB MIDI. How it shares the bus with crow and Teletype is part of the bus-leadership question below.

**ii bus leadership** is the main open question for the 3.6 design. Strata's ii output needs crow to lead the bus, and Teletype normally leads it too. Two leaders on one bus can collide. Options: Strata leads and Teletype only talks to crow; Teletype leads and Strata's ii output goes through Teletype; or a setting that picks one. The design must test the chosen arrangement on a case with crow, Teletype and the ii followers above.

### MIDI out

- Pattern steps and their notes (3.4, chords from 3.5) as MIDI notes on a chosen port and channel per voice: one 3.4 step output, with its own note-off clock.
- LFOs and macros as CC out, read through the 3.4 modulation source registry.
- **Program change recalls a scene** (added 2026-11-11): an incoming program change 1-16 recalls that scene, through 3.4's quantized actions, on the MIDI input Strata already listens to. A setting turns it off, and the 3.6 design decides whether Strata also sends one when a scene is recalled.
- Transport following moved to 3.4 (decided 2026-11-08, cross-release decision 6): patterns already start and stop with norns' clock transport. 3.6 adds only MIDI out; whether Strata should also lead the transport (its play key starting the clock) is open (3.4's Question 26 recommends follow only).

### Controllers

- **OXI E16:** a built-in layout for its 16 encoders, used as a second arc, and mapping one to one onto 3.4's 16 macros (cross-release decision 7), its rings reading each macro's modulation source: the encoders follow the screen page, and the LED rings show each value if the E16 accepts ring feedback over MIDI (to be checked in the 3.6 design; otherwise it sends only). Encoders send relative changes if the E16 supports that, so values never jump.
- **Faderpunk and Faderbank (including the Faderbank 16nx)** (added 2026-11-11, #555): fader controllers. Like the E16's encoders, their faders map one to one onto 3.4's 16 macros (cross-release decision 7), as many as a device has (its fader count is to be checked in the 3.6 design); following the screen page instead, as the grid's fader pages do, is an alternative the 3.6 design decides. Each connects over USB MIDI, and over i2c through crow where the device offers it (ii devices, above, and its bus-leadership question). Feedback: whatever the device can show, to be checked in the 3.6 design. Without one, Strata degrades gracefully, as it does without a grid, an arc or a MIDI device. Anything else about the devices is to be checked in the 3.6 design.
- **OXI One:** as a sequencer driving Strata over MIDI. Its tracks map to the channel-per-voice mode (one track per voice), its polyphonic tracks to 3.5's note allocation, its CCs through PARAMS > MAP or a preset mapping, and its clock through norns' MIDI clock. Strata's own MIDI out (above) can also feed the OXI One.
- **midigrid:** the Launchpad (and other MIDI grids) as a grid through the midigrid library. A Launchpad is 8×8 (plus side buttons), so it gets the 64 layout from 3.1, using the side buttons for the page and step-half controls where present.
- **iii scripts for the grid and the arc** (added 2026-11-11): grids from 2022 on and the 2025 arc can run monome's iii (https://monome.org/docs/iii), Lua scripts on the device itself. A device in iii mode is a USB MIDI device to norns, not a grid or an arc, so Strata's layouts and rings never reach it. 3.6 ships Strata's own iii scripts, one for the grid and one for the arc, so a device kept in iii mode still plays Strata.
  - They live in the repository apart from the norns script: they are uploaded to the device with monome's `diii` and never loaded by norns.
  - Each script draws its own LEDs and talks to Strata over USB MIDI: keys and ring turns go to Strata, and Strata's state comes back for the LEDs through MIDI out (above).
  - The 3.6 design decides: the messages in both directions; whether the scripts mirror today's grid pages and arc rings or are simpler surfaces of their own; which grid sizes iii runs on and how each maps; how Strata recognizes the device (a controller layout picked on SETUP, as for the E16); how the scripts are tested off the device (iii's functions stubbed, as norns' are); and how they keep up with iii, which is short of version 1.0 and may still change.
  - A grid or arc in monome's usual mode keeps working as it does today.
- **TouchOSC / OSC:** an OSC address for every param, and a published layout.

### Other

- **nb:** pattern steps can play an nb voice (another script's voice mod), for layering Strata's sequencer with other synths. It is one 3.4 step output. Strata as an nb voice itself is out of scope (its engine can't share).
- **softcut layer:** an optional softcut tape loop of Strata's output with degradation (oooooo style). It runs on norns' separate softcut DSP, at no scsynth cost.

## 3.7: Rhythm

Added 2026-11-11, at the maintainer's request. It makes rhythmic material playable: 3.3 made buffers instruments and 3.4 deepens the sequencer, and this joins the two. It gets its own design before code.

### Slices

- A buffer is cut into slices, by its transients or into equal parts, and a step, a grid key or a MIDI note plays slice N. Slices sit beside 3.3's four bookmarks per voice (a bookmark is a place the player chose; slices cover the whole buffer) and reuse its positions: a slice is a start and, with 3.4's gates, a length.
- 3.4's step attributes gain a slice (as they have `pos` and `bookmark`), so a pattern can rearrange a loop.
- The design decides: how transients are found (in sclang at load, inside #131's limits on allocation, or on the server); how many slices a slot holds; how they are stored (with the slot, in `buffers.data`) and drawn on BUFFER's waveform; how the position grids show them.

### Buffers that follow the tempo

- A scan measured in beats or in seconds. Today `bufScan` moves in lengths of the valid region per second, so a 300 s slot scans 300 s a second at scan 1 (the candidate `docs/status.md` has carried since 3.3); loop regions are the answer until this ships.
- A slot can carry a tempo (set by hand, or from its length as a count of bars), so its loop region, its slices and its scan line up with the clock, and a loop recorded at one tempo follows a tempo change by its grain rate or by its scan, the design choosing which.

### Trig conditions

- Elektron-style conditions on a step, beside 3.4's probability: play on the A-th of every B passes, only on the first pass, only when the previous step with a condition played or did not, and a fill condition held from a key. 3.4 lists them as a non-goal; they come once its probability and chaining have been lived with.
- They are step attributes in 3.4's format (sparse, validated, in scenes and the chain), drawn and edited on SEQ's edit view and the step editor.

The six items below were added on 2026-11-11 from a review of four hardware granular instruments (Tasty Chips' GR-1, GR-MEGA and GR-2, Torso's S-4), at the maintainer's request.

### Scan modes

- A voice's scan wraps today: at the end of its loop region it starts again. Two more modes: **bounce** (it turns round at each edge) and **one shot** (it stops at the edge until the next step, note or jump restarts it).
- One option per voice beside `buf_scan`, and a change to the engine's scan phase; no real-time memory. The playheads follow the same rule (3.3's estimate mirrors the engine's scan).

### A buffer's key and level

- **Tuning:** a slot carries the note its sample is in (set by hand, or by playing the matching note), so step notes, MIDI notes and scale quantize treat it as that note. Today every buffer is taken to be at the root note at rate 1.
- **Normalize:** a slot's level can be evened out from the peaks 3.3 already computes, as a gain at playback, never by rewriting the audio (3.3 left editing audio out, and that stands).
- The design decides where the two live (with the slot, in `buffers.data`) and how BUFFER shows them.

### Pattern directions

- A voice's steps can play forward (today), in reverse, ping-pong or in random order, with an optional chance of a misstep (a drunk walk). One option per voice in 3.4's `seq` record; the chain and each voice's length keep their meaning.

### Scene chains with chance

- The scene sequencer plays its scenes in order today. A rule per sequence picks the next scene instead: the next, the previous, a walk either way or any at random, each with a chance, so a set of scenes becomes a generative form. 3.4's pattern chain can take the same rule.

### A delay on the beat

- The delay's time as a division of the tempo (it is in seconds today), following tempo changes as the clocked LFOs do, and a ping-pong mode that alternates its repeats left and right. The sync is Lua's; ping-pong is a change to the delay SynthDef, measured against its memory first.

### Envelope and random-sequence modulators

- Two kinds of modulation source for 3.4's registry and matrix: an **envelope** (attack and decay, or ADSR, with a curve and an optional loop) fired by a voice's steps and MIDI notes, and a **random sequence** of N values that repeats and can drift, a pattern where 3.4's sample-and-hold is new at every cycle.
- They register like every 3.4 source, so MOD lists them unchanged. An envelope on a fast destination must run in the engine, as an LFO there does, as a persistent node a step re-triggers: a step never creates one.

## 3.8: Sound

Added 2026-11-11, at the maintainer's request. It widens what a voice can be. It gets its own design before code, and that design starts from the real-time memory left after 3.5.

### More voice types

- Each of the seven voices has one fixed synth today (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring). This release lets a voice choose its type, and adds types to choose from: a wavetable voice, an additive voice and a noise or texture voice are the candidates `docs/history.md` has listed since 1.0.
- Seven voices stay seven (the non-goal above stands): this is a choice per voice, not more voices.
- The design decides: which types; how a voice's params, its MAIN param, its scenes and its PSETs follow a type change (a scene made with one type recalled on another); what each new SynthDef costs in real-time memory against 3.5's notes per voice; whether old scenes need a migration (each voice's type defaults to today's).

### Microtuning and a scale editor

- Scales other than twelve equal steps: a tuning loaded from a Scala file or picked from a built-in list, applied wherever Strata turns a note into a frequency or a rate: 3.2's scale quantize, 3.4's step notes, MIDI notes and 3.5's note allocation and MPE.
- **A scale editor** (added 2026-11-11, from the hardware review): toggle each of the twelve pitch classes to make a scale of your own, beside the built-in list. The engine's `setScale` already takes any 12-bit set, so this is a screen and a stored mask.
- The design decides: one tuning for the script or one per voice; how a tuning meets the engine's quantize (`setScale` sends a 12-bit mask today); where its file lives and how PSETs and scenes name it.

### Shimmer

- Pitch-shifted feedback in the reverb or the delay, the rising or falling halo ambient music leans on.
- It costs real-time memory (a pitch shifter is a delay line), so the design measures first on the standard tier, and may offer it on the high tier only, as the FDN reverb and spectral freeze are.

### Voice presets

- Save one voice's sound (its type, synth, grain, filter and send values) to a file and load it into any voice, and copy a voice's sound to another voice. Scenes store all seven voices at once and the grid's copy and paste covers patterns only, so there is no way today to keep or move a single voice's sound.
- The design decides: what a preset holds and leaves out (the source and its buffer, the pattern, the lock); where the files live; the keys on VOICE and the grids.

The seven items below, and the scale editor above, were added on 2026-11-11 from the same review of the GR-1, GR-MEGA, GR-2 and S-4.

### A deeper grain

- **A continuous grain window.** The five fixed envelope shapes become points on a continuous control (from percussive to swelling, with a skew), so an LFO, a macro or a routing can move the grain's shape. It is a finer bank of envelope buffers picked per grain, as the engine picks one of five today; the design sizes the bank against the buffer memory.
- **Grain probability.** A chance for each grain to sound, for sparse and uneven clouds: one more per-grain draw, on the grain trigger, like 3.2's variation draws.
- **A grain arpeggiator.** A voice's grain intervals are drawn at random today. An order (up, down, up and down, shuffled) steps the grains through the set in turn, and, after 3.5, through a held chord.
- **Constant overlap.** A mode in which grain size and density move together, so one control changes the grain's length while the cloud keeps its thickness. Lua couples two params the engine already has.

### Voices that grain each other

- A voice's grain stage can read another voice's live sound, as it reads its own synth or the input today, so voices chain: one voice's output becomes the next one's material.
- Every voice already writes a ring; the work is in the engine's ring readers (which ring a grain synth reads, freeze, and the rule that a ring is written only by its own writer) and in what a loop of voices reading each other does. The design measures the memory of a second reader per ring first.

### An input channel per voice

- An input voice picks the left channel, the right channel or both, so two mono sources (a guitar and a microphone, say) feed different voices. Today every input voice reads the one stereo input ring; a channel choice is a control on the grain synth's read.

### Delay freeze and clear

- **Freeze** holds what is in the delay as a loop (its feedback at one and its input closed) until released, as a drone to play over; **clear** empties it at once. Both are controls on the delay SynthDef, with a key on FX and the grids. A reverb freeze is possible only in the high tier's reverb and is the design's to weigh.

## pre-4.0 and 4.0: full review, then release

Added 2026-11-08. After 3.8 ships (3.6, until 3.7 and 3.8 were added on 2026-11-11), the whole project gets one full code review before 4.0, as 3.0.2 did for 3.0.1:
- **Scope.** All of it: the Lua script and its modules, the engine and its areas, the tests and checks (the Lua suites, the sync check, the engine check), CI, the user docs and the notes. Correctness first (bugs, broken invariants, races, memory on the standard and high tiers, SuperCollider 3.13 behavior on norns), then dead code, duplication and docs that no longer match the code.
- **Every finding is filed and fixed, whatever its priority.** Each finding gets its own GitHub issue, from a crash to a stale comment, and each issue is fixed in its own pull request, through the usual checks. Nothing is triaged out, deferred to a later release or recorded as "known and accepted, no action": a finding is closed only by a merged fix. A final review of those fixes follows, and everything it finds is filed and fixed the same way, until a review finds nothing.
- **Stricter than 3.0.2.** 3.0.2 followed this pattern (issues #10-#27, then #46-#52, one pull request each, all fixed), but grouped its findings by area into checklist issues and accepted three small ones without a fix (the "Known and accepted, no action" list in `docs/status.md`). pre-4.0 files one issue per finding and accepts none; the items on that list today are among its findings.
- **Releases.** The fixes ship as a pre-4.0 release (or several), so they can be tried on hardware (the checks still open on #6 included) before 4.0. 4.0 is then the reviewed code: no new features unless its own design adds them.
- **Why 4.0.** It marks the end of the 3.x feature line: everything this roadmap planned is in and has been reviewed as a whole.
- **Factory presets** (added 2026-11-11, at the maintainer's request). 4.0 ships content, so a new player hears what Strata can do in the first minute: a set of scenes, the PSET they belong to (with 3.4's side files for macros, routings and recorders) and a few short, freely licensed samples for the buffers.
  - They never touch a player's own data: they load only when asked (a SETUP action), or once on a first run that finds no scenes file, and a player's scenes, PSETs and buffers are never overwritten.
  - The code that installs and loads them is built before the review starts, so the review covers it; the sounds themselves are made and tuned by ear on a norns, on both tiers, up to the release.
  - 4.0's own design decides: how many scenes and which features each shows; where the files live in the repository and on the device; the samples' sources and licenses; how a later release adds to them or replaces them.

---

## Decisions (2026-11-07)

1. **3.2's sound change:** accepted. Synth voices transpose by grain rate, and their grains start a grain length in the past.
2. **3.5 note assignment:** both modes, selected voice as the default (3.5, MIDI and MPE).
3. **3.6 hardware:** crow, Just Friends, W/, ER-301, TELEXo, Teletype, Launchpad, TouchOSC, Disting NT, OXI One, OXI E16, Faderpunk and Faderbank (including the Faderbank 16nx; added 2026-11-11, #555). The E16 takes the place the Midi Fighter Twister had in the brainstorm (no Twister layout is planned).
4. **Pi 4 RAM:** 8 GB, so the high tier offers buffers up to 300 s (the 3.2 section's "Longer buffers", since removed).
5. **After the last feature release** (2026-11-08; 3.6 then, 3.8 since 2026-11-11): a full code review of the whole project as a pre-4.0 release, then 4.0 (see pre-4.0 and 4.0 above). Every finding, whatever its priority, gets its own issue and its own fix; none is deferred or accepted.

## Cross-release decisions (2026-11-08)

Taken by the maintainer from what 3.5 (polyphony and MPE) and 3.6 (integration) need, so neither redesigns 3.3 or 3.4. `docs/design/3.4-design.md` ("Decided 2026-11-08 (cross-release)") holds 3.4's detail; the 3.3 design's amendment holds the first.

1. **3.3's per-voice mix stage.** 3.3's Wave 0 (package 0c) moves the voice filter and the sends out of every grain synth into one per-voice stage after the grains. 3.4's cutoff and amp modulation act on that stage (its `filterFreq` control and `voiceLevel`), and 3.5's notes share their voice's stage.
2. **3.4's fast-modulation bus per note slot.** The engine offset bus is indexed by (voice, note slot, destination), with one note slot per voice in 3.4 (35 channels, where the approved layout had them). 3.5 raises the slot count for per-note pressure and slide without a redesign.
3. **Chord-capable steps.** 3.4's pattern and scene format stores a list of notes per step (up to eight). 3.4's UI edits one note and its voices play the first; 3.5 adds chord editing and plays the whole list, with no format change.
4. **A step output registry.** The sequencer fires each step through outputs registered with `S.register_step_output(...)`; 3.4 registers only Strata's voices, and 3.6 adds MIDI out, Just Friends and W/ over ii and nb as one registration each.
5. **A modulation source registry.** LFOs, macros and gesture recorders register with `S.register_mod_source(...)` (a key, a name, a value and its range) and MOD lists sources generically; 3.5 registers MPE pressure and slide, 3.6 crow CV and MIDI CC.
6. **Transport following in 3.4.** The sequencer follows norns' clock transport (`clock.transport.start` and `stop`), so Link and MIDI clock start and stop Strata, as a SETUP option on by default. 3.6 then only adds MIDI out.
7. **16 macros** in four banks of four, in place of four: MOD, the arc and the grids show one shared bank, the 256's rows 10-13 show it, and scenes store all 16. 3.6's OXI E16 maps its 16 encoders one to one.

## Calls made in this brainstorm (any can be reversed)

- K1 held as ALT, with ALT+E3 as fine adjustment.
- Eight screen pages in 3.1 (VOICE, SEQ and SCENES added; SEQ chosen 2026-11-07). MOD arrives in 3.4.
- Lock and freeze are separate controls; the scene field name `frozen` stays.
- Randomize keeps one level of undo.
- The performance setting is stored outside scenes and PSETs and applies at the next start.
- Buffer waveforms go through a file, not a poll.
- Playheads are estimated in Lua.
- 16 scenes in two banks (3.4).
- Six LFOs and engine-side fast modulation for a fixed set of destinations (3.4).
- 3.4 may swap places with 3.3 (reversed 2026-11-08: 3.4 depends on 3.3).
- Each release still gets its own design document, builder check and plan before code.
