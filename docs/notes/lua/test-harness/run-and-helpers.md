## Must not break

- CI's LuaJIT is built without Lua 5.2 compatibility, so `table.unpack`, `table.pack`, `table.move`, `math.type`, `math.tointeger`, `utf8.*`, `string.pack` and `string.unpack` are nil there, though a local LuaJIT may have them. Never use them in `lib/`, `test/` or `strata.lua` without a fallback in the same expression (`table.unpack or unpack`). A static check in `test/unit/structure_test.lua` fails any other use (comments and strings are skipped).

## The Lua test run

- `lua test/run.lua` and `luajit test/run.lua` load every `test/unit/*_test.lua` (listed and sorted by `load_unit_files` in `test/helpers.lua`, so a new unit file needs no runner edit) and run their tests. With an argument (`lua test/run.lua scenes`) they load only the unit files whose name contains it.
- Each unit file is `return function(h) ... end`: it registers its tests with `h.test(name, fn)` and takes the helpers from `h`.
- `test/helpers.lua` holds the harness: the stubs, the test registry and `run_test`, the assertions, `load_strata`, `find_upvalue`/`local_value`, the clock drivers and the helpers several unit files share.
- **Temporary folders.** Every test writes below `h.data_root` (a fresh `os.tmpname()` folder) and deletes only through `h.remove_tree(path)`, which refuses (raises, deletes nothing) any path that is not `h.data_root` or inside it, is relative or has a `.` or `..` segment, and quotes the path for the shell (`h.shell_quote`) after `rm -rf --`. Never call `rm` through `os.execute` directly. The engine check deletes only `<temp dir>/strata-engine-check-*`, and `test/run_engine_check.sh` only its own `strata-engine-run.XXXXXX` folder (#134).
- The tests load `strata.lua` into norns stubs (`test/norns_stubs.lua`). The run exits non-zero on failure and includes the static sync check.

### Reaching script state

- Add a test for every behavior change.
- Script values are reached through `find_upvalue()`/`local_value()`. They look in the shared table `S` (`lib/state.lua`, found as the upvalue `S` of `init`; a key ever assigned into `S`, even to nil, is recorded in `S.__declared` and found while nil), then in `S.constants`, then in the script locals (the upvalues of global functions). The setter writes where the name was found.
- The stub's `include(file)` follows norns' `lua/core/startup.lua`: it runs the script folder's `<file>.lua` with `dofile` on every call.
- Only `strata.lua` includes, each module once, by its `lib/` path. A test checks this, and that a reload builds an `S` sharing no table with the last one.
- `load_strata { source = text }` loads a patched copy of `strata.lua`, and `load_strata { module_sources = { ["lib/x"] = text } }` patched modules. `patched_script(pattern, replacement)` builds either from whichever file holds the pattern.
- `read_lua_sources()` returns the script's Lua files (`strata.lua`, then `lib/**/*.lua`) for the tests that read the source.
- `MODULE_HOMES` (`test/unit/structure_test.lua`) maps a module path to the global functions it must define.
- Each `load_strata` gets a data directory of its own, named by a counter (tests reseed `math.random`, so a random name could repeat). `load_strata { data_subdir = name }` shares one between loads (the persistence tests).

### Module safety nets

The Wave 0 golden master (a logged scripted session compared with a fixture) proved the module split changed no behavior and was retired once the split was done; git history keeps it.

- **Global-reference check** (Lua 5.3 only; it needs `luac` or `luac5.3` on PATH and fails without one; LuaJIT prints a skip note):
  - `luac -l -l -p` lists each file's `GETTABUP`/`SETTABUP` on `_ENV` (the name in the comment, or for a key past the first 256 constants the `LOADK` into its register);
  - every global read must be written by some script file or be a key of `_G` right after `stubs.install` (norns and the standard library);
  - `KNOWN_UNDEFINED_GLOBALS` lists reads allowed while their bug is open (none today).
- **Duplicate-global check** (same listing, Lua 5.3 only): no global, function or value, is written by more than one file, since a later include would silently replace the earlier definition. `GLOBALS_WRITTEN_IN_TWO_FILES` allows `key` and `enc`, which `lib/pages/buffer.lua` puts back when the file selector fails.
- **Locals probe**:
  - inserts `local p1, ..., pN` at the end of each file's main chunk (before a module's final top-level `return`) and of each constructor (before its final `  return M\nend`; every module but the plain constants table must end that way);
  - finds the largest N that loads;
  - requires at least 30 in each main chunk and each constructor, `strata.lua` included (195 free in its main chunk today).

### Docs checks

- AGENTS.md's command table under "Lua ↔ SuperCollider Communication" must have exactly one row per engine `addCommand`, with the same signature and argument count. Update the table in the same commit as the engine.
- No `engine.<name>(` mentioned in the maintained docs may name a command the engine no longer has. The maintained docs are AGENTS.md, README.md, `docs/status.md`, `docs/decisions.md` and every `.md` under docs/notes/ (recursively), docs/user/ and docs/process/ (`maintained_docs` in `test/helpers.lua`).
- Every repo path the maintained docs name in backticks (under docs/, test/, .github/ and lib/) must exist, from the repo root. A relative Markdown link target must exist relative to the doc's own folder (`doc_paths_missing(text, doc_name)`); `docs/notes/lua.md` alone may still link root files from the repo root, a fallback to delete with that file. A norns library is named by its path in the norns repo (`lua/lib/lfo.lua`), which is not checked.
- Every file in docs/notes/lua/ must have `## Must not break` as its first heading (headings inside code fences do not count).
- Every changelog fragment in changes/ (`changes/README.md` aside) must hold an `### Added`, `### Changed` or `### Fixed` heading with a bullet under it.
- Every docs/notes/engine/ file's first heading is `## Must not break` too; `docs/notes/engine.md` only indexes docs/notes/engine/, and AGENTS.md names every engine notes file and `STRATA_ENGINE_CHECK_AREAS`; every engine check area has a notes file of the same name and a place in the runner's `areaOrder`, and every docs/notes/engine/ file has an area.
- Every `docs/user/pages/` and `docs/user/grid/` file is linked from `docs/user/controls.md` or `docs/user/grid.md`.
- No docs/user/ page or README.md sentence says "freeze" with lock, `[L]`, params or values unless it contrasts them ("unlike").
- US spelling: the `text uses US spelling` test scans the tracked text files; extend its word list.
- These checks are in `test/unit/docs_test.lua`.
