# 3.8 plan facts: effects (1a, 1b, 2a, 3a, 4a)

Read against `main` at 2edbfa96: `docs/design/3.8-design.md` (whole), `docs/design/3.8-facts/engine-effects.md` (whole, with its appendix), `lib/engine/StrataEffects.sc`, `StrataMix.sc`, `StrataRecord.sc` (tap), `StrataModulation.sc` (`voiceMixMod`), `StrataPerformance.sc` (`highMemoryBytes`), `lib/voice_mix.lua`, `lib/delay_sync.lua`, `lib/params_setup.lua` (fx group, read hook), `lib/engine_sync.lua` (fx senders), `lib/scenes.lua` (scene globals), `lib/state.lua` (`register_fx_params`), `lib/pages/fx.lua`, `lib/arc/fx.lua`, `lib/arc/core.lua`, `lib/arc/main.lua`, `lib/ui/header.lua`, `lib/ui/alt.lua`, `lib/constants.lua` (`HEADER`), `test/norns_stubs.lua` (engine spec parser, argument checks, font advances), `test/sync_check.lua`, `test/unit/docs_test.lua`, `test/unit/params_setup_test.lua` (fixture test), `test/engine_check.scd` (harness, `areaOrder`), `test/engine_check/{effects,mix,record,modulation,structure,memory}.scd`, `.github/workflows/test.yml`, the notes `docs/notes/engine/{effects,mix,memory,record,structure}.md`, `docs/notes/lua/{voice-mix,delay-sync,params,arc-pages,pages/fx}.md`, `docs/notes/lua/ui/header-and-flashes.md`, the user pages `docs/user/effects.md`, `docs/user/pages/fx.md`, `docs/user/arc.md`, and norns' `lua/core/paramset.lua`.

One probe (scratch copy of the tree, nothing tracked touched): the reverb's default set to 0.43 in `lib/params_setup.lua:570`, `lib/scenes.lua:115` and both reverb defs, then `lua test/run.lua`. 2813 tests, 10 failures; 7 come from the default (listed under 1a, Tests); 3 are the copy's (no `.git`: "text uses US spelling", "no .sc file is tracked...", "recursive deletes happen only at the guarded sites", each failing at a `git ls-files` or repo-scan line).

Built on 0b: `\strataDelay` lives in `lib/engine/StrataDelay.sc` (new), reads `BufDelayC` on two mono buffers of 2^18 frames, time clipped to `delayMaxSeconds` (5.4), `delay_sync`'s `DELAY.max_seconds` 5.4, `checkBypassMemory` rewritten, `fixedBufferBytes` in `highMemoryBytes` and `lib/performance.lua`. The effects area keeps `startDelay`, the node and its place. I assume 0b keeps the delay def's arg list form, the `synths[\delay] = Synth(\strataDelay` literal in `startDelay`, and `setDelay`'s body in `addEffectCommands`; if 0b moves `setDelay` into `StrataDelay.sc`, every "StrataEffects.sc:282-292" below reads there.

---

## Package 1a: plain sends

### 1. Files

