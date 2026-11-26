# Just Friends

A voice's notes can play Just Friends (the Mannequins module) over the ii bus. Part of the [IO page](../pages/io.md): two rows in the `voice` section. Back to [Screen Controls](../controls.md).

It is off by default: with the routes off Strata sends Just Friends nothing.

## What you need

- crow on the ii bus, and the `bus leader` row of IO's `ii` section set to `strata leads` (a rig setting), so that Strata leads the bus. A route does nothing while Strata does not lead, and its `jf` row then shows `[idle]` at its right.
- Just Friends' SPEED switch at sound (not shape). When Strata starts leading it sends `mode 1`, which picks Synthesis from that switch; with the switch at shape, Just Friends enters Geode instead. When Strata stops leading it sends `mode 0`.

## The settings

All eight are saved with a PSET; none is in a scene. Recalling a changed route applies it to the next note. A Just Friends note already playing finishes its own decay.

| Setting | Values | Default | What it does |
|---|---|---|---|
| jf (per voice; `jf out v1` to `jf out v7` in PARAMETERS > out ii) | off, on | off | the selected voice's notes play Just Friends |
| jf level | 0-10 V | 5 | the volume of a note at full velocity, in volts (a velocity of 0.5 plays half of it) |

## How notes play

- Each note is one `play_note` with its pitch in volts and its level. Strata sends note 60 as 0 V, one volt an octave, clamped to -5 to 5 V. Just-Type calls 0 V C3.
- Just Friends has six voices: a note takes a free one, and when all six sound it steals its oldest. A note's end sends nothing, so Just Friends shapes the note's length itself.

## Good to know

- Sources: the Just-Type manual (Just Friends' ii commands) and crow's `lua/ii/jf.lua`. Unverified on the device until the 4.0 hardware check.
