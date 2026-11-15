# IO

The rest of the rig: what Strata sends to other instruments and what it takes from controllers, in one list of sections. Back to [Screen Controls](../controls.md).

IO is the tenth page, after SETUP. Each part of the rig adds a section to it: the selected voice's routes (`voice`), MIDI out (`midi`), crow, the ii bus (`ii`), W/ tape (`wtape`), controllers, remote grids and arcs (`remote`), OSC and the tape loop (`tape`), in that order. Until those parts arrive the page shows `no sections`. Everything on it starts off: a fresh Strata sends nothing to any of them.

Each section starts with a title line: its name at the left and, at the right, what it needs you to know, such as `[--]` when its device is not connected. Under the title are its rows. The list scrolls (a thin bar at the right edge shows where you are). A row is one of:
- **a value** - a setting saved with a PSET, or a rig setting (below); E3 changes it, and the value shows at the right
- **an action** - K3 does what the hint row names (`K3:scan`, ...); the right side shows what it last did
- **a status line** - text only, dim, which the cursor skips
- **a detail** - a row with its own short list (a CC slot's four settings, for example): K3 opens the list, E2 moves in it, E3 changes the setting under the cursor, K2 closes it

If a section cannot draw itself, its title shows `error` and the other sections carry on.

## Rig settings

Some rows are rig settings: they describe how your rig is wired, not a sound, so they are kept in `io.data` in Strata's data folder, not in a PSET or a scene, and only a row of this page changes them (no PSET, scene, controller, OSC message or Teletype script can). If norns cannot write the file, the row keeps its old value and the hint row flashes `setting not saved`. If the file cannot be read at start, it is kept as `io.data.bak` and every setting starts at its default.

| Setting | Values | Default | What it is |
|---|---|---|---|
| ii bus | off, strata, teletype | off | who leads the ii bus: nobody, Strata (through crow), or a Teletype. Strata sends ii messages only while it leads |
| e16 port | off, 1-16 | off | the MIDI port an E16 is on |
| e16 channel | 1-16 | 16 | the E16's channel |
| e16 cc | 0-104 | 102 | the first of the E16's sixteen CCs |
| e16 encoding | rel1, rel2 | rel1 | how its encoders send a turn: 1 and 127, or 63 and 65 |
| faders port | off, 1-16 | off | the MIDI port a box of sixteen faders is on |
| faders channel | 1-16 | 1 | its channel |
| faders cc | 0-80 | 32 | the first of its sixteen CCs |
| faders hires | off, on | off | 14-bit faders, the low 7 bits on each CC + 32 |
| remote grid port, remote arc port | off, 1-16 | off | the MIDI port a grid or an arc in iii mode is on |
| midi grid | off, on | off | a MIDI grid through the midigrid mod |
| osc feedback | off, on | off | whether Strata sends its values back to an OSC controller |
| osc port | 1-65535 | 9000 | the port that feedback goes to (E3 moves 10 at a time, ALT+E3 one) |

Each setting takes effect once the part of the rig that reads it arrives with its section.

## Controls

- **E2** - Move to the next or previous row; past the last one, scroll over the lines below it
- **E3** - Change the row's value (with K1 held, ALT+E3, finely); on a scrolled view, scroll back to the row instead
- **K2** - Jump to the next section's first row (from the last section, back to the first)
- **K3** - Run the row's action, or open its detail list; when the row is out of view, bring it back instead
- **ALT+E2** - Select the voice, as on MAIN: the `voice` section shows the selected voice's routes

The arc's rings are off on IO for now.

## Devices and connections

Each device or connection IO reaches has its own page, listed here as it arrives:
