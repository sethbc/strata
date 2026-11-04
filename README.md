# Strata

An ambient granular soundscape generator for monome norns.

## Overview

Strata creates evolving ambient textures by combining seven unique synthesis voices with granular processing. Each voice has its own character and can be individually controlled, randomized, and frozen, and any voice can grain a sample buffer or the live input instead of its synth. A filter, delay and reverb, three global LFOs, scenes, MIDI input and grid and arc support complete it. The result is a layered sonic landscape perfect for experimental electronic music and ambient compositions.

Version 3.0 brings in the Confluence script's feature set (buffers and live input, filter and delay, grain envelopes and triggered grains, LFOs, MIDI, a paged screen); see [CHANGELOG.md](CHANGELOG.md).

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

Each voice has its own granular processor (reading the voice's synth, a buffer or the input; see Audio Sources) with independent control over:
- Grain size (texture density)
- Grain density (grains per second)
- Pitch shifting (true transposition, 0.25x-4x, with a subtle slow detune drift on unfrozen voices)
- Position spread (temporal smearing)
- Grain envelope (the shape of each grain: hann, sine, perc, linen or trap); scene transitions switch it at the end instead of crossfading, and mutations leave it alone
- Grain mode: **continuous** (grains stream at the grain density) or **triggered** (one grain per trigger; nothing sounds between triggers). The trigger's velocity sets the voice's accent, which the grain carries. In triggered mode grains fire from pattern steps (and MIDI notes); K3 keeps its start/freeze meaning, so it does not fire grains. Grain density does nothing in triggered mode, and neither does position spread unless the voice's source is a buffer (there it still jitters each grain's position). The MAIN page shows `[TRIG]` for a voice in triggered mode. Like the envelope, scene transitions switch it at the end and mutations leave it alone

### Audio Sources (buffers and live input)

