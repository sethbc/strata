# MIDI out

Strata's voices can play a MIDI synth: each voice's steps and the notes you play on it go to a port and channel, as plain MIDI or as MPE. Eight CC slots send modulation out, and program changes can recall scenes and follow them. Back to [IO](../pages/io.md).

Everything starts off. Until you give a voice a port, set a CC slot's source or turn program change on, Strata sends no MIDI at all.

Built from the MIDI 1.0 specification and its MPE specification (MIDI Polyphonic Expression 1.0, the MMA's RP-053), and from norns' `lua/core/midi.lua`. It is unverified on the device until the 4.0 hardware check.

## A voice's route

On IO, the `voice` section shows the selected voice's `midi` row (ALT+E2 selects the voice); K3 opens its settings. The same settings are in PARAMETERS > out midi, saved with a PSET, never with a scene:
- **port**: `off`, or the MIDI port 1 to 16 the voice plays (the ports SYSTEM > DEVICES lists). A port something else holds shows its owner beside the number, as SETUP's `midi` row does (`3 (remote grid)`): Strata sends nothing to a port a remote grid, a remote arc or `midi grid` holds, since those devices read notes as their lights, and sends there again once it is let go. A note still sounding on a port as one of them takes it gets its note off then, so the synth there is not left holding it; a note played while the port is held sends nothing at all, not even its note off once the port is let go. A controller's port (`(e16)`, `(faders)`) is still sent to as set
- **channel**: 1 to 16 (voice n starts on channel n), in plain mode
- **mode**: `plain` or `mpe`
- **members**: 1 to 15 (15 by default), the member channels of an MPE voice

The row reads `off`, `port 2  ch 3` or `port 2  mpe 15`.

### Plain

Each note goes out on the voice's channel at its nearest MIDI note, with its velocity (in a tuning other than 12 equal, a tuned note's cents are not sent: MPE mode carries them). A note struck again while it sounds (a step repeating a note you hold, say) is sent as a note off and a new note on, so the synth always has one note off for each note on; the last note off goes when the last of them ends. A note you play into Strata is not sent back to the port it came in on (the `midi device` port in PARAMETERS > midi), so a keyboard that is also the synth does not double its notes; the voice's steps still go there.

### MPE

An MPE voice takes its port's lower zone: channel 1 is the master and channels 2 to members + 1 carry one note each where they can. Strata tells the synth so (the MPE configuration message, then the member channels' bend range, **bend range** on IO's `midi` section, 1 to 96 semitones, default 48, and the master channel's 2) when the mode turns on, the port, the members or the bend range change, when the synth is plugged in, and when a remote grid, a remote arc or `midi grid` lets its port go (so the synth is set up before its first note). A device a remote grid or arc takes as it is plugged in gets none of it, and that includes a synth plugged into a port SETUP's rig still names for a remote grid or arc: it gets no MPE setup until you set that grid or arc port to another port or off. Turning the mode off, or moving the voice to another port, closes the zone on the old port; while a remote grid, a remote arc or `midi grid` holds that port, the zone is closed as it lets the port go, unless an MPE voice has taken the port again by then. When Strata ends (you load another script, or norns stops it), it closes every zone it opened on a synth that is still plugged in, so the synth goes back to what it was before as far as MPE goes. A synth unplugged while its zone was open, and one on a port a remote grid, a remote arc or `midi grid` holds as Strata ends, keeps the zone until something resets it.

A note takes the member channel freed longest ago; when every channel has a note, it shares the one with the fewest, and with it that channel's bend: a new note's first values stand there. A value another note changes after the new note starts goes out at the next step, but one it changed just before waits until a played note on the channel ends. When a played note on it ends, the played notes still on it send their own values again. A note struck again on its channel while it sounds there is sent as a note off and a new note on, as in plain mode. A note you play carries its own bend, pressure and slide (CC 74): the values your controller sent go just before the note on, and later changes follow, whatever the voice's own pressure and slide targets are (those only decide what Strata's sound does with them). Strata sends at most 24 such messages each 1/48 s, the newest values, every note in turn. A step note has no expression: on a channel of its own it gets a centered bend before its note on; on a channel it shares, it takes the bend the channel has. In a tuning (3.8) a note goes out as its nearest MIDI note, and its distance from it (a fraction of a semitone, or more at the ends of the note range) is added to its bend, the played note's own bend included, so the synth plays the tuned pitch; a step note on a shared channel sends no bend, so it loses its cents.

Only one voice can be MPE on a port, and a plain voice on that port needs a channel outside the zone. A change to a voice's route (its port, channel, mode or members) takes effect a moment after you make it (within 1/48 s), and changes made in that same moment are judged together. If the set would break the rule, every route setting changed in that moment goes back to what it was, a moment after the turn, with the message `port has an mpe voice`, and nothing is sent: a refused change takes its neighbors, even legal ones, back with it. A bend range changed in the same moment stands. Turn one route setting at a time and the refusal takes back only that one. Plain and MPE voices can share a port on different channels (an MPE voice with 7 members leaves channels 9 to 16 free). A PSET brings every route back as it was saved. Only a file that breaks the rule (one edited by hand) is changed: its voices are taken in order, and a voice that clashes with a lower-numbered one comes back off, with the same message.

### When the synth comes back

If a port's device is unplugged and plugged in again, or moved to another port in SYSTEM > DEVICES, Strata sends it a note off for each note it was still owed, on the port it is now on, then sets an MPE voice's zone up again. That includes a note that ended while the menu was open: its note off is not sent to the old port, where the device that took it never had the note. A device moved away and back to its own port in one visit gets its note offs as the menu closes. A device that takes the old port gets none of this, and a note sent to it there while the menu is open is its own, with its own note off; so is a note sent to a moved device at its new port while the menu is open, and nothing cuts it early. A note sent to a port while it has no device, or while a remote grid, a remote arc or `midi grid` holds it, reaches no one, and no device gets its note off. A note you still hold on a port that a note was sent to while its device was away (the menu open, the device moved off and back) is cut as the menu closes, when its device is back: the note goes on sounding in Strata, and its own end sends nothing. Two devices of the same name share what they are owed: one plugged in while its namesake is unplugged gets the namesake's note offs. While the menu is open, a played MPE note's bend, pressure and slide stop when its device leaves the port: the device that takes the port gets none of them.

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

## Sources

The MIDI 1.0 specification, the MPE specification (RP-053) and norns' `lua/core/midi.lua`. Unverified on the device until the 4.0 hardware check.
