# SETUP

The MIDI input, mutations, saving and loading scenes, the performance setting, and the connected devices. Back to [Screen Controls](../controls.md).

A list of fields, with the status lines below it. The list scrolls (a thin bar at the right edge shows where you are).

Fields:
- **midi** - the port Strata listens to (1-4) and the device on it (`midi 1: <device>`, shortened if the name is long, or `none`)
- **channels** - per voice, or omni to the selected voice
- **mutations** - on or off
- **mutation rate**, **mutation prob**, **mutation amt** - how often, how likely and how much
- **save scenes**, **load scenes** - write the scenes to disk, or read them back
- **performance** - auto, standard or high: how much of the norns Strata uses (see [Performance tiers](../technical.md#performance-tiers)). It takes effect the next time the script starts, and until then a dim `(next start)` shows below the fields. `may xrun` warns that high may drop out on a CM3 or Pi 3 norns
- **buffer length** - 16, 60, 120 or 300 s per buffer on the high tier (shown when the setting or the running tier is high). If there is not enough memory the engine uses a shorter length, shown below the fields as, for example, `300 s -> 120 s (memory)`

Neither is saved in a PSET or a scene: they are norns settings, kept in `performance.data` in Strata's data folder.

Status lines: what runs now (`running: high, 60 s` or `running: standard`), how many grids are connected (and their sizes, while one is), whether an arc is connected, and how many buffers were restored when the script started (`buffers: 3 restored`; `buffers: 2 ok, 1 missing` when remembered files were not found).

- **E2** - Move to the next or previous field
- **E3** - Change the field's value
- **K3** - Run save scenes or load scenes (the same as PARAMETERS > save scenes to disk and load scenes from disk); nothing on other fields

The arc's rings are off on this page. MIDI is described in [MIDI Input](../midi.md).
