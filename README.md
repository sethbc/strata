# Strata

An ambient granular soundscape generator for monome norns.

## Overview

Strata creates evolving ambient textures by combining seven unique synthesis voices with granular processing. Each voice has its own character and can be individually controlled, randomized, and frozen. The result is a layered sonic landscape perfect for experimental electronic music and ambient compositions.

## Features

### Seven Synthesis Voices

1. **Resonator** - Filtered noise through resonant filter banks with slow modulation
2. **FM** - Two-operator FM synthesis with evolving harmonic/inharmonic timbres
3. **Folder** - Sine wave through wavefolder with dynamic folding amount
4. **Sub** - Ultra-low frequency sine wave for grounding the mix
5. **Pulse** - Pulse width modulation synthesis with resonant filtering for classic analog sounds
6. **Karplus** - Karplus-Strong plucked string synthesis for organic, physical timbres
7. **Ring** - Ring modulation between two oscillators for metallic, bell-like textures

### Granular Processing

Each synthesis voice is fed through its own granular processor with independent control over:
- Grain size (texture density)
- Grain density (grains per second)
- Pitch shifting (transposition)
- Position spread (temporal smearing)

### Cross-Modulation

Voices can modulate each other for evolving, interdependent textures:
- Each voice generates a modulation signal based on its audio output
- Route any voice to modulate another voice's amplitude and/or frequency
- Adjustable modulation depth for subtle or dramatic effects
- Creates organic, evolving relationships between layers

### Global Controls

- **Master Density** - Controls grain density across all voices simultaneously
- **Tape Drift** - Adds subtle pitch drift to the entire mix for analog warmth
- **Reverb** - Adjustable mix, size, and damping

### Performance Features

- **Randomization** - Generate new parameter sets for each voice
- **Freeze** - Lock a voice's parameters while others continue to evolve
- **Auto-modulation** - Slow LFOs add subtle movement to frozen voices

### Probability-Based Mutations

Strata includes an optional mutation system for creating organic, evolving textures:
- **Probabilistic Evolution** - Each parameter has a chance to mutate at regular intervals
- **Adjustable Behavior** - Control mutation rate, probability, and amount via PARAMETERS menu
- **Smart Mutations** - Uses gaussian-like distribution for natural-sounding changes
- **Selective Application** - Only affects active, non-frozen voices
- **Preserved Stability** - Amplitude and pan are never mutated to maintain voice balance
- **Visual Feedback** - `[MUT]` indicator appears on screen when mutations are enabled

The mutation system works alongside the existing LFO system, creating multiple layers of organic movement. Combine with the freeze feature to let some voices evolve while others remain stable.

## Installation

### Method 1: Using maiden's project manager (recommended)

1. Open maiden (norns web IDE at `http://norns.local/maiden`)
2. Navigate to the project manager by clicking the circular icon in the top right
3. Click "available" to see available projects
4. Search for "strata" or scroll to find it
5. Click "install"

Alternatively, you can install directly from the GitHub URL:
1. In maiden's project manager, click "catalog"
2. Enter the repository URL: `https://github.com/sethbc/strata`
3. Click "install"

### Method 2: Using command line

From maiden's command line (bottom panel):

```bash
cd ~/dust/code
git clone https://github.com/sethbc/strata.git
```

After installation with either method, restart norns or run `;restart` in maiden.

## Controls

### Encoders

- **E1** - Master density (affects grain density globally)
- **E2** - Select voice (1-7)
- **E3** - Adjust selected voice's main parameter
  - Resonator: Frequency
  - FM: Modulation index
  - Folder: Fold amount
  - Sub: Drift amount
  - Pulse: Pulse width
  - Karplus: Decay time
  - Ring: Frequency ratio

### Keys

- **K2** - Randomize selected voice parameters
- **K3** - Start/stop voice, or freeze/unfreeze if already active

### Monome Arc (optional)

Strata supports the monome arc controller for hands-on parameter control with visual LED feedback.

#### Arc Encoders

- **Ring 1** - Master density (0.1 to 2.0)
- **Ring 2** - Selected voice's main parameter (follows E3 mapping)
- **Ring 3** - Grain size for selected voice
- **Ring 4** - Grain density for selected voice

#### Arc Button (2025 model)

- **Button** - Same as K3 (start/stop voice, or freeze/unfreeze if already active)

#### LED Feedback

- Bright rings (level 15/12) indicate active voices
- Dim rings (level 4/3) indicate inactive voices
- Ring position shows current parameter value

### Monome Grid (optional)

Strata includes comprehensive grid integration for pattern sequencing and parameter manipulation. Supports multiple grids simultaneously and adapts layout based on grid size.

#### Supported Grid Sizes

- **256 (16×16)** - Full featured layout with patterns, parameters, and controls
- **128 horizontal (16×8)** - Pattern sequencing with essential controls
- **128 vertical (8×16)** - Pattern sequencing optimized for vertical layout
- **64 (8×8)** - Basic pattern sequencing (8 steps per voice)

#### 16×16 Grid Layout (256 buttons)

**Rows 1-7: Pattern Sequencer**
- Each row represents one voice
- 16 steps per pattern
- Press buttons to toggle steps on/off
- Current step highlighted during playback

**Row 8: Transport & Page Controls**
- Columns 1-4: Play/stop pattern sequencer
- Columns 5-8: Tempo adjustment (-10, -1, +1, +10 BPM)
- Columns 13-16: Page selection (1-4)

**Rows 9-12: Parameter Manipulation** (Page 2)
- 64 virtual control positions for parameter adjustment
- Press to randomize parameter values
- Layout depends on selected parameter page

**Row 13: Parameter Page Selection**
- Select which parameter set to control (1-4)

