# Plan facts: 2b LFO home routings, and 3c's #741

Read-only, `main` = 61e07acb (same code as 3bb75daa for these files). Counts by grep.

# Package 2b

## 1. Files

**lib/lfos.lua** (1,033 lines). Removed: header 1-21 (rewrite); `LFO.group_size` 14 → 12 (:41); `destination_of` reading `strata_lfo<n>_dest` (:207-209, rewritten); `lfo_destination_labels` keys part (:185-190); `restore_lfo_destination` (:434-446); `send_destination` (:493-495); `step_lua`'s Lua branch (:513-535); the `S.lfo_last_dest` uses in `step_lfo` (:662, :694), `turned` (:806), the depth action (:905), cleanup (:777); the `io_keyed.add` destination (:869-879); the six scene blocks (:963-994). Kept unchanged: `fast_destination`, `build_destinations`, `destination_groups`, `check_global_destinations`, `evaluate`, `capped`, the queue and `drain` (:374-404), `on_step`, the engine path (:540-635, it reads `destination_of(n).fast`), the clock, `SCENE_FIELDS` (:942-961), `transition_stops` (:998), the sources (:1019-1030). `send_direct` (:499-508) stays but sums its own LFOs (below).

**lib/matrix.lua** (761 lines): storage and the step for slots 17-22 (:67-71, :329-337, :375-406, :442-527, :534-574, :683-716, :736-744). Public R1-R16 functions keep `is_index` 1..16.

**lib/engine_sync.lua**: `with_lfo_offsets` (:87-116) loses its LFO loop; remove `NUM_LFOS` local (:32, its only use), `S.lfo_last_dest`/`S.lfo_scaled` (:54-55), header lines 4, 7-10 and 23; comments :369 (`as modulated by the LFOs`) and :410.

**lib/macros.lua**: `modulated(m)` (:251-258) and the hook's call (:281), header comment :271-277.

**lib/side_files.lua**: `check` (:33-43), `read` (:69-80), header :4.

**lib/data_files.lua**: `largest_scenes_tables` (:39) + 96 (six tables a scene × 16; the six string blocks it replaces hold no table), on top of 1a's figure; comment :32-38.

**lib/pages/lfo.lua**: `LFO_FIELDS[1]` (:90), `lfo_enc` (:342-353), `lfo_alt_enc` (:358-373), `lfo_alt_hold` (:419-427), header :2-16, layout states :450-510 (6 `params:set(... "dest")` sites, `destination_labeled`, `widest`).

**lib/pages/mod.lua**: only the render state `engine_lfos` (:1262-1276, one site :1267). The `L1`-`L6` rows already draw `S.lib.lfos.describe(n)` and need no change; the routing view, learn and the rings stay on R1-R16 (`MATRIX_SLOTS` loops :110, :715, :896, :1154, :1230).

**lib/io/crow.lua**: one site, the render state "an output marked ~" (:684-691): `params:set(S.lib.lfos.param_id(1, "dest"), index)` → `S.lib.matrix.set_home(1, destination.key)`. :635 (`is_engine_run`) unchanged.

**Unchanged readers** (answers kept): `lib/pages/main.lua:139-140` (`destination(n).fast`, `engine_playing`), `lib/io/midi_out.lua:747`, `lib/arc/lfo.lua` (depth and rate only), `lib/arc/mod.lua` (R only), `lib/envelopes.lua` (k 1..16, source `env<v>`), `lib/expression.lua:326` (`with_lfo_offsets`).

