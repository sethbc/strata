### Fixed
- Developer tooling: the engine check runner stops the SuperCollider server it started on machines without `pgrep` or `timeout`, and after a crashed `sclang`, so no server is left holding the check's port (#152).
