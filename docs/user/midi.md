# MIDI Input

Playing the voices from a MIDI keyboard, sequencer or MPE controller, and mapping MIDI CCs to parameters. Back to the [README](../../README.md).

A MIDI keyboard or sequencer plays the voices: one channel per voice, every channel to the selected voice, or, with an MPE controller, every note with its own pitch bend, pressure and slide. Each voice plays chords of up to eight notes. The note sets the pitch, the velocity sets the accent, pitchbend bends, and pressure swells the note. Any parameter can follow a MIDI CC through norns' own PARAMS > MAP. The sections below give the details.

## Playing the voices

Choose the port on the SETUP page (the first field; E3 changes it) or in PARAMETERS > midi; the port numbers are the norns SYSTEM > DEVICES > MIDI slots 1-16. Devices can be plugged in and out while Strata runs; unplugging the device, or moving it to another port in SYSTEM > DEVICES, releases every note it was playing (in release mode, the voices its keys held stop).

- **Channels** - PARAMETERS > midi > midi channels (SETUP's `channels` row) has four modes:
  - **per voice** (the default): MIDI channel 1 plays voice 1 (Resonator) ... channel 7 plays voice 7 (Ring); channels 8-16 are ignored;
  - **omni to selected**: every channel plays the voice selected with E2;
  - **mpe selected**: an MPE controller plays the selected voice, each note with its own expression (below);
  - **mpe split**: an MPE controller's notes play the voices whose zone and note range hold them (Split zones, below).
- **Notes** - A note sets its pitch: a frequency for a synth voice (exact equal temperament, limited to 20 Hz-2 kHz), a buffer rate for a buffer-sourced voice and a grain pitch for an input-sourced voice (note 60 plays at 1, an octave up doubles it, limited to 0.25x-4x). A voice set to quantize plays every note on its scale. A voice that is off starts; the first note accents it at the note's velocity (Karplus plucks its string, a triggered-mode voice fires a grain). Voices keep their attacks: the velocity lands on the accent, and each voice's `attack` and `release` times shape every note it plays
- **Chords** - A key played while another is down on the same voice adds a note to it: each voice plays up to eight notes at once, its own and up to seven more from a pool all voices share (SETUP's `note pool` row sets the pool, 4 by default on the standard performance and 8 on high). When the pool is full a new note takes the oldest extra note's place. A voice's `note cap` (VOICE's `notes` section) limits its notes; at 1 every key re-pitches the voice's one note, as Strata 3.4 did
- **Note off** - SETUP's `note off` row (PARAMETERS > midi > midi note off) chooses what lifting a key does:
  - **latch**: nothing. A chord keeps sounding, each note at the highest pressure it reached, and the next chord replaces it: the first key played after all are up ends the old chord and starts the new one;
  - **release**: each note fades as its key lifts, and the voice stops with its last key (whoever started it). A note played while the voice is still fading brings it back without restarting its synths;
  - **auto** (the default): latch in the per voice and omni modes, release in the MPE modes.
  A PSET made with Strata 3.4 keeps its behavior: its `ignore` is auto (latch on a plain keyboard), its `voice off` is release
- **Pitchbend** - In the per voice and omni modes the wheel bends the voice, every note it plays, by up to 2 semitones either way (its grains' rate for a buffer- or input-sourced voice). It is not saved in scenes; a voice started while the wheel is held starts bent. Changing the port or channel mode re-centers every bent voice. In omni mode the bend follows the selection: selecting another voice with the wheel off center returns the old voice to pitch and bends the new one by the wheel's position
- **Pressure** - Poly aftertouch presses its own note; channel aftertouch presses every note the channel holds, and the channel's next notes start at its pressure. What pressure does is set per voice in VOICE's `notes` section (`press target` and `press depth`): by default it swells the note's level, up to twice its own at full pressure, so a key at rest sounds as it always did
- **All notes off** - CC 123 (all notes off) and CC 120 (all sound off), from any channel, release every note and stop every voice a MIDI note started and that is still running, held or not, in any note off mode (a voice you started on the norns, the grid or a pattern is left alone)
- **Changing the channel mode** - releases every note, since the keys still down would no longer reach their voices; in release mode the voices those keys held stop
- **CC** - Strata has no other fixed CC mapping in the per voice and omni modes: map CCs to any parameter with norns' PARAMS > MAP (below)

## MPE

MPE (MIDI Polyphonic Expression) gives every note a channel of its own, so each note bends, presses and slides on its own. Strata reads the standard's zones:

- **The lower zone** is channel 1 (its master) and the member channels from 2 up: `mpe lower members` (PARAMETERS > midi, 15 by default) sets how many. **The upper zone** is channel 16 and the members from 15 down (`mpe upper members`, 0 by default: off). The two never overlap: setting one lowers the other while both have members. Notes on a channel in neither zone are ignored
- **Per note**: a member channel's pitch bend bends its note (over `mpe bend range`, 48 semitones by default) on top of its zone's master bend (2 semitones); its channel pressure is the note's pressure; CC 74 is the note's slide, measured from where the touch began, so a note starts on the stored sound wherever the finger lands. A controller that sends CC 87 before them gives 14-bit pressure and slide. What slide does is set per voice in VOICE's `notes` section (`slide target`, by default the voice's main control at 50 %)
- **The controller's own setup**: many MPE controllers send their zone layout (RPN 6) and bend range (RPN 0) when MPE is turned on, and Strata follows them: the member counts change (the header shows `MPE lower <n>` or `MPE upper <n>`) and so does the bend range. A plain keyboard on channel 1 plays the lower zone through its master channel
- **A change of zones** (a member count, a voice's zone or range) releases every note, as a mode change does

**Setting up a controller.** Turn the controller's MPE mode on, then choose `mpe selected` (or `mpe split`) on SETUP's `channels` row. Set the controller's pitch bend range and Strata's `mpe bend range` to the same number, or each note bends by the wrong amount; 48 semitones is the MPE standard's default. Each controller's manual says where its settings are:
- **LinnStrument**: set the split you play to the MPE MIDI mode. Its X axis bends, its Z axis (pressure) presses and its Y axis sends CC 74, the slide; a note's Y starts where the finger lands, which Strata's relative slide ignores. With the surface split in two, the left split is the lower zone and the right split the upper: give each zone its member channels (for example 7 and 7) and choose `mpe split` to play a voice from each half
- **Osmose**: turn its MPE output on. A key's aftertouch is the note's pressure and its side-to-side movement the bend; its CC 74 starts at 0 at every note, so the slide moves only as the key does
- **Exquis**: choose its MPE mode. A pad's sideways tilt bends, its pressure presses, and its forward and back tilt is the slide, measured from the pad's center where every touch starts

Do not map CC 74, 87, 6, 38, 100 or 101 in PARAMS > MAP while an MPE controller is in use: MPE uses CC 74 and 87 for every note's slide and pressure, and 6, 38, 100 and 101 for its setup messages.

## Split zones

In `mpe split` mode each voice has a zone (off, lower or upper) and a lowest and highest note (PARAMETERS > zones, or SETUP's `mpe & zones` editor, where ALT+K3 on a voice's row learns its range from the next two notes played). A note plays every voice whose zone is the note's and whose range holds it, so overlapping ranges layer voices. By default voice 1 takes the lower zone's whole range and voice 2 the upper zone's: a LinnStrument split in two plays voice 1 on its left half and voice 2 on its right with nothing else set.

## MIDI CC mapping (norns PARAMS > MAP)

Any Strata parameter can follow a MIDI CC through norns' built-in mapping:

1. Open the norns menu (K1), go to PARAMETERS and choose **MAP >** (E2 to select it, K3 to enter). In EDIT or MAP, K1 + K3 switches between the two
2. Select a parameter with E2 and press K3 to open its mapping
3. With **learn** selected press K3 and move the knob or fader on your controller (or set the device, channel and CC by hand with E2/E3); the remaining fields set the CC and output ranges
4. K2 leaves the mapping and saves it. norns keeps Strata's mappings in `~/dust/data/strata/strata.pmap` and loads them every time the script starts

Mappings made with 3.3 on an LFO keep working where the LFO param kept its meaning: a CC on LFO 1-3's depth, offset, phase or clocked rate moves to the new LFO's param of the same name at start (with its range). A mapping on any other 3.3 LFO param (its state, shape, mode, free rate and the library's min, max, baseline and reset settings) is removed at start, as MAP cannot show it; without that, every CC sent to it would raise an error in norns' MIDI handler. The maiden console names each mapping moved or removed, and Strata saves the mappings again so this happens once. Every other mapping is left as it is, including one on a parameter a mod adds after Strata starts.

These CCs make a good starting point (they follow the usual General MIDI meanings):

| CC | Controller | Strata parameter |
|----|------------|------------------|
| 1 | Mod wheel | master density |
| 7 | Volume | a voice's amp (for example voice 1 amp) |
| 10 | Pan | a voice's pan (for example voice 1 pan; the Sub, voice 4, has no pan) |
| 74 | Brightness | filter freq (not with an MPE controller: CC 74 is its slide) |
| 71 | Resonance | filter res |
| 91 | Reverb | reverb mix |
| 93 | Chorus | delay mix |

On most controllers CC 7 and CC 10 are an overall volume and pan. Strata has no single global amplitude or pan parameter, so map them to the voices you play: each voice's `v<n>_amp` and `v<n>_pan` (shown as amp and pan in its PARAMETERS section) work for synth-, buffer- and input-sourced voices alike.
