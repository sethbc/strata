# Lua implementation notes (moved)

The Lua notes are now one short file per module, each opening with what you must not break. CLAUDE.md's module table maps every `lib/` file to its notes file and its unit tests. This page only points old links at the new files.

| Old section | Now in |
|-------------|--------|
| Modules | CLAUDE.md's module table, and the Owns section of each file below |
| Voice State Management, Resource Management and Cleanup, Bounds Checking, Async Initialization | `docs/notes/lua/state-and-voices.md` |
| Param -> engine: `send_param_to_engine` | `docs/notes/lua/engine-sync.md` |
| Parameter System (and the tempo handler) | `docs/notes/lua/params.md` |
| Global LFOs | `docs/notes/lua/lfos.md` |
| MIDI Input | `docs/notes/lua/midi.md` |
| Probability-Based Mutation System (and the drift) | `docs/notes/lua/mutation.md` |
| Scene System (transitions, sequencer, migration, validation, persistence) | `docs/notes/lua/scenes.md` |
| Buffers persistence (buffers.data) | `docs/notes/lua/buffers.md` |
| Grid Integration, the pattern sequencer, the grid's scene page | `docs/notes/lua/grid-and-sequencer.md` |
| Arc Integration | `docs/notes/lua/arc.md` |
| UI Updates: screen pages, redraws, main parameter, MAIN layout | `docs/notes/lua/ui-and-pages.md` |
| Future Extension Points, Version History | `docs/notes/lua/version-history.md` |
| Test harness details | `docs/notes/lua/test-harness.md` |
