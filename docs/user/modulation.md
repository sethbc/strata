# Modulation

Cross-modulation between voices, probability-based mutations and the global LFOs. Back to the [README](../../README.md).

## Cross-Modulation

Voices can modulate each other for evolving, interdependent textures:
- Each voice generates a modulation signal based on its audio output
- **Multi-Source Routing**: Each voice can be modulated by up to 3 different sources simultaneously
- Route any combination of voices to modulate another voice's amplitude and/or frequency
- Adjustable modulation depth per source for subtle or dramatic effects

## Probability-Based Mutations

Strata includes an optional mutation system for creating organic, evolving textures:
- **Probabilistic Evolution** - Each parameter has a chance to mutate at regular intervals
- **Adjustable Behavior** - Control mutation rate, probability, and amount via PARAMETERS menu
- **Smart Mutations** - Uses gaussian-like distribution for natural-sounding changes
- **Selective Application** - Only affects active, unlocked voices
- **Preserved Stability** - Amplitude and pan are never mutated to maintain voice balance
- **Visual Feedback** - `[M]` indicator appears on screen when mutations are enabled

The mutation system works alongside the per-voice drift and the global LFOs, creating multiple layers of organic movement. Combine with the lock feature to let some voices evolve while others remain stable.

## Global LFOs

Three LFOs, built on norns' own LFO library, can each modulate one parameter:
- **Shapes** - sine, tri, square, random, up, down
- **Rate** - free (a period from 0.1 s to 300 s) or clocked to the norns clock (the library's rates from 1/16 bar, a quarter beat, to 1024 bars)
- **Depth** - 0-100 %; at 100 % the LFO swings half the destination's range either side of its value
- **Destinations** - none, master density, tape drift, filter freq / res / mix, delay time / feedback / mix, reverb mix / size / damp, and for each voice: its main parameter (the one E3 adjusts: the synthesis parameter, or buffer position for a buffer-sourced voice, grain size for an input-sourced one), grain size, density, pitch, spread, buffer position, rate and scan; then each voice's input history (`v1 hist` ... `v7 hist`, [Voices and Grains](voices-and-grains.md)), its voice filter's cutoff (`vfilt`) and its delay and reverb sends (`dsend`, `rsend`, [Effects](effects.md))
- **Modulates around your setting** - an LFO never changes the parameter's value; it moves the sound around it, so turning the knob still sets the center. When an LFO is turned off, its depth reaches 0 or its destination changes, the parameter goes back to exactly its set value. Two LFOs on one destination add up

The fastest free rate is 10 Hz (the library's 0.1 s free period). Clocked rates follow the tempo: 1/16 bar is a quarter beat, so it is 8 Hz at 120 BPM and 20 Hz at 300 BPM. 20 Hz at any tempo would need the LFOs in the engine instead of Lua. Each LFO updates 48 times per beat (96 times a second at 120 BPM) and only sends a new value to the engine when it has moved by at least 1/1000 of the destination's range, so slow LFOs cost very little. On a frequency or another range that the encoder moves in octaves, that is 1/1000 of its octaves (8 cents on a voice's frequency), so a slow LFO glides as evenly at the low end as at the top. The grid has no LFO controls: use the LFO page, the arc or PARAMETERS.
