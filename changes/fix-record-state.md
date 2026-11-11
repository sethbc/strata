### Fixed
- With record sync on, canceling an armed take with K3 before its beat or bar no longer empties a buffer that was still playing: the buffer keeps its audio, name and path. A cancel in the last moment before the beat, once the take has silenced the buffer, still leaves it empty (#373). This differs from design 3.3 section 1.8, which had a canceled armed replace take always leave the buffer empty.
- A missing or damaged file loaded into a buffer while a synced take waits for its beat no longer renames the buffer `take <n>` with a take that was never written: the buffer goes back to the file it was playing (#311).
- A periodic length report arriving between K3 on an armed synced take and the engine's cancel no longer names the buffer `take <n>` (#311).
- An armed synced take's row keeps showing the buffer's length until the engine silences the buffer, instead of 0 s at once (#311).
- K3 for an overdub or loop recording while a file is still loading into the buffer now records nothing and flashes `buf <n> loading` (K3 again once the length shows), instead of dropping the file and letting the script and the engine run different kinds of recording (#455).
- A loop or overdub recording sent while a load is in flight is judged on the empty buffer, never on the sample rate of the file the load replaces (#374).
- A synced take's delay now runs from the moment the command arrives, not from when the engine gets to it, so a take started while a file loads into another buffer starts on its beat (#376).
- A take whose end report arrives before its own timer settles at once, instead of showing `...` for up to 2.25 s with K3 ignored and saves refused (#457).
