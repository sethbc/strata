# MOD

The modulation in one list: the macros, the morph, scatter, the gesture recorders, the LFOs and the modulation matrix. Back to [Screen Controls](../controls.md).

```
MOD     ·····•···            S3
macros
 bank                   1  M1-M4
 M1   v3 pitch +2            42%
 M2   -                       0%
 M3   -                       0%
K3:targets E3:value
```

The page is a list under dim section names, five rows at a time, with a thin scroll marker at the right: **macros** (the `bank` row, then the shown bank's four macros), **morph** (`A`, `B`, `morph`), **scatter** (`on`, `depth`, `rate`, then `pitch`, `pos`, `size`, `cutoff`, `amp`), **gestures** (`G1`-`G4`), **lfos** (`L1`-`L6`), **matrix** (`R1`-`R16`), then **audio** (`IN`, the input level). A section added by a later release shows after these. The row under the cursor is bright.

What each row shows:
- **bank** - the bank shown (`1  M1-M4`: bank 1 holds macros 1-4). The MOD page, its arc rings and the grids show the same bank
- **M1**-**M16** - the macro's first target and how many more (`v3 pitch +2`; `-` with none) and its value
- **A**, **B** - the two scenes the morph goes between, with their names (`S3 dusk`); **morph** - the position, 0 % at A, 100 % at B
- **scatter** - on or off, its depth and rate, and which settings it moves
- **G1**-**G4** - each recorder: `empty`, `rec 3.2 s` while it records, `play 2 bars` or `play 5.0 s` while it plays, `stop 5.0 s`
- **L1**-**L6** - each LFO's destination (`~` when it runs in the engine), depth, and the LFOs its rate and depth follow (`v3 pitch~ 25% <L2`)
- **R1**-**R16** - each routing: its source, `>`, its destination and its depth (`R3 L2>v3 pitch~  +40%`), or `-` when empty. A routing that is off, or misses its source or destination, is dim
- **IN** - the input level now, as a routing reads it

## The list

- **E2** - Move the cursor
- **K2** - Jump to the next section (after the last, back to the first)
- **E3** - Change the row: the bank, a macro's value, the morph's scenes and position, scatter's on/off, depth, rate and settings (turn right for on, left for off), a recorder's quantize (free, beat or bar), an LFO's depth, a routing's depth, the input's gain
- **ALT+E3** - The same in finer steps, where the value is continuous
- **K3** - On the bank row, the next bank (bank 4 back to 1); on a macro, its targets (below); on scatter's switches, on or off; on a recorder, its next state (record, play, stop, play: [Modulation](../modulation.md#gesture-recorders)); on an LFO, the LFO page with that LFO selected; on a routing, the routing (below)
- **ALT+E2** on a macro - The same macro of the next bank (turn left for the bank before); the arc's rings and the grids follow
- **ALT+K3** - On a playing recorder, overdub on or off; on a routing, turn it on or off
- **ALT+K2** - In scatter and the matrix, a quick press randomizes the section: scatter's depth (0-30 %) and rate (0.02-0.5 Hz, spread evenly across octaves), or the depth of every routing that has both a source and a destination (−50 to +50 %). It acts when you let go of K2; within 5 seconds a quick ALT+K2 again on the same section undoes it, and changing one of those values ends the undo. Held for half a second it clears the recorder or the routing under the cursor, if it holds anything (the hint turns to `K2:clear`; on a row with nothing to clear it says `K2:cancel`, and letting go does nothing). On a recorder, ALT+K2 held is all it does. The macros, the morph and the LFOs are not randomized here: ALT+K2 does nothing on their rows

The hint row names the row's keys: `K3:targets E3:value` on a macro, `K3:rec E3:quant` on an empty recorder, `K3:lfo E3:depth` on an LFO, `K3:edit E3:depth` on a routing. With K1 held it names only what acts on the row: `K2:rand` (or `K2:undo`) in scatter and the matrix, `K2:clear` on a recorder that holds a loop (or a routing that holds anything but nothing to randomize), no K2 where ALT+K2 does nothing (a macro, the morph, an LFO, an empty recorder); then `K3:dub` on a playing recorder, `K3:on` or `K3:off` on a routing, `E2:bank` on a macro and `E3:fine` where a value turns finely.

## A macro's targets

K3 on a macro shows its eight targets:

```
MOD     ·····•···
M1 targets                   42%
1 v3 pitch               20>90%
2 rev mix                0>100%
3 -
K2:back K3:col E3:target
```

Each row is a target and the two ends it moves between as the macro goes from 0 to 100 %, in percent of the target's range (`90>20%` moves it down). One of the three columns, the target, its first end or its second, is bright on the cursor's row.
- **E2** - Select the row
- **K3** - Next column
- **E3** - Change the column: the target, through every setting a macro can move (none first), or an end, 1 % per step (ALT+E3 0.1 %)
- **ALT+E3** on the target - Jump a group (the globals, voice 1 ... voice 7, the registered settings, the LFOs' rates and depths, the routings' depths)
- **ALT+K3** - Learn: the next setting you touch with an encoder, an arc ring or a grid fader becomes the row's target, from 0 to 100 % (the header shows `M1 > v3 pitch`, or `not a macro target`). The row shows `learn` while it waits; K2, leaving the page or 10 seconds cancels it
- **ALT+K2** held half a second - Empty the row (with K1 held, a row with a target shows `K2:clear`; an empty row shows no K2)
- **K2** - Back to the list

A target from another release is kept and drawn dim, as it was saved.

## A routing

K3 on a routing shows it:

```
MOD     ·····•···
R3 routing                    on
source                        L2
dest                    v3 pitch~
depth                       +40%
K2:back K3:off E3:source
```

- **E2** - Select the row
- **E3** - Change it: the source, through every modulation source in turn (ALT+E3 jumps to the next kind: LFOs, macros, recorders, the input); the destination, through every setting an LFO can move but the macros (ALT+E3 jumps a group); the depth (ALT+E3 in finer steps); on or off. A routing that gets both a source and a destination at a depth of 0 starts at 25 %, so you hear it. All sixteen macros are offered as sources, whatever bank the list shows
- **K3** - Turn the routing on or off
- **ALT+K3** on `dest` - Learn: the next setting you touch becomes the destination (the header shows `R3 > v3 pitch`, or `not a destination`); K2, leaving the page, showing another routing (arc ring 4) or 10 seconds cancels it
- **ALT+K2** held half a second - Clear the routing
- **K2** - Back to the list

How the macros, the morph, scatter, the recorders and the matrix work is in [Modulation](../modulation.md). The arc's MOD rings are in [Monome Arc](../arc.md).
