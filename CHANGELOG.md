# Strata Changelog

## Version 3.0.1 - 2026-11-03

Fixes the minor findings deferred from the 3.0 reviews. No engine command, param or file format changes: scenes and `buffers.data` from 3.0 load unchanged.

### Fixes

- **Arc ring speeds.** Every ring that sets a value (MAIN 1-4, FX 1-4, BUFFER 1-4 and the LFO page's ring 4 in free mode) sweeps its parameter's whole range in 512 ticks, half a turn of the arc's 1024 ticks per revolution, following the parameter's curve (256 ticks take resonator freq from 20 Hz to 200 Hz). In 3.0 each ring had its own scale: filter freq swept in under half a turn while res and mix took about ten turns and buffer position about twenty. The LFO depth rings (10 ticks per percent) and the clocked rate (20 ticks per rate) still step whole values.
- **MAIN arc ring 2 follows the curve.** The main parameter's ring is drawn along the parameter's curve, like the FX and BUFFER rings: resonator freq at 200 Hz lights half the ring instead of about a tenth.
- **LFO ring 4 forgets its part-turn.** Ticks carried toward the next clocked rate are dropped when another LFO is selected or the selected LFO's mode changes, so they never step a different LFO or mode.
- **BUFFER save confirmation.** K2 + K3 shows `saved buf <n>` in the hint row for 1.5 s, `buf <n> busy` while the buffer records or waits for its take, or `buf <n> empty` when the buffer holds no audio; nothing is saved in the last two cases.
- **Keys held into the norns menu.** Opening the menu (K1, a script error, a keyboard's menu key) forgets held keys at once instead of on the next 100 ms check, so even a quick menu visit with K2 held no longer turns the next BUFFER K3 into a save. Strata wraps norns' `_menu.set_mode` and gives it back on exit; the 10 Hz check stays as a fallback. The BUFFER page's file selector (K2) forgets held keys the same way as it opens.
- **Omni pitchbend follows the selection.** In omni mode, selecting another voice with the wheel off centre returns the old voice to pitch and bends the new one.
- **Takes and loads are confirmed by the engine.** A take shows `REC` (hint `K3:...`, K3 does nothing) until the engine reports what it captured, then becomes `take <n>`, or `empty` when nothing was captured (a stop right after the start). A loaded file the engine reports no audio for (an unreadable file) drops to dim. A take or load the engine reports late, such as a slow read during the restore at start, is still picked up unless the buffer was cleared, loaded or recorded into meanwhile, and a take settles from its last known length after 5 s if no report ever comes. In 3.0 a take was named and counted as loaded the moment its timer ended, whatever the engine had captured.
- **Restored buffers are counted when the engine has them.** SETUP's `buffers: k restored` counts a buffer once the engine reports audio in it, and reads `buffers: k ok, m missing` when remembered files were not found.
- **Missing buffer files are remembered.** A file that is not found at start (deleted, moved or on a drive that is not mounted) is skipped but kept in `buffers.data`, so it comes back once the file is there again; clearing, loading or recording into that buffer forgets it.
- **Scene recall syncs a switched voice once, after its params.** A running voice whose source a scene changes used to get its full sync from the source change, before the recalled params, so the new grain synth briefly played the old values. It now gets one sync after every recalled param, for instant recalls and smooth transitions alike. An error during a recall is still raised, but first every running voice whose source it had already switched gets its sync (of what was applied), and later source changes are no longer left without theirs.
- **Voice start under an LFO.** `voiceOn` sends the grain density the engine has (including any LFO offset on the voice's density or master density) instead of the stored values, so a voice started under such an LFO does not jump.
- **Grid page 4 during scene transitions.** The FX faders redraw once per transition step instead of once per changed param.
- **Filter type crossfades.** Changing the filter type crossfades over 20 ms instead of jumping between the lowpass, highpass and bandpass outputs (a click, loudest between the antiphase lowpass and highpass).
- **Grain mode fades.** Switching a voice between continuous and triggered grains fades the position-spread path over 50 ms instead of clicking.
- **Stop then clear.** Stopping a recording and clearing the buffer at once leaves it empty; the stopped take used to come back and be written as the scratch take.
- **Loads apply when the file is read.** A buffer keeps its old length until the file has been read (an empty buffer stays silent until then), and a clear (or another load or recording) sent meanwhile wins. A voice already playing a buffer that held audio hears the buffer being refilled during the read, against its old length.
- **Grain synth order after source switches.** Grain synths that read a voice's bus always run before those that copy into one, and every grain synth runs before its voice's mod synth, after any history of source switches and restarts. No grain synth is placed next to a synth that may have freed already (which could create nothing, or leave a grain synth that never frees).
- **Cross-modulation for input-sourced voices.** An input-sourced voice now takes amplitude modulation from its mod slots (frequency modulation means nothing for live input and is ignored). In 3.0 its routing and amounts had no effect.
- **Failed and interrupted writes.** A save to a directory that cannot be made reports `cannot write` and deletes its temporary files; it used to stop with an error and leave them behind. Partial `.part` files left by a crash in `~/dust/audio/strata/` and its `scratch/` folder are deleted when the engine starts (only absolute folders below the root are cleaned: an empty, relative or root scratch folder never makes it clean the working directory or `/`).
- **Safer engine defaults.** Both grain SynthDefs mirror nothing unless the engine turns the mirror on, and a synth-sourced grain synth reads the silent bus for its unused mod slots instead of control bus 0 (the input amplitude follower on norns). The engine caches each SynthDef's control names instead of looking them up on every control change.

### Other Changes

- Code only, no change in behaviour: the arc button finds MAIN by its page index, not its title; `gentle_mutate` checks every grain key against `DISCRETE_GRAIN_KEYS`; the drift's step is one helper (`mean_reverting_step`); `add_voice_params` builds every param id the same way.
- `strata.lua`'s main chunk holds 186 of Lua's 200 locals (183 in 3.0).

### Decisions

- **Arc rings sweep in half a turn.** 512 ticks per full sweep was chosen over a full revolution; the arc's 1024 ticks per revolution was checked against the monome arc documentation and matron's delta handling.
- **The write interleave keeps its per-frame loop.** An array-level `lace` interleave was tried and measured about twice as slow (0.11 s against 0.057 s per 16 s take, standalone), because each chunk must be converted FloatArray → Array → FloatArray. The loop stays, and a new engine check writes a full 16 s buffer and checks every frame's position (end to end about 0.15 s on a Mac).
- **Position spread in triggered mode.** It does nothing for synth- and input-sourced voices, but a buffer-sourced voice still jitters each triggered grain's position by it; the docs say so.

### Testing

- `lua test/run.lua` / `luajit test/run.lua` grew from 97 to 118 tests: arc rings per page and their sweep speed, the transition holding `filter_type`, bad `bufferState` values (NaN, infinities, unknown slots), cleared and missing buffers across restarts, engine-confirmed takes, loads and restores, MIDI-held voices stopped from the grid or a scene, the menu hook, the save flash, omni bend, one sync per recall, and the static `param.t` check for both quotes and both orders. The param stub takes its type codes from one table and rejects unknown types.
- `test/run_engine_check.sh` checks the triggered grain mode (silent without a trigger, a grain on retrigger), the filter crossfade (largest sample step across type changes), the stop-then-clear race, grain synth order after rapid switches, mirror and crossmod controls, load completion, failed writes and stale `.part` files, and a full 16 s write. Every reply it waits for times out after 5 s and the whole check after 540 s, so a lost reply fails the run instead of hanging it. Engine checks on one machine share scsynth's port: run one at a time.

### Check on Hardware

- Arc feel with every ring sweeping in half a turn, especially long ranges (record duration, the LFO free period)
- How soon a take or a restored buffer shows on the BUFFER and SETUP pages on the CM3
- CPU: synth- and input-sourced grain synths carry seven more controls, and the filter runs its three filters as before

## Version 3.0 - 2026-11-03

Absorbs the feature set the Confluence script promised (buffers and live input, filter and delay, grain envelopes and triggered grains, LFOs, MIDI, a paged screen), so Confluence can be retired. Strata keeps its seven voices, and every grid row keeps its meaning. Not brought over, by design: Confluence's 16-voice polyphony, preset file export (scenes cover it), a buffer waveform display, MIDI learn code (norns' PARAMS > MAP does it) and 20 Hz LFOs. Design: `docs/superpowers/specs/2026-11-03-confluence-features-design.md`.

### New Features

- **Paged screen UI.** E1 selects one of five pages: MAIN (the old screen), FX, LFO, BUFFER and SETUP. Each page has its own E2/E3/K2/K3, a shared header (page title, `dens:`, `[M]`, `S1`-`S8`) and a hint row. E1 has no acceleration (one page per short turn). Master density moved off E1 to the FX page, MAIN's arc ring 1 and PARAMETERS. The MAIN voice list shows 4 rows so it clears the hint row.
- **Arc pages.** The arc follows the screen page: MAIN (density, main parameter, grain size, grain density), FX (filter freq, filter res, delay time, delay mix), BUFFER (buffer position and rate of the selected voice, record duration, record level), LFO (depth of LFO 1-3, period of the selected LFO); SETUP has no rings. The arc button mirrors K3 on MAIN only.
- **Filter and delay.** A lowpass/highpass/bandpass filter (`setFilter`, mix 0 = bypass by default) and a stereo feedback delay up to 2 s (`setDelay`, dry by default) run before the reverb. FX page K3 bypasses the filter and restores its last mix above 0. The master limiter now sits before the saturator, where it can catch resonance and feedback peaks.
- **Grain envelope shapes.** Per voice: hann, sine, perc, linen or trap (`envShape`).
- **Triggered grain mode.** Per voice: continuous grains, or one grain per pattern step or MIDI note (`grainMode`). `retrigger` now carries a velocity (`"if"`): pattern step level / 15, or MIDI velocity / 127, scales the accent. MAIN shows `[TRIG]`.
- **Audio sources.** Each voice can grain its own synth, one of eight stereo 16 s buffers or the live stereo input (`setGrainSource`). Buffer-sourced voices use two sample-aligned `GrainBuf`s with buffer position, rate (0.25x-4x) and scan; switching replaces the grain synth and never stacks nodes. Buffer- and input-sourced voices still feed cross-modulation, and still accent on pattern steps and notes. For a buffer source, E3, arc ring 2, the grid faders, randomize, mutations and the drift work on the buffer parameters; for the input source, on grain size and the grain parameters.
- **Buffers.** Load a file (up to 16 s), record the input (press again to stop early and keep the take), clear and save, from the BUFFER page, grid 256 page 4 (record, clear, and a source row per voice) or PARAMETERS > buffers. New commands `loadBuffer`, `recordBuffer`, `stopRecord`, `clearBuffer`, `saveBuffer`, and the `bufferState` poll (each slot's length, shown on the BUFFER page).
- **Buffer persistence.** A finished take is written to `~/dust/audio/strata/scratch/buf<n>.wav`; K2+K3 on the BUFFER page (or `buf<n>_save`) writes a timestamped WAV to `~/dust/audio/strata/`. On exit Strata remembers each buffer's file or take in `~/dust/data/strata/buffers.data` and reloads them on start (SETUP shows how many). Overlapping writes to one file can never mix.
- **Grid 256 page 4 (buffers / FX).** Row 1 record/stop, row 2 clear, rows 3-7 filter and delay faders, rows 9-15 each voice's source; rows 8 and 16 as on page 1.
- **Global LFOs.** Three LFOs on norns' `lib/lfo.lua` (sine, tri, square, random, up, down; free or clocked), each routed to one destination (68 options, none included): master density, drift, filter, delay and reverb settings, and per voice its main parameter (following its source), grain size, density, pitch, spread and buffer position, rate and scan. They modulate around the stored value and never write it; the value returns exactly when an LFO stops, reaches depth 0 or changes destination. LFO page with a waveform and a moving dot per LFO.
- **MIDI input.** Notes play voices (per-voice channels 1-7, or omni to the selected voice): pitch from the note (frequency, or buffer rate for a buffer source), velocity on the accent, pitchbend up to 2 semitones (`bend`, transient). Note off is ignored by default; in "voice off" mode a note during the release re-gates the releasing synths instead of starting new ones. SETUP shows the port, device and channel mode (E2/E3); hot-plug works. CC mapping is norns' PARAMS > MAP (README lists Confluence's suggested CCs).
- **Scenes, format 2.** Scenes capture the FX settings, grain envelope and mode, each voice's source and buffer parameters (not buffer audio) and the LFO settings. Version-1 files migrate on load with defaults (FX at defaults, every voice on its synth, LFOs off) and are saved as version 2.

### Other Changes

- Every engine-facing param action goes through `send_param_to_engine`, which also adds any running LFO's offset, so edits, mutations, scene fades and the drift never send the plain value under an LFO.
- The per-voice random walk `lfo_update` is now `drift_update` (and `drift_metro`), so it is not confused with the global LFOs.
- `voiceOn` never stacks synths: a voice's synths still running or still releasing are re-gated.
- The `freq` controlspec step is 0, so MIDI notes keep exact equal-tempered pitch.
- Grid 256 fader pages: 5 for Folder and Sub, 6 for the other voices, 5 for a buffer-sourced voice and 4 for an input-sourced one (grain envelope and mode added).
- Whole-branch review fixes:
  - `\strataGrain` (synth- and input-sourced voices) runs one mono `GrainIn` per input channel panned with `Balance2`, like `\strataGrainBuf`. Its stereo `GrainIn` on a stereo input had expanded into two, each panning its own channel, which `Out` folded back to one channel apiece: pan spread did nothing (it only wobbled the level), the position-spread path was added twice, and every voice ran four `PitchShift`s. **Synth- and input-sourced voices are about 3-6 dB quieter than before this fix**; no makeup gain was added, so compare levels across sources on hardware.
  - A voice playing a buffer that is being recorded is silent until the take completes, instead of looping the take's first grain 20 times a second (`\strataGrainBuf` is muted while its slot reads 0 frames).
  - Scrolling a running voice's source no longer piles up grain or voice synths: each switch cuts (a 0.05 s fade, then freed) whatever an earlier switch left releasing, so once a switch has been processed a voice has at most one releasing grain synth and one releasing voice synth, at any scrolling speed. The cut is a kill fade in every voice and grain SynthDef (`kill` triggers it); a second, shorter forced release could not shorten the 2 s forced release a replaced synth is already in.
  - A voice started and stopped in one control block (a MIDI note on and note off arriving together in "voice off" mode) frees its synths after their release instead of keeping a silent trio running for ever: every ASR's gate is held open for the synth's first block. A grain synth from the previous source that a restart left releasing is cut when the voice stops again.
  - A buffer-sourced voice re-gated during its release picks up a buffer that was loaded, recorded or cleared meanwhile; `voiceOn` keeps the voice's grain mode, envelope and buffer position, so a triggered-mode voice no longer fires one stray continuous grain when it starts.
  - Picking the same file again (after recording into or clearing the buffer) loads it, from the BUFFER page and from PARAMETERS; restored buffers show their file in PARAMETERS.
  - The BUFFER page caches each buffer's shortened name; `strata.lua`'s grid, BUFFER-page and FX-page constants are grouped into tables (main-chunk locals 198 → 183 of Lua's 200).
- Documentation: MAIN K3 and the arc button were described as "start/stop"; they start a stopped voice and otherwise freeze/unfreeze it (stop voices from the grid, a scene or a MIDI note off). CLAUDE.md no longer claims mutations change cross-modulation.

### Deviations from the design

- **Limiter before the saturator.** The design put `Limiter.ar` after the tanh stage, whose output is already bounded to ±0.5, so it could never act. It runs before the saturator.
- **K3 keeps start/freeze.** The design let K3 on MAIN fire a triggered grain for a running voice; K3 keeps freezing it, so triggered grains come from pattern steps and MIDI notes only.
- **Input-sourced voices' main parameter is grain size.** The design mapped every non-synth source to buffer position, which does nothing for the input; E3, arc ring 2, MAIN and the first fader use grain size, and randomize, mutations and the drift touch only grain parameters.
- **LFO rate ceiling 10 Hz.** The library's fastest free period is 0.1 s; Confluence promised 20 Hz, which would need engine-side LFOs.
- **LFO depth in percent.** Depth is the library's 0-100 % number param; E3 and the arc step whole percents.
- **LFO message rate bounded.** Each LFO steps at 48 ppqn (the library's default is 96) and skips a send when its destination would move less than 1/1000 of its range; restores and param actions always send.
- **LFO params.** norns groups cannot nest, so the destinations are `strata_lfo<n>_dest` in their own "lfo destinations" group beside the library's own LFO 1-3 groups (`lfo_*` ids are the library's). Scenes capture each LFO's mode and clocked rate as well as its free period.
- **`bufferState` poll encoding.** matron delivers one float per poll message, so each message carries one slot as `slot * 100 + seconds`, cycling through the slots.
- **`stopRecord` command.** Added so a recording can stop early and keep what it captured (the design asked for stopping early but listed no command).
- **BUFFER page save gesture.** K2 acts on release (file browser); holding K2 and pressing K3 saves.
- **Source changes reach stopped voices.** `v<i>_source` always sends `setGrainSource` (the engine records it for a stopped voice), so `voiceOn` builds the right synths directly.
- **Grain-side accent only for the input source.** The design put the accent × velocity in `\strataGrain` for every voice. A synth-sourced voice is already accented by its voice synth, so `\strataGrain` applies its own accent only when it grains the live input (`accentAmt` 1; 0 for the synth source) and no voice is accented twice.
- **Input-sourced grains mirror to the voice bus.** As for buffer sources, the input `\strataGrain` also writes its output to the voice's bus, so the voice's mod synth keeps feeding cross-modulation. The mirror is off for the synth source, whose grain synth reads that bus (it would feed back).
- **Scratch directory is an engine variable.** `scratchDir` defaults to `~/dust/audio/strata/scratch/` (Lua's `_path.audio .. "strata/scratch/"` on norns) and is created on demand; the engine check points it at a temporary directory so it never writes into `~/dust`.

### Check on Hardware

- CPU with several buffer-sourced voices (two `GrainBuf`s and a stereo `PitchShift` each), on top of every voice's `\strataGrain` (two `GrainIn`s and a stereo `PitchShift`)
- Levels across sources: synth- and input-sourced voices are 3-6 dB quieter than before the `\strataGrain` fix; compare a synth, a buffer and an input voice at the same `amp`
- Arc ring speeds: FX filter freq sweeps in under half a turn, res and mix take about ten turns; BUFFER position takes about twenty
- Save and scratch-take interleave time for a full 16 s buffer on the CM3 (8192-frame chunks, 1 ms apart)
- MIDI with a real device: hot-plug, long device names on SETUP, pitchbend, voice-off mode with fast repeated notes
- Levels: limiter and saturation with high filter resonance and delay feedback, accents at full velocity, recording level from the input, LFO steppiness at fast rates
- Clicks when switching filter type or grain mode while sounding

3.0.1 changed the arc ring speeds (every ring now sweeps in half a turn), crossfades filter type changes and fades grain mode switches; see 3.0.1 above.

### Testing

- `lua test/run.lua` / `luajit test/run.lua` grew to 97 tests: stubs for option/file/text params, `lib/lfo.lua`, MIDI, fileselect, polls, encoders and screen levels; tests for every feature above. A docs test checks that CLAUDE.md's command table lists exactly the engine's commands with their signatures, and that no doc mentions a command the engine no longer has.
- `test/run_engine_check.sh` drives every new command (sources, buffers, stopRecord, overlapping writes, filter, delay, re-gating) against a local scsynth, including a burst of source switches, the grain synths' structure, and a test tone recorded into a buffer a voice is playing (silent until the take completes).

### Upgrade Notes

- Existing `scenes.data` files load and are rewritten as version 2 on exit.
- Master density is no longer on E1 (use the FX page, MAIN's arc ring 1 or PARAMETERS).
- Pattern step brightness is now accent velocity: hand-set steps (15) accent as before, randomized steps (8-15) more softly.
- The buffers take about 49 MB of scsynth memory.

## Version 2.1 - 2026-11-03

Fixes every finding from a whole-app code review, plus an off-device test harness.

### Critical Fixes

- **C1 - Voices started at the wrong pitch.** `voiceOn` was declared `"isfffff"`, typing `freq` as a string; matron stringified it and scsynth ignored it, so `freq` was never set when a voice started. The signature is now `"iffffff"`.
- **C2 - Starting a voice dropped most of its state.** `voiceOn` sent only freq/amp/pan and three grain values and the engine filled everything else from its own defaults, so edits made while a voice was off, `posSpread`, all cross-modulation routing and amounts, and mod speed were lost, and recalled scenes came up with the wrong timbre and no routing. New `sync_voice_to_engine()` pushes the complete Lua state right after `voiceOn`; the engine's `getVoiceParams` defaults were removed.
- **C3 - The pattern sequencer stacked synth chains.** Each step on a running voice toggled it off and on, leaving the old voice/grain/mod synths running through releases of up to 12 s; dense patterns piled up ~90 chains per voice. New engine command `retrigger(voice)` fires an accent envelope (`t_trig`) on the running voice (Karplus re-plucks); steps never create nodes.
- **C4 - "Grain pitch" was a volume control, and it wandered.** The grain output was multiplied by `pitchShift`, and the LFO random-walked it to its limits (up to +/-12 dB). Grain pitch now uses `PitchShift.ar`, and the LFO drift is much smaller (+/-0.002 per tick) and pulls back toward the pitch you last set.

### Important Fixes

- **I1 - Tempo did nothing.** The tempo param and grid tempo buttons now set norns' `clock_tempo` (the sequencer still syncs to the norns clock, so external clocks work); the param starts at the current clock tempo.
- **I2 - The 8x16 grid layout was unreachable.** Layout detection matched `rows >= 16` before checking 8x16; sizes are now matched exactly.
- **I3 - Grid hot-plug was broken.** A replugged grid was never redrawn and every press ran twice. `grid.add` now stores the port's vport like `grid_init`; `grid.remove` clears the handler. (The arc had the same problem and got the same fix.)
- **I4 - "No modulation source" followed the input jack.** Unrouted mod slots read control bus 0, which on norns is the input amplitude follower. The engine now allocates an always-zero silent bus for them.
- **I5 - Modulation could push frequencies to zero or below, and FM/Sub were unclamped.** The frequency modulator is clamped to -0.9..2 in every voice, and FM and Sub gained the same amplitude clamping as the other voices.
- **I6 - Scene transitions finished early.** A 20 s crossfade was ~97% done after 10 s. Start values are now snapshotted once and faded linearly; only continuous parameters fade, the rest switch at the end. Any recall cancels a running transition.
- **I7 - Scene validation missed fields recall depends on, and a bad scene file could crash init.** Validation now covers every field recall reads (globals, freeze flags, all pattern steps, crossmod slots); the file is loaded under `pcall`, missing slots are filled, and the file records a format version (`{version = 1, scenes = ...}`; older files still load). A file that fails to load is moved to `scenes.data.bak` (or, if that fails, the exit auto-save is skipped) so the save on exit never overwrites it with empty scenes.
- **I8 - The 16x16 grid parameter page was a stub.** Rows 9-12 are now faders over the selected voice's parameters (synthesis, grain, cross-modulation) and row 13 selects the fader page (4-5 pages per voice). Faders follow each parameter's controlspec warp, so exponential params such as freq and cutoff are usable across their whole range.
- **I9 - Grid LEDs went stale.** Starting/stopping voices, freezing from K3/arc/grid and randomizing now refresh the grid.

### Minor Fixes

- **M1** - Remaining hardcoded voice/scene/step counts replaced with `NUM_VOICES`, `NUM_SCENES`, `PATTERN_LENGTH` (Lua) and `numVoices` (engine).
- **M2** - The Resonator's output was doubled (two summed stereo pairs); it is now one stereo pair (about 6 dB quieter than before).
- **M3** - Reverb added the dry signal twice, so mix could never be fully wet; it now outputs FreeVerb2's own dry/wet mix (lower overall level at the default mix).
- **M4** - Tape drift and the Sub's drift were LFO rates (0 froze the pitch at a random offset); they now set the drift depth at a fixed slow rate. Tape drift 0 = none; the Sub drift minimum stays 0.001.
- **M5** - Reverb and master ran after norns' output stage; all engine nodes now run inside the engine group in the order voices, grain/mod, reverb, master.
- **M6** - Engine commands ignore voices that are not running, and starting a running voice releases its old synths first.
- **M7** - Header text overlapped (`dens:` ran into `[M]`); the layout was rearranged (`dens:` now starts at x=40, clear of the title) and `[FREEZE]` no longer runs off the screen. The grid highlights the step that just played rather than the next one.
- **M8** - Removed dead state (`grid_dirty`, `selected_param`, `param_names`, `grid_key1_held`, unused `musicutil`, the unused `tempo` local, a duplicate local); the transition-active flag is cleared on cancel; the arc variable is now `arc_device`.
- **M9** - Cleanup also resets the scene sequencer param and darkens grid and arc.
- **M10** - Documentation brought in line with the code (README grid layouts, CLAUDE.md function references, engine commands).

### Other Fixes

- Voice params now default to each voice's own values (the PARAMS menu showed 100 Hz for every voice's freq, for example).
- The `ratio` step is now 0.001 so the Ring's 1.618 default is not snapped to 1.6.
- Under the grid playhead, empty steps are dim and active steps bright (the whole column used to be lit at full).
- The grid's parameter faders follow mutations, the grain pitch drift and scene transitions instead of going stale.

### Testing

- `lua test/run.lua` / `luajit test/run.lua` - behaviour tests against norns stubs; every `engine.*` call is checked against the engine's command signatures.
- `lua test/sync_check.lua` - static Lua/engine command sync check.
- `test/run_engine_check.sh` - compiles the engine against the real norns classes and exercises every command on a local scsynth.

### Upgrade Notes

- Existing `scenes.data` files load unchanged and are rewritten in the versioned format on exit.
- Overall level is lower than in 2.0 because of the Resonator (M2) and reverb (M3) fixes; raise voice `amp` or the norns output level if needed.
- Grain pitch now transposes the whole grain-synth output (grains and position-spread path); scenes saved with grain pitch away from 1.0 will sound transposed rather than louder or quieter.
- Scene recall now sets the clock tempo (norns' `clock_tempo`), including for scenes saved by 2.0, whose stored tempo used to have no effect. Under Link this changes the session tempo for every peer.

## Version 2.0 - 2025-01-24

### Critical Bug Fixes

**Scene Data Corruption Prevention**
- Added comprehensive scene data validation before loading from disk
- Prevents crashes from corrupted or incompatible scene files
- New `validate_scene_data()` function checks:
  - Table structure integrity
  - Voice count matches (NUM_VOICES)
  - Required fields presence (params, grain, crossmod)
  - Pattern data validity
- Graceful error messages instead of crashes

**Scene Sequencer Position Bounds**
- Fixed wraparound bug that could cause out-of-bounds scene access
- Added `util.clamp()` to keep sequencer position within valid range (1 to sequence_length)
- Changed modulo arithmetic to explicit bounds checking for clarity
- Sequencer now skips empty scenes with console notification instead of failing silently

**Concurrent Scene Transition Prevention**
- Fixed race condition where rapid scene recalls created multiple concurrent transition clocks
- Added `scene_transition_clock` tracking variable
- Transitions now cancel previous transition before starting new one
- Prevents parameter oscillation during rapid scene switching

### High Priority Bug Fixes

**Arc Initialization Race Condition**
- Fixed duplicate handler creation when arc connects multiple times
- `arc.add()` now checks if already connected before re-initializing
- Prevents memory leaks and multiple callback registrations

**Mutation Metro State Synchronization**
- `cleanup()` now properly syncs mutation_enabled parameter with metro state
- Prevents state inconsistency between param system and actual metro
- Metro is stopped and parameter set to 0 on script exit

**64-Button Grid Pattern Display**
- Fixed bug where pattern position could advance beyond visible range (1-8)
- Updated condition to only highlight visible steps
- Added clarifying comment about showing first 8 steps of 16-step pattern

**Pattern Bounds Checking**
- Added bounds checking to `toggle_pattern_step()`, `clear_pattern()`, and `randomize_pattern()`
- Prevents array expansion beyond intended voice/step limits
- Functions now return early if indices are out of range

**Scene Transition Nil Access Protection**
- Added validation checks for scene_data.voices existence before accessing
- Checks for nil values in params and grain data during transitions
- Prevents crashes from incomplete scene data structures

### Medium Priority Improvements

**Code Quality & Maintainability**
- Replaced hardcoded magic numbers with named constants:
  - `NUM_VOICES = 7` - Total number of synthesis voices
  - `NUM_SCENES = 8` - Total number of scene slots
  - `PATTERN_LENGTH = 16` - Steps per pattern
  - `SCENE_DATA_VERSION = 1` - For future compatibility
- Updated all voice loops to use `NUM_VOICES` instead of hardcoded 7
- Updated all pattern loops to use `PATTERN_LENGTH` instead of hardcoded 16
- Improved code consistency throughout grid rendering functions

**Scene System Enhancements**
- Scene sequencer now skips empty scenes instead of causing gaps
- Added console notifications when skipping empty scenes
- Improved error messages for invalid scene data

**Resource Management**
- Added nil checks to cleanup() for metros and clocks
- Scene transition clock properly cancelled on cleanup
- All clocks tracked and cleaned up to prevent orphaned coroutines

**SuperCollider Engine Improvements**
- Added modulation signal clamping to prevent excessive amplitude
- Prevents 4x amplitude spikes when 3 modulation sources max out
- Modulation signals now clipped to -2...+2 range before mixing
- Final amplitude clamped to 0...2 range for safety
- Applies to all voice SynthDefs (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring)

### Documentation

**Code Comments**
- Added explanatory comments for critical bug fixes
- Documented bounds checking rationale
- Clarified scene validation logic
- Explained modulation clamping ranges

**Developer Notes**
- All magic numbers replaced with documented constants
- Improved function headers with bounds checking documentation
- Added inline comments for complex validation logic

### Breaking Changes

None - Version 2.0 maintains full backward compatibility with version 1.0

### Upgrade Notes

**Scene File Compatibility**
- Existing scene files (~/dust/data/strata/scenes.data) will be validated on load
- Corrupted files will be rejected with error message instead of crashing
- If you encounter scene loading issues, delete scenes.data and recreate your scenes
- Future versions may use SCENE_DATA_VERSION for migrations

**Parameter Behavior**
- No parameter changes - all existing parameter automation remains compatible
- Scene transitions now handle missing data more gracefully
- Pattern sequencer behaves identically but with better bounds checking

### Performance

- No performance regressions
- Added validation adds negligible overhead (<1ms on scene load)
- Grid redraw optimization (grid_dirty flag) prepared but not yet enabled
- Clock cancellation prevents accumulation of orphaned coroutines

### Known Issues

None identified in version 2.0 release.

### Testing Recommendations

After upgrading to 2.0, please test:
1. Scene save/load functionality
2. Scene sequencer with varying sequence lengths
3. Rapid scene transitions (manual and sequenced)
4. Arc hot-plug (connect/disconnect while running)
5. Pattern sequencer with 64-button grid
6. Cross-modulation with multiple sources at high amounts
7. Script restart (cleanup verification)

### Developer Statistics

- Files Modified: 2 (strata.lua, Engine_Strata.sc)
- Bug Fixes: 24 total (3 critical, 7 high, 9 medium, 5 low)
- Lines Changed: ~150
- Constants Added: 4
- New Functions: 1 (validate_scene_data)
- Improved Functions: 15+

### Credits

Version 2.0 comprehensive review and improvements completed January 2025.
