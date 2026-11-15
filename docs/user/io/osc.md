# OSC and TouchOSC

Control Strata from an OSC app such as TouchOSC, and have it show Strata's values. Back to [IO](../pages/io.md). OSC is off by default for feedback; norns itself always listens.

Built from norns' `lua/core/osc.lua`, TouchOSC's manual (hexler.net/touchosc/manual) and the tosclib library's file format. **Unverified on the device until the 4.0 hardware check**, and the two layouts have never been opened in TouchOSC.

## What norns accepts

norns listens for OSC on port **10111**. `/param/<id> <value>` sets any param, in the param's own units (Hz, dB, an option's number), exactly as if you had turned it. Ids are in the parameters menu's param ids (`macro_1`, `v1_amp`, `v3_freq`, ...).

Strata adds six addresses for what is not a param:

| Address | Does |
|---|---|
| `/strata/scene <n>` | Recalls scene n (with the scene's transition time and the quantizer, like a scene key) |
| `/strata/voice/<n>/run <0, 1 or 2>` | Stops, starts or toggles voice n (1 to 7) |
| `/strata/voice/<n>/retrigger <velocity>` | Accents a running voice, velocity 0 to 1 |
| `/strata/patterns <0, 1 or 2>` | Stops, starts or toggles the patterns |
| `/strata/watch <param id>` | Adds a param to the feedback list |
| `/strata/hello` | Sends every watched value and the states now |

A wrong address, a missing or wrong argument or a voice that is not 1 to 7 prints one line to the console and does nothing.

## Feedback

Set **osc feedback** to `on` in the IO page's `osc` section. Strata sends values back to the host of the last message it received, at **osc port** (9000 by default), up to 15 times a second:
- `/param/<id> <value>` for each watched param when it changes. The list starts as the sixteen macros and each voice's mute and level; `/strata/watch` adds more.
- `/strata/scene <n>`, `/strata/voice/<n>/running <0 or 1>` and `/strata/patterns <0 or 1>` when they change.

A value that has just arrived from the app is not sent back to it. Send `/strata/hello` when the app starts so it shows everything. The section's title shows the sender's host, or `no sender` until a message has arrived.

## TouchOSC

TouchOSC has no default ports, so type them in. In its connections, make a UDP connection with:
- **Host**: norns' address (its IP address or `norns.local`)
- **Send port**: 10111
- **Receive port**: the same number as osc port on the IO page (9000 by default)

Two layouts are in `extras/touchosc/` in the Strata folder: `strata-tablet.tosc` and `strata-phone.tosc`. Each has three pages: the sixteen macros, the seven voices (run, mute and level) and the sixteen scenes with the patterns' toggle. They are made by `tools/touchosc/generate.py` from `tools/touchosc/layout.lua` (see `tools/touchosc/README.md`), in a file format Hexler does not document.
