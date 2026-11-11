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

A buffer voice has four bookmarks: saved positions in its slot (0-1 of the slot's length, shown with three decimals), starting at 0, 0.25, 0.5 and 0.75. They are the last rows of the VOICE page for a voice reading a buffer (see [VOICE](pages/voice.md)), so you can set one like any other row (a grid's store key also sets one: [Grid](grid.md)), and they are saved in scenes and PSETs (a scene fades them like any other value). A bookmark changes nothing until it is recalled, with the BUFFER page's `bm` field (E3 steps to a bookmark, ALT+E3 returns to the one shown; see [BUFFER](pages/buffer.md)) or a grid's bookmark keys: recalling jumps the voice's grains there (inside its loop, or, if the bookmark lies outside the loop, the loop becomes the whole slot first) and restarts its scan. A bookmark holds a place in the slot, so it means the same place if the loop changes. Randomize and mutations never touch them.

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

### Scales

PARAMETERS > scale holds the **scale** (off, or any of norns' scales: Major, Natural Minor, Dorian, the pentatonics, ...) and its **root** (C-B), which every quantizing voice shares. With the scale off, quantize rounds to semitones. A synth voice quantizes around its own pitch; a buffer or input voice, whose key Strata cannot know, takes its audio to be in the root (C4 for root C). A buffer voice played at another rate (a MIDI note, its buffer rate) is transposed by it and its grains still land on the scale. Changing the scale or root moves every quantizing voice's pitch to the nearest tone of the new scale (not while a scene is recalled or fading). Scenes capture the scale and root and switch them at the end of a fade. A PSET loads every voice's saved pitch exactly, whatever its quantize was set to before.

## Performance Features

- **Randomization** - Generate new parameter sets for each voice
- **Lock** - Protect a voice's parameters while others continue to evolve
- **Freeze** - Hold what a voice's grains are playing while pitch, spread and grain size keep moving; see [Freeze on the VOICE page](pages/voice.md#freeze)
- **Drift** - A slow random walk adds subtle grain pitch movement to active voices that are not locked; it always drifts back toward the pitch you set
