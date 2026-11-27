# The engine check on SuperCollider 3.14.1, the local machines' version, in
# a container a shard (#1039). test/run_engine_check_313.sh -s 3.14 builds
# this image (as strata-sc314) when it is missing or its sources changed,
# and runs it; see docs/notes/test-harness/engine-check-runner.md.
#
# The packages are Ubuntu 26.10's, the release the local 3.14.1 comes from:
# SC_APT_VERSION is its supercollider-language and supercollider-server
# (apt-cache policy supercollider-language on the host). To move the pin,
# set it and FROM to a release whose archive carries the build, and the
# pin's line in docs/checks.md with them (test/unit/docs_test.lua checks
# they match). The build's context is test/docker, so the image runs the
# 3.13 image's check command (sc313/check.sh), the one file both share.
# The container must run as a non-root user (QtWebEngine refuses root),
# with the repo at /src and a norns checkout at /norns. 26.10's jackd2
# (1.9.22) no longer carries jack_lsp, which check.sh waits on:
# jack-example-tools does (24.04's jackd2 still has it).
FROM ubuntu:26.10@sha256:29ac5e68db830ab61b7d77c1ffdb78c73f0631de88a5d77bf4399868f64f38dd

ARG SC_APT_VERSION=1:3.14.1+repack2-1build1

ENV DEBIAN_FRONTEND=noninteractive QT_QPA_PLATFORM=offscreen

RUN echo "jackd2 jackd/tweak_rt_limits boolean false" | debconf-set-selections \
  && apt-get update \
  && apt-get install -y --no-install-recommends jackd2 jack-example-tools procps coreutils python3 \
    "supercollider-language=$SC_APT_VERSION" "supercollider-server=$SC_APT_VERSION" \
  && apt-get clean

COPY sc313/check.sh /usr/local/bin/check
RUN chmod 0755 /usr/local/bin/check
