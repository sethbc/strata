# 3.8 facts: what a voice type change touches in Lua, once the groundwork is in

Read from `main` at 59a0a0c1 (the groundwork is not merged yet; where it changes a site, this file describes the code as the groundwork's design, plan and fact files `plan-1a-values.md` and `plan-2a-records.md` leave it, and says so), and norns' Lua at ~/src/norns (227aa044). Three scratch runs (plain Lua 5.3, the repo's stubs, `h.load_strata()`, nothing written in the repo): a param count, a menu count and a stub PSET write and read timing; and the locals probe of `test/unit/structure_test.lua:717-768`, copied and run on the files below. Every figure is marked **measured** (how), **quoted** (from where) or **(est.)**. Nothing was checked on a norns.

## 0. The facts most likely to change the design

1. **The engine, and the test harness's engine stub, know a voice's synth only by its index; Lua never names it.** `voiceSynthDefs = [\strataResonator, \strataFM, ...]` (`lib/engine/StrataVoices.sc:24-25`) is read at a voice's start (`StrataLifecycle.sc:10`), at a re-gate (`:164`) and for every extra note (`StrataNotes.sc:260, 498, 528`). The stub parses the same list (`test/norns_stubs.lua:496-499`) and checks each `setVoiceParam` name against `voice_synthdefs[voice + 1]`'s controls (`:526-529, 664-668`). A type choice therefore needs an engine command or control that Lua sends (a stopped voice's as `setGrainSource` is sent before `voiceOn`, `lib/params_setup.lua:942-952`), and a stub that keeps each voice's current def.
2. **Params are added once, at init, with fixed ids and places; after the groundwork the `synth` record adds `param_order`'s params per voice with `count = fn(voice)`, checked at init** (`lib/params_setup.lua:871-879`; `plan-2a-records.md:82, 106-113`). So a voice that can take another type at run time needs, at init, either every type's params on every voice (hidden or not) or a fixed set of generic slots whose spec, name and formatter change with the type. No param can be added later in its voice's place (the menu and PSET order are `params.params`' order). **Measured** (scratch run, stubs): 1113 param entries, 981 PSET lines; per voice 90-94 ids, of which the synth params are 3-7 (39 in all). "Every voice carries every type's params": with today's 20 distinct synth key names shared, 20 a voice, 140 in all (+101); with three new types of about six params each, freq, amp and pan shared (est.), 29 a voice, 203 (+164); with every type's own keys apart and only freq, amp and pan shared, 22 a voice today (154, +115) and 31-34 with three new types (217-238) (est.).
3. **On a live norns param, the spec, name, formatter, action and an option's list are plain fields; the id, the place and a group's size are not.** `Control` keeps `controlspec`, `name`, `formatter`, `action` and `raw` (0-1) as fields (`~/src/norns/lua/core/params/control.lua:23-38`); `get` maps `raw` through the current spec (`:47-50`), so a new spec moves the value unless `raw` is set again. An `Option` keeps `options` and `count` (`option.lua:16-30`; `set` clamps to `count`, `:37-40`). `hide`/`show` set `params.hidden[i]` and touch only the menu (`paramset.lua:454-472`); a PSET writes and reads every saved param by id, hidden or not (`paramset.lua:513, 527-575`), and reads each value through the spec in force at that line (`control.lua:66-68`), so a re-specced slot needs the type's line earlier in the PSET (the `add_first` precedent, #125, `docs/notes/lua/variation.md:29`). A MIDI map (`norns.pmap`, one `<script>.pmap` per script, `pmap.lua:61-64`) is keyed by id and drives a control's `raw` (`menu/params.lua:737-739`), so a mapped slot follows its new range.
4. **No stored modulation reference names a type-specific synth key.** The per-voice destinations every LFO home routing, R routing and macro target picks from are `v<i>_main`, the grain seven and the registered history, `vfilt`, `dsend`, `rsend` and `amp` (`lib/lfos.lua:96-107, 128-145`, `lib/voice_mix.lua:24-27, 214-216`, `lib/history.lua:78`); the matrix's and the macros' catalogs are built from that list (`lib/matrix.lua:94-112`, `lib/macros.lua:89-125`). `v<i>_main` resolves at each use through `main_param_id` (`lib/matrix.lua:134-145`, `lib/macros.lua:150-154`, `lib/lfos.lua:132-133`). Only gestures store any control id a hand touched (`lib/gestures.lua:5-7`), synth keys included.
5. **freq, amp and pan are type-independent in the code around the synth.** `v<i>_freq` is read by the quantize filter (`lib/variation.lua:106, 171, 205, 221, 228`), the notes' reference and range (`lib/notes.lua:134, 354, 1046`), the step note (`lib/sequencer.lua:403-406`) and MIDI's own note (`lib/midi_in.lua:483-490`). `v<i>_amp` is fast destination 4 (`lib/lfos.lua:57`), an LFO destination (`lib/voice_mix.lua:27`), the stage's level on the other path (`StrataMix.sc:143-166`) and on OSC's watch list (`lib/io/osc.lua:20`). `pan` is a buffer or input grain's pan (`StrataVoices.sc:333`). Every type has to keep freq and amp under those keys; Sub has no pan (`lib/voices.lua:115`), which `lib/grid/faders.lua:35`, `lib/ui/voice_rows.lua:42`, `lib/arc/main.lua:41` and `lib/engine_sync.lua:804` (`pan or 0`) test.
6. **Format 9's validation, as planned, makes the live type unusable as the key set.** `validate_scene` will require a voice's `values` to hold exactly `voice_scene_keys(i)`'s keys, rejecting an unknown key and a missing one (`plan-1a-values.md:183-188`), and a disk load sets the whole file aside when one scene fails (`lib/scenes.lua:1124-1131`; plan ruling 27). Scenes load at init, before any PSET sets a type. If `voice_scene_keys` follows the voice's current type, one scene captured on another type sets every scene aside. The type has to be a scene key and the synth keys checked against the scene's own type, as `source` is checked per scene (`lib/scenes.lua:1250`).
7. **A type is tied to more than `MAIN_PARAMS`.** These are tied to it too: the engine's expression control and range per def (`noteMainRanges`, `StrataVoiceDefs.sc:57-62`, equal to Lua's spec by `docs_test.lua:2163`); the attack and release defaults, kept per voice index as "its def's times" (`NOTES.envelope`, `lib/notes.lua:40-43`; `notes_test.lua:1019, 1078, 1100`); the menu separator `voice <i>: <name>`, fixed text at init (`lib/params_setup.lua:911`); and one spec per key name across types (`VOICE_PARAM_SPECS`, `lib/params_setup.lua:1198-1219`: `ratio` is FM's and Ring's, `mod` Folder's and Ring's). The Resonator's MAIN param is `freq` while its expression control is `rq` (`StrataVoiceDefs.sc:55-58`).
8. **`source` is the model for a discrete per-voice choice, end to end.** It is an option param whose action reaches stopped voices (`AGENTS.md`, "The `voices` table is the only source of values"), sends the engine first, runs `source_change` hooks outside a recall (freeze clears, `lib/freeze.lua:136`), syncs a running voice once and clamps the fader page (`lib/params_setup.lua:944-970`). A recall applies it before the voice's keys and sends one sync afterward (`docs/notes/lua/scenes.md`, "Source changes and the full sync"); a fade switches it at the end. 3.7's keyed option (`S.lib.io_keyed`) stores a choice by key, never by index (`docs/notes/lua/lfos.md:19`), so a list that grows keeps saved choices.
9. **Morph already drops a key one corner lacks; a fade does not.** Morph leaves out "an entry equal in every valid corner, or missing from one" (`lib/morph.lua:193-201`). A fade snapshots each continuous entry with `params:lookup_param(id)` (`lib/scenes.lua:618`), which raises for an id with no param (`paramset.lua:485-494`). Every key a valid scene can hold must name a param that exists.
10. **The hard limits do not bind a type change; AGENTS.md is the tight one.** Each constructor 3.8 would grow has at least 83 free locals (**measured**, the probe; table in section 5). A type field adds no table to the scenes file, and more keys add none: only a nested table per voice adds 112 per level (16 × 7), and room under the 4-times margin is about 1294 tables after the groundwork's 6898 (**quoted**, plan :102, :445; `test/unit/data_files_test.lua:183-187`). AGENTS.md has 225 words left (**measured**, `wc -w` 7775). The `setGrainSource` command row is 34 words and the voice-type rule (`AGENTS.md:333`) 30.

## 1. Where a voice's type is assumed today

"Init" means the site reads the type once, when params are added or the module is included; "use" means at each call.

**The definitions** (`lib/voices.lua:17-232`). Each voice has a `name`, a `param_order` and a `params` table. These become `values` in 1a. The defaults sit in the table and are the params' defaults (`lib/params_setup.lua:920`). After 1a a separate static default table is needed, since `values` holds live values (`plan-2a-records.md:192`). The type is the voice index: voice i always has the type in slot i. Nothing in `S` names a type apart from `name`.

**Reads of `name`** (all at use except the separator):
- `lib/params_setup.lua:911`: the separator `voice <i>: <name>`. Init. Its `name` field can be reassigned later (`separator.lua:14-19`; the menu reads `get_name` at each draw, `paramset.lua:340-343`), but its id stays the init text.
- `lib/pages/main.lua:85`: `update_voice_list`, `MAIN_PARAMS[name].list_name`. Use; rebuilt at start and on every toggle, lock or notes change.
- `lib/pages/main.lua:98-109`: `main_param_entry` and `main_param_id`. Use.
- `lib/pages/main.lua:156`: the details column draws `string.upper(v.name)`. Use.
- `lib/pages/voice.lua:91`: a mod source row shows its voice's `list_name`. Use.
- `lib/pages/voice.lua:133`: the header. Use.

**`MAIN_PARAMS` and `list_name`** (`lib/constants.lua:148-156`), keyed by the type name. The keys are:
- resonator `freq` (`reso`)
- fm `index`
- folder `fold`
- sub `drift`
- pulse `width`
- karplus `decay` (`karp`)
- ring `ratio`

A buffer voice uses `BUFFER_MAIN_PARAM` (`buf_pos`) and an input voice `INPUT_MAIN_PARAM` (`grain_size`) (`:160-161`). Readers: `lib/pages/main.lua:16, 85, 100` and `lib/pages/voice.lua:17, 91, 133`. `list_name` has at most 5 characters (`docs/notes/lua/pages/main.md:5`; `pages_main_test.lua:531`).

**`get_param_spec`** (`lib/params_setup.lua:1198-1227`): one spec per key name, built once (init). A key name must mean one range in every type that uses it.

**The params' creation:**
- Today, `add_voice_params` (`lib/params_setup.lua:902-1193`) adds `param_order` at 918-937. Each param gets a sender, `setVoiceParam(engine_voice, key, ...)`, captured at init (935), and `turn_on_own_delta` (936).
- After 2a, the `synth` record adds the same params in `lib/voices.lua`, with `count = fn(v) #param_order` and `voice_keys = fn(v)` (`plan-2a-records.md:105-113`).
- The count check runs once per voice at init (`lib/params_setup.lua:875-879`).
- After 2a, `voice_scene_keys` lists "every key a built-in record adds as a value", each default its `param_default` (plan, Task 2a Interfaces). The key set is fixed per voice at init.

**`lib/engine_sync.lua`:**
- A start sends the source, then the grain params, then the registered grain keys (`:800-802`).
- Then `voiceOn` with `freq`, `amp` and `pan or 0` (`:803-806`).
- Then, after the hooks, the synth params in `pairs` order (`:736-740, 810`) and crossmod and bend (`:742-754`).
- A sync sends the same groups (`:761-770`).
- After 1a the synth part is "the voice's synth keys, sorted" (`plan-1a-values.md:149`), read from `voice_engine_parts(voice_idx)` at use.
- The engine learns which def to run from nothing Lua sends (fact 1).

**The source tests** (`voice_uses_synth` and `voice_uses_buffer`, `lib/voices.lua:235-242`): source only, never the type. Use. 1a adds `S.lib.voices.is_synth_key(voice_idx, key)`, membership in `param_order` (ruling 8). Use.

**MAIN** (`lib/pages/main.lua`):
- the voice list (85);
- `main_param_entry`, `main_param_id` and `main_fields` (98-120);
- `field_text` (123-128): the format string comes from the type's entry;
- the details name (156);
- randomize through `S.lib.mutation.voice_spec` (227).

All at use.

**VOICE** (`lib/ui/voice_rows.lua:24-49`):
- `section_keys` builds the synth section from `param_order` minus amp and pan;
- the mix section adds `pan` only when present (42).

At use, on every call (`:1-9`). One include-time read: `first_field_row` (`lib/ui/cursors.lua:19`, `voice_rows.lua:129-140`). It is always row 2 for any type that has at least one synth key besides amp and pan.

`lib/pages/voice.lua:204` draws a synth row when `params[key] ~= nil`; 1a changes this to `is_synth_key`. At use. The cursor's anchor is a key (`lib/ui/cursors.lua:27-30`): a key the new type lacks makes it clamp by index (`docs/notes/lua/pages/voice.md`, Must not break 2-3).

**The 256's fader pages** (`lib/grid/faders.lua:33-65`):
- today `fader_param_ids` reads `param_order` on a synth voice;
- `voice_level_fader_keys` reads `params.pan`.

At use. After 2a it reads the synth record's `fader = {{keys = fn(v) param_order, when = voice_uses_synth}}` (`plan-2a-records.md:111`), still at use. A count change needs the clamp the source action does (`lib/params_setup.lua:965-967`).

**MAIN's randomize** (`lib/mutation.lua:197-215`): `pairs(v.params)`, every key but amp. **The mutations** (`:317-381`): `pairs(v.params)`, every key but amp and pan. Both at use. After 2a they become the synth record's `main_randomize` and `mutate` groups over `param_order` (`plan-2a-records.md:112-113`), still at use.

**The LFO and matrix destination list** (`lib/lfos.lua:115-160`): built at init by `build_destinations`. Per voice it holds `main` (resolved at use) and fixed ids that carry no synth key but `amp`. The matrix and macro catalogs are rebuilt when `#params.params` changes (`lib/matrix.lua:114-117`, `lib/macros.lua:128-131`), which happens only at init. Stored by key: a home routing's destination (groundwork §4) and an R routing's `dest`. After the groundwork, a key this build lacks is kept and not played (`docs/design/3.8-groundwork-design.md`, §4 Storage).

**Macro targets**: the same list, plus each LFO's rate and depth, the R depths and the registered targets (`lib/macros.lua:110-123`). No synth key but `amp` (main resolved).

**Step locks** (`lib/sequencer.lua:65-66`): `pos`, `pitch`, `size` and `bookmark` lock `buf_pos`, `grain_pitch` and `grain_size`. The type is never read.

The step note's param (`:403-406`) is `freq` on a synth voice, `buf_rate` on a buffer voice and `grain_pitch` on an input voice. Use. Base overrides (`set_base_override`) are keyed by param id.

**Scenes** (today, `lib/scenes.lua`):
- capture: `pairs(S.voices[i].params)` (`:357-358`);
- entries: `pairs(voice_data.params)` (`:469`);
- validate: rejects a synth key the voice lacks (`:1255-1256`);
- a scene never stores the type.

After 1a: `capture_voice` stores `voice_scene_keys(i)`'s keys, and `validate_scene` requires exactly those (`plan-1a-values.md:173, 183-188`). Use, but the key set is the voice's init set (above).

**MIDI maps**: norns' `pmap` by param id (`~/src/norns/lua/core/pmap.lua`). Strata's own MIDI input maps no CC to a param (`lib/midi_in.lua:459`, panic only); the E16 maps macros only (`lib/io/controllers.lua:50`).

**Notes and expression:**
- Notes read `v<i>_freq` (`lib/notes.lua:134, 354, 1046`) and the per-voice attack and release defaults (`:40-43`). The defaults are init-time per voice index.
- Expression's `main` is the engine's `noteMain` on a synth voice: its def's own control, `buf_pos` on a buffer voice, `grain_size` on an input voice (`lib/expression.lua:87-101`). Use.
- Extra notes are the voice's def, in the engine (`StrataNotes.sc:260`).

**The arc:**
- MAIN's ring 2 is `main_param_id` (`lib/arc/main.lua:26`);
- MAIN's ALT ring 4 is dark for a voice without pan (`:41`);
- VOICE's rings follow `voice_page_group`.

All at use.

**IO modules:**
- OSC watches `v<i>_amp` and `v<i>_mute` (`lib/io/osc.lua:17-20`). Built at include time; type-independent keys. norns' own `/param/<id>` reaches any id.
- crow and MIDI out read an LFO's destination through `S.lib.lfos.is_engine_run` (`lib/io/crow.lua:635`, `lib/io/midi_out.lua:747`).
- Their pitch comes from note events, never from a synth param (`lib/io/crow.lua:213-249`).
- The controllers map macros only.

No IO module names a type-specific key.

## 2. What cannot change after init

**norns** (all from ~/src/norns/lua/core):

**Can change on a live param** (each is a field of the param table):
- `controlspec`, `name`, `formatter` and `action` (`params/control.lua:23-31`);
- an option's `options`, `count` and `name` (`params/option.lua:16-30`);
- a separator's `name` (`params/separator.lua:14-19`);
- visibility, through `params:hide(id)` and `params:show(id)`, which set `params.hidden[index]` (`paramset.lua:454-472`).

`params:set_action(id, fn)` exists (`:414-417`). Changing `controlspec` leaves `raw`, so the shown value is `raw` mapped through the new spec (`control.lua:47-50`) until the script sets it.

**Cannot change:**
- The id. `params.lookup[id]` is set at `add` (`paramset.lua:197-201`), and a PSET line and a map find a param by it.
- The place. `params.params` is appended to in order (`:195`), and the menu, PSET writes and PSET reads follow that order.
- A group's size. `self.group` counts down at `add` (`:196`), the menu skips `params:get(group)` entries (`menu/params.lua:49-58`), and `Group:get` returns the fixed `n` (`params/group.lua:14-24`).

A param added after init lands at the end of `params.params`, outside its voice's section (est., from `:195`).

**The menu and hidden params:**
- `build_page` lists the visible params only (`menu/params.lua:49-58`; a group's members through `build_sub`, `:60-67`).
- It runs when EDIT or MAP is entered (`:144, 150`) and in `_menu.rebuild_params()`.
- `_menu.rebuild_params()` (`:697-707`) rebuilds the page only while the menu is in EDIT or MAP, and redraws. It does not clamp `m.pos`. A page that shrank below the cursor makes `page[m.pos+1]` nil (`:155, 244, 419`) (read only, unverified on a device).
- MAP mode shows the same page, so a hidden mapped param cannot be seen or unmapped there, but its CC still sets it (`:720-744`).
- norns' own `lib/lfo.lua:141, 491, 510` and `core/midi.lua:413` call `rebuild_params` after hiding.

**A PSET:**
- `write` writes `id: get()` for every param with an id and `save`, except triggers and separators, hidden or not (`paramset.lua:498-520`).
- `read` sets each line's param by id through its own `set`, once, with its action unless silent, in file order (`:527-575`). A control's line goes through the current spec (`control.lua:66-68`). An option clamps to `count` (`option.lua:37-40`).
- Strata then sets every param the file has no line for to its default (`docs/notes/lua/params.md`, Must not break, #628), so params a new type adds load at their defaults from an older PSET.

**Strata's registries that close at init** (`lib/state.lua:73-78`): `voice_params`, `scene_fields`, `lfo_destinations`, `fx_params`, `start`, `menu_close`, `scene_blocks` and `pset_hooks`. The other 24 stay open (`docs/notes/lua/state-and-voices.md:231`).

**Lists built once from the voices:**
- `S.LFO_DESTINATIONS` (init, `lib/lfos.lua:115-160`).
- The matrix and macro catalogs (rebuilt only when the param count changes, so effectively at init).
- The engine senders (`S.engine_senders[id]`, one per param at init, `lib/params_setup.lua:763-765, 935`).
- OSC's watch list (include time).
- MIDI maps are not built: norns keeps them by id across sessions.

**Built at use:** the fader groups, VOICE's rows, MAIN's fields and list, the randomize and mutation draws, and `voice_engine_parts` and `voice_scene_keys` (after 1a).

Two record rules bear on a type choice:
- A record's `count` is checked per voice at init (`lib/params_setup.lua:875-879`).
- A registered record's `scene_defaults` function must give every voice the same keys (`lib/state.lua:222-231`). The groundwork's built-in records sidestep this by carrying no `scene_defaults` table (plan, Task 2a Interfaces), so only the built-in `synth` record can have keys that differ by voice.

**The ways a voice could take another type's params:**

| Way | Param ids | PSETs | MIDI maps | Menu | Params (est.) |
|---|---|---|---|---|---|
| A. Every voice adds every type's keys, names shared across types (one `v<i>_ratio` for FM and Ring) | today's ids kept; new keys added | every key saved; 3.7 PSETs load (new keys at default, #628) | kept by id; a map on a hidden key still sets it | +101 rows unhidden today; hide the others and `rebuild_params` | 140 synth params today; 203 with three new types |
| B. Every voice adds every type's keys under per-type ids, freq, amp and pan shared | today's ids renamed (or kept for each voice's original type only) | a 3.7 PSET's `v1_rq` line names no param if renamed | a map of a renamed id is lost | as A, larger | 154 today; 217-238 with three new types |
| C. Generic slots (freq, amp, pan and N slots re-specced by type) | today's synth ids go but freq, amp and pan | the type's line must come before the slots; a read applies each value through the spec in force | a map follows the slot, so its meaning changes with the type | no growth; names change in place (`name` is a field) | 7 a voice with N = 4 (Resonator's four besides freq, amp and pan), 49 in all |
| D. A voice's type is fixed at init from a setting (read before the params are added, like the freeze mode's options from the tier, `docs/notes/lua/freeze.md`, Must not break 4) | per voice as today | a PSET from another setting has lines for absent ids (skipped) | maps to absent ids do nothing | as today | as today |

With A and B, a sender gated only on `active` would send every type's keys at a start and a sync. The stub refuses names the voice's def lacks (`test/norns_stubs.lua:664-668`). The engine keeps any name in `voiceControls` and passes on only the def's controls (`StrataVoices.sc:281-293`, `StrataUtil.sc:51-58`). The sends would need gating on the current type.

**Counts today** (**measured**, the scratch run):
- 1113 param entries (37 separators, 30 groups); 981 PSET lines (20,068 bytes).
- Per voice 90, 92, 93, 93, 93, 93 and 94 ids (648 in all). Of these:
  - 14 per voice are the IO and zone params, in groups;
  - 3-7 per voice are synth params (39 in all).
- The PARAMETERS menu's top level has 629 rows: 550 voice params and 28 voice separators. The voices sit in no group, so a voice's params add no group-size constraint. The other 484 params are in 30 groups.

**norns' cost of many params.** Nothing in the repo or norns' docs measures it.
- **Measured**, on this development machine (x86, Lua 5.3, the repo's stub `ParamSet`, not norns'): `params:write` 0.92 ms and `params:read` 3.24 ms for 981 lines, about 3.3 µs a line read, actions included.
- On a CM3 or Pi 4, with norns' own `ParamSet` and real engine sends, these are unknown. They grow in proportion to the lines: +10 % (A today) to +23 % (B with three new types) (est.).
- The menu's top level would grow by the same rows unless hidden.

## 3. A scene and a type

**Where a type would be stored.** Format 9 stores `scene.voices[i] = {active, source, values}` (`docs/design/3.8-groundwork-design.md`, §3). `source` sits beside `values`, and:
- it is checked per scene (`lib/scenes.lua:1250`);
- it is discrete, the voice's second entry after `active` (`lib/scenes.lua:468`);
- it is applied before the voice's keys, with the `v<i>_source` action's sync held back during a recall (`lib/params_setup.lua:957-963`), and synced once after (`lib/scenes.lua:595-600`; scenes.md, "Source changes and the full sync");
- in a fade it switches at the end, through `recall_scene_instant`.

A type stored as a sibling field would follow the same path. It would sit before `source` or after it, and before the synth keys. Validation would read the scene's type to pick its synth key set (fact 6). A format 9 scene with no type field can be filled with the voice's built-in type: its synth keys are exactly that type's, so it stays valid without a format change (est., from `plan-1a-values.md:183-188` and the fill's order, missing keys then `normalize_scene`, `:176`).

**A key the voice lacks or a scene lacks, today and after 1a:**
- **Today, `validate_scene`** rejects a synth key the voice lacks (`lib/scenes.lua:1255-1256`) and an unknown registered key (`:1270-1275`; decisions 3.2:11). A missing synth key is allowed and simply not applied (no fill for synth keys, `lib/scenes.lua:300-321`).
- **After 1a**, every key `voice_scene_keys(i)` lists must be present after the fill, and any other key is rejected (`plan-1a-values.md:183-188`).
- **`fill_scene`** fills missing keys from their defaults, then runs each record's `normalize_scene` (`:176`).
- **`apply_voice(i, data)`** fills a deep copy and refuses invalid data with one console line. It applies the voice's entries, starting or stopping it by `active` and syncing once on a source change. It leaves the pattern, the lock, the globals, the blocks and a running fade alone (`plan-1a-values.md:174-178`). What it does during a running fade is 3.8's (ruling 6).
- **A recall** applies every entry; an entry naming no param raises in its action (est.: `params:set` on an unknown id raises in `lookup_param`, `paramset.lua:485-494`).
- **A fade** snapshots every continuous entry's current value with `params:lookup_param` (`lib/scenes.lua:618`), so an unknown id raises at the fade's start.
- **Morph** pairs entries by key and leaves out one missing from any valid corner (`lib/morph.lua:193-201`), so a synth key one corner's type lacks is neither blended nor switched there. A type entry that differs between corners would switch at the crossing, as source does (est.).

**A type switch on a running voice, in Lua:**
- **The start path.** A stopped voice only records the type (as source does). A running voice needs the engine to replace its voice synth. Lua then sends the new type's synth keys: a sync (`sync_voice_values_to_engine`), whose synth part after 1a is the voice's synth keys sorted, read at use. The grain, registered and crossmod parts do not change. A start needs the type sent before `voiceOn`, since `voiceOn` builds the def (`StrataLifecycle.sc:10`).
- **Extra notes.** An extra note on a synth voice is its def (`StrataNotes.sc:260`), and its slot is held in `lib/notes.lua`. A switch leaves notes of the old def unless they are cut or replaced. `S.lib.notes.recall_switched` already cuts a voice's extras after a recall's source switch to a frozen synth voice (`lib/notes.lua:1035-1037`), and `cut_extras` is local there.
- **Audio freeze.** A frozen synth voice's ring holds the old type's sound. A source switch unfreezes through the `source_change` hook (`lib/freeze.lua:136`; AGENTS.md, Freeze). The notes module takes a frozen voice's reference from `freq` (`lib/notes.lua:1042-1047`).
- **Step locks and base overrides** are on `buf_pos`, `grain_pitch`, `grain_size` and, for a step note, `freq`, `buf_rate` or `grain_pitch` (`lib/sequencer.lua:65, 403-406`). None is type-specific while every type keeps `freq`.
- **LFO home routings, R routings and macro targets** can aim at a synth key only through `v<i>_main` (resolved at use) or `v<i>_amp` (fact 4). The matrix's one sum per resolved id, and its one more send when a sum returns to 0 (groundwork design §4), already handle a `main` that re-resolves. The groundwork tests that for a source switch between a Lua and a fast param (plan, Review Focus 5); a type switch moves `main` between two Lua params (`freq` and `index`, say), since no type's main is fast today. A gesture's recorded events can name any synth key (`lib/gestures.lua:5-7`).
- **The undo.** `S.undo` holds param ids and values (`lib/mutation.lua:110`) and is cleared by an edit of a param it holds (`:235`), by a recall (scenes.md, Must not break) and by a new randomize. A type change clears it only if its action does. A held MAIN or VOICE undo would otherwise restore the old type's keys (with A and B, invisible params; with C, values in the old type's meaning).
- **The lock.** Randomize, mutation, drift and scatter leave a locked voice alone, but it can still be edited (AGENTS.md, Lock), and a recall applies a locked voice's values and its lock from the scene (`lib/scenes.lua:519-526`). A type change from a param or a recall would reach a locked voice unless the design says otherwise.
- **Redraws.** MAIN's list needs `update_voice_list()` (`lib/pages/main.lua:71-91`). The 256 needs its fader-page clamp (`lib/params_setup.lua:965-967`). The menu needs `_menu.rebuild_params()` if params are hidden or shown.

## 4. Type-independent values

**Shared by every type** (after 1a, 75-79 keys a voice, `plan-1a-values.md:22-45`):
- the 9 grain keys and 10 crossmod keys;
- all 53 registered keys: the voice filter and sends, loop, variation with quantize, the notes record's `note_cap`, `attack` and `release`, expression, envelopes, the sequencer's `seq_*`, freeze, history, bookmarks, scan and follow, slices, mute and solo.

Of the 3-7 synth keys, `freq` and `amp` are shared in every voice, and `pan` in every voice but Sub (fact 5).

The fast destinations are pitch `grain_pitch`, position `buf_pos`, size `grain_size`, cutoff `filter_freq` (the stage's voice filter) and amp `amp` (`lib/lfos.lua:57`). All are type-independent while every type has `amp`.

**Type-specific:**
- the other synth keys: `rq`, `noise`, `mod1`, `mod2`; `ratio`, `index`, `modFreq`; `fold`, `mod`; `drift`; `width`, `cutoff`, `res`; `decay`, `damping`, `excite`; `ratio`, `mod`, `brightness` (`lib/voices.lua:22-205`);
- `MAIN_PARAMS`'s key;
- the engine's `noteMain` control;
- the default attack and release (`NOTES.envelope`, held per voice: a type change keeps the old values unless it sets them).

**`v<i>_main`** is `main_param_id(i)`, which is `"v" .. i .. "_" .. main_param_entry(i).key` (`lib/pages/main.lua:98-109`):
- a synth voice uses `MAIN_PARAMS[S.voices[i].name]`;
- a buffer voice uses `buf_pos`;
- an input voice uses `grain_size`.

It is resolved at each use by the matrix (`lib/matrix.lua:134-145`), the macros (`lib/macros.lua:150-154`), the LFO list's `resolve` (`lib/lfos.lua:132-133`), MAIN's E3 and fields (`lib/pages/main.lua:114-128, 248`) and arc ring 2 (`lib/arc/main.lua:26`). It is never stored resolved.

**A buffer or input voice and its type's params today:**
- A start and a sync still send every synth key (`lib/engine_sync.lua:736-740`), and the engine keeps them.
- Only `amp` (the stage's level), `pan` and `bend` (`voiceLevelGrainControls`, `StrataVoices.sc:333`) act on a buffer or input voice.
- VOICE shows `buf_pos`, `buf_rate` and `buf_scan` in the synth section of a buffer voice and no synth section on an input voice (`lib/ui/voice_rows.lua:16-34`).
- The faders show buf ×3, amp and pan (buffer), or grain ×6, amp and pan (input) (`lib/grid/faders.lua:45-58`).
- Randomize and mutation draw the buffer keys or none (`lib/mutation.lua:200-211, 343-355`).
- MAIN shows `buf_pos` or `grain_size`.
- Expression's `main` is position or size (`lib/expression.lua:92-95`).

So on a buffer or input voice the type matters only for pan's presence. The type's values return when the source goes back to synth.

## 5. Limits

**Free locals** (**measured**: the probe's binary search of `structure_test.lua:717-768`, copied to a scratch folder and run on `main` 59a0a0c1; the groundwork will move them, e.g. 2a deletes `add_voice_params`' 291 lines and adds three records in `lib/voices.lua`):

| File | Constructor free locals |
|---|---|
| `lib/voices.lua` | 194 |
| `lib/params_setup.lua` | 173 |
| `lib/engine_sync.lua` | 151 |
| `lib/scenes.lua` | 151 |
| `lib/mutation.lua` | 179 |
| `lib/state.lua` | 168 |
| `lib/pages/main.lua` | 176 |
| `lib/pages/voice.lua` | 164 |
| `lib/grid/faders.lua` | 190 |
| `lib/ui/voice_rows.lua` | 190 |
| `lib/notes.lua` | 138 |
| `lib/expression.lua` | 156 |
| `lib/lfos.lua` | 139 |
| `lib/matrix.lua` | 147 |
| `lib/macros.lua` | 144 |
| `lib/arc/main.lua` | 187 |
| `lib/variation.lua` | 176 |
| `lib/freeze.lua` | 192 |
| `lib/sequencer.lua` | 83 |
| `lib/midi_in.lua` | 165 |
| `lib/grid/layout_256.lua` | 167 |
| `lib/constants.lua` (main chunk) | 152 (48 top-level locals; `MAIN_PARAMS` is one) |

Every file's main chunk other than constants.lua keeps 200 (each is `return function(S)`). The floor is 30. None is close.

**The scenes file:**
- After the groundwork the largest file is 6898 tables (**quoted**, plan :102, :445), with a voice at 2 tables (the voice and its `values`).
- A type field (a number or a string) adds no table; more keys in `values` add none.
- A nested table per voice in every scene (one per type held, say) adds 112 tables per level (16 × 7).
- `max_tables` is 32768 (`lib/data_files.lua:31`), and the test keeps it at least 4 times the largest (`test/unit/data_files_test.lua:183-187`). That allows a largest of 8192, so about 1294 more tables, 11 such levels a voice, before `max_tables` must rise.
- Bytes: 16 full scenes are 788 KB to 1.1 MB (**quoted**, `lib/data_files.lua:24, 33-34`) against `max_bytes` 4 MB. Every voice holding every type's keys adds about 35 KB today and 64-89 KB with three new types (est.: 14-31 more keys × 112 voice-scenes × about 22 bytes a key).

**AGENTS.md:** 7775 words of 8000 (**measured**, `wc -w`; `docs_test.lua:780-786`); the groundwork rewrites its lines no longer (design, Anti-goals). What a type adds, measured on today's rows:
- a command row like `setGrainSource`'s: 34 words;
- a module row: 9 words (`lib/slices.lua`'s) to about 20;
- a rewrite of `AGENTS.md:333` (30 words) and of `:320`, which 2a rewrites;
- any new "Must not break" pointer line: about 25-50 words each (est., from the file's own lines);
- engine files named in the engine row: 1 word each.

## 6. Tests that pin a voice's type, and the fixtures

**Unit tests** (file:line of `test(`):

*Param list and specs*
- `params_setup_test.lua`:
  - 11, "every voice param has a menu param, ordered by param_order";
  - 398, "every voice param has its own spec: range, warp and step";
  - 416, "a voice's params follow param_order between its heading and its granular separator".
- 1a adds "every param's id, default and spec is 3.7.0's" against `test/fixtures/3.7.0-params.lua` (plan Global Constraints; `plan-1a-values.md:235`). Any new param is an allowed difference it must list.

*Engine sends and engine source*
- `engine_sync_test.lua`, 1a's "the synth params go out sorted: voice 1 gives `amp`, `freq`, `mod1`, `mod2`, `noise`, `pan`, `rq`" (`plan-1a-values.md:238`).
- `docs_test.lua`:
  - 753, "the engine stub rejects param names the SynthDefs do not have (#24)";
  - 1694, "params.md names every Strata group in menu order and every param of a voice's last three parts (#343)";
  - 1836, "voices-and-grains.md has a row for every synthesis param, with its range, unit and default (#395)", a table per voice under its name;
  - 2163, "the engine's expression controls and ranges equal the Lua specs", the seven defs and their controls written out;
  - 2192.
- `stubs_test.lua:1329`.
- `voices_test.lua`:
  - 10, input voices' main param, faders and randomize (`6 + 2 + 9` faders, `:24-25`);
  - 73, "the pulse voice starts at res 0.8";
  - 93, "the pulse res mirror is the engine's".

*MAIN, VOICE and cursors*
- `pages_main_test.lua`:
  - 531, "every voice type's list name is at most 5 characters";
  - 611, "main_param_id and main_param_entry's label name each voice's E3 and arc ring 2 param".
- `pages_voice_test.lua`: 297, 330, 472, 486, 786 ("a synth voice's synth section draws every synthesis param but amp and pan (#557)"), 875.
- `ui_cursors_test.lua`: 89 ("VOICE rows for a synth voice"), 131 ("the Sub voice has no pan row"), 176, 230, 324, 357.

*Notes, quantize and per-voice defaults*
- `notes_test.lua`:
  - 1019, "attack and release default to each voice's times of 3.4";
  - 1078;
  - 1100, "the engine's default times equal NOTES.envelope".
- `variation_test.lua:322`, "quantize snaps freq on all seven synth voices but never index, fold or the other main params".
- `scenes_test.lua:3345`, "a record's scene defaults may depend on the voice".
- 1a's "`capture_voice` holds exactly the scene keys: ... Sub has no pan".
- `registries_test.lua:64, 142, 291`.

*Faders, mutation and arc*
- `grid_layout_256_test.lua`:
  - 11, I8: resonator's and FM's fader values;
  - after 2a, the page counts per voice and source (`plan-2a-records.md:217-226`: resonator 32 faders and 8 pages, folder 30, sub 28 ...).
- `mutation_test.lua`:
  - 259 and 504 name voice 1's synth ids;
  - 2a's "MAIN's randomize draws 3.7's sets on every voice and source".
- `arc_pages_test.lua:729`, `lfos_test.lua:650`.

*Whole system*
- `system_37_test.lua:88`, "a fresh Strata has every 3.7 feature off": compares the start calls with 3.6.0's.

**Fixtures** (`test/fixtures/`):
- `3.6.0-start-calls.lua` holds every voice's `setVoiceParam` names by voice index. It would move with a type field sent at a start, or a new start command.
- `3.6.0-files.lua` is a 3.6 scenes file and PSET with each voice's synth keys. After format 9 its scenes are set aside, but its PSET part still loads by id (0a/4a, plan ruling 2).
- `3.7.0-params.lua` is added by 1a.
- The format 9 fixture is added by 4a (ruling 2). Its voices carry no type, so it is the test of "each voice's type defaults to today's".

The stub: `test/norns_stubs.lua:496-499, 526-529, 664-668` keys a voice's accepted `setVoiceParam` names by index (fact 1).

## Where the roadmap or the notes are wrong or silent

- `ROADMAP.md:117-119` lists what the design decides but is silent that the engine picks a voice's def by index (`lib/engine/StrataVoices.sc:24-25`), that Lua sends no type, and that the test stub checks names by index (`test/norns_stubs.lua:664-668`). Each needs a change for any choice of type.
- `ROADMAP.md:119` ("whether old scenes need a migration (each voice's type defaults to today's)"): format 9's exact-key validation (`docs/design/3.8-groundwork-facts/plan-1a-values.md:183-188`) answers it only if validation reads the scene's own type. With the live type, a file loaded at init sets every scene aside once one voice's scene differs (`lib/scenes.lua:1124-1131`).
- `docs/design/3.8-groundwork-design.md:100` ("A voice type becomes a record's set of keys"): a record's params are added once per voice with a `count` checked at init (`lib/params_setup.lua:871-879`), and after 2a `voice_scene_keys` is the keys each record added (plan, Task 2a Interfaces). The key set is then a function of the voice at init, not of a type that can change. A registered (non-built-in) record cannot give voices different keys (`lib/state.lua:222-231`).
- `AGENTS.md:333` ("A new voice type needs a `MAIN_PARAMS` entry ... and `get_param_spec()` specs") is silent on:
  - the engine's `noteMainRanges` and its docs test (`lib/engine/StrataVoiceDefs.sc:57-62`, `test/unit/docs_test.lua:2163`);
  - `NOTES.envelope` (`lib/notes.lua:40-43`);
  - the user page's table per voice (`test/unit/docs_test.lua:1836`);
  - `freq` and `amp` (and `pan`) being keys every type must keep (fact 5).
- `docs/notes/lua/state-and-voices.md:31, 34-35` says `name` is "the voice type" and `params` "per voice type". In the code a voice's type is its index's: nothing reads `name` to pick the engine def, and the `voice <i>: <name>` separator is fixed at init (`lib/params_setup.lua:911`).
- `lib/params_setup.lua:1198-1219` holds one spec per key name across types, and no note says so. A new type that reuses `cutoff`, `decay`, `mod` or `ratio` must take that range or a new name. Pulse's `cutoff` (100-8000 Hz) is apart from the voice filter's `filter_freq`.
- `lib/notes.lua:40` calls the attack and release defaults "its def's times", but they are kept per voice index. A voice that changes type keeps them unless the design says otherwise.
- `docs/notes/lua/scenes.md` ("A voice's synth and grain params follow `pairs` over the scene's tables") is 1a's to rewrite, to sorted order.

## Unsure

- **norns' PSET and menu cost with 100-230 more params** on a CM3 or Pi 4: only a stub timing on an x86 development machine was run (section 2). It needs a device (#6).
- **Whether norns' PARAMETERS menu errors when `rebuild_params` shrinks the page below its cursor.** Read from `lua/core/menu/params.lua:155, 244, 419, 697-707`, not run.
- **Whether a hidden param with a MIDI map can be unmapped.** MAP mode lists only visible params (`menu/params.lua:144-151`); not run.
- **Whether attack and release reach a buffer or input voice's grain synth.** Not read; it decides whether those type-tied defaults matter off the synth source.
- **The groundwork's final shapes**: field names, the exact `voice_scene_keys` order, whether `turn_on_own_delta` and the sender gating move. Taken from the plan and its fact files, since the code has not landed.
- **The engine's side of a switch** (replacing a running voice's def, its kept `voiceControls`, memory): the engine fact files' to say. Read here only as far as `StrataVoices.sc:281-293` and `StrataUtil.sc:51-58`.
