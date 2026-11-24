# Grid Page 3: Scenes

The sixteen scenes, the morph, the scene sequencer and the gesture recorders, on every grid size. Back to [Monome Grid](../../grid.md).

```
     1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
1    recall at once: scenes 1-16          (SV held: save)
2    recall with the transition time      (SV held: save)
3    the scene of the morph corner picked on line 7
4    morph X (a fader)
5    morph Y (a fader)
6    the scene sequence's length, 1-16
7    SQ SV .. cA cB cC cD .. G1 G2 G3 G4 .. .. .. ..
```

- **Line 1** recalls scene x at once, **line 2** with the transition time (`transition time` on SCENES and in PARAMETERS). With quantize actions on beat or bar (PARAMETERS > sequencer), the recall waits for the next beat or bar and the header says so (`S3 at bar`), and both keys of that scene blink between 15 and 2 until it lands (a recall from SCENES' K2 or K3 too); a second press before then replaces it ([Scenes](../../scenes.md))
- **SV, held, saves**: hold SV and press a key of line 1 or 2 to save the sound into that scene, writing it to disk at once (`saved S3` in the header). The key saves only: it recalls nothing. Let go of SV first and the key recalls again. A scene key already held when SV comes down does nothing; a page change of the pane while SV is held forgets it, so the next scene key recalls. On the [16×16](../256.md) each pane has its own SV, which saves only from its own pane, and SV on one grid never makes another grid's keys save
- **Line 3** sets the scene of the morph corner picked on line 7 (A at first): press scene x to make it that corner's scene. It shows the corner's scene at 15, the other saved scenes at 6 and the empty slots at 2
- **Lines 4 and 5** are the morph's position, X (`morph`) and Y (`morph y`), as faders: the key pressed sets it along the line, the bar lights to it at 8 and the value at 15. They are grid touches, so a gesture recorder records them. Set elsewhere (MOD, the arc, a MIDI map, PARAMETERS, a recorder's playback), they show within a tick ([Modulation](../../modulation.md))
- **Line 6** sets how many scenes the sequencer cycles through: key x is length x, the keys within the length at 8 and those beyond at 2
- **SQ** (line 7, key 1) starts or stops the scene sequencer: 15 while it runs, 4 while it does not. A MIDI controller mapped to it in PARAMETERS > MAP follows
- **SV** (line 7, key 2): 15 while held, 4 otherwise
- **cA-cD** (line 7, keys 4-7) pick the corner line 3 shows and sets: the picked one 15, the others 4. Each grid keeps its own pick
- **G1-G4** (line 7, keys 9-12) are the gesture recorders: a tap presses the recorder as you let go (empty → recording → playing → stopped → playing), and held half a second it clears the recorder (the key lights nothing more while the hold runs), and letting go then does nothing. Two held at once each act as each is let go. 2 empty, 5 stopped, 10 playing, 15 recording ([Gesture recorders](../../modulation.md))
- Keys 3, 8 and 13-16 of line 7 are dark and do nothing

What the scene keys show (lines 1 and 2): a recall key 15 for the current scene (a scene a crossfade is heading for blinks until it lands), 10 for the scene the running sequencer recalls next, 8 for another saved scene, 2 for an empty slot; a fade key 6 saved, 2 empty; both keys of a scene whose recall waits for its beat or bar blink between 15 and 2.

Where it sits: rows 1-7 of the [16×8](../128h.md) and either pane of the [16×16](../256.md) (the bottom pane's lines on rows 9-15), down columns 1-7 of the [8×16](../128v.md) (line 7 is column 7, its keys from the top; the faders run up their columns, row 16 the minimum), and a half at a time on the [8×8](../64.md): scenes 1-8, SQ, SV and the corners on the left half, scenes 9-16 and the recorders on the right, where key 16 of line 7 is a second SV, so scenes 9-16 can be saved there too. On the 8×8 the faders run across the half's eight keys, the whole range in eight. The corner picked on the left half is the one the right half's line 3 sets.
