## Must not break

- **3.4's interface**: `S.lib.bookmarks.recall(v, n)` and `S.lib.bookmarks.is_set(v, n)` keep their names and behavior. `is_set` is true only for a whole `v` in 1..`NUM_VOICES`, a whole `n` in 1..`NUM_BOOKMARKS` and a voice reading a slot whose reported seconds (`S.buffers[slot].seconds`) are above 0; `recall` does nothing when it is false, else `S.lib.positions.recall_bookmark(v, n)`.
- **Neither ever creates a node.** A pattern step's lock fires them: they send `params:set`s and at most one `setGrainParam` (`t_scanReset`), never `voiceOn` or `setGrainSource` (the bookmarks tests assert it).
- The module is a constructor ending with `  return M` and `end`; its table is `S.lib.bookmarks`.

## Owns

`lib/bookmarks.lua`: the thin interface over `lib/positions.lua` that 3.4's step locks call (design 3.3 section 5.4). The bookmarks themselves (the params, the scene fields, `store_bookmark`, `recall_bookmark`) are `lib/positions.lua`'s (`docs/notes/lua/positions.md`). 3.4's beat-quantized actions may also call `S.lib.positions.jump` and `set_loop`, and read `S.constants.NUM_BOOKMARKS` and the params `v<i>_bookmark_<n>`.

Tests: `test/unit/bookmarks_test.lua` (recall and the last recalled, `is_set` for every refused case, recall a no-op when unset, no node).
