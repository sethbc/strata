# Lua implementation notes (moved)

The Lua notes are now one short file per module, each opening with what you must not break. AGENTS.md's module table maps every `lib/` file to its notes file and its unit tests. This page only points old links at the new files.

| Old section | Now in |
|-------------|--------|
| Modules | AGENTS.md's module table, and the Owns section of each file below |
| Voice State Management, Resource Management and Cleanup, Bounds Checking, Async Initialization | `docs/notes/lua/state-and-voices.md` |
| Param -> engine: `send_param_to_engine` | `docs/notes/lua/engine-sync.md` |
| Parameter System (and the tempo handler) | `docs/notes/lua/params.md` |
| Global LFOs | `docs/notes/lua/lfos.md` |
| MIDI Input | `docs/notes/lua/midi.md` |
| Probability-Based Mutation System (and the drift) | `docs/notes/lua/mutation.md` |
| Scene System (transitions, sequencer, migration, validation, persistence) | `docs/notes/lua/scenes.md` |
| Buffers persistence (buffers.data) | `docs/notes/lua/buffers.md` |
| Grid Integration | `docs/notes/lua/grid-core.md` (devices, holds, faders) and one file per layout under docs/notes/lua/grid/ (`docs/notes/lua/grid/layout_256.md`, ..., the 256's scene page included) |
| The pattern sequencer | `docs/notes/lua/sequencer.md` |
| Arc Integration | `docs/notes/lua/arc-core.md` (devices, dispatch, drawing) and `docs/notes/lua/arc-pages.md` (each page's rings) |
| UI Updates: screen pages, redraws | `docs/notes/lua/ui-core.md` |
| Main parameter, MAIN layout, and each other page | one file per page under docs/notes/lua/pages/ (`docs/notes/lua/pages/main.md`, ...) |
| Future Extension Points, Version History | `docs/notes/lua/version-history.md` |
| Test harness details | `docs/notes/lua/test-harness.md` |
