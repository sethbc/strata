# LFO

The three global LFOs. Back to [Screen Controls](../controls.md).

One row per LFO: `L1`-`L3` (the selected one bright), one cycle of its shape, a dot that follows the LFO while it runs, its destination (`filt freq`, `v2 main`, ...) and `on`/`off` with its depth. The dot swings as far as the depth takes the destination: across the whole wave at 100 %, along its middle at 0 %.

Under the selected LFO's row, one line shows its settings, left to right: destination, shape, mode (`free` or `clocked`), rate, depth, offset and on/off. The rate is the free period in seconds (`4.0s`, 0.1-300 s) or, in clocked mode, the clocked rate (`1/4`, `1`, `16`, ...). The setting under the cursor is bright and its name is in the hint row (`E3:shape`). The line shows as many settings as fit and scrolls to keep the cursor's in view; `<` and `>` at the ends mean more settings lie that way.

- **E2** - Move the cursor along the settings line
- **E3** - Change the setting under the cursor, both ways (the destination stops at none and at the end of the list, `v7 rsend`, after the voice destinations and the 28 registered ones). On the rate: ALT+E3 changes the free period in finer steps
- **ALT+E3** on the destination - Jump a group (the ALT hint row shows `E3:group` there): none, the global destinations (density, drift, filter, delay, reverb), voice 1 ... voice 7 (each group starts at the voice's main parameter), then one last group that starts at `v1 hist` and holds all 28 registered destinations: every voice's input history (`v1 hist` ... `v7 hist`), voice filter cutoff (`vfilt`), delay send (`dsend`) and reverb send (`rsend`), voice by voice
- **K2** / **K3** - Select the previous / next LFO
- **ALT+K2** - Reset the setting under the cursor to its default
- **ALT+K3** - Turn the selected LFO on or off (the hint row shows `K3:on` or `K3:off`). The arc's button does the same on this page

LFOs start at 25 % depth, so turning one on is audible straight away. A scene saved with another depth (0 included) recalls its own depth.

The offset shifts the LFO's swing up or down (-50 to 50 % with the "from center" baseline). Turning an LFO on or off keeps its offset, wherever you do it; changing the baseline in PARAMETERS sets it back to 0. Scenes store the offset and crossfade it in a transition; a scene saved before they did recalls an offset of 0. Phase, baseline, min/max and the reset settings stay in PARAMETERS > LFO 1-3.

What the LFOs modulate is described in [Modulation](../modulation.md).
