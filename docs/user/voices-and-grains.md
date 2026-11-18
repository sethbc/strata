# Voices and Granular Processing

The seven synthesis voices, each voice's granular processor and the per-voice performance features. Back to the [README](../../README.md).

## Seven Synthesis Voices

Each voice plays one synth type, picked on its VOICE page's `type` row (below). The voices start on the first seven, voice 1 on the first and so on, so a fresh Strata sounds as 3.7 did; the other five (3.8) are chosen on a voice's `type` row:

1. **Resonator** - Filtered noise through resonant filter banks with slow modulation (level-matched to the other voices and limited, so at its normal settings it no longer pushes the rest of the mix down; as a cross-modulation source it is now as strong as the other voices, where before it drove what it modulated to the limit at almost any depth)
2. **FM** - Two-operator FM synthesis with evolving harmonic/inharmonic timbres
3. **Folder** - Sine wave through wavefolder with dynamic folding amount
4. **Sub** - Ultra-low frequency sine wave for grounding the mix
5. **Pulse** - Pulse width modulation synthesis with resonant filtering for classic analog sounds. Its res (0.1-1, default 0.8) rises with resonance like every other res: turned up, the filter rings at its cutoff; at 0.1 it is flat. Before 3.3 it ran the other way: a PSET saved then loads its number as it is, and so plays another resonance. A controller mapped to it or its grid fader sharpens it as it goes up
6. **Karplus** - Karplus-Strong plucked string synthesis for organic, physical timbres
7. **Ring** - Ring modulation between two oscillators for metallic, bell-like textures
8. **Wave** - A wavetable voice that glides through eight tables, from a pure sine to a bright buzz, with three slightly detuned copies for a slow chorus (3.8; no voice starts on it: choose it on a voice's `type` row)
9. **Additive** - A bank of up to 16 sine partials over the pitch: a tilt from bright to almost a sine, a stretch that bends the series out of tune, a balance of the odd and even partials, and one slow wander of the brightness. No voice starts on it
10. **Noise** - Colored noise and crackling dust through a bank of four resonances at the voice's pitch, from a breathy wash to a ringing, whistling tone (no voice starts on it: choose it on the `type` row)
11. **Saw** - Three detuned variable saws on each side through the Pulse's resonant lowpass, for a wide, slowly beating pad. No voice starts on it; any voice can choose it. Its width, cutoff and res are the Pulse's own parameters, so a Pulse voice switched to Saw keeps its filter where it was
12. **Formant** - A vowel voice: two formant oscillators a side sing at formants that move between vowels, from an "ee" toward an "ah", with a slow wander of their own; its main parameter scales both formants up or down, from a darker, larger voice to a smaller, brighter one

### Voice types

A voice's type is its `type` row on VOICE, the first row of the page (and its first parameter in PARAMETERS). Turn E3 there to choose: the new name shows dim while you turn, and the voice changes to it once the encoder has rested for 0.3 s, so turning through five types changes the sound once. Choosing another voice, leaving VOICE or stopping the voice changes it at once. An arc ring on the row does the same. Hold ALT+K2 on the row to put the voice back on its own type.

A type change keeps the voice's other settings: its grains, its sends, its attack and release, its freeze. A frozen voice keeps its held sound: a type chosen while a voice is frozen in `spectral` mode is heard when the freeze ends (in `hold` it changes at once, unheard until the unfreeze). Every voice keeps the settings of every type, so switching back to a type finds its parameters where the voice left them. A change works on a locked voice (the lock guards against randomize and mutation, not edits), and no randomize or mutation ever changes a type. MAIN's E3 and arc ring 2 follow the new type's main parameter.

A scene stores each voice's type, and a recall puts it back (a fade between two scenes of one type fades the synth parameters; between types, the type and its parameters change at the fade's end). A PSET stores each voice's type and every type's parameters; a PSET saved before 3.8 puts each voice back on its own type.

## Synthesis Parameters

