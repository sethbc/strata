## Must not break

- **IO is the tenth page, appended** to `UI_PAGES`, so no other page's index moved (`UI_PAGES.index.SETUP` is still 9). E1 stops at MAIN and IO.
- **The page owns no setting**: its rows edit params (`enc_param_delta`, or `set_binary_param` for a binary), the rig settings (`S.lib.io_rig.step`, the only caller besides the rig module itself, structure tests), run a section's action, or show text. It never calls `params:delta`, `params:set` or `S.lib.io_rig.set` on a row's behalf otherwise.
- **Sections show in `IO_PAGE.sections`' order** (`voice`, `midi`, `crow`, `ii`, `wtape`, `controllers`, `remote`, `osc`, `tape`), whatever order their modules register in; any other name follows them in registration order. Only a registered section shows: with none, the page draws `no sections`.
- **The rows are rebuilt at each use** (`M.rows()`, the draw, the hints, each key and encoder): a section's `rows()` and `status()` are read live, so a module never tells the page it changed; it calls `request_redraw()` as everywhere.
- **A section is contained**: its title (when a function), `rows()` and `status()` each run through `S.lib.ui_frame.contained_call`, as does a row the page cannot draw (a kind it does not know, a missing label, field or param, an unknown rig key); one that raises prints one `strata: io section <name> <part> failed:` line per new message, its title row shows `error` at the right and the section shows no rows, while the other sections draw. An action's `run` and a detail's fields are contained the same way.
- **The cursor (`S.io_cursor`) rests only on a selectable row** (`field_list.clamp`): a title and a status row are `selectable = false`.
- **The cursor follows its row, not its index**: the rows are rebuilt at each use, and a row that comes or goes above the cursor (a device plugged in) would otherwise put E3 on another row. `place` remembers the cursor's row by its identity (`row_ids`: its section and its own name, a param row's `param_id`, a rig row's `key` or the row's `id`, falling back to its label only for a row with none; then how many rows of that section and name come before it) and the index it was put at; `follow`, at the start of every draw, hint, encoder and key, finds that row again, and when it is gone puts the cursor on the nearest selectable row at or before its old place. `S.io_cursor` stays the row index (the tests read it); a cursor set from outside is taken where it is. A section gives an `id` to an action, status or detail row that can share its label with another in the section.
- **E3 and K3 never act on a row no draw has shown under the cursor**: when the cursor's own row went and it fell to another (`view.unseen`), E3, ALT+E3 and K3 only ask for a redraw until a draw has shown that row lit; E2, K2 and `show_section` place the cursor deliberately and clear it.
- **While the cursor's row is out of view E3 and K3 only bring it back** (`hidden`: scrolled past it with E2, as SETUP, or a section `show_section` put at the top without it); the hint row then reads `E2:row E3:back`.
- **A rig row's failed write flashes `setting not saved`** on the hint row (`S.lib.ui_flash`, scoped to IO), as SETUP's device settings do.
- **ALT+E2 selects the voice through `S.lib.ui_keys.select_voice_by`**, never by setting `S.selected_voice`; ALT+E3 on a rig row steps it finely (`step(key, d, true)`), and on a param row reaches `enc_param_delta`, which is fine with ALT held.
- **No arc fields**: IO's arc file (the tape's rings) comes later in 3.6; until then the rings stay dark on IO (`test/unit/ui_pages_test.lua` exempts IO beside SETUP).

## Owns

- `lib/pages/io.lua` (`S.lib.pages_io`): the IO record (`draw`, `hints`, `enc`, `alt_enc`, `key`, `leave`, `layout_states`), `S.io_cursor`; on the module `IO_PAGE` (the layout, the section order, the row kinds and the texts), `rows()` and `show_section(name)`.
- The registry it reads, `S.registry.io_sections`, and its register function `S.register_io_section` are in `lib/state.lua` (`docs/notes/lua/state-and-voices.md`).
- Its unit tests: `test/unit/pages_io_test.lua`; the registry's checks are in `test/unit/registries_test.lua`.

## Sections

