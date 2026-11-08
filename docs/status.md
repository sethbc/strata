# Strata development status

Last updated 2026-11-07, at the 3.1.0 release. This file is the hand-off between machines and sessions: what is still open, how to run the checks, and where the details live (the decisions are in `docs/decisions.md`). Update it at the end of each piece of work.

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
  - force pushes and deleting `main` are blocked;
  - history must be linear: pull requests merge by rebase (or squash), never with a merge commit, and branches are updated by rebasing on `main`.
- **CI pins:** norns commit `227aa044` (the engine is compiled against its `sc/core`), SuperCollider `1:3.13.0+repack-1ubuntu3` (Ubuntu 24.04's package; norns ships 3.13.0) and `actions/checkout` by commit. The workflow's comments say how to move each pin.
- **Docs layout:**
  - AGENTS.md is an index: the rules every change needs, the engine command table, how to run the checks, the "Working in parallel" rules, and a table mapping each module to its notes file and its unit tests. Keep it short: put module details in that module's notes file.
  - The Lua notes are one file per module under docs/notes/lua/ (state and voices, engine sync, buffers, LFOs, mutation, scenes, MIDI, params, the UI core, the arc core and page rings, the grid core, the sequencer, the test harness and the version history), plus one per screen page (docs/notes/lua/pages/) and per grid layout (docs/notes/lua/grid/). Each opens with "## Must not break"; AGENTS.md folds in the rules that span modules. `docs/notes/lua.md` now only maps the old sections to the new files; it stays while `docs/notes/engine.md`, a comment in `strata.lua` and the docs tests (`test/unit/docs_test.lua`, `test/helpers.lua`) still name it.
  - `docs/notes/engine.md` is the engine's implementation reference. It splits per module with the engine in 3.2.
  - `docs/design/3.0-design.md` is the 3.0 design, still the reference for behavior; CHANGELOG.md's 3.0 "Deviations from the design" and the later entries say where the code differs.
  - `docs/design/3.1-3.6-roadmap.md` is the agreed order and scope of the next releases (3.1 to 3.6) with the decisions taken on it. Each release still gets its own design document before code: `docs/design/3.1-design.md` (shipped as 3.1.0) and `docs/design/3.2-design.md` (approved). Implementation plans are under docs/superpowers/plans/.
  - README.md is a short overview, quick start and index; the user documentation is one page per area under docs/user/ (`docs/user/controls.md`, `docs/user/grid.md`, ...), with one page per screen page under docs/user/pages/ and per grid size under docs/user/grid/. CHANGELOG.md holds the per-release changes (pull requests add fragments under changes/, merged at each release), this file the open items, and `docs/decisions.md` the decisions taken during development, one section per release.
  - The 3.0 and 3.0.1 implementation plans were removed in 3.0.2, and the 3.1 plans (Wave 0's restructure, Waves 1 and 2) after the 3.1.0 release; git history keeps them, and CHANGELOG.md's 3.1.0 entry says what they built. The 3.2 plan stays until the 3.2 release removes it.
  - The tests check the maintained docs (AGENTS.md, README.md, this file, `docs/decisions.md` and every `.md` under docs/notes/, recursively, docs/user/ and docs/process/): AGENTS.md's command table must match the engine, no `engine.<name>(` may name a command the engine lacks, every path under docs/, test/, .github/ or lib/ they name must exist, relative links resolve from each doc's folder, and every docs/notes/lua/ file opens with "## Must not break".

## Running the checks

- **Lua:** `lua test/run.lua`, `luajit test/run.lua` and `lua test/sync_check.lua`, from the repo root. They need only Lua 5.3 (norns' version) and LuaJIT.
- **Engine:** `test/run_engine_check.sh [path/to/norns]` compiles the engine against a norns checkout's `sc/core` and runs `test/engine_check.scd` on a silent local scsynth with norns' 8192 KB real-time pool.
  - It needs SuperCollider and a norns checkout (`git clone https://github.com/monome/norns ~/src/norns`, or set `$NORNS_DIR`; CI uses commit `227aa044`).
  - It uses `$SCLANG` if set, else `sclang` on `PATH`, else the macOS app.
  - It stops after `$ENGINE_CHECK_TIMEOUT` seconds (570 by default, below CI's 600) and at once on a compile error. Stopping sclang also stops its scsynth (descendants found with POSIX `ps`, so neither `pgrep` nor `timeout` is needed), and a scsynth that outlives a crashed sclang is stopped through the PID the check writes to its work dir (#152).
  - Each run boots scsynth on the UDP port in `$STRATA_SC_PORT` (57110 by default). Runs on different ports can overlap, for example one per worktree (`STRATA_SC_PORT=57141 test/run_engine_check.sh`); avoid 57120 and the few ports above it, which sclang takes for itself when several run. Two runs on the same port collide, so on a shared machine give each its own port or wrap the runs in a lock, for example `flock /tmp/strata-engine-check.lock test/run_engine_check.sh`.
- **Soak** (on demand, not in CI or a full run): `STRATA_ENGINE_CHECK_AREAS=soak test/run_engine_check.sh` runs rounds of a 60 s load, save and every-frame check of the saved file on a high engine of its own, to stress sclang's allocation as a long session would (#131). `STRATA_SOAK_ROUNDS` (40) and `STRATA_SOAK_SECONDS` (60; 120 or 300) size it; give a long soak a longer `ENGINE_CHECK_TIMEOUT` (the check's own deadline follows, 30 s under it). Run it with SuperCollider 3.13, norns' version, to be meaningful.
- **Engine check on SuperCollider 3.13:** `test/run_engine_check_313.sh [-n runs] [-j parallel] [-o log_dir]` runs the check in Docker on CI's SuperCollider (norns' 3.13), one container per run, so many can run at once; it builds its image (`test/docker/sc313/Dockerfile`) on first use and reports how many runs passed, failed or crashed (#131). Details in `docs/notes/lua/test-harness.md`.
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
- [#131](https://github.com/sethbc/strata/issues/131) **sclang's garbage collector under heavy allocation (a platform limit):** norns' SuperCollider 3.13 keeps the collector's scan count in an int32 that overflows under millions of small allocations, and sclang crashes later; 3.14.1 made it int64 but has crashed the same way once too, so more than one collector bug is involved. Strata works around it on every version: no `LocalBuf` (#132), fresh `readData` arrays (#141), and now no sclang function per sample in the engine's interleave or the engine check's test sound and file checks (`docs/notes/engine/files.md`, sclang's garbage collector under heavy allocation), with freeze and memory in different CI shards. Full 3.13 checks, 16 in parallel: 10 of 16 completed before (6 crashes, mostly just after the files area), 32 of 32 after (two failed a load-sensitive reverb RT60 measurement, no crash); on 3.14.1, 8 in parallel, 6 of 8 before (two crashes just after files) and 8 of 8 after. The 300 s soak (`STRATA_ENGINE_CHECK_AREAS=soak STRATA_SOAK_SECONDS=300`) crashed 3.13 near its tenth round because the check's poll Lists grew past 128 entries inside their OSC responder; made with room for every message (`pollListCapacity`), 40-round 300 s soaks passed 6 of 6 with `STRATA_SOAK_CHECK=length` (2 of 6 before) and 5 of 6 with the every-frame check (one failed count assertion in round 3, a different trigger still to find). Full 3.13 checks with it: 16 of 16 passed. The rarer early failures (a count assertion in round 3, a hang in round 1, about 1 every-frame soak in 9) are sclang's collector too: the language stopped (its own deadline never fired), early in a run, after two engine builds; 24 soaks of 120 rounds (every-frame, `length` and leaner) all passed. Still to do: the soak on a norns.
- [#113](https://github.com/sethbc/strata/issues/113) **Grid playhead one step ahead between steps:** a grid redraw between pattern steps lights the next step, while SEQ draws the sounding one. Not new in 3.1; a shared "sounding step" helper fixes both.
- [#6](https://github.com/sethbc/strata/issues/6) **Hardware check on norns:** the essential checks for 3.2 (about 40 minutes) are in the issue.
- **Limits to keep in mind:**
  - Lua's 200-local limit applies to each function: the locals probe in `test/run.lua` measures the free locals at the end of each file's main chunk and of each module's constructor function, and requires 30 in each (`strata.lua`'s main chunk uses 5). Group new constants into tables, and split a module that runs short.
  - LFOs top out at 10 Hz, the norns `lfo` library's ceiling. Anything faster belongs in the engine.
  - scsynth's real-time pool on norns is 8192 KB and the measured peak is about 6.9 MB (`docs/notes/engine.md`, Real-time memory). A new UGen with a delay line or table in the voice or grain SynthDefs needs that budget re-measured.

## Decisions taken during development

They are in `docs/decisions.md`, one section per release, each with what it costs if wrong.
