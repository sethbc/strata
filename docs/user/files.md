# A File's Settings

Since 3.7 Strata remembers a few things about each audio file you load into a buffer: its **tempo**, its **key**, whether it is **normalized**, and how it is sliced. They follow the file, not the slot: load the same file into any slot, in this session or a later one, and its settings come back with it. Nothing is ever written beside your audio files; Strata keeps them in its own data folder (`data/strata/samples.data`).

A file loaded from a start point other than its beginning (BUFFER's `start` field) is other audio, so it has settings of its own: `drone.wav` from 0 s and from 12 s are remembered apart. Settings are found by the file's path, so a file you rename or move loses them (load it again and set them again).

A file with every setting at its default is not remembered at all, and Strata keeps the 256 files loaded most recently; past that, the one loaded longest ago is forgotten.

## The settings

They are set in BUFFER's slice editor (K3 on BUFFER's `slices` field, for the buffer under the cursor: [BUFFER](pages/buffer.md#the-slice-editor)), where the `tempo`, `bars`, `key` and `norm` rows sit beside the slices'.

- **Tempo**, in BPM (20 to 300), or none. It can also be set as **bars**: how many 4-beat bars the slot's audio holds at the tempo, so a loop you know is 2 bars long gets its exact tempo. A take recorded with `record sync` on takes the clock's tempo at its start. The tempo does nothing by itself: the voices' tempo follow reads it.
- **Key**, a MIDI note, or none (while the editor's `key` row is picked, a note played on a MIDI controller sets it). With no key a sample behaves as it always has: MIDI note 60 plays it at its own speed (rate 1), and scale quantize takes it to be at the scale's root. With a key of, say, A2 (57, as norns names notes: 60 is C3), note 57 plays it at rate 1, an octave above plays it at twice the speed, and quantize treats the sample as being in A: MIDI notes, step notes and chords on a voice reading it all count from the key. Input and synth voices are not affected.
- **Normalize**, on or off. On, the slot plays louder by the amount that brings its loudest moment to full level (at most 16 times, +24 dB); a file that already reaches full level is left alone. The level follows the audio: it is worked out again whenever the slot's waveform is read, after a load or a take. While a slot records, it plays at its own level.

The slices (their mode, count, sensitivity and markers) are kept the same way.

## Takes

A take (a recording into a slot) has no file of its own until you save it, so its settings belong to its slot: they stay with the take between sessions (in `buffers.data`) until the slot is cleared, a file is loaded into it, or a new take replaces it.

- **An overdub or a loop recording over a file** turns the slot into a take, which starts with a copy of the file's settings. The file's own settings are untouched: the file on disk did not change.
- **An overdub of a take** keeps the take's settings.
- **Saving the whole buffer** (`save`) hands the take's settings to the saved file, as they were when you saved, so loading that file later brings them back. Saving only the loop region does not.

## Files Strata could not read

If `samples.data` cannot be read (damaged, or from another version of Strata), it is kept as `samples.data.bak` (or `.bak.2`, ... when an earlier backup is there), the console says so once, and every file loads with no settings. Strata 3.6 cannot read the `buffers.data` that 3.7 writes, and sets it aside: going back to 3.6 starts with empty slots.