Every voice can grain something other than its own synth. Its **source** (the BUFFER screen page, grid page 4, or PARAMETERS > the voice's granular section) is its synth (the default), one of eight sample buffers (`buf 1` to `buf 8`), or the live stereo input:
- **Buffers** hold up to 16 seconds of stereo audio each. Load a sound file, record the input, clear or save a buffer from the BUFFER screen page, grid page 4 (record and clear) or the PARAMETERS **buffers** group
- **Buffer position** (0-1 of the buffer's recorded or loaded length), **buffer rate** (0.25x-4x playback speed) and **buffer scan** (moves the position through the buffer, in buffer lengths per second, backwards when negative; 0 = static) shape a buffer-sourced voice. Grain size, density, pitch, spread, envelope and mode work as for synth voices
- While a voice's source is a buffer, E3, arc ring 2 and the MAIN screen show its buffer position (`pos`), the grid fader page shows its buffer position, rate, scan and level instead of the synthesis parameters, K2 randomizes the buffer parameters (and grain size and pitch) instead of the synthesis parameters, mutations change the buffer parameters, and the position drifts subtly around the value you set
- While a voice's source is the input, neither its synthesis nor its buffer parameters do anything, so E3, arc ring 2 and the MAIN screen show its grain size (`size`), the grid fader page starts with the grain parameters (then level), and K2, mutations and the drift change only the grain parameters
- The source itself is never randomized or mutated, and freeze keeps the buffer parameters still
- Several voices can read the same buffer, and any voice can be switched back to its synth at any time

### Cross-Modulation

Voices can modulate each other for evolving, interdependent textures:
- Each voice generates a modulation signal based on its audio output
- **Multi-Source Routing**: Each voice can be modulated by up to 3 different sources simultaneously
- Route any combination of voices to modulate another voice's amplitude and/or frequency
- Adjustable modulation depth per source for subtle or dramatic effects
- Creates complex, organic, evolving relationships between layers

### Global Controls and Effects

- **Master Density** - Controls grain density across all voices simultaneously
- **Tape Drift** - Adds slow pitch drift to the entire mix for analog warmth; the amount sets the depth (0 = none)
- **Filter** - Lowpass, highpass or bandpass filter on the whole mix with resonance; its mix fades from bypassed (the default) to fully filtered
- **Delay** - Stereo delay (10 ms to 2 s) with feedback, after the filter; starts dry
- **Reverb** - Adjustable mix (fully dry to fully wet), size, and damping
- **Limiter** - A limiter in the master stage catches peaks from filter resonance and delay feedback before the soft saturation
- **Tempo** - Sets norns' clock tempo, which the pattern sequencer follows

### Performance Features

- **Randomization** - Generate new parameter sets for each voice
- **Freeze** - Lock a voice's parameters while others continue to evolve
- **Drift** - A slow random walk adds subtle grain pitch movement to active voices that are not frozen; it always drifts back toward the pitch you set

### Probability-Based Mutations

Strata includes an optional mutation system for creating organic, evolving textures:
- **Probabilistic Evolution** - Each parameter has a chance to mutate at regular intervals
- **Adjustable Behavior** - Control mutation rate, probability, and amount via PARAMETERS menu
- **Smart Mutations** - Uses gaussian-like distribution for natural-sounding changes
- **Selective Application** - Only affects active, non-frozen voices
- **Preserved Stability** - Amplitude and pan are never mutated to maintain voice balance
- **Visual Feedback** - `[M]` indicator appears on screen when mutations are enabled

The mutation system works alongside the per-voice drift and the global LFOs, creating multiple layers of organic movement. Combine with the freeze feature to let some voices evolve while others remain stable.

### Global LFOs

Three LFOs, built on norns' own LFO library, can each modulate one parameter:
- **Shapes** - sine, tri, square, random, up, down
- **Rate** - free (a period from 0.1 s to 300 s) or clocked to the norns clock (the library's rates from 1/16 bar, a quarter beat, to 1024 bars)
- **Depth** - 0-100 %; at 100 % the LFO swings half the destination's range either side of its value
- **Destinations** - none, master density, tape drift, filter freq / res / mix, delay time / feedback / mix, reverb mix / size / damp, and for each voice: its main parameter (the one E3 adjusts: the synthesis parameter, or buffer position for a buffer-sourced voice, grain size for an input-sourced one), grain size, density, pitch, spread, buffer position, rate and scan
- **Modulates around your setting** - an LFO never changes the parameter's value; it moves the sound around it, so turning the knob still sets the centre. When an LFO is turned off, its depth reaches 0 or its destination changes, the parameter goes back to exactly its set value. Two LFOs on one destination add up

The fastest rate is 10 Hz (the library's 0.1 s free period); Confluence promised 20 Hz, which would need the LFOs in the engine instead of Lua. Each LFO updates 48 times per beat (96 times a second at 120 BPM) and only sends a new value to the engine when it has moved by at least 1/1000 of the destination's range, so slow LFOs cost very little. The grid has no LFO controls: use the LFO page, the arc or PARAMETERS.

### MIDI Input

A MIDI keyboard or sequencer plays the voices: one channel per voice (or every channel to the selected voice), the note sets the voice's pitch, the velocity sets its accent, and pitchbend bends it by up to 2 semitones. Any parameter can follow a MIDI CC through norns' own PARAMS > MAP. See MIDI under Controls.

### Scene System & Automation

Strata includes a comprehensive scene system for longer-form composition and automation:
- **8 Scene Slots** - Save complete snapshots of all voices, patterns, and parameters
- **Disk Persistence** - Scenes automatically save to disk and load on startup
- **Instant or Smooth Recall** - Jump immediately or crossfade between scenes
- **Scene Sequencer** - Automatically progress through scenes for hands-free composition
- **Complete State Capture** - Scenes store voice parameters and sources, patterns, freeze states, and global settings, including each LFO's state, shape, rate, depth and destination (not the audio in the sample buffers)
- **Grid Integration** - Dedicated scene page on grid for performance control
- **Visual Feedback** - `S1`-`S8` indicator shows current scene on screen

Perfect for creating structured ambient compositions with multiple movements or live performance setups with prepared sonic palettes. Scenes persist across script restarts, allowing you to build a library of sonic palettes.

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

### Screen Pages

The screen has five pages: **MAIN**, **FX**, **LFO**, **BUFFER** and **SETUP**.

- **E1** - Select the page (turn left toward MAIN, right toward SETUP; one page per short turn, without acceleration)

Every page shows the page name, master density (`dens:`), the `[M]` mutation indicator and the `S1`-`S8` scene indicator at the top, and the page's key hints on the bottom row. E2, E3, K2 and K3 do something different on each page. The arc follows the page too (see below).

Master density is no longer on E1: adjust it on the first row of the FX page, with arc ring 1 on the MAIN page, or in the PARAMETERS menu.

#### MAIN

- **E2** - Select voice (1-7)
- **E3** - Adjust selected voice's main parameter
  - Resonator: Frequency
  - FM: Modulation index
  - Folder: Fold amount
  - Sub: Drift amount
  - Pulse: Pulse width
  - Karplus: Decay time
  - Ring: Frequency ratio
  - Any voice whose source is a buffer: buffer position (`pos`)
  - Any voice whose source is the input: grain size (`size`)
- **K2** - Randomize selected voice parameters (buffer parameters for a buffer-sourced voice, only grain parameters for an input-sourced one)
- **K3** - Start the selected voice if it is off; if it is running, freeze/unfreeze it (it never stops a voice and never fires a triggered grain: stop voices from the grid, a scene or a MIDI note off)

`[TRIG]` on the main parameter row means the selected voice is in triggered grain mode.

#### FX

A scrolling list of the effects settings, five rows at a time: master density, tape drift, filter type / freq / res / mix, delay time / feedback (`fdbk`) / mix, reverb mix / size / damp. The selected row is bright.

- **E2** - Select a row
- **E3** - Adjust the selected row's value
- **K3** - Bypass the filter (mix to 0), or bring it back at the last mix it had above 0, however that was set (fully on if it has never been above 0). The hint row shows `K3:filter bypass` or `K3:filter on`

#### BUFFER

Where a voice's source is chosen and its buffer is filled, so it works without a grid. The left column shows the selected voice, its source (`src: buf 2`), and the record duration and level. The right column lists the eight buffers: number, name (the file name, shortened, or `take <n>` for a recording, or `empty`) and length in seconds, or `REC` while recording. A take shows `REC` until the engine reports what it captured (a moment after the recording ends): then it becomes `take <n>`, or `empty` if nothing was captured (a stop right after the start; a take the engine reports late still becomes `take <n>`, unless the buffer was cleared, loaded or recorded into meanwhile). A loaded file shows its name at once; if the engine reports no audio for it (an unreadable file), the buffer drops to dim. The selected voice's buffer is bright, buffers holding audio are mid, empty ones dim.

- **E2** - Select voice (the same selection as MAIN)
- **E3** - Cycle the voice's source: synth, buf 1 ... buf 8, input
- **K3** - Record the input into the voice's buffer for the record duration (replacing what was there); press again while recording to stop early and keep what was captured. Voices playing that buffer are silent while it records and play the new take as soon as it is done
- **K2** - Load a sound file into the voice's buffer: K2 acts when released and opens the file browser at `~/dust/audio`
- **K2 + K3** - Hold K2 and press K3 to save the voice's buffer to `~/dust/audio/strata/<date-time>-buf<n>.wav` (each K3 press while K2 is held saves again; releasing K2 then does not open the file browser). For 1.5 s the hint row confirms it with `saved buf <n>`, or shows `buf <n> empty` when the buffer holds no audio and nothing was saved
- The hint row reads `K2:load K3:rec K2+3:save` (`K3:stop` while the buffer records, `K3:...` while a take that has ended waits for the engine; K3 does nothing then). When the voice's source is the synth or the input there is no buffer: K2 and K3 do nothing and the hint row reads `K2:- K3:- E3:source`

Record duration and level are on arc rings 3 and 4 of this page (and in PARAMETERS > buffers).

#### LFO

One row per LFO: `L1`-`L3` (the selected one bright), one cycle of its shape, a dot that follows the LFO while it runs, its destination (`filt freq`, `v2 main`, ...) and `on`/`off` with its depth.

- **E2** - Select an LFO
- **E3** - Adjust the selected LFO's depth (1 % steps)
- **K2** - Next destination (wraps from the last voice's scan back to none)
- **K3** - Turn the selected LFO on or off
- Shape, rate, mode, phase and the other LFO settings are in PARAMETERS > LFO 1-3

#### SETUP

Shows how many grids are connected and their sizes, whether an arc is connected, how many of the 8 scene slots hold a scene, how many buffers were restored when the script started (`buffers: 3 restored`, counting a buffer once the engine reports audio in it; `buffers: 2 ok, 1 missing` when remembered files were not found), and the MIDI input: the port Strata listens to and the device on it (`midi 1: <device>`, shortened if the name is long, or `none`) and the channel mode (`ch: per voice`).

- **E2** - MIDI port (1-4)
- **E3** - MIDI channel mode (per voice, or omni to the selected voice)
- **K3** - Save scenes to disk (same as PARAMETERS > save scenes to disk)

### MIDI (optional)

A MIDI keyboard or sequencer plays the voices. Choose the port on the SETUP page (E2) or in PARAMETERS > midi; the port numbers are the norns SYSTEM > DEVICES > MIDI slots 1-4. Devices can be plugged in and out while Strata runs.

- **Channels** - In **per voice** mode (the default) MIDI channel 1 plays voice 1 (Resonator) ... channel 7 plays voice 7 (Ring); channels 8-16 are ignored. In **omni to selected** mode every channel plays the voice selected with E2
- **Notes** - A note sets the voice's pitch: its frequency for a synth voice (exact equal temperament, limited to 20 Hz-2 kHz), its buffer rate for a buffer-sourced voice (note 60 plays at rate 1, an octave up doubles it, limited to 0.25x-4x); an input-sourced voice takes no pitch. A voice that is off starts; then the note accents it at the note's velocity (Karplus plucks its string, a triggered-mode voice fires a grain). Voices keep their slow attacks: Strata is not a fast-attack synth, the velocity lands on the accent
- **Note off** - Ignored by default, so a note starts a voice that keeps sounding. Set PARAMETERS > midi > midi note off to **voice off** for gated playing: a voice stops when its last held note is released, and a note played while it is still fading out brings it back without restarting its synths
- **Pitchbend** - Bends the voice by up to 2 semitones either way (the buffer rate for a buffer-sourced voice). It is not saved in scenes; a voice started while the wheel is held starts bent. Changing the port or channel mode re-centres every bent voice. In omni mode the bend follows the selection: selecting another voice with the wheel off centre returns the old voice to pitch and bends the new one by the wheel's position
- **CC** - Strata has no fixed CC mapping: map CCs to any parameter with norns' PARAMS > MAP (below)

### MIDI CC mapping (norns PARAMS > MAP)

Any Strata parameter can follow a MIDI CC through norns' built-in mapping:

1. Open the norns menu (K1), go to PARAMETERS and choose **MAP >** (E2 to select it, K3 to enter). In EDIT or MAP, K1 + K3 switches between the two
2. Select a parameter with E2 and press K3 to open its mapping
3. With **learn** selected press K3 and move the knob or fader on your controller (or set the device, channel and CC by hand with E2/E3); the remaining fields set the CC and output ranges
4. K2 leaves the mapping and saves it. norns keeps Strata's mappings in `~/dust/data/strata/strata.pmap` and loads them every time the script starts

Confluence (the norns script Strata's buffers, FX, LFOs and MIDI input come from) suggested these CCs; they make a good starting point:

| CC | Controller | Strata parameter |
|----|------------|------------------|
| 1 | Mod wheel | master density |
| 7 | Volume | a voice's amp (for example voice 1 amp) |
| 10 | Pan | a voice's position spread (grain spread) |
| 74 | Brightness | filter freq |
| 71 | Resonance | filter res |
| 91 | Reverb | reverb mix |
| 93 | Chorus | delay mix |

Confluence mapped CC 7 to the global grain amplitude and CC 10 to position spread; Strata has neither as a single global parameter, so map them to the voices you play.

### Monome Arc (optional)

Strata supports the monome arc controller for hands-on parameter control with visual LED feedback.

#### Arc Encoders

The rings control the current screen page. Every ring that sets a value sweeps its parameter's whole range in half a turn (512 of the arc's 1024 ticks per revolution), following the parameter's curve (frequency, delay time and buffer rate are exponential, so each half of the sweep covers as much of the curve). The exceptions are the LFO page's depth rings (10 ticks per percent) and clocked rate (20 ticks per rate). On the **MAIN** page:

- **Ring 1** - Master density (0.1 to 2.0)
- **Ring 2** - Selected voice's main parameter (follows E3 mapping: buffer position for a buffer-sourced voice, grain size for an input-sourced one)
- **Ring 3** - Grain size for selected voice
- **Ring 4** - Grain density for selected voice

On the **FX** page:

- **Ring 1** - Filter frequency
- **Ring 2** - Filter resonance
- **Ring 3** - Delay time
- **Ring 4** - Delay mix

On the **BUFFER** page:

- **Ring 1** - Selected voice's buffer position
- **Ring 2** - Selected voice's buffer rate
- **Ring 3** - Record duration
- **Ring 4** - Record level

Rings 1 and 2 adjust the voice's buffer parameters whatever its source (ready for when it switches to a buffer), but are drawn dim unless the source is a buffer.

On the **LFO** page:

- **Rings 1-3** - Depth of LFO 1-3 (10 ticks per percent; bright while the LFO runs)
- **Ring 4** - Period of the LFO selected on the page: the free period, or the clocked rate when its mode is clocked (part-turns toward the next rate are forgotten when you select another LFO or change its mode)

On the **SETUP** page the rings are off and do nothing.

#### Arc Button (2025 model)

- **Button** - On the MAIN page, same as K3 (start the voice if it is off, otherwise freeze/unfreeze it); does nothing on the other pages

#### LED Feedback

- Ring position shows the current parameter value
- MAIN: bright rings (level 15/12) for a running voice, dim (4/3) for a stopped one
- FX: level 12; frequency and delay time follow their exponential curve
- BUFFER: rings 1-2 bright (15) for a buffer-sourced voice, dim (4) otherwise; rings 3-4 at 12
- LFO: depth rings bright (15) while the LFO runs, dim (4) when off; ring 4 at 12

### Monome Grid (optional)

Strata includes comprehensive grid integration for pattern sequencing and parameter manipulation. Supports multiple grids simultaneously and adapts layout based on grid size.

The grid has no LFO controls (no layout has room for them); the LFOs live on the screen's LFO page, the arc's LFO page and in PARAMETERS.

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
- Columns 5-8: Tempo adjustment (-10, -1, +1, +10 BPM; sets norns' clock tempo)
- Columns 13-16: Page selection (1-4; page 2 = parameters, page 3 = scenes, page 4 = buffers / FX)

**Rows 9-12: Parameter Faders** (Page 2)
- Each row is a fader for one parameter of the voice selected in row 14
- Press a column to set the value: column 1 = minimum, column 16 = maximum, following each parameter's curve (frequency and cutoff faders are exponential, so low frequencies get as many columns as high ones)
- The row lights up to the current value (dim bar, bright value position)
- The grain envelope fader steps through its five shapes (column 1 = hann, column 16 = trap); the grain mode fader is continuous on columns 1-8 and triggered on columns 9-16
- Faders run through the voice's synthesis parameters (amp and pan last), then grain size, density, pitch, spread, envelope and mode, then source / amp mod / freq mod for cross-modulation slots 1-3
- For a voice whose source is a buffer, the first faders are buffer position, rate, scan and level instead of the synthesis parameters; for an input-sourced voice the faders start with grain size (the grain parameters, then level)

**Row 13: Fader Page Selection** (Page 2)
- Each fader page shows the next four parameters (rows 9-12)
- Columns 1-4, 1-5 or 1-6 select the page, depending on how many parameters the voice has (Folder and Sub have 5 pages, the other voices 6; a buffer-sourced voice has 5, an input-sourced one 4); the selected page is bright

**Row 14: Voice Selection & Status**
- Columns 1-7: Select voice for parameter editing
- Columns 9-15: Toggle voices on/off

**Row 15: Pattern Operations**
- Columns 1-7: Clear pattern for each voice
- Columns 9-15: Randomize pattern for each voice

**Row 16: Voice Freeze**
- Columns 1-7: Freeze/unfreeze each voice

**Scene Page (Page 3)**
- **Row 1**: Scene recall (instant) - Press to immediately load scenes 1-8
- **Row 2**: Scene recall (with transition) - Press to smoothly crossfade into scenes 1-8
- **Row 3**: Scene save - Press to capture current state to scenes 1-8
- **Row 5, Column 1**: Toggle scene sequencer on/off
- **Row 5, Columns 3-10**: Set scene sequence length (1-8)
- **Row 8, Columns 13-16**: Page selection (same as other pages)

Scene LED feedback:
- Populated scenes glow (brightness 6-8)
- Current scene is bright (brightness 15)
- Empty scenes are dim (brightness 2)
- Sequencer shows next scene position when active

**Buffers / FX Page (Page 4)**
- **Row 1, Columns 1-8**: Record the input into buffer 1-8 for the record duration; press again while it records to stop early. Lit 15 while recording, 8 when the buffer holds audio, 2 when empty
- **Row 2, Columns 1-8**: Clear buffer 1-8 (lit 4)
- **Rows 3-7**: Faders for filter frequency, filter resonance, delay time, delay feedback and delay mix. Press a column to set the value (column 1 = minimum, column 16 = maximum; frequency and delay time are exponential); the row lights up to the current value and follows changes made on the screen, arc or by a scene
- **Row 8**: Play/stop, tempo and page selection, as on page 1
- **Rows 9-15**: One row per voice (row 9 = voice 1 ... row 15 = voice 7) choosing its source: column 1 = synth, columns 2-9 = buffer 1-8, column 10 = input. The selected source is lit 15, the others 4, empty buffers 2. Columns 11-16 do nothing
- **Row 16**: Freeze/unfreeze each voice, as on page 1
- The LEDs follow buffer and source changes made anywhere (screen, PARAMETERS, scenes, a recording finishing)
- The 16×8, 8×16 and 8×8 layouts have no buffers / FX page: choose sources and manage buffers on the BUFFER screen page or in PARAMETERS

#### 16×8 Grid Layout (128 buttons horizontal)

**Rows 1-7: Pattern Sequencer**
- 16 steps per voice pattern

**Row 8: Multi-function Controls**
- Columns 1-4: Play/stop
- Column 5: Patterns page
- Column 6: Parameters page
- Column 7: Scenes page
- Columns 9-15: Voice toggle on/off
- Column 16: Cycle voice selection

**Scenes page (row 8, column 7)**
- Row 1: Scene recall (instant), scenes 1-8
- Row 2: Scene recall (with transition)
- Row 3: Scene save
- Row 4: Set scene sequence length (1-8)
- Row 5, Column 1: Toggle scene sequencer

#### 8×16 Grid Layout (128 buttons vertical)

**Columns 1-7: Pattern Sequencer**
- 16 steps per voice (vertical orientation)

**Column 8: Controls**
- Rows 1-7: Toggle voices on/off
- Row 9: Play/stop sequencer
- Rows 10-16: Voice selection for parameters (row 10 = voice 1 ... row 16 = voice 7)

#### 8×8 Grid Layout (64 buttons)

**Rows 1-7: Pattern Sequencer**
- Only steps 1-8 of each pattern are shown and editable here
- Patterns are still 16 steps long: steps 9-16 (set on a larger grid or by randomize/scene recall) keep playing, but are not visible on this grid

**Row 8: Essential Controls**
- Column 1: Play/stop
- Columns 3-7: Toggle first 5 voices

#### Pattern Sequencer Features

- **16-step patterns** per voice (only steps 1-8 are visible on a 64-button grid)
- **Per-voice patterns** - each voice has independent pattern
- **Real-time recording** - toggle steps while playing
- **Visual feedback** - the step that just played is highlighted (bright if active, dim if empty)
- **Tempo control** - 40-300 BPM (adjustable via grid or PARAMS)
- **Pattern operations** - clear, randomize per voice
- **Automatic voice triggering** - a step starts a voice that is off, and gives a running voice a short accent (Karplus re-plucks its string) without restarting it; a voice in triggered grain mode also fires one grain
- **Step level is velocity** - a step's brightness (1-15) sets how strong its accent is (a triggered grain carries that accent): level 15 is full, level 6 is 6/15. Steps set by hand are 15; randomized patterns use levels 8-15

#### Multi-Grid Support

- Connect up to 4 grids simultaneously
- Each grid shows the same interface
- Hot-plug support - connect/disconnect grids while running
- All grids stay synchronized

## Usage Tips

### Getting Started

1. The script starts with the Resonator and FM voices active
2. Use E2 to select different voices
3. Press K3 to start a voice (pressing it again freezes the running voice)
4. Experiment with master density (arc ring 1 on the MAIN page, or PARAMETERS) to change the overall texture

### Creating Evolving Textures

- Start with 2-3 voices active
- Use K2 to randomize individual voices until you find interesting combinations
- Freeze voices you like with K3
- Adjust master density (arc ring 1 or PARAMETERS) to create movement
- Add reverb or delay on the FX page for more space

### Exploring Cross-Modulation

- Open PARAMETERS menu and navigate to a voice's cross-modulation section
- Each voice has 3 modulation slots that can be independently configured:
  - **Slot 1**: Set "mod source 1" to another active voice (e.g., voice 2)
  - Adjust "amp mod 1" (0.5 to 1.5 is a good starting range for amplitude modulation)
  - Try "freq mod 1" for pitch variation (start subtle: 0.1 to 0.3)
  - **Slot 2**: Add a second modulation source to create complex interactions
  - **Slot 3**: Add a third source for even more intricate modulation networks
- Experiment with different multi-source routing combinations
- Create modulation networks (voice 1 → 2, voice 2 → 3, voice 3 → 1) for complex evolution
- Mix multiple sources on a single voice (e.g., voice 1 modulated by voices 2, 4, and 7)
- Use positive and negative modulation amounts to create push-pull relationships

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
- Watch the `[M]` indicator on screen to confirm mutations are active
- For dramatic changes, increase probability to 0.25+ and amount to 0.40+
- For subtle drift, decrease both values and increase the mutation rate

### Using Scenes for Composition

**Building a Scene-Based Composition**:
1. Create your first sonic texture using voices, patterns, and parameters
2. Navigate to grid page 3 (or use PARAMETERS menu)
3. Press row 3 to save the scene (scenes 1-8)
4. Build a contrasting or complementary texture
5. Save to another scene slot
6. Repeat until you have 3-8 distinct scenes

**Manual Scene Performance**:
- Press row 1 buttons for instant scene changes (good for rhythmic switching)
- Press row 2 buttons for smooth crossfades (good for ambient transitions)
- Adjust transition time in PARAMETERS to control crossfade duration

**Automatic Scene Sequencing**:
- Set scene sequence length (how many scenes to cycle through)
- Set scene duration (how long each scene plays)
- Set transition time (crossfade duration between scenes)
- Press row 5, column 1 to start/stop the sequencer
- Watch `S1`-`S8` indicator on screen (bright = sequencer active)

**Creative Tips**:
- Use scenes to create song structure: intro → verse → chorus → bridge
- Combine with mutations: save some scenes with mutations on, others with mutations off
- Freeze different voices in different scenes for evolving vs static sections
- Scenes remember pattern data - create rhythmic scenes and ambient scenes

## Parameters

Everything is in the PARAMETERS menu. The menu shows the master settings, mutations and scenes first, then the **fx**, **lfo destinations**, **LFO 1-3**, **buffers** and **midi** groups, then one section per voice. Grouped by topic:

### Master
- Master density
- Tempo (40-300 BPM; sets norns' clock tempo, starts at the current clock tempo)

### FX (group)
- Filter type (lowpass, highpass, bandpass)
- Filter freq (20-20000 Hz, default 5000)
- Filter res (0-1, default 0.5)
- Filter mix (0 = bypass, the default, to 1)
- Delay time (0.01-2 s, default 0.375)
- Delay feedback (0-0.95, default 0.4)
- Delay mix (0 = dry, the default, to 1)
- Reverb mix, size and damping
- Tape drift amount (depth of the drift; 0 = none)

### LFOs
- **lfo destinations** (group) - LFO 1-3 dest (none by default)
- **LFO 1**, **LFO 2**, **LFO 3** (groups, the norns LFO library's own parameters) - lfo state (off by default), shape (sine), depth (0-100 %, default 0), phase, offset, scaled and raw value (read-only), min/max (keep -1 and 1) and baseline (keep "from center"): Strata's depth math assumes all three. With min -1, max 1 and a centre baseline an LFO swings up to half the destination's range either side of the value you set; "from min" makes it swing only below that value (down to half the range at 100 %), "from max" only above it, and other min/max values change the swing size, mode (free) and rate (4 s free, or a clocked rate), reset and reset target. Turning an LFO on shows the rest of its settings

### Buffers (group)
- Record duration (0.5-16 s, default 8) and record level (0-2, default 1)
- For each buffer 1-8:
  - File: load a sound file (up to 16 s; stereo files keep both channels, mono files fill both). Loading never copies the file
  - Record: record the live input for the record duration, replacing what was there. Trigger it again while recording to stop early and keep what was captured. The finished take is also written to `~/dust/audio/strata/scratch/buf<n>.wav` (overwritten by the next take)
  - Clear: empty the buffer
  - Save: write the buffer as a stereo WAV to `~/dust/audio/strata/<date-time>-buf<n>.wav`, so it can be loaded again later (an empty buffer is not saved)

#### Saving and restoring buffers

Strata writes audio to disk only when a recording finishes and when you save a buffer:
- **Scratch take** - Every finished (or early-stopped) recording is written to `~/dust/audio/strata/scratch/buf<n>.wav`, replacing that buffer's previous take. It exists so the take survives a restart; save the buffer to keep it
- **Save** - The buffer's save trigger (PARAMETERS > buffers, or K2 + K3 on the BUFFER page) writes a new timestamped file, `~/dust/audio/strata/<date-time>-buf<n>.wav`, which appears in the file browser for loading later. Nothing is overwritten
- **Restore on start** - When the script exits it remembers, for each buffer, the file loaded into it or its scratch take (in `~/dust/data/strata/buffers.data`, a list of paths, not audio). On the next start each remembered file that still exists is loaded again, so scenes that use buffers are not silent after a reboot. A file that is not found (deleted, moved, or on a drive that is not mounted) is skipped and the console names it, but its path is kept for the next start, so the sample comes back once the file is there again; clearing, loading or recording into that buffer forgets it. The SETUP page shows how many buffers were restored (those the engine reports holding audio) and how many remembered files are missing
- A damaged or incompatible `buffers.data` loads nothing, is reported in the console and is moved to `buffers.data.bak` so the save on exit does not overwrite it

### MIDI (group)
- MIDI device: the port Strata listens to (1-4, default 1)
- MIDI channels: per voice (channels 1-7 play voices 1-7, the default) or omni to selected
- MIDI note off: ignore (the default) or voice off

### Mutations
- Mutations enabled (on/off)
- Mutation rate (0.5-10 seconds)
- Mutation probability (0-1, chance per parameter)
- Mutation amount (0-1, size of changes)

### Scenes
- Scene sequencer (on/off)
- Scene transition time (0-30 seconds)
- Scene duration (4-120 seconds)
- Scene sequence length (1-8 scenes)
- Save scenes to disk (manual trigger)
- Load scenes from disk (manual trigger; a damaged or incompatible file is reported in the console, the current scenes are kept, and the file is moved to `scenes.data.bak` so it is not overwritten when the script exits)
- Scene files from earlier versions of Strata still load: settings they do not contain (filter, delay, grain envelope and mode, sources and buffer settings, LFOs) start at their defaults (LFOs off, every voice on its synth), and the console prints `migrated scenes file from version 1`. The file is saved in the new format when the script exits

Scenes capture the FX settings too; smooth transitions crossfade every FX value except the filter type, which switches at the end.

Scenes capture each voice's source and buffer position, rate and scan, but **not the audio in the buffers**: a recalled scene plays whatever is in the buffer now. A voice's source switches at the end of a smooth transition; the buffer parameters crossfade. LFO depths and free periods crossfade too; the other LFO settings switch at the end.

### Per-Voice Sections
Each voice includes:
- Synthesis parameters (varies by voice type)
- Source (synth, buf 1-8, input; default synth)
- Buffer position (0-1, default 0), buffer rate (0.25-4, default 1) and buffer scan (-2 to 2, default 0)
- Grain size
- Grain density
- Grain pitch shift (transposition ratio)
- Position spread
- Grain envelope (hann, sine, perc, linen, trap; default hann)
- Grain mode (continuous or triggered; default continuous)
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
- Per-voice granular processors: two `GrainIn`s (left and right) followed by one `PitchShift` for a synth- or input-sourced voice, two sample-aligned `GrainBuf`s (left and right) followed by one `PitchShift` for a buffer-sourced voice; both pan their grains the same way (position spread)
- Eight stereo buffers (each a pair of 16 s mono buffers, about 49 MB in all) and a live stereo input bus
- Switching a voice's source replaces its grain synth; synths never stack
- Cross-modulation routing via control buses
- Each voice generates a modulation signal from its output (buffer- and input-sourced voices copy their grains back to their voice bus, so they modulate other voices too)
- Master effects chain: multimode filter, stereo delay, reverb
- A limiter, then soft saturation, on master output
- The LFOs and MIDI run in the Lua script and reach the engine as parameter changes

### Audio Signal Flow

```
Voice Synth → Voice Bus → Granular Processor → Main Bus → Filter → Delay → Reverb → Master (drift, limiter, saturation) → Output
                  ↓
              Mod Synth → Mod Bus → Other Voice Synths (cross-modulation)

Buffer source:  Buffer (L/R) → Buffer Granular Processor → Main Bus (and the Voice Bus, for the Mod Synth)
Input source:   Audio input → Input Bus → Granular Processor → Main Bus (and the Voice Bus, for the Mod Synth)
```

## Requirements

- monome norns
- SuperCollider (included with norns)
- monome arc (optional - provides tactile parameter control with LED feedback)
- monome grid (optional - provides pattern sequencing and parameter manipulation)
- MIDI keyboard or controller (optional - plays voices with velocity and pitchbend; CCs through norns' PARAMS > MAP)

## Development

Off-device checks (no norns needed):
- `lua test/run.lua` (or `luajit test/run.lua`) - behaviour tests against norns stubs
- `lua test/sync_check.lua` - checks Lua `engine.*` calls against the engine's commands
- `test/run_engine_check.sh [path/to/norns]` - compiles and exercises the SuperCollider engine against the norns `sc/core` classes (requires SuperCollider)

`test/run.lua` also checks that CLAUDE.md's engine command table lists exactly the engine's commands.

GitHub Actions (`.github/workflows/test.yml`) runs all three on every pull request and on pushes to `main`: the Lua tests under Lua 5.3 (the version norns runs) and LuaJIT, and the engine check on Ubuntu with SuperCollider, a dummy JACK server and `monome/norns` at a pinned commit. Both jobs (`lua`, `engine`) are required to pass before a pull request can merge into `main`.

## Credits

Created for experimental ambient electronic music production.

