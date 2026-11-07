-- lib/ui/header.lua
-- The rows every screen page shares: the header at y 8 (draw_header) and
-- the hint row at y 62 (draw_hints). The functions stay global.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local NUM_UI_PAGES = S.constants.NUM_UI_PAGES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local HEADER = S.constants.HEADER

  -- Screen pages. E1 selects the page; E2, E3, K2 and K3 go to the page's
  -- handlers in its S.registry.pages record (enc, key, key_release), and
  -- redraw() draws the shared header, then the record's draw function,
  -- then the hint row with the "hints" flash (lib/ui/flash.lua) or the
  -- text of the record's hints(alt_held).

  local HEADER_Y = 8
  local HINT_ROW_Y = 62

  -- The eight page dots, the current page's bright
  local function draw_page_dots()
    for page = 1, NUM_UI_PAGES do
      screen.level(page == S.ui_page and HEADER.current_dot_level or HEADER.dot_level)
      screen.rect(HEADER.dots_x + (page - 1) * HEADER.dot_spacing, HEADER.dot_y, HEADER.dot_size, HEADER.dot_size)
      screen.fill()
    end
  end

  -- The play mark at x: a filled 3x5 triangle pointing right, one rect per
  -- pixel column (5, 3 and 1 px tall)
  local function draw_play_mark(x)
    screen.level(15)
    for column = 0, 2 do
      screen.rect(x + column, HEADER.play_y + column, 1, 5 - 2 * column)
    end
    screen.fill()
  end

  local function any_slot_recording()
    for slot = 1, NUM_BUFFERS do
      if S.buffers[slot] and S.buffers[slot].recording then return true end
    end
    return false
  end

  -- [M] while mutations run, the play mark while patterns play, REC while
  -- any buffer slot records
  local function draw_indicators()
    if params:get("mutation_enabled") == 1 then
      screen.move(HEADER.mutation_x, HEADER_Y)
      screen.level(6)
      screen.text("[M]")
    end
    if S.pattern_playing then draw_play_mark(HEADER.play_x) end
    if any_slot_recording() then
      screen.move(HEADER.rec_x, HEADER_Y)
      screen.level(15)
      screen.text("REC")
    end
  end

  -- The header, y 8: the page title, then a header flash while one shows,
  -- else the page dots and either the page's header_status (with the play
  -- mark) or the indicators; the scene at the right
  function draw_header()
    screen.level(15)
    screen.move(0, HEADER_Y)
    screen.text(UI_PAGES[S.ui_page])

    local flash = S.lib.ui_flash.text("header")
    if flash then
      screen.level(15)
      screen.move(HEADER.flash_x, HEADER_Y)
      screen.text(S.lib.ui_text.fit_text(flash, HEADER.flash_width))
    else
      draw_page_dots()
      local record = S.registry.pages[S.ui_page]
      local status = record and record.header_status and record.header_status()
      if status then
        if S.pattern_playing then draw_play_mark(HEADER.status_play_x) end
        screen.level(10)
        screen.move(HEADER.status_x, HEADER_Y)
        -- it ends where a flash would, before a right-aligned S8
        screen.text(S.lib.ui_text.fit_text(tostring(status), HEADER.flash_x + HEADER.flash_width - HEADER.status_x))
      else
        draw_indicators()
      end
    end

    -- Scene indicator (right-aligned to the screen edge)
    if S.current_scene > 0 then
      screen.move(HEADER.scene_right, HEADER_Y)
      screen.level(S.scene_sequencer_enabled and 10 or 6)
      screen.text_right("S" .. S.current_scene)
    end
  end

  function draw_hints(text)
    screen.level(4)
    screen.move(0, HINT_ROW_Y)
    screen.text(text)
  end

  return M
end