`S.register_io_section({name, title, rows, status, layout_states})`: `name` a string no other section has; `title` a string or a function returning one; `rows` a function returning a list of rows; `status` optional, a function returning a string or nil (a device's `[--]`, the bus leader, a drop count, `map clash`); `layout_states` optional, a list of `{name, setup = fn(context)}`. Any other field is refused. The registry is read at each use and stays open.

## Rows

Each row a section returns is `{label, kind, ...}`, with an optional `id` (a string or a number) naming the row where its `param_id` or `key` does not (an action, a status, a detail), so the cursor keeps to it when rows come and go:
- `param`: `param_id`, optional `binary = {[0] = text, [1] = text}` and `format` (a `string.format` pattern); otherwise the param's own string. E3 through `enc_param_delta(3, id, d)`, or `set_binary_param(id, d > 0 and 1 or 0)` for a `binary` row or a binary param.
- `rig`: `key`, a rig setting; shows `S.lib.io_rig.text(key)`. E3 calls `step(key, d)`, ALT+E3 `step(key, d, true)`; false flashes `setting not saved`.
- `action`: `run`, `hint` (the K3 hint's word), optional `text` (a function: what was last done, shown at the right). K3 runs it; E3 does nothing.
- `status`: `text`, a string or a function; drawn dim, at the row indent, never selectable.
- `detail`: `text` (a function, shown at the right), `fields` (a list of `param` and `rig` rows). K3 pushes a modal owner (`S.lib.ui_modal.push`) that lists the detail's label as a title and its fields: E2 moves, E3 edits the field under its cursor (ALT+E3 finely), K2 closes it (`pop`), and the page shows again with its cursor on the detail's row. Leaving the page closes it, and ends a view `show_section` pinned, so the next visit opens on the cursor's row.

Drawing (`IO_PAGE`): six rows at y 18-53, 7 px apart (as SETUP), values right-aligned at x 124 (the scroll marker owns x 127). A title row draws the section's title at x 0 and its status right-aligned at x 124, both at level 10, the title cut to the room the status leaves. A section's rows start at x 4 (`row_indent`), the label at level 15 under the cursor and 4 otherwise, the value cut to the room the label leaves (`value_gap` 4 px between them). The page copies each row it shows (with its `section` and what it shows); a section's own tables are never changed.

## Keys

- **E2** moves over the selectable rows (`field_list.move_scroll`: past the last one it scrolls the view over the rows below; while it is scrolled, E3 only scrolls back, as SETUP).
- **E3** edits a `param` or `rig` row.
- **K2** jumps to the next section's first selectable row, wrapping from the last section to the first.
- **K3** runs an `action` or opens a `detail`.
- **ALT+E2** selects the voice (the `voice` section shows the selected voice's routes). ALT+K2 and ALT+K3 do nothing here.

Hints: `E2:row E3:value K2:section` on a param or rig row, `E2:row K2:section K3:<hint>` on an action, `E2:row K2:section K3:open` on a detail, `E2:row E3:back` while the cursor's row is out of view, `E1:page` with no section; with ALT held `E2:voice`, plus `E3:fine` on a rig row or a control param. The detail list's: `E2:field E3:value K2:close` (`E2:field E3:fine` with ALT).

## Layout states

The page has one state of its own, `ALT held` (its ALT hint row; with no section registered it is also the render of `no sections`, which the render test needs for every page). The start step `io_layout_states` (16, after VOICE's at 15) adds to it: for each registered section, in the page's order, `<name> at the top` (`show_section(name)`), then each of the section's own states as `<name>: <state>`, run after `show_section(name)`. So the layout tests and the page renders draw every section a module registers without an edit here. `show_section(name)` puts the section's title at the top of the view (or as near it as the list's end allows) whether or not the section has a selectable row, since a section without its device may show only status rows (design §11). The cursor goes on the section's first selectable row; with none, on the nearest selectable row before the section, else the first after it, else it stays. The view is pinned to the section (`view.pinned`, by name, so it survives a rebuild): the draw passes `field_list.draw` the row after the title as its cursor, so the title is the row above at the top, and lights the real cursor's row. E2 or K2 ends the pin; E3 or K3 ends it without acting when the cursor's row is out of that view. It returns true for a registered section (which always shows its title row), false otherwise.
