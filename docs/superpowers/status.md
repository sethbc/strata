# Strata development status

Last updated 2026-11-03, after Strata 3.0.1 (the deferred minor findings from the 3.0 reviews). This file is the hand-off between machines and sessions: what was decided, what is still open, and where the details live. Update it at the end of each piece of work.

## Where things are

- **Released on `main`:** 3.0, which brought in Confluence's features through PR #3, and CI, through PR #4. 3.0.1 lands through the `minor-fixes` pull request.
- **CI:** `.github/workflows/test.yml` runs two jobs, `lua` and `engine`. `main` is protected:
  - every change goes through a pull request, with no approvals required;
  - both jobs must pass on a branch that is up to date with `main`;
  - the rules apply to admins too;
  - force pushes and deleting `main` are blocked.
- **Design and plans:**
  - `docs/superpowers/specs/2026-11-03-confluence-features-design.md`: the 3.0 design, still the reference for behaviour.
  - `docs/superpowers/plans/2026-11-03-confluence-features.md`: the 3.0 plan.
  - `docs/superpowers/plans/2026-11-03-minor-findings.md`: the 3.0.1 plan.
- **Running the checks locally:**
  - `lua test/run.lua`, `luajit test/run.lua` and `lua test/sync_check.lua`.
  - `test/run_engine_check.sh` needs SuperCollider and a norns checkout at `~/src/norns` (`git clone https://github.com/monome/norns`; CI pins commit `227aa044`).
  - Run only one engine check at a time on a machine: each one boots scsynth on UDP port 57110.

## Open items

- [#6](https://github.com/sethbc/strata/issues/6) **Hardware check on a norns:** CPU, levels across synth, buffer and input sources and against 2.0, arc ring feel, the 16 s save time, the buffer restore, MIDI, grid page 4 and the arc pages. Nothing has been tried on hardware yet.
- [#5](https://github.com/sethbc/strata/issues/5) **Corrupt file loaded over a buffer with audio:** it is shown as loaded and remembered. Fixing it needs the engine to report a failed load to Lua (3.1).
- **Known and accepted, no action:**
  - A failed `moveBefore` during grain synth placement makes scsynth print one `FAILURE /n_before` line. It is harmless.
  - A buffer slot's internal `restoring` flag can stay set after a restore that never gets audio. Nothing reads it except when audio is confirmed.
- **Limits to keep in mind:**
  - `strata.lua`'s main chunk uses 186 of Lua's 200 locals. Group new constants into tables and use globals for new functions, as the code already does.
  - LFOs top out at 10 Hz, the norns `lfo` library's ceiling. Anything faster belongs in the engine.

## Decisions made on Seth's behalf

Each was taken during autonomous runs, with what it costs if it was wrong. Reverse any of them in a normal pull request.

**3.0 (Confluence features)**
- **Limiter placement:** the master limiter sits *before* the tanh saturator, where the spec said "after". After it, the limiter could never act. If wrong: a one-line revert.
- **Input voices' main param:** for input-sourced voices, E3, arc ring 2, the MAIN label and the first fader control **grain size**. Randomize, mutate and drift touch only grain params, because synth and buffer params are dead for live input. If wrong: revert one branch of `main_param_entry`.
- **LFO rate:** LFOs step 48 times per beat (`LFO_PPQN`), and a send is skipped when the value moved less than 1/1000 of the range. This bounds the message rate; the cost is slightly steppier fast LFOs.
- **Buffer-length poll:** the `bufferState` poll sends one float per slot (`slot * 100 + seconds`), because matron's data polls only take blobs. It could be replaced by eight polls later.
- **`stopRecord` added:** K3 on the BUFFER page can stop a recording early, as the spec requires.
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

**3.0.1 (minor findings)**
- **Arc ring speed:** every continuous ring on MAIN, FX and BUFFER sweeps its whole range in half a turn (512 of the arc's 1024 ticks). This replaces "tune on hardware"; retune `ARC_TICKS_PER_SWEEP` after #6.
- **Engine-confirmed buffers:** a recording or load shows as loaded only once the engine reports its length. A 0 s report only counts 1 s after the change, and a late report with audio is still adopted. A finishing take shows `...` and ignores K3, with a 5 s fallback.
- **Missing sample files:** if a remembered file is missing at startup, its path is kept, so a sample on an unmounted drive comes back later.
- **Input crossmod:** input-sourced voices get amplitude crossmod (`modLevel`). Frequency crossmod is ignored for live input.
- **Menu-held keys:** keys held when the norns menu opens are forgotten. This uses a wrapped `_menu.set_mode`, restored in cleanup, with the 10 Hz check as a fallback.
- **Interleave:** the save interleave stays a per-frame loop. An array `lace` was measured about 2× slower.

## How the work was run

The 3.0 and 3.0.1 work was done with the superpowers subagent-driven-development workflow:
- one implementer per task, followed by a spec and quality review, then a whole-branch review;
- 3.0.1 ran Tasks 1-4 in parallel git worktrees and merged them afterwards.

The per-task ledgers and reports were scratch files and are not kept. This file, the CHANGELOG and git history are the record.
