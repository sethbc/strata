# Modulators

The modulation sources 3.7 adds: four random sequences. Like the LFOs, the macros and the recorders, each is a source for the [modulation matrix](modulation.md#modulation-matrix): a routing moves any setting an LFO can move by the sequence's value times its depth. Back to the [README](../../README.md).

## Random Sequences

Four sequences, **RS1** to **RS4**, each a row of sixteen values between -1 and 1. The first `length` of them play in order, one per step, and repeat: a stepped pattern, like a sample and hold that comes back around.

- **Clock**: each sequence steps on its own clock. A division of the norns clock's tempo (`1/32` to `1 bar`, triplets and dotted values among them; `1/8` by default) steps it on the beat, with the tempo, Link and MIDI clock. A voice (`voice 1` to `voice 7`) steps it at each of that voice's hits: each step the sequencer plays on it (a chord step is one), each MIDI note it plays, and its start. A clock that jumps ahead (a transport start, a tempo change) steps the sequence once, not once per division it skipped.
- **Length** (2 to 16, default 8): how many of the sixteen values play. A shorter length keeps the values past it, and a longer one plays them again.
- **Drift** (0 to 100 %, default 0): at each step, the chance that the value just played is replaced by a new random one. At 0 the sequence is a fixed loop you can program by hand; at 100 every value is new as it plays; in between, the pattern wanders slowly.
- **New**: draws all sixteen values again.

### On MOD

The [MOD](pages/mod.md) page lists the four under **sequences**, each with its clock and where it is in its loop (`RS1  1/8 3/8`: on eighth notes, the third of eight). K3 on a sequence's row opens its settings:

```
RS1
length                         8
drift                         0%
clock                        1/8
new
v1                         0.250
K2:back E2:row E3:edit
```

- **E2** - Move between the rows: `length`, `drift`, `clock`, `new`, then one row per value in play (`v1` to `v8` at the default length)
- **E3** - Change the row: the length, the drift, the clock, or a value, 0.01 a detent (**ALT+E3** 0.001)
- **K3** - On `new`, draw all sixteen values again
- **K2** - Back to the list

To use a sequence, set a matrix routing's source to it (`RS1` to `RS4`) and choose its destination and depth.

### What is saved

The settings (length, drift, clock) are parameters, in the PARAMETERS menu's **random sequences** group, saved with each PSET. The values are saved with each PSET too (in a file beside it, `<pset>.sequences.data`), in every scene (a recall sets them at the end of its fade) and between sessions. The very first time Strata starts with random sequences, their values are drawn at random; a scene or a PSET saved before them sets every value to 0.
