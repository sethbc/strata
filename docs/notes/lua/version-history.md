## Must not break

- Each release gets a short entry here (highlights only). CHANGELOG.md holds the full list and `docs/decisions.md` the decisions.
- Entries describe a release as it shipped. Do not rewrite old entries to today's names or layout.
- The docs check reads this file (it covers every file under docs/notes/): every repo path it names in backticks must still exist, and every `engine.<name>(` must name a command the engine has. Name commands without `engine.` and parentheses (`setFilter`), and name a file that has since moved by its plain name.
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
- Per-scene naming/tagging system
- ~~MIDI integration for external control~~ ✓ Implemented (v3.0 - notes, velocity, pitchbend; CC via norns PARAMS > MAP)
- ~~Sample buffers and live input~~ ✓ Implemented (v3.0 - per-voice sources)
- ~~Global LFOs~~ ✓ Implemented (v3.0 - three, on norns `lua/lib/lfo.lua`)
- Engine-side LFOs (above the Lua library's 10 Hz ceiling)
- ~~Buffer waveform display on the BUFFER page~~ ✓ Implemented (v3.3 - peaks files, `lib/waveforms.lua`)
- Tempo-synced delay times
- Undo/redo for parameter changes
- Parameter automation recording

The agreed order of the next releases is `docs/design/3.1-3.6-roadmap.md`.

## Version 3.3.2 (2026-11-11)

Page randomize (#557; design: `docs/superpowers/specs/2026-11-11-page-randomize-design.md`). ALT+K2 randomizes on MAIN, VOICE, SEQ, FX and LFO (the section under the cursor on VOICE, FX and LFO), acting on release (a quick press under 0.5 s; held past it, the page's hold action), with one undo for the whole script on the same key. SEQ's ALT+K2 randomizes and ALT+K3 clears; VOICE's and LFO's reset to default is ALT+K2 held. No engine file changed. See CHANGELOG.md and `docs/status.md`.

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

Before the release, three rounds of fixes landed on main: an audit of the script's state handling (#232-#258, #295), with the invariants harness (`S.register_invariant`, checked after every unit test); an audit of the engine's state (#259-#262) and CI's job timeouts (#225); and a whole-project code review's 236 issues (#300-#535) and the issues its fixes filed (to #559), landed as reviewed packages in batches, one pull request per batch (`docs/process/agents.md`), with a final review and one fix wave. Their decisions are in `docs/decisions.md` (3.3).

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
