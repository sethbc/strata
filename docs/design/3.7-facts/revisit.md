# Decisions worth revisiting now that compatibility is free

Thirteen candidates, ranked by value for the effort; five fit inside 3.7 (1, 2, 3, 7 and 9).
The three most valuable: make the scan a speed and drop the loops-a-second unit (1); delete the old-format conversions and set a format floor (3); order LFO destinations by voice and store them by key (4).
Candidate 2 costs nothing and unlocks the rest: two lines of the 3.7 plan still treat "sounds like 3.6" as a promise.
Compatibility cost less than feared: most defaults are "off", which is also the best default. The real cost is in a handful of units, lists and names, about 400 lines of conversion code and about 22 tests.
Nothing here is a new feature; each alternative is one the documents name, or the removal of something kept.

## How this was read

Read in full: `docs/design/3.7-design.md`, the plan's Global Constraints, Review Focus and 28 rulings, `ROADMAP.md`, `docs/decisions/README.md`. Searched for compatibility reasoning and then read the hits in place: `docs/decisions/3.0.md` to `3.6.md`, the designs 3.0 to 3.6 and 3.3.2, `docs/history.md`, the notes and the user docs. Checked each candidate against the code (`lib/`, `lib/engine/`, `test/`). Paths are relative to the repository root; "the plan" is `.claude/worktrees/docs-3.7-plan/docs/superpowers/plans/2026-11-15-3.7-plan.md` (a draft of the plan, removed at the 3.7.0 release; its rulings are in `docs/decisions/3.7.md`).

Sizes are counts from `grep` and `wc`, rounded. Nothing was run.

## The candidates

### 1. The scan is a speed; drop `scan_unit`

