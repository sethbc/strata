# Confluence Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring every capability Confluence promised into Strata (buffer and live-input sources, delay and filter, grain envelopes and triggered grains, global LFOs, MIDI, a paged screen UI with arc pages) so the Confluence repository can be deleted.

**Architecture:** Strata stays a two-file norns script (`strata.lua` + `lib/Engine_Strata.sc`) with an off-device harness in `test/`. Each voice keeps its synth, grain, and mod synth trio; a per-voice `source` swaps the grain synth between the voice bus, a stereo buffer pair, or the live input. New master effects are separate synths at the tail of the engine group. LFOs are norns' `lfo` library driving a single `send_param_to_engine` path that the params system also uses. The screen becomes five pages selected by E1.

**Tech Stack:** Lua 5.3 (norns matron), SuperCollider (scsynth/sclang via CroneEngine), norns libs `lfo`, `musicutil`, `fileselect`, `midi`; test harness `test/run.lua` + `test/norns_stubs.lua`, `test/sync_check.lua`, `test/run_engine_check.sh` + `test/engine_check.scd`.

**Spec:** `docs/superpowers/specs/2026-11-03-confluence-features-design.md` (the approved design; the plan argues from it, executors read both).

## Global Constraints

- Branch off `review-fixes` (HEAD after its task review). `main` untouched; no push.
- Lua/SC sync: every `engine.X(...)` has a matching `this.addCommand(\X, "sig")`; argument counts and types match; voice index `voice_idx - 1` at every call site; mod source Lua 0/1..7 → SC -1/0..6. `test/sync_check.lua` must pass after every task.
- Named constants only: `NUM_VOICES` (7), `NUM_SCENES` (8), `PATTERN_LENGTH` (16), `NUM_MOD_SLOTS` (3); new `NUM_BUFFERS = 8`, `BUFFER_SECONDS = 16`, `NUM_LFOS = 3`, `NUM_UI_PAGES = 5`. SC mirrors: `numVoices = 7`, `numBuffers = 8`, `bufferSeconds = 16`.
- All state changes go through `params:set`; the `voices` table is the source of truth; engine writes only through param actions, `sync_voice_to_engine`, or `send_param_to_engine`.
- Descriptive names. `clock.sleep` only inside `clock.run`. Param IDs unique and not colliding with norns built-ins (`reverb`, `rev_*`, `clock_tempo`, `lfo_*` is reserved for the norns LFO library's own params: Strata's LFO params are `strata_lfo{n}_*`).
- Screen 128×64, no overlap at any value; every page has a hint row at y 62.
- Grid: 7 voice rows and row 8/row 16 meanings never change on any layout. Arc redraw stays nil-safe.
- Scene format version becomes 2 with migration of version-1 files; no scene file becomes unloadable.
- No new synth nodes per event. Source switching replaces a voice's grain synth.
- Buffers: eight slots, each a left/right pair of mono buffers, 16 s each. Disk writes only on recording completion (scratch take) or explicit save.
- LFOs modulate around the stored param value and never write it; rate ceiling is the library's (10 Hz free).
- Every task updates CLAUDE.md/README.md for what it changes; Task 12 adds the CHANGELOG 3.0 entry and reconciles docs.
- Tests: `lua test/run.lua`, `luajit test/run.lua`, `lua test/sync_check.lua`, `test/run_engine_check.sh` all pass before each commit. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. A voice switched to a buffer source while a scene transition is running: `scene_transition_targets` must not interpolate `source`, `grain_mode`, or `grain_env`; pinned in Task 7 (`transition skips discrete voice fields`).
2. Loading a version-1 scene file after the new fields exist: recall must not call `params:set` with nil; pinned in Task 3 (`v1 scene file migrates`).
3. A MIDI note for a voice whose source is `input`: no pitch to set; retrigger still fires, nothing errors; pinned in Task 11.
4. Recording into a buffer that a running voice is reading: no node creation and no error; the poll updates seconds afterwards; pinned in Task 6 (engine check) and Task 9 (Lua state).
5. An LFO whose destination voice's `main` resolves to a param that is off-screen when the voice becomes buffer-sourced mid-run: the old destination is restored, the new one modulated; pinned in Task 10 (`main destination follows source`).

---

### Task 1: Harness support for the new norns APIs

**Files:**
- Modify: `test/norns_stubs.lua` (`make_params`, `stubs.install`)
- Create: `test/stub_lfo.lua`, `test/stub_midi.lua`
- Test: `test/run.lua`