Each type's own parameters, by the names the VOICE page's synth section, MAIN and PARAMETERS (the voice's first part) show; the grid's fader pages run through them in this order. MAIN's E3 and arc ring 2 adjust the one marked *main*. Most of the sounds also move on their own: slow random wobbles keep each voice drifting while nothing is turned, so a setting is the center of a movement more than a fixed value. Every voice also has **amp**, its level (0-1; 0.25 to 0.4 to start, by voice), and all but the Sub have **pan** (-1 left to 1 right, 0 center); the VOICE page shows them in its mix section. While a voice's source is a buffer or the input, its synthesis parameters do nothing; amp and pan still do.

**Resonator**

| param | range | default | what it does |
|---|---|---|---|
| `freq` (main) | 20-2000 Hz | 100 | The pitch: four resonances, at 1, 1.5, 2.3 and 3.7 times it, rung by noise |
| `rq` | 0.01-1 | 0.1 | The width of the lowpass after the resonances, whose cutoff wanders between 1 and 4 times the pitch: lower is narrower, ringing at the cutoff; 1 is a gentle slope |
| `noise` | 0-1 | 0.5 | How loud the pink noise that rings the resonances is (a low rumble of their own still rings them at 0) |
| `mod1` | 0.01-1 Hz | 0.1 | The rate of one of two slow random swells of the level (each between half and full); higher swells faster |
| `mod2` | 0.01-1 Hz | 0.15 | The rate of the other swell |

**FM**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 80 | The carrier's pitch |
| `ratio` | 0.5-8 | 1.5 | The modulator's frequency as a multiple of the carrier's: whole numbers sound harmonic, others bell-like or clangorous. It wanders 0.1 either way |
| `index` (main) | 0-10 | 2 | The modulation depth: 0 is a plain sine, higher is brighter and harsher. It wanders between half and one and a half times the setting |
| `modFreq` | 0.01-1 Hz | 0.05 | The rate of the slow random swell of the level (between 0.3 and full, left and right apart), which itself wanders between half and twice the setting. It is not the modulator's frequency (that is the ratio) |

**Folder**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 60 | The pitch of the sine (one each side, a little apart) |
| `fold` (main) | 0.1-5 | 1 | How hard the sine drives the wavefolder: wherever the drive passes 1 the wave folds back on itself and gains harmonics, so low settings stay close to a sine. It wanders between half and one and a half times the setting; a lowpass between 1 and 3 kHz follows |
| `mod` | 0.01-2 | 0.2 | How fast the fold amount wanders (new random values a second) |

**Sub**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 40 | The pitch of a sine, with a quieter one an octave below |
| `drift` (main) | 0.001-0.1 | 0.02 | The depth of a slow random pitch drift, as a fraction of the pitch: 0.02 is 2% either way, about a third of a semitone |

**Pulse**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 120 | The pitch (one pulse each side, a little apart) |
| `width` (main) | 0.05-0.95 | 0.5 | The pulse width: 0.5 is a square wave, toward either end thinner and more nasal. It wanders 0.2 either way, and amplitude cross-modulation moves it too |
| `cutoff` | 100-8000 Hz | 2000 | The resonant lowpass's cutoff; it wanders between half and twice the setting, within 100-8000 Hz |
| `res` | 0.1-1 | 0.8 | The filter's resonance: higher is a sharper peak that rings at the cutoff, 0.1 flat (before 3.3 it ran the other way; see Pulse above) |

**Karplus**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 200 | The string's pitch |
| `decay` (main) | 0.5-10 s | 4 | How long a pluck rings, until it is 60 dB down |
| `damping` | 0.1-0.9 | 0.5 | How fast the string's highs die away: higher is darker and duller, lower brighter |
| `excite` | 0.1-2 Hz | 0.3 | How often the string plucks itself, in plucks a second; pattern steps and MIDI notes pluck it too |

**Ring**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 300 | The carrier's pitch (one each side, a little apart) |
| `ratio` (main) | 0.5-8 | 1.618 | The second oscillator's frequency as a multiple of the carrier's: the ring tone is their sum and difference, metallic away from whole numbers. It wanders 0.1 either way |
| `mod` | 0.01-2 | 0.2 | How fast the ratio wanders (new random values a second) |
| `brightness` | 0-1 | 0.5 | How much of the plain carrier is mixed in under the ring tone |

**Wave**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 100 | The pitch |
| `morph` (main) | 0-1 | 0.3 | The place in the bank of eight tables, which go from a pure sine (0) through fuller and hollower ones to a bright buzz of many harmonics (1); between two tables it blends them. Amplitude cross-modulation moves it too |
| `morphRate` | 0.01-1 Hz | 0.05 | How fast the place wanders on its own (new random values a second) |
| `morphDepth` | 0-1 | 0.2 | How far it wanders either way of `morph`: 0 holds it still, 1 can sweep the whole bank |
| `detune` | 0-0.02 | 0.003 | How far apart the three copies on each side are tuned, as a fraction of the pitch (the left above it, the right below): 0 is one clean tone, higher a faster, wider chorus |

**Additive**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 100 | The pitch: the first partial, the others above it |
| `tilt` (main) | 0-3 | 1 | How fast the partials fall away: partial k is at 1/k^tilt of the first, so 0 is every partial equal (bright and buzzy), 1 a sawtooth-like slope, 3 almost a plain sine. Its peak stays bounded whatever the tilt, but a flatter tilt spreads it over more partials and sounds quieter (at 0 about 13 dB under 3) |
| `stretch` | -1-1 | 0 | Bends the series: at 0 the partials are whole multiples of the pitch (harmonic); above it they spread wider, below it they crowd closer, both bell-like and out of tune. A partial that would pass 21.6 kHz is silent |
| `oddEven` | 0-1 | 0.5 | Which partials sound: 0 the odd ones only (hollow, like a clarinet), 0.5 all of them, 1 the even ones only (the first always sounds) |
| `wander` | 0.01-1 Hz | 0.2 | The rate of a slow random drift of the tilt, 0.3 either way, which makes the color breathe |

**Noise**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 100 | The pitch of the bank: four resonances, at 1, 1.5, 2.25 and 3.375 times it, each quieter than the one below |
| `color` | 0-1 | 0.5 | The lowpass on the noise and dust before the bank: 0 is dark (200 Hz), 1 bright (16 kHz) |
| `grit` | 0-1 | 0.3 | Dust against noise: 0 is smooth pink noise, 1 only crackling bursts of dust |
| `dust` | 0.5-50 /s | 8 | How many bursts of dust a second (each side a little apart) |
| `q` (main) | 0.005-1 | 0.05 | The width of the resonances: lower is narrower, ringing at the pitch like a whistle; 1 is a broad, breathy hiss. The level stays about even across it, and a limiter keeps the narrowest from jumping out |
| `bank` | 0-1 | 0.7 | The resonant bank against the plain noise: 0 is the noise alone, 1 only the resonances. The bank swells slowly between 0.6 and full |

**Saw**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 100 | The pitch of the saws |
| `width` (main) | 0.05-0.95 | 0.5 | Each saw's shape: 0.5 is a triangle, soft and hollow; toward either end it becomes a sawtooth, brighter and buzzier |
| `detune` | 0-0.02 | 0.003 | How far apart the three saws on each side are, as a fraction of the pitch: the second is that far off it, the third twice as far, upward on the left and downward on the right. 0 is one plain saw; higher beats faster and spreads wider |
| `cutoff` | 100-8000 Hz | 2000 | The resonant lowpass's cutoff, as the Pulse's: it wanders between half and twice the setting, within 100-8000 Hz |
| `res` | 0.1-1 | 0.8 | The filter's resonance, as the Pulse's: higher is a sharper peak that rings at the cutoff, 0.1 flat. One setting sounds the same on both types |

**Formant**

| param | range | default | what it does |
|---|---|---|---|
| `freq` | 20-2000 Hz | 100 | The pitch the formants sing at (one each side, a little apart) |
| `formant` (main) | 0.5-2 | 1 | A scale on both formants' frequencies: below 1 a darker, larger voice, above 1 a smaller, brighter one (at 2 and a high pitch it turns harsh) |
| `vowel` | 0-1 | 0.5 | Where the formants sit between vowels, from an "ee" at 0 to an "ah" at 1: at 0 the first at 300 Hz and the second at 2300, at 1 the first at 800 and the second at 1100 (times the formant scale). It wanders 0.2 either way |
| `bw` | 0.1-1 | 0.5 | Each formant's width, as a fraction of its frequency: low is a narrow, ringing formant, high a broad, soft one |

## Granular Processing

Each voice has its own granular processor (reading the voice's synth, a buffer or the input; see [Audio Sources and Buffers](sources-and-buffers.md)) with independent control over:
- Grain size (texture density)
- Grain density (grains per second)
- Pitch (0.25x-4x, two octaves either way, with a subtle slow detune drift on unlocked voices). Pitch is each grain's playback rate: an exact transposition with no smearing. A pitch change (drift, an LFO, a scene fade) reaches the next grains, so pitch steps grain by grain instead of gliding. A buffer voice's grains read its sample faster or slower with the pitch, on top of its buffer rate
- Position spread: each grain starts a random distance back in what the voice played, up to half a second at full spread (for a buffer voice, a random offset around its position). It does nothing for a synth or input voice in triggered mode
- History (input-sourced voices only): how far back in the live input the grains play, 0 s (now) to 16 s (60 s on the high performance setting), while the input keeps coming in. Scenes capture it and fade it, and an LFO can move it (`v<i> hist`). Randomize and mutations leave it alone
- The grain's window, two controls (3.8): **grain shape** (0-1, from pointed through the Hann at 0.57, the default and 3.7's sound, to flat-topped) and **grain skew** (-1 to 1: from percussive, a fast rise and a long fall, through even at 0, to swelling). Each grain takes the window of the moment it starts, one of 8 shapes and 15 skews, so a shape turned slowly steps from window to window (0.50 to 0.64 is the Hann). Scenes capture and fade them, and an LFO, a matrix routing or a macro can move them (`v<i> shape`, `v<i> skew`); randomize and mutations leave them alone. The five envelopes of 3.7 (hann, sine, perc, linen, trap) are gone: a 3.7 PSET's envelope is not loaded, and each voice plays the default window
- **Grain prob** (0-100 %, 100 at first): in continuous mode each grain sounds by this chance, so the stream thins out; in triggered mode it does nothing (a step has its own probability)
- **Grain cloud**: **density** (grains a second at the grain density, as before) or **overlap**: a constant overlap as the size moves, **grain overlap** (0.25-16, 2 at first) grains at once, the grains a second being the overlap over the size each grain plays (with an LFO or envelope on the size, too), within 0.1 to 250 a second. Master density scales both. In overlap mode VOICE shows the overlap in the density's row; MAIN and the arc's ring 4 stay on the density, which overlap mode does not use. Continuous mode only: in triggered mode a voice plays one grain a trigger either way. Scenes switch the cloud at a transition's end
- **Pan wander** (0-100 %, 50 at first): how far the slow random pan wander moves the grains, from none to either side; at the center the pair is 3 dB down, as it always was
- Grain mode: **continuous** (grains stream at the grain density) or **triggered** (one grain per trigger; nothing sounds between triggers). The trigger's velocity sets the voice's accent, which the grain carries. Grain density does nothing in triggered mode, and neither does position spread for a voice playing its synth or the input (a buffer-sourced voice still spreads each triggered grain's position). Switching modes changes only what starts new grains: the grains already sounding play out with their own envelope, so after a switch to triggered a voice rings on for up to a grain (at most 0.5 s) before it falls silent. In triggered mode grains fire from pattern steps (and MIDI notes), at most one every 4 ms: two notes on one voice within 4 ms (a chord whose notes arrive a little apart, or a flood of MIDI notes) give one grain, while pattern steps (at least 50 ms apart) never lose one; K3 keeps its start/stop meaning (ALT+K3 locks), so it does not fire grains. The MAIN page shows `[T]` for a voice in triggered mode. Like the cloud, scene transitions switch it at the end and mutations leave it alone

### How the grains play

Every voice's grains read audio that is already there: a synth voice writes its synth into a 4-second loop of its own, an input voice reads the last seconds of the input, and a buffer voice reads its buffer. So a synth or input voice's grains start a few milliseconds in the past. Raising the pitch makes a grain read faster than the audio arrives, so it starts further back: at pitch 2 a grain length back, and at the extremes (pitch 4, 0.5 s grains) 1.5 s back. In triggered mode a grain instead stays close to the trigger: above pitch 2 it is shortened (at pitch 4 a 0.5 s grain lasts 0.17 s), so an accent never arrives late. A synth or input voice's grains play at most 4x, forward or backward (two octaves up), so pitch, jitter and intervals that ask for more stop there, and so, on an input voice, do pitchbend and frequency cross-modulation (a synth voice's pitchbend and cross-modulation move its synth's pitch, not its grains' rate); buffer voices have no such limit. Input voices now follow pitchbend and frequency cross-modulation, as buffer voices do.

### Bookmarks

A buffer voice has four bookmarks: saved positions in its slot (0-1 of the slot's length, shown with three decimals), starting at 0, 0.25, 0.5 and 0.75. They are the last rows of the VOICE page for a voice reading a buffer (see [VOICE](pages/voice.md)), so you can set one like any other row (a grid's store key also sets one: [Grid](grid.md)), and they are saved in scenes and PSETs (a scene fades them like any other value). A bookmark changes nothing until it is recalled, with the BUFFER page's `bm` field (E3 steps to a bookmark, ALT+E3 returns to the one shown; see [BUFFER](pages/buffer.md)), a grid's bookmark keys or a pattern step's bookmark lock (see [Sequencer](sequencer.md); a step recalls only a bookmark inside the loop): recalling jumps the voice's grains there (inside its loop, or, if the bookmark lies outside the loop, the loop becomes the whole slot first) and restarts its scan. A bookmark holds a place in the slot, so it means the same place if the loop changes. Randomize and mutations never touch them.

### Scan modes and tempo follow

A buffer voice's **buffer scan** is a speed: at 1 its position moves through the audio at the audio's own rate, whatever the loop's length, at 2 twice as fast, and below 0 backward (VOICE shows it as `1.00x`). With the grain pitch and buffer rate at 1, a scan of 1 plays the audio in its own time; then the pitch changes the pitch and not the time, and the scan the time and not the pitch. Two more rows follow the loop on VOICE, for a voice reading a buffer (and after them `slices`: [Slices](slices.md)):
- **scan mode** (wrap, bounce, one shot; wrap): what the scan does at the loop's end. **wrap** goes round to the start again, as before 3.7; **bounce** turns back and plays the loop backward, then forward again; **one shot** plays it once and stays silent at the end (or at the start, scanning backward) until the voice's next hit: a pattern step, a MIDI note or a retrigger restarts it. Changing the mode restarts the scan.
- **follow** (off, stretch, repitch; off): for a voice reading a file that has a tempo, the scan follows the clock's tempo. **stretch** keeps the pitch and moves the scan by the clock's tempo over the file's (a 120 BPM loop at 90 BPM scans at three quarters), so the loop stays on the beat; **repitch** moves the speed and the pitch together, as a tape would (its read rate stops at a quarter and four times). A file with no tempo plays as with follow off. The values the rows show never move: the follow changes only what the engine plays. Once a bar a following voice in wrap or bounce is put back on the beat (not while its scan is held, glides or is frozen).

Scenes store both and switch them at the end of a transition; randomize, mutations and the grid's fader pages leave them alone.

**A sliced loop on the beat** at any tempo takes three settings: **buffer scan** 1, **scan mode** one shot and **follow** stretch. Each piece then lasts its own length in beats, and a pattern that plays the pieces in order rebuilds the loop.

### Grain variation

Each grain can differ from the one before it. These are the rows of the VOICE page's **variation** section (and PARAMETERS > voice n extras, except quantize, which is listed above the voice's freq); at their defaults every grain plays as in 3.1. A synth or input voice's grains never play faster than 4x (see [How the grains play](#how-the-grains-play)), so at pitch 4 the upward half of the pitch jitter and the upper intervals play at the voice's pitch, and at pitch 2 a +19 plays +12; a buffer voice plays them as set:
- **reverse** (0-100%, 0): the chance that a grain plays backward
- **pitch jitter** (0-12 st, 0): each grain's pitch moves at random up to that many semitones either way
- **pan jitter** (0-1, 0): each grain moves at random across the stereo field, up to fully across at 1, on top of the slow pan wander
- **size jitter** (0-1, 0): each grain's length is the grain size times up to 2 either way (at 1, half to double), but never longer than 0.5 s
- **intervals** (off, octaves, fifths, chord, custom; off): each grain adds one interval from the set, picked at random. Octaves are -12, 0 and +12 semitones; fifths -12, -5, 0, +7 and +12; chord the root, third, fifth and seventh of the scale (0, 4, 7 and 11 semitones with the scale off); custom the five **custom** rows, -24 to +24 semitones each (-12, 0, 7, 12 and 19 to start), shown only while the set is custom
- **interval prob** (0-100%, 100%): the chance that a grain takes an interval at all; the others play at the voice's pitch
- **quantize** (off/on, off): every grain's pitch (with its jitter and interval) lands on a tone of the scale. For a synth voice the freq param snaps to the scale too, turned by E3, the arc or PARAMETERS one scale tone at a time (about a semitone of turning per tone); anything that sets it instead (a scene crossfade, a MIDI-mapped CC, a grid fader) lands on the tone nearest its own value, so a crossfade climbs or falls through the scale once, and MIDI notes play the nearest tone (a note between two tones plays the lower)

