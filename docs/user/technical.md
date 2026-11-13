# Technical Details

Architecture and signal flow of the engine, and the off-device checks, for the curious. Developers should also read AGENTS.md and the files in docs/notes/. Back to the [README](../../README.md).

## Architecture

The engine uses SuperCollider for synthesis and granular processing:
- Seven independent synthesis voices
- Up to eight notes on each voice: its own note and up to seven extra notes from a note pool the seven voices share (Performance tiers, below). A synth voice's extra note is another synth of the voice's kind on its voice bus, so the voice's one granular processor grains the whole chord; a buffer or input voice's extra note is a granular processor of its own, playing at the note's rate; a frozen synth voice's notes are streams of its frozen sound. Every note of a voice goes through the voice's one mix stage. The script decides which slot a note takes and which note a new one replaces; the engine holds at most one sounding and one fading synth in a slot, and never more notes than the pool, whatever arrives
- Individual audio buses for each voice
- Per-voice granular processors: two sample-aligned `GrainBuf`s (left and right) per voice. A synth- or input-sourced voice's grains read a ring buffer of its recent sound, a buffer-sourced voice's read the sample; both pan their grains the same way (the same fixed pan spread), and a buffer- or input-sourced voice's pan places it as it does a synth voice. A buffer grain never reads past the end of the sample, so short samples play at an even level. Grain pitch is the grain's playback rate, an exact transposition with no pitch-shifter stage
- Real-time synthesis memory does not depend on grain size: what counts is how many synths run at once. Each voice keeps at most its running synths plus one fading out and one being cut, and each extra note one sounding and one being cut, however fast notes, source changes or scene recalls come, so all seven voices fit in norns' 8 MB real-time pool with room to spare. With no extra note playing, at the worst moment, with six engine LFOs and scatter running, about 3.5 MB is in use on the standard tier and about 4.2 MB on the high tier (the engine check's memory test as CI runs it, on SuperCollider 3.13), and the check requires at least 3 MB of the pool left free on standard (3.5 MB on high). With all sixteen extra notes the pool allows playing at once, the worst moment the check measures (its memory test as CI runs it, on SuperCollider 3.13) leaves 2560 KB free on standard and 2070 KB on high (1960 KB on high in a full run of every check on 3.14.1), against the 1280 KB the check requires there
- Eight stereo buffers (each a pair of mono buffers: 16 s on the standard tier, about 49 MB in all, up to 300 s on the high tier) and a live stereo input bus. Each voice also keeps the last 4 s of its own sound and, for a frozen input, a 4 s copy of the input of its own (about 22 MB for the seven), and the input keeps its history (16 s, 60 s on the high tier)
- Switching a voice's source replaces its grain synth; synths never stack
- Cross-modulation routing via control buses
- Each voice generates a modulation signal from its output (buffer- and input-sourced voices copy their grains back to their voice bus, so they modulate other voices too)
- One mix stage per voice after its grains (the Voice Stage of the signal flow below): the voice's own filter, the level of a buffer- or input-sourced voice (a synth voice's level is set in its synth), and its delay and reverb sends. It writes the voice's dry sound to the main bus and its sends to a delay send bus and a reverb send bus beside it ([Each voice's filter and sends](effects.md#each-voices-filter-and-sends))
- Master effects chain: the multimode filter (on the main bus and on each send bus, with the same settings), stereo delay (fed by the delay send), reverb (fed by the reverb send and the delay)
- A limiter, then soft saturation, on master output
- MIDI and most LFOs run in the Lua script and reach the engine as parameter changes; an LFO on a voice's grain pitch, position, size, filter cutoff or level runs in the engine itself

## Performance tiers

Strata runs on one of two tiers, chosen by the engine each time the script starts:

| | standard | high |
|---|---|---|
| buffer length (each of the eight) | 16 s | 16, 60, 120 or 300 s (60 by default) |
| grains per voice (at most) | 128 | 128 |
| live input history | 16 s | 60 s |
| note pool (extra notes the voices share, by default) | 4 | 8 |

The **performance** field on the SETUP page picks the tier ([SETUP](pages/setup.md)):
- **auto** (the default) - high on a Pi 4 or Compute Module 4 norns (CM4, CM4S), standard on a CM3, a Pi 3 or anything else
- **standard** - standard on every norns
- **high** - high on every norns; on a CM3 or Pi 3 it may cause audio dropouts (xruns), and SETUP says `may xrun`

The **note pool** field on SETUP sets how many extra notes the seven voices can play at once, 0-16 on either tier (0 plays one note per voice). The default follows the tier: 4 on standard, 8 on high. Every extra note is another synth running, so a large pool asks more of the CPU: on the standard tier SETUP shows `may xrun` under a pool above 4, since how many notes a CM3 plays without dropouts has not been measured on a norns yet. The real-time memory holds the full 16 on both tiers (Architecture, above). Like the performance setting, the pool is a setting of the norns, not of a patch: it is saved at once to `notes.data` in Strata's data folder and no PSET or scene holds it, but it takes effect at once.

On the high tier the **buffer length** field sets how long each buffer is. The buffers live in the norns' memory (eight stereo buffers of 300 s take about 922 MB), so the engine checks how much memory is free when it starts: if the chosen length would leave less than 1 GB free, it steps down to 120, 60 or 16 s, and SETUP shows it (`300 s -> 120 s (memory)`).

Both fields are settings of the norns, not of a patch: no PSET or scene holds them. They are saved at once to `performance.data` in Strata's data folder (`~/dust/data/strata/`) and take effect the next time the script starts (restart the script, or norns, to apply them); until then SETUP shows `(next start)`. The status line `running: high, 60 s` or `running: standard` shows what runs now. The engine writes what it chose to `performance_active.data` beside it, which the script reads as it starts. If that file cannot be written and no old one is left, Strata runs standard. An old file the engine cannot replace (the data folder or the file became read-only) is what the script reads, so the engine runs the tier that file names, high included, until the file is removed by hand: SETUP then shows `old active file kept`.

## Long buffers

On the high tier each buffer holds up to the buffer length (60 s by default, up to 300 s). Recording, loading, clearing and saving work as on the standard tier, with a few differences:
- **Loading** a file longer than 16 s checks it first (decoding it, to catch a damaged file) without stopping the rest of Strata: the buffer keeps what it held until the check is done, then fades and loads the new file. Load, record into or clear the buffer meanwhile and the later action wins. A longer file than the buffer holds loads its first part (a 300 s file on 60 s buffers loads its first 60 s).
- **Saving** a long buffer takes a while (a 300 s buffer about 2 s on a desktop computer, several seconds on the norns; the file appears when it is complete) and needs room for two temporary files of about 58 MB each.
- The BUFFER page shows lengths of a minute and more as minutes and seconds (`1:05`).
- Buffer scan moves in buffer lengths per second, so a setting that drifts gently through a 16 s buffer covers a full 300 s buffer at the same pace in buffer lengths, about 19 times as many seconds of audio per second: use small values.

## Audio Signal Flow

```
Synth source:   Voice Synth → Voice Bus → Voice Ring → Granular Processor ┐
Buffer source:  Buffer (L/R) → Granular Processor ───────────────────────┼→ Voice Stage
Input source:   Audio input → Input Bus → Input Ring → Granular Processor ┘

Voice Stage ─ dry ────────── Filter ─────────────────────┐
            ─ delay send ─── Filter → Delay ─┬───────────┤
            ─ reverb send ── Filter ─────────┴→ Reverb ──┴→ Master (drift, limiter, saturation) → Output

(one Voice Stage per voice: the voice filter, its level, the delay and reverb sends, and the copy of a buffer or input voice's grains to its Voice Bus)
(a synth voice's extra notes are more Voice Synths on its Voice Bus; a buffer or input voice's are more Granular Processors into its Voice Stage)

Voice Bus → Mod Synth → Mod Bus → Other Voice Synths (cross-modulation)
```

## Development

Off-device checks (no norns needed):
- `lua test/run.lua` (or `luajit test/run.lua`) - behavior tests against norns stubs
- `lua test/sync_check.lua` - checks Lua `engine.*` calls against the engine's commands
- `test/run_engine_check.sh [path/to/norns]` - compiles and exercises the SuperCollider engine against the norns `sc/core` classes (requires SuperCollider; the norns source defaults to `~/src/norns` or `$NORNS_DIR`)

The engine check uses `$SCLANG` if set, else `sclang` on `PATH`, else the macOS app. On Linux, install `supercollider-language`, `supercollider-server` and `jackd2`, start a JACK server with a dummy driver (scsynth needs one, no sound card required) and run the check headless:

```sh
jackd --no-realtime -d dummy -r 48000 -p 1024 &
QT_QPA_PLATFORM=offscreen test/run_engine_check.sh ~/src/norns
```

Two runs on the same scsynth port collide (it is 57110 unless `STRATA_SC_PORT` says otherwise), so give each run its own `STRATA_SC_PORT` to run checks side by side, avoiding 57120 and the few ports above it.

`test/run.lua` also checks that AGENTS.md's engine command table lists exactly the engine's commands, and that the docs name no engine command or repository file that no longer exists.

GitHub Actions (`.github/workflows/test.yml`) runs all three on every pull request and on pushes to `main`: the Lua tests under Lua 5.3 (the version norns runs) and LuaJIT, and the engine check on Ubuntu with SuperCollider, a dummy JACK server and `monome/norns` at a pinned commit. Both jobs (`lua`, `engine`) are required to pass before a pull request can merge into `main`.
