## Must not break

- The performance area (`lib/engine/StrataPerformance.sc`, order 10) runs first: it sets `tier`, `bufferSeconds`, `maxGrains` and `historySeconds` before any other area allocates a buffer or builds a SynthDef with them. It also sets `instanceTag` and `writeGenerations` (the file-write state), which its own write uses.
- The engine runs what Lua will read. Normally that is the `performance_active.data` it just wrote. A failed write (an unwritable settings folder) leaves no file, since the old one is deleted first, so both run standard. An old file the engine cannot remove (a read-only folder or file, #153) is what Lua reads at init, so `unwrittenPerformance` reads it with Lua's rules (`parseActivePerformance`, which must stay identical to `S.lib.performance.parse_active_text`) and runs standard for an invalid or standard file, and the high tier at its length for `high, N s` (with the usual memory step-down). When the step-down leaves less than N s, Lua learns the real length from the `bufferState` poll's slot-length message (`bufferLengthValue`, slot index `numBuffers`) and caps `S.performance.buffer_seconds` and the record duration to it (`engine_slot_seconds`, one console line). It posts that the file could not be replaced and must be removed by hand to apply the setting. The two never disagree on the tier.
- `performance_active.data` follows the file-write invariant: written to `<path>.<instanceTag>-<generation>.part`, renamed with `mv -f`, synchronously, so it exists before `alloc` returns. The final path is never opened for writing, and no `.part` is left behind. `stalePartDirs` holds the settings folder, so `deleteStaleParts` removes a crash's stale `.part` there at the next alloc.
- A missing or garbled `performance.data` means auto and 60 s. Each key is read on its own: a value outside its choices (`performance turbo`, `buffer_seconds 999`, a truncated line) falls back to that key's default with one line in the post window; other keys are ignored. Lua's `S.lib.performance.setting()` reads it the same way.
- `/proc` files read as empty with `File.readAllString`: `readMemAvailableKB` reads lines with `getLine`, and `readBoardModel` reads bytes with `getChar` (the device-tree model ends in a NUL, which is stripped).
- The high tier keeps `maxGrains` 128 (Lua's `grain_density` maximum stays 100). The step-down arithmetic counts the slots, every voice's ring and the high input ring; it must stay the same as the rings area allocates (`ringSeconds`, `ringGuardSeconds`).
- `standardBufferSeconds` (16) equals Lua's `STANDARD_BUFFER_SECONDS` (the docs test compares them). `bufferSeconds` is a tier value; Lua reads it from the active file as `S.performance.buffer_seconds`.
- Each slot holds `bufferSeconds` at the server rate (the engine check asserts it on a standard and a high engine).

## Owns

- `lib/engine/StrataPerformance.sc`: the area, `standardBufferSeconds`, `highBufferChoices`, `standardHistorySeconds`, `highHistorySeconds`, `tierMaxGrains`, `minFreeMemKB`, `defaultPerformanceSetting`, `settingsDirectory`, `allocSettingsDirectory`, `readPerformanceSetting`, `readBoardModel`, `readMemAvailableKB`, `highMemoryBytes`, `performanceDecision`, `writeActivePerformance`, `unwrittenPerformance`, `parseActivePerformance`, and `areaState[\performance]` (`settingsDir`, `decision`).
- The check area `test/engine_check/performance.scd`.

## The decision

At `alloc` (`allocPerformance`):
1. **The setting.** `performance.data` in the settings folder: `settingsDir`, a classvar that is nil on norns and then `~/dust/data/strata/` (Lua's `_path.data .. "strata/"`, the folder `scenes.data` is in). Lines `performance auto|standard|high` and `buffer_seconds 16|60|120|300`; missing means auto and 60 s.
2. **The tier.** `standard` gives standard. `high` gives high on any board (SETUP warns `may xrun` on a CM3 or Pi 3). `auto` gives high when the board model contains `Raspberry Pi 4` or `Compute Module 4` (which covers the CM4S, and the Pi 400), the strings matron matches; any other model, an empty one, a desktop or CI gives standard. The model is `modelPath` or `/sys/firmware/devicetree/base/model`.
3. **The buffer length.** Standard is always 16 s. High is the setting's length, stepped down through `highBufferChoices` (300, 120, 60, 16) until the high tier's memory leaves at least `minFreeMemKB` (1048576 kB, 1 GB) of `MemAvailable` (`meminfoPath` or `/proc/meminfo`). The memory for a length `L` (`highMemoryBytes`) is `8 × 2 × L × sampleRate × 4` bytes of slots, plus `numVoices × 2 × ringSeconds × sampleRate × 4` of voice rings, plus `2 × (highHistorySeconds + ringGuardSeconds + 1) × sampleRate × 4` of input ring. At 48 kHz that is 3000 kB per second of slot length plus 34875 kB, so a 300 s setting gets 300 s from a `MemAvailable` of 1983451 kB, 120 s from 1443451 kB, 60 s from 1263451 kB and 16 s below that (16 s is the floor); an unreadable meminfo gives 16 s. A step-down is added to the reason (`; buffer 300 s -> 120 s (memory)`).
4. **The values.** `maxGrains` is 128 on both tiers; `historySeconds` is 16 on standard and `highHistorySeconds` (60) on high, so the input ring holds 65 s on high (21 s on standard).
5. **The active file.** `performance_active.data`, beside the setting:

   ```
   tier high
   buffer_seconds 60
   max_grains 128
   history_seconds 60
   reason auto: Raspberry Pi 4 Model B Rev 1.4
   ```

   Reasons: `standard: setting`, `high: setting`, `auto: <model>` (`auto: unknown board` for an empty model), with the step-down appended, or `standard: performance_active.data could not be written`. When an old file could not be replaced, `: setting` reads `: the old performance_active.data (it could not be replaced)` (`, unreadable` before the parenthesis for an invalid one).
6. The area posts what it runs: `strata: performance high, 60 s buffers (auto: Raspberry Pi 4 Model B Rev 1.4)`.

`performanceDecision(setting, model, memAvailableKB, sampleRate)` is a pure function of its arguments (the check calls it with fake models and memory); `readPerformanceSetting`, `readBoardModel` and `readMemAvailableKB` read the classvars' paths when called, so the check sets them around a call or for one build (`h.startEngine((settingsDir: ..., modelPath: ..., meminfoPath: ...))`). The runner gives every engine it builds a fresh `settingsDir` below its temp dir and a `modelPath` that does not exist, so a check engine never reads or writes `~/dust` and runs standard unless the area asks for more.

## The check area

`test/engine_check/performance.scd`: the main engine runs standard with 16 s slots; the tier per setting and board (standard on any board, high on a CM3, auto on a Pi 4, CM4 and CM4S, and standard for a CM3, Pi 3, unknown and empty model); the 300 → 120 → 60 → 16 step-down at `MemAvailable` 2100000, 1800000, 1350000, 1150000 kB and with no meminfo; the memory formula; garbled, truncated, newer-release, binary and empty settings files (auto, 60 s); the model and meminfo readers; a high engine's active file, values and 60 s slots; the `.part` write (none left; the method never opens the final path); a garbled setting on a Pi 4 (auto, high, 60 s); an unwritable settings folder and an active file that is a folder (standard); `parseActivePerformance` on valid, CRLF, padded and repeated-key texts and on the texts Lua refuses (the same texts as `test/unit/performance_test.lua`); an old active file in a read-only settings folder (`chmod 555`, skipped as root): high 60 s runs high 60 s whatever the setting, high 300 s at `MemAvailable` 1350000 kB runs high 60 s, standard and garbled ones run standard; a stale `.part` deleted at alloc and a fresh one kept; and the `bufferState` stride (`slot * 1000 + seconds`, exact to 0.01 s in a 32-bit float up to 7 × 1000 + 300). The real-time memory budget the tiers must fit is in [memory.md](memory.md).
