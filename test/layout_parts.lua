-- test/layout_parts.lua
-- The page layout check, split by page across the unit files
-- test/unit/ui_layout_<part>_test.lua so the processes of a run, and of a
-- CI shard, share it (#1001): every page by every voice, source, ALT state
-- and flash on one started script, then each page record's own
-- layout_states with ALT up and down, each on a fresh script. A part file
-- registers its part's test with `require("layout_parts").register(h,
-- "<part>")`; ui_layout_test.lua checks that the part files together draw
-- every case exactly once, running them with the draws counted
-- (draw_case, draw_state). docs/notes/lua/ui/layout-and-renders.md
local M = {}

-- The parts, each a unit file's: `pages` by title, and for a page with
-- many layout states `states = {from, every}`, the states from, from +
-- every, ... (its grid cases go with from = 1). The layout states are the
-- weight (a fresh script each; at #1001 VOICE's 542 took about 54 s under
-- Lua 5.3, the other pages' 314 about 35 s, the grid cases about 1 s in
-- all; ui_layout_test.lua's counting test prints today's two counts), so
-- each file weighs well under the longest other unit file
M.PARTS = {
  { name = "pages_1", pages = { "MAIN", "SEQ", "FX", "LFO", "MOD" } },
  { name = "pages_2", pages = { "BUFFER", "SCENES", "SETUP", "IO" } },
  { name = "voice_1", pages = { "VOICE" }, states = { from = 1, every = 3 } },
  { name = "voice_2", pages = { "VOICE" }, states = { from = 2, every = 3 } },
  { name = "voice_3", pages = { "VOICE" }, states = { from = 3, every = 3 } },
}

-- The sources every page is drawn with (v<i>_source options)
M.SOURCES = { { name = "synth", option = 1 }, { name = "buf 1", option = 2 }, { name = "input", option = 10 } }
M.FLASHES = { "no flash", "header flash", "hints flash" }
M.ALTS = { false, true }

function M.part(name)
  for _, part in ipairs(M.PARTS) do
    if part.name == name then return part end
  end
  error("no layout part named " .. tostring(name))
end

-- The PAGE_TITLES indexes of `titles`
function M.page_indexes(h, titles)
  local indexes = {}
  for _, title in ipairs(titles) do
    for index, page_title in ipairs(h.PAGE_TITLES) do
      if page_title == title then indexes[#indexes + 1] = index end
    end
    assert(indexes[#indexes] and h.PAGE_TITLES[indexes[#indexes]] == title, "no page named " .. tostring(title))
  end
  return indexes
end

-- Start the flash `kind` names (FLASHES): a header flash long enough to
-- need cutting, the longest hints flash a page raises
function M.start_layout_flash(S, kind)
  S.lib.ui_flash.cancel_all()
  if kind == "header flash" then
    header_flash("v1 grain density 12.5 Hz, a header flash long enough to be cut")
  elseif kind == "hints flash" then
    S.lib.ui_flash.start("hints", "K3 again: overwrite S16")  -- the longest planned
  end
end

function M.started_script(h)
  local context = h.load_strata(); h.finish_startup(context)
  return context
end

-- One grid case: `page` shown with `flash` started, drawn and checked (the
-- voice, source and ALT state set by check_grid)
function M.draw_case(h, context, S, case)
  h.show_page(case.page)
  M.start_layout_flash(S, case.flash)
  redraw()
  h.assert_screen_layout(context, string.format("%s, voice %d, %s%s, %s", h.PAGE_TITLES[case.page], case.voice,
    case.source.name, case.alt and ", ALT" or "", case.flash))
end

-- Every page of `pages` (PAGE_TITLES indexes) by every voice, source, ALT
-- state and flash, on one started script. A part that starts after MAIN
-- first sets every voice's source to the last one, as the earlier pages'
-- loops leave them when one test draws every page
function M.check_grid(h, pages)
  local context = M.started_script(h)
  local S = h.local_value("S")
  local _, set_selected = h.find_upvalue("selected_voice")
  local voices = h.local_value("voices")
  if pages[1] > 1 then
    for voice_idx = 1, #voices do params:set("v" .. voice_idx .. "_source", M.SOURCES[#M.SOURCES].option) end
  end
  for _, page in ipairs(pages) do
    for voice_idx = 1, #voices do
      set_selected(voice_idx)
      for _, source in ipairs(M.SOURCES) do
        params:set("v" .. voice_idx .. "_source", source.option)
        for _, alt in ipairs(M.ALTS) do
          key(1, alt and 1 or 0)
          for _, flash in ipairs(M.FLASHES) do
            M.draw_case(h, context, S, { page = page, voice = voice_idx, source = source, alt = alt, flash = flash })
          end
        end
      end
    end
  end
  key(1, 0)
  S.lib.ui_flash.cancel_all()
end

-- One layout state: `entry`'s (its page index and name) state
-- `state_index` on a fresh script from `load()`, with ALT up or down
function M.draw_state(h, load, entry, state_index, alt)
  local context = load()
  h.show_page(entry.index)
  local state = h.local_value("S").registry.pages[entry.index].layout_states[state_index]
  h.assert_true(type(state.setup) == "function", entry.name .. " layout state " .. state_index .. " has a setup")
  state.setup(context)
  key(1, alt and 1 or 0)
  redraw()
  h.assert_screen_layout(context, string.format("%s state %s%s", entry.name,
    tostring(state.name or state_index), alt and " with ALT" or ""))
end

-- Draw the layout_states of the page records `pages` (indexes), each on a
-- fresh script from `load()` (which returns its context), with ALT up and
-- down, and check the layout; with `pick` ({from, every}) only the states
-- from, from + every, ... Returns the number of states drawn
function M.check_layout_states(h, load, pages, pick)
  load()
  local entries = {}
  for _, index in ipairs(pages) do
    local record = h.local_value("S").registry.pages[index]
    entries[#entries + 1] = { index = index, name = record.name, count = #(record.layout_states or {}) }
  end
  local drawn = 0
  for _, entry in ipairs(entries) do
    for state_index = 1, entry.count do
      if not pick or (state_index - pick.from) % pick.every == 0 and state_index >= pick.from then
        for _, alt in ipairs(M.ALTS) do M.draw_state(h, load, entry, state_index, alt) end
        drawn = drawn + 1
      end
    end
  end
  return drawn
end

-- A part's check: its pages' grid cases (but a later states part's), then
-- its layout states
function M.run_part(h, part)
  local pages = M.page_indexes(h, part.pages)
  if not part.states or part.states.from == 1 then M.check_grid(h, pages) end
  M.check_layout_states(h, function() return M.started_script(h) end, pages, part.states)
end

-- Register part `name`'s test (a ui_layout_<name>_test.lua file's one)
function M.register(h, name)
  local part = M.part(name)
  local pages, name_text = table.concat(part.pages, ", "), nil
  local states = part.states and string.format("layout states %d, %d, ...", part.states.from,
    part.states.from + part.states.every) or "each layout state"
  if part.states and part.states.from > 1 then
    name_text = pages .. "'s " .. states .. " with ALT up and down (#1001)"
  else
    name_text = pages .. " lay out with every voice, source, ALT state and flash, and "
      .. states .. " with ALT up and down (#1001)"
  end
  h.test(name_text, function() M.run_part(h, part) end)
end

return M
