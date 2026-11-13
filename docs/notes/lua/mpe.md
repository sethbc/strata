## Must not break

- **`S.lib.mpe` sends no engine command and plays nothing** (design §5.4): it keeps the zones' and channels' values and says which voices a note plays. `lib/midi_in.lua` (3.5's MIDI package) calls it.
- **Zones never overlap**: while both member counts are above 0, setting one lowers the other (silently, with no second action) so their sum is at most 14; 15 members leave the other zone at 0, which is off. A zone with 0 members is off, its master channel too.
- **CC87 waits for its own channel's next pressure or CC74, once**; another channel's message never takes it, and a master channel's CC87 is dropped.
- **A data entry (CC6) acts only under RPN 0 or 6 on its own channel**; the null RPN (CC101 127, CC100 127) and a reset deselect. CC38 is read and ignored.
- **Pressure and CC74 on a master channel, and anything on a channel in neither zone, change nothing** (`control` returns `{}`). `control` returns nil only for what is not MPE's: outside the MPE modes (`midi_channel_mode` 3 and 4), a note, key pressure, and a CC that is none of 74, 87, 6, 38, 100 and 101.
- The zone and mode params are PSET params, never scene fields, and never in `param_order`.

## Owns

`lib/mpe.lua` (`S.lib.mpe`, 3.5 package 1c), included after `lib/notes.lua`, with `MPE` (`M.MPE`: `slide_cc` 74, `fine_cc` 87, `master_bend` 2, and the channel, RPN and mode constants):
- `active()`: `midi_channel_mode` is 3 (`mpe selected`) or 4 (`mpe split`).
- `zone(channel)`: `"lower"` or `"upper"` and whether it is the zone's master; nil for a channel in neither. Lower: master 1, members 2 to `1 + mpe_lower_members`. Upper: master 16, members `16 - mpe_upper_members` to 15.
- `targets(channel, note)`: the voices the note plays. Mode 3: the selected voice for a channel in a zone. Mode 4: every voice (ascending) whose `v<i>_zone` is the channel's zone and whose `v<i>_zone_low` to `_high` holds the note. Empty outside both zones and outside the MPE modes.
- `control(msg)`: applies a `midi.to_msg` table (pitch bend, channel pressure, CC74, CC87, and CC101, CC100, CC6 and CC38 as RPN 0 and 6) and returns the channels whose values changed, or nil. A master channel's bend returns its zone's members. RPN 6 on channel 1 or 16 sets that zone's member count (clamped 0-15; the other zone may be lowered) and flashes `MPE lower <n>` or `MPE upper <n>` through `S.lib.ui_flash`. RPN 0 on a member channel sets `mpe_bend_range` (1-96) and returns every member channel; on a master channel it sets that zone's master range (kept in state, 2 by default) and returns the zone's members. RPN 6 on a member channel and RPN 0 outside both zones do nothing.
- `values(channel)`: `{bend, pressure, slide}`. `bend` is `2 ^ (((raw - 8192) / 8192) * range / 12)` for the channel (the member range `mpe_bend_range`) times its zone's master ratio (a master channel's is its own, at the master range); the ratio is computed at read, so a changed range applies to the bend last received. `pressure` is nil until the channel's first, then 0-1; `slide` is 0-1. A seven-bit value is `val / 127`, with a pending CC87 `(val * 128 + fine) / 16383`.
- `reset()`: every channel's values, pending CC87 and RPN state, and the masters' ranges, forgotten (the MIDI package calls it on a port, mode or zone change).
- `add_midi_params()` (the last three of `strata_midi`, called inside `lib/params_setup.lua`'s midi record): `mpe_lower_members` (0-15, default 15), `mpe_upper_members` (0-15, 0), `mpe_bend_range` (1-96, 48).
- `add_params()` (the record `zones`): group `strata_zones`, 21 params: per voice `v<i>_zone` (`off`, `lower`, `upper`; voice 1 lower, voice 2 upper, the rest off), `v<i>_zone_low` and `v<i>_zone_high` (0-127, 0 and 127; each clamps the other so a low never passes its high).

`midi_channel_mode`'s two MPE options are in `S.lib.midi_in.MIDI.channel_mode_options`; until the MIDI package lands the modes play as `per voice` (`docs/notes/lua/midi.md`).
