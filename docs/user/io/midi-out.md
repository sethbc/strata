# MIDI out

Strata's voices can play a MIDI synth: each voice's steps and the notes you play on it go to a port and channel, as plain MIDI or as MPE. Eight CC slots send modulation out, and program changes can recall scenes and follow them. Back to [IO](../pages/io.md).

Everything starts off. Until you give a voice a port, set a CC slot's source or turn program change on, Strata sends no MIDI at all.

Built from the MIDI 1.0 specification and its MPE specification (MIDI Polyphonic Expression 1.0, the MMA's RP-053), and from norns' `lua/core/midi.lua`. It is unverified on the device until the 4.0 hardware check.

## A voice's route

On IO, the `voice` section shows the selected voice's `midi` row (ALT+E2 selects the voice); K3 opens its settings. The same settings are in PARAMETERS > out midi, saved with a PSET, never with a scene:
- **port**: `off`, or the MIDI port 1 to 16 the voice plays (the ports SYSTEM > DEVICES lists)
- **channel**: 1 to 16 (voice n starts on channel n), in plain mode
- **mode**: `plain` or `mpe`
- **members**: 1 to 15, the member channels of an MPE voice

The row reads `off`, `port 2  ch 3` or `port 2  mpe 15`.

### Plain

Each note goes out on the voice's channel at its nearest MIDI note, with its velocity. A note struck again while it sounds (a step repeating a note you hold, say) is sent as a note off and a new note on, so the synth always has one note off for each note on; the last note off goes when the last of them ends. A note you play into Strata is not sent back to the port it came in on (the `midi device` port in PARAMETERS > midi), so a keyboard that is also the synth does not double its notes; the voice's steps still go there.

### MPE

An MPE voice takes its port's lower zone: channel 1 is the master and channels 2 to members + 1 carry one note each where they can. Strata tells the synth so (the MPE configuration message, then the member channels' bend range, **bend range** on IO's `midi` section, 1 to 96 semitones, default 48, and the master channel's 2) when the mode turns on, the port, the members or the bend range change, and when the synth is plugged in. Turning the mode off, or moving the voice to another port, closes the zone on the old port.

A note takes the member channel freed longest ago; when every channel has a note, it shares the one with the fewest, and with it that channel's bend: a new note's first values stand there until a value of another note changes, and when a played note on it ends, the played notes still on it send their own values again. A note struck again on its channel while it sounds there is sent as a note off and a new note on, as in plain mode. A note you play carries its own bend, pressure and slide (CC 74): the values your controller sent go just before the note on, and later changes follow, whatever the voice's own pressure and slide targets are (those only decide what Strata's sound does with them). Strata sends at most 24 such messages each 1/48 s, the newest values, every note in turn. A step note has no expression: on a channel of its own it gets a centered bend before its note on; on a channel it shares, it takes the bend the channel has.

Only one voice can be MPE on a port, and a plain voice on that port needs a channel outside the zone. A change to a voice's route takes effect a moment after you make it (within 1/48 s), and changes made together in that moment are judged together. One that would break the rule goes back a moment after the turn, with the message `port has an mpe voice`, and nothing is sent. Plain and MPE voices can share a port on different channels (an MPE voice with 7 members leaves channels 9 to 16 free). A PSET brings every route back as it was saved. Only a file that breaks the rule (one edited by hand) is changed: its voices are taken in order, and a voice that clashes with a lower-numbered one comes back off, with the same message.

### When the synth comes back

If a port's device is unplugged and plugged in again, Strata sends all notes off (CC 123) on each channel it had notes on, then sets an MPE voice's zone up again.

## CC out

IO's `midi` section has eight rows, `cc 1` to `cc 8`; K3 opens one:
- **source**: `off`, or any modulation source MOD lists (`lfo1`, `macro3`, `pressure2`, `crow1`, ...)
- **port**, **channel**, **number** (0 to 127; slot k starts on CC k)

A slot sends its source across 0 to 127 whenever the value changes, while its port has a device. A slot following an LFO that runs in the engine (its destination shows `~` on the LFO page) sends Strata's own model of it and shows ` ~`: in step with a clocked LFO, drifting slowly from a free one. A PSET keeps each slot's source by its name, so a later release that adds sources still loads it on the same one.

## Program change

Both start off; the five rows are at the end of IO's `midi` section:
- **pc in**: a program change 0 to 15 on the `midi device` port recalls scene 1 to 16, as a scene key does (quantized when PARAMETERS > seq quantizes actions). **pc channel** picks the channel it listens on, or `any`. An empty scene does nothing, and so does any other program number.
- **pc out**: each scene recall sends program change scene - 1 on **pc out port** and **pc out channel**. A recall a program change asked for is not sent back to the port it came from, even when it waits for the beat or bar and other scenes are recalled meanwhile. If that waiting recall never happens (another scene key replaced it), the next recall of its scene sends nothing to that port, once.

The section's title line shows `[--]` while a port some setting sends on has no device.
