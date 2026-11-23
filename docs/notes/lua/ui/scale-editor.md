## Must not break

- **The editor is a modal owner** (`S.lib.ui_modal`): open exactly while its own owner is the modal top, but beneath SEQ's step editor as the zones editor allows (a registered invariant, "scale editor"). SETUP's key handler does not run under a modal owner, so it and the zones editor are never open together.
- **A class toggle under a built-in scale (or off) writes `scale_mask` first, then `scale` = custom**, so the one `setScale` (custom's action) carries the new mask; `scale_mask`'s action sends nothing while the scale is not custom. Under custom only `scale_mask` changes. The last class cannot be turned off (the mask stays 1-4095).
- **In a tuning that is not twelve notes to an octave** (`S.lib.tuning.scale_active()` false) the scale and notes rows show `--`, E3 and K3 there change nothing, and the note tap takes no note.
- **A pending tuning choice sends nothing**: E3 on the tuning row moves it (drawn dim), K3 applies it through `S.lib.tuning.select` (one `setTuning` set); closing drops it. The folder is listed once, at open (`S.lib.tuning.files()`, a shell's `ls`).
- **The note tap is the editor's while it is open**: `S.lib.midi_in.set_note_tap(M.note)` at open and again at each draw (`reset_midi_input` clears the tap without telling its owner), cleared at close. A note it takes plays nothing.
- **A refused file's reason shows on the editor's own hint row, and no other flash does**: under a modal owner `redraw()` takes the hints from the owner, never from the "hints" flash, so the owner's `hints` returns `S.lib.ui_flash.text("hints")` while it is the reason the editor flashed (`editor.reason`, dropped at open and close; the flash itself, started with SETUP's page, ends on its clock). Another module's hints flash, unscoped (a scenes or buffers load's) or SETUP's, never covers the editor's keys (#843).
- **Cleanup closes an open editor** (`CLEANUP_ORDER.scale_editor`, 139): its owner leaves the modal stack and the note tap is cleared, as the factory list's step closes it (#847).

## Machines

### scale editor
- **State:** `editor = {open, row, class, choices, pending, reason}` (local to `lib/ui/scale_editor.lua`), read through `S.lib.ui_scale_editor.is_open()`; `pending` is the tuning row's dim choice, `reason` a refused file's flash; the note tap (`S.lib.midi_in.set_note_tap`) is the editor's while it is open.
- **Invariant:** `scale editor`: the open editor's owner is the modal one (or lies beneath SEQ's step editor), the closed editor's never; its cursor is on a row and a class; a pending choice is one of the choices.
- **Test:** `test/unit/ui_scale_editor_test.lua`: "SETUP's scale & tuning row opens the editor; K2 closes it" (and "the tuning row: E3 moves a dim pending choice and K3 applies it; a refused file says why", "cleanup closes the editor and clears the note tap").

No test runs this table: it is one of the design's modal owners (its section 5, a table and no test). It lists the events that open or close the editor and those that set or apply a pending choice; every other key or turn (E2's row, E3 on the root, the scale or the class cursor) is its own editing and leaves it open, and a cleanup of a closed editor does nothing. Its opens and closes are a row of the owners' table (`docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner).

| State | Event | Next | Effect |
|---|---|---|---|
| closed | K3 on SETUP's `scale & tuning` row | open | the tuning choices listed, nothing pending, the note tap set, pushed |
| open | E3 on the tuning row | open | a pending choice (drawn dim), nothing sent |
| open | K3 on the tuning row with a choice pending | open | applied through `S.lib.tuning.select`, nothing pending |
| open | K3 on the notes row, or a MIDI note | open | the class toggled |
| open | K2 (no ALT) | closed | the tap cleared, the pending choice and reason dropped, popped |
| open | cleanup (step 139) | closed | as K2 |

## lib/ui/scale_editor.lua (`S.lib.ui_scale_editor`)

Opened from SETUP's `scale & tuning` row (K3; an action row appended after `transport`, 3.8 ruling 44). Fields: `open`, `close`, `is_open`, `note(key)` (the tap) and `SCALE_EDITOR` (the layout); its cleanup step (139) closes it.

Rows, top to bottom, six visible from y 18, 7 px apart, values right-aligned at x 124 (`S.lib.ui_field_list.draw`, as SETUP's and the zones editor's):

| Row | Shows | E3 | K3 |
|-----|-------|----|----|
| root | `params:string("root")` | `enc_param_delta` on `root` | |
| scale | the scale's name, or `--` | `enc_param_delta` on `scale` (not under `--`) | |
| notes | twelve cells, a degree from the root each, 8 px apart from x 28: a natural's letter, `#` for a sharp, `.` for a class out of the scale; or `--` | the class cursor (0-11, clamped) | toggles the class |
| tuning | the tuning's name, or the pending choice's (dim), cut by `S.lib.ui_text.fit_text` | the pending choice: the built-ins, then the folder's files | applies it |

The hint row: `K2:back E3:value` (root, scale), `K2:back E3:note K3:<the cursor's class>` (notes), `K2:back E3:tuning` (tuning; `K2:back K3:apply E3:tuning` while a choice is pending), `K2:back` alone on a row showing `--`; with ALT held E3 turns as without (no row has a fine step) and K2 and K3 do nothing, so the hints are `E2:row E3:value` (or `E3:note`, `E3:tuning`), `E2:row` alone on a `--` row (#419); a refused file's reason while its flash shows (only the editor's own, #843). A file's name is drawn through `S.lib.ui_text.printable` and measured as drawn (#551); a file's choice is named by `S.lib.tuning.file_tuning_name`, the rule its tuning's name follows, so E3 steps on from an applied file.

The note tap (`M.note(key)`): while open and the scale applies, a note toggles class `(key - (60 + root)) % 12` and is taken. A refused file (`S.lib.tuning.load_file`'s reason) leaves the tuning as it was.

SETUP's record carries the editor's layout states (`scale_editor_state` in `lib/pages/setup.lua`): the cursor on root; the widest scale name (`Gagaku Rittsu Sen Pou`, 97 px, right-aligned at 124 it starts at x 27, clear of `scale`); every class in (`C # D # E F # G # A # B`); the longest built-in (`meantone 1/4`); a long file name (as `load_file` gives it, cut to `name_max`, then by `fit_text`); a non-ASCII file name, drawn printable; 19 equal's `--`; a pending choice; a refused file's reason on the hint row. Each layout state's note tap is a do-nothing stand-in.

Tests: `test/unit/ui_scale_editor_test.lua` (the SETUP row, the rows and E3, the class toggle's order and its one `setScale`, the last class, the note tap open and closed, 19 equal's `--`, the pending tuning and a refused file, another module's flash left off its hint row (#843), the cleanup step, every state's layout).
