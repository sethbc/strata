## Must not break

- **`pick` is pure**: it reads and keeps no state, sends nothing, never yields and calls nothing but its `random` argument, so the scene sequencer and the pattern chain can both call it from any clock.
- **One draw picks the move**: `r = random() * 100` against the three chances in their order (next, previous, random); a random move draws once more for its slot. **With one chance at 100 (100, 0, 0 above all) it makes no draw**: 3.6's play in order needs no random number, and a test passes a `random` that raises.
- **A repeat is the move, never two equal slots** (plan ruling 36): `pick` returns the move's name with the slot, and only `"repeat"` means the caller recalls or links nothing. One populated slot at 100, 0, 0 is `"next"` to that same slot, which is recalled again, as 3.6 does.
- The caller hands it only the slots that can play (it leaves out empty and invalid ones); `pick` never looks inside a slot.

## Owns

`lib/chance.lua` (`S.lib.chance`, 3.7, package 0b, design §0.5 and §5.4):
- `pick(current, slots, chances, random)`: the next slot and the move's name (`"next"`, `"previous"`, `"random"` or `"repeat"`).
- `CHANCE`: its tunables (`percent`, 100, what the chances sum to at most; `moves`, the four names in the draw's order).
- Its unit tests: `test/unit/chance_test.lua`.

## The rules

- `slots` is an ordered list of slot numbers (any numbers, in the order the caller plays them); an empty list (or one that is not a table) returns nil.
- `chances` is `{next, previous, random}` in percent. A chance below 0, or one that is not a number (NaN included), counts as 0. A sum above 100 scales all three down to sum 100 (`{100, 100, 0}` is `{50, 50, 0}`).
- `random` is a function returning 0 to 1 (`math.random` by default).
- The move: next when `r` is below `next`, previous below `next + previous`, random below the three's sum, else a repeat. With one chance at 100 that move is taken with no draw; with all three at 0 it is a repeat with no draw.
- Next past the last slot is the first; previous before the first is the last. A `current` not in `slots` counts as before the first: next is the first slot, previous the last.
- Random draws once more among the slots other than `current` (`floor(random() * n) + 1`, kept inside the list for a draw of 1); with no other slot (one slot, which is `current`) it is a repeat.
- A repeat returns `current` itself.
