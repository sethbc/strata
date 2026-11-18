# Grid Page 7: FX

The effects on the grid: the delay, the reverb and the master in three sets of five faders, the bypasses, the delay's freeze and clear, sync, the filter's type and its mix, and shimmer's interval. Press the page's key (P7) to show it. Back to [Monome Grid](../../grid.md).

```
     1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
1-5  five faders of the picked set
6    DL RV MA .. i1 i2 i3 i4 i5 .. .. .. .. .. .. ..
7    db ds DF DC .. rb RF .. lp hp bp fm .. .. .. ..
```

- **Lines 1-5** are the picked set's five faders: the key pressed sets the param along the line, the bar lights to it at 8 and the value at 15. They are grid touches, so a gesture recorder records them. Set elsewhere (the [FX page](../../pages/fx.md), the arc, a MIDI map, PARAMETERS, an LFO, a scene), they show within a tenth of a second
  - **DL**, the delay: its time (while the delay is synced, its division: the sixteen keys pick among the twelve divisions, 1/32 to 1 bar; unsynced the last key is the line's whole 5.4 s), feedback, level, ping-pong and shimmer
  - **RV**, the reverb: its level, size, damping, shimmer and how much of the delay it takes (delay to reverb)
  - **MA**, the master: the filter's cutoff, resonance and mix, master density and tape drift
- **DL RV MA** (line 6, keys 1-3) pick the set: the set shown 15, the others 4. Each grid keeps its own set (the delay at first); on a 16×16 both panes showing FX show the same set
- **i1-i5** (line 6, keys 5-9) pick shimmer's interval: an octave down, a fifth, an octave, an octave and a fifth, two octaves ([Shimmer](../../effects.md#shimmer)). The interval 15, the others 4
- **db** and **rb** (line 7, keys 1 and 6) bypass the delay or the reverb, or bring it back ([Bypass](../../effects.md#bypass)): 8 while the effect plays, 2 while bypassed, as a mute key shows what is heard. A bypass ends the effect's freeze
- **ds** (line 7, key 2) syncs the delay's time to the tempo or frees it: 15 synced, 4 free. Line 1 then shows the division or the time
- **DF** (line 7, key 3) freezes the delay's loop or releases it ([Delay freeze and clear](../../effects.md#delay-freeze-and-clear)): 15 frozen, 4 not. A bypassed delay cannot be frozen: the key stays 4
- **DC** (line 7, key 4) empties the delay as you press it: 15 while held, 4 otherwise
- **RF** (line 7, key 7) is the reverb's freeze. 3.8 has none, so the key is dark and does nothing
- **lp hp bp** (line 7, keys 9-11) set the master filter's type, lowpass, highpass or bandpass: the type 15, the others 4
- **fm** (line 7, key 12) turns the master filter on or off, as K3 does on the FX page's filter rows: off sets its mix to 0 and remembers it, on brings that mix back. 15 while the mix is above 0, 4 at 0
- Keys 4 and 10-16 of line 6 and keys 5, 8 and 13-16 of line 7 are dark and do nothing

Every key acts as you press it; letting go does nothing. A key's light follows its param however it is set: a bypass, sync, a freeze, the filter's type and mix and the interval set elsewhere show within a tenth of a second.

Where it sits: rows 1-7 of the [16×8](../128h.md) and either pane of the [16×16](../256.md) (the bottom pane's lines on rows 9-15), down columns 1-7 of the [8×16](../128v.md) (the five faders run up columns 1-5, row 16 the minimum; the set and interval keys down column 6, line 7's keys down column 7), and a half at a time on the [8×8](../64.md): the left half (columns 1-8) holds the set keys, intervals 1-4, the delay's four keys and the reverb's two, the right half (columns 9-16) interval 5 and the filter's types and mix. On the 8×8 the faders run across the half's eight keys on both halves, the whole range in eight.
