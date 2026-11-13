# Strata development decisions

The decisions taken during development, one file per release line. Each was taken during development without a design review, and lists what it costs if it was wrong. Reverse any of them in a normal pull request.

- [3.0](3.0.md): 3.0 (sample sources, FX, LFOs, MIDI, pages), 3.0.1 (minor findings) and 3.0.2 (review fixes).
- [3.1](3.1.md): playable from the norns alone.
- [3.2](3.2.md): the performance setting and one grain path.
- [3.3](3.3.md): buffers as instruments and the review fixes, with 3.3.1 (the fix release) and 3.3.2 (page randomize).
- [3.4](3.4.md): modulation and sequencing. Its rulings are numbered; code comments cite them by number.
- [3.5](3.5.md): polyphony and MPE. Its fifty rulings keep the build's numbers, which code comments cite.

A new release adds its file here, `docs/decisions/<release>.md`, and its line above. A fix release's decisions go in its release line's file.
