#!/bin/sh
# Compile lib/Engine_Strata.sc against the real norns CroneEngine classes and
# run test/engine_check.scd, which boots a local scsynth (output routed to a
# private bus, so it is silent) and exercises every engine command.
#
# usage: [STRATA_SC_PORT=57141] test/run_engine_check.sh [path/to/norns]
#   STRATA_SC_PORT is the UDP port scsynth boots on (default 57110). Give each
#   run its own port to run checks side by side (one per worktree); avoid
#   sclang's own language port (57120, and the few above it when several
#   sclang processes run). Two runs on the same port collide.
#   NORNS_DIR / SCLANG environment variables override the defaults. sclang is
#   $SCLANG if set, else `sclang` on PATH, else the macOS SuperCollider app.
#   scsynth needs a running JACK server on Linux (see README, Development).
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
norns_dir=${1:-${NORNS_DIR:-$HOME/src/norns}}
mac_sclang=/Applications/SuperCollider.app/Contents/MacOS/sclang
if [ -n "${SCLANG:-}" ]; then
  sclang=$SCLANG
elif command -v sclang >/dev/null 2>&1; then
  sclang=$(command -v sclang)
else
  sclang=$mac_sclang
fi

if [ ! -d "$norns_dir/sc/core" ]; then
  echo "norns source not found at $norns_dir (pass it as the first argument)" >&2
  exit 2
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir/classes"
cp "$script_dir/StrataTestNoBoot.sc.in" "$work_dir/classes/StrataTestNoBoot.sc"

cat > "$work_dir/sclang_conf.yaml" <<YAML
includePaths:
    - $norns_dir/sc/core
    - $repo_root/lib
    - $work_dir/classes
excludePaths: []
postInlineWarnings: false  # norns' own Crone.sc triggers inline warnings
YAML

# sclang never exits by itself when engine_check.scd or the class library
# fails to compile: it waits at its prompt, holding the caller's lock (and
# CI's job) for good. So the run is wrapped in timeout (sclang_timeout
# seconds: a normal run takes about 2 minutes, the check's own deadline is
# 540 s, CI's is 600 s) and killed as soon as sclang reports a compile error.
# timeout signals the whole process group, the scsynth sclang booted
# included; the script's own stop (and its limit, when there is no timeout
# command) signals every descendant, so no scsynth is left holding its
# port. stdbuf makes sclang's output line-buffered, so an error is in the
# output file while sclang waits (block-buffered, it never would be).
sclang_timeout=${ENGINE_CHECK_TIMEOUT:-570}
compile_error='^ERROR: (syntax error|Command line parse failed|file .* parse failed)|Library has not been compiled successfully'
timeout_cmd=$(command -v timeout || command -v gtimeout || true)
stdbuf_cmd=$(command -v stdbuf || command -v gstdbuf || true)
set --
[ -n "$timeout_cmd" ] && set -- "$timeout_cmd" --kill-after=10 "$sclang_timeout"
[ -n "$stdbuf_cmd" ] && set -- "$@" "$stdbuf_cmd" -oL -eL

# Signal a process and all its descendants, children first (once the
# parent is gone they would be re-parented out of reach)
kill_tree() (
  for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child"; done
  kill "$1" 2>/dev/null
)

output="$work_dir/output.txt"
set +e
# started from the temp dir: anything the check writes to its working
# directory is removed with it, never left in the caller's directory
(cd "$work_dir" && STRATA_CHECK_TMPDIR="$work_dir" exec "$@" "$sclang" -l "$work_dir/sclang_conf.yaml" "$script_dir/engine_check.scd") > "$output" 2>&1 &
sclang_pid=$!
# Without a timeout command this loop enforces the limit itself
elapsed=0
stopped=
while kill -0 "$sclang_pid" 2>/dev/null; do
  if grep -qE "$compile_error" "$output"; then
    stopped="sclang reported a compile error"
  elif [ "$elapsed" -ge $((sclang_timeout + 15)) ]; then
    stopped="no result within $sclang_timeout s"
  fi
  if [ -n "$stopped" ]; then
    kill_tree "$sclang_pid"
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done
wait "$sclang_pid"
status=$?
set -e
# 124: timeout stopped it; 137: timeout's --kill-after SIGKILL
if [ -z "$stopped" ] && { [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; }; then
  stopped="no result within $sclang_timeout s"
fi
if [ -n "$stopped" ]; then
  echo "ENGINE CHECK FAILED: $stopped; sclang stopped" >&2
fi

# keep the interesting lines: class-library errors and the check results
grep -E "^(ok |FAIL|ERROR|WARNING|ENGINE CHECK|compiled)|FAILURE|alloc failed|Too many grains|Strata invariant broken|Parse error|syntax error|not understood" "$output" || true

# scsynth prints "alloc failed" when a UGen cannot get real-time memory (it
# then outputs zeros) and "Too many grains!" when a GrainIn or GrainBuf would
# run more than its maxGrains (it drops the grain), and the engine "Strata
# invariant broken" when its synth bookkeeping finds a state it should never
# reach; in any part of the check each is a failure
if grep -q "ENGINE CHECK PASSED" "$output" && [ "$status" -eq 0 ] \
  && ! grep -qE "^ERROR|FAILURE|alloc failed|Too many grains|Strata invariant broken" "$output"; then
  exit 0
fi
echo "--- full sclang output ---"
cat "$output"
exit 1
