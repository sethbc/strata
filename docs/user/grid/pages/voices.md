# Grid Page 6: Voices

One line per voice: its mute, solo and lock, its pattern's clear, randomize and copy, a copy of its sound onto another voice, and its level. Its fourth key is its audio freeze. Press the page's key (P6) to show it. Back to [Monome Grid](../../grid.md).

```
     1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
1    MU SO LK FZ CL RN PC VC lv lv lv lv lv lv lv lv
...
7    MU SO LK FZ CL RN PC VC lv lv lv lv lv lv lv lv
```

Line 1 is voice 1, line 7 voice 7. Every key acts as you press it, but CL and RN, which act once held half a second.

- **MU** mutes or unmutes the voice, **SO** solos it or lifts its solo ([Mute and solo](../../voices-and-grains.md#mute-and-solo)): 15 on, 4 off. They are two keys: a voice can be muted and soloed at once, and the mute wins. A muted voice keeps running and its pattern keeps stepping. On the [16×16](../256.md) the bottom strip's mute keys and MU are the same mute. A MIDI controller mapped to `mute` or `solo` in PARAMETERS > MAP follows
- **LK** locks or unlocks the voice (`[L]` on MAIN): 12 locked, 2 not. A lock keeps randomize, drift, mutations and scatter off the voice's sound (its params): you can still edit it and copy a sound onto it. It does not lock the pattern: CL and RN still clear and randomize a locked voice's pattern, and PC still pastes onto it
- **FZ** freezes or unfreezes the voice's audio ([Freeze](../../pages/voice.md#freeze)): 15 frozen, 3 not. With quantize actions on beat or bar (PARAMETERS > sequencer) it waits for the next beat or bar and the header says so (`v2 frz at beat`); the key lights when the voice freezes, and a second press before then takes it back. What waits is what the press asked for: a press on a frozen voice unfreezes it at the bar and one on a voice not frozen freezes it, even if a source switch, a scene or a change of `freeze` by hand comes before then (if the voice already has it by the bar, nothing changes)
- **CL** clears the voice's pattern and **RN** randomizes it, once held half a second: 15 while you hold, 2 otherwise. Let go before then, or change the pane's page, and nothing happens
- **PC** copies and pastes a pattern. With no copy, a press copies the voice's sixteen steps as they are now (its key lights 15, every other voice's 4). A press on another voice pastes them over that voice's pattern, and the copy stays, so you can paste it again. A paste carries which steps are on and how strong each is, nothing else: the voice keeps its own step settings (each step's chance, condition, ratchets, notes, locks, gate length and slice, set in SEQ's step editor) and its length, division and the rest of its sequencer settings, and a step lock or note it was playing ends. A press on the copied voice drops the copy (all PC keys back to 2). Pasting ends a step held on that voice ([Holds and Two-Key Gestures](../../grid.md#holds-and-two-key-gestures))
- **VC** copies one voice's sound onto another, as VOICE's preset copy does ([Voice presets](../../voices-and-grains.md#voice-presets)): a press marks the voice (15, the others 4); a press on another voice gives it the marked voice's sound as it is at that press (its type and the sound's settings; the voice keeps its source, its place in its audio, its pattern and whether it runs), and the mark stays; a press on the marked voice drops the mark. A quick ALT+K2 on VOICE, on the voice that took the sound, undoes the copy. A copy that cannot be made changes nothing, and the mark stays
- **lv** (keys 9-16) is the voice's level (`level` on MAIN, `amp` in PARAMETERS), a fader of eight keys: the key pressed sets it along the line, the bar lights to it at 8 and the value at 15. A level set elsewhere (the screen, the arc, a scene, a MIDI map) shows within a tenth of a second

Each grid keeps its own pattern copy and voice mark: they stay while the grid shows other pages, the two panes of a 16×16 share them, and unplugging the grid forgets them. A mute, solo or lock set anywhere else (the screen, a scene, MIDI) shows at once. So does a freeze.

Where it sits: rows 1-7 of the [16×8](../128h.md) and either pane of the [16×16](../256.md) (the bottom pane's lines on rows 9-15; a 16×16 starts on patterns over voices), down columns 1-7 of the [8×16](../128v.md) (each voice's eight keys down rows 1-8 of its column, its level up rows 9-16, row 16 the minimum), and a half at a time on the [8×8](../64.md): the left half holds the eight keys (columns 1-8), the right half the levels (columns 9-16), each across its eight keys.
