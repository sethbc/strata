### Fixed
- Developer tooling: an interrupted engine check (Ctrl-C, a caller's time limit) now stops its sclang, scsynth and work folder instead of leaving them on the port.
- Developer tooling: the engine check fails at once, naming the cause, when its port already has a server, when scsynth cannot boot or when an area name is unknown; any sclang WARNING fails a run, and a stray `.sc` file outside the engine's files fails the tests.
- CI runs with a read-only token, no stored credentials, `actions/checkout` v7 and norns pinned by its full commit.
