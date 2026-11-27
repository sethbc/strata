# Reproducing the November 26 observations

These fixtures reproduce observations on the v3.9.0 runtime (`d8621dd5`). Their `.txt` extensions keep norns from listing the Lua examples as playable scripts. From the root of the checkout containing this guide, export the historical source to a temporary directory. Run the following examples in the same shell.

```sh
fixtures="$PWD/docs/design/2026-11-26-state-machine-facts/probes"
audit_tmp=$(mktemp -d)
mkdir "$audit_tmp/runtime"
git archive --output="$audit_tmp/runtime.tar" d8621dd5
tar -xf "$audit_tmp/runtime.tar" -C "$audit_tmp/runtime"
cd "$audit_tmp/runtime"
```

## Lua

Prepare the four harness tests in a private temporary directory. On this revision each runtime exits with status 1 and reports 20 tests, with the 10 failing alternate paths named in the musical inventory. The standalone probes print both outcomes.

```sh
mkdir "$audit_tmp/unit"
for file in "$fixtures"/*_test.lua.txt; do
  name=$(basename "$file" .txt)
  cp "$file" "$audit_tmp/unit/$name"
done
for vm in lua luajit; do
  "$vm" test/run.lua --jobs 1 --dir "$audit_tmp/unit"
  for probe in strata-save-audit strata-scan-release-audit strata-surfaces-probe position-bookmark txo-reconcile target-release; do
    "$vm" "$fixtures/$probe.lua.txt"
  done
done
```

The musical inventory also gives the sequence for the independent shrink/expand test (position 11 → 1 → 11). The grid traces give coordinates and release order. The TXo probe includes a counterexample to using the ordinary owed-off queue for configuration. The target-release fixture inspects the old target, last gate line and next note for all seven adapters.

## SuperCollider

Use the prerequisites in [the engine check instructions](../../checks.md), including a norns source checkout and JACK on Linux. The examples use the registered command dispatch and a real scsynth. The wrapper delays one selected rename only inside the test process. Replace the three check areas in the temporary source tree. Set `NORNS_DIR` to the norns source checkout if it lives outside `~/src/norns`. Choose a free port.

```sh
mkdir "$audit_tmp/bin"
cp "$fixtures/save-command-mv.sh.txt" "$audit_tmp/bin/mv"
chmod 700 "$audit_tmp/bin/mv"
cp "$fixtures/save-command-area.scd.txt" "test/engine_check/files.scd"
cp "$fixtures/publication-command-area.scd.txt" "test/engine_check/onsets.scd"
cp "$fixtures/publication-reload-area.scd.txt" "test/engine_check/waveform.scd"
(
set -e
for area in files onsets waveform; do
  QT_QPA_PLATFORM=offscreen STRATA_SAVE_PROBE_BIN="$audit_tmp/bin" STRATA_SC_PORT=57179 \
    STRATA_ENGINE_CHECK_AREAS="$area" test/run_engine_check.sh
done
)
```

With the pinned implementation each characterization area finishes with `ENGINE CHECK PASSED`. The decisive lines are the final WAV going from 5,513 to 11,025 frames, onset marker 8192 becoming 4096 while the audio stays new, and the successor engine's 4,410-frame WAV becoming 11,025. The result means the fixture observed the described defect. The full stock engine suites and the norns hardware checks are separate.
