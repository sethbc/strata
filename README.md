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

## Installation

```bash
cd ~/dust/code
git clone https://github.com/yourusername/strata.git
```

Then restart norns or run `;restart` in maiden.

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

## Parameters

All voice parameters and granular settings are available in the PARAMETERS menu for detailed control and automation. Each voice has its own section with synthesis parameters and granular processing controls.

### Master Section
- Master density
- Tape drift amount

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

- Implement probability-based parameter mutations
- Add preset save/load functionality
- Create monome grid integration for pattern sequencing
- Implement longer-form automation/sequencing
- Multi-source modulation routing (currently one source per voice)
- Additional voice types (wavetable, additive, granular noise, etc.)

## Requirements

- monome norns
- SuperCollider (included with norns)

## Credits

Created for experimental ambient electronic music production.