**Tests** (sites of `params:set(<dest param>, ...)`: 80 in 13 files; `hold_lfo(` calls: lfos_test 20, matrix_test 4):
- lfos_test.lua: 41 sets, 20 `hold_lfo`, 6 gets of the param, `local_value("lfo_last_dest")` in 2+ tests; 39 of 56 tests touch it.
- pages_lfo_test.lua: 20 sets, 9 gets; 14 of 23 tests.
- matrix_test.lua: 2 sets + helpers `destination_index`/`hold_lfo` (:91-104, :332), and the file tests (:972, :1085, :1196-1200).
- engine_sync_test.lua: 2 sets (:762, :893) and two direct writes of `S.lfo_last_dest`/`S.lfo_scaled` (:410-413, :452-455).
- registries_test.lua 2 sets + the option list and `S.LFO_DESTINATIONS[params:get(...)]` (:367-400); macros_test 3 (:324, :384, :444) + `strata_lfo1_dest` in a target list (:132); pages_main_test 3 (:817, :825, :856); io_crow_test 2 (:585-586); scenes_test (:1344-1393, 9 refs); system_37_test (:228, :295, :347-349); structure_test MODULE_HOMES (:411); io_controllers_test (:301), voice_mix_test (:112), history_test (:140), variation_test (:477), pages_mod_test (:169): 1 each.
- side_files_test.lua (floor tests added); the data_files figure in random_sequences_test.lua:394-395 (asserts exactly 7474) and matrix_test's 16-full-scenes test (:1374-1440).
- fixtures: test/fixtures/3.6.0-files.lua has 18 dest lines (data, keep). 1a's new format 9 fixture must be regenerated if it was written while the six blocks existed.