- **Decided:** `docs/design/3.7-design.md` §2.2, §2.3 and "Calls made": "The scan's unit is an option beside today's, not a replacement: loops a second is useful (a loop once a second whatever its length), and old scenes keep their meaning without a conversion."
- **Instead:** `buf_scan` is a speed, where 1 is the audio's own rate, and nothing else. `scan_unit` and the `scanUnit` grain control are never built.
- **Why it is better:** `buf_scan` defaults to 0 (`lib/voices.lua:41`), so no default sound moves. Loops a second is the unit `docs/status.md` has listed as a defect since 3.3 (a 300 s slot scans 300 s a second at 1). With a region per note it misleads: under loops a second, a voice's slices of different lengths each play at a different speed. "A loop once a second" is what `follow` with a file tempo gives, on the beat. Design §3.6's recipe for a tight sliced loop drops from three settings to two.
- **Cost:** it removes work. 1a loses one control and one branch of the phase rate; 2a loses one option, one VOICE row, one scene field and a branch of `pass_seconds`; the playheads mirror one unit. It adds a re-based positions check (`test/engine_check/positions.scd`, 172 lines, pins 3.2's scan at a non-zero scan) and one decision: whether a frozen ring's scan becomes a speed too (I would, so the param means one thing; the design's non-goal leaves rings alone).
- **When:** 3.7, packages 1a and 2a, before either starts.
- **Recommendation:** revise. It is the one place 3.7 builds a new control only to keep old numbers meaningful.

### 2. Reword the plan's two compatibility constraints

- **Decided:** the design's Anti-goals ("Changing what a 3.6 scene or PSET sounds like"); the plan's Global Constraints, "Off at the defaults" ("A fresh Strata, a 3.6 PSET and a 3.6 scene send the engine exactly what 3.6 sends") and "Equality at the defaults in the engine" ("No such check is loosened or removed"); ruling 6, which gives `slotGrainReader` a trailing optional Event so the check-only copies of 3.2's and 3.3's defs "stay as they are".
- **Reason given:** the anti-goal, written before decision 18 was applied to sound.
- **Instead:** keep both as regression nets and say so: "a new feature is off at its default" and "a check that compares with an earlier release is re-based, in the same commit and named in the report, when a package changes a default on purpose". Ruling 6 becomes the builder's choice.
- **Why:** as written, the two lines forbid candidates 1, 5 and 11 and make every worker treat an accidental promise as a rule. The checks are for the developers (see "Not compatibility" below).
- **Cost:** three sentences in the plan and one in the design. Risk: a worker re-bases a check to hide a real regression; the "named in the report" clause is the guard.
- **When:** now, before Wave 0.
- **Recommendation:** revise.

### 3. Delete the old-format conversions; set a format floor

This is the compatibility machinery that can simply go. What exists:

| What | Where | Size |
|---|---|---|
| 3.3's LFO library import: a scene migration and a PSET hook | `lib/lfos.lua:922-1031` | 110 lines, 4 tests (215 lines) |
| MIDI map repair for 3.3's LFO ids (#602) | `lib/midi_in.lua:511-595` | 85 lines, 3 tests |
| PSET read: the Pulse `res` mirror, the hidden `strata_pset_format` param, `PSET_FORMAT` | `lib/params_setup.lua:225-263, 325-329` | 30 lines, 1 test (75 lines) |
| Scene conversions by version: Pulse mirror, `round_whole_fields`, `migrate_slot_name`, the bare array of before 2.1, `NAMES_FORMAT`, `WHOLE_NUMBERS_FORMAT`, "a format 5 file loads into slots 1-8" | `lib/scenes.lua:262-400, 1123-1137` | 100 lines, 6 tests (220 lines) |
| The `scene_migrations` registry and its two 3.5 fills | `lib/state.lua:388-398`, `lib/expression.lua:526-540`, `lib/notes.lua:732-748` | 50 lines, 4 tests |
| `buffers.data` version 1, and the kept copies `.v<n>` of both files (#467) | `lib/buffers.lua:901-990`, `lib/scenes.lua:1049-1060`, `lib/data_files.lua:390` | 50 lines, 4 tests |

About 400 lines of Lua, about 22 tests (800 lines), and long paragraphs of `docs/notes/lua/scenes.md` (Versions), `params.md`, `midi.md`, `lfos.md` and `docs/user/params.md`.

- **Reason given:** ROADMAP's anti-goal 2. The 3.7 design keeps the habit: "3.7 still migrates old scenes, because a default for a new field is cheap", and `buffers.data` version 3 "still loads 1 and 2".
- **Instead:** one rule. A file of the floor format or later loads, with missing fields filled from defaults (the generic fill in `migrate_scene`, which development needs anyway). Anything older is set aside, as an unknown version is today. The floor is format 7 for scenes and 2 for `buffers.data`. Every conversion keyed on a version goes, with `PSET_FORMAT` and its hidden param.
- **Keep:** the set-aside, the `.part` writes, and #628's rule that a PSET line that is missing means the default. Those are data safety and correctness. The PSET read's whole-number rounding (#554, five lines, two tests) also guards a hand-edited PSET; keep it or drop it.
- **Cost:** the deletions above; the notes voice's per-voice attack and release defaults need a home in the generic fill (the record's `scene_defaults` are voice 1's). In the plan: 2d's test "a version 2 buffers.data loads ... and is kept as .v2" shrinks; 0b's "version 7 migrates to 8" stays (it is the generic fill). Risk: the maintainer's own pre-3.5 files are set aside, not lost.
- **When:** its own small Lua package beside Wave 0. It edits `lib/scenes.lua`, `lib/buffers.lua`, `lib/midi_in.lua` and `lib/params_setup.lua`, which 1f, 2d, 2b and 1d edit later, so it lands first or waits for 3.8.
- **Recommendation:** revise.

### 4. LFO destinations: ordered by voice, stored by key

- **Decided:** `docs/design/3.4-design.md` §2.1 (`strata_lfo<n>_dest`: "the id stays today's, so stored indices keep their meaning") and §2.3 ("The destination list keeps its order: the 68 built-in entries, then the registered ones in registration order"); `docs/decisions/3.4.md` ("`v<i> amp` is registered ... after `rsend`, so the saved indices ... keep their meaning"); `docs/notes/lua/lfos.md:18`.
- **What it costs a player:** the list is in release order. `docs/user/pages/lfo.md` has to explain that voice 3's main param is in the "voice 3" group while its `hist`, `vfilt`, `dsend`, `rsend` and `amp` are each in a later group of seven. The matrix's destination picker inherits the order. Every destination 3.8 registers will append again.
- **Instead:** the list is built by voice (globals, then each voice's destinations together, then macros), and the param stores a key, through 3.6's `S.lib.io_keyed` (`docs/decisions/3.6.md`, plan ruling 24, written for this exact problem). ALT+E3's group jump becomes "next voice".
- **Cost:** `lib/lfos.lua` (the list and the param), `lib/pages/lfo.lua` (the jump), `lib/matrix.lua` (reads the list), the scene field's validation; perhaps 200 lines changed and 20 tests touched across `lfos_test.lua`, `pages_lfo_test.lua` and `matrix_test.lua`. Risk: low; fast destinations are found by param suffix, not by index.
- **When:** its own package before 3.8's design, which adds destinations.
- **Recommendation:** revise.

### 5. The hidden pan wander

- **Decided:** `docs/design/3.2-design.md` §4: "Pan jitter is added to the slow wander, not swapped for it. The roadmap says it replaces the wander. Keeping the wander at its fixed ±0.5 keeps every old scene's stereo image, which the anti-goal requires."
- **What it is:** every grain synth pans its whole output with `LFNoise1.kr(2)` over ±`panSpread` (`lib/engine/StrataGrainDefs.sc:246`). `panSpread` defaults to 0.5 in the SynthDef and no Lua code sends it. It is a sound value the `voices` table does not hold, it is on no screen (`docs/user/voices-and-grains.md` mentions it once, under pan jitter), and a voice's `pan` can never be still. That breaks ROADMAP's standing anti-goal, "Hiding state".
- **Instead:** either the roadmap's own choice (remove it; `pan jitter` is the control), or expose the depth as a per-voice param. Exposing needs no engine change: the control exists.
- **Cost:** exposed, one registered param, a VOICE row and a scene field. Removed, one line in the engine, the same line in the check-only copies of 3.2's and 3.3's defs, and a new default image (static until jitter is raised).
- **When:** with 3.8, the sound release, or as a small package before it.
- **Recommendation:** revise; which of the two is the maintainer's call.

### 6. Rename `frozen` to `locked`

- **Decided:** `docs/decisions/3.1.md`: "Lock is a UI name only: the state, the code and the scene field stay `frozen`, so scenes need no migration."
- **What it costs:** an AGENTS.md invariant, a paragraph of `docs/notes/lua/freeze.md` and a test that scans function names exist only to keep `S.frozen` (the lock) apart from freeze (the audio feature). 3.8 adds a delay freeze.
- **Instead:** `S.locked`, the scene field `locked`.
- **Cost:** mechanical. 122 uses in 23 files under `lib/`, about 300 in tests, about 160 in the notes and user docs. Risk: merge conflicts with any open package.
- **When:** between 3.7 and 3.8, with no package open. With candidate 3's floor raised at the same time, no conversion is needed.
- **Recommendation:** revise, for the code's readers only; a player sees nothing.

### 7. BUFFER's keys

- **Decided:** `docs/design/3.3.2-page-randomize-design.md`, proposal A, and `docs/decisions/3.3.md`: "BUFFER, SCENES and SETUP keep their keys ... If wrong: the gesture is not the same on every page." The 3.7 design's decision 14 then adds a row on which K3 opens an editor "instead of recording", and its "Cost if wrong" expects it to trip people.
- **What it costs a player:** ALT+K2 randomizes on MAIN, VOICE, SEQ, FX, LFO and MOD, the gesture 3.3.2 was written to make a habit. On BUFFER a quick ALT+K2 clears the buffer, and randomize is K2 held.
- **Instead:** on BUFFER, ALT+K2 loads a random file (held: fill the empty slots), and clear moves to where a slip costs less (K2 held, or a row). The slice editor's key can be settled in the same pass.
- **Cost:** `lib/pages/buffer.lua` (1,092 lines; the key handlers and hints only), `docs/user/pages/buffer.md`, perhaps 10 tests of `pages_buffer_test.lua`.
- **When:** 3.7, package 2c, which owns the file.
- **Recommendation:** the maintainer's call. Proposal A was approved for a reason that was partly habit and partly "BUFFER holds files, not parameters".

### 8. The 256's fader pages stop at 3.1's params

- **Decided:** `docs/design/3.2-design.md` §8 and its list of calls: "3.2's new per-voice params stay off the 256 fader pages (`fader = false`), so today's faders don't move." Now a rule in AGENTS.md and `docs/notes/lua/params.md:19`.
- **What it costs:** nothing added since 3.2 has a fader: the voice filter, the sends, the loop, the jitters, attack and release.
- **Instead:** a record sets `fader = true` for its continuous params; row 13 has room for more page keys.
- **Cost:** `lib/grid/faders.lua` (314 lines), `lib/grid/layout_256.lua`'s row 13, the records' one line each, tests in `grid_layout_256_test.lua`.
- **When:** its own small package, or with candidate 13.
- **Recommendation:** the maintainer's call; it depends on how much the 256's faders are played.

### 9. A synced delay leaves the 256's delay fader dead

- **Decided:** the 3.7 design, §6 and "Calls made": "the 256's delay fader stays on `delay_time`", which a synced delay ignores.
- **Reason:** none is written. It may be habit or the package boundary (1d does not own the layout); I cannot tell.
- **Instead:** while synced, the fader picks the division, as FX's `time` row and arc ring 3 do.
- **Cost:** a few lines in `lib/grid/layout_256.lua`, a shared line between 1d and 1e.
- **When:** 3.7, package 1d.
- **Recommendation:** revise if the reason was habit; small either way.

### 10. `midi_note_off`'s `auto`

- **Decided:** `docs/design/3.5-design.md` §5.1: "`midi_note_off` keeps its indices' behavior: index 1, `ignore` until now, is `auto` (latch in the plain modes ... release in the MPE modes) ... So no PSET changes meaning and `PSET_FORMAT` stays 2."
- **What it costs:** a third option whose meaning depends on another param, and `docs/user/midi.md`'s paragraph on what switching modes does to held keys "with auto".
- **Instead:** two values, `latch` and `release`, and one default.
- **Cost:** `lib/midi_in.lua`, a few tests. The open question is the default: `auto` does give each mode a sensible one.
- **When:** before 3.8.
- **Recommendation:** the maintainer's call; low value.

### 11. Sends as plain send and return

- **Decided:** `docs/design/3.2-design.md`, Approaches and Decision 1: "Plain send/return (rejected) ... Old scenes would play their dry signal 3 dB louder at the default reverb mix." Now the AGENTS.md invariant "Sends reproduce 3.0's chain".
- **What it costs:** each voice's stage reads the global mixes and computes three gains; the master filter runs three times (dry, delay send, reverb send); the bus and the nodes' mixes must move in one bundle. `docs/user/effects.md` has to explain two side effects: a voice with reverb send 0 still has its echoes reverberated, and one with delay send 0 still hears the others' echoes in the reverb. The stage has 0.71 KB left under its limit, which already shaped 3.7 (no envelope in the stage).
- **Instead:** the conventional mixer: dry at full level, sends as sends, the mixes as return levels.
- **Cost:** high. `lib/engine/StrataMix.sc` and `StrataEffects.sc`, the effects and mix checks (1,056 and 684 lines; the comparison with 3.0's chain goes), the memory figures, every default level by ear. I did not measure what the stage would get back.
- **When:** 3.8's design, which reopens the delay and reverb for shimmer and delay freeze; not 3.7.
- **Recommendation:** the maintainer's call. The crossfade mix is also a legitimate musical choice; only the rejection's reason was compatibility.

### 12. Three ways to modulate one destination

- **Decided:** `docs/design/3.4-design.md`, Question 34: "LFO destinations and macro targets stay as they are; the matrix adds routings beside them ... One model ... would change every LFO and macro PSET id, scene field and editor, mix macros' absolute writes with the matrix's offsets, and lose the rule that an LFO on a fast destination runs in the engine."
- **Reason:** mixed. The first clause is compatibility and workload; the other two were technical. 3.7's node per envelope routing is the mechanism that answers the third.
- **Instead:** an LFO is a source and its destination a matrix routing.
- **Cost:** very high: `lib/lfos.lua`, `lib/matrix.lua`, the LFO and MOD pages, the engine LFO path, sixteen slots that six LFOs would share.
- **When:** a question for the pre-4.0 review.
- **Recommendation:** leave, unless the review finds players confused by an LFO's own destination beside the matrix.

### 13. The 256 layout, grown by filling holes

- **Decided:** "every existing grid row keeps its meaning" (`docs/design/3.0-design.md` and `docs/design/3.1-design.md`, Anti-goals; ROADMAP's anti-goal 3), followed by every release since.
- **Evidence in `docs/user/grid/256.md`:** page 5's key is at column 12, apart from pages 1 to 4 at 13 to 16; the scene sequence's length takes two rows of eight keys (9 to 16 evidently appended under 1 to 8); freeze is behind a hold on row 16; four keys do the same play and stop; page 4 has faders for the filter and delay and none for the reverb. That these came from the rule is my inference; no document says so for each.
- **Cost:** high: `lib/grid/layout_256.lua` (636 lines) and its 1,453-line test, then the three smaller layouts if they follow.
- **When:** the pre-4.0 review, after 3.8 has added its keys.
- **Recommendation:** the maintainer's call, with a grid in hand.

## Not compatibility, though it looks like it

- **The engine checks against 3.0's chain, 3.1's starts and 3.2's and 3.3's defs** are regression nets: they prove a refactor changed nothing. They have hardened into a constraint in the plan's "No such check is loosened or removed" and in ruling 6 (candidate 2).
- **The whole-system test that a default Strata sends what 3.6 sent** is the same kind of net. It should assert "the new features are off".
- **Setting aside a file a build cannot read, `.part` writes, backups that never replace one another** are data safety. Keep all of it.
- **A PSET line that is missing means the default (#628)** is correctness for any PSET saved during development.
- **"No draw is made at forward with misstep 0"** (3.7 §5.5) keeps tests deterministic; it promises players nothing.
- **Options saved by key, macro targets and routings by id** protect future lists, not old files.
- **3.6's "nothing by default"** for MIDI, crow and ii outputs is hardware safety.
- **Neutral defaults for 3.5's note controls** and **the CM3 tier** are memory and hardware.

## Looked at and set aside

- **`v<i>_seq_gate` off by default** (3.4, Question 41b: "every old scene sounds as it did"). Drones are the instrument; off is the right default anyway.
- **`v<i>_history` separate from `buf_pos`** (3.2 §2.5, to protect old scenes). The units differ (seconds back, a fraction of a loop); two params is right.
- **Attack and release default to each voice's old fixed times** (3.5, Question 6: "so every scene sounds the same"). The slow swells are the voices' character; no better default is evident.
- **A file's key left unset** (3.7 §4.3: "today's behavior, exactly"). The two references differ only when the scale's root is not C, and "an unkeyed sample is in the root" is a sound assumption.
- **3.7's other defaults** (wrap, forward, misstep 0, chances 100/0/0, sync off, ping-pong 0, `slices` off, `follow` off): each is the best default as well as the old behavior. `follow` could default to stretch at no change to any existing file, since it does nothing without a file tempo; that is a taste question, not a compatibility cost.
- **3.7 ruling 15** (FX's K3 stays the bypass on the `sync` row) and **ruling 9** (no `[F]` for fill in the header): consistency and layout reasons, not habit.
- **Fill on the 128v and 64, three play keys kept on the 128h:** the maintainer's own decision 16.
- **The Pulse `res` turned around (3.3, #314):** the design was fixed; only its conversion remains (candidate 3).
- **The pattern chain beside the scene sequencer, ten data files, `extras` beside the built-in voice params:** accretion from building in parallel, not from compatibility. Questions for the pre-4.0 review.
- **The own note beside the extra notes:** memory and "a step never creates a node".
