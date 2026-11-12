## Must not break

- Morph writes params and never recalls: it never calls `recall_scene` or `recall_scene_instant`, never starts a transition and never calls `clear_undo` itself (a param it sets ends the randomize undo through its own action, as any set does).
- Each continuous value is set through `S.lib.scenes.set_value(id, value)`, the setter a transition's step uses (a registered field's own `set`, a macro's silent one; otherwise `params:set`, or `set_binary_param` for a binary), never through `apply_entries`, and morph never sets `S.scene_recall_in_progress` for it. So a quantized voice's `freq` snaps to the scale as under a fade's step (the `freq` filter stands down only for a recall, `docs/notes/lua/variation.md`).
- The discrete entries switch through `S.lib.scenes.apply_entries(entries, {only = "discrete"})`, in recall order: voices that stop stop first, sources before their params, discrete extras after their source, blocks, voices that start start last, one sync per running voice whose source changed.
- A continuous value is `util.linlin(0, 1, A, B, morph)`, a transition step's formula, so morph and a fade agree at the same fraction; a number param rounds to whole numbers, as a fade rounds it.
- A voice's loop pair (`loop_start`, `loop_length`, `lib/loops.lua`) is one unit of the round robin: written whole whenever either value is due, the start first, then the length. A recall sets the length first because the length's filter stands down while `S.scene_recall_in_progress` is set; morph's sets are a fade step's, with the filter on, so a length set first would be cut to the old start's room. The start's action cuts a length the new start leaves no room for, and the blended length, a blend of two fitting pairs, always fits the blended start.
- The discrete entries take A's side below 0.5 and B's from it on the first apply after a plan change (and after a recall, a PSET load or an error), then switch to B at 0.52 and back to A at 0.48 (`MORPH.hysteresis` 0.02), never between.
- Every apply writes inside one `S.lib.engine_sync.deferrable(fn)`, and `fn` never yields: the clock sleeps outside it.
- One clock, `S.morph_clock`, applies at most `MORPH.apply_hz` (10) times a second: the morph action only marks a move (and whether morph held the state then) and starts the clock if none runs. Its first apply is on the next scheduler tick, so a PSET load's hook can cancel it.
- A recall or a fade that comes after the latest move wins: the move is dropped, never applied over it (`move_overtaken`). A move made after a recall applies, starting again from the recalled state.
- At most `MORPH.max_values_per_apply` (120) continuous values per apply, round robin from where the last apply stopped (a loop pair whole or not at all), so a still morph converges within a few applies. A crossing's discrete switch, and its ramps' writes to 0, are applied whole, outside that count (they happen only at the hysteresis edges; a block's ramps are few, the matrix's at most 16).
- While the morph moves, a value that moved less than `MORPH.send_threshold` (1/1000) of its param's range since morph last set it is skipped. The applies at rest set every value that moved at all, so a morph resting at 0 holds A's exact continuous values and at 1 B's (still 120 an apply). A value that did not move is never due, so the clock stops once every value is on its blend.
- A block's ramp through 0 (its `through_zero`, design §10.2) is asked once per plan each way, `through_zero(a_value, b_value)` for the switch to B and `through_zero(b_value, a_value)` for the one to A, so each switch points at its own side's value. At a crossing the ramps' ids are set to 0 first, then the switches run, then the discrete entries; the ids are written before any other value in every apply.
- A PSET load never applies the morph: the PSET hook `morph` cancels the apply the PSET's `morph` line started, and the loaded values stand.
- The params `morph`, `morph_a` and `morph_b` are never a scene field, an LFO destination or a macro target; `morph_a` and `morph_b` take their maximum from `NUM_SCENES`.

## Owns

