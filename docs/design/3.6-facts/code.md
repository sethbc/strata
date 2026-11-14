# 3.6 facts from the merged code (main at 545b1e18)

Paths are repo-relative to /home/sethbc/src/strata. "Code wins" marks a place where the notes or the brief disagree with the code.

## 1. Pages

Registration
- The list: `local UI_PAGES = {"MAIN", "VOICE", "SEQ", "FX", "LFO", "MOD", "BUFFER", "SCENES", "SETUP"}` at lib/constants.lua:76; `NUM_UI_PAGES = #UI_PAGES` at :77; `UI_PAGES.index[name]` is built at :78-79; both are exported at :281 and :307. The arc constants live on the same table: `ARC_TICKS_PER_SWEEP` 1024, `ARC_PORT` 1, `ARC_PORTS` 4, `ARC_FULL_TURN_MARGIN` (:84-89). lib/ui/frame.lua:29-32 adds `FRAMES_PER_SECOND = 15`, `screen_dirty`, `arc_dirty` and `frame_clock` at run time.
- There is no `S.register_page` function. Each page file assigns `S.registry.pages[UI_PAGES.index.<PAGE>] = {...}` itself: setup.lua:389, main.lua:318, voice.lua:396, seq.lua:1075, fx.lua:195, lfo.lua:542, mod.lua:1228, buffer.lua:1085 (through `BUFFER_INDEX`), scenes.lua:392. `S.registry.pages` is declared at lib/state.lua:28.
- strata.lua:99-107 includes one page file per page, by hand, then asserts at :108-114 that every `UI_PAGES` name has a record whose `name` equals it and whose `draw`, `hints`, `enc` and `key` are functions. The arc files are included after it (strata.lua:119-127).
- Record fields (docs/notes/lua/ui/pages-and-dispatch.md:25-36; test/unit/ui_pages_test.lua:15-16 lists them as `PAGE_FIELDS`):
  - required: `name`, `draw()`, `hints(alt_held) -> string`, `enc(n, d)`, `key(n)`;
  - optional: `alt_enc(n, d) -> handled`, `alt_key(n)`, `alt_key_release(n)`, `key_release(n)`, `enter()`, `leave()`, `arc_button()`, `header_status() -> string|nil`, `layout_states = {{name, setup = fn(context)}}`, `animates() -> bool`, and the ALT+K2 helpers `randomize_section`, `alt_hold`, `alt_hold_hint`;
  - the four arc fields `arc_delta(n, d)`, `arc_redraw(arc_port)`, `arc_alt_delta`, `arc_alt_redraw`, set only by `lib/arc/<page>.lua`. A test enforces this split (ui_pages_test.lua:105, :135).
- Dispatch:
  - E1 calls `S.lib.ui_keys.set_ui_page(util.clamp(S.ui_page + d, 1, NUM_UI_PAGES))` (strata.lua:213).
  - E2 and E3 go to `record.enc`, or to `alt_enc` first while ALT is held (:215-218). Keys: :234-262. Redraw: :274-305.
  - `set_ui_page(page)` is at lib/ui/keys.lua:57-69: on a change it runs the old record's `leave`, calls `forget_arc_ticks()`, clears the held keys, sets `S.ui_page` and runs the new record's `enter`.
  - `S.ui_page = 1` at lib/ui/frame.lua:12.
  - Bounds checks: `alt_action` in lib/ui/alt.lua:34 checks `1..NUM_UI_PAGES`; mutation.lua:94 checks that a spec's page is a `UI_PAGES` index.
- The header (lib/ui/header.lua:23-29, `draw_page_dots`) shows the page by title and dots:
  - The title is `UI_PAGES[S.ui_page]` at x 0, y 8 (:81).
  - It draws one dot per page from `HEADER` (lib/constants.lua:103-105): `dots_x = 36`, `dot_spacing = 4`, `dot_size = 2`, `dot_y = 4`, `status_play_x = 73`, `mutation_x = 76`, `play_x = 90`, `rec_x = 96`, `status_x = 79`, `flash_x = 40`.
  - Nine dots span x 36-69. A tenth would sit at x 72-73 and overlap the status play mark at x 73 (the comment at lib/constants.lua:101-102 says 3.4 moved the dots 4 px left so the ninth clears it). So ten do not fit as `HEADER` stands.
  - With the stub font, the widest titles ("BUFFER", "SCENES") are 27 px and "IO" is 9 px. So `dots_x = 32` (the tenth dot then ends at x 70) or `dot_spacing = 3` would fit. Either changes the `HEADER` values the tests assert.
