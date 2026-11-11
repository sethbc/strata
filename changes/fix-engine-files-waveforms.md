### Fixed
- A recording whose scratch take cannot be written (a full card, a folder that cannot be made) now says so on the BUFFER page (`buf <n> take not saved`) and is not restored at the next start under its name; the engine reports it on a new poll, `takeWriteFailed` (#312).
- A recording that makes a buffer longer shows the old audio's waveform only where that audio is in the new length, from the moment it starts, and the new length is reported only once its waveform file is written; one canceled before it starts gives the old waveform back (#313).
- One error in the waveform reading loop no longer stops waveforms from updating for the rest of the session (#330).
- A buffer's waveform is forgotten as soon as its length changes, so a new file never shows the previous file's waveform for a frame (#401).
- A file of under 5 ms (a single-cycle waveform) loads as audio instead of showing as not loaded with nothing to save (#456).
- Two saves of a buffer within the same second (or after the clock was set back) no longer write one file over the other: the second gets a counter, `<date-time>-buf<n>-2.wav` (#522).
- A long file's check on the high tier stops as soon as a clear, a recording or a later load supersedes it, instead of decoding the rest of the file (#375).

### Changed
- While a buffer records without emptying, its waveform file is rewritten only when the waveform has changed, and at most every 2 s, so a loop recording never writes the card twice a second (a loop left recording silence, or one whose waveform has stopped changing, writes nothing until it ends). The cost: during an overdub or loop recording the waveform updates every 2 s instead of every 0.5 s; it is complete again when the recording ends (#523).
- The user docs name the waveform files `buf1.peaks` to `buf8.peaks` in `~/dust/data/strata/` (#351); the developer notes for buffers and the waveform follow 3.3's recording (#377), and the peaks mover's poll steps are named constants (#381).