**Row 14: Voice Selection & Status**
- Columns 1-7: Select voice for parameter editing
- Columns 9-15: Toggle voices on/off

**Row 15: Pattern Operations**
- Columns 1-7: Clear pattern for each voice
- Columns 9-15: Randomize pattern for each voice

**Row 16: Voice Freeze**
- Columns 1-7: Freeze/unfreeze each voice

#### 16×8 Grid Layout (128 buttons horizontal)

**Rows 1-7: Pattern Sequencer**
- 16 steps per voice pattern

**Row 8: Multi-function Controls**
- Columns 1-4: Play/stop
- Column 5: Patterns page
- Column 6: Parameters page
- Columns 9-15: Voice toggle on/off
- Column 16: Cycle voice selection

#### 8×16 Grid Layout (128 buttons vertical)

**Columns 1-7: Pattern Sequencer**
- 16 steps per voice (vertical orientation)

**Column 8: Controls**
- Rows 1-7: Toggle voices on/off
- Row 9: Play/stop sequencer
- Rows 11-16: Voice selection for parameters

#### 8×8 Grid Layout (64 buttons)

**Rows 1-7: Pattern Sequencer**
- 8 steps per voice (reduced from 16)

**Row 8: Essential Controls**
- Column 1: Play/stop
- Columns 3-7: Toggle first 5 voices

#### Pattern Sequencer Features

- **16-step patterns** per voice (8 steps on 64-button grid)
- **Per-voice patterns** - each voice has independent pattern
- **Real-time recording** - toggle steps while playing
- **Visual feedback** - current step highlighted bright
- **Tempo control** - 40-300 BPM (adjustable via grid or PARAMS)
- **Pattern operations** - clear, randomize per voice
- **Automatic voice triggering** - voices activate when pattern step plays

#### Multi-Grid Support

- Connect up to 4 grids simultaneously
- Each grid shows the same interface
- Hot-plug support - connect/disconnect grids while running
- All grids stay synchronized

## Usage Tips

### Getting Started

1. The script starts with the Resonator and FM voices active
2. Use E2 to select different voices
3. Press K3 to activate/deactivate voices
4. Experiment with E1 to change the overall texture density

### Creating Evolving Textures

- Start with 2-3 voices active
- Use K2 to randomize individual voices until you find interesting combinations
- Freeze voices you like with K3
- Adjust master density with E1 to create movement
- Add reverb via the PARAMETERS menu for more space

### Exploring Cross-Modulation

- Open PARAMETERS menu and navigate to a voice's cross-modulation section
- Set "mod source" to another active voice (e.g., voice 2 modulates voice 1)
- Adjust "amp mod amount" (0.5 to 1.5 is a good starting range)
- Try "freq mod amount" for pitch variation (start subtle: 0.1 to 0.3)
- Experiment with different modulation routing combinations
- Create feedback loops (voice 1 → 2, voice 2 → 1) for complex evolution

### Performance Workflow

1. Build up layers by activating voices one at a time
2. Randomize unfrozen voices to create variation
3. Use master density for dynamic swells and fades
4. Freeze/unfreeze voices to create structural changes
5. Set up cross-modulation for interdependent voice relationships

### Using Probability-Based Mutations

- Enable mutations via PARAMETERS > mutations enabled
- Start with conservative settings:
  - Mutation rate: 2-3 seconds (how often mutations occur)
  - Mutation probability: 0.10-0.15 (chance each parameter will change)
  - Mutation amount: 0.20-0.30 (size of changes relative to parameter range)
- Freeze voices you want to keep stable while others evolve
- Combine with cross-modulation for complex, interdependent evolution
- Watch the `[MUT]` indicator on screen to confirm mutations are active
- For dramatic changes, increase probability to 0.25+ and amount to 0.40+
- For subtle drift, decrease both values and increase the mutation rate

## Parameters

All voice parameters and granular settings are available in the PARAMETERS menu for detailed control and automation. Each voice has its own section with synthesis parameters and granular processing controls.

### Master Section
- Master density
- Tape drift amount
- Tempo

### Mutations Section
- Mutations enabled (on/off)
- Mutation rate (0.5-10 seconds)
- Mutation probability (0-1, chance per parameter)
- Mutation amount (0-1, size of changes)

### Reverb Section
- Mix
- Size
- Damping

### Per-Voice Sections
Each voice includes:
- Synthesis parameters (varies by voice type)
- Grain size
- Grain density
- Grain pitch shift
- Position spread
- Cross-modulation controls:
  - Modulation source (which voice modulates this one)
  - Amplitude modulation amount
  - Frequency modulation amount
  - Modulation speed

## Technical Details

### Architecture

The engine uses SuperCollider for synthesis and granular processing:
- Seven independent synthesis voices
- Individual audio buses for each voice
- Per-voice granular processors using `GrainIn`
- Cross-modulation routing via control buses
- Each voice generates a modulation signal from its output
- Global reverb and master effects chain
- Soft saturation on master output

### Audio Signal Flow

```
Voice Synth → Voice Bus → Granular Processor → Main Bus → Reverb → Master (with drift/saturation) → Output
                  ↓
              Mod Synth → Mod Bus → Other Voice Synths (cross-modulation)
```

## Expanding the Script

The codebase is designed to be extended. Some ideas:

- Add preset save/load functionality
- Implement longer-form automation/sequencing
- Multi-source modulation routing (currently one source per voice)
- Additional voice types (wavetable, additive, granular noise, etc.)

## Requirements

- monome norns
- SuperCollider (included with norns)
- monome arc (optional - provides tactile parameter control with LED feedback)
- monome grid (optional - provides pattern sequencing and parameter manipulation)

## Credits

Created for experimental ambient electronic music production.

