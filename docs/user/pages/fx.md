# FX

The effects settings. Back to [Screen Controls](../controls.md).

A scrolling list of the effects settings under dim section labels (master, filter, delay, reverb), five rows at a time, with a thin scroll marker at the right edge. The selected row is bright. Master: density and tape drift. Filter: type, freq, res, mix. Delay: time, feedback (`fdbk`), mix. Reverb: mix, size, damp. Mixes, feedback and damping show in percent. A bypassed delay or reverb shows `byp` (dim) on its section label's row; its mix still shows its value.

- **E2** - Select a row (the labels are skipped)
- **E3** - Adjust the selected row's value (ALT+E3 in finer steps; the filter type steps one type at a time either way)
- **ALT+K2** (hold K1, press and let go of K2) - Randomize the section under the cursor: master (density, drift), filter (type, freq, res), delay (time, feedback, mix) or reverb (mix, size, damp), each within a musical range (freq and delay time spread evenly across octaves). The filter's mix and the delay and reverb bypasses are never changed. It acts when you let go of K2, and only after a quick press: to cancel, hold ALT+K2 for half a second, until the hint says `K2:cancel`, and let go. Within 5 seconds, a quick ALT+K2 on the same section undoes it. A change to one of its values ends the undo
- **K3 on a delay or reverb row** - Bypass that effect, or lift its bypass (the `delay bypass` and `reverb bypass` params). A bypassed effect stops running and gives back its CPU and memory; its mix is kept, and lifting the bypass brings it back at that mix, starting empty. Setting a mix to 0 is not a bypass: the effect keeps running
- **K3 on a filter row** - Turn the filter's mix to 0, or bring it back at the mix it had: the mix it last rose to, or the mix at the press when K3 turned it off (100% if it has never been above 0). Turning the mix down a step at a time or fading it to 0 does not change what K3 restores. So a mix turned down from 80% to 30% and later to 0 comes back at 80%. The filter is never bypassed
- **K3 on a master row** - Nothing

The hint row shows `K3:delay bypass` / `K3:delay on` (or `reverb`) by the bypass, `K3:filter bypass` / `K3:filter on` by the filter's mix, and `E3:value` on the master rows. With ALT held it shows `K2:rand` (or `K2:undo` within 5 seconds of a randomize of that section), plus `E3:fine` on a row that turns finely.

The effects themselves, each voice's sends and the bypass are described in [Global Controls and Effects](../effects.md).
