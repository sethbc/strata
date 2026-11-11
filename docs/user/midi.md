# MIDI Input

Playing the voices from a MIDI keyboard or sequencer, and mapping MIDI CCs to parameters. Back to the [README](../../README.md).

A MIDI keyboard or sequencer plays the voices: one channel per voice (or every channel to the selected voice), the note sets the voice's pitch, the velocity sets its accent, and pitchbend bends it by up to 2 semitones. Any parameter can follow a MIDI CC through norns' own PARAMS > MAP. The sections below give the details.

## Playing the voices

A MIDI keyboard or sequencer plays the voices. Choose the port on the SETUP page (the first field; E3 changes it) or in PARAMETERS > midi; the port numbers are the norns SYSTEM > DEVICES > MIDI slots 1-16. Devices can be plugged in and out while Strata runs; unplugging the device, or moving it to another port in SYSTEM > DEVICES, releases the notes it was holding (in voice off mode, the voices those keys held stop).

- **Channels** - In **per voice** mode (the default) MIDI channel 1 plays voice 1 (Resonator) ... channel 7 plays voice 7 (Ring); channels 8-16 are ignored. In **omni to selected** mode every channel plays the voice selected with E2
- **Notes** - A note sets the voice's pitch: its frequency for a synth voice (exact equal temperament, limited to 20 Hz-2 kHz), its buffer rate for a buffer-sourced voice (note 60 plays at rate 1, an octave up doubles it, limited to 0.25x-4x); an input-sourced voice takes no pitch. A voice that is off starts; then the note accents it at the note's velocity (Karplus plucks its string, a triggered-mode voice fires a grain). Voices keep their slow attacks: Strata is not a fast-attack synth, the velocity lands on the accent
- **Note off** - Ignored by default, so a note starts a voice that keeps sounding. Set PARAMETERS > midi > midi note off to **voice off** for gated playing: a voice stops when its last held note is released, and a note played while it is still fading out brings it back without restarting its synths
- **Pitchbend** - Bends the voice by up to 2 semitones either way (its grains' rate for a buffer- or input-sourced voice). It is not saved in scenes; a voice started while the wheel is held starts bent. Changing the port or channel mode re-centers every bent voice. In omni mode the bend follows the selection: selecting another voice with the wheel off center returns the old voice to pitch and bends the new one by the wheel's position
- **All notes off** - CC 123 (all notes off) and CC 120 (all sound off), from any channel, release every held note and stop the voices those keys held, in either note off mode
- **Changing the channel mode** - Keys held at that moment keep the voices they started: their note offs still reach those voices
- **CC** - Strata has no other fixed CC mapping: map CCs to any parameter with norns' PARAMS > MAP (below)

## MIDI CC mapping (norns PARAMS > MAP)

Any Strata parameter can follow a MIDI CC through norns' built-in mapping:

1. Open the norns menu (K1), go to PARAMETERS and choose **MAP >** (E2 to select it, K3 to enter). In EDIT or MAP, K1 + K3 switches between the two
2. Select a parameter with E2 and press K3 to open its mapping
3. With **learn** selected press K3 and move the knob or fader on your controller (or set the device, channel and CC by hand with E2/E3); the remaining fields set the CC and output ranges
4. K2 leaves the mapping and saves it. norns keeps Strata's mappings in `~/dust/data/strata/strata.pmap` and loads them every time the script starts

These CCs make a good starting point (they follow the usual General MIDI meanings):

| CC | Controller | Strata parameter |
|----|------------|------------------|
| 1 | Mod wheel | master density |
| 7 | Volume | a voice's amp (for example voice 1 amp) |
| 10 | Pan | a voice's pan (for example voice 1 pan; the Sub, voice 4, has no pan) |
| 74 | Brightness | filter freq |
| 71 | Resonance | filter res |
| 91 | Reverb | reverb mix |
| 93 | Chorus | delay mix |

On most controllers CC 7 and CC 10 are an overall volume and pan. Strata has no single global amplitude or pan parameter, so map them to the voices you play: each voice's `v<n>_amp` and `v<n>_pan` (shown as amp and pan in its PARAMETERS section) work for synth-, buffer- and input-sourced voices alike.
