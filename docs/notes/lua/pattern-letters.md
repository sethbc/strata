## Must not break

- **The playing pattern stays where it is** (design section 3): `S.patterns[v]`, `S.pattern_steps[v]` and the voice's lane lengths (`S.lib.lanes`) are the letter playing, so every reader of them is untouched. This module keeps only the patterns not playing (`slots`), never a second copy of the one that plays: a letter is used exactly when it is the playing one or has a slot (`used`), and nothing else records it.
- **A pattern is the whole of it**: `S.lib.sequencer.whole(voice)` is a deep copy of the levels (sixteen), the steps' settings (sparse, chords copied) and the lane lengths (`S.lib.lanes.lengths`); nothing a caller does to it reaches the pattern, and nothing a later edit does reaches it.
- **Every whole-pattern load goes through `S.lib.sequencer.replace_whole(voice, pattern)`**: the levels through `replace_pattern` (so its endings run once: the held values and locks, the held step gestures, the step editor but for its own replacement, the Euclidean row, the undo), then a copy of the steps' settings, then the lane lengths through `set_lengths` (a lane the pattern does not name follows), then `send_gate_rule(voice)`. The rule is sent twice at a switch (`replace_pattern` sends it when its answer moves); a test asserts the last `seqGate`, never a count (ruling 4a-4). It redraws nothing: callers do.
- **A switch** (`switch_now(voice, letter)`) stores `whole(voice)` under the playing letter first, then loads the other through `replace_whole`. A letter never used is first given a copy of the playing pattern, so the voice plays on unchanged; a used letter is loaded as it is, empty or not: a cleared letter stays empty. The playing letter, a voice or letter out of range does nothing.
- **The block `variations`** (design section 6): per voice `{current = letter, order = {letters}, order_on = boolean, slots = {<letter> = pattern}}`, `slots` holding only the used letters not playing; its default, letter A with no order and no slot, so a scene saved before it plays its own pattern on A alone. Its check refuses a voice out of range or missing, a key it does not know (in a voice or a pattern), a `current` or slot letter that is none of `LETTERS`, the playing letter in `slots`, an order of more than eight letters, with a hole or a letter that is none, an `order_on` that is no boolean, and a slot whose levels fail the patterns' check (sixteen whole levels 0 to 15), whose steps fail the `steps` block's (`S.lib.sequencer.valid_steps`, for its own voice) or whose lanes fail the `lanes` block's (`S.lib.lanes.valid_block`). Every slot holds all three of `levels`, `steps` and `lanes`.
- **A recall and a chain link apply the block with the patterns**, as a copy (`apply_block`: the scene keeps its own): a recall through the block's `apply` (blocks first, then the patterns, `lib/scenes.lua`), a link in `load_chain_scene` after the `steps` block. The block sets the store only; the playing pattern comes from the scene's `patterns`, `steps` and `lanes`. A block's apply redraws nothing (a recall's redraw is its caller's: an extra repaint fails "a sequenced instant recall lights at once (#49)").
- **The chain start's undo holds the letters** (rulings 2c-3, 4a-1): `S.lib.mutation.hold_patterns` captures `capture()` beside the levels, steps and lanes, holds when any changed, and its undo puts each voice's pattern back through `replace_whole` and then the letters through `apply_block`.
- **The live letters are in no PSET and no data file**: only scenes keep them, as for the patterns.
- **A switch by hand waits for the bar** (4b, design section 3, When): `switch(voice, letter)` switches now (`switch_now`) while the patterns are stopped; while they play the letter waits for the next bar of the sequencer's own count (`S.lib.sequencer.on_bar`, the chain's count), the waiting letter tapped again switches now, another letter replaces the one waiting, and the playing letter cancels the wait. Every `switch` turns the voice's order off. `switch_now` itself leaves nothing waiting for its voice. A tap repaints the grid once.
- **The bar** (`on_bar`'s hook, `at_bar`): each voice takes its waiting letter, or, with its order on, the order's next entry, wrapping; an entry equal to the playing letter switches nothing (`switch_now` returns at once, so the step editor stays open and nothing ends). The hook runs after a chain link due on that bar and before the bar's first step, so the letter plays from that step, and repaints no grid (the bar's step repaints it once: one repaint a beat); at the patterns' start (its first call, `first`) every order's place goes back to its first entry, which the start's own bar plays. After a late wake that skipped bars (the hook's `bars`, review round 1) the order moves on by the bars that passed, wrapping, and switches once, to the entry it lands on, never loading those between; a waiting letter switches once.
- **The order** (design section 3, The order): `set_order(voice, letters)` takes a copy of what the block's check takes (`valid_order`: up to eight letters, each one of `LETTERS`, keyed 1 to n with no hole; anything else, or a voice out of range, is refused and changes nothing), and turns it on; an empty list leaves no order, off. An order with no letter is never on: `set_order_on(voice, true)` turns one on only when it has a letter, and `apply_block` reads a block's empty order as off; turning it on clears a waiting letter and puts its place back to its first entry, taken at the next bar the hook sees. So a bar never has two claims: a letter waits only while no order is on.
- **What is never stored** (`live`): the waiting letter and the order's place. A stop of the patterns clears every wait (`end_waits`, called by `pattern_clock_stop`). A recall or a chain link wins over a wait on the same bar and clears it, whichever runs first (ruling 4b-3): `apply_block` clears every voice's wait and place, a link's running before the hook (`at_beat`), a recall's from the quantizer's own clock, before or after it.

