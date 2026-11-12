## Must not break

- MOD draws and edits a modulation source only through its record (`S.lib.mod_sources`: `name`, `describe()`, `row` with `enc`, `fine_enc`, `press`, `alt_press`, `hints`), never through the module that registered it, so a source registered later (3.5's MPE, 3.6's crow and CC inputs, a test's) shows with no change here. A source without `row` is read-only: E3, K3 and ALT+K3 do nothing and the hint row is empty. The page knows two sections by their sources: the macros (K3 opens the target view, the value right-aligned, ALT+E2 and the button change the bank) and the gestures (the arc button presses a recorder).
- The rows are built from the registry at each use (`build_rows`: `MOD_PAGE.sections` in order, then every other section in the order its first source registered; a section with no row is left out), and the cursor follows its row's id (`S.mod_page.row_id`): the row keeps the cursor when rows come and go, and where the id is gone (a bank change) the cursor keeps its index, so a bank change from any surface puts it on the same row of the new bank. Always move the cursor through the page (`place`, E2, K2, closing a view), never by setting `S.mod_page.row`.
- Every encoder edit goes through `enc_param_delta(3, id, d)` (center detents; ALT+E3 fine on a control param) or a source's own `enc`/`fine_enc`; a binary param (scatter's toggles, a routing's on/off) through `set_binary_param` (#538). The target view's min and max are not params: they go through `S.lib.macros.set_target`, the routing view's source and destination through `S.lib.matrix.edit_routing` (its 25 % rule for a routing it completes), never `set_routing`.
- Learn (ALT+K3: `S.lib.macros.learn` on a target row, `S.lib.matrix.learn` on the routing view's `dest` row) ends on K2 (which closes the view) and on leaving the page (the record's `leave`), besides the modules' own 10 s and the touch.
- ALT+K2 goes through the shared handler (`S.lib.ui_alt.k2_down` and `k2_up(record)`, #557): `randomize_section()` gives the scatter section's spec (`scatter_depth` a whole percent 0-30, `scatter_rate` even in octaves 0.02-0.5 Hz) and the matrix section's (the depth of every complete routing, a whole percent −50..50, on or off; nil when none is complete), and nil in the macros, morph, gestures, lfos and any registered section (a macro apply writes up to eight params the undo would not hold). The target view follows the macros, the routing view the matrix. Every param a spec draws calls `note_param_edit` from its action (`lib/scatter.lua`, `lib/matrix.lua`).
- `alt_hold()` clears only what is under the cursor: a target row with an id, the routing (list or view: `S.lib.matrix.clear`), a source's `alt_press(2)` (a recorder's clear); elsewhere nothing, and `alt_hold_hint()` then says `cancel`, else `clear`.
- With ALT held the hint names only keys that act (#419): ALT+K3 only on a routing (on/off), a source with `alt_press` (its own `hints(true)`: a playing recorder's `K3:dub`), and in the views (learn, on the routing view's `dest` row only).
- The rings read and move the page's state only through `S.lib.pages_mod` (`docs/notes/lua/arc-pages.md`); the page sets no arc field. The arc button is the record's `arc_button`.
- Every row stays inside 128×64 at its widest: values are cut to the room left of them and a row's text to the room before its value (`S.lib.ui_text.fit_text`, after `printable`), so a source's long describe, a later release's long name and a stored unknown key or id never cross the value or leave the screen (the layout states).

## Owns

- `lib/pages/mod.lua` (`S.lib.pages_mod`): the MOD record, `S.MOD_PAGE` (the sections, layout, levels, the bound steps, the randomize ranges) and the page state `S.mod_page` (`row`, `row_id`, `view`, `views`, `macro`, `target_row`, `target_column`, `routing`, `routing_row`). Module fields: `place(id)`, `view()`, `section()`, `cursor_routing()`, `routing()`, `macro()`, `target_row()`, `target_bounds()`, `nudge_bound(which, amount)`, `move_target_row(steps)`, `move_routing(steps)`, `step_source(steps)`, `step_dest(steps)`, `source_position()`, `dest_position()`, `routing_plays(k)`, `carry_context(with_routing)`.
- The sources, macros, scatter, morph, recorders, LFOs and the matrix are their modules' (`docs/notes/lua/mod-sources.md`, `macros.md`, `scatter.md`, `morph.md`, `gestures.md`, `lfos.md`, `matrix.md`).
- Its unit tests: `test/unit/pages_mod_test.lua`. Its rings: `lib/arc/mod.lua` (`docs/notes/lua/arc-pages.md`).

## The list

Five rows from y 18, 8 px apart (`S.lib.ui_field_list`, the scroll marker at x 127). A section label at x 0, level 2. A row: its label at x 6, its text from x 24 (or 4 px after a label wider than 14 px), its value right-aligned at x 124. Levels: the cursor's row 15, the others 8; a routing that is off or incomplete 4 (10 under the cursor).

| Section | Rows | Shows | E3 | K3 |
|---|---|---|---|---|
| macros | `bank` | `1  M1-M4` | the bank (1-4) | the next bank (4 wraps to 1) |
| | the shown bank's four macros (`M1`-`M16`) | describe (`v3 pitch +2`), the value right (`42%`) | the macro's `enc` | the target view |
| morph | `A`, `B` | the slot's label (`S3 dusk`) | `morph_a`, `morph_b` | — |
| | `morph` | `35%` | `morph` | — |
| scatter | `on`, `pitch`, `pos`, `size`, `cutoff`, `amp` | on/off | on (+), off (−) | toggle |
| | `depth`, `rate` | `10%`, `0.10 Hz` | the param | — |
| gestures | `G1`-`G4` | describe (`empty`, `rec 3.2 s`, `play 2 bars`) | quantize (`enc`) | `press` |
| lfos | `L1`-`L6` | describe (`v3 pitch~ 25% <L2`) | depth (`enc`) | `press`: the LFO page with that LFO selected (`show_lfo`) |
| matrix | `R1`-`R16` | `L2>v3 pitch~` and the depth right (`+40%`); `-` when empty | the depth | the routing view |
| audio (and any other) | `IN`, ... | describe | the record's `enc` | the record's `press` |

- E2 moves over the rows (clamped). K2 jumps to the next section's first row, after the last to the first. ALT+E2 on a macro row shows the next bank (with E2 back, the bank before), the cursor on the same row of it. ALT+E3 is the row's `fine_enc` or a fine `enc_param_delta`.
- ALT+K3: a routing's on/off; a source's `alt_press(3)` (a recorder's overdub). ALT+K2 held 0.5 s: `alt_hold()`.
- A routing row draws its source by name (`S.lib.mod_sources.get(key).name`) and its destination by its LFO destination label (from `S.LFO_DESTINATIONS`), with `~` when the param it resolves to now is one of the five fast ones (`S.lib.lfos.fast_destination`; a voice's main entry follows its source); a key or id this build lacks as stored, cut to the room.
- Hints: `K3:bank E3:bank`; the source's own (`K3:targets E3:value`, `K3:rec E3:quant`, `K3:lfo E3:depth`, `E3:gain`); `E3:scene`, `E3:morph`, `E3:depth`, `E3:rate`; `K3:on|off E3:on/off`; `K3:edit E3:depth`. With ALT: `S.lib.ui_alt.k2_hint(record)` (`K2:rand`, `K2:undo`, then once held `K2:clear` or `K2:cancel`), ALT+K3's (`K3:on|off`, `K3:dub`), `E2:bank` on a macro row, `E3:fine` on a row that turns finely. K1 let go while ALT+K2 is down: K2's hint alone.

## The target view

K3 on a macro row. y 16: `M<m> targets` (15) and the macro's value right-aligned (8). Rows 1-8, five in view from y 24, 7 px apart: the number at x 0, the target's label from x 8 (`-` for an empty row; an id this build lacks as stored, at 4; `learn` while learn waits for the row), and `min>max%` right-aligned at x 124 (min and max in whole percents, a tenth shown where they have one; `90>20%` inverted). On the cursor's row the column under the cursor is at 15 and the rest at 8; the other rows at 4.
- E2 the row; K3 the next column (target, min, max, wrapping); E3 the column: the target steps through `S.lib.macros.target_ids()` (none first; ALT+E3 jumps a group: the LFO destinations' groups, then the LFOs' rate and depth, then the routings' depths), min and max 1 % a detent, ALT+E3 0.1 % (`MOD_PAGE.bound_step`, `bound_fine_step`), clamped to 0..1. An empty row takes no bound.
- K2 back (the list cursor on the macro's row). ALT+K3 learn. ALT+K2 held empties the row.
- Hints: `K2:back K3:col E3:target|min|max`; ALT `K2:rand K3:learn E3:group|fine`.

## The routing view

K3 on a routing row. y 16: `R<k> routing` and `on`/`off` right-aligned. Rows from y 24, 7 px apart: `source` (the name), `dest` (the label, `~` on a fast destination; `learn` while learn waits), `depth` (`+40%`), `on`; the cursor's row at 15, the others at 4.
- E2 the row; E3: the source through `S.lib.mod_sources.list()` in registration order (none first; ALT+E3 jumps a section), the destination through `S.lib.matrix.destination_ids()` (ALT+E3 jumps a group), the depth (ALT+E3 fine), on/off. A source or destination not in the list (a key this build lacks, a macro of a bank not shown) steps from none. K3 on/off; K2 back (the list cursor on the routing's row). ALT+K3 on `dest`: learn. ALT+K2 held clears the routing.
- Hints: `K2:back K3:off|on E3:source|dest|depth|on`; ALT `K2:rand` with `K3:learn E3:group` on `dest`, `E3:section` on `source`, `E3:fine` on `depth`.

## Redraws

Every edit asks for a redraw (param actions, `enc`, `key`, the rings; the macros' `set_bank`, the matrix's and the recorders' own changes). `animates` is true while ALT+K2 is down (its hint turns at the hold time), while a recorder records (its row counts seconds) and while a row of a section MOD does not list in `MOD_PAGE.sections` is in view (a live value: the input level).

## Layout states

Every section's first and last row (the bank row; M16 of bank 4 with every macro's eight targets at the widest label and 100 %; morph A with a twelve-letter scene name; the morph at 100 %; scatter on; scatter amp with depth and rate at the top; G1 and G4 with the four recorders empty, playing, stopped and recording; L1 and L6 with six LFOs engine-run and modulated; R1 with an empty, an off, an incomplete and an unknown routing; R1 and R16 with all sixteen routings at their widest; IN), a section registered by a test, ALT+K2 held on a macro row (`K2:cancel E2:bank E3:fine`) and on a playing recorder (`K2:clear K3:dub`), the target view of M16 at rows 1 and 8 with each column, M1's target view learning, the routing view of R16 at its widest with each row, and a routing with unknown parts.
