# Monome Arc

Using a monome arc for hands-on control with LED feedback. Back to the [README](../../README.md).

Strata supports the monome arc controller for hands-on parameter control with visual LED feedback. Strata follows one arc, on whichever arc port it is assigned to (SYSTEM > DEVICES > ARC). An arc moved to another port there is followed once you close the menu. If a second arc is plugged in while one is connected, it is ignored; unplugging the connected arc moves Strata to the other one.

## Arc Encoders

The rings control the current screen page. They keep working while the norns menu is open (as the grid does): turning one still changes its parameter, and the rings show changes made in PARAMETERS to what they control. Every ring that sets a value sweeps its parameter's whole range in a full turn (1024 ticks, one revolution), following the parameter's curve (frequency, delay time and buffer rate are exponential, so each half of the sweep covers as much of the curve). A ring whose range runs through 0 (pan, crossmod amounts) fills from the top: clockwise for a value above 0, counter-clockwise below it, and only a dim top LED at exactly 0, where it also holds for a moment as you turn through it. The exceptions to the full-turn sweep step whole values: the LFO page's depth rings (10 ticks per percent) and clocked rate (20 ticks per division), the VOICE page's choice, number and on/off rows (20 ticks per step), the SEQ rings (10 ticks per step, per level and per BPM; 20 per voice), the step editor's probability (about 10 ticks per percent) and ALT rings (20 ticks per step), the SCENES cursor ring (10 ticks per slot or field) and its morph B ring (20 ticks per scene), and on MOD the morph B ring, a routing's source, destination and number and a macro's target row (20 ticks per step). Part-turns toward the next step are kept for the next turn of that ring, and forgotten when you change page. The arc has no fine mode.

On the **MAIN** page:

- **Ring 1** - Master density (0.1 to 2.0)
- **Ring 2** - Selected voice's main parameter (always the first of the three fields E3 can edit on MAIN, whichever field the cursor is on: buffer position for a buffer-sourced voice, grain size for an input-sourced one)
- **Ring 3** - Grain size for selected voice (grain pitch for an input-sourced voice, whose ring 2 already is grain size)
- **Ring 4** - Grain density for selected voice

With **K1 held** (ALT), MAIN's rings change to the selected voice's:

- **Ring 1** - Grain pitch
- **Ring 2** - Grain spread
- **Ring 3** - Level
- **Ring 4** - Pan (dark and does nothing for Sub, which has no pan)

On the **VOICE** page, the four rings edit four rows of the voice's list: the group of four the cursor is in (rows 1-4, 5-8, ... counting only the parameters, not the section names), ring 1 the group's first row. Moving the cursor into the next group moves the rings with it. Continuous parameters sweep as above; choices and numbers (grain envelope and mode, the mod sources, the source) step one value per 20 ticks. An on/off row (freeze, quantize) turns on after 20 ticks up and off after 20 ticks down. Its ring is dark while off and a full ring while on. A ring past the last row of the list is dark and does nothing. The ring of the row under the cursor is the brightest.

On the **SEQ** page, in the patterns and in the edit view alike (in the edit view ring 1 moves the step being edited):

- **Ring 1** - Step cursor (10 ticks per step)
- **Ring 2** - Level of the step under the cursor on the selected voice's pattern, 0 (off) to 15 (10 ticks per level; the grid follows)
- **Ring 3** - Tempo (10 ticks per BPM)
- **Ring 4** - Voice row, the selected voice (20 ticks per voice)

Rings 1, 2 and 4 show their position: the step across the 16 steps, the level up to 15, the voice across the 7 voices. At the first position (step 1, level 0, voice 1) one LED stays lit, so the ring never looks off. The same holds for the SCENES cursor ring at slot 1.

While a grid's **step editor** is open (a step key held on the grid, over any page; see the [SEQ page](pages/seq.md)), the rings edit that step instead of the page's:

- **Ring 1** - Position, **Ring 2** - pitch, **Ring 3** - size, the step's step locks (see [Sequencer](sequencer.md)): a full turn for the whole range of the voice's own parameter. A step lock that is off starts from the voice's own value; turning below the start of the range turns it off again
- **Ring 4** - Probability, in whole percents (a full turn for 0-100 %)
- With **ALT** held: **Ring 1** - ratchets, **Ring 2** - note, **Ring 3** - bookmark (dark and does nothing without bookmarks), **Ring 4** - the step's level (20 ticks per step)

A set step lock, note or bookmark is drawn bright; one that is off is drawn dim at the value a turn starts from.

On the **FX** page:

- **Ring 1** - Filter frequency
- **Ring 2** - Filter resonance
- **Ring 3** - Delay time
- **Ring 4** - Delay mix

