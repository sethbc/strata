# SETUP

The MIDI input, mutations, saving and loading scenes, and the connected devices. Back to [Screen Controls](../controls.md).

A list of fields, with the status lines below it. The list scrolls (a thin bar at the right edge shows where you are).

Fields:
- **midi** - the port Strata listens to (1-4) and the device on it (`midi 1: <device>`, shortened if the name is long, or `none`)
- **channels** - per voice, or omni to the selected voice
- **mutations** - on or off
- **mutation rate**, **mutation prob**, **mutation amt** - how often, how likely and how much
- **save scenes**, **load scenes** - write the scenes to disk, or read them back

Status lines: how many grids are connected (and their sizes, while one is), whether an arc is connected, and how many buffers were restored when the script started (`buffers: 3 restored`; `buffers: 2 ok, 1 missing` when remembered files were not found).

- **E2** - Move to the next or previous field
- **E3** - Change the field's value
- **K3** - Run save scenes or load scenes (the same as PARAMETERS > save scenes to disk and load scenes from disk); nothing on other fields

The arc's rings are off on this page. MIDI is described in [MIDI Input](../midi.md).
