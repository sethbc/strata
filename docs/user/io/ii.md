# The ii bus and Teletype

ii is the small bus behind your modules that lets crow, Teletype, Just Friends, W/, an ER-301 or a TELEXo talk to each other. Strata reaches it only through crow, and only when you say so. Back to [IO](../pages/io.md).

Built from crow's firmware v4.0.5 (its `lua/ii/` descriptors and `lua/ii.lua`), Teletype v5.0.0's `CROW.*` ops, and monome's ii page (https://monome.org/docs/modular/ii). It is unverified on the device until the 4.0 hardware check.

## Who leads the bus

A bus has one leader: the device that starts each message. Two leaders talking at once can lock a module up. So Strata asks you which one yours has, in the `ii` section's `bus leader` row (E3 changes it). The setting belongs to your rig, not to a patch: it is kept on the norns, and loading a PSET or a scene never changes it.

- **off** (the default) - Strata sends nothing on the bus and answers nothing. Use it when nothing of Strata's is on the bus, or when something else leads it.
- **strata** - crow leads the bus whenever Strata sends, so the voices' ii targets (Just Friends, W/, ER-301, TELEXo, each on its own page) play. Without a crow, nothing is sent. Turning away from `strata` first sends the lows of any notes still sounding, then puts the devices back as they were.
- **teletype** - a Teletype leads the bus. Strata sends no ii message at all, and crow passes Teletype's three calls on to Strata (below).

**What `strata` risks with a Teletype on the bus.** Teletype always leads: it has no way to follow. With both a Teletype and crow sending, the two can start messages at the same time, and monome documents that setup as "not currently supported": it can lock the bus or a module until you power the case off and on again. If a Teletype is on the bus, choose `teletype`.

Strata sends at most four ii messages each 1/48 of a second, in order, so a chord to several devices is spread over a few hundredths of a second (eight notes to two devices take about 0.1 s). If more than 48 are waiting, the newest are dropped, and the `ii` section's title shows how many (`12 dropped`); slow the pattern or route fewer notes to ii. Without a crow the title shows `[--]`.

## Teletype's calls

With the bus set to `teletype` and crow connected, Strata gives crow three handlers, again each time crow is plugged in. On Teletype:

| Teletype | Does |
|---|---|
| `CROW.C1 n` | Recalls scene n (1 to 16), quantized as a scene key is |
| `CROW.C2 v x` | Voice v (1 to 7; 0 the selected voice): x 0 stops it, 1 starts it, 2 toggles it |
| `CROW.C3 1 v x` | Retriggers voice v at velocity x (0 to 127), if it is running |
| `CROW.C3 2 v x` | Freezes voice v: x 0 off, 1 on, 2 toggles |
| `CROW.C3 3 v x` | Mutes voice v: x 0 off, 1 on, 2 toggles |
| `CROW.C3 4 m x` | Sets macro m (1 to 16) to x / 16383 (x 0 to 16383) |
| `CROW.C3 5 0 x` | The patterns: x 0 stops them, 1 plays them, 2 toggles |

A call with a number out of range does nothing and prints one line in maiden. `CROW.C4` does nothing, and so do the queries (`CROW.Q0` to `CROW.Q3`): answering a query from norns can crash crow. Turning the setting away from `teletype` gives crow its own handlers back.
