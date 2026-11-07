# Parameters Reference

Everything in the norns PARAMETERS menu, grouped by topic. Back to the [README](../../README.md).

Everything is in the PARAMETERS menu. The menu shows the master settings, mutations and scenes first, then the **fx**, **lfo destinations**, **LFO 1-3**, **buffers** and **midi** groups, then one section per voice. Grouped by topic:

## Master
- Master density
- Tempo (1-300 BPM, the range of norns' clock tempo; sets norns' clock tempo, starts at the current clock tempo)

## FX (group)
- Filter type (lowpass, highpass, bandpass)
- Filter freq (20-20000 Hz, default 5000)
- Filter res (0-1, default 0.5)
- Filter mix (0 = bypass, the default, to 1)
- Delay time (0.01-2 s, default 0.375)
- Delay feedback (0-0.95, default 0.4)
- Delay mix (0 = dry, the default, to 1)
- Reverb mix, size and damping
- Tape drift amount (depth of the drift; 0 = none)

## LFOs
- **lfo destinations** (group) - LFO 1-3 dest (none by default)
- **LFO 1**, **LFO 2**, **LFO 3** (groups, the norns LFO library's own parameters) - lfo state (off by default), shape (sine), depth (0-100 %, default 25 %, so an LFO is audible as soon as it is turned on; scenes recall the depth they stored), phase, offset, scaled and raw value (read-only), min, max and baseline, mode (free) and rate (4 s free, or a clocked rate), reset and reset target. Turning an LFO on shows the rest of its settings
- Keep min at -1, max at 1 and the baseline at "from center": Strata's depth math assumes all three. With them an LFO swings up to half the destination's range either side of the value you set. "From min" starts the swing half the range below that value (it reaches above the value only past 50 % depth), "from max" starts it half the range above (and swings half as wide as "from min"), and other min/max values change the size of the swing

## Buffers (group)
- Record duration (0.5 s to the buffer length: 16 s, or up to 300 s on the high tier; default 8) and record level (0-2, default 1)
- For each buffer 1-8:
  - File: load a sound file (up to the buffer length at 48 kHz, 16 s on the standard tier, so a 96 kHz file keeps half of it; stereo files keep both channels, mono files fill both). Loading never copies the file. A file that cannot be read leaves the buffer as it was, but stops a recording in it (nothing is kept). A voice playing the buffer fades out before a load, recording or clear replaces what it plays
  - Record: record the live input for the record duration, replacing what was there. Trigger it again while recording to stop early and keep what was captured. The finished take is also written to `~/dust/audio/strata/scratch/buf<n>.wav` (overwritten by the next take)
  - Clear: empty the buffer
  - Save: write the buffer as a stereo 16-bit WAV to `~/dust/audio/strata/<date-time>-buf<n>.wav`, so it can be loaded again later (an empty buffer is not saved). A take recorded at a level above 1 can go past full scale: saved takes (and the scratch take) are clipped to full scale

How buffers are saved, written to disk and restored at startup is described in [Saving and restoring buffers](sources-and-buffers.md#saving-and-restoring-buffers).

## MIDI (group)
- MIDI device: the port Strata listens to (1-4, default 1)
- MIDI channels: per voice (channels 1-7 play voices 1-7, the default) or omni to selected
- MIDI note off: ignore (the default) or voice off

## Mutations
- Mutations enabled (on/off)
- Mutation rate (0.5-10 seconds)
- Mutation probability (0-1, chance per parameter)
- Mutation amount (0-1, size of changes)

## Scenes
- Scene sequencer (on/off)
- Scene transition time (0-30 seconds)
- Scene duration (4-120 seconds; a scene plays at least as long as its transition)
- Scene sequence length (1-8 scenes)
- Save scenes to disk (manual trigger)
- Load scenes from disk (manual trigger; a damaged or incompatible file is reported in the console, the current scenes are kept, and the file is moved to `scenes.data.bak` so it is not overwritten when the script exits)
- Scene files from earlier versions of Strata still load: settings they do not contain (filter, delay, grain envelope and mode, sources and buffer settings, LFOs) start at their defaults (LFOs off, every voice on its synth), and the console prints `migrated scenes file from version 1`. The file is saved in the new format when the script exits

Scenes capture the FX settings too; smooth transitions crossfade every FX value except the filter type, which switches at the end.

Scenes capture each voice's source and buffer position, rate and scan, but **not the audio in the buffers**: a recalled scene plays whatever is in the buffer now. A voice's source switches at the end of a smooth transition; the buffer parameters crossfade. LFO depths and free periods crossfade too; the other LFO settings switch at the end.

## Per-Voice Sections
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
