# Grid Page 5: Positions

Where each voice reads its buffer, on two sides: side 1 a line of 16 cells per voice, side 2 every voice's marks (its bookmarks, store, hold and whole keys) and the slots' record and clear keys. Press the page's key (P5) to show it, and press it again while it is lit for the other side (the key lights 10 on side 2). Back to [Monome Grid](../../grid.md).

Line 1 is voice 1, line 7 voice 7. Only voices reading a buffer respond.

## Side 1: the cells

A voice's buffer is cut into 16 cells from its start to its end, one line per voice.

- **A press** jumps the voice to its cell's start. Inside the voice's loop it moves within the loop; outside it, the loop goes back to the whole buffer first, as recalling a bookmark outside the loop does. Either way a running voice's scan restarts from there, and an arc glide ends
- **Two keys** set a loop: hold one cell and press another of the same voice, and the loop runs from the start of the earlier cell to the end of the later one, in either order (two neighbors make a loop two cells long); the voice then jumps to the loop's start. On an 8×8 both keys are in the half it shows. On a 16×16 the two cells can be in different panes. If you hold the same cell in both panes, the newer press is the anchor until you release it
- **On the beat**: with PARAMETERS > sequencer > quantize actions on beat or bar, a press, a two-key loop and a bookmark recall wait for the next beat or bar of the clock, and the header says so (`v1 jump at bar`, `v1 bm 2 at bar`); a second press before then replaces the first. Store, hold and whole act at once ([Parameters](../../params.md#sequencer-group))

What the cells show, brightest first:
- the playhead, where the voice's grains start, at 15 (a stopped voice shows where it will start)
- the record head, at 13, while the buffer records without emptying (an overdub or a loop recording)
- a held cell, at 11
- the cell of a jump or a two-key loop (its second key) that waits for its beat or bar, once you let go, blinking between 15 and 2 until it lands
- the cells inside the loop at 4 to 8 and those outside it at 1 to 3, brighter where the buffer's audio is louder, so the line draws the waveform
- a voice that reads no buffer, or whose buffer is empty, has a dark line

### Slice rows

A voice set to play slices (its `slices` row on [VOICE](../../pages/voice.md) not off) whose buffer has slices shows them on its line instead of positions, 16 at a time. A voice with slices off, or a buffer with none, keeps its positions.

- **A press** plays its slice, and letting go ends it, except in one shot with a moving scan, where a slice plays to its end. A key with no slice does nothing
- **The bank keys**: while the line shows slices, side 2's four bookmark keys of the voice pick the bank it shows: slices 1-16, 17-32, 33-48 or 49-64. A bank with no slices cannot be picked. Each grid keeps its own bank per voice, and a new file in the slot whose slices do not reach the bank puts it back to 1. Store, hold and whole keep their meaning. Bookmarks are then recalled from [BUFFER](../../pages/buffer.md)'s `bm` field and from steps' bookmark locks
- **On the beat**: with quantize actions on beat or bar, a press waits for the next beat or bar (`v1 sl 5 at bar`), and a key let go before then takes it back, except in one shot with a moving scan, where a tap still plays at the beat
- **What it shows**: a slice playing at 15, a held key at 11, a slice at 9, no slice dark; the bank keys light 15 for the bank shown, 4 for a bank that holds slices and 0 for one that holds none

## Side 2: the marks and the slots

```
x   1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
1   B1 B2 B3 B4 .  ST HD WH R1 R2 R3 R4 R5 R6 R7 R8
2   B1 B2 B3 B4 .  ST HD WH C1 C2 C3 C4 C5 C6 C7 C8
3-7 B1 B2 B3 B4 .  ST HD WH
```

Each line's keys 1-8 are its voice's marks:
- **B1-B4** recall bookmarks 1-4 (a jump to the bookmark, as a press of a cell does); while ST is held, every bookmark key pressed stores the voice's playhead instead of recalling it
- **ST** (store) is held to store
- **HD** (hold) stops the voice's scan while it is down; it stays held until everything holding it lets go: another grid's hold key, or the arc's ring 1 turned with ALT on the BUFFER page
- **WH** (whole) puts the loop back to the whole buffer without a jump

The slots, on columns 9-16 (slot 1 to slot 8):
- **R1-R8** (line 1) record into the slot with the record settings ([Recording](../../sources-and-buffers.md#recording)); pressed again while it records, the recording stops early and keeps what it took; pressed while it waits for its beat or bar, it is canceled
- **C1-C8** (line 2) clear the slot

What side 2 shows (all of a voice's marks dark when it reads no buffer):
- a bookmark key at 6, the bookmark last recalled at 10 (until the voice changes its source), and 15 while you store it; a bookmark that waits for its beat or bar (quantize actions) blinks between 15 and 2 until it lands
- On the 16×16, you can hold ST in one pane and store a bookmark in the other. Leaving the bookmark's page ends its bright indication and keeps the saved position. If both panes hold that bookmark, it stays bright until the last key is up
- ST at 15 while it is held on this grid, 4 otherwise
- HD at 15 while the voice's scan is held (by any grid or the arc), 4 otherwise
- WH at 15 while the loop is the whole buffer, 4 otherwise
- a record key at 15 while its slot records, 11 while it waits for its beat or bar, 8 while the slot holds audio, 2 while it is empty; a clear key at 4

## Held keys

A held key belongs to its pane: changing that pane's page or side, or the 8×8's half, or opening the 8×8's chooser, ends it (a held hold lets the scan go, a held store stops storing, a held cell is no loop anchor any more, a held slice ends), while the other pane's keys go on. If you leave HD held, release it on another page and return to the cells, pressing column 7 jumps with the scan free to run. On the 16×16 both panes can show the page, one on each side: a store held below stores the bookmark pressed below while the top pane shows the cells, and a voice's store or hold held in both panes lasts until the last of them lets go.

Where it sits: rows 1-7 of the [16×8](../128h.md) and either pane of the [16×16](../256.md) (the bottom pane's lines on rows 9-15), down columns 1-7 of the [8×16](../128v.md) (each voice's cells, and its side-2 keys, down its column), and a half at a time on the [8×8](../64.md): cells 1-8 or 9-16, and on side 2 the marks on the left half, the slots on the right.
