# Modulation

Cross-modulation between voices, probability-based mutations, the global LFOs, the macros, the morph, scatter, the gesture recorders and the modulation matrix. Back to the [README](../../README.md).

The [MOD](pages/mod.md) page shows the macros, the morph, scatter, the recorders, the LFOs and the matrix in one list, with their arc rings ([Monome Arc](arc.md)). On [MAIN](pages/main.md), a `~` after the selected voice's name says the engine is moving it: an LFO in the engine, scatter or a routing.

## Cross-Modulation

Voices can modulate each other for evolving, interdependent textures:
- Each voice generates a modulation signal based on its audio output
- **Multi-Source Routing**: Each voice can be modulated by up to 3 different sources simultaneously
- Route any combination of voices to modulate another voice's amplitude and/or frequency
- Adjustable modulation depth per source for subtle or dramatic effects

## Probability-Based Mutations

Strata includes an optional mutation system for creating organic, evolving textures:
- **Probabilistic Evolution** - Each parameter has a chance to mutate at regular intervals
- **Adjustable Behavior** - Control mutation rate, probability, and amount on SETUP (the `mutations`, `mutation rate`, `mutation prob` and `mutation amt` fields), or in the PARAMETERS menu
- **Smart Mutations** - Uses gaussian-like distribution for natural-sounding changes
- **Selective Application** - Only affects running, unlocked voices: a stopped voice keeps every value until it starts, and so does a locked one
- **Preserved Stability** - Amplitude and pan are never mutated to maintain voice balance, nor are the voice's source, its grain envelope and mode, its cross-modulation routing and amounts, or its freeze, variation, loop and voice mix settings
- **On the scale** - A voice that quantizes to the scale mutates its pitch from tone to tone of the scale
- **Visual Feedback** - `[M]` indicator appears in the header when mutations are enabled (on SEQ the tempo takes its place)

The mutation system works alongside the per-voice drift (which also moves only running, unlocked voices) and the global LFOs, creating multiple layers of organic movement. Combine with the lock feature to let some voices evolve while others remain stable.

## Global LFOs

Six LFOs can each modulate one parameter:
- **Shapes** - sine, tri, square, up, down, s&h (a new random value each cycle, held), smooth (a glide from one random value to the next over each cycle) and drunk (a random walk: each cycle moves up to a fifth of the range from where the last one ended)
- **Rate** - free (0.003-50 Hz, so a cycle can last over five minutes) or clocked to the norns clock (the rates from 1/16 bar, a quarter beat, to 1024 bars), following the tempo, Link and MIDI clock
- **Depth** - 0-100 %; at 100 % the LFO swings half the destination's range either side of its value
- **Offset** - moves the swing up or down by a percentage of the destination's range; **phase** sets where the LFO starts when it is turned on
- **Destinations** - none, master density, tape drift, filter freq / res / mix, delay time / feedback / mix, reverb mix / size / damp, and for each voice: its main parameter (the one E3 adjusts: the synthesis parameter, or buffer position for a buffer-sourced voice, grain size for an input-sourced one), grain size, density, pitch, spread, buffer position, rate and scan; then each voice's input history (`v1 hist` ... `v7 hist`, [Voices and Grains](voices-and-grains.md)), its voice filter's cutoff (`vfilt`), its delay and reverb sends (`dsend`, `rsend`, [Effects](effects.md)) and its level (`amp`)
- **Modulates around your setting** - an LFO never changes the parameter's value; it moves the sound around it, so turning the knob still sets the center. When an LFO is turned off, its depth reaches 0 or its destination changes, the parameter goes back to exactly its set value. Two LFOs on one destination add up

**LFOs moving LFOs.** Each LFO's rate and depth can follow a lower-numbered LFO (LFO 3 can follow LFO 1 or 2; LFO 1 follows none). The rate input at +100 % takes the rate up to two octaves up and down with the other LFO's swing; the depth input at +100 % takes the depth from 0 to double. What an input reads is the other LFO's shape alone, before its own depth, so an LFO with no destination makes a good modulator. An LFO that is off moves nothing.

