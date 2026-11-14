#!/bin/sh
# Run the engine check on SuperCollider 3.13 (norns' version, CI's pin) in
# Docker, any number of times, several at once. Each container has its own
# network, so parallel containers never share a scsynth or sclang port
# (local sclang runs exhaust the language ports past a few at once).
#
# A full run is CI's: the shards of .github/workflows/test.yml's engine-shard
# matrix (its areas list, one "- a,b,c" item a shard), each in a container,
# and so a fresh sclang, of its own (#581). One sclang running every area in
# turn is where 3.13's collector gives out (#131, #211); CI never runs one.
# The list is read from the workflow at each start, never copied here, so
# the two cannot drift. A run passes only when every one of its shards
# passed.
#
# usage: [STRATA_ENGINE_CHECK_AREAS=files] test/run_engine_check_313.sh [-n runs] [-j parallel] [-o log_dir] [-1] [-l] [-c] [path/to/norns]
#   -n  how many runs (default 1)
#   -j  how many containers run at once (default 1): shards of one run and
#       of different runs alike
#   -o  the folder for the logs (created if missing; default a new
#       ${TMPDIR:-/tmp}/strata-sc313-logs.XXXXXX). A sharded run <i>'s
#       shard writes run-<i>-<shard>.log and run-<i>-<shard>.status there,
#       the shard's commas written as _ (run-3-voices_freeze_grains.log); a
#       run in one container writes run-<i>.log and run-<i>.status. Nothing
#       in it is ever deleted.
#   -1  runs each full run in one container, every area in one sclang, as
#       before #581 (for studying #131)
#   -l  prints the shards a sharded run would use, one a line, and starts
#       nothing
#   -c  classifies the runs already in the -o folder (i = 1..n, either
#       layout; a run with shard logs is read as sharded, against the
#       workflow's list: its shards in the list's order, then any shard log
#       the list no longer names, by file name; a run lacking a listed
#       shard's log is incomplete) and starts nothing
#   path/to/norns defaults to $NORNS_DIR, else ~/src/norns.
#   STRATA_ENGINE_CHECK_AREAS, set and not empty, runs those areas in one
#   container per run, as before #581. It, ENGINE_CHECK_TIMEOUT (which
#   applies to each container: each shard of a sharded run),
#   STRATA_SOAK_ROUNDS and STRATA_SOAK_SECONDS pass through to every
#   container.
#   STRATA_SC313_IMAGE names the image (default strata-sc313).
#   STRATA_SC313_MEMORY is each container's memory cap (default 8g: a
#   healthy run of every area peaked at 1.42 GiB, sampled every 3 s, #544). A run sclang's collector sends out of
#   control is killed inside its container, not by the machine's own
#   out-of-memory killer.
#
# The image is built from test/docker/sc313/ when it is missing or that
# folder's files changed (the image's strata.dockerfile-sha256 label holds
# their hash), so a fresh machine needs no manual step; the one-time build
# takes about a minute (it downloads Ubuntu's SuperCollider and JACK).
#
# Each container ends in one of six ways (#545, #687), the worst first:
# collector failure (the log holds the collector's count-error lines, the
# collector failure of #211, whatever else it shows and at exit status 0
# too; sclang spells the word with an e, so the pattern is written gr[e]y
# for the US spelling check); failed (any FAIL, ERROR or "Strata invariant
# broken" line, whatever ended it); capped (the memory cap killed a process
# in the container: oom_kill above 0, #544); killed (exit 137 with no cap
# kill: stopped from outside); crashed (a signal with none of those: #131);
# or passed. The detail of a collector failure says what else the log
# shows. A sharded run that did not pass takes the class of its worst shard
# (the first in that order, after passed; of two alike, the first in the
# run's order), and the summary names that shard, then any other shard that
# did not pass; a run -c finds incomplete says which shards have no log.
# The summary counts runs by class (and the incomplete ones), then for
# sharded runs their shards by class (and the missing ones: a run's other
# shards show only there) and names the slowest shard; the exit status is 0
# only when every run passed.
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
docker_dir=$script_dir/docker/sc313
workflow=$repo_root/.github/workflows/test.yml
image=${STRATA_SC313_IMAGE:-strata-sc313}

runs=1
parallel=1
log_dir=
classify_only=
list_only=
one_process=
while getopts n:j:o:cl1 flag; do
  case $flag in
    n) runs=$OPTARG ;;
    j) parallel=$OPTARG ;;
    o) log_dir=$OPTARG ;;
    c) classify_only=1 ;;
    l) list_only=1 ;;
    1) one_process=1 ;;
    *) echo "usage: $0 [-n runs] [-j parallel] [-o log_dir] [-1] [-l] [-c] [path/to/norns]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
