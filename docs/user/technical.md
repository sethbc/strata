# Technical Details

Architecture and signal flow of the engine, and the off-device checks, for the curious. Developers should also read CLAUDE.md and the files in docs/notes/. Back to the [README](../../README.md).

## Architecture

The engine uses SuperCollider for synthesis and granular processing:
- Seven independent synthesis voices
- Individual audio buses for each voice
- Per-voice granular processors: two `GrainIn`s (left and right) followed by one `PitchShift` for a synth- or input-sourced voice, two sample-aligned `GrainBuf`s (left and right) followed by one `PitchShift` for a buffer-sourced voice; both pan their grains the same way (the same fixed pan spread), and a buffer- or input-sourced voice's pan places it as it does a synth voice. A buffer grain never reads past the end of the sample, so short samples play at an even level. The `PitchShift` window is a fixed 0.1 s whatever the grain size
- Real-time synthesis memory does not depend on grain size: what counts is how many synths run at once. Each voice keeps at most its running synths plus one fading out and one being cut, however fast its source changes or scenes are recalled, so all seven voices fit in norns' 8 MB (about 6.9 MB at the worst moment)
- Eight stereo buffers (each a pair of 16 s mono buffers, about 49 MB in all) and a live stereo input bus
- Switching a voice's source replaces its grain synth; synths never stack
- Cross-modulation routing via control buses
- Each voice generates a modulation signal from its output (buffer- and input-sourced voices copy their grains back to their voice bus, so they modulate other voices too)
- Master effects chain: multimode filter, stereo delay, reverb
- A limiter, then soft saturation, on master output
- The LFOs and MIDI run in the Lua script and reach the engine as parameter changes

## Audio Signal Flow

```
Voice Synth → Voice Bus → Granular Processor → Main Bus → Filter → Delay → Reverb → Master (drift, limiter, saturation) → Output
                  ↓
              Mod Synth → Mod Bus → Other Voice Synths (cross-modulation)

Buffer source:  Buffer (L/R) → Buffer Granular Processor → Main Bus (and the Voice Bus, for the Mod Synth)
Input source:   Audio input → Input Bus → Granular Processor → Main Bus (and the Voice Bus, for the Mod Synth)
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

Run only one engine check at a time per machine (it uses scsynth's port 57110).

`test/run.lua` also checks that CLAUDE.md's engine command table lists exactly the engine's commands, and that the docs name no engine command or repository file that no longer exists.

GitHub Actions (`.github/workflows/test.yml`) runs all three on every pull request and on pushes to `main`: the Lua tests under Lua 5.3 (the version norns runs) and LuaJIT, and the engine check on Ubuntu with SuperCollider, a dummy JACK server and `monome/norns` at a pinned commit. Both jobs (`lua`, `engine`) are required to pass before a pull request can merge into `main`.
