#!/bin/sh
# Run the engine check in Docker on SuperCollider 3.13 (norns' version, CI's
# pin; the default) or, with -s 3.14, on 3.14.1 (the local machines'
# version, #1039), any number of times, several at once. Each container
# has its own network, so parallel containers never share a scsynth or
# sclang port (local sclang runs exhaust the language ports past a few at
# once).
#
# A full run is CI's: the shards of .github/workflows/test.yml's engine-shard
# matrix (its areas list, one "- a,b,c" item a shard), each in a container,
# and so a fresh sclang, of its own (#581). One sclang running every area in
# turn is where 3.13's collector gives out (#131, #211); CI never runs one.
# The list is read from the workflow at each start, never copied here, so
# the two cannot drift. A run passes only when every one of its shards
# passed.
#
# usage: [STRATA_ENGINE_CHECK_AREAS=files] test/run_engine_check_313.sh [-s version] [-n runs] [-j parallel] [-o log_dir] [-1] [-l] [-c] [path/to/norns]
#   -s  the SuperCollider the containers run: 3.13 (default; the image
#       strata-sc313, from test/docker/sc313) or 3.14 (3.14.1: strata-sc314,
#       from test/docker/sc314, built in test/docker to share sc313's
#       check.sh); anything else is refused with the usage line. Every other
#       option works the same under either, and CI never passes it
#   -n  how many runs (default 1)
#   -j  how many containers run at once (default 1): shards of one run and
#       of different runs alike
#   -o  the folder for the logs (created if missing; default a new
#       ${TMPDIR:-/tmp}/strata-sc313-logs.XXXXXX, or strata-sc314-logs
#       under -s 3.14). A sharded run <i>'s
#       shard writes run-<i>-<shard>.log and run-<i>-<shard>.status there,
#       the shard's commas written as _ (run-3-voices_freeze_grains.log); a
#       run in one container writes run-<i>.log and run-<i>.status. Each
#       log's first line names the release, option and image it ran
#       ("strata engine check on SuperCollider 3.14.1 (option -s 3.14, image
#       strata-sc314)"). Nothing in it is ever deleted.
#   -1  runs each full run in one container, every area in one sclang, as
#       before #581 (for studying #131)
#   -l  prints the shards a sharded run would use, one a line, and starts
#       nothing
#   -c  classifies the runs already in the -o folder (i = 1..n, either
#       layout) and starts nothing. Use the latest launch's run count and
#       shard list to select its logs. For older folders without a record,
#       infer each layout from its logs and the workflow's shard list
#   path/to/norns defaults to $NORNS_DIR, else ~/src/norns.
#   STRATA_ENGINE_CHECK_AREAS, set and not empty, runs those areas in one
#   container per run, as before #581. It, ENGINE_CHECK_TIMEOUT (which
#   applies to each container: each shard of a sharded run),
#   STRATA_SOAK_ROUNDS and STRATA_SOAK_SECONDS pass through to every
#   container.
#   STRATA_SC313_IMAGE names the 3.13 image (default strata-sc313), and
#   STRATA_SC314_IMAGE the 3.14 one (default strata-sc314).
#   STRATA_SC313_MEMORY is each container's memory cap, under either
#   version (default 8g: a healthy run of every area peaked at 1.42 GiB,
#   sampled every 3 s, #544). A run sclang's collector sends out of
#   control is killed inside its container, not by the machine's own
#   out-of-memory killer.
#
# The image is built from its Dockerfile when it is missing or its sources
# changed (the Dockerfile and test/docker/sc313/check.sh; the image's
# strata.dockerfile-sha256 label holds their hash), so a fresh machine needs
# no manual step; the one-time build takes about a minute (it downloads
# Ubuntu's SuperCollider and JACK).
#
# Each container ends in one of six ways (#545, #687), the worst first:
# collector failure (the log holds the collector's count-error lines, the
# collector failure of #211, whatever else it shows and at exit status 0
# too; sclang spells the word with an e, so the pattern is written gr[e]y
# for the US spelling check); failed (any FAIL, ERROR or "Strata invariant
# broken" line, whatever ended it); capped (the memory cap killed a process
# in the container: oom_kill above 0, #544); killed (exit 137 with no cap
# kill: stopped from outside); crashed (a signal with none of those: #131);
# a remaining ENGINE CHECK FAILED: report is failed; otherwise status 0
# passes. The detail of a collector failure says what else the log
# shows. A sharded run that did not pass takes the class of its worst shard
# (the first in that order, after passed; of two alike, the first in the
# run's order), and the summary names that shard, then any other shard that
# did not pass; a run -c finds incomplete says which logs are missing.
# The summary counts runs by class (and the incomplete ones), then for
# sharded runs their shards by class (and the missing ones: a run's other
# shards show only there) and names the slowest shard; the exit status is 0
# only when every run passed.
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
workflow=$repo_root/.github/workflows/test.yml
usage="usage: $0 [-s version] [-n runs] [-j parallel] [-o log_dir] [-1] [-l] [-c] [path/to/norns]"

