-- lib/ui/alt.lua
-- ALT: K1 held. norns delivers K1 to a script only once it has been held for
-- KEY1_HOLD_TIME (0.25 s); a shorter press opens the norns menu. key() in
-- strata.lua sets ALT through set(held) and sends ALT+K2/ALT+K3 to
-- alt_action (global), which runs the page record's alt_key. long_press(n)
-- is the hook for the long-press fallback (3.1 design §2): if K1 is ever
-- dropped as ALT, a LONG_PRESS_SECONDS hold of K2/K3 calls it. Fields of
-- this module's table (S.lib.ui_alt): set, long_press.
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
  -- whether it ran. Every ALT+K2/ALT+K3 action goes through here, so ALT
  -- and the long-press fallback trigger the same actions
  function alt_action(page, n)
    if n ~= 2 and n ~= 3 then return false end
    if type(page) ~= "number" or page < 1 or page > NUM_UI_PAGES then return false end
    local record = S.registry.pages[page]
    if not (record and record.alt_key) then return false end
    record.alt_key(n)
    return true
  end

  -- The long-press fallback's hook: key n (K2 or K3) has been held for
  -- LONG_PRESS_SECONDS. If it is still down on the page showing and is not
  -- already an ALT press, it becomes one: its ALT action runs now and its
  -- release goes to alt_key_release, as an ALT press's does. The press is
  -- marked ALT even when the page has no alt_key, so its plain key_release
  -- is swallowed (a long press never also runs the short-press release).
  -- Returns whether the press became an ALT press. Unused while K1 works as
  -- ALT
  function M.long_press(n)
    if n ~= 2 and n ~= 3 then return false end
    if S.key_press_page[n] ~= S.ui_page or S.key_press_alt[n] then return false end
    S.key_press_alt[n] = true
    alt_action(S.ui_page, n)
    request_redraw()
    return true
  end

  return M
end
