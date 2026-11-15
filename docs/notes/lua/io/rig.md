## Must not break

- **Only a row of the IO page changes a rig setting** (design §2.3): `S.lib.io_rig.set(` and `step(` appear in no file of `lib/` or `strata.lua` but `lib/pages/io.lua` and `lib/io/rig.lua` (a structure test, `only the IO page changes a rig setting`). A PSET load, a scene recall, a controller, OSC and a Teletype call never change one, so the ii bus's leader (`ii_bus`) and the ports a controller or remote device holds stay where the player put them. Other modules read them with `get` and hear changes through `on_change`.
- **The rig settings are never params, scene fields or PSET data**: they live only in `io.data` (data/strata/), written through `S.lib.data_files.write` and read through `S.lib.data_files.read`, never `tab.save` or `tab.load`.
- **`set` writes first** (as `S.lib.notes.set_pool` and `S.lib.grid_core.set_rotation` do): the whole table goes to `io.data`, and only when that write worked does the value change and do its listeners hear it. A write that fails returns false and changes nothing; IO's row then flashes `setting not saved`. A value outside its key's spec, or an unknown key, is refused (false) with nothing written.
- **Listeners are contained**: each `on_change` function runs through `S.lib.ui_frame.contained_call`, so one that raises prints one `strata: io rig listener <key> failed:` line (once per distinct message) and the next listener still runs. A set to the value already held tells nobody.
- **A file it cannot use is set aside, never written over unread**: unreadable text, another version, a `values` that is not a table, or a known key holding a value outside its spec moves the file to its first free backup name (`set_aside(path, ".bak")`: `io.data.bak`, `.bak.2` ... `.bak.9`) with one console line (`strata: io.data not used (<why>): the rig settings are the defaults; kept as io.data.bak`, or `; not moved: <why>` when every backup name is taken, after which the next change writes over it), and every setting takes its default. A missing file gives the defaults with no line.
- **The `rig` invariant**: every key of `RIG.order` holds a value of its spec, and no other key is held.

## Owns

- `lib/io/rig.lua` (`S.lib.io_rig`), included directly before `lib/midi_in.lua`.
- Its unit tests: `test/unit/io_rig_test.lua`; the structure test above is in `test/unit/structure_test.lua`.

## The settings

`M.RIG = {file = "io.data", version = 1, backup_suffix = ".bak", order, specs}`. A spec is a choice (`values`, `default`) or a whole number (`min`, `max`, `default`, with `step` and `fine_step` for E3, 1 when absent, and `off_at`, the value shown as `off`):

| Key | Values | Default | Read by |
|---|---|---|---|
| `ii_bus` | `off`, `strata`, `teletype` | `off` | the ii bus (who leads it) |
| `e16_port` | 0 (off), 1 to 16 | 0 | the E16 controller |
| `e16_channel` | 1 to 16 | 16 | the E16 |
| `e16_cc` | 0 to 104, the first of 16 CCs | 102 | the E16 |
| `e16_encoding` | `rel1` (1 and 127), `rel2` (63 and 65) | `rel1` | the E16 |
| `faders_port` | 0 (off), 1 to 16 | 0 | a fader box |
| `faders_channel` | 1 to 16 | 1 | the fader box |
| `faders_cc` | 0 to 80, the first of 16 CCs | 32 | the fader box |
| `faders_hires` | `off`, `on` (14 bits, the low 7 on CC + 32) | `off` | the fader box |
| `remote_grid_port`, `remote_arc_port` | 0 (off), 1 to 16 | 0 | a grid or arc in iii mode |
| `midi_grid` | `off`, `on` | `off` | a MIDI grid through midigrid |
| `osc_feedback` | `off`, `on` | `off` | OSC's feedback |
| `osc_port` | 1 to 65535 (E3 10 a detent, ALT+E3 1) | 9000 | OSC's feedback port |

The design's text counts fifteen keys; its table, and this module, hold these fourteen.

## The functions

- `get(key) -> value`.
- `set(key, value) -> boolean`: validated, written (`{version = 1, values = {...}}`, every key), then held and told; see Must not break.
- `step(key, d, fine) -> boolean`: the value `d` detents away, a choice by `d` places, a number by `d` times `step` (`fine_step` with `fine`, which IO passes for ALT+E3), clamped to the ends; `set` when it differs. True at an end (nothing to write); false for an unknown key or a failed write.
- `text(key) -> string`: what IO's row shows: a choice as it is, a number in digits, a port at 0 as `off`.
- `on_change(key, fn)`: `fn(value, previous)` after each change; raises for an unknown key or a non-function.

## Start and cleanup

- The start step `io_rig` (85, after the grids and before 3.6's MIDI ports at 88 and `midi` at 90) resets every value to its default and reads `io.data`; a good file sets each key it holds (a key it leaves out keeps its default, a key no spec has is dropped). No listener is told: the modules that read a setting do it in their own start steps, which come later.
- The cleanup step `io_rig_save` (38, with the other data files' saves, before `buffer_paths_save` 40) writes `io.data` once more, only when the start step ran (`"unchanged"` costs no write when nothing changed).