version=3.13
runs=1
parallel=1
log_dir=
classify_only=
list_only=
one_process=
while getopts s:n:j:o:cl1 flag; do
  case $flag in
    s) version=$OPTARG ;;
    n) runs=$OPTARG ;;
    j) parallel=$OPTARG ;;
    o) log_dir=$OPTARG ;;
    c) classify_only=1 ;;
    l) list_only=1 ;;
    1) one_process=1 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# The version's image: the release it runs, its part of a container's or
# log folder's name, the image's name, its Dockerfile and its build's
# context.
# Both images run sc313's check.sh, so it is in both hashes (#1039)
check_script=$script_dir/docker/sc313/check.sh
case $version in
  3.13)
    release=3.13.0
    version_name=sc313
    image=${STRATA_SC313_IMAGE:-strata-sc313}
    dockerfile=$script_dir/docker/sc313/Dockerfile
    build_context=$script_dir/docker/sc313
    ;;
  3.14)
    release=3.14.1
    version_name=sc314
    image=${STRATA_SC314_IMAGE:-strata-sc314}
    dockerfile=$script_dir/docker/sc314/Dockerfile
    build_context=$script_dir/docker
    ;;
  *) echo "-s takes 3.13 or 3.14, got \"$version\"" >&2; echo "$usage" >&2; exit 2 ;;
esac
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
  # Decimal digits only, with at least one nonzero digit.
  case $count in
    *[!0-9]*) ;;
    *[1-9]*) continue ;;
  esac
  echo "-n and -j take a whole number of at least 1, got \"$count\"" >&2
  exit 2
done

if [ -n "$list_only" ]; then
  read_shards || exit 2
  exit 0
fi

# The record is blank during setup. Before any container starts, publish the
# run count and exact shard list with all of this attempt's statuses empty.
shards=
recorded_runs=
sharded=
launch_runs() {
  # All writers use the same flat log names. Hold a kernel lock on the folder
  # itself, inherited by running jobs, including if the launcher is killed.
  exec 9< "$log_dir"
  if command -v flock > /dev/null 2>&1; then
    lock_folder() { flock -n 9; }
  else
    # macOS ships Perl's flock instead of the util-linux command.
    lock_folder() { perl -MFcntl=:flock -e 'open my $dir, "<&=9" or die $!; exit !flock($dir, LOCK_EX | LOCK_NB)'; }
  fi
  if ! lock_folder; then
    echo "cannot lock the log folder for writing: $log_dir" >&2
    exit 2
  fi
  : > "$log_dir/current-run"
  if [ -z "$one_process" ] && [ -z "${STRATA_ENGINE_CHECK_AREAS:-}" ]; then
    sharded=1
    shards=$(read_shards) || exit 2
  fi
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
    sources_hash=$(cat "$dockerfile" "$check_script" | sha256sum | cut -c 1-64)
  else
    sources_hash=$(cat "$dockerfile" "$check_script" | shasum -a 256 | cut -c 1-64)
  fi
  built_hash=$(docker image inspect -f '{{ index .Config.Labels "strata.dockerfile-sha256" }}' "$image" 2> /dev/null || true)
  if [ "$built_hash" != "$sources_hash" ]; then
    echo "building $image from ${dockerfile#"$repo_root"/} (about a minute, once)"
    docker build --label "strata.dockerfile-sha256=$sources_hash" -t "$image" -f "$dockerfile" "$build_context"
  fi

  for_each_container clear_status
  record=$(mktemp "$log_dir/current-run.XXXXXXXX")
  { printf '%s %s\n' "$runs" "${record##*.}"; printf '%s\n' "$shards"; } > "$record"
  chmod +r "$record"   # match the logs' readability under the caller's umask
  mv -f -- "$record" "$log_dir/current-run"

  echo "SuperCollider $release (option -s $version, image $image)"
  if [ -n "$sharded" ]; then
    echo "areas: all, in the workflow's shards ($(echo $shards)), one container each; $runs run(s), $parallel container(s) at once"
  else
    echo "areas: ${STRATA_ENGINE_CHECK_AREAS:-all}, one container per run; $runs run(s), $parallel at once"
  fi
  for_each_container start_container
  wait
}

