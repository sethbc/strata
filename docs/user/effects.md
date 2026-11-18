# Global Controls and Effects

Master density, tape drift, the filter, delay, reverb, each voice's own filter, dry level and sends, the bypass, the limiter and tempo. Back to the [README](../../README.md).

- **Master Density** - Controls grain density across all voices simultaneously
- **Tape Drift** - Adds slow pitch drift to the entire mix for analog warmth; the amount sets the depth (0 = none, the default ±0.2 %, the largest ±2 %). It only bends the pitch: a steady tone keeps its level at any amount (in earlier versions the drift's pitch shifter also made every sound flutter, at 0 too, and took some of the treble)
- **Filter** - Lowpass, highpass or bandpass filter on the whole mix with resonance; its mix fades from bypassed (the default) to fully filtered, and changing the filter type crossfades (20 ms) instead of clicking. A cutoff that jumps up (a scene recall, a square or random LFO, a controller jump) glides to its new value at 100 octaves a second, the whole range in a tenth of a second, so a resonant filter no longer throws a burst; it falls as fast as before. It filters what goes to the delay and reverb too, as it always has (one filter on the dry mix and one on each send, before the effects; never on what the effects return)
- **Delay** - Stereo delay (10 ms to 5.4 s) with feedback, after the filter; its level (the return, `delay level`) starts at 0, silent. Its time can follow the tempo in divisions of the beat (`sync`), and its repeats can alternate left and right (ping-pong): see [FX](pages/fx.md)
- **Reverb** - Its level (the return, `reverb level`, default 43%), size, and damping; `delay to reverb` (default 100%) sets how much of the delay's echoes it takes. On the high performance setting it is a richer reverb (a feedback delay network) with about the same decay at each size
- **Limiter** - A limiter in the master stage catches peaks from filter resonance and delay feedback before the soft saturation
- **Tempo** - Sets norns' clock tempo, which the pattern sequencer follows; a tempo changed in PARAMETERS > CLOCK or by an external clock is picked up too

## Each voice's filter and sends

Every voice has a "filter & sends" section on the VOICE page (and in PARAMS, after the voice's own params):

- **filter type, freq, res, mix** - A lowpass, highpass or bandpass filter on the voice's grains, whatever its source (a cutoff sweep also moves a buffer's or the input's audio). Mix 0 (the default) leaves it out; a type change crossfades in 20 ms; a cutoff that jumps up glides at 100 octaves a second, as the master filter's does
- **dry** - How much of the voice reaches the mix dry, 0-100%, default 100%
- **delay send, reverb send** - How much of the voice goes to the delay and the reverb, 0-100%, default 100%

### Plain sends

Since 3.8 the sends are plain sends, as on a mixing desk: each voice plays dry at its dry level and sends to the delay and the reverb at its sends, and the delay and the reverb return their echoes and tail at their own levels (`delay level` and `reverb level` in PARAMS, `level` on the FX page). The sends are taken before the dry level, so a voice at dry 0 is all effect. The master sums the dry mix and the two returns (times 0.7, so the limiter and the saturation see the level they always did).

- **delay to reverb** (PARAMS > fx, 0-100%, default 100%) - How much of the delay's return the reverb takes. At 100% the echoes are reverberated as before; at 0 a voice with no reverb send has dry echoes. A reverb at level 0 leaves the echoes: the delay's return reaches the master on its own. It is an LFO destination (`dly>rev`), and scenes keep it and crossfade it.
- **A default start sounds as before**: the reverb's level starts at 43% (3.7's 30% divided by 0.7) with every voice dry and sending at 100%. A scene or a PSET away from the defaults keeps its values, so its balance changes once: 3.7's reverb mix of 30% now reads as a level of 30%, a little less reverb than before, and its delay mix now adds the echoes on top of the dry sound instead of crossfading it away.

The voice filter's cutoff and both sends are LFO destinations (`v1 vfilt`, `v1 dsend`, `v1 rsend`, ...); the dry level is not. Scenes keep all seven; the filter type switches at the end of a transition, the others fade. Randomize and mutations leave them alone (VOICE's ALT+K2 on the section never draws the dry level either); the grid's [faders page](grid/pages/faders.md) shows the cutoff, resonance, mix, the dry level and both sends on the voice's fader pages, on every grid size.

## Delay freeze and clear

Both are in the fx group of the PARAMETERS menu.

- **delay freeze** - Holds what the delay is playing as a loop you can play over: within 20 ms its feedback goes to exactly 100% and it stops taking in sound, so the loop keeps its level, its brightness and, with ping-pong on, its width (a ping-pong of 50% or more is held as full ping-pong, below it as none). The loop keeps its length: a tempo change under sync or a new delay time waits until you release the freeze. Released, the loop fades away at the delay's feedback and the delay takes in sound again.
- **delay clear** - Empties the delay at once: its echoes stop, and the first echo of what comes in after plays one delay time later. Frozen, it empties the loop (it stays frozen, silent, until released).
- Neither is saved: a PSET neither stores nor changes a freeze, and scenes leave both alone. Bypassing the delay ends a freeze, and a freeze cannot be set while the delay is bypassed. Both can be mapped to MIDI (PARAMETERS > MAP); the FX page gets their rows in a later 3.8 package.

## Bypass

`delay bypass` and `reverb bypass` (PARAMS > fx, or K3 on the FX page's delay or reverb rows) switch an effect off completely: it fades out over 50 ms and stops running, which frees its CPU, and the reverb's memory too (the delay's line is kept apart from the memory the voices use, and emptied). Lifting the bypass brings it back at the same level, starting empty, so the echoes or the tail build up again from a 50 ms fade-in (a sound already playing comes into the first echo without a click).

- The level keeps its value while bypassed, and changing it, the delay time, the reverb size or delay to reverb meanwhile takes effect when the bypass is lifted.
- A level of 0 is not a bypass: an LFO, a scene fade or a MIDI CC can take a level through 0 and the effect keeps running, so its echoes and tail are still there when the level comes back up.
- PSETs store the bypass; scenes do not (a scene recall never switches an effect on or off). If a scene sets a level while the effect is bypassed, the effect stays silent until the bypass is lifted.
