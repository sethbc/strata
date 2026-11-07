-- test/unit/pages_seq_test.lua
-- The SEQ page (lib/pages/seq.lua); its rings are in arc_pages_test.lua
-- Run alone: lua test/run.lua pages_seq

return function(h)
local test, assert_equal = h.test, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, hint_text = h.show_page, h.hint_text

test("the SEQ stub page shows E1:page and takes no input", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SEQ")
  assert_equal(hint_text(context), "E1:page", "SEQ hint row")
  local before = {}
  for _, param_id in ipairs({ "master_density", "v1_grain_size", "tempo", "midi_device" }) do
    before[param_id] = params:get(param_id)
  end
  for n = 2, 3 do enc(n, 3); enc(n, -1); h.tap(n) end
  for param_id, value in pairs(before) do
    assert_equal(params:get(param_id), value, "SEQ leaves " .. param_id)
  end
  assert_equal(local_value("ui_page"), S.constants.UI_PAGES.index.SEQ, "still on SEQ")
end)

end
