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
  local HINT_ROW_WIDTH = 128

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

  -- "REC" while any slot records (a slot waiting to start, armed by a beat,
  -- a bar or a level, does not count), else "ARM" while one is armed, else nil
  local function record_indicator()
    local armed = false
    for slot = 1, NUM_BUFFERS do
      if S.buffers[slot] and S.buffers[slot].recording then
        local state = S.lib.record.state(slot)
        if state and state.phase == "armed" then
          armed = true
        else
          return "REC"
        end
      end
    end
    return armed and "ARM" or nil
  end

  -- [M] while mutations run, the play mark while patterns play, REC while
  -- any buffer slot records, ARM in its place while a slot only waits to start
  local function draw_indicators()
    if params:get("mutation_enabled") == 1 then
      screen.move(HEADER.mutation_x, HEADER_Y)
      screen.level(6)
      screen.text("[M]")
    end
    if S.pattern_playing then draw_play_mark(HEADER.play_x) end
    local record = record_indicator()
    if record then
      screen.move(HEADER.rec_x, HEADER_Y)
      screen.level(15)
      screen.text(record)
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
        -- it ends where a flash would, where a right-aligned S16 begins
        screen.text(S.lib.ui_text.fit_text(tostring(status), HEADER.flash_x + HEADER.flash_width - HEADER.status_x))
      else
        draw_indicators()
      end
    end

    -- Scene indicator S1-S16 (right-aligned to the screen edge); the scene
    -- a fade goes to blinks, dark at 2 (#254)
    if S.current_scene > 0 then
      screen.move(HEADER.scene_right, HEADER_Y)
      local scene_level = S.scene_sequencer_enabled and 10 or 6
      screen.level(S.lib.scenes.shows_current(S.current_scene) and scene_level or 2)
      screen.text_right("S" .. S.current_scene)
    end
  end

  -- Whether the hint row shows `text` whole: a flash naming a folder picks
  -- a shorter name when not, so the folder's own name shows (#432)
  function M.hint_fits(text)
    return screen.text_extents(S.lib.ui_text.printable(text)) <= HINT_ROW_WIDTH
  end

  -- The hint row, as norns' font draws it (a flash can name a file with
  -- accented letters: S.lib.ui_text.printable, #551) and cut to the screen
  -- (or a long file or folder); the last cut is kept, so a steady hint is
  -- measured once
  local hint_cut = {text = nil, cut = nil}
  function draw_hints(text)
    if text ~= hint_cut.text then
      hint_cut.text = text
      hint_cut.cut = type(text) == "string" and S.lib.ui_text.fit_text(S.lib.ui_text.printable(text), HINT_ROW_WIDTH)
        or text
    end
    screen.level(4)
    screen.move(0, HINT_ROW_Y)
    screen.text(hint_cut.cut)
  end

  return M
end
