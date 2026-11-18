# Parameters Reference

Everything in the norns PARAMETERS menu, grouped by topic. Back to the [README](../../README.md).

After norns' own settings, the menu shows Strata's master settings, mutations and scenes first, then the **fx**, **LFO 1-6**, **macros**, **morph**, **scatter**, **matrix**, **input**, **gestures**, **random sequences**, **out midi**, **crow**, **out ii**, **out nb**, **tape**, **sequencer**, **buffers**, **record**, **positions**, **midi** and **zones** groups, then the **scale** section, then one section per voice. Grouped by topic:

PSETs (PARAMETERS > PSET) save every one of them, and the sixteen scenes beside it (`<pset>.scenes.data`: [Saved scenes on disk](scenes.md#saved-scenes-on-disk)). A PSET loads every setting it holds as it is, and a setting it does not hold (one added since it was saved) at its default. Any PSET's whole-number settings (a modulation source, the sequence length, ...) load as whole numbers, even if a fraction was saved.

## Master
- Master density
- Tempo (1-300 BPM, the range of norns' clock tempo; sets norns' clock tempo, starts at the current clock tempo)

## FX (group)
- Filter type (lowpass, highpass, bandpass)
- Filter freq (20-20000 Hz, default 5000)
- Filter res (0-1, default 0.5)
- Filter mix (0 = bypass, the default, to 1)
- Delay time (0.01-5.4 s, default 0.375)
- Delay feedback (0-0.95, default 0.4)
- Delay level (the delay's return, 0 = silent, the default, to 1; the id stays `delay_mix`)
- Reverb level (its return, 0-1, default 0.43; the id stays `reverb_mix`), size and damping
- Tape drift amount (depth of the pitch drift; 0 = none, default 0.01 = ±0.2 %; it bends the pitch only, with no flutter in the level)
- Delay bypass and reverb bypass (off by default): switch the effect off completely, freeing its CPU (and the reverb's memory; the delay's line is kept apart, emptied), and keep its level (see [Bypass](effects.md#bypass)). PSETs store them; scenes do not
- Delay to reverb (0-100 %, default 100): how much of the delay's return the reverb takes; at 0 a voice with no reverb send has dry echoes ([Plain sends](effects.md#plain-sends)). Scenes store it and crossfade it
- Shimmer interval (oct down, fifth, octave, oct+5th, 2 oct; default octave), shimmer delay and shimmer reverb (0-100 %, default 0): a pitch shift in the delay's feedback and around the reverb ([Shimmer](effects.md#shimmer)). Scenes store all three (the interval switches at a transition's end, the amounts crossfade)
- Delay sync (off by default): the delay plays delay division at the tempo instead of delay time; a division longer than 5.4 s plays at half its length (or a quarter, ...) until it fits (see [FX](pages/fx.md))
- Delay division (1/32, 1/16T, 1/16, 1/16D, 1/8T, 1/8, 1/8D, 1/4T, 1/4, 1/4D, 1/2, 1 bar; default 1/8D)
- Delay ping-pong (0-1, default 0): at 1 the repeats alternate left and right. Scenes store the three: sync and division switch at the end of a transition, ping-pong crossfades

## LFOs
- **LFO 1** ... **LFO 6** (a group each) - on (off by default), shape (sine, tri, square, up, down, s&h, smooth, drunk; sine), mode (free or clocked; free), rate (0.003-50 Hz, default 0.25 Hz, a 4 s cycle), clocked rate (1/16 to 1024 bars of four beats; 4), depth (0-100 %, default 25 %, so an LFO is audible as soon as it is turned on; scenes recall the depth they stored), offset (-100 to 100 %, 0), phase (0-100 %, 0), rate mod and depth mod (none, or a lower-numbered LFO: LFO 3 offers L1 and L2) and their amounts (-100 to 100 %, 0). An LFO's destination is no menu parameter: it is set on the [LFO](pages/lfo.md) page and saved with the matrix's routings. See [Modulation](modulation.md#global-lfos)
- An LFO always swings up to half the destination's range either side of the value you set, at 100 % depth

## Macros (group)
- Macro 1-16 (0-100 %, default 0): each moves up to eight targets at once, each between two ends of its own (where the macro's 0 % and 100 % put it; a first end above the second turns it around), along the target's own scale (a frequency in octaves). A target is any setting an LFO can move, or an LFO's rate or depth, or a matrix routing's depth, never another macro or the morph. See [Modulation](modulation.md#macros)
- The targets are not parameters: they are saved with each PSET (in a file beside it, `<pset>.macros.data`), in scenes and between sessions. A scene recall, a fade and the morph set a macro's value without moving its targets, since the scene holds their own values

## Morph (group)
- Morph (0-100 %, default 0): the position between two saved scenes, 0 % scene A's sound and 100 % scene B's. Morph A and morph B (scene 1-16, defaults 1 and 2) pick the scenes. See [Modulation](modulation.md#morph)
- Morph y (0-100 %, default 0), morph C and morph D (scene 1-16, defaults 3 and 4): the XY morph's second axis and its two other scenes, C above A and D above B. At morph y 0 % the morph is the one between A and B
- None of the six is stored in a scene; a PSET stores them, and loads the position without applying it

## Scatter (group)
- Scatter (off by default), depth (0-100 %, default 10 %), rate (0.01-1 Hz, default 0.1 Hz), and the settings it moves: pitch and position (on by default), size, cutoff and amp (off). See [Modulation](modulation.md#scatter)
- Scenes store all eight: the depth and the rate fade, the switches change at the end of a fade

## Matrix (group)
- R1-R16 depth (-100 to 100 %, default 0) and R1-R16 on (on by default): the modulation matrix's 16 routings. Each moves its destination by its source's value times its depth, around the value you set (100 % from an LFO swings half the destination's range either side; a macro, a recorder or the input level only adds, from 0). A source is an LFO, a macro, a gesture recorder or the input level; a destination is any setting an LFO can move, never a macro. Routings on the same setting add up with its LFOs before the setting's range limits them. Macros can move the depths; no LFO can
- A routing's source and destination are not parameters: they are saved with each PSET (in a file beside it, `<pset>.matrix.data`), in scenes and between sessions. A scene fades the depths and switches each routing's on/off at the end of a fade; a routing whose source or destination differs fades to 0 first and switches halfway

## Input (group)
- Input follow gain (1-30, default 4): scales the live input's level, the modulation source `IN` on the MOD page and in the matrix, so a line-level input moves a destination. It does not change what you hear or the BUFFER page's meter

## Gestures (group)
- Gesture 1-4 quantize (free, beat, bar; default free): how gesture recorder 1-4 keeps time. Free plays the loop as you recorded it. Beat and bar round the loop's length to whole beats or bars of the norns clock when the recording stops (at least one), stretch its moves to fit, and start each pass on a beat or bar, so the loop stays with the tempo, Link and MIDI clock. Changing it on a recorded loop converts the loop the same way (back to seconds at the current tempo for free)
- A recorder records your hand edits of continuous settings (encoders, arc rings, grid faders) as the values they reach, from the first edit to the stop; it never records options, switches, sources, scene recalls, LFOs, the drift, mutations or another recorder's playback. One records at a time, up to 1024 moves or 10 minutes. Its loops are saved with each PSET (in a file beside it, `<pset>.gestures.data`) and between sessions, and load stopped; scenes store only whether each one plays
- A hand edit of a setting a loop plays holds until the loop's next move of that setting

## Random sequences (group)
- RS1-RS4 length (2-16, default 8), drift (0-100 %, default 0), clock (1/32 to 1 bar, or voice 1-7; default 1/8) and new (draws all sixteen values again). See [Random Sequences](modulators.md#random-sequences)
- The sixteen values of each are not parameters: they are saved with each PSET (in a file beside it, `<pset>.sequences.data`), in scenes and between sessions, and edited on MOD

## out midi (group)
- Per voice: out port (off or 1-16; off), out channel (1-16; the voice's number), out mode (plain, mpe; plain) and out members (1-15; 15). Out bend range (1-96 semitones; 48). CC 1 to CC 8: source (off or a modulation source; off), port (1-16; 1), channel (1-16; 1) and number (0-127; the slot's). Program change in (off), its channel (any or 1-16; any), program change out (off), its port (1) and channel (1). See [MIDI out](io/midi-out.md)

## crow (group)
- In 1 and in 2: mode (off, cv, trigger; off), range (-5..5, 0..5, 0..10 V; -5..5), action (retrigger, next scene, freeze, record, patterns, fill; retrigger) and voice (sel, the selected voice, or 1-7; sel). Out 1 to out 4: source (off, a modulation source, a voice's pitch or gate, or clock; off), range (0..5, 0..10, -5..5 V; 0..5) and div (1/16 to 4 beats; 1). See [crow](io/crow.md)
- A PSET stores them; scenes do not

## out ii (group)
- The ii devices' settings, in this order. Just Friends: jf out v1 to v7 (off, on; off) and jf level (0-10 V; 5). W/ synth: v1 w/ syn to v7 w/ syn (off, on; off) and w/ syn level (0-10 V; 5). ER-301: v1 er-301 port to v7 er-301 port (off or 1-100; off). TELEXo: per voice its txo output (off or 1-32; off) and txo mode (pitch, envelope; pitch), then txo attack and txo decay (1-10000 ms; 10 and 500). See [Just Friends](io/jf.md), [W/](io/w.md) and [ER-301 and TELEXo](io/er301-txo.md)
- A PSET stores them; scenes do not

## out nb (group)
- V1 nb to v7 nb (none, or a player an installed nb voice mod offers; none): the player each voice's steps and played notes go to, kept by name. See [nb voices](io/nb.md)
- A PSET stores them; scenes do not

## tape (group)
- The tape loop's seven settings: tape loop (off, on; off), tape record (off, on; on), tape length (0.25-60 s; 4), tape speed (-2 to 2, negative plays backward; 1), tape feedback (0-100 %; 50), tape wear (0-100 %; 20) and tape level (0-100 %; 70). Level, speed, feedback and wear are also macro targets. See [The tape loop](io/tape.md)
- A PSET stores them; scenes do not

## Sequencer (group)
The quantizer for actions, the pattern chain, the division reset, following the clock's transport and fill ([Sequencer](sequencer.md)). PSETs store them (but fill); scenes do not.
- Quantize actions (off, beat, bar; default off): with beat or bar, these wait for the next beat or bar of the norns clock, and the header says so (`v1 jump at bar`, `v1 bm 2 at bar`, `S3 at beat`, `v2 frz at bar`, `play at bar`): a grid's position and bookmark keys, BUFFER's bookmark field (`bm`), a scene recall (the SCENES page's K2, K3 and arc button, and every grid's scene keys) and the start of the patterns (a stop never waits). A grid's freeze keys (FZ on the [voices page](grid/pages/voices.md)) wait too. A second press of a scene, bookmark or position key before then replaces the first; a second press of a freeze key or of the play key takes its waiting action back, so nothing happens, and a transport start or stop drops a waiting start of the patterns. Off acts at once. A step's bookmark lock never waits. Saved in PSETs, not in scenes
- Chain (off/on, default off), chain from (scene 1-16, default 1), chain scenes (1-16, default 2) and chain bars (1-16, default 4): while the patterns play, every chain-bars bars a saved scene of the range gives its patterns, their step attributes and each voice's sequence length, division, direction and misstep, and nothing else
- Chain next (0-100 %, default 100), chain previous (default 0) and chain random (default 0): the chances that the next link is the next saved scene of the range, the one before, or any other; what is left over keeps the scene for another round
- Division reset (trigger): every voice starts again at the next bar, at its direction's first step
- Follow transport (off/on, default on): a MIDI clock or Link start and stop start and stop the patterns (SETUP's `transport` row)
- Fill (off/on, default off): fill's latch, which a MIDI controller can map ([Fill](sequencer.md#fill)). Never saved: it is off at every start, and a PSET load leaves it as it is

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
- MIDI channels: per voice (channels 1-7 play voices 1-7, the default), omni to selected, or, for MPE controllers, mpe selected and mpe split ([MIDI Input](midi.md))
- MIDI note off: latch (the default: chords sound on until the next) or release (each note ends with its key), in every channel mode; an MPE player sets release ([MIDI Input](midi.md))
- mpe lower members and mpe upper members (0-15, default 15 and 0): the member channels of each zone (the lower zone's master is channel 1 and its members follow it; the upper zone's master is channel 16 and its members count down from 15). Setting one lowers the other while both are above 0, so together they never pass 14. A controller's own configuration message (RPN 6) sets them and flashes `MPE lower <n>` or `MPE upper <n>`
- mpe bend range (1-96 semitones, default 48): a member channel's pitch bend range; RPN 0 on a member channel sets it. Do not map CC 74, 87, 6, 38, 100 or 101 in PARAMS > MAP while an MPE controller is in use

PSETs save the MIDI group; scenes never do. The note pool, how many extra notes the voices share for chords, is not a parameter: SETUP's `note pool` sets it for the norns, and no PSET or scene holds it ([SETUP](pages/setup.md)).

## Zones (group)
Split zones for the mpe split mode. Each voice has a zone (off, lower or upper; voice 1 lower, voice 2 upper, the others off by default) and a lowest and highest note (0-127; the lowest never passes the highest, the one you set moves the other). A note plays every voice whose zone and range hold it. SETUP's `mpe & zones` editor sets them too, and learns a voice's range from the next two notes played ([Split zones](midi.md#split-zones)). PSETs save them; scenes never do.

## Mutations
- Mutations enabled (on/off)
- Mutation rate (0.5-10 seconds)
- Mutation probability (0-1, chance per parameter)
- Mutation amount (0-1, size of changes)

## Scenes
- Scene sequencer (on/off)
- Scene transition time (0-30 seconds)
- Scene duration (4-120 seconds; a scene plays at least as long as its transition)
- Scene sequence length (1-16 scenes)
- Chance next, chance previous and chance random (0-100% each; defaults 100%, 0% and 0%): how the sequencer picks the scene after the one it recalls, the rest a repeat ([Automatic Scene Sequencing](scenes.md)). Saved in PSETs, not in scenes
- Save scenes to disk (manual trigger; each scene save already writes the file, [Saved scenes on disk](scenes.md#saved-scenes-on-disk))
- Load scenes from disk (manual trigger; while a scene saved in this session is not on disk, the first trigger only prints a line in the console and a second within 2 seconds loads. A damaged or incompatible file is reported in the console, the current scenes are kept, and the file is moved to the first free of `scenes.data.bak`, `scenes.data.bak.2` ... `scenes.data.bak.9`, so it is never overwritten and an earlier copy is never replaced)
- Scene files saved by Strata 3.8 or later load: settings they do not contain start at their defaults. A scenes file from before 3.8, or a `buffers.data` from before 3.3, is not converted: it is set aside as a backup (`scenes.data.bak`, `buffers.data.bak`) with one line in the console, and the script starts without it. A PSET loads every setting it holds as it is; a setting it does not hold starts at its default

Scenes capture the FX settings too; smooth transitions crossfade every FX value except the filter type, which switches at the end.

Scenes capture each voice's source and buffer position, rate and scan, but **not the audio in the buffers**: a recalled scene plays whatever is in the buffer now. A voice's source switches at the end of a smooth transition; the buffer parameters crossfade. LFO depths, offsets and rates crossfade too (toward a scene that has a running LFO off, its depth fades to 0 and its offset and rate hold); the other LFO settings switch at the end, except an LFO's destination: it switches at the middle of the transition, where its depth dips to 0.

## Scale
- Scale (off, any of norns' scales, or custom; default off), root (C-B, default C) and scale mask (1-4095, 4095: the custom scale's notes), shared by every voice that quantizes ([voices and grains](voices-and-grains.md#scales))
- Tuning: its name (12 equal by default; the scale and tuning editor on SETUP chooses it) and, hidden, its tones. A PSET saves the tuning; a scene does not ([voices and grains](voices-and-grains.md#tunings))

## Per-Voice Sections
Each voice has four parts in the menu, in this order: its heading (`voice 1: resonator`, naming the voice's type), with its type, quantize, the voice's synthesis parameters, its amp and (all but the Sub type) its pan; then `voice 1 granular`, `voice 1 cross-modulation` and `voice 1 extras`. Every voice holds the synthesis parameters of every type, but the menu shows only its current type's; the others keep their values (a PSET saves them all) and come back with their type. The synthesis parameters are listed type by type in [Synthesis Parameters](voices-and-grains.md#synthesis-parameters). The Pulse voice's res (0.1-1, default 0.8) rises with resonance, as every other res does: up is a sharper, ringing peak at the cutoff, 0.1 is flat. Before 3.3 it ran the other way (0.1 was the sharpest); a PSET saved then loads its number as it is, so it plays another resonance (a scenes file that old is set aside).

The rest of each voice's parameters, in menu order. A default "by voice" gives voices 1-7's in turn; a numbered parameter's defaults are its numbers' in turn.

| parameter | range | default | |
|---|---|---|---|
| type | resonator, fm, folder, sub, pulse, karplus, ring, wave, additive, noise, saw, formant | by voice: resonator, fm, folder, sub, pulse, karplus, ring | The voice's synth ([Voice types](voices-and-grains.md#voice-types)). First under the voice's heading; a PSET from before 3.8 has no line for it and puts each voice back on its own type |
| quantize | off/on | off | Right after the type and above the voice's freq, so a PSET sets it before the freq ([Grain variation](voices-and-grains.md#grain-variation)) |
| source | synth, buf 1-8, input, voice 1-7 | synth | What the voice's grains read: its synth, a buffer, the live input or a voice's output, another's or its own ([Audio Sources and Buffers](sources-and-buffers.md)) |
| buffer position | 0-1 | 0 | Where a buffer-sourced voice's grains read, in its loop |
| buffer rate | 0.25-4 | 1 | How fast a buffer-sourced voice's grains read the buffer |
| buffer scan | -2 to 2 | 0 | How fast the position moves through the loop, as a speed: at 1 the audio's own rate, at 2 double, below 0 backward (VOICE shows it as `1.00x`). Before 3.7 it was loop lengths a second, so a scene or PSET saved then with a scan that is not 0 plays at another speed |
| grain size | 0.01-0.5 s | by voice: 0.1, 0.15, 0.08, 0.2, 0.12, 0.08, 0.1 | |
| grain density | 1-100 /s | by voice: 20, 15, 25, 10, 18, 22, 20 | Grains a second |
| grain pitch | 0.25-4 x | 1 | The transposition ratio |
| position spread | 0-1 | by voice: 0.5, 0.3, 0.4, 0.2, 0.35, 0.25, 0.4 | |
| grain mode | continuous, triggered | continuous | |
| mod source 1-3 | none, voice 1 to voice 7 | none | The voice that modulates this one, in each of the three slots ([Cross-Modulation](modulation.md#cross-modulation)) |
| amp mod 1-3 | -2 to 2 | 0 | How far that voice moves this one's level |
| freq mod 1-3 | -2 to 2 | 0 | How far that voice moves this one's pitch |
| mod speed | 0.1-50 Hz | 10 | The rate of the slow random wobble in this voice's own modulation signal, the one it sends to the voices it modulates |
| grain shape | 0-1 | 0.57 | The grain's window, from pointed through the Hann (the default) to flat-topped ([Granular Processing](voices-and-grains.md#granular-processing)). 3.8; a 3.7 PSET's `grain envelope` line names no param and is not loaded |
| grain skew | -1 to 1 | 0 | The window's lean: percussive at -1, even at 0, swelling at 1 |
| grain prob | 0-100 % | 100 | The chance each grain sounds, in continuous mode |
| grain cloud | density, overlap | density | What sets the grains a second: the grain density, or the overlap over the grain size |
| grain overlap | 0.25-16 x | 2 | How many grains at once in the overlap cloud |
| pan wander | 0-100 % | 50 | How far the slow random pan wander moves the grains |
| history | 0-16 s (0-60 s on the high tier) | 0 | Input-sourced voices: how far back in the live input the grains play ([Granular Processing](voices-and-grains.md#granular-processing)) |
| input channel | stereo, left, right | stereo | Input-sourced voices: both of the input's channels, or the left or the right one alone ([Audio Sources and Buffers](sources-and-buffers.md)) |
| freeze | off/on | off | Hold what the voice's grains play ([Freeze](pages/voice.md#freeze)) |
| freeze mode | hold (and spectral on the high tier) | hold | |
| loop start | 0-1 | 0 | The part of the buffer a buffer-sourced voice plays ([Audio Sources and Buffers](sources-and-buffers.md)) |
| loop length | 0.001-1 | 1 | |
| reverse | 0-100% | 0 | How each grain differs from the last, the reverse to custom rows ([Grain variation](voices-and-grains.md#grain-variation)) |
| pitch jitter | 0-12 st | 0 | |
| pan jitter | 0-1 | 0 | |
| size jitter | 0-1 | 0 | |
| intervals | off, octaves, fifths, chord, custom | off | |
| interval prob | 0-100% | 100 | |
| custom 1-5 | -24 to 24 st | -12, 0, 7, 12, 19 | |
| filter type | lowpass, highpass, bandpass | lowpass | The voice's own filter ([Each voice's filter and sends](effects.md#each-voices-filter-and-sends)) |
| filter freq | 20-20000 Hz | 5000 | |
| filter res | 0-1 | 0.5 | |
| filter mix | 0-1 | 0 | 0 leaves the filter out |
| dry | 0-100% | 100 | The voice's dry level: how much of it reaches the mix dry. The sends are taken before it, so at 0 the voice is all effect ([Plain sends](effects.md#plain-sends)) |
| delay send | 0-100% | 100 | |
| reverb send | 0-100% | 100 | |
| mute | off/on | off | Silences the voice without stopping it; scenes keep it ([Mute and solo](voices-and-grains.md#mute-and-solo)) |
| solo | off/on | off | Silences every voice that is not soloed; scenes never keep it |
| bookmark 1-4 | 0-1 | 0, 0.25, 0.5, 0.75 | Buffer voices: saved positions in the slot, set on VOICE or with a grid's store key, and recalled with BUFFER's `bm` field (E3) or a grid's bookmark keys. Kept in scenes (they fade like other values) and PSETs ([voices and grains](voices-and-grains.md#bookmarks)) |
| scan mode | wrap, bounce, one shot | wrap | Buffer voices: at the loop's end the scan goes round again, turns back, or plays once and stays silent until the voice's next hit ([voices and grains](voices-and-grains.md#scan-modes-and-tempo-follow)) |
| follow | off, stretch, repitch | off | Buffer voices on a file with a tempo: the scan follows the clock's tempo, keeping the pitch (stretch) or moving it with the speed (repitch) |
| env attack | 0.001-10 s | 0.005 | The voice's envelope, a modulation source fired by its hits ([Envelopes](modulators.md#envelopes)): the rise to 1 |
| env decay | 0.001-10 s | 0.2 | The fall to the sustain |
| env sustain | 0-1 | 0 | The level held for the hit's gate length; 0 makes it an attack and a decay |
| env release | 0.001-10 s | 0.2 | The fall to 0 after the hold |
| env curve | -8 to 8 | -4 | Bends the three slopes; 0 is straight. The times, the sustain and the curve fade in scenes |
| env loop | off, on | off | On: the envelope starts again each time it ends. A scene switches it at the end of its fade |
| note cap | 1-8 | 8 | How many notes the voice plays at once: its own and up to seven more from the note pool all voices share. 1 plays one note at a time. Kept in PSETs, never in scenes ([VOICE](pages/voice.md)) |
| attack | 0.005-30 s | by voice: 4, 5, 3, 8, 2, 0.01, 3 | The time a synth voice takes to fade in; each voice starts at its own, as before 3.5. A buffer or input voice's notes, and a frozen synth voice's, keep their grain fades (0.1 s in, 2 s out). Kept in scenes ([VOICE](pages/voice.md)) |
| release | 0.01-30 s | by voice: 8, 10, 6, 12, 4, 2, 5 | The time a synth voice's note takes to fade out when it ends while the voice runs; a voice's stop fades in at most about 2 s whatever it is set to. As `attack`, a synth voice's only. Kept in scenes ([VOICE](pages/voice.md)) |
| arp | off, up, down, up-down, shuffle | off | The arpeggiator: the grains step through the voice's intervals, or a held chord, one after another in the order it names ([The arpeggiator](voices-and-grains.md#the-arpeggiator)). Kept in scenes; a scene switches it at the end of its fade |
| press target | off, amp, level, main, size, density, position, cutoff | amp | What a note's pressure moves; position acts on a buffer voice only ([Expression](modulation.md#expression)) |
| press depth | -100 to 100% | 100 | How far: at 100% full pressure doubles the note's level on amp (+6 dB), so a keyboard's aftertouch swells its notes; `press target` off, or a depth of 0, turns that off |
| slide target | off, amp, level, main, size, density, position, cutoff | main | What a note's slide moves, from where its touch began |
| slide depth | -100 to 100% | 50 | |
| slices | off, one, overlap | off | Buffer voices: whether MIDI notes and a grid's row play the slot's slices, one at a time on the voice's own note or each in a note of its own; a step's slice plays as overlap gives, else as one ([Slices](slices.md)) |
| seq length | 1-16 | 16 | The voice's pattern: how many steps it plays, how long each is, its gate and swing ([Sequencer](sequencer.md)) |
| seq division | 1/32, 1/16t, 1/16, 1/8t, 1/8, 1/4, 1/2, 1 bar | 1/16 | |
| seq gate | off, on | off | On: the voice is heard only while a step's gate is open |
| seq gate length | 0.05-16 st | 0.5 | In steps |
| seq gate release | 0.005-4 s | 0.1 | |
| seq swing | 50-75 | 50 | Percent: 50 is straight |
| seq direction | forward, reverse, ping-pong, random | forward | The order the voice takes its steps |
| seq misstep | 0-100% | 0 | The chance of a step up or down instead of the direction's |

None of the extras (grain shape to seq misstep) is changed by MAIN's randomize or the mutations. The grid's fader pages show the window's shape and skew among the grain faders (where 3.7's envelope was), and, after the voice's own faders, the voice filter's cutoff, resonance and mix, the dry level, both sends, a buffer voice's loop, the three jitters and the voice's attack and release; ALT+K2 on VOICE randomizes some of the extras with the section under the cursor ([VOICE](pages/voice.md)).
