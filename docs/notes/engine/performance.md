## Must not break

- Today there is one tier: the engine's `bufferSeconds` (16) and `maxGrains` (128) are fixed, and Lua mirrors `bufferSeconds` as `BUFFER_SECONDS` (the docs test compares them).
- Each slot holds `bufferSeconds` at the server rate (the engine check asserts it).

## Performance tiers

The 3.2 performance setting (`docs/design/3.2-design.md`, §1) makes these values tier-dependent; its package fills this file and `test/engine_check/performance.scd`. Until then the area checks the fixed values: `numBuffers` 8, `bufferSeconds` 16, and every buffer 16 s long at the server rate. The real-time memory budget the values must fit is in `docs/notes/engine/memory.md`.
