# Voices and Granular Processing

The seven synthesis voices, each voice's granular processor and the per-voice performance features. Back to the [README](../../README.md).

## Seven Synthesis Voices

1. **Resonator** - Filtered noise through resonant filter banks with slow modulation (level-matched to the other voices and limited, so at its normal settings it no longer pushes the rest of the mix down; as a cross-modulation source it is now as strong as the other voices, where before it drove what it modulated to the limit at almost any depth)
2. **FM** - Two-operator FM synthesis with evolving harmonic/inharmonic timbres
3. **Folder** - Sine wave through wavefolder with dynamic folding amount
4. **Sub** - Ultra-low frequency sine wave for grounding the mix
5. **Pulse** - Pulse width modulation synthesis with resonant filtering for classic analog sounds. Its res (0.1-1, default 0.8) rises with resonance like every other res: turned up, the filter rings at its cutoff; at 0.1 it is flat. Before 3.3 it ran the other way; scenes and PSETs saved then sound the same and show the turned-around number (0.3 shows as 0.8), and a controller mapped to it or its grid fader now sharpens it as it goes up
6. **Karplus** - Karplus-Strong plucked string synthesis for organic, physical timbres
7. **Ring** - Ring modulation between two oscillators for metallic, bell-like textures

## Synthesis Parameters