**Notes and docs**: `docs/notes/lua/lfos.md` (lines 3, 4, 7-9, 13, 14, 18, 19, 22, 31-33, 47, 52-53, 90, 92, 94-96, 101, 106 and 114 are false or change), `matrix.md` (4, 7, 9, 10, 16, 17, 26-28, 40-42, 56-59, 63), `macros.md:12`, `engine-sync.md` (33, 37, 55, 63; 16 stays), `data-files.md` (6, 51-52, 61: the spec's `floor`), `pages/lfo.md` (9, 18); `pages/mod.md:34` unchanged. User pages: `docs/user/pages/lfo.md` (7, 10, 11, 13: the destination is no menu param now), `docs/user/modulation.md:42` (add a from-3.7 note: a 3.7 PSET's LFOs load aimed at nothing) and :92 (the side file holds the LFOs' destinations too). A `changes/<branch>.md` fragment.

**AGENTS.md lines made false**:
- :247 "one on a fast destination runs in the engine (...), every other in Lua through `S.lib.lfos.mark_due` (at most 12 sends a step, each inside `deferrable`)". Proposed (48 words, the same count as today): "- **LFOs**: one 48 Hz clock (`S.lfo_clock`) steps the six in index order; an LFO's destination is its home routing, the matrix's slot 16 + n: its engine node plays a fast one (`setFastLfo`, `stopFastLfo`, `syncFastLfo`), the matrix any other; a modulation input reads lower-numbered LFOs only. `docs/notes/lua/lfos.md`"
- :260 "an envelope's fast routing is `S.lib.envelopes`' (`owns`), left out of the sum" (12 words) → "an owned routing (`S.lib.envelopes.owns`, `S.lib.lfos.owns`) is left out of the sum" (11).
- :238, :250 and :259 stay true.

## 2. Names

**Removed**: params `strata_lfo<n>_dest`, `strata_lfo<n>_dest_key` (12); scene blocks `strata_lfo<n>_dest_key` (6); `S.lfo_last_dest`, `S.lfo_scaled` (engine_sync.lua:54-55, reached by `local_value("lfo_last_dest")` in lfos_test); global `restore_lfo_destination(n)` (lfos.lua:436; in MODULE_HOMES, structure_test.lua:411, so that line becomes `{ "lfo_destination_id", "add_lfo_params" }`); locals `step_lua` and `send_destination`.

**Kept, same name and answer, now reading the home**: `S.lib.lfos.destination(n)` (the `S.LFO_DESTINATIONS` entry whose key is `S.matrix[16 + n].dest`; the `none` entry for `""` or an unknown key), global `lfo_destination_id(n)` (`destination(n).resolve()`), `is_engine_run(n)`, `engine_playing(n)`, `label(n)`, `describe(n)`, `capped(n)`, `effective_rate(n)`.

**Added to lib/lfos.lua** (proposed):
- `M.destination_index(n)`: the index of the home's entry in `S.LFO_DESTINATIONS` (1 for none or unknown). Needs a key → index map rebuilt in `build_destinations` (:150-158).
- `M.destination_id(index)`: the matrix id of entry `index` (`""` for none, else its `key`).
- `M.home_m(n)`: `state[n].value * state[n].depth / 100 + 2 * params:get(offset) / 100` (today's `S.lfo_scaled`, :523) while `is_on(n)` and `params:get(depth) > 0`, else nil. `state[n].depth` is depth' (the modulated depth), as today.
- `M.owns(n, id)`: true when LFO n's home routing to `id` is the LFO module's to play: `(destination(n).fast ~= nil and destination(n).resolve() == id) or direct.known[id] == true`; false for an n outside 1..NUM_LFOS or a nil id. True whatever the on/off and depth (as `envelopes.owns` is about kind); the matrix asks only for a playing home. A `v<i> main` entry is never fast (it has no `fast` field, :133-134), so a home on a buffer voice's main is not owned (see Risks 1).
- `M.home_changed(n)`: what the old destination action did. It releases a direct destination the LFO held when the new one differs, then calls `settings_changed(n, false)` (:818, which only marks during a recall).
- `M.modulates(id)`: whether an LFO holds direct destination `id` now (for the macros' `modulated`).
- `M.direct_value(id)`: `util.clamp(params:get(id) + Σ offset_for(id, home_m(n)), param_range(id))` over the LFOs holding `id`. This replaces `with_lfo_offsets(macro_id, ...)`: a macro param has no override, extra or factor.
- Locals: `direct.held[n]` (the direct id LFO n holds, replacing `S.lfo_last_dest` for macros only); `step_direct(n)` (replaces `step_lua`: re-resolve, release on change or depth 0, mark `direct.due[id]`); `release_direct(n)` (the direct half of today's restore, `send_direct(id, true)`).

**Added to lib/matrix.lua** (proposed; no new constant in lib/constants.lua, so the constants list at AGENTS.md :305 is untouched):
- locals `HOMES = S.constants.NUM_LFOS`, `ROUTINGS = MATRIX_SLOTS + HOMES` (22), `is_slot(k)` (1..ROUTINGS), `home_slot(n)` = `MATRIX_SLOTS + n`; `M.home_slot(n)` public.
- `MATRIX.data_version = 2`, `MATRIX.data_floor = 1`.
- `S.matrix[16 + n] = {source = "lfo" .. n, dest = ""}` at include (the source is fixed, never `""`).
- `M.home(n)`: the home's destination id (`""` for none), nil for a bad n.
- `M.set_home(n, dest_id)`: text of at most 32 characters, unknown ids kept (recall, morph's switch, PSET, a transition's midpoint). It saves the live file, redraws and calls `S.lib.lfos.home_changed(n)`. Returns whether it set the home.
- `M.edit_home(n, dest_id)`: `""`, a known home id, or the one held; then `set_home`. No 25 % rule (design §4). Returns whether it set the home.
- `home_known(id)`: an `S.LFO_DESTINATIONS` key other than `none`, macros included (`MATRIX.never` does not apply to homes).

**Changed**: the `read_routing` loop gains `read_home(n)` (label `matrix home <n>`, contained); `idle()` loops to ROUTINGS (a home with dest `""` stays idle); `sparse()`, `block_problem` (keys 1..22; a home's `source` must equal `lfo<n>`), `stored_routing`, `load_block` (homes forced to source `lfo<n>`), `report_unknown` (for homes: "LFO <n>'s destination <id> is unknown here; kept, and it does not play") and `through_zero` (to 22). `M.routing`, `set_routing`, `edit_routing`, `clear`, `playing`, `learn`, `uses_source` and `affects` keep 1..16, so the `R` mark (`uses_source`) and MAIN's `~` (`affects`) keep their answers.

**lib/engine_sync.lua**: `with_lfo_offsets` keeps its name (11 call sites in lib, 8 test references). The offsets it adds still come from LFOs, through the matrix and the macros' LFO extras. It becomes: the override, then Σ extra offsets clamped once, then `factored`. No caller changes.

**lib/side_files.lua**: an optional `spec.floor` (a number no higher than `version`; `check` raises otherwise: "side_files.new: a floor is a number no higher than the version"). `read` accepts `floor <= loaded.version <= version`, with `floor` defaulting to `version`. Its why stays `not a version <version> <name> file` without a floor and becomes `not a version <floor>-<version> <name> file` with one. Optional: pass `loaded.version` as `load`'s fourth and `validate`'s second argument (4a's scenes may want it; the matrix does not).

**Stored shapes**: the file is `{version = 2, matrix = {[k] = {source, dest}, ...}}`, k 1..22, sparse (a home is written only when its dest is not `""`, as `{source = "lfo<n>", dest = <id>}`). The scene block `matrix` holds the same sparse table. A version 1 file has keys 1..16 only and loads with every home `""`.

**Late binding**: lfos (include line 57) comes before matrix (87), macros (80) and delay_sync (108). Every `S.lib.matrix.*` call in lfos.lua is inside a function that runs after include (`destination_of`, the callers of `home_changed`, the step). Nothing in lfos.lua's include-time code (`build_destinations`, `state`, the senders loop, `SCENE_FIELDS`, the sources loop) reads a home. Calls from matrix to `S.lib.lfos.*` are safe either way. macros calls `S.lib.lfos.modulates` and `direct_value` at step time.

## 3. Order and seams

**The step** (`step_all`, lfos.lua:706-724) runs the six LFOs, then the direct destinations, then the hooks (macros :278, the matrix :408, delay_sync :112, the notes' flush), then the drain. Today a Lua home is marked due in `step_lfo` (:534); after the change it is marked in the matrix hook. That is the same step, before the drain, so the send leaves in the same step with the same value: `send_lua` computes `with_lfo_offsets` at drain time, as `send_destination` did, and `offset_for(id, m)` equals the LFO term `m × half range`. The R routings' m and the home's m are summed first, then clamped once. The macro path keeps its place: `step_direct` marks in the LFO's step, `send_direct` runs after the six, and the macros' hook reads `direct_value`.

**What changes by a step or a send** (the design says only "everything else sounds as before"):
1. A restore of a Lua destination (off, depth 0, new destination, `main` re-resolving) was sent at once from the action or step, outside the round robin (lfos.md:9: "Restores are always sent, at once"). Now the matrix's next step gives the extra up and marks the key once, through the round robin and the budget: at most 1/48 s later, and it may wait for a window. Direct (macro) restores stay immediate.
2. A home whose m is exactly 0 (the case in lfos_test :1419) holds no extra, so its end sends nothing (the engine already has the stored value).
3. A voice start and sync carry the home's offset at once. `start_value` (engine_sync.lua:480-487) and `resend_modulated_voice_params` (:497-513) read `extra_offsets`, and an LFO's term never was one. Today the start sends the stored value and the next step the modulated one (lfos.md:7; lfos_test :306 (#644) and :1501 (#50) pin it).
4. The round robin's key order is first-mark order (lfos.lua:378-384). Homes are now marked in the matrix's sorted id order, not LFO index order, so under a full round robin the keys that go first can differ.
5. A 3.6 PSET's `strata_lfo<n>_dest: N` transient (lfos.md:19, docs/decisions/3.7.md:107) disappears: norns' `ParamSet:read` silently skips a line whose id has no param (`~/src/norns/lua/core/paramset.lua:549-551`).

**What replaces `restore_lfo_destination`** at each call site:
- on/off action, off (:806): `release_direct(n)`; a Lua destination is restored by the matrix's next step.
- depth action at 0 (:905): the same.
- destination action (:877): `home_changed(n)`, called from `set_home`.
- `step_lua`'s re-resolve (:520): `step_direct` for macros, the matrix for Lua destinations.
- `step_lfo` when off or turned fast (:662, :694): `release_direct`.
- cleanup (:777): `release_direct` only. The matrix's cleanup step 118 already forgets its extras and sends nothing.

**Scenes and morph**:
- Blocks apply before the globals. The matrix block sets the homes with no action, and the LFO's settings only mark (`settings_changed` under `S.scene_recall_in_progress`). The on/off, applied last, reconciles once with the home in place, as the old silent block did.
- `through_zero` for home k names `{id = "strata_lfo<n>_depth", switch = function() M.set_home(n, b.dest) end}` when `a.dest ~= b.dest`. `strata_lfo<n>_depth` is a continuous global field (`lfo = n`, `stop_target = 0`, lfos.lua:952), so it is among `scene_transition_targets`' ids and `through_zero_switches` marks it (scenes.lua:648-660).
- With `transition_stops` true the depth's target is 0, so the ramp reaches 0 at the midpoint and stays there; the switch is harmless.
- At depth 0 an engine LFO stops at the next step and the matrix gives a Lua extra up. Past the midpoint, `home_changed` and the rising depth start the new one: there is still one node per LFO, since `setFastLfo` moves or replaces it.
- Morph (morph.lua:113-135) reads `through_zero` generically, so its switch at 0.52 and 0.48 works for homes unchanged.

**Silent PSET read**: the side file's `load` runs after the params (`files.pset_hook(nil, routings_changed)`) and sets the homes with no action. The next step converges: the engine through `reconcile_engine`, which compares voice and destination; a direct destination through `step_direct`'s compare; a Lua one through the matrix.

**Seams with other packages**:
- 2b needs 1a: format 9, its edits to engine_sync and data_files, and the scenes table count re-measured first.
- 2a, in the same wave, owns `lib/params_setup.lua`, `lib/state.lua` and `lib/voices.lua`. 2b needs none of them (`add_lfo_params` keeps its name, `S.register_lfo_destination` stays).
- Shared tests: registries_test (2a too), scenes_test and system_37_test (1a).
- 1a's "every param's id, default and spec against 3.7.0" list must drop the twelve ids; 2b re-bases it.
- 3a and 3c need `set_home`.
- Rules kept: matrix.md's "fast destinations only through setFastOffset" (a home on a resolved fast param that the LFO does not own goes there), "never sets a destination param", and engine-sync.md:16's "Action sends always go out".

## 4. Tests

**Delete** (the behavior is gone): the index-from-an-older-release half of lfos_test "a key the build does not know reads as none", and the block half of scenes_test "scenes capture and recall the LFOs" (:1377-1389: the dest-key block record and its validation).

**Re-base, mechanical**: replace `params:set(<dest>, destination_index(label))` with a helper `aim(n, label)` = `S.lib.matrix.set_home(n, S.lib.lfos.destination_id(destination_index(label)))`; `hold_lfo` in lfos_test :38 and matrix_test :100 uses it. These are the 80 sets listed in §1.

**Re-base, behavior**:
- lfos_test :730 "stored by key in a PSET and in a scene": now stored in `<pset>.matrix.data` (version 2, key 18 for LFO 2) and in the scene's `matrix` block.
- lfos_test :755: an unknown home is kept, not played and named once (at each file load; for a scene, once a session).
- lfos_test :306 (#644) and :1501 (#50): the start sends the modulated density.
- lfos_test :1375, :1419, :1540: restores come at the next step, once; :1419's m = 0 sends nothing.
- lfos_test :1457 "main follows the source": `lfo_last_dest` becomes `S.lib.matrix.offset`; a buffer voice's main now reaches `setFastOffset` on destination 1 (Risks 1).
- lfos_test :1606 (#517): a raising `resolve` of a Lua home now prints `strata: matrix home 1 failed:`.
- lfos_test :1652 cleanup: its asserts are unchanged. :855 (SOUND_BEFORE_3_7, which sets `dest_key` directly) uses `set_home(1, key)` and keeps the same trace strings.
- engine_sync_test :410 and :452: write `set_extra_offset("test", ...)` instead of `S.lfo_*`.
- registries_test :349-400: labels from `S.LFO_DESTINATIONS`, the landing via `destination(1).label`.
- matrix_test :1196-1200: "another version" becomes version 3 and "no routing 17" becomes 23; add "a home whose source is not lfo<n>". :1085 expects version 2. The 16-full-scenes test sets the six homes too, asserts `entry_count(scene.data.matrix) == 22` and the new figure; the exact figure in random_sequences_test :394-395 follows it.
- system_37_test :347-349: the 3.6 PSET's `strata_lfo<n>_dest` lines join the no-param branch (add them to `PSET_3_6.drops`, or a branch asserting `S.lib.matrix.home(n) == ""`). Its version 1 `.matrix.data` loads through the floor, so routing 1 (asserted at :71-72) still holds. :228 and :295 go with 1a's rewrite.
- pages_lfo_test: E3, ALT+E3 and the ALT+K2 hold on the dest field.
- structure_test :411 MODULE_HOMES.

**New** (design §11, "Home routings"):
1. matrix_test "a home routing to a Lua destination is summed by the matrix: one setFilter a step": home `filter_mix`, square held high, depth 40, stored 0.5 → `setFilter` mix 0.5 + 0.4 × 0.5; `matrix.offset("filter_mix")` 0.2; no `setFastLfo`; over two steps, one send each.
2. matrix_test "a home routing to a fast destination is the LFO's engine node": home `v3_grain_pitch` → one `setFastLfo(0, 2, 0, ...)` and no `setFastOffset` on `matrix fast 3 0`; `lfos.owns(1, "v3_grain_pitch")` true; `matrix.offset` 0.
3. matrix_test "a home routing to a macro is handed over by the LFO, never summed": home `macro_1` with a target on `reverb_mix`; `owns(1, "macro_1")` true; the target moves, and `budget_state().sent` does not count the macro itself.
4. matrix_test "a home and an R routing on one param sum and clamp once": home on `filter_mix` at +100 % held high, R1 from `macro16` at −100 % with the macro at 1 → the mix stays at the stored value, one send.
5. lfos_test "the rate ceiling follows the home routing": rate 30 Hz; home `v1_grain_pitch` → `effective_rate(1)` 30; `edit_home(1, "filter_mix")` → 10 and `capped(1)` true; `edit_home(1, "")` → 10.
6. matrix_test "a version 1 matrix file loads with no home routing": a live file and a side file `{version = 1, matrix = {[1] = {...}}}` load R1 with every `home(n) == ""`; a version 3 file is set aside with its line. side_files_test "a file from its floor to its version loads; one below or above is set aside" and "a floor above the version is refused".
7. matrix_test "a home whose destination differs between two scenes ramps the LFO's depth through 0": depth 60 → 40, home `filter_mix` → `reverb_mix`. At f 0.25 the depth is 30 and the home still `filter_mix`; at f 0.5 the switch; at 0.75 depth 20 on `reverb_mix`. Morph switches at 0.52 and 0.48.
8. matrix_test "edit_home refuses an unknown id; set_home keeps one, which does not play", and "the block refuses a home whose source is not lfo<n>".
9. lfos_test "a 3.7 PSET's destination lines read as nothing": a PSET with `"strata_lfo1_dest": 14` and `"strata_lfo1_dest_key": v3_grain_pitch` and no side file loads with no error and `home(1) == ""`.
10. pages_lfo_test "E3 on dest steps the home; ALT+E3 jumps a group; ALT+K2 held sets none" (checks `home(1)` and `label(1)`'s `~`).
11. data_files: the figure 1a measures, plus 96, asserted in matrix_test.

## 5. Risks and open points

1. **`v<i> main` on a buffer or input voice** (the design is silent).
   - It resolves to `buf_pos` or `grain_size` (lib/pages/main.lua:98-108, lib/constants.lua:160-161), which are fast params. The entry has no `fast` (lfos.lua:132-134), so today the LFO runs in Lua and sends `setGrainParam bufPos` with a Lua offset (lfos_test :1467).
   - The matrix never gives a fast param a Lua offset (matrix.md:5), so a home it does not own lands in `fast_sums` and goes out as `setFastOffset` on the offset node (50 ms lag), at a 10 Hz ceiling. The scale matches (half ranges 0.5 and 0.245), but the command and the lag change.
   - Recommended: accept the matrix's rule and name it in the plan; R routings to `v<i>_main` already work this way (matrix.md:36). The alternative, the LFO owning it, keeps a Lua send that the design removes.
   - Unsure: whether the engine lags bufPos today (not checked).
2. **Two timing changes** (§3, 1-3): restores arrive one step later through the round robin, and a voice start carries the offset. Neither is in the design's "what a player notices"; both need plan rulings and notes.
3. **MIDI maps**: a 3.7 `.pmap` entry for `strata_lfo<n>_dest` stays in `norns.pmap.data`. Its CC then reaches `params:t(r)` → `lookup_param` → `error("invalid paramset index")` in norns' `menu_midi_event` (`~/src/norns/lua/core/menu/params.lua:726-729`, `paramset.lua:485-492`). The design's constraint covers MIDI maps only for ids that survive. Options: a note in the changelog and the user page, or a start step that removes these ids from `norns.pmap` (`pmap.remove`). Unsure whether norns catches that error.
4. **An unknown home's label**: `label(n)` shows `none` (the `none` entry) while the key is kept; E3 from it steps from index 1 and replaces it. The design says only "kept and not played"; what the page shows is open.
5. **E3 on the dest row no longer touches a param**: `delta_with_detent` fired `param_touch`, so during matrix learn, turning an LFO's destination flashed `not a destination`. Now learn keeps waiting. Base overrides are unaffected (no LFO param holds one).
6. **lib/pages/mod.lua** is in 2b's list but needs only the render state edit; "MOD's L1-L6 rows are the home routings" is already true through `describe`.
7. **lib/macros.lua**: `direct_destination` stays; the macros' own reads of the old state are only :255 and :281.
8. 1a's format 9 fixture and its param-spec list are re-based by 2b if they include the six blocks or the twelve params.
9. Local counts: lfos.lua loses about 4 locals and gains 3; matrix.lua gains about 5. Not measured against the test's 30 free locals; unsure, but unlikely to bind.

# Package 3c's #741

## 1. Files

`lib/delay_sync.lua` (:84-94 `sent`, :129-133 the sync action), one line in `lib/matrix.lua`'s `update_lua` (about :348 after 2b), `test/unit/delay_sync_test.lua`, `docs/notes/lua/delay-sync.md` and `docs/notes/lua/matrix.md`.

**Where it happens today**:
1. A Lua LFO's step (lfos.lua:528-534) or the matrix's (`update_lua` → `lua_moved` → `mark_lua`, matrix.lua:284-289, :341-354) marks `delay_time` due when its modulated value moved past 1/1000.
2. The drain (lfos.lua:387-404) takes a slot and runs `send_engine_value("delay_time", ...)`.
3. `deliver` (engine_sync.lua:193-205) counts a budget message and calls `S.engine_senders.delay_time`, which is `send_delay_to_engine` (:529-538, :561).
4. That sends `setDelay(S.lib.delay_sync.time(), ...)` with the synced time, unchanged.

After 2b every LFO and matrix send of `delay_time` goes through `update_lua`. An LFO on a macro whose target is `delay_time` (macros.lua:236) also sends each step. The issue names only LFO and matrix sends, so leaving the macro path alone is the smallest fix.

## 2. Names

- `S.lib.delay_sync.time_unheard()` (new) is true when all of these hold:
  - the delay is synced at a finite division (`synced_time()` is not nil);
  - the time last sent equals `M.time()`;
  - `engine_param_value` of `delay_feedback`, `delay_mix` and `delay_pingpong` equal the values captured at the last send.
- `M.sent(time)` (:87) also records those three (their `engine_param_value` at that moment, which are the values `send_delay_to_engine` just sent). Its signature is unchanged, so `lib/engine_sync.lua:537` is not edited.
- matrix `update_lua`: `if lua_moved(id) and not (id == "delay_time" and S.lib.delay_sync.time_unheard()) then mark_lua(id) end`. The extra offset is still set, and a sum returning to 0 still sends once.
- The sync action (:130-133): turning sync off sends `send_param_to_engine("delay_time", params:get("delay_time"))` instead of `("delay_sync", x)`. That way the setDelay that ends sync carries the time with its current offsets. Otherwise it carries `engine_param_value("delay_time")`, the last delivered value, which is stale for one step after a run of skipped sends. Turning sync on is unchanged.

Why not fix it in `engine_messages` (as a send that reaches no engine): the drain counts its slot before it enters `deferrable` (lfos.lua:398-399), so a check meant to pass only modulation sends cannot tell them apart there. A check on every send would dedupe action sends, against engine-sync.md:16.

## 3. Order and seams

#741's fix needs 2b (`set_home`, and the matrix as the one modulation path). The design gives 3c only `lib/scan.lua` and `lib/delay_sync.lua`, so the matrix line edits 2b's file in wave 3. No other wave-3 package owns lib/matrix.lua (3a: sequencer, scenes, chance, actions; 3b: midi_in, params_setup), so there is no same-wave conflict, but the plan should list the file. Include order: delay_sync (108) comes after matrix (87), and the matrix calls it at step time.

## 4. Tests

New in delay_sync_test.lua:
- "a synced delay under a 5 Hz LFO on delay_time sends no setDelay and takes no slot (#741)": 120 BPM, 1/8D, sync on, one step; `set_home(1, "delay_time")`, sine at 5 Hz, depth 100, on; clear; 48 steps → 0 `setDelay`. With 12 probe keys marked each step (lfos_test's `probe_key`), all 12 run every step.
- The same with an R routing (`set_routing(1, "lfo1", "delay_time")`, depth 100, the LFO with no home).
- "a feedback edit under it sends one setDelay with the synced time": `params:set("delay_feedback", 0.5)` → one call, args 0.375 and 0.5.
- "sync off sends the modulated time at once": one `setDelay` whose time equals `with_lfo_offsets("delay_time", params:get("delay_time"))`; the next steps send the moving time.
- "a tempo move under it still resends within a step" (the step hook's `delay sync` key is untouched).

The existing test at :150, "a synced delay ignores delay_time and its modulation", passes as written, because its sends are actions.

## 5. Risks

- `time_unheard` compares the time exactly (the same computation from the same tempo). A tempo move makes it false until the step hook resends, so the next modulation send carries the new time, which is right.
- After a run of skipped sends, `S.engine_param_values.delay_time` holds the last delivered value. Only the sync-off send reads it, and the action change covers that. No other reader of `engine_param_value("delay_time")` exists in lib/ besides `delay_sync.time()`'s unsynced branch (checked).
