### Added
- Changelog fragments: each pull request adds `changes/<branch-name>.md`; see `changes/README.md`.
- The engine check runs on a configurable port, so several can run on one machine.
- MIT license.

### Changed
- `strata.lua` is split into modules under `lib/`.
- The test suite is split into units under `test/unit/`, run by `test/run.lua`.
- The implementation notes are split into topic files under `docs/notes/`.
- The README is split into user guides under `docs/user/`.
- The docs check covers every file under `docs/notes/` and `docs/user/`, and each file under `docs/notes/lua/` must open with a "Must not break" section.
