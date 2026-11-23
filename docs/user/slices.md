# Slices

Since 3.7 a buffer slot's audio can be cut into slices, and a buffer voice can play them as notes: from a MIDI keyboard or pads, from a grid's row, or from the sequencer's steps. A sliced drum loop plays back hit by hit, in any order.

## What a slice is

A slot's slices are up to 64 markers in its audio, the first always at its start. Slice 1 runs from the first marker to the second, and the last runs to the end of the slot's audio. A slice shorter than 10 ms is never made: two markers are always at least 10 ms apart.

The slices belong to the file, as its tempo and key do ([Files](files.md)): load the same file again, into any slot, and its slices come back.

## Making them

A file's slices are made and edited in BUFFER's slice editor: K3 on BUFFER's `slices` field opens it for the buffer under the cursor ([BUFFER](pages/buffer.md#the-slice-editor); its arc rings: [Arc](arc.md)). Its `mode` picks one of three ways, and BUFFER's field shows the result (`eq 12`, `tr 12` or `off`):

- **equal**: 2 to 64 parts of the same length.
- **transients**: Strata listens through the slot's audio once and finds where its hits are (the strongest 63, at least 30 ms apart). The sensitivity picks how many of them become markers: at 100% every hit found, at 0% only the strongest. Turning the sensitivity after that listens to nothing again; it only picks again from the hits already found. Strata listens again when you record over the slot or overdub it; loading a file never does. The hits found are kept only while the slot holds that audio: a file loaded again brings back its slices, and the first turn of its sensitivity (or a change to transients) listens to it once more. While Strata listens, the editor's slice line shows `analyzing`; turning the sensitivity or the mode meanwhile starts no second listen, and the markers come at the settings you have when it ends.
- **by hand**: add, delete and nudge the markers. A slice made by hand stays until you change the mode or turn the count or the sensitivity, which makes the slices again (the hint row says `edits dropped`); a new listen after a take leaves hand-edited slices alone.

If the slot later holds less audio than a file's markers reach (a shorter slot on another performance setting, a file trimmed by its start point), the slices past its end are simply not there.

## Playing them

Each buffer voice has a `slices` setting on VOICE (in its synth section, while it reads a buffer) and in the PARAMETERS menu ([Parameters](params.md)):

- **off** (the default): MIDI notes play the voice at their pitch, as before 3.7.
- **one**: each slice note takes the voice's own note, so a new slice replaces the last. It never starts another synth.
- **overlap**: each slice note plays in a note of its own, as a chord's notes do, up to the voice's note cap and the note pool all voices share ([Notes](voices-and-grains.md)).

A slice always plays at the voice's own pitch (`buffer rate`); its number picked the slice, not a pitch.

**From MIDI**: on a voice whose `slices` is one or overlap and whose slot has slices, note 36 (C1 on most pads) plays slice 1, note 37 slice 2, and so on. A note outside the slices does nothing on that voice. Velocity, pressure and slide work as for any note ([Expression](modulation.md#expression)); a position they move stays inside the slice. The `midi note off` setting applies as for any note, but for a one-shot slice: it plays to its end, so on an overlap voice taps one after another ring over each other.

**From a grid**: on every grid's positions page, the line of a voice that takes slice notes shows 16 of its slices, with the voice's bookmark keys on the page's second side picking which 16 ([Slice rows](grid/pages/positions.md#slice-rows)).

**From the sequencer**: a step's `slice` (on SEQ, after `cond`, while the voice reads a buffer: off, or 1 to 64) plays that slice at the step's first hit. On a voice set to overlap a step's slice takes the voice's own note first, as on one; while an earlier step's slice still rings there (in one shot with the scan moving, a slice rings on to its end, past the next step), the step's slice plays in a note of its own instead, and the ringing slice is not restarted. A slice that does not ring to its end is released at the voice's next step that plays. A chord's step plays inside its slice, as on one. When there is no room under the cap and the pool, the oldest step slice of that voice is cut to make room (a MIDI note is never cut for it). On a voice set to one, or off, the step's slice is the voice's own note for that step, and a chord on the step plays every note inside the same slice. A step naming a slice the slot does not have plays as a plain step.

## When a slice ends

What happens at a slice's end follows the voice's scan:

- In **one shot** with the scan moving, a slice plays once to its end whatever its key does: letting go of a key (or a pad) ends nothing early, and a note of its own ends by itself when its slice is through.
- In **wrap** and **bounce**, and in one shot with the scan at 0, a slice sounds while its key is held, as any note does; a step's slice sounds until the voice's next step that plays.
- With `midi note off` on release, a voice's last key normally stops it; while a slice of it plays to its end, the voice runs on and stops once that slice is through.

A step's gate can still cut a slice short. Loading, clearing or recording over the slot, switching the voice's source and stopping the voice all end the slices that voice plays.