**Where an LFO runs.** An LFO on one of a voice's five fast destinations, its grain pitch, buffer position, grain size, voice filter cutoff (`vfilt`) or level (`amp`), runs in the engine, smoothly and at up to 50 Hz; the LFO page marks its destination with `~` (`v3 pitch~`). Its depth on the cutoff moves the filter by up to five octaves either way at 100 %, and on the level from silence to double. The filter smooths the cutoff, so a fast, deep LFO on it swings less than its depth says, the more so the faster and deeper it is. Every other LFO runs in the script, at up to 10 Hz (a faster rate plays at 10 Hz, and the page shows `max`): it updates 48 times a second, whatever the tempo, and only sends a new value when it has moved by at least 1/1000 of the destination's range, so slow LFOs cost very little. On a frequency or another range that the encoder moves in octaves, that is 1/1000 of its octaves (8 cents on a voice's frequency), so a slow LFO glides as evenly at the low end as at the top. A clocked LFO in the engine is lined up with the clock once a bar and whenever the clock starts again. The random shapes draw their own values in the engine, so the screen's dot shows values of the same kind, not the same ones. The grid has no LFO controls: use the LFO page, the arc or PARAMETERS.

**From 3.3.** The LFO parameters have new names in 3.4. A PSET saved with 3.3 loads its LFO settings (the console prints `imported 3.3 LFO settings`, and the settings 3.3 did not have go to their defaults, LFOs 4-6 off), and so do 3.3's scenes; 3.3's random shape becomes s&h at twice the rate, so it changes value as often as it did. LFOs 4-6 start off.

## Macros

Sixteen macros (PARAMETERS > macros, `macro 1` ... `macro 16`) each turn up to eight settings at once with one control:
- **Targets** - each target moves between two ends of its own as the macro goes from 0 to 100 % (put the first end above the second to turn it around), along the setting's own scale, so a frequency moves in octaves. A target is any setting an LFO can move (a voice's main parameter follows its source, as for an LFO), or an LFO's rate or depth, or a matrix routing's depth; never another macro or the morph, so a macro can never move itself
- **Moving a macro** - turn it, map a controller to it in PARAMETERS > MAP, or record it with a gesture recorder. It moves its targets up to 30 times a second, so a fast knob sweep never floods the engine; you see the targets' values change as it moves, and scenes store them
- **Scenes and the morph** - a scene stores each macro's value and its targets. A recall, a fade and the morph set the macro's value without moving its targets: the scene holds the targets' own values, so a setting you changed by hand after moving the macro comes back as you left it
- **An LFO on a macro** (the destinations `macro 1` ... `macro 16`) moves the macro's targets around their values, never the macro or the targets' settings themselves. It leaves a target that is an LFO's rate or depth alone (it would modulate itself); those follow the macro's own value only
- **Banks** - the macros come in four banks of four (1-4, 5-8, 9-12, 13-16); the MOD page, its arc rings and the grids show one bank at a time, the same one everywhere
- **On the MOD page** - each macro of the shown bank is a row with its first target and its value; K3 shows its eight targets, where E3 picks each target and its two ends (1 % a step, ALT+E3 0.1 %) and ALT+K3 learns the next setting you touch. The arc's rings on MOD are the shown bank's four macros
- **Saving** - the targets are saved with each PSET (in a file beside it, `<pset>.macros.data`) and between sessions. A PSET loads each macro's value, its targets and the targets' own values as the PSET saved them, without the macros moving the targets. A PSET saved before 3.4 loads with no targets. A target this version does not know (from another release) is kept and saved again as it was, does nothing, and the console names it as it loads

## Morph

The morph (PARAMETERS > morph) moves the sound between two saved scenes, A and B (`morph A`, `morph B`, any of the sixteen), with one control, `morph`: at 0 % the sound is scene A's, at 100 % scene B's, and in between each continuous setting is that far from A's value to B's. Settings that cannot blend (sources, switches, patterns, the routings) take A's below the middle and B's above it, switching at 52 % on the way up and 48 % on the way down, so a hand resting on the middle doesn't flicker. Unlike a fade it never ends in a recall: the morph writes the settings, which you can save as a new scene, and the header shows no scene meanwhile. It moves up to ten times a second, so it can be swept fast. An empty scene at either end makes the morph do nothing (the header says `S5 empty`), unless scenes C and D below leave two to blend.

