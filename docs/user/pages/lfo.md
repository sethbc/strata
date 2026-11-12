# LFO

The six global LFOs. Back to [Screen Controls](../controls.md).

The page shows three LFOs at a time: the selected one and its neighbors (LFOs 1-3 while LFO 1 or 2 is selected, 4-6 while 5 or 6 is), with a mark such as `4-6` right of the first row's wave. One row per LFO: `L1`-`L6` (the selected one bright), one cycle of its shape, a dot that follows the LFO while it runs, its destination (`filt freq`, `v2 main`, ...) and `on`/`off` with its depth. The dot swings as far as the depth takes the destination: across the whole wave at 100 %, along its middle at 0 %. A destination followed by `~` (`v3 pitch~`) runs in the engine (see [Modulation](../modulation.md#global-lfos)); a free LFO there has a hollow dot, the screen's estimate of where the engine is. An `R` after the depth means a modulation routing also uses the LFO.

Under the selected LFO's row, one line shows its settings, left to right: destination, shape (sine, tri, square, up, down, s&h, smooth, drunk), mode (`free` or `clocked`), rate, depth, offset, phase (`ph 0%`), the rate input and its amount (`rmod L1`, `ramt +50%`), the depth input and its amount (`dmod none`, `damt 0%`) and on/off. The rate is in Hz (`0.25Hz`, 0.003-50 Hz) or, in clocked mode, the clocked rate (`1/4`, `1`, `16`, ...: a rate of 1 is one bar of four beats). An LFO that runs in Lua plays at most 10 Hz: its rate then shows `max` after it (`20Hz max`). The setting under the cursor is bright and its name is in the hint row (`E3:shape`). The line shows as many settings as fit and scrolls to keep the cursor's in view; `<` and `>` at the ends mean more settings lie that way.

- **E2** - Move the cursor along the settings line
- **E3** - Change the setting under the cursor, both ways (the destination stops at none and at the end of the list). On the rate: ALT+E3 changes it in finer steps; on a percent (depth, offset, phase, the amounts) ALT+E3 still steps whole percents
- **ALT+E3** on the destination - Jump a group (the ALT hint row shows `E3:group` there): none, the global destinations (density, drift, filter, delay, reverb), voice 1 ... voice 7 (each group starts at the voice's main parameter), then every voice's input history (`v1 hist` ... `v7 hist`), voice filter cutoff (`vfilt`), delay send (`dsend`), reverb send (`rsend`) and level (`amp`), a group each, starting at voice 1, then any further global destinations together
- **K2** / **K3** - Select the previous / next LFO
- **ALT+K2** - A quick press randomizes the selected LFO's shape (any of the eight), its rate (0.05-10 Hz, spread evenly across octaves) or, for a clocked LFO, its division (any), and its phase, leaving its destination, mode, depth, offset, inputs and on/off alone, so a running LFO keeps running. It acts when you let go of K2; within 5 seconds a quick ALT+K2 again on the same LFO, in the same mode, undoes it, and editing the shape, rate, division or phase ends the undo. Held for half a second (the hint turns to `K2:reset`), it resets the setting under the cursor to its default instead
- **ALT+K3** - Turn the selected LFO on or off (the hint row shows `K3:on` or `K3:off`). The arc's button does the same on this page

LFOs start at 25 % depth, so turning one on is audible straight away. A scene saved with another depth (0 included) recalls its own depth.

The offset shifts the LFO's swing up or down, by that percentage of the destination's range. The phase is where the LFO starts when it is turned on (a clocked LFO's place in its cycle, counted from the clock's beats). Turning an LFO on or off keeps its offset, wherever you do it. Scenes store every setting and crossfade the rate, depth and offset in a transition; a scene saved before they did recalls an offset of 0.

What the LFOs modulate, and how one LFO can move another's rate or depth, is described in [Modulation](../modulation.md).
