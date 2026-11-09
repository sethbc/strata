## Must not break

- Until its Wave 1 package fills it, every function here is neutral: it answers as pinned in `test/unit/bookmarks_test.lua` and sends no engine command. Wave 1 keeps every name and signature.
- The module is a constructor ending with `  return M` and `end`; its table is `S.lib.bookmarks`.

## Owns

`lib/bookmarks.lua`: a voice's bookmarks (NUM_BOOKMARKS read positions). The header comment says what each function will do.
