# FX

The effects settings. Back to [Screen Controls](../controls.md).

A scrolling list of the effects settings under dim section labels (master, filter, delay, reverb), five rows at a time, with a thin scroll marker at the right edge. The selected row is bright. Master: density and tape drift. Filter: type, freq, res, mix. Delay: time, feedback (`fdbk`), mix. Reverb: mix, size, damp. Mixes, feedback and damping show in percent. A bypassed delay or reverb shows `byp` (dim) on its section label's row; its mix still shows its value.

- **E2** - Select a row (the labels are skipped)
- **E3** - Adjust the selected row's value (ALT+E3 in finer steps)
- **K3 on a delay or reverb row** - Bypass that effect, or lift its bypass (the `delay bypass` and `reverb bypass` params). A bypassed effect stops running and gives back its CPU and memory; its mix is kept, and lifting the bypass brings it back at that mix, starting empty. Setting a mix to 0 is not a bypass: the effect keeps running
- **K3 on a filter row** - Turn the filter's mix to 0, or bring it back at the mix it had: the mix it last rose to, or the mix at the press when K3 turned it off (100% if it has never been above 0). Turning the mix down a step at a time or fading it to 0 does not change what K3 restores. The filter is never bypassed
- **K3 on a master row** - Nothing

The hint row shows `K3:delay bypass` / `K3:delay on` (or `reverb`) by the bypass, `K3:filter bypass` / `K3:filter on` by the filter's mix, and `E3:value` on the master rows.

The effects themselves, each voice's sends and the bypass are described in [Global Controls and Effects](../effects.md).
