# Facts: an LFO's own destination beside the matrix

Read-only survey of `main` at 3bb75daa, 2026-11-16. Counts by grep; "unsure" marks what was not established.

## 1. An LFO's own destination today

- Six LFOs, one group each of 14 params (`LFO.group_size`, `lib/lfos.lua:41`): on, `dest` (an `S.lib.io_keyed` option), hidden `dest_key`, shape (8), mode (free/clocked), rate 0.003-50 Hz, division (22), depth 0-100 %, offset -100..100 %, phase, `rate_mod`/`depth_mod` (lower-numbered LFOs only) and their amounts (`docs/notes/lua/lfos.md:47-62`).
- The list (`build_destinations`, `lib/lfos.lua:116-159`): none, 11 globals, then per voice `v<i> main` (resolved each step through `main_param_id`), 7 grain/buffer params, then registered ones (`hist`, `vfilt`, `dsend`, `rsend`, `amp`: 13 a voice), then `macro 1`-`macro 16`. That is 119 entries (`lfos.md:73`). `destination_groups()` drives ALT+E3 (`lib/lfos.lua:168`).
- Storage is by key: PSETs keep `strata_lfo<n>_dest_key`, and scenes a discrete block of that name. A key the list lacks reads as none and is kept. Indices from before 3.7 read as none (`lfos.md:19`, `lib/lfos.lua:869-872, 964-984`).
- Lua path: one 48 Hz clock steps all six in index order (`lfos.md:5`). A Lua-run LFO offsets around the stored value through `S.lfo_last_dest`/`S.lfo_scaled`, which `with_lfo_offsets` sums (`lib/engine_sync.lua:54-99`). Sends go through `mark_due` (`lib/lfos.lua:378`), at most 12 a step shared with the matrix, keyed by param id (`lfos.md:6`). Lua rate ceiling: 10 Hz (`lib/lfos.lua:39, 329`).
- Engine path: an entry whose param is one of the five fast suffixes (`FAST_DESTINATIONS`, `lib/lfos.lua:57`) runs in the engine. `setFastLfo(n-1, voice-1, destination, shape-1, rate, depth/100, 2×offset/100)`, `syncFastLfo` and `stopFastLfo` are at `lib/lfos.lua:557, 578, 609`. Ceiling 50 Hz. The engine runs one node per LFO, writing one channel (`Out.kr(out, ...)`, `lib/engine/StrataModulation.sc:252-256`). It keeps at most one node per LFO, a releasing one included (`docs/notes/engine/modulation.md`, Must not break). Random shapes draw inside each node (`Dwhite`/`Dbrown`, `StrataModulation.sc:290-292`).
- An LFO's ceiling depends on its own destination: `ceiling = M.is_engine_run(n) and engine_max_hz or lua_max_hz` (`lib/lfos.lua:329`). An LFO with destination none is capped at 10 Hz.
- An LFO can target a macro (`macro <m>`): it moves the macro's targets around their values (`lib/macros.lua:252-256`, `docs/user/modulation.md:50`).

## 2. A matrix routing today

- 16 slots (`MATRIX_SLOTS`). Each has params `matrix_<k>_depth` (-100..100 %) and `matrix_<k>` (on), 32 in all. `S.matrix[k] = {source, dest}` holds strings (`docs/notes/lua/matrix.md:26-27`).
- Sources come from `S.register_mod_source` in their owning modules: `lfo1`-`lfo6` (`lib/lfos.lua:1021`), 16 macros, 4 gestures, input, 16 pressure/slide, 4 random sequences, 7 envelopes and crow's 2 inputs (`lib/io/crow.lua:443`). An LFO already is a matrix source. Its value is `value(n)`, the shape alone before depth and offset (`lfos.md:110`, `docs/user/modulation.md:86`).
- Destinations: `destination_ids()` is the LFO list minus none and the macros. The `never` filter is `{"^macro_%d+$", "^strata_lfo%d+", "^matrix_%d+", "^morph"}` (`lib/matrix.lua:52, 103`), which leaves 102 (`matrix.md:36`). The matrix cannot target a macro or an LFO param, and the LFOs' own destinations can target a macro.
- Offset: `m = depth/100 × normalized(source)`. A Lua destination sums into `set_extra_offset("matrix", id, sum)`. A fast one is sent as `setFastOffset(voice-1, 0, d, sum)` under key `matrix fast <v> <d>`, through `mark_due` and the send budget (`matrix.md:4-6, 40-42`). The engine offset node lags 50 ms (`StrataModulation.sc:271`). So an LFO routed to a fast destination moves at Lua's step rate (24-48 Hz), not in an engine LFO node (`docs/design/3.4-design.md:1006`).
- Storage: depths and on/offs are scene fields and PSET params. The routings are the scene block `matrix`, the PSET side file `<pset>.matrix.data` and `data/strata/matrix.data` (`matrix.md:56-58`).
- MOD's `matrix` section has rows `R1`-`R16`, and K3 opens the routing view (`lib/pages/mod.lua`, 1,432 lines). Arc MOD rings 2 and 3 step a routing's source and destination (`lib/arc/mod.lua:89`).

