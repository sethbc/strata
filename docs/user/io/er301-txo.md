# ER-301 and TELEXo

Two Eurorack modules a voice can play over the ii bus. Part of the [IO page](../pages/io.md): their rows are in its `voice` section, under the selected voice. Back to [Screen Controls](../controls.md).

Two voices on one port or output share it: the newest note of either sounds. Both start off, and both send only while Strata leads the ii bus (the `bus leader` row of IO's `ii` section set to `strata leads`, with crow as the bridge). While Strata does not lead the bus (no crow, `bus leader` at `off` or `teletype leads`), a voice's `er-301` row that names a port, and its `txo` row that names an output, show `[idle]` at their right: they play nothing then. Each plays one note at a time, the newest: when it ends while others still sound, the pitch goes to the newest left with no new trigger, and the gate goes low when the last one ends. A step's gate ends just before the next step, so consecutive steps retrigger; at very fast ratchets the low can fall in the same tick as the next high. This is unverified on the device until the 4.0 hardware check.

## ER-301

| Setting | Values | Default |
|---|---|---|
| er-301 (`v1 er-301 port` to `v7 er-301 port` in PARAMETERS > out ii) | off, port 1 to 100 | off |

A voice with a port sends the note's pitch to that port's `SC.CV` unit (volts, one octave a volt, note 60 at 0 V, clamped to -10 to 10 V) and raises the port's `SC.TR` unit. Patch the ER-301's ii bus to crow's, and put an `SC.CV` and an `SC.TR` unit on the same port number in the chain you play. Teletype's notes say the ER-301's ii connection needs a small hardware modification and a cable with two pins swapped; crow's documents do not repeat it, so check your unit before you rely on it.

Loading a PSET that changes or turns off a voice’s ER-301 port releases its held notes on the old port. A shared port stays high while another voice still holds a note there. New notes follow the recalled setting.

## TELEXo

| Setting | Values | Default |
|---|---|---|
| txo (`v1 txo output` and `v1 txo mode` to `v7` in PARAMETERS > out ii) | off, output 1 to 32, and a mode | off |
| txo attack | 1 to 10000 ms | 10 ms |
| txo decay | 1 to 10000 ms | 500 ms |

The `txo` row opens a list: the output (the 32 outputs span the TELEXo units on the bus, four each) and the mode.
- **pitch**: the output's cv is the note's pitch and its trigger the gate.
- **envelope**: the output's cv is the level (the velocity, up to 5 V), played through the output's envelope: Strata sets the envelope's attack and decay (the two rows below) whenever it starts leading, and whenever one changes.

When the last note on an output ends, its trigger goes low, and in envelope mode its envelope gate too (two messages). When the ii bus is busy, Strata retries the envelope setting as space opens up. When Strata gives up the bus it turns off active envelopes after sending gate offs, within the bus's release limit. Once crow is connected and Strata leads again, it checks every output it had active against the current routes. An output still needed in envelope mode gets the current attack and decay. An output whose last envelope voice switched to pitch or moved elsewhere has its envelope turned off. A silent PSET load also applies the recalled modes. A shared envelope stays active while any voice still needs it. All the settings are saved with a PSET and none is in a scene.

## Sources

Crow's ii documents for the ER-301 and the TELEXo, and the TELEX README. Unverified on the device until the 4.0 hardware check.
