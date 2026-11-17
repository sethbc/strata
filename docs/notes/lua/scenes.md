## Must not break

- A new captured field needs `validate_scene` coverage (and a `SCENE_GLOBAL_PARAMS` entry for a global param) and a default `fill_scene` fills (`SCENE_GLOBAL_PARAMS.default`, a voice key's from `S.lib.params_setup.voice_scene_keys`, `S.SCENE_BLOCK_DEFAULTS` or a record's `scene_defaults`), or files written before it stop loading.
- **A scene's voice is `{active, source, values}`** (format 9, the groundwork before 3.8): `values` holds exactly the voice's scene keys (`S.lib.params_setup.voice_scene_keys(i)`: its synth keys, the nine grain keys, the ten crossmod keys and the registered scene keys; never `note_cap` or `solo`), each a finite number. `validate_scene` refuses a voice with any other field, a missing key, an unknown key (another voice type's synth key, a key from a later version) or a value outside its `range` or `limits`. A test builds a format 9 scene from a capture, never from a literal.
- **The format floor** (3.7, design decision 21): a file of format `SCENE_FORMAT_FLOOR` (9, since the work before 3.8) to `SCENE_DATA_VERSION` loads, every field it lacks filled from the defaults (`fill_scene`); a file below the floor (the bare array before 2.1 included) or above the build's version is set aside to its first free backup name with one console line, and never overwritten. One below the floor reads as older (`S.scene_file.problem` `"older"`), never as unreadable. No code is keyed on a file's version (a structure test finds, under `lib/`, a file's version compared, on either side and bare or wrapped, with a number literal or a name that is no floor (`_FLOOR`) and no build version (`_DATA_VERSION`), and the names `from_version` and `before_version`): a stored value whose meaning changes raises the floor with the version, never adds a conversion.
- Discrete keys (a voice key with a `range` in `voice_scene_keys`: the grain envelope and mode, the mod sources and a record's `discrete` keys; source, lock and active states, tempo, filter type, mutation and LFO settings) switch at the end of a transition, never crossfade. Continuous params fade linearly from start values snapshotted once.
- A fade toward a scene that stops a running LFO (`S.lib.lfos.transition_stops(n, scene_data)`: `strata_lfo<n>` on now, off in the scene) fades that LFO's depth to 0 and holds its rate and offset; the end sets the scene's exact values with the state (#408). The LFO entries of `S.SCENE_GLOBAL_PARAMS` are `lib/lfos.lua`'s `S.lib.lfos.SCENE_FIELDS` (the records themselves, appended after the built-in globals), carrying `lfo = n` and the depth's `stop_target = 0`; this file never lists the LFO fields itself.
- A recall is one list: `recall_scene_instant` is `S.lib.scenes.apply_entries(S.lib.scenes.scene_entries(scene_data))`, and `scene_transition_targets` is the continuous entries of `scene_entries`. Their sends, in order, are 3.3.2's, plus what the lock hooks send for a lock the recall changes (scatter's `setScatter`, `docs/notes/lua/scatter.md`): a test compares both against verbatim copies of the merged functions, the recall's with the lock hooks added and both re-based on the format 9 voice (its values in recall order), for every voice state and source (`test/unit/scenes_test.lua`). A change to what a recall sets goes in `scene_entries` or `apply_entries`, never beside them, so morph (which applies the same lists) follows.
- A recall, every fade step and `apply_entries` set each param through the local `set_scene_value`: a registered field's own `set` when its record has one (3.4: a macro sets itself silently), else the local `set_scene_param`: a binary param through `set_binary_param` (`lib/ui/params.lua`), so a controller mapped to it in PARAMS > MAP follows (norns' `Binary:set` sends no CC, #538), any other through `params:set`.
- A recall's lock entries run every `S.registry.lock_change` hook, `fn(voice_idx, locked)`, for each voice whose lock it changes, after setting `S.locked[voice_idx]`, as `toggle_lock` does (3.4's 0a); a voice whose lock stays runs none.
- Every `S.registry.scene_applied` hook (3.7, `S.register_scene_applied({name, fn})`) runs once per `apply_entries` call, contained, right after it clears `S.scene_recall_in_progress`, before the source syncs and before an error is raised again: an instant recall, a fade's landing and morph's discrete entries.
- Every `S.registry.scene_recalled` hook (3.6's 0a, `S.register_scene_recalled`) runs once per recall, contained (`S.lib.ui_frame.contained_call`, `strata: scene recalled hook <n> failed: ` once per message), with `(scene_num)`: at an instant recall once its entries applied and the scene is current (in `recall_scene_instant`, after `S.current_scene` is set), or at a fade's first step once it ran; a fade's landing passes `recall_scene_instant` its fourth argument `landing = true` and tells nothing again. A refused recall (out of range, empty, invalid), an instant recall whose apply raises and a fade whose first step raises tell nothing; a fade that fails later (a step, or its landing) or is superseded has told already, at its first step, so a hook must never assume the scene landed. The scene sequencer's recalls go through `recall_scene` and tell the same way. The targets send their program changes from it.
- A block's `through_zero` plays only in a fade (and morph): an instant recall, and a fade's end, apply the block's value through its `apply` and never ask it.
- `S.lib.scenes.revision(slot)` rises at every capture of the slot and at every load from disk (every slot), so morph rebuilds its plan; a change to a slot's data anywhere else raises it too.
- `S.lib.scenes.takeovers()` rises at every recall and every transition's start that `recall_scene` lets through (#584): a new way to recall or fade a scene goes through `recall_scene` or raises it too, or a morph move made before it would apply over it.
- A recall and every fade step set a voice's keys in `voice_scene_keys`' order (ruling 4 of the groundwork before 3.8): its built-in keys sorted (synth, then grain, then crossmod, each group sorted), then its registered keys sorted, never in `pairs` order, which changes from run to run and between Lua 5.3 and LuaJIT (#531). Never one fully sorted list: `freeze` would come before `freq`, and a recalled freeze of a running synth voice would take its reference from the old note (a test checks). `lib/loops.lua` relies on the sorted registered keys: `loop_length` is set before `loop_start`, whose action has the last word on the pair (`docs/notes/lua/loops.md`).
- The scene sequencer skips an empty or invalid slot at once (#513, #754): a pass moves the position to the first playable slot from it; only a sequence with no playable scene in it holds a slot for the scene duration, so the clock never spins. `S.lib.scenes.sequencer_next_slot` skips them the same way.
- **One stepper** (the groundwork's design §5): the scene sequencer, the pattern chain (`lib/sequencer.lua`) and the next-scene action (`lib/io/actions.lua`) list their slots only through `S.lib.scenes.playable_slots` and draw only through `S.lib.scenes.next_slot`, so an invalid scene is never drawn on any of them (#738, #754). `next_slot` looks up `S.lib.chance.pick` at each call (a test replaces it).
- **Validity is the cache's, never a draw's** (ruling 27): the local `checked[slot] = {data, valid}` is set at `capture_scene` and at a file load, and `S.lib.scenes.playable` checks once a data table it has not seen (one written into `S.scenes` outside this module: only tests do), so no draw calls `validate_scene` for a scene it has seen. Nothing of the cache is written to the file (`save_scenes_to_disk` writes `S.scenes` itself, so a field on a scene would be saved). A test that needs an invalid scene writes a fresh table into `S.scenes[n]`: an in-place edit of a captured scene keeps the cached `true`. `recall_scene` and morph keep their own `validate_scene` calls.
- An error in a pass of the sequencer's loop outside its recall (a param read, the wait, a redraw) stops the sequencer through its param, as the pattern clock does: the clock forgets its own id first, sets `scene_sequencer_enabled` to 0 through `set_binary_param` (so a controller mapped to it follows, #538) and calls `scene_sequencer_stop`, then raises the error again (#329). Cleanup step 100's stop stays a plain `params:set` (norns is tearing the script down). The recall's own errors are printed and the sequencer goes on. The `scene sequencer` invariant holds `S.scene_sequencer_enabled == (S.scene_sequencer_clock ~= nil)`, with that clock's coroutine not dead.
- A recall stops the voices it stops before setting their sources and params, starts the voices it starts after their params, and sends at most one full sync per running voice whose source changed (`S.scene_recall_in_progress`).
- Every recall clears the randomize undo (`clear_undo`, `lib/mutation.lua`): `recall_scene` after validation, `recall_scene_instant` at its start.
- Every recall cancels a running transition first. Every exit of a transition (end, cancel, error) goes through the one local `end_scene_transition(how)`, which clears `S.scene_transition_active`, `S.scene_transition_clock` and the `SCENE_TRANSITION` fields together (#253). A fade that does not land puts the previous scene back as current, never leaving its target current; a landing keeps the target current while `recall_scene_instant` applies it, so no redraw during the landing shows the previous scene, and puts the previous scene back only if that recall fails. Inside the transition's clock its id is forgotten, never canceled.
- Every display of the current scene (the header's `S<n>`, SCENES' slot, the grids' recall keys) asks `S.lib.scenes.shows_current(slot)`, never compares with `S.current_scene` itself, so the scene a fade goes to blinks on all of them alike and is steady once it lands (#254). `SCENE_TRANSITION.step` is set before each step's redraws and cleared by `end_scene_transition` before a landing applies its scene.
- **The next scene is drawn once** (3.7, design §5.4): each pass calls `S.lib.scenes.next_slot(position, playable_slots(1, length), chances)` exactly once, right after its recall has returned (never inside the apply, while `S.scene_recall_in_progress` is set), and keeps the slot in `S.scene_sequencer_next`. A kept slot is redrawn only when it can no longer play (past the length, empty or invalid): a length or chance changed during the wait draws nothing. Every slot kept can play: when the position itself cannot (a repeat of it could not), `next_slot` makes no pick and 3.6's advance stands in (the first playable slot after the position, wrapping from 1 past the length), with no random draw, so a redraw happens at most once however often the grids ask (1f's review). A `"repeat"` move recalls nothing; every other move recalls its slot, even the one playing (plan ruling 36). At 100, 0, 0 no random number is drawn, so 3.6's order holds. `S.scene_sequencer_next` is nil while the sequencer is off (the `scene sequencer` invariant).
- The three chances (`scene_chance_next`, `scene_chance_previous`, `scene_chance_random`) are PSET settings, never scene fields.
- The sequencer never cuts a transition short. It waits for the transition's end, bounded by `SCENE_TRANSITION.overrun_seconds` measured from the fade's progress, never from its start.
- `load_scenes_from_disk` reads the file through `S.lib.data_files.read`, which parses it and never runs it as Lua (#464, `docs/notes/lua/data-files.md`); never `tab.load`. On any failure it keeps the current scenes and moves the file aside to its first free backup name (`.bak`, `.bak.2` ... `.bak.9`, never over an earlier backup, #466), or blocks the autosave (`S.scene_autosave_blocked`), so a bad file is never overwritten.
- scenes.data is written only by `save_scenes_to_disk`, through `S.lib.data_files.write` (a checked `.part` renamed into place, nothing written when the file holds the same bytes, #301); never `tab.save`. A failed write leaves the file as it was and never prints `saved`; it sets `S.scene_file.problem = "not saved"` and `unsaved`.
- Every user's scene save (`S.lib.scenes.save`) writes the file at once through `S.lib.scenes.autosave` (#327), and its header flash says `saved S<n>` only when the scene is on disk, `S<n> not on disk` otherwise (a failed or blocked write), the slot named through `S.lib.scenes.label` (`saved S3 dusk`). Every flash that names a scene goes through `label`, as the empty-slot recall's `S<n> empty` does; the quantizer's label alone stays `"S" .. slot`. `S.scene_file.unsaved` is true exactly while a scene captured in this session may not be in the file; set it wherever a scene reaches memory without reaching the file.
- A load the player asks for goes through `S.lib.scenes.request_load` (SETUP's K3, the PARAMS trigger), which asks for a second request within `SCENE_LOAD.confirm_seconds` (2 s) while `S.scene_file.unsaved`, and loads at once otherwise (#328). init's load calls `load_scenes_from_disk` directly.
- No copy of an older format is kept at a save (3.7: the `.v<n>` copies of #467 are gone): at every instant scenes.data is the old file or the new one, whole, through the `.part` write.
- A load keeps `S.current_scene` only when the file's scene in that slot encodes to the same text as the one it replaces (`S.lib.data_files.encode`); otherwise it is 0 (#518).
- Bounds-check the scene number (1..`NUM_SCENES`) and check the slot is populated before recalling.
- The registered fields are read at init, never at include time: `S.registry.scene_fields` joins `S.SCENE_GLOBAL_PARAMS` in the scenes load's start step (before the file is read, each field's `set` kept by id), and the voice params' scene keys (`S.registry.voice_params`), the scene blocks (`S.registry.scene_blocks`) and the lock hooks (`S.registry.lock_change`) are read at each use.
- Every slot has a name (format 6, 3.4): `validate_scene` rejects a slot, empty or not, whose `name` is not a string of at most `SCENE_NAME_MAX` (12) printable ASCII characters (bytes 32-126), so a name is part of every slot from the load on. A slot is named only through `S.lib.scenes.set_name`, which keeps the printable ASCII characters of its text, cut to 12, raises the slot's revision and writes the file at once (`autosave`, as a save does: a name never reaches memory without the file, or `S.scene_file.unsaved` says so). A capture keeps the slot's name.
- A loaded slot with no name gets `""` (`fill_scene`); every other name is the player's, whatever it reads.
- A user's recall (SCENES' K2 and K3, the arc button, the grids' recall keys) goes through `S.lib.quantize.schedule("scene", fn, "S" .. slot)` at its call site (design §8.9), so it can wait for a beat or bar once the quantizer can; `recall_scene` itself, the scene sequencer and a transition's end never do: they are not user actions, and a time-based sequence never waits for a bar.
- Each LFO's settings (its offset among them, #103) are set before its state `strata_lfo<n>`, so an LFO a recall turns on starts with the scene's settings in place (`S.lib.lfos.SCENE_FIELDS` lists the state last).
- A registered voice param's scene key needs its default in `scene_defaults` (the param's default; a test checks), and a key that must not crossfade needs a whole `{min, max}` in `discrete`. Discrete extras are set at a transition's end, after the voice's source.

## Owns

`lib/scenes.lua` (`S.lib.scenes`) holds the whole scene system:
- `S.scenes`, `S.current_scene`, and the sequencer and transition state on `S` (`S.scene_sequencer_clock`, `S.scene_sequencer_enabled`, `S.scene_sequencer_position`, `S.scene_sequencer_recall_due`, `S.scene_sequencer_next`, `S.scene_transition_clock`, `S.scene_transition_active`, `S.scene_recall_in_progress`, `S.scene_autosave_blocked`, `S.scenes_loaded`, `S.scene_file`);
- `S.lib.scenes.autosave()`, `S.lib.scenes.request_load()` and `S.lib.scenes.SCENE_LOAD` (Disk persistence, below);
- `S.lib.scenes.scene_entries(scene_data)`, `S.lib.scenes.voice_entries(voice_idx, voice_data)` and `S.lib.scenes.apply_entries(entries, opts)` (Entries, below) and `S.lib.scenes.revision(slot)`;
- one voice (the groundwork before 3.8): `S.lib.scenes.capture_voice(voice_idx)` (a fresh `{active, source, values}`, values holding the voice's scene keys only; nil for a number that is no voice; `capture_scene` stores one per voice) and `S.lib.scenes.apply_voice(voice_idx, data, opts)` (a copy of data filled, through the local `fill_voice`, and checked, through `valid_voice_data`, then `apply_entries(voice_entries(voice_idx, copy), opts)`: the voice stops or starts by its `active`, its source goes first and a running voice whose source changes gets one sync; it leaves the voice's pattern and lock, the globals, the blocks, `S.current_scene` and a running transition alone, redraws nothing, and returns true; a number that is no voice, or data still invalid after the fill, applies nothing, prints one console line and returns false). A recall is built from `voice_entries`, never from seven `apply_voice` calls, which would run the scene-applied hooks eight times;
- for morph (`docs/notes/lua/morph.md`): `S.lib.scenes.set_value(param_id, value)`, the local `set_scene_value` a recall, a fade step and `apply_entries` set each param through (a registered field's own `set`, else `set_scene_param`), which morph sets each continuous value through as a fade step does; and `S.lib.scenes.takeovers()` (3a, #584), the count of recalls and transitions started: `recall_scene` raises it once per recall that passes its checks (instant, or a fade at its start; not a fade's landing, an empty slot's recall or an invalid scene's), so morph tells a recall made after a move from one made before it, even a second recall of the scene current at the move;
- the banks and names (3.4): `S.lib.scenes.bank_of(slot)` (1 for slots 1-8, 2 for 9-16, nil for a number that is no slot; a bank is only a view, design Question 15), `S.lib.scenes.name(slot)` (the slot's name, `""` for none and for a number that is no slot), `S.lib.scenes.label(slot)` (how a flash names a slot, design §9.3: `S3 dusk` for a named slot, `S3` for one with no name and `S` and the number for a number that is no slot, never an error; the save and empty-slot flashes use it, the quantizer's label stays `"S" .. slot` so `S16 at bar` always fits), and `S.lib.scenes.set_name(slot, text)` (What a scene holds, below);
- `S.SCENE_GLOBAL_PARAMS`, `S.SCENE_BLOCK_DEFAULTS`, `S.SCENE_TRANSITION` (with a running fade's `next_step_due`, `target`, `previous` and `step`);
- `S.lib.scenes.fading_to()` (the scene a running fade goes to, else nil) and `S.lib.scenes.shows_current(slot)` (whether the displays light the slot as the current scene);
- the stepper (the groundwork's design §5): `S.lib.scenes.playable(slot)` (true for a whole slot 1..`NUM_SCENES` that is populated and valid by the cache), `S.lib.scenes.playable_slots(first, count)` (the playable slots of `first, first + 1, ...`, at most `NUM_SCENES` of them, wrapping past 16 to 1, in that order; `{}` for a `first` that is no slot or a `count` that is no whole number of at least 1; the sequencer asks for `1, scene_sequence_length`, the chain for `seq_chain_from, seq_chain_scenes`, the next-scene action for `1, NUM_SCENES`) and `S.lib.scenes.next_slot(position, slots, chances, random)` (`slot, move`: `nil, nil` for an empty list; `S.lib.chance.pick(position, slots, chances, random)`, looked up at each call, when `position` is in `slots`, so a list of the playing scene alone gives it back, `"next"` at 100, 0, 0, applied again, else `"repeat"`, held; for a nil position, or one not in the list (emptied, invalid, outside the range), no draw: the first slot of the list after it in the cyclic order of 1..16, `"next"`; a nil position gives the list's first). The local `following(position, slots)` is that cyclic first, with `position` itself last; the pass's skip and `sequencer_next_slot` use it too;
- `S.lib.scenes.sequencer_next_slot()` (#303): the slot the running sequencer recalls next, else nil. While `S.scene_sequencer_recall_due` (set by `scene_sequencer_start` and each advance, cleared by the loop just before it recalls the position, and by `scene_sequencer_stop`) the count starts at the position (1 past `scene_sequence_length`, as the loop's guard); otherwise at the position + 1, wrapped to 1 past the length as it is now, as the advance does. From there it is the first playable slot (empty and invalid slots are skipped, as the loop skips them, #513, #754), or that slot itself when no slot of the sequence plays. Through a hold the position is the scene playing (or, with no playable scene in the sequence, the slot it holds), so the grids' scene pages light this one at 10, never the position. 3.7: once a pass has drawn its next slot (after the recall, while no recall is due) it is `S.scene_sequencer_next`, kept while it can still play; a kept slot past the length, emptied or invalid is drawn again once, there and then, so the light shows the slot the pass will recall; the reckoning above stands before the first draw and with no playable scene in the sequence. Each draw redraws the screen and grids. The "scene sequencer" invariant: no recall is due and no next slot kept while the sequencer is off, and the sequencer is on exactly while its clock lives (#329);
- capture, recall, transitions, the scene sequencer, the fill (`fill_scene`), validation and scenes.data;
- the global `with_traceback` error handler;
- `S.lib.scenes.scene_data_dir`, `S.lib.scenes.move_aside_unloadable_file` and `SCENE_LOAD.start_flash_seconds`, used by `lib/buffers.lua`;
- cleanup steps 30 (save the scenes), 100 (the sequencer) and 110 (the transition).

Patterns are `S.patterns` (`lib/sequencer.lua`). The grid's scene pages are in `docs/notes/lua/grid/layout_256.md`, `docs/notes/lua/grid/layout_128h.md` and `docs/notes/lua/grid/layout_128v.md`, the header's scene indicator in `docs/notes/lua/ui/header-and-flashes.md`, the SCENES page (and its name entry) in `docs/notes/lua/pages/scenes.md`.

## What a scene holds

- **Storage**: `S.scenes`, `NUM_SCENES` slots (16: 1-16, two banks of `SCENE_BANK_SIZE`, 8; 3.4), each `{name, populated, data}`. The `lib/scenes.lua` constructor builds the array afresh on every script load, empty by default. A slot's `name` is the player's, `""` for none: an empty slot's is `""`, a slot can be named whether it holds a scene or not, and the name stays with the slot through captures. `S.lib.scenes.set_name(slot, text)` names one: the printable ASCII characters of `text` (bytes 32-126; the rest are dropped), cut to `SCENE_NAME_MAX` (12); a changed name raises the slot's revision, asks for a redraw and is written at once (`S.lib.scenes.autosave`); it returns false (and changes nothing) for a number that is no slot or a text that is no string. On a load, a slot with no name gets `""`; every other name loads as it is. No code or format assumes a one-digit slot.
- **Revisions**: `S.lib.scenes.revision(slot)` is 0 until the slot's data first changes, then rises at each change: a capture of the slot, and any load from disk that replaces the scenes (every slot rises; a load that finds no file or an unreadable one changes none). A number that is no slot reads 0.
- **Data**, a complete snapshot:
  - every voice parameter (synthesis, granular including the buffer params, cross-modulation, and each registered record's scene keys) in the voice's `values` (`data.voices[i] = {active, source, values}`, format 9) and each voice's source (not buffer contents);
  - voice active and lock states (stored as `locked`);
  - pattern data (all 7 voices × 16 steps);
  - global parameters: master density, tempo, filter, delay, reverb, drift, mutations, and each LFO's shape, mode, rate, depth, offset, destination and state;
  - format 3 (3.2): each voice's registered params (since format 9 in `data.voices[i].values[key]`, the keys of every record's `scene_defaults`), the registered global fields (`S.registry.scene_fields`, stored like the other globals) and each LFO's offset (#103);
  - 3.4: each registered scene block's value, `data[record.key]` (Scene blocks, below).
- **Sequencer**: automatic scene progression with configurable timing.
- **Transitions**: instant recall, or a smooth crossfade between scenes.

## Capture

`S.lib.scenes.save(scene_num)` is the user's save (the grid's hold and SCENES' ALT+K3): for a slot in 1..`NUM_SCENES` it calls `capture_scene`, writes scenes.data (`S.lib.scenes.autosave`, #327), flashes `saved <label>` in the header when the scene is on disk or `<label> not on disk` when the write failed or was blocked (`S.lib.scenes.label`: `saved S3`, or `saved S3 dusk` for a named slot), redraws grid and screen and returns true; any other slot does nothing and returns false. `capture_scene` itself stays silent and writes nothing (tests and layout states call it).

`capture_scene(scene_num)`:

```lua
function capture_scene(scene_num)
  -- Captures the complete current state:
  -- - every voice as capture_voice gives it: {active, source, values}
  -- - voice active/locked states
  -- - all pattern data
  -- - global parameters (density, tempo, reverb, mutations, etc.)
  S.scenes[scene_num].data = scene_data
  S.scenes[scene_num].populated = true
end
```

- Deep copies every value (no references).
- Keeps both the `S.voices` state and the norns param values.
- Copies patterns step by step, to avoid shared references.
- Stores each registered block's `record.capture()` under `data[record.key]` (the record returns a fresh value).
- Stores a new table each time, so capturing into a slot during a fade does not change that fade's end.
- Raises the slot's revision.
- Keeps the slot's name (it sets the slot's `data` and `populated` only).

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
- restores lock states (stored as `locked`) with the scene, running the `lock_change` hooks for each voice whose lock changed.

Patterns:
- restored after all parameter changes, each voice's through `S.lib.sequencer.replace_pattern` (which ends a step held on the grid, #242);
- `grid_redraw()` is called so the grid shows them;
- the pattern sequencer keeps playing if it was running.

### Entries

`S.lib.scenes.scene_entries(scene_data)` lists what a recall applies, in recall order (the scene has passed `validate_scene`):
1. every registered block (`S.registry.scene_blocks`, in registration order): `{kind = "block", key, value}`;
2. the globals in `S.SCENE_GLOBAL_PARAMS` order (the built-in ones, the LFO fields, the registered fields): `{kind = "continuous" | "discrete", id, value}` by the entry's `continuous`;
3. per voice 1..`NUM_VOICES`: its `voice_entries` (`{kind = "discrete", key = "active", voice, value}`, its source, `v<i>_source`, discrete, then each of its scene keys in `voice_scene_keys`' order: the synth keys sorted, the nine grain keys sorted, the ten crossmod keys sorted, then the registered keys sorted, #531; continuous but a key with a `range`: the grain envelope and mode, the mod sources and a record's `discrete` keys), then `{kind = "discrete", key = "lock", voice, value}`. Each of these param entries carries `voice = i` too: `{kind, id, value, voice}`;
4. the patterns: `{kind = "discrete", key = "pattern", voice, value}` per voice.

Every list of one scene is in one order, the same on Lua 5.3 and LuaJIT. The order is 3.3.2's but within a voice's values (3.3.2 set the synth and grain params in `pairs` order and crossmod per slot); the test's verbatim copies of 3.3.2's recall and targets are re-based on the values table in this order.

`S.lib.scenes.apply_entries(entries, opts)` applies a list (any subset of `scene_entries`' output, in its order) as a recall does:
- `S.scene_recall_in_progress` is set for the whole list;
- a param through `set_scene_value` (its field's `set`, else `set_scene_param`); a block through its record's `apply(value)`; a lock by setting `S.locked[voice]`, then, when it changed, the `lock_change` hooks; a pattern through `S.lib.sequencer.replace_pattern`;
- a voice whose `active` entry stops it is stopped there (before its source and params); one it starts is started after its last entry in the list, its pattern aside (patterns follow every voice's entries), so `toggle_voice` syncs what was applied;
- a `v<i>_source` entry that changes the source marks the voice; afterward each running voice so marked (and not started by the list) gets one `sync_voice_values_to_engine`;
- an error in an action: the flag is cleared, the syncs run, and the error is raised again with its traceback (`with_traceback`), as below;
- `opts.only = "discrete"` applies only the blocks and the discrete entries (a block is discrete: it switches at a fade's end); `"continuous"` only the continuous entries (no voice starts or stops); any other value raises before anything is applied;
- it redraws nothing: the caller does (`recall_scene_instant` redraws, updates MAIN's voice list and makes the scene current).

An entry's voice is its `voice` field, never read from its id: a global whose id starts `v1_` is no voice's. So a list a caller builds (morph's interpolated values) copies each per-voice entry's `voice`; an entry without one is a global's, and one whose `voice` is no voice (outside 1..`NUM_VOICES`) is skipped.

### Scene blocks

A block is a top-level part of a scene that a module owns (3.4: macro targets, step data, the matrix), registered as `{key, default = fn() -> value, capture = fn() -> value, validate = fn(value) -> boolean, apply = fn(value), discrete = true, through_zero = fn(from_value, to_value) -> {{id, switch = fn()}, ...}}` (`S.register_scene_block`, 3.4's 0a; `through_zero` optional):
- `capture_scene` stores `capture()` under `data[key]`; `fill_scene` fills a scene that lacks it with `default()`; `validate_scene` rejects a scene whose `validate(data[key])` fails;
- a recall applies every block first, before the first global, through `apply(value)`; a fade applies it at its end. `apply` gets a deep copy of the scene's value (`copy_scene_default`), so a module that changes its argument never changes a saved scene. `validate` and `through_zero` get the stored value itself and must not modify it.
- **Ramps through 0** (design §10.2): when a fade starts, each block with `through_zero` is asked once, `through_zero(capture(), scene_value)`. Each returned `id` that is one of the fade's targets then fades `start × (1 − 2f)` below f = 0.5 and `target × (2f − 1)` from it (f the step's fraction; a number param is rounded as usual), so it passes through 0; each returned `switch` runs once, at the first step with f ≥ 0.5, after that step has set its params (so the id is at 0). An id that is no target only switches. The end sets every value exactly. An instant recall never asks `through_zero`.

### Source changes and the full sync

`apply_entries` (and so `recall_scene_instant`) sets `S.scene_recall_in_progress` while it sets params:
- The body runs in an `xpcall` with `with_traceback`. The flag is always cleared, the end-of-recall syncs run for whatever was applied before an error, and only then is the error raised again with `error(apply_error, 0)`, so the engine never lags the Lua state. `recall_scene_instant` runs it in its own `xpcall`, which keeps the traceback (`with_traceback` adds none to a message that has one), handles the current scene and redraws before raising it again.
- While the flag is set, the `v<i>_source` action sends `setGrainSource` but not its `sync_voice_values_to_engine` (which would send the old values to the new grain synth before the recalled ones).
- After every param is set and the flag is cleared, each voice that is running and whose source changed gets one `sync_voice_values_to_engine`, then `S.lib.notes.recall_switched(voice)`: its held extra notes are cut when the voice now is a frozen synth voice (rulings 58 and 59, `docs/notes/lua/notes.md`). A voice the recall starts is synced by `toggle_voice` instead.

Order of voice changes (#46):
- A voice the recall stops is stopped (`toggle_voice`) before its source and params are set, so its release tail keeps the outgoing scene's values (param actions reach the engine only while a voice is active).
- A voice the recall starts is started after its params.
- The engine only records a stopped voice's source, so a recall never builds a grain synth for the new source only to release it at once. Scenes on/synth, off/input, on/buffer recalled in quick succession used to leave the engine more synths than its real-time memory bound (see Real-time memory in `docs/notes/engine/memory.md`).

So a recall sends at most one full sync per voice, after its params. An instant recall and a smooth transition (which ends in `recall_scene_instant`) both leave the engine with the Lua state of every running voice.

A failed instant recall keeps the previous scene current (`docs/decisions/3.0.md`, 3.0.2), and a fade that does not land puts it back (#253, below). A failed `recall_scene_instant(scene_num, scene_data, current_if_failed)` never makes its scene current: it sets `S.current_scene` to `current_if_failed` when one is given (a fade's landing passes its `previous`; nil leaves the current scene as it is), then redraws the screen and grids once and raises its error, so they show the scene that is current and whatever was applied.

### Smooth transitions

- `scene_transition_targets(scene_data)` snapshots `{id, start, target, step}` for every continuous entry of `scene_entries` *once*, before the fade: the continuous globals in `SCENE_GLOBAL_PARAMS` (master density, filter freq/res/mix, delay time/feedback/mix, reverb, drift, and per LFO the free period, depth and offset), then per voice its continuous keys in recall order (synth, grain, crossmod amounts and speed, the registered keys).
- An LFO the fade stops (`S.lib.lfos.transition_stops(n, scene_data)`: running now, `strata_lfo<n>` off in the scene) gets a depth target of 0 (its entry's `stop_target`) and no rate or offset target, so what the player hears fades out instead of growing toward (or changing rate for) a setting the scene never plays (#408). An LFO the scene keeps on, or one that is off now, crossfades as before. The end sets the scene's depth, rate, offset and state.
- 20 steps whatever the transition time. Step k sets `util.linlin(0, 1, start, target, k / 20)` (the local `step_value`), so the fade is linear over the whole time. Never re-read the current value inside the loop: that makes the fade front-loaded. A target a block's `through_zero` named ramps through 0 instead, and its switches run once at the step that reaches f = 0.5 (Scene blocks, above).
- A step sets each target through `set_scene_value`, so a registered field with its own `set` is never `params:set`, in a step or at the end.
- A number param (`step` 1, which does not round itself) is rounded to whole numbers during the fade. 3.4's LFO depths and offsets are one-percent controls, which round themselves, so a fade lands on whole percents. The end applies the scene's exact value.
- Not interpolated: mod sources, grain envelope shapes and grain modes (their `range` in `voice_scene_keys`), lock and active states, tempo, filter type and mutation settings, a registered voice param's discrete keys (`discrete`) and a registered field with `discrete = true`. They switch at the end through `recall_scene_instant()`, which also lands every param exactly on its target.
- The registered voice params that are not discrete crossfade like the built-in ones (`scene_transition_targets`, by key name); a registered field without `discrete` crossfades with the continuous globals.
- `recall_scene_instant` sets a voice's registered keys (in sorted key order, #531) after its source and its built-in keys, so a discrete one such as freeze lands after the source it belongs to and after the voice's `freq`.
- Every param a recall, a fade step or `apply_entries` sets goes through `set_scene_value`, which calls a registered field's own `set` first, when the field has one; every other param goes through `set_scene_param`: a binary one through `set_binary_param`, so its MIDI map's value follows and a mapped controller with echo gets one CC per set (#538); the others through `params:set`, whose own `set` sends the map's CC on norns.
- Any recall ends a running transition first (`end_scene_transition("superseded")`, which cancels the clock without a redraw, as the recall redraws itself).
- `S.scene_transition_clock` / `S.scene_transition_active` track the running transition; `cancel_scene_transition()` ends it.
- The fade cue (#254): each step sets `SCENE_TRANSITION.step` to its number (1 to 20; the first runs inside the recall) after its params and before its `request_redraw()` and `grid_redraw()`. `shows_current(slot)` is true when `slot == S.current_scene` and either `fading_to()` is not the slot or `step` is nil or odd, so the target is lit from the recall (while step 1 sets its params, before it sets `step`, a param action's direct `grid_redraw` lights it too) and after steps 1, 3, 5, ..., and dark after the even ones: a 2 s fade changes every 0.1 s. Dark is each display's level without the current scene: the header's `S<n>` at 2 (its level is 10 with the scene sequencer on, 6 without), SCENES' slot at 4, a recall key at 8 (populated) or 10 (the slot the sequencer recalls next). `end_scene_transition` clears `step`, so a landing's redraws, a cancel and a superseding recall all show the current scene steady.
- A successful `load_scenes_from_disk()` cancels a running transition before it replaces the scenes. Otherwise the fade's end would apply the file's data for that slot, or fail on a slot that is now empty. The fade stops where it is. The cancel puts the previous scene back as current; the load then keeps it current only if the file holds the same scene in its slot (#518).

#### States

| State | `S.scene_transition_active` | `SCENE_TRANSITION.next_step_due` | `SCENE_TRANSITION.target` | `SCENE_TRANSITION.previous` | `SCENE_TRANSITION.step` | `S.scene_transition_clock` | `S.current_scene` |
|-------|-----|-----|-----|-----|-----|-----|-----|
| idle | false | nil | nil | nil | nil | nil | the last scene that landed (0 = none) |
| fading | true | the `util.time()` its next step or end is due | the scene it goes to | the current scene before it | the number of the step applied last (1-20) | its clock (or a lost id, which the sequencer's overrun ends) | `target` |

- idle to fading: `recall_scene(n, t)` with `t > 0`, after ending any running transition. Before the first step runs it sets five of the seven columns, in this order: `S.scene_transition_active` (true), `next_step_due` (now), `target` (n), `previous` (`S.current_scene`) and `S.current_scene` (n), so the first step's redraw lights the target. The first step, which runs inside `clock.run`, sets `step` (1) before its redraws. The seventh, `S.scene_transition_clock`, is assigned when `clock.run` returns, after the first step (nil while it runs).
- fading to fading: each later step sets `step` to its number before its redraws (the only write of `step` outside `end_scene_transition`).
- fading to idle: only `end_scene_transition(how)`, local to `lib/scenes.lua`. It clears every field and returns the fade's `previous`. How it ends:
  - `"canceled"`: `cancel_scene_transition()` (the sequencer's overrun, a scenes file load, cleanup). It cancels the clock, sets `S.current_scene` back to `previous`, and redraws the screen (`request_redraw()`) and grids (`grid_redraw()`) whenever a fade was running, also a fade back to the current scene: its blink phase (`step`) ended, so a mark left dark at an even step is lit again.
  - `"superseded"`: a new recall. The same, without the redraw: the recall redraws itself (and a failed `recall_scene_instant` redraws before it raises).
  - `"failed"`: a fade step's error, inside the clock. The id is forgotten; `previous` is put back and the screen and grids are redrawn (as for a cancel, also when `previous` was the target), then the error is raised again.
  - `"landing"`: the fade's end, inside the clock. The id is forgotten and the target stays current while `recall_scene_instant` applies it, so no grid or screen redraw inside that recall (a voice it starts or stops) shows `previous`. The landing passes the `previous` that `end_scene_transition` returns to `recall_scene_instant` as `current_if_failed`: only if the recall fails is `previous` current again, set before that recall's one failure redraw.
- So the current scene is always the last one that landed or the one now fading: a fade superseded by another keeps the first fade's `previous`, since the second reads the scene the first put back.
- The `"scene transition"` invariant (`S.register_invariant`) checks that `next_step_due`, `target` and `step` are set exactly while the flag is (`step` is nil exactly when no fade runs), and that no clock is kept while idle.

Every exit of the transition clock ends the transition:
- at its end, before `recall_scene_instant`, which it passes the scene data it read when the fade started;
- when canceled;
- when a param action raises an error during a fade step. Each step runs in an `xpcall` with the global handler `with_traceback`, outside the `clock.sleep`, and the error is raised again with its traceback, so maiden shows where the param action failed. `with_traceback` adds a traceback only when the message has none yet.

## Scene sequencer

`scene_sequencer_start()`:

```lua
function scene_sequencer_start()
  S.scene_sequencer_clock = clock.run(function()
    clock.sleep(0)  -- start on the next scheduler tick (after a PSET read)
    while S.scene_sequencer_enabled do
      -- one pass, under xpcall (an error stops the sequencer through its param, #329)
      if not plays(S.scene_sequencer_position, length) then  -- an empty or invalid slot is skipped at once (#513, #754)
        S.scene_sequencer_position = following(S.scene_sequencer_position, M.playable_slots(1, length))
          or S.scene_sequencer_position
      end
      if SEQUENCER_DRAW.move ~= "repeat" then recall_scene(S.scene_sequencer_position, transition_time) end
      draw_next_scene(length)  -- S.lib.scenes.next_slot, once, into S.scene_sequencer_next
      local held = math.max(scene_duration, transition_time)
      clock.sleep(held)
      wait_for_scene_transition()
      -- the kept slot if it can still play in the sequence as it is now, else
      -- drawn again; with no scene in the sequence, the next slot, wrapped
      S.scene_sequencer_position = kept_next_scene(length_now) or ...
    end
  end)
end
```

Timing:
- Everything that does not fade is applied only by the `recall_scene_instant` at the end of the fade, and the next recall cancels a running fade first. So the sequencer never cuts a transition short.
- A scene lasts `max(scene_duration, transition_time)`.
- Then the sequencer waits, checking every `SCENE_TRANSITION.settle_seconds` (0.01 s), until `S.scene_transition_active` clears. The fade's 20 sleeps add up scheduling delay, so with equal times the sequencer would otherwise wake first.
- It also waits for a transition started by a manual recall.
- A manual recall still cancels a running transition (the sequencer's or its own).
- An empty or invalid slot is skipped at once (#513, #754): the pass recalls the first playable slot from the position (`following` over `playable_slots(1, length)`, wrapping within the sequence), so the scene after it follows the last scene's hold. With no playable scene in the sequence the pass holds the slot for `scene_duration` (no transition starts, nothing is recalled) and prints `scene sequencer: no playable scene in slots 1-<length>`, so the clock never spins.

The bounded wait (`wait_for_scene_transition`), so a transition whose clock is gone cannot stop the sequencer:
- A transition whose next step (or end) is `SCENE_TRANSITION.overrun_seconds` (1 s) late is canceled (`cancel_scene_transition`, with a console message), and the sequencer moves on.
- The bound follows the fade's progress, not its start. The transition clock records in `SCENE_TRANSITION.next_step_due` the `util.time()` at which its next step or its end is due: set when the transition starts and before each step's sleep, nil when no transition runs.
- So a healthy fade whose 21 wake-ups each run late under load (60 ms each puts a 16 s fade's end 1.3 s past its transition time) is never cut short, and one that stalls is caught `overrun_seconds` after its next step was due.
- The same applies to a transition the sequencer did not start (a manual recall's) or one left running because the sequencer's own recall failed validation.

Errors:
- An error in the sequencer's own recall (an instant recall, or the first fade step, which runs inside the sequencer's clock) is caught there with `xpcall` and printed with its traceback (`scene sequencer: scene <n> failed: ...`). The sequencer keeps going.
- That is safe: the recall has already cleared `S.scene_transition_active`, `S.scene_transition_clock` and `S.scene_recall_in_progress`, and the next scene may recall fine (stopping would end a long ambient run over one bad action).
- A failing scene still holds for its duration, so a repeating error prints at most once per scene.
- Errors in later fade steps are raised in the transition's clock, not the sequencer's.
- An error anywhere else in a pass (a param read, `wait_for_scene_transition`, the advance's redraws) stops the sequencer through its param (#329): each pass runs under `xpcall` with `with_traceback`; on an error the clock sets `S.scene_sequencer_clock` to nil first (so the stop never cancels it from inside), sets `scene_sequencer_enabled` to 0 through `set_binary_param` (a mapped controller gets its CC), calls `scene_sequencer_stop()` if that left it on, and raises the error again. So the header, SCENES, the grids and the state agree that it stopped, and one switch starts it again.

The next scene (3.7, design §5.4, decision 12):
- The playable slots of 1..`scene_sequence_length` (`playable_slots(1, length)`: populated and valid), in order, are the stepper's list (`next_slot`), the position its current slot, and `scene_chance_next`, `scene_chance_previous` and `scene_chance_random` (0-100, defaults 100, 0, 0, after the length in PARAMS) its chances (`docs/notes/lua/chance.md`). Next past the last playable slot is the first, previous before the first the last, random any other playable slot; what the three leave is a repeat.
- The draw is made right after the recall (with no playable scene in the sequence, as its hold begins: `next_slot` returns nil for the empty list), and kept with its move in the local `SEQUENCER_DRAW`. The pass after a `"repeat"` recalls nothing and holds the scene for another `scene_duration` (no transition); every other move recalls its slot, the one playing too (one playable slot, the playing one, at 100, 0, 0 is `"next"` to itself, recalled again as in 3.6; with random or all at 0 it is a repeat, held).
- After the wait the position becomes the kept slot when it is still inside the length and playable; otherwise the pick is made again over the sequence as it is now (`kept_next_scene`, which `sequencer_next_slot` calls too, so the grids light the slot that will play; it never draws while a recall applies). A pick made again from a position that can no longer play (past a shortened sequence, or emptied by a scenes load) is no pick: `next_slot` takes 3.6's advance, the first playable slot after the position (wrapped to 1 past the length), as a `"next"` move with no draw. With no playable scene in the sequence the position moves on to the next slot, wrapped, as before 3.7.
- Two cases differ from 3.6 at the defaults, on purpose (1f's review ruling): a sequence lengthened during a hold keeps the drawn slot (4 to 6 on scene 4 plays 1, 3.6 played 5), and a scene saved into a skipped slot during the hold waits for the next round (1 and 3 saved, 1 playing, saving 2 plays 3, 3.6 played 2; a test pins it). The kept slot still plays and the light already shows it.
- Start, stop and the error stop forget the draw (`forget_next_scene`).

Length and PSET loads:
- The sequencer advances with the `scene_sequence_length` it reads after the wait, so a sequence shortened while a scene plays drops a kept slot past its end and draws again: at the defaults that wraps to the first scene (it never jumps to the new last scene). A lengthened one keeps the slot it drew.
- Its clock does nothing until the next scheduler tick (`clock.sleep(0)`). norns' `params:read` (a PSET load from the PARAMS menu) sets params one by one in file order, and `scene_sequencer_enabled` comes before the transition time, duration, length, FX, LFO and voice params. Started inside the read, the sequencer would recall scene 1 with the old transition time and the PSET's later lines would then overwrite it. On the next tick the read has finished.
- `scene_sequencer_start` and `pattern_clock_start` cancel their running clock before starting a new one (tests check that a restart leaves one clock).
- The `scene_sequencer_enabled` param action starts and stops the sequencer. Cleanup step 100 stops it through that param, then `scene_sequencer_stop()`.

## Parameters

In the PARAMS menu (strata_scenes section):
- `scene_sequencer_enabled` (binary): start/stop automatic scene progression.
- `scene_transition_time` (0-30 s, default 2 s): crossfade duration for smooth transitions.
- `scene_duration` (4-120 s, default 16 s): how long each scene plays before advancing.
- `scene_sequence_length` (1-`NUM_SCENES`, 1-16, default 4): how many scenes to cycle through.
- `scene_chance_next`, `scene_chance_previous`, `scene_chance_random` (numbers 0-100, shown as percents, defaults 100, 0, 0; 3.7): the chances for the sequencer's next scene (The next scene, above). PSET only, never in a scene.
- Triggers "save scenes to disk" and "load scenes from disk".

## Disk persistence

- **Location**: `~/dust/data/strata/scenes.data`.
- **Format**: a Lua table in the layout norns' `tab.save` writes (written by `S.lib.data_files.encode`, each table's keys in a fixed order): `{version = SCENE_DATA_VERSION, scenes = {...}}` (version 9, since the work before 3.8: the lock's field `frozen` became `locked`, so the floor rose with it; each package of that work changes the format under 9, never raising it again).
  - **Versions**: a file of format `SCENE_FORMAT_FLOOR` (9) to `SCENE_DATA_VERSION` loads. A file below the floor (formats 1 to 8, 3.5's 7 and 3.7's 8 among them, and the bare scenes array written before 2.1, which has no version) is set aside to its first free backup name, never converted, with one console line that names its format and the floor (`error: scenes file has format <n>, older than format 9, the oldest this version loads: it is set aside, not converted`), and reads as `"older"`; a version above the build's, or one that is no whole number, is set aside too, as `"unreadable"` (`error: scenes file has version <n>, expected format 9`, or `expected formats <floor> to <version>` once the two differ). 3.7 deleted every conversion by version (3.3's Pulse `res` mirror and whole-number rounding, 3.4's LFO import and slot names, 3.5's two fills).
  - When to bump `SCENE_DATA_VERSION`: once per release that adds scene fields, never per field. A field's default fills it in every file from the floor up, so a new field needs only its default. A stored value whose meaning changes raises `SCENE_FORMAT_FLOOR` to the new version with it (an older file is then set aside), never a conversion.
- **The fill**: `load_scenes_from_disk()` runs `fill_scene(scene)` on every loaded slot before `validate_scene_data()`. It fills only what is missing, so it can run twice.
  - A slot with no `name` gets `""`; the rest is filled on a populated scene only.
  - Each global from its `SCENE_GLOBAL_PARAMS` entry's `default` (the param default).
  - Top-level blocks from `S.SCENE_BLOCK_DEFAULTS` (`{key, default}`), then each registered block that is missing from its `default()`.
  - Per voice (the local `fill_voice`): a missing `source` is the synth; when `values` is a table, each scene key it lacks gets its default from `S.lib.params_setup.voice_scene_keys(i)` (a built-in key's param default; a registered key's `S.voice_scene_defaults(record, voice)`: a record's `scene_defaults` table, or the table its `scene_defaults` function gives for the voice, so the notes record's attack and release are each voice's own). A voice with no `values` is not given one.
  - Then each registered record's optional `normalize_scene(values)` on that table, in registration order: it puts back what the params would allow where a hand edit left values inconsistent (loops: a start past 0.999 or a length past `1 - start`), so a recall, which sets the values without the params' cross-clamps, ends where the params would. It leaves anything but numbers to `validate_scene`.
  - The registered global fields from their `default`, as entries of `SCENE_GLOBAL_PARAMS`.
  - Malformed scenes are left for validation to reject.
  - A later scene field adds its default to one of these tables (a voice key has its param's, or its record's `scene_defaults`). `S.SCENE_BLOCK_DEFAULTS` is empty: the LFO settings are globals in `SCENE_GLOBAL_PARAMS`, and a module's block brings its own `default` (Scene blocks, above).
- **What is known of the file**: `S.scene_file = {problem, backup, unsaved}`. `problem` is nil, `"unreadable"` (the file could not be loaded), `"older"` (a format below the floor: an older Strata's file) or `"not saved"` (the last write failed); `backup` is the name an unreadable or older file was kept under (nil while it is still in place); `unsaved` is true while a scene captured in this session may not be in the file (a failed or blocked write). SETUP lists a problem (`docs/notes/lua/pages/setup.md`).
- **Robust loading**: `load_scenes_from_disk()` reads the file with `S.lib.data_files.read`, a parser of `tab.save`'s layout, so nothing in the file runs (#464). It returns `"loaded"`, `"missing"`, `"unreadable"` or `"older"`, and requests a redraw. A missing file prints `no saved scenes file found`; one that is not that layout (code, a truncated file) prints `error loading scenes file: <why>`, why naming the byte.
  - On any failure (unreadable, a version below the floor or unknown, invalid data after the fill) it prints a message and keeps the current scenes (empty at startup).
  - It preserves the file: it is renamed to its first free backup name, `scenes.data.bak`, then `.bak.2` ... `.bak.9` (`S.lib.data_files.set_aside`; an earlier backup is never replaced, #466), and `S.scene_file` records `problem = "unreadable"` (`"older"` for a format below the floor) and the backup. If every name is taken or the rename fails, `S.scene_autosave_blocked` stops the scene saves' writes and `cleanup()`'s, and `backup` stays nil.
  - Its start step flashes `scenes unreadable (SETUP)`, or `scenes older (SETUP)`, on the hint row, on whatever page comes up, for `SCENE_LOAD.start_flash_seconds` (4 s) (#463). The line `-- Load saved scenes from disk` stays as it is: a test patches the script at it.
  - On `"loaded"` it clears `problem`, `backup` and `unsaved`, keeps `S.current_scene` only if the slot's scene is unchanged (#518) and raises every slot's revision.
  - Missing slots in a valid file are filled with empty scenes, before the #518 comparison.
- **Saving** (`save_scenes_to_disk()`, true and `"written"` or `"unchanged"`, or false and why): it makes the folder, then writes `{version = SCENE_DATA_VERSION, scenes = S.scenes}` through `S.lib.data_files.write`.
  - Success: `unsaved` false, a `"not saved"` problem cleared (and an `"unreadable"` or `"older"` one with no backup: the write replaced the file still in place; one set aside stays, and the write is format 9), `S.scene_autosave_blocked` false; `scenes saved to ...` printed only for `"written"`.
  - Failure: `problem = "not saved"`, `unsaved` true, `error: scenes not saved to <file> (<why>); the file is as it was`, and the file as it was.
- **Auto-save** (#327): every user's scene save writes the file, through `S.lib.scenes.autosave()`: nil (and `unsaved` set) when the scenes were never loaded in this session or `S.scene_autosave_blocked`, else `save_scenes_to_disk()`. `cleanup()` saves too (step 30), with the same two guards: only once `load_scenes_from_disk()` has run in this session (`S.scenes_loaded`, set when it returns), so a start that failed before init's loads (the engine did not load, an error earlier in `init`) never overwrites the saved file with the empty in-memory state (#72), and not while blocked. With nothing new the exit writes nothing (the bytes are the same). buffers.data has the same guards (`docs/notes/lua/buffers.md`).
- **Auto-load**: its start step (`START_ORDER.scenes_load`) loads them at init, before the buffers.
- **Manual**: the PARAMS triggers "save scenes to disk" (`save_scenes_to_disk`) and "load scenes from disk", and SETUP's `save scenes` and `load scenes` (K3). Both loads go through `S.lib.scenes.request_load()` (#328): while `S.scene_file.unsaved` the first request arms (`SCENE_LOAD.armed_until`, `confirm_seconds` = 2 s ahead) and returns `"confirm"` (SETUP flashes `K3 again: drop unsaved` for the 2 s; the PARAMS trigger prints a line), and a second inside the window loads; otherwise it loads at once, and returns what `load_scenes_from_disk` returns. With scenes written at every save, memory and the file hold the same scenes, so a stray load drops nothing.
- **What is saved**: all 16 slots, their names, populated state and data. Scenes persist across reboots, building a library of sonic palettes.

## Validation

Always validate scene data before using it, so a corrupted file cannot crash the script.

`validate_scene(scene)` checks one slot; `validate_scene_data(scene_table)` checks every present slot of a loaded table (missing slots are allowed and filled on load). Every "number" below is a finite number: NaN, `inf` and `-inf` are invalid values (the data files' reader reads `inf` and `nan` as numbers, and `tab.load` read `1e999` as `inf`, #464). A populated scene must contain everything `recall_scene_instant()` reads:

```lua
-- every slot, empty or not: name, a string of at most SCENE_NAME_MAX (12) printable ASCII characters
-- every SCENE_GLOBAL_PARAMS id is a number (master_density, tempo, mutation_*, filter_*, delay_*, reverb_*,
--   drift_amount, and per LFO its 13 fields, S.lib.lfos.SCENE_FIELDS, the state strata_lfo<n> last);
--   an option param's value is an integer from 1 to its option count; an entry with a range
--   ({min, max}: an LFO's controls and state) holds a value inside it
-- data.voices: NUM_VOICES tables, each with
--   no field but active (boolean), source (integer 1..#SOURCE_OPTIONS) and values, a table holding
--   exactly the voice's scene keys (S.lib.params_setup.voice_scene_keys(i): every key, nothing else),
--   each a number; a key with a range (grain_env 1..5, grain_mode 1..2, mod_source_<n> 0..NUM_VOICES,
--   a record's discrete keys) an integer inside it, a key with limits (scene_ranges) a number inside them
-- a registered discrete global: an integer (0..1 for a binary, min..max for a number, 1..count for an option)
-- a registered continuous global: inside its param's range (a control's controlspec min..max, a number's min..max)
-- a registered block: record.validate(data[record.key]) is true
-- data.locked: NUM_VOICES booleans
-- data.patterns: NUM_VOICES x PATTERN_LENGTH integers 0..15
```

When adding a field to `capture_scene()`:
- add it to `validate_scene()` (and to `SCENE_GLOBAL_PARAMS`, with its `default`, for a global param), or recall will not restore it;
- give it a default `fill_scene` fills (`SCENE_GLOBAL_PARAMS.default`, a voice key's in `voice_scene_keys`, or `S.SCENE_BLOCK_DEFAULTS`), so files from the floor up still load;
- a module's own data that is no param is a scene block it registers (`capture`, `default`, `validate`, `apply`), never a field this file captures; a module's param is a registered scene field, whose continuous value `validate_scene` keeps inside the param's range.

When to validate:
- always before loading scenes from disk (`load_scenes_from_disk`);
- before recalling (`recall_scene` calls `validate_scene`);
- after receiving scene data from any other source.

Error handling patterns:

```lua
-- Graceful degradation with console messages
if not scene_data or not scene_data.voices then
  print("error: scene " .. scene_num .. " has invalid data")
  return
end

-- Nil-safe iteration
if scene_data.voices[i] and scene_data.voices[i].values then
  for key, target_val in pairs(scene_data.voices[i].values) do
    -- safe to access
  end
end
```

## Usage

Manual performance, from grid page 3 (the 256's and 128h's scenes 1-16 on columns 1-16):
1. Build a sound.
2. Hold a row 3 button for half a second (`scene_save_seconds`) to save it to a scene slot.
3. Change parameters.
4. Save to another slot.
5. Press row 1 buttons to switch between scenes instantly.
6. Press row 2 buttons to crossfade between scenes.

On the screen, SCENES does the same for one bank of eight at a time and names the slots (ALT+K2, `docs/notes/lua/pages/scenes.md`).

Automatic sequencing:

```lua
params:set("scene_transition_time", 3)    -- 3 second crossfades
params:set("scene_duration", 20)          -- 20 seconds per scene
params:set("scene_sequence_length", 4)    -- cycle through scenes 1-4
params:set("scene_sequencer_enabled", 1)  -- start the sequencer
-- Result: scenes 1→2→3→4→1... with 3 s crossfades, 20 s each
```

Composition workflow:
1. Create 4-8 distinct scenes with different voice combinations and parameters.
2. Set the transition time (0 s for rhythmic changes, 5-10 s for ambient evolution).
3. Set the scene duration for the pacing you want.
4. Enable the sequencer for hands-free long-form composition.
5. Mutations still evolve unlocked voices during scenes.

## With other systems

- **Lock**: the lock states (the field `locked`) are captured and restored per scene.
- **Mutations**: mutation settings are per scene, so the sequencer can alternate between static and evolving scenes.
- **Pattern sequencer**: pattern data is saved per scene, so scenes can switch rhythms.
- **Cross-modulation**: routing is per scene, for evolving relationships between voices.
- **Drift**: keeps running during scenes unless voices are locked. The global LFOs keep running with the LFO settings the scene recalled.
