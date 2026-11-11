# MAIN

The voice list and the selected voice's details. Back to [Screen Controls](../controls.md).

```
MAIN •·······           ▶ REC  S3
1+ reso     RESONAT      synth
2+ fm       ON
3- fold    >freq       100 Hz
4+ sub      size       0.10 s
            dens        20 /s
K2:field K3:stop
```

- **E2** - Select voice (1-7)
- **E3** - Adjust the field under the cursor (`>`) (ALT+E3 in finer steps)
- **K2** - Move the cursor to the next field (after the third it goes back to the first)
- **K3** - Start the selected voice, or stop it if it is running
- **ALT+K2** (hold K1, press and let go of K2) - Randomize the selected voice (buffer parameters for a buffer-sourced voice, only grain parameters for an input-sourced one; a locked voice is left alone). It acts when you let go of K2, and only after a quick press: K2 held for half a second or more does nothing. Within 5 seconds, a quick ALT+K2 again undoes the randomize and puts the previous values back. A randomize of another voice, or on another page, in between replaces the undo, so ALT+K2 then randomizes the voice again
- **ALT+K3** - Lock or unlock the selected voice (a locked voice is safe from randomize and mutation, and you can still edit it)

The hint row shows `K2:field K3:start` (or `K3:stop` for a running voice). While K1 is held it shows the ALT keys: `K2:rand` (or `K2:undo` during the 5 seconds after a randomize, or `K2:locked` for a locked voice, which randomize leaves alone) and `K3:lock` (or `K3:unlock`).

## Voice list

The left column lists the voices, four at a time: each entry is the voice number, `+` (running) or `-` (stopped), the short name (`reso`, `fm`, `fold`, `sub`, `pulse`, `karp`, `ring`) and `[L]` when locked, for example `3- fold [L]`. The selected voice is bright. The list keeps four voices in view at both ends.

## Details

The right column shows the selected voice:
- its full name and its source on the right (`synth`, `buf 1`-`buf 8`, `input`). A long name is shortened where it would run into the source;
- `ON` or `OFF`, then `[L]` when locked and `[T]` when its grains are in triggered mode. Last comes `[F]` while the voice's audio is frozen: its grains keep playing the same few seconds (freeze is on the [VOICE](voice.md) page, the grid and MIDI);
- three fields, each with its unit. The cursor (`>`) marks the one E3 adjusts:
  - the main parameter, then grain size (`size`, seconds) and grain density (`dens`, grains per second). The main parameter is:
    - Resonator: frequency (`freq`)
    - FM: modulation index (`index`)
    - Folder: fold amount (`fold`)
    - Sub: drift amount (`drift`)
    - Pulse: pulse width (`width`)
    - Karplus: decay time (`decay`)
    - Ring: frequency ratio (`ratio`)
    - any voice whose source is a buffer: buffer position (`pos`)
  - a voice whose source is the input: grain size, grain density and grain pitch (`pitch`, a ratio).

Locking a voice doesn't dim its values: they can still be edited. The voice's crossmod sources are on the [VOICE](voice.md) page.

The arc's MAIN rings are in [Monome Arc](../arc.md); the arc's button starts and stops the selected voice, as K3 does.
