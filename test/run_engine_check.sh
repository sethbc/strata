#!/bin/sh
# Compile lib/Engine_Strata.sc against the real norns CroneEngine classes and
# run test/engine_check.scd, which boots a local scsynth (output routed to a
# private bus, so it is silent) and runs the check's areas
# (test/engine_check/<area>.scd), which exercise every engine command.
#
# usage: [STRATA_SC_PORT=57141] [STRATA_ENGINE_CHECK_AREAS=memory,buffers] test/run_engine_check.sh [path/to/norns]
#   STRATA_ENGINE_CHECK_AREAS names the areas to run, comma- or
#   space-separated (structure, voices, grains, lifecycle, memory, buffers,
#   files, effects, performance); unset or empty runs every area. They run in
#   the check's fixed order whatever order they are named in, and a name with
#   no area file fails the run ("ENGINE CHECK FAILED: no area <name>"). Each
#   area's time is printed as "area <name>: <seconds> s".
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

case ${STRATA_SC_PORT:-57110} in
  ''|*[!0-9]*) bad_port=1 ;;
  *) [ "${STRATA_SC_PORT:-57110}" -ge 1 ] && [ "${STRATA_SC_PORT:-57110}" -le 65535 ] && bad_port=0 || bad_port=1 ;;
esac
if [ "$bad_port" = 1 ]; then
  echo "STRATA_SC_PORT must be a port number from 1 to 65535, got \"${STRATA_SC_PORT:-}\"" >&2
  exit 2
fi

if [ ! -d "$norns_dir/sc/core" ]; then
  echo "norns source not found at $norns_dir (pass it as the first argument)" >&2
  exit 2
fi

# The run's temporary folder; the exit trap deletes it, and only a folder
# made from this template (#134)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/strata-engine-run.XXXXXX") || exit 2
remove_work_dir() {
  case $work_dir in
    /*/strata-engine-run.??????) [ -d "$work_dir" ] && rm -rf -- "$work_dir" ;;
    *) echo "left $work_dir in place (not this run's temporary folder)" >&2 ;;
  esac
}
trap remove_work_dir EXIT
mkdir "$work_dir/classes"
cp "$script_dir/StrataTestNoBoot.sc.in" "$work_dir/classes/StrataTestNoBoot.sc"
if [ "$(uname -s)" = Darwin ]; then
  cp "$script_dir/StrataTestNoBootOSX.sc.in" "$work_dir/classes/StrataTestNoBootOSX.sc"
fi

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
# seconds: a normal run takes about 3.5 minutes, the check's own deadline is
# 540 s, CI's is 600 s) and killed as soon as sclang reports a compile error.
# timeout signals the whole process group, the scsynth sclang booted
# included; the script's own stop (and its limit, when there is no timeout
# command) signals every descendant, found with POSIX ps (pgrep is not on
# every machine), so no scsynth is left holding its port. A sclang that
# ends on its own (a crash) leaves its scsynth running: the check writes
# the server's PID to scsynth.pid in the work dir, and the script stops it
# after sclang ends (#152). stdbuf makes sclang's output line-buffered, so
# an error is in the output file while sclang waits (block-buffered, it
# never would be).
sclang_timeout=${ENGINE_CHECK_TIMEOUT:-570}
compile_error='^ERROR: (syntax error|Command line parse failed|file .* parse failed)|Library has not been compiled successfully'
timeout_cmd=$(command -v timeout || command -v gtimeout || true)
stdbuf_cmd=$(command -v stdbuf || command -v gstdbuf || true)
set --
[ -n "$timeout_cmd" ] && set -- "$timeout_cmd" --kill-after=10 "$sclang_timeout"
[ -n "$stdbuf_cmd" ] && set -- "$@" "$stdbuf_cmd" -oL -eL

# The PIDs of a process's children: POSIX ps (Linux and macOS), or pgrep
# where ps cannot list processes
child_pids() {
  if processes=$(ps -A -o pid= -o ppid= 2>/dev/null) && [ -n "$processes" ]; then
    printf '%s\n' "$processes" | awk -v parent="$1" '$2 == parent { print $1 }'
  else
    pgrep -P "$1" 2>/dev/null
  fi
}

# Signal a process and all its descendants, children first (once the
# parent is gone they would be re-parented out of reach)
kill_tree() (
  for child in $(child_pids "$1"); do kill_tree "$child"; done
  kill "$1" 2>/dev/null
)

# Stop the scsynth the check booted if it outlived sclang: the PID in
# scsynth.pid, signaled only while its command line still names scsynth
# (never a process that took the PID over)
stop_leftover_server() {
  server_pid=$(cat "$work_dir/scsynth.pid" 2>/dev/null) || return 0
  case $server_pid in ''|*[!0-9]*) return 0 ;; esac
  case $(ps -p "$server_pid" -o args= 2>/dev/null) in
    *scsynth*)
      kill_tree "$server_pid"
      echo "stopped the scsynth sclang left running (pid $server_pid)" >&2
      ;;
  esac
}

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
stop_leftover_server
set -e
# 124: timeout stopped it; 137: timeout's --kill-after SIGKILL
if [ -z "$stopped" ] && { [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; }; then
  stopped="no result within $sclang_timeout s"
fi
if [ -n "$stopped" ]; then
  echo "ENGINE CHECK FAILED: $stopped; sclang stopped" >&2
fi

# keep the interesting lines: class-library errors, the check results and
# each area's time
grep -E "^(ok |FAIL|ERROR|WARNING|ENGINE CHECK|compiled|area )|FAILURE|alloc failed|Too many grains|Strata invariant broken|Parse error|syntax error|not understood" "$output" || true

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
