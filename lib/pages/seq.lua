-- lib/pages/seq.lua
-- The SEQ page: all seven patterns, the transport and the tempo. One row
-- per voice (its number, sixteen cells at the steps' levels, + or - for
-- running), a step cursor on the selected voice's row. E2 moves the step,
-- E3 sets its level, K2 plays/stops, K3 turns the step on or off; ALT+E2
-- moves to another voice's row (the selected voice follows), ALT+E3 the
-- tempo, ALT+K2 clears and ALT+K3 randomizes the voice's pattern. The
-- header shows the tempo (header_status). E3 (and arc ring 2,
-- lib/arc/seq.lua) set the step's level in S.patterns directly, within
-- bounds; clear and randomize call the sequencer's clear_pattern and
-- randomize_pattern (lib/sequencer.lua). Every pattern edit calls
-- grid_redraw(). Registers its S.registry.pages record (every field but
-- the arc fields, which are lib/arc/seq.lua's).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL

  -- The layout (design §5): rows 6 px apart from y 13, each the voice's
  -- number at x 0 (baseline text_offset below the row's top), 16 cells of
  -- 4x4 px, 6 px apart from x 10, and + or - right-aligned at 127. An empty
  -- step is an outline at empty_level, so a level-1 step never reads as
  -- empty. The playing column draws outlines at playing_outline_level and
  -- cells playing_boost brighter. The cursor is a 6x6 outline at 15
  local SEQ_PAGE = {rows_y = 13, row_spacing = 6, label_x = 0, text_offset = 5, cells_x = 10,
    cell_spacing = 6, cell_size = 4, state_right = 127, empty_level = 1, playing_outline_level = 4,
    playing_boost = 4, cursor_level = 15, label_level = 4, selected_label_level = 15}

  -- The step under the cursor, on the selected voice's row
  local function cursor_step()
    return util.clamp(S.cursors.seq_step, 1, PATTERN_LENGTH)
  end


  -- A pattern edit: the grid shows the patterns, so it follows at once. (The
  -- screen needs nothing here: enc and key in strata.lua request its redraw
  -- after every handler)
  local function pattern_changed()
    grid_redraw()
  end

  local function draw_cell(x, y, level, playing)
    if level > 0 then
      screen.level(playing and math.min(MAX_STEP_LEVEL, level + SEQ_PAGE.playing_boost) or level)
      screen.rect(x, y, SEQ_PAGE.cell_size, SEQ_PAGE.cell_size)
      screen.fill()
    else
      screen.level(playing and SEQ_PAGE.playing_outline_level or SEQ_PAGE.empty_level)
      screen.rect(x, y, SEQ_PAGE.cell_size, SEQ_PAGE.cell_size)
      screen.stroke()
    end
  end

  local function redraw_seq()
    -- the playing column: the step sounding now (nil when stopped), the
    -- one every grid layout lights
    local playing = S.lib.sequencer.sounding_step()
    for voice_idx = 1, NUM_VOICES do
      local y = SEQ_PAGE.rows_y + (voice_idx - 1) * SEQ_PAGE.row_spacing
      local selected = voice_idx == S.selected_voice
      screen.level(selected and SEQ_PAGE.selected_label_level or SEQ_PAGE.label_level)
      screen.move(SEQ_PAGE.label_x, y + SEQ_PAGE.text_offset)
      screen.text(tostring(voice_idx))
      for step = 1, PATTERN_LENGTH do
        draw_cell(SEQ_PAGE.cells_x + (step - 1) * SEQ_PAGE.cell_spacing, y, S.patterns[voice_idx][step],
          step == playing)
      end
      screen.level(SEQ_PAGE.label_level)
      screen.move(SEQ_PAGE.state_right, y + SEQ_PAGE.text_offset)
      screen.text_right(S.voices[voice_idx].active and "+" or "-")
    end

    -- the cursor: a 6x6 outline around the selected voice's step
    local cursor_y = SEQ_PAGE.rows_y + (S.selected_voice - 1) * SEQ_PAGE.row_spacing
    screen.level(SEQ_PAGE.cursor_level)
    screen.rect(SEQ_PAGE.cells_x + (cursor_step() - 1) * SEQ_PAGE.cell_spacing - 1, cursor_y - 1,
      SEQ_PAGE.cell_size + 2, SEQ_PAGE.cell_size + 2)
    screen.stroke()
  end

  -- The hint row (redraw() draws it after the page)
  local function seq_hints(alt_held)
    if alt_held then return "K2:clr K3:rand E3:bpm" end
    return "K2:" .. (S.pattern_playing and "stop" or "play") .. " K3:step E3:level"
  end

  local function seq_enc(n, d)
    if n == 2 then
      S.lib.ui_cursors.move("seq_step", d)
    elseif n == 3 then
      local pattern, step = S.patterns[S.selected_voice], cursor_step()
      if not pattern then return end
      pattern[step] = util.clamp(pattern[step] + d, 0, MAX_STEP_LEVEL)
      pattern_changed()
    end
  end

  -- ALT+E2: another voice's row (the selected voice, as on MAIN); ALT+E3:
  -- the tempo (a number param, so whole BPM: patterns are not params and
  -- have nothing to adjust finely)
  local function seq_alt_enc(n, d)
    if n == 2 then
      S.lib.ui_keys.select_voice_by(d)
      return true
    elseif n == 3 then
      enc_param_delta(n, "tempo", d)
      return true
    end
    return false
  end

  local function seq_key(n)
    if n == 2 then
      pattern_toggle()
    elseif n == 3 then
      toggle_pattern_step(S.selected_voice, cursor_step())
      pattern_changed()
    end
  end

  -- ALT+K2 and ALT+K3 (through alt_action): the selected voice's pattern
  local function seq_alt_key(n)
    if n == 2 then
      clear_pattern(S.selected_voice)
      pattern_changed()
    elseif n == 3 then
      randomize_pattern(S.selected_voice)
      pattern_changed()
    end
  end

  -- The tempo replaces the header's indicators (the play mark stays)
  local function seq_header_status()
    return string.format("%d bpm", math.floor(params:get("tempo") + 0.5))
  end

  -- The arc button plays and stops the patterns (design §7)
  local function seq_arc_button()
    pattern_toggle()
  end

  -- Extra states for the layout tests and the page renders
  local function show_cursor(voice_idx, step)
    return function()
      S.lib.ui_keys.select_voice_by(voice_idx - S.selected_voice)
      S.cursors.seq_step = step
    end
  end
  local layout_states = {
    {name = "cursor-v1-s1", setup = show_cursor(1, 1)},
    {name = "cursor-v1-s16", setup = show_cursor(1, PATTERN_LENGTH)},
    {name = "cursor-v7-s1", setup = show_cursor(NUM_VOICES, 1)},
    {name = "cursor-v7-s16", setup = show_cursor(NUM_VOICES, PATTERN_LENGTH)},
    {name = "levels-playing", setup = function(context)
      for voice_idx = 1, NUM_VOICES do
        for step = 1, PATTERN_LENGTH do
          S.patterns[voice_idx][step] = (voice_idx + step) % 3 == 0 and (voice_idx * step) % (MAX_STEP_LEVEL + 1) or 0
        end
      end
      pattern_toggle()
      context.clock.run_for(0.5)
    end},
    {name = "tempo-300", setup = function()
      params:set("tempo", 300)
      pattern_toggle()
    end},
  }

  -- The page's record, at SEQ's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/seq.lua's
  S.registry.pages[UI_PAGES.index.SEQ] = {name = "SEQ", draw = redraw_seq, hints = seq_hints,
    enc = seq_enc, key = seq_key, alt_enc = seq_alt_enc, alt_key = seq_alt_key,
    header_status = seq_header_status, arc_button = seq_arc_button, layout_states = layout_states}

  return M
end
