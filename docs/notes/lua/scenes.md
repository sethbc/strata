## Must not break

- Each part of the scene system has its own notes file under docs/notes/lua/scenes/ (Files, below), each opening with its own "Must not break" list; this list keeps the rules that span them. Read the file for the part you change, and this list.
- A new captured field needs `validate_scene` coverage (and a `SCENE_GLOBAL_PARAMS` entry for a global param) and a default `fill_scene` fills (`SCENE_GLOBAL_PARAMS.default`, a voice key's from `S.lib.params_setup.voice_scene_keys`, `S.SCENE_BLOCK_DEFAULTS` or a record's `scene_defaults`), or files written before it stop loading.
- A recall, every fade step and `apply_entries` set each param through the local `set_scene_value`: a registered field's own `set` when its record has one (3.4: a macro sets itself silently), else the local `set_scene_param`: a binary param through `set_binary_param` (`lib/ui/params.lua`), so a controller mapped to it in PARAMS > MAP follows (norns' `Binary:set` sends no CC, #538), any other through `params:set`.
- `S.lib.scenes.revision(slot)` rises at every capture of the slot and at every load from disk (every slot), so morph rebuilds its plan; a change to a slot's data anywhere else raises it too.
- `S.lib.scenes.takeovers()` rises at every recall and every transition's start that `recall_scene` lets through (#584): a new way to recall or fade a scene goes through `recall_scene` or raises it too, or a morph move made before it would apply over it.
- A recall and every fade step set a voice's keys in `voice_scene_keys`' order (ruling 4 of the groundwork before 3.8): its built-in keys sorted (synth, then grain, then crossmod, each group sorted), then its registered keys sorted, never in `pairs` order, which changes from run to run and between Lua 5.3 and LuaJIT (#531). Never one fully sorted list: `freeze` would come before `freq`, and a recalled freeze of a running synth voice would take its reference from the old note (a test checks). `lib/loops.lua` relies on the sorted registered keys: `loop_length` is set before `loop_start`, whose action has the last word on the pair (`docs/notes/lua/loops.md`).
- **A load lets go of a voice in a running fade** (3.8, design §8.3, ruling 45): `S.lib.scenes.release_voice(v)` marks the voice in the fade's own `released` set (a local of the fade, reachable as `S.SCENE_TRANSITION.released` only while it runs; true then, false otherwise and for a number that is no voice). Each step skips a target whose `voice` is released (every target carries its entry's `voice`), and the landing hands the set to `recall_scene_instant`'s fifth argument through the fade's closure, never through `S.SCENE_TRANSITION`, which `end_scene_transition` clears before the landing applies its scene. The filter lives in `apply_entries` (`opts.skip_voices`, a set by voice), which drops every entry of a released voice (active, source, type, values, lock and pattern) before anything is applied; with no voice released a recall and a fade send what they sent (the 3.3.2 comparisons). A morph move and the scene sequencer's next recall still write the voice.
- The registered fields are read at init, never at include time: `S.registry.scene_fields` joins `S.SCENE_GLOBAL_PARAMS` in the scenes load's start step (before the file is read, each field's `set` kept by id), and the voice params' scene keys (`S.registry.voice_params`), the scene blocks (`S.registry.scene_blocks`) and the lock hooks (`S.registry.lock_change`) are read at each use.
- A registered voice param's scene key needs its default in `scene_defaults` (the param's default; a test checks), and a key that must not crossfade needs a whole `{min, max}` in `discrete`. Discrete extras are set at a transition's end, after the voice's source.

## Files

The scenes' notes, one file per part, each with the rules of its part (#898):
- [capture](scenes/capture.md): what a scene holds (storage, names, revisions, data) and the capture. Its rules: a user's save writes the file at once and its flash, every flash naming a slot through `label`, `S.scene_file.unsaved`; every slot has a name, set only through `set_name`.
- [recall](scenes/recall.md): the recall, its entries (`scene_entries`, `apply_entries`), the scene blocks and the source changes' full sync. Its rules: a recall is one list (3.3.2's sends); the lock hooks, the scene-applied and scene-recalled hooks; a block's `through_zero` only in a fade; the order of a recall's voice stops, starts and syncs; every recall clears the undo; the bounds check; a user's recall through the quantizer; an LFO's settings before its state.
- [transitions](scenes/transitions.md): smooth transitions and their States table. Its rules: discrete keys switch at the end; a fade toward a scene that stops an LFO; every recall cancels a running transition, and every exit goes through `end_scene_transition`; every display of the current scene asks `shows_current`.
- [sequencer](scenes/sequencer.md): the scene sequencer, its timing, its bounded wait, its errors and the next scene. Its rules: an empty or invalid slot skipped at once; one stepper (`playable_slots`, `next_slot`); validity is the cache's; an error stops the sequencer through its param; the next scene drawn once; the chances are PSET settings; the sequencer never cuts a transition short.
- [disk](scenes/disk.md): scenes.data: its format and versions, the fill, what is known of the file, loading, saving, the autosave and the load prompt. Its rules: the format floor; a removed key under format 10 is not converted; the read through `S.lib.data_files.read` and the backups; the one writer, `save_scenes_to_disk`; a load through `request_load`; no copy of an older format; a load keeps `S.current_scene` only for the same scene; a loaded slot with no name gets `""`.
- [pset](scenes/pset.md): each PSET's `<pset>.scenes.data`, its save, load and delete, and a factory set's scenes. Its rules: scenes travel with the PSET (the live scenes kept as a backup first, the mark); the scenes' PSET hook registered at include, before morph's.
- [validation](scenes/validation.md): `validate_scene` and `validate_scene_data`, what a scene must hold, when to validate. Its rule: a scene's voice is `{active, source, type, values}`, checked by its own type.