norns_dir=${1:-${NORNS_DIR:-$HOME/src/norns}}

memory_cap=${STRATA_SC313_MEMORY:-8g}

# The workflow's shards, one a line, in its order: the "- a,b,c" items of
# the areas list under its matrix (comment and blank lines skipped; the list
# ends at the first line that is neither). Status 2, naming the workflow,
# when there is no such list or an item is not area names joined by commas.
read_shards() {
  if [ ! -r "$workflow" ]; then
    echo "no shard list: $workflow cannot be read" >&2
    return 2
  fi
  awk -v workflow="$workflow" '
    function refuse(message) { print message " in " workflow | "cat 1>&2"; refused = 1; exit 2 }
    /^[[:space:]]*matrix:[[:space:]]*$/ { matrix = 1; next }
    matrix && !inside && /^[[:space:]]*areas:[[:space:]]*$/ { inside = 1; next }
    inside && /^[[:space:]]*(#.*)?$/ { next }
    inside && /^[[:space:]]*-/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      sub(/[[:space:]]*$/, "", item)
      if (item !~ /^[A-Za-z0-9]+(,[A-Za-z0-9]+)*$/) refuse("cannot read the shard \"" item "\"")
      print item
      count++
      next
    }
    inside { exit }
    END {
      if (refused) exit 2
      if (!count) refuse("no shard list (the areas of the engine-shard matrix)")
    }
  ' "$workflow"
}

# A shard's part of a log or container name: its commas as _ (area names
# are letters and digits, so the shard can be read back)
file_name() { echo "$1" | tr , _; }

for count in "$runs" "$parallel"; do
  case $count in
    ''|*[!0-9]*|0) echo "-n and -j take a whole number of at least 1, got \"$count\"" >&2; exit 2 ;;
  esac
done

if [ -n "$list_only" ]; then
  read_shards || exit 2
  exit 0
fi

# A start that launches full runs runs them sharded, unless -1 or the
# caller's areas say otherwise
sharded=
shards=
if [ -z "$classify_only" ] && [ -z "$one_process" ] && [ -z "${STRATA_ENGINE_CHECK_AREAS:-}" ]; then
  sharded=1
  shards=$(read_shards) || exit 2
fi

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

  if [ -n "$sharded" ]; then
    echo "areas: all, in the workflow's shards ($(echo $shards)), one container each; $runs run(s), $parallel container(s) at once"
  else
    echo "areas: ${STRATA_ENGINE_CHECK_AREAS:-all}, one container per run; $runs run(s), $parallel at once"
  fi
  run=1
  while [ "$run" -le "$runs" ]; do
    if [ -n "$sharded" ]; then
      for shard in $shards; do start_container "$run-$(file_name "$shard")" "$shard"; done
    else
      start_container "$run" ""
    fi
    run=$((run + 1))
  done
  wait
}

# The containers this start launched, named after this script's PID so an
# interrupt stops only its own
container_name() { echo "strata-sc313-$$-$1"; }
started_names=
stop_containers() {
  for name in $started_names; do
    docker kill "$(container_name "$name")" > /dev/null 2>&1 || true
  done
}
trap 'stop_containers; exit 130' INT TERM

# Start a container once fewer than -j are running: $1 the suffix of its
# name and log (the run, then for a shard its file name), $2 the areas it
# runs (empty: the caller's STRATA_ENGINE_CHECK_AREAS, if any). A job's
# status file is emptied before it starts and written as it ends, so a job
# is running while its status is empty: that cannot be fooled by a PID the
# system has given to another process since. Its PID is asked only for a
# job that ended without writing one (killed first), whose slot then frees
# when the PID is gone.
running=
start_container() {
  while :; do
    still=
    count=0
    for job in $running; do
      if [ ! -s "$log_dir/run-${job%:*}.status" ] && kill -0 "${job##*:}" 2> /dev/null; then
        still="$still $job"
        count=$((count + 1))
      fi
    done
    running=$still
    [ "$count" -lt "$parallel" ] && break
    sleep 0.2 2> /dev/null || sleep 1
  done
  started_names="$started_names $1"
  : > "$log_dir/run-$1.status"
  run_one "$1" "$2" &
  running="$running $1:$!"
}

