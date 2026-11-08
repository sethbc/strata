-- lib/ui/keys.lua
-- Page input the screen pages share: the page each held key went down on
-- (S.key_press_page, read by key() in strata.lua), ALT
-- (S.alt_held) and the keys held as ALT presses (S.key_press_alt; the ALT
-- functions are in lib/ui/alt.lua), forgetting held keys (forget_held_keys,
-- global), and
-- ignore_page_input, select_voice_by and set_ui_page (which runs the page
-- records' leave and enter), fields of this module's table (S.lib.ui_keys).

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- Per key: the page it was pressed on, while it is held (nil when up).
  -- key() sends a release only to the page the key went down on.
  S.key_press_page = {}

  -- ALT: true while K1 is held (key() in strata.lua sets it through
  -- S.lib.ui_alt.set; lib/ui/alt.lua). Pages read it through their
  -- hints(alt_held)
  S.alt_held = false

  -- Per key: true while it is held as an ALT press (it went down with ALT
  -- held), nil otherwise. key() sends
  -- its release to alt_key_release, never key_release, even if K1 came up
  -- first
  S.key_press_alt = {}

  -- Forget every held key, ALT and the ALT presses: for the norns menu and the
  -- file selector, which take the keys while open, so releases never reach
  -- key()
  function forget_held_keys()
    for n in pairs(S.key_press_page) do
      S.key_press_page[n] = nil
    end
    for n in pairs(S.key_press_alt) do
      S.key_press_alt[n] = nil
    end
    S.alt_held = false
  end

  local function ignore_page_input() end
  M.ignore_page_input = ignore_page_input

  -- E2 on MAIN and BUFFER: step the shared selected voice (an omni MIDI
  -- pitchbend moves with it)
  local function select_voice_by(d)
    local previous_voice = S.selected_voice
    S.selected_voice = util.clamp(S.selected_voice + d, 1, NUM_VOICES)
    if S.selected_voice ~= previous_voice then midi_bend_follow_selection(previous_voice) end
    update_voice_list()
  end
  M.select_voice_by = select_voice_by

  -- Show another page (draw_frame redraws the LFO page on every frame). On a
  -- change only, the old page's record gets leave() and the new one's
  -- enter(), when they have them, and the arc's carried ticks are forgotten
  local function set_ui_page(page)
    if page == S.ui_page then return end
    local old_record = S.registry.pages[S.ui_page]
    if old_record and old_record.leave then old_record.leave() end
    forget_arc_ticks()
    S.ui_page = page
    local new_record = S.registry.pages[page]
    if new_record and new_record.enter then new_record.enter() end
  end
  M.set_ui_page = set_ui_page

  return M
end
