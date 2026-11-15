# The tape loop

A stereo loop of what Strata is playing, recorded and replayed on norns' softcut. Part of the [IO page](../pages/io.md): the `tape` section, and the four arc rings of IO. Back to [Screen Controls](../controls.md).

It is off by default: with `tape` off Strata sends nothing to softcut and leaves norns' mixer alone.

## The settings

All seven are saved with a PSET; none is in a scene.

| Setting | Values | Default | What it does |
|---|---|---|---|
| tape | off, on | off | turns the loop on or off |
| record | off, on | on | whether new sound is written into the loop; off keeps what it holds (the feedback still applies) |
| length | 0.25-60 s | 4 s | how long the loop is |
| speed | -2 to 2 | 1 | playback speed; negative plays backward; changes glide over 0.2 s |
| feedback | 0-1 | 0.5 | how much of the loop stays each pass; at the top the loop just holds |
| wear | 0-1 | 0.2 | how much each pass is darkened: 0 is open (12000 Hz), 1 is very worn (800 Hz) |
| level | 0-1 | 0.7 | how loud the loop plays |

Level, speed, feedback and wear are also macro targets, so a macro, an LFO on a macro or a matrix routing can move them.

## The arc

On IO, rings 1 to 4 are level, speed, feedback and wear.

## Good to know

- While the tape is on, softcut takes norns' engine output, which is Strata's output after its limiter, and nothing else: the inputs and norns' own tape playback are set to zero in softcut's input mixer. Turning the tape off, or leaving Strata, puts them back to your system levels.
- While the loop is on, changing norns' own softcut input levels (PARAMETERS > LEVELS: the engine, input and tape levels into softcut) changes what goes into the loop. Turning the loop off puts norns' settings back.
- The loop plays beside Strata's output, so Strata and the loop both running hot can clip norns' output. `level` is the control.
- Softcut belongs to the script that is running: a script change ends the loop and its contents are lost.
- Its voices are softcut's 1 and 2, panned left and right. A script of yours that also uses them would collide.

Built from norns' `lua/core/softcut.lua` and softcut's write path (`docs/design/3.6-facts/checks.md`, section 8). Unverified on the device until the 4.0 hardware check.
