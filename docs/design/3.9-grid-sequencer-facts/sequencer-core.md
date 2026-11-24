# Facts: the sequencer's core and what it stores

Read on `land/sm-wave-2` (2026-11-23). `seq` = `lib/sequencer.lua`; notes = `docs/notes/lua/sequencer.md`.

## 1. How it works today

### Q1 The data
- Levels: `S.patterns[v][s]`, 7×16 whole 0..15, 0 off, built at seq:97-104 (notes, Data). Attributes: `S.pattern_steps[v][s]`, nil for a plain step or a sparse table of `prob` (0-100, nil plays), `ratchet` (1-4), `notes` (list 1..8 of degrees -14..14, no hole), `pos`/`pitch`/`size` (in `v<i>_buf_pos`/`grain_pitch`/`grain_size` range), `bookmark` (1..4), `gate` (0.05-16 steps), `cond` (one of 78 strings), `slice` (1..`SLICES.max`). One check table `ATTR_CHECKS` (seq:214-226) for `set_step_attr` and the scene block. No per-step "value" or "second value" exists; `pos/pitch/size` are three separate locks.
- Per-voice params (seq record, seq:1645-1692, `count = 8`): `seq_length` 1-16 (16), `seq_division` option 8 (3 = 1/16), `seq_gate` off/on (grain key `seqGate`), `seq_gate_length` 0.05-16 steps (0.5), `seq_gate_release` 0.005-4 s (0.1), `seq_swing` 50-75, `seq_direction` 4 options, `seq_misstep` 0-100. Only one length per voice; nothing per attribute.
- Writers of levels: `toggle_pattern_step` (seq:1464), `replace_pattern` (seq:1492: levels only, attrs untouched; forgets `S.seq_euclid`, `end_overrides`, `end_step_gestures`, `note_pattern_edit`), `clear_pattern`/`randomize_pattern` (seq:1504-1520, through replace), `euclid` (seq:1527), and **direct writes**: grid level gesture `lib/grid/core.lua:426`, SEQ `turn_step` level `lib/pages/seq.lua:361`, SEQ E3 `pages/seq.lua:728`, SEQ reset row `pages/seq.lua:654`, arc `lib/arc/seq.lua:51-54`. Each calls `S.lib.mutation.note_pattern_edit`.
- Writers of attributes: only `M.set_step_attr` (seq:253) and the block's `apply` (`set_all_steps`, seq:302), plus the chain (seq:1144). SEQ's `turn_step` (`pages/seq.lua:353-400`) and arc rings (`arc/seq.lua:121-136`) go through `set_step_attr`.
- Copy/paste: grid voices page PC (`lib/grid/pages/voices.lua:61-75`) copies **levels only** and pastes through `replace_pattern`. Undo: randomize holds levels only (`lib/mutation.lua:130-141`), restored through `replace_pattern` (mutation.lua:241); any pattern edit of that voice ends it (mutation.lua:302-305).

