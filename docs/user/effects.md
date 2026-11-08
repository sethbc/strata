# Global Controls and Effects

Master density, tape drift, the filter, delay, reverb, each voice's own filter and sends, the bypass, the limiter and tempo. Back to the [README](../../README.md).

- **Master Density** - Controls grain density across all voices simultaneously
- **Tape Drift** - Adds slow pitch drift to the entire mix for analog warmth; the amount sets the depth (0 = none)
- **Filter** - Lowpass, highpass or bandpass filter on the whole mix with resonance; its mix fades from bypassed (the default) to fully filtered, and changing the filter type crossfades (20 ms) instead of clicking. It filters what goes to the delay and reverb too, as it always has
- **Delay** - Stereo delay (10 ms to 2 s) with feedback, after the filter; starts dry
- **Reverb** - Adjustable mix (fully dry to fully wet), size, and damping. On the high performance setting it is a richer reverb (a feedback delay network) with about the same decay at each size
- **Limiter** - A limiter in the master stage catches peaks from filter resonance and delay feedback before the soft saturation
- **Tempo** - Sets norns' clock tempo, which the pattern sequencer follows; a tempo changed in PARAMETERS > CLOCK or by an external clock is picked up too

## Each voice's filter and sends

Every voice has a "filter & sends" section on the VOICE page (and in PARAMS, after the voice's own params):

- **filter type, freq, res, mix** - A lowpass, highpass or bandpass filter on the voice's grains, whatever its source (a cutoff sweep also moves a buffer's or the input's audio). Mix 0 (the default) leaves it out; a type change crossfades in 20 ms
- **delay send, reverb send** - How much of the voice goes to the delay and the reverb, 0-100%, default 100%

With both sends at 100% the delay and reverb mixes work exactly as before on standard (a moving reverb mix now glides over 50 ms instead of stepping; the high setting uses a different reverb): the delay mix and the reverb mix crossfade the whole sound between dry and wet. A send scales that voice's part of the crossfade: a voice with its sends at 0 plays fully dry at its full level, however high the global mixes are, while the other voices keep their echoes and reverb. Two things follow from the delay feeding the reverb: a voice with reverb send 0 still has its echoes reverberated, and a voice with delay send 0 still hears the other voices' echoes in the reverb.

The voice filter's cutoff and both sends are LFO destinations (`v1 vfilt`, `v1 dsend`, `v1 rsend`, ...). Scenes keep all six; the filter type switches at the end of a transition, the others fade. Randomize, mutations and the grid's fader pages leave them alone.

## Bypass

`delay bypass` and `reverb bypass` (PARAMS > fx, or K3 on the FX page's delay or reverb rows) switch an effect off completely: it fades out over 50 ms and stops running, which frees its CPU and its memory (the delay's 1 MB). Lifting the bypass brings it back at the same mix, starting empty, so the echoes or the tail build up again.

- The mix keeps its value while bypassed, and changing it, the delay time or the reverb size meanwhile takes effect when the bypass is lifted.
- A mix of 0 is not a bypass: an LFO, a scene fade or a MIDI CC can take a mix through 0 and the effect keeps running, so its echoes and tail are still there when the mix comes back up.
- PSETs store the bypass; scenes do not (a scene recall never switches an effect on or off). If a scene sets a mix while the effect is bypassed, the effect stays silent until the bypass is lifted.
