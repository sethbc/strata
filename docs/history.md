# Strata release history

Each release in a paragraph: what it added and how it was built. CHANGELOG.md has the full list of changes, docs/decisions/ the decisions and `ROADMAP.md` what comes next.

## Keeping this file

- Each release gets a short entry here (highlights only). CHANGELOG.md holds the full list and docs/decisions/ the decisions (`docs/decisions/README.md`, one file per release line).
- Entries describe a release as it shipped. Do not rewrite old entries to today's names or layout.
- The docs check reads this file (it is one of the maintained docs, `docs/notes/test-harness/run-and-helpers.md`): every repo path it names in backticks must still exist, and every `engine.<name>(` must name a command the engine has. Name commands without `engine.` and parentheses (`setFilter`), and name a file that has since moved by its plain name or its new path.
- When an idea under Future extension points ships, strike it through and add the version.

## Future extension points

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
- ~~Per-scene naming~~ ✓ Implemented (v3.4 - 12-character names, `S.lib.scenes.name`); tagging is still open
- ~~MIDI integration for external control~~ ✓ Implemented (v3.0 - notes, velocity, pitchbend; CC via norns PARAMS > MAP)
- ~~Sample buffers and live input~~ ✓ Implemented (v3.0 - per-voice sources)
- ~~Global LFOs~~ ✓ Implemented (v3.0 - three, on norns `lua/lib/lfo.lua`)
- ~~Engine-side LFOs (above the Lua library's 10 Hz ceiling)~~ ✓ Implemented (v3.4 - on the five fast destinations, up to 50 Hz, `lib/engine/StrataModulation.sc`)
- ~~Buffer waveform display on the BUFFER page~~ ✓ Implemented (v3.3 - peaks files, `lib/waveforms.lua`)
- ~~Polyphony inside each voice, and MPE~~ ✓ Implemented (v3.5 - up to eight notes a voice from a shared pool, `lib/notes.lua`; MPE zones, `lib/mpe.lua`)
- An arc page showing each held note's pressure as ring segments (3.5's stretch goal, not built)
- Tempo-synced delay times
- Undo/redo for parameter changes
- ~~Parameter automation recording~~ ✓ Implemented (v3.4 - four gesture recorders, `lib/gestures.lua`)

The agreed order of the next releases is `ROADMAP.md`.

## Version 3.5.0 (2026-11-13)

Polyphony and MPE (design: `docs/design/3.5-design.md`, amended where the build differs). 3.4's sound by default: a voice nothing plays chords on sounds the same, and scenes and PSETs saved with 3.4 load; what sounds or plays differently (a second held key adds a note, a keyboard's aftertouch swelling its notes, a frozen synth voice's quantize, MIDI pitching an input voice, the note off modes, a buffer voice's exact MIDI pitch) is under CHANGELOG.md's Sound Changes and Upgrade Notes. Highlights:
- Notes in the engine: the notes area (`lib/engine/StrataNotes.sc`, order 170) with eight slots a voice (slot 0 the own note) and a pool of extra notes all voices share (at most 16); a synth voice's extra note is a voice synth, a buffer or input voice's a grain synth of its own, a frozen synth voice's a stream of its ring; four commands (`noteOn`, `noteOff`, `noteExpression`, `setNotePool`); the voice and grain defs' note controls (the park, `noteBend`, `noteAmp`, `noteMain`, `notePos`, `noteSize`, `noteRate`, `attackTime`, `releaseTime`); voice-wide sends through `setVoiceSynths` and `setGrainSynths`.
- Notes in Lua: the allocator (`lib/notes.lua`: six branches, stealing, the own note's park, the pool in `notes.data`, the note cap, the attack and release times, the expression flush at 16 a step), with the voice-stop and freeze-change registries and `count_sends` beneath it.
- Players: MIDI chords with latch and release and aftertouch (`lib/midi_in.lua`), MPE zones, RPNs and assignment (`lib/mpe.lua`), the expression mapping and its sources (`lib/expression.lua`), sequencer chords (`lib/sequencer.lua`, whose further notes take only free room) edited on SEQ and the arc's step editor.
- UI: MAIN's note count, VOICE's `notes` section, SETUP's `note off`, `mpe & zones` (`lib/ui/zones.lua`, its learn through MIDI's note tap) and `note pool`, MOD's pressure and slide sources.
- Scenes: format 7.
- Memory: every voice SynthDef measured for the first time; two cases with the pool full, the tightest leaving 2070 KB on high in CI's shard against a 1280 KB floor (`docs/notes/engine/memory.md`).
- Tests: 1931 Lua tests, among them a whole-system test that plays 3.5 end to end against the engine stub and a model of the engine's note slots checked against the allocator; the engine check's notes area, and 1330 checks a full run. At the release every area passed on SuperCollider 3.14.1 in CI's shards (7 of 7, 1202 s) and in four full runs on 3.13 (all 7 shards in each), with no collector error, and again after the final review's fixes (7 of 7 in 1208 s, and four full runs on 3.13).