**Four scenes on two axes (the XY morph).** The morph has a second axis, `morph y` (0-100 %, default 0), and two more scenes, C and D (`morph C`, `morph D`, scenes 3 and 4 by default). Think of a square: A at the bottom left, B at the bottom right, C at the top left, D at the top right; `morph` moves left to right and `morph y` bottom to top. Each continuous setting is a blend of the four scenes, each weighted by how near the position is to its corner, so the middle of the square is a quarter of each. Settings that cannot blend take the nearest corner's, and change to another corner only once the position is clearly nearer to it (its weight leads by 4 %), so the middle never flickers. On an edge of the square only the edge's two scenes count, so at `morph y` 0 % the morph is exactly the morph between A and B above, setting for setting: a setting A and B agree on is left as you set it by hand, whatever C and D hold, and leaving the second axis alone changes nothing. Inside the square all four count. An empty scene in a corner is left out: the scenes in the other corners share its weight. With fewer than two saved scenes in the corners the morph does nothing (the header names the first empty one). A routing that differs between corners fades to 0 between them and switches where the corner changes, as in a fade; corners that hold the same routing blend its depth and never fade it between them.

On the [MOD](pages/mod.md) page, `A`, `B`, `C` and `D` pick the scenes (with their names), `morph` sets the position across and `y` up; on SCENES the arc's ring 3 sweeps the morph and ring 4 steps scene B, and on MOD the same with K1 held (rings 1 and 4). The arc has no ring for `y`: move it from the screen, MIDI, a gesture recorder or the 16x16 grid's pad ([16x16 grid](grid/256.md)), which sets both axes with one press. Scenes do not store the morph's settings; a PSET does.

## Scatter

Scatter (PARAMETERS > scatter) gives every unlocked voice slow, smooth random movement, each voice and each setting on its own:
- **Settings** - grain pitch and buffer position (on by default), grain size, the voice filter's cutoff and the level (off), each switched on and off on its own
- **Depth** - 0-100 % (default 10 %): at 100 % a setting wanders up to half its range either side of its value (the cutoff up to five octaves, the level from silence to double)
- **Rate** - 0.01-1 Hz (default 0.1 Hz): how fast it wanders
- **Lock** - a locked voice is left alone, as by the drift and the mutations
- Scatter runs in the engine, smoothly, and sends nothing while it plays. Scenes store its eight settings: the depth and the rate fade, the switches change at the end of a fade
- **On the MOD page** - its eight settings are rows (K3 or E3 switches one), and a quick ALT+K2 there draws a new depth (0-30 %) and rate (0.02-0.5 Hz), undone by another quick ALT+K2 within 5 seconds. With K1 held, the arc's rings 2 and 3 on MOD are its depth and rate, and on MOD the arc's button turns scatter on and off (on a row whose button does nothing else)

## Gesture Recorders

Four recorders (`G1`-`G4` on the [MOD](pages/mod.md) page) record your hand moves of continuous settings and play them back as a loop:
- **Record** - press K3 on an empty recorder's row (or the arc's button there): it records from your first move, so a silent lead-in isn't part of the loop. Moves of encoders, arc rings and grid faders are recorded as the values they reach (the macros and the morph included); options, switches, sources, scene recalls, LFOs, the drift and mutations never are
- **Play, stop** - press again to play the loop (a loop kept to the beat or bar starts on the next one), again to stop it, again to play it again. One recorder records at a time: starting another ends the recording, which then plays
- **Overdub** - ALT+K3 on a playing recorder adds new moves into the loop as it plays, until you press ALT+K3 again
- **Clear** - hold ALT+K2 on its row for half a second (the hint says `K2:clear`) and let go
- **Timing** - E3 on its row sets its quantize: free (as you played it) or kept to the beat or the bar of the norns clock (see [Parameters](params.md))
- A recorder holds up to 1024 moves or 10 minutes. The row shows `rec 3.2 s` while recording, `play 2 bars` or `play 5.0 s` while playing, `stop 5.0 s` stopped. Its loop's place (0-100 %) is a modulation source the matrix can route

## Modulation Matrix

