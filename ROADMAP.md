# Strata roadmap

The order and scope of the releases from 3.1 to 3.9 and 4.0. 3.1 to 3.8 have shipped (Shipped, below); **3.9, what 3.8 delays, is next**, then the pre-4.0 review. `docs/status.md` has the open items.

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
9. 3.9: what 3.8 delays (added 2026-11-18). A version number was kept free before 4.0 for this: a feature cut from 3.8 or a finding too large for its last fix wave is built here. Its first part, the state machines made explicit, has landed (2026-11-24); the grid's sequencer reworked comes next, then the high tier's reverb freeze.
10. 4.0: a full code review of the whole project once 3.9 is out (a pre-4.0 release), then 4.0 with its fixes, the hardware check (#6) and the factory presets' sounds.

## Non-goals

- More than seven voices, or voice banks. "More voices" means polyphony inside each voice (decided 2026-11-07). Banks of 14 voices were the rejected alternative and could come back after 3.5.
- Using softcut as a grain source. SuperCollider can't read softcut's buffers. softcut may appear in 3.6 as an output layer, never as a source.
- Replacing norns' own CC learn, PSET or TAPE.

## Anti-goals

- Breaking a CM3 norns. Every feature works on the standard tier, perhaps with smaller limits, and the default `auto` setting never picks the high tier on a CM3 or a Pi 3.
- Making old scenes unloadable. Every release that adds scene fields bumps `SCENE_DATA_VERSION` with defaults that sound like the previous release.
- Changing what a grid row means on a layout that already has it, unless a release says so and the README is updated in the same change.
- Hiding state. Anything that changes the sound shows on the screen with its unit.

*2026-11-15:* before 4.0, the second and third of these no longer limit a design: layouts, menus and storage may change where a release is better for it, and the release says so (the maintainer, during the 3.7 brainstorm; `docs/design/3.7-design.md`, decision 18). A file an older build cannot read is still set aside, never overwritten.

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
| 3.9 | What 3.8 delays: the state machines made explicit (landed), the grid's sequencer reworked, the high tier's reverb freeze | Engine and Lua | Medium |
| pre-4.0 | Full code review of the whole project | Everything (review fixes only) | Low to medium |
| 4.0 | Release of the reviewed code, checked on hardware, with factory sounds | Everything | Low |

- 3.1 comes first. Every later release adds controls, and 3.1's page model is what gives them room. It needs no engine work.
- 3.2's grain-engine rework comes before 3.3 and 3.5. Freeing memory per voice makes polyphony affordable, and the unified grain path gives buffer, input and synth voices the same features.
- 3.3 comes before 3.4 (2026-11-08): 3.4 builds on 3.3's scene version, its bookmarks and its per-voice mix stage. The brainstorm's "3.4 can move ahead of 3.3" no longer holds.
- 3.7 and 3.8 (added 2026-11-11) come after 3.6: slices and trig conditions build on 3.4's sequencer and 3.3's positions, and new voice types, microtuning and voice presets on 3.5's note allocation, so neither is designed before those have shipped. Each gets its own design first, like every release.
- 3.9 (added 2026-11-18) takes what 3.8 delays, so that 3.8 ships at its planned scope less what failed its own conditions and nothing is pushed into the review. Its three parts go in the order the maintainer set on 2026-11-23: the state machines made explicit (landed 2026-11-24), the grid's sequencer, then the reverb freeze.
- The full review comes last, after 3.9, when every planned feature is in, so it reviews the code 4.0 ships. Since 2026-11-16 it is the review alone: everything else once kept for it was moved up to before 3.8 or into 3.8 (the maintainer), and only what needs a norns in hand (#6, the factory sounds) waits for 4.0.

## Development approach (all releases)

The code and documents are restructured for agent-driven development, and every release is planned to run as parallel as possible (decided 2026-11-07). In practice:
- **The restructure is done.** 3.1 split the script into modules with registries, one file per page, grid layout and arc page, with tests and notes per module, changelog fragments and engine checks on a configurable port; 3.2 did the same for the engine (class-extension files under lib/engine/, one check area and notes file each). AGENTS.md describes the result and `docs/workflow.md` how packages run through agents.
- **Every release design ends with work packages.** Each lists the files it owns, the interfaces it depends on, its tests, and which packages run at the same time, grouped in waves.
- **Releases can overlap.** Once 3.1's restructure is merged, Lua-only work in a later release (for example 3.4's sequencer or 3.6's controller layouts) can run alongside engine work in another, because they touch different files.

---

## Shipped: 3.1 to 3.8

| Release | Theme | Design | Shipped |
|---|---|---|---|
| 3.1 | Playable from the norns alone | `docs/design/3.1-design.md` | 3.1.0, 2026-11-07 |
| 3.2 | Performance setting, one grain path | `docs/design/3.2-design.md` | 3.2.0, 2026-11-09 |
| 3.3 | Buffers as instruments | `docs/design/3.3-design.md` | 3.3.0, 2026-11-11 |
| 3.4 | Modulation and sequencing | `docs/design/3.4-design.md` | 3.4.0, 2026-11-12 |
| 3.5 | Polyphony and MPE | `docs/design/3.5-design.md` | 3.5.0, 2026-11-13 |
| 3.6 | Integration | `docs/design/3.6-design.md` | 3.6.0, 2026-11-15 |
| 3.7 | Rhythm | `docs/design/3.7-design.md` | 3.7.0, 2026-11-16 |
| 3.8 | Sound | `docs/design/3.8-design.md` | 3.8.0, 2026-11-18 |

Their sections of this roadmap were removed on 2026-11-12 (3.5's on 2026-11-13, 3.6's on 2026-11-15, 3.7's on 2026-11-16, 3.8's on 2026-11-18): each release's design replaced its section, CHANGELOG.md and `docs/history.md` say what shipped, and git history keeps the text (the file was docs/design/3.1-3.6-roadmap.md until then). A release that ships moves from its section below to this table. The work between 3.7 and 3.8 (done 2026-11-17: the three revisions, `frozen` renamed `locked`, the 256's fader pages for newer params and MIDI note off as latch or release; the fixes of #738-#744 and #747-#754; and the three questions moved up from the pre-4.0 review: an LFO's own destination as a home routing of the matrix, one stepper under the pattern chain and the scene sequencer, the per-voice values as one table with one registration path, and scenes that travel with the PSET) had no release of its own and shipped in 3.8.0; its design is `docs/design/3.8-groundwork-design.md`.

---

## 3.9: what 3.8 delays

Added 2026-11-18 (the maintainer): a version number was left free before 4.0 on purpose, and 3.9 takes whatever 3.8 delays. Each item has its issue on the 3.9 milestone; 3.9 gets its own design first, like every release.

- **The high tier's reverb freeze** (#819). 3.8's package built the design's freeze on the FDN and measured it on SuperCollider 3.13 and 3.14.1: frozen, the tail lost 2.4 to 3.2 dB above 6 kHz in six seconds and stepped by up to 1.24 dB at the freeze, so by the plan's own condition it was cut. The cause is known (an interpolating delay line never lands on a whole sample once its time has moved), and so is what a freeze that holds needs: whole-sample reads on every line while frozen, by a second read of each line (about 144 KB of the real-time pool) or by moving the lines into buffers (that much back to the pool), and taps that keep their interpolation and damping. The FX page and the grids' FX page already reach the freeze through one test (`S.lib.fx_hold.offered`), so they light up when it exists.
- **What 3.8's last review deferred**: nothing. Its findings (#823-#861) were moved to 3.8 and fixed before 3.8.0, at the maintainer's word, so nothing of 3.8's is on the 3.9 milestone but #819; a finding too large for a release's last fix wave still comes here with its issue, never into the pre-4.0 review.
- **The state machines made explicit** (added 2026-11-21, the maintainer; #864-#949). A search of the whole script and engine for the state machines kept without a name found about 110, and filed every finding: 86 issues, from defects in transitions (a freeze key's waiting toggle, the 64's chooser and the positions keys, a key press lost under a covering editor) to states the player cannot see and machines with no table. Its design, `docs/design/3.9-state-machines-design.md`, makes a machine explicit in four forms (one name and one reader, a table a test runs, a seeded walk, a state shown where it changes what a key does), adds no stored state and no engine command, and fixes every issue but #939, which waits for a device. It is 3.9's first part, and it has landed (57 packages in seven waves and about forty more for what the build found, 2026-11-23 to 2026-11-24): every issue #864-#949 is closed but #939, which moves to the 4.0 milestone with #6, and the build's own, #951-#1040, are all closed. Its decisions are in `docs/decisions/3.9.md`.
- **The grid's sequencer, reworked** (added 2026-11-23, the maintainer). A step on the grid did too little: a swell of at most 6 dB on a voice that sounds anyway, keys that only turn a step on and off, nothing to perform with. Its design, `docs/design/3.9-grid-sequencer-design.md`, gives each voice a step mode (a voice with steps pulses by default, or its steps move its position, pitch, size or filter), turns what a step holds into lanes with their own lengths, shown and entered on a second side of the grid's patterns page, and adds a loop, a roll, four variations a voice with an order, and mutes, solo and fill on every grid size. It is built after the state machines work and before the reverb freeze.

## pre-4.0 and 4.0: full review, then release

Added 2026-11-08. After 3.9 ships (3.6, until 3.7 and 3.8 were added on 2026-11-11; 3.8, until 3.9 was added on 2026-11-18), the whole project gets one full code review before 4.0, as 3.0.2 did for 3.0.1:
- **Scope.** All of it: the Lua script and its modules, the engine and its areas, the tests and checks (the Lua suites, the sync check, the engine check), CI, the user docs and the notes. Correctness first (bugs, broken invariants, races, memory on the standard and high tiers, SuperCollider 3.13 behavior on norns), then dead code, duplication and docs that no longer match the code.
- **Every finding is filed and fixed, whatever its priority.** Each finding gets its own GitHub issue, from a crash to a stale comment, and each issue is fixed in its own pull request, through the usual checks. Nothing is triaged out, deferred to a later release or recorded as "known and accepted, no action": a finding is closed only by a merged fix. A final review of those fixes follows, and everything it finds is filed and fixed the same way, until a review finds nothing.
- **Stricter than 3.0.2.** 3.0.2 followed this pattern (issues #10-#27, then #46-#52, one pull request each, all fixed), but grouped its findings by area into checklist issues and accepted three small ones without a fix (the "Known and accepted, no action" list in `docs/status.md`). pre-4.0 files one issue per finding and accepts none; the items on that list today are among its findings.
- **Releases.** The fixes ship as a pre-4.0 release (or several), so they can be tried on hardware (the checks still open on #6 included) before 4.0. 4.0 is then the reviewed code: no new features unless its own design adds them.
- **Why 4.0.** It marks the end of the 3.x feature line: everything this roadmap planned is in and has been reviewed as a whole.
- **The review alone** (2026-11-16): what was kept for it moved up. The two questions added the same day (the 256's layout and an LFO's own destination as a routing) go to 3.8 and to the questions decided before 3.8, the known findings to the fixes before 3.8, and the factory presets' code to 3.8.
- **Factory presets** (added 2026-11-11, at the maintainer's request). 4.0 ships content, so a new player hears what Strata can do in the first minute: a set of scenes, the PSET they belong to (with 3.4's side files for macros, routings and recorders) and a few short, freely licensed samples for the buffers.
  - They never touch a player's own data: they load only when asked (a SETUP action), or once on a first run that finds no scenes file, and a player's scenes, PSETs and buffers are never overwritten.
  - The code that installs and loads them was built in 3.8 (its last package, moved up 2026-11-16; SETUP's `factory sets` row), so the review covers it; the sounds themselves are made and tuned by ear on a norns, on both tiers, up to the release, beside the hardware check (#6).
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
2. **3.4's fast-modulation bus per note slot.** The engine offset bus is indexed by (voice, note slot, destination), with one note slot per voice in 3.4 (35 channels, where the approved layout had them). 3.5 raises the slot count for per-note pressure and slide without a redesign. *Set aside by 3.5 (its design's Question 1, decided 2026-11-12):* per-note values are controls on each note's own synth, set by one `noteExpression` per note, and the bus keeps one slot per voice (`fastModNoteSlots` 1); the addressing stays for a later release that wants per-note engine modulation.
3. **Chord-capable steps.** 3.4's pattern and scene format stores a list of notes per step (up to eight). 3.4's UI edits one note and its voices play the first; 3.5 adds chord editing and plays the whole list, with no format change.
4. **A step output registry.** The sequencer fires each step through outputs registered with `S.register_step_output(...)`; 3.4 registers only Strata's voices, and 3.6 adds MIDI out, Just Friends and W/ over ii and nb as one registration each.
5. **A modulation source registry.** LFOs, macros and gesture recorders register with `S.register_mod_source(...)` (a key, a name, a value and its range) and MOD lists sources generically; 3.5 registers MPE pressure and slide, 3.6 crow CV and MIDI CC.
6. **Transport following in 3.4.** The sequencer follows norns' clock transport (`clock.transport.start` and `stop`), so Link and MIDI clock start and stop Strata, as a SETUP option on by default. 3.6 then only adds MIDI out.
7. **16 macros** in four banks of four, in place of four: MOD, the arc and the grids show one shared bank, the 256's rows 10-13 show it, and scenes store all 16. 3.6's OXI E16 maps its 16 encoders one to one.

## Calls made in this brainstorm (any can be reversed)

- K1 held as ALT, with ALT+E3 as fine adjustment.
- Eight screen pages in 3.1 (VOICE, SEQ and SCENES added; SEQ chosen 2026-11-07). MOD arrives in 3.4.
- Lock and freeze are separate controls; the scene field name `frozen` stays (reversed: `locked` since scene format 9).
- Randomize keeps one level of undo.
- The performance setting is stored outside scenes and PSETs and applies at the next start.
- Buffer waveforms go through a file, not a poll.
- Playheads are estimated in Lua.
- 16 scenes in two banks (3.4).
- Six LFOs and engine-side fast modulation for a fixed set of destinations (3.4).
- 3.4 may swap places with 3.3 (reversed 2026-11-08: 3.4 depends on 3.3).
- Each release still gets its own design document, builder check and plan before code.
