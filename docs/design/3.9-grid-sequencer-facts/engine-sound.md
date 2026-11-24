# Facts: what a step does to the sound (engine accent and gate, what a step can move)

## 1. How it works today

### Q1 The accent
- `voiceAccent` = `EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity)` (`lib/engine/StrataVoiceDefs.sc:102-104`): 5 ms attack, 0.4 s decay, Env.perc's default curve -4. `levelScale` is read when the envelope starts, so a new velocity never rescales a running tail.
- `voiceLevel(amp, modSig, accent)` = `(amp × (1 + modSig) × (1 + accent)).clip(0, 2)` (`lib/engine/StrataMix.sc:53-55`). It is the one formula: every voice def uses it through `voiceModulation` (`StrataVoiceDefs.sc:15-21`), and the stage uses it on the other path only (`StrataMix.sc:160,164`). The synth path in the stage takes `voiceLevel(1, ampOffset, 0)` and no accent (`:165`), so a voice is never accented twice.
- Velocity is `level / MAX_STEP_LEVEL` (`docs/notes/lua/sequencer.md`, Must not break 1). A level-15 step is velocity 1, so the accent's peak doubles the level (+6 dB) while `amp × (1 + modSig) ≤ 1`. The amp specs run 0-1 with defaults 0.25-0.35 (`lib/types/fm.lua:21`, `karplus.lua:22`), so a default voice never meets the clip at 2. A level-1 step peaks at ×1.067.
- **Where a synth voice's accent is heard**: in its voice synth, before the ring writer. The grains read the ring 5 ms (`ringReadMargin`, `StrataRings.sc:18`) plus a backward spread of up to `posSpread × 0.5 s` (`ringSpreadSeconds`, `:22`; `docs/notes/engine/rings.md`, the lookback) behind the write head. So the accent reaches the output late and smeared across grains. A buffer or input voice's accent is in the stage, after the grains, and lands at once.
- **`retrigger`** (`lib/engine/StrataVoices.sc:140-148`) sends three things:
  - `velocity` and `t_trig` to the own voice synth;
  - `t_trig` alone to every grain synth of the voice, its extra notes' included (`setGrainSynths`);
  - `velocity` and `t_trig` to the stage, only while the voice runs.

  It then calls `voiceHit(\retrigger)`, which sends the envelope routes' `\hold` and `\t_hit` (`StrataEnvelopes.sc:159-167`) and restarts a one-shot voice's scan (`docs/notes/engine/positions.md`, Must not break 7). It creates no node. Lua's only caller of it is `S.lib.engine_sync.retrigger` (`lib/engine_sync.lua:638-645`).
- **Karplus** also feeds `T2A.ar(t_trig) × velocity` into its exciter and `Pluck`'s trigger (`StrataVoiceDefs.sc:364`), so a step re-plucks it as hard as the velocity.
- **Triggered grain mode** (`grainMode` 1) plays one grain per `t_trig`, never two within `grainTriggerSeconds` (4 ms, `StrataGrainDefs.sc:20`). A grain def's own `t_accent` belongs to its note, and `retrigger` never fires it.

### Q2 The step gate
- The stage's factor is `voiceGate = (1 − seqGate.lag(0.02) × (1 − env)) × (1 − voiceMute.lag(0.02))` (`lib/engine/StrataModulation.sc:241`).
  - `env` = `EnvGen.kr(Env([0,1,1,0], [gateAttackSeconds, gateSeconds.clip(0.005,120), gateRelease.clip(0.005,4)]), t_trig + t_gate)` (`:232-233`).
  - Its attack is 5 ms rounded up to whole control blocks (`gateAttackSeconds`, `:62-65`).
  - A new trigger restarts the envelope from its current level, and each segment's time is read as that segment starts.
  - The controls' defaults are `seqGate` 0, `gateSeconds` 0.1, `gateRelease` 0.1 and `voiceMute` 0 (`:225-226`).