# Visit exactly the same run and shard names for preparation and launch.
for_each_container() {
  run=1
  while [ "$run" -le "$runs" ]; do
    if [ -n "$sharded" ]; then
      for shard in $shards; do "$1" "$run-$(file_name "$shard")" "$shard"; done
    else
      "$1" "$run" ""
    fi
    run=$((run + 1))
  done
}

clear_status() { : > "$log_dir/run-$1.status"; }

# The containers this start launched, named after this script's PID so an
# interrupt stops only its own
container_name() { echo "strata-$version_name-$$-$1"; }
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
# status file is empty from preparation until it ends, so a job
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
  run_one "$1" "$2" &
  running="$running $1:$!"
}

run_one() {
  set +e
  if [ -n "$2" ]; then areas="STRATA_ENGINE_CHECK_AREAS=$2"; else areas=STRATA_ENGINE_CHECK_AREAS; fi
  began=$(date +%s)
  echo "strata engine check on SuperCollider $release (option -s $version, image $image)" > "$log_dir/run-$1.log"
  # --memory and --memory-swap alike: the cap holds without swap (#544)
  docker run --rm --name "$(container_name "$1")" \
    --memory="$memory_cap" --memory-swap="$memory_cap" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e XDG_RUNTIME_DIR=/tmp \
    -e "$areas" -e ENGINE_CHECK_TIMEOUT -e STRATA_SOAK_ROUNDS -e STRATA_SOAK_SECONDS \
    -v "$repo_root:/src:ro" -v "$norns_dir:/norns:ro" \
    "$image" check >> "$log_dir/run-$1.log" 2>&1
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
  log_dir=$(mktemp -d "${TMPDIR:-/tmp}/strata-$version_name-logs.XXXXXX")
else
  mkdir -p -- "$log_dir"
  log_dir=$(cd "$log_dir" && pwd)
fi
echo "logs: $log_dir"

[ -n "$classify_only" ] || launch_runs

# New launches record their layout even when older logs are still present.
# A folder made by an older runner keeps the original discovery rules.
recorded=
if [ -f "$log_dir/current-run" ]; then
  recorded=1
  {
    read -r recorded_runs attempt || recorded_runs=0
    shards=$(cat)
  } < "$log_dir/current-run"
  case $recorded_runs in ''|*[!0-9]*) recorded_runs=0 ;; esac
elif [ -n "$classify_only" ]; then
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
  signal=$(grep -m 1 -oE "^ENGINE CHECK FAILED: sclang ended on signal [0-9]+ after [0-9]+ s" "$1" 2> /dev/null || true)
  signal=${signal#ENGINE CHECK FAILED: }
  engine_failure=$(grep -m 1 "^ENGINE CHECK FAILED:" "$1" 2> /dev/null || true)
  failure=$(grep -m 1 -E "^FAIL|^ERROR|Strata invariant broken" "$1" 2> /dev/null || true)
  cap_note=
  grep -qE "^strata cgroup oom_kill: [1-9]" "$1" 2> /dev/null && cap_note="; the memory cap killed a process (#544)"
  detail=
  if grep -q "gr[e]y count error" "$1" 2> /dev/null; then
    class=collector rank=1
    detail="#211; count errors"
    [ -z "$failure" ] || detail="$detail; $failure"
    detail="$detail$cap_note"
    [ "$status" != 137 ] || detail="$detail; exit 137"
    if [ -n "$signal" ]; then
      detail="$detail; $signal"
    elif [ -n "$engine_failure" ] && [ -z "$failure$cap_note" ]; then
      detail="$detail; $engine_failure"
    elif [ "$status" = 0 ] && [ -z "$failure$cap_note" ]; then
      detail="$detail; the check itself passed"
    fi
  elif [ -n "$failure" ]; then
    class=failed rank=2
    detail="$failure$cap_note"
  elif [ -n "$cap_note" ]; then
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
  elif [ -n "$engine_failure" ]; then
    class=failed rank=2
    detail=$engine_failure
  elif [ "$status" = 0 ]; then
    class=passed rank=6
  else
    class=failed rank=2
    detail=$(grep -m 1 -E "ENGINE CHECK FAILED|FAILURE" "$1" 2> /dev/null || echo "see the log")
  fi
  label=$class
  [ "$class" != collector ] || label="collector failure"
}

