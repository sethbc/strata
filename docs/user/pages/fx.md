# FX

The effects settings. Back to [Screen Controls](../controls.md).

A scrolling list of the effects settings under dim section labels (master, filter, delay, reverb), five rows at a time, with a thin scroll marker at the right edge. The selected row is bright. Master: density and tape drift. Filter: type, freq, res, mix. Delay: time, feedback (`fdbk`), mix. Reverb: mix, size, damp. Mixes, feedback and damping show in percent.

- **E2** - Select a row (the labels are skipped)
- **E3** - Adjust the selected row's value (ALT+E3 in finer steps)
- **K3** - Bypass the effect the selected row belongs to (its mix to 0), or bring it back at the last mix it had above 0, however that was set. A mix that has never been above 0 comes on at 100% for the filter and 30% for the delay and reverb. On the master rows K3 does nothing. The hint row shows `K3:filter bypass` / `K3:filter on` (or `delay`, `reverb`), and `E3:value` on the master rows

The effects themselves are described in [Global Controls and Effects](../effects.md).
