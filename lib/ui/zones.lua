-- lib/ui/zones.lua
-- The MPE and zones editor (3.5, design §9.3), S.lib.ui_zones: a modal
-- screen owner (S.lib.ui_modal) that SETUP's mpe & zones row opens. Its
-- rows are the zones' member counts (mpe_lower_members, mpe_upper_members),
-- the member channels' bend range (mpe_bend_range) and one row per voice
-- with three columns, its split zone (v<i>_zone) and the zone's lowest and
-- highest note (v<i>_zone_low, v<i>_zone_high, named as norns names notes:
-- 60 is C3). E2 the row, K3 the next column on a voice row, E3 the value
-- under the cursor, K2 closes; ALT+K3 on a voice row learns its range: the
-- next two notes played (through the MIDI module's note tap,
-- S.lib.midi_in.set_note_tap, ZONES_EDITOR.tap_owner its owner) are its lowest and highest, with a header
-- notice and a 10 s timeout, as MOD's learn has. Fields of this module's
-- table: open, close, is_open, learn, cancel_learn, learning, note,
-- ZONES_EDITOR. See docs/notes/lua/ui-core.md (The zones editor).

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local field_list = S.lib.ui_field_list
  local musicutil = require "musicutil"

  -- The editor's tunables and layout: learn's timeout (its clock is the
  -- clock helper's, #870); six rows from y 18, 7 px apart, as SETUP's; a
  -- voice row's columns (the label at x 0, the zone from zone_x, the lowest note
  -- right-aligned at low_right, the highest at value_right, where a count
  -- row's value goes; the scroll marker owns x 127); the levels (the
  -- cursor's column, the rest of its row, the other rows); the notes a zone
  -- range holds
  local ZONES_EDITOR = {learn_seconds = 10,
    visible = 6, first_y = 18, spacing = 7, zone_x = 20, low_right = 94, value_right = 124,
    levels = {selected = 15, row = 8, other = 4},
    columns = {"zone", "low", "high"}, column_params = {zone = "", low = "_low", high = "_high"},
    note_range = {0, 127}, learn_text = "learn", tap_owner = "zones editor"}
  M.ZONES_EDITOR = ZONES_EDITOR

  -- The rows, top to bottom: the three settings, then one per voice
  local ROWS = {
    {label = "lower members", param_id = "mpe_lower_members", unit = ""},
    {label = "upper members", param_id = "mpe_upper_members", unit = ""},
    {label = "bend range", param_id = "mpe_bend_range", unit = " st"},
  }
  for voice = 1, NUM_VOICES do
    table.insert(ROWS, {label = "v" .. voice, voice = voice})
  end

  -- open; the cursor's row (an index into ROWS) and a voice row's column
  -- (an index into ZONES_EDITOR.columns); both kept while it is closed
  local editor = {open = false, row = 1, column = 1}
  -- {voice, which = "low" | "high", first} while learn waits for a note
  local learning = nil
  -- Learn's timeout clock's handle (S.lib.clocks, #870; S.zones_learn_clock
  -- is its id while learn waits): its end stops it through the helper,
  -- which never cancels it once norns may have posted its resume (#626) but
  -- retires it, and at its wake it ends, touching nothing a newer learn armed
  local learn_clock = {handle = nil}
  S.zones_learn_clock = nil
  -- whether the editor's M.note is the MIDI module's note tap now (set
  -- when a learn starts, cleared when it ends), under the owner
  -- ZONES_EDITOR.tap_owner (3.9, #900)
  local tap_set = false

  -- Take the tap (fn) or give it up (nil); a set another owner's tap
  -- refuses leaves tap_set false
  local function set_tap(fn)
    if fn then
      tap_set = S.lib.midi_in.set_note_tap(ZONES_EDITOR.tap_owner, fn) ~= false
    else
      S.lib.midi_in.clear_note_tap(ZONES_EDITOR.tap_owner)
      tap_set = false
    end
  end

  local function whole_in(value, low, high)
    return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
  end

  local function zone_param(voice, column)
    return "v" .. voice .. "_zone" .. ZONES_EDITOR.column_params[ZONES_EDITOR.columns[column]]
  end

  local function note_name(note)
    return musicutil.note_num_to_name(note, true)
  end

  ---------------------------------------------------------------------------
  -- Learn
  ---------------------------------------------------------------------------

  -- End the learn waiting (none: nothing): its clock canceled or retired,
  -- the note tap cleared
  function M.cancel_learn()
    if learn_clock.handle then
      S.lib.clocks.stop(learn_clock.handle)
      learn_clock.handle, S.zones_learn_clock = nil, nil
    end
    if learning then
      learning = nil
      set_tap(nil)
      request_redraw()
    end
  end

  -- Learn voice's range while the editor is open: the next note is its
  -- lowest, the one after its highest (M.note, set as the MIDI module's note
  -- tap); learn_seconds without both, K2 (which closes the editor) or a new
  -- learn ends it, and so does a MIDI reset (the tap's owner told). A tap
  -- another owner holds leaves nothing waiting. Returns whether it waits
  function M.learn(voice)
    if not editor.open or not whole_in(voice, 1, NUM_VOICES) then return false end
    M.cancel_learn()
    set_tap(M.note)
    if not tap_set then return false end
    learning = {voice = voice, which = "low"}
    local started = S.lib.clocks.run(function(handle)
      if not handle.sleep(ZONES_EDITOR.learn_seconds) then return end
      learn_clock.handle, S.zones_learn_clock = nil, nil
      learning = nil
      set_tap(nil)
      request_redraw()
    end)
    learn_clock.handle, S.zones_learn_clock = started, started.id
    request_redraw()
    return true
  end

  -- The voice learn waits for and which note it waits for ("low" or
  -- "high"), or nil
  function M.learning()
    if learning then return learning.voice, learning.which end
    return nil
  end

  -- The note tap: a note on (0-127) while learn waits is taken (true), so it
  -- plays nothing. The first sets the voice's lowest note, the second its
  -- highest, the two swapped when the second is the lower, and learn ends.
  -- The lowest is set before the highest, so neither param's action moves
  -- the other (lib/mpe.lua keeps low <= high). 3.9 (#900): nil is the MIDI
  -- module telling the owner it cleared the tap (a reset, cleanup): learn
  -- ends. While another owner covers the editor (SEQ's step editor) it
  -- takes no note, which plays as with no tap; uncovered, it takes them again
  local owner
  function M.note(note)
    if note == nil then
      if learning then M.cancel_learn() end
      return false
    end
    if not learning or not whole_in(note, ZONES_EDITOR.note_range[1], ZONES_EDITOR.note_range[2]) then
      return false
    end
    if S.lib.ui_modal.top() ~= owner then return false end
    local voice = learning.voice
    if learning.which == "low" then
      learning.which, learning.first = "high", note
      params:set(zone_param(voice, 2), note)
      request_redraw()
      return true
    end
    local low, high = math.min(learning.first, note), math.max(learning.first, note)
    M.cancel_learn()
    params:set(zone_param(voice, 2), low)
    params:set(zone_param(voice, 3), high)
    return true
  end

  -- While learn waits the header says so on every page (a standing notice:
  -- it goes the moment learn ends; every way it ends asks for a redraw)
  S.lib.ui_flash.add_notice("header", function()
    if learning then return "learn v" .. learning.voice .. " " .. learning.which end
    return nil
  end)

  ---------------------------------------------------------------------------
  -- The modal owner (declared above M.note, which reads it)
  ---------------------------------------------------------------------------

  local function draw_row(row, y, selected, value_right)
    local levels = ZONES_EDITOR.levels
    if not row.voice then
      screen.level(selected and levels.selected or levels.other)
      screen.move(0, y)
      screen.text(row.label)
      screen.move(value_right, y)
      screen.text_right(params:get(row.param_id) .. row.unit)
      return
    end
    local function level(column)
      if not selected then return levels.other end
      return column == editor.column and levels.selected or levels.row
    end
    local learn_voice, waiting = M.learning()
    local function column_text(column)
      local name = ZONES_EDITOR.columns[column]
      if learn_voice == row.voice and waiting == name then return ZONES_EDITOR.learn_text, true end
      if name == "zone" then return params:string(zone_param(row.voice, column)) end
      return note_name(params:get(zone_param(row.voice, column)))
    end
    screen.level(selected and levels.row or levels.other)
    screen.move(0, y)
    screen.text(row.label)
    local places = {{ZONES_EDITOR.zone_x, "left"}, {ZONES_EDITOR.low_right, "right"}, {value_right, "right"}}
    for column, place in ipairs(places) do
      local text, waits = column_text(column)
      screen.level(waits and levels.selected or level(column))
      screen.move(place[1], y)
      if place[2] == "left" then screen.text(text) else screen.text_right(text) end
    end
  end

  local function draw()
    if not editor.open then return end
    field_list.draw(ROWS, editor.row, {visible = ZONES_EDITOR.visible, first_y = ZONES_EDITOR.first_y,
      spacing = ZONES_EDITOR.spacing, value_right = ZONES_EDITOR.value_right}, draw_row)
  end

  -- The hint row: K3 only on a voice row (its column, or with ALT its
  -- learn); E3 on every row (with ALT it turns as without: number and
  -- option params have no fine step, so ALT names E2, K3's learn and E3,
  -- #844, as the scale editor's ALT hints name its E3)
  local function hints(alt_held)
    local voice_row = ROWS[editor.row].voice ~= nil
    if alt_held then return voice_row and "E2:row K3:learn E3:value" or "E2:row E3:value" end
    return voice_row and "K2:back K3:column E3:value" or "K2:back E3:value"
  end

  -- E2 the row (clamped), E3 the value under the cursor (enc_param_delta)
  local function enc(n, d)
    if not editor.open then return end
    if n == 2 then
      editor.row = util.clamp(editor.row + d, 1, #ROWS)
    elseif n == 3 then
      local row = ROWS[editor.row]
      enc_param_delta(n, row.voice and zone_param(row.voice, editor.column) or row.param_id, d)
    end
    request_redraw()
  end

  -- At the press: K2 closes (with ALT nothing); K3 on a voice row the next
  -- column (wrapping), with ALT its learn
  local function key(n, z)
    if not editor.open or z ~= 1 then return end
    local row = ROWS[editor.row]
    if n == 2 and not S.alt_held then
      M.close()
    elseif n == 3 and row.voice then
      if S.alt_held then
        M.learn(row.voice)
      else
        editor.column = editor.column % #ZONES_EDITOR.columns + 1
        request_redraw()
      end
    end
  end

  owner = {draw = draw, hints = hints, enc = enc, key = key}

  -- Open the editor over the page (from SETUP's mpe & zones row); already
  -- open, nothing
  function M.open()
    if editor.open then return end
    editor.open = true
    S.lib.ui_modal.push(owner)
  end

  -- Close it (learn ends); closed, nothing
  function M.close()
    if not editor.open then return end
    M.cancel_learn()
    editor.open = false
    S.lib.ui_modal.pop(owner)
  end

  function M.is_open()
    return editor.open
  end

  -- Cleanup ends a learn waiting (its clock canceled, the tap cleared; the
  -- helper's own step, the last, cancels what it retired)
  S.register_cleanup(S.constants.CLEANUP_ORDER.zones_learn, function()
    S.lib.clocks.cancel(learn_clock.handle)
    M.cancel_learn()
  end)

  -- Learn waits exactly while its timeout clock is pending (its coroutine
  -- alive) and the note tap is the editor's, and only while the editor is
  -- open; a retired clock (the helper's) is never S.zones_learn_clock; the
  -- closed editor's owner is never the modal one, the
  -- open editor's own owner is (or is beneath SEQ's step editor); the
  -- cursor is on a row and a column
  S.register_invariant("zones editor", function()
    if (learning ~= nil) ~= (S.zones_learn_clock ~= nil) then
      return "learn waits: " .. tostring(learning ~= nil) .. ", but its clock is " .. tostring(S.zones_learn_clock)
    end
    local pending = S.zones_learn_clock and clock.threads and clock.threads[S.zones_learn_clock]
    if S.zones_learn_clock and clock.threads and (type(pending) ~= "thread" or coroutine.status(pending) == "dead") then
      return "learn's clock " .. tostring(S.zones_learn_clock) .. " is no longer pending"
    end
    if (learning ~= nil) ~= tap_set then
      return "learn waits: " .. tostring(learning ~= nil) .. ", but the note tap is " .. (tap_set and "set" or "not set")
    end
    if learning and not editor.open then return "learn waits with the editor closed" end
    if S.zones_learn_clock and S.lib.clocks.retired[S.zones_learn_clock] then
      return "the retired learn clock " .. S.zones_learn_clock .. " is still the learn clock"
    end
    local top = S.lib.ui_modal.top()
    if not editor.open and top == owner then return "the editor is closed but its owner is the modal one" end
    -- open: its own owner is the modal one, but for the one owner a grid
    -- can push over it, SEQ's step editor (its own invariant holds that)
    if editor.open and top ~= owner and not (top == S.lib.pages_seq.step_editor_owner and S.lib.pages_seq.step_editor()) then
      return "the editor is open but the modal owner is " .. tostring(top) .. ", not its own"
    end
    if not whole_in(editor.row, 1, #ROWS) or not whole_in(editor.column, 1, #ZONES_EDITOR.columns) then
      return "the cursor is on row " .. tostring(editor.row) .. ", column " .. tostring(editor.column)
    end
  end)

  return M
end
