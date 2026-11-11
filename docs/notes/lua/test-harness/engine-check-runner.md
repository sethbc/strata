## Must not break

- Only one engine check runs per scsynth port: runs on the same port collide.
- `test/StrataTestNoBoot.sc.in`, `test/StrataTestTempDir.sc.in` and `test/StrataTestNoBootOSX.sc.in` stay `.sc.in` files: norns compiles every `.sc` under `~/dust`, and these test classes disable Crone's boot and replace the platform's temp dir. A structure test fails on any tracked `.sc` that is not `lib/Engine_Strata.sc` or `lib/engine/Strata*.sc` (#332), and `.gitignore` keeps `test/**/*.sc` out of a commit.
- A signal (INT, TERM, HUP) to the script stops sclang's whole tree, its scsynth and the work folder, and exits 130 (#331; GNU `timeout` keeps sclang in a process group of its own, so the script's death alone would leave it running on the port).
- Any `WARNING` line fails a run, as `ERROR` does (#486).
- Every 3.13 container keeps its memory cap, and a run is classified by its log, never by a signal alone (#544, #545; below).
- A failed precondition (an unknown area, a bad port) or a failed start ends the run with its own `ENGINE CHECK FAILED:` line and nothing after it (#485, #471, #472).

## The engine check

`test/run_engine_check.sh [path/to/norns]`:
- compiles `lib/Engine_Strata.sc` against the real norns `sc/core` classes (default `~/src/norns`, or `$NORNS_DIR`);
- boots a local scsynth with its output on a private bus (silent) and runs `test/engine_check.scd`, which drives every engine command.

Its own SynthDefs, to hear what a bus carries:
- `\strataCheckTone`: a 440 Hz tone written into `inputBus`;
- `\strataCheckPeak`: a resettable peak meter on a stereo bus;
- `\strataCheckSine`/`\strataCheckStep`: a sine of any frequency, and the largest sample-to-sample step on a bus, for the filter crossfade;
- added by `addAudioCheckDefs`: `\strataCheckChannelPeaks` (per-channel peaks, for pan), `\strataCheckBadValues` (NaN/inf seen on a bus), `\strataCheckRms` (a bus's RMS over about 1.5 s) and `\strataCheckBadSource` (50 ms of inf and NaN; a float overflow, since `log(0)` is not -inf in scsynth).

Structure:
- The check routine is at sclang's per-function selector limit: new checks go in top-level functions called from it.
- Every server reply it waits for goes through `awaitReply` (5 s, then a FAIL), and the whole check fails after its deadline (`STRATA_ENGINE_CHECK_DEADLINE`, the timeout less 30 s: 1170 s by default, 540 s in CI), so a reply that never comes fails the check instead of hanging it (CI kills the job at 600 s and passes `ENGINE_CHECK_TIMEOUT=570`).

What fails it, besides a failed check: any output line with `ERROR` or `WARNING` at its start, `FAILURE` (the server's report of a failed command), `alloc failed`, `Too many grains` (a grain UGen past `maxGrains`) or `Strata invariant broken`.

Timeouts and processes:
- The script runs sclang under `timeout` (`ENGINE_CHECK_TIMEOUT`, default 1200 s; a full run of every area takes about 12 minutes on 3.14.1, CI shards set 570 s) with line-buffered output (`stdbuf`).
- It stops sclang as soon as the output shows a compile error (a syntax error in `engine_check.scd`, `Library has not been compiled successfully`): sclang never exits by itself then, and would hold the machine and CI's job until killed.
- `timeout` signals the whole process group, so the scsynth sclang booted goes too. Without a `timeout` command, the script's own watch loop enforces the limit.
- It stops the scsynth too, even after a sclang crash (through the PID the check writes to its work dir, #152), without needing `pgrep` or `timeout`.
- The script's own stop signals sclang and every descendant (`kill_tree`, children first), so no scsynth is left on its port. Exit 124 or 137 (timeout's `--kill-after` SIGKILL) reports as a timeout. A signal to the script itself runs the same stop (`stop_on_signal`) and exits 130.

Start-up (the check's own, `test/engine_check.scd`):
- Before booting, it sends `/status` to `$STRATA_SC_PORT`; any reply fails the run at once with `ENGINE CHECK FAILED: port <n> already has a server`, and it never quits a server it did not start (#471).
- A scsynth that exits without booting (a port held by a program that does not answer, JACK not running) fails the run within seconds with `ENGINE CHECK FAILED: scsynth did not boot` instead of at the deadline (#472). The script's summary prints scsynth's `*** ERROR` lines.
- The temp dir override the check needs lives in `test/StrataTestTempDir.sc.in`, copied into a `SystemOverwrites` folder of the work dir's classes, where sclang does not warn that an extension overwrites a system method (#486).
- CI's engine shards also run the check with an unknown area and require its failure line without an `ERROR` line (#485). The waveform shard also runs it against a port a `scsynth` already holds (the failure line naming the port, and that server still running afterward, #471) and against a port held by a silent UDP socket (`scsynth did not boot` within 40 s, #472). A boot is ended by a watch on the server's pid: `waitForBoot`'s own limit and `onFailure` are not applied by sclang 3.13 or 3.14.1.

Ports:
- Each run boots scsynth on `$STRATA_SC_PORT` (default 57110). Runs on different ports (avoid 57120 and the few above it, used by sclang itself) can overlap; runs on the same port collide. `docs/status.md` (Running the checks) has the details.

Setup:
- Needs SuperCollider: sclang is `$SCLANG` if set, else `sclang` on `PATH`, else the macOS app path.
- On Linux scsynth also needs a running JACK server. CI and local runs use a dummy driver: `jackd --no-realtime -d dummy -r 48000 -p 1024 &` (check with `jack_lsp`). `QT_QPA_PLATFORM=offscreen` keeps sclang headless.

### The engine check on SuperCollider 3.13 (Docker)

`test/run_engine_check_313.sh [-n runs] [-j parallel] [-o log_dir] [path/to/norns]` runs the engine check on SuperCollider 3.13, norns' version, whatever version the machine has:
- The image (`strata-sc313`, from `test/docker/sc313/Dockerfile`) is CI's setup: Ubuntu 24.04, `supercollider-language` and `supercollider-server` at CI's `SC_APT_VERSION` (`1:3.13.0+repack-1ubuntu3`; a docs test checks the two pins match), `jackd2`, `procps` and `coreutils`. Its `check` command (`test/docker/sc313/check.sh`) starts a dummy JACK, waits for `jack_lsp`, then runs `test/run_engine_check.sh /norns` on the repo at `/src`.
- The script builds the image when it is missing or the folder's files changed (the image's `strata.dockerfile-sha256` label holds their hash), so a fresh machine needs no manual step. The one-time build takes about a minute (55 s measured; longer on a slow connection: it downloads Ubuntu 24.04 and its SuperCollider and JACK packages, about 230 MB); later runs reuse the image.
- Each run is `docker run --rm --user $(id -u):$(id -g) -e HOME=/tmp -e XDG_RUNTIME_DIR=/tmp -v <repo>:/src:ro -v <norns>:/norns:ro strata-sc313 check`. It runs as a non-root user because QtWebEngine refuses root. The mounts are read-only: the check writes only to its container's `/tmp`.
- Every container has its own network, so parallel runs never clash on a port. Local sclang runs exhaust sclang's language ports past a few at once, so use this script for more than three or four parallel runs.
- `-n` is the number of runs (1), `-j` how many run at once (1), `-o` the log folder (created if missing; default a new `${TMPDIR:-/tmp}/strata-sc313-logs.XXXXXX`), with run `<i>`'s output in `run-<i>.log`. The script never deletes a log. `STRATA_ENGINE_CHECK_AREAS`, `ENGINE_CHECK_TIMEOUT`, `STRATA_SOAK_ROUNDS` and `STRATA_SOAK_SECONDS` pass through to every run.
- Every container has a memory cap, `--memory` and `--memory-swap` both `$STRATA_SC313_MEMORY` (default 8g; a healthy run of every area peaked at 1.42 GiB, sampled with `docker stats` every 3 s), so a collector gone wrong (#211) is killed inside its own container and not by the machine's out-of-memory killer, which once took sclang at 59 GB (#544). The image's `check` command prints `strata cgroup oom_kill: <n>` from the container's `memory.events` (cgroup v2) after the run.
- The summary classifies each run by its log, in this order (#545): **passed** (status 0); **failed** (any `FAIL`, `ERROR` or `Strata invariant broken` line, whatever ended it, with a note when the collector or the cap was involved too); **capped** (the cap killed a process: `oom_kill` above 0 in the container's own count); **killed** (exit 137 with no cap kill: stopped from outside, such as a `docker kill`); **collector failure** (sclang ended on a signal after the collector's count-error lines: #211); **crashed** (a signal with none of those: #131). The script exits 0 only when every run passed. `-c` classifies the runs already in the `-o` folder (required; it makes no folder) and starts nothing (the structure test feeds it fixture logs); the structure test also runs the script against a fake `docker` and checks that `docker run` carries the cap. An interrupt stops only the containers this run started (named `strata-sc313-<pid>-<i>`).
- Example, #131's rate on the files area: `STRATA_ENGINE_CHECK_AREAS=files test/run_engine_check_313.sh -n 16 -j 8 -o /tmp/files-313`.
