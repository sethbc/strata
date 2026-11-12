## Must not break

- **A macro never targets a macro or the morph** (`macro_<m>`, `morph`, `morph_a`, `morph_b`), nor a discrete or non-control param: `target_ids()` is the only list of targets, `set_target` refuses any other id and learn flashes `not a macro target` for it. So no macro can start a loop (design §4.2; the plan's "Feedback loops are impossible by construction").
- **Scenes, a transition and morph set a macro silently**: the scene field `macro_<m>`'s own `set` is `set_silently(m, v)` (`params:set(id, v, true)`, and a waiting apply of that macro is dropped), which `S.lib.scenes.set_value` (a recall, a fade step, morph) calls in place of `params:set`. The scene already holds every target's own value, so the targets never follow the macro there. Only a hand move (encoder, arc, grid fader), a MIDI CC, a gesture recorder's playback and a PSET read run the macro's action; the PSET hook then drops what that read set waiting.
- **One clock for all sixteen** (`S.macro_clock`): a macro's action only marks it pending and starts the clock if none runs; the clock sleeps 0 (its first apply is on the next tick, so a PSET hook can cancel it), then applies each pending macro once `1 / MACROS.apply_hz` (1/30 s) has passed since its last apply, sleeping to the next one due, and ends when none waits. Never one clock per macro. The `macro apply` invariant: a macro waits exactly while the clock runs, and its coroutine is not dead.
- **Every apply's fan-out is deferrable**: the targets are set inside one `S.lib.engine_sync.deferrable(fn)` (`fn` never yields), so the macros' demand can only delay their targets' sends, never exceed `ENGINE_BUDGET` (150 per 100 ms). The macro param, each target's stored value, the screen and the grid change at once.
- **An apply is `params:set(id, spec:map(min + v × (max − min)))`** for each row whose id this version knows, `v<i>_main` resolved through `main_param_id(i)` at the apply (it follows the voice's source). A row with an unknown id, or an empty one, is skipped; a macro with no target does nothing.
- **An LFO on a macro moves engine values, never a param**: `S.engine_senders["macro_<m>"]` gets the macro as the LFO modulates it; for each target it takes the difference between the target at that value and at the stored macro value, as `set_extra_offset("macro<m>", id, difference)` on a Lua target or `S.lib.matrix.set_fast_extra("macro<m>", id, S.lib.lfos.m_for(id, at_stored, at_value))` on a fast one (one of `S.lib.lfos.FAST_DESTINATIONS`), each sent through `S.lib.lfos.mark_due` (a Lua target's key is its param id, so it shares the LFOs' send of that param). **It skips LFO-param and matrix-depth targets** (`strata_lfo<n>_rate`, `strata_lfo<n>_depth`, `matrix_<k>_depth`): they follow only the macro's own value. The stored value itself clears every extra (the LFO's restore sends it). Without a matrix (`S.lib.matrix` nil, before package 1h) a fast target does nothing.
- **Every extra goes when its row changes**: a new target for a row, a load of the targets (live file, PSET, scene block) and a main entry that resolves to another param clear the row's extra first (its target sent again through the round robin), so no old id keeps an offset.
- **The PSET hook's read drops every waiting apply, then loads the targets**: norns' `params:read` runs every param's action (the macros' among them) before `action_read`, so an apply would use the old targets and overwrite the PSET's own target values. Its write always writes the side file, an empty one too, so a PSET saved over never keeps an older side file; its delete removes it.
- **Files** go through `S.lib.data_files` only (`write`, `read`, `set_aside`): a missing side file loads no targets (a PSET from before 3.4), an unreadable or invalid one is set aside (`<file>.bak`, ...) with a console line and loads none, and the PSET still loads. An unknown id is kept verbatim, with a console line at each file load, saved again as it was, and does nothing (no apply, no LFO extra, no bank mark).
- **Sparse storage**: the scene block `macros`, the side file and the live file hold `[m][k] = {id, min, max}` for rows with an id only (an empty table when there is none). 16 scenes of 16 full macros keep scenes.data inside `lib/data_files.lua`'s `max_tables` (8192): the test writes one (3410 tables, 464 KB with 3.4's other blocks so far).
- The shown bank is session state, a view only: `set_bank` moves no macro and sends nothing; every surface reads `bank()` and `bank_macros(b)`, never 4b − 3 itself.
- **Learn** waits exactly while its timeout clock runs (`S.macro_learn_clock`, the `macro learn` invariant), `MACROS.learn_seconds` (10 s), and cancel_learn ends both.

## Owns

`lib/macros.lua` (`S.lib.macros`, 3.4, package 1e, design §4):
- `add_params()`: the group `strata_macros` ("macros", `NUM_MACROS` 16) with `macro_1` .. `macro_16` (control 0-1, step 0, default 0, shown in whole percents). `lib/params_setup.lua`'s menu record `macros` calls it, after the LFOs.
- `S.macros[m].targets[k] = {id, min, max}` (`MACRO_TARGETS` 8 rows; `id` a param id, `v<i>_main`, or `""` for an empty row; `min` and `max` fractions 0-1 of the target's range along its warp, `min` above `max` inverting).
- `target_ids()`, `target_label(id)`, `targets(m)` (a copy), `set_target(m, k, id, min, max)` (returns whether it set the row; the live file follows), `apply(m)` (now, for code), `set_silently(m, v)`, `learn(m, k)`, `learning()` (the macro and row, or nil), `cancel_learn()`, `bank()`, `set_bank(b)`, `bank_macros(b)`, `bank_has_targets(b)`.
- `MACROS`, the module's one table of tunables and names (`apply_hz` 30, `learn_seconds` 10, `save_delay` 0.1, `banks` 4, the files' version and suffixes, the never-target ids, the LFO skip patterns).
- `S.macro_clock`, `S.macro_learn_clock`, `S.macro_save_clock`; the engine senders `macro_1` .. `macro_16`; the touch hook (learn); the scene fields `macro_<m>` and the scene block `macros`; the global LFO destinations `macro 1` .. `macro 16` (104-119, the group `registered globals`); the sources `macro1` .. `macro16`; the PSET hook `macros`; the start step `macros_load` (105), the cleanup steps `macros_save` (32) and `macros` (114); the invariants `macro apply` and `macro learn`.

