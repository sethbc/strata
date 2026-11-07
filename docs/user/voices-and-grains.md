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
- Pitch shifting (true transposition, 0.25x-4x, with a subtle slow detune drift on unlocked voices)
- Position spread (temporal smearing)
- Grain envelope (the shape of each grain: hann, sine, perc, linen or trap); scene transitions switch it at the end instead of crossfading, and mutations leave it alone
- Grain mode: **continuous** (grains stream at the grain density) or **triggered** (one grain per trigger; nothing sounds between triggers). The trigger's velocity sets the voice's accent, which the grain carries. Grain density does nothing in triggered mode, and neither does position spread for a voice playing its synth or the input (a buffer-sourced voice still spreads each triggered grain's position). Switching modes fades over about 50 ms instead of clicking. In triggered mode grains fire from pattern steps (and MIDI notes); K3 keeps its start/lock meaning, so it does not fire grains. The MAIN page shows `[TRIG]` for a voice in triggered mode. Like the envelope, scene transitions switch it at the end and mutations leave it alone

## Performance Features

- **Randomization** - Generate new parameter sets for each voice
- **Lock** - Protect a voice's parameters while others continue to evolve
- **Drift** - A slow random walk adds subtle grain pitch movement to active voices that are not locked; it always drifts back toward the pitch you set