Sixteen routings (`R1`-`R16` on the [MOD](pages/mod.md) page), each from one modulation source to one setting, with a depth from −100 to +100 %:
- **Sources** - the six LFOs (`L1`-`L6`, each at its own shape before its depth, so an LFO with no destination of its own makes a good modulator), the sixteen macros (`M1`-`M16`), the four recorders' loop places (`G1`-`G4`), the input level (`IN`) and the notes' pressure and slide (`PRES`, `SLID`, `PR1`-`PR7`, `SL1`-`SL7`: [Expression](#expression)). An LFO swings both ways around the setting; a macro, a recorder, the input and the notes only add, from 0
- **Destinations** - any setting an LFO can move (a voice's main parameter follows its source), never a macro. At 100 % from an LFO a routing swings half the destination's range either side of your value, as the LFO itself would at full depth
- **Around your setting** - like the LFOs, a routing moves the sound around the value you set and never changes it. Routings, LFOs and an LFO on a macro on the same setting add up before the setting's range limits them, so +100 % and −100 % cancel
- **In the engine** - a routing to one of a voice's grain pitch, buffer position, grain size, voice filter cutoff or level is added in the engine (the destination shows `~`), at the script's update rate (24 to 48 times a second); for the smoothest fast movement put the LFO on that setting itself
- **Editing** - K3 on a routing's row shows its source, destination, depth and on/off; E3 changes each, and a routing that gets both a source and a destination at 0 % starts at 25 %, so you hear it. ALT+K3 on its destination learns the next setting you touch. ALT+K3 on a row, or K3 in the routing, turns it on or off; ALT+K2 held clears it. A quick ALT+K2 in the matrix draws a new depth for every routing with a source and a destination (−50 to +50 %), undone by another quick press within 5 seconds
- **Arc** - with the cursor in the matrix, the rings are the depths of the four routings around it (R1-R4, R5-R8, ...), filled from the top both ways, and the button turns the cursor's routing on or off; in a routing, ring 1 is its depth and rings 2-4 step its source, its destination and the routing shown
- **Saving** - the depths and on/offs are parameters (PSETs, scenes, MIDI mapping, macros can move a depth); the sources and destinations are saved with each PSET (in a file beside it, `<pset>.matrix.data`), in scenes and between sessions. A routing whose source or destination is from another release is kept, drawn dim and does nothing

## Expression

Each note a voice plays can carry its own pressure and slide: an MPE controller's channel pressure and its CC74 slide (a LinnStrument's Y, an Osmose's or an Exquis's), or a keyboard's aftertouch. Each voice maps the two to a target of its own, on the `notes` section of [VOICE](pages/voice.md): `press target` and `press depth` for pressure, `slide target` and `slide depth` for slide, each depth from -100 to +100 % (a negative depth turns the move around).

| target | what it moves | where |
|---|---|---|
| `amp` | the note's level, as a swell above your setting: full pressure at +100 % doubles it (+6 dB), no pressure leaves it as set. It is the default for pressure, so a keyboard's aftertouch swells its notes; `off` plays it as 3.4 did | each note |
| `level` | pressure: the note's level, as its loudness: at +100 % a note is silent until pressed, and full pressure is your setting. A note that has sent no pressure yet plays at your setting. Slide on `level` acts as on `amp`, since a slide starts at 0 with every touch | each note |
| `main` | a synth voice's expression control (the Resonator's rq, FM's index, Folder's fold, Sub's drift, Pulse's width, Karplus's decay, Ring's ratio), the position on a buffer voice, the grain size on an input voice | each note |
| `size` | the grain size | each note on a buffer or input voice, the whole voice on a synth voice |
| `position` | the buffer position | each note, on a buffer voice only (any other voice ignores it) |
| `density` | the grain density | the whole voice |
| `cutoff` | the voice filter's cutoff, by up to five octaves each way | the whole voice |

- **Slide is measured from where the touch began**, so every note starts on your sound whatever its controller sends first. Pressure is read as it is
- **The defaults** are pressure on `amp` at +100 % and slide on `main` at +50 %: nothing changes until a controller sends pressure or slide
- **Two on one target** multiply (`amp`, `level`) or add (the others)
- **A whole-voice target** (density, cutoff, a synth voice's size) follows the note pressed or slid furthest, so a soft finger added or lifted changes nothing. Like the LFOs and the matrix, it moves the sound around your setting and never changes it
- **A frozen synth voice** plays its notes from the frozen sound: `size` acts per note there, and `main` does nothing
- **Latch** - a note held after its key lifts keeps the highest pressure it reached and its last slide
- **Modulation sources** - `PRES` and `SLID` are the largest pressure and slide (as the controller sends it, not from the touch's start) among every voice's held notes, and `PR1`-`PR7` and `SL1`-`SL7` each voice's, 0 with no note held. They are listed last on [MOD](pages/mod.md); a voice's pair shows there while it holds a note that has sent pressure or slide, and a routing can choose any of them at any time
- Scenes and PSETs keep the four settings per voice; a scene saved before 3.5 recalls pressure on `amp` and slide on `main`, which change nothing until expression arrives
