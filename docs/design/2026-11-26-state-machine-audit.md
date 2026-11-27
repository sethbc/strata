# Strata state-machine audit, November 26, 2026

This audit describes the released v3.9.0 runtime at `d8621dd5`. Its recommendations and observations below are dated November 26, 2026. It builds on the [3.9 audit](3.9-state-machines-design.md). The [archived implementation plan](2026-11-26-state-machine-plan.md) records the proposed order, files and acceptance cases.

**Recommendation.** Fix ownership at four boundaries where Strata can say one thing and do another. A file's writer owns publication until the OS can no longer replace that path. During a running session each accepted save owns its filename and settings until its outcome is known. A physical press owns its release. A PSET read or device reconnect must reconcile the running owner with the newly requested configuration. Start with file publication. On a real desktop scsynth a newer save reported success and an older save subsequently replaced its WAV.

## Where to look

| Area | Historical rows reconciled | Current owners, entry points, checks and history |
|---|---:|---|
| Voice lifecycle, node placement, modulation, notes, buffers, recording, output files and FX in SuperCollider | 22 | [Engine inventory](2026-11-26-state-machine-facts/engine.md) |
| Buffer lifecycle, sample settings, scanning, selection, positions and saves in Lua | 12 | [Buffer inventory](2026-11-26-state-machine-facts/buffers.md) |
| Scenes and persistence, sequencer, modulation and voices in Lua | 47 | [Musical inventory and later sequencer changes](2026-11-26-state-machine-facts/music.md) |
| UI, grid, arc and external I/O | 32 | [Surface and I/O inventory, including device scripts](2026-11-26-state-machine-facts/surfaces.md) |

The ten historical summary tables contribute **113 rows**. Some rows cover several protocols, such as the last row of the buffer inventory. Some describe both ends of the same interaction. After the first part of 3.9 landed at `548e5b2b`, 29 runtime paths changed by the release tag. The added owners include independent lane cursors, held step values, pattern letters and their bar queue, loop and roll ownership, the grid step view, and the high-tier reverb's live/frozen/bypassed transitions. See also the [grid rework](3.9-grid-sequencer-design.md) and [reverb design](3.9-reverb-freeze-design.md).

For this audit a machine has history that changes what its next event does. An option label, synthesis formula, controlspec or draw routine that only reads its inputs belongs with the owner it projects. For example, input history in `lib/history.lua` is a registered value, the ring writer and head are engine state, and the playhead is a Lua estimate. A player's press, its queued effect and its audible result can legitimately have three different lifetimes. The inventory names the layer at which each result was observed. A finite review cannot prove that every sequence of platform events is safe.

### Checks on the inventory

At the tag, 59 Lua notes files have a `## Machines` section. Within those sections are 82 named entries and 61 exact `State | Event | Next | Effect` table headers. The harness connects registered invariants to entries and executes selected transition tables and seeded walks. The save, same-coordinate release and silent-read examples below fall *between* owners that can each pass their own invariant.

The following groups account for the runtime delta after the first machine build. File names are relative to `lib/` except for the script entry point.

| Changed paths | Question checked |
|---|---|
| `lanes.lua`, `loop_roll.lua`, `pattern_letters.lua`, `sequencer.lua`, `positions.lua` | Who advances the real play position, who owns the temporary override, and which release or bar ends it? |
| `grid/core.lua`, `grid/pane.lua`, `grid/pages/{patterns,voices}.lua`, `arc/seq.lua`, `pages/{seq,voice}.lua` | Which physical press or modal opener owns the gesture, and what position/range does the player see? |
| `scenes.lua`, `mutation.lua`, `voice_presets.lua`, `data_files.lua` | Which blocks survive a recall, release or undo, and can the reader hold the largest file the new blocks produce? |
| `engine_sync.lua`, `envelopes.lua`, `params_setup.lua`, `voices.lua`, `state.lua`, `strata.lua` (root) | Which owner drives the audible gate and which writes count as a hand, scene, sequence or engine sync? |
| `engine/Strata{Effects,Modulation,Performance,Reverb}.sc`, `fx_hold.lua`, `pages/{fx,setup}.lua` | Which tier can freeze the reverb, how is it released on bypass or reload, and who budgets the persistent delay lines? |

