# The engine check on SuperCollider 3.13, norns' version, on any machine.
# test/run_engine_check_313.sh builds this image (as strata-sc313) when it
# is missing or this folder's files changed, and runs it; see
# docs/notes/lua/test-harness/engine-check-runner.md.
#
# The packages are CI's: Ubuntu 24.04 and SC_APT_VERSION in
# .github/workflows/test.yml (test/unit/docs_test.lua checks that the two
# pins match). The container must run as a non-root user (QtWebEngine
# refuses root), with the repo at /src and a norns checkout at /norns.
FROM ubuntu:24.04

ARG SC_APT_VERSION=1:3.13.0+repack-1ubuntu3

ENV DEBIAN_FRONTEND=noninteractive QT_QPA_PLATFORM=offscreen

RUN echo "jackd2 jackd/tweak_rt_limits boolean false" | debconf-set-selections \
  && apt-get update \
  && apt-get install -y --no-install-recommends jackd2 procps coreutils \
    "supercollider-language=$SC_APT_VERSION" "supercollider-server=$SC_APT_VERSION" \
  && apt-get clean

COPY check.sh /usr/local/bin/check
RUN chmod 0755 /usr/local/bin/check
