-- lib/ui/alt.lua
-- ALT: K1 held. norns delivers K1 to a script only once it has been held for
-- KEY1_HOLD_TIME (0.25 s); a shorter press opens the norns menu. key() in
-- strata.lua sets ALT through set(held) and sends ALT+K2/ALT+K3 to
-- alt_action (global), which runs the page record's alt_key. Fields of this
-- module's table (S.lib.ui_alt): set, run_release_hooks, and the shared
-- ALT+K2 of the randomizing pages: k2_up, k2_held, k2_hint, and
-- join, the hint row's parts joined.
-- S.alt_held and S.key_press_alt live in lib/ui/keys.lua, whose
-- forget_held_keys clears them.

return function(S)
  local M = {}
  local NUM_UI_PAGES = S.constants.NUM_UI_PAGES

  -- Hold or clear ALT. The hint row shows the ALT layer while it is held
  function M.set(held)
    local was_held = S.alt_held
    S.alt_held = held == true
    if was_held and not S.alt_held then M.run_release_hooks() end
    request_redraw()
  end

  -- The registered ALT-release hooks (S.registry.alt_release), run when ALT
  -- goes from held to not held: from set(false) and forget_held_keys
  function M.run_release_hooks()
    for _, hook in ipairs(S.registry.alt_release) do hook() end
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

  -- The shared ALT+K2 of every randomizing page (#557), acting on release:
  -- a quick press (released within ALT_HOLD_SECONDS) undoes the randomize
  -- held there or randomizes the page's section; a longer one runs the
  -- record's alt_hold, or cancels on a page without one. A page's
  -- alt_key_release(2) calls k2_up(record); its ALT+K2 press calls nothing
  -- (#959). The
  -- record's randomize_section() returns the spec of the section under its
  -- cursor (S.lib.mutation.randomize), with "locked" second for a locked
  -- voice (nothing is randomized, but an undo held there still runs), or
  -- nil. The press time is the dispatcher's (S.key_press_at, read through
  -- S.lib.ui_keys.held_seconds; #866): this module keeps no mark of its
  -- own, so a page change, the norns menu, the file selector and a modal
  -- push, which forget the press, leave nothing to go stale
  local ALT_HOLD_SECONDS = S.constants.ALT_HOLD_SECONDS

  -- Whether ALT+K2 is down on the page showing: a page change, the norns
  -- menu, the file selector and a modal push forget it (S.key_press_page),
  -- so a press carried away and back holds nothing
  function M.k2_held()
    return S.lib.ui_keys.held_seconds(2) ~= nil and S.key_press_alt[2] == true
  end

  local function held_long()
    return M.k2_held() and S.lib.ui_keys.held_seconds(2) >= ALT_HOLD_SECONDS
  end

  -- What a quick press on the record does: "undo" while the undo held is its
  -- section's, else nil where it draws nothing (no spec, or a draws spec
  -- with none: VOICE's type and preset rows, a Sub voice's mix; #823),
  -- else "locked" for a locked voice, else "rand"; with the spec
  local function quick_action(record)
    local spec, reason
    if record.randomize_section then spec, reason = record.randomize_section() end
    if spec and S.lib.mutation.undo_for(spec.page, spec.section, spec.voice) then return "undo", spec end
    if spec == nil or (spec.pattern == nil and #spec.draws == 0) then return nil end
    if reason == "locked" then return "locked" end
    return "rand", spec
  end

  -- ALT+K2 released on the record's page: held ALT_HOLD_SECONDS, its
  -- alt_hold; else the quick action (undo, randomize, nothing when locked).
  -- held is how long the key was down: by default the page's ALT+K2
  -- (k2_held, read in the release key() runs); a modal owner passes its own
  -- (S.lib.ui_modal.held_seconds, SEQ's step editor). No held press:
  -- nothing
  function M.k2_up(record, held)
    if held == nil and M.k2_held() then held = S.lib.ui_keys.held_seconds(2) end
    if held == nil then return end
    if held >= ALT_HOLD_SECONDS then
      if record.alt_hold then record.alt_hold() end
    else
      local action, spec = quick_action(record)
      if action == "undo" then
        S.lib.mutation.undo()
      elseif action == "rand" and spec then
        S.lib.mutation.randomize(spec)
      end
    end
    request_redraw()
  end

  -- The hint for ALT+K2 on the record's page, what letting go will do:
  -- once it is held ALT_HOLD_SECONDS, "K2:reset" on a page with alt_hold
  -- (or "K2:" and its alt_hold_hint, a string or a function returning one,
  -- 3.4: SEQ's edit, MOD's clear) and "K2:cancel" on one without (its
  -- release does nothing); before, the quick action's, or nil where a
  -- quick press does nothing (the page leaves K2 out of its hint, as MOD's
  -- k2_part does). The record animates while k2_held(), so the frame clock
  -- draws the change at the hold time
  function M.k2_hint(record)
    if held_long() then
      if not record.alt_hold then return "K2:cancel" end
      local hint = record.alt_hold_hint
      if type(hint) == "function" then hint = hint() end
      return "K2:" .. (hint or "reset")
    end
    local action = quick_action(record)
    return action and "K2:" .. action or nil
  end

  -- A hint row from its parts, joined by a space, a nil or empty part left
  -- out ("" for none): every page joins k2_hint's part, which may be nil,
  -- through it, so a hint never concatenates a nil
  function M.join(...)
    local parts = {}
    for index = 1, select("#", ...) do
      local part = select(index, ...)
      if part ~= nil and part ~= "" then parts[#parts + 1] = part end
    end
    return table.concat(parts, " ")
  end

  return M
end
