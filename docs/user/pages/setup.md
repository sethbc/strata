# SETUP

The MIDI input (with MPE and the voices' split zones), the note pool, mutations, saving and loading scenes, following the clock's transport, each grid's rotation, the performance setting, and the connected devices. Back to [Screen Controls](../controls.md).

A list of fields, with the status lines below it. The list scrolls (a thin bar at the right edge shows where you are). Turn E2 past the last field and the view scrolls on over the status lines (`running:`, `grid:`, `arc:`, `buffers:` and any data file that had a problem), so each can be read; E2 back brings the fields up again. While the view is scrolled that far the field may be out of sight, so E3 changes nothing: it brings the field back into view (the hint row reads `E2:field E3:back`), and the next E3 changes it.

Fields:
- **midi** - the port Strata listens to (1-16) and the device on it (`midi 1: <device>`, shortened if the name is long, or `none`)
- **channels** - per voice, or omni to the selected voice (the [MIDI Input](../midi.md) page describes every mode)
- **note off** - what releasing a key does: the same setting as PARAMETERS > midi > midi note off ([MIDI Input](../midi.md))
- **mpe & zones** - K3 opens the MPE and zones editor (below)
- **note pool** - how many extra notes the seven voices share for chords, 0-16 (E3). A voice's first note never counts; each further note held at once on any voice takes one from the pool, and when it is used up the oldest is let go for the new one. 0 plays one note per voice. The default is 4 on the standard tier and 8 on high. On the standard tier a dim `may xrun` shows under a pool above 4: that many notes at once may make the audio drop out there. Kept in `notes.data` in Strata's data folder, not in a PSET or a scene; if norns cannot write the file, the field keeps its old value and the hint row flashes `setting not saved`
- **mutations** - on or off
- **mutation rate**, **mutation prob**, **mutation amt** - how often, how likely and how much
- **save scenes**, **load scenes** - write the scenes to disk, or read them back. The hint row says what happened: `scenes saved` or `scenes not saved`; `scenes loaded`, `no scenes file` or `scenes unreadable`. Each scene save already writes the file ([Saved scenes on disk](../scenes.md#saved-scenes-on-disk)), so a load replaces the slots with the same scenes, except when a save could not be written: then the first K3 only shows `K3 again: drop unsaved`, and a second K3 within 2 seconds loads the file over the unsaved scenes
- **transport** - `follow` (the default) or `off`: whether a MIDI clock or Link start and stop start and stop the patterns (PARAMETERS > sequencer > follow transport; see [Following the clock's transport](../sequencer.md#following-the-clocks-transport)). On the internal clock nothing follows either way
- **grid 1 rotation** to **grid 4 rotation** - turn the grid on that port (SYSTEM > DEVICES > GRID) a quarter turn at a time: 0, 90, 180 or 270 degrees. A monome 128 reports itself as 16×8; at 90 or 270 it stands upright and Strata uses the [8×16 layout](../grid/128v.md) (choose whichever puts its cable where you want it). A 16×16 or 8×8 keeps its layout, turned. The grid starts again on page 1, with no keys held. Each port keeps its rotation, with or without a grid on it, in `grids.data` in Strata's data folder (not in a PSET or a scene), and a grid plugged into the port is turned at once. Leaving Strata puts the grid back unturned for the next script. If norns cannot write the file, the field keeps its old value and the hint row flashes `setting not saved`
- **performance** - auto, standard or high: how much of the norns Strata uses (see [Performance tiers](../technical.md#performance-tiers)). If norns cannot write the setting, the field keeps its old value and the hint row flashes `setting not saved`. It takes effect the next time the script starts, and until then a dim `(next start)` shows below the fields. `may xrun` warns that high may drop out on a CM3 or Pi 3 norns
- **buffer length** - 16, 60, 120 or 300 s per buffer on the high tier (shown when the setting or the running tier is high). If there is not enough memory the engine uses a shorter length, shown below the fields as, for example, `300 s -> 120 s (memory)` (`(meminfo)` means the engine could not read the system's free memory and took the shortest length)

Neither the performance setting nor the buffer length is saved in a PSET or a scene: they are norns settings, kept in `performance.data` in Strata's data folder.

When a data file has a problem, lines at the end of the list say so, after the status lines (the last row is `buffers:`, then these): `scenes unreadable, kept` with the copy's name under it (`as scenes.data.bak.2`) when a file could not be read at start and was moved aside; `scenes file unreadable` and `not saved over` when it could not even be moved (then nothing is written over it this session; for scenes, save scenes here does write over it); `scenes file not saved` when the last write failed (the file on the card is the previous one, whole). The same lines exist for `buffers` (`buffers.data`, the remembered buffer files). At start, a file that could not be read is also named on the hint row for a few seconds (`scenes unreadable (SETUP)`, `buffers unreadable (SETUP)`, or `data files unreadable (SETUP)` for both).

Status lines: what runs now (`running: high, 60 s` or `running: standard`; a dim line under it says `active file not written` or `old active file kept` if the engine could not save which tier it runs, so the running tier may not be what the setting asked for), how many grids are connected (and their sizes, while one is), whether an arc is connected, and how many buffers were restored when the script started (`buffers: 3 restored`; `buffers: 2 ok, 1 missing` when remembered files were not found).

- **E2** - Move to the next or previous field; past the last field, scroll over the status lines
- **E3** - Change the field's value; while E2 has scrolled past the last field, scroll back to it instead
- **K3** - Run save scenes or load scenes (the same as PARAMETERS > save scenes to disk and load scenes from disk; load scenes may ask for a second K3, above), or open the MPE and zones editor on mpe & zones; nothing on other fields. With K1 held (ALT) no K3 is offered: ALT+K3 does nothing here

The arc's rings are off on this page. MIDI is described in [MIDI Input](../midi.md).

## MPE and zones

K3 on **mpe & zones** opens an editor over the page (PARAMETERS > midi and > zones hold the same settings):

```
SETUP ·········
lower members             15
upper members              0
bend range             48 st
v1   lower     C-2      G8
v2   upper     C-2      G8
K2:back E3:value
```

- **lower members**, **upper members** - how many member channels each MPE zone has (0-15; 0 turns the zone off). The lower zone's master is channel 1 and its members 2 upward; the upper's master is channel 16 and its members 15 downward. While both have members they share 14 channels: raising one lowers the other
- **bend range** - the member channels' pitch bend range, 1-96 semitones (48 by default, the MPE standard)
- **v1** to **v7** - each voice's split zone and its range: the zone (`off`, `lower` or `upper`), then the lowest and the highest note it plays, named as norns names notes (middle C, note 60, is `C3`; the full range is `C-2` to `G8`). In the `mpe split` channel mode a note plays every voice whose zone is the note's and whose range holds it

- **E2** - Move to the next or previous row
- **E3** - Change the value under the cursor
- **K3** - On a voice row, move to the next column (zone, lowest, highest)
- **ALT+K3** - On a voice row, learn its range: play two notes within 10 seconds, the lowest and the highest (in either order). The header says `learn v3 low`, then `learn v3 high`, and the column waiting reads `learn`. The two notes only set the range: neither plays
- **K2** - Back to SETUP (a learn still waiting ends)
