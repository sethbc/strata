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
- **Modulation Input**: Each voice synth can receive modulation from up to 3 different sources simultaneously
- **3 Modulation Slots**: Each voice has 3 independent modulation slots, each with its own source and depth controls
- **Routing**: Controlled via `setModSource(voice, slot, sourceVoice)` where slot is 1-3
- **Depth Control**: Each slot has independent `modAmpAmt` and `modFreqAmt` controls
- **Signal Mixing**: The 3 modulation signals are mixed together (weighted sum) before applying to voice parameters
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
| `engine.setModSource(voice, slot, sourceVoice)` | `"iii"` | Set which voice modulates this voice at given slot (slot=1-3, sourceVoice: -1=none, 0-6=voice index) |
| `engine.setModAmpAmt(voice, slot, amount)` | `"iif"` | Set amplitude modulation amount for given slot (-2 to 2) |
| `engine.setModFreqAmt(voice, slot, amount)` | `"iif"` | Set frequency modulation amount for given slot (-2 to 2) |
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

**Cross-Modulation Parameters** (per voice, 3 slots per voice):
- **Slot 1, 2, 3** - Each slot has:
  - **source**: Which voice modulates this slot (0=none, 1-7 in Lua, -1=none, 0-6 in SC)
  - **amp_amt**: Amplitude modulation depth (-2 to 2, bipolar)
  - **freq_amt**: Frequency modulation depth (-2 to 2, bipolar)
- **speed**: Modulation signal LFO speed (0.1 to 50 Hz, shared across all slots)

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

### Always use named constants for magic numbers (v2.0+)

**CRITICAL**: The codebase uses named constants defined at the top of [strata.lua](strata.lua:15-19):
```lua
local NUM_VOICES = 7        -- Total number of synthesis voices
local NUM_SCENES = 8        -- Total number of scene slots
local PATTERN_LENGTH = 16   -- Steps per pattern
local SCENE_DATA_VERSION = 1  -- Scene file format version
```

**Always use these constants** instead of hardcoded numbers:
- Use `NUM_VOICES` in voice loops: `for i = 1, NUM_VOICES do`
- Use `NUM_SCENES` for scene validation: `if scene_num > NUM_SCENES then return end`
- Use `PATTERN_LENGTH` for pattern operations: `for step = 1, PATTERN_LENGTH do`
- Never use hardcoded 7, 8, or 16 in voice/scene/pattern code

**Why this matters**:
- Makes code maintainable if voice/scene counts change
- Prevents subtle bugs from inconsistent hardcoded values
- Self-documents the meaning of these numbers
- Enables easy extension (e.g., adding voice 8)

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

### CRITICAL: Always keep grid and arc integration synchronized with codebase updates

**Hardware controller integration must evolve with the codebase.** When adding features, voices, or parameters, the grid and arc interfaces should be reviewed and updated to provide access to new capabilities.

#### When adding new voices, you MUST review:

1. **Grid Integration**:
   - Update pattern sequencer to handle new voice count (currently 7 voices)
   - Adjust grid layout if voice count exceeds current row allocation
   - Update `grid_redraw_*()` functions to display new voices
   - Ensure voice toggle buttons work for all voices
   - Update pattern operations (clear, randomize) for new voices

2. **Arc Integration**:
   - Consider if new voice parameters should be accessible via arc rings
   - Update `arc_delta()` to handle new voice-specific parameters
   - Update `arc_redraw()` to display new parameter ranges correctly
   - Ensure parameter min/max values match between arc feedback and param specs

#### When adding new parameters, you MUST review:

1. **Grid Parameter Manipulation**:
   - Map new parameters to grid button positions in `manipulate_parameter()`
   - Update parameter page system if needed (currently 4 pages)
   - Consider adding dedicated grid controls for critical new parameters
   - Update grid documentation in README.md

2. **Arc Parameter Control**:
   - Evaluate if new parameters should replace or augment arc ring mappings
   - Update `get_param_spec()` to ensure arc can scale parameter ranges correctly
   - Consider adding new arc rings if 4 rings is limiting (requires arc hardware change)

#### When adding new features, you MUST review:

1. **Grid Feature Integration**:
   - Determine if feature needs grid UI representation
   - Add grid buttons for feature controls (play/stop, mode switching, etc.)
   - Update grid LED feedback to reflect feature state
   - Ensure feature works correctly when triggered from grid
   - Test with all grid sizes (256, 128h, 128v, 64)

