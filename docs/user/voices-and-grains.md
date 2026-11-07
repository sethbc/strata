# Voices and Granular Processing

The seven synthesis voices, each voice's granular processor and the per-voice performance features. Back to the [README](../../README.md).

## Seven Synthesis Voices

1. **Resonator** - Filtered noise through resonant filter banks with slow modulation (level-matched to the other voices and limited, so at its normal settings it no longer pushes the rest of the mix down; as a cross-modulation source it is now as strong as the other voices, where before it drove what it modulated to the limit at almost any depth)
2. **FM** - Two-operator FM synthesis with evolving harmonic/inharmonic timbres
3. **Folder** - Sine wave through wavefolder with dynamic folding amount
4. **Sub** - Ultra-low frequency sine wave for grounding the mix
5. **Pulse** - Pulse width modulation synthesis with resonant filtering for classic analog sounds
6. **Karplus** - Karplus-Strong plucked string synthesis for organic, physical timbres
7. **Ring** - Ring modulation between two oscillators for metallic, bell-like textures

## Granular Processing

Each voice has its own granular processor (reading the voice's synth, a buffer or the input; see [Audio Sources and Buffers](sources-and-buffers.md)) with independent control over:
- Grain size (texture density)
- Grain density (grains per second)
- Pitch (0.25x-4x, two octaves either way, with a subtle slow detune drift on unlocked voices). Pitch is each grain's playback rate: an exact transposition with no smearing. A pitch change (drift, an LFO, a scene fade) reaches the next grains, so pitch steps grain by grain instead of gliding. A buffer voice's grains read its sample faster or slower with the pitch, on top of its buffer rate
- Position spread: each grain starts a random distance back in what the voice played, up to half a second at full spread (for a buffer voice, a random offset around its position). It does nothing for a synth or input voice in triggered mode
- History (input-sourced voices only): how far back in the live input the grains play, 0 s (now) to 16 s (60 s on the high performance setting), while the input keeps coming in. Scenes capture it and fade it, and an LFO can move it (`v<i> hist`). Randomize and mutations leave it alone
- Grain envelope (the shape of each grain: hann, sine, perc, linen or trap); scene transitions switch it at the end instead of crossfading, and mutations leave it alone
- Grain mode: **continuous** (grains stream at the grain density) or **triggered** (one grain per trigger; nothing sounds between triggers). The trigger's velocity sets the voice's accent, which the grain carries. Grain density does nothing in triggered mode, and neither does position spread for a voice playing its synth or the input (a buffer-sourced voice still spreads each triggered grain's position). Switching modes fades over about 50 ms instead of clicking. In triggered mode grains fire from pattern steps (and MIDI notes); K3 keeps its start/stop meaning (ALT+K3 locks), so it does not fire grains. The MAIN page shows `[TRIG]` for a voice in triggered mode. Like the envelope, scene transitions switch it at the end and mutations leave it alone

### How the grains play

Every voice's grains read audio that is already there: a synth voice writes its synth into a 4-second loop of its own, an input voice reads the last seconds of the input, and a buffer voice reads its buffer. So a synth or input voice's grains start a few milliseconds in the past. Raising the pitch makes a grain read faster than the audio arrives, so it starts further back: at pitch 2 a grain length back, and at the extremes (pitch 4, 0.5 s grains) 1.5 s back. In triggered mode a grain instead stays close to the trigger: above pitch 2 it is shortened (at pitch 4 a 0.5 s grain lasts 0.17 s), so an accent never arrives late. Input voices now follow pitchbend and frequency cross-modulation, as buffer voices do.

### Grain variation

Each grain can differ from the one before it. These are the rows of the VOICE page's **variation** section (and PARAMETERS > voice n extras); at their defaults every grain plays as in 3.1:
- **reverse** (0-100%, 0): the chance that a grain plays backward
- **pitch jitter** (0-12 st, 0): each grain's pitch moves at random up to that many semitones either way
- **pan jitter** (0-1, 0): each grain moves at random across the stereo field, up to fully across at 1, on top of the slow pan wander
- **size jitter** (0-1, 0): each grain's length is the grain size times up to 2 either way (at 1, half to double), but never longer than 0.5 s
- **intervals** (off, octaves, fifths, chord, custom; off): each grain adds one interval from the set, picked at random. Octaves are -12, 0 and +12 semitones; fifths -12, -5, 0, +7 and +12; chord the root, third, fifth and seventh of the scale (0, 4, 7 and 11 semitones with the scale off); custom the five **custom** rows, -24 to +24 semitones each (-12, 0, 7, 12 and 19 to start), shown only while the set is custom
- **interval prob** (0-100%, 100%): the chance that a grain takes an interval at all; the others play at the voice's pitch
- **quantize** (off/on, off): every grain's pitch (with its jitter and interval) lands on a tone of the scale. For a synth voice the freq param snaps to the scale too, turned by E3 or the arc one scale tone at a time (about a semitone of turning per tone), and MIDI notes play the nearest tone (a note between two tones plays the lower)

Scenes capture all of them; intervals, quantize and the custom intervals switch at the end of a fade, the rest fade. Randomize and mutations leave them alone, and they are not on the grid's fader pages.

### Scales

PARAMETERS > scale holds the **scale** (off, or any of norns' scales: Major, Natural Minor, Dorian, the pentatonics, ...) and its **root** (C-B), which every quantizing voice shares. With the scale off, quantize rounds to semitones. A synth voice quantizes around its own pitch; a buffer or input voice, whose key Strata cannot know, takes its audio to be in the root (C4 for root C). Scenes capture the scale and root and switch them at the end of a fade.

## Performance Features

- **Randomization** - Generate new parameter sets for each voice
- **Lock** - Protect a voice's parameters while others continue to evolve
- **Drift** - A slow random walk adds subtle grain pitch movement to active voices that are not locked; it always drifts back toward the pitch you set
