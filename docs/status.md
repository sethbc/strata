# Strata development status

Last updated 2026-11-09, at the 3.2.0 release. This file is the hand-off between machines and sessions: what is still open, how to run the checks, and where the details live (the decisions are in `docs/decisions.md`). Update it at the end of each piece of work.

## Where things are

- **Released on `main`:**
  - 3.0 (sample and input sources, filter and delay, grain envelopes and triggered grains, LFOs, MIDI, paged screen) through PR #3, and CI through PR #4.
  - 3.0.1, the minor findings deferred from the 3.0 reviews, through PR #7.
  - 3.0.2, the fixes from a whole-codebase review of 3.0.1 (issues #10-#27), from a final review of those fixes (#46-#52) and #5, one pull request per issue (#28-#45, #53-#59, then the docs pull request that closes #52). CHANGELOG.md lists each fix with its pull request.
  - 3.1.0, playable from the norns alone (`docs/design/3.1-design.md`): Wave 0, the restructure for parallel work (#62-#79, fixing #67, #68, #72 and #73 on the way); Wave 1, the shared UI, grid and arc interfaces (#80-#90, #94, and #93 for #91); Wave 2, twelve page, grid and arc packages built in parallel (#95-#108); Wave 3, the docs pass (#110), the follow-ups (#111), the final-review fixes (#115) and the release.
  - 3.2.0, the performance setting and one grain path (`docs/design/3.2-design.md`): Wave 0, the engine split, the check per area and the Lua registries; Wave 1, the performance setting and the grain path; Wave 2, freeze, variation, loop regions, the voice mix and long buffers, built in parallel; Wave 3, one issue and pull request per remaining finding, the docs restructure and the release. The tag follows the hardware check (#6).
- **CI:** `.github/workflows/test.yml` runs `lua` and the engine check in five parallel shards (memory alone, #131) (`engine (<areas>)`, one runner each, about 2.5 minutes in all instead of 6), gathered by one `engine` job that passes only when every shard passed. The shards are balanced from the per-area times the check prints; `test/unit/docs_test.lua` checks that every area is in exactly one. A new push to a pull request cancels its older runs; runs on `main` are never canceled. `main` is protected:
  - every change goes through a pull request, with no approvals required;
  - both jobs must pass on a branch that is up to date with `main`;
  - the rules apply to admins too;
  - force pushes and deleting `main` are blocked;
  - history must be linear: pull requests merge by rebase (or squash), never with a merge commit, and branches are updated by rebasing on `main`.
- **CI pins:** norns commit `227aa044` (the engine is compiled against its `sc/core`), SuperCollider `1:3.13.0+repack-1ubuntu3` (Ubuntu 24.04's package; norns ships 3.13.0) and `actions/checkout` by commit. The workflow's comments say how to move each pin.
- **Docs layout:**
  - AGENTS.md is an index: the rules every change needs, the engine command table, how to run the checks, the "Working in parallel" rules, and a table mapping each module to its notes file and its unit tests. Keep it short (about 6k words; every agent loads it): each rule is one line naming the notes file whose "Must not break" holds the detail, and module details go in that module's notes file.
  - The Lua notes are one file per module under docs/notes/lua/ (state and voices, engine sync, buffers, LFOs, mutation, scenes, MIDI, params, the UI core, the arc core and page rings, the grid core, the sequencer, the test harness and the version history), plus one per screen page (docs/notes/lua/pages/) and per grid layout (docs/notes/lua/grid/). The UI core and the test harness are split by part under docs/notes/lua/ui/ and docs/notes/lua/test-harness/, with `docs/notes/lua/ui-core.md` and `docs/notes/lua/test-harness.md` as their indexes. Each opens with "## Must not break"; AGENTS.md folds in the rules that span modules.
  - The engine notes are one file per area of the engine check under docs/notes/engine/ (`docs/notes/engine/structure.md`, `docs/notes/engine/memory.md`, ...), each opening with "## Must not break"; an area and its notes file stay one to one.
  - `docs/process/agents.md` says how a session runs work packages through agents.
  - `docs/design/3.0-design.md` is the 3.0 design, still the reference for behavior; CHANGELOG.md's 3.0 "Deviations from the design" and the later entries say where the code differs.
  - `docs/design/3.1-3.6-roadmap.md` is the agreed order and scope of the releases from 3.1 to 3.6 and 4.0, with the decisions taken on it. Each release still gets its own design document before code: `docs/design/3.1-design.md` (shipped as 3.1.0), `docs/design/3.2-design.md` (shipped as 3.2.0), `docs/design/3.3-design.md` and `docs/design/3.4-design.md` (approved). Implementation plans are under docs/superpowers/plans/ while their release is open.
  - README.md is a short overview, quick start and index; the user documentation is one page per area under docs/user/ (`docs/user/controls.md`, `docs/user/grid.md`, ...), with one page per screen page under docs/user/pages/ and per grid size under docs/user/grid/. CHANGELOG.md holds the per-release changes (pull requests add fragments under changes/, merged at each release), this file the open items, and `docs/decisions.md` the decisions taken during development, one section per release.
  - Finished implementation plans are removed at their release (3.0 and 3.0.1 in 3.0.2, the 3.1 plans after 3.1.0, the 3.2 plan at 3.2.0); git history keeps them, and each CHANGELOG.md entry says what they built.
  - The tests check the maintained docs (AGENTS.md, README.md, this file, `docs/decisions.md` and every `.md` under docs/notes/, recursively, docs/user/ and docs/process/): AGENTS.md's command table must match the engine, no `engine.<name>(` may name a command the engine lacks, every path under docs/, test/, .github/ or lib/ they name must exist, relative links resolve from each doc's folder, and every docs/notes/lua/ file opens with "## Must not break".

## Running the checks

- **Lua:** `lua test/run.lua`, `luajit test/run.lua` and `lua test/sync_check.lua`, from the repo root. They need only Lua 5.3 (norns' version) and LuaJIT.
- **Engine:** `test/run_engine_check.sh [path/to/norns]` compiles the engine against a norns checkout's `sc/core` and runs `test/engine_check.scd` on a silent local scsynth with norns' 8192 KB real-time pool.
  - It needs SuperCollider and a norns checkout (`git clone https://github.com/monome/norns ~/src/norns`, or set `$NORNS_DIR`; CI uses commit `227aa044`).
  - It uses `$SCLANG` if set, else `sclang` on `PATH`, else the macOS app.
  - It stops after `$ENGINE_CHECK_TIMEOUT` seconds (1200 by default, which a full run of about 9 minutes on 3.14.1 fits with headroom; CI passes `ENGINE_CHECK_TIMEOUT=570` to keep each shard below its 600 s limit; the check's own deadline is 30 s less) and at once on a compile error. Stopping sclang also stops its scsynth (descendants found with POSIX `ps`, so neither `pgrep` nor `timeout` is needed), and a scsynth that outlives a crashed sclang is stopped through the PID the check writes to its work dir (#152).
  - Each run boots scsynth on the UDP port in `$STRATA_SC_PORT` (57110 by default). Runs on different ports can overlap, for example one per worktree (`STRATA_SC_PORT=57141 test/run_engine_check.sh`); avoid 57120 and the few ports above it, which sclang takes for itself when several run. Two runs on the same port collide, so on a shared machine give each its own port or wrap the runs in a lock, for example `flock /tmp/strata-engine-check.lock test/run_engine_check.sh`.
- **Soak** (on demand, not in CI or a full run): `STRATA_ENGINE_CHECK_AREAS=soak test/run_engine_check.sh` runs rounds of a 60 s load, save and every-frame check of the saved file on a high engine of its own, to stress sclang's allocation as a long session would (#131). `STRATA_SOAK_ROUNDS` (40) and `STRATA_SOAK_SECONDS` (60; 120 or 300) size it; give a long soak a longer `ENGINE_CHECK_TIMEOUT` (the check's own deadline follows, 30 s under it). Run it with SuperCollider 3.13, norns' version, to be meaningful.
- **Engine check on SuperCollider 3.13:** `test/run_engine_check_313.sh [-n runs] [-j parallel] [-o log_dir]` runs the check in Docker on CI's SuperCollider (norns' 3.13), one container per run, so many can run at once; it builds its image (`test/docker/sc313/Dockerfile`) on first use and reports how many runs passed, failed or crashed (#131). Details in `docs/notes/lua/test-harness/engine-check-runner.md`.
- **Page renders** (on demand, not in CI): `lua test/render_pages.lua <dir>` then `python3 test/render_pages.py <dir> --font ~/src/norns/resources/norns.ttf` (needs Pillow) draws every page state as a PNG. The layout tests catch overlaps on one baseline and text off-screen; the renders are the check for text over a line or box and for strings crowding on nearby baselines.
- **Engine check on Linux:** install `supercollider-language`, `supercollider-server` and `jackd2`. scsynth needs a JACK server, and a dummy driver needs no sound card. Start one in the background, then run the check headless:

  ```sh
  nohup jackd --no-realtime -d dummy -r 48000 -p 1024 >/tmp/jackd.log 2>&1 &
  SCLANG=/usr/bin/sclang QT_QPA_PLATFORM=offscreen test/run_engine_check.sh ~/src/norns
  ```

  If scsynth does not boot, check that JACK is running (`jack_lsp` fails when it is not) and start `jackd` again. Run JACK at 48 kHz, like norns.

## What 3.2 changed

CHANGELOG.md has every change. In short:
- **Sound:** every grain synth is a `GrainBuf` pair reading a ring or a slot, so every voice transposes by grain rate and steps per grain, and synth and input voices start milliseconds in the past and spread backward. Every new per-voice setting defaults to 3.1's sound; a Pi 4 or CM4 on `auto` runs high and so the FDN reverb (SETUP `standard` keeps the old one).
- **Performance setting:** auto, standard or high on SETUP. High (a Pi 4 or CM4) has buffers up to 300 s, 60 s of input history, spectral freeze and an FDN reverb.
- **Features:** freeze per voice, reverse grains, pitch, pan and size jitter, interval sets and scale quantize, loop regions, input history, a filter and sends per voice, delay and reverb bypass.
- **Code:** the engine split into `lib/engine/` areas, the engine check per area, registries for the shared Lua spots. Scenes are version 3; new engine files need one norns restart.
- **Tests:** 622 Lua tests.

## Open items

- **Next: 3.3**, recording, files, waveforms and positions (`docs/design/3.3-design.md`, approved; plan `docs/superpowers/plans/2026-11-08-3.3-plan.md`). 3.3 code follows this release.
- **State machine fixes** (plan `docs/superpowers/plans/2026-11-10-state-machine-fixes-plan.md`): 27 fixes from an audit of the script's implicit state machines, one issue and pull request each ([#232](https://github.com/sethbc/strata/issues/232) to [#258](https://github.com/sethbc/strata/issues/258)), merged before 3.3's final review. The audit's engine findings ([#259](https://github.com/sethbc/strata/issues/259) to [#262](https://github.com/sethbc/strata/issues/262)) wait for the pre-4.0 review.
- **3.3 candidate:** a seconds-based scan mode. `bufScan` moves in valid-region lengths per second, so a 300 s slot scans 300 s per second at scan 1; loop regions are the answer until then.
- [#6](https://github.com/sethbc/strata/issues/6) **Hardware check on norns:** the essential checks for 3.2 (about 40 minutes) are in the issue. The maintainer tags 3.2.0 after it.
- **Limits to keep in mind:**
  - Lua's 200-local limit applies to each function: the locals probe in `test/run.lua` measures the free locals at the end of each file's main chunk and of each module's constructor function, and requires 30 in each (`strata.lua`'s main chunk uses 5). Group new constants into tables, and split a module that runs short.
  - LFOs top out at 10 Hz, the norns `lfo` library's ceiling. Anything faster belongs in the engine.
  - scsynth's real-time pool on norns is 8192 KB. 3.2's worst case leaves 4.90-4.94 MB free on standard and, with spectral freeze on every voice and the FDN reverb, 4.24-4.26 MB on high (4.13-4.15 MB counting the spectral writers' late allocations), against floors of 3 MB and 4 MB (`docs/notes/engine/memory.md`). A new UGen with a delay line or table in the voice or grain SynthDefs needs that budget re-measured.
  - sclang's garbage collector fails under millions of small allocations (#131, closed as a platform limit of norns' SuperCollider 3.13). The rules that work around it are in AGENTS.md and `docs/notes/engine/files.md`, the device check is #6 section 6.

## Decisions taken during development

They are in `docs/decisions.md`, one section per release, each with what it costs if wrong.