## Machines

### pattern letters
- **State:** whether the patterns play (`S.pattern_playing`), voice 1's waiting letter (`waiting(1)`) and whether its order is on (`order(1)`'s second value), named `stopped`, `stopped/order`, `playing`, `playing/waiting` or `playing/order`.
- **Invariant:** `pattern letters`: a letter waits only while the patterns play and no order is on, and never the one playing; every voice's `current` is one of `LETTERS`.
- **Test:** `test/unit/pattern_letters_test.lua`: "pattern letters: playing/waiting + a bar" (one test a row), "the pattern letters invariant fails on a letter waiting while the patterns are stopped", and the named tests beside them.

Each state is a fresh script: voice 1's A, B and C used, each with step 1 alone at its own level (15, 7 and 3), A playing; scene 1 captured then (its order none, off); the order B C set and turned off; A's step 16 set (the scene's A lacks it); then the patterns started (playing: started, then half a second), the order turned on, and C tapped (waiting). The events: `tap playing` (`switch` to the playing letter), `tap another` (`switch(1, "B")`), `tap waiting` (`switch(1, "C")`, the waiting letter), `a bar` (the clock run to just past the next bar), `stop` and `start` (the patterns), `set_order` (`{"C", "B"}`), `order on` and `order off` (`set_order_on`), `chain link` (the chain switched on over scene 1 alone, one bar, and the clock run past the next bar) and `recall` (scene 1, at once). Each row checks the letter playing, its level on step 1, the letter waiting and, where the Effect says, the order. The impossible pairs: `tap waiting` wherever no letter waits (stopped: a tap switches at once and a stop clears a wait; `playing`; `playing/order`: an order on and a wait never meet). `chain link` while stopped switches the chain on and links nothing (a start's own link is `start`).

| State | Event | Next | Effect |
|---|---|---|---|
| `stopped` | `tap playing` | `stopped` | nothing |
| `stopped` | `tap another` | `stopped` | B at once |
| `stopped` | `a bar` | `stopped` | nothing: no bar while stopped |
| `stopped` | `stop` | `stopped` | nothing |
| `stopped` | `start` | `playing` | A plays: the order is off |
| `stopped` | `set_order` | `stopped/order` | the order C B, on |
| `stopped` | `order on` | `stopped/order` | the order B C, on |
| `stopped` | `order off` | `stopped` | nothing |
| `stopped` | `recall` | `stopped` | the scene's A, its order none |
| `stopped` | `chain link` | `stopped` | nothing: the chain links only while the patterns play |
| `stopped/order` | `tap playing` | `stopped` | the order off |
| `stopped/order` | `tap another` | `stopped` | B at once, the order off |
| `stopped/order` | `a bar` | `stopped/order` | nothing: no bar while stopped |
| `stopped/order` | `stop` | `stopped/order` | nothing |
| `stopped/order` | `start` | `playing/order` | B, the order's first entry, at the start's own bar |
| `stopped/order` | `set_order` | `stopped/order` | the order C B |
| `stopped/order` | `order on` | `stopped/order` | nothing |
| `stopped/order` | `order off` | `stopped` | the order off |
| `stopped/order` | `recall` | `stopped` | the scene's A, its order none |
| `stopped/order` | `chain link` | `stopped/order` | nothing: the chain links only while the patterns play |
| `playing` | `tap playing` | `playing` | nothing |
| `playing` | `tap another` | `playing/waiting` | B waits, A plays on |
| `playing` | `a bar` | `playing` | nothing |
| `playing` | `stop` | `stopped` | nothing |
| `playing` | `start` | `playing` | A plays |
| `playing` | `set_order` | `playing/order` | the order C B, on; A until the bar |
| `playing` | `order on` | `playing/order` | A until the bar |
| `playing` | `order off` | `playing` | nothing |
| `playing` | `chain link` | `playing` | the scene's A, its order none |
| `playing` | `recall` | `playing` | the scene's A, its order none |
| `playing/waiting` | `tap playing` | `playing` | the wait canceled |
| `playing/waiting` | `tap another` | `playing/waiting` | B waits in C's place |
| `playing/waiting` | `tap waiting` | `playing` | C at once |
| `playing/waiting` | `a bar` | `playing` | C from the bar's first step |
| `playing/waiting` | `stop` | `stopped` | the wait cleared, A |
| `playing/waiting` | `start` | `playing` | C at the start's own bar |
| `playing/waiting` | `set_order` | `playing/order` | the wait cleared, the order C B |
| `playing/waiting` | `order on` | `playing/order` | the wait cleared, the order B C |
| `playing/waiting` | `order off` | `playing/waiting` | nothing |
| `playing/waiting` | `chain link` | `playing` | the link wins: the scene's A, the wait cleared |
| `playing/waiting` | `recall` | `playing` | the recall wins: the scene's A, the wait cleared |
| `playing/order` | `tap playing` | `playing` | the order off |
| `playing/order` | `tap another` | `playing/waiting` | the order off, B waits |
| `playing/order` | `a bar` | `playing/order` | B, the order's first entry |
| `playing/order` | `stop` | `stopped/order` | nothing |
| `playing/order` | `start` | `playing/order` | B, the order's first entry, at the start's own bar |
| `playing/order` | `set_order` | `playing/order` | the order C B |
| `playing/order` | `order on` | `playing/order` | nothing |
| `playing/order` | `order off` | `playing` | the order off |
| `playing/order` | `chain link` | `playing` | the scene's A, its order none |
| `playing/order` | `recall` | `playing` | the scene's A, its order none |

