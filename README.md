# Strata

An ambient granular soundscape generator for monome norns.

## Overview

Strata creates evolving ambient textures by combining seven unique synthesis voices with granular processing. Each voice has its own character and can be individually controlled, randomized, and locked, and any voice can grain a sample buffer or the live input instead of its synth. The buffers are instruments of their own: record, overdub and loop into them while they play, and jump, loop, bookmark and scrub through them. A filter, delay and reverb, six global LFOs, scenes, MIDI input and grid and arc support complete it. The result is a layered sonic landscape perfect for experimental electronic music and ambient compositions.

This is version 3.4.0. Version 3.0 added buffers and live input, filter and delay, grain envelopes and triggered grains, LFOs, MIDI and a paged screen; 3.0.1 and 3.0.2 are fix releases. Version 3.1 makes everything playable from the norns alone: new VOICE, SEQ and SCENES pages, K1 held as ALT, lock and randomize undo, fine adjustment, arc rings on every page but SETUP and fuller layouts for the smaller grids. Version 3.2 adds a performance setting (a high tier on the Pi 4, with buffers up to 300 s), per-voice freeze, grain variation and scale quantize, loop regions for buffers, input history and a filter and effect sends per voice; every voice now transposes by grain rate. Version 3.3 makes the buffers instruments: overdub and loop recordings that keep playing while they record, record sources, takes armed by level or started on the clock, random loads, a long file's start point, saving a loop region, waveforms and playheads on the BUFFER page, position jumps and bookmarks, arc scrubbing with friction and a position page on every grid. Version 3.4 adds modulation and sequencing: six LFOs (the fast ones in the engine), sixteen macros, a morph between two or four scenes, scatter, gesture recorders and a modulation matrix on a new MOD page; a length, division and swing per voice, step probability, ratchets, locks, notes and gates, Euclidean fill and pattern chaining; sixteen named scenes, mute and solo, and actions that wait for the beat or bar. See [CHANGELOG.md](CHANGELOG.md).

## Features

- Seven synthesis voices (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring), each with its own granular processor
- Eight sample buffers (up to 300 s each on a Pi 4 norns) and a live stereo input with up to 60 s of history as alternative grain sources
- Recording into the buffers from the input, the master or any one voice: takes that replace a buffer, overdubs and loop recordings that keep playing while they record, armed by a level or started on the clock's beat or bar
- Random files from a folder, a start point anywhere in a long file, and saving a buffer or just its loop region
- Waveforms and playheads on the BUFFER page; position jumps, loops and four bookmarks per voice on every grid (and bookmark recalls on the BUFFER page); arc scrubbing that glides on with a set friction
- Per-voice freeze, grain variation (reverse, jitter, intervals), scale quantize and loop regions
- Cross-modulation between voices, six global LFOs (the fast ones run in the engine) and probability-based mutations
- Sixteen macros, a morph between two scenes or four (an XY pad on the 16×16 grid), scatter, gesture recorders and a sixteen-routing modulation matrix on the MOD page, with the live input's level as a source
- A filter and delay and reverb sends per voice; filter, delay, reverb and a limiter on the master output
- Sixteen named scenes in two banks, with smooth recall and a scene sequencer; actions that can wait for the beat or bar
- Mute and solo for every voice
- A nine-page screen UI that reaches every parameter, the patterns, the scenes and the modulation without a grid or arc
- A pattern sequencer (on the SEQ page and the grid) with a length, division and swing per voice, probability, ratchets, step locks, gates, Euclidean fill and scene chaining, MIDI input and monome arc support

## Requirements

- monome norns
- SuperCollider (included with norns)
- monome arc (optional - provides tactile parameter control with LED feedback)
- monome grid (optional - provides pattern sequencing and parameter manipulation)
- MIDI keyboard or controller (optional - plays voices with velocity and pitchbend; CCs through norns' PARAMS > MAP)

## Installation

Strata is not in the norns community catalog, so maiden's project manager does not list it. Install it in one of two ways, with the norns on your network:

### From maiden (recommended)

1. Open maiden, the norns web editor: browse to `http://norns.local` from a computer on the same network (or to the IP address the norns shows in SYSTEM > WIFI)
2. In the REPL at the bottom of maiden, on its `matron` tab, type `;install https://github.com/sethbc/strata` and press enter. maiden downloads the script into `~/dust/code/strata`

### With git, over SSH

Log in to the norns (`ssh we@norns.local`) and clone the repository into `~/dust/code`:

```bash
cd ~/dust/code
git clone https://github.com/sethbc/strata.git
```

### Then restart norns

After installing, restart norns from its own menu: SYSTEM > RESTART. Strata's engine is a set of SuperCollider classes, which norns compiles only as it restarts; until then the script cannot load its engine. Restart the same way after every update.

## Quick Start

1. The script starts with the Resonator and FM voices active, on the MAIN page
2. Use E2 to select a voice, and E3 to adjust its main parameter (K2 moves to grain size and grain density)
3. Press K3 to start or stop the selected voice. Hold K1 for ALT: ALT+K2 randomizes the voice (again within 5 s to undo) and ALT+K3 locks it
4. Turn E1 to reach the other pages: VOICE for every parameter of the voice, SEQ for the patterns, FX for master density and the effects, LFO for the six LFOs, MOD for the macros, morph, scatter, recorders and matrix, BUFFER to record, load and see the buffers, and SCENES to save and recall scenes (a saved scene is written to disk at once)

## Documentation

- [Voices and Granular Processing](docs/user/voices-and-grains.md) - the seven voices and their parameters, grain controls and performance features
- [Audio Sources and Buffers](docs/user/sources-and-buffers.md) - buffers, live input, recording, files, saving and restoring
- [Modulation](docs/user/modulation.md) - cross-modulation, mutations, the LFOs, the macros, the morph, scatter, the gesture recorders and the modulation matrix
- [Global Controls and Effects](docs/user/effects.md) - master density, drift, filter, delay, reverb, tempo
- [Scenes and Automation](docs/user/scenes.md) - scenes, the scene sequencer and composing with scenes
- [Sequencer](docs/user/sequencer.md) - each voice's pattern length, division and swing, step probability, ratchets, step locks, notes and gates, Euclidean fill, chaining and following the clock's transport
- [Screen Controls](docs/user/controls.md) - the nine screen pages (one file each under docs/user/pages/), E1, the header, ALT, fine adjustment and center detents
- [MIDI Input](docs/user/midi.md) - playing voices from MIDI and mapping CCs
- [Monome Grid](docs/user/grid.md) - grid sizes (one layout file each under docs/user/grid/), holds and step levels (since 3.4 a step key toggles its step when you let go, not when you press, and a step held 0.3 s opens the step editor), and the pattern sequencer
- [Monome Arc](docs/user/arc.md) - arc rings, button and LED feedback
- [Parameters Reference](docs/user/params.md) - everything in the PARAMETERS menu
- [Usage Tips](docs/user/tips.md) - workflows and starting points
- [Technical Details](docs/user/technical.md) - architecture, signal flow and the development checks

Page renders: `lua test/render_pages.lua <dir>` then `python3 test/render_pages.py <dir>` draw every screen page state as a PNG (`docs/status.md`, Running the checks).

## License

Strata is released under the MIT License; see [LICENSE](LICENSE).
