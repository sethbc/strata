# Monome Arc

Using a monome arc for hands-on control with LED feedback. Back to the [README](../../README.md).

Strata supports the monome arc controller for hands-on parameter control with visual LED feedback. Strata follows one arc, on whichever arc port it is assigned to (SYSTEM > DEVICES > ARC). If a second arc is plugged in while one is connected, it is ignored; unplugging the connected arc moves Strata to the other one.

## Arc Encoders

The rings control the current screen page. Every ring that sets a value sweeps its parameter's whole range in half a turn (512 of the arc's 1024 ticks per revolution), following the parameter's curve (frequency, delay time and buffer rate are exponential, so each half of the sweep covers as much of the curve). The exceptions are the LFO page's depth rings (10 ticks per percent) and clocked rate (20 ticks per rate). On the **MAIN** page:

- **Ring 1** - Master density (0.1 to 2.0)
- **Ring 2** - Selected voice's main parameter (follows E3 mapping: buffer position for a buffer-sourced voice, grain size for an input-sourced one)
- **Ring 3** - Grain size for selected voice
- **Ring 4** - Grain density for selected voice

On the **FX** page:

- **Ring 1** - Filter frequency
- **Ring 2** - Filter resonance
- **Ring 3** - Delay time
- **Ring 4** - Delay mix

On the **BUFFER** page:

- **Ring 1** - Selected voice's buffer position
- **Ring 2** - Selected voice's buffer rate
- **Ring 3** - Record duration
- **Ring 4** - Record level

Rings 1 and 2 adjust the voice's buffer parameters whatever its source (ready for when it switches to a buffer), but are drawn dim unless the source is a buffer.

On the **LFO** page:

- **Rings 1-3** - Depth of LFO 1-3 (10 ticks per percent; bright while the LFO runs)
- **Ring 4** - Period of the LFO selected on the page: the free period, or the clocked rate when its mode is clocked (part-turns toward the next rate are forgotten when you select another LFO or change its mode)

On the **SETUP** page, and for now on the placeholder **VOICE**, **SEQ** and **SCENES** pages, the rings are off and do nothing.

## Arc Button (2025 model)

- **Button** - On the MAIN page, same as K3 (start the voice if it is off, otherwise lock/unlock it); does nothing on the other pages

## LED Feedback

- Ring position shows the current parameter value
- MAIN: bright rings (level 15/12) for a running voice, dim (4/3) for a stopped one
- FX: level 12; frequency and delay time follow their exponential curve
- BUFFER: rings 1-2 bright (15) for a buffer-sourced voice, dim (4) otherwise; rings 3-4 at 12
- LFO: depth rings bright (15) while the LFO runs, dim (4) when off; ring 4 at 12