Each voice's own parameters, by the names the VOICE page's synth section, MAIN and PARAMETERS (the voice's first part) show; the grid's fader pages run through them in this order. MAIN's E3 and arc ring 2 adjust the one marked *main*. Most of the sounds also move on their own: slow random wobbles keep each voice drifting while nothing is turned, so a setting is the center of a movement more than a fixed value. Every voice also has **amp**, its level (0-1; 0.25 to 0.4 to start, by voice), and all but the Sub have **pan** (-1 left to 1 right, 0 center); the VOICE page shows them in its mix section. While a voice's source is a buffer or the input, its synthesis parameters do nothing; amp and pan still do.

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

## Granular Processing

Each voice has its own granular processor (reading the voice's synth, a buffer or the input; see [Audio Sources and Buffers](sources-and-buffers.md)) with independent control over:
- Grain size (texture density)
- Grain density (grains per second)
- Pitch (0.25x-4x, two octaves either way, with a subtle slow detune drift on unlocked voices). Pitch is each grain's playback rate: an exact transposition with no smearing. A pitch change (drift, an LFO, a scene fade) reaches the next grains, so pitch steps grain by grain instead of gliding. A buffer voice's grains read its sample faster or slower with the pitch, on top of its buffer rate
- Position spread: each grain starts a random distance back in what the voice played, up to half a second at full spread (for a buffer voice, a random offset around its position). It does nothing for a synth or input voice in triggered mode
- History (input-sourced voices only): how far back in the live input the grains play, 0 s (now) to 16 s (60 s on the high performance setting), while the input keeps coming in. Scenes capture it and fade it, and an LFO can move it (`v<i> hist`). Randomize and mutations leave it alone
- Grain envelope (the shape of each grain: hann, sine, perc, linen or trap); scene transitions switch it at the end instead of crossfading, and mutations leave it alone
- Grain mode: **continuous** (grains stream at the grain density) or **triggered** (one grain per trigger; nothing sounds between triggers). The trigger's velocity sets the voice's accent, which the grain carries. Grain density does nothing in triggered mode, and neither does position spread for a voice playing its synth or the input (a buffer-sourced voice still spreads each triggered grain's position). Switching modes changes only what starts new grains: the grains already sounding play out with their own envelope, so after a switch to triggered a voice rings on for up to a grain (at most 0.5 s) before it falls silent. In triggered mode grains fire from pattern steps (and MIDI notes), at most one every 4 ms: two notes on one voice within 4 ms (a chord whose notes arrive a little apart, or a flood of MIDI notes) give one grain, while pattern steps (at least 50 ms apart) never lose one; K3 keeps its start/stop meaning (ALT+K3 locks), so it does not fire grains. The MAIN page shows `[T]` for a voice in triggered mode. Like the envelope, scene transitions switch it at the end and mutations leave it alone

### How the grains play

Every voice's grains read audio that is already there: a synth voice writes its synth into a 4-second loop of its own, an input voice reads the last seconds of the input, and a buffer voice reads its buffer. So a synth or input voice's grains start a few milliseconds in the past. Raising the pitch makes a grain read faster than the audio arrives, so it starts further back: at pitch 2 a grain length back, and at the extremes (pitch 4, 0.5 s grains) 1.5 s back. In triggered mode a grain instead stays close to the trigger: above pitch 2 it is shortened (at pitch 4 a 0.5 s grain lasts 0.17 s), so an accent never arrives late. A synth or input voice's grains play at most 4x, forward or backward (two octaves up), so pitch, jitter and intervals that ask for more stop there, and so, on an input voice, do pitchbend and frequency cross-modulation (a synth voice's pitchbend and cross-modulation move its synth's pitch, not its grains' rate); buffer voices have no such limit. Input voices now follow pitchbend and frequency cross-modulation, as buffer voices do.

### Bookmarks

A buffer voice has four bookmarks: saved positions in its slot (0-1 of the slot's length, shown with three decimals), starting at 0, 0.25, 0.5 and 0.75. They are the last rows of the VOICE page for a voice reading a buffer (see [VOICE](pages/voice.md)), so you can set one like any other row (a grid's store key also sets one: [Grid](grid.md)), and they are saved in scenes and PSETs (a scene fades them like any other value). A bookmark changes nothing until it is recalled, with the BUFFER page's `bm` field (E3 steps to a bookmark, ALT+E3 returns to the one shown; see [BUFFER](pages/buffer.md)) a grid's bookmark keys or a pattern step's bookmark lock (see [Sequencer](sequencer.md); a step recalls only a bookmark inside the loop): recalling jumps the voice's grains there (inside its loop, or, if the bookmark lies outside the loop, the loop becomes the whole slot first) and restarts its scan. A bookmark holds a place in the slot, so it means the same place if the loop changes. Randomize and mutations never touch them.

### Grain variation

Each grain can differ from the one before it. These are the rows of the VOICE page's **variation** section (and PARAMETERS > voice n extras, except quantize, which is listed above the voice's freq); at their defaults every grain plays as in 3.1. A synth or input voice's grains never play faster than 4x (see [How the grains play](#how-the-grains-play)), so at pitch 4 the upward half of the pitch jitter and the upper intervals play at the voice's pitch, and at pitch 2 a +19 plays +12; a buffer voice plays them as set:
- **reverse** (0-100%, 0): the chance that a grain plays backward
- **pitch jitter** (0-12 st, 0): each grain's pitch moves at random up to that many semitones either way
- **pan jitter** (0-1, 0): each grain moves at random across the stereo field, up to fully across at 1, on top of the slow pan wander
- **size jitter** (0-1, 0): each grain's length is the grain size times up to 2 either way (at 1, half to double), but never longer than 0.5 s
- **intervals** (off, octaves, fifths, chord, custom; off): each grain adds one interval from the set, picked at random. Octaves are -12, 0 and +12 semitones; fifths -12, -5, 0, +7 and +12; chord the root, third, fifth and seventh of the scale (0, 4, 7 and 11 semitones with the scale off); custom the five **custom** rows, -24 to +24 semitones each (-12, 0, 7, 12 and 19 to start), shown only while the set is custom
- **interval prob** (0-100%, 100%): the chance that a grain takes an interval at all; the others play at the voice's pitch
- **quantize** (off/on, off): every grain's pitch (with its jitter and interval) lands on a tone of the scale. For a synth voice the freq param snaps to the scale too, turned by E3, the arc or PARAMETERS one scale tone at a time (about a semitone of turning per tone); anything that sets it instead (a scene crossfade, a MIDI-mapped CC, a grid fader) lands on the tone nearest its own value, so a crossfade climbs or falls through the scale once, and MIDI notes play the nearest tone (a note between two tones plays the lower)

Scenes capture all of them; intervals, quantize and the custom intervals switch at the end of a fade, the rest fade. Randomize and mutations leave them alone, and they are not on the grid's fader pages.

### Mute and solo

Each voice has `mute` and `solo` rows at the end of VOICE's filter & sends section (and params `v1_mute`, `v1_solo`, ...). A voice is silenced while it is muted, or while any voice is soloed and it is not; a mute wins over the voice's own solo. Silencing happens in the voice's mix stage: the voice keeps running, its pattern keeps stepping, its LFOs and scenes keep acting on it, other voices still hear it through crossmod, and the delay and reverb tails already sent ring out. MAIN's voice list shows `m` for a silenced running voice and `s` for a soloed one. Scenes keep each voice's mute and never its solo, so a recall mutes and unmutes voices and leaves a solo as it is. Randomize and mutations never change either, and neither is a grid fader.

### Scales

PARAMETERS > scale holds the **scale** (off, or any of norns' scales: Major, Natural Minor, Dorian, the pentatonics, ...) and its **root** (C-B), which every quantizing voice shares. With the scale off, quantize rounds to semitones. A synth voice quantizes around its own pitch; a buffer or input voice, whose key Strata cannot know, takes its audio to be in the root (C4 for root C). A buffer voice played at another rate (a MIDI note, its buffer rate) is transposed by it and its grains still land on the scale. Changing the scale or root moves every quantizing voice's pitch to the nearest tone of the new scale (not while a scene is recalled or fading). Scenes capture the scale and root and switch them at the end of a fade. A PSET loads every voice's saved pitch exactly, whatever its quantize was set to before.

## Performance Features

- **Randomization** - Generate new parameter sets for each voice
- **Lock** - Protect a voice's parameters while others continue to evolve
- **Freeze** - Hold what a voice's grains are playing while pitch, spread and grain size keep moving; see [Freeze on the VOICE page](pages/voice.md#freeze)
- **Drift** - A slow random walk adds subtle grain pitch movement to active voices that are not locked; it always drifts back toward the pitch you set
