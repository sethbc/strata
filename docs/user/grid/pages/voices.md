# Grid Page 6: Voices

One line per voice: its mute, solo and lock, its pattern's clear, randomize and copy, a copy of its sound onto another voice, and its level. Its fourth key is its audio freeze. Press the page's key (P6) to show it; press it again for the [perform side](#side-2-the-perform-side). Back to [Monome Grid](../../grid.md).

## Side 1: each voice's keys

```
     1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
1    MU SO LK FZ CL RN PC VC lv lv lv lv lv lv lv lv
...
7    MU SO LK FZ CL RN PC VC lv lv lv lv lv lv lv lv
```

Line 1 is voice 1, line 7 voice 7. Every key acts as you press it, but CL and RN, which act once held half a second.

- **MU** mutes or unmutes the voice, **SO** solos it or lifts its solo ([Mute and solo](../../voices-and-grains.md#mute-and-solo)): 15 on, 4 off. They are two keys: a voice can be muted and soloed at once, and the mute wins. A muted voice keeps running and its pattern keeps stepping. On the [16×16](../256.md) the bottom strip's mute keys and MU are the same mute. A MIDI controller mapped to `mute` or `solo` in PARAMETERS > MAP follows
- **LK** locks or unlocks the voice (`[L]` on MAIN): 12 locked, 2 not. A lock keeps randomize, drift, mutations and scatter off the voice's sound (its params): you can still edit it and copy a sound onto it. It does not lock the pattern: CL and RN still clear and randomize a locked voice's pattern, and PC still pastes onto it
- **FZ** freezes or unfreezes the voice's audio ([Freeze](../../pages/voice.md#freeze)): 15 frozen, 3 not. With quantize actions on beat or bar (PARAMETERS > sequencer) it waits for the next beat or bar and the header says so (`v2 frz at beat`); the key blinks between 15 and 2 while the set waits and lights when the voice freezes, and a second press before then takes it back. What waits is what the press asked for: a press on a frozen voice unfreezes it at the beat or bar and one on a voice not frozen freezes it, even if a source switch, a scene or a change of `freeze` by hand comes in between (if the voice already has it by then, nothing changes)
- **CL** clears the voice's pattern and **RN** randomizes it, once held half a second: 15 while you hold, 2 otherwise. Let go before then, or change the pane's page, and nothing happens
- **PC** copies and pastes a pattern. With no copy, a press copies the voice's whole pattern as it is now (its key lights 15, every other voice's 4): which steps are on and how strong each is, every step's settings (its chance, condition, ratchets, notes, locks, gate length, slice and values, set in SEQ's step editor) and the lanes' own lengths. A press on another voice pastes it over that voice's playing pattern whole, and the copy stays, so you can paste it again. The voice keeps its length, division and the rest of its sequencer settings, and a step lock, note or value it was playing ends. A press on the copied voice drops the copy (all PC keys back to 2). Pasting ends a step held on that voice ([Holds and Two-Key Gestures](../../grid.md#holds-and-two-key-gestures))
- **VC** copies one voice's sound onto another, as VOICE's preset copy does ([Voice presets](../../voices-and-grains.md#voice-presets)): a press marks the voice (15, the others 4); a press on another voice gives it the marked voice's sound as it is at that press (its type and the sound's settings; the voice keeps its source, its place in its audio, its pattern and whether it runs), and the mark stays; a press on the marked voice drops the mark. A quick ALT+K2 on VOICE, on the voice that took the sound, undoes the copy. A copy that cannot be made changes nothing, and the mark stays
- **lv** (keys 9-16) is the voice's level (`level` on MAIN, `amp` in PARAMETERS), a fader of eight keys: the key pressed sets it along the line, the bar lights to it at 8 and the value at 15. A level set elsewhere (the screen, the arc, a scene, a MIDI map) shows within a tenth of a second

Each grid keeps its own pattern copy and voice mark: they stay while the grid shows other pages, the two panes of a 16×16 share them, and unplugging the grid forgets them. A mute, solo or lock set anywhere else (the screen, a scene, MIDI) shows at once. So does a freeze.

Where it sits: rows 1-7 of the [16×8](../128h.md) and either pane of the [16×16](../256.md) (the bottom pane's lines on rows 9-15; a 16×16 starts on patterns over voices), down columns 1-7 of the [8×16](../128v.md) (each voice's eight keys down rows 1-8 of its column, its level up rows 9-16, row 16 the minimum), and a half at a time on the [8×8](../64.md): the left half holds the eight keys (columns 1-8), the right half the levels (columns 9-16), each across its eight keys.

## Side 2: the perform side

Every voice's performing keys, a line each, so you can play the [variations](../../sequencer.md#variations), the loop's latch, the rolls, the step modes and fill of all seven voices from one page. Press the page's key again while it shows (on the [8×8](../64.md), the chooser's rows 3 and 4).

```
     1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
1    MU SO A  B  C  D  OR LP R1 R2 R3 R4 PU MV AC FL
...
7    MU SO A  B  C  D  OR LP R1 R2 R3 R4 PU MV AC FL
```

- **MU** and **SO** mute and solo the voice, as on side 1
- **A**, **B**, **C**, **D** switch the voice to that pattern ([Variations](../../sequencer.md#variations)). While the patterns play, the letter waits for the next bar and blinks between 15 and 2; tap it again to switch at once, tap the playing letter to cancel the wait. With the patterns stopped it switches at once. The playing letter lights 15, a letter the voice has used 4 (one used and cleared stays used), one never used 2. Switching by hand turns the voice's order off
- **OR** is the voice's order. Hold it and tap letters: each tap adds that letter (up to eight), and nothing switches while you hold it. Let go and the order you tapped replaces the old one and turns on: the voice takes its first letter at the next bar and one letter a bar after that. Tap OR alone to turn the order off or back on (an order is kept while off). OR lights 10 while held, 15 while the order is on, 4 for an order that is off, 2 with none. Changing the pane's page before you let go sets nothing. On a 16×16 with this side on both panes, an order is built on its own pane: the other pane's letters switch as ever, and its OR builds an order of its own
- **LP** is the loop's latch ([The loop](../../sequencer.md#performing)): 2 off; pressed, it arms (10), and the next loop you make on the voice (on the patterns page's side 1) stays when you let its keys go; 6 while a loop is held and not latched, when a press latches it; 15 while a loop is latched, when a press ends it
- **R1** to **R4** roll the voice while held: its last played hit again, 1, 2, 3 or 4 times a step, never closer than 20 ms ([The roll](../../sequencer.md#performing)). The key lights 15 while it rolls, 4 otherwise. Of two roll keys held the last pressed rolls, and letting the first go changes nothing; letting go of the rolling key ends the roll at once, whatever another grid holds. A change of the pane's page (or the 8×8's half) or unplugging the grid ends it too. With the patterns stopped a roll key does nothing
- **PU**, **MV**, **AC** choose the voice's step mode, pulse, move or accent ([Step modes](../../sequencer.md#step-modes)), as the patterns page's side 2 does (choosing move gives every set step a random value A where it has none): the voice's mode 15, the others 4. A voice in `gate` (chosen on SEQ or in PARAMETERS, or 3.8's seq gate in an old scene) lights PU at 8 and none of the three 15. Every voice's mode shows at once
- **FL** holds fill while it is down, on any line ([Fill](../../sequencer.md#fill)): 15 while fill is on, however it was turned on, 4 otherwise. Each line's FL is its own hold, and on a 16×16 each pane's: letting go of one leaves another held, the strip's FL and a latched fill. A change of the pane's page (or the 8×8's half) or unplugging the grid lets go. This puts fill on the 8×8, which has no fill key on its strip

Side 2 has no level fader: keys 9-16 are the rolls, the mode keys and FL. Where it sits: as side 1 on the 16×8 and the 16×16 (on either pane, or side 1 on one and side 2 on the other), each voice's sixteen keys down its column on the 8×16, and on the 8×8 a half at a time: MU, SO, the letters, OR and LP on the left half, the rolls, the mode keys and FL on the right.
