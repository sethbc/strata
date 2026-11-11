#!/bin/sh
# Run the engine check on SuperCollider 3.13 (norns' version, CI's pin) in
# Docker, any number of times, several at once. Each run is its own
# container with its own network, so parallel runs never share a scsynth or
# sclang port (local sclang runs exhaust the language ports past a few at
# once).
#
# usage: [STRATA_ENGINE_CHECK_AREAS=files] test/run_engine_check_313.sh [-n runs] [-j parallel] [-o log_dir] [path/to/norns]
#   -n  how many runs (default 1)
#   -j  how many run at once (default 1)
#   -o  the folder for the logs (created if missing; default a new
#       ${TMPDIR:-/tmp}/strata-sc313-logs.XXXXXX). Run <i>'s output is
#       run-<i>.log there. Nothing in it is ever deleted.
#   path/to/norns defaults to $NORNS_DIR, else ~/src/norns.
#   STRATA_ENGINE_CHECK_AREAS, ENGINE_CHECK_TIMEOUT, STRATA_SOAK_ROUNDS and
#   STRATA_SOAK_SECONDS pass through to every run.
#   STRATA_SC313_IMAGE names the image (default strata-sc313).
#   STRATA_SC313_MEMORY is each container's memory cap (default 8g: a
#   healthy run of every area peaked at 1.42 GiB, sampled every 3 s, #544). A run sclang's collector sends out of
#   control is killed inside its container, not by the machine's own
#   out-of-memory killer.
#   -c classifies the runs already in the -o folder (run-<i>.log and
#   run-<i>.status, i = 1..n) and starts nothing.
#
# The image is built from test/docker/sc313/ when it is missing or that
# folder's files changed (the image's strata.dockerfile-sha256 label holds
# their hash), so a fresh machine needs no manual step; the one-time build
# takes about a minute (it downloads Ubuntu's SuperCollider and JACK).
#
# Each run ends in one of five ways (#545): passed; failed (any FAIL, ERROR
# or "Strata invariant broken" line, whatever ended it); capped (the memory
# cap killed a process in the container, #544); collector (sclang ended on a
# signal after the collector's count-error lines (sclang spells it with an e: the pattern is written gr[e]y so the US spelling check passes): the collector failure of #211); or
# crashed (a signal with none of those: #131). The summary gives the
# counts; the exit status is 0 only when every run passed.
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
docker_dir=$script_dir/docker/sc313
image=${STRATA_SC313_IMAGE:-strata-sc313}

runs=1
parallel=1
log_dir=
classify_only=
while getopts n:j:o:c flag; do
  case $flag in
    n) runs=$OPTARG ;;
    j) parallel=$OPTARG ;;
    o) log_dir=$OPTARG ;;
    c) classify_only=1 ;;
    *) echo "usage: $0 [-n runs] [-j parallel] [-o log_dir] [-c] [path/to/norns]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
norns_dir=${1:-${NORNS_DIR:-$HOME/src/norns}}

memory_cap=${STRATA_SC313_MEMORY:-8g}

launch_runs() {
  if [ ! -d "$norns_dir/sc/core" ]; then
    echo "norns source not found at $norns_dir (pass it as the last argument)" >&2
    exit 2
  fi
  norns_dir=$(cd "$norns_dir" && pwd)
  if ! command -v docker > /dev/null 2>&1; then
    echo "docker is not on PATH" >&2
    exit 2
  fi

  # The hash of the image's sources, kept as a label on the image
  if command -v sha256sum > /dev/null 2>&1; then
    sources_hash=$(cat "$docker_dir/Dockerfile" "$docker_dir/check.sh" | sha256sum | cut -c 1-64)
  else
    sources_hash=$(cat "$docker_dir/Dockerfile" "$docker_dir/check.sh" | shasum -a 256 | cut -c 1-64)
  fi
  built_hash=$(docker image inspect -f '{{ index .Config.Labels "strata.dockerfile-sha256" }}' "$image" 2> /dev/null || true)
  if [ "$built_hash" != "$sources_hash" ]; then
    echo "building $image from test/docker/sc313 (about a minute, once)"
    docker build --label "strata.dockerfile-sha256=$sources_hash" -t "$image" "$docker_dir"
  fi

  echo "areas: ${STRATA_ENGINE_CHECK_AREAS:-all}; $runs run(s), $parallel at once"
  while [ "$started" -lt "$runs" ]; do
    batch=0
    while [ "$batch" -lt "$parallel" ] && [ "$started" -lt "$runs" ]; do
      started=$((started + 1))
      batch=$((batch + 1))
      run_one "$started" &
    done
    wait
  done
}

