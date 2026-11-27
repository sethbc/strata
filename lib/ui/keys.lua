-- lib/ui/keys.lua
-- Page input the screen pages share: the page each held key went down on
-- and when (S.key_press_page, S.key_press_at, set by key() in strata.lua),
-- ALT (S.alt_held) and the keys held as ALT presses (S.key_press_alt; the
-- ALT functions are in lib/ui/alt.lua), forgetting held keys
-- (forget_held_keys, global), and held_seconds, forget_presses,
-- select_voice_by and set_ui_page (which runs the page records' leave and
-- enter; both apply the pending type choices, 3.8), fields of this
-- module's table (S.lib.ui_keys).

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- Per key: the page it was pressed on, while it is held (nil when up).
  -- key() sends a release only to the page the key went down on.
  S.key_press_page = {}

  -- Per key: when it went down (util.time()), set and cleared with
  -- S.key_press_page (nil when up or forgotten). Read through held_seconds:
  -- the one press time a release decides by (#866)
  S.key_press_at = {}

  -- ALT: true while K1 is held (key() in strata.lua sets it through
  -- S.lib.ui_alt.set; lib/ui/alt.lua). Pages read it through their
  -- hints(alt_held)
  S.alt_held = false

  -- Per key: true while it is held as an ALT press (it went down with ALT
  -- held), nil otherwise. key() sends
  -- its release to alt_key_release, never key_release, even if K1 came up
  -- first
  S.key_press_alt = {}

  -- How long key n (2, 3) has been held on the page showing, in seconds, or
  -- nil: up, or its press forgotten (a page change, the norns menu, the
  -- file selector, a name entry, a modal owner pushed over the page). A
  -- release handler key() runs still reads it
  function M.held_seconds(n)
    local at = S.key_press_at[n]
    if at == nil or S.key_press_page[n] ~= S.ui_page then return nil end
    return util.time() - at
  end

  -- Forget the page's held keys (their press pages, times and ALT marks);
  -- ALT itself stays (K1 may still be down). A page change and a modal
  -- push (S.lib.ui_modal.push) forget them so
  local function forget_presses()
    S.displayed_hint_token = nil  -- another page, modal or the menu takes the screen
    for n in pairs(S.key_press_page) do S.key_press_page[n] = nil end
    for n in pairs(S.key_press_at) do S.key_press_at[n] = nil end
    for n in pairs(S.key_press_alt) do S.key_press_alt[n] = nil end
  end
  M.forget_presses = forget_presses

  -- Forget every held key, ALT and the ALT presses, a modal owner's presses
  -- too: for the norns menu, the file selector and a name entry, which take
  -- the keys while open, so releases never reach key()
  function forget_held_keys()
    forget_presses()
    S.lib.ui_modal.forget_presses()
    local was_held = S.alt_held
    S.alt_held = false
    if was_held then S.lib.ui_alt.run_release_hooks() end
  end

  -- Step the shared selected voice (an omni MIDI pitchbend moves with it):
  -- MAIN's E2, SEQ's ALT+E2 and the arc's SEQ ring 4 (BUFFER's E2 picks a
  -- buffer)
  -- 3.8 (ruling 63): every voice's pending type choice (VOICE's type row,
  -- S.lib.types) applied at once
  local function flush_pending_types()
    for voice_idx = 1, NUM_VOICES do S.lib.types.flush(voice_idx) end
  end

  -- A voice pick applies the pending type choices first (ruling 63)
  local function select_voice_by(d)
    local previous_voice = S.selected_voice
    S.selected_voice = util.clamp(S.selected_voice + d, 1, NUM_VOICES)
    if S.selected_voice ~= previous_voice then
      flush_pending_types()
      midi_bend_follow_selection(previous_voice)
    end
    update_voice_list()
  end
  M.select_voice_by = select_voice_by

  -- Show another page (draw_frame redraws the LFO page on every frame). On a
  -- change only, the old page's record gets leave() and the new one's
  -- enter(), when they have them, and the arc's carried ticks are forgotten.
  -- Leaving VOICE applies the pending type choices first (ruling 63)
  local function set_ui_page(page)
    if page == S.ui_page then return end
    if S.ui_page == S.constants.UI_PAGES.index.VOICE then flush_pending_types() end
    local old_record = S.registry.pages[S.ui_page]
    if old_record and old_record.leave then old_record.leave() end
    forget_arc_ticks()
    -- A key held across the change must not release on the page it comes
    -- back to; ALT itself stays (K1 is still down)
    forget_presses()
    S.ui_page = page
    local new_record = S.registry.pages[page]
    if new_record and new_record.enter then new_record.enter() end
  end
  M.set_ui_page = set_ui_page

  -- An ALT press is a held key: it has the page it went down on; a held
  -- key has its press time, and only a held key has one; a held key's
  -- page is the page shown (set_ui_page forgets the presses, #234, #989)
  S.register_invariant("key presses", function()
    for n in pairs(S.key_press_alt) do
      if S.key_press_page[n] == nil then return "key " .. tostring(n) .. " is an ALT press with no press page" end
    end
    for n in pairs(S.key_press_page) do
      if S.key_press_at[n] == nil then return "key " .. tostring(n) .. " is held with no press time" end
      if S.key_press_page[n] ~= S.ui_page then
        return "key " .. tostring(n) .. " is held on page " .. tostring(S.key_press_page[n])
          .. ", not the page shown, " .. tostring(S.ui_page)
      end
    end
    for n in pairs(S.key_press_at) do
      if S.key_press_page[n] == nil then return "key " .. tostring(n) .. " has a press time with no press page" end
    end
  end)

  return M
end