# Select the finished shard stems and count each missing shard once. Legacy
# folders use the workflow order, then any remaining shard logs by file name.
# Both lists empty means a run in one container (run-<i>.log).
run_shards() {
  stems=
  missing=
  found=
  ambiguous=
  if [ -z "$recorded" ]; then
    for log in "$log_dir/run-$1-"*.log; do
      [ -e "$log" ] || continue
      stem=${log##*/run-}
      found="$found ${stem%.log}"
    done
    [ -n "$found" ] || return 0
    if [ -f "$log_dir/run-$1.log" ]; then ambiguous=1; return 0; fi
  fi
  for shard in $shards; do
    stem=$1-$(file_name "$shard")
    if [ -f "$log_dir/run-$stem.log" ] && { [ -z "$recorded" ] || [ -s "$log_dir/run-$stem.status" ]; }; then
      stems="$stems $stem"
    else
      missing="$missing,$shard"
      count shard total
      count shard missing
    fi
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
  if [ -n "$recorded" ] && [ "$run" -gt "$recorded_runs" ]; then
    count run incomplete
    echo "run $run: incomplete (no completed run $run in the latest attempt)"
    run=$((run + 1))
    continue
  fi
  run_shards "$run"
  log=$log_dir/run-$run.log
  if [ -n "$ambiguous" ]; then
    count run incomplete
    echo "run $run: incomplete (both single and shard logs without a current-run record)"
  elif [ -z "$stems$missing" ] && [ ! -f "$log" ]; then
    count run incomplete
    echo "run $run: incomplete (missing $log)"
  elif [ -z "$stems$missing" ] && [ -n "$recorded" ] && [ ! -s "$log_dir/run-$run.status" ]; then
    count run incomplete
    echo "run $run: incomplete (no finished result for $log)"
  elif [ -z "$stems$missing" ]; then
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
      count run incomplete
      [ -z "$worst_stem" ] || others="$newline  and $worst$others"
      if [ -n "$recorded" ]; then reason="no finished result"; else reason="no log"; fi
      echo "run $run: incomplete ($reason for $missing)$others"
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
# A replay may read while another launch starts. Refuse mixed evidence if
# the folder changed hands since the record was read (including a legacy
# folder's first reuse).
if [ -n "$classify_only" ] && [ -f "$log_dir/current-run" ]; then
  read -r current_runs current_attempt < "$log_dir/current-run" || current_attempt=
  if [ "${attempt:-}" != "$current_attempt" ] || [ -z "$recorded" ]; then
    echo "incomplete: another attempt started while classifying $log_dir"
    exit 1
  fi
fi
[ -z "$slowest" ] || echo "slowest shard: $slowest, $slowest_seconds s"
echo "passed $run_passed of $runs; failed $run_failed; capped $run_capped (#544); killed $run_killed; collector failure $run_collector (#211); crashed $run_crashed (#131); incomplete $run_incomplete"
[ "$shard_total" -eq 0 ] || echo "shards: passed $shard_passed of $shard_total; failed $shard_failed; capped $shard_capped (#544); killed $shard_killed; collector failure $shard_collector (#211); crashed $shard_crashed (#131); missing $shard_missing"
[ "$run_passed" -eq "$runs" ]
