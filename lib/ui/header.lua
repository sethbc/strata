-- lib/ui/header.lua
-- The rows every screen page shares: the header at y 8 (draw_header) and
-- the hint row at y 62 (draw_hints). The functions stay global.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  -- Screen pages. E1 selects the page; E2, E3, K2 and K3 go to the page's
  -- handlers in its S.registry.pages record (enc, key, key_release), and
  -- redraw() draws the shared header, then the record's draw function,
  -- then the hint row with the text of the record's hints(alt_held).

  local HINT_ROW_Y = 62

  function draw_header()
    screen.level(15)
    screen.move(0, 8)
    screen.text(UI_PAGES[S.ui_page])

    -- Master density (after the page title; "BUFFER" ends near x=36)
    screen.move(40, 8)
    screen.level(4)
    screen.text("dens:" .. string.format("%.2f", S.master_density))

    -- Mutation indicator (between density and scene)
    if params:get("mutation_enabled") == 1 then
      screen.move(98, 8)
      screen.level(6)
      screen.text("[M]")
    end

    -- Scene indicator (right-aligned to the screen edge)
    if S.current_scene > 0 then
      screen.move(127, 8)
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
