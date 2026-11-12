### Changed
- A PSET saved with 3.3 loads every setting 3.4 added at its default (the mutes and solos, scatter, the sequencer's gates, swing and chain, morph, the macros, the matrix depths, the recorders' quantize), so it plays as it did instead of keeping the session's values.
- A MIDI CC mapped in 3.3 to an LFO's depth, offset, phase or clocked rate follows the new LFO param of the same meaning; a mapping on any other 3.3 LFO param is removed at start, where every CC it received raised an error in norns' MIDI handler. Every other mapping is left as it is.
- A mute, or another voice's solo, silences a voice stopped while its release still sounds, within the mute's 20 ms.
