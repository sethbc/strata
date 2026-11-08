#!/bin/sh
# The image's `check` command: start a dummy JACK server (scsynth needs
# one; the dummy driver needs no sound card), wait until it answers, then
# run the engine check on the repo at /src against the norns checkout at
# /norns. STRATA_ENGINE_CHECK_AREAS, ENGINE_CHECK_TIMEOUT and the soak's
# variables pass through from `docker run -e`.
set -eu

jackd --no-realtime -d dummy -r 48000 -p 1024 > /tmp/jackd.log 2>&1 &
ready=
for attempt in $(seq 1 40); do
  if jack_lsp > /dev/null 2>&1; then ready=1; break; fi
  sleep 0.25
done
if [ -z "$ready" ]; then
  echo "ENGINE CHECK FAILED: JACK did not start" >&2
  cat /tmp/jackd.log >&2
  exit 1
fi

cd /src
SCLANG=/usr/bin/sclang exec test/run_engine_check.sh /norns