It was built from a plan in three waves of parallel packages, landed in five batches, with fifty-seven rulings taken on the way, each kept by number in `docs/decisions/3.5.md`. Found and fixed while it was built: the design's findings (#662-#666), two notes' stale shard text (#669), the local engine check's full run, which now runs CI's shards, each in a fresh sclang (#671), and its timing-dependent runner test (#673). Then, before the release, three fixes landed together (PR #681): #211, sclang's collector failing in the waveform area's 300 s check (and crashing #671's single-sclang runs), traced to methods whose frames outlive their call and called from functions (the engine's area hooks, `strataAreas`, the grain readers, two `onFree`s, a synced take, an engine LFO's start and watch, `gateVoice` and six commands' methods), each now called through `areaCall` with structure tests to keep it so (ruling 50; #680 lists the guards' gaps); #677, a timing assumption in the modulation area's 20 Hz LFO check; and #679, a buffer voice's own MIDI note rounded to a 0.01 rate, found by the whole-system test. The whole-release review then found no critical issue and five important ones, each fixed or documented in the release (rulings 53-57): a frozen synth voice's held chord out of tune after a source switch (#682, the engine now takes a stream note's rate from its note), a gated voice's added MIDI keys silent (#683, an extra note's start opens the step gate), one latched MIDI note shutting the sequencer out of the voice's own note (#684, only a key held down keeps it), aftertouch swelling a 3.4 setup's notes (#685, documented under Sound Changes), and no test comparing Lua's held notes with the engine's slots (#686, a model of the engine's note slots, which found one more case for a ruling: a recall into a frozen synth voice under held notes).

See CHANGELOG.md and `docs/status.md`.

## Version 3.4.0 (2026-11-12)

Modulation and sequencing (design: `docs/design/3.4-design.md`, amended where the build differs). 3.3's sound by default, apart from LFOs on a voice's grain pitch, position, size and filter cutoff, which run in the engine (the cutoff in octaves). Highlights:
- Fast modulation: the modulation area (`lib/engine/StrataModulation.sc`, order 160) with a 35-channel offset bus addressed by `fastModChannel(voice, noteSlot, destination)`, the offsets added in the grain synths (pitch, position, size) and the per-voice stage (cutoff, level, `voiceMixMod`), eight LFO shapes and scatter as nodes in `fastModGroup`, the matrix's offset node, the stage's step gate and mute; five commands (`setFastLfo`, `stopFastLfo`, `syncFastLfo`, `setScatter`, `setFastOffset`).
- The script's hooks (`lib/state.lua`, `lib/engine_sync.lua`): the `scene_blocks`, `scene_migrations`, `pset_hooks`, `param_touch`, `lock_change`, `step_outputs` and `mod_sources` registries; base overrides and extra offsets; the send budget (`ENGINE_BUDGET`, `deferrable`, `expected_value`); the modal owner (`lib/ui/modal.lua`); a recall as one list of entries (`scene_entries`, `apply_entries`).
- Modulation: Strata's own six LFOs (`lib/lfos.lua`, rewritten: one 48 Hz clock, `strata_lfo<n>_*` params, 3.3's PSETs and scenes imported), macros and scatter (`lib/macros.lua`, `lib/scatter.lua`), the morph and the XY morph (`lib/morph.lua`), gesture recorders (`lib/gestures.lua`), the matrix (`lib/matrix.lua`), the input level (`lib/input_level.lua`) and the sources' registry (`lib/mod_sources.lua`); the MOD page and its rings (`lib/pages/mod.lua`, `lib/arc/mod.lua`).
- Sequencing: `lib/sequencer.lua` rewritten (a clock per voice, step attributes, locks as base overrides, notes, gates, swing, euclid, chaining, transport following, step outputs), quantized actions (`lib/quantize.lua`), SEQ's edit view and the step editor (`lib/pages/seq.lua`), step keys on release (`lib/grid/core.lua`).
- Scenes: sixteen slots in two banks with names, format 6; mute and solo (`lib/voice_mix.lua`).
- Data files: `macros.data`, `matrix.data`, `gestures.data` (live and per PSET); the reader's cap 32768 tables; the MIDI map repair of 3.3's LFO ids (`lib/midi_in.lua`).
- Memory: every floor holds with six engine LFOs and scatter running; the stage's check limit 42 KB (`docs/notes/engine/memory.md`).
- Tests: 1757 Lua tests; the engine check's modulation area; CI's Lua suites in two parallel jobs.

