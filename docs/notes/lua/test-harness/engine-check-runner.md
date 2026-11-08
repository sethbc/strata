## Must not break

- Only one engine check runs per scsynth port: runs on the same port collide.
- `test/StrataTestNoBoot.sc.in` stays a `.sc.in` file: norns compiles every `.sc` under `~/dust`, and that test class disables Crone's boot.

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
- Every server reply it waits for goes through `awaitReply` (5 s, then a FAIL), and the whole check fails after 540 s, so a reply that never comes fails the check instead of hanging it (CI kills the job at 600 s).

What fails it, besides a failed check: any output line with `ERROR` at its start, `FAILURE` (the server's report of a failed command), `alloc failed`, `Too many grains` (a grain UGen past `maxGrains`) or `Strata invariant broken`.

Timeouts and processes:
- The script runs sclang under `timeout` (`ENGINE_CHECK_TIMEOUT`, default 570 s; a normal run takes about 2 minutes) with line-buffered output (`stdbuf`).
- It stops sclang as soon as the output shows a compile error (a syntax error in `engine_check.scd`, `Library has not been compiled successfully`): sclang never exits by itself then, and would hold the machine and CI's job until killed.
- `timeout` signals the whole process group, so the scsynth sclang booted goes too. Without a `timeout` command, the script's own watch loop enforces the limit.
- It stops the scsynth too, even after a sclang crash (through the PID the check writes to its work dir, #152), without needing `pgrep` or `timeout`.
- The script's own stop signals sclang and every descendant (`kill_tree`, children first), so no scsynth is left on its port. Exit 124 or 137 (timeout's `--kill-after` SIGKILL) reports as a timeout.

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
- The summary counts the runs that passed, failed, and crashed (sclang ended on a signal, #131's failure), and the script exits 0 only when every run passed. An interrupt stops only the containers this run started (named `strata-sc313-<pid>-<i>`).
- Example, #131's rate on the files area: `STRATA_ENGINE_CHECK_AREAS=files test/run_engine_check_313.sh -n 16 -j 8 -o /tmp/files-313`.