run_one() {
  set +e
  if [ -n "$2" ]; then areas="STRATA_ENGINE_CHECK_AREAS=$2"; else areas=STRATA_ENGINE_CHECK_AREAS; fi
  began=$(date +%s)
  # --memory and --memory-swap alike: the cap holds without swap (#544)
  docker run --rm --name "$(container_name "$1")" \
    --memory="$memory_cap" --memory-swap="$memory_cap" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e XDG_RUNTIME_DIR=/tmp \
    -e "$areas" -e ENGINE_CHECK_TIMEOUT -e STRATA_SOAK_ROUNDS -e STRATA_SOAK_SECONDS \
    -v "$repo_root:/src:ro" -v "$norns_dir:/norns:ro" \
    "$image" check > "$log_dir/run-$1.log" 2>&1
  status=$?
  echo "strata container seconds: $(( $(date +%s) - began ))" >> "$log_dir/run-$1.log"
  echo "$status" > "$log_dir/run-$1.status"
}

if [ -n "$classify_only" ]; then
  # classifying makes no folder: it reads the one it is given
  if [ -z "$log_dir" ] || [ ! -d "$log_dir" ]; then
    echo "-c needs -o <the folder holding run-<i>.log and run-<i>.status, or run-<i>-<shard>.log and .status>" >&2
    exit 2
  fi
  log_dir=$(cd "$log_dir" && pwd)
elif [ -z "$log_dir" ]; then
  log_dir=$(mktemp -d "${TMPDIR:-/tmp}/strata-sc313-logs.XXXXXX")
else
  mkdir -p -- "$log_dir"
  log_dir=$(cd "$log_dir" && pwd)
fi
echo "logs: $log_dir"

[ -n "$classify_only" ] || launch_runs

# -c judges a folder that holds shard logs against the workflow's list: a
# run lacking some of its shards is incomplete, and a run's shards are read
# in the list's order
if [ -n "$classify_only" ]; then
  for log in "$log_dir"/run-*-*.log; do
    if [ -e "$log" ]; then shards=$(read_shards) || exit 2; fi
    break
  done
fi

# classify <log> <status file>: sets class (collector, failed, capped,
# killed, crashed or passed), rank (its place in that order: a sharded run
# takes its lowest), label (the summary's word) and detail. A log holding
# the collector's count-error lines is the collector class whatever else it
# shows, a passing one too (#687); its detail says what else the log shows.
classify() {
  status=$(cat "$2" 2> /dev/null || echo 1)
  signal=$(grep -o "sclang ended on signal [0-9]* after [0-9]* s" "$1" 2> /dev/null | head -n 1)
  detail=
  if grep -q "gr[e]y count error" "$1" 2> /dev/null; then
    class=collector rank=1
    detail="#211; count errors"
    if grep -qE "^FAIL|^ERROR|Strata invariant broken" "$1"; then
      detail="$detail; $(grep -m 1 -E "^FAIL|^ERROR|Strata invariant broken" "$1")"
    fi
    grep -qE "^strata cgroup oom_kill: [1-9]" "$1" && detail="$detail; the memory cap killed a process (#544)"
    [ "$status" != 137 ] || detail="$detail; exit 137"
    if [ -n "$signal" ]; then
      detail="$detail; $signal"
    elif [ "$status" = 0 ]; then
      detail="$detail; the check itself passed"
    fi
  elif [ "$status" = 0 ]; then
    class=passed rank=6
  elif grep -qE "^FAIL|^ERROR|Strata invariant broken" "$1" 2> /dev/null; then
    class=failed rank=2
    note=
    grep -qE "^strata cgroup oom_kill: [1-9]" "$1" && note="; the memory cap killed a process (#544)"
    detail="$(grep -m 1 -E "^FAIL|^ERROR|Strata invariant broken" "$1")$note"
  elif grep -qE "^strata cgroup oom_kill: [1-9]" "$1" 2> /dev/null; then
    class=capped rank=3
    detail="the container's memory cap of $memory_cap killed it; ${signal:-no sclang signal}"
  elif [ "$status" = 137 ]; then
    # SIGKILL from outside (a docker kill, the host's own out-of-memory
    # killer) with no cap kill in the container's own count
    class=killed rank=4
    detail="exit 137 with no memory-cap kill: stopped from outside"
  elif [ -n "$signal" ]; then
    class=crashed rank=5
    detail=$signal
  else
    class=failed rank=2
    detail=$(grep -m 1 -E "ENGINE CHECK FAILED|FAILURE" "$1" 2> /dev/null || echo "see the log")
  fi
  label=$class
  [ "$class" != collector ] || label="collector failure"
}

