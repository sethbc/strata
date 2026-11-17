# Plan facts: 0a `locked` and the docs pass 5a

Read from the worktree `docs-before-3.8-design`, whose code is main's (its only changes are uncommitted edits to `ROADMAP.md` and `docs/status.md`). Counts come from grep. `lua test/run.lua engine_sync_test` passes today (53 tests).

## Package 0a `locked`

### 1. Files

**The design's counts are wrong** (design §1, line 79: "122 uses in 23 files under `lib/`, 300 in tests, 160 in docs"). Those numbers count every `frozen`, the audio freeze's included. The lock's own uses are much fewer:

- **lib/: 25 `S.frozen`, 5 scene-field lines and 2 comments, in 9 files.** strata.lua has none.
  - `lib/voices.lua:3` (comment), `:256`, `:258`.
  - `lib/engine_sync.lua:670` (twice), `:671`.
  - `lib/scatter.lua:53`, `:74`.
  - `lib/mutation.lua:144`, `:276`, `:324`; the comments `:272` and `:323` say "non-frozen" for the lock.
  - `lib/pages/voice.lua:129`, `:231`, `:241`.
  - `lib/pages/main.lua:82`, `:173`, `:227`, `:238`, `:305`, `:350`.
  - `lib/grid/core.lua:451`.
  - `lib/notes.lua:615` (a locked voice's note is never stolen).
  - `lib/scenes.lua`: the `S.frozen` uses are `:521` and `:522`. The scene field is at `:328` (`frozen = {}`), `:374` (`scene_data.frozen[i] = S.frozen[i]`), `:485` (`add_voice_state("lock", i, scene_data.frozen[i])`), `:1243` (validate: `type(data.frozen) ~= "table"`) and `:1280` (`type(data.frozen[i]) ~= "boolean"`).
  - `lib/constants.lua:11` and `:15` hold the two values and their comments.
- **Left alone (audio freeze), about 90 uses:** `lib/freeze.lua` (all 7), `lib/notes.lua` (23 of 24, `frozen_synth` included), `lib/expression.lua` (5), `lib/playheads.lua` (2), `lib/scan.lua`, `lib/variation.lua`, `lib/state.lua` (3: the `freeze_change` hook's argument), `lib/pages/main.lua:169/183/293/323` (`[F]`, the layout state "all locked, running, triggered, frozen, field 3"), `lib/pages/seq.lua:53`, `lib/scenes.lua:597`, the three layouts' `frozen_level`/`unfrozen_level` and `is_frozen`, and every `lib/engine/*.sc` use (66). No engine file changes.
- **Tests: about 100 lock lines in 14 files.** Each one is `local_value("frozen")`, `local_value("S").frozen`, `S.frozen`, a scene's `.frozen` or a local named after them:
  - `pages_main_test.lua` 26 lines: 60, 277, 284, 289, 295, 313, 316, 328, 330, 523, 526, 546-559 (the `state.frozen` keys), 573-581 (`stopped_frozen`, `running_frozen`), 594, 676, 695, 732, 905. Lines 722, 739, 753-764 are the audio freeze.
  - `scenes_test.lua` 17 lines: 38, 42, 74, 75, 162, 1283, 1965, 2139-2142 (a copy of the lock apply), 2339, 2352, 2418, 2426, 2999, 3032. Line 1255 is the audio freeze.
  - `grid_layout_256_test.lua` 13 lines: 262, 404, 807, 875, 878, 882, 889, 924, 930, 933, 944, 951, 1050. Lines 910, 913, 940, 945 and 1494 are freeze LEDs.
  - `engine_sync_test.lua` 10 lines: 278-283, 305-322.
  - `pages_voice_test.lua` 6 lines: 459, 461, 463, 469, 944, 989.
  - `grid_layout_128v_test.lua` 6 lines: 45, 49, 53, 60, 69, 79.
  - `mutation_test.lua` 6 lines plus a comment: 27, 29, 31, 81 ("freeze covers buffer params"), 83, 85, 86.
  - `grid_layout_128h_test.lua` 4 lines: 140, 196, 202, 204.
  - `midi_in_test.lua` 3 lines: 300, 317, 322 (message "freeze unchanged", which should read "lock unchanged").
  - `ui_test.lua` 3 lines: 48, 54, 600.
  - `io_system_test.lua` 2 lines: 167, 1635.
  - `io_nb_test.lua` 2 lines: 589, 590.
  - `ui_layout_test.lua` 1 line: 197.
  - `ui_pages_test.lua` 1 line: 214.
- **Tests left alone:** every audio use: `test/notes_model.lua`, `freeze_test.lua`, `notes_test.lua`, `expression_test.lua`, `variation_test.lua`, `scan_test.lua`, `playheads_test.lua`, `strata_test.lua` (its `"frozen"` op tag at 467), `io_crow_test`, `io_ii_test`, `structure_test.lua:2170` (`notesUnfrozen`) and the `.scd` files.
- **`test/fixtures/3.6.0-files.lua:161` and `:333`** (`["frozen"]=...`) are recorded bytes and never change. Only the header comment (lines 1-27, "loading in 3.7") needs a line saying the scenes file is now set aside.
- **Maintained docs, about 27 lock sites:**
  - `AGENTS.md:245` (the rule, 53 words) and `:305` (`` `SCENE_DATA_VERSION` (8) ``).
  - `docs/notes/lua/freeze.md:3`.
  - `docs/notes/lua/ui-core.md:4`, which says "the state and the scene field keep the name `frozen` ... so scene files load unchanged". It is now false and must be rewritten.
  - `docs/notes/lua/mutation.md:19`, `:65` (code), `:136`, `:142`.
  - `docs/notes/lua/state-and-voices.md:25`.
  - `docs/notes/lua/engine-sync.md:40`.
  - `docs/notes/lua/notes.md:7`.
  - `docs/notes/lua/grid/layout_256.md:42`.
  - `docs/notes/lua/pages/main.md:14`.
  - `docs/notes/lua/scenes.md:9`, `:63`, `:81`, `:128`, `:147`, `:337` (`data.frozen: NUM_VOICES booleans`), `:395`, `:399`, `:403`.
  - The version lines: `docs/notes/lua/scenes.md:4` and `:289-291`, and `docs/notes/lua/data-files.md:12` (floor 7).
  - The user pages: `docs/user/scenes.md:21` and `docs/user/params.md:137`, which both say "3.5 or later load". They become "3.8 or later", because the fragments ride to 3.8.0.
  - No user page says `frozen` for the lock; `docs_test.lua:971` enforces that.
- **Docs that must not change** (history: entries describe a release as it shipped): `CHANGELOG.md` (19 uses, 2 of them the lock), `docs/history.md:150`, `docs/decisions/3.1.md`, the designs under docs/design/ (3.1, 3.3, 3.5 and 3.7 mention the field), `docs/notes/lua/expression.md:60` ("`SCENE_DATA_VERSION` is 7 from this package", a dated line) and `docs/notes/lua/state-and-voices.md:225` (audio).
- **Changelog fragment:** `changes/<branch>.md` under `### Changed`. It should say that scenes files saved before this version are set aside as `scenes.data.bak` on the first start, and that the lock is unchanged for players.

### 2. Names

- `S.frozen` (built at `lib/voices.lua:256`) becomes `S.locked`. The tests reach it as `local_value("frozen")`, which becomes `local_value("locked")`. Nothing else is named `locked` on `S`, at the top level of `S.constants` or as an upvalue of a global function, so the lookup resolves (`lib/constants.lua:183`'s `locked` sits inside a LEVELS table).
- A scene's `data.frozen` becomes `data.locked`, at `lib/scenes.lua:328`, `:374`, `:485`, `:1243` and `:1280`. The design writes it `scene.locked[i]`; in the code it is `scene.data.locked[i]`.
- **No function, registry, hook or param names `frozen` for the lock.** `toggle_lock` (global, `MODULE_HOMES` at `test/unit/structure_test.lua:404`), `S.register_lock_change`, `S.registry.lock_change`, the hooks' `fn(voice_idx, locked)` and morph's and `scene_entries`' voice-state key `"lock"` all say lock already, and keep their names. So "function names that say frozen for the lock follow" (design line 79) is empty in lib/. Only test locals rename: `frozen` becomes `locked`; `frozen_pitch` and `frozen_state` in `mutation_test.lua` become `locked_pitch` and `locked_state`; `stopped_frozen` and `running_frozen` become `stopped_locked` and `running_locked`; the `state.frozen` keys at `pages_main_test.lua:547-559` become `state.locked`.
- **Untouched:**
  - Params: the lock is no param, so no param id, PSET line or MIDI map changes.
  - Data files other than scenes: none hold the lock. No OSC address or IO action names it (`lib/io/*` has no lock).
  - User-visible strings: `[L]`, `lock`/`unlock`, `"locked"` and the layout-state names stay.
  - The audio names: `S.lib.freeze.is_frozen`, `register_freeze_change(fn(voice_idx, frozen))` and `frozen_level`.
- **Constants:** `SCENE_DATA_VERSION` goes from 8 to 9 (`lib/constants.lua:11`, exported at `:313`). `SCENE_FORMAT_FLOOR` goes from 7 to 9 (`:15`, exported at `:314`). `lib/scenes.lua:27-28` and `:1107-1119` read them by name. The comments become something like "9 since the work before 3.8" and "9: files of 3.5-3.7 are set aside".

### 3. Order and seams

- 0a runs alone, before every other package, which all reach `S.locked`.
- 0a gives 1a and 2b format 9 with `data.locked`. **1a and 2b must not raise the version again:** the reshape of `voices[i]`, the matrix's slots 17-22 and the removal of the six `strata_lfo<n>_dest_key` blocks all go under 9. So might 4a's marker for "a PSET holds these scenes" (design §6, left to the builder), if it goes in scenes.data.
- **0a must leave these alone:**
  - `voices[i].params/grain/crossmod/extras` (1a's).
  - The LFO dest-key assertions in the PSET half of `system_37_test.lua:341-346` (2b's).
  - `lib/data_files.lua`'s table count (0a adds no tables).
  - The format 9 fixture. Design §3 has it added "for later releases to load", but the shape is not final until 2b, or 4a if 4a writes a field. Recorded in 0a, it would be re-recorded twice. The plan should give it to the last package that changes the format.
- **The 3.6 PSET half stays with 0a's test.** 0a re-bases only the scenes half of the 3.6 system test, which wave 1 and 2 packages also edit (1a the voice values, 2b the LFO dest lines). The landing resolves overlaps (design §10).
- **Rules:** no AGENTS.md rule breaks. `AGENTS.md:245` itself becomes false and is rewritten. A proposal of 33 words against 53: "- **Lock** (`[L]`, `toggle_lock`, the state `S.locked`): randomize, drift, mutation and scatter leave a locked voice alone, and it can still be edited; "freeze" names only the audio freeze. `docs/notes/lua/mutation.md`, `docs/notes/lua/freeze.md`". `freeze.md`'s "Freeze is not the lock" item (line 3) becomes "`S.locked` (the scene field `locked`)". `ui-core.md:4` is reduced to "The lock is called lock everywhere (`[L]`, hints, `S.locked`, `toggle_lock`)".

### 4. Tests

**The test that scans names: `test/unit/engine_sync_test.lua:305`**, "the lock keeps its lock names and the freeze module never touches S.frozen". It requires `S%.frozen%[` to exist and `lib/freeze.lua` never to name `S.frozen`. Rewrite it as "the lock is S.locked, and no Lua file names S.frozen or a scene field frozen":
- `S%.locked%[` is found in lib/.
- No file under lib/ or strata.lua matches `S%.frozen` or `%.frozen%f[^%w_]`. The frontier pattern spares `.is_frozen` and `.frozen_level`, and test/ stays out, since `notes_model.lua`'s `state.frozen` is audio.
- `lib/freeze.lua` never names `S.locked` or `toggle_lock`.
- MAIN's `[L]` stays.

`:290` ("no Lua file says freeze for the lock feature") stays and may add `"S%.frozen"` to its banned list. `docs_test.lua:971` (the user docs never say freeze for lock) stays as it is.

**Re-based for the floor of 9:**
- `scenes_test.lua:3202` "below format 7" becomes "below format 9". It asserts the floor is 9 (`:3205`), adds cases for formats 7 and 8 (3.5's and 3.7's) beside 1, 5 and 6, and expects the console line "older than format 9" (`:3229`).
- `scenes_test.lua:3239` "a format 7 file loads" becomes "a file at the floor loads, and a field it lacks is its default", with `version = S.constants.SCENE_FORMAT_FLOOR` (`:3250`, `:3253`). Its field deletions (`extras.slide_depth`, `grain.mode`) are 1a's to reshape.
- `scenes_test.lua:3264` (no copy kept): `version = 7` at `:3275` becomes the floor.
- `scenes_test.lua:3319` "a version 7 scenes file migrates to 8 with nothing changed" becomes "a format 9 file loads with nothing changed". It asserts version 9 and floor 9 (`:3323-3324`), writes version 9 (`:3331`) and expects `:3341` to read 9. This keeps `first_difference` (`:3299`) used.
- `scenes_test.lua:3382` (`version = 7`) becomes `SCENE_DATA_VERSION`.
- `registries_test.lua:581` (8 becomes 9), `:606` ("saved as version 8" becomes 9), `:608` (`version = 7` becomes the floor) and `:837` (8 becomes 9).
- `positions_test.lua:349` (8 becomes 9). Its name, "migrate from version 3", is stale and could drop "and migrate from version 3".
- `system_37_test.lua:252` ("a 3.6 scenes file, a 3.6 PSET and a version 2 buffers.data load with their values as saved") is split:
  - The scenes half goes: lines 277-326 and the `:305` "nothing is set aside". In its place, the 3.6 scenes file is set aside whole (`scenes.data.bak` equals the fixture's text, `S.scene_file.problem == "unreadable"`, no slot populated).
  - The PSET, side-file and buffers halves stay.
  - `scene_leaves` (`:190`) and `added_leaf_problem` (`:225`) then have no caller. Delete them.
- `system_37_test.lua:387` "older than format 7" becomes "older than format 9". It uses the fixture unlabeled (format 7) plus one relabeled to 8 (`'["version"]=7,'` replaced by `'["version"]=8,'`).
- **No change:** `structure_test.lua:128-330` (the version-comparison scan; its 6 and 7 are scanner cases, and lib/ compares only with `_FLOOR` and `_DATA_VERSION` names); `data_files_test.lua` (generic `version = 4` tables); every `tab.save` written with `SCENE_DATA_VERSION`.

**New tests:**
1. `scenes_test.lua`, "a captured scene stores the lock as locked": `capture_scene(1)` after `toggle_lock(3)`. It asserts `S.scenes[1].data.locked[3] == true` and that `data.frozen == nil`.
2. `scenes_test.lua`, "a scene without locked is refused": `validate_scene` rejects `data.locked = nil`, `data.locked[3] = nil` and a scene that holds only `frozen`. These are the re-based `:74-75`.
3. `scenes_test.lua`, "a 3.7 scenes file is set aside whole": version 8, with the text equal to `scenes.data.bak`, one console line naming format 9, and the next save writing 9. This is design §11's "Format 9" test, which may instead live in system_37 with the fixture relabeled to 8.

### 5. Risks and open points

- **No 3.7 fixture exists.** Only `test/fixtures/3.6.0-files.lua` and `3.6.0-start-calls.lua` do. Design §3's "tests that load 3.6 and 3.7 files" has nothing recorded for 3.7, so its format 8 file must be made in the test, by relabeling or by writing a capture with version 8.
- **Every player's scenes are set aside on the first start after the update,** with the flash `scenes unreadable (SETUP)` and SETUP's "scenes unreadable, kept" (`S.scene_file.problem` is `"unreadable"`, `system_37_test.lua:411`). It reads like damage. The design accepts losing the file, but says nothing on the wording. Unsure whether a distinct problem such as `"older"` is wanted. That would change `lib/scenes.lua`, `lib/pages/setup.lua` and the setup tests.
- **The console line reads "expected 9 to 9"** for a version above 9, once the floor equals the version (`lib/scenes.lua:1117-1118`). This is cosmetic.
- **The design's §1 counts** need correcting in the plan (above).
- **Seam:** a scene file written between 0a and 1a (format 9, old voice shape) fails 1a's validation. That is harmless, since nothing is released between the packages, but tests must build format 9 files from captures, never from literal old shapes.

## Package 5a, the docs pass

### 1. Files

- **AGENTS.md:**
  - Today it has 7,775 words of 8,000 (`wc -w`).
  - Rules each package rewrites, which 5a checks whole:
    - `:245` (lock, 0a) and `:305` (`SCENE_DATA_VERSION` (9), 0a).
    - The voices-table paragraph ("The `voices` table is the only source of values") and the "Transient scan state ... the one exception to the `voices` table holding every value" rule (1a).
    - "Registered per-voice params" and "CRITICAL: keep Lua and the engine in sync"'s second bullet (2a).
    - "LFOs" and "The matrix adds offsets" (2b).
    - "Data files" (`:240`, 4a).
    - "Scenes: ... a migration default", stale since 3.7 (1a or 5a).
  - The command table does not change (no new command; #742 edits no `addCommand`). Neither does the module table: no package adds a module unless one splits a file.
- **ROADMAP.md:**
  - The section "Between 3.7 and 3.8" (`:100-109`) is done. No release ships, so there is no Shipped row. It becomes a short "done on <date>" note pointing at the design and `docs/decisions/3.8.md`, or is removed with 3.8.0.
  - `:212` "the scene field name `frozen` stays" needs "(reversed: `locked` since scene format 9)".
  - 3.8's "More voice types" (`:115-119`, "whether old scenes need a migration") now builds on the value table and format 9.
- **docs/status.md:**
  - Line 13's "Next" becomes 3.8's design and plan. Remove #738-#744 and #747-#754 as their packages close them (each package removes its own line).
  - "Plans:" names the plan while it is open.
  - Limits: the scenes file's largest table count (today 7474) re-measured by 1a and 2b; AGENTS.md's word count; the LFO limits line if 2b changes the 12 sends.
- **docs/history.md:** its rule (`:5-10`) is "Entries describe a release as it shipped", and there is no release. The groundwork's paragraph and landing line belong to 3.8.0's entry (`docs/workflow.md:112`). 5a should add nothing, or at most hold a draft for 3.8.0. The design's table (line 218) names the file, so this is unsure.
- **docs/decisions/3.8.md does not exist yet.** `docs/decisions/README.md` requires:
  - the file `docs/decisions/<release>.md`;
  - its line in the README's list;
  - each decision with what it costs if wrong;
  - kept numbers when code cites rulings.
  The existing files open with "The other releases: [README](README.md)." and a paragraph naming the design and the numbering series (`docs/decisions/3.7.md:1-5`). The README's 3.8 line has to cover both this groundwork and 3.8's own decisions to come.
- **docs/design/3.8-groundwork-design.md:** its lines that the build differs from could be marked "amended <date>, as built" (§1's counts at least). The workflow asks this only at a release (`docs/workflow.md:116`).

### 2-4. Names and tests

The docs tests that check them:
- `docs_test.lua:781`, the word budget: at most 8000 words, and the file states "a test fails above 8,000 words".
- `:791`, the command table: one row per `addCommand`.
- `:1390`, every `` `NAME` (n) `` in the "Named constants" paragraph equals `S.constants`, with at least ten quoted. `SCENE_DATA_VERSION` (9) is checked there; `SCENE_FORMAT_FLOOR` is not quoted.
- `:833`, every repo path in the maintained docs exists. The maintained docs are AGENTS.md, README.md, ROADMAP.md, `docs/*.md`, `docs/notes/**`, `docs/user/**` and `docs/decisions/**` (`test/helpers.lua:577`). So `docs/decisions/3.8.md` and `docs/history.md` must name only paths that exist after the plan (none of the removed `restore_lfo_destination`-era files are paths).
- `:816-830`: no maintained doc names a removed `engine.<name>(`.
- `:918`: every Lua and test-harness notes file opens with "Must not break".
- `:938`: every user page is linked from its index.
- `:971`: freeze is never said for lock.
- `:1332`: US spelling.
- `:1369`: the start and cleanup tables.
- `:1406`: every registry is named in `state-and-voices.md`.
- `:1424`: every registered invariant.
- `:1614`: every plan under docs/superpowers/plans names the execution skill and a skill per task.
- `:1668`: the release lines. They stay 3.7.0 until 3.8.0.
- `:886`: every changelog fragment has a heading and a bullet.

### 5. Risks

- **docs/history.md and ROADMAP.md have no rule for work with no release.** Their rules are written for releases (`docs/history.md:7-8`, `docs/workflow.md:111-117`), so the plan must say what 5a writes there.
- **5a is listed as "checks"** (design §10, line 200), but it owns `docs/decisions/3.8.md`, which needs the plan's and build's rulings collected from every package's report.
