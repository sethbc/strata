# Scenes and Automation

The scene system, the scene sequencer and how to compose with scenes. Back to the [README](../../README.md).

Strata includes a comprehensive scene system for longer-form composition and automation:
- **8 Scene Slots** - Save complete snapshots of all voices, patterns, and parameters
- **Disk Persistence** - Scenes automatically save to disk and load on startup
- **Instant or Smooth Recall** - Jump immediately or crossfade between scenes
- **Scene Sequencer** - Automatically progress through scenes for hands-free composition
- **Complete State Capture** - Scenes store voice parameters and sources, patterns, lock states, and global settings, including each LFO's state, shape, rate, depth and destination (not the audio in the sample buffers)
- **Grid Integration** - Dedicated scene page on grid for performance control
- **Visual Feedback** - `S1`-`S8` indicator shows current scene on screen

Perfect for creating structured ambient compositions with multiple movements or live performance setups with prepared sonic palettes. Scenes persist across script restarts, allowing you to build a library of sonic palettes.

## Using Scenes for Composition

**Building a Scene-Based Composition**:
1. Create your first sonic texture using voices, patterns, and parameters
2. Navigate to grid page 3 (or use PARAMETERS menu)
3. Hold a row 3 key for half a second to save the scene (scenes 1-8)
4. Build a contrasting or complementary texture
5. Save to another scene slot
6. Repeat until you have 3-8 distinct scenes

**Manual Scene Performance**:
- Press row 1 buttons for instant scene changes (good for rhythmic switching)
- Press row 2 buttons for smooth crossfades (good for ambient transitions). Saving into the scene a crossfade is heading for stores the sound as it is at that moment; the crossfade still ends on the scene as it was recalled
- Adjust transition time in PARAMETERS to control crossfade duration

**Automatic Scene Sequencing**:
- Set scene sequence length (how many scenes to cycle through). Shortened while a scene past the new end plays, the sequence wraps to scene 1
- Set scene duration (how long each scene plays)
- Set transition time (crossfade duration between scenes)
- Each scene plays for the scene duration or the transition time, whichever is longer, and the sequencer then waits for the transition to end, so the settings that switch at the end of a transition (voices on/off, sources, patterns, locks, grain envelope and mode, ...) always arrive. The wait is bounded: a transition that stops making progress (its next step or its end more than 1 s overdue) is canceled, with a console message, and the sequencer moves on. A slow but healthy transition is never cut short. Recalling a scene by hand still interrupts a running transition
- Press row 5, column 1 to start/stop the sequencer
- Loading a PSET saved with the sequencer on, while the sequencer is off, starts it once the whole PSET has loaded, from scene 1, with the PSET's transition time, duration and length. A sequencer that is already running keeps its place
- Loading scenes from disk stops a running transition where it is
- Watch `S1`-`S8` indicator on screen (bright = sequencer active)

**Creative Tips**:
- Use scenes to create song structure: intro → verse → chorus → bridge
- Combine with mutations: save some scenes with mutations on, others with mutations off
- Lock different voices in different scenes for evolving vs static sections
- Scenes remember pattern data - create rhythmic scenes and ambient scenes