To repeat the scope check, use `git diff --name-status 548e5b2b..d8621dd5 -- strata.lua lib extras` and compare the numbered rows in the ten historical fact files with the four current inventories. The supplemental client inventory covers the iii grid and arc, E16 and TouchOSC, whose source did not change in this range.

## Evidence and decisions

| Trigger on v3.9.0 | Observation and control | Explicit transition to build |
|---|---|---|
| One slot, six accepted whole saves, constant timestamp, no published files yet | Filenames ended in 1, 2, 3, 4, 5, 1. Six injected success reports forwarded four settings snapshots. A single success already copies its send-time settings in the existing suite. | Reserve each admitted request until its terminal result. Bound admission, identify the four outstanding results across lost notifications and show a refusal before sending a command. |
| Two writes to one WAV, first OS rename held past the wait | The registered commands on scsynth published 5,513 frames and then 11,025 after the older writer resumed. Releasing the first rename inside the wait preserved order. A retired engine also overwrote its successor's file. | Establish one right to replace a pathname across the mover, fallback and engine teardown. The acceptance oracle reads the file after every outstanding writer has resumed. |
| Equal-length loads with different amplitudes, and two analyses with different markers | The audio remained at .750 but the final peaks returned to .250. A newer onset pass reported success with marker 8192, then the old failed pass left marker 4096. The healthy onset control published the original marker at 4096. | Reuse the same publication rule. Keep the three callers' different completion rules for audio feedback, latest waveform and numbered analysis. |
| HD released on a different grid view and the same physical coordinate immediately reused | On 128h, after half a second the scan was still held. An adjacent-coordinate control released it. On the 256, an older pane release canceled a newer loop anchor. | Use the core's per-press liveness token and identify the releasing pane. Preserve intentional cross-pane two-key gestures. |
| Banked overlap slices 4 and 20 on different panes, same logical cell | Letting go of both keys left slice 4 sounding. Different columns released both. A lost bookmark release also left its LED bright while a separate Store hold was valid. | Give the note allocator and the grid release record matching physical identities. Give the bookmark indication its own release lifetime. |
| Last scan holder removed while advancing that voice's estimate throws | Holder gone, scan still held, zero release sends. Healthy unplug sent exactly one. The periodic tick's protection of other voices did not cover this call inside the release. | Estimate the old position under fault containment, then commit the holder edge and send it. Keep fault reporting and all other holders. |
| TXo switches from envelope to pitch under queue pressure or loss of transport | Normal trace activated and deactivated output 3. Full queue, unplug after admission and loss of leadership each left only activation. A silent PSET loading pitch also missed deactivation. Blindly replaying a gate-style owed off can turn off an envelope the player has since reselected. | Track the configuration still owed to each output. On readiness, compare it with current routes and send the required final mode in order. Crow handoff is the last observable software event. |
| Silent PSET changes scene transport, playing chain or random-sequence clock | Scene and chain clocks each stayed in their old state in both directions. At beat 8.5 a new random division advanced once too often. Shortening then expanding before a tick restored step 11 where a normal read kept step 1. | Reconcile actual transport/deadline, clock basis and stored position once after loading. Preserve continuity whenever the effective setting is unchanged. |
| Silent PSET changes MIDI port, channel routing, note-off policy or split layout | New port could not play, or a note remained owned under the old mapping. Normal reads passed. Old device, general mode and MPE-layout changes already have different reset behavior. | Apply the narrow existing reset for the changed ownership domain. An unchanged read during a held note must keep its owner and negotiated bend range. |
| Silent PSET moves a held external output route | The crow stub last received 5 V even after key-up. Selecting none for nb still routed a new note to the old player. ER-301 and TXo kept gates until key-up, Just Friends and W/syn kept logical ownership, and MIDI out settled correctly. | Release the previously applied target, using its recorded line or player, before activating the new route. Keep each adapter’s gate, one-shot and PSET-stop rules. |
| Playing chain last linked S1, range changed to empty S2 | SEQ still showed S1 after a bar. Cycling the switch showed the empty status. The historical slot is still needed to select the next playable scene. | Derive empty-range status from current playable scenes while keeping the historical cursor and deadline. |

