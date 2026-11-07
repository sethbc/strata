# Strata

An ambient granular soundscape generator for monome norns.

## Overview

Strata creates evolving ambient textures by combining seven unique synthesis voices with granular processing. Each voice has its own character and can be individually controlled, randomized, and locked, and any voice can grain a sample buffer or the live input instead of its synth. A filter, delay and reverb, three global LFOs, scenes, MIDI input and grid and arc support complete it. The result is a layered sonic landscape perfect for experimental electronic music and ambient compositions.

This is version 3.0.2. Version 3.0 added buffers and live input, filter and delay, grain envelopes and triggered grains, LFOs, MIDI and a paged screen; 3.0.1 and 3.0.2 are fix releases. See [CHANGELOG.md](CHANGELOG.md).

## Features

- Seven synthesis voices (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring), each with its own granular processor
- Eight sample buffers and a live stereo input as alternative grain sources
- Cross-modulation between voices, three global LFOs and probability-based mutations
- Filter, delay, reverb and a limiter on the master output
- Eight scenes with smooth recall and a scene sequencer
- A pattern sequencer on the grid, MIDI input, monome arc support and an eight-page screen UI

## Requirements

- monome norns
- SuperCollider (included with norns)
- monome arc (optional - provides tactile parameter control with LED feedback)
- monome grid (optional - provides pattern sequencing and parameter manipulation)
- MIDI keyboard or controller (optional - plays voices with velocity and pitchbend; CCs through norns' PARAMS > MAP)

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

## Quick Start

1. The script starts with the Resonator and FM voices active
2. Use E2 to select different voices
3. Press K3 to start a voice (pressing it again locks the running voice)
4. Experiment with master density (arc ring 1 on the MAIN page, or PARAMETERS) to change the overall texture

## Documentation

- [Voices and Granular Processing](docs/user/voices-and-grains.md) - the seven voices, grain controls and performance features
- [Audio Sources and Buffers](docs/user/sources-and-buffers.md) - buffers, live input, saving and restoring
- [Modulation](docs/user/modulation.md) - cross-modulation, mutations and LFOs
- [Global Controls and Effects](docs/user/effects.md) - master density, drift, filter, delay, reverb, tempo
- [Scenes and Automation](docs/user/scenes.md) - scenes, the scene sequencer and composing with scenes
- [Screen Controls](docs/user/controls.md) - the eight screen pages (one file each under docs/user/pages/), E1, the header, ALT, fine adjustment and center detents
- [MIDI Input](docs/user/midi.md) - playing voices from MIDI and mapping CCs
- [Monome Grid](docs/user/grid.md) - grid sizes (one layout file each under docs/user/grid/), holds and step levels, and the pattern sequencer
- [Monome Arc](docs/user/arc.md) - arc rings, button and LED feedback
- [Parameters Reference](docs/user/params.md) - everything in the PARAMETERS menu
- [Usage Tips](docs/user/tips.md) - workflows and starting points
- [Technical Details](docs/user/technical.md) - architecture, signal flow and the development checks

## License

Strata is released under the MIT License; see [LICENSE](LICENSE).
