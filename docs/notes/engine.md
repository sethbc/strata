# Engine notes

The engine notes are one file per area of the engine check (`test/engine_check/<area>.scd`), each opening with what you must not break. A section of the old single file is now in the area named after it below.

- [structure](engine/structure.md): architecture and signal flow, the Lua ↔ SuperCollider details, the engine check's areas and helpers, SynthDef Organization, Audio Bus Management, Node Ordering
- [voices](engine/voices.md): Cross-Modulation System, index conversion, starting a voice (`voiceOn` sync), the silent bus, Retrigger, Pitchbend, the voice and crossmod parameters, Modulation Signal Clamping, Signal safety, Resonator level
- [grains](engine/grains.md): the granular parameters (`envShape`, `grainMode`, `pitchShift`), Audio Sources (`\strataGrainBuf`, live input, the mirror, voice-level controls), the grain SynthDefs and their hooks
- [lifecycle](engine/lifecycle.md): Replace, never stack (the kill fade), Synth Lifecycle (re-gating, watching, `sendToSynth`, the invariant warnings)
- [memory](engine/memory.md): Real-time memory (the grain UGens' sizes, the budget, the worst cases)
- [buffers](engine/buffers.md): the `bufferState` and `bufferLoadFailed` polls, the buffer slots, Buffer commands (damaged files and failed reads, fade before zeroing, `slotChanges`, recording, `stopRecord`), Audio Sources: Lua side (the buffers table, buffer params, scenes)
- [files](engine/files.md): `writeSlot` and `saveBuffer` (`.part` files, generations, clipping), `deleteStaleParts`, the scratch directory
- [effects](engine/effects.md): `\strataFilter`, `\strataDelay`, `\strataReverb`, `\strataMaster`, the NaN guard before the effects
- [performance](engine/performance.md): the values a performance tier sets
- [rings](engine/rings.md): the voice and input rings, their writers, where a ring grain starts (the lookback, history), `ringReaders`
- [freeze](engine/freeze.md): freeze per source (hold, spectral), the input copy and its fade, the frozen read point, the spectral writer
- [loops](engine/loops.md): loop regions, where a buffer grain starts (`slotGrainPos`), forward and reverse grains kept inside the valid region