Engine:
- `lib/engine/StrataMix.sc`: `voiceOutput` (`:242-260`, the law and its comment), `\strataVoiceMix`'s arg list (`:143-145`, gains `dry=1`), its `voiceMixMod` Event (`:147-153`, gains `dry: dry`) and its `this.voiceOutput(...)` call (`:169`); `grainParamHandlers` (`:25-32`, gains `dry`); `mixBusControls` (`:111-117`, loses `\fxMixIn`); `allocMixBuses` (`:81-102`, loses `state[\fxMix] = Bus.control(server, 2)` at `:84`); `freeMixBuses` (`:122`, loses `\fxMix`); the header comment (`:1-9`) and the bus comment (`:68-80`). `fxMixLag` (`:65-66`) stays as the lag of sends and returns (rename optional, see Names).
- `lib/engine/StrataEffects.sc`: `masterSum` (`:102-110`); `\strataReverb` (`:170-178`) and `\strataReverbFDN` (`:180-217`): `mix=0.43`, a new `delayToReverb=1` arg scaling `In.ar(delayIn, 2)`; `\strataMaster` (`:221-223`, loses the `fxMix` arg); `setReverb` (`:255-263`, becomes `"ffff"`, no `broadcastFxMix`); `setDelay` (`:277-292`, no `broadcastFxMix`); `liveMix` and `broadcastFxMix` (`:311-321`, deleted); `setEffectBypass` (`:323-367`: the bundle at `:341-344` keeps only the mix 0, the lift at `:363-364` sets the kept mix); `startReverb` (`:383-392`, passes `\delayToReverb`); `startEffectsChain` (`:401-421`: `effectDefaults(\strataReverb, [\mix, \size, \damp, \delayToReverb])`, no `broadcastFxMix` at `:407`, the master without `\fxMix` at `:419-420`); comments `:1-6`, `:31-35`, `:102-105`, `:147-157` (0b's file by then), `:170-172`, `:323-333`.
- `lib/engine/StrataDelay.sc` (0b's): only the return's comment ("lagged as fxMixBus's readers", `StrataEffects.sc:152` today). Its `mix.clip(0, 1).lag(this.fxMixLag)` stays.
- `lib/engine/StrataRecord.sc`: `\strataTapPreMaster` (`:81-84`, loses `fxMix`), `startRecordTaps` (`:185-186`, loses `\fxMix, this.mixBus(\fxMix)`), comment `:76-80`.

Lua:
- `lib/voice_mix.lua`: `VOICE_MIX.keys` (`:28`, gains `dry`), `voice_mix_param` (`:119-142`, a `dry` spec), the record's `grain_keys` (`:190-197`), `scene_defaults` (`:198-199`), `fader` (`:203`); header comment (`:1-19`). `count` follows `#keys` (8 to 9). Proposed home of `delay_to_reverb` (see Names): a second fx record in this file, beside the bypass one (`:221-241`).
- `lib/params_setup.lua`: `reverb_mix`'s default (`:570`, 0.3 to 0.43); names `"delay mix"` (`:557`) and `"reverb mix"` (`:569`) to `"delay level"` / `"reverb level"` (the design's "the screen calls them level"; optional for the menu, see Risks).
- `lib/scenes.lua:115`: `{id = "reverb_mix", continuous = true, default = 0.3}` to 0.43 (0d's file; one line).
- `lib/engine_sync.lua:527-530`: `send_reverb_to_engine` sends `engine_param_value("delay_to_reverb")` as a fourth argument; `:551-553` gain `S.engine_senders.delay_to_reverb = send_reverb_to_engine` if the param is not registered with its own sender (0d's file; one or two lines).
- `lib/pages/fx.lua:48` and `:52`: labels `mix` to `level` (4a's file in wave 4; two lines, see Order). `:189-195` randomize draws keep `delay_mix`/`reverb_mix` ids (names unchanged).

Tests (unit):
- `test/unit/voice_mix_test.lua`: count 8 to 9, the new key, spec, grain key, scene default, fader, and that `dry` is out of the randomize.
- `test/unit/params_setup_test.lua:258-296` ("fx params: defaults, one exactly sized strata_fx group"): group size `#FX_PARAM_IDS + 2 + 3` (`:276`) gains 1; `:1007-1016` the 3.7.0 fixture's allowed differences (see Risks 1: the comparison has no kind for an added param, a changed default or a changed name).
- `test/unit/docs_test.lua:571-575`: `compared` 8 to 9 (`delayToReverb.clip(0, 1)` adds a pair); the FX defaults test (`:453-485`) covers the fourth argument with no edit.
- `test/unit/engine_sync_test.lua:1654-1676` ("a voice start sends 3.7.0's messages") and `test/fixtures/3.7.0-start-calls.lua`: each start gains `setGrainParam(<v>, "dry", 1)` (three starts; lines 55-60, 125-130, 191-196 show the neighbors).
- `test/helpers.lua:937-938` `FX_PARAM_IDS` (only if `delay_to_reverb` joins params_setup's own 11).
- The seven tests the 0.43 default breaks (probe): `test/unit/gestures_test.lua:97` ("a recorder records hand edits of control params only", expects 0.31), `test/unit/lfos_test.lua:429` ("an LFO on a fast destination runs in the engine": "Lua's sends begin: expected 1, got 2", the default no longer equals the value the test sets), `test/unit/macros_test.lua:93` ("a macro sets each target between its min and max"), `test/unit/mutation_test.lua:577` ("randomize records the old values and undo restores them (#557)"), `test/unit/params_setup_test.lua:628` ("a PSET has no strata_pset_format..."), `test/unit/params_setup_test.lua:1084` (the 3.7.0 fixture, param 27 `reverb_mix`'s default), `test/unit/scenes_test.lua:1336` ("fill_scene fills a voice's missing keys with their defaults...").

Engine check:
- `test/engine_check.scd:85-96` (comment), `:112-120` (`voiceOutput32`), `:947-948` (`h.voiceOutput32`): the harness copy becomes the plain law (drop `fxMixIn`; add a `dry` argument, 1 for the verbatim 3.2 defs). Every `h.def32` grain def is built with it (`:199-202`), so the verbatim references follow.
- `test/engine_check/effects.scd` (1177 lines): `checkChain30` (`:492-549`) and its calls (`:1090-1101`), `checkDrySends` (`:551-588`), the check-only `\strataCheck30Delay`/`\strataCheck30Reverb` (`:96-107`; keep `\strataCheck30Filter`, `:83-95`, #305's reference), `\strataCheckChainSource` (`:109-117`, its `voiceOutput` call), `\strataCheckMasterSum` (`:118-120`), `checkFreshDefaults` (`:370-406`), `checkRouting` (`:408-440`, three `fxMix` assertions), `checkEffectSendsReported` (`:480`, a 3-argument `setReverb`), `broadcasts` (`:644-648`) and its two uses (`:660`, `:946`), `checkBypassFrees` (`:671-676`), `checkMixThroughZero` (`:930-936`), `checkSetWhileBypassed` (`:946-961`), `checkReverbBypass` (`:973-985`), `checkFdn` (`:1068`, `\fxMix` in a bus list), the closing lines `:1104-1109`, `:1124`, `:1142`. `command.(\setReverb, ...)` with three arguments: 15 sites in `effects.scd`, 3 in `mix.scd`, 2 in `record.scd` (grep `\\setReverb`).
- `test/engine_check/mix.scd`: `defaults` (`:22`, add `dry: 1`), `refPairs` (`:96`, drop `\fxMixIn`), `checkGrainDefsLostControls` (`:306-313`; `\fxMixIn` may stay in the "removed" list, add `\dry`), `prepareVoice` (`:151`), `checkStageValues` (`:316-327`, six names to seven), the steady-state block (`:586-617`, its "delay and reverb mixes 0.5 and 0.4" no longer matter), the closing reset (`:676`).
- `test/engine_check/modulation.scd:212` (`engine.voiceOutput(sig, c[\out], c[\delaySend], c[\reverbSend])`, the check's copy of 3.3's stage) and `:289-293` (`stageArgs`, `\fxMixIn`).
- `test/engine_check/record.scd:247-249` (`\strataCheckMasterSum`), `:307-327` (the pre-master test, `\fxMix` at `:315`).
- `test/engine_check/structure.scd:84` (`\fxMix` in `engineLeft`'s bus list), `:464` (`\fxMixIn`).
- `test/engine_check/memory.scd:131-133` (`engine.mixBusControls` into the 3.2 copies: follows by itself), `:153-155` (the stage probe, `\fxMixIn`), `:144-162` (the 42 KB limit, keep; see Names).

Docs:
- `docs/notes/engine/effects.md`: `:4` (Must not break, "Sends at 1 are 3.0's chain": rewrite as the plain law), `:13` ("its comparison with 3.0's chain rely on"), `:27-31` (the reverb's and master's descriptions, `masterSum`), `:33` (Commands: the broadcast), `:46` (the check paragraph: `checkChain30`, the dry sends, `fxMix`).
- `docs/notes/engine/mix.md`: `:16` (`\fxMix` bus), `:31` (`voiceOutput`), `:36` (3.0's output paragraph), "Is it the same sound?" (`:38-`, the references now carry the plain law).
- `docs/notes/engine/structure.md:104` (the master sums), `:149` (the `fxMix` control bus).
- `docs/notes/engine/memory.md:10`, `docs/status.md:22`: the stage's reading (41.29 of 42 today; the facts measured 38.8 plain).
- `docs/notes/lua/voice-mix.md`: `:3` (Must not break, "3.1's chain by default"), the param table (`:15-`), the fader line (`:7`).
- `docs/notes/lua/params.md:21`, `:96`, `:129` (the fx group's size, if `delay_to_reverb` is a registered record they stay true).
- `docs/user/effects.md`: `:8` ("Reverb - Adjustable mix (fully dry to fully wet)"), `:16-17` (the sends list gains dry), `:20` (the crossfade paragraph, rewritten), `:26` ("the delay's 1 MB" is 0b's).
- `docs/user/pages/fx.md:5` ("mix" labels; 4a rewrites the page; see Order).
- `CHANGELOG` fragment `changes/<branch>.md` naming the sound change (decision 12).

`AGENTS.md` (7,744 words before 0a):
- `:225` (35 words): "- **Sends reproduce 3.0's chain**: every mix reader lags 0.05 s, the bus and the nodes' mix controls move in one bundle, and a stage gets its send and mix buses through `stageControls` (`docs/notes/engine/mix.md`). `docs/notes/engine/effects.md`". Proposed (44 words): "- **Plain sends**: a stage writes its signal times `dry` to the dry bus and times each send to its send bus, the sends taken before the dry level; the returns are levels; `masterSum` is the three summed times 0.7 and the pre-master tap reads it; a stage gets its send buses through `stageControls`. `docs/notes/engine/mix.md`, `docs/notes/engine/effects.md`"
- `:152` (23 words), the `setReverb` row: see Names.
- `:154` (29 words), the `setDelay` row: "mix 0-1 (0 = dry, the node keeps running)" becomes "level 0-1 (the return; 0 = silent, the node keeps running)" (0b changes the 2.7 s).
- `:224` ("Bypass is explicit ... a mix at 0 only silences"): "a level at 0" (optional).
- `:214` ("each mix stage under 42 KB"): stays true.

### 2. Names

Engine:
- `voiceOutput { arg sig, out, delaySend, reverbSend; }` (`StrataMix.sc:252`) becomes `voiceOutput { arg sig, out, dry, delaySend, reverbSend; }`: `Out.ar(out, sig * dry.clip(0, 1).lag(this.fxMixLag))`, `Out.ar(\delaySendOut.kr(...), sig * toDelay)`, `Out.ar(\reverbSendOut.kr(...), sig * toReverb)`. No `In.kr`.
- `\strataVoiceMix` gains arg `dry=1`, reached by `setGrainParam(voice, "dry", value)` through a new `grainParamHandlers` entry `dry: { arg voice, value; this.setStageParam(voice, \dry, value) }` (the stub reads the handler keys, `norns_stubs.lua:522-524`). Kept in `grainControls[voice]` (so `voiceMixArgs`, `:193-197`, and `replaceBadVoiceMix` restart a stage with it).
- The tap and the mirror stay before the dry level (`Out.ar(c[\tapOut], sig)`, `:171`; the mirror `other`, `:170`). The design is silent; a tap after `dry` would make a voice at dry 0 record silence on the voice record source and on 1d's output ring. Recommend: before (unchanged), stated in `mix.md`.
- `mixBusControls` (`:111`): `\delaySendOut`, `\reverbSendOut` only.
- `masterSum { arg in, delayIn, reverbIn, fxMix; }` (`StrataEffects.sc:106`) becomes `masterSum { arg in, delayIn, reverbIn; ^(In.ar(in, 2) + In.ar(delayIn, 2) + In.ar(reverbIn, 2)) * this.masterSumGain }`, with a new constant `masterSumGain { ^0.7 }` (§7.1's 0.7; `masterAmp`'s `amp=0.7` is a different 0.7, at the output).
- `\strataMaster` args `in, delayIn, reverbIn, out, amp=0.7, drift=0.01`; `\strataTapPreMaster` args `out, in, delayIn, reverbIn`.
- Reverb defs: `arg in, delayIn, out, mix=0.43, size=0.8, damp=0.5, delayToReverb=1, fadeIn=0;` and the input `(In.ar(in, 2) + (In.ar(delayIn, 2) * delayToReverb.clip(0, 1).lag(this.fxMixLag))) * this.liftFade(fadeIn)`. The arg must be in the `arg` list (the stub reads controls only from it, `norns_stubs.lua:451-463`, and the limit only from a literal `.clip`/`.lag(t).clip`, `:260-262`); a NamedControl (`\x.kr`) is invisible to the stub and fails the FX defaults test (`docs_test.lua:477`).
- Command, recommended: `setReverb(mix, size, damp, delayToReverb)`, `"ffff"`, body `this.keepEffectControls(\reverb, (mix: msg[1], size: msg[2], damp: msg[3], delayToReverb: msg[4])); this.setSynth(\reverb, \mix, msg[1] * this.effectLive(\reverb), \size, msg[2], \damp, msg[3], \delayToReverb, msg[4]);`. Precedent: 3.7 widened `setDelay` with `pingPong`. Alternative: `setDelayToReverb(amount)`, `"f"` (no edit of 20 engine-check call sites, one more row and one more stub check entry). Row (recommended): `` | `engine.setReverb(mix, size, damp, delayToReverb)` | `"ffff"` | Reverb return level 0-1, size 0-1, damping 0-1, delayToReverb 0-1 (how much of the delay's return it takes). `FreeVerb2` on standard, the FDN on high. Kept while bypassed | `` (about 33 words, +10). Alternative row: `` | `engine.setDelayToReverb(amount)` | `"f"` | How much of the delay's return the reverb takes, 0-1 (1 = 3.7's). Kept while bypassed | ``.
- `liveMix` (`:312`) and `broadcastFxMix` (`:319`) deleted. `setEffectBypass`'s lift sets `\mix, areaState[\effects][\controls][key][\mix]` (the node clips it). `bypassFadeTime` (`:33`) stays (the node's own mix lag plus a block); its comment changes.
- `fxMixLag` (`StrataMix.sc:66`): its bus goes, it stays the lag of every send, return and `liftFade`. 18 references in `lib/engine/StrataEffects.sc`, `StrataMix.sc`, `test/engine_check.scd`, `docs/notes/engine/{mix,effects}.md`. Renaming (proposed `levelLag`) is optional and mechanical; keeping the name is cheaper.
- `areaState[\mix][\fxMix]` goes; `areaState[\effects][\controls][\reverb]` gains `\delayToReverb`.

Lua:
- `v<i>_dry`: control, `controlspec.new(0, 1, "lin", 0.01, 1)`, name `"dry"` (or `"dry level"`), formatter `send_percent` (`voice_mix.lua:116`), grain key `dry = "dry"`, `scene_defaults.dry = 1` (a voice scene key: §11 lists it), fader keys `{"filter_freq", "filter_res", "filter_mix", "dry", "delay_send", "reverb_send"}` (rank 1; the fader group's size grows to six, check it fits a 256 fader page: 0e's/1k's to confirm), not in `randomize` (a draw near 0 silences the dry voice; the design is silent). Proposed place in `keys`: before `delay_send` (`{"filter_type", "filter_freq", "filter_res", "filter_mix", "dry", "delay_send", "reverb_send", "mute", "solo"}`), so VOICE's "filter & sends" section reads dry, sends. LFO destination: the design is silent (see Risks 6).
- `delay_to_reverb`: control `controlspec.new(0, 1, "lin", 0.01, 1)`, name `"delay to reverb"`, percent; action `note_param_edit("delay_to_reverb"); send_param_to_engine("delay_to_reverb", x)`; sender `send_reverb_to_engine`; scene global, continuous, default 1 (`S.register_scene_field({id = "delay_to_reverb", default = 1})` or a `SCENE_GLOBAL_PARAMS` line). Home, recommended: a second fx record in `lib/voice_mix.lua`, `S.register_fx_params({name = "sends", count = 1, add = ...})`, so `params_setup.lua`'s own `FX_GROUP_PARAMS` (11, `params_setup.lua:20`) and `test/helpers.lua`'s `FX_PARAM_IDS` stay. Alternative: `params_setup.lua`'s own group after `reverb_damp` (`FX_GROUP_PARAMS` 12, `FX_PARAM_IDS` and the scene-global test follow). Its `S.engine_senders` entry must exist (`docs_test.lua:465-468` sends every fx param).
- `reverb_mix` default 0.43 in three places that tests compare: the param (`params_setup.lua:570`), the scene global (`scenes.lua:115`, pinned by `params_setup_test.lua:285-290`), both SynthDefs (`docs_test.lua:453-485`).

No new global function, no start or cleanup step, no new registry.

### 3. Order and seams

- Needs 0b (`StrataDelay.sc`, the buffer delay) and 0d (it edits `lib/engine_sync.lua`, `lib/scenes.lua`, `lib/params_setup.lua`, all 0d's).
- Gives 1b: `effectDefaults` lists and `keepEffectControls` with no broadcast; 2a: the reverb defs' arg lists with `delayToReverb`; 1d: the tap before `dry` (its output rings record it); 3b: `dry` as a voice scene key (the preset filter lists it "in"); 4a: the `level` labels and `delay_to_reverb`'s row.
- Same-wave file overlaps: `lib/params_setup.lua` with 1e (1e edits the read hook's `pset.default`, `:194-204`; 1a edits `:557`, `:569`, `:570`): different sites, 1a lands first by §14's order. `test/engine_check.scd` with 1b, 1d, 1e (they edit `areaOrder`, `:24-25`; 1a edits `:85-120`, `:947`). `test/unit/params_setup_test.lua` (fixture entries) with every wave-1 package that adds a param. `test/fixtures/3.7.0-start-calls.lua`, which 1c also moves (`envShape` goes): §13 says "the last package of each wave that moves it" re-bases it; the plan should name 1c or 1d and have 1a add its line only if it lands alone.
- `lib/pages/fx.lua` is 4a's (wave 4). The two `level` labels are a 1a edit of a later package's file with no same-wave conflict; or 4a makes them, with 1a leaving the screen saying `mix` for three waves. Pick one in the plan.
- Rules rewritten: `AGENTS.md:225` (above), `docs/notes/engine/effects.md:4`, `docs/notes/lua/voice-mix.md:3`. The "NaN guards" line (`:226`) stays true.

### 4. Tests

New unit tests:
- `voice_mix_test.lua`: "every voice has a dry level, 0-1, 1 at first, sent as the stage's dry" (`params:get("v1_dry") == 1`; `params:set("v3_dry", 0.5)` on a running voice sends `setGrainParam(2, "dry", 0.5)`; a stopped voice sends nothing; a start sends `dry` with the voice's value); "dry is a scene key with default 1 and a fader, never randomized" (capture holds `dry`; `fill_scene` gives 1; the record's `fader[1].keys` holds `dry`; VOICE's ALT+K2 on the section leaves `dry`).
- `voice_mix_test.lua` or `params_setup_test.lua`: "delay_to_reverb is an fx param, 1 at first, a continuous scene global, and goes as setReverb's fourth argument" (`engine.setReverb` last call `args[4] == 0.25` after `params:set("delay_to_reverb", 0.25)`; a scene fade crossfades it).
- `params_setup_test.lua`: "the reverb's level starts at 0.43 and is called level" (`params:get("reverb_mix") == 0.43`; `params:lookup_param("reverb_mix").name == "reverb level"` if renamed).

New engine checks (effects area unless said):
- `checkPlainSends` (replaces `checkDrySends`): the stand-in source through `voiceOutput` at `[dry, delaySend, reverbSend]` in `[[1, 0, 0], [1, 1, 1], [0, 1, 0.5], [0.5, 0.3, 1]]` with the levels at 0.8 and 0.9: dry bus = `x·dry`, delay send = `x·s_d`, reverb send = `x·s_r`, each within 1e-5 (the levels no longer enter).
- `checkPlainChain` (replaces `checkChain30`): with the filter on, delay level 0.5 and reverb level 0.4, `delayToReverb` 0, 0.5, 1: the reverb's input equals a check-only `\strataReverb` (FreeVerb2 is deterministic; use the standard def) fed `reverbSendPost + k·delayBus` at mix 1, times the level, within -60 dB; `masterSum` equals `0.7 × (filterBus + delayBus + reverbBus)` within 1e-6.
- `checkDefaultBalance`: at the defaults (dry 1, sends 1, delay level 0, reverb level 0.43) the master's input is within -40 dB of a check-only copy of 3.7's law (`0.7·F(x) + 0.3·R(F(x))`); the facts' arithmetic gives 0.301 against 0.3 on the reverb, about -50 dB of it.
- `checkFreshDefaults`: reverb `[0.43, 0.8, 0.5, 1]` (`mix, size, damp, delayToReverb`), no `fxMix`; `areaState[\mix][\fxMix]` is nil.
- `checkRouting`: the master and the stages have no `fxMix`/`fxMixIn` control (`SynthDescLib`), the reverb reads `delayIn`.
- bypass: `checkBypassFrees` asserts the bypass bundle sets the node's mix to 0 and holds no `/n_free` (no `/c_setn`); lift restores the kept level (0.6); `checkSetWhileBypassed` and `checkReverbBypass` read the kept controls and the node's `mix`, not a bus; `delayToReverb` kept through a lift.
- `mix.scd`: `checkStageValues` covers `dry` (`[2, 800, 0.7, 0.75, 0.5, 0.2, 0.4]` for the seven names); a split comparison at `dry` 0.5 (the reference's `h.voiceOutput32` with `c[\dry]`).
- `record.scd`: "pre-master equals masterSum" stays, with `masterSum` three-argument; add "pre-master is 0.7 of the three buses' sum".
- memory: the stage under 42 KB (keep the limit; record the reading, the facts' 38.8 KB plain plus the `dry` control, expected under 39.5).

### 5. Risks and open points

1. **The 3.7.0 param fixture test cannot express 3.8.** `params_setup_test.lua:1074-1085` compares every param with `test/fixtures/3.7.0-params.lua`; the allowed kinds are `removed`, `group_size` and `options` only (`:995-1016`, `:1031-1041`, with a test at `:1087-1130` that an unknown kind raises). 1a needs "added" (seven `v<i>_dry`, `delay_to_reverb`), "default" (`reverb_mix`), "name" (if renamed) and `group_size` (`strata_fx`, n 16 to 17). Every 3.8 package that adds a param needs "added". This is a release-wide decision, probably 0a's or 0d's (0d adds about 213 params): new kinds, or a 3.8 fixture.
2. **The default's reach.** Seven unit tests move with 0.43 (listed under Files); `checkFreshDefaults` too. The design's §13 "a default start sends what 3.7.0's sends, but for the reverb's level": no start sends `setReverb` (the script never bangs; the engine starts from the def's 0.43).
3. **Where `delay_to_reverb` lives and how it reaches the engine** is the design's silence; the two options above. A fourth `setReverb` argument edits 20 engine-check sites and `checkEffectSendsReported`'s list.
4. **The verbatim 3.2 references change.** `h.def32[\grainRing]`/`[\grainBuf]` call `voiceOutput32`; with the plain law they are "3.2's grain defs with 3.8's output law". The comparisons stay exact (the stage and the reference use the same law), and `mix.md`'s "Is it the same sound?" must say so. The memory area's printed 3.2 sizes (`memory.scd:129-142`) shrink by a few UGens, for the record only.
5. **The menu names.** "the screen calls them level" (§7.1) may mean only FX's rows. Renaming the params' `name` changes the PARAMS menu and the fixture's `name` field; LFO labels `"dly mix"`, `"rev mix"` (`lib/lfos.lua:101`) are on screen too and appear in about 16 test lines (`lfos_test.lua`, `macros_test.lua:1038-1041`). Recommend: rename FX rows and the param names; keep LFO labels (stored by key, a later rename costs nothing).
6. **LFO destinations for `v<i>_dry` and `delay_to_reverb`**: the design is silent. A new per-voice destination shifts every later index of `S.LFO_DESTINATIONS` (tests pin indices, e.g. `registries_test.lua:404`, `S.LFO_DESTINATIONS[110]`). Recommend: `delay_to_reverb` as a global destination (`S.register_lfo_global_destination("dly>rev", "delay_to_reverb")`), `dry` none in 1a.
7. The stage's tap is before `dry` (recommended); 1d's output ring then records a voice at dry 0 at full level. The design's "everything the voice sounds dry" (§5) reads either way: 1d's planner should state it.

---

## Package 1b: delay freeze and clear

### 1. Files

- `lib/engine/StrataDelay.sc` (0b's new file): `\strataDelay`'s arg list gains `frozen=0, t_clear=0`; the graph (below); two commands. The commands' home: `addEffectCommands` (`StrataEffects.sc:250-299`, 1a's) or a new `addDelayCommands` in `StrataDelay.sc` called from `addEffectCommands` (one line in `StrataEffects.sc`). The stub reads any `addCommand` body wherever it is (`norns_stubs.lua:334-339`).
- `lib/engine/StrataEffects.sc`: `startDelay` (`:369-377`, passes `\frozen, controls[\frozen]`), `startEffectsChain` (`:405`, `effectDefaults(\strataDelay, [\time, \feedback, \mix, \pingPong, \frozen])`). If the lists are 0b's in `StrataDelay.sc`, there.
- `lib/fx_hold.lua` (new): the freeze and clear params (and 3a's reverb freeze later).
- `strata.lua`: one include, `S.lib.fx_hold = include("lib/fx_hold")(S)`, after `lib/delay_sync` (`strata.lua:108`), before `lib/params_setup` (`:109`).
- `lib/voice_mix.lua` (1a's): the bypass action (`:230-237`) sets the effect's freeze off first (see Order).
- `test/norns_stubs.lua` (0c's): two entries in `engine_argument_checks`'s `checks` table (`:664-700`; "Every engine command needs an entry", asserted at `:3109-3111`).
- `test/unit/fx_hold_test.lua` (new); `test/unit/voice_mix_test.lua` (the bypass ends a freeze); `test/unit/params_setup_test.lua` (group size `:276` +2; the fixture's "added" entries); `test/unit/docs_test.lua` (nothing if the freeze is in `fx_commands`: the FX defaults test then needs `delay_freeze` to send `setDelayFreeze` at its default 0 against `frozen=0`; the limits count stays 9, a binary has no controlspec).
- Engine check, a new area `delay`: `test/engine_check/delay.scd` (new); `test/engine_check.scd:24-25` (`\delay` in `areaOrder`, proposed after `\effects`); `test/unit/docs_test.lua:1008-1010` (`ENGINE_CHECK_AREA_ORDER`); `.github/workflows/test.yml:104-111` (a shard, not `memory,rings`); `docs/notes/engine/delay.md` (new, opens with "## Must not break"); `AGENTS.md:17` (the engine notes list gains `docs/notes/engine/delay.md`). The tests `docs_test.lua:1023`, `:1036`, `:1048`, `:1087`, `:1104` enforce each.
- Notes and docs: `docs/notes/lua/fx-hold.md` (new); `docs/notes/engine/effects.md` (the delay's description, `:27`, and "kept controls"); `docs/notes/lua/voice-mix.md:6` (the bypass ends a freeze); `docs/user/effects.md` (a freeze and clear paragraph; the bypass section `:24-28`); `docs/user/pages/fx.md` is 4a's (no FX rows before 4a: the params are in PARAMS > fx and on a MIDI map until then).
- `AGENTS.md`: two command rows; a module row `` | `lib/fx_hold.lua` | `fx_hold` | `docs/notes/lua/fx-hold.md` | fx_hold_test.lua | `` after `lib/delay_sync.lua`'s (`:108`); the bypass rule `:224` (proposed +12 words: "a bypass ends the effect's freeze first (Lua's bypass action)"); a new invariant line (below).

### 2. Names

Engine (the def, on 0b's `BufDelayC` line; `feedback.clip(0, 0.95)` stays for `setDelay`, the stub's limit and Lua's param):
- `frozen` (arg, default 0): `hold = Slew.kr(frozen.clip(0, 1), 50, 50)` (proposed: a linear 20 ms ramp that reaches exactly 1, where a one-pole `.lag(0.02)` only approaches it, as the facts' prototype did; the facts measured 0.2-0.4 dB over 9 s with the lag). Loop gain `feedback.clip(0, 0.95).max(hold)`; input `In.ar(in, 2) * this.liftFade(fadeIn) * (1 - hold)`.
- the time while frozen: held at its value at the freeze, rounded to whole samples; a change waits for the release. Proposed: `open = frozen <= 0`; `held = Gate.kr(time.clip(0.01, this.delayMaxSeconds), open).lag(0.1)`; `rounded = (held * SampleRate.ir).round / SampleRate.ir`; delay time `Select.kr(1 - open, [held, rounded])`. Holding before the lag makes a release glide to the new time, as any time change does. 0b's literal `time.lag(0.1).clip(0.01, <max>)` is what the stub and `delay_sync`'s docs test read (`docs/notes/engine/effects.md:27`, "The engine stub reads setDelay's time limit from the literal"): keep a literal `time...clip(0.01, 5.4)` somewhere the parser sees, or the time limit check drops (`compared` falls by one).
- the cross-feed while frozen: `cross = Select.kr(1 - open, [pingPong.clip(0, 1), pingPong.clip(0, 1) >= 0.5]).lag(0.05)` ("1 from 0.5 up"; the 50 ms is today's ping-pong lag, the design says 20 ms for the whole freeze: use `Slew` 50/50 there too if 20 ms is meant).
- `t_clear` (arg, default 0, a trigger control by its `t_` prefix): `clearGain = (1 - Trig1.kr(t_clear, lagTime + 0.005)).lag(0.003)`, on the feedback (`LocalOut.ar(fed * loopGain * clearGain)`) and on the return (`Out.ar(out, delayed * clearGain * mix...)`). With the input stopped the line read -142 dB after the window (facts §3). A time lengthened inside the window could read pre-clear audio (est., facts §3): note it.
- Commands. `setDelayFreeze(frozen)`, `"i"`: 0 or 1 (others ignored with one line, as `setBypass` ignores, `StrataEffects.sc:296-297`); `this.keepEffectControls(\delay, (frozen: msg[1])); this.setSynth(\delay, \frozen, msg[1]);` (while bypassed it is kept and sets nothing: `setSynth` skips a missing key). `clearDelay()`, `""`: `this.setSynth(\delay, \t_clear, 1);` never kept. norns takes an empty format (`~/src/norns/sc/engines/Engine_PolySub.sc:136`, facts §6); the stub's signature regex is `"([^"]*)"` (`norns_stubs.lua:214`), its arity check `#signature` is 0 (`:3122-3125`), the sync check's `count_arguments` returns 0 for `()` (`sync_check.lua:88-111`), and the `AGENTS.md` table test reads `"(%a*)"` and an empty argument list as 0 (`docs_test.lua:791-803`). All four accept it.
- Rows: `` | `engine.setDelayFreeze(frozen)` | `"i"` | Freeze the delay's loop (1) or release it (0) over 20 ms: feedback exactly 1, input closed, time held and rounded to whole samples, ping-pong snapped to 0 or 1. Others ignored. Kept while bypassed | `` (about 38 words). `` | `engine.clearDelay()` | `""` | Empty the delay: its feedback and return muted for the delay time and 5 ms, so the line refills with what comes in. Nothing while bypassed | `` (about 28 words).
- Stub entries: `setDelayFreeze = function(args) return range("frozen", args[1], 0, 1) end`, `clearDelay = none`.
- `t_clear` is not a kept control; `frozen` is (`effectDefaults` and `startDelay`), so a lift re-creates the node with it, which Lua keeps at 0 (below).

Lua, `lib/fx_hold.lua` (`S.lib.fx_hold`, a module constructor):
- `M.FX_HOLD = {delay = {freeze_id = "delay_freeze", clear_id = "delay_clear"}}` (3a adds `reverb = {freeze_id = "reverb_freeze"}`).
- `delay_freeze`: `params:add{type = "binary", id = "delay_freeze", name = "delay freeze", behavior = "toggle", default = 0, action = function(x) send_param_to_engine("delay_freeze", x); request_redraw(); grid_redraw() end}` then `params:set_save("delay_freeze", false)` (norns' `ParamSet:write` skips `save == false`, `paramset.lua:513`; precedent `lib/gestures.lua:598`; the read hook's `pset.default` gives such a param no default, `params_setup.lua:195`, so a PSET load leaves the freeze as it is). Sender `S.engine_senders.delay_freeze = function(value) engine.setDelayFreeze(value) end`.
- `delay_clear`: `params:add{type = "trigger", id = "delay_clear", name = "delay clear", action = function() send_param_to_engine("delay_clear", 1) end}`; sender `S.engine_senders.delay_clear = function() engine.clearDelay() end` (norns never writes a trigger, `paramset.lua:513`). The sender must exist if `clearDelay`'s body has the literal `setSynth(\delay, ...)`: it is then in the stub's `fx_commands` and the FX defaults test asserts an fx param sends it (`docs_test.lua:469-471`).
- Registration: `S.register_fx_params({name = "hold", count = 2, add = ...})` (3a makes it 3). No scene field (only `register_scene_field` and `SCENE_GLOBAL_PARAMS` make one), not an LFO destination, not a macro target (the macros list LFO destinations, `macros.lua:131-139`), not a gesture's (a recorder takes control params only), not in FX's randomize.
- Functions: `M.frozen(effect)` (true only for an offered effect whose param is 1), `M.offered(effect)` (delay always), `M.toggle(effect)` (through `set_binary_param`, so a MIDI map follows, #538), `M.release(effect)` (sets the freeze param to 0 when it is 1), `M.clear()` (sets `delay_clear`), `M.any_frozen()` (for 4a's header).
- The bypass ends a freeze: `lib/voice_mix.lua:236`'s action becomes `function(x) if x == 1 then S.lib.fx_hold.release(effect) end send_param_to_engine(bypass.param_id, x) end`. A freeze set while bypassed (a MIDI map, a PARAMS edit) would be kept at 1 and the lift would start a frozen, empty, closed line. The design covers only the bypass edge. Recommend: the freeze action does nothing but set itself back to 0 while its effect is bypassed, or the lift also calls `release`. Name the choice in the plan.
- The fx group then ends `delay_bypass, reverb_bypass` (and 1a's `delay_to_reverb` if registered there), `delay_sync, delay_division, delay_pingpong`, `delay_freeze, delay_clear`: the include order sets it.

Proposed `AGENTS.md` invariant (about 45 words): "- **Delay freeze and clear**: the freeze is `\strataDelay`'s `frozen` (feedback `max` the freeze, input closed, time held and rounded, ping-pong snapped), never a feedback of 1 through `setDelay`; clear mutes the feedback and the return for a delay time, never zeroes the line. `docs/notes/engine/delay.md`, `docs/notes/lua/fx-hold.md`"

### 3. Order and seams

- Needs 1a (the delay def's kept controls with no broadcast; the bypass action in `lib/voice_mix.lua`). Lands second in wave 1.
- Gives 2a the def with `frozen` (shimmer is checked frozen) and `fx_hold`'s record; gives 3a `fx_hold.lua` (it adds the reverb's); gives 4a `S.lib.fx_hold` (`frozen`, `offered`, `toggle`, `clear`, `any_frozen`) and 4b the same for DF and DC.
- Same-wave overlaps: `test/norns_stubs.lua` with 1e (`setTuning`, `setTuningTone` entries in the same `checks` table); `test/engine_check.scd:24-25`, `docs_test.lua:1008-1010` and `.github/workflows/test.yml:104-111` with 1d (`outrings`) and 1e (`tuning`): each adds one name to the same one or two lines. Treat them as registration lines (keep both at a landing).
- Who owns the "buffer line against a check-only `DelayC` to the sample" check: §13 puts it in the `delay` area, but 0b builds the line (in the effects area, which 0b owns) before the area exists. Recommend: 0b's check in `effects.scd`, moved by 1b into `delay.scd`, or 0b leaves it and §13's sentence is read loosely. The plan should say.

### 4. Tests

`test/unit/fx_hold_test.lua` (new):
- "delay_freeze is a binary fx param, off, never saved in a PSET and never a scene field" (`params:lookup_param("delay_freeze").save == false`; `params:write` then grep the file has no `delay_freeze` line; capture a scene, `scene_holds` false; recall leaves it).
- "delay_freeze sends setDelayFreeze, running or bypassed" (`params:set("delay_freeze", 1)`: one `setDelayFreeze(1)`).
- "delay_clear sends clearDelay once a trigger and is never saved" (one `clearDelay()` call, zero arguments).
- "a bypass ends the delay's freeze first" (freeze 1, `params:set("delay_bypass", 1)`: the calls are `setDelayFreeze(0)` then `setBypass(0, 1)`; the param reads 0).
- "a freeze set while bypassed does not survive the lift" (whichever rule the plan picks).
- "fx_hold.frozen, toggle and any_frozen" (toggle through `set_binary_param` echoes to a MIDI map, as `pages_fx_test.lua:402` does for the bypass).

`test/engine_check/delay.scd` (new; times from facts §3):
- the frozen loop holds: steady pink noise on the delay send, feedback 0.4, time 0.375 s and 0.30928 s (fractional), frozen at 1 s: the return's energy in 1 s windows from 1.5 s to 9 s within 0.5 dB of the first; its 6-24 kHz band within 0.5 dB over the same span at both times (proves the rounding; unrounded it lost 10.7-11 dB at 0.30928 s); ping-pong 0, 1 and 0.5 (at 0.5 the side signal stays above -20 dB of the mid after 2 s: the snap; unsnapped it read -999 dB).
- the input is closed: a 1 kHz sine started on the send after the freeze is absent from the return (under -60 dB of its level unfrozen).
- a time change while frozen changes nothing until the release (`setDelay` at 0.2 s while frozen: the node's loop energy and period unchanged; after release the new time plays).
- released, the loop decays at the kept feedback (under -40 dB 2 s after a release at 0.4; facts: -42 to -44).
- clear: steady input, `clearDelay` at 2 s: the return under -60 dB from 10 ms after to the delay time, the first echo of post-clear input one delay time later; input stopped then cleared: under -120 dB after the window; frozen then cleared: an empty frozen loop (under -120 dB while frozen).
- kept controls: `frozen` kept through a bypass lift (the lifted node's `frozen` equals the kept value); `t_clear` while bypassed sends nothing and raises nothing; `setDelayFreeze` with 2 or -1 ignored with one line.
- the fresh engine's `frozen` is 0 (`checkFreshDefaults` in effects reads `\frozen` too).
- memory: `\strataDelay` with freeze and clear under 20 KB of the pool (facts: 13.5 KB on `BufDelayC` with both).
Must re-measure: every figure above on both versions; the delay area's run time for its shard.

### 5. Risks and open points

1. The freeze edge cases (set while bypassed) are design-silent (above).
2. The time literal the stub reads: the freeze rewrites `time.lag(0.1).clip(...)`; keep a parseable literal (`norns_stubs.lua:260-262` reads `c.clip(lo, hi)` or `c.lag(t).clip(lo, hi)` on an arg-list control), else `docs_test.lua:571-575`'s count and `delay_sync`'s max-seconds docs test lose their source.
3. A one-pole lag never reaches exactly 1.0; the design's "exactly 1" needs a linear ramp (`Slew`, or `Line`/`VarLag` with a linear shape) on the `max`.
4. No FX row exists for the freeze or the clear until 4a (wave 4): 1b's user docs say "PARAMS > fx" until then.
5. Same-wave registration lines (area order, workflow shard, `ENGINE_CHECK_AREA_ORDER`, stub `checks`) with 1d and 1e.

---

## Package 2a: shimmer

### 1. Files

- `lib/engine/StrataDelay.sc` (1b's def): the feedback blend; `shiftL=0, shiftR=0, shimmer=0, shimmerRatio=2` args.
- `lib/engine/StrataEffects.sc`: the method `shimmerShift`, constants, the two reverb defs' outer loop, the ring buffers' allocation in `allocEffectBuses` (`:37-52`) and their free in `freeEffects` (`:434-439`), `startDelay`/`startReverb` (`:369-392`, the ring bufnums and the kept shimmer controls), `startEffectsChain` (`:405-406`, `effectDefaults` lists gain `\shimmer, \shimmerRatio`), the command `setShimmer` in `addEffectCommands`. (The design gives 2a `StrataDelay.sc` and "the reverb defs in `StrataEffects.sc`"; the shifter method, used by both, sits in either: proposed `StrataEffects.sc`.)
- 0b's `fixedBufferBytes` (`lib/engine/StrataPerformance.sc` near `highMemoryBytes`, `:248-252`, and its mirror in `lib/performance.lua`): see Risks 1.
- `lib/shimmer.lua` (new); `strata.lua` one include after `lib/fx_hold`; `test/norns_stubs.lua` one `checks` entry.
- `test/unit/shimmer_test.lua` (new); `test/unit/params_setup_test.lua` (group size +3, fixture "added" entries); `test/unit/docs_test.lua:574` (`compared` 9 to 11: `shimmer.clip(0, 1)` on both defs, from `shimmer_delay` and `shimmer_reverb`'s specs).
- Engine check: a new area `shimmer`: `test/engine_check/shimmer.scd`, `areaOrder`, `ENGINE_CHECK_AREA_ORDER`, a shard (it builds a high engine for the FDN: never the `memory,rings` shard, per the workflow's comment `test.yml:100-102`), `docs/notes/engine/shimmer.md`, `AGENTS.md:17`. `test/engine_check/memory.scd` (the worst cases re-run; the defs' sizes), `test/engine_check/structure.scd:86-88` (`engineLeft`'s buffer list gains the four rings), `test/engine_check/effects.scd` (`checkFreshDefaults`: `shimmer` 0 and `shimmerRatio` 2 on both nodes; `checkFdn`'s pool size).
- Docs: `docs/notes/engine/effects.md` (the defs, the NaN-guard line `:8` is made false by a loop the effect builds, facts "wrong or silent"), `docs/notes/engine/memory.md`, `docs/notes/lua/shimmer.md` (new), `docs/user/effects.md` (a shimmer section, the ceiling's halo), `docs/status.md` (limits).
- `AGENTS.md`: one row; module row `` | `lib/shimmer.lua` | `shimmer` | `docs/notes/lua/shimmer.md` | shimmer_test.lua | ``; the NaN guards line `:226` (18 words) gains "the reverbs' outputs and shimmer loops"; the buffer memory line `:213` (0b's rewrite) gains the shimmer rings; proposed invariant: "- **Shimmer**: one audio-rate `LocalIn` a SynthDef (a loop widens it); the reverb's loop clips softly at 0.25 and its output passes `zeroBadValues`; at amount 0 each effect is its def without shimmer, bit for bit. `docs/notes/engine/shimmer.md`" (about 38 words).

### 2. Names

Engine:
- `shimmerRingFrames { ^2 ** 14 }` (0.34 s at 48 kHz; the window is 0.1 s), `shimmerWindowSeconds { ^0.1 }` (a literal: it sets the heads' rate, never memory), `shimmerCeiling { ^0.25 }`, `shimmerLowpassHz { ^6000 }`, `shimmerHighpassHz { ^100 }`.
- `shimmerShift { arg sig, bufs, ratio; }`: `BufWr` of each channel into its ring at a `Phasor` over `shimmerRingFrames`; two read heads per channel `window` apart, delays `offset + saw * window` with `saw = LFSaw.ar((1 - ratio) / window, [0, 1]).range(0, 1)` and Hann gains `(saw * pi).sin.squared` (they sum to 1: a convex mix, never above the line's peak), as the facts' `scratchDopplerRead` (appendix). Returns stereo. `BufRd` cubic with `.wrap` measured 12.6 KB stereo and 1.23× FreeVerb2's CPU; `DelTapWr`/`DelTapRd` cubic 0.83× (pool not measured, est. under 15 KB).
- Rings: `areaState[\effects][\shimmerRings]`, four mono `Buffer.alloc(server, this.shimmerRingFrames, 1)`: the delay's left and right, the reverb's left and right; passed as `\shiftL, \shiftR` bufnums at `startDelay`/`startReverb` (bufnums never change).
- Delay (`\strataDelay`): `fed = delayed + ((this.shimmerShift(delayed, [shiftL, shiftR], ratio) - delayed) * shimmer.clip(0, 1).lag(0.05))`, `LocalOut.ar(fed * loopGain * clearGain)`; the return stays `delayed`. At 0: `delayed + 0` exactly (the ring holds finite values).
- Reverbs: `\strataReverb` gains `LocalIn.ar(2)`; `\strataReverbFDN`'s `LocalIn.ar(8)` (`:203`) widens to 10 (channels 8-9 the loop). Loop: `wet -> shimmerShift -> LPF 6000 -> HPF 100 -> soft clip at the ceiling (proposed `(x / ceiling).tanh * ceiling`) -> * shimmer -> LocalOut`, entering the reverb's input (FreeVerb2's two inputs; the FDN's before the diffusers, as the prototype `\pFdnShimBuf`). Output `Out.ar(out, wet.collect({ arg channel; this.zeroBadValues(channel) }) * mix...)`. Recommended beyond the design: `zeroBadValues` on the loop signal before `LocalOut` too, since a NaN inside the loop otherwise lives there until a bypass (facts §2).
- Args on both reverb defs (arg list, for the stub): `shiftL=0, shiftR=0, shimmer=0, shimmerRatio=2`; the delay def the same four.
- Command `setShimmer(delayAmount, reverbAmount, ratio)`, `"fff"`: `this.keepEffectControls(\delay, (shimmer: msg[1], shimmerRatio: msg[3])); this.keepEffectControls(\reverb, (shimmer: msg[2], shimmerRatio: msg[3])); this.setSynth(\delay, \shimmer, msg[1], \shimmerRatio, msg[3]); this.setSynth(\reverb, \shimmer, msg[2], \shimmerRatio, msg[3]);`. The defs clip `shimmer.clip(0, 1)` and `shimmerRatio.clip(0.5, 4)` literally, so the stub gives the arguments those limits (`norns_stubs.lua:475-484`). Stub entry `setShimmer = none`. A non-finite argument: ignore with one line (`fastModValuesFinite`, as `setDelay`, `StrataEffects.sc:283-284`).
- Row: `` | `engine.setShimmer(delayAmount, reverbAmount, ratio)` | `"fff"` | Shimmer: the delay's feedback blend 0-1 and the reverb's loop 0-1 (0 = none, the effect as without shimmer), shifted by the ratio 0.5-4 (Lua sends 0.5, 1.5, 2, 3 or 4). Kept while bypassed | `` (about 40 words).

Lua, `lib/shimmer.lua` (`S.lib.shimmer`):
- `M.SHIMMER = {ratios = {0.5, 1.5, 2, 3, 4}, names = {"oct down", "fifth", "octave", "oct+5th", "2 oct"}, default_interval = 3}` (widths by the stub's font: 27, 19, 28, 31, 22 px).
- Params, one fx record `S.register_fx_params({name = "shimmer", count = 3, ...})`: `shimmer_interval` (option, names, default 3), `shimmer_delay` and `shimmer_reverb` (control `controlspec.new(0, 1, "lin", 0.01, 0)`, percent). Each action calls `note_param_edit(id)` (FX's randomize may draw them, AGENTS "Randomize undo") and `send_param_to_engine(id, x)`.
- One sender: `local function send_shimmer() engine.setShimmer(engine_param_value("shimmer_delay"), engine_param_value("shimmer_reverb"), M.SHIMMER.ratios[engine_param_value("shimmer_interval")]) end` for all three ids. (A scene recall then sends up to three `setShimmer`; `delay_sync` holds its sends during `apply_entries`, `lib/engine_sync.lua:516-520`; shimmer may do the same or accept three.)
- Scene globals: `S.register_scene_field({id = "shimmer_interval", default = 3, discrete = true})`, `shimmer_delay` and `shimmer_reverb` with default 0, continuous.
- The FX defaults test sends every fx param and compares the last `setShimmer`'s arguments with the defs' defaults: `shimmer=0` on `\strataDelay` and `\strataReverb` (the stub maps `\reverb` to whichever `synths[\reverb] = Synth(\...` comes last in the source: `\strataReverb` at `StrataEffects.sc:390` today, `norns_stubs.lua:468-471`), `shimmerRatio=2` = ratio 3.
- LFO destinations: design-silent; recommend `S.register_lfo_global_destination("shim dly", "shimmer_delay")` and `("shim rev", "shimmer_reverb")`.

### 3. Order and seams

- Needs 1a (the reverb defs' arg lists) and 1b (the delay's `frozen`: shimmer is checked frozen). Owns `StrataDelay.sc` after 1b and the reverb defs after 1a.
- Gives 3a the FDN with `LocalIn.ar(10)` and the loop entering before the diffusers: 3a's freeze closes the input after the diffusers, which also closes the shimmer loop into a frozen FDN. That matters: a bounded input into a lossless network can grow without bound; the order of the two must stay so, and 3a's check runs a frozen FDN with shimmer 1.
- Gives 4a `S.lib.shimmer` and the params for rows and the arc's ALT rings 3 and 4; 4b the interval keys.
- No same-wave conflict in wave 2 (2b, 2c own other files), but `test/engine_check.scd`'s `areaOrder` and the workflow are touched again.

### 4. Tests

`test/unit/shimmer_test.lua`:
- "shimmer's three params: an interval of five ratios (octave at first) and two amounts at 0" (options, defaults, `setShimmer(0, 0, 2)` from a default send).
- "each param sends setShimmer with the other two as the engine has them" (`params:set("shimmer_interval", 1)`: `args[3] == 0.5`; `shimmer_reverb` 0.4: `args[2] == 0.4`).
- "shimmer's params are scene globals and kept through a bypass" (capture and recall; the interval switches at a fade's end; a bypass sends no `setShimmer`).
- "an FX randomize that draws shimmer notes the edit" (if 4a's specs draw it: 4a's test).

`test/engine_check/shimmer.scd`:
- shimmer 0 is the effect without it, bit for bit: the delay against a check-only copy of 1b's def (largest difference 0.0 over 5 s, fixed and LFO-moved time, feedback 0.4, ping-pong 0.5); each reverb against a check-only copy without the loop (FreeVerb2 is deterministic; the FDN's drift is `LFNoise1`, so run its check-only copy with the same seed in one bundle, or compare `shimmer` 0 with the loop's `LocalOut` at exactly 0 by reading the graph).
- the delay's loop bounded: a 0.2 s pink burst, feedback 0.95, each of the five ratios at shimmer 1, unfrozen and frozen: the return's energy in the last 1 s window of 9 s at most +1 dB over the first after the burst (facts: -14 to -15 dB unfrozen, -3 to -7 frozen).
- the reverb's loop bounded on both reverbs: each ratio × amount {0.5, 1} × size {0.8, 1} at damp 0, steady pink noise for 3 s then silence: the output's peak under 1.0 and no bad value (`CheckBadValues` count 0) over 9 s; at ratio 1.5 and amount 1, size 1 (the worst near 1 among the five) the sustained level after the input stops stays under -6 dBFS (the ceiling's halo, design §7.4). The facts' unbounded cases (ratio 1, 1.02) are not among the ratios; add one check-only case at ratio 1.02 to prove the ceiling holds (it grew +110 to +126 dB unbounded).
- a NaN written into the loop (a check-only `setn` on the node's input bus) never reaches the output (the output guard).
- time: 2 effects × 5 × 2 × 2 cases of 9 s is about 6 min serially; run cases in parallel nodes per batch (FreeVerb2 104.5 KB, the FDN 209-225 KB of pool each; a batch of eight FDNs is about 1.8 MB, which a check engine has). The builder measures the area's time for its shard.
- memory (memory area): the worst cases with both shifters and the loop (facts: -40 KB with both shimmers on buffers, high synth -> buffer -> synth 4790 against 4830); `\strataDelay` under 30 KB, `\strataReverb` under 125 KB, `\strataReverbFDN` under 235 KB (facts: 27.8, 121.3, 225.4).

### 5. Risks and open points

1. **`fixedBufferBytes` misses the shimmer rings.** §0.2 sets it "once for all four sets 3.8 allocates" (the delay line, the output rings, the window bank, the wavetables) and "the later packages allocate against it and edit neither file"; §7.4's shifter "is written to a small ring (ordinary RAM)", built twice: four mono rings of 2^14 frames, 256 KB at 4 bytes a frame. Either 0b counts 256 KB more (recommended: the plan tells 0b) or 2a edits `StrataPerformance.sc` and `lib/performance.lua`, 0b's files. The same holds for `AGENTS.md`'s buffer memory rule, which §0.2 says "names the four".
2. **CPU is not counted anywhere.** Two shifters run always, at amount 0 too: about 1.2× FreeVerb2's CPU each with `BufRd`, 0.8× with `DelTapRd` (x86 NRT, facts §2), on top of the FDN's 1.33×. No CM3 or Pi 4 figure; #6's device list should gain "shimmer's CPU on a CM3" (§13 lists only "shimmer at every interval for five minutes").
3. The shifter in the delay sits after `delayed` with its own ring, so a shimmered repeat arrives 0-0.1 s later than a plain one (the heads' delay). The facts' stable prototype on a buffer line read the delay's own line at `time + d(t)` instead (`\pDelayShimTaps`); the design's "built twice" rules the own-ring form. Stability measured on `\pDelayShimPS` (also after `delayed`) holds.
4. The loop's filters and whether the ceiling is a soft clip or a limiter are the builder's (design's "Left to the builder"); the check above is the gate.
5. The prototype used NamedControls (`\shimmer.kr(0)`); the stub requires arg-list controls (`norns_stubs.lua:452-454`, every SynthDef must open with `arg`): write them in the arg list.

---

## Package 3a: the reverb's freeze (high tier)

### 1. Files

- `lib/engine/StrataEffects.sc`: `\strataReverbFDN` (2a's), its `frozen=0` arg; the command; `startReverb` and `startEffectsChain`'s kept controls (`:383-392`, `:406`).
- `lib/fx_hold.lua` (1b's): `M.FX_HOLD.reverb = {freeze_id = "reverb_freeze"}`, the record's count 2 to 3, `offered("reverb")`.
- `lib/voice_mix.lua`: nothing more if 1b's bypass action already calls `S.lib.fx_hold.release(effect)` for both effects (recommended: write it for both in 1b).
- `test/norns_stubs.lua`: one `checks` entry. `test/unit/fx_hold_test.lua`, `test/unit/params_setup_test.lua` (group size +1, fixture entry).
- `test/engine_check/effects.scd` (the design gives 3a "the effects area"): the freeze checks, `checkFreshDefaults` (the FDN's `frozen` 0), `checkFdn` (its pool size, +3.8 KB est.). `test/engine_check/memory.scd`: the high cases re-run (-4 KB est.).
- Docs: `docs/notes/engine/effects.md` (the FDN), `docs/notes/lua/fx-hold.md`, `docs/user/effects.md`, `docs/status.md`, `AGENTS.md` one row.

### 2. Names

- FDN graph while frozen, 20 ms (`hold = Slew.kr(frozen.clip(0, 1), 50, 50)`): the input closed after the diffusers (`diffused * (1 - hold)`; the facts' prototype closed it before them and stepped -2.5 to +11.9 dB, facts §4); every line's gain `.max(hold)` (`StrataEffects.sc:212-214`); damping `damp... * 0.4 * (1 - hold)` (`:192`); the lengths rounded to whole samples (`((length - ControlDur.ir) * SampleRate.ir).round / SampleRate.ir`, as the facts' check-only `\sFdnFreezeRound`), blended in over the 20 ms; the two drifting lines held (`Gate.kr(LFNoise1.kr(0.31) * 0.0006, open)`, `:195`). Design-silent and recommended: hold `room` (size) too while frozen (`Gate.kr` before its lag), since the lengths and gains follow it (`:196`, `:194`); a size change would move the read points and darken the tail.
- Command `setReverbFreeze(frozen)`, `"i"`. On standard: ignored (no node has the control; `tier`, `StrataEffects.sc:387`). Kept on high (`keepEffectControls(\reverb, (frozen: msg[1]))`). The stub problem: `\reverb` maps to `\strataReverb` (the last `synths[\reverb] = Synth(\...` in the source, `norns_stubs.lua:468-471`), so a literal `this.setSynth(\reverb, \frozen, msg[1])` in the command body makes the FX defaults test assert `\strataReverb` has a numeric `frozen` default (`docs_test.lua:475-477`) and fails. Two ways: give `\strataReverb` an inert `frozen=0` arg (no UGen reads it), or keep the `setSynth` out of the command body (`this.setReverbFrozen(msg[1])`, a method; the stub then sees no fx setting and the engine check's fresh-defaults read covers the default). Also `effectDefaults(\strataReverb, [..., \frozen])` (`:406`) returns nil for a control `\strataReverb` lacks (`effectDefaults`, `:395-399`, calls `.defaultValue` on nil): read the FDN's default or add the inert arg. Recommended: the method, and `frozen` kept with a literal 0 start.
- Stub entry: `setReverbFreeze = function(args) return range("frozen", args[1], 0, 1) end`.
- Row: `` | `engine.setReverbFreeze(frozen)` | `"i"` | High tier: freeze the FDN reverb's tail (1) or release it (0) over 20 ms; ignored on standard and for other values. Kept while bypassed | `` (about 30 words).
- Lua: `reverb_freeze`, a binary like `delay_freeze` (`set_save` false, no scene field); its sender sends only when `S.performance.tier == "high"` (as `S.lib.freeze.spectral_offered`, `lib/freeze.lua:33-35`); `M.offered("reverb")` is that test; `M.frozen("reverb")` false on standard whatever the param, so the header mark and FX's row (`--`) never claim a frozen standard reverb.

### 3. Order and seams

- Needs 2a (the FDN with its loop at `LocalIn.ar(10)`, the loop entering before the diffusers) and 1b (`fx_hold.lua`).
- **Cut and reported** (decision 15), concretely, if the condition fails: no `setReverbFreeze`, no `frozen` on the FDN, no `reverb_freeze` param, no `FX_HOLD.reverb`, no row, no stub entry; the engine work is reverted, not left inert; an issue filed with the measurements; `docs/decisions/3.8.md` and `docs/status.md` record it; §1's "-4" line goes; the user docs never mention it. So 4a and 4b must be written against `S.lib.fx_hold.offered("reverb")` (false on standard, and false when no reverb record exists), never against the param's presence: 4a's reverb `freeze` row and the header, 4b's RF key (dark). Recommended: the plan's 3a starts with the measurement on a check-only def before any Lua, and 4a/4b's tasks state the "not offered" path.

### 4. Tests

Engine (effects area), the 1 dB condition as a check: steady pink noise into the FDN until the freeze, frozen at 2 s; the level is the mean energy in [1.0, 1.9] s against [2.1, 3.0] s, within 1 dB, and [8, 9] s within 0.6 dB of [2.1, 3.0] (facts: 0.6 dB held over 9 s); cases: size 0.5, 0.8 and 1 × damp 0 and 0.5 × drift held (the def's), and one case with shimmer 1 at ratio 2 (the loop closed by the freeze); the 6-24 kHz band within 1 dB over 9 s (rounded lengths; unrounded it fell 44-48 dB); released, under -40 dB of the frozen level 3 s later (facts: -64 dB at 2.2 s). Both SuperCollider versions: 3.13 in CI's shard, 3.14.1 locally (`test/run_engine_check_313.sh` for 3.13 in Docker). A size or damp change while frozen changes the level by under 1 dB (if size is held). On standard: `setReverbFreeze(1)` changes nothing (the standard node's output unchanged, nothing kept).
Unit (`fx_hold_test.lua`): "reverb_freeze sends setReverbFreeze on high only" (with `S.performance.tier` high and standard); "a reverb bypass ends its freeze first"; "frozen('reverb') is false on standard".

### 5. Risks and open points

1. Whether closing after the diffusers holds 1 dB is unmeasured (facts "Unsure"); the size-hold is design-silent.
2. The stub mapping of `\reverb` to `\strataReverb` (above): any reverb-only control (2a's do not have this problem: both defs carry them) needs the method or the inert arg.

---

## Package 4a: FX's rows, the arc's ALT layer, the header mark

### 1. Files

- `lib/pages/fx.lua` (262 lines): `S.FX_PAGE.rows` (`:35-55`), `draw_fx_row` (`:82-110`: `frz` beside `byp`), `fx_hints` (`:135-146`), `fx_enc` (`:148-161`), `fx_key` (`:167-176`: K3 on `clear`), `fx_alt_key` (`:214-216`: ALT+K3 freeze), `FX_SECTION_DRAWS` (`:189-195`: a shimmer section; new rows), `fx_randomize_section` (`:203-205`: by a row's section, not its effect), `layout_states` (`:227-259`), header comment (`:1-11`).
- `lib/arc/fx.lua` (66 lines): `ARC_FX_ALT_RINGS` and `record.arc_alt_delta`, `record.arc_alt_redraw` (`:58-62`).
- `lib/ui/header.lua` (`:58-73` `draw_indicators`, or `:78-101` `draw_header`) and `lib/constants.lua:106-108` (`HEADER`: a new position).
- Tests: `test/unit/pages_fx_test.lua` (pinned: `:52` "18 rows ... plus four section labels", `:41-87` every row and value inside 128×64, `:115-126` percent rows, `:139-171` K3, `:212-240` hints, `:242-280` layout states, `:282-305` ALT hint, `:451-520` randomize); `test/unit/arc_pages_test.lua` (`:174-190` FX rings, `:1118-1160` ring brightness: add the ALT state); `test/unit/ui_header_test.lua` (`:74-83` "the header constants are the plan's": the new constant; a new test for the mark); `test/unit/ui_layout_test.lua` (the JSON dump of layout states) and the page renders.
- Docs: `docs/user/pages/fx.md` (22 lines, rewritten), `docs/user/arc.md:44-50` (FX's rings; an ALT list), `docs/notes/lua/pages/fx.md` (Must not break `:3-13`: "ALT+K3 does nothing" (`:8`) becomes the freeze; K3's rule gains the `clear` exception), `docs/notes/lua/arc-pages.md:60-63`, `docs/notes/lua/ui/header-and-flashes.md:11-19` (the mark's place).
- `AGENTS.md`: nothing required (the header rule, `[BRACKETS]`, is about indicators: a pixel mark is not bracketed; see the mark below).

### 2. Names

FX rows (§7.6's order), proposed entries (`param_id`, `format`, `effect`, new fields `section` and `freeze`):
- master: density, drift (as today).
- filter: type, freq, res, mix (as today).
- delay (`bypass = "delay"`, `freeze = "delay"`): time (`synced`), `fdbk`, `level` (`delay_mix`, percent), `sync` (`binary`), `ping`, `freeze` (`delay_freeze`, `binary = true`, `on_off`), `clear` (`delay_clear`, value shown `K3`, no E3: `kind = "action"` or no `binary`/format; E3 does nothing).
- reverb (`bypass = "reverb"`, `freeze = "reverb"`): `level` (`reverb_mix`), `size`, `damp`, `to rev`? The label for `delay_to_reverb`: `"dly>rev"` (30 px) or `"from dly"`; `"delay to reverb"` is 67 px from x 6, ending at 73, clear of a right-aligned `100%` (19 px, from 105): it fits too. `freeze` (`reverb_freeze`; `--` and inert when `S.lib.fx_hold.offered("reverb")` is false).
- shimmer (`section = "shimmer"`, no `effect`): `interval` (option name), `delay` (`shimmer_delay`, percent), `reverb` (`shimmer_reverb`, percent). K3 does nothing there and the hint is `E3:value` (design-silent; recommended).
- Rows: 5 sections + 20 param rows = 25 (today 4 + 14 = 18, `pages_fx_test.lua:52`).
- Section row `frz`: right-aligned at the value column like `byp` (`S.FX_PAGE.bypass_text`, `:61-62`): `S.FX_PAGE.frozen_text = "frz"` (13 px) at `bypass_level` 4. A bypass ends a freeze, so the two never show together.
- K3: the bypass on every delay and reverb row but `clear`, where it calls `S.lib.fx_hold.clear()`. ALT+K3 (`fx_alt_key(3)`, through `alt_action`, `lib/ui/alt.lua:32-39`): on a delay row `S.lib.fx_hold.toggle("delay")`, on a reverb row `toggle("reverb")` when offered, nothing on a bypassed effect (no node: recommended, design-silent). E3 on a `freeze` row turns it on and off (`binary`, `set_binary_param`).
- Hints (widths by the stub's font, `norns_stubs.lua:2453-2474`; the row is 128 px): `K3:clear` (32) on `clear`; with ALT on a delay or reverb row `K2:rand K3:freeze E3:fine`, `K2:cancel K3:unfreeze E3:fine` the widest (122 px, fits); the shimmer rows `E3:value`.
- Randomize: `FX_SECTION_DRAWS.shimmer = {{"shimmer_interval", uniform}, {"shimmer_delay", between(0, 0.5)}, {"shimmer_reverb", between(0, 0.4)}}`; reverb gains `delay_to_reverb` (between 0.3 and 1)? (design: "FX's randomize ranges for the new rows" are the builder's). Never drawn: the freezes, the clear, the bypasses, the filter's mix. Each drawn param's action calls `note_param_edit` (1a's and 2a's params must, AGENTS "Randomize undo").
- `layout_states` to add: "delay frozen" (cursor on `delay_time`, `frz` in view), "reverb frozen on high" (needs `S.performance.tier` high in the setup; or the standard `--` row), "the clear row" (`K3:clear`), "ALT on a frozen delay row" (the 122 px hint), "shimmer at its widest" (`oct+5th`, 100%), "last row".
- Arc (`lib/arc/fx.lua`): `ARC_FX_ALT_RINGS = {{param_id = "delay_feedback"}, {param_id = "reverb_mix"}, {param_id = "shimmer_delay"}, {param_id = "shimmer_reverb"}}` (§7.6); `record.arc_alt_delta = function(n, delta) ... arc_sweep_param(ring.param_id, delta) end`, `record.arc_alt_redraw` with `arc_ring_fill(arc_port, n, param_fraction(id), ARC_FX.level)`. `lib/arc/core.lua:268-274` (`page_ring_handler`) dispatches to them while `S.alt_held`; MAIN does the same (`lib/arc/main.lua:84-93`), BUFFER and MOD likewise. The ownership tests allow the four arc fields (`arc_pages_test.lua:1086`, `ui_pages_test.lua:14`).
- Header mark: `S.lib.fx_hold.any_frozen()`.

The header's room (`lib/constants.lua:106-108`, `docs/notes/lua/ui/header-and-flashes.md:11-19`): title from x 0 (`BUFFER`/`SCENES` end near 36); ten dots x 32-69; `[M]` at 76 (12 px, to 87); the play mark at 90-92; `REC`/`ARM` at 96 (13/16 px, to 111); `S16` 114-127. On SEQ (`header_status`) the status play mark is at 73-75 and the status text 79-114. A header flash covers x 40-114. Free columns: 70-75 (6 px; 70-72 on SEQ while playing), 88-89, 93-95, 112-113. Proposed: a 3×3 pixel mark (a plus or a filled square) at x 70-72, y 4-6, level 15, drawn in the dots' branch whenever a flash is not showing (so on SEQ too): 1 px clear of the tenth dot (ends 69) and of SEQ's play mark (73). `HEADER.frozen_x = 70`, `HEADER.frozen_y = 4`. Alternative: draw the FX page's own dot (x 44) as a 2×4 bar (y 2-5) while frozen. A text mark (`*`, `[F]`) has no room: `[F]` is 11 px and MAIN's voice freeze already uses it (`lib/pages/main.lua:169`). The mark hides during a header flash, as every indicator does.

### 3. Order and seams

- Needs 1a (`delay_to_reverb`, the `level` names), 1b (`S.lib.fx_hold`), 2a (`S.lib.shimmer`, its params), 3a (`reverb_freeze`, or its absence: write against `offered`).
- 4b (grid FX page) reads the same params and `fx_hold`: no shared file with 4a (4b's is `lib/grid/pages/fx.lua`).
- The `level` labels: if 1a renamed them, 4a keeps them.
- Rules: `docs/notes/lua/pages/fx.md:8` (hint rule "ALT+K3 does nothing") and `:3-4` (K3 always the bypass) are rewritten; `AGENTS.md`'s FX filter-restore rule (`:249`) is untouched.

### 4. Tests

`pages_fx_test.lua` (new and re-based):
- "FX lists master, filter, delay, reverb and shimmer in §7.6's order" (rows by `param_id`; 25 rows, five labels).
- "K3 on the clear row clears; on every other delay and reverb row it bypasses" (one `clearDelay()`; no `setBypass`).
- "ALT+K3 on a delay row freezes and releases the delay; on a reverb row the reverb (high), nothing on standard" (`setDelayFreeze(1)`, then `(0)`; on standard no `setReverbFreeze`).
- "E3 turns a freeze row on and off" (up 1, down 0, through `set_binary_param`).
- "a frozen effect's section row shows frz" (cursor on `delay_time`; `frz` at the value column, level 4).
- "the reverb's freeze row shows -- on standard and does nothing".
- "FX's hints name K3:clear, and with ALT K3:freeze or K3:unfreeze, and fit".
- "ALT+K2 on the shimmer section draws the interval and both amounts, never a freeze".
- every new row inside 128×64 at both ends of its range (the existing `:41-87` test covers rows by iteration once the rows exist).
`arc_pages_test.lua`: "arc FX with ALT: delay feedback, reverb level, shimmer delay and reverb" (turns sweep each; draws at 12; ring brightness test gains FX's ALT levels).
`ui_header_test.lua`: "the header marks a frozen delay or reverb on every page, clear of the dots and SEQ's play mark" (every page: a 3×3 rect at x 70 while frozen, none while not; on SEQ with `header_status` and patterns playing, the mark ends left of 73; a flash hides it; a standard tier's reverb param at 1 draws none); "the header constants are the plan's" gains `frozen_x = 70`.
Page renders after the change (`docs/notes/lua/ui/layout-and-renders.md`).

### 5. Risks and open points

1. How registered fx params become rows is design-silent ("Left to the builder"). `S.register_fx_params` records accept only `name`, `count`, `add` (`lib/state.lua:156`, `FX_PARAM_FIELDS`). §7.6's order interleaves params of five modules (params_setup, delay_sync, voice_mix, fx_hold, shimmer), so rows registered per module would need positions. Recommended: 4a writes them in `S.FX_PAGE.rows` by hand, as 3.7 did for `delay_sync`'s rows; `FX_PARAM_FIELDS` unchanged.
2. `fx_randomize_section` keys on `row.effect` (`:203-205`); shimmer rows have no effect (K3 inert) but a section of their own, so rows need a `section` field.
3. The reverb freeze may be cut (3a): write every reverb-freeze path through `S.lib.fx_hold.offered("reverb")`.

---

## For the planner

1. **The 3.7.0 param fixture test blocks every package that adds a param.** `test/unit/params_setup_test.lua:1074-1085` compares all params with `test/fixtures/3.7.0-params.lua`, allowing only `removed`, `group_size` and `options` (`:995-1041`, an unknown kind raises, `:1087-1130`). 1a needs "added", "default" and "name"; 1b, 2a, 3a need "added". Settle it in Wave 0 (new kinds or a 3.8 fixture), with one owner.
2. **`fixedBufferBytes` omits shimmer's rings.** §0.2 lists four sets; §7.4's two shifters need four mono 2^14-frame rings, 256 KB of RAM. Tell 0b to count them, or give 2a `StrataPerformance.sc` and `lib/performance.lua`.
3. **Reverb default 0.43 re-bases seven unit tests** (measured): `gestures_test.lua:97`, `lfos_test.lua:429`, `macros_test.lua:93`, `mutation_test.lua:577`, `params_setup_test.lua:628` and `:1084`, `scenes_test.lua:1336`, plus `checkFreshDefaults`. It lives in four places: `params_setup.lua:570`, `scenes.lua:115`, both reverb defs.
4. **`delay_to_reverb` has no command in the design.** Recommend `setReverb(mix, size, damp, delayToReverb)` `"ffff"` (3.7 widened `setDelay` this way): 20 engine-check call sites change. Or `setDelayToReverb` `"f"`.
5. **`setReverbFreeze` breaks the FX defaults docs test if written plainly.** The stub maps `\reverb` to `\strataReverb` (`norns_stubs.lua:468-471`), and `effectDefaults(\strataReverb, [\frozen])` fails on a control the standard def lacks (`StrataEffects.sc:395-399`). Use a method outside the command body, or an inert `frozen=0` on `\strataReverb`.
6. **Every new effect control must be an `arg`-list control with a literal `.clip`.** The prototypes' NamedControls are invisible to the stub (`norns_stubs.lua:451-463`). The freeze's time hold must keep the time-limit literal the stub and `delay_sync`'s test read.
7. **The design covers a bypass that ends a freeze, not a freeze set while bypassed.** A MIDI map can set `delay_freeze` 1 then; the lift re-creates a frozen, empty, closed line. The plan should pick a rule (refuse, or release at the lift). 1b also edits `lib/voice_mix.lua`'s bypass action (1a's file).
8. **Wave 1 shares registration lines.** 1b, 1d and 1e all add an area to `areaOrder` (`test/engine_check.scd:24-25`), `ENGINE_CHECK_AREA_ORDER` (`docs_test.lua:1008-1010`), the workflow matrix (`test.yml:104-111`) and stub `checks` entries. 1a and 1e both edit `lib/params_setup.lua`, at different sites. 1a and 1c both move `test/fixtures/3.7.0-start-calls.lua` (dry; envShape).
9. **3a's cut path must be planned.** If 3a cuts, it removes the command, param, row and stub entry, so 4a and 4b must read `S.lib.fx_hold.offered("reverb")` and never the param's presence. Start 3a with the 1 dB measurement. Also hold the FDN's size while frozen (design-silent).
10. **The header has a 6 px gap at x 70-75 and nothing else.** Propose a 3×3 mark at x 70-72, y 4-6 (`HEADER.frozen_x = 70`). It sits 1 px clear of the tenth dot and of SEQ's status play mark at 73. `[F]` is taken and too wide. FX rows need a `section` field, and their rows are best written by hand in `S.FX_PAGE.rows` (`FX_PARAM_FIELDS` accepts only name, count, add).
