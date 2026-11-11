## Must not break

- A data file is parsed, never run (#464): `scenes.data` and `buffers.data` are read only through `S.lib.data_files.read`, which parses the layout norns' `tab.save` writes. Nothing in `strata.lua` or `lib/` uses `tab.load` or calls `loadfile`, `dofile`, `loadstring` or `load` (a structure test enforces it), since `tab.load` runs the file as a Lua chunk that sees every global (`os`, `io`, `_norns`), and `pcall` contains only an error, not what the chunk does or an endless loop.
- `decode` accepts exactly `tab.save`'s layout and raises nothing: any other text (code, a truncated file, a reference to a table the file does not hold, a NaN key, text after the end) returns nil and a message naming the byte, and the caller treats the file as unloadable (kept as `.bak`, `docs/notes/lua/scenes.md`). It reads in time proportional to the text's length and allocates in proportion to it; `read` refuses a file over `DATA_FILES.max_bytes` (4 MB; eight full scenes are about 100 KB) before reading it.
- Every file `tab.save` wrote reads to the value `tab.load` reads, number subtypes included on Lua 5.3, with shared and self-referencing tables kept as one table. A change to the parser keeps the round-trip test (`decode reads every layout tab.save writes ...`) passing on Lua 5.3 and LuaJIT, with its files written by the stub's `tab.save` (norns' lib/tabutil.lua, ported unchanged).
- The call sites look `read` up at call time (`S.lib.data_files.read(...)`), so the start-steps structure test can observe it.

## lib/data_files.lua (`S.lib.data_files`)

Included just before `lib/buffers.lua`. It holds the reader of the two data files; the writer (`encode`, `write`) and the backups are #301's, to be added to this module.

- **`decode(text)`**: the value `text` holds, or nil and what is wrong (`"<what> at byte <n>"`). A scanner over `text` with a position:
  - between tokens, spaces, newlines and `--` comments to the end of the line;
  - a string from `"` to the next unescaped `"`, with the escapes `%q` writes on Lua 5.3 and LuaJIT (`\"`, `\\`, backslash-newline, one to three decimal digits up to 255) and older Lua's `\n` and `\r`; a raw newline or any other escape is an error;
  - `true`, `false`, and `inf`, `-inf`, `nan`, `-nan` (what `tostring` writes for those numbers: `tab.load` reads them as nil globals or raises, so they are new here; the callers judge them: `validate_scene` rejects NaN, and the buffers restore loads a start that is not finite from 0);
  - a number matched by `^%-?[%d%.]+[eE][%+%-]?%d+` or `^%-?[%d%.]+` and accepted only if `tonumber` takes it (so `3` stays an integer and `3.0` a float on Lua 5.3);
  - a table reference `{digits}`.
  - The grammar: `return`, `{`, tables each followed by `,`, `}`, then the end of the text. A table is `{`, entries each followed by `,`, `}`; an entry is `[key]=value` or `value`. Positional values take indices 1, 2, ... after the keyed entries are set, as a table constructor sets them. References are resolved once every table is read, so one may name a later table or its own.
- **`read(path)`**: the value; or nil and `"missing"` when the file cannot be opened (as `util.file_exists` decides); or nil, `"unreadable"` and why (larger than `max_bytes`, a read that fails, or `decode`'s message).
- **`read_text(path)`**: the file's bytes (binary mode, nothing changed), or nil when it cannot be read.
- **`DATA_FILES`** (`M.DATA_FILES`): `max_bytes`, 4 MB.

The callers: `read_scenes_file` (`lib/scenes.lua`, `docs/notes/lua/scenes.md`) and `restore_buffers_from_file` (`lib/buffers.lua`, `docs/notes/lua/buffers.md`) print `no saved ... file found` for `"missing"` and `error loading ... file: <why>` for anything that is not a table, then move the file aside as before; their version and shape checks are unchanged.

Cost: decoding a scenes file of eight full scenes (about 97 KB) takes 7 to 10 ms on a desktop with Lua 5.3, against about 1 ms for `tab.load` (a device is several times slower), once at start and once per `load scenes`.

Tests: `test/unit/data_files_test.lua` (eleven texts that are code, a loop, a value built by a call, a missing reference, a truncated file, trailing code, an empty text and a binary chunk header, through `decode` and `read`, with nothing run; the round trip against the stub's `tab.save` and `tab.load`; `read`'s outcomes and `max_bytes`; a scenes and a buffers file holding code at start). `test/unit/structure_test.lua` checks that nothing in the script uses `tab.load` or a chunk loader.
