-- test/unit/ui_layout_voice_2_test.lua
-- One part of the page layout check (#1001): its pages and layout states
-- are test/layout_parts.lua's PARTS entry "voice_2", and ui_layout_test.lua
-- checks that the parts together draw every case once.
-- Run alone: lua test/run.lua ui_layout_voice_2

return function(h)
require("layout_parts").register(h, "voice_2")
end