Scenes capture all of them; intervals, quantize and the custom intervals switch at the end of a fade, the rest fade. Randomize and mutations leave them alone; of them, the grid's fader pages show the pitch, size and pan jitters.

### The arpeggiator

VOICE's `arp` row (the last of the grain section; PARAMETERS > voice n extras) sets the voice's arpeggiator: **off** (the default), **up**, **down**, **up-down** or **shuffle**. On, the grains no longer pick an interval at random: each grain takes the next step of a list, in turn.
- **With no chord held** the list is the voice's interval set (above): up plays it from the lowest interval to the highest, down from the highest, up-down up and back again, and shuffle in an order drawn afresh at each of the voice's hits (a step, a MIDI note) and at least every 4 seconds. With `intervals` off the list is empty and the voice plays its own pitch. A scale or tuning change moves a chord set's list with it.
- **A held chord becomes the list**: on a running voice whose arpeggiator is on, the keys held beside the voice's own note (a MIDI keyboard's, an MPE controller's, a sequencer step's chord) are no extra notes: each is a step, measured from the own note, so one grain stream walks the chord (C, E and G held: 0, +4 and +7 semitones, in the order the mode gives; two keys alternate). Up to eight steps, the own note's included; a ninth key takes the oldest one's place. Each key accents the voice as it goes down; lifting a key in release mode takes its step out, and in latch mode the chord stays until the next chord's first key. Lifting the own note's key leaves the voice sounding on that note, and the chord's steps stay measured from it until the next key you play becomes the voice's own note. A step's chord is the list for its step and ends with it.
- **Turned on while extra notes sound**, the arpeggiator takes their pitches into its list and their notes end at once; **turned off**, the list ends: the own note plays on, and the other keys still down sound again only when played again.
- The notes of the list have no expression of their own: an MPE controller's per-note bend, pressure and slide do not reach them (the own note keeps its). MIDI out and the other note targets still play the whole chord. A slice (a buffer voice's `slices` notes) is never a step: it plays in a note of its own as before.
- On a synth voice the steps transpose the grains (the 3.2 sound); a synth or input voice's grains play at most 4x, so a wide chord at a high pitch stops there. In a tuning other than twelve equal steps each step is the key's exact pitch in it.
- Scenes keep the mode and switch it at the end of a fade; the held chord is never saved.

