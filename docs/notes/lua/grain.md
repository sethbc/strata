## Must not break

- The six params reach the engine only through their registered grain keys (`setGrainParam` while the voice runs, and the voice sync and start, before `voiceOn`, in `send_order`); never `engine.*` from an action. A start sends `windowShape`, `windowSkew`, `grainProb`, `overlapOn`, `grainOverlap` and `panSpread`, each at its default the sound of 3.7 (the Hann's table plays as `GrainBuf`'s own window), the start's differences from 3.7.0 the fixture allowances name.
- **Master density reaches the overlap through Lua** (3.8 ruling 35): `grainOverlap` goes out as `v<i>_grain_overlap` × `engine_param_value("master_density")`, and `send_master_density_to_engine` (`lib/engine_sync.lua`) sends a running voice in overlap mode its `grainOverlap` in place of its `grainDensity`: still one message a running voice, as the budget counts it. The cloud's switch resends the rate the voice now plays (its overlap or its density, with the master density), so a master density moved in the other mode never lingers.
- **No fader group of its own** (ruling 31): shape and skew are faders of the built-in `grain` record (`lib/voices.lua`), after `grain_spread` and before `grain_mode`, where 3.7's envelope was; the record's `fader` is false.
- It draws nothing: no `main_randomize`, `mutate` or `randomize`, so MAIN's randomize, the mutations, the drift and VOICE's ALT+K2 leave the six alone.
- `grain_cloud` is discrete (`{1, 2}`): a transition sets it at its end; the five others crossfade, each within its `scene_ranges`.
- In overlap mode VOICE's density row shows `grain_overlap` (`voice_rows.swaps`, ruling 36); MAIN's third field and arc ring 4 stay on `grain_density`.
- Shape and skew are LFO, matrix and macro destinations moved in Lua (`set_extra_offset`), never fast destinations; an LFO never sets their params.

## lib/grain.lua (`S.lib.grain`)

One registered voice-param record (`S.register_voice_params`, `docs/notes/lua/params.md`), `grain_controls` ("grain" is the built-in record's), included right after `lib/voices.lua` so it is the fourth record: its params follow the cross-modulation ones under each voice's `extras` separator, before history.

| Param | Spec | Default | Engine (`grain_keys`) |
|---|---|---|---|
| `v<i>_grain_shape` | control 0-1, lin, step 0.01, `%.2f` | 0.57 | `windowShape` |
| `v<i>_grain_skew` | control -1..1, lin, step 0.01, `%.2f` | 0 | `windowSkew` |
| `v<i>_grain_prob` | control 0-100 %, lin, step 1 | 100 | `grainProb` = x / 100 |
| `v<i>_grain_cloud` | option {density, overlap} | 1 | `overlapOn` = x - 1, `carry = false` |
| `v<i>_grain_overlap` | control 0.25-16, exp, step 0, `%.2f x` | 2 | `grainOverlap` = x × master density |
| `v<i>_pan_wander` | control 0-100 %, lin, step 1 | 50 | `panSpread` = x / 100 |

- The default shape, 0.57, is k / 7 for the Hann's shape index 4 (the engine rounds `windowShape × 7`; 0.50 to 0.64 give the Hann), so a fresh voice plays 3.7's window. The engine's bank and pick: `docs/notes/engine/grains.md`.
- `M.GRAIN` holds the record's names, ranges, defaults and LFO labels; `M.overlap(voice_idx)` is true while the voice's cloud is overlap (false before init); `M.FORMATS` and `M.text(key, value)` the params' texts.
- VOICE: the record's rows `grain_shape`, `grain_skew`, `grain_prob`, `grain_cloud`, `pan_wander` end the `grain` section, after the built-in grain rows; its `swaps` puts `grain_overlap` in the density's row while `M.overlap` holds. `layout_states`: each voice with every new row at both ends of its range in overlap mode, the cursor on each row in turn.
- LFO destinations `v<i> shape` and `v<i> skew` (`S.register_lfo_destination`), the first registered ones in each voice's group, so matrix destinations and macro targets too (`lib/matrix.lua`, `lib/macros.lua` read the list).
- 3.7's `v<i>_grain_env` is gone with `GRAIN_ENV_OPTIONS` and the engine's `envShape`: a 3.7 PSET's line names no param (norns skips it, printing nothing), and a scene key `grain_env` no longer exists. `h.scramble_state` sets `v<i>_grain_shape` from the draw the envelope took, so every later seeded draw keeps its place.

Tests: `test/unit/grain_test.lua` (specs, defaults and texts at both ends; sends of a running and a stopped voice and a start's order; master density in each mode; the LFO, matrix and macro destinations; the fader place and fm's count; the VOICE rows in overlap mode and MAIN's third field; randomize, mutation and drift; scenes; an old PSET's envelope lines; a triggered voice in overlap mode).
