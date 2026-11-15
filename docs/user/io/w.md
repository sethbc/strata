# W/ (synth and tape)

Whimsical Raps' W/ over the ii bus: W/ synth plays a voice's notes, and W/ tape's transport runs from the [IO page](../pages/io.md). Back to [Screen Controls](../controls.md).

Both need the ii bus to be Strata's (the ii bus setting on IO) and a crow connected. With the bus off, or led by a Teletype, Strata sends W/ nothing.

A W/ runs one engine at a time (Tape, Delay or Synth) and you switch engines from its panel. Strata talks to the engine by its ii address, so the synth rows work while W/ runs Synth and the tape rows while it runs Tape.

## W/ synth

Each voice has a `w/ syn` toggle (off by default) and there is one `w/ level` (0 to 10 V, default 5), all on the `voice` section of IO and saved with a PSET. A note on a routed voice sends one note: its pitch in volts (C4 is 0 V, 1 V per octave, held to -5 to 5 V) and its velocity scaled by the level. W/ synth has four voices (2-operator FM) in AR mode, and ends its notes itself, so Strata sends nothing at a note's end. Strata puts W/ in AR mode with four voices when the bus becomes Strata's.

## W/ tape

The `w/ tape` section has six rows. Each press sends one command and the row shows what was last sent, or `-` before any:

| Row | Press sends | Shows |
|---|---|---|
| record | record on, then off, alternately | on, off |
| play | play on, then off | on, off |
| reverse | reverse | sent |
| loop start | loop start at the current time | sent |
| loop end | loop end at the current time | sent |
| loop | loop on, then off | on, off |

While the bus is not Strata's a press sends nothing, flashes `ii bus is not strata's`, and the section shows `[--]`.

## Good to know

- Strata cannot read W/'s state, so a row shows only what Strata sent. If you change W/ from its panel the rows can disagree with it.
- Sources: the W/ wiki (github.com/whimsicalraps/wslash/wiki) and crow's `lua/ii/wsyn.lua` and `wtape.lua`.
- Unverified on the device until the 4.0 hardware check.