- Everything that assumes nine pages or a fixed page list:
  - lib/constants.lua:76 (the list), :91-102 (the header comment: "nine").
  - strata.lua:5-27 (the header comment that lists the pages' controls), :99-107 (one include per page), :116-118 ("SETUP has none" arc).
  - test/helpers.lua:637: `PAGE_TITLES` is a hard-coded copy of the nine names. `show_page` (:648) and the render script's `fresh_page` read it.
  - test/unit/ui_pages_test.lua:
    - :18-29 asserts the nine names in order, `NUM_UI_PAGES == 9` and `UI_PAGES.index.SCENES == 8`;
    - :31-35 asserts that E1 stops at 9 = SETUP;
    - :190-195 requires a `lib/arc/<page>` include for every page but SETUP, so a ringless IO page fails it.
  - test/unit/pages_mod_test.lua:117-135 asserts nine dots, the last at x 68.
  - test/unit/ui_header_test.lua:77-78 (the exact `HEADER` table), :85-105 (nine dots), :176, :450-460 (nine dots, `dots[9].x == 68`, the last dot clear of the mark at 73).
  - test/unit/arc_pages_test.lua:21: an `expected_rings` table keyed by page name. A tenth page with no entry compares against nil and fails.
  - test/unit/ui_alt_test.lua:65 uses `NUM_UI_PAGES + 1` (generic).
  - test/unit/mutation_test.lua:776 expects 6 randomizing pages (fine if IO has no `randomize_section`).
  - Docs: AGENTS.md:9 ("a nine-page screen UI (MAIN, ... SETUP)") and :278 (`NUM_UI_PAGES` (9, `#UI_PAGES`)). docs_test.lua:1389, "every constant AGENTS.md quotes with a value has that value", fails until :278 changes. Also docs/user/controls.md:7 ("nine pages"), README.md:24 ("nine-page"), docs/notes/lua/ui/pages-and-dispatch.md:16, :19 and :37, and docs/notes/lua/ui/header-and-flashes.md:13.
- Generic, needing no edit: lib/ui/header.lua (loops `NUM_UI_PAGES`), test/render_pages.lua:155-166 (iterates `S.registry.pages` and each record's `layout_states`; its fixed `M.STATES` list at :40-65 names pages but needs no IO entry), test/unit/ui_layout_test.lua:166 and :252 (iterate `UI_PAGES` and records), and docs_test.lua:937-945 (`expected = {pages = 8}` is a minimum; each docs/user/pages/*.md must be linked from docs/user/controls.md).
- To add a tenth page "IO" at the end, the changes are:
  - lib/constants.lua:76 (append "IO"; appending changes no existing index, inserting it between pages would);
  - lib/constants.lua:103 (`HEADER.dots_x` or `dot_spacing`) and the :91-102 comment;
  - strata.lua:107 (add `S.lib.pages_io = include("lib/pages/io")(S)`) and the comment block at :5-27;
  - the new files lib/pages/io.lua, docs/user/pages/io.md (and a link from docs/user/controls.md), docs/notes/lua/pages/io.md (opening with "## Must not break", docs_test.lua:917), test/unit/pages_io_test.lua, and optionally lib/arc/io.lua;
  - test edits: helpers.lua:637; ui_pages_test.lua:18-35 and :192 (exempt IO, or give it an arc file); pages_mod_test.lua:117-135; ui_header_test.lua:77-105 and :450-460; arc_pages_test.lua:21 (add `IO = n`);
  - doc edits: AGENTS.md:9 and :278 (plus the module-table row), docs/user/controls.md, README.md:24, and the two notes files above.
- The E1 sensitivity is `E1_TICKS_PER_PAGE = 4` (lib/constants.lua:20; strata.lua:158-161). A tenth page adds one more detent stop to reach SETUP from MAIN.

## 2. Grid page keys

Refuted: no grid layout has a key that selects the screen page. No file under lib/grid/ reads or sets `S.ui_page` or calls `set_ui_page`; the only callers are strata.lua:213 and lib/ui/keys.lua. Every grid page key calls `grid_core.set_page(port, page)` for the grid's own pages: `GRID_PAGES = {patterns = 1, faders = 2, scenes = 3, sources = 4, positions = 5, count = 5}` (lib/constants.lua:165-166, checked in lib/grid/core.lua:70-72).
- 256 (lib/grid/layout_256.lua): row 8, columns 13-16 select pages 1-4 (:309-312) and column 12 (`positions_key_column`, :45) selects page 5 (:304-306). LEDs at :573-580.
- 128h (lib/grid/layout_128h.lua:20-25): row 8, columns 5-8 select pages 1-4 (`page_first_column = 5`, `num_pages = 4`). Column 8 pressed again while on page 4 selects positions (:179-183). Columns 1-4 are play/stop, 9-15 toggle voices 1-7 and 16 cycles the voice. The row is full.
- 128v (lib/grid/layout_128v.lua:22): one key at column 8, row 8 (`page_key_row`) cycles `page % PAGES.count + 1` (:136-137). The page shows as one LED level from `page_levels = {3, 6, 9, 12, 15}` (:21, :283).
- 64 (lib/grid/layout_64.lua:64-77): no page keys. A hold on row 8, column 1 cycles steps 1-8, steps 9-16 and positions.
- So a tenth screen page changes no grid key.
- Notes vs code: docs/notes/lua/ui/pages-and-dispatch.md:52 says "A page change made elsewhere (the grid) still changes the header's page underneath". No grid code changes the screen page; code wins.

## 3. Row pages (lib/ui/field_list.lua, `S.lib.ui_field_list`)

- The module is stateless: the rows are rebuilt by the page on every call, and the cursor is a row index the page stores.
- Row shape (:3-6): `{label, param_id?, selectable = true|false, section?}`. Every other field is the page's own.
- API:
  - `move(rows, cursor, d)` (:28) clamps and never wraps.
  - `clamp(rows, cursor)` (:43) returns the nearest selectable row at or before the cursor.
  - `ordinal(rows, cursor) -> position, count` (:54).
  - `first_visible(rows, cursor, visible, tail)` (:69) keeps one row above the cursor.
  - `tail_room(rows, cursor, visible)` (:76).
  - `move_scroll(rows, cursor, tail, d, visible) -> cursor, tail` (:84): E2 scrolls past the last selectable row.
  - `draw_marker(first, visible, count, top, bottom, x)` (:109) draws the scroll bar at x 127.
  - `draw(rows, cursor, spec, draw_row)` (:129), with `spec = {visible, first_y, spacing, value_right = 124, marker_top?, marker_bottom?, tail?}` and `draw_row(row, y, selected, value_right)` supplied by the page.
- Editing, hiding and sections are not in the field list:
  - The page's own `enc` decides how a row edits. SETUP uses row `kind`s: `"param"` → `enc_param_delta(n, id, d)`, or `set_binary_param` for a binary or `binary = {...}` row; `"action"` → K3 runs `run()`; `"pool"`, `"performance"` and `"rotation"` are custom steppers (setup.lua:330-354).
  - A hidden row is simply left out of the rebuilt list (setup.lua:180-212 inserts rows conditionally).
  - Because the cursor is a row index, a row that comes or goes above the cursor moves it. SETUP's rule: conditional rows only below the fields, or under the cursor's own row (setup.lua:166-167, :184-186).
- SETUP (lib/pages/setup.lua):
  - Layout: `SETUP_PAGE = {visible = 6, first_y = 18, spacing = 7, value_right = 124}` (:22-26).
  - Not sectioned. `SETUP_FIELDS` (:59-79) has 12 rows: midi, channels, note off, mpe & zones (action), note pool, mutations, mutation rate, mutation prob, mutation amt, save scenes, load scenes, transport.
  - `setup_rows()` (:180-212) then adds 4 grid rotation rows (one per `S.MAX_GRID_PORTS = 4`; lib/grid/core.lua:26), "performance", and "buffer length" when the tier or setting is high: 17-18 selectable rows.
  - Then status rows: may xrun / (next start) notes, "running: ...", running_note, "grid: N connected", sizes, "arc: ...", "buffers: ...", and the data file problems.
  - The cursor is `S.setup_cursor` (:93); the scroll tail is the local `setup_view.tail` (:96).
- VOICE (lib/ui/voice_rows.lua):
  - Rows come from the global `voice_page_rows(voice_idx)` (:110): section label rows `{label, section, selectable = false}`, then `{label = param.name, param_id, section, selectable = true, kind = "control"|"number"|"option"|"binary"}`.
  - A registered voice-param record's `voice_rows = {section, rows = {key...}, when = fn(voice_idx, key), before = <section>}` adds rows, hidden per voice by `when` (:57-87; validated in lib/state.lua:203-209).
  - VOICE's layout is `visible = 5, first_y = 24, spacing = 7` (lib/pages/voice.lua:28-30).

## 4. Step outputs

- `S.register_step_output(record)` (lib/state.lua:435-440):
  - Fields: `{name, play = fn(event), stop = fn(), available = fn(voice_idx) -> boolean}`; `play` is required. Unknown fields are refused (`STEP_OUTPUT_FIELDS`, :360). A duplicate name is refused.
  - The registry stays open (read at each use).
- Order: outputs run in registration order (lib/sequencer.lua:667-675). The `voices` output registers at sequencer.lua:614, at include time, and lib/sequencer.lua is the last include (strata.lua:137). So a module included earlier that registers at include time plays before the voices output; one that registers in a start step plays after it.
- The hit event (`hit_event`, sequencer.lua:698-716). One table is shared by every output, so an output that mutates it affects the ones after it.
  - Fields:
    - `voice` (1-7), `step` (1-16), `hit` (1..hits), `hits` (the ratchet count: `min(attrs.ratchet or 1, step_seconds / 0.02)`, :1027), `first = hit == 1`, `level` (1-15);
    - `velocity = level / MAX_STEP_LEVEL` (0-1), `beat = clock.get_beats()`;
    - `gate_beats = division / hits` always; for a gated voice (`v<i>_seq_gate` on), `steps * division / hits`, where steps is the step's `gate` attr or `seq_gate_length` (default 0.5);
    - `notes` (the step's scale degrees, a copy) and `semitones` (each degree's semitones from the voice's pitch through the global scale; `M.degree_semitones`, :356), only when the step has notes;
    - `locks` (a subset of `{pos, pitch, size, bookmark}`, `SEQ.lock_keys` :56), only when set.
  - Every ratchet hit is a separate `play` call with `hit` > 1 (`play_voice_hit`, :1037-1039).
- Missing from the event: there is no absolute pitch. Absolute chord pitches are computed only inside `step_chord` (:425-441) from the voice's note param (`value_note` and `voice_pitch_note`, locals at :343-349) and kept in the local `chords[voice]`. An external target has to recompute the pitch (no public `M.*` gives it) or the design adds one.
- Note length: `event.gate_beats` (beats) is the one existing note length. In seconds, `M.gate_seconds(voice_idx, step, hits)` (:386-392) clamps to `SEQ.gate_seconds = {0.005, 120}` (:46).
- `available(voice)` is called before every `play` (:655-657).
- `stop()` is called only by `pattern_clock_stop()`, and only when the patterns were playing (:1318-1329, `stop_outputs` :677-685). It is not called when a voice stops, a step ends or `replace_pattern` runs.
- Coroutines and errors (:617-661):
  - Every output but `voices` runs in its own reused coroutine (`run_output`). A raise, or any yield (`clock.sleep` or `clock.sync` in `play`), marks the output `play.failed[name]`. It prints once and is skipped until the next pattern start resets `play.failed = {}` (:1296).
  - `voices` is called directly; its error stops the patterns and is raised again.
- How `voices` ends its notes:
  - It owns `SEQ.note_owner = "seq"` (:71).
  - `end_chord(voice)` → `S.lib.notes.release_owner(voice, "seq")` (:308-312) runs from `end_overrides` (each step without notes, a stop, `replace_pattern`, a shorter length) and from the output's `stop` (:611-613).
  - A step's chord notes that the next step lacks are released by key: `S.lib.notes.release(voice, "seq", k)` for k > chord count (`apply_step` :536-538).
  - In other words, notes end when the next step plays or the patterns stop, never by `gate_beats`. The voice's own note is gated by the engine's `gateSeconds` (`send_gate_seconds`, :378-382).

## 5. Notes (lib/notes.lua, `S.lib.notes`)

- Tunables: `NOTES` at :28-40.
  - `owners = {midi = true, seq = true}` (:30) is a closed set: `valid_note` (:372-380) refuses any other owner, and the invariant's `record_problem` (:825) flags one.
  - `sends_per_step = 16`, `cut_seconds = 0.05`, `expression_keys = {"bend", "amp", "position", "size", "main"}`, `neutral`, `expression_ranges`.
- Public API:
  - `play(voice, note) -> slot|nil` (:388), with `note = {owner, key, pitch (fractional MIDI note), velocity (0-1), set_own = fn(pitch), park?, quiet?, extra_only?, expression? = {bend, amp, position, size, main}}`. Six branches: :397-458.
  - `release(voice, owner, key) -> bool` (:485).
  - `release_owner(voice, owner)` (:494): extras first, then the own note (which parks).
  - `forget_owner(voice, owner)` (:511): extras get noteOff; the own note is dropped silently.
  - `forget(voice, owner, key) -> bool` (:527).
  - `release_all(voice)` (:541): forgets everything and sends nothing; called by the voice-stop hook.
  - `find(voice, owner, key) -> slot|nil` (:224).
  - `slots(voice) -> {{slot, owner, key, pitch, held, parked}, ...}` (copies, :234).
  - `held(voice) -> count` (:204); `pool_used()` (:213); `pool()` (:248); `set_pool(n) -> bool` (:608).
  - `note_values(voice, pitch) -> {note, freq, rate}|nil` (:279); `freeze_reference(voice)` (:258).
  - `set_expression(voice, slot, values) -> bool` (:555), which marks the note due for the flush.
  - `expression(voice, slot) -> copy|nil` (:568): the mapped five values.
  - `stop_flush()` (:597); `recall_switched(voice)` (:808).
- Owners today: `MIDI.owner = "midi"` (lib/midi_in.lua:31; key = `channel * 128 + note`, :221) and `SEQ.note_owner = "seq"` (sequencer.lua:71; key = the chord index k, 1-8).
- There is no hook, registry or callback for a note starting, ending or changing expression, and the module has no event list. Notes also end without their owner being told:
  - steals: `forget(victim)` at :437 (branch 4, any voice) and :453 (branch 5);
  - branch 6 taking slot 1 (`play_own` forgets the previous own record, :338);
  - freeze cuts (`cut_extras` :761-776, from the freeze-change hook :815 and `recall_switched`);
  - the voice-stop hook (`release_all`, :751-755);
  - `set_pool` shrinking (:618-627).
- The narrowest places for a hook (every path goes through them):
  - start: `new_record` (:148-152, called from `play_own` :340 and `start_extra` :364);
  - re-pitch in place: branch 1 (:400-411) and `play_own` on the same owner and key;
  - end: the local `forget(record, now)` (:155-160), and parking in `release_slot` (:475-478, `record.parked = true`, not `forget`);
  - expression: `mark_due` (:162) or `send_expression` (:123-127). The flush (:578-594) runs from the LFO step hook at 48 Hz.
- MPE: `S.lib.mpe.values(channel) -> {bend (a ratio, member times master), pressure (0-1, nil before the first), slide (0-1 absolute, nil before the first)}` (lib/mpe.lua:113-128). Also `active()` (:44), `zone(channel)` (:51), `targets(channel, note) -> {voice...}` (:88), `control(msg) -> {changed channel...}` (:181), `on_layout_change(fn)` (:203), `reset()` (:31).
- Expression (lib/expression.lua):
  - `note_values(voice, raw) -> {bend, amp, position, size, main}` (:154). Raw is `{bend, pressure, slide (relative)}`, mapped through `v<i>_press_target`, `slide_target` and the depths.
  - `update(voice, owner, key, raw)` (:221), `latch` (:250), `forget` (:268).
  - The raw per-note values (pressure, peak, slide, reference) are in the local `records[voice]` (:166-177), with no reader.
- What Lua has for a MIDI note:
  - At note on (`midi_note_on`, lib/midi_in.lua:381-399): the voice, the quantized pitch (`S.lib.variation.midi_note(voice, note)`), velocity / 127, the channel (from the key), and the raw `{bend, pressure, slide}` from `raw_values` (:227-230): the MPE channel's in the MPE modes; in the plain modes bend 1 and the poly or channel pressure.
  - As it moves: `express_channel` (:305-312) and `plain_pressure_message` (:316-330) call `S.lib.expression.update`.
  - Plain-mode pitchbend goes to the voice through `midi_set_bend` (:438-441, `S.midi_state.bend[voice]`) and not per note.

## 6. Modulation sources

- `S.register_mod_source(record)` (lib/state.lua:447-464):
  - Fields: `{key, name (1-4 chars), section, value = fn() -> number, range = {min, max} (min < max; min < 0 is bipolar), describe? = fn() -> string, visible? = fn() -> bool, row? = {enc, fine_enc, press, alt_press, hints}}`.
  - Unknown fields are refused. The registry stays open.
- lib/mod_sources.lua is read-only and never yields:
  - `get(key)` (:17), `list(section)` (visible only, :30), `registered(section)` (all, :41), `sections()` (in the order each was first registered, :50);
  - `fraction(key) -> 0..1` (a non-finite value gives 0.5 bipolar or 0 unipolar, :76);
  - `normalized(key) -> -1..1 bipolar or 0..1` (a non-finite value gives 0, :87).
- Sources on main, as `key/name/section`:
  - `lfo1..lfo6`/L1-L6/lfos, -1..1 (lib/lfos.lua:1050-1061);
  - `macro1..macro16`/M1-M16/macros, 0..1, visible only in the shown bank (lib/macros.lua:693-700);
  - `gesture1..gesture4`/G1-G4/gestures (lib/gestures.lua:779-787, value `M.phase(k)`);
  - `input`/IN/audio (lib/input_level.lua:105, a poll at 30 Hz, :15);
  - `pressure`/PRES, `slide`/SLID, `pressure1..7`/PR1-7, `slide1..7`/SL1-7, section `notes` (lib/expression.lua:372-386).
- Rates: LFO values change once a 48 Hz step (`LFO.step_hz = 48`, lfos.lua:38; the clock at :711). `S.lib.lfos.on_step(fn)` (:373-376) runs `fn` after the six LFOs each step; the matrix and the notes flush use it.
- `S.lib.lfos.value(n)` (:326) is `state[n].value`, set each step as `2 * lfo_u(n, phase) - 1` (:650) for Lua-run and engine-run LFOs alike.
  - For an engine-run LFO it is Lua's own model: the same phase, rate and shape math, but not read back from the engine.
  - It is exact in phase for an unmodulated clocked LFO (docs/notes/lua/lfos.md:78), and approximate for a free one, since the two clocks drift.
  - It is not the engine's value for the random shapes (s&h, smooth, drunk): Lua draws its own randoms (`new_cycle`).
- MOD lists sections generically: `section_order()` (lib/pages/mod.lua:111-124) is `MOD_PAGE.sections = {"macros", "morph", "scatter", "gestures", "lfos", "matrix"}` (:41), then every other section from `S.lib.mod_sources.sections()`. So a new section shows up without editing MOD (a layout state at mod.lua:1182-1185 proves it). The matrix offers every registered source (`registered()`, mod.lua:326).

## 7. Macros

- Params: `macro_1..macro_16` (`macro_id(m) = "macro_" .. m`, lib/macros.lua:52), in group `strata_macros` (:662-668):
  - `type = "control"`, `controlspec.new(0, 1, "lin", 0, 0, "")` (step 0, so the quantum is controlspec's default 0.01), a percent formatter;
  - `action = function() mark_pending(m) end`: the 30 Hz apply clock, `MACROS.apply_hz` (:36).
  - Each is a scene field with `set = M.set_silently` (:688) and an LFO global destination "macro m" (:690).
- API:
  - `apply(m)` (:383);
  - `set_silently(m, value)` (:392): `params:set(id, value, true)` with no apply, for scenes, morph and fades only;
  - `target_ids()` (:127), `target_label(id)` (:135), `targets(m)` (:514), `set_target(m, k, id, min, max)` (:524);
  - `learn(m, k)` (:564), `cancel_learn()` (:544), `learning()` (:585);
  - banks: `bank()` (:622), `bank_macros(b)` (:625), `set_bank(b)` (:634, a view only, moving no macro), `bank_has_targets(b)` (:645). `MACROS.banks = 4` (:41). The shown bank is the local `shown.bank` (:618).
  - `MACROS` holds the tunables (:35-50).
- Setting a macro from outside:
  - Absolute: plain `params:set("macro_<m>", v)` (the action queues the apply).
  - Relative: `delta_with_detent(id, d, opts)` (lib/ui/detent.lua:80), with `d` in encoder detents, a step of `d * quantum` (0.01), and `opts.fine` and `opts.source` (passed to the param-touch hooks; "enc", "arc" and "grid" exist today). `enc_param_delta(n, id, d)` (:148) is only `delta_with_detent` with `fine = (n == 3 and S.alt_held)`, so it is wrong for MIDI. A macro spans 0..1, so the zero detent never applies.
  - Nothing in Strata implements pickup.
- norns PARAMS > MAP (~/src/norns/lua/core/menu/params.lua:710-750):
  - `norns.menu_midi_event` runs for every MIDI message on any device that has a vport (core/midi.lua:470-474), whether or not Strata listens to that port.
  - For a control param it does `params:set_raw` (absolute). `accum` (relative) turns `v > 64` into +1 and otherwise -1 on a 0-127 accumulator. There is no pickup.
  - So a macro mapped in MAP and also handled by a 3.6 controller module would move twice.
  - Strata's only MAP code: `set_binary_param` echoes a binary to a mapped controller (lib/ui/params.lua:40-48: `midi.vports[map.dev]:cc(map.cc, map.value, map.ch)`), and `M.repair_midi_map` (lib/midi_in.lua:498-538) fixes 3.3's LFO ids.

## 8. MIDI in (lib/midi_in.lua)

- Port: param `midi_device` (number 1..`#midi.vports` = 16, default 1; lib/params_setup.lua:690-700). Its action is `attach_midi(x)` then `reset_midi_input()`.
  - `attach_midi(port)` (:77-83) sets `S.midi_device = midi.connect(port)` and `.event = midi_event`, after clearing the old vport's `.event`. The handler lives on the vport only (:61-63).
  - The group `strata_midi` has 6 params: midi_device, midi_channel_mode, midi_note_off and 3 from `S.lib.mpe.add_midi_params()` (params_setup.lua:684-726).
- Hot-plug overwrites norns' globals rather than chaining them: `midi.add = midi_added`, `midi.remove = midi_removed` in the start step (:548-549), and both become no-ops at cleanup (:569-570). A second module that sets `midi.add` replaces Strata's and the reverse. The same is true of `grid.add` and `grid.remove` (lib/grid/core.lua:676 and :686, assigned at include time) and `arc.add` and `arc.remove` (lib/arc/core.lua:155 and :165).
- `M.reconcile()` (:114-120) runs on menu close for SYSTEM > DEVICES moves.
- `midi_event(data)` (:332-353) handles, in order:
  - `note_on` with vel > 0 → `note_on`;
  - `note_on`/`note_off` → `note_off`;
  - `cc` 120 or 123 (`M.PANIC_CCS`) → `release_held_notes(true)`;
  - in the MPE modes, everything else goes to `S.lib.mpe.control(msg)`;
  - else `pitchbend` → `midi_pitchbend`, and `key_pressure`/`channel_pressure` → `plain_pressure_message`.
- Program change is ignored today. In the MPE modes it reaches `mpe.control`, which ignores it. It belongs in `midi_event`'s chain before the MPE branch (:338-340). Clock, start and stop are not handled here: norns' clock takes them.
- A note reaches a voice through one call site of `S.lib.notes.play`: `midi_note_on(voice_idx, note, velocity, channel, raw)` (:381-399), with `{owner = "midi", key = channel * 128 + note, pitch = S.lib.variation.midi_note(voice_idx, note), velocity = velocity / 127, park = true, set_own = own_setters[voice_idx], expression = S.lib.expression.note_values(voice_idx, {bend, pressure, slide = 0})}`.
  - Routing: `note_targets` (:215-219) uses `S.lib.mpe.targets` in the MPE modes, else `midi_target_voice(channel)` (:205-211: channel n plays voice n, or the selected voice in omni).
  - The other sequencer call site is `apply_step`/`play_chord` through `chord_note` (sequencer.lua:464-474, 554, 578).
- Ends:
  - `end_key` (:242-251): latch → `S.lib.expression.latch`; release → `S.lib.notes.release(voice, "midi", key)`, or the voice's last key → `midi_note_off_for` (stops the voice);
  - `release_held_notes(stop_all)` (:160-182): `forget_owner` per voice, or `toggle_voice` stops;
  - `reset_midi_input()` (:187-196): re-centers every bend, clears the note tap, `release_held_notes(false)`;
  - the note tap: `M.set_note_tap(fn)` (:143), used by the zones learn.
- State: `S.midi_state = {bend[voice], held[voice][key], note_voice[channel][note] = {voices}, started[voice]}` (:38-47).
- Ports: Strata opens one MIDI vport (`S.midi_device`). The only other MIDI use is the MAP echo via `midi.vports[map.dev]:cc` (lib/ui/params.lua:46). There are no output ports or controller ports.

## 9. Scenes and quantized actions

- `recall_scene(scene_num, transition_time)` (lib/scenes.lua:750-836) is global.
  - Empty or invalid scenes are refused. It increments `takeover_count`, ends a running transition and clears the undo.
  - With a time, a clock fades over `S.SCENE_TRANSITION.steps`, and `S.current_scene` becomes the target at the first step (:790). Without one, it calls `recall_scene_instant`.
- `recall_scene_instant(scene_num, scene_data?, current_if_failed?)` (:847-871) applies `M.apply_entries(M.scene_entries(data))`, then sets `S.current_scene = scene_num` (:866), `update_voice_list()` and the redraws.
- `S.lib.quantize.schedule(key, fn, label) -> ran_now, token` (lib/quantize.lua:95-125) also has `cancel(key)` (:82) and `waiting(key, token)` (:128).
- Every scene recall from a control goes through `schedule("scene", function() recall_scene(n, t) end, "S" .. n)`: lib/pages/scenes.lua:242, layout_256.lua:321 and :325, layout_128h.lua:156 and :160, layout_128v.lua:105 and :108. The scene sequencer calls `recall_scene` directly (scenes.lua:938). There is no `request_recall` function.
- No hook runs when a scene is recalled. A program-change-out hook fits at :866 (an instant recall or a fade's landing) or :790 (a fade's start).

## 10. Grid and arc devices

Grid (lib/grid/core.lua)
- Ports: `S.MAX_GRID_PORTS = 4` (:26) and `S.grids[port] = vport` (:27).
- `attach_grid(port)` (local, :610-619) does `grid.connect(port)`, records `attached_devices[port] = grid_port.device` (local), sets `grid_port.key = fn(x, y, z) grid_key(port, x, y, z)` (on the vport only) and calls `apply_rotation` (`grid_port:rotation(r)`, :601-604).
- `grid_init()` (:663-672) attaches ports 1..4 that hold a device. The start step is `START_ORDER.grids` = 80 (:812).
- Hot-plug: `grid.add` and `grid.remove` (:676-698); `M.reconcile_ports()` (:707-726) runs on menu close for ports 1..4.
- Layout: `grid_layout(grid_port)` (local, :513-525) picks by exact size: 16x16 "256", 16x8 "128h", 8x16 "128v", 8x8 "64", anything else nil. `M.layout_of(port)` is at :530.
- Dispatch:
  - Keys: global `grid_key(port, x, y, z)` (:755-773) checks bounds against `grid_port.cols` and `rows`, then calls `layout.key(port, x, y, z)`.
  - Redraw: global `grid_redraw()` (:790-808) goes over `pairs(S.grids)` and, for each entry with `.device`, calls `all(0)`, `layout.redraw(port, grid_port)` and `refresh()`.
- Per-port state: `M.page(port)`, `M.set_page(port, page)` (:59-75), `M.any_page(page)` (:81), `M.port_state(port)` (:139), `S.grid_held`, `M.held(port, x, y)` and `M.consumed`.
- What a device object must provide: fields `cols`, `rows`, `device` (truthy while connected) and a writable `key`; methods `led(x, y, level)` (88 call sites in lib/grid/), `all(level)`, `refresh()` and `rotation(r)` (attach, and cleanup at :827).
- Other readers: lib/playheads.lua:153 (`pairs(S.grids)`, `.device`), lib/grid/layout_64.lua:102 and :114 (`S.grids[port].cols`), lib/pages/setup.lua:99-109 (counts ports 1..`MAX_GRID_PORTS`).
- A virtual grid is feasible as one more `S.grids` entry (a port above 4) that calls the global `grid_key(port, ...)`. The seams:
  - `attach_grid` is local and hard-codes `grid.connect`, so a public attach function is needed;
  - `reconcile_ports`, `grid_init`, the "grid keys" invariant (:836-841, which requires `S.grids[port]` exactly while `attached_devices[port]` is set, for ports 1..4 only), `set_rotation` (ports 1..4) and SETUP's count all loop 1..`MAX_GRID_PORTS`. A virtual grid at port 1-4 would be detached on the next menu close (its norns vport is empty, :716-721);
  - the cleanup step (:825-833) calls `rotation`, `all` and `refresh` on every entry.
  - Nothing depends on `grid.vports` beyond `grid.connect`.

Arc (lib/arc/core.lua)
- Strata follows one arc: `S.arc_device` (the vport) and `S.arc_connected` (:19-20).
- `attach_arc(port)` (local, :123-134) sets `.delta = arc_delta` and `.key = arc_key` on the vport.
- Which arc: `arc_init()` (:151-153) follows the first of vports 1..4 holding a device (`first_arc_port`, :138-145), else port 1 empty.
  - `arc.add` (:155-163) attaches only while none is connected.
  - `arc.remove` (:165-179) moves to the next port holding an arc.
  - `M.reconcile()` (:186-200) runs on menu close.
- Dispatch:
  - Turns: global `arc_delta(n, delta)` (:217) goes to the modal owner or the page's `arc_delta`/`arc_alt_delta`.
  - Button: global `arc_key(n, s)` (:228).
  - Redraw: global `arc_redraw()` (:245-255) requires `S.arc_device.device`, then calls `all(0)`, the page's `arc_redraw(S.arc_device)` and `refresh()`.
- What a device must provide: a `device` field (truthy), writable `delta` and `key`, and methods `all`, `refresh`, `segment(ring, from_angle, to_angle, level)` and `led(ring, n, level)`. All drawing goes through `arc_ring_fill*`.
- A virtual arc can replace `S.arc_device` (`arc.add` and `arc.remove` leave a non-vport device alone, :159 and :168; `reconcile` keeps any device whose `.device` is set), but `attach_arc` is local. It needs a public attach or follow function, and the invariant "arc connection" (:263-269) needs `S.arc_connected == (S.arc_device.device ~= nil)`.

## 11. Budgets, clocks, start and cleanup

- Engine budget (lib/engine_sync.lua:140-330):
  - `ENGINE_BUDGET = {messages_per_window = 150, window_seconds = 0.1}` (lib/constants.lua:336).
  - The window is `math.floor(util.time() / window_seconds)` and never goes back.
  - `send_engine_value(param_id, value)` (:265-277, exported :711) counts `engine_messages(param_id)`. While `S.deferrable_write` is set and the window is full, the value waits as `budget.pending[id]` (the newest wins, in first-waited order) and `S.engine_budget_clock` (:229-239) flushes it at the next window's start; the clock is never canceled and ends at its own wake.
  - `M.deferrable(fn)` (:283-289) sets `S.deferrable_write` around `fn`, which must not yield.
  - `M.count_sends(n)` (:305-313) adds n direct messages to the current window, defers nothing and sends nothing (lib/notes.lua's `count`, :121).
  - `M.expected_value(id)` (:295) and `M.budget_state()` (:316, for tests).
  - The invariant is "engine budget" (:321) and the cleanup step `CLEANUP_ORDER.engine_budget` = 127.
  - Everything is keyed by param id over `S.engine_senders`, local to engine_sync. Nothing is generic to reuse for ii or MIDI: copy the pattern.
- LFO round robin (lib/lfos.lua:334-370): `M.mark_due(key, send)` queues `send()` under `key` (a later mark replaces it). `drain()` runs at most `LFO.sends_per_step = 12` a 48 Hz step, each inside `deferrable` and contained. Keys that `S.lib.engine_sync.reaches_engine(key)` is false for take no slot. `M.on_step(fn)` (:373).
- Notes flush: at most `NOTES.sends_per_step = 16` `noteExpression` a step, counted (lib/notes.lua:578-594).
- Clocks:
  - `S.lfo_clock` (48 Hz, lfos.lua:694 and :711; `START_ORDER.lfo_clock` 125, cleanup `lfos` 120);
  - `S.macro_clock` (macros.lua:69, at most 30 Hz per macro, runs while pending);
  - `S.morph_clock` (morph.lua:49 and :687);
  - `UI_PAGES.frame_clock` (15 Hz, lib/ui/frame.lua:29 and :129);
  - the playheads clock, a local `clock_id` (lib/playheads.lua:19 and :204, `PLAYHEADS.update_hz = 15`), not on `S`;
  - `S.pattern_clock` (sequencer.lua:81 and :1311), `S.engine_budget_clock`, `S.scene_transition_clock` and `S.scene_sequencer_clock` (scenes.lua:45-50), and the learn clocks `S.macro_learn_clock`, `S.matrix_learn_clock` and `S.zones_learn_clock`;
  - the input level polls at 30 Hz.
- Registration: `S.register_start(order, fn)` and `S.register_cleanup(order, fn)` (lib/state.lua:95-104) refuse a duplicate order; start closes at init. docs_test.lua:1368 requires docs/notes/lua/state-and-voices.md's tables to list every step.
- `START_ORDER` (lib/constants.lua:181-207), in use: 5 started, 10 voice_list, 15 voice_layout_states, 20 e1_settings, 30 menu_watch, 40 drift_metro, 50 mutation_metro, 60 buffer_polls, 62 input_level, 65 record_poll, 70 arc, 80 grids, 90 midi, 100 scenes_load, 105 macros_load, 107 gestures_load, 108 matrix_load, 109 notes_load, 110 buffers_load, 120 startup_clock, 125 lfo_clock, 130 frame_clock, 140 waveforms, 150 playheads, 160 pattern_transport.
  - Free: 1-4, 6-9, 11-14, 16-19, 21-29, 31-39, 41-49, 51-59, 61, 63-64, 66-69, 71-79, 81-89, 91-99 (after midi, before the data loads), 101-104, 106, 111-119, 121-124, 126-129, 131-139, 141-149, 151-159, and 161 up.
- `CLEANUP_ORDER` (:234-271), in use: 10 tempo_handler, 20 menu_watch, 30 scenes_save, 32 macros_save, 34 gestures_save, 36 matrix_save, 40 buffer_paths_save, 50 startup_clock, 60 frame_clock, 70 drift_metro, 80 mutation_metro, 85 undo_clock, 90 pattern_clock, 95 gestures, 97 quantize, 100 scene_sequencer, 110 scene_transition, 112 morph_clock, 114 macros, 117 zones_learn, 118 matrix, 119 notes, 120 lfos, 122 playheads, 124 scrub_glide, 126 waveforms, 127 engine_budget, 128 buffer_start_reload, 130 buffer_polls, 132 record, 135 input_meter, 140 ui_flash, 150 midi_handler, 160 voices_off, 170 grids_dark, 180 arc_dark.
  - Free: 31, 33, 35, 37-39 (saves), 41-49, 51-59, 61-69, 71-79, 81-84, 86-89, 91-94, 96, 98-99, 101-109, 111, 113, 115-116, 121, 123, 125, 129, 131, 133-134, 136-139, 141-149, 151-159, 161-169, 171-179, and 181 up.
  - norns frees the engine before `cleanup()` (comment at :230-232). A MIDI-out note-off step before 150 still reaches devices; engine commands do not.

## 12. Params, data files, PSET, `S.performance`

- Param groups: `register_params(name, add)` is local to lib/params_setup.lua (:162-175), not on `S`. Each record `{name, add}` is appended to `S.registry.params`, and init runs them in order (strata.lua:187-189). The add wrapper puts every new param into `pset.record_params` and rounds number params.
  - Menu order: performance, master, mutations, scenes, fx, lfos, then 3.4's loop at :641-644 (`{"macros","macros"}, {"morph","morph"}, {"scatter","scatter"}, {"matrix","matrix"}, {"input","input_level"}, {"gestures","gestures"}`, each calling `S.lib[module].add_params()`), then seq, buffers, record, positions, midi, zones, scale, voices.
  - So a new module's group needs a line in that loop (or a new `register_params` call) in lib/params_setup.lua: it cannot register itself.
- Per-voice params: `S.register_voice_params(record)` (lib/state.lua:174-220), with fields `{name, count, add = fn(voice_idx), add_first?, grain_keys?, sync?, scene_defaults?, discrete?, scene_ranges?, voice_rows?, layout_states?, normalize_scene?, fader (never true), randomize?}`.
  - It closes at init.
  - `add` must call `S.lib.params_setup.add_voice_extra(voice_idx, record, key, param)` (lib/params_setup.lua:807-846). That makes `v<i>_<key>` and stores it in `S.voices[i].extras[key]`. Its action runs the param filter, `note_param_edit`, `send_param_to_engine` (harmless without a sender) and the param's own action.
- PSET-only vs scene field:
  - Every Strata param is in the PSET.
  - A param is a scene field only if it is in `S.SCENE_GLOBAL_PARAMS` (lib/scenes.lua:87-...), a registered scene field (`S.register_scene_field({id, default, discrete?, set?})`, lib/state.lua:227-239), a key in a voice-params record's `scene_defaults`, or part of a scene block (`S.register_scene_block`, :371-378).
  - Anything else is PSET-only. `params:set_save(id, false)` keeps a param out of the PSET (lib/gestures.lua:598).
  - Data beside a PSET: `S.register_pset_hook({name, write, read, delete})` (:397-403).
- Data files:
  - `scenes.data`, `buffers.data`, `macros.data`, `matrix.data`, `gestures.data`, `grids.data`, `notes.data` go through `S.lib.data_files` (lib/data_files.lua): `encode` (:63), `decode` (:127), `read(path) -> value | nil, "missing" | nil, "unreadable", why` (:301), `write(path, value) -> ok, problem` (:347: writes `.part`, then renames; skips identical bytes), `read_text`, `set_aside(path, suffix)` (:374), `keep_copy` (:390).
  - The live file and per-PSET file pairs use `S.lib.side_files.new(spec)` (lib/side_files.lua:47), whose spec requires `name`, `contents`, `version`, `key`, `live_file`, `side_suffix`, `backup_suffix`, `capture`, `validate`, `load`, ... It returns `read`, `write`, `load_live`, `save_live`, `save_now` and `pset_hook`.
  - `performance.data` and `performance_active.data` are lib/performance.lua's own (io.open, :51; `set_setting`, :195), outside data_files.
- `S.performance = {tier = "standard"|"high", buffer_seconds, max_grains, history_seconds, reason?}`:
  - starts empty (params_setup.lua:30);
  - is filled by the first params record "performance" (`read_active`) from `performance_active.data`;
  - only ever has `buffer_seconds` lowered, by the poll.
  - The setting (`S.lib.performance.setting()`, `set_setting(key, value)`) is SETUP-only, not a param.

## 13. Transport, OSC, softcut, crow, audio levels; stubs

- Transport: one installer at lib/sequencer.lua:1465-1472 (start step `pattern_transport` = 160). It saves `clock.transport.start` and `stop` into `transport.previous_start` and `previous_stop` and installs `transport.start` and `transport.stop` (:1445-1461), which call the previous ones last.
  - A later module chains the same way: install in a start step above 160 and call whatever handler it found.
  - The cleanup restores the previous handlers unless a later one replaced them (comment at :1417-1419).
  - The tempo handler chains in the same pattern at lib/params_setup.lua:81-91.
- `osc`, `softcut`, `crow` and `audio.level_*` are not used anywhere in lib/ or strata.lua (grep). The only `audio` use is `audio.file_info` (lib/buffers.lua:389-407); `crow` appears only in a comment (params_setup.lua:104) and in the stub's clock params.
- Stubs:
  - `_G` is assembled in test/norns_stubs.lua:3214-3253: engine, include, util, controlspec, params, clock, metro, grid, arc, screen, tab, midi, poll, `audio = context.audio.api` (only `file_info`, :3178-3186), _menu, norns and _path. There are no crow, osc, softcut or nb stubs.
  - The stub's system params include `softcut_level` and `clock_crow_*` (:928, :979-982).
  - test/stub_midi.lua: 16 vports, each with `send` and the send methods `note_on`, `note_off`, `cc`, `pitchbend`, `key_pressure`, `channel_pressure`, `program_change`, `start`, `stop`, `continue` and `clock` (:52-60), forwarding to the device, which records into `device.sent` (:104-108). There are also `to_data` and `to_msg` (which decodes `program_change`, :89).
  - Test helpers: `plug(port, name)` (:103), `unplug(port)` (:125), `send(port, msg)` (:136) and `context.midi.reassign(from, to)` (norns_stubs.lua:3127; the grid and arc have the same at :2169 and :2245).
  - Adding a stub: write `test/stub_<x>.lua` returning a constructor, `require("stub_<x>")` it in norns_stubs.lua's context setup (as midi at :3124), and assign `_G.<x>` beside :3214-3230. test/run.lua:12 puts test/ on `package.path`. Library modules go through `package.preload` (:3262, :3266).
  - "every global read is defined" (structure_test.lua:400) reads the stubs' globals (`stub_global_names()`), so any new global the script reads (`crow`, `osc`, `softcut`) needs a stub global or an entry in `KNOWN_UNDEFINED_GLOBALS`.

## 14. Limits

- AGENTS.md is 7854 words by `wc -w` against `AGENTS_WORD_LIMIT = 8000` (test/unit/docs_test.lua:779-788, which also checks that the stated "a test fails above 8,000 words" matches). 146 words of headroom.
- 3.5's change (v3.4.0 → v3.5.0): 11243 → 7854 words (3.5 condensed AGENTS.md; the limit test came with that commit, 73aba49f). Table rows went 72 → 80: +4 module rows (notes, mpe, expression, ui/zones) and +4 command rows (noteOn, noteOff, noteExpression, setNotePool). Invariant bullets went 64 → 67.
  - 3.6 can afford roughly: 1-3 module rows (~25-40 words each), 1-2 invariant bullets, and the "nine-page" and `NUM_UI_PAGES` (9) edits. Anything more needs cuts elsewhere.
- Free locals (computed with the structure test's probe, structure_test.lua:521-572; the test prints no counts, only fails under 30): constructor free locals are lib/state.lua 176, lib/midi_in.lua 174, lib/params_setup.lua 172, lib/notes.lua 151, lib/sequencer.lua 100, lib/grid/core.lua 153, lib/arc/core.lua 194, lib/pages/setup.lua 173, lib/macros.lua 144, lib/lfos.lua 133. Main chunks: strata.lua 195, lib/constants.lua 154. No module is near the limit.
- The include rule (test/unit/structure_test.lua:19-56, "only strata.lua includes, once per module, by lib/ paths") scans every file from `find lib -name "*.lua"` (test/sync_check.lua:283-285). It flags any `include(` outside strata.lua, a non-literal path, a path not starting "lib/", and a path included twice.
- The same file set feeds the other source checks, so a library vendored under lib/ (nb: lib/nb/...) is checked too:
  - the include rule (nb's own `include`s);
  - "each file keeps 30 free locals", plus "does not end in the constructor's `  return M\nend`" for every lib/ file but constants (:582-603);
  - "every global read is defined" (:400) and "no global is defined in two files" (:484);
  - "no data file is run as Lua" (tab.load, dofile, loadfile, load: :81);
  - "no Lua 5.2+ name LuaJIT lacks" (:1676), "recursive deletes" (:1733) and `util.scandir` (:2602);
  - the sync check (any non-`engine.<name>(` use of `engine`);
  - the `redraw()` and `ui_page` scan (ui_detent_test, pages-and-dispatch.md:10).
  - A vendored nb fails these unless it lives outside lib/ or the checks get an exclusion.

## 15. `other_owns_slot_1`

- Location: lib/sequencer.lua:446-453, not lib/midi_in.lua.
  ```lua
  local function other_owns_slot_1(voice_idx)
    for _, used in ipairs(S.lib.notes.slots(voice_idx)) do
      if used.slot == 1 then
        return used.held and not used.parked and used.owner ~= SEQ.note_owner and S.lib.midi_in.keeps_own(voice_idx)
      end
    end
    return false
  end
  ```
- It is used once, in `apply_step` (:550): `local own = note_id and not other_owns_slot_1(voice_idx)`.
- `S.lib.midi_in.keeps_own(voice)` (lib/midi_in.lua:409-417) returns false unless `own.owner == MIDI.owner`. So for a third owner holding slot 1, `other_owns_slot_1` returns false.
- The step then treats slot 1 as its own:
  - it calls `leave_extra_slot`;
  - it plays the first note with `quiet = true`, `extra_only = false` and `set_own`;
  - in `S.lib.notes.play`, branches 3-6 may steal the third owner's extra notes (branch 4 or 5) or take slot 1 from it (branch 6 → `play_own`, which forgets its record).
  - This breaks ruling 35 ("a step never takes a slot or a note from another owner").
- What a new note owner must change:
  1. Add it to `NOTES.owners` (lib/notes.lua:30), or `play` refuses its notes and the "notes" invariant flags them.
  2. Change `other_owns_slot_1` (sequencer.lua:449) to return true for a held, unparked non-seq owner whose note is "down" by that owner's own rule, calling `keeps_own` only for MIDI (or a per-owner keeps-own lookup).
  3. Release and reset its notes itself, as MIDI does: `forget_owner` on its own reset, `release`/`release_owner` on its note offs.
  4. Know that `S.lib.sequencer.own_note_taken(voice)` (:503) must be called when its note lands on slot 1, as `midi_note_on` does (lib/midi_in.lua:395).
- Note that external targets (MIDI out, ii) only mirror notes. They need not be note owners at all, since they create no engine slot.

## Surprises

- No note event hooks exist. lib/notes.lua ends notes silently (steals :437 and :453, branch 6 :338, freeze cuts :761, voice stop :751, pool shrink :618). Mirroring notes to MIDI out or ii needs new hooks at `new_record` (:148), `forget` (:155), parking (:478) and `mark_due`/`send_expression` (:162, :123), or targets fed from `midi_note_on` and a step output instead (missing steals and stops).
- `NOTES.owners = {midi = true, seq = true}` (lib/notes.lua:30) is closed. A third owner is refused by `play`.
- `other_owns_slot_1` is in lib/sequencer.lua:446, not midi_in. Through `keeps_own` it returns false for any non-MIDI owner, so the sequencer would steal from a third owner.
- The step event has no absolute pitch: only `semitones` relative to the voice's note param, with chord pitches in a local. A step without notes carries no pitch at all. An external target must recompute it from the private `value_note`/`voice_pitch_note` (sequencer.lua:343-349), or the event gains a field.
- Step notes end at the next step or a pattern stop, never at `gate_beats`. MIDI out must schedule its own note-off from `event.gate_beats` (or `M.gate_seconds`). Step outputs must never yield, so a note-off needs its own clock or timer, not `clock.sleep` in `play`.
- The step-output order follows registration. lib/sequencer.lua is the last include, so an output registered at include time by an earlier module plays before `voices`. One event table is shared by all outputs.
- `stop()` runs only when playing patterns stop. A voice stop or `replace_pattern` reaches no external output.
- `midi.add`, `midi.remove`, `grid.add`, `grid.remove`, `arc.add` and `arc.remove` are overwritten, not chained (midi_in.lua:548-549 and :569-570; grid/core.lua:676 and :686, at include time; arc/core.lua:155 and :165). Controller, iii and output ports need one shared hot-plug dispatcher, or each module overwrites the others.
- norns' PARAMS > MAP handles every CC on every vport (norns core/midi.lua:470-474), absolute or `accum` only, with no pickup. A 3.6 controller mapping beside it double-drives a mapped macro.
- No `register_params` on `S`: a new param group needs an edit to lib/params_setup.lua (:641-644). No `register_page` either: pages assign `S.registry.pages[...]` directly.
- A tenth page breaks hard-coded tests:
  - helpers.lua:637 `PAGE_TITLES`;
  - ui_pages_test.lua:18-35 (nine pages, SCENES = 8, E1 stops at 9), plus :192, which needs an arc file for every page but SETUP;
  - pages_mod_test.lua:117-135 and ui_header_test.lua:77-105 and :450-460 (nine dots, x 36-68, `HEADER` values);
  - arc_pages_test.lua:21 `expected_rings`;
  - docs_test.lua:1389 via AGENTS.md:278 (`NUM_UI_PAGES` (9)).
- The header does not fit ten dots as is: the tenth at x 72-73 overlaps the status play mark at 73. `HEADER.dots_x` or `dot_spacing` must change.
- Virtual grid and arc seams: `attach_grid` and `attach_arc` are local and call `grid.connect`/`arc.connect`. `reconcile_ports`, the "grid keys" invariant, `set_rotation` and SETUP loop ports 1..4, so a virtual grid needs a port above 4 or core changes. The arc's "arc connection" invariant needs `S.arc_device.device`.
- The engine budget code is param-id-keyed and private. An ii or MIDI budget copies the pattern (window, pending, flush clock never canceled) rather than reusing it. `count_sends` counts only engine messages.
- A vendored nb under lib/ would fail the include rule, the constructor and locals probe, the global-read and two-files checks, the chunk loader, LuaJIT, scandir and engine-use scans (all read `find lib -name "*.lua"`).
- No crow, osc, softcut or nb stubs exist, and the global-read check needs any new global provided by a stub.
- The playheads clock is a local (`clock_id`, lib/playheads.lua:19), not an `S` field.
- AGENTS.md has 146 words of headroom.
- Program change is silently ignored today. In the MPE modes it goes to `S.lib.mpe.control(msg)` first, so a PC handler must sit before the MPE branch (midi_in.lua:340).
- `enc_param_delta` reads `S.alt_held`, so it is wrong for MIDI relative input. Use `delta_with_detent(id, d, {source = ...})`; a touch hook gets that source, and macro learn listens to touches.
