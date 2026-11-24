# Grid Page 1: Patterns

Seven lines of sixteen steps, one line per voice (line 1 voice 1), on every grid size. Back to [Monome Grid](../../grid.md).

- **Tap a key** to turn its step on or off: the step changes when you let go, not when you press
- **Hold a step and press another key on its line** to set the held step's level: that key's share of 15 along the keys shown (key 16 = 15, key 8 = 8; on an 8×8's half, key 8 = 15, key 4 = 8). Every further key sets it again while the first stays down; none of them toggles its own step
- **Hold a step for 0.3 s** to open the step editor for it on the screen ([SEQ](../../pages/seq.md)), and let go to close it; the step is not toggled. The key lights nothing more while the hold runs: it looks like a press until the editor opens
- **What it shows**: a step at its level (15 for steps set by hand), the step that just played at 15 if set and 4 if empty, the same step SEQ shows; a set step past the voice's length dims to 1, an empty one stays dark

Where it sits: rows 1-7 of the [16×8](../128h.md) and either pane of the [16×16](../256.md) (the bottom pane's lines on rows 9-15), down columns 1-7 of the [8×16](../128v.md) (each voice's steps down its column), and a half at a time on the [8×8](../64.md). Each voice plays its own length and division ([Sequencer](../../sequencer.md)).
