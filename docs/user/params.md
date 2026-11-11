# Parameters Reference

Everything in the norns PARAMETERS menu, grouped by topic. Back to the [README](../../README.md).

After norns' own settings, the menu shows Strata's master settings, mutations and scenes first, then the **fx**, **lfo destinations**, **LFO 1-3**, **buffers**, **record**, **positions** and **midi** groups, then the **scale** section, then one section per voice. Grouped by topic:

PSETs (PARAMETERS > PSET) save every one of them, and a hidden format line that tells a PSET saved now from one saved before 3.3. An older PSET loads as it sounded: the Pulse voice's res, which ran the other way before 3.3, is turned around as it loads (see [Per-Voice Sections](#per-voice-sections)), until you save it again. Any PSET's whole-number settings (a modulation source, the sequence length, ...) load as whole numbers, even if a fraction was saved.

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
- Tape drift amount (depth of the pitch drift; 0 = none, default 0.01 = ±0.2 %; it bends the pitch only, with no flutter in the level)
- Delay bypass and reverb bypass (off by default): switch the effect off completely, freeing its CPU and memory, and keep its mix (see [Bypass](effects.md#bypass)). PSETs store them; scenes do not

## LFOs
- **lfo destinations** (group) - LFO 1-3 dest (none by default)
- **LFO 1**, **LFO 2**, **LFO 3** (groups, the norns LFO library's own parameters) - lfo state (off by default), shape (sine), depth (0-100 %, default 25 %, so an LFO is audible as soon as it is turned on; scenes recall the depth they stored), phase, offset, scaled and raw value (read-only), min, max and baseline, mode (free) and rate (4 s free, or a clocked rate), reset and reset target. Turning an LFO on shows the rest of its settings
- Keep min at -1, max at 1 and the baseline at "from center": Strata's depth math assumes all three. With them an LFO swings up to half the destination's range either side of the value you set. "From min" starts the swing half the range below that value (it reaches above the value only past 50 % depth), "from max" starts it half the range above (and swings half as wide as "from min"), and other min/max values change the size of the swing. Min never goes above max: setting min above max moves max up with it, and setting max below min moves min down with it (norns' LFO library stops every LFO when a random LFO's min is above its max)

## Buffers (group)
- Record duration (0.5 s to the buffer length: 16 s, or up to 300 s on the high tier; default 8) and record level (0-2, default 1)
- For each buffer 1-8:
  - File: load a sound file (up to the buffer length at 48 kHz, 16 s on the standard tier, so a 96 kHz file keeps half of it; stereo files keep both channels, mono files fill both). Loading never copies the file. A file that cannot be read leaves the buffer as it was, but stops a recording in it (nothing is kept). A voice playing the buffer fades out before a load, recording or clear replaces what it plays. A file in a folder whose name holds `$`, a backtick, `\` or `"` loads and is restored at the next start, but this parameter and PSETs do not show or save it (the parameter shows the buffer as empty), since norns would run that folder name as a command when it lists the folder
  - Record: record into the buffer with the record settings (the source, feedback, loop, threshold and sync of the [Record group](#record-group) below), for the record duration, or the record beats with sync on. With feedback 0 and loop off it replaces what was there; otherwise the buffer keeps playing while it records. Trigger it again to stop: a recording keeps what it captured, one still waiting to start (for its threshold, beat or bar) is canceled, recording nothing. Every finished recording is also written to `~/dust/audio/strata/scratch/buf<n>.wav` (overwritten by the next one)
  - Clear: empty the buffer
  - Save: write the buffer as a stereo 16-bit WAV to `~/dust/audio/strata/<date-time>-buf<n>.wav`, so it can be loaded again later (an empty buffer is not saved). A take recorded at a level above 1 can go past full scale: saved takes (and the scratch take) are clipped to full scale

How buffers are saved, written to disk and restored at startup is described in [Saving and restoring buffers](sources-and-buffers.md#saving-and-restoring-buffers).

## Record (group)
Settings for the BUFFER page's record key (K3), the grid's record keys and each buffer's Record trigger. They are saved in PSETs, not in scenes. Record duration and level are in the buffers group.
- Record source: input (default), pre-master (the master before its effects), post-master (after them, Strata's own output only: norns' monitor, softcut and TAPE are mixed outside SuperCollider and not heard) or voice 1-7
- Record feedback (0-100%, default 0): how much of the old audio a recording keeps. At 0 with loop off, a recording replaces the buffer (a take); otherwise it plays on while it records
- Record loop (off/on): wrap over the first record-duration seconds until stopped
- Record threshold (off, -48 to -6 dB in 6 dB steps): wait for the source to pass this level before recording
- Record sync (off, beat, bar): start on the next beat or bar of the norns clock, at least 0.25 s ahead. With sync on, the length is record beats (1-64, default 16) at the tempo when it starts, at most the buffer length
- Trigger Record while a recording waits or records to stop it

## Positions (group)
- Scrub friction (0-100%, default 100%): how far the arc's scrub ring keeps going when you let go of it. At 100% the ring moves the buffer position directly and stops with your finger; below it, a flick keeps the position moving in the same direction at the speed you turned it and slows down, for longer the lower the friction. At 0% the glide loses about two thirds of its speed every 4 s and stops after 16 to 31 s (16 s for a flick of a twentieth of the loop a second, 28 s for one loop a second, 31 s for two); a friction of 50% halves those times (8 to 15 s), 75% quarters them (4 to 8 s), and at 90% a glide stops after 1.7 to 3.2 s. A new turn, a jump or a source switch ends a glide at once. Saved in PSETs, not in scenes

## MIDI (group)
- MIDI device: the port Strata listens to (1-16, the norns MIDI slots, default 1)
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
- Save scenes to disk (manual trigger; each scene save already writes the file, [Saved scenes on disk](scenes.md#saved-scenes-on-disk))
- Load scenes from disk (manual trigger; while a scene saved in this session is not on disk, the first trigger only prints a line in the console and a second within 2 seconds loads. A damaged or incompatible file is reported in the console, the current scenes are kept, and the file is moved to the first free of `scenes.data.bak`, `scenes.data.bak.2` ... `scenes.data.bak.9`, so it is never overwritten and an earlier copy is never replaced)
- Scene files from earlier versions of Strata still load: settings they do not contain (filter, delay, grain envelope and mode, sources and buffer settings, LFOs) start at their defaults (LFOs off, every voice on its synth), the Pulse voice's res is turned around so it sounds the same (it ran the other way before 3.3), and the console prints `migrated scenes file from version 1`. The next save writes the new format and first keeps the original file as `scenes.data.v<n>` (`scenes.data.v1` here), once; `buffers.data` from 3.2 is kept as `buffers.data.v1` the same way

Scenes capture the FX settings too; smooth transitions crossfade every FX value except the filter type, which switches at the end.

Scenes capture each voice's source and buffer position, rate and scan, but **not the audio in the buffers**: a recalled scene plays whatever is in the buffer now. A voice's source switches at the end of a smooth transition; the buffer parameters crossfade. LFO depths, offsets and free periods crossfade too (toward a scene that has a running LFO off, its depth fades to 0 and its offset and free period hold); the other LFO settings switch at the end.

## Scale
- Scale (off, or any of norns' scales; default off) and root (C-B, default C), shared by every voice that quantizes ([voices and grains](voices-and-grains.md#scales))

## Per-Voice Sections
Each voice has four parts in the menu, in this order: its heading (`voice 1: resonator`, the voice's own parameters), then `voice 1 granular`, `voice 1 cross-modulation` and `voice 1 extras`. The synthesis parameters, voice by voice, are listed in [Synthesis Parameters](voices-and-grains.md#synthesis-parameters). Each voice includes:
- Quantize (off/on, default off), first, right after the voice's heading and above its freq, so a PSET sets it before the freq
- Synthesis parameters (varies by voice type). The Pulse voice's res (0.1-1, default 0.8) rises with resonance, as every other res does: up is a sharper, ringing peak at the cutoff, 0.1 is flat. Before 3.3 it ran the other way (0.1 was the sharpest); a scene or PSET saved then still sounds the same, and shows the mirrored number (0.3 shows as 0.8)
- Source (synth, buf 1-8, input; default synth)
- Bookmarks 1-4 (buffer voices; 0-1, default 0, 0.25, 0.5 and 0.75): saved positions in the slot, set on VOICE or with a grid's store key, and recalled with BUFFER's `bm` field (E3) or a grid's bookmark keys. Kept in scenes (they fade like other values) and PSETs, never randomized or mutated ([voices and grains](voices-and-grains.md#bookmarks))
- Buffer position (0-1, default 0), buffer rate (0.25-4, default 1) and buffer scan (-2 to 2, default 0): what a buffer-sourced voice reads ([Audio Sources and Buffers](sources-and-buffers.md))
- Grain size (0.01-0.5 s, default 0.1)
- Grain density (1-100 grains a second, default 20)
- Grain pitch (0.25-4, the transposition ratio, default 1)
- Position spread (0-1, default 0.5)
- Grain envelope (hann, sine, perc, linen, trap; default hann)
- Grain mode (continuous or triggered; default continuous)
- Cross-modulation, three slots ([Cross-Modulation](modulation.md#cross-modulation)):
  - Mod source 1-3 (none or voice 1-7; default none): the voice that modulates this one in each slot
  - Amp mod 1-3 (-2 to 2, default 0): how far that voice moves this one's level
  - Freq mod 1-3 (-2 to 2, default 0): how far that voice moves this one's pitch
  - Mod speed (0.1-50 Hz, default 10): the rate of the slow random wobble in this voice's own modulation signal, the one it sends to the voices it modulates
- The voice's extras, last, in this order:
  - History (input-sourced voices; 0-16 s, 0-60 s on the high tier, default 0): how far back in the live input the grains play ([Granular Processing](voices-and-grains.md#granular-processing))
  - Freeze (off/on, default off) and freeze mode (hold, and on the high tier spectral; default hold): hold what the voice's grains play ([Freeze](pages/voice.md#freeze))
  - Loop start (0-1, default 0) and loop length (0.001-1, default 1): the part of the buffer a buffer-sourced voice plays ([Audio Sources and Buffers](sources-and-buffers.md))
  - Reverse (0-100%, default 0), pitch jitter (0-12 st, default 0), pan jitter (0-1, default 0), size jitter (0-1, default 0), intervals (off, octaves, fifths, chord, custom; default off), interval prob (0-100%, default 100%) and custom 1-5 (-24 to 24 st; default -12, 0, 7, 12 and 19): how each grain differs from the last ([Grain variation](voices-and-grains.md#grain-variation))
  - Voice filter type (lowpass, highpass, bandpass), filter freq (20-20000 Hz, default 5000), filter res (0-1, default 0.5) and filter mix (0 = off, the default, to 1), and delay send and reverb send (0-100%, default 100%; see [Each voice's filter and sends](effects.md#each-voices-filter-and-sends))
  - Bookmark 1-4 (above)
- None of the extras is randomized, mutated or on the grid's fader pages
