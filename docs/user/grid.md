# Monome Grid

The supported grid sizes, the key gestures every layout shares, the pattern sequencer and multi-grid support. Back to the [README](../../README.md).

Strata includes comprehensive grid integration for pattern sequencing and parameter manipulation. Supports multiple grids simultaneously and adapts layout based on grid size.

The grid has no LFO controls (no layout has room for them); the LFOs live on the screen's LFO page, the arc's LFO page and in PARAMETERS.

## Supported Grid Sizes

Each size has its own layout:

- [16×16 (256)](grid/256.md) - Full featured layout with patterns, parameters, scenes, buffers and FX
- [16×8 (128 horizontal)](grid/128h.md) - Four pages: patterns, faders, scenes and sources (record and clear buffers), and a fifth for buffer positions
- [8×16 (128 vertical)](grid/128v.md) - Five pages: patterns, faders, scenes, sources and positions, laid out vertically; the key at (8,8) steps to the next page. A monome 128 reports itself as 16×8: to play it upright, set its port's rotation on [SETUP](pages/setup.md) (`grid 1 rotation` for port 1) to 90 or 270, whichever puts its cable where you want it
- [8×8 (64)](grid/64.md) - Pattern sequencing, 8 steps per voice, one half of the 16 at a time: tap row 8 column 1 for play/stop, hold it to switch halves; columns 2-8 toggle voices 1-7; a third view shows the selected voice's positions

A grid of any other size stays dark. SETUP's rotation fields turn any grid a quarter turn at a time (a 16×16 or 8×8 keeps its layout, turned); a turned grid starts again on page 1.

Lock keys (lit = the voice is locked): the 16×16 on row 16, the 16×8 on row 7 of its faders page, the 8×16 on column 7 rows 10-16 of its faders page. The 8×8 has none.