2. **Arc Feature Integration**:
   - Evaluate if feature adds controllable parameters
   - Consider if arc button (2025 model) should trigger feature
   - Ensure arc LED feedback reflects feature state
   - Test graceful degradation when arc is not connected

#### When changing voice count or architecture, you MUST update:

1. **Grid Layouts**:
   - `grid_key_256()`, `grid_key_128h()`, `grid_key_128v()`, `grid_key_64()` - Key handling
   - `grid_redraw_256()`, `grid_redraw_128h()`, `grid_redraw_128v()`, `grid_redraw_64()` - LED feedback
   - Pattern storage structure: `patterns[voice_idx][step]`
   - Voice selection range checks throughout grid code

2. **Arc Voice Selection**:
   - Update voice-specific parameter mapping in `arc_delta()`
   - Ensure `arc_redraw()` handles all voice types correctly
   - Update voice selection via norns E2 to work with arc feedback

#### Hardware Integration Checklist

Before completing any feature addition or architectural change, verify:
- [ ] Grid pattern sequencer accommodates all voices
- [ ] Grid layouts (all 4 sizes) reflect current feature set
- [ ] Grid LED feedback accurately represents system state
- [ ] Grid buttons trigger all relevant features
- [ ] Arc rings provide access to most-used parameters
- [ ] Arc LED feedback displays current parameter values accurately
- [ ] Arc parameter ranges match controlspecs exactly
- [ ] All grid/arc functions handle new features gracefully
- [ ] README.md documents new grid/arc controls
- [ ] CLAUDE.md updated with grid/arc implementation patterns for new features
- [ ] Tested with and without hardware connected (graceful degradation)

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

### Probability-Based Mutation System

Strata includes a mutation system that applies gentle, probabilistic changes to voice parameters over time, creating organic evolution:

#### Architecture
- **Mutation Metro**: `mutation_metro` - Timer that periodically calls `gentle_mutate()`
- **Mutation Function**: `gentle_mutate()` - Applies probability-based parameter changes
- **Global Parameters**: Controlled via PARAMS menu:
  - `mutation_enabled` (0/1) - Toggle mutation system on/off
  - `mutation_rate` (0.5-10s) - How often mutations are checked
  - `mutation_probability` (0-1) - Chance each parameter will mutate per check
  - `mutation_amount` (0-1) - Size of mutation delta relative to parameter range

#### Implementation Details

