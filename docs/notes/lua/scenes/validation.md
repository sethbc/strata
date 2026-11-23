## Must not break

- **A scene's voice is `{active, source, type, values}`** (format 10, 3.8: `type` its voice type's key, a string): `values` holds exactly the voice's scene keys of the scene's own type (`S.lib.params_setup.voice_scene_keys(i, type)`: that type's synth keys, the eight grain keys, the ten crossmod keys and the registered scene keys; never `note_cap` or `solo`), each a finite number. `validate_scene` checks a voice by its own type, never the voice's current one, and refuses a voice with any other field, a type that is no key string, a missing key, an unknown key (another type's synth key, a key from a later version) or a value outside its `range` or `limits`. A type this build lacks (a later build's) is valid with every shared key present and valid and any other key a finite number: a recall leaves the voice's type and applies the shared keys only, and a save keeps the scene as it is. A missing type is filled with the voice's own (`S.lib.types.default_key`). A test builds a format 10 scene from a capture, never from a literal.

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
--   each a number; a key with a range (grain_mode 1..2, grain_cloud 1..2, mod_source_<n> 0..NUM_VOICES,
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
