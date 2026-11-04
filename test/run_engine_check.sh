#!/bin/sh
# Compile lib/Engine_Strata.sc against the real norns CroneEngine classes and
# run test/engine_check.scd, which boots a local scsynth (output routed to a
# private bus, so it is silent) and exercises every engine command.
#
# usage: test/run_engine_check.sh [path/to/norns]
#   NORNS_DIR / SCLANG environment variables override the defaults.
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
norns_dir=${1:-${NORNS_DIR:-$HOME/src/norns}}
sclang=${SCLANG:-/Applications/SuperCollider.app/Contents/MacOS/sclang}

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

output="$work_dir/output.txt"
set +e
# started from the temp dir: anything the check writes to its working
# directory is removed with it, never left in the caller's directory
(cd "$work_dir" && "$sclang" -l "$work_dir/sclang_conf.yaml" "$script_dir/engine_check.scd") > "$output" 2>&1
status=$?
set -e

# keep the interesting lines: class-library errors and the check results
grep -E "^(ok |FAIL|ERROR|WARNING|ENGINE CHECK|compiled)|FAILURE|Parse error|syntax error|not understood" "$output" || true

if grep -q "ENGINE CHECK PASSED" "$output" && [ "$status" -eq 0 ] \
  && ! grep -qE "^ERROR|FAILURE" "$output"; then
  exit 0
fi
echo "--- full sclang output ---"
cat "$output"
exit 1