- The factor multiplies the stage's whole output, meaning the tap, dry and sends (`StrataMix.sc:165-169`), but not the mirror (`:168`). The delay and reverb tails ring on after the gate closes (`docs/user/sequencer.md:53`).
- **What opens the gate**:
  - `t_trig` (`retrigger`) opens it and accents.
  - `t_gate` opens it with no accent (`openStepGate`, `StrataNotes.sc:439-441`). It is sent from `extraNoteOn` for each extra note a player or a step starts.
  - Velocity never reaches the gate (`docs/notes/engine/modulation.md`, Must not break 14-15).
- **Lua's side**:
  - `seq_gate` (off/on) is the grain key `seqGate` = index − 1, and `seq_gate_release` is the grain key `gateRelease` (`lib/sequencer.lua:1659-1676`).
  - `gateSeconds` is sent directly as `engine.setGrainParam`, only when it changed (`send_gate_seconds`, `:444-448`), and before the hit's retrigger (`:761-767`).
  - `gate_seconds` = (the step's gate or `seq_gate_length`) × the nominal step / hits, clamped 0.005-120 s (`:452-458`). A ratchet's hits therefore split the gate, and each hit's `t_trig` restarts the envelope.
  - A chord's further notes send `t_gate` right after the step's retrigger, and the gate is voice-wide.
- **With the patterns stopped**, a gated voice is silent but running: `seqGate` stays 1 and `env` stays at 0 (`docs/user/sequencer.md:53`).
- **A MIDI note** first runs `M.note_gate(voice)`, which resends the voice's own gate length if a step's was the last sent (`lib/sequencer.lua:468-470`, #639). It then retriggers, which opens the gate and accents.
- **No floor exists**: a closed gate is exactly 0. Adding a floor would mean all of the following:
  - a new stage control in `voiceMixMod`;
  - an entry in the literal `grainParamHandlers` Event (`StrataModulation.sc:82-87`), whose keys the Lua stub reads;
  - `setStageParam`, which keeps the value in `grainControls`, so a stage replaced or restarted (`replaceBadVoiceMix`, `restartVoiceMix`) gets it back;
  - a Lua grain key, which a start then sends (Q5).

  The mirror stays outside the gate, so crossmod would not see the floor. The stage stays persistent, and a floor needs no re-gate (it is a plain set). On memory: the stage measures 39.6 KB against a 42 KB limit, so 2.4 KB is free (`docs/notes/engine/memory.md`, "3.8: plain sends"), and a UGen costs about 0.25 KB (`docs/notes/engine/variation.md`, Must not break 4). `controlNameSets` and `voiceControls` are not involved, because the gate controls are stage-only grain params.
- **The envelope routes' hold** is `seqGate × gateSeconds` (`StrataEnvelopes.sc:167`, ruling 26). A pulse mode that renames or splits `seqGate` changes that hold too.

### Q3 What a step can set, and how
Locks are base overrides: `set_override` → `S.lib.engine_sync.set_base_override` (`lib/sequencer.lua:324-331`). Each is set at once, never deferred, and counted in the budget (`docs/notes/lua/engine-sync.md`, Must not break 20-21). A lock lasts until the voice's next *played* step that lacks it (`apply_step`, `:646-651`).

| Target | Lua param, then engine control | Lag in the engine | Messages | Fast destination on the same value |
|---|---|---|---|---|
| Position | `v<i>_buf_pos` → `setGrainParam bufPos` (`SEQ.lock_params`, `:65`) | none: each grain latches it, and the scan goes on (`bufPos` + phase, with no restart) | 1 | 1, `bufPos + 0.5·m` (`StrataModulation.sc:200-202`) |
| Bookmark | `S.lib.positions.jump`: `params:set` of `buf_pos` (the **stored** value changes), plus `loop_start` and `loop_length` 0/1 when the mark is outside the loop, then `t_scanReset` (`lib/positions.lua:168-182`). A step recalls only inside the loop (`lib/sequencer.lua:474-479,652-655`) | none | 2 | as for position |
| Pitch lock | `v<i>_grain_pitch` → `pitchShift` | none: latched per grain | 1 | 0, `pitchShift + 1.875·m` (`StrataModulation.sc:191`) |
| Note degree | synth `v<i>_freq` → `setVoiceParam freq` + `scaleNote`; buffer `v<i>_buf_rate` → `bufRate` (the scale area resends `scaleNote`); input `v<i>_grain_pitch` (`note_param`, `lib/sequencer.lua:406-410`) | freq none, so a synth voice's pitch is heard through the ring lookback | 1-2 | the grain pitch only, never freq or bufRate |
| Size | `v<i>_grain_size` → `grainSize` | none: latched per grain; it also moves the overlap cloud's rate | 1 | 2, `+0.245·m` |
| Cutoff | **no lock today**. `v<i>_filter_freq` → `filterFreq` on the stage (`lib/voice_mix.lua:136,200`) | 0.05 s lag + the rise limit of 100 octaves a second (`StrataMix.sc:270-273`) | 1 | 3, `× 31.62^m` (`StrataModulation.sc:239`) |

- Degrees go through `S.lib.tuning.step` or `equal_step` (`degree_semitones`, `lib/sequencer.lua:431-439`). Grain quantize is the engine's (`quantizedOffset`, `docs/notes/engine/variation.md`, The scale area).
- **`filter_mix` defaults to 0** (`lib/voice_mix.lua:140`): the voice filter is bypassed until it is raised, so a cutoff step on a default voice is inaudible.
- The matrix adds on the same values: a Lua destination's sum goes into `with_lfo_offsets` on top of the override, a fast one into `setFastOffset`, and the offset node lags 0.05 s (`StrataModulation.sc:273-275`).

### Q4 Limits
- **The 20 ms floor**: `SEQ.min_ratchet_seconds` (`lib/sequencer.lua:33`). It caps retriggers at 50 a second per voice, 350 for all seven (`docs/design/3.4-design.md:306,701`). The hits are `min(ratchet, floor(step_seconds / 0.02))` (`docs/notes/lua/sequencer.md`, The clocks). The engine's own floor is 4 ms between grains (`StrataGrainDefs.sc:20`).
- **16 `noteExpression`** is a limit per step of the 48 Hz LFO clock's flush, not per sequencer step (`docs/notes/lua/notes.md`, Must not break 9 and The flush). Note commands go through `count_sends` and are never deferred.
- **A voice's own note never creates a node** (AGENTS.md). A chord's extra notes are one synth per slot, through `S.lib.notes`. The pool is 0-16 and shared by every voice.
- **Memory**:
  - a grain synth must stay under 94 KB, and `\strataGrainBuf` reads 91.8-92.7 KB (1.3-2.2 KB free);
  - the stage must stay under 42 KB and reads 39.6 KB;
  - the floors are 3 MB on standard and 3.5 MB on high, 1280 KB with the pool full (`docs/notes/engine/memory.md`, Must not break 5-8, 12).

  None of the four parts needs a node, delay line or table per voice. A slew in the grain defs for move mode would eat the 1.3-2.2 KB those defs have left.
- **Worst-case first hit, one voice** (derived from the code, never measured): up to 7 `noteOff` (`:643-645`), 4 override clears + 4 sets (+1 `scaleNote` per freq change), a bookmark jump 2-4, a slice region 2, `gateSeconds` 1, `retrigger` 1, chord notes 2-3 each, an overlap step slice about 4: about 25 commands before the chord, about 175 for seven, plus at most about 48 for chords (pool 16). A later ratchet hit is `retrigger` + a `noteOn` per held extra note. `retrigger` fans out on the server (voice synth, every grain synth, stage). `gateSeconds` and `retrigger` are uncounted by the 150-per-0.1 s budget; locks are counted.

### Q5 "The default sound does not move"
- `test/unit/system_38_test.lua:39-77` compares a fresh start with `test/fixtures/3.8.0-start-calls.lua` call for call (808 lines), with no allowed differences (`RUN_CALLS_ALLOWED = {}`). Only package 4c (#925) may re-base it (`.superpowers/sdd/2026-11-21-state-machines/plan-common.md:19`). Each voice's start sends `voiceMute 0`, `seqGate 0` and `gateRelease 0.1` (fixture lines 78, 87-88). The fixture has no step and no `retrigger`.
- The sequencer's own exact-message tests (`test/unit/sequencer_test.lua`): "an ungated voice sends nothing per hit beyond its retrigger" (`:1454`), "a one-note step and a step without notes send 3.4's messages" (`:2566`), "on a gated voice a chord step sends its gate, one retrigger and its further notes, nothing more" (`:3112`) and "a 3.6 pattern plays the same steps as before" (`:3899`).
- **What would move a default start's messages**:
  - any new grain key (a floor, a step-mode key) that a start sends;
  - a change of `seq_gate`'s default, or of what it sends, such as "pulse by default".

  Lanes, variations, rolls and keys change no start message as long as the engine still gets `seqGate 0` for a voice without steps.

## 2. What the rework would touch
- **Step you can hear**:
  - `lib/sequencer.lua`: the `seq` record (`:1659-1691`), `gated()` (`:174`), `voices_play` (`:741-786`) and `apply_step`;
  - for a floor, `voiceMixMod` and the `grainParamHandlers` (`StrataModulation.sc:82-87,223-243`) and `docs/notes/engine/modulation.md`;
  - for move mode, `SEQ.lock_params` and `lock_keys` (`:65-66`) plus a cutoff lock on `v<i>_filter_freq`. `set_base_override` serves as it is.
  - `retrigger`, `voiceAccent` and `voiceLevel` can stay.
- **Lanes**: Lua data only (`S.pattern_steps`, `ATTR_CHECKS`, the `steps` scene block). The event's fields (`velocity`, `locks`, `semitones`, `gate_beats`) can carry each lane's value unchanged.
- **Performing**: rolls are retriggers, so the 20 ms rule and the budget apply. Mutes go through `voiceMute`, which already exists.

## 3. Constraints
- In AGENTS.md: velocity only scales `levelScale`; one persistent stage, never re-gated; the mirror outside the gate and mute; `t_gate` engine-owned; `seqGate`, `gateSeconds`, `gateRelease` and `voiceMute` kept in `grainControls`; Lua owns base values and the buses hold offsets; transient scan state is never a param; no node for the own note; replace, never stack.
- The engine check's velocity test (`docs/notes/engine/voices.md`, Must not break 1), and the 3.3-equality of the stage at `seqGate` 0 within 1e-6 (`modulation.md`, Must not break 4).
- The literal `seqGate.round.clip(0, 1)` (`StrataModulation.sc:230`): the stub reads it as an enumeration (`modulation.md`, Must not break 19).
- `docs/notes/lua/sequencer.md` has **8996 words against a 9000 limit** (`test/unit/docs_test.lua:2758`); AGENTS.md has 7924 of 8000.
- Memory headroom: stage 2.4 KB, grain defs 1.3-2.2 KB (above).

## 4. Open questions
1. Should a pulse voice be silent with the patterns stopped, as gated voices are today, or sound at its floor? The code leans to silent (`seqGate` stays at 1).
2. What sends `seqGate`: the mode alone, or the mode and "has steps"? Sending on the mode alone would silence a stepless voice and move the fixture.
3. Should the floor be a stage control (engine) or Lua scaling `amp`? Lua cannot gate fast enough, so the code leans to the engine.
4. Should a move step's buffer position restart the scan (as a bookmark does) or only offset it (as a pos lock does)?
5. Is a pitch move a degree on the note param or a `grain_pitch` ratio? Today both exist, and the fast pitch offset rides only on `grain_pitch`.
6. Does a cutoff move raise `filter_mix`, or say it needs one? Today it defaults to 0.
7. Should a move persist past unplayed steps? Today it does, until the next played step without the lock. Should the stored `buf_pos` move, as a bookmark does today?