### Q2 The clock
- One coroutine per voice plus the transport's (seq:1376, 1425). Tick k at `anchor + k×division`, odd ticks late by `(swing-50)/50×division` (seq:1073-1095).
- `take_position` (seq:1210-1257): first step by direction; forward/reverse/random pass = `pass_length` steps taken; ping-pong ends a pass at each turn (`ping_pong_step`, seq:1186); length change applies at once while `taken < length`, else at pass end; direction change resets `taken` (#874); misstep wraps by `pass_length`. At pass end: `conditions.next_pass`, and overrides/chord end if `not has_set_step` (seq:1247-1254). Skipped ticks call the same `take_position` (seq:1354-1361).
- One step (`begin_voice_step`, seq:1265-1299), in order: `at_beat` (chain link due), `take_position`, `S.pattern_sounding_steps[v] = step`, level>0 → `cond` test then one prob draw, `record` if conditioned; if plays: `hits = min(ratchet, floor(step_seconds/0.02))`, semitones, `step_inputs` (locks, wanted values, chord), `step_pitches`, `play_outputs(hit 1)`; `finish_beat` (one grid repaint per beat, seq:1107). Later hits: `play_voice_hit` (seq:1301), spaced `step_beats/hits`, through `due_hit`.
- Voices output at the first hit (`voices_play` seq:741 → `apply_step` seq:634): release chord keys it lacks, **clear the previous step's overrides this step lacks** (seq:646-648), set locks, bookmark recall (inside loop only), slice/region, first note via `S.lib.notes.play` (sets the note override), record `overrides[v]`, `last_played[v]`. Then start a stopped voice (`start_voice`, `retrigger_follows = gated`) or gate length + `retrigger`; then `play_chord`; then an overlap slice.
- "Just played": `S.pattern_sounding_steps[v]` read by `M.sounding_step(v)` (seq:1773) → `step_brightness` (seq:1787; grid `lib/grid/pages/patterns.lua:23`) and SEQ (`pages/seq.lua:188, 549`). Transport's 16th: `S.pattern_sounding_step`. Locals `last_played[v]` (step that set overrides) and `step_slices[v].step` too.

### Q3 Passes
Pass state is per voice, one count (`S.lib.conditions` passes[], `lib/conditions.lua:45-62`), moved only by `take_position` (seq:1248) and reset by `start_position` (seq:1172: pattern start, `restart_voice`, division reset's bar seq:1343-1346, `end_clocks`). Readers: `conditions.test` `A:B` and `first` (conditions.lua:142-145); the pass-end `has_set_step` override end (seq:1251); `pass_length` (a shorter length waiting, misstep wrap). `pre`/`nei` read outcomes, not passes. `fill` reads `fill()` only. Chain and division reset count transport bars from the anchor (seq:1098-1102, 1161-1166, 1577), not passes. A chain link and scene recall keep position and pass. No other module reads the pass (grep).

### Q4 Base overrides
- `set_base_override(id, v)` / `clear_base_override(id)` (`lib/engine_sync.lua:378-390`): one global map keyed by param id, no owner; sends at once; finite numbers only; the touch hook (hand edit) clears it (engine_sync.lua:399). Only the sequencer calls them (grep). Wrapped by `set_override`/`clear_override` (seq:324-332, resend `scaleNote` for freq).
- Ends: next played step lacking it (seq:646); `end_overrides` (seq:386) at stop (seq:1595), `replace_pattern`, chain link (seq:1142), `seq_length` below `last_played` (seq:1654), pass end with no set step (seq:1251); MIDI taking own note (`own_note_taken` seq:569). A step skipped by cond/prob keeps the last overrides (test at `test/unit/sequencer_test.lua:3915`).
- For "stays until the next step with a value": change the clear loop in `apply_step` (seq:646-648) to clear only keys the step replaces, keep it through value-less steps, and rethink the length-cut (seq:1654) and empty-wrap (seq:1251) ends; locks are tied to `level > 0` plays today (seq:1275), so a value lane with no hit would need its own path through `apply_step`. A cutoff target has no lock key: `SEQ.lock_params` is `pos/pitch/size` only (seq:65); the voice filter is `v<i>_filter_freq` with `filter_mix` default 0, i.e. off (`lib/voice_mix.lua:4-5`).

### Q5 Step outputs
- Record `{name, play(event), stop(), available(voice)}` (`lib/state.lua:553, 625-630`); registry open, read at each hit (seq:846). Outputs: `voices` (seq:790, called directly, errors stop the patterns) and `targets` (`lib/io/targets.lua:176`, registered at start step 161, runs in a worker coroutine, skipped once it fails).
- Event per hit (seq:889-903): `voice, step, hit, hits, first, level, velocity, beat, gate_beats, pitches`, plus `notes`, `semitones`, `locks {pos,pitch,size,bookmark}`, `slice` when set. Every ratchet hit goes to every output. `targets.available` refuses a silenced voice (targets.lua:150-156); the voices output plays muted voices (mute is the stage's).

### Q6 Storage
- Scenes: `data.patterns[v][s]` captured step by step (`lib/scenes.lua:354-360`), validated as 7×16 integers 0..15 (scenes.lua:1455-1466); recalled as `{kind="discrete", key="pattern"}` entries after every voice's (scenes.lua:493, 533-534), so at a fade's end. Attributes: scene block `steps` (seq:309-316), discrete, applied before patterns; `default` 7 empty tables (fill_scene, scenes.lua:307-309); `valid_steps` refuses any unknown key or value (seq:268-283). The seq params are voice scene keys (`scene_defaults`, `discrete`, `scene_ranges`, seq:1682-1689).
- `SCENE_DATA_VERSION` 10 = `SCENE_FORMAT_FLOOR` 10 (`lib/constants.lua:11,15`). No conversion: files below the floor are set aside; no code may key on a version (structure test; `docs/notes/lua/scenes/disk.md`, Must not break). `fill_scene` only adds missing fields (scenes.lua:295-313); `normalize_scene` is a voice-param record hook on values only (scenes.lua:282-284).
- PSETs: patterns and attributes are **not** in PSETs except through `<pset>.scenes.data` (scenes). The seq params are PSET params; `strata_seq` group (seq:1611) too, `seq_fill` never saved. `sequences.data` is the random sequences' (`lib/random_sequences.lua:36`), unrelated to patterns.
- Chain: `load_chain_scene` (seq:1139-1151): `end_all_overrides`, `replace_pattern` per voice, `set_all_steps`, `SEQ.chain_keys` params. Scene sequencer: a full recall (`docs/notes/lua/scenes/sequencer.md`).

### Q7 Tests that pin playing
- `test/unit/sequencer_test.lua:3899` "a 3.6 pattern plays the same steps as before" (`CALLS_36`, :3882, every engine call over 32 steps with ratchet, locks, chord).
- :3983 prob draws in 3.6's order; :3412 no draw at plain forward; :2566 and :2595 3.4's messages; :3265; :2725 and :1058 node counts over 64 steps.
- Machines: "position and pass" table (25 rows, notes table; rows asserting known faults #961, #970), :4595 closed forms, :4646 1:2 through a direction change; "voice hit", "slice decision", "step holds" (:4790), "pattern clock".
- `test/unit/system_38_test.lua` + `test/fixtures/3.8.0-start-calls.lua`: a default start's every call (no patterns, but the seq record's `sync` runs in every start), `RUN_CALLS_ALLOWED` empty.
- `test/unit/params_setup_test.lua` vs `test/fixtures/3.7.0-params.lua`: every param keeps id, default, place; on-purpose differences listed there.
- `test/unit/system_37_test.lua:492` loads `test/fixtures/format-10-files.lua` (a scene with a step's prob, notes, ratchet).
- `test/unit/matrix_test.lua:1670-1699` the largest scenes file (every step attribute set) against `largest_scenes_tables` 6898.

## 2. What the rework would touch
- **Step mode** (part 1): `seq_gate` (option, grain key `seqGate`) and its `resend_gate`/`gate_sent`/`send_gate_seconds` (seq:444-470); `voices_play` (seq:741-786: start/retrigger per hit); `apply_step` for move; the seq record's `count`, `scene_defaults`, `discrete`, `sync`; `SEQ.lock_params`. "No steps → drone, a step → pulse" needs a voice-level test like `has_set_step` (seq:233) plus a gate switch outside the clock (today the gate is per param, sent at sync).
- **Lanes** (part 2): `S.pattern_steps` shape, `ATTR_CHECKS`, `valid_steps`, `copy_steps`, `set_step_attr`/`step_attr` (SEQ, arc, grid callers), `hit_event`, `step_inputs`, `begin_voice_step`'s read of one step's `attrs`, `take_position` (one position per voice now), pass logic, `has_set_step`, `replace_pattern`, the chain, the steps block, scenes' `patterns` capture/validate, `largest_scenes_tables`. Could stay: clocks, `wait_for`, transport, outputs registry, notes/chord/slice machinery, conditions module (with a per-lane or per-hit-lane pass).
- **Keys** (part 3): `step_key`'s level path (grid core:426), `end_step_gestures`, `sounding_step` (per-lane playheads).
- **Performing** (part 4): no loop range (position is 1..length); a roll needs a hit outside `begin_voice_step` (local, tied to `take_position`); variations A-D need four level+lane sets per voice and a bar (chain counts the sequencer's bars, `next_bar_beat` is local; `S.lib.quantize` uses the clock's); mutes are `v<i>_mute`; fill is `S.lib.conditions.hold_fill`.

## 3. Constraints
- notes Must not break: no node for the own note; outputs only; locks/notes are base overrides; whole-pattern changes via `replace_pattern`; every edit `note_pattern_edit` + `grid_redraw`; draws only where 3.6 drew; `take_position` for skipped ticks; `start_position` at every start site; one repaint per beat; no bursts.
- AGENTS.md: "Step locks and notes ... end at the voice's next played step without them" (to reword for move); "no `play` yields".
- Stored format: format 10 = floor; a meaning change raises the floor (sets aside 3.8.0's files), never a conversion, no version-keyed code (structure test). The maintainer's answer 8 says "old scenes convert" (ledger progress.md:23): in direct tension. A new block with a `default` loads old files (fill).
- `largest_scenes_tables` 6898 (`docs/notes/lua/data-files.md`), `max_tables` 32768 ≥ 4×; adding lanes/variations raises both and `matrix_test`. `max_bytes` 4 MB vs 1.15 MB.
- `system_38_test` start fixture: no start message may move (only package 4c re-bases it).
- `3.7.0-params` fixture: new/changed params listed on purpose.
- Notes word limit 9,000 (`test/unit/docs_test.lua:2758`); `sequencer.md` is at 8,996: package 3i (wave 3) moves "position and pass" to `docs/notes/lua/sequencer/pass.md` and fixes #961 and #970 in `take_position`. AGENTS.md ≤ 8,000 words.
- 200 locals: the constructor has about 115 now (30 must stay free).
- Ratchet spacing ≥ 20 ms (`SEQ.min_ratchet_seconds`); quantize never wraps a step ("a step never waits for a bar", `docs/notes/lua/quantize.md`).
- Every hit tells `voice_hit` hooks once (envelopes, positions, random sequences listen): a move step with no retrigger would stop them.

## 4. Open questions
1. How do 3.8.0 scenes become lanes when no conversion may be keyed on a version: same-key reading (lanes at the voice's length = today's `patterns` + `steps`), a new block filled from them, or raise the floor? The code leans to keeping `patterns`/`steps` as lane data at the voice's length plus a new block with defaults.
2. One pass per voice or per lane: which lane's wrap moves `conditions.pass` (A:B, first), the empty-wrap override end and the waiting shorter length? The code leans to the hits lane's.
3. Does a move step still retrigger (hits for envelopes, `voice_hit`, targets' notes), and does a value with no hit set an override?
4. Where a move override ends: the length cut and empty wrap (seq:1251, 1654), stop, replace, a hand edit; and whether a cond/prob miss holds it (today it does).
5. Cutoff as a move target: `v<i>_filter_freq` does nothing while `filter_mix` is 0 (default).
6. Pulse vs `seq_gate`: a new `step_mode` param, or `seq_gate` given a third value (its stored meaning changes)?
7. "Next bar" for variations and chain: the sequencer's count (anchor bars) or the quantizer's clock bars?
8. Loop range and rolls: a start offset in `take_position`, and a hit path outside the clock's step.
9. Do variations and lane lengths travel in scenes, chain links (`SEQ.chain_keys`) and the grid paste (today levels only)?