**Mutation Function** ([strata.lua:616-666](strata.lua#L616-L666)):
```lua
function gentle_mutate()
  local probability = params:get("mutation_probability")
  local amount = params:get("mutation_amount")

  for i = 1, #voices do
    if voices[i].active and not frozen[i] then
      -- Check each synthesis parameter
      for key, current_val in pairs(v.params) do
        if key ~= "amp" and key ~= "pan" then
          if math.random() < probability then
            -- Generate gaussian-like mutation delta
            local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount * range
            local new_val = util.clamp(current_val + delta, spec.minval, spec.maxval)
            params:set("v" .. i .. "_" .. key, new_val)
          end
        end
      end

      -- Granular parameters mutate at lower probabilities
      -- grain_size: 0.5× probability
      -- grain_pitch: 0.3× probability
      -- grain_spread: 0.2× probability
    end
  end
end
```

**Key Design Decisions**:
- **Excluded Parameters**: `amp` and `pan` are never mutated to preserve voice balance and stereo placement
- **Frozen Voice Exemption**: Frozen voices are excluded from mutations
- **Gaussian Distribution**: Averaging two random values creates a bell curve distribution, favoring smaller changes
- **Relative Deltas**: Mutation amount is scaled to parameter range, ensuring consistent behavior across different specs
- **Granular Hierarchy**: Grain parameters mutate less frequently than synthesis parameters

#### Usage Patterns

**Starting Mutations**:
```lua
params:set("mutation_enabled", 1)  -- Enable via params
params:set("mutation_probability", 0.15)  -- 15% chance per parameter
params:set("mutation_amount", 0.25)  -- 25% of parameter range
params:set("mutation_rate", 2)  -- Check every 2 seconds
```

**Recommended Settings**:
- **Subtle Evolution**: probability=0.1, amount=0.15, rate=3s
- **Moderate Change**: probability=0.15, amount=0.25, rate=2s (default)
- **Dramatic Shift**: probability=0.25, amount=0.4, rate=1s

**Integration with Existing Systems**:
- **LFO System**: Mutations work alongside `lfo_update()` which adds continuous drift
- **Freeze Feature**: Frozen voices are stable - neither LFO nor mutations affect them
- **Cross-Modulation**: Mutations can change modulation sources/amounts, creating evolving relationships
- **UI Feedback**: `[MUT]` indicator appears at top-right when enabled

#### Lifecycle Management
- **Initialization**: Metro created in `init()` but not started automatically
- **Control**: `mutation_enabled` param action starts/stops the metro
- **Cleanup**: `mutation_metro:stop()` called in `cleanup()` to prevent orphaned timers

### Scene System for Longer-Form Automation

Strata includes a comprehensive scene system for creating longer-form compositions and automations. Scenes capture complete snapshots of the instrument state and can be recalled manually or sequenced automatically.

#### Architecture
- **Scene Storage**: `scenes` table - 8 scene slots (numbered 1-8)
- **Scene Data**: Complete instrument state including:
  - All voice parameters (synthesis, granular, cross-modulation)
  - Voice active states and freeze states
  - Pattern data (all 7 voices × 16 steps)
  - Global parameters (master density, tempo, reverb, drift, mutations)
- **Scene Sequencer**: Automatic scene progression with configurable timing
- **Transition Modes**: Instant recall or smooth crossfade between scenes

#### Core Functions

**Scene Capture** ([strata.lua:737-790](strata.lua#L737-L790)):
```lua
function capture_scene(scene_num)
  -- Captures complete current state:
  -- - All voice parameters (params, grain, crossmod)
  -- - Voice active/frozen states
  -- - All pattern data
  -- - Global parameters (density, tempo, reverb, mutations, etc.)
  scenes[scene_num].data = scene_data
  scenes[scene_num].populated = true
end
```

**Scene Recall** ([strata.lua:792-850](strata.lua#L792-L850)):
```lua
function recall_scene(scene_num, transition_time)
  -- Instant recall (transition_time = 0)
  -- OR smooth transition (transition_time > 0)
  --   - 20 interpolation steps
  --   - Crossfades all parameters
  --   - Uses util.linlin() for smooth curves
end
```

**Scene Sequencer** ([strata.lua:915-952](strata.lua#L915-L952)):
```lua
function scene_sequencer_start()
  scene_sequencer_clock = clock.run(function()
    while scene_sequencer_enabled do
      recall_scene(scene_sequencer_position, transition_time)
      clock.sleep(scene_duration)
      scene_sequencer_position = scene_sequencer_position % seq_length + 1
    end
  end)
end
```

#### Parameters

Controlled via PARAMS menu (strata_scenes section):
- `scene_sequencer_enabled` (binary) - Start/stop automatic scene progression
- `scene_transition_time` (0-30s, default 2s) - Crossfade duration for smooth transitions
- `scene_duration` (4-120s, default 16s) - How long each scene plays before advancing
- `scene_sequence_length` (1-8, default 4) - How many scenes to cycle through

#### Grid Integration

Scene controls on **Page 3** (16×16 grid):
- **Row 1**: Scene recall (instant) - Press to immediately load scene 1-8
- **Row 2**: Scene recall (with transition) - Press to crossfade into scene 1-8
- **Row 3**: Scene save - Press to capture current state to scene 1-8
- **Row 5, Column 1**: Toggle scene sequencer on/off
- **Row 5, Columns 3-10**: Set sequence length (1-8 scenes)

**LED Feedback**:
- Populated scenes: brightness 8 (row 1) or 6 (row 2)
- Current scene: brightness 15 (highlighted in row 1)
- Empty scenes: brightness 2
- Active sequencer: brightness 15, shows next scene position
- Sequence length indicators: brightness 8 for included scenes, 2 for excluded

#### UI Feedback

**Screen Display**:
- `S1` through `S8` indicator at top-right shows current scene number
- Brightness level 10 when sequencer is active, 6 when static
- Mutation indicator abbreviated to `[M]` to make room for scene indicator

#### Implementation Details

**State Capture**:
- Deep copy of all parameter values (not references)
- Preserves both the `voices` table state and norns param values
- Patterns are copied step-by-step to avoid reference issues

**Smooth Transitions**:
- 20 interpolation steps regardless of transition time
- Each step calculates `mix = step / steps` (0 to 1)
- Uses `util.linlin(0, 1, current_val, target_val, mix)` for smooth curves
- Final step ensures exact target values via `recall_scene_instant()`

**Voice Activation Handling**:
- Checks if voice state needs to change (on→off or off→on)
- Uses existing `toggle_voice()` function to properly start/stop voices
- Preserves freeze states across scene transitions

**Pattern Preservation**:
- Patterns are restored after all parameter changes
- Ensures `grid_redraw()` is called to update grid display
- Pattern sequencer continues playing if it was active

#### Usage Patterns

**Manual Scene Performance**:
```lua
-- From grid page 3:
-- 1. Build your sound
-- 2. Press row 3 button to save to scene slot
-- 3. Modify parameters
-- 4. Save to another slot
-- 5. Press row 1 buttons to instantly switch between scenes
-- 6. Press row 2 buttons to smoothly transition between scenes
```

**Automatic Scene Sequencing**:
```lua
-- Setup:
params:set("scene_transition_time", 3)  -- 3 second crossfades
params:set("scene_duration", 20)  -- 20 seconds per scene
params:set("scene_sequence_length", 4)  -- Cycle through scenes 1-4
params:set("scene_sequencer_enabled", 1)  -- Start sequencer

-- Result: Scenes 1→2→3→4→1... with 3s crossfades, 20s each
```

**Composition Workflow**:
1. Create 4-8 distinct scenes with different voice combinations and parameters
2. Set appropriate transition time (0s for rhythmic changes, 5-10s for ambient evolution)
3. Set scene duration based on desired pacing
4. Enable sequencer for hands-free long-form composition
5. Mutations can still evolve non-frozen voices during scenes

#### Integration with Other Systems

- **Freeze Feature**: Frozen voices are captured and restored per-scene
- **Mutations**: Mutation settings are per-scene; sequencer can alternate between static and evolving scenes
- **Pattern Sequencer**: Pattern data is saved per-scene; can switch between different rhythmic patterns
- **Cross-Modulation**: Modulation routing is per-scene; enables complex evolving relationships
- **LFO System**: Continues to operate during scenes unless voices are frozen

#### Lifecycle Management
- **Initialization**: Scenes array initialized in global scope, empty by default
- **Scene Sequencer Control**: Started/stopped via param action
- **Cleanup**: `scene_sequencer_stop()` called in `cleanup()` to prevent orphaned clocks
- **Transition State**: `scene_transition_active` flag prevents concurrent transitions

#### Disk Persistence
- **Storage Location**: `~/dust/data/strata/scenes.data`
- **File Format**: Lua table serialization using norns `tab` library
- **Auto-save**: Scenes automatically saved to disk in `cleanup()` when script exits
- **Auto-load**: Scenes automatically loaded from disk in `init()` on script startup
- **Manual Controls**: PARAMS menu includes "save scenes to disk" and "load scenes from disk" trigger actions
- **What's Saved**: Complete scenes table including all 8 scene slots, populated state, and scene data
- **Persistence**: Scenes persist across norns reboots, allowing you to build a library of sonic palettes

#### Scene Data Validation (v2.0+)

**IMPORTANT**: Always validate scene data before using it to prevent crashes from corrupted files.

The `validate_scene_data()` function ([strata.lua:1144-1180](strata.lua#L1144-L1180)) performs comprehensive checks:
```lua
function validate_scene_data(scene_table)
  -- Type checking
  if type(scene_table) ~= "table" then return false end

  -- Structure validation
  for i = 1, NUM_SCENES do
    if scene_table[i] and scene_table[i].populated then
      -- Verify required fields exist
      if not data.voices or not data.patterns then return false end

      -- Verify voice count matches
      if #data.voices ~= NUM_VOICES then return false end

      -- Verify each voice has complete structure
      -- (params, grain, crossmod tables)
    end
  end

  return true
end
```

**When to validate**:
- Always before loading scenes from disk
- Before recalling scenes (check scene_data.voices exists)
- After receiving scene data from external sources

**Error handling patterns**:
```lua
-- Graceful degradation with console messages
if not scene_data or not scene_data.voices then
  print("error: scene " .. scene_num .. " has invalid data")
  return
end

-- Nil-safe iteration
if scene_data.voices[i] and scene_data.voices[i].params then
  for key, target_val in pairs(scene_data.voices[i].params) do
    -- Safe to access
  end
end
```

### Bounds Checking and Safety (v2.0+)

**CRITICAL**: Always validate array indices before accessing to prevent expansion or crashes.

**Pattern bounds checking**:
```lua
function toggle_pattern_step(voice_idx, step)
  -- Bounds checking to prevent array expansion
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  if step < 1 or step > PATTERN_LENGTH then return end

  -- Safe to access
  patterns[voice_idx][step] = ...
end
```

**Scene bounds checking**:
```lua
function recall_scene(scene_num, transition_time)
  if scene_num < 1 or scene_num > num_scenes then return end
  if not scenes[scene_num].populated then
    print("scene " .. scene_num .. " is empty")
    return
  end
  -- Safe to proceed
end
```

**Apply bounds checking to**:
- All voice index access (1 to NUM_VOICES)
- All scene index access (1 to NUM_SCENES)
- All pattern step access (1 to PATTERN_LENGTH)
- Grid button coordinates
- Parameter ranges

### Resource Management and Cleanup (v2.0+)

**IMPORTANT**: Always clean up metros, clocks, and other resources to prevent leaks.

The `cleanup()` function ([strata.lua:2025-2054](strata.lua#L2025-L2054)) demonstrates proper cleanup:
```lua
function cleanup()
  -- Save state before cleanup
  save_scenes_to_disk()

  -- Stop metros with nil checks
  if lfo_metro then lfo_metro:stop() end

  -- Sync parameter state with actual state
  if mutation_metro then
    mutation_metro:stop()
    params:set("mutation_enabled", 0)  -- Keep param in sync
  end

  -- Stop pattern and scene clocks
  pattern_clock_stop()
  scene_sequencer_stop()

  -- Cancel transition clocks to prevent orphaned coroutines
  if scene_transition_clock then
    clock.cancel(scene_transition_clock)
    scene_transition_clock = nil
  end

  -- Turn off all voices
  for i = 1, NUM_VOICES do
    if voices[i].active then
      engine.voiceOff(i - 1)
    end
  end
end
```

**Clock management patterns**:
```lua
-- Before starting a clock, cancel existing one
if scene_transition_clock then
  clock.cancel(scene_transition_clock)
  scene_transition_clock = nil
end

-- Then start new clock
scene_transition_clock = clock.run(function()
  -- Clock body
end)
```

**Prevents**:
- Orphaned clock coroutines
- Concurrent clocks causing parameter oscillation
- Memory leaks from uncancelled metros
- State inconsistencies between params and actual state

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

All voice SynthDefs now include multi-source cross-modulation inputs (3 slots):
- `modBus1`, `modBus2`, `modBus3` - Control buses to read modulation signals from (one per slot)
- `modAmpAmt1`, `modAmpAmt2`, `modAmpAmt3` - Amplitude modulation depths (-2 to 2)
- `modFreqAmt1`, `modFreqAmt2`, `modFreqAmt3` - Frequency modulation depths (-2 to 2)
- The 3 modulation signals are mixed together (weighted sum) before application

**Modulation Signal Clamping (v2.0+)**:
To prevent excessive amplitude spikes when multiple modulation sources are active, all SynthDefs now include clamping:
```supercollider
// Mix modulation signals with clamping to prevent excessive modulation
modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
modFreq = freq * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-2, 2));
modAmp = (amp * (1 + modSig)).clip(0, 2);
```
This prevents the theoretical 4× amplitude spike that could occur with 3 sources all at maximum positive modulation.

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

## Version History

### Version 2.0 (2025-01-24)

Major stability and code quality release focusing on bug fixes and defensive programming:

**Critical Bug Fixes**:
- Scene data validation prevents crashes from corrupted files
- Scene sequencer position bounds checking prevents out-of-bounds access
- Concurrent scene transition prevention via clock tracking and cancellation

**High Priority Bug Fixes**:
- Arc initialization race condition fixed
- Mutation metro state synchronization in cleanup
- 64-button grid pattern display corrected
- Pattern/scene bounds checking added throughout
- Scene transition nil access protection

**Code Quality Improvements**:
- Named constants (NUM_VOICES, NUM_SCENES, PATTERN_LENGTH) replace magic numbers
- Comprehensive error handling and validation patterns
- Resource management with proper cleanup
- Modulation signal clamping in SuperCollider engine

See [CHANGELOG.md](CHANGELOG.md) for complete details.

### Version 1.0

Initial release with:
- 7 synthesis voices with granular processing
- Cross-modulation (3 slots per voice)
- Probability-based mutations
- Scene system with disk persistence
- Grid and arc integration
- Pattern sequencer

## Future Extension Points

Potential expansion areas:
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
- MIDI integration for external control
- Undo/redo for parameter changes
- Parameter automation recording
