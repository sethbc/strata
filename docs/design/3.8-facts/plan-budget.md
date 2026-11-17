# 3.8 plan facts: packages 0a, 0b and 0f (the budget)

Read on `main` at 2edbfa96 (clean). Every `file:line` is today's. Counts were measured with `wc -w`, `awk` and `git grep`; word counts of drafts were measured on scratch drafts. Nothing was run against the engine.

---

## Package 0a: room in `AGENTS.md`, and the wrong lines

### 1. Files

- `AGENTS.md` (345 lines, **7,744 words**; the design's 7,745 is one off). Words per section (`awk` on headings):

| Section (first line) | Words |
|---|---|
| preamble (1) | 101 |
| Project Overview (7) | 305 |
| How work is done (23) | 200 |
| Architecture (41) | 274 |
| Modules, notes and tests (58) | 773 |
| Lua modules and `S` (129) | 241 |
| Lua ↔ SuperCollider Communication (140) | 1,276 |
| Invariants that are easy to break (191) | 2,624 |
| Working in parallel (269) | 423 |
| Development & Testing (281) | 460 |
| Code Style Guidelines (303) | 332 |
| keep Lua and the engine in sync (317) | 132 |
| update the UI (324) | 386 |
| keep grid and arc in step (337) | 217 |

  The longest single lines: 305 (Named constants, 152), 214 (Real-time memory, 92), 262 (sequencer, 88), 142 (command table preamble, 83), 290 (`run_engine_check.sh`, 77), 288 (`run.lua`, 74), 162 (`recordBuffer` row, 72), 272 (Rebase, 66), 203 (stage, 65), 216 (fast modulation, 64), 189 (the `voices` table, 62), 267 (Targets, 61).
- `docs/notes/lua/state-and-voices.md` (gains the full module table under "Modules and `S`", line 208, and the constants list beside line 23).
- `docs/notes/lua/sequencer.md`, `docs/notes/engine/files.md`, `docs/notes/lua/engine-sync.md`, `docs/workflow.md`: receive the few words of detail the trimmed lines drop (each already holds most of it: `sequencer.md:9` and `:22`, `workflow.md:68` and `:99`, `state-and-voices.md:45-56`).
- `docs/status.md:42` ("AGENTS.md has 7,744 words of its 8,000 (256 left ...)") is rewritten with the new count.
- The wrong-line fixes (section 6 below) edit the notes files they name.
- No test file changes: the moves keep everything the tests read (below).

### 2. What the tests read in `AGENTS.md` (`test/unit/docs_test.lua` unless named)

| Test | Line | What it requires |
|---|---|---|
| "AGENTS.md stays within its word budget" | `:781-789` | `%S+` tokens ≤ 8000 (as `wc -w`), and the text `a test fails above 8,000 words` |
| "AGENTS.md command table lists exactly the engine's commands" | `:791-829` | one row per `addCommand`, `` | `engine.<name>(<args>)` | `"<sig>"` | ``, argument count = signature length; no row for a gone command; no `engine.<name>(` in any maintained doc naming a gone command |
| the limits test | `:737-750` | the `setModAmpAmt` and `setModFreqAmt` rows contain `-2 to 2` and `setModSpeed`'s `0.1-50` (the params' specs) |
| "AGENTS.md is the only agent instructions file" | `:768-775` | the file exists, no `CLAUDE.md` |
| "AGENTS.md names the engine notes files" | `:1036-1043` | every `docs/notes/engine/<name>.md` in backticks, and `STRATA_ENGINE_CHECK_AREAS` (both in lines 17 and 290) |
| the 3.13 runner's synopsis | `:1204-1219` | `` `test/run_engine_check_313.sh [-n runs] [-j parallel] [-o log_dir] [-1] [-l] [-c] [path/to/norns]` `` verbatim |
| "the 3.13 runner documents its sharded default" | `:1246-1255` | the bullet starting `` - `test/run_engine_check_313.sh `` names `` `-1` ``, `` `-l` ``, `shard` and `.github/workflows/test.yml` |
| shard counts | `:1235-1244` | any "N shards" equals the workflow's (AGENTS says none today) |
| "every constant AGENTS.md quotes with a value has that value" | `:1390-1403` | the paragraph starting `**Named constants, never magic numbers.**` quotes ≥ 10 `` `NAME` (n) `` pairs, each equal to `S.constants` |
| the process section | `:1545-1559` | `## How work is done: the superpowers skills` above `## Architecture`, naming exactly the process skills |
| skill names | `:1590-1612` | every `superpowers:` name is known |
| the release | `:1668-1688` | `The current release is 3.7.0` (CHANGELOG's newest) |
| paths | `:833-842` | every repo path named exists (placeholders like `<page>` are tolerated, as today) |
| US spelling | `:1318-1340` | |
| `test/unit/structure_test.lua:3361-3368` | | `about 20 minutes` (the workflow's area times) in line 290, and not `about 9 minutes` |

Nothing reads the module table, the invariants or the "Working in parallel" section.

### 3. Moves that reach 800 free (≤ 7,200 words; 544 to cut)

Each keeps the rule as one or two lines naming the notes file; the detail named goes to that file. Drafts are in the scratch folder (`m1.txt` ...); savings are measured.

| # | Move | Lines | Now | After | Saved |
|---|---|---|---|---|---|
| 1 | **The module table keeps only the rows that break the naming rule.** 39 of its 62 rows are `` | `lib/<x>.lua` | `<x>` | `docs/notes/lua/<x with - for _>.md` | <x>_test.lua | `` exactly (measured by script). They and line 60 give way to one sentence; the full table moves to `docs/notes/lua/state-and-voices.md` (a "The module table" subsection under "Modules and `S`"). The 23 other rows stay (state, voices, ui/*, io/*, pages/*, arc/*, grid/*, engine, harness, renders). Bonus: 3.8's new top-level modules (`lib/types.lua`, `lib/grain.lua`, `lib/arp.lua`, `lib/tuning.lua`, `lib/fx_hold.lua`, `lib/shimmer.lua`, `lib/voice_presets.lua`, `lib/factory.lua`) then need no row at all | 60, 64-125 | 363 | 38 | **325** |
| 2 | Row 123 lists every engine file; it becomes "`lib/engine/Strata*.sc` (an area, or a set of defs, a file)", so 3.8's seven new engine files add no words | 123 | 41 | 28 | 13 |
| 3 | Named constants: eleven quoted values (`NUM_VOICES` 7, `NUM_SCENES` 16, `PATTERN_LENGTH` 16, `SCENE_DATA_VERSION` 9, `NUM_MOD_SLOTS` 3, `NUM_UI_PAGES` 10, `MAX_STEP_LEVEL` 15, `NUM_BUFFERS` 8, `NUM_LFOS` 6, `NOTE_SLOTS` 8, `NORNS_SAMPLE_RATE` 48000: the test needs 10), the rest listed in `state-and-voices.md:23` | 305 | 152 | 97 | 55 |
| 4 | The command table's preamble | 142 | 83 | 62 | 21 |
| 5 | "The `voices` table is the only source of values" (the start's send order goes to `engine-sync.md`) | 189 | 62 | 37 | 25 |
| 6 | The sequencer's invariant (the coroutine and yield detail is `sequencer.md:9`, `:22`) | 262 | 88 | 50 | 38 |
| 7 | File writes (the mover detail is `files.md`, `waveform.md`) | 227 | 54 | 40 | 14 |
| 8 | "Working in parallel": its intro and the Rebase, worktree, scratch, Edit-only, Registering and conflict lines (the detail is `docs/workflow.md:68`, `:99` and `state-and-voices.md` "Modules and `S`"; Shared files and Changelog stay) | 271-277 | 373 | 259 | 114 |
| | **Core total** | | | | **605** |
| 9 (optional) | `run.lua` and `run_engine_check.sh` bullets (keep `STRATA_ENGINE_CHECK_AREAS`, `about 20 minutes`, `$STRATA_SC_PORT`) | 288, 290 | 151 | 133 | 18 |
| 10 (optional) | docs/design/ bullet | 14 | 39 | about 25 | about 14 |
| 11 (optional) | "Each screen page, grid layout ..." | 127 | 46 | about 30 | about 16 |

The core gives **7,139 words, 861 free**; with the optional three about 7,091, about 909 free. Trimming more invariants gives little each (measured: the record synth 8, fast modulation 8, the stage 5 words), so they are not worth the review risk.

Draft of move 1 (38 words): "A module `lib/<name>.lua` the table does not list is `S.lib.<name>`, with its notes in `docs/notes/lua/<name>.md` (underscores as hyphens) and its tests in `test/unit/<name>_test.lua`; `strata.lua` gives the include order, and the whole list is in `docs/notes/lua/state-and-voices.md` (The module table)."

Draft of move 3 keeps "The slot length is a tier value ..." and "Never hardcode 7, 8 or 16 ..." verbatim. Package 0d changes `SCENE_DATA_VERSION` (9) to 10 in that paragraph.

### 4. Order and seams

0a lands first and alone. Every 3.8 row and rule after it uses the room: the design's estimate is about 700 words (about ten command rows, about 130 words each for the longer ones measured today: 11-72 a row; rewritten invariants). Move 1 removes the twenty module rows from that estimate, and move 2 the engine files.

### 5. Tests

None change. The whole suite must pass (`lua test/run.lua` and `luajit test/run.lua`); `lua test/run.lua docs` and `lua test/run.lua structure` while working.

### 6. The wrong lines, checked against `main`

"Stands" means still on `main`; "fixed" means the groundwork's last batches changed it; "superseded" means a later document rules.

**`ROADMAP.md`** (the fact files' roadmap items: engine-grain 1-7, engine-voices 1 and 7, engine-effects 1-3, lua-presets 1-4, lua-grids 2 and 9-10, lua-tuning 3-5, lua-types 1-2): **superseded**. `ROADMAP.md:106` now says "where it differs from the sketches below, the design rules ('The roadmap against the facts' there says where and why)". No issue; the release folds the 3.8 section into "Shipped" as usual.

**`docs/design/` and history** (`3.7-facts/revisit.md:124-126, :142-143`, `3.7-facts/engine.md:224`, `3.8-groundwork-design.md:100, :167`, the groundwork plan's ruling 6): design files are history, not maintained docs (`test/helpers.lua:569-577`). No issue, except the status line below.

| # | Line | Says | Status on `main` |
|---|---|---|---|
| E1 | `docs/notes/engine/memory.md:12` ("A synth voice's extra note is one voice synth, so Karplus, not `\strataGrainBuf` (69.1 KB), is 3.5's costliest note"), `:118`, `docs/notes/engine/notes.md:85` ("Karplus is the costliest note (80.9 KB ... against `\strataGrainBuf`'s 73.3 KB)"), `docs/status.md:22` ("Karplus, the costliest note, 80.9 KB of its 83") | Karplus is the costliest note | **stands**: `\strataGrainBuf` is 82.6 KB since 3.7's 1a (`memory.md:165`) |
| E2 | `memory.md:12` (`\strataFM` **22** (19.4)) | FM 19.4 KB | **stands**: measured 20.2 KB on both versions (engine-voices) |
| E3 | `memory.md:12` ("its two 0.1 s `Pluck` lines take 64 KB") | silent on the power-of-two rounding (0.0839 s halves them) | **stands**; 0b rewrites the line anyway |
| E4 | `memory.md:4` ("one fading and one cutting set") | silent on three voice synths a voice under a release-type switch | **stands** (0c cuts, so two; say so in 0c) |
| E5 | `memory.md:104` ("A `DelayN`, `GrainBuf` or `Pluck` takes its memory when it first runs (the next block)") | `Pluck` allocates in its constructor | **stands** (no figure moves) |
| E6 | `memory.md:104` ("keep the server from ever running with a full pool") | the reserve probes can fail themselves near a floor (`DelayN_Ctor: alloc failed`), and the figure then reads about 130 KB high | **stands** |
| E7 | `memory.md:28` (the idle row: "master `PitchShift` ... its window 0.01 s = 16 KB") | the master is 39.6 KB (its `Limiter` about 11 KB more) | **stands** |
| E8 | `docs/notes/engine/effects.md:30` ("about 202 KB") | the FDN measures 209.0 KB | **stands** |
| E9 | `effects.md:8` and `StrataEffects.sc:138-139` ("can never poison the delay feedback or the reverb for good") | holds for bad input only; a loop the effect builds (shimmer) is downstream of every guard | **notes fixed** (`effects.md:8` no longer says it); the code comment at `lib/engine/StrataEffects.sc:136-139` **stands** (2a's file; 2a adds the guard after the reverb) |
| E10 | silent everywhere: one audio-rate `LocalIn` per SynthDef; the stub's `arg` list on every SynthDef (`test/norns_stubs.lua:451-454`) | | **stands** (`docs/notes/test-harness/engine-stub-and-sync.md:11` names "the SynthDef `arg` lists" but not that a def without one fails the load) |
| E11 | `effects.md:16`, `:36`, `docs/user/effects.md:26` (the 1 MB and 2.729 s cap) | | **stands; 0b's** (they become false only with 0b) |
| E12 | `AGENTS.md:210` ("No per-sample sclang loop in engine code ... a structure test enforces it in `StrataFiles.sc`") | `allocEnvelopeBuffers` (`lib/engine/StrataGrainDefs.sc:62-70`) calls `Env.asSignal`, a per-sample sclang loop | **stands**; 1c replaces the four tables with the bank built from `Signal` primitives, so the code fix is 1c's; 0a only files it |
| E13 | `docs/notes/engine/variation.md:4` ("about a quarter of a KB each") | | **consistent** (the fact file says so): not wrong |
| E14 | `docs/notes/engine/rings.md:7`, `:27` (`ringReaders` "holds every `\strataGrainRing` with its voice") | it maps the synth to the reading voice, and no engine code reads it (`StrataLifecycle.sc:84, 251`, `StrataRings.sc:95, 151`: writes and clears only) | **stands**; 1d's (a reader of another voice's ring) |
| L1 | `docs/notes/lua/notes.md:13` ("`note_values` is the one place a pitch becomes what the engine plays ... 3.8's tunings change it alone"), `lib/notes.lua:351` (the same in a comment) | the tuning enters at the key, the snap, the degree, the chord and the engine's table | **stands** |
| L2 | `lib/engine/StrataNotes.sc:641` ("a later release's tunings will need a note's number apart from its rate") | not needed if Lua sends the tuned pitch | **stands** (a comment; 1e's) |
| L3 | `docs/notes/lua/variation.md:4` ("One encoder detent (0.8 semitone of raw travel) ... moves less than a scale step") | false in dense tunings | **stands; future** (true until 1e; 1e's) |
| L4 | `docs/notes/lua/midi.md:15`, `docs/user/midi.md:16` ("exact equal temperament") | false under a tuning | **future; 1e's** (not filed) |
| L5 | `lib/sequencer.lua:434-435`, `lib/variation.lua:39-43`, the In Sen Pou order | code comments, silent notes | **stand; 1e's** |
| L6 | `docs/notes/lua/grid-core.md:148` ("Every layout handles releases on its position page ...; elsewhere `z == 0` returns at once") | the 256's page 1 row 9 and page 3 row 4, the fill keys, the 128h's page 3 recorders and page 4 strip, the 128v's scenes recorders and the 64's play key handle releases | **stands** (0e rewrites grid-core.md; fix now as the design asks, or leave to 0e: see risks) |
| L7 | `grid-core.md:85` (`set_page` "port 1..`MAX_GRID_PORTS`") | also takes the virtual ports 5 and 6 (`lib/grid/core.lua:69-71, 86`; `grid-core.md:28` says so) | **stands** |
| L8 | `docs/user/grid/256.md:40` ("**Row 14: Voice Selection & Status**", no page qualifier; row 15 at `:44` has "(pages 1 and 2)") | row 14 is pages 1-2 only | **stands** |
| L9 | `docs/user/grid.md:7` ("no layout has room for them") | a judgment the free-key counts do not support for the 256 | **stands** (0e and the page packages rewrite the grid pages; low) |
| L10 | `docs/user/grid/256.md:38`, `128h.md:112`, `grid-core.md:158` ("1-4, 1-5 or 1-6", "4-6 fader pages") | | **fixed** (no match on `main`) |
| L11 | `docs/notes/lua/data-files.md` and `lib/side_files.lua:5` ("three side-file modules") | | **fixed** (`data-files.md:14` and `side_files.lua:6` name five) |
| L12 | no note says Strata's data folder (`_path.data .. "strata/"`, `lib/scenes.lua`) and norns' PSET folder (`norns.state.data`) differ when the script folder is not named `strata` | silent | **stands** (4d's concern) |
| L13 | `docs/notes/lua/pages/voice.md` (Keys and encoders) silent that VOICE has no key left | | **stands; moot** once 3b's `preset` row exists |
| L14 | `AGENTS.md:333` ("A new voice type needs a `MAIN_PARAMS` entry ... and `get_param_spec()` specs", 30 words) silent on `noteMainRanges`, `NOTES.envelope`, the user page's table, `freq`/`amp` | | **stands; 0d rewrites the line** (design §14) |
| L15 | `docs/notes/lua/state-and-voices.md:31` (`name`: "the voice type"), `:34-35`, `lib/params_setup.lua:1198-1219` (one spec per key, unsaid), `lib/notes.lua:40` ("its def's times") | | **stand; 0d makes them true** |
| L16 | `docs/notes/lua/scenes.md` ("follow `pairs` over the scene's tables") | | **fixed** (no match) |
| C1 | `docs/notes/lua/history.md:14` ("migration fills 0") | format 9 has no migration: `fill_scene` fills the default | **stands** (the only "migration fills" in docs/notes and docs/user) |
| C2 | `docs/design/3.8-groundwork-design.md:4` ("(`.superpowers/sdd/2026-11-16-before-3.8/facts-*.md` in the main checkout)") | `.superpowers/` is untracked (`git ls-files .superpowers` is empty), so the path is in no clone | **stands** (point at `docs/decisions/3.8.md`, or say the facts were not kept) |

**Issues to file first** (one per notes file or theme; the design's six are E1, E7/E8, L1, L6, L8, L11, and L11 is already fixed):

1. "Engine memory notes: Karplus is not the costliest note since 3.7, and `\strataFM`'s size, `Pluck`'s allocation and the reserve probes are misstated" (E1, E2, E3, E5, E6; `memory.md`, `notes.md:85`, `status.md:22`).
2. "Effects and memory notes: the master is 39.6 KB and the FDN 209 KB of the pool" (E7, E8).
3. "Engine notes are silent on one audio-rate `LocalIn` a SynthDef and the stub's `arg`-list rule" (E10; `effects.md`, `docs/notes/test-harness/engine-stub-and-sync.md`).
4. "`allocEnvelopeBuffers` runs a per-sample sclang loop (`Env.asSignal`) that AGENTS.md's rule says the engine has none of" (E12; the fix is 1c's).
5. "`rings.md`: `ringReaders` maps a ring reader to its voice, and nothing reads it" (E14; 1d's).
6. "`notes.md`: `note_values` is not the one place a tuning changes" (L1, L2).
7. "Grid notes: the layouts' release handling, `set_page`'s ports and the 256's row 14" (L6, L7, L8, L9).
8. "Two stale lines from the groundwork: history.md's migration and the groundwork design's ledger path" (C1, C2).

Not filed: the ROADMAP and design-history items (superseded), the fixed ones (L10, L11, L16, E9's notes), the future ones 1e and 0d own (L3-L5, L14, L15), E4 (0c states it), E11 (0b), L12 and L13 (silent; 4d and 3b).

### 7. Risks and open points

- **Double edits.** E1, E3, E5, E6, E7 and E11 are in `memory.md`, `effects.md`, `notes.md` and `status.md`, which 0b rewrites days later with new figures (Karplus 49.7 KB, the delay's 13.5 KB, the costliest def). If 0a fixes them first, 0b edits the same sentences again. Recommendation: 0a files issues 1 and 2 and fixes only the wording that 0b's figures do not touch (E2, E5, E6, E8); 0b fixes E1, E3, E7 with its new figures and closes the issues. L6-L9 are in files 0e rewrites; the same split applies (0a fixes L8 and L7 as one-liners, 0e owns L6 and L9).
- Moving the module table changes how an agent finds a module's notes: the sentence makes it derivable, and 3.8's twenty new modules then need no rows. If the planner wants the table whole in `AGENTS.md`, move 1 shrinks to the row format (drop the "Unit tests" column to a rule: about 120 words) and the total falls short of 800 without three more invariant trims.

---

## Package 0b: the delay's line, Karplus and the budget

### 1. Files

**Engine**
- `lib/engine/StrataDelay.sc` **(new)**: the delay's line, def, node start and command (moved from `StrataEffects.sc`), so 1a, 1b and 2a edit this file and not `StrataEffects.sc`'s delay parts. Header comment as the others (`// StrataDelay.sc` + what it holds + `See docs/notes/engine/effects.md`). Name passes `test/unit/structure_test.lua:1303` (`^lib/engine/Strata%u[%w]*%.sc$`). No area of its own (the design: the effects area owns the node), so no `ENGINE_AREAS` entry (`structure_test.lua:1293-1295`) and no `areaOrder` change.
- `lib/engine/StrataEffects.sc` (440 lines): remove `\strataDelay` (`:147-168`), `startDelay` (`:369-377`) and the `setDelay` command (`:277-292`) to the new file; `allocEffectBuses` (`:37-52`) calls `this.allocDelayLine`; `addEffectDefs` (`:132`) calls `this.addDelayDef` (directly, not inside a function: `test/engine_check/structure.scd:120-155` walks each SynthDef function's home frame up to `areaCall` through method frames only); `addEffectCommands` calls `this.addDelayCommands`; `freeEffects` (`:434-439`) calls `this.freeDelayLine`; `setEffectBypass`'s free (`:348-354`) empties the line (below); comments at `:326` ("the delay's 1 MB"). `startEffectsChain` (`:405`, `effectDefaults(\strataDelay, ...)`) and the lift (`:360`) keep calling `startDelay`.
- `lib/engine/StrataVoiceDefs.sc`: Karplus's two `maxdelaytime: 0.1` (`:351`, `:361`).
- `lib/engine/StrataPerformance.sc`: `highMemoryBytes` (`:244-252`) gains `fixedBufferBytes`.

**Lua**
- `lib/delay_sync.lua:22-26` (`M.DELAY.max_seconds = 2.7`, comment "DelayC").
- `lib/params_setup.lua:534` (`controlspec.new(0.01, 2.7, "exp", 0.001, 0.375, "s")`). (0d owns this file in Wave 0; 0b lands first: no conflict.)
- `lib/pages/fx.lua:250` (the layout state "delay synced and halved" sets `clock_tempo` 30; with 5.4 s it shows `1 bar>1/2`, not the test's `1 bar>1/4`: set 20). One line in 4a's file; nothing else in Wave 0 edits it.
- **No `lib/performance.lua` change: the design's "mirror in `lib/performance.lua`" does not exist** (see Risks). Lua reads the engine's active file only (`lib/performance.lua:1-31`); the step-down arithmetic lives in the engine alone, checked by `test/engine_check/performance.scd:92-101`.

**Engine check**
- `test/engine_check/memory.scd` (798 lines): the recast (section 4).
- `test/engine_check/effects.scd`: `echoPeaks` (`:792-815`), `checkLongDelay` (`:862-868`), `checkBypassMemory` (`:870-885`), new checks (section 4).
- `test/engine_check/performance.scd:92-101`: the formula and the rings-term checks gain `fixedBufferBytes`.

**Lua tests**: `test/unit/delay_sync_test.lua` (`:91-127`, `:608-617`), `test/unit/pages_fx_test.lua` (`:597-600`, `:617-632`), `test/unit/grid_layout_256_test.lua:296`, `test/unit/lfos_test.lua:1396`, `test/unit/params_setup_test.lua` (`PARAM_FIXTURE_ALLOWED`, `:995-1072`, and its self-test `:1086`). `test/fixtures/3.7.0-params.lua:49` stays 3.7.0's.

**Docs** (every site of 2.7, the megabyte and the Karplus figures; counted with `git grep`):
- `docs/notes/engine/effects.md:16` (sizing rule), `:28` (the def), `:33` (ranges), `:36` (bypass returns 1 MB), `:46` (the check list: "a time of 2.7 s ... 900 and 1100 KB"); a sentence that `\strataDelay` lives in `StrataDelay.sc` under `:23`'s heading.
- `docs/notes/engine/memory.md`: Must not break `:3` (rule), `:5` and `:6` (the worst cases' figures), `:8` (a third pool case), `:12` (one 52 KB limit; Karplus 49.7 with 4096-frame lines; the costliest def), `:13` (buffer memory: the delay's 2 MB, `fixedBufferBytes`), `:104` (the `Pluck` sentence, E5), and a new section "3.8: the delay's line and Karplus (package 0b)" with before/after tables on both versions, as `:159-254` do for 3.7.
- `docs/notes/engine/notes.md:85` (the costliest note and the pool sum).
- `docs/notes/engine/performance.md:8`, `:15` (method list), `:23` (the step-down figures: 45375 kB becomes 58531 kB, so 300 s needs 2007107 kB, 120 s 1467107, 60 s 1287107).
- `docs/notes/engine/voices.md` (Karplus: `maxdelaytime` `karplusMaxDelay`, its lowest pitch 11.9 Hz; near `:80`).
- `docs/notes/lua/delay-sync.md:4`, `:5`, `:20`, `:32`.
- `docs/user/effects.md:8` ("10 ms to 2.7 s"), `:26` ("its memory (the delay's 1 MB)"; and "starting empty", which 0b must keep true: Risks).
- `docs/user/pages/fx.md:14` ("The delay holds at most 2.7 seconds ... one bar at 60 BPM plays a half note": becomes 5.4 s, and the example 30 BPM).
- `docs/user/params.md:18`, `:24`.
- `docs/status.md:22` (Limits: every figure), `:42` if 0b's AGENTS lines change the count.
- `changes/<branch>.md`: "### Changed": the delay reaches 5.4 s; a bypass no longer frees memory the voices use; Karplus's lowest pitch. A restart line naming the new file (`AGENTS.md:47` requires one only for a rename or delete, but every release since 3.5 names its new files: `CHANGELOG.md:9`, `:220`).

**`AGENTS.md` lines 0b makes false** (after 0a's moves):
- `:154` (29 words), the `setDelay` row: "0.01-2.7 s" becomes "0.01-5.4 s" (no words added).
- `:213` (41 words), Buffer memory: add the four fixed sets (draft: "..., the input ring, and the fixed buffers `fixedBufferBytes` counts once (the delay's two lines of 2^18 frames, the output rings, the window bank, the wavetables); never allocate longer ones; bufnums never change.": about +20).
- `:214` (92 words), Real-time memory: "every voice def under 52 KB" and "the worst cases with every voice on the costliest voice def" (about +15; 1c later changes 88 to 97).
- `:235` (34 words): "the step-down arithmetic matches what the rings area allocates" becomes "what the areas allocate (`fixedBufferBytes`)" (+2).
- `:123` the engine file list, only if 0a's move 2 is not taken (+1 name).

### 2. Names

**Engine (new, in `StrataDelay.sc`)**
- `delayLineFrames { ^262144 }` (2^18; a literal, so nothing depends on whether sclang's `2 ** 18` is an Integer).
- `allocDelayLine`: `areaState[\effects][\delayLine] = 2.collect({ Buffer.alloc(context.server, this.delayLineFrames, 1) })`. Called from `allocEffectBuses` (allocState, synced before `start` by `lib/Engine_Strata.sc:145`). Bufnums never change.
- `freeDelayLine`: frees both (from `freeEffects`, the free pass, after every stop).
- `delayLine { ^areaState[\effects][\delayLine] }`.
- `addDelayDef`: `SynthDef(\strataDelay, { arg in, out, bufL, bufR, time=0.375, feedback=0.4, mix=0, pingPong=0, fadeIn=0; ... })`, today's graph with `BufDelayC.ar([bufL, bufR], lineIn, time.lag(0.1).clip(0.01, 5.4))` in place of `DelayC.ar([...], 2.7, time.lag(0.1).clip(0.01, 2.7))`. The time clip stays a literal: the stub reads `setDelay`'s time limit from it (`test/norns_stubs.lua:401-404`, pattern `name.lag(...).clip(lo, hi)`), and the 3.7 plan's ruling 2 (`docs/decisions/3.7.md:41`) chose no `delayMaxSeconds` method for that reason. `BufDelayC` clips the delay to `PREVIOUSPOWEROFTWO(frames) - 1` = 262143 frames = 5.461 s at 48 kHz (`~/src/supercollider/server/plugins/DelayUGens.cpp:2143-2146`), so 5.4 fits.
- `addDelayCommands`: `setDelay` moved unchanged (`"ffff"`), still `this.setSynth(\delay, \time, msg[1], ...)` so the stub's `fx_commands` parse holds (`norns_stubs.lua:473-487`).
- `startDelay(target, addAction, mix, fadeIn = 0)` moved, passing `\bufL, this.delayLine[0], \bufR, this.delayLine[1]`; keep the literal `synths[\delay] = Synth(\strataDelay,` (the stub maps keys to defs from it, `norns_stubs.lua:467-471`).
- `emptyDelayLine`: the two `zeroMsg`s, sent in one bundle with the node's free in `setEffectBypass` (`:351`) when the key is `\delay` (see Risks: without it a lift replays the old line).
- **`bufL` and `bufR` must be passed by every `Synth(\strataDelay ...)`**: their default 0 is bufnum 0, and a negative bufnum is also buffer 0 (`GET_BUF`, `~/src/supercollider/include/plugin_interface/SC_Unit.h:290-312`), so an omitted one writes into whatever buffer 0 is. A Must not break line in `effects.md`.

**Engine (changed)**
- `karplusMaxDelay { ^0.0839 }` (StrataVoiceDefs.sc), read by both `Pluck`s: 0.0839 × 48000 + 65 = 4093, next power of two 4096 frames (`DelayUGens.cpp:3436-3452`, quoted in the facts); also 4096 at 44.1 kHz. Lowest pitch 1/0.0839 = 11.92 Hz; `modFreq` (`StrataVoiceDefs.sc` `voiceModulation`, `freq × bend × noteBend × (1 + crossmod)`) can go below Lua's 20 Hz floor (`lib/params_setup.lua:971`) by bend and crossmod, and is then held at 11.9 Hz where it held at 10.
- `fixedBufferBytes(sampleRate)` (StrataPerformance.sc): `^((2 * this.delayLineFrames) + (numVoices * 2 * this.outRingSeconds * sampleRate) + this.windowBankFrames + this.wavetableBankFrames) * 4`, with three reservation methods beside it that the later packages read when they allocate, so they edit neither file: `outRingSeconds { ^4 }` (1d; equal to `ringSeconds`), `windowBankFrames { ^15 * 8 * 1024 }` (122880; 1c), `wavetableBankFrames { ^8 * 4096 }` (32768: eight tables of 2048 samples in wavetable form; 1f). At 48 kHz: 2,097,152 + 10,752,000 + 491,520 + 131,072 = **13,471,744 bytes = 13,156 kB** exactly.
- `highMemoryBytes(seconds, sampleRate)` (`:248-252`) adds `+ this.fixedBufferBytes(sampleRate)`. The performance check's MemAvailable cases (2100000, 1800000, 1350000, 1150000 kB, `performance.scd:82-91`, `:270`, `:296`) still give 300, 120, 60 and 16 s with the new thresholds (2007107, 1467107, 1287107 kB): no case moves.

**Lua (changed)**
- `M.DELAY.max_seconds` = 5.4 (`lib/delay_sync.lua:26`); `delay_time`'s spec max 5.4 (`lib/params_setup.lua:534`, default 0.375 unchanged).

**Check (memory area, new or renamed)**: `voiceDefLimitKB = 52` and `modDefLimitKB = 9.9` replacing `voiceDefLimitsKB` (`memory.scd:254-255`); `voiceDefSizes` (an Event name → KB, filled by `checkVoiceSynthSizes`); `costliestVoiceDef` (the name with the largest size); `castVoices(target, defName)` (below); `delayDefLimitKB = 16` (a size line for `\strataDelay`). No Lua name the tests reach changes; no start or cleanup step; no registry.

### 3. Order and seams

- Needs 0a (the room). Gives 0c: `castVoices` (0c replaces its body with `setVoiceType`) and the list read in one place (`h.voiceDefs`, `test/engine_check.scd:48-49`, which 0c makes the engine's `voiceTypeDefs`). Gives 1a, 1b, 2a: `StrataDelay.sc` holding the whole delay (1a's return lag, 1b's freeze, clear and their commands, 2a's shimmer go there). Gives 1c, 1d, 1f: `windowBankFrames`, `outRingSeconds`, `wavetableBankFrames`, already counted in `highMemoryBytes`. Gives 1b: a line that a lift finds empty (`emptyDelayLine`), which 1b's "a lifted bypass starts empty and unfrozen" (design §7.3) relies on.
- **Inside 0b, the delay must land with or before the recast**: the facts measured every voice on the trimmed Karplus at 3513 KB on high synth -> buffer -> synth, 71 under the 3584 floor, before the delay's megabyte (`engine-voices.md` §4). The recast alone fails.
- No other Wave 0 package owns these files. 0c owns `test/norns_stubs.lua`; 0b needs no stub change (the def keeps an `arg` list; the clip stays literal; `synths[\delay] = Synth(\strataDelay` stays literal).
- `AGENTS.md` rules 0b rewrites: Buffer memory and Real-time memory (design §14 names both for 0b); "The engine runs the tier Lua reads" (`:235`) wording.

### 4. Tests

**Lua, re-based** (values computed from `DIVISIONS.beats`, `lib/constants.lua:349-352`, and `while seconds > 5.4 do seconds = seconds / 2`):
- `delay_sync_test.lua` "a division that does not fit is halved until it does" (`:91-127`): 60 BPM 1 bar 4 s **not halved** (`1 bar`); 30 BPM 1 bar 8 s → 4 s, halved once, `1 bar>1/2`; 20 BPM 12 s → 3 s, twice, `1 bar>1/4`; 10 BPM 24 s → 3 s, three times, `1 bar>1/8`; the boundary: 44.5 BPM 1 bar 5.393 s not halved (in place of 88.9 BPM's 2.6997 s), 44.4 BPM 5.405 s halved once; 300 BPM 1/32 0.025 s unchanged; 1/4T at 5 BPM 8 s → 4 s, once, `1/4T>1/8T`; 1/4D at 5 BPM 18 s → 4.5 s, twice, `1/4D>1/16D`; a seconds label: 1/4D at 3 BPM 30 s → 3.75 s, three times, `1/4D>3.75 s`.
- `delay_sync_test.lua:613`: 2.7 → 5.4 (the stub's limit and `delay_time`'s top follow by themselves).
- `pages_fx_test.lua:598-600`: `clock_tempo` 60 → 30 for `1 bar>1/2`; `:617-632` passes once `lib/pages/fx.lua:250` sets 20.
- `grid_layout_256_test.lua:296`: 2.7 → 5.4.
- `lfos_test.lua:1396`: −1.345 → −2.695 ("half of 0.01-5.4 s").
- `params_setup_test.lua` "every param's id, type, name, default and spec is 3.7.0's" (`:1074-1084`): **no allowed kind covers a range** (kinds: removed, group_size, options; `:995-1047`). Add a kind `{kind = "range", id = "delay_time", max = 5.4, why = "0b: the delay's line is a buffer (design §0.2)"}` to `allowed_records`, and a case of it to the self-test "the fixture comparison honors each kind of allowed difference" (`:1086`).
- Also whatever else the suite turns up: the counts above are every `2.7`, `1.345`, `>1/` and `delay_time` value in test/unit/ (`git grep`).

**Lua, new**: none required beyond the above (the existing "DELAY.max_seconds equals the engine's limit" covers the pair). Optionally `delay_sync_test.lua` "a division of exactly 5.4 s is not halved" (1 bar at 400/9 BPM).

**Engine check, effects area** (`effects.scd`):
- `echoPeaks` allocates its own two lines (`Buffer.alloc(server, engine.delayLineFrames, 1)` each, fresh per call, freed after) and passes `\bufL`, `\bufR`: a private `\strataDelay` on the engine's buffers would write into the engine's running line (today it is "the engine's delay untouched", `:792-793`).
- `checkLongDelay`: `[\time, 5.4, \feedback, 0]`, windows `[0, 5.38, 5.39, 5.41, 5.42, 5.6]` (peak in window 3 only).
- `checkBypassMemory` replaced: the pool line goes (a 13.5 KB node is under one flood probe here, `memory.md:104`: about 17 KB), and in its place "effects: the delay's line is two buffers of 262144 frames, one channel each, whose bufnums a bypass and its lift keep" and "effects: a time of 5.4 s is reached".
- New: "effects: a lifted delay starts empty": an impulse on the send at feedback 0.9, a bypass after the free, a lift, then nothing above −60 dB on the return for 5.5 s (fails without `emptyDelayLine`).
- New: "effects: the buffer line plays what `DelayC` played": a check-only copy of today's `\strataDelay` on `DelayC` (2.7 s line) beside the engine's def on fresh buffers, pink noise for 5.5 s at a fractional fixed time (0.30928 s) and on a 0.5 Hz LFO, feedback 0.4, ping-pong 0.5: largest difference 0 (the facts measured 0.0 on both versions). Design §13 gives this comparison to 1b's `delay` area; 0b is where the line changes, so it belongs here and 1b moves it.
- `checkChain30` (`:504`, `:1094-1095`) keeps passing (its 3.0 copy is `DelayC`, `:100`; bit-identical); 1a removes it.

**Engine check, memory area** (`memory.scd`):
- `checkVoiceSynthSizes` (`:243-280`): one limit, `voiceDefLimitKB` 52, for every name in `h.voiceDefs`; `\strataMod` 9.9; it records each size in `voiceDefSizes` and sets `costliestVoiceDef` (expect `\strataKarplus` at about 49.7). Line: "memory: % takes % KB of the pool (at most 52 KB; ...)". New line: "memory: the costliest voice def is % (% KB), on every voice in every worst case".
- New size line: "memory: \strataDelay takes % KB of the pool (at most 16 KB, by allocation probes)" with `sizeOf` and twenty nodes on private buses and one pair of check buffers (expect 13.5).
- **`castVoices(target, defName)`**: before the first `startAll` of `checkMemoryWorstCase` (`:351`) and for the high engine too (`checkHighWorstCase`, `:747`), every voice's def is the costliest. 0b has no `setVoiceType`, so its body is check-only: keep `target.voiceSynthDefs.copy`, then `target.numVoices.do({ arg voice; target.voiceSynthDefs.put(voice, defName) })` (`voiceSynthDefs` is a `var <` getter on a mutable Array literal, `lib/Engine_Strata.sc:19`, `StrataVoices.sc:24-25`; every reader indexes it at use: `StrataLifecycle.sc:10`, `:164-165`, `StrataNotes.sc:260`, `:498`, `:528`); `castVoices(target, nil)` puts the copy back after the last case. Cast only with no voice synth playing or releasing (`h.stopAllVoices(target)`, then check `voiceGroup` holds no voice def), since `gateVoice` takes a releasing voice synth back whatever its def (`engine-voices.md` §0 fact 8). 0c replaces the body with one `setVoiceType` per voice (the index of the costliest in `voiceTypeDefs`) and `h.voiceDefs` with the engine's list; nothing else in the recast moves. So 0c "only supplies the list".
- The pool case with voice-synth notes (`:664-707`): `poolKarplus` becomes `poolCostliest` over every voice's slots (not `[5]`); `counts == [23, 14, 30, 9]` becomes `[23, 14, 30, 30]` (every voice synth the costliest); labels drop "Karplus's seven first" for "of the costliest def (\strataKarplus)". The note spread `[2, 2, 2, 1, 1, 7, 1]` may stay.
- **The third pool case** (new, after the second, before `setNotePool 0`): the second case's steps up to `switchAll.({ 0 })` under `holdVoices`, then inside the hold each of the sixteen notes released (`noteOff` cut 0) and played again (`playPoolNote`: a `noteOn` on a releasing slot cuts its tail), so each slot holds a live and a cutting voice synth; `probeHeadroom` with 5 probes and `cutBound` `(2 * numVoices) + notePoolMax` (30); the report checks `poolHeld == [16, 16]` and the server's counts: 7 `\strataGrainBuf` (the buffer grain synths fading), 14 `\strataGrainRing`, 46 voice synths, 46 of the costliest def. Line: "memory: synth -> buffer -> synth with every pool slot's voice synth live and cutting (a type switch under a full held chord) leaves 1280 KB (...)". 0c may replace the release-and-replay with a `setVoiceType` on every voice (its `restartNotes` cut); the counts stay.
- `modulationRunning.size == 20` (`:784`) becomes 22 (one more `probeHeadroom` a tier); `checkHighWorstCase`'s spectral indices `[0, 1, 3, 9]` (`:736-738`) stay valid (the new case is index 10; add `spectral[10]`).
- The grain defs' 88 KB (`:139-141`) is unchanged (1c raises it to 97).
- Comments with figures: `:244-253` (the 3.5 sizes), `:672-680`.

**Engine check, performance area**: `performance.scd:94-95` adds `+ engine.fixedBufferBytes(48000)` to the formula; `:98-101` subtracts it before comparing the rings; new: "performance: fixedBufferBytes counts the delay's two lines (262144 frames each), seven output rings of 4 s a channel pair, a window bank of 122880 frames and a wavetable bank of 32768 (13471744 bytes at 48 kHz)" and "performance: the delay's lines are what the effects area allocated" (`engine.delayLine.collect(_.numFrames).sum * 4 == 2 * engine.delayLineFrames * 4`).

**Areas 0b runs**: while building, `STRATA_ENGINE_CHECK_AREAS=effects,memory,performance,voices` on its own port; before landing, every area on 3.14.1 and the CI shards on 3.13 (`test/run_engine_check_313.sh`, Docker), plus the memory area alone on 3.13 (CI's figure). It must measure and report, on both versions and both tiers: every voice def's size (Karplus about 49.7, the costliest), `\strataDelay`'s size (about 13.5), the idle pool (facts: 6580 → about 7600 KB), and every worst case before and after, as a table in `memory.md` like `:227-254`. Expected (the facts' sums, est.): high synth -> buffer -> synth about 4520 KB (3820 + 1010 − 304), standard about 5180; the high pool case about 2390, standard about 3060; the third case about 2900 on high and 3540 on standard (`engine-voices.md` §4: 1906 and 2529 with every voice the trimmed Karplus, before the delay's 1010). It reads every log for `alloc failed` (E6: a reserve probe that fails overstates by about 130 KB).

### 5. Risks and open points

- **A lifted delay would replay the old line.** `BufDelayC`'s write index starts at frame 0 in a new node, and it reads the buffer at `write − delay`, which a bypassed node left full; `DelayC` gave each node a fresh line. Today `docs/user/effects.md:26` promises "Lifting the bypass brings it back ... starting empty". Options: (a) zero both buffers in the bundle that frees the node (`/b_zero` runs in the non-real-time thread, `SC_SequencedCommand.cpp:432-436`, so a lift sent within the zero's fraction of a millisecond could hear a stale block; every lift comes after the free's scheduled function); (b) `/b_fill` in the same bundle (audio thread, exact, but 524,288 writes in one block, about 1-2 ms on a CM3, est.: an xrun risk); (c) an age gate in the def (return and feedback 0 until the node has run one delay time), exact but it breaks the bit-for-bit match with `DelayC` at the first echo. Recommendation: (a), with the new "starts empty" check. Not in the design; the facts did not run the effects area on the buffer delay (only the memory area per variant).
- **The private delay nodes in `effects.scd` must get their own lines** (`echoPeaks`): on the engine's buffers they would corrupt the running delay. And a missing `bufL`/`bufR` writes into buffer 0 (`SC_Unit.h:290-312`).
- **There is no Lua mirror of `highMemoryBytes`** (design §0.2 and §14 name one in `lib/performance.lua`). Lua never computes memory; the engine decides and writes `performance_active.data`. So "and its mirror" is nothing to edit; the guard is `performance.scd:92-101`. `lib/performance.lua` stays untouched.
- **`delayMaxSeconds`** (design §0.2, §1) contradicts the 3.7 plan's ruling 2 (no method; the stub reads the literal clip). Recommendation: the literal `.clip(0.01, 5.4)` and `DELAY.max_seconds` as today, compared by the existing test; no method. If the planner wants the method, the stub must learn to read it (`engine_number`, `norns_stubs.lua:417`), which is 0c's file.
- **`delay_time`'s range doubles on an exponential warp**: a MIDI map, the 256's fader and arc ring 3 move to different times for the same position, an LFO's half range is 2.695 s where it was 1.345, and FX's randomize range (`lib/pages/fx.lua:193`, `octaves(0.05, 1.0)`) is unchanged. Scenes and PSETs store seconds and keep their times. A sound change for mapped controllers; the changelog says so.
- **The fixture test needs a new allowed kind** (`range`): without it "every param's id ... is 3.7.0's" fails on `delay_time`'s max.
- **Karplus below 11.9 Hz** (a 20 Hz voice bent down an octave and a half, or crossmodulated) holds at 11.9 where it held at 10; nothing tests it. Unsure whether anything plays there in practice.
- The facts' prototype used 2^17-frame buffers; the design's 2^18 (2 MB) was not measured. Its pool cost should not change (the buffers are not in the pool); the build measures `\strataDelay` again.
- `castVoices` mutates the engine's list from the check; the memory area must put it back before the areas that follow use the default engine (it is the runner's shared engine).

---

## Package 0f (new): #772, MPE zone setup and a remote's claim

### What happens today

- **Hook order.** `S.lib.io_ports` runs its change hooks, and its claim hooks, in the order their names were first registered (`lib/io/ports.lua:67-90`). `io_midi_out` registers both at its include (`lib/io/midi_out.lua:560`, `:608`; include line `strata.lua:95`), before `remote` (`lib/io/remote.lua:485`, `:504`; `strata.lua:105`); `midi_in` and `io_controllers` register theirs in start steps (`lib/midi_in.lua:598-599`, START_ORDER 90; `lib/io/controllers.lua:530-531`, 94).
- **Arrival** (`ports.lua:214-221` `added`, and `:245-258` `reconcile`): MIDI out's hook pays the owed offs and sends each MPE voice's zone `setup` at once (`midi_out.lua:564-569`); then remote's hook claims the port (`remote.lua:496-497` → `connect`, `:332-345`: `claim` at `:337`, `claimed_port` set at `:341`, the hello at `:343`). So the setup reached the device first (#772 part 1).
- **Claims.** Two sites: `connect` (remote grid or arc, `remote.lua:337`) and `claim_midigrid_port` (`:383-388`). Claim hooks run with the owner recorded but before `claimed_port` is set (`ports.lua:171-181`), so `holds` is still false and MIDI out ends the port's notes there (#769, `midi_out.lua:600-621`).
- **Releases.** `disconnect` releases while `claimed_port` is still set (`remote.lua:349-360`, its comment at `:354-355`); `release_midigrid_port` clears `midigrid.ports[port]` first (`:394-398`). `release` clears the owner and runs the claim hooks with nil (`ports.lua:184-189`). MIDI out's claim hook returns at once for nil (`midi_out.lua:609`), so a release sends nothing; and during a remote grid's or arc's release `holds(port)` is still true (`remote.lua:215-220`), so a setup sent from that hook would be dropped by `send` (`midi_out.lua:82-86`) (#772 part 2). Remote's own claim hook may claim the port straight back for the other kind (`remote.lua:504-510`), inside the same release.
- **A settle while held.** `apply` (`midi_out.lua:705-733`) sends a zone's setup through `send`, which drops it on a held port, and nothing resends it.

### Options and their seams

1. **A settled hook in `S.lib.io_ports`, a due flag in MIDI out, and `holds` read through the owner** (recommended).
   - `lib/io/ports.lua`: `M.on_settled(name, fn)`, `fn(port)` run (as `run_set`, contained, in registration order) once a port's arrival, or its release, has been told to every change or claim hook, any claim a hook made meanwhile included: after `run_set(state.changes, ...)` in `added` (`:218`), after the arrivals loop of `reconcile` (`:257`, once per arrived port), and after `run_set(state.claims, ..., nil)` in `release` (`:187`). A new set `state.settles = new_set()` beside `changes` and `claims` (`:48`).
   - `lib/io/remote.lua:215-220`: `holds(port)` is true for a kind only while `claimed_port == port` **and** `S.lib.io_ports.owner(port) == record.owner`, so it is false from the moment `release` clears the owner, though `disconnect` keeps `claimed_port` until `release` returns (its own claim hook's guard at `:508` is unchanged). midigrid's term is already cleared first.
   - `lib/io/midi_out.lua`: `state.setup_due[port]`; the arrival hook (`:566-569`) marks it instead of sending; the claim hook remembers a holder's claim (`state.held_owner[port] = owner` when `holders[owner]`) and, at a release of such a port, marks it; `apply` marks a port it could not reach (`remote_holds(port)` at its setup); a zone that goes away clears the mark. `S.lib.io_ports.on_settled("io_midi_out", flush_setup)`: if the mark is set and `present(port)`, the port's MPE voice (from the settled routes) gets its one `setup` and the mark clears; while held the mark stays; with no device it clears (the next arrival marks again).
   - Result: an arrival a remote takes gets nothing from MIDI out; a port a remote or midigrid lets go gets its setup at once, before any note; a release a remote takes straight back sends nothing. An arrival with no claimant still gets its setup in the same call as today (after the other hooks rather than before), so the existing tests that assert it at the plug (`io_midi_out_test.lua:886-890`, `:1055`) keep passing; the settle tests (`:1580`, `:1606-1607`, `:1789-1815`) send to ports no remote holds and are unchanged.
2. **Order by registration**: MIDI out registers a second change hook (`io_midi_out_zones`) in a start step after `io_remote` (START_ORDER 95), so remote's claim runs first. No `ports.lua` API, but it rests on start order, and a release still needs part 2's fix (a release hook that runs after the port is free), so it is half a fix.
3. **Hold every setup to the next LFO step**, in `midi_out.lua` alone: mark at arrival, release and a held `apply`; send from the step hook (`:458-463`, about 21 ms later) when `present(port)`, and from `start_note` before a note on a marked port. One file, and robust to paths nobody listed; but every test that asserts the setup at the plug needs a step first, and a remote grid's `holds` is true during its release, so only the step (after `disconnect` has cleared `claimed_port`) sees the port free.

**Recommendation: option 1.** It is the issue's own shape ("a hook that runs then", "hold the setup at an arrival until the claims are made"), synchronous, and leaves today's timings and tests standing. Option 3 is the fallback if the planner wants the package to own one file.

### Files, names, tests

- `lib/io/ports.lua` (`M.on_settled`; `state.settles`), `lib/io/remote.lua` (`M.holds`), `lib/io/midi_out.lua` (`state.setup_due`, `state.held_owner`, `flush_setup`, the arrival, claim and `apply` sites). No start or cleanup step, no registry, no `MODULE_HOMES` entry, no name a test reaches by `local_value`.
- Notes: `docs/notes/lua/io/ports.md` (Must not break: the settled hook, when it runs); `docs/notes/lua/io/remote.md:45` (`holds`); `docs/notes/lua/io/midi_out.md:3`, `:30` ("then the MPE setup of a voice on that port"), `:51` ("and when the port's device arrives"). `docs/status.md:15` (#772 leaves). `changes/<branch>.md` ("### Fixed"). `AGENTS.md`: nothing false (its MIDI ports rule, `:243`, still holds).
- Tests, `test/unit/io_midi_out_test.lua` (helpers there: `started`, `mpe_voice`, `settled`, `step`, `remote_grid_at`, `ASK_HELLO`, `SETUP_15_48`, `sent`, `clear`):
  - "an MPE zone's setup waits while a remote grid takes its arriving device (#772)": voice 1 MPE on port 3, settled; the rig's remote grid port 3 with no device; plug `iii grid` at 3: `sent` is `ASK_HELLO` alone, no `cc 101`, `cc 100`, `cc 6`.
  - "a port a remote grid lets go gets its zone setup before its first MPE note (#772)": the MPE route set and settled while the grid holds port 3 (nothing sent); `remote_grid_at(S, 0)`: the remote's own messages, then `SETUP_15_48` once; then a played note: `pitchbend 8192 2|note_on 60 127 2` after it.
  - "a port midigrid lets go gets its zone setup (#772)" (as `:1310`'s Launchpad).
  - "a release the remote arc takes straight back sends no setup (#772)": grid and arc both named on port 3 (the arc `in use`), the grid's port set to 0: the arc claims inside the release, and the device gets no RPN.
  - "an arrival nobody claims still gets its setup in the same call" (today's `:886-890`, unchanged).
- `test/unit/io_ports_test.lua`: "on_settled hears a port once its arrival or release has reached every hook, a claim made by one included" (order of names, a raising hook contained, nothing for a departure or a port outside 1-16).
- `test/unit/io_remote_test.lua`: "holds is false while the port's release is told" (a claim hook probe reads `holds` at the release).

### Order and seams

- Wave 0, any time after 0a; it touches no file 0b-0e own (0e edits `lib/grid/core.lua`; `remote.lua` calls `S.lib.grid_core.attach_virtual` and `detach_virtual` (`:227`, `:410`, `:424`): if 0e changes those calls' shape it must edit `remote.lua` too, a one-line seam to watch).
- **1e edits `lib/io/midi_out.lua`** (design §6.5: a tuning's cents in the MPE bend, `encoded` `:147-157` and `start_note` `:285-353`): 0f lands first (Wave 0 before Wave 1), and 1e builds on `flush_setup`. 4d's factory loader reads MIDI out's groups for its rig list (`FACTORY.rig`) and edits none of these files.

### Risks

- A takedown for a zone removed while its port was held is still dropped (the device the port then holds is the remote's own); not in #772's expected behavior. Unsure whether it matters: a device that got a setup before the claim keeps its zone after the release.
- The controllers' claims (`lib/io/controllers.lua:369`) never stop MIDI out sending (a controller's port is sent to as set), so their releases mark nothing; option 1 keys the mark on `holders`.

---

## For the planner

1. **The design's Lua mirror of `highMemoryBytes` does not exist.** `lib/performance.lua` (222 lines) only parses `performance_active.data`; the step-down is the engine's alone, checked by `test/engine_check/performance.scd:92-101`. 0b edits `StrataPerformance.sc` and that check, not `lib/performance.lua`.
2. **A lifted buffer delay would replay its old line** (a new `BufDelayC` node writes from frame 0 and reads the full buffer the bypassed node left), breaking `docs/user/effects.md:26`'s "starting empty". 0b must empty the line at the free (`/b_zero` in the free's bundle) and add a check; 1b's "a lifted bypass starts empty and unfrozen" depends on it.
3. **The effects area's private `\strataDelay` nodes must get their own buffers** (`echoPeaks`, `effects.scd:792-815`), and every `Synth(\strataDelay` must pass `bufL` and `bufR`: a default or negative bufnum is buffer 0 (`SC_Unit.h:290-312`).
4. **The 3.7.0 params fixture test has no kind for a changed range**: `delay_time`'s 5.4 s max fails "every param's id ... is 3.7.0's" (`params_setup_test.lua:1074`) until 0b adds a `range` kind to `PARAM_FIXTURE_ALLOWED`.
5. **0b can recast the memory area without `setVoiceType`**: a check-only `castVoices` puts the costliest def into the engine's mutable `voiceSynthDefs` (every reader indexes it at use), so 0c replaces one function body and the list (`h.voiceDefs`), nothing else.
6. **`checkBypassMemory`'s pool measurement cannot survive**: 13.5 KB is under one flood probe (about 17 KB); the size moves to the memory area (twenty nodes, 0.85 KB steps), and the effects check asserts the 5.4 s echo and the bufnums.
7. **`delayMaxSeconds` contradicts the 3.7 plan's ruling 2** (the stub reads the literal clip); keep the literal 5.4 and `DELAY.max_seconds`.
8. **0a reaches 861 free with eight moves**, 325 words of them from replacing the 39 module-table rows that follow the naming rule with one sentence (the full table to `state-and-voices.md`); that also spares 3.8's twenty new modules their rows. No test reads the module table, the invariants or "Working in parallel".
9. **Six of the design's wrong lines sit in files 0b rewrites** (`memory.md`, `notes.md:85`, `effects.md`, `status.md:22`); file the issues in 0a but fix those figures in 0b, or each sentence is edited twice. The side files' count is already fixed on `main`, and every ROADMAP item is superseded by `ROADMAP.md:106`.
10. **#772's fix fits a settled hook in `lib/io/ports.lua`** (after the change or release hooks, nested claims included) plus `holds` read through the port's owner (`remote.lua:215-220`); it keeps every existing setup-at-plug test, and lands before 1e, which edits `lib/io/midi_out.lua`.

## Package 0g: the sites (read when its task was drafted)

- `test/unit/params_setup_test.lua`: `PARAM_FIXTURE_FIELDS` (952), `string_at_default` (954), `fixture_record` (961: separators `{id, t, name}`, groups add `n` only), `field_text` (985), `PARAM_FIXTURE_ALLOWED` (1007, today one `options` entry for `midi_note_off` and a loop of 2b's `removed` and `group_size` for the LFO groups), `allowed_records` (1020; today one entry an id, `listed[entry.id]`), `first_param_difference` (1058). The tests are "every param's id, type, name, default and spec is 3.7.0's, in order" (1075) and the self-test (1087). The fixture `test/fixtures/3.7.0-params.lua` has 1048 records, 25 groups and 32 separators.
- `test/unit/engine_sync_test.lua`: `start_call_line` (1621), `START_HOOK_SENDS` and `start_canonical` (1633-1650: the `setVoiceParam` run after `voiceOn` and the hooks' two sends sorted), and the test "a voice start sends 3.7.0's messages" (1654-1676). The fixture `test/fixtures/3.7.0-start-calls.lua` is keyed `voice_1`, `voice_4` and `buffer_voice_3`, and has no allowance today.
- `test/unit/system_37_test.lua`: `NEW_COMMANDS` and `NEW_SYNC_KEYS` (38-39), `call_line` (42), `canonical` (53-71), and the test "a fresh Strata has every 3.7 feature off" (88-142), which compares with `test/fixtures/3.6.0-start-calls.lua` (setDelay's fourth argument dropped at 123-126). It is the only start-call comparison in the file.