## 3. 3.7's envelopes and Question 34

- Question 34, `docs/design/3.4-design.md:71`, exactly: "**LFO destinations and macro targets stay as they are; the matrix adds routings beside them, and every layer sums into one offset per destination.** One model (an LFO's destination and a macro's targets becoming matrix routings) would change every LFO and macro PSET id, scene field and editor, mix macros' absolute writes with the matrix's offsets, and lose the rule that an LFO on a fast destination runs in the engine at any rate. Nothing migrates." `revisit.md:132`'s quotation drops "at any rate".
- Envelopes: route k-1 is matrix slot k. `numEnvRoutes { ^16 }` (`StrataEnvelopes.sc:18`) is test-compared with `MATRIX_SLOTS` (`docs/notes/engine/envelopes.md`). A routing from `env<v>` to a fast destination is "owned" (`S.lib.envelopes.owns(k, id)`, `lib/envelopes.lua:202`). It runs as one engine node per route, sent `setFastEnv`/`stopFastEnv` through the round robin (`lib/envelopes.lua:239-242`). The matrix's `read_routing` skips an owned routing (`lib/matrix.lua:331`). One def, one node per route, no node per hit.
- The pattern this gives: a matrix slot can own an engine node that writes the fast channel itself. No such path exists for LFO sources today. A per-route LFO node would differ from envelopes in one known way: random shapes draw per node, so two routes from one LFO would not match (inference from `StrataModulation.sc:290-292`).

## 4. Candidate 4 (list by voice, stored by key)

Built in 3.7, package 0e: decision 24 (`docs/design/3.7-design.md:41`; `docs/decisions/3.7.md:33, 72`, plan ruling 33), and CHANGELOG.md:12 and :63. One accepted transient remains: an old PSET's `strata_lfo<n>_dest: N` line can blip an engine LFO for one step (`docs/decisions/3.7.md:107`, `lfos.md:19`).

## 5. What a player reads

- `docs/user/pages/lfo.md:5`: "An `R` after the depth means a modulation routing also uses the LFO."
- `docs/user/modulation.md:38`: "...so an LFO with no destination makes a good modulator."
- `:86`: "the six LFOs (`L1`-`L6`, each at its own shape before its depth, so an LFO with no destination of its own makes a good modulator)".
- `:87`: "At 100 % from an LFO a routing swings half the destination's range either side of your value, as the LFO itself would at full depth".
- `:89`: "at the script's update rate (24 to 48 times a second); for the smoothest fast movement put the LFO on that setting itself."
- `docs/user/pages/mod.md:23`: "**L1**-**L6** - each LFO's destination (`~` when it runs in the engine), depth, and the LFOs its rate and depth follow".
- `mod.md:79`: the routing's destination is "every setting an LFO can move but the macros".

## 6. Inventory if an LFO becomes a source only

