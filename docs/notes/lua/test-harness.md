## Must not break

- Each part of the test harness has its own notes file under docs/notes/lua/test-harness/ (listed below), each opening with its own "Must not break" list. Read the one for the part you change.

## Files

The test harness's notes, one file per part:
- [run-and-helpers](test-harness/run-and-helpers.md): the Lua test run, the unit files and `test/helpers.lua`, temporary folders, reaching script state, the module safety nets and the docs checks.
- [stubs](test-harness/stubs.md): the norns stubs: params, param types and group sizes, the libraries.
- [clock](test-harness/clock.md): the clock stub, after matron's scheduler: time, waits, tempo, event slots, driving it from a test, errors in clocks.
- [engine-stub-and-sync](test-harness/engine-stub-and-sync.md): the engine stub (signatures, ranges, param names, the parsed spec) and the sync check.
- [engine-check-runner](test-harness/engine-check-runner.md): `test/run_engine_check.sh` and the engine check, and `test/run_engine_check_313.sh` (SuperCollider 3.13 in Docker).

## Owns

`test/run.lua` (the runner), `test/helpers.lua` (the shared harness), the unit files under test/unit/ (one per module; AGENTS.md's module table names each), `test/norns_stubs.lua`, `test/stub_lfo.lua`, `test/stub_midi.lua`, `test/sync_check.lua`, `test/run_engine_check.sh`, `test/run_engine_check_313.sh` and its image (`test/docker/sc313/Dockerfile`, `test/docker/sc313/check.sh`), `test/engine_check.scd`, `test/StrataTestNoBoot.sc.in`.

## On hardware

On norns, norns shield or fates:
- Use maiden (the norns web IDE at `http://norns.local/maiden`) to edit files and watch the console.
- The maiden REPL is useful for trying Lua code.
- SuperCollider changes need a script restart.
- Watch for errors in the maiden console (bottom panel).
