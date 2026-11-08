-- lib/ui/alt.lua
-- ALT: K1 held. norns delivers K1 to a script only once it has been held for
-- KEY1_HOLD_TIME (0.25 s); a shorter press opens the norns menu. key() in
-- strata.lua sets ALT through set(held) and sends ALT+K2/ALT+K3 to
-- alt_action (global), which runs the page record's alt_key. Field of this
-- module's table (S.lib.ui_alt): set.
-- S.alt_held and S.key_press_alt live in lib/ui/keys.lua, whose
-- forget_held_keys clears them.

return function(S)
  local M = {}
  local NUM_UI_PAGES = S.constants.NUM_UI_PAGES

  -- Hold or clear ALT. The hint row shows the ALT layer while it is held
  function M.set(held)
    S.alt_held = held == true
    request_redraw()
  end

  -- The ALT action of key n (K2 or K3) on page `page` (an index into
  -- UI_PAGES): runs the page record's alt_key(n), if it has one. Returns
  -- whether it ran. Every ALT+K2/ALT+K3 action goes through here
  function alt_action(page, n)
    if n ~= 2 and n ~= 3 then return false end
    if type(page) ~= "number" or page < 1 or page > NUM_UI_PAGES then return false end
    local record = S.registry.pages[page]
    if not (record and record.alt_key) then return false end
    record.alt_key(n)
    return true
  end

  return M
end