## Owns

- `S.lib.pattern_letters`: `LETTERS` (`{"A", "B", "C", "D"}`), `VARIATIONS` (its tunables: `first`, `max_order` 8, `pattern_keys`), `current(voice)` (`"A"` by default, nil for no voice), `used(voice, letter)`, `switch_now(voice, letter)`, `capture()` (every voice's letters as a block, a copy), `apply_block(block)` (a copy; a voice the block lacks is on A alone; it clears every wait and place). 4b's: `switch(voice, letter)`, `waiting(voice)` (the letter waiting, or nil), `order(voice)` (a copy of the letters, and whether it is on), `set_order(voice, letters)`, `set_order_on(voice, on)`, `end_waits()` (the sequencer's stop calls it).
- What is never stored: `live.waiting` and `live.place`, per voice.
- The invariant `pattern letters`, and the bar hook it registers with `S.lib.sequencer.on_bar`.
- The scene block `variations` (`S.register_scene_block`, discrete: it switches at a transition's end).
- Its include is the last, after `lib/sequencer.lua` (`strata.lua`); it calls the sequencer and the lanes only at a switch, a check or a capture, and `S.lib.sequencer.on_bar` once at its include (its hook). The sequencer calls it back at a bar (the hook), a stop (`end_waits`) and a link (`apply_block`).

## The largest scenes file

Every letter of every voice full (a full pattern stored under three letters a voice) adds 778 tables a scene: the block, three a voice (itself, its order, its slots) and, for each of the three stored letters, 36 (itself, its levels, its steps, its lanes and sixteen steps of settings with a chord each). Sixteen such scenes take the largest file from 7026 tables to 19474 (`DATA_FILES.largest_scenes_tables`) and from 1.25 MB to 3,278,194 bytes on Lua (3,271,986 on LuaJIT), so 3.9 tripled both caps of `lib/data_files.lua` (`max_tables` 98304, over four times it; `max_bytes` 12 MB): `docs/notes/lua/data-files.md`. How long that file takes to read on a norns is one of #6's checks. An order adds up to eight short strings a voice and no table.

## Tests

`test/unit/pattern_letters_test.lua`: the letters and their defaults; `whole` a deep copy; `replace_whole` loading all three and asking the gate rule; "the first switch to a letter copies the playing pattern"; "a switch stores what was playing"; "a cleared letter stays empty"; "a switch ends the held values and closes the step editor"; "a switch asks the gate rule" (a pulse voice switched to an empty used letter while playing: the last `seqGate` is 0); "a scene keeps the used letters and the playing one"; "an old scene fills with letter A alone"; "the block refuses a slot with a level of 16 or an unknown step key" (and every other refusal above); 4b's: "a tap waits for the bar; the letter plays from the bar's first step", "a bar's switch repaints the grid once, with the bar's step", "a tap with the patterns stopped repaints the grid once", "a late wake past three bars moves an order on three entries and switches once", "an order the block gives with no letter is off", "set_order refuses an order with a hole", "a second tap on the waiting letter switches at once", "with the patterns stopped a tap switches at once", "an order A A B A plays four bars from the patterns' start and starts again", "an order of one letter never replaces the pattern", "turning an order on clears a waiting letter", "a switch by hand turns the order off", "a chain link wins over a waiting letter on the same bar", "a recall clears a wait, before or after the bar's hook", "a stop clears a wait" and the table `pattern letters`. `test/unit/sequencer_test.lua`: "a chain link loads the scene's letters"; 4b's "on_bar runs at each bar, the first beat included, after the bar's chain link and before its first step", "a bar hook that errors at a start leaves the patterns stopped", "a chain link that errors at a start leaves the patterns stopped" and the probe "a late wake past three chain periods links three times in a burst (probe, a known fault)". `test/unit/grid_pages_voices_test.lua`: "PC copies settings and lane lengths with the levels". `test/unit/mutation_test.lua`: "a chain start's undo puts the letters back (4a)" and "a chain start that changes only the letters holds its undo (4a)". `test/unit/matrix_test.lua`: "the largest scenes file stays a quarter of the table cap and under the size cap"; `test/unit/random_sequences_test.lua` counts its share.