On the 16×16, 16×8 and 8×16, the recall key of the scene a crossfade goes to blinks until the crossfade lands (see each layout's scene page).

## Holds and Two-Key Gestures

Strata knows which keys of each grid are held, so a key can act on a hold, and a second key can change what a held key does:

- **A step key toggles when you let go** (since 3.4; every layout): a tap turns its step on or off as the key comes up, not as it goes down, so you can hold a step to edit it without changing it first. Every other key that 3.3 had keeps what it does
- **Hold a step to edit it** - a step key held for 0.3 s opens the step editor for that voice and step on the screen, whatever page it shows: the encoders and the arc edit the step there (see [SEQ](pages/seq.md)). Let go of the key to close it and go back to the page; the step is not toggled. Another key of the same voice still sets the held step's level meanwhile. The editor's own clear, Euclidean fill, randomize and undo keep it open. A page change on that grid, a half switch on the 8×8, unplugging the grid or anything else that replaces the voice's pattern (a clear, a randomize or a paste from the 16×16's keys, a scene recall, the scene sequencer's next scene, a chain link: while the chain plays, the editor stays open at most until the next link, one bar at chain bars 1) closes the editor too, and the key's release then does nothing
- **Setting a step's level** - hold a step key and press another key of the same voice: the held step's level becomes that key's share of 15 along the voice's steps (column 16 = 15, column 8 = 8, column 1 = 1; on the 8×8, column 8 = 15 and column 4 = 8; on the 8×16, down the voice's column). The second key does not toggle its own step. Press more keys while still holding to try other levels: every further key of that voice sets the held step's level for as long as the first key stays down, and a key that set a level never takes one itself. Clearing, randomizing or pasting the voice's pattern, recalling a scene (the scene sequencer's next scene too), a chain link, changing the grid's page or switching the 8×8's half ends the level setting: the held key's release changes nothing, and the next key turns its own step on or off. Only the step editor's own clear, fill, randomize and undo leave the key that opened it as the held step
- **Hold to save a scene** - a scene save key (row 3 of the scene page on the 16×16 and 16×8, column 3 on the 8×16) saves only once held for half a second. The key lights up while you hold it; letting go sooner saves nothing, so a stray press never overwrites a scene. A save flashes `saved S<n>` in the header
- **Holding the scan** - the strip's hold key (on the positions page, or the 16×8's sources page) stops a buffer voice's own scan while you hold it. The scan stays held until everything holding it lets go: another grid's hold key, or the arc's ring 1 turned with ALT on the BUFFER page. The key lights while the voice's scan is held, whoever holds it, and, like the rest of the strip, stays dark for a voice that does not read a buffer. Starting or restarting a voice ends its hold, even with the key still down (the key goes dim); press it again to hold
- **Hold to clear or randomize a pattern** (16×16 only) - row 15's keys act only once held for half a second, as a scene save does; the key lights up while you hold it
- **Gesture recorders** (16×16, 16×8 and 8×16) - a tap of a recorder key records, plays, stops and plays again, as MOD's K3 does, as you let go; held half a second it only clears the recorder (nothing plays or starts recording first), and letting go then does nothing
- **Mute and solo** (16×16 only) - a tap of a mute key mutes or unmutes its voice; held half a second it solos or unsolos it
- **Setting a loop** - on a positions page (or the 8×8's position view), hold one position key and press another of the same voice: the loop runs from the earlier key's start to the later key's end (either order; see [Positions](#positions))
- **Storing a bookmark** - on a positions page's strip, hold the store key and press bookmark 1-4: the bookmark takes the voice's playhead position
- Unplugging a grid (or leaving the script) while a key is held cancels its hold: nothing is saved, cleared or randomized, a step editor it opened closes, and a grid's scan hold lets go
- **Changing the page ends what held keys were doing**: a key still held when its grid shows another page does nothing at its hold or its release (a scene save, a clear, a recorder's clear or a solo does not happen, a step does not toggle and its editor closes), and a key held from the page before never acts as the key it comes up on (a recorder or mute key). Another grid's page change leaves this grid's keys alone
- **On the beat**: with PARAMETERS > sequencer > quantize actions on beat or bar, a freeze key waits for the next beat or bar, as a scene recall does, and the header says so (`v2 frz at beat`); pressed again before then, it takes the waiting freeze back

## Positions

Every layout has a positions page (the 8×8 a position view), where a voice's buffer is cut into 16 cells from its start to its end: the 16×16, 16×8 and 8×16 show every voice, one row or column each, the 8×8 only the grid's selected voice. Each layout also has a bookmark strip: the 16×16 one per voice, on its positions page; the 8×16 and 8×8 one for the grid's selected voice, on theirs; the 16×8 one for its grid voice, on its sources page. Only voices reading a buffer respond.

- **A press** jumps the voice to its cell's start. Inside the voice's loop it moves within the loop; outside it, the loop goes back to the whole buffer first, as recalling a bookmark outside the loop does. Either way a running voice's scan restarts from there, and an arc glide ends
- **Two keys** set a loop: hold one cell and press another of the same voice, and the loop runs from the start of the earlier cell to the end of the later one, in either order (two neighbors make a loop two cells long); the voice then jumps to the loop's start
- **The strip**: the four bookmark keys recall bookmarks 1-4 (a jump to the bookmark, as above); while store is held, every bookmark key pressed stores the voice's playhead instead of recalling it; hold stops the voice's scan while it is down; whole puts the loop back to the whole buffer without a jump
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

## Pattern Sequencer Features

- **16-step patterns** per voice (a 64-button grid shows steps 1-8 or 9-16, as you choose)
- **Per-voice patterns** - each voice has independent pattern
- **Real-time recording** - toggle steps while playing
- **Visual feedback** - the step that just played is highlighted (bright if active, dim if empty): the same step the SEQ page shows, until the next one plays
- **Tempo control** - 1-300 BPM, the range of norns' clock tempo: on the 16×16's row 8, columns 5-8, on the [SEQ page](pages/seq.md) (ALT+E3) or in PARAMETERS. The 16×8, 8×16 and 8×8 have no tempo keys
- **Pattern operations** - clear or randomize a voice's pattern: on the 16×16's row 15 (hold the key half a second) or on the SEQ page (ALT+K2 randomizes, ALT+K3 clears the selected voice's). The 16×8, 8×16 and 8×8 have no keys for them
- **Automatic voice triggering** - a step starts a voice that is off, and gives a running voice a short accent (Karplus re-plucks its string) without restarting it; a voice in triggered grain mode also fires one grain
- **Step level is velocity** - a step's brightness (1-15) sets how strong its accent is (a triggered grain carries that accent): level 15 is full, level 6 is 6/15. Steps set by hand are 15; randomized patterns use levels 8-15. Set a step's level with the two-key gesture above

## Multi-Grid Support

- Connect up to 4 grids simultaneously
- Each grid has its own page: one grid can show the patterns while another shows the scenes. Patterns, voices and everything else are shared
- Hot-plug support - connect/disconnect grids while running. A grid plugged in starts on page 1, turned to its port's rotation (SETUP); unplugging a grid while a scene save key is held saves nothing
- The same state lights the same on every layout: a running voice's key 12, a running voice that is muted or silenced by another's solo 6, and a stopped one's 2, the shown page's key bright and the others dim, the selected voice bright and the others dim, a locked voice's key 12
- **Macros and the morph** - the 16×16's macro faders and the 16×8's and 8×16's macro key show one bank of four macros, the same bank on every grid, MOD and its arc rings: changing it anywhere changes it everywhere. Their faders, and the morph faders, follow a value moved on the screen, the arc or MIDI within a tenth of a second. The 8×8 has no keys for them
- A grid moved to another port in SYSTEM > DEVICES works once the norns menu closes, and starts on page 1 with no held keys, as a plugged-in grid does
