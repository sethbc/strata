# FX

The effects settings. Back to [Screen Controls](../controls.md).

A scrolling list of the effects settings under dim section labels, five rows at a time, with a thin scroll marker at the right edge. The selected row is bright.

- **master** - density and tape `drift`
- **filter** - `type`, `freq`, `res`, `mix`
- **delay** - `time`, feedback (`fdbk`), `level` (its return, [Plain sends](../effects.md#plain-sends)), `sync` (on or off), ping-pong (`ping`), `freeze` (on or off) and `clear` (it shows `K3`)
- **reverb** - `level`, `size`, `damp`, `from delay` (how much of the delay's return the reverb takes: [delay to reverb](../effects.md#plain-sends)) and `freeze`
- **shimmer** - `interval` (`oct down`, `fifth`, `octave`, `oct+5th` or `2 oct`), `delay` and `reverb` (the two amounts; [Shimmer](../effects.md#shimmer))

The filter's mix, the levels, feedback, ping-pong, damping, `from delay` and the shimmer amounts show in percent. A bypassed delay or reverb shows `byp` (dim) on its section label's row, a frozen one `frz` in the same place (a bypass ends a freeze, so the two never show together); its level still shows its value. While the delay is frozen its `time` row also shows `held` (dim) after the label: a frozen loop keeps the length it had when it froze, and the time the row shows (and still edits) is the one it plays once released. While the reverb is frozen its `size` row shows `held` the same way: the size waits for the release, and `damp`, which still shades the frozen tail, shows no mark ([Reverb freeze](../effects.md#reverb-freeze)). The reverb freezes on the high performance setting only: on the standard setting its `freeze` row shows `--` and does nothing.

- **E2** - Select a row (the labels are skipped)
- **E3** - Adjust the selected row's value (ALT+E3 in finer steps; the filter type and the shimmer interval step one option at a time either way). On `sync` and `freeze`, turn right for on and left for off. On `clear` it does nothing
- **K3 on a delay or reverb row** - Bypass that effect, or lift its bypass (the `delay bypass` and `reverb bypass` params). A bypassed effect stops running and gives back its CPU (the reverb its memory too; the delay's line is kept apart, emptied); its level is kept, and lifting the bypass brings it back at that level, starting empty. Setting a level to 0 is not a bypass: the effect keeps running
- **K3 on the delay's `clear` row** - Empty the delay ([Delay freeze and clear](../effects.md#delay-freeze-and-clear)). A frozen delay is released first, so it takes in sound again and refills. While the delay is bypassed there is nothing to empty: the row shows `--` and K3 lifts the bypass, as on the other delay rows
- **K3 on a filter row** - Turn the filter's mix to 0, or bring it back at the mix it had: the mix it last rose to, or the mix at the press when K3 turned it off (100% if it has never been above 0). Turning the mix down a step at a time or fading it to 0 does not change what K3 restores. So a mix turned down from 80% to 30% and later to 0 comes back at 80%. The filter is never bypassed
- **K3 on a master or shimmer row** - Nothing
- **ALT+K3 on a delay row** - Freeze the delay, or release it: the delay holds what it is playing as a loop you can play over. A bypassed delay does not freeze. Loading a PSET that bypasses the delay releases its freeze, however it is loaded. On the filter, master and shimmer rows ALT+K3 does nothing
- **ALT+K3 on a reverb row** - On the high performance setting, freeze the reverb, or release it: the reverb holds its tail as a wash you can play over. A bypassed reverb does not freeze, and loading a PSET that bypasses the reverb releases its freeze. On the standard setting it does nothing
- **ALT+K2** (hold K1, press and let go of K2) - Randomize the section under the cursor: master (density, drift), filter (type, freq, res), delay (time, feedback, level), reverb (level, size, damp, from delay 30-100%) or shimmer (interval, delay 0-50%, reverb 0-40%), each within a musical range (freq and delay time spread evenly across octaves). The filter's mix, the bypasses, the freezes and the clear are never changed. It acts when you let go of K2, and only after a quick press: to cancel, hold ALT+K2 for half a second, until the hint says `K2:cancel`, and let go. Within 5 seconds, a quick ALT+K2 on the same section undoes it. A change to one of its values ends the undo

**The frozen mark.** While the delay or the reverb is frozen, FX's own dot among the page dots at the top of the screen (the fourth) stands tall and bright, on every page, so a freeze set from FX, a grid or a MIDI controller is never forgotten, and the dot points at the page where you release it. It goes back to a small dot when the freeze ends. A header message hides it with the other dots while it shows.

**The delay on the beat.** With `sync` on, the delay's time follows the tempo: the `time` row shows a division of the beat instead of seconds (1/32, 1/16T, 1/16, 1/16D, 1/8T, 1/8, 1/8D, 1/4T, 1/4, 1/4D, 1/2 or 1 bar; 1/8D at first), and E3 on it picks the division. The delay holds at most 5.4 seconds, so a division that does not fit at the tempo plays at half its length, or a quarter, and so on until it fits: the row then shows the division and what plays, such as `1 bar>1/2` (one bar at 30 BPM plays a half note) or, when no division matches, the seconds. The delay time you set in seconds is kept, and comes back when `sync` is off; while synced, an LFO or a modulation routing on the delay time changes nothing you hear. A frozen delay keeps its loop's length until it is released.

**Ping-pong.** At 0 the delay's repeats stay on their own side. Turned up, the repeats alternate between left and right: at 100% everything comes back first on the left, then the right, then the left again. Both input sides go into the left repeat, so a sound in the center comes back louder on the left the first time.

The hint row shows `K3:delay bypass` / `K3:delay on` (or `reverb`) by the bypass, `K3:clear` on the clear row, `K3:filter bypass` / `K3:filter on` by the filter's mix, and `E3:value` on the master and shimmer rows. With ALT held it shows `K2:rand` (or `K2:undo` within 5 seconds of a randomize of that section), then `K3:freeze` (or `K3:unfreeze` while frozen) on a row of a running delay, or of a running reverb on the high setting, then `E3:fine` on a row that turns finely.

With an arc, the FX page's rings turn the filter's frequency and resonance and the delay's time and level; with ALT held, the delay's feedback, the reverb's level and the two shimmer amounts ([Arc](../arc.md)).

The effects themselves, each voice's sends and the bypass are described in [Global Controls and Effects](../effects.md).
