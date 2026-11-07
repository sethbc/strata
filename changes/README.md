# Changelog fragments

Every pull request adds one fragment, `changes/<branch-name>.md`, with one or
more bullets under `### Added`, `### Changed` and/or `### Fixed` (omit the
headings it does not use). Write for a user of the script, one line per change.

```
### Added
- Short description of the new behavior.

### Fixed
- Short description of the fix.
```

Release process: the release pull request merges the fragments into
CHANGELOG.md under the new version and deletes them. `docs/status.md` changes
only at a release or when a pull request closes an open item, so fragments
never conflict there.

`test/unit/docs_test.lua` checks every fragment (this file excepted) for a
heading and a bullet under it.
