# Grid Page 1: Patterns

Two sides: side 1 is seven lines of sixteen steps, one line per voice (line 1 voice 1); side 2, the lane side, is one voice's hits and lanes with a utility line. Press the lit patterns page key again to go from one side to the other (on the 8×8, hold NV and pick rows 3-4 of column 1). On a 16×16 one pane can show side 1 and the other side 2. Back to [Monome Grid](../../grid.md).

## Side 1: every voice

- **Tap a key** to turn its step on or off: the step changes when you let go, not when you press
- **A press picks the voice** for side 2: the picked voice's line shows it, its empty steps lit at 1 up to its length (past it they stay dark, so the length shows). The pick is the grid's (both panes of a 16×16 share it) and is not the screen's selected voice
- **Hold a step and press another key on its line** to set the held step's level: that key's share of 15 along the keys shown (key 16 = 15, key 8 = 8; on an 8×8's half, key 8 = 15, key 4 = 8). Every further key sets it again while the first stays down; none of them toggles its own step
- **Hold a step for 0.3 s** to open the step editor for it on the screen ([SEQ](../../pages/seq.md)), and let go to close it; the step is not toggled. The key lights nothing more while the hold runs: it looks like a press until the editor opens
- **What it shows**: a step at its level (15 for steps set by hand), the step that just played at 15 if set and 4 if empty, the same step SEQ shows; a set step past the voice's length dims to 1, an empty one stays dark (the picked voice's at 1 inside its length). A voice in `move` lights each set step at its value A (4 with none)

## Side 2: the picked voice's lanes

```
line 1  hits     a step a key, at its level
line 2  value A  a cell a key, at its value
line 3  value B
line 4  chance
line 5  repeats
line 6  gate
line 7  PU MV AC LN T1 T2 T3 T4 B  V1 V2 V3 V4 V5 V6 V7
```

- **Line 1, the hits**: the voice's steps, as on side 1: a tap toggles, a 0.3 s hold opens the step editor, and a second key sets the held step's level (in `move`, its value A: the level stays the step's strength)
- **Lines 2-6, the lanes** ([Lanes](../../sequencer.md#lanes)): value A, value B, chance, repeats and gate. **Hold a cell and press another key of its line** to set it from that key's place along the keys shown: value A and B 1-15 as a level; chance that share of 100 % (key 8 of 16 = 53 %); repeats 1 to 4 spread over the keys (key 8 of 16 = 2); gate one of fifteen lengths from 0.05 to 16 steps (key 8 of 16 the eighth). **Tap a cell** to clear it, or, if it is empty, to give it the value last set on that lane from this grid (before any: 15 for value A and B, 53 % for chance, 2 repeats, the voice's own gate length). A value A or B given to a step that is off, by a tap or a second key, turns the step on at 15, since a value on a step that is off is never played (a lane with a length of its own is not tied to the steps, so its cells leave them alone); in move, so does the hits line's second key
- **What the lanes show**: each cell at its value (chance at its share of 15, at least 1, and 15 for a set step with no chance of its own; repeats 4, 8, 11, 15 for 1 to 4; gate at its place of the fifteen lengths). The cell each lane read last while the voice plays lights 15 if it holds something and 4 if not, so a lane with its own length is seen to drift against the hits; a cell past its lane's length lights 1 if it holds something. Where value B names value A's target, B's line does nothing and its set cells light 2
- **The mode** ([Step modes](../../sequencer.md#step-modes): PU pulse, MV move, AC accent): the voice's mode 15, the others 4; a voice saved in `gate` lights PU at 8. Choosing `move` here gives every set step with no value A a random one
- **LN**: tap to arm (it lights 15). Armed, each lane's line lights 8 up to its own length and a lane that follows the hits lights 3 up to the voice's length; the next key you press on lines 1-6 sets that lane's length to that key (the key at its length already makes the lane follow again; on line 1 it sets the voice's length), and LN goes out. Tap LN again to disarm. A page or side change disarms it; on the 8×8 it stays armed across the halves, so every length can be reached
- **The targets** (T1 position, T2 pitch, T3 size, T4 cutoff): value A's target lights 15 (10 while A is `auto`, on the target `auto` names), value B's 8, the others 2. A tap sets A's target; **with B held** a tap sets B's, and B's own lit key turns B off. Choosing cutoff on a voice whose filter is closed (mix 0) opens it and says so in the header
- **B** lights 15 while held, 8 while value B has a target and 2 while it is off
- **V1-V7** pick the voice side 2 shows: the picked one 15, the others 4

On the 8×8, side 2's left half holds the mode keys, LN and the targets and its right half B and the voices, so B and the targets are never shown together: on an 8×8, set value B's target in PARAMETERS (the voice's **seq move B**).

Where it sits: rows 1-7 of the [16×8](../128h.md) and either pane of the [16×16](../256.md) (the bottom pane's lines on rows 9-15), down columns 1-7 of the [8×16](../128v.md) (each line down its column), and a half at a time on the [8×8](../64.md). Each voice plays its own length and division ([Sequencer](../../sequencer.md)).