# run_shards <run>: sets stems, the log stems of the run's shards (the
# workflow's, in its order; for -c, those with a log, then any other shard
# log the folder holds, by name), and missing, for -c, the workflow's shards
# with no log, joined by commas. stems empty: a run in one container
# (run-<i>.log), never incomplete
run_shards() {
  stems=
  missing=
  if [ -n "$sharded" ]; then
    for shard in $shards; do stems="$stems $1-$(file_name "$shard")"; done
    return 0
  fi
  [ -n "$classify_only" ] || return 0
  found=
  for log in "$log_dir/run-$1-"*.log; do
    [ -e "$log" ] || continue
    stem=${log##*/run-}
    found="$found ${stem%.log}"
  done
  [ -n "$found" ] || return 0
  for shard in $shards; do
    stem=$1-$(file_name "$shard")
    if [ -e "$log_dir/run-$stem.log" ]; then stems="$stems $stem"; else missing="$missing,$shard"; fi
  done
  for stem in $found; do
    case " $stems " in
      *" $stem "*) ;;
      *) stems="$stems $stem" ;;
    esac
  done
  missing=${missing#,}
}

# The counts: runs, and for sharded runs their shards (a run takes one class,
# so its other shards' classes show only here)
for kind in run shard; do
  for name in passed failed capped killed collector crashed incomplete missing total; do
    eval "${kind}_$name=0"
  done
done
count() { eval "$1_$2=\$((\$1_$2 + 1))"; }
slowest=
slowest_seconds=-1
newline='
'
run=1
while [ "$run" -le "$runs" ]; do
  run_shards "$run"
  if [ -z "$stems" ]; then
    log=$log_dir/run-$run.log
    classify "$log" "$log_dir/run-$run.status"
    count run "$class"
    if [ "$class" = passed ]; then echo "run $run: passed"; else echo "run $run: $label ($detail), $log"; fi
  else
    # the worst shard: of those that did not pass, the first in the run's
    # order of the lowest rank
    worst_rank=6
    worst_stem=
    worst_class=
    worst=
    for stem in $stems; do
      log=$log_dir/run-$stem.log
      shard=$(echo "${stem#*-}" | tr _ ,)
      seconds=$(sed -n 's/^strata container seconds: \([0-9][0-9]*\)$/\1/p' "$log" 2> /dev/null | tail -n 1)
      if [ -n "$seconds" ] && [ "$seconds" -gt "$slowest_seconds" ]; then
        slowest_seconds=$seconds
        slowest="$shard in run $run"
      fi
      classify "$log" "$log_dir/run-$stem.status"
      count shard total
      count shard "$class"
      if [ "$rank" -lt "$worst_rank" ]; then
        worst_rank=$rank
        worst_stem=$stem
        worst_class=$class
        worst="$label in $shard ($detail), $log"
      fi
    done
    # every other shard that did not pass, in the run's order
    others=
    for stem in $stems; do
      [ "$stem" != "$worst_stem" ] || continue
      classify "$log_dir/run-$stem.log" "$log_dir/run-$stem.status"
      [ "$class" != passed ] || continue
      others="$others$newline  and $label in $(echo "${stem#*-}" | tr _ ,) ($detail), $log_dir/run-$stem.log"
    done
    if [ -n "$missing" ]; then
      for shard in $(echo "$missing" | tr , ' '); do
        count shard total
        count shard missing
      done
      count run incomplete
      [ -z "$worst_stem" ] || others="$newline  and $worst$others"
      echo "run $run: incomplete (no log for $missing)$others"
    elif [ -n "$worst_stem" ]; then
      count run "$worst_class"
      echo "run $run: $worst$others"
    else
      count run passed
      echo "run $run: passed"
    fi
  fi
  run=$((run + 1))
done
[ -z "$slowest" ] || echo "slowest shard: $slowest, $slowest_seconds s"
echo "passed $run_passed of $runs; failed $run_failed; capped $run_capped (#544); killed $run_killed; collector failure $run_collector (#211); crashed $run_crashed (#131); incomplete $run_incomplete"
[ "$shard_total" -eq 0 ] || echo "shards: passed $shard_passed of $shard_total; failed $shard_failed; capped $shard_capped (#544); killed $shard_killed; collector failure $shard_collector (#211); crashed $shard_crashed (#131); missing $shard_missing"
[ "$run_passed" -eq "$runs" ]
