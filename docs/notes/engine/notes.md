## Must not break

- **Four commands, exactly**, with these signatures: `noteOn(voice, slot, note, freq, rate, velocity)` `"iiffff"`, `noteOff(voice, slot, cut)` `"iii"`, `noteExpression(voice, slot, bend, amp, position, size, main)` `"iifffff"`, `setNotePool(size)` `"i"` (design 3.5 §3.1). Slots are 0-indexed in the engine: 0 is the voice's own note, 1-7 its extra notes; Lua's are 1-8 and it passes `slot - 1`.
- **Each command checks before it acts**: its indices first (voice 0-6, slot 0..`noteSlots` - 1, `noteOff`'s `cut` 0 or 1, `setNotePool`'s size 0..`notePoolMax`), then that every continuous argument is finite, through the modulation area's `fastModIndicesValid` and `fastModValuesFinite`, as 3.4's five commands do. A bad one is ignored with one console line (`strata: noteOn ignored: voice 7 is not a whole number from 0 to 6`, posted by `postFastModIgnored`): nothing recorded, no state changed. Only then are the continuous arguments clipped (note 0-127, freq 8-20000, rate 0.25-4, velocity 0-1, bend 0.0625-16, amp 0-2, position, size and main -1..1), never ignored for being out of range.
- **The literals** `noteSlots { ^8 }` and `notePoolMax { ^16 }` equal Lua's `NOTE_SLOTS` and `NOTE_POOL.max` (a docs test compares them), and the Lua engine stub reads them as written (`name { ^N }`) for its index checks: keep them literal methods. `noteLag { ^0.02 }` is every per-note control's lag.
- **Until the note lifecycle lands the commands are stubs**: they record what they took and create no node (the check counts the server's nodes after each, sent to a running voice). `setNotePool` keeps the size. They are in `test/sync_check.lua`'s `PENDING_COMMANDS` until the note module (`S.lib.notes`), the only one that sends them, calls them.
- The area's state lives in `areaState[\notes]`; `StrataNotes.sc`, like every extension file, adds methods only, never a variable.

## The notes area (`StrataNotes.sc`, order 170)

The last area in `alloc`'s order and the first in `free`'s. It has `allocState` and `addCommands` only: no SynthDef, node, bus or buffer yet, so no `start`, `stop` or `free`.

`areaState[\notes]`:
- `pool`: how many extra notes the pool holds, across every voice; 0 until Lua sends `setNotePool` (Lua sends its tier's default, `NOTE_POOL.standard` 4 or `NOTE_POOL.high` 8, or the player's setting from `notes.data`, at its start).
- `slots`: per voice an Array of `noteSlots` places, nil while the slot is empty. Nothing fills them yet.
- `received`: what each command last took (an IdentityDictionary, the command's name to its arguments, the continuous ones clipped), for the engine check, as the modulation area's `received`.

### The commands

The rows of AGENTS.md's table:

| Command | Indices checked | Clipped | Does |
|---|---|---|---|
| `noteOn(voice, slot, note, freq, rate, velocity)` `"iiffff"` | voice 0-6, slot 0-7 | note 0-127, freq 8-20000, rate 0.25-4, velocity 0-1 | records; will start the slot's note (a synth voice plays `freq`, a buffer voice `rate` as its `bufRate`, an input voice as its `pitchShift`) |
| `noteOff(voice, slot, cut)` `"iii"` | voice 0-6, slot 0-7, cut 0-1 | | records; will release the slot's note (cut 0) or cut it in 50 ms (1) |
| `noteExpression(voice, slot, bend, amp, position, size, main)` `"iifffff"` | voice 0-6, slot 0-7 | bend 0.0625-16, amp 0-2, position, size and main -1..1 | records; will keep the slot's expression and set it on its synth (it creates no node) |
| `setNotePool(size)` `"i"` | size 0-16 (`notePoolMax`) | | keeps the size in `pool` and records it; will trim past a smaller pool |

The Lua engine stub refuses the same indices and, from the clips in the source (`note = msg[3].clip(0, 127)`, ...), the clipped ranges, so Lua sends neither (`docs/notes/test-harness/engine-stub-and-sync.md`).

### Memory

The note pool is sized from what a note costs. A synth voice's extra note is a voice synth, a buffer or input voice's a grain synth; the memory area measures all seven voice SynthDefs and `\strataMod` for the first time (`memory: \strataResonator takes <n> KB`, ...), each at most 96 KB, a bound against a gross error only (3.5's package 1a gives each def its own limit). Karplus is the costliest note (77.5 KB, against `\strataGrainBuf`'s 69.1), and by design 3.5 §1's sum redone from the figures a full pool of 16 leaves about 1443 KB on high and 2225 KB on standard at the tightest case, above the 1280 KB a full pool must leave. The figures and the sum are in `docs/notes/engine/memory.md` (the voice SynthDefs; the floors section).

### The check (`test/engine_check/notes.scd`)

About 1.5 s, in lifecycle's CI shard (`.github/workflows/test.yml`). Its checks:
- the area runs at order 170; its literals (8, 16, 0.02) and its state as `alloc` leaves it: no pool, an empty place for every slot of every voice;
- the four commands exist with their signatures;
- no command creates a node: the server's synth and group counts are the same after each of seven valid calls of the four, sent to a running voice;
- each command records its arguments, the continuous ones clipped (the limits themselves, and values past each limit);
- out-of-range indices (negative, too large, fractional) and non-finite values (NaN, both infinities) of every command are ignored, one line each naming the command, with nothing recorded, the pool unchanged and no node made;
- the check counts those lines through the modulation area's `postIgnored` hook, and gives the hook back however its body ends (`withIgnoredLines`, a `protect`): a deliberate error inside it must leave the hook as it was, so the areas after this one see their lines;
- `setNotePool` keeps the size it is sent, and an ignored one leaves it.

The area sets the pool back to 0 and stops the voice it started.
