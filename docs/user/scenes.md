# Scenes and Automation

The scene system, the scene sequencer and how to compose with scenes. Back to the [README](../../README.md).

Strata includes a comprehensive scene system for longer-form composition and automation:
- **16 Scene Slots in two banks** - Save complete snapshots of all voices, patterns, and parameters, and name each slot
- **Disk Persistence** - Each scene you save is written to disk at once, and the scenes load on startup ([Saved scenes on disk](#saved-scenes-on-disk))
- **Instant or Smooth Recall** - Jump immediately or crossfade between scenes
- **Scene Sequencer** - Automatically progress through scenes for hands-free composition
- **Complete State Capture** - Scenes store voice parameters and sources, patterns, lock states, and global settings, including each LFO's state, shape, rate, depth, offset, phase, inputs and destination (not the audio in the sample buffers)
- **Grid Integration** - Dedicated scene page on grid for performance control
- **Visual Feedback** - `S1`-`S16` indicator shows current scene on screen

Perfect for creating structured ambient compositions with multiple movements or live performance setups with prepared sonic palettes. Scenes persist across script restarts, allowing you to build a library of sonic palettes.

## Saved scenes on disk

- Saving a scene (ALT+K3 on SCENES, or the grid's half-second hold) writes all sixteen slots, with their names, to `~/dust/data/strata/scenes.data` at once, so a scene is kept even if the norns restarts from maiden (`;restart`), crashes or loses power before the script exits. A power cut in the few seconds right after a save can still leave the file as it was before that save (the card has not finished writing it), never a damaged one. Saving the same scene again, or leaving the script with nothing new, writes nothing.
- The file is written to a temporary file first and put in place only when the whole write worked, so a full card or a power cut leaves the previous file whole, never an empty or cut-short one. If the write fails, the header says `S<n> not on disk` instead of `saved S<n>`: the scene is kept in memory, SETUP shows `scenes file not saved`, and the next save (or the exit) tries again.
- Loading scenes from disk (SETUP's `load scenes`, or PARAMETERS > load scenes from disk) replaces all sixteen slots with the file's. While a scene saved in this session is not on disk, the first press only asks (`K3 again: drop unsaved` on SETUP's hint row) and a second within 2 seconds loads. Otherwise one press loads, since the file already holds every saved scene.
- A file that cannot be read (damaged, or written by a newer Strata) is not loaded: the script starts with empty slots, the hint row says `scenes unreadable (SETUP)` for a few seconds, and SETUP names the copy it was kept as (`scenes.data.bak`, then `.bak.2` up to `.bak.9`, so an earlier copy is never replaced). A file from an older Strata is loaded and converted, and the first save keeps the original as `scenes.data.v<n>` (`scenes.data.v3` for 3.2's): renamed back to `scenes.data`, it is the file an older Strata reads.

## Using Scenes for Composition

**Building a Scene-Based Composition**:
1. Create your first sonic texture using voices, patterns, and parameters
2. Save it into a scene slot (scenes 1-16): on the [SCENES page](pages/scenes.md), pick a slot with E2 and press ALT+K3; or on a grid's scene page, hold a save key for half a second (row 3 on the [16×16](grid/256.md) and [16×8](grid/128h.md), column 3 on the [8×16](grid/128v.md); the 8×8 has no scene page)
3. Build a contrasting or complementary texture
4. Save it to another scene slot
5. Repeat until you have as many distinct scenes as you need (up to 16)

**From the screen**: the [SCENES page](pages/scenes.md) saves and recalls scenes without a grid. E2 picks a slot, K2 recalls it with the transition time, K3 recalls it at once, and ALT+K3 saves, flashing `saved S<n>` in the header once the scene is on disk (`saved S3 dusk` for a named slot; a slot that already holds a scene asks for a second ALT+K3 within 2 seconds). The same page sets the transition time, sequencer on/off, sequence length and scene duration.

**Banks and names**: the sixteen slots are two banks of eight, scenes 1-8 and 9-16. A bank is only a view: SCENES shows the bank of the slot under the cursor (ALT+E2 jumps from one bank to the other), the grids show all sixteen at once (the 8×16 down its columns), and the sequencer, recalls and saves work the same on every slot. ALT+K2 on SCENES names a slot (up to 12 characters, on an empty slot too); the name shows beside the slot and stays with it when you save a scene into it. Scenes saved by an older Strata (eight slots) load into slots 1-8, with slots 9-16 empty, and the old default names (`scene 1` and so on) are dropped.

**Manual Scene Performance** (on the SCENES page K3 recalls at once and K2 with the transition; the grid keys below are the 16×16's and 16×8's rows, the 8×16's columns 1 and 2):
- Press row 1 buttons for instant scene changes (good for rhythmic switching)
- Press row 2 buttons for smooth crossfades (good for ambient transitions). Saving into the scene a crossfade is heading for stores the sound as it is at that moment; the crossfade still ends on the scene as it was recalled
- A crossfade's scene shows as current (on the screen's `S1`-`S16`, the SCENES page and the grid) from its start, and blinks until the crossfade lands: it changes with each of the crossfade's 20 steps (every 0.1 s for a 2 s crossfade), then stays lit. A blinking scene is still on its way, so a save during it stores a half-faded sound. If the crossfade does not land (the sequencer cancels it, scenes are loaded from disk, or an error stops it), the scene before it is current again, since the crossfade's own scene was never fully applied. A recall that interrupts a crossfade makes its own scene current; if that recall fails too, the last scene that landed is current
- A crossfade to a scene that has an LFO off, while that LFO runs, fades the LFO out (its depth to 0, its rate and offset held), then switches it off with the scene's settings; an LFO the scene keeps on fades its depth, rate and offset toward the scene's
- Adjust transition time in PARAMETERS to control crossfade duration

**Automatic Scene Sequencing**:
- Set scene sequence length (how many scenes to cycle through). Shortened while a scene past the new end plays, the sequence wraps to scene 1
- Empty slots in the sequence are skipped at once: the next scene that holds one follows the last scene's duration, with no wait for the empty slot. A sequence with no scene in it waits on each slot for the scene duration
- Set scene duration (how long each scene plays)
- Set transition time (crossfade duration between scenes)
- Each scene plays for the scene duration or the transition time, whichever is longer, and the sequencer then waits for the transition to end, so the settings that switch at the end of a transition (voices on/off, sources, patterns, locks, grain envelope and mode, ...) always arrive. The wait is bounded: a transition that stops making progress (its next step or its end more than 1 s overdue) is canceled, with a console message, and the sequencer moves on. A slow but healthy transition is never cut short. Recalling a scene by hand still interrupts a running transition
- Start or stop the sequencer on the SCENES page, in PARAMETERS, or on a grid's scene page: row 5 column 1 on the 16×16 and 16×8, column 4 row 1 on the 8×16. If something goes wrong in the sequencer itself (an error, shown in maiden), it switches itself off, so the screen and grid show it stopped; switching it on again starts it from the start of the sequence
- Loading a PSET saved with the sequencer on, while the sequencer is off, starts it once the whole PSET has loaded, from scene 1, with the PSET's transition time, duration and length. A sequencer that is already running keeps its place
- Loading scenes from disk stops a running transition where it is. The current scene (`S1`-`S16`) stays marked only if the file holds the same scene in its slot; otherwise no scene is marked, since what plays is no longer that slot
- Watch `S1`-`S16` indicator on screen (bright = sequencer active)

**Creative Tips**:
- Use scenes to create song structure: intro → verse → chorus → bridge
- Combine with mutations: save some scenes with mutations on, others with mutations off
- Lock different voices in different scenes for evolving vs static sections
- Scenes remember pattern data - create rhythmic scenes and ambient scenes
