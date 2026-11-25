# Strata development decisions

The decisions taken during development, one file per release line. Each was taken during development without a design review, and lists what it costs if it was wrong. Reverse any of them in a normal pull request.

- [3.0](3.0.md): 3.0 (sample sources, FX, LFOs, MIDI, pages), 3.0.1 (minor findings) and 3.0.2 (review fixes).
- [3.1](3.1.md): playable from the norns alone.
- [3.2](3.2.md): the performance setting and one grain path.
- [3.3](3.3.md): buffers as instruments and the review fixes, with 3.3.1 (the fix release) and 3.3.2 (page randomize).
- [3.4](3.4.md): modulation and sequencing. Its rulings are numbered; code comments cite them by number.
- [3.5](3.5.md): polyphony and MPE. Its fifty-nine rulings keep the build's numbers, which code comments cite.
- [3.6](3.6.md): integration. Its rulings come in two series that keep their numbers: the plan's thirty-three, cited as plan ruling N, and the build's fifty-two, cited as build ruling N.
- [3.7](3.7.md): rhythm (slices, scan modes, a file's settings, trig conditions, the delay on the beat, envelopes, random sequences). The design's twenty-four decisions by number; the plan's thirty-seven rulings, cited as plan ruling N; the build's rulings unnumbered, but for the ii queue fix's five, numbered in their package.
- [3.8](3.8.md): the groundwork before 3.8 (the value table, LFO home routings, one stepper, scenes with the PSET, three revisions and their fixes): the maintainer's decisions, the plan review's rulings, the plan's thirty-seven rulings by number and the build's rulings unnumbered. Then sound (voice types, the grain, voices as sources, tuning, plain sends, the delay's freeze, shimmer, voice presets, the grids as panes, factory sets): the design's twenty-three decisions by number and the maintainer's decisions of the build; the plan's sixty-four rulings, cited as plan ruling N (or 3.8 ruling N); the build's rulings, unnumbered but for the pre-flight's P1-P20 and D2-D6.
- [3.9](3.9.md): the state machines made explicit, 3.9's first part: the maintainer's decisions, before and during the build; the plan's sixteen rulings, cited as plan ruling N; the build's rulings that bind more than one package, B1-B11; and the build's rulings by wave, unnumbered. Then the grid's sequencer reworked, its second part: the maintainer's decisions, the design's twenty-four calls by number, the plan review's rulings by id (G1-G9, then each package's), and the build's rulings by wave, unnumbered.

A new release adds its file here, `docs/decisions/<release>.md`, and its line above. A fix release's decisions go in its release line's file.