The Lua observations used the public input paths with norns stubs, except where a fault or report was explicitly injected. The engine observations used sclang 3.14.1 and a desktop server with controlled rename delays. Neither proves how often a player will meet the condition on norns. The [reproduction guide and fixtures](2026-11-26-state-machine-facts/probes.md) let another checkout run the critical cases. The inventory records controls, limits and source-level follow-ups.

## What to make explicit

- **For the player**, releasing a key ends its note, a saved WAV still contains the take reported as saved, and the status next to a control tells what it will do. A save request the system cannot track gets an immediate, distinct busy message. A silent PSET load is primarily a script/mod path. Ordinary PARAMS recall remains a regression control.
- **For a developer**, keep each authority local. A holder set owns the hold, the note allocator owns sounding notes, the transport owns its deadline, and a file operation owns the part it can still publish. Where the program truly needs history, store that one fact explicitly, such as the clock option a previous beat count belongs to. The effect column of a transition table must say what was sent, released, published or retained.
- **For an agent**, each owning module gets its transition entry next to its existing invariants. Each entry points to a named test and any corresponding consumer across Lua, SC, a device script or the filesystem. Use the existing table and seeded-walk helpers where the model has several events. A simple edge needs a paired regression and control. The index above and commit anchors let a reviewer start at the current authority and recover why the exception exists.

The 3.9 decision to derive state where possible still holds. Replaying every param action could reset notes and phases and send duplicate engine messages. A general state-machine library would introduce another dispatch path into code with beat deadlines and callbacks that query their owner mid-transition. Documentation alone has already been tried at several of these boundaries. The proposal changes the event paths with reproduced failures and records explicit transitions at their owners. The high-tier reverb table, posted-clock retirement, slot rollback, mute/solo, quantized waits, note pool and current scene format remain compatibility controls.

### Session boundary for saves

The proposed save window and replay recover a lost result while Lua and its engine are running. During teardown, already confirmed and persisted sample settings keep their usual lifetime. An old writer may have committed a WAV while its settings snapshot still exists only in the retiring Lua session. Such a save is unconfirmed and can survive without those settings. The plan tests that distinction and rejects a late old completion against a new save with the same number. Recovering metadata across a crash would require a durable journal. Physical ordering is a separate obligation: an old writer must lose the ability to overwrite a successor’s successful WAV.

## Residual limits and release evidence

The full ordinary Lua suites are a baseline. The focused counterexamples deliberately exercise event orders the baseline accepts or omits. The software evidence ends at the crow send, the stubs' control events and the software audio server. Actual TXo envelopes, performance under SD-card stalls, simultaneous grid holds on physical devices, audible phase continuity, and the Lua mirror of a failed engine voice start belong in [the 4.0 hardware check](https://github.com/sethbc/strata/issues/6). The proposed plan lists the pass conditions. No change to the released engine or script was made in this audit.

## What landed after the audit

- The original 47 issues (#1068 through #1114) closed. The WAV publication fix protects a successful save from a delayed older writer. The multichannel normalization fix measures the channels Strata plays. [WAV publication](https://github.com/sethbc/strata/pull/1140) and [multichannel peaks](https://github.com/sethbc/strata/pull/1184).
- An integrated review of `7890efff` recorded 49 findings, including recording persistence, sequencer catch-up and external gates. Seven priority fixes and two additional test-harness fixes landed by `032c1ae3`. At that revision, both Lua runtimes passed 6,113 tests. [Changes between the two reviewed revisions](https://github.com/sethbc/strata/compare/7890efff...032c1ae3).
- The November 27 release review tracked 57 issues, including the 42 carried over from the integrated review. Specialist reviews also identified an unsafe preset backup, a master-drift test that accepted silence, and duplicate scene validation during preset reload. The four release blockers and a related MIDI learn defect landed together. Both Lua suites passed 6,124 tests on that branch. [Release review issues](https://github.com/sethbc/strata/issues?q=is%3Aissue%20label%3Areview-2026-11-27-board) and [release-blocker fixes](https://github.com/sethbc/strata/pull/1277).
- Later tests covered a delayed WAV rename across an abrupt sclang restart and different save outcomes for the same request number in two buffer slots. The norns poll-registry reload fixture also joined CI. [Save regression tests](https://github.com/sethbc/strata/pull/1285).

The software checks ran off-device. Open device measurements and the 4.0 hardware checklist are tracked in [project status](../status.md).
