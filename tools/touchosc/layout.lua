-- tools/touchosc/layout.lua
-- The description of Strata's two TouchOSC layouts (3.6 design §10.3), read by
-- tools/touchosc/generate.py (which writes extras/touchosc/*.tosc) and by
-- test/unit/io_osc_test.lua, which checks every address in it.
-- A table of data only: params (ids sent as /param/<id>, in real units; they
-- are also lib/io/osc.lua's starting feedback watch list), addresses (Strata's
-- own, sent by the layouts, with the voice number 1 to 7), and the two
-- layouts: {name, width, height, pages}. A page is {title, columns, rows,
-- controls}; a control is {kind, label, param or address, [argument], [min,
-- max], x, y, w, h} in cells of a columns by rows grid, which the generator
-- scales to the screen. kind is fader, toggle or button; a toggle's argument
-- "value" sends its 0 or 1, a button's number is sent as an integer.

local NUM_VOICES, NUM_MACROS, NUM_SCENES = 7, 16, 16

local params, addresses = {}, {"/strata/scene", "/strata/patterns"}
for m = 1, NUM_MACROS do params[#params + 1] = "macro_" .. m end
for v = 1, NUM_VOICES do
  params[#params + 1] = "v" .. v .. "_mute"
  params[#params + 1] = "v" .. v .. "_amp"
  addresses[#addresses + 1] = "/strata/voice/" .. v .. "/run"
end

-- The macros: a fader each, in rows of `columns`
local function macro_page(columns)
  local controls = {}
  for m = 1, NUM_MACROS do
    local column, row = (m - 1) % columns, math.floor((m - 1) / columns)
    controls[#controls + 1] = {kind = "fader", label = "macro " .. m, param = "macro_" .. m, min = 0, max = 1,
      x = column, y = row * 4, w = 1, h = 4}
  end
  return {title = "macros", columns = columns, rows = math.ceil(NUM_MACROS / columns) * 4, controls = controls}
end

-- The voices: per voice a run toggle, a mute toggle and a level fader
local function voice_page(columns)
  local controls = {}
  for v = 1, NUM_VOICES do
    local column, row = (v - 1) % columns, math.floor((v - 1) / columns) * 6
    controls[#controls + 1] = {kind = "toggle", label = "run " .. v, address = "/strata/voice/" .. v .. "/run",
      argument = "value", x = column, y = row, w = 1, h = 1}
    controls[#controls + 1] = {kind = "toggle", label = "mute " .. v, param = "v" .. v .. "_mute", min = 0, max = 1,
      x = column, y = row + 1, w = 1, h = 1}
    controls[#controls + 1] = {kind = "fader", label = "level " .. v, param = "v" .. v .. "_amp", min = 0, max = 1,
      x = column, y = row + 2, w = 1, h = 4}
  end
  return {title = "voices", columns = columns, rows = math.ceil(NUM_VOICES / columns) * 6, controls = controls}
end

-- The scenes: a button each, then the patterns' toggle across the bottom
local function scene_page(columns)
  local controls = {}
  for n = 1, NUM_SCENES do
    local column, row = (n - 1) % columns, math.floor((n - 1) / columns)
    controls[#controls + 1] = {kind = "button", label = "scene " .. n, address = "/strata/scene", argument = n,
      x = column, y = row, w = 1, h = 1}
  end
  local rows = math.ceil(NUM_SCENES / columns)
  controls[#controls + 1] = {kind = "toggle", label = "patterns", address = "/strata/patterns",
    argument = "value", x = 0, y = rows, w = columns, h = 1}
  return {title = "scenes", columns = columns, rows = rows + 1, controls = controls}
end

return {
  params = params,
  addresses = addresses,
  tablet = {name = "strata-tablet", width = 1280, height = 800,
    pages = {macro_page(8), voice_page(7), scene_page(8)}},
  phone = {name = "strata-phone", width = 800, height = 360,
    pages = {macro_page(4), voice_page(4), scene_page(4)}},
}