Before the release, a whole-release review split by area filed #595-#641, each fixed in a fix wave of seven groups by file ownership; then the late fixes: `bufferState` reports numbered per load (#578, `(load × 9 + slot) × 1000 + seconds`, `bufferStateLoads`), the clock stub's instant as matron's tick (#588, #650), a send budget that counts exactly the messages reaching the engine with discrete switches outside it (#642, #644-#646, #649), morph crossings at most once per `MORPH.crossing_seconds` (#653), one side-file helper (`lib/side_files.lua`, #648) and the matrix's sends through `expected_value` (#647), the recorders' live file written soon after each change (#651), the engine check's areas independent of their order (#652) and the budget's flush clock ending at its own wake (#654). #211 (sclang's collector in the waveform area's 300 s check, about 1 run in 10 to 16 as measured at the release, on the 3.3 engine about as often as on 3.4's) is held. The decisions, with the rulings by number, are in `docs/decisions/3.4.md`.

See CHANGELOG.md and `docs/status.md`.

## Version 3.3.2 (2026-11-11)

Page randomize (#557; design: `docs/design/3.3.2-page-randomize-design.md`). ALT+K2 randomizes on MAIN, VOICE, SEQ, FX and LFO (the section under the cursor on VOICE, FX and LFO), acting on release (a quick press under 0.5 s; held past it, the page's hold action), with one undo for the whole script on the same key. SEQ's ALT+K2 randomizes and ALT+K3 clears; VOICE's and LFO's reset to default is ALT+K2 held. No engine file changed. See CHANGELOG.md and `docs/status.md`.

## Version 3.3.1 (2026-11-11)

A fix release. A clock-synced recording takes its length and wait from the tempo the clock will run at (internal clock: the `clock_tempo` param; Link, MIDI and crow: `clock.get_tempo()`) and starts `delay` after the moment Lua sent it, however busy the engine is (`recordBuffer`'s ninth argument, `sent`, Lua's wall clock modulo 1000 s: #565, #567); `buffers.data` is written once per burst of changes, 0.1 s after the first, with the newest state (#566); the freeze check's setup is retried and the local check's timeout is 1800 s (#569, #570). See CHANGELOG.md and `docs/status.md`.

## Version 3.3.0 (2026-11-11)

Buffers as instruments (design: `docs/design/3.3-design.md`). 3.2's sound by default, apart from 5 ms record fades, a re-gated buffer voice restarting its scan and the grain synths' fades running before the voice filter; the review fixes add the brighter master, the cutoff's rise limit, the FM and Ring highpass and the 4 ms trigger bound. Highlights:
- The per-voice mix stage: one persistent `\strataVoiceMix` per voice (`lib/engine/StrataMix.sc`) holds the voice filter, the voice-level gain, the sends, the mirror and the voice tap; grain synths write their source kind's path only, about 16 KB less each.
- Recording: the record area (`lib/engine/StrataRecord.sc`, `lib/record.lua`): playable overdub and loop recordings with the head guard (`slotHeadGuard`), record sources, threshold arming with a 10 ms pre-roll, clock sync through `recordBuffer`'s `delay`, and the `recordState` and `takeWriteFailed` polls.
- Files and waveforms: `loadBuffer`'s start, `saveBuffer`'s region, the peaks files and their mover (`lib/engine/StrataWaveform.sc`, `lib/waveforms.lua`), random loads and fills (`lib/files.lua`); `buffers.data` version 2.
- Positions: the scan phase's `t_scanReset`, `scrubRate` and `scanHold` (`lib/engine/StrataPositions.sc`), jumps, loops, the scan hold's holders and the scrub glide (`lib/positions.lua`), playheads (`lib/playheads.lua`), bookmarks and 3.4's interface (`lib/bookmarks.lua`).
- UI: BUFFER's fields, waveform and heads, its keys on release, its arc rings; a position page on every grid layout, and a rotation per grid port (`grids.data`). Registries: `grain_restart`, `alt_release`, `menu_close`, `invariants`.
- Data files: `lib/data_files.lua` writes `scenes.data` and `buffers.data` through a checked `.part` and reads them with a parser, never `tab.save` or `tab.load`; scenes are format 5 and every PSET holds `strata_pset_format`.
- Memory: floors of 3 MB standard and 3.5 MB high, the all-buffer and synth -> buffer -> synth worst cases, recordings in the check; a copy ring per voice for a frozen input (`docs/notes/engine/memory.md`).
- Tests: 1189 Lua tests; the engine check has record, waveform and positions areas.

Before the release, three rounds of fixes landed on main: an audit of the script's state handling (#232-#258, #295), with the invariants harness (`S.register_invariant`, checked after every unit test); an audit of the engine's state (#259-#262) and CI's job timeouts (#225); and a whole-project code review's 236 issues (#300-#535) and the issues its fixes filed (to #559), landed as reviewed packages in batches, one pull request per batch (`docs/workflow.md`), with a final review and one fix wave. Their decisions are in `docs/decisions/3.3.md`.

See CHANGELOG.md and `docs/status.md`.

## Version 3.2.0 (2026-11-09)

The performance setting and one grain path (design: `docs/design/3.2-design.md`). The sound changes (every voice: pitch by rate, stepped per grain; synth and input voices: milliseconds of lookback, position spread as a backward offset); every new per-voice setting defaults to 3.1's sound, and a Pi 4 or CM4 on `auto` runs high and its FDN reverb (SETUP `standard` keeps the old one). Highlights:
- Engine split: `lib/Engine_Strata.sc` holds the class, its variables and a generic `alloc` and `free`; everything else is an area in `lib/engine/` (`strataArea<Name>`). The engine check runs per area (`test/engine_check/<area>.scd`).
- Performance: `lib/performance.lua` and `lib/engine/StrataPerformance.sc`; SETUP's setting, the engine's active file and `S.performance`. The high tier has buffers up to 300 s, 60 s of history, spectral freeze and an FDN reverb.
- One grain path: `\strataGrainRing` and `\strataGrainBuf`, built by `grainBody`, reading rings (`lib/engine/StrataRings.sc`) or slots; no `PitchShift` or spread delay, so the worst case falls from 6.9 MB to about 3.3 MB of the pool.
- Features, one module and engine area each: freeze (`lib/freeze.lua`), variation and scale quantize (`lib/variation.lua`, `setScale`), loop regions (`lib/loops.lua`), input history (`lib/history.lua`), the voice filter and sends (`lib/voice_mix.lua`), effect bypass (`setBypass`).
- Registries: `voice_params`, `scene_fields`, `source_change`, `param_filters`, `lfo_destinations`, `fx_params`. Scenes are version 3.
- Buffers: the `bufferSaveResult` poll; long files checked and saved through `yieldToCommands`.
- Docs: AGENTS.md slimmed to the rules; engine notes per check area, the old index files removed.
- Tests: 622 Lua tests.

See CHANGELOG.md and `docs/status.md`.

## Version 3.1.1 (2026-11-07)

A fix release on 3.1 (`release/3.1.x`), with no command, param or file format change:
- Engine: buffer writes (saves and scratch takes) yield to commands between chunks (`yieldToCommands`, `commandGap`), so a save no longer holds up the script's commands until it ends (#124; fixed on main for 3.2 by #126, the same fix).
- Tests: 462 Lua tests; the engine check sends a message during a save and requires it handled before the save ends.

See CHANGELOG.md.

## Version 3.1.0 (2026-11-07)

Playable from the norns alone (design: `docs/design/3.1-design.md`). No engine, command, param or scene format change; the one default change is LFO depth 25%. Highlights:
- Module split: `strata.lua` holds the entry points; every part of the script is a constructor module under `lib/` sharing `S`, with registries (`S.registry.pages`, `params`, `grid_layouts`, `start`, `cleanup`) so work packages own disjoint files. `init` runs `START_ORDER` steps (#73).
- Pages: eight page records (`UI_PAGES`), VOICE, SEQ and SCENES new; the header's page dots and `header_flash`; `S.lib.ui_flash` for the header and the hint row; `S.lib.ui_field_list`, `S.lib.ui_cursors` and `S.lib.ui_voice_rows` for row pages.
- Keys: K1 held as ALT (`S.alt_held`, `alt_action`, `S.key_press_alt`, a `long_press` hook for the fallback, removed in 3.2 once K1 was confirmed on hardware); fine adjustment on ALT+E3 (`FINE_DIVISOR`); center detents (`delta_with_detent`, `enc_param_delta`); lock as the UI name of `frozen` (`toggle_lock`); randomize undo (`UNDO_SECONDS` 5).
- Arc: `arc_ring_fill_bipolar`, ALT rings (`arc_alt_delta`, `arc_alt_redraw`), a per-page `arc_button`, `arc_whole_steps` carries forgotten on a page change; page rings in `lib/arc/<page>.lua`.
- Grid: pages and held keys per port (`S.lib.grid_core.page`, `S.grid_held`), `step_key` step levels, `scene_save_key` half-second holds through `on_hold`; fader and sources pages on the 16×8 and 8×16, pattern halves on the 8×8, copy/paste on the 16×16.
- LFOs keep their offset across on/off (`wrap_param_action`, part of #103).
- Process: changelog fragments in `changes/`, one notes file, user page and unit test file per page and grid layout, the US-spelling test, page renders (`test/render_pages.lua`).
- Tests: 462 Lua tests.

See CHANGELOG.md and `docs/status.md`.

## Version 3.0.2 (2026-11-05)

Fixes the whole-codebase review of 3.0.1, its final review and #5. No command, param or file format changes (one new poll, `bufferLoadFailed`). Highlights:
- Redraws: one 15 fps frame clock (`request_redraw()`, `draw_frame`), which also animates the LFO page; `redraw()` draws the file selector while it is open; `fileselect` is `require`d.
- Arc: `arc_ring_fill` (a ring at its maximum lights all 64 LEDs), MAIN rings through `param_fraction`, one followed arc on any port.
- MAIN voice list in ASCII (`+`/`-`, `list_name`); grid play/stop LEDs on all four columns; bipolar faders exact 0 at column 9.
- Scenes: the sequencer waits for a transition's end, bounded by its progress (`wait_for_scene_transition`, `SCENE_TRANSITION.next_step_due`); a fade ends on the data it started with; PSET loads start the sequencer one tick later; `tempo` follows `clock.tempo_change_handler` over `clock_tempo`'s range.
- Randomize and mutations in normalized space (`mutated_value`); the start-up clock checks voice 2 and is canceled in cleanup (`STARTUP`).
- Buffers: failed loads reported by `bufferLoadFailed` and undone per load number (`buffer_load_failed`).
- Engine: fixed `PitchShift` window and `maxGrains` 128, at most one live, one fading and one cutting grain synth per voice; Resonator gain and limiter; rate fix for files not at 48 kHz; fades before a played slot changes; pan for buffer and input voices; NaN guard.
- Tests: 210 Lua tests on stubs that follow norns and matron; the engine check runs with norns' 8192 KB pool.

See CHANGELOG.md and `docs/status.md`.

## Version 3.0.1 (2026-11-03)

Fixes the minor findings deferred from the 3.0 reviews. No command, param or file format changes. Highlights:
- Arc: every continuous ring sweeps its range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (512 ticks, half a revolution) through `arc_sweep_param`, following the warp; MAIN ring 2 drawn along the warp; LFO ring 4's carry reset on LFO or mode change; `arc_key` finds MAIN by index.
- BUFFER K2+K3 save flash (`buffer_page_flash`); held keys forgotten when the norns menu opens (`watch_menu_opening` wraps `_menu.set_mode`); omni pitchbend follows the selection.
- Buffer takes and loads settle on the engine's `bufferState` report (`finishing`, `settle_buffer_slot`, `settled_empty` for late reports, `BUFFER_SETTLE` fallback); `buffers_restored` engine-confirmed; missing files kept in `missing_path`.
- One full sync per scene recall, after the recalled params (`scene_recall_in_progress`); `voiceOn` density from `engine_param_value`.
- Engine: filter type crossfade (20 ms), grain-mode fade (50 ms), `slotChanges` guards against stop/clear and load races, loads apply on completion, grain synths placed by `startPlacedGrainSynth`, mirror off by default, amplitude crossmod for input-sourced voices, failed writes cleaned up and stale `.part` files deleted at alloc.
- Decisions: arc sweep 512 ticks; the write interleave keeps its per-frame loop (an array `lace` measured about twice as slow).
- Tests: 118 Lua tests; the engine check bounds every reply wait (`awaitReply`, 5 s) and the whole run (540 s).

See CHANGELOG.md.

## Version 3.0 (2026-11-03)

Adds sample and input sources, FX, LFOs, MIDI and a paged screen (design: `docs/design/3.0-design.md`). Highlights:
- Paged screen UI (MAIN, FX, LFO, BUFFER, SETUP; E1 selects, no acceleration) with arc pages that follow it.
- Master filter (`setFilter`) and stereo delay (`setDelay`) before the reverb; limiter moved before the saturator.
- Grain envelope shapes (`envShape`) and triggered grain mode (`grainMode`); `retrigger` carries velocity (`"if"`).
- Eight stereo 16 s buffers and the live input as per-voice grain sources (`setGrainSource`, `loadBuffer`, `recordBuffer`, `stopRecord`, `clearBuffer`, `saveBuffer`, poll `bufferState`); BUFFER page, arc buffer rings, grid 256 page 4.
- Buffer persistence: scratch takes, remembered paths in `buffers.data`, explicit timestamped save.
- Three global LFOs on norns' `lua/lib/lfo.lua`, modulating around stored values through `send_param_to_engine`; per-voice drift renamed `drift_update`.
- MIDI notes, velocity and pitchbend (`bend`) with per-voice channels; CC through norns PARAMS > MAP.
- Scene format version 2 with migration of version-1 files.

Deviations from the design: limiter before the saturator; K3 keeps start/freeze (no grain trigger); input-sourced voices' main param is grain size; LFO ceiling 10 Hz, LFO depth in percent, 48 ppqn plus send dedupe; one-slot-per-message `bufferState` encoding; `stopRecord` added; K2+K3 save gesture; scenes capture LFO mode and clocked rate as well as the free period; grain-side accent only for the input source (`accentAmt`); the input `\strataGrain` mirrors to the voice bus; `scratchDir` is an engine variable. See CHANGELOG.md.

## Version 2.1 (2026-11-03)

Whole-app review fix release. Highlights:
- `voiceOn` signature `"iffffff"` (freq was typed as a string and dropped); voices start with their full Lua state (`sync_voice_to_engine`).
- Pattern steps accent running voices with the new `retrigger` command instead of stacking synth chains.
- Grain pitch is real pitch shifting; its LFO drift is subtle and mean-reverting.
- Tempo param drives `clock_tempo`; 128v layout reachable; grid hot-plug fixed; 256 parameter page implemented as faders; grid LEDs stay current.
- Silent bus for unrouted mod slots; frequency modulation clamped above zero; FM/Sub clamped.
- Linear scene transitions; thorough scene validation; versioned, crash-safe scene file loading.
- Engine nodes ordered inside `context.xg`; resonator and reverb no longer double their output; drift amounts mean depth.
- Off-device test harness (test/).

See CHANGELOG.md for complete details.

## Version 2.0 (2025-01-24)

Major stability and code quality release focusing on bug fixes and defensive programming.

Critical bug fixes:
- Scene data validation prevents crashes from corrupted files.
- Scene sequencer position bounds checking prevents out-of-bounds access.
- Concurrent scene transition prevention via clock tracking and cancellation.

High priority bug fixes:
- Arc initialization race condition fixed.
- Mutation metro state synchronization in cleanup.
- 64-button grid pattern display corrected.
- Pattern/scene bounds checking added throughout.
- Scene transition nil access protection.

Code quality improvements:
- Named constants (NUM_VOICES, NUM_SCENES, PATTERN_LENGTH) replace magic numbers.
- Comprehensive error handling and validation patterns.
- Resource management with proper cleanup.
- Modulation signal clamping in SuperCollider engine.

See CHANGELOG.md for complete details.

## Version 1.0

Initial release with:
- 7 synthesis voices with granular processing
- Cross-modulation (3 slots per voice)
- Probability-based mutations
- Scene system with disk persistence
- Grid and arc integration
- Pattern sequencer

## How each release landed

The pull requests and waves of each release, as `docs/status.md` recorded them until 3.4.0. A release adds its line.

- 3.0 (sample and input sources, filter and delay, grain envelopes and triggered grains, LFOs, MIDI, paged screen) through PR #3, and CI through PR #4.
- 3.0.1, the minor findings deferred from the 3.0 reviews, through PR #7.
- 3.0.2, the fixes from a whole-codebase review of 3.0.1 (issues #10-#27), from a final review of those fixes (#46-#52) and #5, one pull request per issue (#28-#45, #53-#59, then the docs pull request that closes #52). CHANGELOG.md lists each fix with its pull request.
- 3.1.0, playable from the norns alone (`docs/design/3.1-design.md`): Wave 0, the restructure for parallel work (#62-#79, fixing #67, #68, #72 and #73 on the way); Wave 1, the shared UI, grid and arc interfaces (#80-#90, #94, and #93 for #91); Wave 2, twelve page, grid and arc packages built in parallel (#95-#108); Wave 3, the docs pass (#110), the follow-ups (#111), the final-review fixes (#115) and the release.
- 3.2.0, the performance setting and one grain path (`docs/design/3.2-design.md`): Wave 0, the engine split, the check per area and the Lua registries; Wave 1, the performance setting and the grain path; Wave 2, freeze, variation, loop regions, the voice mix and long buffers, built in parallel; Wave 3, one issue and pull request per remaining finding, the docs restructure and the release.
- 3.3.0, buffers as instruments (`docs/design/3.3-design.md`): Wave 0, the engine surface, the Lua scaffolding and the per-voice mix stage; Wave 1, recording, waveforms and files, and positions, engine and Lua, built in parallel; Wave 2, the BUFFER page, its arc rings and the four grid layouts' position pages, with the fixes #199, #207-#210, #217, #218 and #221 on the way. Then three rounds of fixes: the state machine fixes (#232-#258, #295) with the invariants harness (`S.register_invariant`, every module's state invariant checked after every unit test); the engine state fixes (#259-#262) and CI's job timeouts (#225); and the whole-project review's fixes (#300-#559, 29 reviewed packages landed in batches, one pull request per batch, then a final review and its fix wave). Wave 3, the release.
- 3.3.1, a fix release: a clock-synced recording follows a tempo change and starts on time while the engine is busy (#565, #567; `recordBuffer` gains a ninth argument, `sent`, so one norns restart), `buffers.data` written once per burst of changes, 0.1 s after the first (#566), the engine check's freeze precondition and default timeout (#569, #570), and the design docs for 3.4 and 3.6 (#229, #555).
- 3.3.2, page randomize (#557): ALT+K2 randomizes on MAIN, VOICE, SEQ, FX and LFO (the section under the cursor on VOICE, FX and LFO), acting on release, with one undo on the same key; SEQ's keys swapped, VOICE's and LFO's reset moved to ALT+K2 held. No engine file changed. Also #575's check tooling (the 3.13 image's python3, the record check's sender timeout).
- 3.4.0, modulation and sequencing (`docs/design/3.4-design.md`): Wave 0, the script's hooks, the scene format and the engine's modulation skeleton; Wave 1, the engine's fast modulation, the LFOs, scene banks and names, the sequencer, macros and scatter, gestures and quantized actions, the morph, the matrix, the input level and mute and solo, built in parallel and landed in three batches; Wave 2, the MOD page, SEQ's edit view and the step editor, and the grids; then the XY morph, a whole-release review split by area (#595-#641, each finding its own issue and fix, in a fix wave of seven groups), and, landed after the release branch was built, #578 (`bufferState` reports numbered per load, an engine change), #588 and #650 (the clock stub), #642 with #644-#646 (the send budget counts exactly what reaches the engine), #649 (its exception for discrete switches, documented), #653 (morph crossings at most once per 0.3 s), #647 and #648 (the matrix's sends, one side-file helper), #651 (the recorders' live file written soon after each change), #652 (the engine check's areas independent of their order) and #654 (the budget's flush clock); then the release. One new engine file and four changed, so one norns restart.
- 3.5.0, polyphony and MPE (`docs/design/3.5-design.md`): Wave 0, the Lua hooks, the engine's notes area as stubs with every voice SynthDef measured, and the design's findings (#662-#666), as PR #670; Wave 1, the note controls, the allocator and the MPE parser, as PR #672 (closing #669); Wave 2, the note lifecycle, MIDI, expression, sequencer chords, SEQ and the arc, MAIN and SETUP, the envelope times and the engine check runner's fixes (#671, #673), built in parallel and landed as PRs #674, #676 and #678; README.md's version line (#675) outside the plan; then #211's, #677's and #679's fixes (PR #681) and the release.
