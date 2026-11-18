# Monome Grid

The grid's panes, pages and strips, the key gestures every page shares, the pattern sequencer and multi-grid support. Back to the [README](../../README.md).

Strata includes comprehensive grid integration for pattern sequencing and parameter manipulation. Supports multiple grids simultaneously, and every size shows the same pages with each key in the same place.

The grid has no LFO controls; the LFOs live on the screen's LFO page, the arc's LFO page and in PARAMETERS.

## Panes, pages and strips

Since 3.8 every grid is built on one model. A **pane** is seven lines of sixteen keys, with a **strip** of fixed keys; a line is a voice on the pages that are per voice, line 1 voice 1. A pane shows one of seven **pages**, the same on every size:

1. [Patterns](grid/pages/patterns.md) - seven lines of sixteen steps
2. faders, 3. scenes, 4. sources, 5. positions, 6. voices, 7. FX - coming in the rest of 3.8: until then their page keys are dark and do nothing, and only the patterns page is filled

The sizes, one page each:

- [16×16 (256)](grid/256.md) - two panes, rows 1-7 over rows 9-15, each with its own page and strip; it starts on patterns over voices (patterns over patterns until the voices page arrives)
- [16×8 (128 horizontal)](grid/128h.md) - one pane, its strip on row 8
- [8×16 (128 vertical)](grid/128v.md) - one pane turned: voices down columns 1-7, the strip down column 8. A monome 128 reports itself as 16×8: to play it upright, set its port's rotation on [SETUP](pages/setup.md) (`grid 1 rotation` for port 1) to 90 or 270, whichever puts its cable where you want it
- [8×8 (64)](grid/64.md) - the left or the right half of a pane, eight columns at a time, with a small strip on row 8; hold its first key to choose the page and half

A grid of any other size stays dark. SETUP's rotation fields turn any grid a quarter turn at a time (a 16×16 or 8×8 keeps its layout, turned); a turned grid starts again on its first pages.

### The strips

```
            1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
128h row 8  PL FL P1 P2 P3 P4 P5 P6 P7 O1 O2 O3 O4 O5 O6 O7
256 row 8   the same, for the top pane
256 row 16  T- T+ P1 P2 P3 P4 P5 P6 P7 M1 M2 M3 M4 M5 M6 M7
128v col 8  the 128h's strip, top to bottom
64 row 8    NV O1 O2 O3 O4 O5 O6 O7
```

