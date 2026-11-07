-- lib/ui/keys.lua
-- Page input the screen pages share: the page each held key went down on
-- (S.key_press_page, read by key() in strata.lua and the BUFFER page),
-- forgetting held keys (forget_held_keys, global), and ignore_page_input,
-- select_voice_by and set_ui_page, fields of this module's table
-- (S.lib.ui_keys).

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- Per key: the page it was pressed on, while it is held (nil when up).
  -- key() sends a release only to the page the key went down on.
  S.key_press_page = {}

  -- Forget every held key (and the K2 save): for the norns menu and the file
  -- selector, which take the keys while open, so releases never reach key()
  function forget_held_keys()
    for n in pairs(S.key_press_page) do
      S.key_press_page[n] = nil
    end
    S.buffer_saved_during_k2 = false
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

  -- Show another page (draw_frame redraws the LFO page on every frame)
  local function set_ui_page(page)
    S.ui_page = page
  end
  M.set_ui_page = set_ui_page

  return M
end
