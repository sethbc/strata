# 3.7 plan facts A: packages 0a, 0b, 1e, 1f, 1g

Read-only survey of the main checkout at **78ba8510** (main moved past the facts files' 334429aa: three docs commits added `docs/design/3.7-design.md`, its fact files, a `ROADMAP.md` paragraph and two `docs/status.md` lines; no file under `lib/` or `test/` changed, so every code line in `docs/design/3.7-facts/lua.md` still holds). "lua.md §n" cites that fact file; what it already establishes is not repeated. "Not found" marks what could not be established. No design is proposed.

---

## Surprises first

1. **`[F]` is banned outside `lib/pages/main.lua`.** `test/unit/engine_sync_test.lua:290-303` ("no Lua file says freeze for the lock feature") fails if any Lua file other than `lib/pages/main.lua` contains `[F]` outside a comment. `[F]` already means 3.2's *audio freeze* on MAIN's status row (`lib/pages/main.lua:186`, `docs/user/pages/main.md:32`, and `test/unit/docs_test.lua:989` requires main.md to describe `[F]` as freeze). §5.2's header `[F]` for fill in `lib/ui/header.lua` breaks that test and gives one mark two meanings.
2. **The header has no free 10 px.** `[F]` is 10 px wide (stub glyph widths). Today's spans at y 8: title 0-27 (SCENES/BUFFER 27 px), dots 32-69, `[M]` 76-87, play mark 90-92, REC/ARM 96-111, `S16` 114-127. The gaps are 70-75 (6 px), 93-95 (3 px) and 112-113 (2 px). On a page with `header_status` (SEQ has one, `lib/pages/seq.lua:763-765`), the status text runs from x 79 to 113 and the play mark sits at 73-75. `test/unit/ui_header_test.lua:74-83` pins every HEADER value.
3. **Release paths.** The 256 returns on `z == 0` at `lib/grid/layout_256.lua:303`, before any row-8 handling. The 128h returns on every control-row release at `lib/grid/layout_128h.lua:199-213` (`y ~= LAYOUT_128H.control_row`). So a held fill key needs a release branch above those returns. `test/unit/grid_layout_128h_test.lua:88-104` pins column 4 as play/stop ("column 4 starts the pattern").
4. **crow triggers are rising-edge only** (`lib/io/crow.lua:431-436`: `if rising ~= 1 and rising ~= true then return end`), and `io_actions` has no hold semantics. A crow "hold" of fill therefore needs the falling edge, which no path delivers today.
5. **A `set_save(false)` param survives a PSET load.** `pset.default` (`lib/params_setup.lua:203-204`) returns nil for `param.save == false`, so `migrate_read_pset` never defaults it. A latched fill stays on through a PSET load.
6. **A sync sends `buf_scan` unmodulated.** `send_grain_params` (`lib/engine_sync.lua:610-620`) sends the stored `voice.grain.buf_scan`. Only ids in `base_overrides` or `extra_offsets` are resent with their modulation (`resend_modulated_voice_params`, `:440-457`), and only those get it in a start (`start_value`, `:427-432`). A new factor table must join both lists, or every sync and start sends the unfactored scan.
7. **`AGENTS.md` quotes `BUFFER_DATA_VERSION` (2)** in its constants paragraph, which `docs_test.lua:1389-1403` checks. So 2d's `buffers.data` version 3 must edit `AGENTS.md` too, as 0b does for the scene version.
8. **`SCENES_FIELDS` lives in `lib/constants.lua:111`** (0b's file) and is also read by `lib/arc/scenes.lua:15, :41`, which is not in 1f's list.
9. **`side_files.new` requires `live_file`** (`lib/side_files.lua:24-29`). There is no PSET-only mode, so 1g either keeps a live file in `data/strata/` (a new data file for `AGENTS.md`'s list) or never calls `load_live`/`save_now`.
10. **The LFO step hooks get no arguments** (`lib/lfos.lua:685-687`), not the step's beat reading. Hooks run in registration order. Include-time registrations go macros (`lib/macros.lua:278`), matrix (`lib/matrix.lua:399`), expression (`:382`), targets (`lib/io/targets.lua:210`), midi_out (`:432`), crow (`:467`) and ii (`:209`); notes' flush registers last, at its start step (`lib/notes.lua:769`). For the matrix to read a sequence's new value in the same step, the sequences' hook must register before `lib/matrix.lua`'s, so the module's include goes before `strata.lua:81`.
11. `docs/status.md:16`'s scan-unit line is **already fixed** on main ("loop lengths per second"). `ROADMAP.md`'s wrong line moved from 109 to **111**.

---

## 0a. Room in AGENTS.md and the wrong lines

### (1) The count and the tests on AGENTS.md

- **The count: 7917 words.** Counting `%S+` as the test does gives the same figure as `wc -w`, so 83 are free. Per section: Project Overview 444, How work is done 200, Architecture 315, Modules table 690, Lua modules and `S` 271, Lua↔SC 1178, Invariants 2603, Working in parallel 423, Development & Testing 584, Code Style 369, Lua/engine sync 135, UI 386, grid and arc 218, title block 101.
- Tests that read AGENTS.md (`test/unit/docs_test.lua` unless noted):
  - `:779-788` "stays within its word budget": `AGENTS_WORD_LIMIT = 8000` counted as `%S+`. The file must still contain the phrase `a test fails above 8,000 words` (matched by `a test fails above ([%d,]+) words`, equal to 8000).
  - `:790-831` "command table lists exactly the engine's commands": rows must match `^| \`engine%.(%w+)%((.-)%)\` | \`"(%a*)"\` |`, exactly one per engine `addCommand`, with the same signature and argument count. No `engine.<name>(` in any maintained doc may name a missing command. The check also requires its list of read docs to include `ROADMAP.md`, `docs/status.md`, `docs/checks.md`, `docs/workflow.md`, `docs/history.md`, `docs/decisions/README.md`, `docs/decisions/3.4.md`, `docs/notes/test-harness.md`, `docs/notes/test-harness/run-and-helpers.md`, `docs/notes/engine/structure.md` and `docs/notes/lua/state-and-voices.md`.
  - `:736-749`: the rows of `setModAmpAmt` and `setModFreqAmt` must contain `-2 to 2` (`"%g to %g"`), and `setModSpeed`'s row `0.1-50` (`"%g-%g"`), from the params' controlspecs.
  - `:767-775`: AGENTS.md exists and CLAUDE.md does not.
  - `:1035-1042`: AGENTS.md names every `docs/notes/engine/<name>.md` in backticks, and `STRATA_ENGINE_CHECK_AREAS`. The new areas `onsets` and `envelopes` must be named.
  - `:1203-1222`: every `` `test/run_engine_check_313.sh [...]` `` synopsis equals the script's usage line.
  - `:1245-1254`: the bullet starting `- \`test/run_engine_check_313.sh` names `` `-1` ``, `` `-l` ``, `shard` and `.github/workflows/test.yml`.
  - `:1232-1243`: any "N shards" or "N parallel shards" count equals the workflow's.
  - `:1389-1403`: in the paragraph starting `**Named constants, never magic numbers.**`, every `` `NAME` (n, `` or `` `NAME` (n) `` must equal `S.constants.NAME`, and at least ten must be quoted. 25 are quoted today: NUM_VOICES 7, NUM_SCENES 16, PATTERN_LENGTH 16, **SCENE_DATA_VERSION 7**, NUM_MOD_SLOTS 3, NUM_UI_PAGES 10, MAX_STEP_LEVEL 15, NUM_BUFFERS 8, STANDARD_BUFFER_SECONDS 16, **BUFFER_DATA_VERSION 2**, PSET_FORMAT 2, NUM_LFOS 6, NUM_BOOKMARKS 4, WAVEFORM_POINTS 64, NORNS_SAMPLE_RATE 48000, NUM_MACROS 16, MACRO_BANK_SIZE 4, MACRO_TARGETS 8, MATRIX_SLOTS 16, NUM_GESTURES 4, SCENE_BANK_SIZE 8, SCENE_NAME_MAX 12, NUM_FAST_DESTINATIONS 5, FAST_MOD_NOTE_SLOTS 1, NOTE_SLOTS 8.
  - `:1544-1559`: `## How work is done: the superpowers skills` names the same skill set as `docs/workflow.md`'s `## Skills`, and comes before `## Architecture`.
  - `:1667-1687`: `The current release is (%d+%.%d+%.%d+)` equals CHANGELOG.md's newest `## Version`.
  - `:832-841` and helpers `test/helpers.lua:433-452` (`doc_paths_missing`): every backticked repo path and every link (anchors against GitHub heading anchors) in a maintained doc must exist. **So an AGENTS.md row naming `lib/chance.lua`, `lib/conditions.lua` or `lib/random_sequences.lua` can only land with or after its file.**
  - `:1331-1351`: US spelling.
  - `test/unit/structure_test.lua:3072-3077`: AGENTS.md says `about <N> minutes`, where N is the workflow's area times summed and rounded (19 today: "about 19 minutes of areas, 20 in all", `AGENTS.md:275`), and never `about 9 minutes`.
- **Not found**: any test of the module table, the registries list or the invariant bullets. Module-table rows are checked only through the path check.

### (2) Passages that could move (ranked by words freed per risk)

Each candidate: its location in AGENTS.md, its words now, a rough figure for what it frees, and the notes file that already holds the detail (checked).

1. **`AGENTS.md:9`, Project Overview paragraph ("Strata is an ambient granular soundscape generator...")**: 167 words. Shrinking it to its first sentence plus the release sentence frees about 130. Home: `README.md:7-24` lists every feature (seven voices, buffers, MOD, the ten pages). The sentence `The current release is 3.6.0 (see CHANGELOG.md).` must stay (`docs_test.lua:1685`). **Risk: none.**
2. **`AGENTS.md:170`, "**Polls** (engine → Lua)..."**: 85 words. Reduced to one pointer, it frees about 65. Home: `docs/notes/engine/buffers.md:15-34` (Polls, The polls' encodings), `docs/notes/engine/record.md`, `docs/notes/lua/buffers.md` and `docs/notes/lua/record.md`. The paragraph already says the formulas are there. **Risk: low.**
3. **`AGENTS.md:127`, "**Registries** (`S.registry`: ...)"**: 77 words. Replacing the list with a pointer frees about 45 and removes the wrong "thirteen" in the same edit. Home: `docs/notes/lua/state-and-voices.md:21`, the Owns bullet, whose completeness `docs_test.lua:1405-1421` checks. Which registries close and which stay open is at `:224`. 3.7's `voice_hit` would otherwise need adding here too. **Risk: low.**
4. **Development & Testing bullets, `AGENTS.md:272` (81 words), `:274` (55), `:275` (102), `:277-280` (120)**: condensing them frees about 150. Home: `docs/checks.md:9-33`. It holds the filter runs, the sync check with `PENDING_COMMANDS`, the ports, the soak, the stubs and `param.t`, and `test/StrataTestNoBoot.sc.in`. Constraints: keep `STRATA_ENGINE_CHECK_AREAS`, `about 19 minutes`, and the `:276` bullet's synopsis, `-1`, `-l`, "shard" and `.github/workflows/test.yml`. **Risk: low to medium** (four tests read text here).
5. **`AGENTS.md:290`, Named constants paragraph**: 189 words. Dropping the mirror sentences ("The engine mirrors them as ... `notePoolMax`.", about 70 words) frees about 70. Home: `docs/notes/engine/modulation.md`, `docs/notes/engine/notes.md` and `docs/notes/test-harness/engine-stub-and-sync.md` name NUM_FAST_DESTINATIONS and NOTE_POOL, and `docs_test.lua:215`, `:2089`, `:2132` enforce the mirrors. Keep at least ten quoted values. **Risk: low** (keep `SCENE_DATA_VERSION`, or remove it here, which also removes 0b's edit).
6. **`AGENTS.md:46`, the engine areas sub-bullet**: 85 words. Cut to the stop/free rule plus the pointer, it frees about 45. Home: `docs/notes/engine/structure.md:161-167` (Areas: the hooks, `order`, stop before free, `areaState`). **Risk: low.**
7. **`AGENTS.md:282-286`, Common norns pitfalls**: 64 words, about 60 freed. Partial home: "Groups cannot nest" is in `docs/notes/lua/params.md` and `docs/notes/lua/lfos.md`. **Not found** in any notes file: `UI.List`'s `set_items` and `clock.sleep` in `init()`. They must be added (for example to `docs/notes/test-harness/stubs.md` or `docs/notes/lua/ui-core.md`), not dropped. **Risk: low.**
8. **`AGENTS.md:168` (37 words, "3.4's five fast-modulation and 3.5's four note commands...") and `:172` (33 words, Index conversion)**: about 50 freed together. Homes: `docs/notes/engine/modulation.md:125`, `docs/notes/engine/notes.md:4, :90`, `docs/notes/lua/engine-sync.md:15` and `docs/notes/engine/voices.md:32`. **Risk: low to medium.**
9. **`AGENTS.md:118`, "Each screen page, grid layout and the arc's page rings have their own user page..."**: 46 words, about 40 freed. The module table repeats it, and `:13` already names `docs/history.md`. **Risk: low.**
10. **`AGENTS.md:174`, "The `voices` table is the only source of values."**: 62 words, about 35 freed. Home: `docs/notes/lua/engine-sync.md:8`. **Risk: medium** (a core rule; keep one line).
11. **Working in parallel, `AGENTS.md:255-263`**: 423 words, about 200 freed. Home: `docs/workflow.md:65-79` (Worker rules: worktree, rebase, scratch folder, ownership, shared files) and `:99-107`. The registration-conflict rule (`AGENTS.md:261`) exists only in AGENTS.md: `docs/workflow.md:123` points back to it. It must move into workflow.md, not be dropped. **Risk: medium** (every agent's process rules).

Candidates 1-6 alone free about 500.

### (3) The wrong lines (text at 78ba8510)

- **The scan's unit:**
  - `docs/notes/engine/grains.md:25`, inside the `\strataGrainBuf` bullet: "`bufPos` (0-1) and the scan are fractions of the valid region (`bufFrames`), so a 2 s sample uses the whole range; `bufScan` moves the position in **valid-region lengths per second** (spec §1; bipolar, wraps; ..."
  - `lib/engine/StrataGrainDefs.sc:134-138`:
    ```
    // Granular processor for a buffer slot (bufnumL/R). bufPos (0-1) and
    // the scan are fractions of the valid region (bufFrames), so a short
    // sample uses the whole position range; bufScan moves the position
    // in valid-region lengths per second and wraps. No grain reads past
    ```
  - `lib/engine/StrataFreeze.sc:129-130`: `// The rate of a buffer grain synth's position scan (valid-region` / `// lengths per second): stopped while frozen`.
  - `ROADMAP.md:111`: "Today `bufScan` moves in lengths of the valid region per second, so a 300 s slot scans 300 s a second at scan 1 (the candidate `docs/status.md` has carried since 3.3); loop regions are the answer until this ships."
  - `docs/status.md:16` is already right: "moves in loop lengths per second, so a voice whose loop is a whole 300 s slot scans 300 s per second at scan 1; ... until 3.7's speed unit".
  - The right text, for the fix: `docs/notes/engine/loops.md:27` ("`bufPos`, the scan and the spread are fractions of the loop and wrap inside it (a scan of 1 crosses the loop once a second, whatever its length)") and `lib/playheads.lua:36` ("The scan's rate in loop fractions a second").
  - The statement that `.sc` comments change no behavior is not checked by any test, but the file is an engine file: no norns restart is needed for comments.
- **`AGENTS.md:127`**: "...: they are read at init, never at include time (the last thirteen are read at each use and stay open), and each `S.register_*` function checks its argument and refuses a duplicate name." Code: `lib/state.lua:71-72` `INIT_READ = {"voice_params", "scene_fields", "lfo_destinations", "fx_params", "start", "menu_close", "scene_blocks", "scene_migrations", "pset_hooks"}`; 31 registries (`:27-62`), so 22 stay open. The list's last thirteen (`param_touch` .. `io_sections`) are all open, but so are `pages`, `params`, `cleanup`, `grid_layouts`, `source_change`, `param_filters`, `grain_restart`, `alt_release` and `invariants`. `docs/notes/lua/state-and-voices.md:224` also says "3.6's six", which counts six of 3.6's seven open registries (`io_sections` is described separately at `:222`).
- **`docs/status.md:24`**: "Lua's 200-local limit applies to each function: the locals probe in `test/run.lua` measures the free locals ..." The probe is in `test/unit/structure_test.lua:582` ("each file keeps 30 free locals"), which `test/run.lua` runs.
- **`AGENTS.md:248`**: "...; they end at the voice's next step without them, a stop, `replace_pattern` or a shorter length. `docs/notes/lua/sequencer.md`". Code: `apply_step` (`lib/sequencer.lua:568-611`) clears them only at a played step, and `take_position` (`:1048-1053`) ends them at a wrap with no set step. `docs/notes/lua/sequencer.md:10` says "the voice's previous played step" correctly.
- **`buf_pos` 1**: `docs/notes/lua/playheads.md:20` says "`buf_pos` wraps with the phase: `buf_pos` 1 is the loop's start again, as the engine's `Phasor` wraps." `lib/playheads.lua:74` does that: `return start + ((buf_pos + heads[voice_idx].phase) % 1) * length`. The engine holds `bufPos` under `lastLoopPosition { ^0.999999 }` (`lib/engine/StrataLoop.sc:17`) at `:59` (`bufPos.min(this.lastLoopPosition) + scanPhase + spreadDraw).wrap(0, 1)`), so `bufPos` 1 is the loop's last start (#363, `docs/notes/engine/loops.md:27`). §2.3 gives this fix to 2a (`lib/playheads.lua`), not 0a; 0a can file it.

---

## 0b. Lua seams

### (1) `engine.retrigger` call sites and voice starts

- **`lib/notes.lua:379`**, in `play_own(voice, note, played, now)` (`:354-384`), the slot-1 branch of `M.play` (`:413`):
  ```lua
  note.set_own(played.pitch)
  if previous then forget(previous, now, moved) end
  if not note.quiet and not S.voices[voice].active then toggle_voice(voice) end
  local record = new_record(voice, 1, played, now)
  slots[voice][1] = record
  run_note_hooks(moved and "moved" or "started", record)
  ...
  if (was_parked or frozen_synth(voice)) and S.voices[voice].active then
    send_note_on(voice, 1, record)
    messages = messages + 1
  end
  if not note.quiet then engine.retrigger(voice - 1, record.velocity) end
  ```
  The start at `:362` always has a retrigger after it, because both depend on `not note.quiet`. It goes through the global `toggle_voice`, not `start_voice`, so "a retrigger follows" must pass through `toggle_voice` or `:362` must call `start_voice` itself. Quiet plays come only from the sequencer (`chord_note`, `lib/sequencer.lua:464-473`, `quiet = own`). `start_extra` (`lib/notes.lua:387-395`) sends `noteExpression` and `noteOn` and no retrigger. Its callers: MIDI (`lib/midi_in.lua:443`, owner `"midi"`, `MIDI.owner` `:33`) and a step's chord (owner `"seq"`, `SEQ.note_owner`, `lib/sequencer.lua:71`, from `play_chord` `:613-622`).
- **`lib/sequencer.lua:645`**, `voices_play(event)` (`:631-649`):
  ```lua
  if event.first then
    apply_step(voice_idx, event)
    if not voice.active then
      S.lib.engine_sync.start_voice(voice_idx)
      started = true
    end
  end
  if not voice.active then return end
  if not started or gated(voice_idx) then
    if gated(voice_idx) then send_gate_seconds(voice_idx, M.gate_seconds(voice_idx, event.step, event.hits)) end
    engine.retrigger(voice_idx - 1, event.velocity)
  end
  play_chord(voice_idx, event)
  ```
  A start (`:638`) has a retrigger after it only when `gated(voice_idx)` (`:151`). Ratchet hits 2..n come through here with `event.first == false`, and each gets a retrigger.
- **`lib/io/actions.lua:85`**, `M.retrigger(voice, velocity)` (`:73-87`): `S.lib.sequencer.note_gate(v)`, then `engine.retrigger(v - 1, math.max(0, math.min(1, velocity)))`. It never starts a voice (it returns false when stopped). Callers: crow `lib/io/crow.lua:416`, ii `lib/io/ii.lua:363`, OSC `lib/io/osc.lua:182`.
- **`start_voice`**: `function M.start_voice(voice_idx)`, `lib/engine_sync.lua:674-707` (its comment is `:660-673`). It returns early for an invalid voice or a running one. The order: `forget_sent_voice_values`, `M.send_grain_source`, `send_grain_params(voice_idx, carried)`, `send_registered_voice_values`, `engine.voiceOn(...)`, then inside `xpcall` `run_grain_restart_hooks`, `send_synth_params`, `send_crossmod_and_bend`. On error it sends `voiceOff`, runs `run_voice_stop_hooks` and re-raises. Then `voice.active = true` and `resend_modulated_voice_params(voice_idx, carried)`.
- **`toggle_voice(voice_idx)`**: global, `lib/engine_sync.lua:535-550` (in `MODULE_HOMES`). On a stopped voice it calls `M.start_voice(voice_idx)`, then `update_voice_list()`, `request_redraw()`, `grid_redraw()`.
- **Starters through `toggle_voice`** (none followed by a retrigger):
  - `lib/scenes.lua:659`, in `M.apply_entries` (`:631`): a scene starts a voice after its last entry.
  - `lib/pages/main.lua:254` (K3 and the arc button, `start_stop_selected_voice`).
  - `lib/pages/voice.lua:313` (the arc button).
  - The grids: `lib/grid/layout_256.lua:392`, `layout_128h.lua:185`, `layout_128v.lua:135`, `layout_64.lua:130`.
  - `lib/io/actions.lua:70` (`run_voice`).
  - `strata.lua:189, :193` (the startup clock).
  - Layout states only: `lib/pages/main.lua:304, :329, :349` and `lib/pages/buffer.lua:1028, :1033`.
  - Stops only: `lib/midi_in.lua:218, :482` and `lib/scenes.lua:596`.
- `start_voice` callers outside `toggle_voice`: only `lib/sequencer.lua:638`.
- Tests that read the order of retriggers (they read engine calls, which stay the same if the new door still sends `engine.retrigger`): `test/unit/sequencer_test.lua:1365, :1391, :1411, :1448, :1473, :2437, :2469, :2653`, `test/unit/io_actions_test.lua:73-121`, `test/unit/midi_in_test.lua:91, :971` and `test/unit/strata_test.lua:239`. The source-scan pattern for a "one caller" test: `test/unit/engine_sync_test.lua:290-303` (`h.read_lua_sources()`, comments stripped, path filters).

### (2) `lib/state.lua`: registries

- Declaration: a key in `M.registry = { ... }`, `lib/state.lua:27-62`. 3.6's block is at `:54-61`, with comment `-- 3.6's (design §0.1), read at each use`.
- Closing: `INIT_READ` at `:71-72`, with `close_registries` at `:74-76`. A registry read at each use is left out of it.
- Helpers: `require_arg` `:116`, `is_whole` `:120`, `all_entries` `:125`, `name_taken` `:134`, `require_known_fields` `:143`, `require_named(record, registry, kind, name_field, allowed)` `:341-350`, `optional_function` `:352`, `require_functions(record, where, required, optional)` `:355-362`.
- A complete small example, `lib/state.lua:518-527`:
  ```lua
  local NOTE_HOOK_FIELDS = {name = true, started = true, ended = true, moved = true, expressed = true}
  ...
  function M.register_note_hook(record)
    local kind = "register_note_hook"
    local where = require_named(record, "note_hooks", kind, "name", NOTE_HOOK_FIELDS)
    require_functions(record, where, {}, {"started", "ended", "moved", "expressed"})
    table.insert(M.registry.note_hooks, record)
  end
  ```
  A plain function hook is `:499-502`:
  ```lua
  function M.register_voice_stop(fn)
    require_arg(type(fn) == "function", "register_voice_stop", "a hook is a function")
    table.insert(M.registry.voice_stop, fn)
  end
  ```
  How hooks run contained: `lib/engine_sync.lua:528-533`: `S.lib.ui_frame.contained_call(voice_stop_errors, index, "voice stop hook", hook, voice_idx)`.
- `MOD_SOURCE_FIELDS`, `lib/state.lua:369-370`: `{key, name, section, value, range, describe, visible, row}`. `MOD_SOURCE_ROW_FIELDS` `:371`: `{enc, fine_enc, press, alt_press, hints}`. `MOD_SOURCE_NAME_MAX = 4` (`:372`). `M.register_mod_source` (`:475-497`) checks:
  - `require_named` on `key` (so an unknown field such as `fields` is refused today);
  - the name is 1-4 characters, and the section a non-empty string;
  - `value` is a function, and `describe` and `visible` are optional functions;
  - the range is `{min, max}` with min < max;
  - `row` is optional, and when present has only known fields, each an optional function.
- The tests a new registry needs, in `test/unit/registries_test.lua` (the 3.6 model is `:998-1085`; helpers `fresh_state()`, `refused(fn, ...)`, `load_strata`):
  - the argument checks and the duplicate refusal;
  - an unknown field refused (`names_field`, `:870-875` style);
  - the registry open after init (`:1076-1084` style), or closed (`:939-960`).
  - A mod source's new field needs a case in `:907-918` (the `mod_source(...)` helper is at `:860-865`).
- The docs test: `docs/notes/lua/state-and-voices.md:21`, the line starting `  - \`S.registry\``, must name every registry key in backticks (`docs_test.lua:1405-1421`). The prose at `:212-224` describes each record (not tested).

### (3) `lib/engine_sync.lua`: value functions

| Function | Where | Signature |
|---|---|---|
| `engine_param_value` (global) | `:54-58` | `(param_id)`: `S.engine_param_values[param_id]`, else `params:get(param_id)` |
| `with_lfo_offsets` (local; exported `M.with_lfo_offsets` `:715`) | `:71-93` | `(param_id, value)` |
| `send_engine_value` (local; `M.send_engine_value` `:716`) | `:262-273` | `(param_id, value)`: the budget, then `send_now` → `deliver` (`:170-183`), which sets `S.engine_param_values[param_id] = value` and calls `S.engine_senders[param_id](value)` |
| `M.expected_value` | `:294-298` | `(param_id)`: `budget.pending[id]`, else `S.engine_param_values[id]` |
| `send_param_to_engine` (global) | `:348-350` | `(param_id, value)`: `send_engine_value(param_id, with_lfo_offsets(param_id, value))` |
| `send_base` (local) | `:358-360` | `send_engine_value(id, with_lfo_offsets(id, params:get(id)))` |
| `M.set_base_override` | `:364-370` | `(param_id, value)`: a finite value or it raises; stores it, then `send_base` |
| `M.clear_base_override` | `:372-376` | `(param_id)` |
| `M.engine_base_value` | `:379-383` | |
| touch hook | `:385` | `S.register_param_touch(function(param_id) M.clear_base_override(param_id) end)` |
| `M.set_extra_offset` | `:390-404` | `(source_key, param_id, offset)`: nil clears; sends nothing |
| `start_value` (local) | `:427-432` | modulates only ids in `base_overrides` or `extra_offsets` |
| `resend_modulated_voice_params` (local) | `:440-457` | resends the ids in those two tables that start with `v<i>_` |

- The chain from a stored value to the engine is `params:get(id)` or the action's value → `with_lfo_offsets`. Inside it:
  1. `base_overrides[id]` replaces the value;
  2. the LFO offset is `Σ S.lfo_scaled[n]` for each LFO whose `S.lfo_last_dest[n] == id`, scaled by `0.5 * (max - min)`;
  3. the `extra_offsets[id]` entries are summed in;
  4. `util.clamp(value + offset, min, max)`, once.

  The result goes to `send_engine_value`, `deliver` and `S.engine_param_values[id]`, and then to the sender. The voice senders are `M.add_voice_sender`, `:106-113`, gated on `S.voices[v].active`.
- **A factor "applied last"** goes after the clamp at `:92`, the line `return util.clamp(value + offset, minval, maxval)`. Note the early return `if not modulated then return value end` at `:91`, which a factor must also cover.
  - `S.engine_param_values` then holds the factored value, so `engine_param_value("v<i>_buf_scan")`, which `lib/playheads.lua:37` reads, would carry the factor.
  - `start_value` (`:428`) and `resend_modulated_voice_params` (`:444`) list only `{base_overrides, extra_offsets}`. A factor table must join both, or `send_grain_params` (`:619`, the stored `voice.grain.buf_scan`) bypasses it.
  - Every other caller of `with_lfo_offsets`: `lib/macros.lua:281`, `lib/matrix.lua:255, :280`, `lib/expression.lua:327`, `lib/lfos.lua:459, :465, :493`.

### (4) `lib/pages/mod.lua` and `S.lib.ui_field_list`

- **State**: `S.mod_page = {row, row_id, view = "list", views = 0, macro = 1, target_row = 1, target_column = 1, routing = 1, routing_row = 1}` (`:56-57`). `MOD_PAGE` (`:40-50`, exported `S.MOD_PAGE` `:51`) holds `sections`, the geometry (`title_y = 16, view_first_y = 24, view_spacing = 7, view_label_x = 8, visible_rows = 5`), `columns` and `routing_rows`.
- **The list**: `section_order` `:112`, `rows_from_registry` `:129-148`. A source row is `{id = "source:" .. key, label = name, kind = "source", source = record, section}` (`:141-142`). Also `build_rows` `:151-164`, `list_cursor` `:169-184`, `M.place(id)` `:198-208`, `row_macro` `:211`.
- **K3 dispatch**: `mod_key(n)` `:534-552`. With `view ~= "list"`, K2 is `close_view()`, K3 in targets steps the column, and K3 in routing toggles on/off. In the list, K2 is `next_section()` and K3 is `press(cursor_row())`. `press(row)` is at `:418-433`:
  ```lua
  elseif row.kind == "source" then
    local m = row_macro(row)
    if m then
      open_targets(m)
    elseif row.source.row and row.source.row.press then
      row.source.row.press()
    end
  ```
- **The views**:
  - **Enter**: `change_view(view)` `:389-394` (sets the view, `views + 1`, `request_redraw`), `open_targets(m)` `:396-399`, `open_routing(k)` `:401-404`.
  - **Leave**: `close_view()` `:408-415`. It ends learn, then `local id = state.view == "targets" and ("source:macro" .. state.macro) or ("routing:" .. state.routing)`, `change_view("list")`, `M.place(id)`. A third view needs its own id here.
  - **Draw**: `redraw_mod()` `:830-841` branches `targets`/`routing`/else. `draw_targets` `:786-793` uses `FL.draw(TARGET_ROWS, state.target_row, {visible, first_y = view_first_y, spacing = view_spacing}, draw_target_row)`. `draw_routing` is `:820-828`, with rows `ROUTING_VIEW_ROWS` `:796-797` and `draw_routing_row` `:810-818`.
  - **Encoders**: `mod_enc(n, d)` `:512-525` branches on the view (`targets_enc` `:467-485`, `routing_enc` `:490-510`).
  - **Other view branches**: `mod_alt_key` `:554-573`, `hold_action` `:597-615`, `mod_randomize_section` `:652-660`, `mod_arc_button` `:665-686`, `view_hint(alt_held)` `:903-916`, `mod_hints` `:920-926`, `mod_animates` `:932-947` (`view ~= "list"` returns false), `M.view` `:967`, `M.section()` `:973-978`, `M.carry_context` `:1042-1047`.
  - `lib/arc/mod.lua:94-150` branches on `mod_page().view()` for `"targets"`, `"routing"` and else (list). That file is outside 0b's list, and a new view would get the list's rings.
- **`layout_states`** `:1152-1224`: `state(name, id, setup)` `:1121-1126`, `view_state(name, open, row, column, setup)` `:1128-1138`, the list's states, then loops adding the target and routing view states. The record is at `:1228-1232` (`layout_states = layout_states`).
- **Tests that pin the list and the views**, in `test/unit/pages_mod_test.lua`:
  - `:117` MOD is the sixth page;
  - `:138` the list draws each section's sources;
  - `:173` "a section registered by a test shows after the matrix, read-only without a row";
  - `:228` "K3 on a macro row opens its targets; ... K2 goes back" (asserts `S.mod_page.view` and hints);
  - `:361` the gesture row's K3;
  - `:393` "K3 on an LFO row goes to the LFO page";
  - `:406` and `:446` the routing view;
  - `:547` "MOD builds its rows once";
  - `:675` the hint row.
  - `test/unit/ui_layout_test.lua:33-57` draws every record's `layout_states`.
- **`S.lib.ui_field_list`** (`lib/ui/field_list.lua`): stateless, with **no constructor**. Rows are `{label, param_id?, selectable, section?}`.
  - `M.move(rows, cursor, d)` `:28`, `M.clamp(rows, cursor)` `:43`, `M.ordinal(rows, cursor)` `:54`.
  - `M.first_visible(rows, cursor, visible, tail)` `:69`, `M.tail_room` `:76`, `M.move_scroll(rows, cursor, tail, d, visible)` `:84`.
  - `M.draw_marker(first, visible, count, top, bottom, x)` `:109`.
  - `M.draw(rows, cursor, spec, draw_row)` `:129`, where `spec = {visible, first_y, spacing, value_right = 124, marker_top?, marker_bottom?, tail?}` and `draw_row(row, y, selected, value_right)`.
  - SEQ's edit view calls `field_list.clamp` (`lib/pages/seq.lua:440, :445`), `field_list.move` (`:451`) and `field_list.draw` (`:529-531`), with `SEQ_EDIT.visible = 5, first_y = 24, spacing = 7, value_right = 124` (`:58-60`).

### (5) `SCENE_DATA_VERSION` 7: every place

- Code: `lib/constants.lua:11` `local SCENE_DATA_VERSION = 7  -- Scene file format version (written into scenes.data)`; exported at `:303`. `lib/scenes.lua:28, :1063, :1125-1129, :1173-1175` read the constant (no literal 7).
- Tests asserting 7:
  - `test/unit/positions_test.lua:349`;
  - `test/unit/registries_test.lua:582`, `:608` (`saved.version, 7, "saved as version 7"`), `:841` (in "the 3.3 constants");
  - `test/unit/scenes_test.lua:1301`, `:1530` (the test **name** says "save as version 7"), `:1538`, `:1611`, `:1674`, `:1858`, `:2841` (`"the file format is 7"`), `:2862`, `:3174`;
  - `test/unit/expression_test.lua:529` (`"as format 7"`).
  - Not to change: `test/unit/expression_test.lua:504` (the migration's `before_version == 7`), `lib/notes.lua:734` (`before_version = 7`), `test/unit/registries_test.lua:570` (a test name, "migrates to 7"), and the "version 99" tests (`scenes_test.lua:126, :149, :1820, :2216`).
- Docs: `AGENTS.md:290` (`` `SCENE_DATA_VERSION` (7) ``, checked by `docs_test.lua:1389`) and `docs/notes/lua/scenes.md:277` ("`{version = SCENE_DATA_VERSION, scenes = {...}}` (version 7, since 3.5)"). **Not found** in `docs/user`.

### (6) `lib/constants.lua`: tables, orders

- Shape: the top-level `local`s (`:8-297`), then `return { ... }` `:299-364`. 3.4's pattern is "fields of this table, never new locals" (`:354`, e.g. `NUM_MACROS = 16`, `ENGINE_BUDGET = {...}` `:363`). A tunables table such as `DIVISIONS = {...}` goes as a field in the return table, which is the safe place: the constants main chunk has 153 locals free (lua.md §9). `test/unit/structure_test.lua:270-278` requires a plain table.
- Existing division lists (for comparison, not reuse):
  - `SEQ.division_names` / `division_beats` (8, `lib/sequencer.lua:37-38`);
  - `LFO.divisions` (22, `lib/lfos.lua:45-48`);
  - crow's `SPEC.divisions` (7, `lib/io/crow.lua:32-33`).
- **`START_ORDER`** (`:187-223`), in use: 5, 10, 15, 16, 20, 30, 40, 50, 60, 62, 65, 70, 80, 85, 88, 90, 92-97, 100, 105, 107, 108, 109, 110, 120, 125, 130, 140, 150, 160, 161.
  - Free: 1-4, 6-9, 11-14, 17-19, 21-29, 31-39, 41-49, 51-59, 61, 63-64, 66-69, 71-79, 81-84, 86-87, 89, 91, 98-99, 101-104, 106, 111-119, 121-124, 126-129, 131-139, 141-149, 151-159, 162 and up.
- **`CLEANUP_ORDER`** (`:250-297`), in use: 10, 20, 30, 32, 34, 36, 38, 40, 50, 60, 70, 80, 85, 90, 95, 97, 100, 110, 112, 114, 117-120, 122, 124, 126-128, 130, 132, 135, 140, 142-150, 152, 160, 170, 180.
  - Free: 1-9, 11-19, 21-29, 31, 33, 35, 37, 39, 41-49, 51-59, 61-69, 71-79, 81-84, 86-89, 91-94, 96, 98-99, 101-109, 111, 113, 115-116, 121, 123, 125, 129, 131, 133-134, 136-139, 141, 151, 153-159, 161-169, 171-179, 181 and up.
- Each new order needs a row in `docs/notes/lua/state-and-voices.md`'s "The sequence (`START_ORDER`" or "(`CLEANUP_ORDER`" table (`docs_test.lua:1368-1387`). It also needs an entry in `test/unit/structure_test.lua`'s `start_steps()` (`:796-853`, `{ "<step name>", { <observed effects> } }` in order) or `CLEANUP_STEPS` (`:623-632`, a string per step in order), with its effect made observable in the cleanup test (`:673-768`: `clocks`, `watch_method`, `file_steps`).

### (7) Includes and the structure test's lists

- `strata.lua` includes, in order: `:37` state, `:40` constants, then `:49-113` voices, ui/frame, engine_sync, data_files, side_files, buffers, record, lfos, mutation, scenes, io/rig, io/ports, midi_in, history, freeze, loops, variation, voice_mix, performance, files, waveforms, playheads, positions, bookmarks, ui/modal, quantize, mod_sources, macros, scatter, morph, gestures, input_level, **matrix (81)**, notes, mpe, expression, io/actions, io/targets, io/keyed, io/midi_out, io/crow, io/ii, io/jf, io/wsyn, io/wtape, io/er301, io/txo, io/nb, io/controllers, io/remote, io/osc, io/tape, params_setup (101), ui/params, ui/voice_rows, ui/cursors, ui/header, ui/flash, ui/text, ui/field_list, ui/keys, ui/alt, ui/detent, ui/menu_watch and ui/zones (113).
  - Then pages `:119-128`, arc `:140-149`, and grid core and faders, layouts 256, 128h, 128v and 64 at `:153-158`.
  - **The sequencer is last** (`:159`).
  - The line format is `S.lib.<name> = include("lib/<path>")(S)`.
- `test/unit/structure_test.lua`:
  - `:44-58` checks the includes (only strata.lua, once, by `lib/` paths). There is no include-order list.
  - `MODULE_HOMES` (`:205-256`) lists **global functions only**: a module with no globals needs no entry.
  - `CLEANUP_STEPS` `:623-632` and `start_steps()` `:796-853` are as in (6).
  - `:582` is the locals probe.
- **Not found**: a test listing every module. The AGENTS.md module table row is one per module or group (not tested beyond paths).

---

## 1e. Conditions, directions, fill, the chain's chance

### (1) `lib/sequencer.lua`

lua.md §1-§2 cover `ATTR_CHECKS` (`:187-196`), `take_position` (`:1042-1057`), `begin_voice_step` (`:1062-1090`), `skip_due_ticks` (`:1145-1152`), `take_tick` (`:1131-1139`), `voice_clock` (`:1167-1197`), `restart_voice` (`:1201-1209`) and the chain. Additions:

- **The per-voice state** (`play.voices[v]`, comment `:95-122`):
  - `{anchor, tick, beat, due, position, pass_length}`;
  - plus the wait's `{last_sync, generation, sync_time, sync_beat, sync_beat_seconds, stale, waiting, retired}`.
  - Reset sites: `end_clocks` `:1235-1246` (`{anchor = 0, tick = 0, beat = 0, position = 1, pass_length = PATTERN_LENGTH}`), `voice_clock` `:1169-1171`, `take_tick` `:1135-1136`, and `restart_voice` `:1206` (`play.voices[voice_idx] = {}`).
  - Module locals: `overrides, last_played, gate_sent, chords` (`:125`), `chain = {current, next_beat}` (`:127`), `stepping` (`:519`).
- **Functions** (all `local` unless `M.`):
  - `apply_step(voice_idx, event)` `:568-611`;
  - `end_overrides(voice_idx)` `:316-322`, `end_all_overrides()` `:324-326`;
  - `chain_slots()` `:985-991`, `next_chain_scene(current)` `:995-1005`, `load_chain_scene(slot)` `:1009-1021`, `chain_link()` `:1023-1026`, `at_beat(beat)` `:1030-1035`;
  - `chain_switched(on)` `:1389-1392` (the action of `seq_chain`);
  - `M.add_params()` `:1397-1413`, `play_chord` `:613-622`, `voices_play` `:631-649`, `hit_event` `:751-764`.
  - The keys a link carries are `{"seq_length", "seq_division"}`, at `:1017` inside `load_chain_scene`.
- **`M.add_params`** adds the group `params:add_group("strata_seq", "sequencer", SEQ.group_params + S.lib.quantize.PARAM_COUNT)` with `SEQ.group_params = 6` (`:48`). New params in this group (the fill, three chain chances) raise `group_params`.
- **The `seq` record** (`:1418-1459`, registered `:1459`): `count = 6`. Its `add` calls `S.lib.params_setup.add_voice_extra(voice_idx, record, key, param)` for `seq_length` (with its action), `seq_division` (option, `SEQ.division_names`), `seq_gate`, `seq_gate_length`, `seq_gate_release` and `seq_swing`. The rest of the record:
  ```lua
  grain_keys = {seq_gate = {name = "seqGate", value = function(option) return option - 1 end},
    seq_gate_release = "gateRelease"},
  sync = function(voice_idx) ... end,
  scene_defaults = {seq_length = PATTERN_LENGTH, seq_division = SEQ.default_division, seq_gate = 1,
    seq_gate_length = SEQ.gate_length_default, seq_gate_release = SEQ.gate_release_default, seq_swing = SEQ.swing[1]},
  discrete = {seq_length = {1, PATTERN_LENGTH}, seq_division = {1, #SEQ.division_names},
    seq_gate = {1, #SEQ.gate_options}, seq_swing = {SEQ.swing[1], SEQ.swing[2]}},
  scene_ranges = {...}, fader = false,
  ```
  Each new per-voice key needs a row in `docs/user/params.md`'s "Per-Voice Sections" table with its range and default (`docs_test.lua:1693-1834` checks every per-voice param outside the synthesis ones).
- The draws: the probability uses the global `math.random` (`:1072`). The seeded tests: `sequencer_test.lua:324` (`math.randomseed(7)`), `:630` (seed 1). Also `randomize_pattern` `:1294-1311`.

### (2) `lib/pages/seq.lua`

- **`EDIT_ROWS`** `:69-95`. Three kinds:
  ```lua
  {row = "length", label = "length", voice_param = "seq_length", format = "%d"},   -- a voice param (id v<i>_<voice_param>)
  {row = "prob", label = "prob", attr = "prob"},                                   -- a step attribute
  {row = "chain", label = "chain", param_id = "seq_chain", binary = true},        -- a global param, binary
  ```
  Also `{section = "voice"|"step"|"chain"}` labels, the special rows `euclid` and `clear`, the chord row `{..., chord = true}` and `quantize` (`param_id = "quantize_actions"`).
  - Sections: `voice` `:70-78`, `step` `:79-88` (bookmark shown only while `M.has_bookmarks`, filtered at `edit_rows` `:398`), `chain` `:89-94`.
  - `SEQ_EDIT.first_key = "length"`, `editor_first_key = "level"` (`:58-60`). Anchors: `views = {page = {anchor = {row = "length", index = 2}}, editor = {anchor = {row = "level", index = 2}}}` (`:403-406`). Rows put above `length` or `level` move those indices.
- **How a row reads and turns**:
  - `edit_rows(voice_idx, step)` `:374-401` resolves `param_id` (`spec.param_id` or `v<i>_<voice_param>`);
  - `row_text(voice_idx, step, row)` `:457-483` (binary "on/off"; `%d`/`%d%%`; `spec.format`; else `params:string`; then the attribute formats);
  - `turn_row(view, voice_idx, step, row, d)` `:544-573` (binary: `set_binary_param(id, d > 0 and 1 or 0)`; param: `enc_param_delta(3, id, d)`; attr: `M.turn_step`);
  - `edit_enc` `:575-584`;
  - **K3**: `edit_k3(view)` `:586-596` toggles the step (the clear row clears). It has **no per-row K3 dispatch**, so a `fill` row latched by K3 needs a branch here;
  - `reset_row` `:600-624`, `row_resets` `:629-634`, `edit_hints` `:646-655` ("K2:back K3:step E3:<label>").
- **`M.turn_step(voice_idx, step, key, d, opts)`** `:332-369`: the branches are `level`, `prob`, `ratchet`, `notes`, `bookmark` and the locks (`lock_param_name`). Any other key returns false.
- **The step editor**:
  - `editor_enc` `:787-794`, `editor_key(n, z)` `:799-822`, `editor_k2_text` `:827-833`, `editor_animates` `:837-839`;
  - `editor_owner` `:850-860` (`M.step_editor_owner`);
  - `M.open_step_editor(voice_idx, step, port)` `:868-875`, `M.close_step_editor(port)` `:879-884`, `M.step_editor()` `:887-890`, `M.step_editor_replacing()` `:896-898`;
  - the invariant "step editor" `:901-907`.
- **`layout_states`** `:981-1072`:
  - `show_cursor` `:912-917`, `widest_values` `:921-946`, `edit_state` `:949-960`;
  - `edit_windows(note_rows, bookmarks)` `:968-971`: `#EDIT_ROWS - 1 + note_rows - (bookmarks and 0 or 1)` windows of 5. A row shown conditionally (`slice`) needs the same correction as bookmark.
  - The record is at `:1075-1080` (with `header_status = seq_header_status`, `:763-765`).
- **`lib/arc/seq.lua`**: `ARC_SEQ` `:26-34`:
  ```lua
  editor_rings = {"pos", "pitch", "size", "prob"},
  editor_alt_rings = {"ratchet", "notes", "bookmark", "level"},
  editor_ticks = 20, editor_set_level = 15, editor_off_level = 4,
  ```
  `editor_delta(n, delta)` `:117-135`.

### (3) Grids, row 8

- **256**:
  - `grid_key_256(port, x, y, z)` `:278`. The positions page excludes rows 8 and 16 (`:280`). Page 1's modulation rows `:291-296` and page 3's recorder `:298-302` take releases. Then `:303` `if z == 0 then return end  -- presses only`.
  - Row 8 column 12 → page 5 (`:304-307`); columns 13-16 → pages (`:309-313`). Every page then reaches `grid_key_256_transport(x)` at `:343` (scenes), `:366` (sources) and `:374` (others, positions included).
  - The transport key:
    ```lua
    function grid_key_256_transport(x)
      if x <= 4 then
        pattern_toggle()
      elseif LAYOUT_256.tempo_steps[x] then
        params:delta("tempo", LAYOUT_256.tempo_steps[x])
        header_flash(string.format("tempo %d", util.round(S.lib.params_setup.clock_tempo_now())))
      end
    end
    ```
    (`:403-415`; `tempo_steps = {[5] = -10, [6] = -1, [7] = 1, [8] = 10}` `:31`; `positions_key_column = 12` `:45`.)
  - The redraw:
    ```lua
    function grid_redraw_256_transport(port, grid_device)
      for x = 1, 4 do
        grid_device:led(x, 8, grid_core.play_level())
      end
      for x in pairs(LAYOUT_256.tempo_steps) do
        local held = grid_core.held(port, x, 8) ~= nil
        grid_device:led(x, 8, held and LAYOUT_256.tempo_held_level or LAYOUT_256.tempo_level)
      end
      grid_redraw_256_page_row(port, grid_device)
    end
    ```
    (`:583-596`; called at `:472, :500, :510, :522`.) The tempo keys show the pattern for a held light: `grid_core.held`.
  - Tests: `grid_layout_256_test.lua:461` (columns 1-4 play) and `:948-960` (row 8 on page 5).
- **128h**:
  - `grid_key_128h` `:194-234`. Releases: `:199-213`, and only for `y ~= LAYOUT_128H.control_row` (positions, recorders, strip keys). Then `if y == LAYOUT_128H.control_row then control_row_key(port, x) return end` (`:214-217`).
  - `LAYOUT_128H.play_last_column = 4` (`:21`), used by:
    ```lua
    local function control_row_key(port, x)
      local page_offset = x - LAYOUT_128H.page_first_column + 1
      local voice_offset = x - LAYOUT_128H.voice_first_column + 1
      if x <= LAYOUT_128H.play_last_column then
        pattern_toggle()
      elseif page_offset == PAGES.sources and grid_core.page(port) == PAGES.sources then
      ...
    ```
    (`:175-191`) and by `redraw_control_row` (`:325-344`: `for x = 1, LAYOUT_128H.play_last_column do grid_device:led(x, y, grid_core.play_level()) end`).
  - Test: `test/unit/grid_layout_128h_test.lua:88-104` presses column 4 to start.
- **`S.lib.grid_core.held(port, x, y)`** (`lib/grid/core.lua:134-136`) returns `S.grid_held[port][x][y]`, the press time, or nil. The flow:
  - `handle_key` (`:825-835`): a press runs `press_key` (`:259-266`, sets held) and then `layout.key(port, x, y, 1)`. A release runs `cancel_hold` and then `layout.key(port, x, y, 0)` unless consumed, then `release_step_key`.
  - `grid_key` (`:844-860`) then always calls `release_key` (`:268-273`, clears held), and repaints once per key (`grid_redraw()` is suppressed during the key).
  - Roles for a key that acts on release: `M.press_as(port, x, y, role)` `:234-237` and `M.pressed_as` `:241-243`. They exist so a release acts only for the key pressed in that role (on the page it went down on).

### (4) `lib/io/actions.lua`

- **No registry.** The actions are plain fields of `S.lib.io_actions` (131 lines): `M.recall_scene(n)` `:45`, `M.next_scene()` `:55`, `M.run_voice(voice, mode)` `:64`, `M.retrigger(voice, velocity)` `:73`, `M.freeze`/`M.mute = binary_action(...)` `:101-102`, `M.macro(m, value)` `:104`, `M.patterns(mode)` `:113`, `M.record()` `:125`.
- The shape: return true when acted; else `ignored(action, why)` (`:14-17`) prints `strata: <action> ignored: <why>` and returns false. Mode 0/1/2 goes through `wanted(mode, now)` (`:37-42`); voice 0 is the selected voice (`resolve_voice` `:25-29`).
- Callers:
  - crow `TRIGGER_ACTIONS` (`lib/io/crow.lua:415-421`), named by `SPEC.actions = {"retrigger", "next scene", "freeze", "record", "patterns"}` (`:31`);
  - OSC `/strata/scene`, `/strata/patterns` and `VOICE_ACTIONS {run, retrigger}` (`lib/io/osc.lua:180-200`);
  - ii (`lib/io/ii.lua:351-373`);
  - midi_out (`:455`).
  - The remote surfaces (`lib/io/remote.lua`) do not call io_actions: a remote grid is a grid port, so grid keys reach it.
- Tests: `test/unit/io_actions_test.lua:33` (recall_scene), `:49` (next_scene), `:58` (run_voice), `:73` and `:96` (retrigger), `:123` (freeze, mute), `:135` (macro), `:146` (patterns), `:156` (record). Notes: `docs/notes/lua/io/actions.md`.

### (5) Header

- `lib/ui/header.lua`: `HEADER_Y = 8` (`:18`).
  - `draw_page_dots` `:23-29`, `draw_play_mark(x)` `:33-39`, `record_indicator` `:43-56`.
  - `draw_indicators` `:60-72`: `[M]` at `mutation_x` level 6, the play mark at `play_x`, REC/ARM at `rec_x` level 15.
  - `draw_header` `:77-108`: title; a flash at `flash_x`, cut to `flash_width`; else dots, then a `header_status` at `status_x` with the play mark at `status_play_x`, or the indicators; the scene right-aligned at `scene_right`.
- `HEADER` (`lib/constants.lua:104-106`): `dots_x = 32, dot_spacing = 4, dot_size = 2, dot_y = 4, mutation_x = 76, play_x = 90, play_y = 3, rec_x = 96, scene_right = 127, status_x = 79, status_play_x = 73, flash_x = 40, flash_width = 74, flash_seconds = 1.5`.
- Widths (from `test/norns_stubs.lua`'s `stubs.text_width`): `[M]` 12, `[F]` 10, REC 13, ARM 16, S16 13, SCENES 27, BUFFER 27.
- The free spans and the `[F]` ban are under Surprises 1 and 2.
- Tests pinning positions, in `test/unit/ui_header_test.lua`:
  - `:74-83` (every constant);
  - `:109` (`[M]` at x 76, REC at x 96);
  - `:163` (header_status replaces the indicators; play mark 73-76);
  - `:403` (ARM at x 96);
  - `:444` (ten dots from 32, the tenth at 68, clear of 73; S16 clears REC).
  - `test/unit/ui_layout_test.lua:231-233` reads `status_x` and `status_play_x` from a notes sentence.

### (6) Tests most likely to break on a direction or condition change

In `test/unit/sequencer_test.lua`:
- `:68` sounding_step;
- `:95` step_brightness;
- `:604` "each voice plays at its own division and wraps at its own length" (asserts steps 9, 5, 4 after two beats);
- `:623` "probability draws once per step" (seed 1; a 50 % step in 8-24 of 32 passes);
- `:1101` the chain;
- `:1136` "seq_division_reset puts every voice back at step 1";
- `:1199` the transport start at step 1;
- `:1566` swing;
- `:1632` "turning off a voice's only set step ends its lock and note at the next wrap";
- `:1969` and `:1973` (no two steps at one instant, 1/32);
- `:2088` and `:2157` (restart);
- `:2259` "a clock held two beats plays one step when it wakes";
- `:2286` "the beat set forward ... plays each late step once";
- `:2575` "a chord ends when ... the wrap passes it".

In `test/unit/pages_seq_test.lua`:
- `:211`, `:312`, `:333` and `:568` (the randomize, seeds at `:220, :267, :315, :571, :590, :1060, :1208`);
- `:603` "the edit view edits length, division and each step attribute";
- `:940` "every edit view row lays out with the cursor on it ...";
- `:1086` the hint rows.

### (7) A binary that is never stored

- Code examples: `params:set_save(id, false)` at `lib/gestures.lua:598` (a hidden toggle binary `gesture_<k>_play`) and `lib/io/keyed.lua:64`. No `momentary` binary exists in `lib/`.
- norns:
  - `ParamSet:set_save` (`~/src/norns/lua/core/paramset.lua:422-425`);
  - `ParamSet:write` skips `not param.save`, triggers and separators (`:513`);
  - `ParamSet:read` sets a binary unless its behavior is trigger (`:546-550`);
  - `Binary:delta` (`params/binary.lua:48-56`): momentary → `self:set(d)`, toggle flips on d ~= 0.
- The stub: `ParamSet:set_save` (`test/norns_stubs.lua:1485`), write filter `:1434`.
- Strata's PSET read never defaults a `save == false` param (`lib/params_setup.lua:203-204`; Surprise 5).
- Scenes store only `SCENE_GLOBAL_PARAMS`, registered scene fields and per-voice keys, so a plain group param is no scene field (lua.md §4).

---

## 1f. Scene chance

- **The sequencer** (`lib/scenes.lua`):
  - `first_scene_from(from, length)` `:906-912` (local);
  - `scene_sequencer_start()` `:914-1003` (global): it cancels the clock, sets `S.scene_sequencer_enabled = true`, `position = 1`, `recall_due = true`, then `grid_redraw()`.
  - The local `pass()` (`:926-980`):
    1. the guard (`:929-932`);
    2. `S.scene_sequencer_position = first_scene_from(S.scene_sequencer_position, length) or S.scene_sequencer_position` (`:937-938`);
    3. `recall_due = false` (`:943`);
    4. recall in `xpcall` (`:944-956`), or the empty-sequence print and hold (`:957-960`);
    5. `clock.sleep(math.max(params:get("scene_duration"), transition_time))` and `wait_for_scene_transition()` (`:965-967`);
    6. the advance `position + 1`, wrapped at the current length (`:971-974`);
    7. `recall_due = true`, `request_redraw()`, `grid_redraw()`.
  - The clock body: `clock.sleep(0)`, then a loop of `xpcall(pass, ...)`. On error it clears the clock id, runs `set_binary_param("scene_sequencer_enabled", 0)`, then `scene_sequencer_stop()` and `error` (`:982-1002`).
  - `scene_sequencer_stop()` `:1005-1014`.
  - State: `S.scene_sequencer_position`, `S.scene_sequencer_enabled`, `S.scene_sequencer_recall_due` and `S.scene_sequencer_clock` (`:39-45`).
  - `M.sequencer_next_slot()` `:1474-1481` (quoted in lua.md §4).
  - The **invariant "scene sequencer"** `:1487-1499`: `recall_due` only while enabled; enabled exactly while a clock id is held; the clock's coroutine not dead.
  - Other readers of the position: `lib/pages/scenes.lua:136` (the `>` mark) and `:379` (a layout state sets it to 12).
- **The params** (`lib/params_setup.lua`, inside `register_params("scenes", ...)` `:413-487`, under the separator `strata_scenes`, **not a group**):
  ```lua
  params:add{
    type = "control",
    id = "scene_duration",
    name = "scene duration",
    controlspec = controlspec.new(4, 120, "lin", 1, 16, "s"),
    action = function(x)
      -- Time before advancing to next scene
    end
  }
  ```
  `scene_sequencer_enabled` `:417-430`, `scene_transition_time` `:432-440`, `scene_duration` `:442-450`, `scene_sequence_length` `:452-463`; then the triggers `save_scenes` and `load_scenes` `:465-486`.
- **`SCENES_FIELDS`**:
  - `lib/constants.lua:108-111` (comment "stops NUM_SCENES + 1 .. NUM_SCENES + #SCENES_FIELDS (17-20; lib/ui/cursors.lua)"); exported `:335`.
  - Read in `lib/pages/scenes.lua:23`; `field_text(field_id)` `:73-82` (one branch per field); `redraw_scenes` `:156-169`, which draws them as a 2×2 block from `SCENES_PAGE.fields_y = {48, 55}` and `column_x = {0, 64}` (`:26-40`); `scenes_enc` `:207-220` (the binary branch for `scene_sequencer_enabled`, else `enc_param_delta(n, SCENES_FIELDS[cursor - NUM_SCENES], d)`); `scenes_hints` `:173-180` ("E2:move E3:edit" on a field); `scenes_key` `:247-255` (returns on a field); the `layout_states` loop `:356` (one state per stop).
  - `lib/ui/cursors.lua:16, :40-44` (`last_stop("scene") = NUM_SCENES + #SCENES_FIELDS`).
  - `lib/arc/scenes.lua:15, :41` (ring 1's position over the stops).
- **The grids**: `M.scene_recall_level(slot)` `lib/grid/core.lua:467-472`, with `SCENE_LEVELS = {saved = 8, empty = 2, next = 10, current = 15, ...}` `:464-465`:
  ```lua
  if S.lib.scenes.shows_current(slot) then return SCENE_LEVELS.current end
  if slot == S.lib.scenes.sequencer_next_slot() then return SCENE_LEVELS.next end
  ```
- **Tests pinning the recall order and the next-slot light**:
  - `test/unit/scenes_test.lua`: `:465`, `:480` and `:492` (holds and transitions); `:915` (a shortened sequence wraps to scene 1); `:930` and `:960` (`sequencer_next_slot`, #303); `:983` and `:997` (one clock); `:1024` (a PSET read starts it); `:1950` (skips an empty slot, #513, with `next_slot` asserts at `:1968-1983`); `:1990` and `:2022` (the error stop, #329); `:2175` (a restart recalls scene 1 first, #411); `:2190`; `:2967` (up to 16 scenes, `:2977` "scene 16 is next").
  - `test/unit/grid_core_test.lua:1129`, `:1158` and `:1198`.
  - `test/unit/grid_layout_256_test.lua:205`.
  - `test/unit/ui_cursors_test.lua:291-302` pins `SCENES_FIELDS` exactly ("scene_transition_time scene_sequencer_enabled scene_sequence_length scene_duration", 20 stops, 17 the first field).
  - `test/unit/pages_scenes_test.lua:213` and `test/unit/arc_pages_test.lua:961, :990` use `#SCENES_FIELDS`.

---

## 1g. Random sequences

- **(1) The step hooks**:
  - `M.on_step(fn)` `lib/lfos.lua:373-376` appends to `step_hooks`, which `step_all` (`:671-689`) calls after the six LFOs and the direct destinations. Each runs as `S.lib.ui_frame.contained_call(hook_errors, index, "LFO step hook", fn)`, with no arguments, then the round robin `drain()`.
  - The registration order, and so the call order, is in Surprise 10. The source the matrix reads is `S.lib.mod_sources.normalized(key)` (`lib/mod_sources.lua:87-95`), which calls `record.value()` at the time the matrix's step runs.
- **The gestures as a model**:
  - Sources `gesture1-4`: `lib/gestures.lua:779-801` (with `row = {enc, press, alt_press, hints}`).
  - A discrete scene field per recorder: `S.register_scene_field({id = param_id(k, "play"), default = 0, discrete = true})` (`:605`).
  - Its files: `files = S.lib.side_files.new({...})` (`:727-751`), with `name, contents, version = GESTURES.data_version, key = "recorders", live_file, side_suffix, backup_suffix, save_delay, clock_field = "gesture_save_clock", capture, validate (returns nil or a problem string), load(data)`. The constants are `GESTURES` `:46-50` (`live_file = "gestures.data"`, `side_suffix = ".gestures.data"`, `backup_suffix = ".bak"`).
  - Registrations: `S.register_pset_hook(files.pset_hook(stop_all, stored_changed))` `:756`, `S.register_start(START_ORDER.gestures_load, files.load_live)` `:761`, `S.register_cleanup(CLEANUP_ORDER.gestures_save, files.save_now)` `:762`.
  - `S.lib.side_files` API (`lib/side_files.lua`): `M.new(spec)` `:47`, returning `files.write(path)`, `files.read(path, silent)`, `files.load_live()`, `files.save_live()` (needs `save_delay`), `files.save_now()` and `files.pset_hook(before_read, after_read)` → `{name, write, read, delete}`. The required spec fields are at `:24-29` (Surprise 9). `pset_hooks` and `scene_blocks` close at init: register both in the constructor.
- **Params groups**:
  - `lib/gestures.lua:587-600`: `params:add_group("strata_gestures", "gestures", 2 * NUM_GESTURES)`, then the params.
  - The group is registered in `lib/params_setup.lua:638-645`:
    ```lua
    for _, group in ipairs({{"macros", "macros"}, {"morph", "morph"}, {"scatter", "scatter"}, {"matrix", "matrix"},
        {"input", "input_level"}, {"gestures", "gestures"}}) do
      local module_name = group[2]
      register_params(group[1], function() S.lib[module_name].add_params() end)
    end
    ```
    3.6's guarded loop (`if S.lib[module_name] then ...`) is at `:647-657`.
  - `register_params(name, add)` (`:162-175`) records each param for the PSET defaults (`pset.record_params`) and rounds number params.
  - The count must equal the params added. `docs/user/params.md`'s "The menu shows" sentence must name every group in menu order, in bold (`docs_test.lua:1693-1718`).
- **(2) A scene block registration in full** (`lib/macros.lua:723-733`):
  ```lua
  S.register_scene_block({
    key = "macros",
    default = function() return {} end,
    capture = sparse,
    validate = function(value) return block_problem(value) == nil end,
    apply = function(value)
      load_block(value)
      save_live()
    end,
    discrete = true,
  })
  ```
  The matrix's (`lib/matrix.lua:686-707`) adds `through_zero`. The fields are checked by `SCENE_BLOCK_FIELDS` (`lib/state.lua:364-365`, `M.register_scene_block` `:379-389`). How scenes treat a block:
  - `capture_scene` (`lib/scenes.lua:401`) stores `record.capture()` under `key` (`:411-413`);
  - `migrate_scene(scene, from_version)` (`:353`) fills a missing block with `record.default()` (`:366-368`), whatever the version, **before** validation;
  - `validate_scene` (`:1225`) calls `record.validate(data[key])` for each block (`:1261-1263`), and any failure fails the scene. At load, a failed slot sets the whole file aside (`:1149-1151`, lua.md §1). **So `validate` must accept `default()`'s value.**
  - The apply is discrete, as an entry `{kind = "block"}` (`:535-537`), applied with a copy (`:585-587`).
- **(3) The largest-file test**: `test/unit/matrix_test.lua:1353-1411` ("a scenes file of 16 scenes, each with 16 full macros, 16 routings and attributes on every step, loads").
  - It sets 16 macros × 8 targets, 16 routings (`set_routing(k, "macro" .. (17 - k), destinations[k])`, depth `-100 + k`), and on every voice and step `notes = {-14, -9, -5, -2, 0, 3, 7, 14}` plus `attrs = {prob = 37, ratchet = 4, pos = 0.123456789, pitch = 1.23456789, size = 0.123456789, bookmark = 4, gate = 7.123456789}` through `set_step_attr`.
  - It saves each slot (`S.lib.scenes.save(slot)`) and counts `-- Table: ` markers in the file:
    ```lua
    local tables = select(2, text:gsub("%-%- Table: ", ""))
    assert_true(tables <= S.lib.data_files.DATA_FILES.max_tables, ...)
    local largest = S.lib.data_files.DATA_FILES.largest_scenes_tables  -- the cap keeps 4 times it (data_files_test.lua)
    assert_equal(tables, largest, "the largest scenes file the reader's cap is sized for holds exactly its figure")
    ```
  - Then it reloads, validates every slot, checks the routings, notes and gates, and recalls slot 16.
  - Whatever tables the `sequences` block's `capture` writes at the defaults count here from the moment the block registers. If the block is captured full, the figure moves without the test setting anything.
  - `lib/data_files.lua:23-41`: `DATA_FILES = {max_bytes = 4 * 1024 * 1024, max_tables = 32768, largest_scenes_tables = 7394, backups = 9}`, with the comment at `:33-39`: "... test/unit/matrix_test.lua writes it and checks it holds no more; test/unit/data_files_test.lua checks max_tables keeps at least four times it. Raise it with a release that adds scene tables, and max_tables with it".
  - `test/unit/data_files_test.lua:182-187`: `SCENES_MARGIN = 4`, `max_tables >= 4 * largest`.
  - `docs/status.md:27` states the figure 7394 (a doc line to update).
- **(4) The beat without a coroutine**:
  - `lib/lfos.lua:603-615` `read_beats(step)`: `step.beats = clock.get_beats()` once a step, and `step.fell = beats_reading.last ~= nil and step.beats < beats_reading.last` (a transport start).
  - A clocked LFO's phase is `(beats / period_beats(n) + st.clocked_offset + offset) % 1` (`:641`), with `period_beats(n) = LFO.division_values[...] * LFO.beats_per_division` (`:275-277`); the public `M.phase(n)` is at `:313-322`.
  - That reading is private to `step_all`, so a hook calls `clock.get_beats()` itself.
  - `S.lib.params_setup.beat_seconds_now()` (`lib/params_setup.lua:120-123`) is what the LFOs read for seconds.