- **PL** plays or stops the patterns: 15 while playing, 4 while stopped
- **FL** holds fill while it is down: 15 while fill is on, however it was turned on ([Fill](sequencer.md#fill)). A page change leaves it held; unplugging the grid ends it
- **P1-P7** show a page on the strip's pane (row 16's on the 256's bottom pane): the shown page 15, the others 2, a page that is not there yet 0. The lit key pressed again shows the page's second side, where it has one, and lights 10 there
- **O1-O7** start or stop a voice: 12 running, 6 running but silenced (muted, or another voice soloed), 2 stopped
- **T- T+** (the 256's row 16) set the tempo down or up by 1 BPM and show it in the header; held, they repeat after half a second, ten times a second, until you let go
- **M1-M7** (the 256's row 16) mute or unmute a voice: 15 muted, 4 not
- **NV** (the 8×8's): a tap plays or stops the patterns as you let go; held half a second it shows the chooser (see [8×8](grid/64.md)), and letting go then only closes it

## Holds and Two-Key Gestures

Strata knows which keys of each grid are held, so a key can act on a hold, and a second key can change what a held key does:

- **A step key toggles when you let go** (since 3.4): a tap turns its step on or off as the key comes up, not as it goes down, so you can hold a step to edit it without changing it first
- **Hold a step to edit it** - a step key held for 0.3 s opens the step editor for that voice and step on the screen, whatever page it shows: the encoders and the arc edit the step there (see [SEQ](pages/seq.md)). Let go of the key to close it and go back to the page; the step is not toggled. Another key of the same voice still sets the held step's level meanwhile. The editor's own clear, Euclidean fill, randomize and undo keep it open. A page change on that pane, a half change on the 8×8 (or its chooser opening), unplugging the grid or anything else that replaces the voice's pattern (a clear, a randomize, a scene recall, the scene sequencer's next scene, a chain link: while the chain plays, the editor stays open at most until the next link, one bar at chain bars 1) closes the editor too, and the key's release then does nothing
- **Setting a step's level** - hold a step key and press another key of the same voice: the held step's level becomes that key's share of 15 along the voice's keys (key 16 = 15, key 8 = 8, key 1 = 1; on the 8×8, key 8 of the half = 15 and key 4 = 8; on the 8×16, down the voice's column). The second key does not toggle its own step. Press more keys while still holding to try other levels: every further key of that voice sets the held step's level for as long as the first key stays down, and a key that set a level never takes one itself. On the 16×16 a voice's keys in both panes count as one: a voice has one held step on a grid. Clearing, randomizing or pasting the voice's pattern, recalling a scene (the scene sequencer's next scene too), a chain link, changing the pane's page or switching the 8×8's half ends the level setting: the held key's release changes nothing, and the next key turns its own step on or off. Only the step editor's own clear, fill, randomize and undo leave the key that opened it as the held step
- Unplugging a grid (or leaving the script) while a key is held cancels its hold: nothing happens at its hold or its release, a step editor it opened closes, and a held FL lets fill go
- **Changing a pane's page ends what its held keys were doing**: a key of that pane still held when it shows another page does nothing at its hold or its release (a step does not toggle and its editor closes). The other pane's keys and the strips' keys go on: a held FL keeps fill on, a held tempo key keeps repeating. Another grid's page change leaves this grid's keys alone

## Positions

The positions page (page 5) arrives in the rest of 3.8; this is what it will do. A voice's buffer is cut into 16 cells from its start to its end, one line per voice, and each voice has a bookmark strip. Only voices reading a buffer respond.

- **A press** jumps the voice to its cell's start. Inside the voice's loop it moves within the loop; outside it, the loop goes back to the whole buffer first, as recalling a bookmark outside the loop does. Either way a running voice's scan restarts from there, and an arc glide ends
- **Two keys** set a loop: hold one cell and press another of the same voice, and the loop runs from the start of the earlier cell to the end of the later one, in either order (two neighbors make a loop two cells long); the voice then jumps to the loop's start
- **The strip**: the four bookmark keys recall bookmarks 1-4 (a jump to the bookmark, as above); while store is held, every bookmark key pressed stores the voice's playhead instead of recalling it; hold stops the voice's scan while it is down (it stays held until everything holding it lets go: another grid's hold key, or the arc's ring 1 turned with ALT on the BUFFER page); whole puts the loop back to the whole buffer without a jump
- **On the beat**: with PARAMETERS > sequencer > quantize actions on beat or bar, a press, a two-key loop and a bookmark recall wait for the next beat or bar of the clock, and the header says so (`v1 jump at bar`, `v1 bm 2 at bar`); a second press before then replaces the first. Store, hold and whole act at once ([Parameters](params.md#sequencer-group))

What the cells show, brightest first:
- the playhead, where the voice's grains start, at 15 (a stopped voice shows where it will start)
- the record head, at 13, while the buffer records without emptying (an overdub or a loop recording)
- a held cell, at 11
- the cells inside the loop at 4 to 8 and those outside it at 1 to 3, brighter where the buffer's audio is louder, so the row draws the waveform
- a voice that reads no buffer, or whose buffer is empty, has a dark row

What the strip shows (all of it dark for a voice that reads no buffer):
- a bookmark key at 6, the bookmark last recalled at 10 (until the voice changes its source), and 15 while you store it; a bookmark that waits for its beat or bar (quantize actions) blinks between 15 and 2 until it lands
- the store key at 15 while it is held, 4 otherwise
- the hold key at 15 while the voice's scan is held (by any grid or the arc), 4 otherwise
- the whole key at 15 while the loop is the whole buffer, 4 otherwise

### Slice rows

A voice set to play slices (its `slices` row on [VOICE](pages/voice.md) not off) whose buffer has slices shows them on its position line instead of positions, 16 at a time. A voice with slices off, or a buffer with none, keeps its positions.

- **A press** plays its slice, and letting go ends it, except in one shot with a moving scan, where a slice plays to its end. A key with no slice does nothing
- **The bank keys**: while the line shows slices, the strip's four bookmark keys pick the bank it shows: slices 1-16, 17-32, 33-48 or 49-64. A bank with no slices cannot be picked. Each grid keeps its own bank per voice, and a new file in the slot whose slices do not reach the bank puts it back to 1. Store, hold and whole keep their meaning. Bookmarks are then recalled from [BUFFER](pages/buffer.md)'s `bm` field and from steps' bookmark locks
- **On the beat**: with quantize actions on beat or bar, a press waits for the next beat or bar (`v1 sl 5 at bar`), and a key let go before then takes it back, except in one shot with a moving scan, where a tap still plays at the beat
- **What it shows**: a slice playing at 15, a held key at 11, a slice at 9, no slice dark; the bank keys light 15 for the bank shown, 4 for a bank that holds slices and 0 for one that holds none

## Pattern Sequencer Features

- **16-step patterns** per voice (a 64-button grid shows steps 1-8 or 9-16, as you choose)
- **Per-voice patterns** - each voice has independent pattern
- **Real-time recording** - toggle steps while playing
- **Visual feedback** - the step that just played is highlighted (bright if active, dim if empty): the same step the SEQ page shows, until the next one plays
- **Tempo control** - 1-300 BPM, the range of norns' clock tempo: on the 16×16's row 16 (T- and T+, by 1), on the [SEQ page](pages/seq.md) (ALT+E3) or in PARAMETERS. The 16×8, 8×16 and 8×8 have no tempo keys
- **Pattern operations** - clear or randomize a voice's pattern on the SEQ page (ALT+K2 randomizes, ALT+K3 clears the selected voice's)
- **Fill** - FL, held on the 16×16's and 16×8's row 8 and the 8×16's column 8, on every page: on while the key is down, lit 15 while fill is on however it was turned on ([Fill](sequencer.md#fill)). The 8×8 has no fill key
- **Automatic voice triggering** - a step starts a voice that is off, and gives a running voice a short accent (Karplus re-plucks its string) without restarting it; a voice in triggered grain mode also fires one grain
- **Step level is velocity** - a step's brightness (1-15) sets how strong its accent is (a triggered grain carries that accent): level 15 is full, level 6 is 6/15. Steps set by hand are 15; randomized patterns use levels 8-15. Set a step's level with the two-key gesture above

## Multi-Grid Support

- Connect up to 4 grids simultaneously. Strata's four grid ports are norns' own (SYSTEM > DEVICES), with or without the midigrid mod
- Each pane of each grid has its own page: one grid can show the patterns while another shows another page. Patterns, voices and everything else are shared
- Hot-plug support - connect/disconnect grids while running. A grid plugged in starts on its first pages, turned to its port's rotation (SETUP); unplugging a grid while a key is held does nothing of what the key would have done
- The same state lights the same on every size: a running voice's key 12, a running voice that is muted or silenced by another's solo 6, and a stopped one's 2, the shown page's key bright and the others dim
- A grid moved to another port in SYSTEM > DEVICES works once the norns menu closes, and starts on its first pages with no held keys, as a plugged-in grid does
