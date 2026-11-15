# ER-301 and TELEXo

Two Eurorack modules a voice can play over the ii bus. Part of the [IO page](../pages/io.md): their rows are in its `voice` section, under the selected voice. Back to [Screen Controls](../controls.md).

Both start off, and both send only while Strata leads the ii bus (the `ii bus` setting on IO, with crow as the bridge). Each plays one note at a time, the newest: when it ends while others still sound, the pitch goes to the newest left with no new trigger, and the gate goes low when the last one ends. This is unverified on the device until the 4.0 hardware check.

## ER-301

| Setting | Values | Default |
|---|---|---|
| er-301 | off, port 1 to 100 | off |

A voice with a port sends the note's pitch to that port's `SC.CV` unit (volts, one octave a volt, note 60 at 0 V, clamped to -10 to 10 V) and raises the port's `SC.TR` unit. Patch the ER-301's ii bus to crow's, and put an `SC.CV` and an `SC.TR` unit on the same port number in the chain you play.

## TELEXo

| Setting | Values | Default |
|---|---|---|
| txo | off, output 1 to 32, and a mode | off |
| txo attack | 1 to 10000 ms | 10 ms |
| txo decay | 1 to 10000 ms | 500 ms |

The `txo` row opens a list: the output (the 32 outputs span the TELEXo units on the bus, four each) and the mode.
- **pitch**: the output's cv is the note's pitch and its trigger the gate.
- **envelope**: the output's cv is the level (the velocity, up to 5 V), played through the output's envelope: Strata sets the envelope's attack and decay (the two rows below) whenever it starts leading, and whenever one changes.

All the settings are saved with a PSET and none is in a scene. Sources: crow's ii documents for the ER-301 and the TELEXo, and the TELEX README.
