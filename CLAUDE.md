# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Strata is an ambient granular soundscape generator for monome norns. It combines seven unique synthesis voices (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring) with individual granular processing to create evolving ambient textures.

See @README.md for additional project details

## Architecture

### Dual-Language System

This project uses two languages that work together:

1. **strata.lua** - The norns script (Lua)
   - User interface and control logic
   - Parameter management
   - Encoder/key handling
   - Communicates with the SuperCollider engine via `engine.*` commands

2. **lib/Engine_Strata.sc** - The audio engine (SuperCollider)
   - All synthesis and audio processing
   - Exposes commands to Lua via `this.addCommand()`
   - Manages audio buses, synths, and signal routing

### Audio Signal Flow

```
Voice Synth → Voice Bus → Granular Processor → Main Bus → Filter → Filter Bus → Delay → Delay Bus → Reverb → Reverb Bus → Master (drift/limiter/saturation) → Output
                  ↓
              Mod Synth → Mod Bus → Other Voice Synths (cross-modulation)

Buffer source:  Buffer pair (L/R) → strataGrainBuf → Main Bus (and mirrored to the Voice Bus → Mod Synth)
Input source:   SoundIn → strataInput → Input Bus → strataGrain → Main Bus (and mirrored to the Voice Bus → Mod Synth)
```

Each of the 7 voices follows this path:
1. Voice synth (strataResonator/strataFM/strataFolder/strataSub/strataPulse/strataKarplus/strataRing) outputs to its own `granBuses[i]`
2. Granular processor (`strataGrain`) reads from voice bus, outputs to shared `mainBus`
3. Modulation synth (`strataMod`) analyzes voice bus output and generates control signal to `modBuses[i]`
4. Other voice synths can read from any `modBuses[i]` to modulate their amplitude and/or frequency
5. Filter (`strataFilter`) processes mainBus, outputs to `filterBus`; delay (`strataDelay`) processes filterBus, outputs to `delayBus`
6. Reverb (`strataReverb`) processes delayBus, outputs to `reverbBus`
7. Master (`strataMaster`) applies drift, a `Limiter.ar(sig, 0.95)` safety stage that catches peaks before saturation, then saturation, and outputs to norns output

### Cross-Modulation System

Each voice generates a modulation signal (envelope follower + slow LFO) that can modulate other voices:
- **Modulation Output**: Each voice has a `strataMod` synth that analyzes its audio output and creates a control signal (0-1 range)
- **Modulation Input**: Each voice synth can receive modulation from up to 3 different sources simultaneously
- **3 Modulation Slots**: Each voice has 3 independent modulation slots, each with its own source and depth controls
- **Routing**: Controlled via `setModSource(voice, slot, sourceVoice)` where slot is 1-3
- **Depth Control**: Each slot has independent `modAmpAmt` and `modFreqAmt` controls
- **Signal Mixing**: The 3 modulation signals are mixed together (weighted sum) before applying to voice parameters
- **Signal Character**: The mod signal combines envelope following (70%) with slow LFO movement (30%) for organic evolution

### Lua ↔ SuperCollider Communication

**IMPORTANT**: This section documents the current engine command interface. Keep it updated when adding/modifying commands.

The Lua script controls the engine through these commands:

| Lua Command | SC Signature | Purpose |
|-------------|--------------|---------|
| `engine.voiceOn(voice, freq, amp, pan, grainSize, grainDensity, pitchShift)` | `"iffffff"` | Start a voice with initial parameters |
| `engine.voiceOff(voice)` | `"i"` | Stop a voice (gates off with release envelope) |
| `engine.retrigger(voice, velocity)` | `"if"` | Accent a running voice in place at `velocity` (0-1): fires the voice synth's `t_trig` accent envelope scaled by velocity (Karplus re-plucks), and one grain when the voice is in triggered grain mode. Creates no nodes; used by pattern steps (velocity = step level / 15) and MIDI notes |
| `engine.setVoiceParam(voice, param, value)` | `"isf"` | Update synthesis parameters dynamically |
| `engine.setGrainParam(voice, param, value)` | `"isf"` | Update granular parameters dynamically (`envShape` is an index the engine maps to an envelope buffer; `grainMode` 0 = continuous, 1 = triggered) |
| `engine.setMasterDrift(amount)` | `"f"` | Control global tape drift effect |
| `engine.setReverb(mix, size, damp)` | `"fff"` | Update reverb (mix, size, damping) |
| `engine.setFilter(freq, res, type, mix)` | `"ffif"` | Update the master filter: freq 20-20000 Hz, res 0-1 (rq = `1 - res * 0.95`), type 0 lowpass / 1 highpass / 2 bandpass (Lua `filter_type` option index - 1), mix 0 (bypass) to 1 |
| `engine.setDelay(time, feedback, mix)` | `"fff"` | Update the master delay: time 0.01-2 s (lagged 0.1 s), feedback 0-0.95, mix 0 (dry) to 1 |
| `engine.setModSource(voice, slot, sourceVoice)` | `"iii"` | Set which voice modulates this voice at given slot (slot=1-3, sourceVoice: -1=none, 0-6=voice index). "None" routes the slot to the engine's always-zero `silentBus` |
| `engine.setModAmpAmt(voice, slot, amount)` | `"iif"` | Set amplitude modulation amount for given slot (-2 to 2) |
| `engine.setModFreqAmt(voice, slot, amount)` | `"iif"` | Set frequency modulation amount for given slot (-2 to 2) |
| `engine.setModSpeed(voice, speed)` | `"if"` | Set modulation LFO speed (0.1 to 50) |
| `engine.setGrainSource(voice, source)` | `"ii"` | Choose a voice's audio source: 0 = its synth, 1-8 = buffer slot, 9 = live input. A running voice gets its grain synth replaced (never stacked); a stopped voice only records it. Same source = no-op; out-of-range sources are ignored |
| `engine.loadBuffer(slot, path)` | `"is"` | Read up to 16 s of a sound file into slot 0-7 (stereo: L/R; mono: both). Missing/unreadable files leave the slot unchanged |
| `engine.recordBuffer(slot, seconds, level)` | `"iff"` | Record the live input × level into slot 0-7, replacing it (seconds clamped to 16 s). On completion writes the scratch take `buf<n>.wav` |
| `engine.clearBuffer(slot)` | `"i"` | Zero slot 0-7 (cancels a recording in progress) |
| `engine.stopRecord(slot)` | `"i"` | End slot 0-7's recording early, keeping what was captured: the valid length becomes the frames actually recorded, the scratch take is written and the poll updated, as for a completed recording. No-op if the slot is not recording |
| `engine.saveBuffer(slot, path)` | `"is"` | Write the slot's valid region to `path` as a stereo 16-bit WAV (creates the directory) |

**Poll `bufferState`** (engine → Lua): each slot's valid seconds. matron's `/poll/value` handler is typed `"if"` (one float) and its data-blob polls are broken (`w_handle_poll_data` writes every byte to index 1), so a string or table cannot reach Lua: every message carries **one** slot as `slot_index * 100 + seconds` (`bufferStateStride = 100`; seconds ≤ 16, rounded to 0.01). Decode in Lua with `slot = math.floor(value / 100)` (0-based, so Lua slot `slot + 1`) and `seconds = value - slot * 100`. The poll is periodic (0.25 s) and cycles through the eight slots; every change (load, record start, completion and early stop, clear) is also sent immediately via `bufferStatePoll.update`. A slot reads 0 s while it records and its length once the recording completes. Lua: `init` calls `poll.set("bufferState", buffer_state_changed)` and starts it (it prints a message if the poll is missing); `buffer_state_changed` decodes the value with `BUFFER_STATE_STRIDE` (100) into `buffers[slot].seconds` and ignores slots outside 1..`NUM_BUFFERS`; `cleanup` stops it.

**Index Conversion**: Voice indices are 0-indexed in SuperCollider but 1-indexed in Lua. Always subtract 1 when calling engine commands from Lua (e.g., `engine.voiceOn(voice_idx - 1, ...)`). Mod sources are converted by `engine_mod_source()` (Lua 0=none / 1-7 → SC -1=none / 0-6).

**Starting a voice (`toggle_voice` → `sync_voice_to_engine`)**: `voiceOn` only carries the initial freq/amp/pan and grain size/density/pitch, and param actions only reach the engine while a voice is active. So `toggle_voice` calls `sync_voice_to_engine(voice_idx)` right after `engine.voiceOn`, which sends `setGrainSource(voice, source - 1)` **first**, then (`sync_voice_values_to_engine`) every `voices[i].params` entry (`setVoiceParam`), all nine grain params (`setGrainParam`: size, density × `master_density`, pitch, spread, `envShape` and `grainMode` = option index − 1, `bufPos`, `bufRate`, `bufScan`), every crossmod slot (`setModSource`/`setModAmpAmt`/`setModFreqAmt`) and `setModSpeed`. The engine holds no per-voice defaults of its own (there is no `getVoiceParams`); the Lua `voices` table is the only source of values. The `v<i>_source` param action is the one voice param that also reaches a stopped voice: it always sends `setGrainSource` (the engine only records it, so the next `voiceOn` builds the right synths), then, for a running voice, `sync_voice_values_to_engine`. `setGrainSource` after `voiceOn` in `sync_voice_to_engine` is then a no-op in the engine.

**Silent bus**: An unrouted mod slot must read a bus that is always zero. Control bus 0 is not safe on norns (CroneAudioContext allocates the input amplitude follower `amp_in_b` there before any engine loads), so the engine allocates `silentBus` in `alloc`, sets it to 0, uses its index for `sourceVoice = -1` and as the `voiceOn` default for `modBus1..3`, and frees it in `free`.

