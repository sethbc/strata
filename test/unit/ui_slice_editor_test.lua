-- test/unit/ui_slice_editor_test.lua
-- The slice editor (lib/ui/slice_editor.lua, S.lib.ui_slice_editor, 3.7
-- design §3.7): a modal owner K3 opens from BUFFER's slices field. It
-- picks, nudges, adds and deletes a file's markers and edits the file's
-- mode, amount, tempo, bars, key and normalize. The slices and the file's
-- settings are S.lib.slices' and S.lib.samples' (packages 2b and 2d): the
-- tests set doubles of the functions the editor consumes (h.slice_doubles)
-- Run alone: lua test/run.lua ui_slice_editor

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, next_frame, finish_startup = h.load_strata, h.local_value, h.next_frame, h.finish_startup
local show_page, assert_screen_layout, hint_text, tap = h.show_page, h.assert_screen_layout, h.hint_text, h.tap

-- The editor's doubles (h.slice_doubles' editor ones: the slot's
-- markers, settings, frames and rate, and a log of the edits made), set as
-- fields of the real S.lib.slices, S.lib.samples and S.lib.waveforms after
-- startup
local function plug_doubles()
  return h.slice_doubles(local_value("S"), nil, { editor = true })
end

-- A slot holding `seconds` of audio, as the engine reports it
local function with_audio(context, slot, seconds)
  local S = local_value("S")
  load_buffer(slot, "/tmp/take" .. slot .. ".wav")
  context.polls.fire("bufferState", context.polls.buffer_state_value(slot, S.buffers[slot].loads_sent, seconds))
end

-- A started script with the doubles, BUFFER shown, slot 1 holding 2 s
-- (96000 frames) cut at {0, 12000, 24000, 48000} in equal mode
local function loaded()
  local context = load_strata()
  finish_startup(context)
  local fake = plug_doubles()
  local S = local_value("S")
  show_page("BUFFER")
  with_audio(context, 1, 2)
  S.lib.samples.settings(1).mode = 2
  S.lib.samples.settings(1).count = 4
  fake.markers[1] = { 0, 12000, 24000, 48000 }
  return context, S, fake, S.lib.ui_slice_editor
end

local function with_alt(fn) key(1, 1); fn(); key(1, 0) end

-- Start (running true) or stop a voice, whatever it does now
local function run_voice(voice, running)
  if local_value("S").voices[voice].active ~= running then toggle_voice(voice) end
end

-- Move BUFFER's field cursor to field n
local function to_field(n) with_alt(function() enc(2, -20); enc(2, n - 1) end) end

-- A field drawn as its label and, on the same row, its value
local function pair(context, label, value)
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == label then
      for _, other in ipairs(h.texts_on_row(context, entry.y)) do
        if other.text == value and other.align == "right" then return true end
      end
    end
  end
  return false
end

local function screen_has(context, text)
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == text then return true end
  end
  return false
end

