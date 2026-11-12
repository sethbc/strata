# Modulation

Cross-modulation between voices, probability-based mutations, the global LFOs, the macros and scatter. Back to the [README](../../README.md).

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

**Where an LFO runs.** An LFO on one of a voice's five fast destinations, its grain pitch, buffer position, grain size, voice filter cutoff (`vfilt`) or level (`amp`), runs in the engine, smoothly and at up to 50 Hz; the LFO page marks its destination with `~` (`v3 pitch~`). Its depth on the cutoff moves the filter by up to five octaves either way at 100 %, and on the level from silence to double. Every other LFO runs in the script, at up to 10 Hz (a faster rate plays at 10 Hz, and the page shows `max`): it updates 48 times a second, whatever the tempo, and only sends a new value when it has moved by at least 1/1000 of the destination's range, so slow LFOs cost very little. On a frequency or another range that the encoder moves in octaves, that is 1/1000 of its octaves (8 cents on a voice's frequency), so a slow LFO glides as evenly at the low end as at the top. A clocked LFO in the engine is lined up with the clock once a bar and whenever the clock starts again. The random shapes draw their own values in the engine, so the screen's dot shows values of the same kind, not the same ones. The grid has no LFO controls: use the LFO page, the arc or PARAMETERS.

**From 3.3.** The LFO parameters have new names in 3.4. A PSET saved with 3.3 loads its LFO settings (the console prints `imported 3.3 LFO settings`, and the settings 3.3 did not have go to their defaults, LFOs 4-6 off), and so do 3.3's scenes; 3.3's random shape becomes s&h at twice the rate, so it changes value as often as it did. LFOs 4-6 start off.

## Macros

Sixteen macros (PARAMETERS > macros, `macro 1` ... `macro 16`) each turn up to eight settings at once with one control:
- **Targets** - each target moves between two ends of its own as the macro goes from 0 to 100 % (put the first end above the second to turn it around), along the setting's own scale, so a frequency moves in octaves. A target is any setting an LFO can move (a voice's main parameter follows its source, as for an LFO), or an LFO's rate or depth; never another macro or the morph, so a macro can never move itself
- **Moving a macro** - turn it, map a controller to it in PARAMETERS > MAP, or record it with a gesture recorder. It moves its targets up to 30 times a second, so a fast knob sweep never floods the engine; you see the targets' values change as it moves, and scenes store them
- **Scenes and the morph** - a scene stores each macro's value and its targets. A recall, a fade and the morph set the macro's value without moving its targets: the scene holds the targets' own values, so a setting you changed by hand after moving the macro comes back as you left it
- **An LFO on a macro** (the destinations `macro 1` ... `macro 16`) moves the macro's targets around their values, never the macro or the targets' settings themselves. It leaves a target that is an LFO's rate or depth alone (it would modulate itself); those follow the macro's own value only
- **Banks** - the macros come in four banks of four (1-4, 5-8, 9-12, 13-16); the MOD page, its arc rings and the grids show one bank at a time, the same one everywhere
- **Saving** - the targets are saved with each PSET (in a file beside it, `<pset>.macros.data`) and between sessions. A PSET loads each macro's value, its targets and the targets' own values as the PSET saved them, without the macros moving the targets. A PSET saved before 3.4 loads with no targets. A target this version does not know (from another release) is kept and saved again as it was, does nothing, and the console names it as it loads

## Scatter

Scatter (PARAMETERS > scatter) gives every unlocked voice slow, smooth random movement, each voice and each setting on its own:
- **Settings** - grain pitch and buffer position (on by default), grain size, the voice filter's cutoff and the level (off), each switched on and off on its own
- **Depth** - 0-100 % (default 10 %): at 100 % a setting wanders up to half its range either side of its value (the cutoff up to five octaves, the level from silence to double)
- **Rate** - 0.01-1 Hz (default 0.1 Hz): how fast it wanders
- **Lock** - a locked voice is left alone, as by the drift and the mutations
- Scatter runs in the engine, smoothly, and sends nothing while it plays. Scenes store its eight settings: the depth and the rate fade, the switches change at the end of a fade