**Retrigger**: Pattern steps never create synth nodes. For a running voice the pattern clock calls `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)` (step level 1-15, so a step's brightness is its velocity). The engine sets `velocity` and `t_trig` in one message on the voice synth and on the grain synth. Every voice SynthDef has a plain `velocity=1` control and an accent envelope `EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity)` applied as `modAmp * (1 + accent)` inside the amplitude clamp. `levelScale` is sampled when the envelope (re)starts, so a new velocity never rescales a running accent tail; never multiply a running signal by `velocity`. Karplus also feeds `T2A.ar(t_trig) * velocity` (a single-sample impulse, so only that trigger's excitation is scaled) into its exciter and `Pluck` trig inputs so it re-plucks as hard as the velocity. In `\strataGrain` the trigger only matters in triggered grain mode (one grain per trigger). For buffer and input sources there is no voice synth, so the accent lives in the grain synth: `\strataGrainBuf` and `\strataGrain` have the same `EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity)` accent. `\strataGrain` applies it only with `accentAmt = 1` (input source); for the synth source the engine sets `accentAmt = 0` so voices are not double-accented and velocity reaches triggered grains through the voice accent. Grain-side velocity is always per trigger (`levelScale`), never a bare multiplier on the output (`GrainIn`/`GrainBuf` grains still playing would jump); the engine check asserts `velocity` feeds only `EnvGen` `levelScale` inputs in both grain SynthDefs. A step on a stopped voice starts it with `toggle_voice`. K3 on MAIN keeps its start/freeze meaning: triggered grains fire from pattern steps and MIDI notes only (a deliberate deviation from the spec's "K3 on MAIN with the voice already on").

**Current Voice Parameters** (as of latest sync):
- **Resonator**: freq, rq, noise, mod1, mod2, amp, pan
- **FM**: freq, ratio, index, modFreq, amp, pan
- **Folder**: freq, fold, mod, amp, pan
- **Sub**: freq, drift, amp
- **Pulse**: freq, width, cutoff, res, amp, pan
- **Karplus**: freq, decay, damping, excite, amp, pan
- **Ring**: freq, ratio, mod, brightness, amp, pan

**Current Granular Parameters**: grainSize, grainDensity, pitchShift, posSpread, envShape, grainMode, bufPos, bufRate, bufScan (the last three only matter to `\strataGrainBuf`, i.e. buffer sources; Lua `v<i>_buf_pos` 0-1 lin step 0, `v<i>_buf_rate` 0.25-4 exp, `v<i>_buf_scan` -2..2 lin, in `voices[i].grain.buf_pos|buf_rate|buf_scan`)
- `envShape` (Lua option `v<i>_grain_env`, `GRAIN_ENV_OPTIONS = {"hann", "sine", "perc", "linen", "trap"}`, default hann; `voices[i].grain.env` holds the option index 1-5) is sent as index − 1. The engine's `envBufnumFor(index)` turns it into the grain synth's `envBuf`: 0 = `-1` (GrainIn's built-in Hann), 1-4 = `envBuffers[index - 1].bufnum`; any other index is ignored. `envBuffers` are four 1024-frame `Buffer.loadCollection`s of `Env.sine`, `Env.perc(0.1, 0.9)`, `Env.linen(0.1, 0.8, 0.1)` and the trapezoid `Env([0, 1, 1, 0], [0.25, 0.5, 0.25])`
- `grainMode` (Lua option `v<i>_grain_mode`, `GRAIN_MODE_OPTIONS = {"continuous", "triggered"}`, default continuous; `voices[i].grain.mode` holds the option index 1-2) is sent as index − 1. `\strataGrain` picks its `GrainIn` trigger with `Select.ar(mode, [Impulse.ar(grainDensity), T2A.ar(t_trig)])` (`mode = grainMode.round.clip(0, 1)`): continuous fires `grainDensity` grains per second, triggered fires one grain per `retrigger` (its level follows the voice accent, not a grain-side velocity) and mutes the position-spread path so only the triggered grains sound. MAIN shows `[TRIG]` for a voice in triggered mode
- `DISCRETE_GRAIN_KEYS` (`{ env = #GRAIN_ENV_OPTIONS, mode = #GRAIN_MODE_OPTIONS }`) maps the grain keys that hold an option index to their option count: `scene_transition_targets` skips them (they switch when the fade ends), mutation and randomize never touch them, and `validate_scene` requires integers from 1 to the count
- `pitchShift` (Lua `grain_pitch`, 0.25-4) is a real transposition: the grain output runs through `PitchShift.ar` (window = `grainSize` clipped to 0.01-0.5, fixed when the synth starts; ratio = `pitchShift.lag(0.5)`). It is not a gain.

**Cross-Modulation Parameters** (per voice, 3 slots per voice):
- **Slot 1, 2, 3** - Each slot has:
  - **source**: Which voice modulates this slot (0=none, 1-7 in Lua, -1=none, 0-6 in SC)
  - **amp_amt**: Amplitude modulation depth (-2 to 2, bipolar)
  - **freq_amt**: Frequency modulation depth (-2 to 2, bipolar)
- **speed**: Modulation signal LFO speed (0.1 to 50 Hz, shared across all slots)

### Audio Sources (buffers and live input)

Every voice's grain stage has a source (`grainSource[voice]`): 0 = its own synth (the voice synth writes `granBuses[i]`, `\strataGrain` reads it), 1-8 = buffer slot, 9 = live input. The engine side:

- **Buffer slots**: `numBuffers = 8` slots (mirrors Lua `NUM_BUFFERS`), each a pair of mono buffers `buffersL[i]`/`buffersR[i]` (GrainBuf reads mono buffers only) of `sampleRate * bufferSeconds` frames (`bufferSeconds = 16`, mirrors `BUFFER_SECONDS`). Memory: 8 × 2 × 16 s × 48 kHz × 4 bytes ≈ 49 MB of scsynth memory. Never allocate longer buffers. `bufferFrames[i]` is the valid length (0 = empty); `bufferSampleRates[i]` the content's sample rate. bufnums never change: loads read into the existing buffers
- **`\strataGrainBuf`**: two `GrainBuf.ar(1, ...)` (left, right) sharing one trigger, position, rate and duration, so grains stay sample-aligned and the stereo image is kept; `Balance2` with `LFNoise1.kr(2).range(panSpread.neg, panSpread)`, then one `PitchShift` stage on the pair. `bufPos` (0-1) and the scan are fractions of the valid region (`bufFrames / BufFrames`), so a 2 s sample uses the whole range; `bufScan` moves the position in **valid-region lengths per second** (spec §1; bipolar, wraps); grain position jitter ± `posSpread * 0.5`. Rate = `bufRate * bend * bufRateScale * (1 + rateMod)` where `bufRateScale` = content rate / server rate, tracked by the engine (`b_alloc`/`b_zero` keep a loaded file's rate on the server buffer and norns' scsynth predates `b_setSampleRate`, so `BufRateScale.kr` would be wrong after recording into a slot that held a file). Crossmod applies to amplitude and rate like voices (`rateMod` clamped -0.9..2), the accent is per trigger, and `grainMode` works as in `\strataGrain`
- **Live input**: the persistent `\strataInput` synth (`SoundIn.ar([0, 1])` → stereo `inputBus`) at the head of `voiceGroup`. Input-sourced voices run `\strataGrain` with `in = inputBus`
- **Mirror to the voice bus**: with no voice synth, a buffer- or input-sourced voice's `granBuses[i]` would be silent and its `\strataMod` (and every voice it modulates) would go dead. So `\strataGrainBuf` always writes its output to `mirrorOut` (= `granBuses[i]`) as well as `mainBus`, and `\strataGrain` does when `mirrorLevel = 1` (input source). In synth mode `mirrorLevel = 0`: that grain synth reads `granBuses[i]`, so mirroring would feed back. Grain synths are added at the head of `processGroup` and mod synths at its tail, so the mirror reaches `\strataMod` in the same block
- **Voice-level controls follow the source**: `voiceControls[voice]` keeps every `setVoiceParam` and crossmod value (reset by `voiceOn` to its freq/amp/pan and silent routing) and `grainControls[voice]` every `setGrainParam` (reset by `voiceOn` to its size/density/pitch; `envShape` stored as `envBuf`). When the source is not the synth, `setVoiceControl` also sends the controls the grain SynthDef has: `amp` (the voice's level), `bend` and the crossmod routing/amounts for `\strataGrainBuf`, `amp` for the input `\strataGrain`. The synth-source `\strataGrain` keeps `amp = 1` (the voice synth applies the level)

**Replace, never stack.** `setGrainSource` on a running voice calls `replaceGrainSynth`: the new grain synth is created with the voice's current `grainControls` (and voice-level controls) and the old one is gated off (2 s `grainRelease`) in the same call, so one voice never runs two grain paths beyond that release. Leaving the synth source releases the voice synth with `release(grainRelease)` (a forced release: its sound only reached the output through the old grain synth, so it does not run its own up-to-12 s release silently); returning to the synth source starts a new voice synth from `voiceControls`. A replacement that reads the voice bus (synth source) is placed `\addBefore` the releasing grain synth and one that mirrors into it `\addAfter`, so neither re-grains the other's mirror. `voiceOn` for a voice whose source is not 0 builds `\strataGrainBuf` (or the input `\strataGrain`) directly and no voice synth. `setGrainSource` with the current source does nothing (Lua sends it on every voice start).

**Buffer commands** (`loadSlot`, `recordSlot`, `clearSlot`, `writeSlot` in the engine): load zeroes the pair, opens the file with `SoundFile` (frames, channels, rate; anything unreadable is logged and the slot left unchanged) and `readChannel`s at most 16 s (at the file's rate) into the existing buffers. Record zeroes the pair and, after a `server.sync` (so the zeroing never lands on the take), starts a `\strataRecord` synth (two `RecordBuf`s of `In.ar(inputBus, 2) * level`, `loop: 0`, plus a `Line` with `doneAction: 2` for the duration) right after `inputSynth`, unless the recording was cancelled meanwhile (`recordSynths[i]` is the token; do not use a zero completion message: it cannot be cancelled before the node exists). The slot reads 0 frames until the recording completes (`onFree`), then gets its frames and the take is written to `scratchDir +/+ "buf<n>.wav"`. A new record, load or clear on the slot cancels a recording in progress or pending (`stopRecording`), which writes nothing. `stopRecord` (`stopRecordSlot`) instead keeps the take: the record synth writes its frame count (`Sweep.kr(0, SampleRate.ir)`) to the slot's `recordFrameBuses[i]`; the engine frees the synth, reads that bus (`/c_get` is answered after the `/n_free`, and the bus keeps its last value), sets `bufferFrames[i]` to it and writes the scratch take. Read `isPlaying` before freeing (`Node.free` clears it). A recording still waiting for its zeroed buffers has captured nothing and is just cancelled. `writeSlot(index, path)` (scratch takes and `saveBuffer`) has the server write each mono buffer's valid frames to a temporary float file, then sclang interleaves them in 8192-frame chunks (yielding `writeChunkWait`, 1 ms, between chunks) into a stereo 16-bit WAV at the content's rate and deletes the temporaries; it creates no synth nodes. Writes to the same path can overlap (a full 16 s take is still being written when the next, shorter take completes), so each write gets a generation number in `writeGenerations[path]`, interleaves into its own `path.<generation>.part` file, and renames it into place (`mv -f`, atomic on one filesystem; sclang has no `File.rename`) only if it is still the newest write for that path. An older write checks after every chunk, abandons as soon as a newer one starts, and deletes its `.part`. The newest write always wins, two writes never mix, and a reader never sees a half-written file. Never open the final path directly for writing: `SoundFile.openWrite` truncates it, and libsndfile rewrites the header on `close`. The engine check sets `writeChunkWait` to 0.02 s so the overlap is certain. Every change updates `bufferFrames`, the grain synths reading the slot (`bufFrames`, `bufRateScale`) and the `bufferState` poll.

**Scratch directory**: `scratchDir` (engine variable, settable) defaults to `Platform.userHomeDir +/+ "dust/audio/strata/scratch/"`, which equals Lua's `_path.audio .. "strata/scratch/"` on norns; it is created on demand before writing. `test/engine_check.scd` points it at a temporary directory so the check never writes into `~/dust`.

**Lua side** (strata.lua):
- **Per-voice source**: option `v<i>_source` over `SOURCE_OPTIONS = {"synth", "buf 1", ..., "buf 8", "input"}` (built from `NUM_BUFFERS`), default synth, held in `voices[i].source`. The action always sends `setGrainSource(i - 1, x - 1)`, then for a running voice `sync_voice_values_to_engine`, clamps the grid `param_page` and redraws. `voice_uses_synth(i)` (source 1), `voice_uses_buffer(i)` (sources 2-9; input is not a buffer) and `voice_source_label(i)` (the option name) are the helpers. The source params sit at the top of each voice's granular section with `v<i>_buf_pos`, `v<i>_buf_rate`, `v<i>_buf_scan`
- **Behaviour rules (spec §1, input amended by controller ruling)**: for a buffer source (`voice_uses_buffer`): E3, arc ring 2 and MAIN's main parameter are `buf_pos` (label `pos`, through `main_param_entry`), the 256 grid's first faders are `BUFFER_FADER_KEYS`, `randomize_voice` sets `buf_pos` (0-1), `buf_rate` (0.5-2, `2 ^ (r * 2 - 1)`) and `buf_scan` (-0.5..0.5) plus grain size/pitch instead of synthesis params, `gentle_mutate` mutates the buffer params instead of synthesis params, and `lfo_update` drifts `buf_pos` as well as grain pitch. For the input source both the synth and the buffer params are dead in the engine, so the main param is `grain_size` (`INPUT_MAIN_PARAM`, label `size`, `%.2f s`, arc scale 0.01 like MAIN ring 3), its faders start with the grain params (then `amp`), and `randomize_voice`, `gentle_mutate` and `lfo_update` touch only grain params. Test with `voice_uses_synth` / `voice_uses_buffer`, never `not voice_uses_synth` (that includes input). `source` is never randomized or mutated; freeze covers the buffer params. `voice_buffer_slot(i)` is the slot (1-8) a buffer-sourced voice reads, or nil
- **Buffers table**: `buffers[slot]` = `{name, loaded, recording, seconds, path}` per slot (`name = "empty"` until something is loaded or recorded). `load_buffer(slot, path)` sends `loadBuffer` and sets `name` (the file name), `loaded`, `path`; it ignores `""`, norns' `"-"` (no file chosen) and directory paths. `record_buffer(slot)` sends `recordBuffer(slot - 1, record_duration, record_level)`, sets `recording` and starts a `clock.run` timer of `record_duration` (`buffer_record_clocks[slot]`) that ends it with `name = "take <n>"`, `loaded = true` and `path` = the scratch take `_path.audio .. "strata/scratch/buf<n>.wav"`; called while the slot records, it sends `stopRecord` and ends the take the same way at once. `clear_buffer(slot)` sends `clearBuffer` and resets the slot. Load, clear and stop cancel the slot's timer (the engine cancels its recording). `save_buffer(slot)` does `util.make_dir(buffer_audio_dir)` and `saveBuffer(slot - 1, buffer_save_path(slot))` (`_path.audio .. "strata/<YYYYMMDD-HHMMSS>-buf<n>.wav"`) and prints the path; a slot with nothing in it (not loaded, 0 s) is not saved. `seconds` comes only from the poll. Load, record (start, stop, timer end) and clear call `buffer_display_changed()` (`redraw()` + `grid_redraw()`: the BUFFER page and grid page 4 show the state); `buffer_state_changed` redraws the screen, and the grid while `grid_page == 4`, only when a slot's seconds change (the periodic poll repeats values). All four check the slot (1..`NUM_BUFFERS`); `cleanup` cancels the timers and stops the poll
- **Buffer params**: group `strata_buffers` (size `2 + NUM_BUFFERS * 4`): `record_duration` (0.5-`BUFFER_SECONDS` s, default 8), `record_level` (0-2, default 1), then per slot `buf<n>_file` (`params:add_file`, starting folder `_path.audio`; action `load_buffer`), `buf<n>_record`, `buf<n>_clear`, `buf<n>_save` triggers
- **Scenes** capture `voices[i].source` and the three buffer params (through `GRAIN_PARAM_IDS`), never buffer contents: a recalled scene plays whatever is in the slot now. `source` switches at the end of a smooth transition (it is not in `params`/`grain`, so `scene_transition_targets` skips it); the buffer params crossfade. `VOICE_SCENE_DEFAULTS` gives older scenes `source = 1` and the buffer params' defaults; `validate_scene` requires `source` to be an integer 1..`#SOURCE_OPTIONS`

## Development & Testing

### Running on norns

1. Copy the project to `~/dust/code/` on the norns
2. Restart norns or run `;restart` in maiden
3. Select the script from the norns SELECT menu

### Testing Changes

**Off-device tests** (run from the repo root before committing):
- `lua test/run.lua` and `luajit test/run.lua` - loads `strata.lua` into norns stubs (`test/norns_stubs.lua`) and runs the behaviour tests; exits non-zero on failure. The engine stub rejects any `engine.*` call whose name, argument count or types do not match the SC `addCommand` signatures, and the run includes the static sync check. Like norns, the param stub stores numeric type codes in `param.t` (`params.tOPTION` etc.); never compare `param.t` with a string (a test enforces this for `strata.lua`).
- `lua test/sync_check.lua` - static check that every `engine.<name>(...)` call in `strata.lua` has a matching `addCommand` with the same number of arguments, and that every command is used.
- `test/run_engine_check.sh [path/to/norns]` - compiles `lib/Engine_Strata.sc` against the real norns `sc/core` classes (default `~/src/norns`, or `$NORNS_DIR`), boots a local scsynth with its output on a private bus (silent) and runs `test/engine_check.scd`, which drives every engine command. Needs SuperCollider (`$SCLANG` overrides the sclang path).
- `test/StrataTestNoBoot.sc.in` is deliberately not a `.sc` file: norns compiles every `.sc` under `~/dust`, and that test class disables Crone's boot.
- Add a test to `test/run.lua` for every behaviour change; script locals are reached through `find_upvalue()`/`local_value()`.
- The stubs mirror the real norns libraries (`~/src/norns/lua`), so check behaviour there before changing them. Besides params (number, control, option, binary, trigger, file, text, separator, group; `set_action`, `hide`/`show`/`visible`), they provide: `require("lfo")` (`test/stub_lfo.lua`: the library's `lfo_*` params and actions; nothing runs on its own, `context.lfo.tick(instance, raw)` performs one library step with `raw` 0..1 as the shape output), `midi` (`test/stub_midi.lua`: 16 vports, `to_msg`/`to_data`; helpers `context.midi.plug(port, name)`, `unplug(port)`, `send(port, msg)`), `poll.set` (system polls plus the engine's `addPoll` names, unknown names return nil; `context.polls.fire(name, value)` reaches started polls), `fileselect.enter` (records `fileselect.last`), `require("musicutil").note_num_to_freq`, `_path.audio` (`context.audio_dir`), `util.scandir`/`util.os_capture`, `_menu.rebuild_params`, and `norns.enc.accel`/`sens` (state in `context.encoders.accel`/`sens`, starting at norns' script defaults accel on / sens 2; `context.encoders.deliver(n, delta, interval)` delivers one hardware encoder event the way `encoders.process_with_accel` does, with `interval` seconds since the previous one).

**On hardware** - since this runs on norns hardware (or norns shield/fates):
- Use maiden (norns web IDE at `http://norns.local/maiden`) to edit files and view console output
- The maiden REPL is useful for testing Lua code
- SuperCollider changes require script restart
- Watch for errors in the maiden console (bottom panel)

### Common Issues

**UI errors**: The norns UI library has specific requirements:
- `UI.List` doesn't have `set_items()` - recreate the list instead
- `UI.List.new(x, y, index, items)` requires all parameters

**Coroutine errors**: Some functions require coroutine context:
- `clock.sleep()` must be called inside `clock.run(function() ... end)`
- Never call `clock.sleep()` directly in `init()`

**Parameter naming**: Avoid parameter ID collisions:
- norns has built-in params like "reverb"
- Use prefixed names like "strata_fx" for separators and groups
- Each param needs a unique ID

## Code Style Guidelines

### Always use named constants for magic numbers (v2.0+)

**CRITICAL**: The codebase uses named constants defined at the top of [strata.lua](strata.lua) (the "Constants" block):
```lua
local NUM_VOICES = 7        -- Total number of synthesis voices
local NUM_SCENES = 8        -- Total number of scene slots
local PATTERN_LENGTH = 16   -- Steps per pattern
local SCENE_DATA_VERSION = 2  -- Scene file format version (written into scenes.data)
local NUM_MOD_SLOTS = 3     -- Cross-modulation slots per voice
local NUM_UI_PAGES = 5      -- Screen pages (MAIN, FX, LFO, BUFFER, SETUP), selected with E1
local MAX_STEP_LEVEL = 15   -- Pattern step levels 0 (off) to 15; level / 15 = retrigger velocity
local NUM_BUFFERS = 8       -- Sample buffer slots
local BUFFER_SECONDS = 16   -- Length of each buffer slot (record_duration maximum)
```
The engine mirrors `NUM_VOICES` as `numVoices`, `NUM_BUFFERS` as `numBuffers` and `BUFFER_SECONDS` as `bufferSeconds` in [lib/Engine_Strata.sc](lib/Engine_Strata.sc). Remaining bare numbers in grid code are grid coordinates and LED levels, not counts.

**Always use these constants** instead of hardcoded numbers:
- Use `NUM_VOICES` in voice loops: `for i = 1, NUM_VOICES do`
- Use `NUM_SCENES` for scene validation: `if scene_num > NUM_SCENES then return end`
- Use `PATTERN_LENGTH` for pattern operations: `for step = 1, PATTERN_LENGTH do`
- Never use hardcoded 7, 8, or 16 in voice/scene/pattern code

**Why this matters**:
- Makes code maintainable if voice/scene counts change
- Prevents subtle bugs from inconsistent hardcoded values
- Self-documents the meaning of these numbers
- Enables easy extension (e.g., adding voice 8)

### Always use descriptive variable names

Prefer clarity over brevity. Good examples from this codebase:
- `selected_voice` over `sv`
- `master_density` over `density` or `md`
- `lfo_metro` over `metro` or `lfo`

### Always keep README.md and CLAUDE.md updated as changes are made to the codebase

When making significant changes to the codebase, ensure both documentation files reflect:
- New features or architectural changes
- Updated workflows or testing procedures
- New patterns or conventions introduced
- Changes to the signal flow or engine commands

### IMPORTANT: Always update the UI when adding features or changing the codebase

**The norns screen is 128×64 pixels - every pixel matters.** The UI must evolve with the codebase to remain usable and informative.

#### UI Design Principles for norns

1. **Screen Constraints**:
   - Total resolution: 128×64 pixels
   - Use column layouts to maximize information density without overlapping
   - Current layout (MAIN page): Left column (0-60px) for voice list, Right column (65-128px) for parameters
   - Reserve the hint row (y=62, drawn by `draw_hints()`) on every page for key hints

2. **Scrolling Lists**:
   - Use `UI.ScrollingList` for lists that exceed visible space
   - Set `num_visible` appropriately (currently 4 for 7 voices: `UI.ScrollingList` draws row i at `y + 5 + (i - 1) * 11`, so from y=10 a fifth row at y=59 would collide with the hint row)
   - Set `num_above_selected` for context (currently 1)
   - Always set `active = true` and update `index` when selection changes

3. **Information Hierarchy**:
   - Page title at top (y=8, `draw_header()`)
   - Critical global params in header (master density)
   - Selected item details in dedicated column
   - Helper text at bottom (key functions)

#### When Adding New Features, Update the UI to:

1. **Display New Parameters**:
   - Add new parameters to the right column display
   - Consider abbreviating labels if space is tight (e.g., "dens" instead of "density")
   - Use appropriate units (Hz, s, %, etc.)
   - Update the parameter value display in the page's draw function (`redraw_main()`, ...)

2. **Add New Voices**:
   - Voice list automatically scrolls with more than 4 voices
   - Add the voice type to `MAIN_PARAMS` (E3, MAIN display and arc ring 2 follow)
   - Update `get_param_spec()` with controlspec for new parameters
   - Consider whether right column layout needs adjustment

3. **Add New Status Indicators**:
   - Place indicators in consistent locations (currently status at y=26)
   - Use brightness levels to show importance (15=bright, 4=dim, 1=subtle)
   - Consider using `[BRACKETS]` for state indicators like `[FREEZE]`

4. **Maintain Visual Balance**:
   - Keep divider line between columns (x=62)
   - Preserve alignment of related information
   - Use consistent spacing between UI elements
   - Test with all voices to ensure nothing overlaps or clips

#### UI Update Checklist

Before completing any feature addition, verify:
- [ ] New parameters are visible in the UI without overlapping
- [ ] Voice list scrolling still works correctly
- [ ] All status indicators are clearly visible
- [ ] Parameter values display with appropriate precision and units
- [ ] Key hints at bottom reflect current functionality
- [ ] UI works correctly for all 7 voices
- [ ] No text or graphics extend beyond screen bounds (128×64)
- [ ] Visual hierarchy remains clear (title → list → details → hints)

### CRITICAL: Always keep the Lua script and SuperCollider engine synchronized

**This is the most important rule for this codebase.** The dual-language architecture requires strict synchronization between [strata.lua](strata.lua) and [lib/Engine_Strata.sc](lib/Engine_Strata.sc).

#### When modifying the SuperCollider engine, you MUST update:

1. **Engine Commands** - If you add/modify `this.addCommand()` in the SC file:
   - Add corresponding `engine.*` calls in the Lua file
   - Ensure parameter counts and types match exactly
   - Update the "Lua ↔ SuperCollider Communication" section in this file

2. **SynthDef Parameters** - If you add/modify SynthDef arguments:
   - Update the `voices` table in Lua with matching parameter names
   - Add corresponding params in `add_voice_params()` function
   - Add to `get_param_spec()` with appropriate controlspec
   - Ensure `engine.setVoiceParam()` calls use the correct parameter names

3. **Voice-Specific Parameters** - If you change voice parameters:
   - Update default values in Lua `voices` table (the engine has no per-voice defaults to update; `sync_voice_to_engine` sends the Lua values)
   - Update the voice's `param_order` list (menu order and grid fader order)
   - Verify parameter names match between SC SynthDef args and Lua param IDs

#### When modifying the Lua script, you MUST update:

1. **New Engine Calls** - If you add new `engine.*` calls:
   - Add corresponding `this.addCommand()` in the SC engine
   - Match the parameter signature exactly (use SC type codes: i=int, f=float, s=string)
   - Test the command works on norns/maiden

2. **Parameter Changes** - If you modify voice parameters:
   - Update the corresponding SynthDef arguments in SC
   - Ensure default values match between Lua and SC
   - Update voice-specific parameter lists

3. **Granular Parameters** - If you modify grain processing:
   - Update `\strataGrain` SynthDef arguments
   - Update `engine.setGrainParam()` calls
   - Verify parameter names match (e.g., `grainSize`, `grainDensity`, `pitchShift`, `posSpread`, `envShape`, `grainMode`)

#### Synchronization Checklist

Before completing any modification task, verify:
- [ ] All `engine.*` commands in Lua have matching `this.addCommand()` in SC
- [ ] All SynthDef parameters are accessible from Lua params system
- [ ] Parameter names match exactly (case-sensitive)
- [ ] Array indexing conversions are correct (Lua 1-indexed → SC 0-indexed with `-1`)
- [ ] Default values are consistent between Lua and SC
- [ ] Documentation in CLAUDE.md reflects any new commands or parameters
- [ ] README.md is updated if user-facing features changed

### CRITICAL: Always keep grid and arc integration synchronized with codebase updates

**Hardware controller integration must evolve with the codebase.** When adding features, voices, or parameters, the grid and arc interfaces should be reviewed and updated to provide access to new capabilities.

#### When adding new voices, you MUST review:

1. **Grid Integration**:
   - Update pattern sequencer to handle new voice count (currently 7 voices)
   - Adjust grid layout if voice count exceeds current row allocation
   - Update `grid_redraw_*()` functions to display new voices
   - Ensure voice toggle buttons work for all voices
   - Update pattern operations (clear, randomize) for new voices

2. **Arc Integration**:
   - Consider if new voice parameters should be accessible via arc rings
   - Add the voice type to `MAIN_PARAMS` (drives E3, the MAIN screen and arc ring 2 through `main_param_id`)
   - Update the page's arc functions (`arc_main_delta`/`arc_main_redraw`, ...) for any other voice-specific mapping
   - Ensure parameter min/max values match between arc feedback and param specs

#### When adding new parameters, you MUST review:

1. **Grid Parameter Manipulation**:
   - Grid fader page: `fader_param_ids()` lists the selected voice's `param_order` (or `BUFFER_FADER_KEYS` = buf_pos, buf_rate, buf_scan, amp for a buffer source), six grain params (`GRAIN_FADER_KEYS`; envelope shape and grain mode are option params shown as index faders) and the nine crossmod slot values; an input source lists the grain params first, then amp. New params added to `param_order` appear automatically. Pages hold 4 faders each, so a voice has `fader_page_count()` = 4-6 pages today (Folder and Sub 5, the others 6; any buffer-sourced voice 5, any input-sourced voice 4)
   - Faders are set by `set_fader_param()` and drawn by `grid_redraw_faders()`
   - Consider adding dedicated grid controls for critical new parameters
   - Update grid documentation in README.md

2. **Arc Parameter Control**:
   - Evaluate if new parameters should replace or augment arc ring mappings
   - Update `get_param_spec()` to ensure arc can scale parameter ranges correctly
   - Consider adding new arc rings if 4 rings is limiting (requires arc hardware change)

#### When adding new features, you MUST review:

1. **Grid Feature Integration**:
   - Determine if feature needs grid UI representation
   - Add grid buttons for feature controls (play/stop, mode switching, etc.)
   - Update grid LED feedback to reflect feature state
   - Ensure feature works correctly when triggered from grid
   - Test with all grid sizes (256, 128h, 128v, 64)

2. **Arc Feature Integration**:
   - Evaluate if feature adds controllable parameters
   - Consider if arc button (2025 model) should trigger feature
   - Ensure arc LED feedback reflects feature state
   - Test graceful degradation when arc is not connected

#### When changing voice count or architecture, you MUST update:

1. **Grid Layouts**:
   - `grid_key_256()`, `grid_key_128h()`, `grid_key_128v()`, `grid_key_64()` - Key handling
   - `grid_redraw_256()`, `grid_redraw_128h()`, `grid_redraw_128v()`, `grid_redraw_64()` - LED feedback
   - Pattern storage structure: `patterns[voice_idx][step]`
   - Voice selection range checks throughout grid code

2. **Arc Voice Selection**:
   - Update voice-specific parameter mapping in `arc_main_delta()` / `MAIN_PARAMS`
   - Ensure `arc_main_redraw()` handles all voice types correctly
   - Update voice selection via norns E2 to work with arc feedback

#### Hardware Integration Checklist

Before completing any feature addition or architectural change, verify:
- [ ] Grid pattern sequencer accommodates all voices
- [ ] Grid layouts (all 4 sizes) reflect current feature set
- [ ] Grid LED feedback accurately represents system state
- [ ] Grid buttons trigger all relevant features
- [ ] Arc rings provide access to most-used parameters
- [ ] Arc LED feedback displays current parameter values accurately
- [ ] Arc parameter ranges match controlspecs exactly
- [ ] All grid/arc functions handle new features gracefully
- [ ] README.md documents new grid/arc controls
- [ ] CLAUDE.md updated with grid/arc implementation patterns for new features
- [ ] Tested with and without hardware connected (graceful degradation)

## Key Implementation Patterns

### Voice State Management

Each voice has a table structure containing:
- `name` - Voice type identifier
- `active` - Boolean state
- `source` - Grain source, a `SOURCE_OPTIONS` index: 1 = synth, 2..`NUM_BUFFERS` + 1 = buffer 1-8, `NUM_BUFFERS` + 2 = input (`SOURCE_SYNTH`, `SOURCE_INPUT`)
- `param_order` - Ordered list of the `params` keys (PARAMS menu order and grid fader order; amp/pan last)
- `params` - Synthesis parameters (voice-specific); their values are also the param defaults
- `grain` - Granular processing parameters (size, density, pitch, spread, env = grain envelope option index, mode = grain mode option index, buf_pos, buf_rate, buf_scan)
- `crossmod` - `slot1`..`slot3` (`source`, `amp_amt`, `freq_amt`) and `speed`

The `voices` table is the single source of truth. Engine state mirrors this: param actions forward changes while a voice is active, and `sync_voice_to_engine` pushes everything when a voice starts.

### Parameter System

Use norns params for all adjustable values:
1. Define in `init()` with `params:add{}`
2. Include `action` function to update engine
3. Reference params with `params:get("id")` or `params:set("id", value)`
4. Group related params with `params:add_separator()`, or `params:add_group(id, name, n)` for a collapsible section (`strata_fx`). `n` must equal the number of params that follow it exactly: norns groups cannot nest, and the test stub errors on a group opened inside another

### Probability-Based Mutation System

Strata includes a mutation system that applies gentle, probabilistic changes to voice parameters over time, creating organic evolution:

#### Architecture
- **Mutation Metro**: `mutation_metro` - Timer that periodically calls `gentle_mutate()`
- **Mutation Function**: `gentle_mutate()` - Applies probability-based parameter changes
- **Global Parameters**: Controlled via PARAMS menu:
  - `mutation_enabled` (0/1) - Toggle mutation system on/off
  - `mutation_rate` (0.5-10s) - How often mutations are checked
  - `mutation_probability` (0-1) - Chance each parameter will mutate per check
  - `mutation_amount` (0-1) - Size of mutation delta relative to parameter range

#### Implementation Details

**Mutation Function** (`gentle_mutate()` in strata.lua):
```lua
function gentle_mutate()
  local probability = params:get("mutation_probability")
  local amount = params:get("mutation_amount")

  for i = 1, #voices do
    if voices[i].active and not frozen[i] then
      -- Check each synthesis parameter
      for key, current_val in pairs(v.params) do
        if key ~= "amp" and key ~= "pan" then
          if math.random() < probability then
            -- Generate gaussian-like mutation delta
            local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount * range
            local new_val = util.clamp(current_val + delta, spec.minval, spec.maxval)
            params:set("v" .. i .. "_" .. key, new_val)
          end
        end
      end

      -- Granular parameters mutate at lower probabilities
      -- grain_size: 0.5× probability
      -- grain_pitch: 0.3× probability
      -- grain_spread: 0.2× probability
    end
  end
end
```

**Key Design Decisions**:
- **Excluded Parameters**: `amp` and `pan` are never mutated to preserve voice balance and stereo placement; neither are the grain envelope shape and grain mode (`DISCRETE_GRAIN_KEYS`) nor the voice's `source`
- **Buffer and input sources**: a buffer-sourced voice mutates `BUFFER_MUTATION_KEYS` (`buf_pos`, `buf_rate`, `buf_scan`, each with `probability`, delta = gaussian × `amount` in the controlspec's normalized range, so the exp `buf_rate` moves evenly) instead of its synthesis params; an input-sourced voice mutates neither synthesis nor buffer params; grain size/pitch/spread mutate as for every voice
- **Frozen Voice Exemption**: Frozen voices are excluded from mutations
- **Gaussian Distribution**: Averaging two random values creates a bell curve distribution, favoring smaller changes
- **Relative Deltas**: Mutation amount is scaled to parameter range, ensuring consistent behavior across different specs
- **Granular Hierarchy**: Grain parameters mutate less frequently than synthesis parameters

#### Usage Patterns

**Starting Mutations**:
```lua
params:set("mutation_enabled", 1)  -- Enable via params
params:set("mutation_probability", 0.15)  -- 15% chance per parameter
params:set("mutation_amount", 0.25)  -- 25% of parameter range
params:set("mutation_rate", 2)  -- Check every 2 seconds
```

**Recommended Settings**:
- **Subtle Evolution**: probability=0.1, amount=0.15, rate=3s
- **Moderate Change**: probability=0.15, amount=0.25, rate=2s (default)
- **Dramatic Shift**: probability=0.25, amount=0.4, rate=1s

**Integration with Existing Systems**:
- **LFO System**: Mutations work alongside `lfo_update()`, which gives each active, unfrozen voice a subtle mean-reverting grain pitch drift: `delta = (math.random() - 0.5) * LFO_PITCH_STEP - (current - base) * LFO_PITCH_REVERSION` (step 0.004, reversion 0.01 per 100 ms tick). `base` (`grain_pitch_base[i]`) is the last grain pitch set by anything other than the LFO (user, mutation, scene), tracked in the param action via the `lfo_writing` flag. The `grain_pitch` controlspec has step 0 so these small steps are not quantized away. Buffer-sourced voices also drift `buf_pos` the same way (`LFO_BUF_POS_STEP` 0.002, `LFO_BUF_POS_REVERSION` 0.01, centre `buf_pos_base[i]`, `buf_pos` step 0)
- **Freeze Feature**: Frozen voices are stable - neither LFO nor mutations affect them (buffer params included; `randomize_voice` also returns for a frozen voice)
- **Cross-Modulation**: Mutations can change modulation sources/amounts, creating evolving relationships
- **UI Feedback**: `[M]` indicator appears in the header (x=98) when enabled

#### Lifecycle Management
- **Initialization**: Metro created in `init()` but not started automatically
- **Control**: `mutation_enabled` param action starts/stops the metro
- **Cleanup**: `mutation_metro:stop()` called in `cleanup()` to prevent orphaned timers

### Scene System for Longer-Form Automation

Strata includes a comprehensive scene system for creating longer-form compositions and automations. Scenes capture complete snapshots of the instrument state and can be recalled manually or sequenced automatically.

#### Architecture
- **Scene Storage**: `scenes` table - 8 scene slots (numbered 1-8)
- **Scene Data**: Complete instrument state including:
  - All voice parameters (synthesis, granular including the buffer params, cross-modulation) and each voice's source (not buffer contents)
  - Voice active states and freeze states
  - Pattern data (all 7 voices × 16 steps)
  - Global parameters (master density, tempo, filter, delay, reverb, drift, mutations)
- **Scene Sequencer**: Automatic scene progression with configurable timing
- **Transition Modes**: Instant recall or smooth crossfade between scenes

#### Core Functions

**Scene Capture** (`capture_scene()` in strata.lua):
```lua
function capture_scene(scene_num)
  -- Captures complete current state:
  -- - All voice parameters (params, grain, crossmod)
  -- - Voice active/frozen states
  -- - All pattern data
  -- - Global parameters (density, tempo, reverb, mutations, etc.)
  scenes[scene_num].data = scene_data
  scenes[scene_num].populated = true
end
```

**Scene Recall** (`recall_scene()` in strata.lua):
```lua
function recall_scene(scene_num, transition_time)
  -- Validates the slot (validate_scene) and cancels any running transition
  -- Instant recall (transition_time = 0) -> recall_scene_instant()
  -- OR smooth transition (transition_time > 0)
  --   - start values snapshotted once by scene_transition_targets()
  --   - SCENE_TRANSITION_STEPS (20) steps of util.linlin(0, 1, start, target, step / steps)
  --   - only continuous params fade; the rest switch at the end
end
```

**Scene Sequencer** (`scene_sequencer_start()` in strata.lua):
```lua
function scene_sequencer_start()
  scene_sequencer_clock = clock.run(function()
    while scene_sequencer_enabled do
      recall_scene(scene_sequencer_position, transition_time)
      clock.sleep(scene_duration)
      scene_sequencer_position = scene_sequencer_position % seq_length + 1
    end
  end)
end
```

#### Parameters

Controlled via PARAMS menu (strata_scenes section):
- `scene_sequencer_enabled` (binary) - Start/stop automatic scene progression
- `scene_transition_time` (0-30s, default 2s) - Crossfade duration for smooth transitions
- `scene_duration` (4-120s, default 16s) - How long each scene plays before advancing
- `scene_sequence_length` (1-8, default 4) - How many scenes to cycle through

#### Grid Integration

Scene controls on **Page 3** (16×16 grid):
- **Row 1**: Scene recall (instant) - Press to immediately load scene 1-8
- **Row 2**: Scene recall (with transition) - Press to crossfade into scene 1-8
- **Row 3**: Scene save - Press to capture current state to scene 1-8
- **Row 5, Column 1**: Toggle scene sequencer on/off
- **Row 5, Columns 3-10**: Set sequence length (1-8 scenes)

**LED Feedback**:
- Populated scenes: brightness 8 (row 1) or 6 (row 2)
- Current scene: brightness 15 (highlighted in row 1)
- Empty scenes: brightness 2
- Active sequencer: brightness 15, shows next scene position
- Sequence length indicators: brightness 8 for included scenes, 2 for excluded

#### UI Feedback

**Screen Display**:
- `S1` through `S8` indicator at top-right shows current scene number
- Brightness level 10 when sequencer is active, 6 when static
- Mutation indicator abbreviated to `[M]` to make room for scene indicator

#### Implementation Details

**State Capture**:
- Deep copy of all parameter values (not references)
- Preserves both the `voices` table state and norns param values
- Patterns are copied step-by-step to avoid reference issues

**Smooth Transitions**:
- `scene_transition_targets(scene_data)` snapshots `{id, start, target}` for every continuous param *once*, before the fade: voice params, grain params, crossmod amp/freq amounts, mod speed, and the continuous globals in `SCENE_GLOBAL_PARAMS` (master density, filter freq/res/mix, delay time/feedback/mix, reverb, drift)
- 20 interpolation steps regardless of transition time; step k sets `util.linlin(0, 1, start, target, k / 20)`, so the fade is linear over the whole transition time (never re-read the current value inside the loop: that makes the fade front-loaded)
- Mod sources, grain envelope shapes and grain modes (`DISCRETE_GRAIN_KEYS`), freeze and active states, tempo, filter type and mutation settings are not interpolated; they switch at the end via `recall_scene_instant()`, which also lands every param exactly on its target
- Any recall calls `cancel_scene_transition()` first, which cancels the clock and clears `scene_transition_active`

**Voice Activation Handling**:
- Checks if voice state needs to change (on→off or off→on)
- Uses existing `toggle_voice()` function to properly start/stop voices
- Preserves freeze states across scene transitions

**Pattern Preservation**:
- Patterns are restored after all parameter changes
- Ensures `grid_redraw()` is called to update grid display
- Pattern sequencer continues playing if it was active

#### Usage Patterns

**Manual Scene Performance**:
```lua
-- From grid page 3:
-- 1. Build your sound
-- 2. Press row 3 button to save to scene slot
-- 3. Modify parameters
-- 4. Save to another slot
-- 5. Press row 1 buttons to instantly switch between scenes
-- 6. Press row 2 buttons to smoothly transition between scenes
```

**Automatic Scene Sequencing**:
```lua
-- Setup:
params:set("scene_transition_time", 3)  -- 3 second crossfades
params:set("scene_duration", 20)  -- 20 seconds per scene
params:set("scene_sequence_length", 4)  -- Cycle through scenes 1-4
params:set("scene_sequencer_enabled", 1)  -- Start sequencer

-- Result: Scenes 1→2→3→4→1... with 3s crossfades, 20s each
```

**Composition Workflow**:
1. Create 4-8 distinct scenes with different voice combinations and parameters
2. Set appropriate transition time (0s for rhythmic changes, 5-10s for ambient evolution)
3. Set scene duration based on desired pacing
4. Enable sequencer for hands-free long-form composition
5. Mutations can still evolve non-frozen voices during scenes

#### Integration with Other Systems

- **Freeze Feature**: Frozen voices are captured and restored per-scene
- **Mutations**: Mutation settings are per-scene; sequencer can alternate between static and evolving scenes
- **Pattern Sequencer**: Pattern data is saved per-scene; can switch between different rhythmic patterns
- **Cross-Modulation**: Modulation routing is per-scene; enables complex evolving relationships
- **LFO System**: Continues to operate during scenes unless voices are frozen

#### Lifecycle Management
- **Initialization**: Scenes array initialized in global scope, empty by default
- **Scene Sequencer Control**: Started/stopped via param action
- **Cleanup**: `scene_sequencer_stop()` called in `cleanup()` to prevent orphaned clocks
- **Transition State**: `scene_transition_clock` / `scene_transition_active` track the running transition; `cancel_scene_transition()` clears both

#### Disk Persistence
- **Storage Location**: `~/dust/data/strata/scenes.data`
- **File Format**: Lua table serialization using norns `tab` library: `{version = SCENE_DATA_VERSION, scenes = {...}}` (version 2). Version 1 files (`{version = 1, ...}`, or the bare scenes array written before 2.1) are migrated on load and print `migrated scenes file from version 1`; the next save writes version 2. Any other version is rejected
- **Migration**: `load_scenes_from_disk()` runs `migrate_scene(scene, from_version)` on every loaded slot before `validate_scene_data()`. It fills only what is missing, so it runs for every version: each global from its `SCENE_GLOBAL_PARAMS` entry's `default` (the param default), top-level blocks from `SCENE_BLOCK_DEFAULTS` (`{key, default}`), and per-voice fields from `VOICE_SCENE_DEFAULTS` (`{path = keys inside data.voices[i], default}`; filled only when the parent table exists). Malformed scenes are left for validation to reject. When a later feature adds a scene field, add its default to one of these tables (both extension tables are empty in format 2.0)
- **Robust Loading**: `tab.load` runs the file as Lua unprotected, so `load_scenes_from_disk()` calls it through `pcall`. On any failure (error, unknown version, invalid data after migration) it prints a message, keeps the current scenes (empty at startup) and preserves the file: it is renamed to `scenes.data.bak` so the save in `cleanup()` cannot destroy it, and if the rename fails `scene_autosave_blocked` makes `cleanup()` skip the auto-save. Missing slots in a valid file are filled with empty scenes
- **Auto-save**: Scenes automatically saved to disk in `cleanup()` when script exits
- **Auto-load**: Scenes automatically loaded from disk in `init()` on script startup
- **Manual Controls**: PARAMS menu includes "save scenes to disk" and "load scenes from disk" trigger actions
- **What's Saved**: Complete scenes table including all 8 scene slots, populated state, and scene data
- **Persistence**: Scenes persist across norns reboots, allowing you to build a library of sonic palettes

#### Scene Data Validation (v2.0+)

**IMPORTANT**: Always validate scene data before using it to prevent crashes from corrupted files.

`validate_scene(scene)` checks one slot and `validate_scene_data(scene_table)` checks every present slot of a loaded table (missing slots are allowed and filled on load). A populated scene must contain everything `recall_scene_instant()` reads:
```lua
-- every SCENE_GLOBAL_PARAMS id is a number (master_density, tempo, mutation_*, filter_*, delay_*, reverb_*, drift_amount)
-- data.voices: NUM_VOICES tables, each with
--   active (boolean), source (integer 1..#SOURCE_OPTIONS), params (only known keys, numbers),
--   grain (only GRAIN_PARAM_IDS keys, numbers; env/mode integers 1..option count),
--   crossmod.slot1..3 {source = integer 0..NUM_VOICES, amp_amt, freq_amt numbers}, crossmod.speed number
-- data.frozen: NUM_VOICES booleans
-- data.patterns: NUM_VOICES x PATTERN_LENGTH integers 0..15
```
When adding a field to `capture_scene()`, add it to `validate_scene()` (and to `SCENE_GLOBAL_PARAMS`, with its `default`, for a global param), or recall will not restore it, and give it a migration default (`SCENE_GLOBAL_PARAMS.default`, `VOICE_SCENE_DEFAULTS` or `SCENE_BLOCK_DEFAULTS`) so older files still load.

**When to validate**:
- Always before loading scenes from disk (`load_scenes_from_disk`)
- Before recalling scenes (`recall_scene` calls `validate_scene`)
- After receiving scene data from external sources

**Error handling patterns**:
```lua
-- Graceful degradation with console messages
if not scene_data or not scene_data.voices then
  print("error: scene " .. scene_num .. " has invalid data")
  return
end

-- Nil-safe iteration
if scene_data.voices[i] and scene_data.voices[i].params then
  for key, target_val in pairs(scene_data.voices[i].params) do
    -- Safe to access
  end
end
```

### Bounds Checking and Safety (v2.0+)

**CRITICAL**: Always validate array indices before accessing to prevent expansion or crashes.

**Pattern bounds checking**:
```lua
function toggle_pattern_step(voice_idx, step)
  -- Bounds checking to prevent array expansion
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  if step < 1 or step > PATTERN_LENGTH then return end

  -- Safe to access
  patterns[voice_idx][step] = ...
end
```

**Scene bounds checking**:
```lua
function recall_scene(scene_num, transition_time)
  if scene_num < 1 or scene_num > NUM_SCENES then return end
  if not scenes[scene_num].populated then
    print("scene " .. scene_num .. " is empty")
    return
  end
  -- Safe to proceed
end
```

**Apply bounds checking to**:
- All voice index access (1 to NUM_VOICES)
- All scene index access (1 to NUM_SCENES)
- All pattern step access (1 to PATTERN_LENGTH)
- Grid button coordinates
- Parameter ranges

### Resource Management and Cleanup (v2.0+)

**IMPORTANT**: Always clean up metros, clocks, and other resources to prevent leaks.

The `cleanup()` function demonstrates proper cleanup:
```lua
function cleanup()
  -- Save state before cleanup
  save_scenes_to_disk()

  -- Stop metros with nil checks
  if lfo_metro then lfo_metro:stop() end

  -- Sync parameter state with actual state
  if mutation_metro then
    mutation_metro:stop()
    params:set("mutation_enabled", 0)  -- Keep param in sync
  end

  -- Stop pattern and scene clocks (scene sequencer via its param, like mutations)
  pattern_clock_stop()
  params:set("scene_sequencer_enabled", 0)
  scene_sequencer_stop()

  -- Cancel transition clocks to prevent orphaned coroutines
  cancel_scene_transition()

  -- Turn off all voices
  for i = 1, NUM_VOICES do
    if voices[i].active then
      engine.voiceOff(i - 1)
    end
  end

  -- Leave connected grids and arc dark
  for _, grid_port in pairs(grids) do grid_port:all(0); grid_port:refresh() end
  if arc_device then arc_device:all(0); arc_device:refresh() end
end
```

**Clock management patterns**:
```lua
-- Before starting a clock, cancel existing one
if scene_transition_clock then
  clock.cancel(scene_transition_clock)
  scene_transition_clock = nil
end

-- Then start new clock
scene_transition_clock = clock.run(function()
  -- Clock body
end)
```

**Prevents**:
- Orphaned clock coroutines
- Concurrent clocks causing parameter oscillation
- Memory leaks from uncancelled metros
- State inconsistencies between params and actual state

### Async Initialization

Voice activation uses `clock.run()` for delayed starts:
```lua
clock.run(function()
  toggle_voice(1)
  clock.sleep(0.5)
  toggle_voice(2)
end)
```

### Grid Integration (Optional)

Strata supports monome grid controllers for pattern sequencing and parameter manipulation. The implementation handles multiple grid sizes and multiple simultaneous grids.

#### Device Lifecycle
- `grid_init()` - Connect to up to 4 grid ports at startup
- `grid.add(device)` - Global callback when grid connects (hot-plug support)
- `grid.remove(device)` - Global callback when grid disconnects; clears the vport's `key` handler and the `grids` slot
- `grids` table - Stores the **vport** (`grid.connect(port)`) of each connected grid, indexed by port (1-4). Both `grid_init` and `grid.add` go through `attach_grid(port)`
- Never store the raw device passed to `grid.add`, and never set `key` on it: devices have no `.device` field (so `grid_redraw` would skip them) and norns fires both `device.key` and `vports[port].key`, so handlers on both run every press twice. The arc uses the same vport-only pattern (`attach_arc`)

#### Grid Size Detection & Adaptive Layouts
`grid_layout(grid_port)` matches the exact `cols`/`rows` (16x16 is tested as `cols == 16 and rows == 16`; a `rows >= 16` test would also catch 8x16) and routes to the appropriate layout:
- **16×16 (256 buttons)**: `grid_key_256()` and `grid_redraw_256()` - Full-featured layout
- **16×8 (128 horizontal)**: `grid_key_128h()` and `grid_redraw_128h()` - Horizontal layout
- **8×16 (128 vertical)**: `grid_key_128v()` and `grid_redraw_128v()` - Vertical layout
- **8×8 (64 buttons)**: `grid_key_64()` and `grid_redraw_64()` - Compact layout

#### Pattern Sequencer Implementation
- **Pattern Storage**: `patterns[voice_idx][step]` - NUM_VOICES × PATTERN_LENGTH steps, values 0-15 (the 64 grid shows and edits only steps 1-8, but patterns still play all 16)
- **Playback Clock**: `pattern_clock` - Uses `clock.run()` and `clock.sync(1/4)` for tempo-synced 16th notes against norns' global clock. The script's `tempo` param (40-300, initialised from `clock_tempo`) sets `clock_tempo` in its action; grid tempo buttons adjust `tempo`. External clock sources still work because the sequencer only syncs
- **Position Tracking**: `pattern_position` - Current step (1-16), wraps around. Each tick triggers the step, redraws the grid (so the highlight shows the step that just played), then advances
- **Triggering**: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)` (accent in place at the step's level as velocity, one grain in triggered grain mode, no new nodes); a stopped voice is started with `toggle_voice`. Never retrigger by toggling a voice off and on
- **Pattern Operations**:
  - `toggle_pattern_step(voice, step)` - Toggle step on/off
  - `clear_pattern(voice)` - Reset all steps to 0
  - `randomize_pattern(voice)` - Generate random pattern with 50% density

#### Multi-Grid Synchronization
- All grids display the same interface simultaneously
- `grid_redraw()` iterates over `grids` table and updates each grid
- Shared state (patterns, voice status, pages) ensures consistency
- Each grid can trigger the same functions independently

#### LED Feedback Patterns
- **Active steps**: Brightness 15 (full)
- **Current playback position**: 15 if the step is active, 4 if empty (`step_brightness()`)
- **Voice active status**: Brightness 12
- **Voice inactive status**: Brightness 2-4
- **Page indicators**: 15 for selected, 2 for unselected
- **256 parameter page faders (rows 9-12) and FX faders (page 4, rows 3-7)**: bar at 8 up to the value, the value's column at 15; row 13 (page 2): fader pages, selected 15, available 4
- **256 page 4 buffers**: row 1 15 recording / 8 loaded / 2 empty, row 2 at 4; source rows 9-15 selected 15, others 4, empty buffers 2
- Always call `grid_port:refresh()` after updating LEDs
- Any state shown on the grid must call `grid_redraw()` when it changes, wherever it changes (`toggle_voice`, `toggle_freeze`, `randomize_voice`, scene recall, ...). `grid_redraw()` returns immediately when no grid is connected, so calling it is cheap

#### Key Implementation Details
- Grid key handler checks `z == 0` to ignore key releases (only respond to presses; only the norns keys have release handling, see Screen pages)
- Use `grid_port:all(0)` to clear all LEDs before redrawing
- Pattern clock uses `clock.sync()` for tempo-accurate timing
- Voices auto-activate when pattern step triggers them
- Stop pattern clock in `cleanup()` to prevent orphaned clock coroutines
- Grid pages allow switching between pattern sequencing and parameter control
- **Parameter page (256, page 2)**: `fader_param_ids(voice)` = the voice's `param_order` (synthesis params, amp/pan last; `BUFFER_FADER_KEYS` buf_pos/buf_rate/buf_scan/amp instead for a buffer source; for the input source no first keys, the grain params then `amp`; the source action clamps `param_page` to the new count), grain size/density/pitch/spread/envelope/mode, then source/amp mod/freq mod for crossmod slots 1-3. Fader page N (row 13, column N) shows entries `(N-1)*4+1 .. N*4` on rows 9-12; pressing column x calls `set_fader_param()`, which looks up the id and calls `set_param_from_column(param_id, x)`: `spec:map((x - 1) / 15)` for control params, so faders follow each controlspec's warp (exp for freq, cutoff, mod speed), and `round(util.linlin(1, 16, min, max, x))` for number params (mod sources) and option params (grain envelope and mode, `param_range` gives `1, count`; it tests `param.options` because norns' `param.t` is a number); `fader_position()` is the inverse (`param_fraction(id) * 15 + 1`, where `param_fraction` is `spec:unmap(value)` or the linear fraction of a number or option param's range). Each fader row is drawn by `grid_redraw_fader_row(grid_device, y, param_id)`. All through `params:set`. Voices have 4-6 fader pages
- **Buffers / FX page (256, page 4)**: `grid_key_256` has an explicit `grid_page == 4` branch so page 4 never falls through to the pattern page.
  - Row 1 (`GRID_BUFFER_RECORD_ROW`), columns 1-`NUM_BUFFERS`: `record_buffer(x)` (a second press stops early). Row 2 (`GRID_BUFFER_CLEAR_ROW`): `clear_buffer(x)`. `grid_redraw_256_buffers`: row 1 at 15 recording, 8 loaded, 2 empty; row 2 at 4
  - Rows 3-7: `GRID_FX_FADER_IDS = {"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"}` are faders (`set_param_from_column`/`grid_redraw_fader_row`). The filter/delay param actions call `fx_fader_changed()`, which redraws the grid while page 4 is shown, so the faders follow the screen, arc and scene recalls
  - Rows 9-15 (`GRID_SOURCE_FIRST_ROW` + voice - 1): column x (1..`#SOURCE_OPTIONS`) is `params:set("v<voice>_source", x)` (1 synth, 2-9 buffer 1-8, 10 input); columns 11-16 do nothing. `grid_redraw_256_sources`: the selected source 15, other sources 4, empty buffers (not loaded, not recording) 2. The source param action calls `grid_redraw()`; buffer changes call it through `buffer_display_changed()`
  - Rows 8 and 16 work and draw as on page 1 (`grid_key_256_transport`/`grid_redraw_256_transport`, `grid_key_256_freeze`/`grid_redraw_256_freeze`)
  - Smaller grids have no buffers / FX page (buffers and sources are on the BUFFER screen page and in params)

### Arc Integration (Optional)

Strata supports the monome arc controller for tactile parameter control. The implementation follows these patterns:

#### Device Lifecycle
- `arc_init()` - Connect to the arc vport (`arc_device = arc.connect(1)`) and set up callbacks via `attach_arc()`
- `arc.add(device)` - Global callback when arc connects; re-attaches the vport for `device.port` (handlers live on the vport only, as for grids)
- `arc.remove(device)` - Global callback when arc disconnects
- Graceful degradation: `arc_redraw()` returns unless `arc_device` has a connected device

#### Arc Pages
The arc follows the screen page (`ui_page`). `ARC_PAGE_DELTA` and `ARC_PAGE_REDRAW` are indexed like `UI_PAGES`: `arc_delta` calls `ARC_PAGE_DELTA[ui_page](ring, delta)`, and `arc_redraw` clears the rings, calls `ARC_PAGE_REDRAW[ui_page](arc_device)` and refreshes. MAIN uses `arc_main_delta`/`arc_main_redraw`, FX `arc_fx_delta`/`arc_fx_redraw`, BUFFER `arc_buffer_delta`/`arc_buffer_redraw`; SETUP has no rings (`arc_ignore_delta`/`arc_draw_nothing`), and LFO uses the same no-ops until its feature adds ring mappings. `enc(1, ...)` calls `arc_redraw()`, so changing page redraws the rings.

#### Input Handling
- `arc_delta(n, delta)` - Handle encoder rotation for rings 1-4 through the page's handler. MAIN:
  - Ring 1: Master density
  - Ring 2: Selected voice's main parameter (`main_param_id`, delta scaled by `main_param_entry(...).arc_scale`; `buf_pos` for a buffer-sourced voice, `grain_size` for an input-sourced one)
  - Ring 3: Grain size for selected voice
  - Ring 4: Grain density for selected voice
- FX (`ARC_FX_RINGS`, `{param_id, scale}` per ring): ring 1 `filter_freq` (delta/4), ring 2 `filter_res` (delta/100), ring 3 `delay_time` (delta/200), ring 4 `delay_mix` (delta/100). Each ring is drawn at level 12 to `param_fraction(param_id)` of a turn, so the exp params (filter freq, delay time) follow their controlspec warp
- BUFFER (`ARC_BUFFER_RINGS`, `{voice_key | param_id, scale}` per ring): ring 1 `v<selected>_buf_pos` (delta/200), ring 2 `v<selected>_buf_rate` (delta/100), ring 3 `record_duration` (delta/20), ring 4 `record_level` (delta/100), each drawn to `param_fraction` of a turn. Rings 1-2 adjust the voice's buffer params whatever its source (they apply once it switches to a buffer) and are drawn at 15 for a buffer-sourced voice, 4 otherwise; rings 3-4 at 12
- `arc_key(n, s)` - Handle button press (2025 arc models)
  - On MAIN mirrors K3 (`start_or_freeze_selected_voice`); does nothing on other pages

#### LED Feedback
- `arc_redraw()` - Update all ring LEDs to reflect current parameter values (the current page's rings)
- Called after parameter changes (from encoders or arc)
- Uses `util.linlin()` to map parameter ranges to 0-64 LED positions
- Brightness levels indicate voice state:
  - 15 = active voice primary parameter
  - 12 = active voice secondary parameters
  - 4 = inactive voice primary parameter
  - 3 = inactive voice secondary parameters
- Uses `arc_device:segment(ring, from, to, level)` for smooth arc visualizations

#### Key Implementation Details
- Arc encoders use scaled deltas (e.g., `delta / 20`, `delta / 100`) for fine control
- Parameters ranges must match between arc feedback and param specs
- Arc redraw is triggered alongside screen redraw for consistency
- All arc functions are non-blocking and safe to call even without arc connected

### UI Updates

#### Screen pages

The screen has `NUM_UI_PAGES` (5) pages, named in `UI_PAGES = {"MAIN", "FX", "LFO", "BUFFER", "SETUP"}`; `ui_page` is the index of the shown page.
- `enc(1, d)` selects the page (`ui_page = util.clamp(ui_page + d, 1, NUM_UI_PAGES)`); E1 does nothing else. `init` turns E1's acceleration off and sets its sensitivity to `E1_TICKS_PER_PAGE` (4) with `norns.enc.accel(1, false)` / `norns.enc.sens(1, ...)`, so a fast turn steps pages instead of skipping to SETUP (norns resets these on every script load, so cleanup restores nothing). `enc(2|3, d)` calls `PAGE_ENC[ui_page](n, d)` and `key(n, 1)` calls `PAGE_KEY[ui_page](n)`
- **Key releases**: `key(n, 1)` records `key_press_page[n] = ui_page`; `key(n, 0)` clears it and calls `PAGE_KEY_RELEASE[ui_page](n)` only if the key went down on the page still shown, so a key held across a page change does nothing when released. Every page but BUFFER has `ignore_page_input` there, so presses keep their meaning and releases do nothing. "K2 is held on this page" is `key_press_page[2] == ui_page`. The norns menu (K1, PARAMS, its file selector) takes every key while open (`_menu.key` is the menu's handler), so a key released there never reaches `key()`; `forget_keys_held_through_menu()`, called at the end of `lfo_update` (the 10 Hz `lfo_metro` tick), clears `key_press_page` and `buffer_saved_during_k2` whenever `norns.menu.status()` is true. Without it a K2 released in the menu would stay held and every BUFFER K3 would save instead of record. (norns has no key-state query; a menu visit shorter than one 100 ms tick is the only gap)
- `redraw()` is `screen.clear(); draw_header(); PAGE_DRAW[ui_page](); screen.update()`. Each page's draw function ends with `draw_hints(text)` (level 4, x=0, y=62)
- `PAGE_DRAW`, `PAGE_ENC`, `PAGE_KEY` and `PAGE_KEY_RELEASE` are indexed like `UI_PAGES`. LFO is a placeholder (`redraw_placeholder` draws an empty hint row, `ignore_page_input` ignores encoders/keys) until its feature replaces it; to fill a page, write its draw/enc/key functions and put them in the tables (and the arc tables below)
- The tables are script locals built after the functions they hold, so page functions must be defined above them
- **MAIN** (`redraw_main`, `main_enc`, `main_key`): the original screen - E2 voice select, E3 main parameter, K2 randomize, K3 start/stop/freeze (`start_or_freeze_selected_voice`)
- **FX** (`redraw_fx`, `fx_enc`, `fx_key`): a scrolling list of `FX_ROWS` (`{label, param_id, format}`; `format` is a `string.format` pattern, or nil for the param's own string): density, tape drift, filter type/freq/res/mix, delay time/fdbk/mix, reverb mix/size/damp. `FX_VISIBLE_ROWS` (5) rows at y=18-50, label at x=0 and value right-aligned at x=127, the selected row (`fx_row`) at level 15 and the others at 4; the view keeps one row above the selection. E2 selects the row, E3 is `params:delta` on its param. K3 toggles `filter_mix` between 0 and `fx_filter_last_mix`, which the `filter_mix` param action records whenever the mix is set above 0 (from E3, PARAMS, scenes or K3; initially 1). Hint: `K3:filter bypass` when the mix is above 0, else `K3:filter on`
- **BUFFER** (`redraw_buffer`, `buffer_enc`, `buffer_key`, `buffer_key_release`): left column (x 0-60) the selected voice's name (y 18), `src: <voice_source_label>` (y 26), `dur:` record duration (y 42) and `lvl:` record level (y 50); divider at x 62; right column eight rows (`BUFFER_ROW_FIRST_Y` 14, `BUFFER_ROW_SPACING` 6, so y 14-56): slot number at x 65, name at x 71 (file name without extension, cut by `fit_text` with `screen.text_extents` to `BUFFER_NAME_MAX_WIDTH` 31 px, whole UTF-8 characters at a time), seconds (`%.1fs`) or `REC` right-aligned at x 127. Row level: the selected voice's buffer (`voice_buffer_slot`) 15, loaded or recording 8, empty 2. E2 is `select_voice_by` (shared with MAIN), E3 `params:delta("v<i>_source", d)`. K3 press: `record_buffer(slot)` (toggles: stops early while recording), or `save_buffer(slot)` when K2 is held on this page (`buffer_saved_during_k2` then makes the K2 release do nothing). K2 release: `fileselect.enter(_path.audio, cb)`, where `cb` sets `buf<slot>_file` unless the path is `"cancel"`, then redraws. With no buffer source (synth, input) K2 and K3 do nothing. Hints: `K2:load K3:rec K2+3:save` (`K3:stop` while the slot records), or `K2:- K3:- E3:source`
- **SETUP** (`redraw_setup`, `setup_key`): grid count and sizes (in port order), arc connected/none, `scenes: k/8 saved`, a `midi:` line for MIDI input; K3 calls `save_scenes_to_disk()`. `grid.add`/`grid.remove`/`arc.add`/`arc.remove` call `redraw()` so SETUP stays current
- Master density left E1. It is on the FX page's first row, MAIN's arc ring 1, in params, and in the header on every page

#### Main parameter

`main_param_id(voice_idx)` returns the param E3 and arc ring 2 adjust on MAIN (`v<i>_freq` resonator, `_index` fm, `_fold` folder, `_drift` sub, `_width` pulse, `_decay` karplus, `_ratio` ring) and `main_param_label(voice_idx)` its screen label. Both read `main_param_entry(voice_idx)`: the `MAIN_PARAMS` entry for the voice type (param id suffix, screen label, value format, arc delta scale), `BUFFER_MAIN_PARAM` (`buf_pos`, label `pos`, `%.2f`) for a buffer source (spec §1), or `INPUT_MAIN_PARAM` (`grain_size`, label `size`, `%.2f s`) for the input source (its synth and buffer params do nothing). Use them instead of `if v.name ==` chains; arc ring 2 is drawn across `param_range(main_param_id(...))`

#### MAIN layout

The `update_voice_list()` function recreates the `UI.ScrollingList` on every change. The list shows:
- Active status (● for on, ○ for off)
- Voice name
- Freeze status ([F] suffix)

MAIN uses a two-column layout:
- **Header (y=8, `draw_header()`, identical on every page)**: page title at x=0 (04B_03 capitals advance ~6 px, so the longest title `BUFFER` ends near x=36), `dens:1.00` at x=40, `[M]` at x=98, scene indicator `S1`-`S8` right-aligned at x=127
- **Left column (0-60px)**: Scrolling voice list (4 visible at a time, rows y=15-48)
- **Right column (65-128px)**: Selected voice details (name, status, main parameter at y=42/50); `[FREEZE]` is right-aligned at x=127 on the status row (y=26), `[TRIG]` (triggered grain mode) right-aligned at x=127 on the main-parameter label row (y=42)
- **Divider (x=62)**: Subtle vertical line separating columns
- **Hint row (y=62)**: `K2:rand K3:freeze|start`
- `test/run.lua` checks, on every page and for every selected voice, that no two strings on a row overlap and that nothing leaves 128×64 (estimating 6 px per capital, 4 per bracket/colon/period, 5 otherwise), that `dens:` starts at least 4 px after the page title, that a hint row is drawn at y=62, and that the voice list's last row ends above the hint row; keep it passing when adding text. The width estimate is `stubs.text_width` in `test/norns_stubs.lua`, which the screen stub also uses for `screen.text_extents` (returns width, 8); the stub records each string's `x`, `y`, `align` and `level`
- Parameter faders on grid page 2 are redrawn after `gentle_mutate`, after every scene-transition step, and from `lfo_update` only when a grid shows page 2 (it runs 10x/s)

When adding UI elements, update the page's draw function (`redraw_main`, `redraw_setup`, ...), never `redraw()` itself.

## SuperCollider Architecture

### SynthDef Organization

Each voice type has its own SynthDef with unique parameters:
- `\strataResonator` - DynKlank resonator bank with filtered noise
- `\strataFM` - Two-operator FM with slow modulation
- `\strataFolder` - Wavefolder with sine input
- `\strataSub` - Ultra-low sine with drift
- `\strataPulse` - Pulse width modulation with resonant filtering
- `\strataKarplus` - Karplus-Strong plucked string physical model
- `\strataRing` - Ring modulation between two oscillators

All voice SynthDefs take `t_trig` and `velocity` controls driving an accent envelope (see Retrigger above), and include multi-source cross-modulation inputs (3 slots):
- `modBus1`, `modBus2`, `modBus3` - Control buses to read modulation signals from (one per slot)
- `modAmpAmt1`, `modAmpAmt2`, `modAmpAmt3` - Amplitude modulation depths (-2 to 2)
- `modFreqAmt1`, `modFreqAmt2`, `modFreqAmt3` - Frequency modulation depths (-2 to 2)
- The 3 modulation signals are mixed together (weighted sum) before application

**Modulation Signal Clamping (v2.0+, frequency floor in v2.1)**:
To prevent excessive amplitude spikes when multiple modulation sources are active, every voice SynthDef (including FM and Sub) clamps:
```supercollider
// Mix modulation signals with clamping to prevent excessive modulation
modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
modFreq = freq * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);
```
This prevents the theoretical 4× amplitude spike that could occur with 3 sources all at maximum positive modulation. The frequency modulator is clamped to -0.9 (not -2) so the modulated frequency never reaches zero or goes negative (Karplus uses `modFreq.reciprocal` as a delay time, Resonator uses it as a filter cutoff).

Shared processing SynthDefs:
- `\strataMod` - Envelope follower + LFO for generating modulation signals
- `\strataGrain` - Granular processor for a stereo bus (one per synth- or input-sourced voice); `GrainIn` (envelope `envBuf`, default -1 = built-in Hann; trigger chosen by `grainMode`: `Impulse.ar(grainDensity)` or `T2A.ar(t_trig)`) followed by `PitchShift` for `pitchShift`. Input-source extras: `accentAmt` (grain-side accent), `mirrorOut`/`mirrorLevel` (copy to the voice bus); `bend` is unused here
- `\strataGrainBuf` - Granular processor for a buffer slot (one per buffer-sourced voice); see Audio Sources
- `\strataInput` - Persistent live input: `SoundIn.ar([0, 1])` to `inputBus`
- `\strataRecord` - One recording into a slot's buffer pair; reports its frame count on `framesOut`; frees itself when done (or is freed by `stopRecord`)
- `\strataFilter` - Master multimode filter (`in, out, freq=5000, res=0.5, filterType=0, mix=0`): `Select.ar` of `RLPF`/`RHPF`/`BPF` at rq `1 - res * 0.95`, `mix` crossfades dry to filtered (0 = bypass)
- `\strataDelay` - Master stereo delay (`in, out, time=0.375, feedback=0.4, mix=0`): `DelayC` (max 2 s, `time.lag(0.1)`) fed by the input plus `LocalIn`, with the delayed signal times `feedback` sent back through `LocalOut`; `mix` crossfades dry to delayed
- The filter and delay SynthDef defaults equal the Lua param defaults: the script never bangs its params, so the engine starts from these values
- `\strataReverb` - Global reverb processor; outputs `FreeVerb2` only (it already crossfades dry/wet by `mix`)
- `\strataMaster` - Master output with drift, then `Limiter.ar(sig, 0.95)` to catch filter resonance and delay feedback peaks, then the tanh saturation. The limiter must stay before the saturator: `(sig * 2).tanh * 0.5` bounds its output to ±0.5, so a limiter after it could never act (the engine check asserts the order). Drift (master and Sub) is an LFO at a fixed slow rate scaled by the drift amount: tape drift 0 = none; the Sub drift param's minimum stays 0.001

### Audio Bus Management

Buses are allocated in `alloc` (`numVoices = 7` in the engine must match `NUM_VOICES` in Lua; use it for every per-voice `Array.fill`):
- `numVoices` stereo `granBuses` (one per voice, for audio)
- `numVoices` mono `modBuses` (one per voice, for control signals)
- 1 mono `silentBus` (always 0; "no modulation source")
- 1 stereo `mainBus` (granular outputs mix here; filter input)
- 1 stereo `filterBus` (filter output, delay input)
- 1 stereo `delayBus` (delay output, reverb input)
- 1 stereo `reverbBus` (reverb output, master input)
- 4 `envBuffers` (grain envelope shapes, 1024 frames each; see `envShape`)
- 1 stereo `inputBus` (live input from `\strataInput`)
- `numBuffers` mono control `recordFrameBuses` (frames recorded so far, for `stopRecord`)
- `numBuffers` (8) slot pairs `buffersL`/`buffersR`, mono, 16 s each (≈ 49 MB total; see Audio Sources)

Buses, buffers, the input synth and groups are freed in `free` to prevent resource leaks (recordings in progress are cancelled first so nothing is written on free).

### Node Ordering

Everything runs inside the engine group `context.xg`, so norns' output group (`og`) and its meters come after the engine:
```
context.xg: voiceGroup (strataInput, voice synths, strataRecord) -> processGroup (grain synths, then mod synths) -> strataFilter -> strataDelay -> strataReverb -> strataMaster
```
`voiceGroup = Group.head(context.xg)`, `processGroup = Group.after(voiceGroup)`, and filter, delay, reverb and master are added in that order with `\addToTail` on `context.xg`. `inputSynth` is added at the head of `voiceGroup` and record synths right after it; grain synths go to the head of `processGroup` (or next to the grain synth they replace) and mod synths to its tail, so every grain synth runs before every mod synth.

### Synth Lifecycle

Synths use `gate` with ASR envelopes:
- Starting: `Synth.new(...)` with `gate=1`. `voiceOn` on a voice that is already running first releases its old trio (`releaseVoice`)
- Stopping: `releaseVoice` sets `\gate, 0` (release phase) and removes the trio from `synths` (a buffer- or input-sourced voice has only a grain and a mod synth)
- Switching source: `replaceGrainSynth` (see Audio Sources)
- `doneAction: 2` frees the synth after release
- Per-voice commands go through `setSynth(key, ...)`, which ignores voices that are not running, and voice indices are range-checked with `validVoice`

## Version History

### Version 2.1 (2026-11-03)

Whole-app review fix release. Highlights:
- `voiceOn` signature `"iffffff"` (freq was typed as a string and dropped); voices start with their full Lua state (`sync_voice_to_engine`)
- Pattern steps accent running voices with the new `retrigger` command instead of stacking synth chains
- Grain pitch is real pitch shifting; its LFO drift is subtle and mean-reverting
- Tempo param drives `clock_tempo`; 128v layout reachable; grid hot-plug fixed; 256 parameter page implemented as faders; grid LEDs stay current
- Silent bus for unrouted mod slots; frequency modulation clamped above zero; FM/Sub clamped
- Linear scene transitions; thorough scene validation; versioned, crash-safe scene file loading
- Engine nodes ordered inside `context.xg`; resonator and reverb no longer double their output; drift amounts mean depth
- Off-device test harness (`test/`)

See [CHANGELOG.md](CHANGELOG.md) for complete details.

### Version 2.0 (2025-01-24)

Major stability and code quality release focusing on bug fixes and defensive programming:

**Critical Bug Fixes**:
- Scene data validation prevents crashes from corrupted files
- Scene sequencer position bounds checking prevents out-of-bounds access
- Concurrent scene transition prevention via clock tracking and cancellation

**High Priority Bug Fixes**:
- Arc initialization race condition fixed
- Mutation metro state synchronization in cleanup
- 64-button grid pattern display corrected
- Pattern/scene bounds checking added throughout
- Scene transition nil access protection

**Code Quality Improvements**:
- Named constants (NUM_VOICES, NUM_SCENES, PATTERN_LENGTH) replace magic numbers
- Comprehensive error handling and validation patterns
- Resource management with proper cleanup
- Modulation signal clamping in SuperCollider engine

See [CHANGELOG.md](CHANGELOG.md) for complete details.

### Version 1.0

Initial release with:
- 7 synthesis voices with granular processing
- Cross-modulation (3 slots per voice)
- Probability-based mutations
- Scene system with disk persistence
- Grid and arc integration
- Pattern sequencer

## Future Extension Points

Potential expansion areas:
- ~~Cross-modulation between voices~~ ✓ Implemented (v1.0)
- ~~Additional voice types (Pulse, Karplus, Ring)~~ ✓ Implemented (v1.0)
- ~~Probability-based parameter mutations~~ ✓ Implemented (v1.0)
- ~~Monome grid integration~~ ✓ Implemented (v1.0)
- ~~Longer-form automation/sequencing~~ ✓ Implemented (v1.0 - scene system)
- ~~Multi-source modulation routing~~ ✓ Implemented (v1.0 - 3 slots per voice)
- ~~Scene disk persistence~~ ✓ Implemented (v1.0 - auto-save/load + manual triggers)
- ~~Scene data validation~~ ✓ Implemented (v2.0)
- ~~Bounds checking and safety~~ ✓ Implemented (v2.0)
- ~~Modulation signal clamping~~ ✓ Implemented (v2.0)
- More voice types (wavetable, additive, granular noise, etc.)
- Modulation matrix visualization on grid or arc
- Per-scene naming/tagging system
- MIDI integration for external control
- Undo/redo for parameter changes
- Parameter automation recording