# The containers this run started, named after this script's PID so an
# interrupt stops only its own
container_name() { echo "strata-sc313-$$-$1"; }
started=0
stop_containers() {
  run=1
  while [ "$run" -le "$started" ]; do
    docker kill "$(container_name "$run")" > /dev/null 2>&1 || true
    run=$((run + 1))
  done
}
trap 'stop_containers; exit 130' INT TERM

run_one() {
  set +e
  # --memory and --memory-swap alike: the cap holds without swap (#544)
  docker run --rm --name "$(container_name "$1")" \
    --memory="$memory_cap" --memory-swap="$memory_cap" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e XDG_RUNTIME_DIR=/tmp \
    -e STRATA_ENGINE_CHECK_AREAS -e ENGINE_CHECK_TIMEOUT -e STRATA_SOAK_ROUNDS -e STRATA_SOAK_SECONDS \
    -v "$repo_root:/src:ro" -v "$norns_dir:/norns:ro" \
    "$image" check > "$log_dir/run-$1.log" 2>&1
  echo $? > "$log_dir/run-$1.status"
}

for count in "$runs" "$parallel"; do
  case $count in
    ''|*[!0-9]*|0) echo "-n and -j take a whole number of at least 1, got \"$count\"" >&2; exit 2 ;;
  esac
done

if [ -z "$log_dir" ]; then
  log_dir=$(mktemp -d "${TMPDIR:-/tmp}/strata-sc313-logs.XXXXXX")
else
  mkdir -p -- "$log_dir"
  log_dir=$(cd "$log_dir" && pwd)
fi
echo "logs: $log_dir"

[ -n "$classify_only" ] || launch_runs

passed=0
failed=0
collector=0
crashed=0
capped=0
run=1
while [ "$run" -le "$runs" ]; do
  log=$log_dir/run-$run.log
  status=$(cat "$log_dir/run-$run.status" 2> /dev/null || echo 1)
  signal=$(grep -o "sclang ended on signal [0-9]* after [0-9]* s" "$log" | head -n 1)
  if [ "$status" = 0 ]; then
    passed=$((passed + 1))
    echo "run $run: passed"
  elif grep -qE "^FAIL|^ERROR|Strata invariant broken" "$log"; then
    failed=$((failed + 1))
    note=
    grep -q "^gr[e]y count error" "$log" && note="; the collector failed too (#211)"
    grep -qE "^strata cgroup oom_kill: [1-9]" "$log" && note="$note; the memory cap killed a process (#544)"
    echo "run $run: failed ($(grep -m 1 -E "^FAIL|^ERROR|Strata invariant broken" "$log")$note), $log"
  elif grep -qE "^strata cgroup oom_kill: [1-9]" "$log" || [ "$status" = 137 ]; then
    capped=$((capped + 1))
    echo "run $run: capped (the container's memory cap of $memory_cap killed it; ${signal:-no sclang signal}), $log"
  elif [ -n "$signal" ] && grep -q "^gr[e]y count error" "$log"; then
    collector=$((collector + 1))
    echo "run $run: collector failure (#211; $signal, after count errors), $log"
  elif [ -n "$signal" ]; then
    crashed=$((crashed + 1))
    echo "run $run: crashed ($signal), $log"
  else
    failed=$((failed + 1))
    echo "run $run: failed ($(grep -m 1 -E "ENGINE CHECK FAILED|FAILURE" "$log" || echo "see the log")), $log"
  fi
  run=$((run + 1))
done
echo "passed $passed of $runs; failed $failed; capped $capped (#544); collector failure $collector (#211); crashed $crashed (#131)"
[ "$passed" -eq "$runs" ]
