### Fixed
- Developer tooling: an interrupted engine check (Ctrl-C, a caller's time limit) now stops its sclang, scsynth and work folder instead of leaving them on the port.
- Developer tooling: the engine check fails at once, naming the cause, when its port already has a server, when scsynth cannot boot or when an area name is unknown; any sclang WARNING fails a run, and a stray `.sc` file outside the engine's files fails the tests.
- CI runs with a read-only token, no stored credentials, `actions/checkout` v7 and norns pinned by its full commit.
- Developer tooling: each 3.13 Docker container of the engine check has a memory cap (8g), so a runaway sclang is killed inside its container; the 3.13 summary now names a failed run (any FAIL or ERROR line), a capped run, a collector failure (#211) and a crash (#131) apart.
- CI also checks that the engine check refuses a port that already has a server (leaving that server running) and fails at once when scsynth cannot boot.