-- The editor's rows mode on the row named `name`
local function pick_row(editor, name)
  with_alt(function() enc(2, -20) end)   -- into the rows, on the row last picked
  local rows = editor.EDITOR.rows
  local index
  for k, row in ipairs(rows) do if row == name then index = k end end
  with_alt(function() enc(2, -#rows); enc(2, index - 1) end)
  assert_equal(editor.state().row, name, "the row " .. name .. " is picked")
end

test("K3 on BUFFER's slices field opens the editor and records nothing; on any other field it records", function()
  local context, S, _, editor = loaded()
  to_field(12)
  redraw()
  assert_equal(hint_text(context), "K2:ld/clr K3:edit", "the slices field names K3's edit")
  context.clear_engine_calls()
  tap(3)
  assert_true(editor.is_open(), "K3 opens the editor")
  assert_equal(S.lib.ui_modal.top() ~= nil, true, "as a modal owner")
  assert_equal(editor.state().slot, 1, "for the cursor's slot")
  assert_equal(#context.calls_named("recordBuffer"), 0, "and records nothing")
  redraw()
  assert_true(screen_has(context, "buf 1") and screen_has(context, "slices"), "its title")
  tap(2)
  assert_true(not editor.is_open(), "K2 closes it")
  -- an empty slot: refused, with BUFFER's empty flash
  enc(2, 1); tap(3); redraw()
  assert_true(not editor.is_open(), "no editor for a slot with no audio")
  assert_equal(hint_text(context), "buf 2 empty")
  assert_equal(#context.calls_named("recordBuffer"), 0)
  -- every other field: K3 records
  to_field(11); tap(3)
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 on fric records")
  assert_true(not editor.is_open())
end)

test("E2 picks a marker and E3 nudges it by a millisecond, ALT by a tenth", function()
  local context, _, fake, editor = loaded()
  assert_true(editor.open(1))
  redraw()
  assert_equal(editor.state().marker, 1, "the editor opens on the first marker")
  assert_true(pair(context, "slice", "1/4"), "slice 1/4")
  enc(2, 2)
  assert_equal(editor.state().marker, 3, "E2 picks marker 3")
  enc(3, 1)
  assert_equal(fake.log[#fake.log], "nudge 1 3 48", "one detent at 48 kHz: 48 frames")
  with_alt(function() enc(3, 1) end)
  assert_equal(fake.log[#fake.log], "nudge 1 3 5", "with ALT 4.8 frames, rounded to 5")
  enc(3, -2)
  assert_equal(fake.log[#fake.log], "nudge 1 3 -96", "two detents down")
  assert_equal(fake.markers[1][3], 24000 + 48 + 5 - 96)
  redraw()
  assert_true(screen_has(context, "at") and screen_has(context, "0.499s"), "its seconds: 23957 / 48000")
  enc(2, 10)
  assert_equal(editor.state().marker, 4, "E2 stops at the last marker")
  enc(2, -10)
  assert_equal(editor.state().marker, 1, "and at the first")
  local before = #fake.log
  enc(3, 1); with_alt(function() enc(3, 1) end)
  assert_equal(#fake.log, before, "the first marker never moves")
  assert_equal(fake.markers[1][1], 0)
end)

test("K3 adds a marker at the playhead, and ALT+K3 deletes the selected one", function()
  local context, S, fake, editor = loaded()
  params:set("v1_source", 2)            -- voice 1 reads slot 1
  params:set("v1_buf_scan", 0); params:set("v1_buf_pos", 0.375)
  run_voice(1, true)
  assert_true(S.voices[1].active)
  editor.open(1)
  tap(3)
  assert_equal(fake.log[#fake.log], "add 1 36000", "at the running voice's playhead: 0.375 of 96000")
  assert_equal(editor.state().marker, 4, "the new marker is selected")
  -- stopped: the middle of the selected slice
  run_voice(1, false)
  enc(2, -2)                              -- marker 2: 12000 to 24000
  tap(3)
  assert_equal(fake.log[#fake.log], "add 1 18000", "a stopped voice: the middle of slice 2")
  assert_equal(editor.state().marker, 3)
  -- the last slice runs to the end of the frames
  enc(2, 10); tap(3)
  assert_equal(fake.log[#fake.log], "add 1 72000", "the middle of 48000 to 96000")
  -- a voice that reads another slot: the middle too
  params:set("v1_source", 3); run_voice(1, true)
  enc(2, -10); tap(3)
  assert_equal(fake.log[#fake.log], "add 1 6000", "the selected voice reads slot 2: the middle of slice 1")
  run_voice(1, false)
  -- ALT+K3 deletes the selected marker
  enc(2, 1)
  assert_equal(editor.state().marker, 3)
  with_alt(function() tap(3) end)
  assert_equal(fake.log[#fake.log], "delete 1 3", "ALT+K3 deletes marker 3")
  assert_equal(table.concat(fake.markers[1], " "), "0 6000 18000 24000 36000 48000 72000")
  assert_equal(editor.state().marker, 2, "the one before it is selected")
  enc(2, -10)
  local before = #fake.log
  with_alt(function() tap(3) end)
  assert_equal(#fake.log, before, "the first marker is never deleted")
  assert_true(editor.is_open(), "and K3 closes nothing")
  redraw()
  assert_equal(hint_text(context), "K2:back K3:add E3:nudge")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "E2 rows E3 fine K3 delete")
  key(1, 0)
end)

test("an add at 64 markers flashes and adds nothing", function()
  local context, _, fake, editor = loaded()
  local list = {}
  for k = 1, 64 do list[k] = (k - 1) * 1000 end
  fake.markers[1] = list
  editor.open(1)
  tap(3); redraw()
  assert_equal(#fake.markers[1], 64, "still 64")
  assert_equal(hint_text(context), "64 slices max", "the hint row says why")
  assert_screen_layout(context, "the editor's full flash")
end)

test("turning the amount after a hand edit remakes the slices and says edits dropped", function()
  local context, S, fake, editor = loaded()
  context.set_time(100)
  editor.open(1)
  pick_row(editor, "amount")
  redraw()
  assert_true(screen_has(context, "count") and screen_has(context, "4"), "equal mode's amount is the count")
  enc(3, 1); redraw()
  assert_equal(S.lib.samples.settings(1).count, 5, "E3 sets the count")
  assert_equal(fake.made, 1, "and makes the slices")
  assert_true(hint_text(context) ~= "edits dropped", "nothing was edited by hand")
  -- a hand edit, then the amount
  enc(2, 1)                               -- E2: back to the markers
  assert_equal(editor.state().view, "markers")
  enc(2, 1); enc(3, 1)
  assert_true(S.lib.samples.settings(1).edited, "a nudge is a hand edit")
  pick_row(editor, "amount")
  enc(3, -1); redraw()
  assert_equal(S.lib.samples.settings(1).count, 4)
  assert_equal(fake.made, 2)
  assert_equal(hint_text(context), "edits dropped", "the flash says the edits went")
  -- transients: the sensitivity, 0-100
  context.set_time(110)
  S.lib.samples.settings(1).mode = 3
  enc(3, 3); redraw()
  assert_equal(S.lib.samples.settings(1).sensitivity, 53, "E3 sets the sensitivity in transients mode")
  assert_true(screen_has(context, "sens") and screen_has(context, "53%"))
  enc(3, 100)
  assert_equal(S.lib.samples.settings(1).sensitivity, 100, "at most 100")
  -- off: the count is kept for later and nothing is made
  S.lib.samples.settings(1).mode = 1
  local made = fake.made
  enc(3, -100)
  assert_equal(S.lib.samples.settings(1).count, 2, "the count stops at 2")
  assert_equal(fake.made, made, "in off nothing is made")
end)

test("mode, tempo, bars, key and norm edit the file's settings", function()
  local context, S, fake, editor = loaded()
  local settings = S.lib.samples.settings(1)
  settings.mode = 1
  editor.open(1)
  pick_row(editor, "mode")
  redraw(); assert_true(screen_has(context, "off"))
  enc(3, 1)
  assert_equal(settings.mode, 2, "E3 steps the mode"); assert_equal(fake.made, 1, "and makes the slices")
  enc(3, 5)
  assert_equal(settings.mode, 3); redraw()
  assert_true(screen_has(context, "transients"))
  -- tempo: from none a turn up starts at the clock's tempo, 0.1 a detent
  pick_row(editor, "tempo")
  redraw(); assert_true(screen_has(context, "--"), "no tempo")
  enc(3, -1)
  assert_equal(settings.tempo, nil, "a turn down from none does nothing")
  enc(3, 1)
  assert_equal(settings.tempo, clock.get_tempo(), "the clock's tempo")
  enc(3, 5)
  assert_true(math.abs(settings.tempo - (clock.get_tempo() + 0.5)) < 1e-9, "0.1 a detent")
  settings.tempo = 20
  redraw(); assert_true(screen_has(context, "20.0"))
  enc(3, -1); redraw()
  assert_equal(settings.tempo, nil, "below 20 it clears")
  assert_equal(fake.log[#fake.log], "set 1 tempo nil")
  settings.tempo = 299.95
  enc(3, 5)
  assert_equal(settings.tempo, 300, "at most 300")
  -- bars, on an 8 s slot
  with_audio(context, 1, 8)
  settings.tempo = 30
  pick_row(editor, "bars")
  redraw(); assert_true(screen_has(context, "bars") and screen_has(context, "1"), "8 s at 30 BPM: one bar")
  enc(3, 1)
  assert_equal(settings.tempo, 60, "bars 2 on an 8 s slot: tempo 60")
  enc(3, -3)
  assert_equal(settings.tempo, 30, "down to 1 bar: 1/2 would be 15 BPM, refused")
  enc(3, 5)
  assert_equal(settings.tempo, 240, "up to 8 bars: 16 would be 480 BPM, refused")
  redraw(); assert_true(screen_has(context, "8"))
  settings.tempo = 45
  redraw(); assert_true(screen_has(context, "1.50"), "a count that is not on the list")
  enc(3, 1)
  assert_equal(settings.tempo, 60, "up from 1.5: 2 bars")
  settings.tempo = 120 * 0.25 * 1.01 * 2
  redraw(); assert_true(screen_has(context, "2.02"))
end)

test("the key row sets a MIDI note number and norm shows its gain", function()
  local context, S, fake, editor = loaded()
  local settings = S.lib.samples.settings(1)
  editor.open(1)
  pick_row(editor, "key")
  redraw(); assert_true(screen_has(context, "--"), "the key unset")
  enc(3, -1); assert_equal(settings.key, nil, "a turn down from unset: still unset")
  enc(3, 3); redraw()
  assert_equal(settings.key, 60, "a turn up from unset starts at the rate's root note, 60")
  assert_true(screen_has(context, "C3"), "60 is C3")
  enc(3, -60); redraw()
  assert_equal(settings.key, 0); assert_true(screen_has(context, "C-2"), "as norns names note 0")
  enc(3, 200); assert_equal(settings.key, 127, "at most 127")
  enc(3, -200); assert_equal(settings.key, nil, "down past 0: unset")
  assert_equal(fake.log[#fake.log], "set 1 key nil")
  pick_row(editor, "norm")
  redraw(); assert_true(screen_has(context, "off"))
  fake.gain = 4
  enc(3, 1); redraw()
  assert_equal(settings.normalize, true, "E3 up: on")
  assert_true(screen_has(context, "+12.0dB"), "showing the gain in dB")
  fake.gain = 16; redraw()
  assert_true(screen_has(context, "+24.1dB"))
  enc(3, -1)
  assert_equal(settings.normalize, false, "E3 down: off")
end)

test("a MIDI note sets the key while its row is picked, and at no other time", function()
  local context, S, _, editor = loaded()
  local settings = S.lib.samples.settings(1)
  local function note(number)
    context.midi.send(1, { type = "note_on", note = number, vel = 100, ch = 1 })
    context.midi.send(1, { type = "note_off", note = number, vel = 0, ch = 1 })
    for _ = 1, 2 do context.clock.advance_until(S.lfo_clock) end
  end
  note(50)
  assert_equal(settings.key, nil, "the editor closed: nothing")
  editor.open(1)
  note(51)
  assert_equal(settings.key, nil, "the markers: nothing")
  pick_row(editor, "tempo")
  note(52)
  assert_equal(settings.key, nil, "another row: nothing")
  pick_row(editor, "key")
  note(57)
  assert_equal(settings.key, 57, "the key row: the note's number")
  redraw(); assert_true(screen_has(context, "A2"))
  note(62)
  assert_equal(settings.key, 62, "each note sets it again")
  tap(2)
  note(64)
  assert_equal(settings.key, 62, "closed again: nothing")
end)

test("the editor shows analyzing until the candidates arrive", function()
  local context, _, fake, editor = loaded()
  editor.open(1)
  fake.analyzing[1] = true
  redraw()
  assert_true(screen_has(context, "analyzing"), "analyzing")
  assert_true(not screen_has(context, "slice"), "in place of slice i/n")
  assert_true(local_value("S").lib.ui_modal.top().animates(), "the editor redraws until the report")
  assert_screen_layout(context, "the editor analyzing")
  fake.analyzing[1] = false
  redraw()
  assert_true(pair(context, "slice", "1/4"))
end)

-- Slot 1's peaks file, every point at `peak`, as the engine writes it
local function write_peaks(context, S, frames, peak)
  load_buffer(1, "/tmp/take1.wav")
  local folder = S.lib.scenes.scene_data_dir
  util.make_dir(folder)
  local values = {}
  for index = 1, S.constants.WAVEFORM_POINTS do values[index] = string.format("%.3f", peak) end
  local file = assert(io.open(folder .. "buf1.peaks", "w"))
  file:write("strata-peaks 1\nslot 1\nframes " .. frames .. "\nrate 48000\ngeneration 1\npeaks "
    .. table.concat(values, " ") .. "\n")
  file:close()
  -- a load over audio reports 0 s first, then its length (lib/buffers.lua's awaiting_zero)
  context.polls.fire("bufferState", context.polls.buffer_state_value(1, S.buffers[1].loads_sent, 0))
  context.polls.fire("bufferState", context.polls.buffer_state_value(1, S.buffers[1].loads_sent, frames / 48000))
  context.clock.run_for(0.2)
end

test("the editor draws the waveform at 2 px, its markers above it and the playing slice", function()
  local context, S, fake, editor = loaded()
  write_peaks(context, S, 96000, 0.5)
  editor.open(1)
  enc(2, 1)
  fake.playing[1] = { 3 }
  params:set("v1_source", 2)
  redraw()
  local LAYOUT = editor.EDITOR.layout
  local columns, ticks, span = {}, {}, {}
  for _, rect in ipairs(context.screen.rects) do
    if rect.w == 2 and rect.y >= LAYOUT.wave_top then columns[rect.x] = rect.level end
    if rect.y == LAYOUT.tick_y and rect.w == 1 then ticks[rect.x] = rect.level end
  end
  for _, line in ipairs(context.screen.lines) do
    if line.y1 == LAYOUT.span_y and line.y2 == LAYOUT.span_y then table.insert(span, line) end
  end
  local count = 0
  for x = 0, 126, 2 do if columns[x] then count = count + 1 end end
  assert_equal(count, 64, "64 points, 2 px apart from x 0")
  assert_equal(ticks[0], 6, "marker 1 at x 0, at 6")
  assert_equal(ticks[16], 15, "the selected marker 2 (12000 of 96000) at x 16, at 15")
  assert_equal(ticks[32], 6); assert_equal(ticks[64], 6)
  assert_equal(#span, 1, "the playing slice's span")
  assert_equal(span[1].x1, 32); assert_equal(span[1].x2, 63)
  assert_equal(span[1].level, 12)
  -- the selected voice's playhead while it runs on the slot
  params:set("v1_buf_scan", 0); params:set("v1_buf_pos", 0.75); run_voice(1, true)
  redraw()
  local head
  for _, line in ipairs(context.screen.lines) do
    if line.x1 == 96 and line.x2 == 96 and line.level == 15 then head = line end
  end
  assert_true(head ~= nil, "the playhead at x 96")
end)

test("the editor lays out in each mode, with 1, 12 and 64 markers, and with each row picked", function()
  load_strata()
  local S = local_value("S")
  local BUFFER = S.constants.UI_PAGES.index.BUFFER
  local states = {}
  for index, state in ipairs(S.registry.pages[BUFFER].layout_states) do
    if state.name:match("^slice editor") then table.insert(states, { index = index, name = state.name }) end
  end
  local wanted = { "slice editor 1 marker", "slice editor 12 markers", "slice editor 64 markers (high, 300 s)",
    "slice editor analyzing", "slice editor full flash", "slice editor edits dropped flash" }
  for _, row in ipairs(S.lib.ui_slice_editor.EDITOR.rows) do table.insert(wanted, "slice editor row " .. row) end
  local listed = {}
  for _, entry in ipairs(states) do listed[entry.name] = true end
  for _, name in ipairs(wanted) do assert_true(listed[name], "a layout state " .. name) end
  for _, entry in ipairs(states) do
    for _, alt in ipairs({ false, true }) do
      local context = load_strata()
      finish_startup(context)
      plug_doubles()
      show_page("BUFFER")
      local state = local_value("S").registry.pages[BUFFER].layout_states[entry.index]
      state.setup(context)
      assert_true(local_value("S").lib.ui_slice_editor.is_open(), entry.name .. " opens the editor")
      key(1, alt and 1 or 0)
      redraw()
      assert_screen_layout(context, entry.name .. (alt and " with ALT" or ""))
      key(1, 0)
    end
  end
end)

test("the slot emptied under the editor closes it", function()
  local context, S, fake, editor = loaded()
  with_audio(context, 2, 3)
  editor.open(1)
  fake.bind(2)
  assert_true(editor.is_open(), "another slot's bind leaves it open")
  fake.bind(1)
  assert_true(editor.is_open(), "a bind of its slot with audio leaves it open")
  clear_buffer(1)
  S.buffers[1].seconds = 0
  fake.bind(1)
  assert_true(not editor.is_open(), "its slot emptied: closed")
  assert_equal(S.lib.ui_modal.top(), nil, "and off the stack")
  assert_true(not editor.open(1), "and it does not open on an empty slot")
end)

end
