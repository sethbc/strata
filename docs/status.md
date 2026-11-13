# Strata development status

Last updated 2026-11-12, after the 3.4.0 release. This file is the hand-off between machines and sessions: what is open, and the limits to plan around. Keep it to that, and update it at the end of each piece of work: a pull request that closes an open item removes its line, and a release updates the first section.

## Where things are

- **Released:** 3.4.0, modulation and sequencing. CHANGELOG.md has every change of every release; `docs/history.md` has each release in a paragraph and how it was built.
- **Plans:** none is open (a plan lives under docs/superpowers/plans/ while its release is open; `docs/workflow.md`).

## Open items

- **Next: 3.5**, polyphony and MPE (`ROADMAP.md`, 3.5), which needs its own design first. 3.4's interfaces for it are listed in `docs/design/3.4-design.md` §14 (the fast-modulation bus's note slots, chords in `notes`, step outputs, modulation sources).
- **Rulings to confirm:** the maintainer has yet to confirm 3.4's rulings marked *To confirm* in `docs/decisions/3.4.md`: the stage's 42 KB and the ring def's 10 KB margin (42, 55), the morph and an LFO one scene stops (30), a grid page change canceling held keys (78), and those that depart from the design's text (76, 77, 80, 81, 82, 87, 88a, 89, 90).
- [#211](https://github.com/sethbc/strata/issues/211) **sclang's collector fails in the waveform area's 300 s load-and-save check** (#131's family): about 1 run in 10 to 16 as measured at the release on SuperCollider 3.13 and 3.14.1, on the 3.3 engine about as often as on 3.4's: the 1 in 80 recorded at 3.3 no longer holds on either, and what changed since was not tested (the machine, the test image's unpinned packages and the kernel are candidates); more under load. The measurements are the issue's comments of 2026-11-12, the last of which (the 3.3 engine against 3.4's, 48 runs each of the area alone on 3.13 in Docker: 45 and 43 passed) corrects the one before it. The check fails with `failed [ 1 ]` after a run of the collector's count-error lines (round 2's load waits out its 60 s, or its save ends early), or sclang ends on signal 11 or signal 8 (with or without those lines first; signal 8 in this release's own full 3.14.1 run), or it hangs after those lines until the check's timeout. A failed `record,waveform` shard (CI's, or the 3.13 runner's) that fails with the collector's count-error lines, sclang ending on signal 11 or signal 8, or a hang after those lines is rerun. Held for now by the maintainer's decision (2026-11-12), to be fixed later, with no release named. Seen twice besides, about 15 minutes into a full single-sclang run on 3.14.1, at the start of the `modulation` area (once in the 3.4 fix wave, once in #578's runs): a silent hang (the check's own deadline never fired) and a truncated UGen name in the area's first `addCheckDefs`; ten repetitions of that stretch did not hang, and it is possibly the same collector problem showing another way.
- **Candidate:** a seconds-based scan mode. `bufScan` moves in valid-region lengths per second, so a 300 s slot scans 300 s per second at scan 1; loop regions are the answer until then.
- [#6](https://github.com/sethbc/strata/issues/6) **Hardware check on norns:** held until 4.0; it gates no 3.x release. Its 3.4 additions (the engine's CPU with six engine LFOs and scatter, an hour's soak of every message source, the step keys by hand, transport following) are in the issue.

## Limits to keep in mind

- Lua's 200-local limit applies to each function: the locals probe in `test/run.lua` measures the free locals at the end of each file's main chunk and of each module's constructor function, and requires 30 in each (`strata.lua`'s main chunk uses 5). Group new constants into tables, and split a module that runs short.
- An LFO that runs in Lua plays at most 10 Hz (`LFO.lua_max_hz`) and sends at most 12 values a 48 Hz step with the matrix's (576 a second); one on a fast destination runs in the engine, up to 50 Hz. A modulation writer's sends share 150 messages per 100 ms (`ENGINE_BUDGET`), counting exactly the messages that reach the engine; a recall's or a morph crossing's discrete switches (voice starts and stops, source switches) go at once outside the count (ruling 93: about 60 messages a voice start, 417 for a crossing that starts all seven, and a crossing at most once per 0.3 s, ruling 94). The budget is a number the hardware soak (#6) is to confirm.
- scsynth's real-time pool on norns is 8192 KB. With six engine LFOs and scatter running on every voice and destination, 3.4.0's worst cases leave 4.79-4.99 MB free on standard and, with spectral freeze on every voice and the FDN reverb, 4.12 MB on high at the tightest, synth -> buffer -> synth (536 KB above the 3.5 MB floor, about 424 KB counting the spectral writers' late allocations), and 4.88 MB at the all-buffer one, as CI's memory shard measures them; `\strataGrainBuf` is 69.1 KB of its 88 KB limit and each mix stage 40.9 KB of 42 (`docs/notes/engine/memory.md`). A new UGen with a delay line or table in the voice or grain SynthDefs, or a node per voice, needs that budget re-measured.
- The largest scenes file 3.4 can write (sixteen scenes of full macros, routings and step attributes) is 7394 tables, under a quarter of the data file reader's cap of 32768 (`lib/data_files.lua`); a later block with tables per step (3.5's chords) re-measures it, since a file over the cap is refused whole.
- sclang's garbage collector fails under millions of small allocations (#131, closed as a platform limit of norns' SuperCollider 3.13; seen once on 3.14.1 too while 3.4 was built). The rules that work around it are in AGENTS.md and `docs/notes/engine/files.md`, the device check is #6 section 6, and the 3.4 command rates' soak is #6's too.

## Where the rest is

- **Rules and the map of the docs:** AGENTS.md.
- **Running the checks, and CI:** `docs/checks.md`.
- **How a session runs work through agents:** `docs/workflow.md`.
- **The order and scope of the coming releases:** `ROADMAP.md`.
- **Decisions taken during development**, each with what it costs if wrong: docs/decisions/, one file per release line (`docs/decisions/README.md`).
