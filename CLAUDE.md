# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Strata is an ambient granular soundscape generator for monome norns. It combines seven unique synthesis voices (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring) with individual granular processing to create evolving ambient textures.

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
                  ↓
              Mod Synth → Mod Bus → Other Voice Synths (cross-modulation)
```

Each of the 7 voices follows this path:
1. Voice synth (strataResonator/strataFM/strataFolder/strataSub/strataPulse/strataKarplus/strataRing) outputs to its own `granBuses[i]`
2. Granular processor (`strataGrain`) reads from voice bus, outputs to shared `mainBus`
3. Modulation synth (`strataMod`) analyzes voice bus output and generates control signal to `modBuses[i]`
4. Other voice synths can read from any `modBuses[i]` to modulate their amplitude and/or frequency
5. Reverb (`strataReverb`) processes mainBus, outputs to `reverbBus`
6. Master (`strataMaster`) applies drift and saturation, outputs to norns output

### Cross-Modulation System

Each voice generates a modulation signal (envelope follower + slow LFO) that can modulate other voices:
- **Modulation Output**: Each voice has a `strataMod` synth that analyzes its audio output and creates a control signal (0-1 range)
- **Modulation Input**: Each voice synth can read from any mod bus and use it to modulate amplitude and/or frequency
- **Routing**: Controlled via `setModSource(voice, sourceVoice)` - each voice can be modulated by one source
- **Depth Control**: `modAmpAmt` and `modFreqAmt` control how much the modulation signal affects each parameter
- **Signal Character**: The mod signal combines envelope following (70%) with slow LFO movement (30%) for organic evolution

### Lua ↔ SuperCollider Communication

**IMPORTANT**: This section documents the current engine command interface. Keep it updated when adding/modifying commands.

The Lua script controls the engine through these commands:

| Lua Command | SC Signature | Purpose |
|-------------|--------------|---------|
| `engine.voiceOn(voice, freq, amp, pan, grainSize, grainDensity, pitchShift)` | `"isfffff"` | Start a voice with initial parameters |
| `engine.voiceOff(voice)` | `"i"` | Stop a voice (gates off with release envelope) |
| `engine.setVoiceParam(voice, param, value)` | `"isf"` | Update synthesis parameters dynamically |
| `engine.setGrainParam(voice, param, value)` | `"isf"` | Update granular parameters dynamically |
| `engine.setMasterDrift(amount)` | `"f"` | Control global tape drift effect |
| `engine.setReverb(mix, size, damp)` | `"fff"` | Update reverb (mix, size, damping) |
| `engine.setModSource(voice, sourceVoice)` | `"ii"` | Set which voice modulates this voice (-1 = none, 0-6 = voice index) |
| `engine.setModAmpAmt(voice, amount)` | `"if"` | Set amplitude modulation amount (-2 to 2) |
| `engine.setModFreqAmt(voice, amount)` | `"if"` | Set frequency modulation amount (-2 to 2) |
| `engine.setModSpeed(voice, speed)` | `"if"` | Set modulation LFO speed (0.1 to 50) |

**Index Conversion**: Voice indices are 0-indexed in SuperCollider but 1-indexed in Lua. Always subtract 1 when calling engine commands from Lua (e.g., `engine.voiceOn(voice_idx - 1, ...)`).

**Current Voice Parameters** (as of latest sync):
- **Resonator**: freq, rq, noise, mod1, mod2, amp, pan
- **FM**: freq, ratio, index, modFreq, amp, pan
- **Folder**: freq, fold, mod, amp, pan
- **Sub**: freq, drift, amp
- **Pulse**: freq, width, cutoff, res, amp, pan
- **Karplus**: freq, decay, damping, excite, amp, pan
- **Ring**: freq, ratio, mod, brightness, amp, pan

**Current Granular Parameters**: grainSize, grainDensity, pitchShift, posSpread

**Cross-Modulation Parameters** (per voice):
- **source**: Which voice modulates this one (0=none, 1-7 in Lua, -1=none, 0-6 in SC)
- **amp_amt**: Amplitude modulation depth (-2 to 2, bipolar)
- **freq_amt**: Frequency modulation depth (-2 to 2, bipolar)
- **speed**: Modulation signal LFO speed (0.1 to 50 Hz)

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

### IMPORTANT: Always update the UI when adding features or changing the codebase

**The norns screen is 128×64 pixels - every pixel matters.** The UI must evolve with the codebase to remain usable and informative.

#### UI Design Principles for norns

1. **Screen Constraints**:
   - Total resolution: 128×64 pixels
   - Use column layouts to maximize information density without overlapping
   - Current layout: Left column (0-60px) for voice list, Right column (65-128px) for parameters
   - Reserve bottom row (y=64) for key hints

2. **Scrolling Lists**:
   - Use `UI.ScrollingList` for lists that exceed visible space
   - Set `num_visible` appropriately (currently 5 for 7 voices)
   - Set `num_above_selected` for context (currently 1)
   - Always set `active = true` and update `index` when selection changes

3. **Information Hierarchy**:
   - Title/app name at top (y=8)
   - Critical global params in header (master density)
   - Selected item details in dedicated column
   - Helper text at bottom (key functions)

#### When Adding New Features, Update the UI to:

1. **Display New Parameters**:
   - Add new parameters to the right column display
   - Consider abbreviating labels if space is tight (e.g., "dens" instead of "density")
   - Use appropriate units (Hz, s, %, etc.)
   - Update the parameter value display in the `redraw()` function

2. **Add New Voices**:
   - Voice list automatically scrolls with more than 5 voices
   - Add parameter display case in `redraw()` function
   - Update `get_param_spec()` with controlspec for new parameters
   - Consider whether right column layout needs adjustment

3. **Add New Status Indicators**:
   - Place indicators in consistent locations (currently status at y=26)
   - Use brightness levels to show importance (15=bright, 4=dim, 1=subtle)
   - Consider using `[BRACKETS]` for state indicators like `[FREEZE]`

4. **Maintain Visual Balance**:
   - Keep divider line between columns (x=62)
   - Preserve alignment of related information
   - Use consistent spacing between UI elements
   - Test with all voices to ensure nothing overlaps or clips

#### UI Update Checklist

Before completing any feature addition, verify:
- [ ] New parameters are visible in the UI without overlapping
- [ ] Voice list scrolling still works correctly
- [ ] All status indicators are clearly visible
- [ ] Parameter values display with appropriate precision and units
- [ ] Key hints at bottom reflect current functionality
- [ ] UI works correctly for all 7 voices
- [ ] No text or graphics extend beyond screen bounds (128×64)
- [ ] Visual hierarchy remains clear (title → list → details → hints)

### CRITICAL: Always keep the Lua script and SuperCollider engine synchronized

**This is the most important rule for this codebase.** The dual-language architecture requires strict synchronization between [strata.lua](strata.lua) and [lib/Engine_Strata.sc](lib/Engine_Strata.sc).

#### When modifying the SuperCollider engine, you MUST update:

1. **Engine Commands** - If you add/modify `this.addCommand()` in the SC file:
   - Add corresponding `engine.*` calls in the Lua file
   - Ensure parameter counts and types match exactly
   - Update the "Lua ↔ SuperCollider Communication" section in this file

2. **SynthDef Parameters** - If you add/modify SynthDef arguments:
   - Update the `voices` table in Lua with matching parameter names
   - Add corresponding params in `add_voice_params()` function
   - Add to `get_param_spec()` with appropriate controlspec
   - Ensure `engine.setVoiceParam()` calls use the correct parameter names

3. **Voice-Specific Parameters** - If you change voice parameters:
   - Update `getVoiceParams()` helper in SC
   - Update default values in Lua `voices` table
   - Verify parameter names match between SC SynthDef args and Lua param IDs

#### When modifying the Lua script, you MUST update:

1. **New Engine Calls** - If you add new `engine.*` calls:
   - Add corresponding `this.addCommand()` in the SC engine
   - Match the parameter signature exactly (use SC type codes: i=int, f=float, s=string)
   - Test the command works on norns/maiden

2. **Parameter Changes** - If you modify voice parameters:
   - Update the corresponding SynthDef arguments in SC
   - Ensure default values match between Lua and SC
   - Update voice-specific parameter lists

3. **Granular Parameters** - If you modify grain processing:
   - Update `\strataGrain` SynthDef arguments
   - Update `engine.setGrainParam()` calls
   - Verify parameter names match (e.g., `grainSize`, `grainDensity`, `pitchShift`, `posSpread`)

#### Synchronization Checklist

Before completing any modification task, verify:
- [ ] All `engine.*` commands in Lua have matching `this.addCommand()` in SC
- [ ] All SynthDef parameters are accessible from Lua params system
- [ ] Parameter names match exactly (case-sensitive)
- [ ] Array indexing conversions are correct (Lua 1-indexed → SC 0-indexed with `-1`)
- [ ] Default values are consistent between Lua and SC
- [ ] Documentation in CLAUDE.md reflects any new commands or parameters
- [ ] README.md is updated if user-facing features changed

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

### Grid Integration (Optional)

Strata supports monome grid controllers for pattern sequencing and parameter manipulation. The implementation handles multiple grid sizes and multiple simultaneous grids.

#### Device Lifecycle
- `grid_init()` - Connect to up to 4 grid devices at startup
- `grid.add(g)` - Global callback when grid connects (hot-plug support)
- `grid.remove(g)` - Global callback when grid disconnects
- `grids` table - Stores all connected grids indexed by port (1-4)

#### Grid Size Detection & Adaptive Layouts
The implementation automatically detects grid dimensions via `g.cols` and `g.rows` and routes to appropriate layout:
- **16×16 (256 buttons)**: `grid_key_256()` and `grid_redraw_256()` - Full-featured layout
- **16×8 (128 horizontal)**: `grid_key_128h()` and `grid_redraw_128h()` - Horizontal layout
- **8×16 (128 vertical)**: `grid_key_128v()` and `grid_redraw_128v()` - Vertical layout
- **8×8 (64 buttons)**: `grid_key_64()` and `grid_redraw_64()` - Compact layout

#### Pattern Sequencer Implementation
- **Pattern Storage**: `patterns[voice_idx][step]` - 7 voices × 16 steps, values 0-15
- **Playback Clock**: `pattern_clock` - Uses `clock.run()` and `clock.sync(1/4)` for tempo-synced 16th notes
- **Position Tracking**: `pattern_position` - Current step (1-16), wraps around
- **Pattern Operations**:
  - `toggle_pattern_step(voice, step)` - Toggle step on/off
  - `clear_pattern(voice)` - Reset all steps to 0
  - `randomize_pattern(voice)` - Generate random pattern with 50% density

#### Multi-Grid Synchronization
- All grids display the same interface simultaneously
- `grid_redraw()` iterates over `grids` table and updates each grid
- Shared state (patterns, voice status, pages) ensures consistency
- Each grid can trigger the same functions independently

#### LED Feedback Patterns
- **Active steps**: Brightness 15 (full)
- **Current playback position**: Minimum brightness 4, or 15 if step is active
- **Voice active status**: Brightness 12
- **Voice inactive status**: Brightness 2-4
- **Page indicators**: 15 for selected, 2 for unselected
- Always call `g:refresh()` after updating LEDs

#### Key Implementation Details
- Grid key handler checks `z == 0` to ignore key releases (only respond to presses)
- Use `g:all(0)` to clear all LEDs before redrawing
- Pattern clock uses `clock.sync()` for tempo-accurate timing
- Voices auto-activate when pattern step triggers them
- Stop pattern clock in `cleanup()` to prevent orphaned clock coroutines
- Grid pages allow switching between pattern sequencing and parameter control

### Arc Integration (Optional)

Strata supports the monome arc controller for tactile parameter control. The implementation follows these patterns:

#### Device Lifecycle
- `arc_init()` - Connect to arc device and set up callbacks
- `arc.add()` - Global callback when arc connects
- `arc.remove()` - Global callback when arc disconnects
- Graceful degradation: All arc functions check if `a == nil` before proceeding

#### Input Handling
- `arc_delta(n, delta)` - Handle encoder rotation for rings 1-4
  - Ring 1: Master density
  - Ring 2: Selected voice's main parameter (voice-specific)
  - Ring 3: Grain size for selected voice
  - Ring 4: Grain density for selected voice
- `arc_key(n, s)` - Handle button press (2025 arc models)
  - Mirrors K3 functionality (toggle/freeze voice)

#### LED Feedback
- `arc_redraw()` - Update all ring LEDs to reflect current parameter values
- Called after parameter changes (from encoders or arc)
- Uses `util.linlin()` to map parameter ranges to 0-64 LED positions
- Brightness levels indicate voice state:
  - 15 = active voice primary parameter
  - 12 = active voice secondary parameters
  - 4 = inactive voice primary parameter
  - 3 = inactive voice secondary parameters
- Uses `a:segment(ring, from, to, level)` for smooth arc visualizations

#### Key Implementation Details
- Arc encoders use scaled deltas (e.g., `delta / 20`, `delta / 100`) for fine control
- Parameters ranges must match between arc feedback and param specs
- Arc redraw is triggered alongside screen redraw for consistency
- All arc functions are non-blocking and safe to call even without arc connected

### UI Updates

The `update_voice_list()` function recreates the `UI.ScrollingList` on every change. The list shows:
- Active status (● for on, ○ for off)
- Voice name
- Freeze status ([F] suffix)

The UI uses a two-column layout:
- **Left column (0-60px)**: Scrolling voice list (5 visible at a time)
- **Right column (65-128px)**: Selected voice details (name, status, main parameter)
- **Divider (x=62)**: Subtle vertical line separating columns

The `redraw()` function handles all screen drawing and must be updated whenever new UI elements are added.

## SuperCollider Architecture

### SynthDef Organization

Each voice type has its own SynthDef with unique parameters:
- `\strataResonator` - DynKlank resonator bank with filtered noise
- `\strataFM` - Two-operator FM with slow modulation
- `\strataFolder` - Wavefolder with sine input
- `\strataSub` - Ultra-low sine with drift
- `\strataPulse` - Pulse width modulation with resonant filtering
- `\strataKarplus` - Karplus-Strong plucked string physical model
- `\strataRing` - Ring modulation between two oscillators

All voice SynthDefs now include cross-modulation inputs:
- `modBus` - Control bus to read modulation signal from
- `modAmpAmt` - Amplitude modulation depth (-2 to 2)
- `modFreqAmt` - Frequency modulation depth (-2 to 2)

Shared processing SynthDefs:
- `\strataMod` - Envelope follower + LFO for generating modulation signals
- `\strataGrain` - Granular processor (one per voice)
- `\strataReverb` - Global reverb processor
- `\strataMaster` - Master output with drift and saturation

### Audio Bus Management

Buses are allocated in `alloc`:
- 7 stereo `granBuses` (one per voice, for audio)
- 7 mono `modBuses` (one per voice, for control signals)
- 1 stereo `mainBus` (granular outputs mix here)
- 1 stereo `reverbBus` (reverb output)

Buses are freed in `free` to prevent resource leaks.

### Synth Lifecycle

Synths use `gate` with ASR envelopes:
- Starting: `Synth.new(...)` with `gate=1`
- Stopping: `synth.set(\gate, 0)` triggers release phase
- `doneAction: 2` frees the synth after release

## Future Extension Points

Potential expansion areas:
- ~~Cross-modulation between voices~~ ✓ Implemented
- ~~Additional voice types (Pulse, Karplus, Ring)~~ ✓ Implemented
- Probability-based parameter mutations
- Preset save/load
- Monome grid integration
- More voice types (wavetable, additive, granular noise, etc.)
- Longer-form automation/sequencing
- Multi-source modulation routing (currently limited to one source per voice)