**Interfaces:**
- Consumes: existing `stubs.install(options)` returning `context` with `params`, `clock`, `grid`, `arc`, `screen`, `engine_calls`, `calls_named`.
- Produces:
  - `params` stub gains `add_option(id, name, options, default)`, `add_group(id, name, n)`, `add_trigger(id, name)`, `add_binary(id, name, behavior, default)`, `add_file(id, name, path)`, `set_action(id, fn)`, `hide(id)`, `show(id)`, and `params:set` accepting a string for `file` and `option`-by-index numbers; `params:string(id)` returns the option label for option params; `param.count` set on option params.
  - `context.midi` with `midi.connect(n)` returning a vport `{ event = nil, name = "stub midi", device = {...} }`, `midi.add`/`midi.remove` hooks, `midi.devices`, `midi.to_msg(data)` (same output table shape as norns: `type`, `note`, `vel`, `ch`, `cc`, `val`), and test helper `midi.send(port, msg)` that builds the data bytes and calls the vport's `event`.
  - `context.lfo`: `package.preload["lfo"]` returns a stub `LFO` with `new(shape, min, max, depth, mode, period, action, phase, baseline)`, `:add{...}`, `:add_params(id, sep, group)` (adds `lfo_<id>` option {off,on}, `lfo_depth_<id>` control 0..1, `lfo_shape_<id>` option {sine,tri,square,random,up,down}, `lfo_mode_<id>` option {clocked,free}, `lfo_free_<id>` control 0.1..1024, `lfo_clocked_<id>` option of the library's beat strings), `:start()`, `:stop()`, `:set(var, v)`, `:get(var)`, and a test helper `context.lfo.tick(lfo_instance, raw)` that computes `scaled = linlin(0, 1, -depth, depth, raw)` for `min = -1, max = 1, baseline = 'center'` and calls `action(scaled, raw)` only when enabled and depth > 0 (mirrors `process_lfo`).
  - `context.fileselect` with `fileselect.enter(folder, callback, filter)` recording `fileselect.last = {folder=, callback=, filter=}`.
  - `package.preload["musicutil"]` returns `{ note_num_to_freq = function(n) return 440 * 2 ^ ((n - 69) / 12) end }` (replaces the current error stub).
  - `_path.audio = options.data_dir .. "audio/"` (created by `install`; `load_strata` exposes it as `context.audio_dir` so a reload with the same `data_subdir` sees the same files), `util.file_exists`, `util.make_dir`, `util.scandir`, `util.os_capture` stubs; `_G.fileselect`, `_G.midi` globals.
  - `context.polls`: `poll.set(name, callback)` stub returning `{ start = fn, stop = fn, callback = callback }` and helper `context.polls.fire(name, value)`.

- [ ] **Step 1: Write the failing tests**

```lua
test("stub params support option, group, trigger, binary, file and set_action", function()
  load_strata()
  params:add_option("stub_opt", "opt", {"a", "b", "c"}, 2)
  assert_equal(params:get("stub_opt"), 2); assert_equal(params:string("stub_opt"), "b")
  assert_equal(params:lookup_param("stub_opt").count, 3)
  local fired
  params:set_action("stub_opt", function(v) fired = v end)
  params:set("stub_opt", 3); assert_equal(fired, 3)
  params:add_file("stub_file", "file", ""); params:set("stub_file", "/tmp/x.wav")
  assert_equal(params:get("stub_file"), "/tmp/x.wav")
  params:add_trigger("stub_trig", "trig"); params:add_binary("stub_bin", "bin", "toggle", 0)
  params:add_group("stub_group", "group", 2); params:hide("stub_opt"); params:show("stub_opt")
end)

test("stub lfo tick calls the action with scaled and raw", function()
  local context = load_strata()
  local LFO = require("lfo")
  local got
  local instance = LFO:add{ shape = "sine", min = -1, max = 1, depth = 0.5, mode = "free", period = 1,
    baseline = "center", action = function(scaled, raw) got = { scaled, raw } end }
  instance:add_params("stubtest", nil, "stub")
  context.lfo.tick(instance, 1.0)
  assert_equal(got, nil, "disabled LFO never fires")
  params:set("lfo_stubtest", 2)
  context.lfo.tick(instance, 1.0); assert_near(got[1], 0.5, 1e-9); assert_near(got[2], 1.0, 1e-9)
  params:set("lfo_depth_stubtest", 0); got = nil
  context.lfo.tick(instance, 1.0); assert_equal(got, nil, "depth 0 never fires")
end)

test("stub midi delivers note_on, cc and pitchbend messages", function()
  local context = load_strata()
  local vport = midi.connect(1)
  local seen = {}
  vport.event = function(data) table.insert(seen, midi.to_msg(data)) end
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 3 })
  context.midi.send(1, { type = "cc", cc = 1, val = 64, ch = 1 })
  context.midi.send(1, { type = "pitchbend", val = 8192 + 4096, ch = 1 })
  assert_equal(seen[1].type, "note_on"); assert_equal(seen[1].note, 60); assert_equal(seen[1].ch, 3)
  assert_equal(seen[2].cc, 1); assert_equal(seen[3].type, "pitchbend"); assert_equal(seen[3].val, 8192 + 4096)
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `lua test/run.lua`
Expected: the three new tests FAIL (`add_option` nil, `require("lfo")` error, `midi` nil).

- [ ] **Step 3: Implement the stubs** in `test/norns_stubs.lua` (params additions inside `make_params`; `midi`, `fileselect`, `musicutil`, `poll`, `_path.audio`, `util` file helpers inside `stubs.install`) and the two new files `test/stub_lfo.lua`, `test/stub_midi.lua` required from `stubs.install`. `midi.to_msg` mirrors `lua/core/midi.lua` byte layout (`0x90 + ch - 1`, 14-bit pitchbend `val = lsb + msb * 128`).

- [ ] **Step 4: Run to verify they pass**

Run: `lua test/run.lua && luajit test/run.lua`
Expected: all tests PASS, including the 18 existing ones.

- [ ] **Step 5: Commit**

```bash
git add test/norns_stubs.lua test/stub_lfo.lua test/stub_midi.lua test/run.lua
git commit -m "test: stub norns option/file params, lfo, midi, fileselect, musicutil, polls"
```

---

### Task 2: Paged screen UI and arc paging scaffold

**Files:**
- Modify: `strata.lua` (`enc`, `key`, `redraw`, `arc_delta`, `arc_redraw`, globals near `selected_voice`)
- Modify: `README.md` (Controls section), `CLAUDE.md` (UI principles: pages)
- Test: `test/run.lua`

**Interfaces:**
- Consumes: existing `redraw`, `enc`, `key`, `arc_delta`, `arc_redraw`, `voices`, `selected_voice`, `master_density`.
- Produces:
  - `local NUM_UI_PAGES = 5`, `local UI_PAGES = {"MAIN", "FX", "LFO", "BUFFER", "SETUP"}`, `local ui_page = 1`.
  - `function draw_header()` (page name at x 0 y 8, `dens:` at x 36 level 4, `[M]` at x 98, `S<n>` right-aligned at 127; identical on every page).
  - `function draw_hints(text)` (level 4, x 0, y 62).
  - `function redraw_main()`, `function redraw_setup()`; `redraw()` becomes `screen.clear(); draw_header(); PAGE_DRAW[ui_page](); screen.update()` with `PAGE_DRAW = {redraw_main, redraw_fx, redraw_lfo, redraw_buffer, redraw_setup}` where the three not yet built are `function() draw_hints("") end` placeholders replaced in Tasks 3, 10, 8.
  - `function page_enc(n, d)` and `function page_key(n)` tables `PAGE_ENC[ui_page]`, `PAGE_KEY[ui_page]`; `enc(1, d)` sets `ui_page = util.clamp(ui_page + d, 1, NUM_UI_PAGES)`; `enc(2|3, d)` → `PAGE_ENC[ui_page](n, d)`; `key(n, 1)` → `PAGE_KEY[ui_page](n)`.
  - `function main_param_id(voice_idx)` returning the E3 param id for a voice (`v<i>_freq` for resonator, `_index` fm, `_fold` folder, `_drift` sub, `_width` pulse, `_decay` karplus, `_ratio` ring) and `function main_param_label(voice_idx)`; `enc`, `redraw_main`, `arc_delta`, `arc_redraw` use them instead of the four `if v.name ==` chains. (Task 7 makes it source-aware.)
  - `ARC_PAGE_DELTA[ui_page](ring, delta)` / `ARC_PAGE_REDRAW[ui_page](arc_device)`; MAIN keeps the current four-ring mapping; SETUP draws nothing; FX/LFO/BUFFER placeholders draw nothing until their tasks.
  - `redraw_setup()`: lines "grid: <n> connected (<sizes>)", "arc: connected|none", "scenes: <k>/8 saved", "midi: ..." (Task 11 fills); K3 = `save_scenes_to_disk()`.
  - SCENE indicator and mutation indicator unchanged.

- [ ] **Step 1: Write the failing tests**

```lua
test("E1 selects pages; MAIN keeps its encoder and key mappings", function()
  local context = load_strata(); context.clock.advance()
  assert_equal(local_value("ui_page"), 1)
  local density = params:get("master_density")
  enc(1, 1); assert_equal(local_value("ui_page"), 2)
  assert_equal(params:get("master_density"), density, "E1 no longer changes density")
  enc(1, 10); assert_equal(local_value("ui_page"), 5)
  enc(1, -10); assert_equal(local_value("ui_page"), 1)
  enc(2, 1); assert_equal(local_value("selected_voice"), 2)
  local before = params:get(main_param_id(2)); enc(3, 1)
  assert_true(params:get(main_param_id(2)) ~= before, "E3 moves the main param on MAIN")
  key(3, 1); assert_true(local_value("frozen")[2], "K3 freezes a running voice on MAIN")
end)

test("every page draws within 128x64 with a header and hint row", function()
  local context = load_strata(); context.clock.advance()
  for page = 1, 5 do
    enc(1, page - local_value("ui_page")); redraw()
    local texts = context.screen.texts
    assert_equal(texts[1].text, ({"MAIN","FX","LFO","BUFFER","SETUP"})[page], "page title")
    for _, entry in ipairs(texts) do
      local left, right = text_span(entry)   -- existing helper in run.lua
      assert_true(left >= 0 and right <= 128 and entry.y <= 64, "text inside screen on page " .. page)
    end
  end
end)

test("arc rings follow the page; MAIN mapping unchanged", function()
  local context = load_strata(); context.clock.advance()
  local device = context.arc.plug(1)
  context.arc.turn(1, 1, 20); assert_true(params:get("master_density") > 1.0, "ring 1 density on MAIN")
  enc(1, 4); arc_redraw()
  assert_equal(next(device.segments), nil, "SETUP page draws no rings")
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `lua test/run.lua`
Expected: FAIL (`ui_page` not found, `main_param_id` nil).

- [ ] **Step 3: Implement** the globals, `draw_header`, `draw_hints`, `redraw_main` (current `redraw` body minus header), `redraw_setup`, page dispatch tables, `main_param_id`/`main_param_label`, and the arc page tables in `strata.lua`. Update README Controls (E1 = page, master density on arc ring 1/FX page/params) and the CLAUDE.md UI section (pages, `draw_header`, hint row).

- [ ] **Step 4: Run to verify they pass**

Run: `lua test/run.lua && luajit test/run.lua && lua test/sync_check.lua`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add strata.lua test/run.lua README.md CLAUDE.md
git commit -m "feat: paged screen UI (MAIN/FX/LFO/BUFFER/SETUP) with arc pages and main-param helpers"
```

---

### Task 3: Effects chain (filter, delay, limiter), FX page, scene v2 migration

**Files:**
- Modify: `lib/Engine_Strata.sc` (`alloc`: buses, `\strataFilter`, `\strataDelay`, master `Limiter`, commands, `free`)
- Modify: `strata.lua` (params group `strata_fx`, `SCENE_GLOBAL_PARAMS`, `SCENE_DATA_VERSION`, `load_scenes_from_disk`, `validate_scene`, `redraw_fx`, `PAGE_ENC[2]`, `PAGE_KEY[2]`, arc FX page, grid page 4 FX faders)
- Modify: `test/engine_check.scd`, `test/run.lua`, `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: Task 2's page tables; existing `synths` dictionary, `setSynth`, `mainBus`, `reverbBus`, `grid_redraw_faders`-style rendering (`fader_position`, `param_range`), `SCENE_GLOBAL_PARAMS`, `empty_scene`.
- Produces:
  - SC: buses `filterBus`, `delayBus`; SynthDefs `\strataFilter` (`in, out, freq=5000, res=0.5, filterType=0, mix=0`), `\strataDelay` (`in, out, time=0.375, feedback=0.4, mix=0`; `LocalIn/LocalOut` feedback around `DelayC` max 2 s, `time.lag(0.1)`); chain `mainBus → filter → filterBus → delay → delayBus → reverb → reverbBus → master`, all `\addToTail` of `context.xg` in that order; `\strataMaster` gains `Limiter.ar(sig, 0.95)` after the tanh stage. Commands `setFilter "ffif"` (freq, res, type, mix) and `setDelay "fff"` (time, feedback, mix).
  - Lua params (group `strata_fx`, replacing the `strata_reverb` separator; ids of reverb and drift unchanged): `filter_type` option {lowpass, highpass, bandpass} default 1; `filter_freq` controlspec 20..20000 exp default 5000 "Hz"; `filter_res` 0..1 default 0.5; `filter_mix` 0..1 default 0; `delay_time` 0.01..2 exp default 0.375 "s"; `delay_feedback` 0..0.95 default 0.4; `delay_mix` 0..1 default 0. Actions call `engine.setFilter(params:get("filter_freq"), params:get("filter_res"), params:get("filter_type") - 1, params:get("filter_mix"))` / `engine.setDelay(...)`.
  - `SCENE_GLOBAL_PARAMS` entries gain `default` (the param default) and the new ids (`filter_type` continuous=false, others continuous=true).
  - `SCENE_DATA_VERSION = 2`; `function migrate_scene(scene, from_version)` fills missing globals from `default`, missing `voices[i]` fields from `VOICE_SCENE_DEFAULTS` (a table later tasks extend: Task 4 `grain.env`, Task 5 `grain.mode`, Task 7 `source`, `grain.buf_pos`, `grain.buf_rate`, `grain.buf_scan`), and missing LFO/MIDI blocks (Tasks 10/11 extend). `load_scenes_from_disk` accepts version 1 and 2, migrating 1 → 2 and printing `"migrated scenes file from version 1"`. `validate_scene` runs after migration.
  - `redraw_fx()`: scrolling list of rows `{label, param_id, format}` for master density, drift, filter type/freq/res/mix, delay time/feedback/mix, reverb mix/size/damp; `fx_row` local index; E2 selects row, E3 `params:delta`; K3 toggles `filter_mix` between 0 and `fx_filter_last_mix` (initial 1); hints `"K3:filter " .. (mix > 0 and "bypass" or "on")`.
  - Arc FX page: ring 1 `filter_freq` (delta/4), ring 2 `filter_res` (delta/100), ring 3 `delay_time` (delta/200), ring 4 `delay_mix` (delta/100); segments by each param's range.
  - Grid 256 page 4: `GRID_FX_FADER_IDS = {"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"}` on rows 3..7 using a generalised `grid_redraw_fader_row(grid_device, y, param_id)` and `set_param_from_column(param_id, x)` (extracted from `set_fader_param`/`grid_redraw_faders`); row 8 and row 16 drawn/handled as on page 1; rows 1-2 and 9-15 untouched until Task 8. `grid_key_256` gets an explicit `grid_page == 4` branch so page 4 no longer falls through to page 1.

- [ ] **Step 1: Write the failing Lua tests**

```lua
test("fx params drive setFilter/setDelay and live in scenes", function()
  local context = load_strata(); context.clear_engine_calls()
  params:set("filter_type", 3); params:set("filter_freq", 1200); params:set("filter_mix", 1)
  local call = context.calls_named("setFilter"); call = call[#call]
  assert_near(call.args[1], 1200, 1); assert_equal(call.args[3], 2); assert_equal(call.args[4], 1)
  params:set("delay_time", 0.5); params:set("delay_feedback", 0.6); params:set("delay_mix", 0.3)
  call = context.calls_named("setDelay"); call = call[#call]
  assert_near(call.args[1], 0.5, 1e-6); assert_near(call.args[2], 0.6, 1e-6); assert_near(call.args[3], 0.3, 1e-6)
  capture_scene(1); params:set("filter_freq", 300); params:set("delay_mix", 0)
  recall_scene(1, 0)
  assert_near(params:get("filter_freq"), 1200, 1); assert_near(params:get("delay_mix"), 0.3, 1e-6)
end)

test("v1 scene file migrates to v2 with fx defaults", function()
  local context = load_strata({ data_subdir = "v1" })
  capture_scene(2)
  local scenes = local_value("scenes")
  scenes[2].data.filter_freq = nil; scenes[2].data.delay_mix = nil   -- as a v1 file would lack them
  tab.save(scenes, context.data_dir .. "scenes.data")               -- v1 wrote the bare array
  load_scenes_from_disk()
  assert_true(local_value("scenes")[2].populated)
  recall_scene(2, 0)                                                -- must not error on nil
  assert_near(params:get("filter_freq"), 5000, 1); assert_equal(params:get("delay_mix"), 0)
  assert_true(table.concat(context.printed, "\n"):find("migrated"), "migration message printed")
end)

test("FX page: E2 selects a row, E3 adjusts it, K3 bypasses the filter", function()
  local context = load_strata(); enc(1, 1)
  params:set("filter_mix", 0.8); key(3, 1); assert_equal(params:get("filter_mix"), 0)
  key(3, 1); assert_near(params:get("filter_mix"), 0.8, 1e-6)
  enc(2, 3); local before = params:get("filter_freq"); enc(3, 2)
  assert_true(params:get("filter_freq") > before, "row 4 is filter freq")
end)

test("grid page 4 shows FX faders in rows 3-7 and keeps row 8/16", function()
  local context = load_strata(); context.clock.advance()
  local device = context.grid.plug(1, 16, 16)
  context.grid.press(1, 16, 8, 1)              -- page 4
  context.grid.press(1, 16, 3, 1); assert_near(params:get("filter_freq"), 20000, 1)
  context.grid.press(1, 1, 7, 1); assert_equal(params:get("delay_mix"), 0)
  assert_equal(device:get_led(16, 3), 15, "filter freq fader at max")
  context.grid.press(1, 1, 8, 1); assert_true(local_value("pattern_playing"), "row 8 play on page 4")
  context.grid.press(1, 1, 16, 1); assert_true(local_value("frozen")[1], "row 16 freeze on page 4")
end)
```

- [ ] **Step 2: Add engine checks** to `test/engine_check.scd`: `\strataFilter` and `\strataDelay` in `allDefs`; `formatOf.(\setFilter) == "ffif"`, `formatOf.(\setDelay) == "fff"`; node order `names` ends `[..., \strataFilter, \strataDelay, \strataReverb, \strataMaster]`; `command.(\setFilter, 800.0, 0.2, 1, 1.0)` then `getControl.(engine.synths[\filter], \filterType) == 1`; `command.(\setDelay, 0.25, 0.5, 0.5)` reaches `engine.synths[\delay]`.

- [ ] **Step 3: Run to verify they fail**

Run: `lua test/run.lua; test/run_engine_check.sh`
Expected: Lua FAIL (`filter_type` invalid param); engine check FAIL (missing defs/commands).

- [ ] **Step 4: Implement** the SC SynthDefs, buses, commands, chain order, limiter, and `free` additions; the Lua `strata_fx` group, scene globals with defaults, `migrate_scene`, version 2 loading, `redraw_fx`, page 2 enc/key, arc FX mapping, grid page 4 FX fader rows. Update CLAUDE.md (command table rows `setFilter`, `setDelay`; signal-flow diagram; scene version 2) and README (FX section, FX page controls, grid page 4 rows 3-7).

- [ ] **Step 5: Run to verify they pass**

Run: `lua test/run.lua && luajit test/run.lua && lua test/sync_check.lua && test/run_engine_check.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/Engine_Strata.sc strata.lua test/ CLAUDE.md README.md
git commit -m "feat: filter and delay in the master chain, FX page, scene format v2 with migration"
```

---

### Task 4: Grain envelope shapes

**Files:**
- Modify: `lib/Engine_Strata.sc` (`alloc`: `envBuffers`; `\strataGrain` arg `envBuf=-1`; `setGrainParam` special case; `free`)
- Modify: `strata.lua` (`voices[i].grain.env`, `GRAIN_PARAM_IDS.env = "grain_env"`, `add_voice_params`, `sync_voice_to_engine`, `scene_transition_targets`, `gentle_mutate`, `VOICE_SCENE_DEFAULTS`, `param_range`)
- Modify: `test/engine_check.scd`, `test/run.lua`, `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: Task 3's `VOICE_SCENE_DEFAULTS`, `migrate_scene`.
- Produces:
  - SC: `envBuffers` = 4 `Buffer.loadCollection` of `Env.sine`, `Env.perc(0.1, 0.9)`, `Env.linen(0.1, 0.8, 0.1)`, `Env([0,1,1,0],[0.25,0.5,0.25])`, each `.asSignal(1024)`; `\strataGrain` (and `\strataGrainBuf` in Task 6) take `envBuf = -1`; `setGrainParam` maps `\envShape` value `n` to `envBuf = (n == 0).if(-1, envBuffers[n-1].bufnum)` via helper `envBufnumFor(index)`.
  - Lua: `GRAIN_ENV_OPTIONS = {"hann", "sine", "perc", "linen", "trap"}`; per-voice option param `v<i>_grain_env` default 1; `voices[i].grain.env` holds the option index (1..5); action sends `engine.setGrainParam(voice_idx - 1, "envShape", x - 1)` when active; `sync_voice_to_engine` sends it; `DISCRETE_GRAIN_KEYS = { env = true }` (Task 5 adds `mode`) skipped by `scene_transition_targets` and `gentle_mutate`; `param_range` returns `1, param.count` for option params so the grid fader shows it.

- [ ] **Step 1: Write the failing tests**

```lua
test("grain envelope option reaches the engine and is synced on start", function()
  local context = load_strata(); context.clock.advance()
  params:set("v1_grain_env", 3)
  local calls = context.calls_named("setGrainParam"); local last = calls[#calls]
  assert_equal(last.args[2], "envShape"); assert_equal(last.args[3], 2)
  toggle_voice(3); params:set("v3_grain_env", 5); toggle_voice(3)       -- on, edit, off
  context.clear_engine_calls(); toggle_voice(3)                          -- on again: synced
  local sent = engine_state_for_voice(context.engine_calls, 2)
  assert_equal(sent.grain.envShape, 4)
  capture_scene(1); params:set("v1_grain_env", 1)
  recall_scene(1, 2); context.clock.advance()
  assert_equal(params:get("v1_grain_env"), 1, "transition does not interpolate env")
  recall_scene(1, 0); assert_equal(params:get("v1_grain_env"), 3)
end)
```

Engine check additions: `engine.envBuffers.size == 4`; after `command.(\setGrainParam, 0, \envShape, 2)`, `getControl.(engine.synths[\grain0], \envBuf) == engine.envBuffers[1].bufnum`; `\envShape, 0` → `-1`.

- [ ] **Step 2: Run to verify they fail** — `lua test/run.lua; test/run_engine_check.sh` → FAIL.

- [ ] **Step 3: Implement** per the Interfaces. README: per-voice "grain envelope" param; CLAUDE.md: grain parameter list gains `envShape`.

- [ ] **Step 4: Run to verify they pass** — all four commands PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: selectable grain envelope shapes (hann/sine/perc/linen/trap)"`

---

### Task 5: Triggered grain mode and velocity on retrigger

**Files:**
- Modify: `lib/Engine_Strata.sc` (`\strataGrain` args `grainMode=0, t_trig=0`; all seven voice SynthDefs' accent scaled by `velocity`; `retrigger` command `"if"` forwarding to voice and grain synths)
- Modify: `strata.lua` (`voices[i].grain.mode`, `GRAIN_PARAM_IDS.mode = "grain_mode"`, `DISCRETE_GRAIN_KEYS.mode`, `add_voice_params`, `sync_voice_to_engine`, `pattern_clock_start`, `VOICE_SCENE_DEFAULTS`)
- Modify: `test/engine_check.scd`, `test/run.lua`, `CLAUDE.md`, `README.md`

**Interfaces:**
- Produces:
  - SC: `\strataGrain` trigger = `Select.ar(grainMode, [Impulse.ar(grainDensity), T2A.ar(t_trig)])`; voice SynthDefs get `t_vel=1` alongside `t_trig` and `accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig) * t_vel` ... implemented as a plain `velocity=1` control set in the same message as `t_trig`. Command `retrigger "if"`: `setSynth(voiceKey, \velocity, msg[2], \t_trig, 1)` and `setSynth(grainKey, \t_trig, 1)`.
  - Lua: `GRAIN_MODE_OPTIONS = {"continuous", "triggered"}`; `v<i>_grain_mode` option default 1 stored in `voices[i].grain.mode`; action sends `setGrainParam(voice, "grainMode", x - 1)`; `pattern_clock_start` sends `engine.retrigger(voice_idx - 1, patterns[voice_idx][pattern_position] / 15)`.
  - Ruling (deviation from spec §1 wording): K3 on MAIN keeps its freeze meaning; triggered grains fire from pattern steps and MIDI notes only. Document in README.

- [ ] **Step 1: Write the failing tests**

```lua
test("pattern steps retrigger with velocity from the step level", function()
  local context = load_strata(); context.clock.advance()
  local patterns = local_value("patterns"); patterns[1][1] = 15; patterns[1][2] = 6
  context.clear_engine_calls(); pattern_toggle(); context.clock.advance(); pattern_toggle()
  local calls = context.calls_named("retrigger")
  assert_equal(calls[1].args[1], 0); assert_near(calls[1].args[2], 1.0, 1e-9)
  assert_near(calls[2].args[2], 6 / 15, 1e-9)
end)

test("grain mode option is sent, synced and never mutated", function()
  local context = load_strata(); context.clock.advance()
  params:set("v1_grain_mode", 2)
  local calls = context.calls_named("setGrainParam"); assert_equal(calls[#calls].args[2], "grainMode"); assert_equal(calls[#calls].args[3], 1)
  params:set("mutation_probability", 1); params:set("mutation_amount", 1); gentle_mutate()
  assert_equal(params:get("v1_grain_mode"), 2)
end)
```

Engine check: `formatOf.(\retrigger) == "if"`; `command.(\retrigger, 0, 0.5)` sets `velocity` 0.5 on `voice0` and creates no nodes; `command.(\setGrainParam, 0, \grainMode, 1)` reaches `grain0`.

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** per Interfaces; `sync_check` will flag the changed arity until every `engine.retrigger` call sends two args.
- [ ] **Step 4: Run all four checks → PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat: triggered grain mode; retrigger carries velocity (pattern level / MIDI)"`

---

### Task 6: Engine audio sources: buffer pairs, live input, GrainBuf synth, buffer commands

**Files:**
- Modify: `lib/Engine_Strata.sc`
- Modify: `test/engine_check.scd`, `CLAUDE.md`

**Interfaces:**
- Consumes: `envBufnumFor`, `silentBus`, `voiceGroup`, `processGroup`, `synths`, `grainKey`, `releaseVoice`, `setSynth`.
- Produces:
  - Vars: `numBuffers = 8`, `bufferSeconds = 16`, `buffersL`, `buffersR` (mono `Buffer.alloc(server, sampleRate * bufferSeconds, 1)`), `bufferFrames` (Array of 0), `inputBus` (stereo), `inputSynth` (`\strataInput`: `Out.ar(out, SoundIn.ar([0, 1]))`, head of `voiceGroup`), `grainSource` (Array of 0 per voice), `bufferStatePoll`.
  - `\strataGrainBuf`: args `out, gate=1, bufnumL, bufnumR, bufFrames=1, bufPos=0, bufRate=1, bufScan=0, grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5, envBuf=-1, grainMode=0, t_trig=0, amp=1, bend=1, modBus1..3, modAmpAmt1..3, modFreqAmt1..3, velocity=1, mirrorOut`. Position: `scanPos = (bufPos + Phasor.ar(0, bufScan / (bufFrames / SampleRate.ir) * SampleDur.ir, 0, 1)) % 1`, grain position jitter `± posSpread * 0.5` wrapped to 0..1, rate `bufRate * bend * BufRateScale.kr(bufnumL) * (1 + freqMod.clip(-0.9, 2))`; two `GrainBuf.ar(1, trig, grainSize, bufnumL|R, rate, pos, 2, 0, envBuf)` sharing `trig`, `rate`, `pos`; `Balance2.ar(left, right, LFNoise1.kr(2).range(panSpread.neg, panSpread))`; `PitchShift.ar` as in `\strataGrain`; amplitude `(amp * (1 + ampMod) * (1 + accent * velocity)).clip(0, 2)`; `Out.ar(out, sig * env)` and `Out.ar(mirrorOut, sig * env)` (mirrorOut = the voice's `granBuses[i]` so `\strataMod` follows it).
  - `\strataGrain` gains the same `bend`, `velocity` controls for symmetry (unused for bus input).
  - Commands: `setGrainSource "ii"` (voice, source 0 synth / 1..8 buffer / 9 input): records `grainSource[voice]`; if the voice is running (`synths[voiceKey]` or `synths[grainKey]` exists) it calls `replaceGrainSynth(voice)`, which gates off the old grain synth and creates the right one with the voice's current grain controls (read from a per-voice `grainControls` Dictionary that `setGrainParam` keeps updated), then gates the voice synth off when source ≠ 0 or recreates it (with `\freq` etc. from `voiceControls[voice]`) when returning to 0. `voiceOn` consults `grainSource[voice]` so a voice started while in buffer mode gets `\strataGrainBuf` directly and no voice synth.
  - `loadBuffer "is"`, `recordBuffer "iff"`, `clearBuffer "i"`, `saveBuffer "is"` as in spec §1 (`SoundFile.openRead` for channel count and frames; `Buffer.readChannel` into `buffersL/R`; `RecordBuf.ar` of `In.ar(inputBus, 2) * level` into both, `doneAction: 2`; on completion write `_path.audio/strata/scratch/buf<n>.wav` via a temporary interleaved buffer — implement helper `writeSlot(index, path)` used by both the scratch write and `saveBuffer`); every change sets `bufferFrames[index]` and calls `bufferStatePoll.update(...)`.
  - Poll `bufferState` (`this.addPoll(\bufferState, { ... })` returning the 8 valid seconds as a space-separated string; Lua parses).
  - `free` frees buffers, `inputBus`, `inputSynth`.

- [ ] **Step 1: Write the failing engine checks** (in `test/engine_check.scd`):

```supercollider
check.(formatOf.(\setGrainSource) == "ii", "setGrainSource ii");
check.(formatOf.(\loadBuffer) == "is" and: { formatOf.(\recordBuffer) == "iff" }
   and: { formatOf.(\clearBuffer) == "i" } and: { formatOf.(\saveBuffer) == "is" }, "buffer command signatures");
check.(engine.buffersL.size == 8 and: { engine.buffersR.size == 8 }, "eight stereo slots as L/R pairs");
check.(engine.buffersL[0].numChannels == 1, "buffers are mono");
// voice 0 running from the earlier voiceOn; switch it to buffer 3
before = synthNames.(context.xg).size;
command.(\setGrainSource, 0, 3); server.sync;
check.(synthNames.(context.xg).includes(\strataGrainBuf), "buffer source uses strataGrainBuf");
check.(synthNames.(context.xg).count({ arg n; n == \strataGrainBuf }) == 1, "one GrainBuf synth per buffer voice");
check.(engine.synths[\voice0].isNil, "voice synth released in buffer mode");
command.(\setGrainSource, 0, 9); server.sync;
check.(synthNames.(context.xg).count({ arg n; n == \strataGrainBuf }) == 0, "input source uses strataGrain");
command.(\setGrainSource, 0, 0); server.sync;
check.(engine.synths[\voice0].notNil, "returning to synth restarts the voice synth");
check.(synthNames.(context.xg).size == before, "source switching leaves no extra nodes");
command.(\setGrainSource, 1, 3); server.sync;            // voice 1 reads slot 3 (index 2)
before = synthNames.(context.xg).size;
command.(\recordBuffer, 2, 0.1, 1.0); 0.3.wait; server.sync;
check.(engine.bufferFrames[2] > 0, "recordBuffer sets the valid length");
check.(synthNames.(context.xg).size == before, "recording into a slot a voice is reading adds no lasting nodes");
command.(\clearBuffer, 2); check.(engine.bufferFrames[2] == 0, "clearBuffer resets it");
```

- [ ] **Step 2: Run to verify it fails** — `test/run_engine_check.sh` → FAIL.
- [ ] **Step 3: Implement** per Interfaces. CLAUDE.md: command table rows, bus list, "Audio sources" section with the replace-not-stack rule and the mirror-to-voice-bus trick.
- [ ] **Step 4: Run `test/run_engine_check.sh` → PASS**; `lua test/sync_check.lua` will report unused commands until Task 7 — acceptable only within this task; note it in the commit body.
- [ ] **Step 5: Commit** — `git commit -m "engine: stereo buffer slots, live input bus, GrainBuf source synth, buffer commands and poll"`

---

### Task 7: Lua sources, buffer params, sync, behavior rules, scenes

**Files:**
- Modify: `strata.lua` (`voices[i]` gains `source = 1`, `grain.buf_pos = 0`, `grain.buf_rate = 1`, `grain.buf_scan = 0`; `SOURCE_OPTIONS`; `add_voice_params`; `sync_voice_to_engine`; `toggle_voice`; `main_param_id`/`main_param_label`; `randomize_voice`; `gentle_mutate`; `lfo_update`; `scene_transition_targets`; `VOICE_SCENE_DEFAULTS`; `validate_scene`; buffer group params; `buffers` table; `bufferState` poll)
- Modify: `test/run.lua`, `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: Task 6 commands; Task 2 `main_param_id`.
- Produces:
  - `SOURCE_OPTIONS = {"synth", "buf 1", ..., "buf 8", "input"}` (built from `NUM_BUFFERS`); `v<i>_source` option default 1 → `voices[i].source`; action: `if active then sync_voice_to_engine(i) end; redraw(); grid_redraw()`.
  - `v<i>_buf_pos` 0..1 default 0, `v<i>_buf_rate` 0.25..4 exp default 1, `v<i>_buf_scan` -2..2 default 0 → `voices[i].grain.buf_pos|buf_rate|buf_scan`, sent as `bufPos`, `bufRate`, `bufScan` via `setGrainParam`; `GRAIN_PARAM_IDS` gains them.
  - `sync_voice_to_engine` sends `engine.setGrainSource(engine_voice, voice.source - 1)` first, then all grain params including the buffer ones, env, mode; `toggle_voice` unchanged otherwise.
  - `function voice_uses_buffer(voice_idx)` (source 2..9) and `function voice_source_label(voice_idx)`; `main_param_id` returns `v<i>_buf_pos` when `voice_uses_buffer`, `main_param_label` returns `"pos"`.
  - `randomize_voice`: when `voice_uses_buffer`, randomizes `buf_pos`, `buf_rate` (0.5..2), `buf_scan` (-0.5..0.5) and grain size/pitch, not the synth params. `gentle_mutate` and `lfo_update`: buffer-sourced voices mutate/drift `buf_pos` instead of synth params (drift step 0.002 of position, mean-reverting like pitch). `source` never randomized or mutated.
  - Scenes: `voices[i].source` captured/recalled (`params:set(prefix .. "source", ...)`), buffer grain params through `GRAIN_PARAM_IDS`; `scene_transition_targets` skips `source` and `DISCRETE_GRAIN_KEYS`; `VOICE_SCENE_DEFAULTS` gains `source = 1`, `grain.buf_pos = 0`, `grain.buf_rate = 1`, `grain.buf_scan = 0`; `validate_scene` checks `source` is an integer 1..NUM_BUFFERS + 2.
  - Buffer group `strata_buffers`: `record_duration` 0.5..16 default 8 "s", `record_level` 0..2 default 1; per slot n: `buf<n>_file` (`params:add_file`, action → `load_buffer(n, path)` when path ≠ ""), `buf<n>_record` trigger → `record_buffer(n)`, `buf<n>_clear` trigger → `clear_buffer(n)`, `buf<n>_save` trigger → `save_buffer(n)`.
  - `local buffer_audio_dir = _path.audio .. "strata/"`; `function buffer_save_path(slot)` → `buffer_audio_dir .. os.date("%Y%m%d-%H%M%S") .. "-buf" .. slot .. ".wav"`; `function save_buffer(slot)` → `util.make_dir(buffer_audio_dir)` then `engine.saveBuffer(slot - 1, buffer_save_path(slot))` and prints the path.
  - `local buffers = {}` with `{name = "empty", loaded = false, recording = false, seconds = 0, path = nil}` per slot; `function load_buffer(slot, path)`, `function record_buffer(slot)` (sends `engine.recordBuffer(slot - 1, params:get("record_duration"), params:get("record_level"))`, sets `recording = true`, `clock.run` timer of `record_duration` clears it and sets `name = "take " .. slot`), `function clear_buffer(slot)`; the `bufferState` poll parses eight numbers into `buffers[n].seconds`.

- [ ] **Step 1: Write the failing tests**

```lua
test("source switching syncs through setGrainSource and swaps the main param", function()
  local context = load_strata(); context.clock.advance()
  context.clear_engine_calls(); params:set("v1_source", 4)      -- buf 3
  local calls = context.calls_named("setGrainSource")
  assert_equal(calls[1].args[1], 0); assert_equal(calls[1].args[2], 3)
  assert_equal(main_param_id(1), "v1_buf_pos"); assert_equal(main_param_label(1), "pos")
  params:set("v1_source", 10); calls = context.calls_named("setGrainSource"); assert_equal(calls[#calls].args[2], 9)
  params:set("v1_source", 1); assert_equal(main_param_id(1), "v1_freq")
  toggle_voice(3); params:set("v3_source", 2); toggle_voice(3)          -- on, edit, off
  context.clear_engine_calls(); toggle_voice(3)                          -- on again: synced
  local sent = engine_state_for_voice(context.engine_calls, 2)
  assert_equal(context.calls_named("setGrainSource")[1].args[2], 1, "started voice sends its source")
  assert_equal(sent.grain.bufPos, 0); assert_equal(sent.grain.bufRate, 1); assert_equal(sent.grain.bufScan, 0)
end)

test("randomize and mutate touch buffer params, never source", function()
  local context = load_strata(); context.clock.advance()
  params:set("v1_source", 2); local freq = params:get("v1_freq")
  math.randomseed(7); randomize_voice(1)
  assert_equal(params:get("v1_freq"), freq, "synth params untouched for a buffer voice")
  assert_true(params:get("v1_buf_rate") ~= 1 or params:get("v1_buf_pos") ~= 0, "buffer params randomized")
  params:set("mutation_probability", 1); params:set("mutation_amount", 1); gentle_mutate()
  assert_equal(params:get("v1_source"), 2)
end)

test("transition skips discrete voice fields; scenes keep source and buffer params", function()
  local context = load_strata(); context.clock.advance()
  params:set("v2_source", 3); params:set("v2_buf_pos", 0.7); capture_scene(1)
  params:set("v2_source", 1); params:set("v2_buf_pos", 0.1)
  recall_scene(1, 4); context.clock.advance()
  assert_equal(params:get("v2_source"), 1, "source only changes at the end of a transition")
  assert_true(params:get("v2_buf_pos") > 0.1, "buf_pos interpolates")
  for _ = 1, 25 do context.clock.advance() end
  assert_equal(params:get("v2_source"), 3); assert_near(params:get("v2_buf_pos"), 0.7, 1e-6)
end)

test("buffer triggers call the engine and track recording state", function()
  local context = load_strata()
  params:set("record_duration", 2); params:set("buf3_record", 1)
  local call = context.calls_named("recordBuffer")[1]
  assert_equal(call.args[1], 2); assert_near(call.args[2], 2, 1e-9)
  assert_true(local_value("buffers")[3].recording)
  context.clock.advance(); assert_true(not local_value("buffers")[3].recording)
  params:set("buf3_file", "/tmp/a.wav"); assert_equal(context.calls_named("loadBuffer")[1].args[2], "/tmp/a.wav")
  params:set("buf3_clear", 1); assert_equal(context.calls_named("clearBuffer")[1].args[1], 2)
  context.polls.fire("bufferState", "0 0 1.5 0 0 0 0 0"); assert_near(local_value("buffers")[3].seconds, 1.5, 1e-9)
end)
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** per Interfaces. README: per-voice source, buffer params, what scenes do and don't capture; CLAUDE.md: voice state table fields, sync order (`setGrainSource` first).
- [ ] **Step 4: Run all four checks → PASS** (`sync_check` now sees every command used).
- [ ] **Step 5: Commit** — `git commit -m "feat: per-voice audio source (synth/buffer/input), buffer params, source-aware sync, scenes"`

---

### Task 8: BUFFER page, arc BUFFER page, grid page 4 buffer rows

**Files:**
- Modify: `strata.lua` (`redraw_buffer`, `PAGE_ENC[4]`, `PAGE_KEY[4]`, `ARC_PAGE_DELTA[4]`, `ARC_PAGE_REDRAW[4]`, `grid_key_256` page 4 rows 1-2 and 9-15, `grid_redraw_256` page 4)
- Modify: `test/run.lua`, `README.md`

**Interfaces:**
- Consumes: Task 7 `buffers`, `voice_uses_buffer`, `record_buffer`, `load_buffer`, `clear_buffer`, `SOURCE_OPTIONS`; Task 1 `fileselect` stub.
- Produces:
  - `redraw_buffer()`: left column (x 0..60): selected voice name, `"src: " .. voice_source_label(selected_voice)`; right column (x 65..127): eight rows `"<n> <name|empty> <seconds>s"` with the voice's buffer at level 15, loaded 8, empty 2, `"REC"` while recording; hints `"K2:load K3:rec"`.
  - E2 → `selected_voice`; E3 → `params:delta("v<i>_source", d)`; K3 → `record_buffer(slot)` if `voice_uses_buffer` else nothing (hint reads `"K3:-"`); K2 → `fileselect.enter(_path.audio, function(path) if path ~= "cancel" then params:set("buf<slot>_file", path) end end)`.
  - `function voice_buffer_slot(voice_idx)` → 1..8 or nil.
  - Arc page 4: ring 1 `v<i>_buf_pos` (delta/200), ring 2 `v<i>_buf_rate` (delta/100), ring 3 `record_duration` (delta/20), ring 4 `record_level` (delta/100).
  - Grid 256 page 4: row 1 cols 1-8 `record_buffer(x)` (LED 15 recording, 8 loaded, 2 empty); row 2 cols 1-8 `clear_buffer(x)` (LED 4); rows 9-15 voice rows: col 1 synth, 2-9 buffers, 10 input → `params:set("v<voice>_source", x)` where voice = y - 8; LED 15 selected, 4 other, 2 for empty buffers.

- [ ] **Step 1: Write the failing tests**

```lua
test("BUFFER page: E3 cycles source, K3 records into the voice's slot, K2 opens the file selector", function()
  local context = load_strata(); context.clock.advance(); enc(1, 3)
  enc(3, 2); assert_equal(params:get("v1_source"), 3)
  key(3, 1); assert_equal(context.calls_named("recordBuffer")[1].args[1], 1)
  key(2, 1); assert_true(context.fileselect.last ~= nil, "fileselect opened")
  context.fileselect.last.callback("/tmp/b.wav"); assert_equal(params:get("buf2_file"), "/tmp/b.wav")
  params:set("v1_source", 1); context.clear_engine_calls(); key(3, 1)
  assert_equal(#context.calls_named("recordBuffer"), 0, "K3 does nothing for a synth voice")
  redraw(); for _, entry in ipairs(context.screen.texts) do local l, r = text_span(entry); assert_true(r <= 128) end
end)

test("grid page 4 buffer rows record, clear and set sources with LED feedback", function()
  local context = load_strata(); context.clock.advance()
  local device = context.grid.plug(1, 16, 16); context.grid.press(1, 16, 8, 1)
  context.grid.press(1, 5, 1, 1); assert_equal(context.calls_named("recordBuffer")[1].args[1], 4)
  assert_equal(device:get_led(5, 1), 15)
  context.grid.press(1, 3, 10, 1); assert_equal(params:get("v2_source"), 3); assert_equal(device:get_led(3, 10), 15)
  context.grid.press(1, 10, 15, 1); assert_equal(params:get("v7_source"), 10)
  context.grid.press(1, 5, 2, 1); assert_equal(context.calls_named("clearBuffer")[1].args[1], 4)
end)
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.** README: BUFFER page controls, arc page 4, grid page 4 rows 1-2 and 9-15.
- [ ] **Step 4: Run all checks → PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat: BUFFER page, arc buffer rings, grid page 4 record/clear/source rows"`

---

### Task 9: Buffer persistence and explicit save

**Files:**
- Modify: `strata.lua` (`buffer_save_path`, `scratch_take_path`, `save_buffers_to_disk`, `load_buffers_from_disk`, `cleanup`, `init`, `redraw_setup` restored count)
- Modify: `test/run.lua`, `README.md`, `CLAUDE.md`

**Interfaces:**
- Produces:
  - `local buffer_scratch_dir = buffer_audio_dir .. "scratch/"` (Task 7 defined `buffer_audio_dir`), `local buffer_data_file = _path.data .. "strata/buffers.data"`.
  - `function scratch_take_path(slot)` → `buffer_scratch_dir .. "buf" .. slot .. ".wav"`.
  - `record_buffer` completion sets `buffers[slot].path = scratch_take_path(slot)` (the engine wrote it); `load_buffer` sets `path`.
  - `save_buffers_to_disk()` writes `{version = 1, paths = {[n] = path or ""}}` via `tab.save`; `load_buffers_from_disk()` (pcall-protected like scenes) calls `load_buffer(n, path)` for each non-empty path whose file exists, counts `buffers_restored`; `init` calls it after `load_scenes_from_disk`; `cleanup` calls `save_buffers_to_disk()`.
  - `redraw_setup` shows `"buffers: <k> restored"`.

- [ ] **Step 1: Write the failing tests**

```lua
test("explicit save writes a timestamped file; cleanup/init persist buffer paths", function()
  local context = load_strata({ data_subdir = "buf" })
  params:set("buf2_save", 1)
  local call = context.calls_named("saveBuffer")[1]
  assert_equal(call.args[1], 1); assert_true(call.args[2]:match("strata/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-buf2%.wav$"))
  params:set("buf1_file", context.audio_dir .. "one.wav"); io.open(context.audio_dir .. "one.wav", "w"):close()
  params:set("buf4_record", 1); context.clock.advance()
  assert_equal(local_value("buffers")[4].path, context.audio_dir .. "strata/scratch/buf4.wav")
  cleanup()
  local again = load_strata({ data_subdir = "buf" })
  local loads = again.calls_named("loadBuffer")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], context.audio_dir .. "one.wav")
  assert_equal(#loads, 1, "scratch take not restored when its file is missing")
end)
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement.** README: "Saving and restoring buffers"; CLAUDE.md: disk persistence section gains buffers.
- [ ] **Step 4: Run all checks → PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat: buffer persistence (scratch takes, remembered paths) and explicit timestamped save"`

---

### Task 10: Global LFOs with the norns lfo library and the LFO page

**Files:**
- Modify: `strata.lua` (`send_param_to_engine`, `engine_senders`, LFO setup in `init`, `LFO_DESTINATIONS`, `redraw_lfo`, page 3 enc/key, arc page 3, `cleanup`, scenes)
- Modify: `test/run.lua`, `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: Task 1 `lfo` stub; Task 7 `voice_uses_buffer`, `main_param_id`.
- Produces:
  - `local engine_senders = {}`; `function send_param_to_engine(param_id, value)` calls `engine_senders[param_id](value)` if present. Every `params:add` action for a control param in `init`/`add_voice_params`/`strata_fx` is rewritten as `action = function(x) <store x>; send_param_to_engine(id, x) end` with `engine_senders[id] = function(value) <the former engine call, still gated on voice.active where it was> end`. Behavior of all existing tests unchanged.
  - `local NUM_LFOS = 3`, `local lfos = {}`; `LFO_DESTINATIONS` = ordered list of `{label, resolve = function() return param_id end}`: `none`, `density` → master_density, `drift`, `filt freq`, `filt res`, `filt mix`, `dly time`, `dly fdbk`, `dly mix`, `rev mix`, `rev size`, `rev damp`, then per voice i: `v<i> main` → `main_param_id(i)`, `v<i> size`, `v<i> dens`, `v<i> pitch`, `v<i> spread`, `v<i> pos`, `v<i> rate`, `v<i> scan`.
  - Params group `strata_lfos`: for n in 1..3: `lfos[n] = LFO:add{shape="sine", min=-1, max=1, depth=0, mode="free", period=4, baseline="center", action=function(scaled) apply_lfo(n, scaled) end}`; `lfos[n]:add_params(tostring(n), "LFO " .. n)` (the library's own ids `lfo_<n>`, `lfo_depth_<n>`, ...); Strata adds `strata_lfo<n>_dest` option over the labels, default 1 (`none`).
  - `function lfo_destination_id(n)` → resolved param id or nil; `function apply_lfo(n, scaled)`: id = destination; if nil return; `minval, maxval = param_range(id)`; `send_param_to_engine(id, util.clamp(params:get(id) + scaled * 0.5 * (maxval - minval), minval, maxval))`; `lfo_last_dest[n] = id`.
  - `function restore_lfo_destination(n)`: if `lfo_last_dest[n]` then `send_param_to_engine(lfo_last_dest[n], params:get(lfo_last_dest[n]))`; called from the dest param action (before changing), from a wrapper installed around `params:lookup_param("lfo_depth_" .. n).action` when the new depth is 0, and from a wrapper around `params:lookup_param("lfo_" .. n).action` when state becomes off.
  - `main` destinations re-resolve on every tick, so when a voice's source changes the old id is restored once (`lfo_last_dest` differs from the resolved id → restore then modulate).
  - `redraw_lfo()`: three rows at y 16, 31, 46: `"L<n>"`, a 64-px waveform from `lfo_shape_value(shape, phase)` (local mirror of the library's shape math), the dot at x = 24 + 64 * `lfo_phase_estimate[n]`, y from `lfo_last_raw[n]`; dest label at x 96; depth `%.2f` right-aligned. `lfo_phase_estimate[n]` advances in a 15 fps `lfo_page_clock` started when `ui_page == 3` and cancelled when leaving the page (in `enc(1, ...)`) and in `cleanup`. E2 selects `selected_lfo`, E3 `params:delta("lfo_depth_<n>", d / 100)`, K3 toggles `lfo_<n>` (1↔2), K2 cycles `strata_lfo<n>_dest`.
  - Arc page 3: rings 1-3 depth of LFO 1-3 (delta/100), ring 4 `lfo_free_<selected_lfo>` (delta/10).
  - Scenes: `SCENE_GLOBAL_PARAMS` gains `lfo_<n>`, `lfo_shape_<n>`, `lfo_free_<n>`, `lfo_depth_<n>` (continuous), `strata_lfo<n>_dest`, all with defaults for migration.
  - `cleanup`: `lfos[n]:stop()`, `params:set("lfo_<n>", 1)`, restore destinations.
  - `lfo_update` (the grain pitch drift) is renamed `drift_update` and `lfo_metro` → `drift_metro` in code and docs.

- [ ] **Step 1: Write the failing tests**

```lua
test("LFO modulates around the stored value without writing it, and restores on disable", function()
  local context = load_strata(); context.clock.advance()
  params:set("filter_freq", 1000); params:set("strata_lfo1_dest", 4)   -- filt freq
  params:set("lfo_depth_1", 0.5); params:set("lfo_1", 2)
  context.clear_engine_calls(); context.lfo.tick(local_value("lfos")[1], 1.0)   -- scaled = +0.5
  local call = context.calls_named("setFilter")[1]
  assert_near(call.args[1], 1000 + 0.5 * 0.5 * (20000 - 20), 1e-6)
  assert_near(params:get("filter_freq"), 1000, 1e-9, "param value untouched")
  context.clear_engine_calls(); params:set("lfo_1", 1)
  assert_near(context.calls_named("setFilter")[1].args[1], 1000, 1e-6, "disable restores the stored value")
end)

test("main destination follows a voice's source and restores the old param", function()
  local context = load_strata(); context.clock.advance()
  params:set("strata_lfo2_dest", 13)   -- v1 main
  params:set("lfo_depth_2", 1); params:set("lfo_2", 2)
  context.lfo.tick(local_value("lfos")[2], 0.5)
  assert_equal(local_value("lfo_last_dest")[2], "v1_freq")
  params:set("v1_source", 2); context.clear_engine_calls(); context.lfo.tick(local_value("lfos")[2], 0.5)
  local voice_calls = context.calls_named("setVoiceParam")
  assert_equal(voice_calls[1].args[2], "freq"); assert_near(voice_calls[1].args[3], params:get("v1_freq"), 1e-9)
  assert_equal(local_value("lfo_last_dest")[2], "v1_buf_pos")
end)

test("LFO page draws three rows inside the screen and cleanup stops LFOs", function()
  local context = load_strata(); context.clock.advance(); enc(1, 2); redraw()
  for _, entry in ipairs(context.screen.texts) do local l, r = text_span(entry); assert_true(l >= 0 and r <= 128 and entry.y <= 64) end
  params:set("lfo_3", 2); cleanup(); assert_equal(params:get("lfo_3"), 1)
end)
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** per Interfaces, including the `send_param_to_engine` refactor (do it first; all existing tests must still pass before adding LFOs). README: LFO section, LFO page, arc page 3, rate ceiling note; CLAUDE.md: "Global LFOs" section with the modulate-around rule and `send_param_to_engine`, rename of the drift metro.
- [ ] **Step 4: Run all checks → PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat: three global LFOs (norns lfo lib) routed through send_param_to_engine, LFO page"`

---

### Task 11: MIDI input and pitchbend

**Files:**
- Modify: `lib/Engine_Strata.sc` (every voice SynthDef and `\strataGrainBuf`: `bend=1` multiplier on `modFreq`/rate)
- Modify: `strata.lua` (`midi_init`, `midi.add`/`midi.remove`, `midi_event`, params `midi_device`, `midi_channel_mode`, `midi_note_off`, `redraw_setup`, `PAGE_ENC[5]`)
- Modify: `test/engine_check.scd`, `test/run.lua`, `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: Task 5 `engine.retrigger(voice, velocity)`; Task 7 `voice_uses_buffer`; Task 1 midi stub; `musicutil`.
- Produces:
  - SC: `bend = 1` control in all seven voice SynthDefs (`modFreq = modFreq * bend`) and `\strataGrainBuf` (rate × bend). Engine check: `command.(\setVoiceParam, 0, \bend, 1.05)` reaches `voice0`.
  - Lua group `strata_midi`: `midi_device` number 1..4 default 1 (action `attach_midi(x)`), `midi_channel_mode` option {`per voice`, `omni → selected`} default 1, `midi_note_off` option {`ignore`, `voice off`} default 1.
  - `local midi_device`; `function attach_midi(port)` sets `midi_device = midi.connect(port); midi_device.event = midi_event`; `midi.add`/`midi.remove` re-attach / print.
  - `function midi_target_voice(channel)` → voice index or nil (mode 1: channel 1..NUM_VOICES; mode 2: `selected_voice`).
  - `function midi_event(data)`: `msg = midi.to_msg(data)`; `note_on` with `vel > 0`: `midi_note_on(voice, msg.note, msg.vel)`; `note_on` vel 0 or `note_off`: `midi_note_off_for(voice)`; `pitchbend`: `midi_pitchbend(voice, msg.val)`.
  - `function midi_note_on(voice_idx, note, velocity)`: source synth → `params:set("v<i>_freq", clamp(musicutil.note_num_to_freq(note), spec))`; buffer → `params:set("v<i>_buf_rate", clamp(2 ^ ((note - 60) / 12), 0.25, 4))`; input → nothing; then `if not active then toggle_voice(i) end; engine.retrigger(i - 1, velocity / 127)`.
  - `function midi_note_off_for(voice_idx)`: if `midi_note_off == 2` and active → `toggle_voice(i)`.
  - `function midi_pitchbend(voice_idx, value)`: `ratio = 2 ^ (((value - 8192) / 8192) * 2 / 12)`; `engine.setVoiceParam(i - 1, "bend", ratio)` if active (also `setGrainParam(i - 1, "bend", ratio)` when buffer-sourced).
  - `redraw_setup`: `"midi: " .. (midi_device and midi_device.name or "none") .. " " .. params:string("midi_channel_mode")`; E2 → `params:delta("midi_device", d)`, E3 → `params:delta("midi_channel_mode", d)`.
  - README: MIDI section with the CC mapping how-to (PARAMS > MAP) and Confluence's suggested CC list.

- [ ] **Step 1: Write the failing tests**

```lua
test("MIDI notes set pitch per source, start or retrigger the voice with velocity", function()
  local context = load_strata(); context.clock.advance()
  context.midi.send(1, { type = "note_on", note = 69, vel = 127, ch = 3 })   -- voice 3, off
  assert_near(params:get("v3_freq"), 440, 0.01); assert_true(local_value("voices")[3].active)
  local rt = context.calls_named("retrigger"); assert_equal(rt[#rt].args[1], 2); assert_near(rt[#rt].args[2], 1, 1e-9)
  params:set("v1_source", 2)
  context.midi.send(1, { type = "note_on", note = 72, vel = 64, ch = 1 })
  assert_near(params:get("v1_buf_rate"), 2, 1e-6); rt = context.calls_named("retrigger"); assert_near(rt[#rt].args[2], 64 / 127, 1e-9)
  params:set("v2_source", 10); context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 2 })  -- input source: no error
  context.midi.send(1, { type = "note_on", note = 50, vel = 100, ch = 9 })  -- no voice: ignored
  params:set("v1_source", 1); params:set("midi_channel_mode", 2)        -- omni → selected voice (1, synth again)
  context.midi.send(1, { type = "note_on", note = 57, vel = 100, ch = 9 })
  assert_near(params:get("v1_freq"), 220, 0.01)
end)

test("note off mode and pitchbend", function()
  local context = load_strata(); context.clock.advance()
  context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 }); assert_true(local_value("voices")[1].active)
  params:set("midi_note_off", 2); context.midi.send(1, { type = "note_off", note = 60, vel = 0, ch = 1 })
  assert_true(not local_value("voices")[1].active)
  context.midi.send(1, { type = "pitchbend", val = 8192 + 8191, ch = 2 })
  local calls = context.calls_named("setVoiceParam"); local last = calls[#calls]
  assert_equal(last.args[2], "bend"); assert_near(last.args[3], 2 ^ (2 / 12), 1e-3)
end)
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** per Interfaces (engine `bend` first, then Lua). `musicutil` is now required by `strata.lua`.
- [ ] **Step 4: Run all checks → PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat: MIDI note/velocity/pitchbend input with per-voice channels; CC via norns param mapping"`

---

### Task 12: Documentation reconciliation and CHANGELOG 3.0

**Files:**
- Modify: `CHANGELOG.md`, `README.md`, `CLAUDE.md`
- Create: `docs/superpowers/specs/2026-11-03-confluence-features-design.md` (if not already committed), this plan under `docs/superpowers/plans/`

**Interfaces:** none (docs only), but the CLAUDE.md command table must list exactly the `addCommand`s in the engine; verify with `grep -c addCommand lib/Engine_Strata.sc` against the table rows.

- [ ] **Step 1: Write the check** — add to `test/run.lua`:

```lua
test("CLAUDE.md command table lists every engine command", function()
  local doc = io.open(repo_root .. "/CLAUDE.md"):read("*a")
  for name in pairs(signatures) do
    assert_true(doc:find("`engine%." .. name .. "%("), "CLAUDE.md documents engine." .. name)
  end
end)
```

- [ ] **Step 2: Run to verify it fails or passes** (it should fail for any command a task forgot).
- [ ] **Step 3: Reconcile** README (feature list, every page's controls, arc pages, grid page 4, MIDI, buffers, LFOs, FX; "Parameters" section regrouped: Master/FX/LFOs/Buffers/MIDI/Mutations/Scenes/Per-voice), CLAUDE.md (architecture diagram with filter/delay and buffer sources, command table, voice state fields, pages, persistence, test commands), CHANGELOG `## Version 3.0` with one bullet per feature and the two documented deviations (LFO 10 Hz ceiling; K3 stays freeze).
- [ ] **Step 4: Run all four checks → PASS.**
- [ ] **Step 5: Commit** — `git commit -m "docs: version 3.0 — Confluence feature set absorbed into Strata"`
