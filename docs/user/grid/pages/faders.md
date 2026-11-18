# Grid Page 2: Faders

Four faders of the picked voice or of a macro bank, the voice's fader pages, its type and the voice picker, on every grid size. Back to [Monome Grid](../../grid.md).

```
     1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
1-4  four faders of the picked voice, or a macro bank's four
5    p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 .. B1 B2 B3 B4 ..
6    the picked voice's type, one key a type, in type order
7    V1 V2 V3 V4 V5 V6 V7 .. .. .. .. .. .. .. .. ..
```

- **Lines 1-4** are four faders: the key pressed sets the param along the line, the bar lights to it at 8 and the value at 15. A range through 0 (pan, the crossmod amounts) has a key that sets exactly 0. They are grid touches, so a gesture recorder records them. Set elsewhere (the screen, the arc, a MIDI map, PARAMETERS, the drift, a mutation), they show within a tick. A line with no fader (the last page of a voice whose faders do not fill it) is dark and does nothing
- **p1-p10** (line 5, keys 1-10) show the picked voice's fader pages, four faders a page: its synth params (a buffer voice's buffer params, level and pan), the grain params (an input voice's level and pan after them), the crossmod slots, then the voice filter and sends, a buffer voice's loop, the jitters, attack and release. The page shown lights 15, the voice's other pages 4, and keys past its last page are dark and do nothing. A voice has at most ten pages
- **B1-B4** (line 5, keys 12-15) show a macro bank's four macros on lines 1-4, as MOD's banks do: the bank shown 15 while its macros are on the faders, otherwise 6 a bank with targets and 2 an empty one. The bank is the one every surface shows, so a bank key also changes MOD's and the arc's. A page key or a voice key goes back to the voice's faders
- **Line 6** sets the picked voice's type at once, one key a type in the order VOICE lists them (resonator, fm, folder, sub, pulse, karplus, ring, and the types added after them): the voice's type 15, the others 4, keys past the last type dark. A choice still pending on VOICE's type row is dropped, so the grid's key is the one that stands. A type with fewer fader pages shows its last page if the page shown was past it; so does a source with fewer
- **V1-V7** (line 7, keys 1-7) pick the voice the faders and the type keys are for: 15 picked, 4 the others. This is the grid's own pick, not the screen's
- Keys 11 and 16 of line 5, the rest of line 6 and keys 8-16 of line 7 are dark and do nothing

Each grid keeps its own choice of the voice's faders or the macros; the picked voice and its page are shared by every grid.

Where it sits: rows 1-7 of the [16×8](../128h.md) and either pane of the [16×16](../256.md) (the bottom pane's lines on rows 9-15), down columns 1-7 of the [8×16](../128v.md) (the faders run up columns 1-4, row 16 the minimum; the page and bank keys down column 5, the types down column 6, the voices down column 7), and a half at a time on the [8×8](../64.md): p1-p8, types 1-8 and the voices on the left half, p9-p10, the banks and types 9-12 on the right. On the 8×8 the faders run across the half's eight keys, the whole range in eight.
