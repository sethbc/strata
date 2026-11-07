# Monome Grid

Grid layouts for every supported size, the pattern sequencer and multi-grid support. Back to the [README](../../README.md).

Strata includes comprehensive grid integration for pattern sequencing and parameter manipulation. Supports multiple grids simultaneously and adapts layout based on grid size.

The grid has no LFO controls (no layout has room for them); the LFOs live on the screen's LFO page, the arc's LFO page and in PARAMETERS.

## Supported Grid Sizes

- **256 (16×16)** - Full featured layout with patterns, parameters, and controls
- **128 horizontal (16×8)** - Pattern sequencing with essential controls
- **128 vertical (8×16)** - Pattern sequencing optimized for vertical layout
- **64 (8×8)** - Basic pattern sequencing (8 steps per voice)

## 16×16 Grid Layout (256 buttons)

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
- Faders whose range runs through zero (pan, buffer scan and the cross-modulation amounts) have a column that sets exactly zero (column 9 for their symmetric ranges); each side of it spreads its half of the range over its own columns
- The row lights up to the current value (dim bar, bright value position)
- The grain envelope fader steps through its five shapes (column 1 = hann, column 16 = trap); the grain mode fader is continuous on columns 1-8 and triggered on columns 9-16
- Faders run through the voice's synthesis parameters (amp and pan last), then grain size, density, pitch, spread, envelope and mode, then source / amp mod / freq mod for cross-modulation slots 1-3
- For a voice whose source is a buffer, the first faders are buffer position, rate, scan, level and pan instead of the synthesis parameters; for an input-sourced voice the faders start with grain size (the grain parameters, then level and pan). The sub voice has no pan, so it has no pan fader

**Row 13: Fader Page Selection** (Page 2)
- Each fader page shows the next four parameters (rows 9-12)
- Columns 1-4, 1-5 or 1-6 select the page, depending on how many parameters the voice has (Folder and Sub have 5 pages, the other voices 6; a buffer- or input-sourced voice has 5, except an input-sourced Sub, which has 4); the selected page is bright

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
- **Row 3**: Scene save - Hold for half a second to capture the current state to scenes 1-8. The key lights up while you hold it; letting go sooner saves nothing, so a stray press never overwrites a scene
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

## 16×8 Grid Layout (128 buttons horizontal)

**Rows 1-7: Pattern Sequencer**
- 16 steps per voice pattern

**Row 8: Multi-function Controls**
- Columns 1-4: Play/stop (all four light while the pattern plays)
- Column 5: Patterns page
- Column 6: Selects page 2, which looks and behaves exactly like the patterns page on this layout (the parameter faders exist only on the 256)
- Column 7: Scenes page
- Columns 9-15: Voice toggle on/off
- Column 16: Cycles the selected voice, which only matters for the 256's faders; it has no visible effect on this layout

**Scenes page (row 8, column 7)**
- Row 1: Scene recall (instant), scenes 1-8
- Row 2: Scene recall (with transition)
- Row 3: Scene save (hold for half a second, as on the 256)
- Row 4: Set scene sequence length (1-8)
- Row 5, Column 1: Toggle scene sequencer

## 8×16 Grid Layout (128 buttons vertical)

**Columns 1-7: Pattern Sequencer**
- 16 steps per voice (vertical orientation)

**Column 8: Controls**
- Rows 1-7: Toggle voices on/off
- Row 9: Play/stop sequencer
- Rows 10-16: Select the voice (row 10 = voice 1 ... row 16 = voice 7) and light the selected one. The selection only matters for the 256's faders, so it has no effect on this layout

## 8×8 Grid Layout (64 buttons)

**Rows 1-7: Pattern Sequencer**
- Only steps 1-8 of each pattern are shown and editable here
- Patterns are still 16 steps long: steps 9-16 (set on a larger grid or by randomize/scene recall) keep playing, but are not visible on this grid

**Row 8: Essential Controls**
- Column 1: Play/stop
- Columns 3-7: Toggle first 5 voices

## Pattern Sequencer Features

- **16-step patterns** per voice (only steps 1-8 are visible on a 64-button grid)
- **Per-voice patterns** - each voice has independent pattern
- **Real-time recording** - toggle steps while playing
- **Visual feedback** - the step that just played is highlighted (bright if active, dim if empty)
- **Tempo control** - 1-300 BPM, the range of norns' clock tempo (adjustable via grid or PARAMS)
- **Pattern operations** - clear, randomize per voice
- **Automatic voice triggering** - a step starts a voice that is off, and gives a running voice a short accent (Karplus re-plucks its string) without restarting it; a voice in triggered grain mode also fires one grain
- **Step level is velocity** - a step's brightness (1-15) sets how strong its accent is (a triggered grain carries that accent): level 15 is full, level 6 is 6/15. Steps set by hand are 15; randomized patterns use levels 8-15
- **Setting a step's level** - hold a step key and press another key of the same voice: the held step's level becomes that key's share of 15 along the voice's steps (column 16 = 15, column 8 = 8, column 1 = 1; on the 8×8, column 8 = 15 and column 4 = 8; on the 8×16, down the voice's column). The second key does not toggle its own step. Press more keys while still holding to try other levels

## Multi-Grid Support

- Connect up to 4 grids simultaneously
- Each grid has its own page: one grid can show the patterns while another shows the scenes. Patterns, voices and everything else are shared
- Hot-plug support - connect/disconnect grids while running. A grid plugged in starts on page 1; unplugging a grid while a scene save key is held saves nothing
