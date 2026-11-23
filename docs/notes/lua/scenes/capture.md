## Must not break

- Every user's scene save (`S.lib.scenes.save`) writes the file at once through `S.lib.scenes.autosave` (#327), and its header flash says `saved S<n>` only when the scene is on disk, `S<n> not on disk` otherwise (a failed or blocked write), the slot named through `S.lib.scenes.label` (`saved S3 dusk`). Every flash that names a scene goes through `label`, as the empty-slot recall's `S<n> empty` does; the quantizer's label alone stays `"S" .. slot`. `S.scene_file.unsaved` is true exactly while a scene captured in this session may not be in the file; set it wherever a scene reaches memory without reaching the file.
- Every slot has a name (format 6, 3.4): `validate_scene` rejects a slot, empty or not, whose `name` is not a string of at most `SCENE_NAME_MAX` (12) printable ASCII characters (bytes 32-126), so a name is part of every slot from the load on. A slot is named only through `S.lib.scenes.set_name`, which keeps the printable ASCII characters of its text, cut to 12, raises the slot's revision and writes the file at once (`autosave`, as a save does: a name never reaches memory without the file, or `S.scene_file.unsaved` says so). A capture keeps the slot's name.

## What a scene holds

- **Storage**: `S.scenes`, `NUM_SCENES` slots (16: 1-16, two banks of `SCENE_BANK_SIZE`, 8; 3.4), each `{name, populated, data}`. The `lib/scenes.lua` constructor builds the array afresh on every script load, empty by default. A slot's `name` is the player's, `""` for none: an empty slot's is `""`, a slot can be named whether it holds a scene or not, and the name stays with the slot through captures. `S.lib.scenes.set_name(slot, text)` names one: the printable ASCII characters of `text` (bytes 32-126; the rest are dropped), cut to `SCENE_NAME_MAX` (12); a changed name raises the slot's revision, asks for a redraw and is written at once (`S.lib.scenes.autosave`); it returns false (and changes nothing) for a number that is no slot or a text that is no string. On a load, a slot with no name gets `""`; every other name loads as it is. No code or format assumes a one-digit slot.
- **Revisions**: `S.lib.scenes.revision(slot)` is 0 until the slot's data first changes, then rises at each change: a capture of the slot, and any load from disk that replaces the scenes (every slot rises; a load that finds no file or an unreadable one changes none). A number that is no slot reads 0.
- **Data**, a complete snapshot:
  - every voice parameter (synthesis, granular including the buffer params, cross-modulation, and each registered record's scene keys) in the voice's `values` (`data.voices[i] = {active, source, type, values}`, format 10, `SCENE_DATA_VERSION`: the voice holds its type, and `values` its own type's synth keys) and each voice's source (not buffer contents);
  - voice active and lock states (stored as `locked`);
  - pattern data (all 7 voices × 16 steps);
  - global parameters: master density, tempo, filter, delay, reverb, drift, mutations, and each LFO's shape, mode, rate, depth, offset, destination and state;
  - format 3 (3.2): each voice's registered params (since format 10 in `data.voices[i].values[key]`, the keys of every record's `scene_defaults`), the registered global fields (`S.registry.scene_fields`, stored like the other globals) and each LFO's offset (#103);
  - 3.4: each registered scene block's value, `data[record.key]` (Scene blocks, `docs/notes/lua/scenes/recall.md`).
- **Sequencer**: automatic scene progression with configurable timing.
- **Transitions**: instant recall, or a smooth crossfade between scenes.

## Capture

`S.lib.scenes.save(scene_num)` is the user's save (the grid's hold and SCENES' ALT+K3): for a slot in 1..`NUM_SCENES` it calls `capture_scene`, writes scenes.data (`S.lib.scenes.autosave`, #327), flashes `saved <label>` in the header when the scene is on disk or `<label> not on disk` when the write failed or was blocked (`S.lib.scenes.label`: `saved S3`, or `saved S3 dusk` for a named slot), redraws grid and screen and returns true; any other slot does nothing and returns false. `capture_scene` itself stays silent and writes nothing (tests and layout states call it).

`capture_scene(scene_num)`:

```lua
function capture_scene(scene_num)
  -- Captures the complete current state:
  -- - every voice as capture_voice gives it: {active, source, type, values}
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