On the **LFO** page:

- **Rings 1-3** - Depth of the three LFOs the page shows: LFOs 1-3 while LFO 1 or 2 is selected, up to LFOs 4-6 while 5 or 6 is (10 ticks per percent; bright while the LFO runs; part-turns are forgotten when the page shows another three)
- **Ring 4** - Rate of the LFO selected on the page: the free rate, or the clocked rate when its mode is clocked (part-turns toward the next clocked rate are forgotten when you select another LFO or change its mode)

On the **MOD** page:

- **Rings 1-4** - The four macros of the bank shown (macros 1-4 on bank 1, up to 13-16 on bank 4). Changing the bank anywhere (the bank row, ALT+E2, the arc's button, a grid) moves the rings with it
- With the cursor on a routing (R1-R16), **rings 1-4** are the depths of the four routings around it (R1-R4, R5-R8, R9-R12, R13-R16), filled from the top: clockwise for a positive depth, counter-clockwise for a negative one; dim while the routing is off or misses its source or destination

With **ALT** (K1) held on the list:

- **Ring 1** - Morph position
- **Ring 2** - Scatter depth
- **Ring 3** - Scatter rate
- **Ring 4** - Morph scene B (20 ticks per scene)

In a macro's targets (K3 on a macro):

- **Ring 1** - The first end of the target under the cursor (a full turn from 0 to 100 %)
- **Ring 2** - Its second end
- **Ring 3** - The macro itself
- **Ring 4** - The target row (20 ticks per row)

In a routing (K3 on a routing):

- **Ring 1** - Its depth
- **Ring 2** - Its source, one per 20 ticks
- **Ring 3** - Its destination, one per 20 ticks
- **Ring 4** - The routing shown, R1-R16 (20 ticks per routing)

Part-turns toward the next step are also forgotten when you open or close a view, move to another section, change the bank or show another routing.

On the **BUFFER** page:

- **Ring 1** - Selected voice's buffer position. With the scrub friction below 100% a fast turn glides on after you let go
- **Ring 2** - Loop start
- **Ring 3** - Loop length
- **Ring 4** - Buffer scan (center is 0: a clockwise fill scans forward, a counter-clockwise fill backward)

With **ALT** (K1) held:

- **Ring 1** - Buffer position; from its first turn the voice's own scan stops, until you let go of ALT
- **Ring 2** - Buffer rate
- **Ring 3** - Scrub friction
- **Ring 4** - Record feedback

The rings adjust the voice's buffer parameters whatever its source (ready for when it switches to a buffer), but are drawn dim unless the source is a buffer. Record duration and level are set on the screen.

On the **SCENES** page:

- **Ring 1** - Scene cursor, over the same 20 stops as E2: the sixteen slots (turning past slot 8 shows the second bank), then the four fields below them (10 ticks per stop). Moving it cancels a pending overwrite question, as E2 does
- **Ring 2** - Transition time
- **Ring 3** - Morph position, between scenes A and B (see [Modulation](modulation.md#morph))
- **Ring 4** - Morph scene B (20 ticks per scene)

On the **SETUP** page the rings are off and do nothing.

## Arc Button (2025 model)

The button runs the page's main action, on the pages that give it one (each page's own page under [Screen Controls](controls.md) says which):

- **MAIN** and **VOICE** - start or stop the selected voice
- **SEQ** - play or stop the patterns (nothing while a step editor is open)
- **LFO** - turn the selected LFO on or off
- **MOD** - on a routing (or in one), turn it on or off; on a macro or the bank row, show the next bank; on a recorder, press it (record, play, stop); anywhere else, turn scatter on or off
- **BUFFER** - record into the slot under the cursor, or stop
- **SCENES** - recall the slot under the cursor at once
- **FX** and **SETUP** - nothing

## LED Feedback

- Ring position shows the current parameter value, or the cursor's position on SEQ and SCENES
- MAIN: bright rings (level 15/12) for a running voice, dim (4/3) for a stopped one; ring 1 (density) always bright. The ALT rings at 12 for a running voice, 3 for a stopped one
- VOICE: the cursor row's ring at 15, the others at 12
- SEQ: step and level rings at 15, tempo and voice rings at 12; the step editor's at 15 while set, 4 while off
- FX: level 12; frequency and delay time follow their exponential curve
- LFO: depth rings bright (15) while the LFO runs, dim (4) when off; ring 4 at 12
- MOD: level 12; a routing's depth ring dim (4) while the routing is off or misses its source or destination
- BUFFER: rings bright (15) for a buffer-sourced voice, dim (4) otherwise; the ALT record feedback ring always at 12
- SCENES: level 12
