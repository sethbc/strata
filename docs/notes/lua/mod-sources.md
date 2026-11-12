## Must not break

- Every modulation source registers itself with `S.register_mod_source(record)` (`lib/state.lua`), in its owning module, at include time or later; nothing lists the sources centrally. MOD and the matrix read them only through `S.lib.mod_sources`, at each use, never at include time.
- `fraction(key)` and `normalized(key)` are the only places a source's value is mapped through its range: a reader that needs 0..1 or −1..1 calls them, never `value()` and `range` itself.
- `normalized` never returns a value that is not finite: a source whose `value()` is NaN, ±inf or not a number reads 0 (no modulation), and so does an unknown key, so a bad source can never send one.
- A source's `value`, `describe` and `visible` are cheap and never send or yield: MOD calls them up to 15 times a second per shown row.

## Owns

`lib/mod_sources.lua` (`S.lib.mod_sources`, 3.4, package 0a, design §10.1), over `S.registry.mod_sources`:
- `get(key)`: the source registered under `key`, or nil.
- `list(section)`: the visible sources of `section` (a source without `visible`, or whose `visible()` is true), in registration order; every section's when `section` is nil.
- `sections()`: the section names, in the order their first source registered (hidden sources count).
- `fraction(key)`: `(value - min) / (max - min)` clamped to 0..1. A value that is not a finite number reads as no modulation: 0.5 for a bipolar source, 0 for a unipolar one; an unknown key reads 0.
- `normalized(key)`: `2 × fraction - 1` (−1..1) for a bipolar source (`range[1] < 0`) and the fraction (0..1) for a unipolar one (design §10.2, Question 37), so an asymmetric bipolar range's middle is 0; 0 for a value that is not finite or an unknown key.

## The record

`S.register_mod_source({key, name, section, value = fn() -> number, range = {min, max}, describe = fn() -> string, visible = fn() -> boolean, row = {enc = fn(d), fine_enc = fn(d), press = fn(), alt_press = fn(n), hints = fn(alt) -> string}})`:
- `key`: unique (a second is refused); also the extra-offset key (`S.lib.engine_sync.set_extra_offset`) when the source moves Lua params.
- `name`: MOD's row label, 1 to 4 characters. `section`: MOD's section; a new name is a new section.
- `value`: the value now, in the source's own units, within `range`. `range[1] < range[2]`; `range[1] < 0` marks a bipolar source, drawn from the center.
- `describe`, `visible` and `row` are optional, and so is each row function; a source without `row` is read-only on MOD. A field outside the set is refused (#385).
- 3.4 registers `lfo1`..`lfo6` (section `lfos`, −1..1, 1b), `macro1`..`macro16` (`macros`, 0..1, visible in the shown bank, 1e), `gesture1`..`gesture4` (`gestures`, the loop's phase, 1f) and `input` (`audio`, 0..1, 1i).