`lib/morph.lua` (`S.lib.morph`, 3.4, package 1g, design §5.1-§5.4):
- `add_params()`: the group `strata_morph` ("morph", `MORPH.param_count` 3) with `morph` (control 0-1, shown in whole percents, default 0), `morph_a` (number 1..`NUM_SCENES`, default 1) and `morph_b` (default 2). `lib/params_setup.lua`'s menu record `morph` calls it, after the LFOs and the macros.
- `plan_ready()`: whether both endpoints hold populated scenes that pass `validate_scene`.
- `MORPH`, the module's one table of tunables (`apply_hz` 10, `hysteresis` 0.02, `max_values_per_apply` 120, `send_threshold` 1/1000, `epsilon`, `param_count`).
- `S.morph_clock`, the cleanup step `CLEANUP_ORDER.morph_clock` (112, cancels the clock and drops the waiting apply), the PSET hook `morph` and the invariant `morph clock` (a move or a value left always has a clock, and the clock's coroutine is not dead).

Elsewhere: `S.lib.scenes.set_value` (`lib/scenes.lua`) is the scenes' own `set_scene_value`, exported for morph.

## The plan

Built from the two slots `morph_a` and `morph_b` name, and rebuilt (lazily, at the next apply or `plan_ready`) when either param or either slot's `S.lib.scenes.revision` changes (a capture, a save, a load from disk):
- `scene_entries` of both scenes, paired by identity: a param by id, a block by key, a voice state (`active`, `lock`, `pattern`) by key and voice. An entry in one scene only, or of another kind in the other, is left out.
- Continuous pairs that differ, in scene A's entry order (the round robin's order), as units: one value each, a voice's loop pair one unit (above). Equal pairs are left out, so morph never touches them.
- Per side, its discrete entries (blocks, discrete params, voice states, patterns) that differ from the other side's, in that scene's recall order. Equal ones are left out.
- The ramps: every id a block's `through_zero` names, from both calls, kept whether or not A and B differ there (a routing that changes moves its old destination otherwise); their value is `A × max(0, 1 − 2m)` on A's side and `B × max(0, 2m − 1)` on B's, so 0 until the side has switched. An id that is no continuous entry only switches.
- An empty or invalid endpoint makes the plan not ready: an apply then flashes `S<n> empty` (the first such endpoint, A before B) once per plan and changes nothing (no cancel, no current scene change).

## Applying

- The `morph` action sets a move, notes whether morph held the state (no scene current, no fade) and the current scene, and starts the clock if none runs. The clock sleeps 0 (its first apply runs on the next tick), then, at each tick:
  - a move waiting that a recall or a fade overtook (morph held the state at the move but no longer does, or the current scene changed since the move) is dropped;
  - a move waiting is applied with the 1/1000 threshold;
  - else, while nothing took over, an apply at rest (no threshold) runs while the last apply left values or a value of the current plan is off its exact blend;
  - else the clock stops.
  After each apply it sleeps 1 / `apply_hz`. So a fast turn is coalesced (100 moves over 1 s apply 11 times: at once, every 0.1 s, and once more for the last position), and the clock stops at the first tick that has nothing to set.
- An apply: build or reuse the plan; if a recall or a transition took over since the last apply (`S.current_scene ~= 0` or `S.scene_transition_active`: morph leaves no scene current), forget what was applied, so this apply starts again from the recalled state (the side by position, every value due); `cancel_scene_transition()`, so the scene sequencer's wait moves on; inside `deferrable`, the side's switch (ramps at 0, switches, `apply_entries(side's discrete, {only = "discrete"})`) when the side changes, then up to 120 continuous values, each through `S.lib.scenes.set_value`; then `S.current_scene = 0`, `request_redraw()` and `grid_redraw()`.
- A recall while values are left stops the convergence: the next tick sees the recalled scene current and the clock ends without writing. A recall never moves the morph param; the next move applies from the recalled state, as above.
- A PSET load (the PSET hook `morph`, after norns has set every param) cancels the clock and forgets what was applied: the PSET's values stand, and the next move starts again from them.
- An error in an apply ends the clock (it forgets its own id first), forgets what was applied and is raised again with its traceback.

## Differences from a transition

- **An LFO one scene has on and the other off** (known difference): a transition toward a scene that stops a running LFO fades that LFO's depth to 0 and holds its rate and offset (#408, `S.lib.lfos.transition_stops`). Morph has no such rule: it blends the LFO's rate, depth and offset toward the other scene's stored values and switches the LFO on or off at the crossing (0.52 or 0.48). Design §5 gives morph no rule for it, and one would need a helper from the LFO module.
- Morph ends nowhere: the discrete entries switch at 0.52 and 0.48, `S.current_scene` stays 0, and the result is params, which a save can store as a new scene (design §5.4).
- Morph sets a value only when it moved (past the threshold while moving, at all at rest); a fade sets every target at every step.

## Tests

`test/unit/morph_test.lua`: the params and their group; the continuous formula against a 20-step transition at f = 0.5 (with a number param's rounding); a quantized freq snapping as under a fade's step; the hysteresis, the recall order of a voice start and stop and its one sync; the first apply after a plan change; 10 Hz coalescing; the 120-value round robin and convergence; the threshold while moving and the exact values at rest at 0 and 1; a loop pair written together, start first; a transition canceled and the current scene cleared; a recall and a fade after a pending move winning; empty and invalid endpoints flashing once; no recall or transition; a save rebuilding the plan; a block's ramp through 0 both ways and a jump across; deferrable sends; a PSET load; a recall stopping the convergence and the next move re-applying; the cleanup step. The cleanup order is in `test/unit/structure_test.lua`.
