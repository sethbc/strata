# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Strata is an ambient granular soundscape generator for monome norns. It combines four unique synthesis voices (Resonator, FM, Folder, Sub) with individual granular processing to create evolving ambient textures.

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
Voice Synth → Voice Bus → Granular Processor → Main Bus → Reverb Bus → Master (drift/saturation) → Output
```

Each of the 4 voices follows this path:
1. Voice synth (strataResonator/strataFM/strataFolder/strataSub) outputs to its own `granBuses[i]`
2. Granular processor (`strataGrain`) reads from voice bus, outputs to shared `mainBus`
3. Reverb (`strataReverb`) processes mainBus, outputs to `reverbBus`
4. Master (`strataMaster`) applies drift and saturation, outputs to norns output

### Lua ↔ SuperCollider Communication

The Lua script controls the engine through these commands:
- `engine.voiceOn(voice, freq, amp, pan, grainSize, grainDensity, pitchShift)` - Start a voice
- `engine.voiceOff(voice)` - Stop a voice (gates off with release envelope)
- `engine.setVoiceParam(voice, param, value)` - Update synthesis parameters
- `engine.setGrainParam(voice, param, value)` - Update granular parameters
- `engine.setMasterDrift(amount)` - Control tape drift effect
- `engine.setReverb(mix, size, damp)` - Update reverb settings

Voice indices are 0-indexed in SuperCollider but 1-indexed in Lua (subtract 1 when calling engine commands).

## Development & Testing

### Running on norns

1. Copy the project to `~/dust/code/` on the norns
2. Restart norns or run `;restart` in maiden
3. Select the script from the norns SELECT menu

### Testing Changes

Since this runs on norns hardware (or norns shield/fates):
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
- Use prefixed names like "strata_reverb" for separators
- Each param needs a unique ID

## Code Style Guidelines

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

## Key Implementation Patterns

### Voice State Management

Each voice has a table structure containing:
- `name` - Voice type identifier
- `active` - Boolean state
- `params` - Synthesis parameters (voice-specific)
- `grain` - Granular processing parameters (size, density, pitch, spread)

The `voices` table is the single source of truth. Engine state mirrors this.

### Parameter System

Use norns params for all adjustable values:
1. Define in `init()` with `params:add{}`
2. Include `action` function to update engine
3. Reference params with `params:get("id")` or `params:set("id", value)`
4. Group related params with `params:add_separator()`

### Async Initialization

Voice activation uses `clock.run()` for delayed starts:
```lua
clock.run(function()
  toggle_voice(1)
  clock.sleep(0.5)
  toggle_voice(2)
end)
```

### UI Updates

The `update_voice_list()` function recreates the `UI.List` on every change. The list shows:
- Active status (● for on, ○ for off)
- Voice name
- Freeze status ([F] suffix)

## SuperCollider Architecture

### SynthDef Organization

Each voice type has its own SynthDef with unique parameters:
- `\strataResonator` - DynKlank resonator bank with filtered noise
- `\strataFM` - Two-operator FM with slow modulation
- `\strataFolder` - Wavefolder with sine input
- `\strataSub` - Ultra-low sine with drift

### Audio Bus Management

Buses are allocated in `alloc`:
- 4 stereo `granBuses` (one per voice)
- 1 stereo `mainBus` (granular outputs mix here)
- 1 stereo `reverbBus` (reverb output)

Buses are freed in `free` to prevent resource leaks.

### Synth Lifecycle

Synths use `gate` with ASR envelopes:
- Starting: `Synth.new(...)` with `gate=1`
- Stopping: `synth.set(\gate, 0)` triggers release phase
- `doneAction: 2` frees the synth after release

## Future Extension Points

The README suggests these expansion areas:
- Cross-modulation between voices
- Probability-based parameter mutations
- Preset save/load
- Monome grid integration
- Additional voice types
- Longer-form automation/sequencing