## Owns

`lib/scenes.lua` (`S.lib.scenes`) holds the whole scene system:
- `S.scenes`, `S.current_scene`, and the sequencer and transition state on `S` (`S.scene_sequencer_clock`, `S.scene_sequencer_enabled`, `S.scene_sequencer_position`, `S.scene_sequencer_recall_due`, `S.scene_sequencer_next`, `S.scene_transition_clock`, `S.scene_transition_active`, `S.scene_recall_in_progress`, `S.scene_autosave_blocked`, `S.scenes_loaded`, `S.scene_file`);
- `S.lib.scenes.autosave()`, `S.lib.scenes.request_load()` and `S.lib.scenes.SCENE_LOAD` (`docs/notes/lua/scenes/disk.md`);
- `S.lib.scenes.scene_entries(scene_data)`, `S.lib.scenes.voice_entries(voice_idx, voice_data)` and `S.lib.scenes.apply_entries(entries, opts)` (Entries, `docs/notes/lua/scenes/recall.md`) and `S.lib.scenes.revision(slot)`;
- one voice (the groundwork before 3.8): `S.lib.scenes.capture_voice(voice_idx)` (a fresh `{active, source, type, values}`, values holding the voice's scene keys of its current type only; nil for a number that is no voice; `capture_scene` stores one per voice) and `S.lib.scenes.apply_voice(voice_idx, data, opts)` (a copy of data filled, through the local `fill_voice`, and checked, through `valid_voice_data`, then `apply_entries(voice_entries(voice_idx, copy), opts)`: the voice stops or starts by its `active`, its source and then its type go first (the data is checked by its own type, so another type's data applies) and a running voice whose source or type changes gets one sync; it leaves the voice's pattern and lock, the globals, the blocks, `S.current_scene` and a running transition alone, redraws nothing, and returns true; a number that is no voice, or data still invalid after the fill, applies nothing, prints one console line and returns false). A recall is built from `voice_entries`, never from seven `apply_voice` calls, which would run the scene-applied hooks eight times;
- for morph (`docs/notes/lua/morph.md`): `S.lib.scenes.set_value(param_id, value)`, the local `set_scene_value` a recall, a fade step and `apply_entries` set each param through (a registered field's own `set`, else `set_scene_param`), which morph sets each continuous value through as a fade step does; and `S.lib.scenes.takeovers()` (3a, #584), the count of recalls and transitions started: `recall_scene` raises it once per recall that passes its checks (instant, or a fade at its start; not a fade's landing, an empty slot's recall or an invalid scene's), so morph tells a recall made after a move from one made before it, even a second recall of the scene current at the move;
- the banks and names (3.4): `S.lib.scenes.bank_of(slot)` (1 for slots 1-8, 2 for 9-16, nil for a number that is no slot; a bank is only a view, design Question 15), `S.lib.scenes.name(slot)` (the slot's name, `""` for none and for a number that is no slot), `S.lib.scenes.label(slot)` (how a flash names a slot, design §9.3: `S3 dusk` for a named slot, `S3` for one with no name and `S` and the number for a number that is no slot, never an error; the save and empty-slot flashes use it, the quantizer's label stays `"S" .. slot` so `S16 at bar` always fits), and `S.lib.scenes.set_name(slot, text)` (What a scene holds, `docs/notes/lua/scenes/capture.md`);
- `S.SCENE_GLOBAL_PARAMS`, `S.SCENE_BLOCK_DEFAULTS`, `S.SCENE_TRANSITION` (with a running fade's `next_step_due`, `target`, `previous` and `step`);
- `S.lib.scenes.fading_to()` (the scene a running fade goes to, else nil) and `S.lib.scenes.shows_current(slot)` (whether the displays light the slot as the current scene);
- the stepper (the groundwork's design §5): `S.lib.scenes.playable(slot)` (true for a whole slot 1..`NUM_SCENES` that is populated and valid by the cache), `S.lib.scenes.playable_slots(first, count)` (the playable slots of `first, first + 1, ...`, at most `NUM_SCENES` of them, wrapping past 16 to 1, in that order; `{}` for a `first` that is no slot or a `count` that is no whole number of at least 1; the sequencer asks for `1, scene_sequence_length`, the chain for `seq_chain_from, seq_chain_scenes`, the next-scene action for `1, NUM_SCENES`) and `S.lib.scenes.next_slot(position, slots, chances, random)` (`slot, move`: `nil, nil` for an empty list; `S.lib.chance.pick(position, slots, chances, random)`, looked up at each call, when `position` is in `slots`, so a list of the playing scene alone gives it back, `"next"` at 100, 0, 0, applied again, else `"repeat"`, held; for a nil position, or one not in the list (emptied, invalid, outside the range), no draw: the first slot of the list after it in the cyclic order of 1..16, `"next"`; a nil position gives the list's first). The local `following(position, slots)` is that cyclic first, with `position` itself last; the pass's skip and `sequencer_next_slot` use it too;
- `S.lib.scenes.sequencer_next_slot()` (#303): the slot the running sequencer recalls next, else nil. While `S.scene_sequencer_recall_due` (set by `scene_sequencer_start` and each advance, cleared by the loop just before it recalls the position, and by `scene_sequencer_stop`) the count starts at the position (1 past `scene_sequence_length`, as the loop's guard); otherwise at the position + 1, wrapped to 1 past the length as it is now, as the advance does. From there it is the first playable slot (empty and invalid slots are skipped, as the loop skips them, #513, #754), or that slot itself when no slot of the sequence plays. Through a hold the position is the scene playing (or, with no playable scene in the sequence, the slot it holds), so the grids' scene pages light this one at 10, never the position. 3.7: once a pass has drawn its next slot (after the recall, while no recall is due) it is `S.scene_sequencer_next`, kept while it can still play; a kept slot past the length, emptied or invalid is drawn again once, there and then, so the light shows the slot the pass will recall; the reckoning above stands before the first draw and with no playable scene in the sequence. Each draw redraws the screen and grids. The "scene sequencer" invariant: no recall is due and no next slot kept while the sequencer is off, and the sequencer is on exactly while its clock lives (#329);
- capture, recall, transitions, the scene sequencer, the fill (`fill_scene`), validation, scenes.data and each PSET's `<pset>.scenes.data` (its spec for `S.lib.side_files` and its PSET hook, registered at include);
- the global `with_traceback` error handler;
- `S.lib.scenes.scene_data_dir`, `S.lib.scenes.move_aside_unloadable_file` and `SCENE_LOAD.start_flash_seconds`, used by `lib/buffers.lua`;
- cleanup steps 30 (save the scenes), 100 (the sequencer) and 110 (the transition).

Patterns are `S.patterns` (`lib/sequencer.lua`). The grid's scene pages are in `docs/notes/lua/grid/layout_256.md`, `docs/notes/lua/grid/layout_128h.md` and `docs/notes/lua/grid/layout_128v.md`, the header's scene indicator in `docs/notes/lua/ui/header-and-flashes.md`, the SCENES page (and its name entry) in `docs/notes/lua/pages/scenes.md`.

## Parameters

In the PARAMS menu (strata_scenes section):
- `scene_sequencer_enabled` (binary): start/stop automatic scene progression.
- `scene_transition_time` (0-30 s, default 2 s): crossfade duration for smooth transitions.
- `scene_duration` (4-120 s, default 16 s): how long each scene plays before advancing.
- `scene_sequence_length` (1-`NUM_SCENES`, 1-16, default 4): how many scenes to cycle through.
- `scene_chance_next`, `scene_chance_previous`, `scene_chance_random` (numbers 0-100, shown as percents, defaults 100, 0, 0; 3.7): the chances for the sequencer's next scene (The next scene, `docs/notes/lua/scenes/sequencer.md`). PSET only, never in a scene.
- Triggers "save scenes to disk" and "load scenes from disk".

## Usage

Manual performance, from grid page 3 (`lib/grid/pages/scenes.lua`, `docs/notes/lua/grid/pages/scenes.md`: scenes 1-16 on x 1-16 of lines 1 and 2):
1. Build a sound.
2. Hold SV (line 7, x 2) and press a line 1 or 2 key to save it to a scene slot.
3. Change parameters.
4. Save to another slot.
5. Press line 1's keys to switch between scenes instantly.
6. Press line 2's keys to crossfade between scenes.

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
