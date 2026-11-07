# Strata development status

Last updated 2026-11-07, after the 3.1 Wave 0b notes split. This file is the hand-off between machines and sessions: what was decided, what is still open, and where the details live. Update it at the end of each piece of work.

## Where things are

- **Released on `main`:**
  - 3.0 (sample and input sources, filter and delay, grain envelopes and triggered grains, LFOs, MIDI, paged screen) through PR #3, and CI through PR #4.
  - 3.0.1, the minor findings deferred from the 3.0 reviews, through PR #7.
  - 3.0.2, the fixes from a whole-codebase review of 3.0.1 (issues #10-#27), from a final review of those fixes (#46-#52) and #5, one pull request per issue (#28-#45, #53-#59, then the docs pull request that closes #52). CHANGELOG.md lists each fix with its pull request.
- **CI:** `.github/workflows/test.yml` runs two jobs, `lua` and `engine`. A new push to a pull request cancels its older runs; runs on `main` are never canceled. `main` is protected:
  - every change goes through a pull request, with no approvals required;
  - both jobs must pass on a branch that is up to date with `main`;
  - the rules apply to admins too;
  - force pushes and deleting `main` are blocked.
- **CI pins:** norns commit `227aa044` (the engine is compiled against its `sc/core`), SuperCollider `1:3.13.0+repack-1ubuntu3` (Ubuntu 24.04's package; norns ships 3.13.0) and `actions/checkout` by commit. The workflow's comments say how to move each pin.
- **Docs layout:**
  - CLAUDE.md is an index: the rules every change needs, the engine command table, how to run the checks, the "Working in parallel" rules, and a table mapping each module to its notes file and its unit tests. Keep it short: put module details in that module's notes file.
  - The Lua notes are one file per module under docs/notes/lua/ (state and voices, engine sync, buffers, LFOs, mutation, scenes, MIDI, params, UI and pages, arc, grid and sequencer, the test harness, and the version history). Each opens with "## Must not break". `docs/notes/lua.md` now only maps the old sections to the new files; it stays while `docs/notes/engine.md`, a comment in `strata.lua` and the docs check still name it.
  - `docs/notes/engine.md` is the engine's implementation reference. It splits per module with the engine in 3.2.
  - `docs/design/3.0-design.md` is the 3.0 design, still the reference for behavior; CHANGELOG.md's 3.0 "Deviations from the design" and the later entries say where the code differs.
  - `docs/design/3.1-3.6-roadmap.md` is the agreed order and scope of the next releases (3.1 to 3.6) with the decisions taken on it. Each release still gets its own design document before code.
  - README.md is a short overview, quick start and index; the user documentation is one page per area under docs/user/ (`docs/user/controls.md`, `docs/user/grid.md`, ...). CHANGELOG.md holds the per-release changes, and this file the open items and decisions.
  - The 3.0 and 3.0.1 implementation plans were removed in 3.0.2; git history keeps them.
  - The tests check the maintained docs (CLAUDE.md, README.md, this file and the files directly in docs/notes/): CLAUDE.md's command table must match the engine, no `engine.<name>(` may name a command the engine lacks, and every path under docs/, test/, .github/ or lib/ they name must exist. Extending the check to docs/notes/lua/ and docs/user/ is planned.

## Running the checks

- **Lua:** `lua test/run.lua`, `luajit test/run.lua` and `lua test/sync_check.lua`, from the repo root. They need only Lua 5.3 (norns' version) and LuaJIT.
- **Engine:** `test/run_engine_check.sh [path/to/norns]` compiles the engine against a norns checkout's `sc/core` and runs `test/engine_check.scd` on a silent local scsynth with norns' 8192 KB real-time pool.
  - It needs SuperCollider and a norns checkout (`git clone https://github.com/monome/norns ~/src/norns`, or set `$NORNS_DIR`; CI uses commit `227aa044`).
  - It uses `$SCLANG` if set, else `sclang` on `PATH`, else the macOS app.
  - It stops after `$ENGINE_CHECK_TIMEOUT` seconds (570 by default, below CI's 600) and at once on a compile error.
  - Each run boots scsynth on the UDP port in `$STRATA_SC_PORT` (57110 by default). Runs on different ports can overlap, for example one per worktree (`STRATA_SC_PORT=57141 test/run_engine_check.sh`); avoid 57120 and the few ports above it, which sclang takes for itself when several run. Two runs on the same port collide, so on a shared machine give each its own port or wrap the runs in a lock, for example `flock /tmp/strata-engine-check.lock test/run_engine_check.sh`.
- **Engine check on Linux:** install `supercollider-language`, `supercollider-server` and `jackd2`. scsynth needs a JACK server, and a dummy driver needs no sound card. Start one in the background, then run the check headless:

  ```sh
  nohup jackd --no-realtime -d dummy -r 48000 -p 1024 >/tmp/jackd.log 2>&1 &
  SCLANG=/usr/bin/sclang QT_QPA_PLATFORM=offscreen test/run_engine_check.sh ~/src/norns
  ```

  If scsynth does not boot, check that JACK is running (`jack_lsp` fails when it is not) and start `jackd` again. Run JACK at 48 kHz, like norns.

## What 3.0.2 changed

CHANGELOG.md has every fix. In short:
- **Engine:** a fixed 0.1 s `PitchShift` window and 128-grain tables, and at most one live, one fading and one cutting grain synth per voice on every path, so seven voices at large grain sizes fit norns' 8 MB real-time pool (about 6.9 MB at the peak). The Resonator's level (it peaked about 23 and drove the master limiter), the pitch of buffers from files not at 48 kHz, fades before a played buffer slot changes, pan for buffer and input voices, NaN guards before the effects and in cross-modulation, fades for release tails before their slot changes, and engine-side reports of failed loads (`bufferLoadFailed`).
- **Lua:** `fileselect` required (BUFFER K2 crashed on norns), a 15 fps frame clock for every screen and arc redraw, arc rings at their maximum and on any port, an ASCII MAIN voice list, grid LEDs, sequenced transitions that finish, the tempo param following the clock, randomize and mutations on each param's curve, start-up and scene edge cases.
- **Tests:** the stubs follow norns' and matron's own code (arc, list, fileselect, clock scheduler, tabutil, params, menu routing); the engine stub range-checks every argument and param name from the engine source; the engine check runs with norns' memory and measures pitch and level. 210 Lua tests.

## Open items

- **Next: 3.1 Wave 0**, the restructure for parallel work (module split, then tests, notes and process split). Wave 0a, the module split, is merged (#69): `strata.lua` holds the entry points and every part of the script is a `lib/` module (CLAUDE.md, "Lua modules and `S`"); its golden master was retired with it. Wave 0b (tests, notes, process) is under way: the README is split into docs/user/, the engine check takes its port from `$STRATA_SC_PORT`, and the Lua notes are split per module with CLAUDE.md as an index (CLAUDE.md, "Working in parallel"). The test split and the changelog fragments follow. The design is `docs/design/3.1-design.md` (approved 2026-11-07), the plan `docs/superpowers/plans/2026-11-07-3.1-wave0-restructure.md`. Waves 1-3 get their plans once Wave 0's module names exist.
- [#6](https://github.com/sethbc/strata/issues/6) **Hardware check on a norns.** 3.0.2 has run on a norns shield (Raspberry Pi 4, 8 GB): everything runs, with plenty of CPU headroom. The detailed measurements are still to do; the issue and its comments list every check. Pending, in short:
  - from 3.0 and 3.0.1: CPU with all voices and with several buffer voices, xruns while scrolling sources, levels across synth, buffer and input sources and against 2.0, the limiter, arc ring feel (512 ticks per sweep), clicks on filter type and grain mode changes, triggered grain mode (velocity-scaled accents, Karplus re-plucks), the BUFFER page's record/stop/clear/save, the save time of a 16 s buffer, the buffer restore at start, MIDI (notes, velocity, bend, voice-off mode, hot-plug, CC mapping), grid page 4 and the arc pages;
  - from 3.0.2: the Resonator in the mix and as a cross-modulation source, pitch-shifted voices with the fixed window, clicks from rapid source switches and scene chords (a synth already fading is cut), real-time memory and CPU at the peak on norns' own scsynth (armhf, and that the engine compiles there), xruns on voice start and source switch at large grain sizes, the pitch of a 44.1 kHz file, how long a load's decode check and a take's write take on the CM3 (and whether pattern steps, LFO sends and MIDI run late while a take is written), the `/fail /b_readChannel` message format on norns' scsynth, a scene-fade step's real duration against the 1 s overrun bound, the sequencer's `clock.sleep(0)` deferral after a PSET read from the menu, frame-clock CPU with the arc spinning, with the LFO page drawing at 15 fps and with drift redraws, tempo following under Link and MIDI clock, the font's real glyph widths against the harness estimate, arc LEDs at a ring's maximum and minimum, and brief "not loaded" or file-list flashes after a slow reload or a file choice.
  - The `●`/`○` glyph check listed on #6 no longer applies: the voice list uses ASCII marks since 3.0.2 (see Decisions).
- **Known and accepted, no action:**
  - A buffer slot's internal `restoring` flag can stay set after a restore that never gets audio. Nothing reads it except when audio is confirmed.
  - Pressing a sequence-length key on the grid repaints the grid twice (one extra 128-LED refresh).
  - The arc keeps redrawing while the norns menu is open (the screen does not), so a param changed from PARAMS, a CC map or an LFO moves the rings at once.
  - The engine check's timeout kills sclang's child processes through `pgrep`. On a machine without `pgrep` and without `timeout`, a hung scsynth may outlive the check.
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
- **Fixed `PitchShift` window and 128-grain tables:** the window is 0.1 s whatever the grain size, and `maxGrains` 128 still covers Lua's largest overlap (0.5 s × 200 grains/s; a Lua test keeps it so). If wrong: pitch-shifted voices at large grain sizes sound different; the window is one engine variable (`pitchShiftWindow`).
- **Resonator gain and limiter:** a fixed gain cut plus a limiter on that voice only, with no make-up gain elsewhere; voice 1 as a crossmod source became much weaker. If wrong: patches that relied on the old strength modulate less; listen on #6.
- **Pan on the 256 fader pages** for buffer- and input-sourced voices, now that their grain synths pan. If wrong: one more fader page entry.
- **Normalized randomize and mutation** applies to Lua's randomize and mutation of synth and buffer params. Grain size, pitch and spread and the Lua drifts already use linear specs and are unchanged; the engine's tape drift is untouched. If wrong: none.
- **Synchronous decode check on load:** a load decodes the file before reading it, an estimated 0.2 s per FLAC on a CM3, which stalls engine commands briefly during a load the user started. A file may decode up to `loadShortfallFrames` (4096 frames, one FLAC block) short of its header. If wrong: measure on #6; move the check off the command path if the stall is audible.
- **A failed instant recall keeps the previous scene current**, so the header shows what is really loaded. If wrong: none.
- **The test clock follows matron:** tie order (sleeps before syncs, event slots in order) and the 100-slot limit match matron's scheduler, so tests see the order norns runs clocks in. If wrong: tests that depend on tie order need updating along with the stub.
- **The `tempo` param takes the clock's range** (`clock_tempo`'s 1-300 BPM), so any clock tempo is captured and recalled. If wrong: none.
- **Docs layout:** this file and the 3.0 design live under `docs/` (`docs/status.md`, `docs/design/3.0-design.md`), and the old implementation plans were removed. If wrong: links to the old paths break; git history keeps the files.
- **3.0's features are described as Strata's own**, with no reference to the earlier, unreleased script they were first sketched for. Git history, commit messages and old pull request titles keep their wording, since rewriting them would mean force-pushing the protected `main`. If wrong: none; the name survives only in history.
