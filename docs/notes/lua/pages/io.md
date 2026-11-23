## Must not break

- **IO is the tenth page, appended** to `UI_PAGES`, so no other page's index moved (`UI_PAGES.index.SETUP` is still 9). E1 stops at MAIN and IO.
- **The page owns no setting**: its rows edit params (`enc_param_delta`, or `set_binary_param` for a binary), the rig settings (`S.lib.io_rig.step`, the only caller besides the rig module itself, structure tests), run a section's action, or show text. It never calls `params:delta`, `params:set` or `S.lib.io_rig.set` on a row's behalf otherwise.
- **Sections show in `IO_PAGE.sections`' order** (`voice`, `midi`, `crow`, `ii`, `wtape`, `controllers`, `remote`, `osc`, `tape`), whatever order their modules register in; any other name follows them in registration order. Only a registered section shows: with none, the page draws `no sections`.
- **The rows are rebuilt at each use** (`M.rows()`, the draw, the hints, each key and encoder): a section's `rows()` and `status()` are read live, so a module never tells the page it changed; it calls `request_redraw()` as everywhere.
- **A section is contained**: its title (when a function), `rows()` and `status()` each run through `S.lib.ui_frame.contained_call`, as does a row the page cannot draw (a kind it does not know, a missing label, field or param, an unknown rig key); one that raises prints one `strata: io section <name> <part> failed:` line per new message, its title row shows `error` at the right and the section shows no rows, while the other sections draw. An action's `run` and a detail's fields are contained the same way.
- **The cursor (`S.io_cursor`) rests only on a selectable row** (`field_list.clamp`): a title and a status row are `selectable = false`.
- **The cursor follows its row, not its index**: the rows are rebuilt at each use, and a row that comes or goes above the cursor (a device plugged in) would otherwise put E3 on another row. `place` remembers the cursor's row by its identity (`row_ids`: its section and its own name, a param row's `param_id`, a rig row's `key` or the row's `id`, falling back to its label only for a row with none; then how many rows of that section and name come before it) and the index it was put at; `follow`, at the start of every draw, hint, encoder and key, finds that row again, and when it is gone puts the cursor on the nearest selectable row at or before its old place. `S.io_cursor` stays the row index (the tests read it); a cursor set from outside is taken where it is. A section gives an `id` to an action, status or detail row that can share its label with another in the section.
- **E3 and K3 never act on a row no draw has shown under the cursor**: when the cursor's own row went and it fell to another (`view.unseen`), E3, ALT+E3 and K3 only ask for a redraw until a draw has shown that row lit; E2, K2 and `show_section` place the cursor deliberately and clear it. The draw that ends it marks the row: `IO_PAGE.unseen_mark` (`>`, level 15) at x 0, before the label at `row_indent` (#902), in the plain and the pinned view alike; the next draw has no mark.
- **While the cursor's row is out of view E3 and K3 only bring it back** (`hidden`: scrolled past it with E2, as SETUP, or a section `show_section` put at the top without it); the hint row then reads `E2:row E3:back`.
- **An action row's `hint` must fit the hint row**: `draw_hints` cuts a long one, so `test/unit/pages_io_test.lua` walks every row E2 reaches in every layout state and fails one that `S.lib.ui_header.hint_fits` refuses (a row whose label is too long gives a short `hint`, as W/ tape's `start` and `end`).
- **A rig row's failed write flashes `setting not saved`** on the hint row (`S.lib.ui_flash`, scoped to IO), as SETUP's device settings do.
- **ALT+E2 selects the voice through `S.lib.ui_keys.select_voice_by`**, never by setting `S.selected_voice`; ALT+E3 on a rig row steps it finely (`step(key, d, true)`), and on a param row reaches `enc_param_delta`, which is fine with ALT held.
- **A layout state reaches a row only through `go_to_row(who, section, match)`** (#707): it shows the section, finds the first of its rows with `match`'s one identity (`param_id`, `key` or `id`), turns E2 over the selectable rows between the cursor and it (either way), checks the cursor landed and returns the row. It turns nothing and presses nothing: E3 on a rig row, K3 on an action or detail row stays the caller's. It raises at level 0, `<who> layout: no row <identity> in <section>` (before the cursor moves) or `<who> layout: the cursor did not reach <identity>`, where `<identity>` is the field and its value (`key e16_port`). Its preconditions are its own, checked before it shows or turns anything: IO is the page shown (`S.ui_page`), no list is open over it (`S.lib.ui_modal.top()`, where E2 would go) and ALT is not held (`S.alt_held`, where E2 would select the voice); each raises at level 0 naming what is in the way (`<who> layout: the IO page is not shown`, `a detail list is open`, `a list is open over the page` for another modal owner, `ALT is held`), with the cursor, the selected voice, the params and the rig as they were. It never closes a list: a caller that wants one closed closes it. The layout harnesses (`test/render_pages.lua`, `test/unit/ui_layout_test.lua`) run each state on a fresh load with its page shown and press ALT only after it; the six callers' states meet the rest. A module carries no copy of these lines; a section never lists one identity twice.
- **No page change happens under the detail list** (#899): the record's `leave` ends a pinned view and closes nothing; while the list (a modal owner) is pushed, E1 does nothing and the page's keys never run (`docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner).
- **The arc fields are `lib/arc/io.lua`'s** (the tape's level, speed, feedback and wear, `docs/notes/lua/arc-pages.md`): this page sets neither `arc_delta` nor `arc_redraw`, and only SETUP has no ring file (`test/unit/ui_pages_test.lua` counts nine).

## Machines

### io detail
- **State:** `detail.owner` (local to `lib/pages/io.lua`): nil while closed, the page's own `detail_owner` while open, with the list's `label`, `fields`, `section` and `cursor` set at the open; `S.lib.ui_modal.top()` names who has the controls.
- **Invariant:** `io detail`: the list is open exactly while its owner is the modal one, or beneath SEQ's step editor (the one owner a grid can push over it); closed, its owner is never the modal one.
- **Test:** `test/unit/pages_io_test.lua`: "the io detail invariant: the detail is open exactly while its owner is on the stack" (and "IO's leave closes no detail: a page change cannot happen under an owner").

No test runs this table: it is one of the design's modal owners (its section 5, a table and no test). It lists the events that open or close the list; E2 (its cursor) and E3 (the field's value) are its own editing and leave it open. No page change happens while it is open (E1 does nothing under an owner, and the page's keys never run), so a page change from open is no row. A cleanup leaves it as it is (#899).

| State | Event | Next | Effect |
|---|---|---|---|
| closed | K3 on a detail row | open | pushed; its title and fields drawn, E2, E3 and K2 its own |
| closed | K3 on a detail row whose fields cannot be drawn | closed | contained: one `strata: io section <name> detail failed:` line, nothing pushed |
| open | K2 | closed | popped; the page shows, its cursor on the detail's row |
| open | E1 | open | nothing (#899) |
| open | the grid's step editor pushed over it | open | covered: the controls are the step editor's until it closes |

### io view
- **State:** `view = {tail, pinned, anchor, index, unseen}` (local to `lib/pages/io.lua`) and `S.io_cursor`: in view; scrolled past the cursor's row (`tail > 0`); pinned (`pinned`, a section `show_section` put at the top); unseen (`unseen`, the cursor fell to another row that no draw has shown). `hidden(rows)` names the scrolled view and a pinned one without the cursor's row.
- **Invariant:** none: any mix of the three is legal (unseen comes over any view, and a draw ends it leaving the view as it was), and the cursor resting on a selectable row is `S.lib.ui_field_list.clamp`'s.
- **Test:** `test/unit/pages_io_test.lua`: "IO marks the row its cursor is on when that row is unseen" (and "E3 and K3 on a row that has gone only move the cursor", "leaving IO ends a pinned view").

No test runs this table: IO's view is one of the design's smaller entries (its section 5, a table and no test). It lists the keys and the events that move the view; ALT+E2 (the voice) leaves the view as it was, and ALT+E3 acts as E3 does here (finely on a rig row).

| State | Event | Next | Effect |
|---|---|---|---|
| in view | E2 | in view | the next selectable row (past the last one the view scrolls: scrolled) |
| in view | E3 or K3 | in view | edits the row, runs its action or opens its detail |
| in view | the cursor's row goes | unseen | the cursor on the nearest selectable row at or before its place |
| in view | `show_section` | pinned | the section's title at the top, the cursor on its first selectable row |
| scrolled | E3 or K3 | in view | only the view comes back (`E2:row E3:back`) |
| scrolled | K2 | in view | the next section's first selectable row |
| pinned | E2 or K2 | in view | the pin ends, and the cursor moves |
| pinned | E3 or K3, the cursor's row out of the pinned view | in view | only the view comes back |
| pinned | leaving the page | in view | `leave` ends the pin, so the next visit opens on the cursor's row |
| unseen | a draw | in view | the row lit and marked `>` (#902); the view as it was |
| unseen | E3, ALT+E3 or K3 | unseen | a redraw asked for, nothing edited or run |
| unseen | E2, K2 or `show_section` | in view | the cursor placed deliberately (pinned after `show_section`) |

## Owns

- `lib/pages/io.lua` (`S.lib.pages_io`): the IO record (`draw`, `hints`, `enc`, `alt_enc`, `key`, `leave`, `layout_states`), `S.io_cursor`; on the module `IO_PAGE` (the layout, the section order, the row kinds and the texts), `rows()`, `show_section(name)` and `go_to_row(who, section, match)`, the one way a layout state reaches a row (the controllers', remote, w/ tape, ii, TELEXo and targets' states use it).
- The registry it reads, `S.registry.io_sections`, and its register function `S.register_io_section` are in `lib/state.lua` (`docs/notes/lua/state-and-voices.md`).
- Its unit tests: `test/unit/pages_io_test.lua`; the registry's checks are in `test/unit/registries_test.lua`.

## Sections

`S.register_io_section({name, title, rows, status, layout_states})`: `name` a string no other section has; `title` a string or a function returning one; `rows` a function returning a list of rows; `status` optional, a function returning a string or nil (a device's `[--]`, the bus leader, a drop count, `map clash`); `layout_states` optional, a list of `{name, setup = fn(context)}`. Any other field is refused. The registry is read at each use and stays open.

## Rows

Each row a section returns is `{label, kind, ...}`, with an optional `id` (a string or a number) naming the row where its `param_id` or `key` does not (an action, a status, a detail), so the cursor keeps to it when rows come and go. A row with no `param_id`, `key` or `id` is known by its label, so its label must not change from one rebuild to the next: a live value belongs in its `text`, or the row carries an `id` (a row whose label changes loses the cursor's anchor at each rebuild, and E3 and K3 then never act on it):
- `param`: `param_id`, optional `binary = {[0] = text, [1] = text}` and `format` (a `string.format` pattern); otherwise the param's own string. E3 through `enc_param_delta(3, id, d)`, or `set_binary_param(id, d > 0 and 1 or 0)` for a `binary` row or a binary param.
- `rig`: `key`, a rig setting; shows `S.lib.io_rig.text(key)`. E3 calls `step(key, d)`, ALT+E3 `step(key, d, true)`; false flashes `setting not saved`.
- `action`: `run`, `hint` (the K3 hint's word), optional `text` (a function: what was last done, shown at the right). K3 runs it; E3 does nothing.
- `status`: `text`, a string or a function; drawn dim, at the row indent, never selectable.
- `detail`: `text` (a function, shown at the right), `fields` (a list of `param` and `rig` rows). K3 pushes a modal owner (`S.lib.ui_modal.push`) that lists the detail's label as a title and its fields: E2 moves, E3 edits the field under its cursor (ALT+E3 finely), K2 closes it (`pop`), and the page shows again with its cursor on the detail's row. No page change happens while it is open (#899); leaving the page ends a view `show_section` pinned, so the next visit opens on the cursor's row.

Drawing (`IO_PAGE`): six rows at y 18-53, 7 px apart (as SETUP), values right-aligned at x 124 (the scroll marker owns x 127). A title row draws the section's title at x 0 and its status right-aligned at x 124, both at level 10, the title cut to the room the status leaves. A section's rows start at x 4 (`row_indent`), the label at level 15 under the cursor and 4 otherwise (the draw that first shows the cursor on a row it fell to puts `>` at x 0 before it, #902), the value cut to the room the label leaves (`value_gap` 4 px between them). The page copies each row it shows (with its `section` and what it shows); a section's own tables are never changed.

## Keys

- **E2** moves over the selectable rows (`field_list.move_scroll`: past the last one it scrolls the view over the rows below; while it is scrolled, E3 only scrolls back, as SETUP).
- **E3** edits a `param` or `rig` row.
- **K2** jumps to the next section's first selectable row, wrapping from the last section to the first.
- **K3** runs an `action` or opens a `detail`.
- **ALT+E2** selects the voice (the `voice` section shows the selected voice's routes). ALT+K2 and ALT+K3 do nothing here.

Hints: `E2:row E3:value K2:section` on a param or rig row, `E2:row K2:section K3:<hint>` on an action, `E2:row K2:section K3:open` on a detail, `E2:row E3:back` while the cursor's row is out of view, `E1:page` with no section; with ALT held `E2:voice`, plus `E3:fine` on a rig row or a control param. The detail list's: `E2:field E3:value K2:close` (`E2:field E3:fine` with ALT).

## Layout states

The page has one state of its own, `ALT held` (its ALT hint row, over the targets core's `voice` section, which `lib/io/targets.lua` always registers; the page draws `no sections` only when the registry is empty, which `test/unit/pages_io_test.lua` covers). The start step `io_layout_states` (16, after VOICE's at 15) adds to it: for each registered section, in the page's order, `<name> at the top` (`show_section(name)`), then each of the section's own states as `<name>: <state>`, run after `show_section(name)`. The registered note targets' `layout_states` (`S.register_note_target`) follow the `voice` section's own as `voice: <state>`, in registration order, run after `show_section("voice")`; with no `voice` section registered they come last, and `show_section` simply returns false. Two states of one full name (`voice: <state>`) would write one render over the other, so the start step raises on a repeat, naming both owners (`section voice` and `target <name>`). So the layout tests and the page renders draw every section a module registers without an edit here. `show_section(name)` puts the section's title at the top of the view (or as near it as the list's end allows) whether or not the section has a selectable row, since a section without its device may show only status rows (design §11). The cursor goes on the section's first selectable row; with none, on the nearest selectable row before the section, else the first after it, else it stays. The view is pinned to the section (`view.pinned`, by name, so it survives a rebuild): the draw passes `field_list.draw` the row after the title as its cursor, so the title is the row above at the top, and lights the real cursor's row. E2 or K2 ends the pin; E3 or K3 ends it without acting when the cursor's row is out of that view. It returns true for a registered section (which always shows its title row), false otherwise.