### Envelope times

Every synth voice fades in over an attack and out over a release, set in VOICE's `notes` section by `attack` (0.005-30 s) and `release` (0.01-30 s). Each voice starts at its own times, the ones it always had (Resonator 4 and 8 s, FM 5 and 10, Folder 3 and 6, Sub 8 and 12, Pulse 2 and 4, Karplus 0.01 and 2, Ring 3 and 5), so nothing sounds different until you turn them. They apply to the next start or note and to a voice fading out now; scenes store them and crossfade them, randomize leaves them alone, and they are the last two of the grid's fader pages. `release` shapes in full a note that ends while its voice runs (an extra note's key lifted, or the voice's own note fading under others); a voice's stop fades out in at most about 2 s whatever it is set to, since the voice's granular processor fades over 2 s as it stops (a shorter release is heard as set). They shape a synth voice's synths only: a buffer or input voice's notes, and a frozen synth voice's, are granular processors with fades of their own (0.1 s in, 2 s out), which the two leave alone (a frozen voice's times apply again once it unfreezes).

### Chords

A voice plays up to eight notes at once: its own note, which its settings pitch as always (a synth voice's freq, a buffer voice's buffer rate, an input voice's grain pitch), and up to seven extra notes, each at a pitch of its own, from a note pool the seven voices share (SETUP's `note pool`: 4 by default on the standard tier, 8 on high; [Performance tiers](technical.md#performance-tiers)). Keys held together on a MIDI keyboard or an MPE controller play them ([MIDI Input](midi.md)), and so does a sequencer step's chord ([Sequencer](sequencer.md)). VOICE's `note cap` limits a voice's notes (at 1 it plays one note, as before 3.5), and MAIN shows a voice's count from two (`1+ reso 3`). What an extra note is depends on what the voice plays:
- **a synth voice**: another synth of the voice's kind at the note's pitch, with its own pluck (Karplus) and its own main control under slide, fading in and out over the voice's `attack` and `release`. The voice's one granular processor grains the whole chord, so grain size and position act on every note together
- **a buffer voice**: another granular processor reading the voice's buffer at the note's rate (note 60 plays at 1, or the file's key when it has one: [A File's Settings](files.md)), starting at the voice's position, with its own position and size under pressure and slide. The BUFFER page's playhead shows the voice's own note
- **an input voice**: another granular processor reading the input at the note's pitch
- **a frozen synth voice**: freezing a synth voice ends its extra notes (their sound is in the frozen recording), and so does recalling a scene that leaves a voice a frozen synth voice, and a note played while it is frozen plays the frozen sound itself at the note's pitch: the key the voice was at when it froze plays it as it is, a key a fifth above plays it a fifth up. Unfreezing turns the notes still held into synths again, at their pitches

Every setting of the voice reaches all its notes: its grain settings (but a buffer voice's buffer rate and an input voice's grain pitch, which are its own note's pitch), its filter, sends, level and mute, its LFOs and the matrix. Changing the voice's source, or recalling a scene, while notes are held keeps every note sounding on what the voice now plays, each at its own pitch (but a recall that leaves the voice a frozen synth voice ends its extra notes, as freezing it does); stopping the voice ends them all. With `seq gate` on, every note started opens the voice's gate ([Sequencer](sequencer.md#gates)). A chord is louder than a note: nothing turns a voice down for its number of notes, and the master limiter is the bound.

### Mute and solo

Each voice has `mute` and `solo` rows at the end of VOICE's filter & sends section (and params `v1_mute`, `v1_solo`, ...). A voice is silenced while it is muted, or while any voice is soloed and it is not; a mute wins over the voice's own solo. Silencing happens in the voice's mix stage: the voice keeps running, its pattern keeps stepping, its LFOs and scenes keep acting on it, other voices still hear it through crossmod, and the delay and reverb tails already sent ring out. MAIN's voice list shows `m` for a silenced running voice and `s` for a soloed one. Scenes keep each voice's mute and never its solo, so a recall mutes and unmutes voices and leaves a solo as it is. Randomize and mutations never change either, and neither is a grid fader.

### Scales

PARAMETERS > scale holds the **scale** (off, or any of norns' scales: Major, Natural Minor, Dorian, the pentatonics, ...) and its **root** (C-B), which every quantizing voice shares. With the scale off, quantize rounds to semitones. A synth voice quantizes around its own pitch; a buffer or input voice, whose key Strata cannot know, takes its audio to be in the root (C4 for root C). A buffer voice played at another rate (a MIDI note, its buffer rate) is transposed by it and its grains still land on the scale. Changing the scale or root moves every quantizing voice's pitch to the nearest tone of the new scale (not while a scene is recalled or fading). Scenes capture the scale, root and scale mask and switch them at the end of a fade. A PSET loads every voice's saved pitch exactly, whatever its quantize was set to before.

A grain lands on the tone nearest its own pitch (a tie goes down). Since 3.8 this holds for a pitch between two notes too (a jittered grain, a fractional pitch shift): in a scale, about one fractional pitch in six now lands a tone away from where Strata 3.7 put it.

The **custom** scale (the last in the list) is any set of the twelve notes, held as the scale mask; the scale and tuning editor (SETUP's `scale & tuning`) toggles its notes. Toggling a note of a built-in scale there copies that scale into custom first.

### Tunings

Strata plays one tuning, 12 equal (exact equal temperament) by default. Every MIDI key, quantize, step degree and chord follows it. Choose one on SETUP's `scale & tuning` editor: the built-ins are 12 equal; the five just tunings of norns' intonation library (ji normal, ptolemy, overtone, undertone, lamonte); pythagorean and meantone 1/4 (fifths from Eb to G#); 19, 24 and 31 equal; and Partch's 43. Your own Scala (`.scl`) files in `data/strata/tunings/` follow them, named for the file. A file is read as text: one over 128 tones, with a period outside 100-4800 cents or tones that do not ascend is refused, and the editor's hint row says why.

- **Keys**: degree 0 sits on MIDI note 60 plus the root (C4 for root C), and each key above or below is the next tone, a period up or down at each wrap. So the root transposes the tuning, and A is 440 Hz only where the tuning puts it.
- **Scales** apply only in a tuning of twelve notes to an octave (the just tunings, pythagorean, meantone): there the scale picks which of its twelve tones are allowed. In any other tuning every tone is allowed and the editor shows `--` for the scale and its notes.
- **Chords** (the chord interval set): with a scale on, in twelve notes to an octave, the scale's 1st, 3rd, 5th and 7th tones; otherwise the tuning's tones nearest 0, 4, 7 and 11 semitones.
- **Turning** a quantized pitch with E3 moves about one tone a detent in a dense tuning (24 or 31 equal, Partch); 12 equal and every scale turn as before.
- A PSET saves the tuning, and a PSET without one (saved before 3.8) loads 12 equal. Scenes do not hold the tuning.
- MIDI out in MPE mode sends a tuned note's distance from its nearest key in its bend; plain MIDI out and nb send the nearest key ([MIDI out](io/midi-out.md)). crow, Just Friends, W/syn, the ER-301 and the TELEXo play the tuned pitch as it is.

## Performance Features

- **Randomization** - Generate new parameter sets for each voice
- **Lock** - Protect a voice's parameters while others continue to evolve
- **Freeze** - Hold what a voice's grains are playing while pitch, spread and grain size keep moving; see [Freeze on the VOICE page](pages/voice.md#freeze)
- **Drift** - A slow random walk adds subtle grain pitch movement to active voices that are not locked; it always drifts back toward the pitch you set