Elsewhere: the MOD page and its rings (package 2a) draw and edit the macros through these functions, and open the target view themselves; the grids' bank keys and macro faders are package 2c's; `S.lib.matrix.set_fast_extra` is package 1h's.

## Targets

`target_ids()`, in this order, only ids whose params exist now (the list is rebuilt when params are added):
- every LFO destination (`S.LFO_DESTINATIONS`) but `none` and the global entries whose param is a macro: the built-in ones (a voice's `main` as `v<i>_main`), then the registered ones (`hist`, `vfilt`, `dsend`, `rsend`, `amp` per voice), 102 in all;
- each LFO's `strata_lfo<n>_rate` and `strata_lfo<n>_depth` (n 1-6);
- each routing's `matrix_<k>_depth` (k 1-16), once package 1h adds them.

`target_label(id)` is the LFO destination's label (`v3 pitch`, `rev mix`, `v3 main`), `L<n> rate` or `L<n> depth`, `R<k> depth`, or the id itself when unknown.

## Applying

- The action of `macro_<m>` marks it pending and starts the clock (above). An apply reads the stored macro value and sets each known row's resolved param, inside `deferrable`; the targets' actions send, note their edit (a held param ends the randomize undo) and request redraws. An apply that raises prints `strata: macro <m> apply failed:` once (`contained_call`), and the clock and the other macros go on.
- 100 hand moves of one macro over 1 s apply about 30 times, the last value applied; sixteen moving macros share the one clock. Sixteen full macros (128 targets) each set 30 times a second stay inside the budget, and every target's last value reaches the engine within a few windows.
- `set_silently(m, v)` drops macro m's waiting apply, and the clock stops when none is left. A recall's block applies first (blocks lead `scene_entries`), then the macro values silently, then every target's own value.

## Learn

`learn(m, k)` (MOD's ALT+K3 in the target view, package 2a) arms row k; the next param a hand touches (the `param_touch` registry: an encoder, an arc ring, a grid fader) that is a target becomes the row's id with min 0 and max 1, and the header flashes `M<m> > <label>` (`M12 > v3 pitch`). A touched voice's main param that is no target itself learns `v<i>_main`. Any other touched param flashes `not a macro target`, and learn waits on. `cancel_learn()` (MOD's K2 and page change), a new `learn` or 10 s without a touch ends it.

## Banks

`bank()` (1-4, 1 at the start), `set_bank(b)` (flashes `macros 5-8`, `request_redraw()`, `grid_redraw()`; a number that is no bank is ignored), `bank_macros(b)` ({4b − 3 .. 4b}), `bank_has_targets(b)` (a macro of the bank has a row whose id this version knows). The sources `macro<m>` are visible only in the shown bank.

## Sources

`macro1` .. `macro16` (`S.register_mod_source`): name `M<m>`, section `macros`, range 0..1, `value` the param, `describe` the first target's label and how many more (`rev mix +2`; `-` without one), visible in the shown bank; `row`: E3 the value (`enc_param_delta`), fine E3 (`delta_with_detent` with `fine`), hints `K3:targets E3:value` (none with ALT). The row has no `press`: MOD opens its target view on K3 itself.

## Storage

- Scenes: the block `macros` (`register_scene_block`, discrete: a fade applies it at its end, before the macro values; its `default` is `{}`, which a scene from before 3.4 gets; its `validate` refuses a macro outside 1-16, a row outside 1-8, an empty or non-string id or a min or max outside 0-1). Its apply loads the targets and saves the live file; the recall redraws. The values are the scene fields `macro_<m>` (continuous, default 0, range-checked by `validate_scene` as every registered continuous field).
- PSETs: the values are params; the targets are `<path_base>.macros.data` (`{version = 1, macros = <sparse>}`), written, read and deleted by the PSET hook `macros`.
- The live file data/strata/macros.data (the same layout): loaded at the start step `macros_load` (a missing file loads no targets), and, once that step has run, written `MACROS.save_delay` (0.1 s) after the targets change (`set_target`, learn, a PSET load, a scene's block), one write per burst carrying the newest targets (`S.macro_save_clock`; MOD's E3 sets a row a detent), and at once at the cleanup step `macros_save`, which cancels that clock first.

## Tests

`test/unit/macros_test.lua`: the params; an apply between min and max (inverted, along an exponential warp, a main entry following its source); the target ids (none of the macros, morph or discrete params; the order and count); one clock at 30 applies a second; sixteen full macros inside the budget; silent sets by a recall, a fade step and morph; an LFO on a macro (Lua and fast targets, a cleared extra, a real LFO on `macro 1`) and its skipped LFO-param targets; the PSET read dropping a waiting apply; the side file always written and deleted; learn; the shown bank; unknown ids; the three stores round-tripping sparse; one live-file write per burst of edits; a PSET without or with an unreadable side file; 16 scenes of 16 full macros in scenes.data; the destinations and sources. The start and cleanup steps are in `test/unit/structure_test.lua`.
