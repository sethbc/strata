## Must not break

- A recall is one list: `recall_scene_instant` is `S.lib.scenes.apply_entries(S.lib.scenes.scene_entries(scene_data))`, and `scene_transition_targets` is the continuous entries of `scene_entries`. Their sends, in order, are 3.3.2's, plus what the lock hooks send for a lock the recall changes (scatter's `setScatter`, `docs/notes/lua/scatter.md`): a test compares both against verbatim copies of the merged functions, the recall's with the lock hooks added and both re-based on the format 10 voice (its values in recall order; its type entry follows the source), for every voice state and source (`test/unit/scenes_test.lua`). A change to what a recall sets goes in `scene_entries` or `apply_entries`, never beside them, so morph (which applies the same lists) follows.
- A recall's lock entries go through the lock's one setter, `S.lib.engine_sync.set_locked(voice_idx, locked)` (3.9, #917), as `toggle_lock` does: it sets `S.locked[voice_idx]` and runs every `S.registry.lock_change` hook, `fn(voice_idx, locked)`, for each voice whose lock it changes (3.4's 0a); a voice whose lock stays runs none. Each hook is contained (#910): one that raises is printed once and the recall applies its later entries.
- Every `S.registry.scene_applied` hook (3.7, `S.register_scene_applied({name, fn})`) runs once per `apply_entries` call, contained, right after it puts `S.scene_recall_in_progress` back (cleared, but inside another apply), before the source syncs and before an error is raised again: an instant recall, a fade's landing and morph's discrete entries.
- Every `S.registry.scene_recalled` hook (3.6's 0a, `S.register_scene_recalled`) runs once per recall, contained (`S.lib.ui_frame.contained_call`, `strata: scene recalled hook <n> failed: ` once per message), with `(scene_num, midi_input_port)` (the port is present only for an incoming program change): at an instant recall once its entries applied and the scene is current (in `recall_scene_instant`, after `S.current_scene` is set), or at a fade's first step once it ran; a fade's landing passes `recall_scene_instant` its fourth argument `landing = true` and tells nothing again. A refused recall (out of range, empty, invalid), an instant recall whose apply raises and a fade whose first step raises tell nothing; a fade that fails later (a step, or its landing) or is superseded has told already, at its first step, so a hook must never assume the scene landed. The scene sequencer's recalls go through `recall_scene` and tell the same way. The targets send their program changes from it.
- A block's `through_zero` plays only in a fade (and morph): an instant recall, and a fade's end, apply the block's value through its `apply` and never ask it.
- A recall stops the voices it stops before setting their sources and params, starts the voices it starts after their params, and sends at most one full sync per running voice whose source or type changed (`S.scene_recall_in_progress`; the type entry, 3.8, is set as the source is, right after it and before the voice's keys).
- Every recall clears the randomize undo (`clear_undo`, `lib/mutation.lua`): `recall_scene` after validation, `recall_scene_instant` at its start.
- Bounds-check the scene number (1..`NUM_SCENES`) and check the slot is populated before recalling.
- A user's recall (SCENES' K2 and K3, the arc button, the grids' recall keys) goes through `S.lib.quantize.schedule("scene", fn, "S" .. slot)` at its call site (design §8.9), so it can wait for a beat or bar once the quantizer can; `recall_scene` itself, the scene sequencer and a transition's end never do: they are not user actions, and a time-based sequence never waits for a bar.
- Each LFO's settings (its offset among them, #103) are set before its state `strata_lfo<n>`, so an LFO a recall turns on starts with the scene's settings in place (`S.lib.lfos.SCENE_FIELDS` lists the state last).

## Recall

`recall_scene(scene_num, transition_time)`:

```lua
function recall_scene(scene_num, transition_time)
  -- Validates the slot (validate_scene) and cancels any running transition
  -- Instant recall (transition_time = 0) -> recall_scene_instant()
  -- OR smooth transition (transition_time > 0)
  --   - start values snapshotted once by scene_transition_targets()
  --   - SCENE_TRANSITION.steps (20) steps of util.linlin(0, 1, start, target, step / steps)
  --   - only continuous params fade; the rest switch at the end
end
```

Bounds check first:

```lua
function recall_scene(scene_num, transition_time)
  if scene_num < 1 or scene_num > NUM_SCENES then return end
  if not S.scenes[scene_num].populated then
    print("scene " .. scene_num .. " is empty")
    return
  end
  -- safe to proceed
end
```

Voice activation:
- checks whether a voice's state needs to change (on → off or off → on);
- starts and stops voices with `toggle_voice()`;
- restores lock states (stored as `locked`) with the scene through `S.lib.engine_sync.set_locked`, which runs the `lock_change` hooks, contained, for each voice whose lock changed.

Patterns:
- restored after all parameter changes, each voice's through `S.lib.sequencer.replace_pattern` (which ends a step held on the grid, #242);
- The outermost recall or grid key repaints each grid once after the entries and hooks, including after a partial failure;
- the pattern sequencer keeps playing if it was running.

### Entries

`S.lib.scenes.scene_entries(scene_data)` lists what a recall applies, in recall order (the scene has passed `validate_scene`):
1. every registered block (`S.registry.scene_blocks`, in registration order): `{kind = "block", key, value}`;
2. the globals in `S.SCENE_GLOBAL_PARAMS` order (the built-in ones, the LFO fields, the registered fields): `{kind = "continuous" | "discrete", id, value}` by the entry's `continuous`;
3. per voice 1..`NUM_VOICES`: its `voice_entries` (`{kind = "discrete", key = "active", voice, value}`, its source, `v<i>_source`, discrete, then each of its scene keys in `voice_scene_keys`' order: the synth keys sorted, the eight grain keys sorted, the ten crossmod keys sorted, then the registered keys sorted, #531; continuous but a key with a `range`: the grain mode, the mod sources and a record's `discrete` keys), then `{kind = "discrete", key = "lock", voice, value}`. Each of these param entries carries `voice = i` too: `{kind, id, value, voice}`;
4. the patterns: `{kind = "discrete", key = "pattern", voice, value}` per voice.

Every list of one scene is in one order, the same on Lua 5.3 and LuaJIT. The order is 3.3.2's but within a voice's values (3.3.2 set the synth and grain params in `pairs` order and crossmod per slot); the test's verbatim copies of 3.3.2's recall and targets are re-based on the values table in this order.

`S.lib.scenes.apply_entries(entries, opts)` applies a list (any subset of `scene_entries`' output, in its order) as a recall does:
- `S.scene_recall_in_progress` is set for the whole list and put back as it was found after it (3.9, #892: an apply inside another, a param action's, leaves the outer one's set; after an error too);
- a param through `set_scene_value` (its field's `set`, else `set_scene_param`); a block through its record's `apply(value)`; a lock through `S.lib.engine_sync.set_locked(voice, value)` (which, when it changed, runs the `lock_change` hooks, contained); a pattern through `S.lib.sequencer.replace_pattern`;
- a voice whose `active` entry stops it is stopped there (before its source and params); one it starts is started after its last entry in the list, its pattern aside (patterns follow every voice's entries), so `toggle_voice` syncs what was applied;
- a `v<i>_source` entry that changes the source marks the voice; afterward each running voice so marked (and not started by the list) gets one `sync_voice_values_to_engine`;
- an error in an action: the flag is cleared, the syncs run, and the error is raised again with its traceback (`with_traceback`), as below;
- `opts.only = "discrete"` applies only the blocks and the discrete entries (a block is discrete: it switches at a fade's end); `"continuous"` only the continuous entries (no voice starts or stops); any other value raises before anything is applied;
- it redraws nothing: the caller does (`recall_scene_instant` redraws, updates MAIN's voice list and makes the scene current).

An entry's voice is its `voice` field, never read from its id: a global whose id starts `v1_` is no voice's. So a list a caller builds (morph's interpolated values) copies each per-voice entry's `voice`; an entry without one is a global's, and one whose `voice` is no voice (outside 1..`NUM_VOICES`) is skipped.

### Scene blocks

A block is a top-level part of a scene that a module owns (3.4: macro targets, step data, the matrix), registered as `{key, default = fn() -> value, capture = fn() -> value, validate = fn(value) -> boolean, apply = fn(value, skip), discrete = true, through_zero = fn(from_value, to_value) -> {{id, switch = fn()}, ...}}` (`S.register_scene_block`, 3.4's 0a; `through_zero` optional):
- `capture_scene` stores `capture()` under `data[key]`; `fill_scene` fills a scene that lacks it with `default()`; `validate_scene` rejects a scene whose `validate(data[key])` fails;
- a recall applies every block first, before the first global, through `apply(value, skip)`; a fade applies it at its end. `skip` (#1050) is a set by voice, empty but for a fade's landing, where it holds the voices a preset load let go of (`apply_entries`' `skip_voices`): a block kept by voice (`steps`, `lanes`, `variations`) must leave those voices' parts exactly as they are, and a global block (`macros`, `matrix`, `sequences`) ignores it. A direct call (a chain link, the undo) passes none. `scenes_test.lua`'s net "every block kept by voice leaves its voices alone when all are skipped" fails a new block by name until it honors `skip` or joins the net's global list. `apply` gets a deep copy of the scene's value (`copy_scene_default`), so a module that changes its argument never changes a saved scene. `validate` and `through_zero` get the stored value itself and must not modify it.
- **Ramps through 0** (design §10.2): when a fade starts, each block with `through_zero` is asked once, `through_zero(capture(), scene_value)`. Each returned `id` that is one of the fade's targets then fades `start × (1 − 2f)` below f = 0.5 and `target × (2f − 1)` from it (f the step's fraction; a number param is rounded as usual), so it passes through 0; each returned `switch` runs once, at the first step with f ≥ 0.5, after that step has set its params (so the id is at 0). An id that is no target only switches. The end sets every value exactly. An instant recall never asks `through_zero`.

### Source changes and the full sync

`apply_entries` (and so `recall_scene_instant`) sets `S.scene_recall_in_progress` while it sets params:
- The body runs in an `xpcall` with `with_traceback`. The flag always goes back to what it was before the apply (false but inside another apply), the end-of-recall syncs run for whatever was applied before an error, and only then is the error raised again with `error(apply_error, 0)`, so the engine never lags the Lua state. `recall_scene_instant` runs it in its own `xpcall`, which keeps the traceback (`with_traceback` adds none to a message that has one), handles the current scene and redraws before raising it again.
- While the flag is set, the `v<i>_source` action sends `setGrainSource` but not its `sync_voice_values_to_engine` (which would send the old values to the new grain synth before the recalled ones).
- After every param is set and the flag is cleared, each voice that is running and whose source or type changed gets one `sync_voice_values_to_engine`, then, when its source changed, `S.lib.notes.recall_switched(voice)`: its held extra notes are cut when the voice now is a frozen synth voice (rulings 58 and 59, `docs/notes/lua/notes.md`). A voice the recall starts is synced by `toggle_voice` instead.

Order of voice changes (#46):
- A voice the recall stops is stopped (`toggle_voice`) before its source and params are set, so its release tail keeps the outgoing scene's values (param actions reach the engine only while a voice is active).
- A voice the recall starts is started after its params.
- The engine only records a stopped voice's source, so a recall never builds a grain synth for the new source only to release it at once. Scenes on/synth, off/input, on/buffer recalled in quick succession used to leave the engine more synths than its real-time memory bound (see Real-time memory in `docs/notes/engine/memory.md`).

So a recall sends at most one full sync per voice, after its params. An instant recall and a smooth transition (which ends in `recall_scene_instant`) both leave the engine with the Lua state of every running voice.

A failed instant recall keeps the previous scene current (`docs/decisions/3.0.md`, 3.0.2), and a fade that does not land puts it back (#253, `docs/notes/lua/scenes/transitions.md`). A failed `recall_scene_instant(scene_num, scene_data, current_if_failed)` never makes its scene current: it sets `S.current_scene` to `current_if_failed` when one is given (a fade's landing passes its `previous`; nil leaves the current scene as it is), then redraws the screen and grids once and raises its error, so they show the scene that is current and whatever was applied.