- Files (lines): `lib/lfos.lua` 1,033; `lib/matrix.lua` 761; `lib/pages/lfo.lua` 542; `lib/pages/mod.lua` 1,432; `lib/arc/lfo.lua` 70 (depth and rate rings only, no destination); `lib/engine/StrataModulation.sc` 618; `lib/macros.lua` 795 (the LFO-on-macro path). Other readers of an LFO's own destination: `lib/pages/main.lua:139-140` (MAIN's `~`), `lib/io/crow.lua:635, 686` and `lib/io/midi_out.lua:747` (an output following an engine-run LFO is marked approximate), and `lib/engine_sync.lua:54-99`. The grid has no LFO controls (`lfos.md:41`).
- Params: `dest` and `dest_key` ×6 would go. Depth, offset, `depth_mod` and `depth_mod_amt` act only on the LFO's own destination, since the source value is the shape alone. Their meaning would change or they would go (unsure which the design would choose). Scene: six `strata_lfo<n>_dest_key` blocks, plus the depth/offset fields in `SCENE_FIELDS` (`lib/lfos.lua:942-961`).
- Engine: `setFastLfo`'s place is indexed by LFO (`numFastLfos { ^6 }`, `StrataModulation.sc:28`). Several fast routings from one LFO need either a node per routing (as envelopes do) or a node writing several channels. Neither exists. Memory: an LFO node is 4.2-6.7 KB (`docs/notes/engine/memory.md:11`). The tightest high case has 236 KB above its floor (`docs/status.md:34`). Re-measuring would be required by AGENTS.md's real-time memory rule.
- Slots: six LFOs that today each hold a destination would take up to 6 of 16 slots. Slots are coupled to `numEnvRoutes`, the scenes-file table count (7,474 of 32,768, `status.md:35`) and MOD's `R1`-`R16`.
- Limits: the 12 sends a step are already shared and keyed by param id, so Lua destinations cost the same either way. A fast destination via the matrix is one counted `setFastOffset` per moving channel per step, against an engine LFO's sends only on change (inference from `matrix.md:6` and `lfos.md:13`). The 10 Hz ceiling applies to an LFO without a fast destination of its own (`lib/lfos.lua:329`).
- Macros: the matrix refuses macro destinations (`lib/matrix.lua:52`), so LFO-on-macro has no routing equivalent today.
- Tests: test blocks naming the dest param (a script matching `"dest"`, `_dest_key`, `destination_index(`, `hold_lfo(`) give about 87 blocks over 17 files. lfos_test 39 of 56, pages_lfo_test 17 of 23, registries_test 7, matrix_test 5 (some may be the matrix's own destination), the rest 1-4 each. Engine LFO commands appear 73 times in `test/engine_check/modulation.scd` (1,769 lines) and 67 in `lfos_test.lua`. Docs: `docs/notes/lua/lfos.md` (114), `matrix.md` (63), `docs/notes/engine/modulation.md` (148), `docs/user/modulation.md` (115), `docs/user/pages/lfo.md` (20), `mod.md` (107), AGENTS.md's LFO and matrix invariants and command rows.

## 7. Middle options the code suggests (neutral)

- **A. Engine-run LFO routings, the envelopes' way.** A matrix routing from `lfo<n>` to a fast destination is owned and played by a per-route engine node, and the LFO's own destination stays. Touches `lib/matrix.lua` (`read_routing`'s skip), a new owner module or `lib/lfos.lua`, new or extended engine commands, memory checks, and `modulation.md:89`'s caveat. Random-shape divergence per node (section 3).
- **B. The own destination as an implicit routing.** Keep `strata_lfo<n>_dest`, but compute it in the matrix's step as a 17th-22nd internal routing. Touches `lib/lfos.lua`'s step and `lib/matrix.lua`. Fast destinations would leave the engine LFO path unless combined with A.
- **C. Present together only.** MOD's routing view or the LFO page lists an LFO's own destination beside the routings that use it (the `R` mark exists, `lfo.md:5`). Touches `lib/pages/lfo.lua` and `lib/pages/mod.lua` and their tests and docs. No storage change.
- **D. Lift the rate cap independent of destination.** Decouple `ceiling` from `is_engine_run` (`lib/lfos.lua:329`). Small, but a Lua-sampled 50 Hz LFO at 48 Hz aliases (unsure whether acceptable).
- **E. Full move** (section 6), with the macro-destination gap and the slot sharing to settle.

## 8. 3.8 and registrations

- ROADMAP.md:110-157 adds voice types, a continuous grain window ("so an LFO, a macro or a routing can move the grain's shape", :145), grain probability, an arpeggiator, constant overlap, voice-to-voice graining, a per-voice input channel, a pan wander param (:128) and voice presets.
- One per-voice param becomes modulatable all three ways with one call: `S.register_lfo_destination(label, suffix)` (`lib/state.lua:332`). The macros' catalog (`lib/macros.lua:96-104`) and the matrix's destinations (`lib/matrix.lua:103-111`) are both built from `S.LFO_DESTINATIONS`. Conditions: it must be a control param (`is_control`), the label must fit 49 px with `~` (`lfos.md:17`), and engine-rate requires a new `FAST_DESTINATIONS` entry plus engine bus channels (`NUM_FAST_DESTINATIONS` 5).
- `lfo_destinations` closes at init (`lib/state.lua:73`), and a per-voice registration adds the destination to all seven voices. A type-specific param would be listed on every voice whatever its type (unsure how 3.8 would filter). A voice synth's own params are reachable today only as `v<i> main`.
