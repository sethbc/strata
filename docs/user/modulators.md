# Modulators

The modulation sources 3.7 adds: four random sequences and an envelope per voice. Like the LFOs, the macros and the recorders, each is a source for the [modulation matrix](modulation.md#modulation-matrix): a routing moves any setting an LFO can move by the source's value times its depth. Back to the [README](../../README.md).

## Random Sequences

Four sequences, **RS1** to **RS4**, each a row of sixteen values between -1 and 1. The first `length` of them play in order, one per step, and repeat: a stepped pattern, like a sample and hold that comes back around.

- **Clock**: each sequence steps on its own clock. A division of the norns clock's tempo (`1/32` to `1 bar`, triplets and dotted values among them; `1/8` by default) steps it on the beat, with the tempo, Link and MIDI clock. A voice (`voice 1` to `voice 7`) steps it at each of that voice's hits: each step the sequencer plays on it (a chord step is one), each MIDI note it plays, and its start. A clock that jumps ahead (a transport start, a tempo change) steps the sequence once, not once per division it skipped.
- **Length** (2 to 16, default 8): how many of the sixteen values play. A shorter length keeps the values past it, and a longer one plays them again.
- **Drift** (0 to 100 %, default 0): at each step, the chance that the value just played is replaced by a new random one. At 0 the sequence is a fixed loop you can program by hand; at 100 every value is new as it plays; in between, the pattern wanders slowly.
- **New**: draws all sixteen values again. Within 5 seconds a quick ALT+K2 on MOD, on the sequence's row or in its settings, brings the old values back; editing one of its values ends the undo.

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
- **K3** - On `new`, draw all sixteen values again (a quick ALT+K2 within 5 seconds brings the old ones back)
- **K2** - Back to the list

To use a sequence, set a matrix routing's source to it (`RS1` to `RS4`) and choose its destination and depth.

### What is saved

The settings (length, drift, clock) are parameters, in the PARAMETERS menu's **random sequences** group, saved with each PSET. If a PSET changes a sequence’s clock to a tempo division, the sequence holds its step on the first clock reading and advances at the next division boundary. Recalling the same division keeps its timing. The values are saved with each PSET too (in a file beside it, `<pset>.sequences.data`), in every scene (a recall sets them at the end of its fade) and between sessions. The very first time Strata starts with random sequences, their values are drawn at random and kept; a scene or a PSET saved before them sets every value to 0.

Between sessions, the values are written half a second after each value you edit, each `new`, a scene recall and a PSET load, and again when you leave Strata cleanly (SLEEP, or loading another script). What drift changes is written only then: if the power is cut, the drift since the last write is lost.

## Envelopes

Each voice has one envelope, **EN1** to **EN7**, fired by that voice's own hits: each step the sequencer plays on it (a chord step is one), each MIDI note it plays, and its start. It rises from where it is to 1 over the **attack**, falls to the **sustain** level over the **decay**, stays there for the hit's hold, then falls to 0 over the **release**:

```
 1 |    /\
   |   /  \______
 s |  /          \
 0 |_/            \____
     a   d   hold   r
```

- **Attack**, **decay** and **release**: 1 ms to 10 s (5 ms, 200 ms and 200 ms by default).
- **Sustain**: 0 to 1 (0 by default). At 0 the envelope is an attack and a decay, whatever the hold.
- **The hold** is the hit's gate length: on a gated voice (its step mode gate, or pulse with a step while the patterns play), the step's gate (a step's own gate length, or the voice's); on a voice that is not gated, none, so the release follows the decay. A long step gives a long envelope.
- **Curve** (-8 to 8, -4 by default) bends all three slopes: below 0 a slope moves fast first and then slowly, above 0 the other way, at 0 it is straight.
- **Loop** (off by default): on, the envelope starts again each time it ends, an LFO of its own shape that runs whether or not its voice plays; a hit still restarts it. Turned off, it finishes the cycle it is in.
- A new hit starts the attack from the level the envelope is at, so quick hits never jump down to 0.
- With the loop off, an envelope that has ended stays at 0 until its next hit: lengthening its times after it ended, by hand, from a scene or from a PSET, does not bring it back.

The envelope goes from 0 to 1: a routing's depth sets how far and in which direction it moves its destination.

### Fast and slow destinations

Routed to one of a voice's fast settings (pitch, position, size, cutoff and level, the ones an LFO moves inside the engine), the envelope runs inside the engine, exactly and at once, however short its attack: a 5 ms attack on a voice's cutoff is a real pluck. Routed to any other setting, Strata follows it about 48 times a second, which is exact for slow envelopes and coarse for fast ones: an envelope routed so, with its attack or its decay shown under 50 ms (`49ms` or less), shows a `~` before its times on MOD (`EN1  ~5ms 200ms`).

### On MOD

The [MOD](pages/mod.md) page lists the seven under **envelopes**, each with its attack and decay (`EN3  5ms 200ms`). K3 on an envelope's row opens its settings: `attack`, `decay`, `sustain`, `release`, `curve` and `loop`, E2 to pick one and E3 to change it (**ALT+E3** in finer steps); K2 goes back to the list. To use an envelope, set a matrix routing's source to it (`EN1` to `EN7`) and choose its destination and depth.

### What is saved

The six settings are parameters, in each voice's extras in the PARAMETERS menu (`env attack` to `env loop`, after the bookmarks), saved with each PSET and in every scene: a scene fades the times, the sustain and the curve, and switches the loop at the end of its fade. A scene saved before the envelopes sets each to its default.
