# Strata development status

Last updated 2026-11-07, at the 3.1.0 release. This file is the hand-off between machines and sessions: what was decided, what is still open, and where the details live. Update it at the end of each piece of work.

## Where things are

- **Released on `main`:**
  - 3.0 (sample and input sources, filter and delay, grain envelopes and triggered grains, LFOs, MIDI, paged screen) through PR #3, and CI through PR #4.
  - 3.0.1, the minor findings deferred from the 3.0 reviews, through PR #7.
  - 3.0.2, the fixes from a whole-codebase review of 3.0.1 (issues #10-#27), from a final review of those fixes (#46-#52) and #5, one pull request per issue (#28-#45, #53-#59, then the docs pull request that closes #52). CHANGELOG.md lists each fix with its pull request.
  - 3.1.0, playable from the norns alone (`docs/design/3.1-design.md`): Wave 0, the restructure for parallel work (#62-#79, fixing #67, #68, #72 and #73 on the way); Wave 1, the shared UI, grid and arc interfaces (#80-#90, #94, and #93 for #91); Wave 2, twelve page, grid and arc packages built in parallel (#95-#108); Wave 3, the docs pass (#110), the follow-ups (#111), the final-review fixes (#115) and the release.
- **CI:** `.github/workflows/test.yml` runs `lua` and the engine check in five parallel shards (memory alone, #131) (`engine (<areas>)`, one runner each, about 2.5 minutes in all instead of 6), gathered by one `engine` job that passes only when every shard passed. The shards are balanced from the per-area times the check prints; `test/unit/docs_test.lua` checks that every area is in exactly one. A new push to a pull request cancels its older runs; runs on `main` are never canceled. `main` is protected:
  - every change goes through a pull request, with no approvals required;
  - both jobs must pass on a branch that is up to date with `main`;
  - the rules apply to admins too;
  - force pushes and deleting `main` are blocked.
- **CI pins:** norns commit `227aa044` (the engine is compiled against its `sc/core`), SuperCollider `1:3.13.0+repack-1ubuntu3` (Ubuntu 24.04's package; norns ships 3.13.0) and `actions/checkout` by commit. The workflow's comments say how to move each pin.
- **Docs layout:**
  - CLAUDE.md is an index: the rules every change needs, the engine command table, how to run the checks, the "Working in parallel" rules, and a table mapping each module to its notes file and its unit tests. Keep it short: put module details in that module's notes file.
  - The Lua notes are one file per module under docs/notes/lua/ (state and voices, engine sync, buffers, LFOs, mutation, scenes, MIDI, params, the UI core, the arc core and page rings, the grid core, the sequencer, the test harness and the version history), plus one per screen page (docs/notes/lua/pages/) and per grid layout (docs/notes/lua/grid/). Each opens with "## Must not break"; CLAUDE.md folds in the rules that span modules. `docs/notes/lua.md` now only maps the old sections to the new files; it stays while `docs/notes/engine.md`, a comment in `strata.lua` and the docs tests (`test/unit/docs_test.lua`, `test/helpers.lua`) still name it.
  - `docs/notes/engine.md` is the engine's implementation reference. It splits per module with the engine in 3.2.
  - `docs/design/3.0-design.md` is the 3.0 design, still the reference for behavior; CHANGELOG.md's 3.0 "Deviations from the design" and the later entries say where the code differs.
  - `docs/design/3.1-3.6-roadmap.md` is the agreed order and scope of the next releases (3.1 to 3.6) with the decisions taken on it. Each release still gets its own design document before code: `docs/design/3.1-design.md` (shipped as 3.1.0) and `docs/design/3.2-design.md` (approved). Implementation plans are under docs/superpowers/plans/.
  - README.md is a short overview, quick start and index; the user documentation is one page per area under docs/user/ (`docs/user/controls.md`, `docs/user/grid.md`, ...), with one page per screen page under docs/user/pages/ and per grid size under docs/user/grid/. CHANGELOG.md holds the per-release changes (pull requests add fragments under changes/, merged at each release), and this file the open items and decisions.
  - The 3.0 and 3.0.1 implementation plans were removed in 3.0.2; git history keeps them.
  - The tests check the maintained docs (CLAUDE.md, README.md, this file and every `.md` under docs/notes/, recursively, and docs/user/): CLAUDE.md's command table must match the engine, no `engine.<name>(` may name a command the engine lacks, every path under docs/, test/, .github/ or lib/ they name must exist, relative links resolve from each doc's folder, and every docs/notes/lua/ file opens with "## Must not break".

## Running the checks

- **Lua:** `lua test/run.lua`, `luajit test/run.lua` and `lua test/sync_check.lua`, from the repo root. They need only Lua 5.3 (norns' version) and LuaJIT.
- **Engine:** `test/run_engine_check.sh [path/to/norns]` compiles the engine against a norns checkout's `sc/core` and runs `test/engine_check.scd` on a silent local scsynth with norns' 8192 KB real-time pool.
  - It needs SuperCollider and a norns checkout (`git clone https://github.com/monome/norns ~/src/norns`, or set `$NORNS_DIR`; CI uses commit `227aa044`).
  - It uses `$SCLANG` if set, else `sclang` on `PATH`, else the macOS app.
  - It stops after `$ENGINE_CHECK_TIMEOUT` seconds (570 by default, below CI's 600) and at once on a compile error. Stopping sclang also stops its scsynth (descendants found with POSIX `ps`, so neither `pgrep` nor `timeout` is needed), and a scsynth that outlives a crashed sclang is stopped through the PID the check writes to its work dir (#152).
  - Each run boots scsynth on the UDP port in `$STRATA_SC_PORT` (57110 by default). Runs on different ports can overlap, for example one per worktree (`STRATA_SC_PORT=57141 test/run_engine_check.sh`); avoid 57120 and the few ports above it, which sclang takes for itself when several run. Two runs on the same port collide, so on a shared machine give each its own port or wrap the runs in a lock, for example `flock /tmp/strata-engine-check.lock test/run_engine_check.sh`.
- **Page renders** (on demand, not in CI): `lua test/render_pages.lua <dir>` then `python3 test/render_pages.py <dir> --font ~/src/norns/resources/norns.ttf` (needs Pillow) draws every page state as a PNG. The layout tests catch overlaps on one baseline and text off-screen; the renders are the check for text over a line or box and for strings crowding on nearby baselines.
- **Engine check on Linux:** install `supercollider-language`, `supercollider-server` and `jackd2`. scsynth needs a JACK server, and a dummy driver needs no sound card. Start one in the background, then run the check headless:

  ```sh
  nohup jackd --no-realtime -d dummy -r 48000 -p 1024 >/tmp/jackd.log 2>&1 &
  SCLANG=/usr/bin/sclang QT_QPA_PLATFORM=offscreen test/run_engine_check.sh ~/src/norns
  ```

  If scsynth does not boot, check that JACK is running (`jack_lsp` fails when it is not) and start `jackd` again. Run JACK at 48 kHz, like norns.

## What 3.1 changed

CHANGELOG.md has every change. In short:
- **Pages:** eight (MAIN, VOICE, SEQ, FX, LFO, BUFFER, SCENES, SETUP). VOICE (every voice param), SEQ (all seven patterns) and SCENES (the slots and the sequencer's fields) are new; every page has a header with page dots and indicators, and FX, LFO, BUFFER and SETUP have field cursors.
- **Keys:** K1 held as ALT through `alt_action`; ALT+E3 fine adjustment; center detents for ranges through 0; lock (stored as `frozen`) on ALT+K3; randomize on MAIN's ALT+K2 with a 5 s undo.
- **Grid and arc:** pages and holds per grid, step levels from a second key, half-second scene saves, fader and sources pages on the 16×8 and 8×16, pattern halves on the 8×8, copy/paste on the 16×16; arc rings on every page but SETUP, ALT rings on MAIN, bipolar fills and a per-page button.
- **Code:** `strata.lua` split into `lib/` modules with registries (pages, params, grid layouts, start, cleanup), so features own disjoint files. No engine change; the one default change is LFO depth 25%.
- **Tests:** 462 Lua tests, in one unit file per module, page, grid layout and the arc's page rings.

## Open items

- **Next: 3.2**, the performance setting and one grain path (`docs/design/3.2-design.md`, approved; plan `docs/superpowers/plans/2026-11-08-3.2-plan.md`). It starts with the engine split, as 3.1 started with the module split.
- [#113](https://github.com/sethbc/strata/issues/113) **Grid playhead one step ahead between steps:** a grid redraw between pattern steps lights the next step, while SEQ draws the sounding one. Not new in 3.1; a shared "sounding step" helper fixes both.
- [#6](https://github.com/sethbc/strata/issues/6) **Hardware check on a norns.** 3.0.2 has run on a norns shield (Raspberry Pi 4, 8 GB): everything runs, with plenty of CPU headroom. The detailed measurements are still to do; the issue and its comments list every check. Pending, in short:
  - from 3.0 and 3.0.1: CPU with all voices and with several buffer voices, xruns while scrolling sources, levels across synth, buffer and input sources and against 2.0, the limiter, arc ring feel (512 ticks per sweep), clicks on filter type and grain mode changes, triggered grain mode (velocity-scaled accents, Karplus re-plucks), the BUFFER page's record/stop/clear/save, the save time of a 16 s buffer, the buffer restore at start, MIDI (notes, velocity, bend, voice-off mode, hot-plug, CC mapping), grid page 4 and the arc pages;
  - from 3.0.2: the Resonator in the mix and as a cross-modulation source, pitch-shifted voices with the fixed window, clicks from rapid source switches and scene chords (a synth already fading is cut), real-time memory and CPU at the peak on norns' own scsynth (armhf, and that the engine compiles there), xruns on voice start and source switch at large grain sizes, the pitch of a 44.1 kHz file, how long a load's decode check and a take's write take on the CM3 (and whether pattern steps, LFO sends and MIDI run late while a take is written), the `/fail /b_readChannel` message format on norns' scsynth, a scene-fade step's real duration against the 1 s overrun bound, the sequencer's `clock.sleep(0)` deferral after a PSET read from the menu, frame-clock CPU with the arc spinning, with the LFO page drawing at 15 fps and with drift redraws, tempo following under Link and MIDI clock, the font's real glyph widths against the harness estimate, arc LEDs at a ring's maximum and minimum, and brief "not loaded" or file-list flashes after a slow reload or a file choice.
  - from 3.1: the page dots, `[L]`/`[T]`, the SEQ step rows and the BUFFER input meter on the real screen and font, the input meter against a recorded take, the arc's whole-step rings (20 ticks per value) and the 24-tick center detent, the grid's half-second holds and step levels, and the screen against the PNG renders.
  - The `●`/`○` glyph check listed on #6 no longer applies: the voice list uses ASCII marks since 3.0.2 (see Decisions).
- **Known and accepted, no action:**
  - The arc keeps redrawing while the norns menu is open (the screen does not), so a param changed from PARAMS, a CC map or an LFO moves the rings at once.
- **Limits to keep in mind:**
  - Lua's 200-local limit applies to each function: the locals probe in `test/run.lua` measures the free locals at the end of each file's main chunk and of each module's constructor function, and requires 30 in each (`strata.lua`'s main chunk uses 5). Group new constants into tables, and split a module that runs short.
  - LFOs top out at 10 Hz, the norns `lfo` library's ceiling. Anything faster belongs in the engine.
  - scsynth's real-time pool on norns is 8192 KB and the measured peak is about 6.9 MB (`docs/notes/engine.md`, Real-time memory). A new UGen with a delay line or table in the voice or grain SynthDefs needs that budget re-measured.

## Decisions taken during development

Each was taken during development without a design review, and lists what it costs if it was wrong. Reverse any of them in a normal pull request.

**3.0 (sample sources, FX, LFOs, MIDI, pages)**
- **Limiter placement:** the master limiter sits *before* the tanh saturator, where the design said "after". After it, the limiter could never act. If wrong: a one-line revert.
- **Input voices' main param:** for input-sourced voices, E3, arc ring 2, the MAIN label and the first fader control **grain size**. Randomize, mutate and drift touch only grain params, because synth and buffer params are dead for live input. If wrong: revert one branch of `main_param_entry`.
- **LFO rate:** LFOs step 48 times per beat (`LFO_PPQN`), and a send is skipped when the value moved less than 1/1000 of the range. This bounds the message rate; the cost is slightly steppier fast LFOs.
- **Buffer-length poll:** the `bufferState` poll sends one float per slot (`slot * 100 + seconds`), because matron's data polls only take blobs. It could be replaced by eight polls later.
- **`stopRecord` added:** K3 on the BUFFER page can stop a recording early, as the design requires.
- **Save gesture:** K2 acts on release (load a file); holding K2 and pressing K3 saves.
- **K3 on MAIN:** it keeps start/freeze. Triggered grains fire from pattern steps and MIDI only.
- **Grain synth stereo:** `\strataGrain` uses two mono GrainIns plus Balance2, like `\strataGrainBuf`. Synth and input voices became about 3-6 dB quieter (check on hardware, #6).
- **Source switching:** replaced synths get a kill fade (50 ms), so fast scrolling can't stack them up.
- **Re-gate during release:** a MIDI note during a voice's release re-opens its synths instead of creating new ones.
- **Smaller calls:**
  - scenes also store each LFO's mode and clocked rate;
  - the source param tells the engine even for a stopped voice;
  - the scratch-take folder is an engine variable, so tests never write into `~/dust`;
  - the test stubs mirror the real norns libraries (numeric param types, LFO depth in percent).

**3.0.1 (minor findings)**
- **Arc ring speed:** every continuous ring on MAIN, FX and BUFFER sweeps its whole range in half a turn (512 of the arc's 1024 ticks). This replaces "tune on hardware"; retune `ARC_TICKS_PER_SWEEP` after #6.
- **Engine-confirmed buffers:** a recording or load shows as loaded only once the engine reports its length. A 0 s report only counts 1 s after the change, and a late report with audio is still adopted. A finishing take shows `...` and ignores K3, with a 5 s fallback.
- **Missing sample files:** if a remembered file is missing at startup, its path is kept, so a sample on an unmounted drive comes back later.
- **Input crossmod:** input-sourced voices get amplitude crossmod (`modLevel`). Frequency crossmod is ignored for live input.
- **Menu-held keys:** keys held when the norns menu opens are forgotten. This uses a wrapped `_menu.set_mode`, restored in cleanup, with the 10 Hz check as a fallback.
- **Interleave:** the save interleave stays a per-frame loop. An array `lace` was measured about 2× slower.

**3.0.2 (review fixes)**
- **Hardware-only checks stay on #6.** Real-time memory on the device, the 44.1 kHz pitch on the device, write-timing jitter, xruns, glyph widths and arc-spin CPU cannot be settled off-device; the code bounds each one and #6 lists what to measure. If wrong: a hardware finding becomes a new issue.
- **The file selector owns the screen while open:** `redraw()` draws the selector instead of doing nothing, so the selector is still there after a K1 menu visit. If wrong: one extra selector redraw now and then.
- **ASCII voice-list marks:** the MAIN list shows `+`/`-` and short names (`reso`, `karp`, ...) instead of `●`/`○`, because the glyphs' width on the norns font is unconfirmed and ASCII fits with 8 px to spare. If wrong: the dots are preferred; a one-line change if hardware shows they render one character wide.
- **Bounded sequencer wait:** the sequencer waits for a transition's end, but cancels one whose next step or end is `SCENE_TRANSITION.overrun_seconds` (1 s) overdue, measured from the fade's progress (`next_step_due`), not its start, so a lost or errored fade can't freeze the sequencer. If wrong: a fade step that really takes over 1 s on a busy CM3 gets canceled; measure on #6 and raise the bound.
- **One followed arc:** Strata follows one arc; a second one is ignored while it is connected, and unplugging the followed arc moves to the next port that holds one, in the order norns clears its ports. If wrong: none in the usual one-arc setup.
- **Engine stub param names:** `setVoiceParam`/`setGrainParam` names are checked against every SynthDef control, including the engine-managed ones (`gate`, `out`, `kill`, ...). If wrong: Lua sending an internal control name isn't caught; a stricter list is a follow-up.
- **Group-size check:** a group must be followed by exactly its size in params and then a group, a separator or the end. If wrong: a future layout with ungrouped params right after a group needs a separator first.
- **Engine-check script fails fast:** a compile error or a hang ends the run (its own 570 s timeout, below CI's 600 s) instead of holding the machine's scsynth port. If wrong: a very slow machine needs `$ENGINE_CHECK_TIMEOUT` raised.
- **Rapid switches cut hard:** a new source switch (or stop/start) frees at once the voice's synths still in their 50 ms kill fade, so a voice never holds more than one live, one fading and one cutting grain synth. If wrong: a click from a synth cut within 50 ms of silence; listen on #6.
- **Quiet messages to synths that can end on their own:** messages to voice, grain and mod synths (and record synths) that may free before they arrive go in `/error -1` bundles (`sendToSynth`), so neither the console nor the engine check sees a `FAILURE` for them; messages to the persistent filter, delay, reverb and master nodes stay plain. If wrong: a real error in one of those voice-synth messages is no longer printed; the engine check's synth-count and level checks still catch its effects.
- **Fixed `PitchShift` window and 128-grain tables:** the window is 0.1 s whatever the grain size, and `maxGrains` 128 still covers Lua's largest overlap (0.5 s × 200 grains/s; a Lua test keeps it so). If wrong: pitch-shifted voices at large grain sizes sound different. 3.2 removed the grain `PitchShift` (pitch is the grain rate), so only the 128-grain tables remain of this decision.
- **Resonator gain and limiter:** a fixed gain cut plus a limiter on that voice only, with no make-up gain elsewhere; voice 1 as a crossmod source became much weaker. If wrong: patches that relied on the old strength modulate less; listen on #6.
- **Pan on the 256 fader pages** for buffer- and input-sourced voices, now that their grain synths pan. If wrong: one more fader page entry.
- **Normalized randomize and mutation** applies to Lua's randomize and mutation of synth and buffer params. Grain size, pitch and spread and the Lua drifts already use linear specs and are unchanged; the engine's tape drift is untouched. If wrong: none.
- **Synchronous decode check on load:** a load decodes the file before reading it, an estimated 0.2 s per FLAC on a CM3, which stalls engine commands briefly during a load the user started. A file may decode up to `loadShortfallFrames` (4096 frames, one FLAC block) short of its header. If wrong: measure on #6; move the check off the command path if the stall is audible.
- **A failed instant recall keeps the previous scene current**, so the header shows what is really loaded. If wrong: none.
- **The test clock follows matron:** tie order (sleeps before syncs, event slots in order) and the 100-slot limit match matron's scheduler, so tests see the order norns runs clocks in. If wrong: tests that depend on tie order need updating along with the stub.
- **The `tempo` param takes the clock's range** (`clock_tempo`'s 1-300 BPM), so any clock tempo is captured and recalled. If wrong: none.
- **Docs layout:** this file and the 3.0 design live under `docs/` (`docs/status.md`, `docs/design/3.0-design.md`), and the old implementation plans were removed. If wrong: links to the old paths break; git history keeps the files.
- **3.0's features are described as Strata's own**, with no reference to the earlier, unreleased script they were first sketched for. Git history, commit messages and old pull request titles keep their wording, since rewriting them would mean force-pushing the protected `main`. If wrong: none; the name survives only in history.

**3.1 (playable from the norns alone)**

From the 3.1 design's "Cost if wrong" and the calls made while building it:
- **K1 held as ALT:** norns hands K1 to a script only after its menu hold (0.25 s), so ALT is always a hold. Confirmed on hardware, so the long-press fallback (0.6 s) was dropped and its unused hook removed (#159); every ALT+K2/ALT+K3 action still goes through `alt_action`. If wrong: a hold timer on K2/K3 that calls `alt_action`, and press actions moved to release where a long press must not also run them.
- **MAIN's K3 starts and stops** the selected voice; lock moved to ALT+K3 and randomize to ALT+K2. If wrong: a stopped voice is one press from running again, and each page's keys are one function.
- **Eight pages:** E1 travels further (seven page steps end to end, at 4 ticks per page). If wrong: reorder `UI_PAGES`, one line.
- **BUFFER's E2 picks a buffer, not a voice:** the selected voice comes from MAIN or VOICE, and every BUFFER key acts on the cursor's buffer. If wrong: ALT+E2 could pick the voice instead of the field cursor.
- **Lock is a UI name only:** the state, the code and the scene field stay `frozen`, so scenes need no migration. If wrong: none; the 3.2 audio freeze gets its own field name.
- **The only default change is LFO depth 25%:** new LFOs are audible when turned on; scenes keep their stored depth, and scene files without LFO settings recall silent LFOs. If wrong: one constant.
- **No new scene fields in 3.1:** the LFO offset is kept across on/off (`wrap_param_action` in `lib/lfos.lua`, #103 step 1), but scenes don't store it until 3.2. If wrong: recalls keep whatever offset is set.
- **Fine adjustment is a tenth of the raw step, on ALT+E3 only;** a param's own `controlspec.step` still limits it, number and option params keep whole steps, and the arc has no fine mode. If wrong: `FINE_DIVISOR`, one constant.
- **Center detents hold for 3 encoder detents or 24 arc ticks** after a change reaches or crosses 0, and for at most 1 s, so a hold left from an old turn never swallows a later one. If wrong: `DETENT`'s three values.
- **The arc button acts per page** (start/stop, play/stop, record/stop, recall, LFO on/off; nothing on FX and SETUP), not always as K3: on LFO, K3 selects the next LFO. If wrong: one `arc_button` field per page.
- **VOICE's whole-step rings step one value per 20 ticks** (choices and numbers), like the LFO page's clocked rate. If wrong: retune on #6.
- **Grid scene saves need a half-second hold**, so a stray press never overwrites a scene. If wrong: `GRID_HOLD`, one constant.
- **The 8×8's column 1 blinks per quarter note** (every 4 steps) while the other half plays, rather than every step, which would strobe at 8 Hz. If wrong: one line.
- **MAIN cuts a long voice name to fit its row** (`fit_text`, so `RESONAT` on hardware), because the source sits on the next row, where `[T]` would collide with a longer name. If wrong: a short display name in `MAIN_PARAMS`.
- **SEQ's playhead animates through the frame clock, screen only,** so a connected arc doesn't redraw at 15 fps while the patterns play. If wrong: none.
- **Built as parallel pull requests:** Wave 1 ran as batches of separate pull requests instead of one serial package, and Wave 2 as twelve packages at once, each owning disjoint files (CLAUDE.md, "Working in parallel"). Parallel pull requests merged `main` and kept both sides of registration conflicts. If wrong: rebase conflicts within a batch, and `main` carried a partly built 3.1 between merges (never tagged).
- **Merged names win:** later work follows the module names already merged (`S.lib.ui_text`, `S.lib.grid_core`, ...) and never renames merged code to match a plan. If wrong: none.
- **The start registry** (#73) came into Wave 1, so each module registers its start step beside its cleanup step and `init` never changes. If wrong: a later package re-homes init pieces.
