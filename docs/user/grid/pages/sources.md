# Grid Page 4: Sources

What each voice grains, one line per voice: its synth, another voice's sound or its own, the input (stereo, left or right) or one of the eight buffers. Press the page's key (P4) to show it. Back to [Monome Grid](../../grid.md).

```
     1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
1    sy v2 v3 v4 v5 v6 v7 in b1 b2 b3 b4 b5 b6 b7 b8
2    v1 sy v3 v4 v5 v6 v7 in b1 b2 b3 b4 b5 b6 b7 b8
...
7    v1 v2 v3 v4 v5 v6 sy in b1 b2 b3 b4 b5 b6 b7 b8
```

Line 1 is voice 1, line 7 voice 7, and each line has one lit key: the voice's source. A press sets it at once, as the source field on [BUFFER](../../pages/buffer.md) or in PARAMETERS does ([Audio Sources and Buffers](../../sources-and-buffers.md)).

- **The voice's own column** (`sy`: column 1 on line 1, column 2 on line 2, ...) is its synth. Pressed while the synth is lit, the voice grains its own output instead ([Voices as sources](../../sources-and-buffers.md#voices-as-sources)), and the key blinks; pressed again, it goes back to the synth. Pressed while the voice reads anything else, it is the synth
- **Another voice's column** (`v1` to `v7`) makes the voice grain that voice's sound
- **`in`** (column 8) makes the voice grain the input, on the channel it had last (stereo at first). Pressed again while it is lit, it steps the channel: stereo, left, right, stereo
- **`b1` to `b8`** (columns 9-16) make the voice grain that buffer

What it shows:
- the voice's source at 15; its own output blinks between 15 and 6, half a second each
- the input key by its channel: 15 stereo, 11 left, 7 right; 4 while the voice reads something else
- another voice's key at 4 while that voice runs, 2 while it is stopped
- a buffer's key at 4 while the buffer holds audio, loads or records, 2 while it is empty; a buffer cleared while a voice reads it dims to 2 at once on the other lines and stays lit at 15 on that voice's line, which keeps reading it
- the voice's own column at 4 while it reads something other than its synth or its own output

A source set anywhere else (the screen, a scene, a MIDI map, PARAMETERS) shows at once; an input channel set on VOICE or in PARAMETERS within a tenth of a second.

Where it sits: rows 1-7 of the [16×8](../128h.md) and either pane of the [16×16](../256.md) (the bottom pane's lines on rows 9-15), down columns 1-7 of the [8×16](../128v.md) (each voice's keys down its column), and a half at a time on the [8×8](../64.md): the left half holds the voices and the input (columns 1-8), the right half the eight buffers (columns 9-16).
