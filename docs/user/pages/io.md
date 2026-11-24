# IO

The rest of the rig: what Strata sends to other instruments and what it takes from controllers, in one list of sections. Back to [Screen Controls](../controls.md).

IO is the tenth page, after SETUP. Each part of the rig has a section on it, in this order: the selected voice's routes (`voice`), MIDI out (titled `midi out`), `crow`, the ii bus (`ii`), W/ tape (titled `w/ tape`), `controllers`, remote grids and arcs (`remote`), `osc` and the tape loop (`tape`). Everything on it starts off: a fresh Strata sends nothing to any of them. A table of every supported device, with the page for each, is on [Supported devices](../io/devices.md).

Each section starts with a title line: its name at the left and, at the right, what it needs you to know, such as `[--]` when its device is not connected. Under the title are its rows. The list scrolls (a thin bar at the right edge shows where you are). A row is one of:
- **a value** - a setting saved with a PSET, or a rig setting (below); E3 changes it, and the value shows at the right
- **an action** - K3 does what the hint row names (`K3:rescan` on the `remote` section's rescan row, ...); the right side shows what it last did
- **a status line** - text only, dim, which the cursor skips
- **a detail** - a row with its own short list (a CC slot's four settings, for example): K3 opens the list, E2 moves in it, E3 changes the setting under the cursor, K2 closes it

If a section cannot draw itself, its title shows `error` and the other sections carry on.

## Rig settings

Some rows are rig settings: they describe how your rig is wired, not a sound, so they are kept in `io.data` in Strata's data folder, not in a PSET or a scene, and only a row of this page changes them (no PSET, scene, controller, OSC message or Teletype script can). If norns cannot write the file, the row keeps its old value and the hint row flashes `setting not saved`. If the file cannot be read at start, it is kept as `io.data.bak` and every setting starts at its default.

| Setting | Values | Default | What it is |
|---|---|---|---|
| bus leader (`ii` section) | off, strata leads, teletype leads | off | who leads the ii bus: nobody, Strata (through crow), or a Teletype. Strata sends ii messages only while it leads |
| e16 port (`controllers` section) | off, 1-16 | off | the MIDI port an E16 is on |
| e16 channel | 1-16 | 16 | the E16's channel |
| e16 cc | 0-104 | 102 | the first of the E16's sixteen CCs |
| e16 encoding | rel1, rel2 | rel1 | how its encoders send a turn: 1 and 127, or 63 and 65 |
| faders port | off, 1-16 | off | the MIDI port a box of sixteen faders is on |
| faders channel | 1-16 | 1 | its channel |
| faders cc | 0-80 | 32 | the first of its sixteen CCs |
| faders hires | off, on | off | 14-bit faders, the low 7 bits on each CC + 32 |
| grid port, arc port (`remote` section) | off, 1-16 | off | the MIDI port a grid or an arc in iii mode is on |
| midi grid (`remote` section) | off, on | off | a MIDI grid through the midigrid mod |
| feedback (`osc` section) | off, on | off | whether Strata sends its values back to an OSC controller |
| port (`osc` section) | 1-65535 | 9000 | the port that feedback goes to (E3 moves 10 at a time, ALT+E3 one) |

The e16 and faders rows (and their channel, cc, encoding and hires rows) are all in the `controllers` section.

## Voice routes

The `voice` section comes first. Its title names the selected voice (`voice 3`); ALT+E2 selects another. Under it, each external instrument a voice can play adds its routes for that voice: `midi` (a detail list: port, channel, mode, members), `jf` and `jf level`, `w/ syn` and `w/ level`, `er-301`, `txo` (a detail list), `txo attack` and `txo decay`, and `nb`, in that order (a line `nb mods send on their own` follows `nb` while any voice has an nb player). crow's outputs follow a voice's pitch or gate from the `crow` section, so crow adds no row here. A mark at the right of the title tells you when a route needs attention (`[!]`, see [nb voices](../io/nb.md)).

A route that is set but plays nothing says so at the right of its row, beside its value:
- `[held]`: the voice's MIDI port is held by a remote grid, a remote arc or `midi grid` (see [MIDI out](../io/midi-out.md))
- `[idle]`: an ii route (`jf`, `w/ syn`, `er-301`) while Strata does not lead the ii bus (see [the ii bus](../io/ii.md))
- `[error]`: the instrument's part of Strata failed (the console names it) and is skipped for new notes until you stop the patterns or change a route

What a routed voice plays on its targets:
- **its pattern steps**: each step plays the step's pitches (the chord's notes, or the voice's own pitch, moved by the step's pitch lock) at the step's level, and each note ends just before the step's gate does (30 ms early, or half the note for a very short one), so a gate or trigger input sees a low before the next step raises it; a ratchet's next hit ends the note before it plays again
- **its played notes**: each MIDI note you play on the voice, held for as long as you hold it (or latch it), with its bend, pressure and slide where the target takes them

A note always ends on the instruments it started on, even if you change a route while it sounds. Every note a voice sounds ends when you stop the voice, change one of its routes, stop the patterns (their step notes), load a PSET that changes its routes, or leave the script (a PSET that leaves them as they are lets the notes end as they would). A muted voice, or one silenced by another's solo, plays nothing on its targets, and its notes end as it falls silent.

Pitch to volts: a target that takes volts plays MIDI note 60 (middle C) at 0 V, one volt an octave, so note 72 is 1 V and note 48 is -1 V; each clamps to its device's range.

## Controls

- **E2** - Move to the next or previous row; past the last one, scroll over the lines below it
- **E3** - Change the row's value (with K1 held, ALT+E3, finely); on a scrolled view, scroll back to the row instead
- **K2** - Jump to the next section's first row (from the last section, back to the first)
- **K3** - Run the row's action, or open its detail list; when the row is out of view, bring it back instead
- **ALT+E2** - Select the voice, as on MAIN: the `voice` section shows the selected voice's routes

When the row under the cursor goes away (a device unplugged, a route changed), the cursor moves to the row in its place, and a `>` at the left marks that row until the screen next changes. A turn of E3 or a press of K3 made before the screen shows the move only shows it, and changes nothing.

The arc's four rings on IO are the tape loop's level, speed, feedback and wear (see [the tape loop](../io/tape.md)).

## Devices and connections

Each device or connection IO reaches has its own page:
- [Supported devices](../io/devices.md): the OXI One and the Disting NT, and one table of every device, how Strata reaches it and what it was built from
- [MIDI out](../io/midi-out.md): a voice's notes to a MIDI synth, plain or MPE, eight CC out slots, program change in and out
- [crow](../io/crow.md): its inputs as modulation or triggers, its outputs for modulation, a voice's pitch or gate, and the clock
- [The ii bus and Teletype](../io/ii.md): who leads the ii bus, and Teletype's three calls to scenes, voices, macros and the patterns
- [Just Friends](../io/jf.md): a voice's notes to Just Friends over the ii bus
- [W/](../io/w.md): W/ synth as a target, and W/ tape's transport from the `w/ tape` section
- [ER-301 and TELEXo](../io/er301-txo.md): a voice's notes to an ER-301 port or a TELEXo output over the ii bus
- [nb voices](../io/nb.md): a voice's steps and played notes to a player an installed nb voice mod offers
- [Controllers](../io/controllers.md): an OXI E16 and a box of sixteen faders on the sixteen macros
- [Remote grids and arcs](../io/remote.md): a grid or arc in iii mode, and a MIDI grid through the midigrid mod
- [OSC and TouchOSC](../io/osc.md): scenes, voices and the patterns from an OSC app, feedback, two TouchOSC layouts
- [The tape loop](../io/tape.md): a stereo loop of Strata's output on softcut, the `tape` section
