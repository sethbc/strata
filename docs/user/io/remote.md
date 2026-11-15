# Remote grids and arcs

A monome grid or arc in iii mode, or a MIDI grid such as a Launchpad through the midigrid mod, works as one more of Strata's grids or as its arc. Back to [IO](../pages/io.md).

Built from iii v1.1.2's documents and source (monome's iii code page, monome.org/docs/iii/code, and the iii, iii-grid-one, iii-grid-zero, iii-grid-2022 and iii-arc repositories) and from midigrid's `master` branch (github.com/jaggednz/midigrid). Unverified on the device until the 4.0 hardware check.

## Which grids and arcs run iii

- **Grids** from 2022 on: grid zero (16 by 16), grid one and the 2022 grid (16 by 8). Older grids, and grids with an FTDI USB chip, cannot run iii; they connect to norns as monome grids, as before.
- **Arc**: the 2025 edition, the one with a key. Older arcs connect as monome arcs, as before.
- **iii 1.1.0 or later** is needed (the current release is 1.1.2). On an older iii the script shows a fixed pattern (a dim checkerboard on a grid, every eighth LED on an arc) and sends nothing; update the device's firmware.

## Putting the script on the device

1. Put the device in iii mode: hold a key (the top-left key on a grid, the only key on an arc) while plugging it in.
2. Open diii, monome's uploader (monome.org/docs/iii/diii, in a Chromium-family browser, or the `diii` command line tool), with the device plugged into your computer.
3. Upload `iii/strata_grid.lua` (for a grid) or `iii/strata_arc.lua` (for an arc) from Strata's folder, then make it the script that runs at start: type `first('strata_grid.lua')` (or `first('strata_arc.lua')`) in diii.
4. Plug the device into norns. SYSTEM > DEVICES > MIDI lists it as `iii grid` or `iii arc`; note its port.

## The three settings

They are on IO's `remote` section and are rig settings (kept in `io.data`, never in a PSET or a scene):

| Setting | Values | What it does |
|---|---|---|
| grid port | off, 1-16 | the MIDI port a grid in iii mode is on |
| arc port | off, 1-16 | the MIDI port an arc in iii mode is on |
| midi grid | off, on | a MIDI grid through the midigrid mod |

Once a port is set and the device is there, Strata asks it to say hello, and it attaches as soon as it answers: a grid plays the layout of its size (a 16 by 8 grid the [128 horizontal](../grid/128h.md) layout, a 16 by 16 the [256](../grid/256.md), an 8 by 16 the [128 vertical](../grid/128v.md), an 8 by 8 the [64](../grid/64.md); a hello of any other size is refused), on a port of its own besides norns' four grid ports, with its own page; the arc becomes the arc Strata follows. The iii grids the documents describe are 16 by 16 and 16 by 8. While a monome arc is plugged into norns, that arc is followed instead, and the remote arc takes over again when it is unplugged. The port is the remote device's alone while its device is there: Strata's MIDI input, the controllers and MIDI out leave it (a voice's MIDI out route to that port sends nothing, since the device reads notes as its lights).

The section shows a line per device that is set, `grid: ...`, `arc: ...` and `midigrid: ...`, ending in:
- `16x8`, `16x16` (a grid's size) or `4 rings` (the arc): attached
- `[--]`: no device on that port (the section's title shows `[--]` too)
- `no hello`: a device is there but has not answered (another device, or the script is not running or is on an older iii)
- `version 2?` (with the number it sent): the script speaks another version of the protocol; use the scripts from the same Strata
- `size 12x6?`: a grid of a size Strata has no layout for
- `in use`: another part of Strata (a controller) has that port

**rescan** (K3) asks each device again, and connects the midigrid when none is attached.

Unplugging the device detaches it; plugging it back in asks again. A remote grid's LEDs are sent thirty times a second, at most 96 changes each time, so a whole new page reaches a 16 by 16 grid within a tenth of a second.

## A MIDI grid through the midigrid mod

With the midigrid mod installed and on (SYSTEM > MODS), turn `midi grid` on. Strata asks the mod for its grid; when the mod has found a supported device (a Launchpad, an APC mini, a Push and others), that grid attaches as one more of Strata's grids and plays the layout of the mod's size (its default, 128, is 16 by 8: the 128 horizontal layout). With no supported device, or with the mod off, nothing attaches and the line shows `[--]`; plug the device in and press **rescan**. Turning `midi grid` off detaches it and leaves it dark.

While the MIDI grid is attached, its device's MIDI port belongs to it: its pads play no voice through Strata's MIDI input (even on the `midi device` port), SETUP's `midi` row shows `(midigrid)`, and MIDI out sends nothing there. Turning `midi grid` off gives the port back.

What a Launchpad keeps for itself: with one 8 by 8 device on a 128 or 256 layout, the mod uses the device's top row (its round buttons) to choose which 8 by 8 quarter of the grid it shows; those buttons never reach Strata. With two devices the mod gives each a quarter. Colors stand for the sixteen brightness levels, so they look different from a monome grid's.

## Sources

iii v1.1.2's documents and source, and midigrid's `master` branch. Unverified on the device until the 4.0 hardware check.
