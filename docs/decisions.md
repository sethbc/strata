# Strata development decisions

The decisions taken during development, one section per release. Each was taken during development without a design review, and lists what it costs if it was wrong. Reverse any of them in a normal pull request.

## 3.0 (sample sources, FX, LFOs, MIDI, pages)

- **Limiter placement:** the master limiter sits *before* the tanh saturator, where the design said "after". After it, the limiter could never act. If wrong: a one-line revert.
- **Input voices' main param:** for input-sourced voices, E3, arc ring 2, the MAIN label and the first fader control **grain size**. Randomize, mutate and drift touch only grain params, because synth and buffer params are dead for live input. If wrong: revert one branch of `main_param_entry`.
- **LFO rate:** LFOs step 48 times per beat (`LFO_PPQN`), and a send is skipped when the value moved less than 1/1000 of the range. This bounds the message rate; the cost is slightly steppier fast LFOs. Since 3.3 the 1/1000 is measured along the destination's warp (#406): an exponential range in octaves (7.97 cents on a voice's freq, where 1.98 Hz was up to 68 cents at 50 Hz), a linear one as before. If wrong: one function, `destination_position` in `lib/lfos.lua`; a slow exponential LFO sends about seven times as often as with the linear measure (131 sends a cycle in #406's probe, against 19).
- **Buffer-length poll:** the `bufferState` poll sends one float per slot (`slot * 100 + seconds`), because matron's data polls only take blobs. It could be replaced by eight polls later.
- **`stopRecord` added:** K3 on the BUFFER page can stop a recording early, as the design requires.
- **Save gesture:** K2 acts on release (load a file); holding K2 and pressing K3 saves.
- **K3 on MAIN:** it keeps start/freeze. Triggered grains fire from pattern steps and MIDI only.
- **Grain synth stereo:** `\strataGrain` uses two mono GrainIns plus Balance2, like `\strataGrainBuf`. Synth and input voices became about 3-6 dB quieter (check on hardware, #6).
- **Source switching:** replaced synths get a kill fade (50 ms), so fast scrolling can't stack them up.
- **Re-gate during release:** a MIDI note during a voice's release re-opens its synths instead of creating new ones.
- **Smaller calls:**
  - scenes also store each LFO's mode and clocked rate;
  - the source param tells the engine even for a stopped voice;
  - the scratch-take folder is an engine variable, so tests never write into `~/dust`;
  - the test stubs mirror the real norns libraries (numeric param types, LFO depth in percent).

## 3.0.1 (minor findings)

- **Arc ring speed:** every continuous ring on MAIN, FX and BUFFER sweeps its whole range in half a turn (512 of the arc's 1024 ticks). This replaces "tune on hardware"; retune `ARC_TICKS_PER_SWEEP` after #6.
  - **Changed in #552 (2026-11-10, at the maintainer's request):** the speed was halved, to a full turn (1024 ticks), because half a turn made fine settings hard to reach.
- **Engine-confirmed buffers:** a recording or load shows as loaded only once the engine reports its length. A 0 s report only counts 1 s after the change, and a late report with audio is still adopted. A finishing take shows `...` and ignores K3, with a 5 s fallback.
- **Missing sample files:** if a remembered file is missing at startup, its path is kept, so a sample on an unmounted drive comes back later.
- **Input crossmod:** input-sourced voices get amplitude crossmod (`modLevel`). Frequency crossmod is ignored for live input.
- **Menu-held keys:** keys held when the norns menu opens are forgotten. This uses a wrapped `_menu.set_mode`, restored in cleanup, with the 10 Hz check as a fallback.
- **Interleave:** the save interleave stays a per-frame loop. An array `lace` was measured about 2× slower.

## 3.0.2 (review fixes)

- **Hardware-only checks stay on #6.** Real-time memory on the device, the 44.1 kHz pitch on the device, write-timing jitter, xruns, glyph widths and arc-spin CPU cannot be settled off-device; the code bounds each one and #6 lists what to measure. If wrong: a hardware finding becomes a new issue.
- **The file selector owns the screen while open:** `redraw()` draws the selector instead of doing nothing, so the selector is still there after a K1 menu visit. If wrong: one extra selector redraw now and then.
- **ASCII voice-list marks:** the MAIN list shows `+`/`-` and short names (`reso`, `karp`, ...) instead of `●`/`○`, because the glyphs' width on the norns font is unconfirmed and ASCII fits with 8 px to spare. If wrong: the dots are preferred; a one-line change if hardware shows they render one character wide.
- **Bounded sequencer wait:** the sequencer waits for a transition's end, but cancels one whose next step or end is `SCENE_TRANSITION.overrun_seconds` (1 s) overdue, measured from the fade's progress (`next_step_due`), not its start, so a lost or errored fade can't freeze the sequencer. If wrong: a fade step that really takes over 1 s on a busy CM3 gets canceled; measure on #6 and raise the bound.
- **One followed arc:** Strata follows one arc; a second one is ignored while it is connected, and unplugging the followed arc moves to the next port that holds one, in the order norns clears its ports. If wrong: none in the usual one-arc setup.
- **Engine stub param names:** `setVoiceParam`/`setGrainParam` names are checked against every SynthDef control, including the engine-managed ones (`gate`, `out`, `kill`, ...). If wrong: Lua sending an internal control name isn't caught; a stricter list is a follow-up.
- **Group-size check:** a group must be followed by exactly its size in params and then a group, a separator or the end. If wrong: a future layout with ungrouped params right after a group needs a separator first.
- **Engine-check script fails fast:** a compile error or a hang ends the run (its own timeout, 1200 s by default for a full local run; CI passes 570 s, below its 600 s) instead of holding the machine's scsynth port. If wrong: a very slow machine needs `$ENGINE_CHECK_TIMEOUT` raised.
- **Rapid switches cut hard:** a new source switch (or stop/start) frees at once the voice's synths still in their 50 ms kill fade, so a voice never holds more than one live, one fading and one cutting grain synth. If wrong: a click from a synth cut within 50 ms of silence; listen on #6.
- **Quiet messages to synths that can end on their own:** messages to voice, grain and mod synths (and record synths) that may free before they arrive go in `/error -1` bundles (`sendToSynth`), so neither the console nor the engine check sees a `FAILURE` for them; messages to the persistent filter, delay, reverb and master nodes stay plain. If wrong: a real error in one of those voice-synth messages is no longer printed; the engine check's synth-count and level checks still catch its effects.
- **Fixed `PitchShift` window and 128-grain tables:** the window is 0.1 s whatever the grain size, and `maxGrains` 128 still covers Lua's largest overlap (0.5 s × 200 grains/s; a Lua test keeps it so). If wrong: pitch-shifted voices at large grain sizes sound different. 3.2 removed the grain `PitchShift` (pitch is the grain rate), so only the 128-grain tables remain of this decision.
- **Resonator gain and limiter:** a fixed gain cut plus a limiter on that voice only, with no make-up gain elsewhere; voice 1 as a crossmod source became much weaker. If wrong: patches that relied on the old strength modulate less; listen on #6.
- **Pan on the 256 fader pages** for buffer- and input-sourced voices, now that their grain synths pan. If wrong: one more fader page entry.
- **Normalized randomize and mutation** applies to Lua's randomize and mutation of synth and buffer params. Grain size, pitch and spread and the Lua drifts already use linear specs and are unchanged; the engine's tape drift is untouched. If wrong: none.
- **Synchronous decode check on load:** a load decodes the file before reading it, an estimated 0.2 s per FLAC on a CM3, which stalls engine commands briefly during a load the user started. A file may decode up to `loadShortfallFrames` (4096 frames, one FLAC block) short of its header. If wrong: measure on #6; move the check off the command path if the stall is audible.
- **A failed instant recall keeps the previous scene current**, so the header shows what is really loaded. If wrong: none.
- **The test clock follows matron:** tie order (sleeps before syncs, event slots in order) and the 100-slot limit match matron's scheduler, so tests see the order norns runs clocks in. If wrong: tests that depend on tie order need updating along with the stub.
- **The `tempo` param takes the clock's range** (`clock_tempo`'s 1-300 BPM), so any clock tempo is captured and recalled. If wrong: none.
- **Docs layout:** the status file and the 3.0 design live under `docs/` (`docs/status.md`, `docs/design/3.0-design.md`), and the old implementation plans were removed. If wrong: links to the old paths break; git history keeps the files.
- **3.0's features are described as Strata's own**, with no reference to the earlier, unreleased script they were first sketched for. Git history, commit messages and old pull request titles keep their wording, since rewriting them would mean force-pushing the protected `main`. If wrong: none; the name survives only in history.

## 3.1 (playable from the norns alone)

From the 3.1 design's "Cost if wrong" and the calls made while building it:
- **K1 held as ALT:** norns hands K1 to a script only after its menu hold (0.25 s), so ALT is always a hold. Confirmed on hardware, so the long-press fallback (0.6 s) was dropped and its unused hook removed (#159); every ALT+K2/ALT+K3 action still goes through `alt_action`. If wrong: a hold timer on K2/K3 that calls `alt_action`, and press actions moved to release where a long press must not also run them.
- **MAIN's K3 starts and stops** the selected voice; lock moved to ALT+K3 and randomize to ALT+K2. If wrong: a stopped voice is one press from running again, and each page's keys are one function.
- **Eight pages:** E1 travels further (seven page steps end to end, at 4 ticks per page). If wrong: reorder `UI_PAGES`, one line.
- **BUFFER's E2 picks a buffer, not a voice:** the selected voice comes from MAIN or VOICE, and every BUFFER key acts on the cursor's buffer. If wrong: ALT+E2 could pick the voice instead of the field cursor.
- **Lock is a UI name only:** the state, the code and the scene field stay `frozen`, so scenes need no migration. If wrong: none; the 3.2 audio freeze gets its own field name.
- **The only default change is LFO depth 25%:** new LFOs are audible when turned on; scenes keep their stored depth, and scene files without LFO settings recall silent LFOs. If wrong: one constant.
- **No new scene fields in 3.1:** the LFO offset is kept across on/off (`wrap_param_action` in `lib/lfos.lua`, #103 step 1), but scenes don't store it until 3.2. If wrong: recalls keep whatever offset is set.
- **Fine adjustment is a tenth of the raw step, on ALT+E3 only;** a param's own `controlspec.step` still limits it, number and option params keep whole steps, and the arc has no fine mode. If wrong: `FINE_DIVISOR`, one constant.
- **Center detents hold for 3 encoder detents or 24 arc ticks** after a change reaches or crosses 0, and for at most 1 s, so a hold left from an old turn never swallows a later one. If wrong: `DETENT`'s three values.
- **The arc button acts per page** (start/stop, play/stop, record/stop, recall, LFO on/off; nothing on FX and SETUP), not always as K3: on LFO, K3 selects the next LFO. If wrong: one `arc_button` field per page.
- **VOICE's whole-step rings step one value per 20 ticks** (choices and numbers), like the LFO page's clocked rate. If wrong: retune on #6.
- **Grid scene saves need a half-second hold**, so a stray press never overwrites a scene. If wrong: `GRID_HOLD`, one constant.
- **The 8×8's column 1 blinks per quarter note** (every 4 steps) while the other half plays, rather than every step, which would strobe at 8 Hz. If wrong: one line.
- **MAIN cuts a long voice name to fit its row** (`fit_text`, so `RESONAT` on hardware), because the source sits on the next row, where `[T]` would collide with a longer name. If wrong: a short display name in `MAIN_PARAMS`.
- **SEQ's playhead animates through the frame clock, screen only,** so a connected arc doesn't redraw at 15 fps while the patterns play. If wrong: none.
- **Built as parallel pull requests:** Wave 1 ran as batches of separate pull requests instead of one serial package, and Wave 2 as twelve packages at once, each owning disjoint files (AGENTS.md, "Working in parallel"). Parallel pull requests merged `main` and kept both sides of registration conflicts. If wrong: rebase conflicts within a batch, and `main` carried a partly built 3.1 between merges (never tagged).
- **Merged names win:** later work follows the module names already merged (`S.lib.ui_text`, `S.lib.grid_core`, ...) and never renames merged code to match a plan. If wrong: none.
- **The start registry** (#73) came into Wave 1, so each module registers its start step beside its cleanup step and `init` never changes. If wrong: a later package re-homes init pieces.

## 3.2 (performance setting, one grain path)

The design's five decisions, its calls and its own "Cost if wrong" list are in `docs/design/3.2-design.md`. These are the calls made while building it:
- **3.2's restructure merged after 3.1.0 merged:** the engine split and check split waited for the 3.1.0 release, so 3.1 shipped the engine it was tested with. If wrong: Wave 0 landed an hour or so later.
- **An area's commands keep their name and format, not their order:** matron and every check address commands by name. If wrong: none observable.
- **Nodes are freed before buses and buffers** through a `stop` phase on every area, added to the split itself because no later package may edit `lib/Engine_Strata.sc`. If wrong: one more phase key.
- **Engine and Lua read the performance setting the same way:** invalid lines are skipped, so a repeated key keeps its last valid value and the two can never disagree. If wrong: none.
- **SETUP marks a pending tier against the setting this start used,** not the running tier, and shows a note row rather than one long line (it did not fit the screen). If wrong: one comparison, and text on SETUP.
- **An unknown key in a scene's extras makes the scene invalid,** as an unknown `params` key does. If wrong: a scene from a later release, or edited by hand, is refused.
- **The grain path carries `bufScan` and a neutral `ringScanOffset` from the start,** because synth hold needs them and freeze does not own the grain SynthDefs. If wrong: one unused control.
- **A frozen synth voice's scan moves back through its ring,** as design §3 says, and frozen grains start half a second before the freeze point so no grain crosses the seam into 4 s-old audio. If wrong: freeze sounds half a second behind; `ringScanOffset`, which adds `grainMaxSeconds` while frozen.
- **`source_change` hooks run before the voice sync,** so a switch sends no stale `freeze` 1 and has no 60-110 ms dip. If wrong: the hook order changes for any later hook.
- **Spectral freeze has a dither about 100 dB down in its analysis,** against a buzz on digital silence. If wrong: a noise floor at -100 dBFS; `spectralDither`, one method.
- **A buffer voice quantizes around the rate it plays,** a design amendment, so MIDI notes and randomize transpose it without shifting the whole scale. If wrong: a behavior the design did not name; `bufRate`'s handler in the scale area.
- **A voice's `quantize` loads ahead of its `freq`** (`add_first`, #125), and so sits above `freq` in PARAMETERS, so a PSET restores every voice's pitch exactly. If wrong: one param out of its group; without it, a rare semitone offset after a PSET load.
- **The VOICE page's variation section comes after mix,** so no existing section moves. If wrong: one field in the record.
- **FX K3 toggles the delay's and reverb's bypass and keeps the mix;** on the filter it still turns the mix off and back on. If wrong: one page's key table.
- **The three-type voice filter stays;** the lowpass-only fallback was held for a failing high floor, and the floor held. If wrong: about 88 KB of the pool at the worst case (4.2 KB per grain synth).
- **Each grain synth has an 80 KB limit in the check,** 5 KB over the largest measured. If wrong: a later package raises one number, with its budget.
- **A long file's load is dropped only by a record, clear, stop or later effective load,** not a later failed one, since Lua's `bufferLoadFailed` undo restores the earlier load. If wrong: engine and Lua disagree on a slot after a failed second load.
- **The design's §2.7 is corrected from measurements** at 1b and again at release: about 50 KB per note stream during 3.2 and about 72 KB as released. If wrong: one paragraph that 3.5 plans from.
- **#131 is handled as a platform limit:** less allocation in the long-file paths, a soak test, the rules in AGENTS.md and a device check in #6; no fix is asked of SuperCollider. If wrong: a new crash on norns reopens it, and #6 section 6 is where it shows.
- **Nothing ships as "known and accepted":** each finding left at the end of 3.2 got its own issue and fix, so the list is gone from `docs/status.md`. If wrong: a longer release.
- **Docs restructure:** AGENTS.md replaced CLAUDE.md with no stub, the decisions moved here, and the notes indexes were removed with every reference. If wrong: a link in an old pull request or a tool that expects CLAUDE.md; the old files are in git history.
- **No tag until the hardware check:** the 3.2.0 pull request prepares the release, and the tag follows #6. If wrong: the release waits on one session with the hardware.
- **#6 stays essential checks only, about 40 minutes:** the plan's measurement items (CPU at density maximum, the 300 s save time, the FDN against `FreeVerb2`, the 126 biquads on the CM3, triggered-mode feel) are not added to it. If wrong: a CPU or timing problem shows up later in use.
- **The arc stays live while the norns menu is open** (#169), like the grid: norns' menu takes only the screen, the keys and the encoders (`lua/core/menu.lua`), so arc turns still reach the script and the rings show their params (an arc turn, PARAMS, a CC map) at once; the screen stops because the menu owns it. If wrong: skip `arc_redraw` in `draw_frame` while `norns.menu.status()` and redraw the arc as the menu closes; an arc turned in the menu would then edit without feedback.
