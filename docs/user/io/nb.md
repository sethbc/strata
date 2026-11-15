# nb voices

Strata can play the voices that installed nb voice mods offer: each of Strata's seven voices can send its steps and the notes you play into it to one nb player, such as a Just Friends voice, a crow voice or a Disting EX. Part of the [IO page](../pages/io.md): the `nb` row of the `voice` section. Back to [Screen Controls](../controls.md).

Strata is an nb host of its own: it lists the players the installed voice mods register and plays them, and it loads no nb file. With no voice mod installed the only choice is `none`, and Strata does nothing here.

## Installing a voice mod

A voice mod is a norns mod: install it from maiden (or copy it to `~/dust/code/`), turn it on in SYSTEM > MODS, and restart norns. Its players then appear in Strata's `nb` list, sorted by name, the next time Strata loads. A mod installed or turned on while Strata runs appears after the restart.

## The setting

| Setting | Values | Default | What it does |
|---|---|---|---|
| nb (one a voice, `v<i>_out_nb` in PARAMETERS > out nb) | `none`, then each player's name | `none` | the player the voice's steps and played notes go to |

- A step plays the player at the step's pitches, rounded to whole notes, with the step's velocity; it ends at the step's gate. A note you play into the voice plays it until you release the note.
- Stopping the voice, a PSET load and leaving Strata stop every chosen player's notes.
- The choice is saved with a PSET by the player's name, so a PSET still picks the same player when you install another mod. A PSET that names a player that is not installed shows `none` and keeps the name: install the mod again and the next load picks it.
- Two voices can choose the same player. A player is switched on when the first voice chooses it and off when the last one leaves it.
- The players' own settings are in PARAMETERS, under `nb players`.

## Good to know

- **nb's own `midi:` players are not listed.** nb's MIDI players (`midi: <device> <n>`) belong to nb's hosts; Strata has its own MIDI out on IO.
- **A player whose name a PSET could not keep** (a name that reads as a number, or starts or ends with a space) is left out, with one line in maiden's console naming it.
- **`nb mods send on their own`**: while any voice has a player, the `voice` section shows this line. Some voice mods (for Just Friends, for a Disting EX, for crow's outputs) send to crow or over ii themselves. Those messages are the mod's, not Strata's: they do not follow IO's ii bus setting or Strata's limits on how much it sends, and a mod that uses crow's outputs shares them with Strata's crow settings. Strata cannot tell which players do this, so the line shows for any player.
- **`[!]` on the voice section's title**: while any voice has a player and the ii bus setting is not `strata`, since such a player may lead the ii bus whatever the setting says.

Built from nb's own `nb.lua` and `player.lua` (in nb's lib folder) at commit `400e0b38`, and the voice mods named in `docs/design/3.6-facts/checks.md`, section 1. Unverified on the device until the 4.0 hardware check.
