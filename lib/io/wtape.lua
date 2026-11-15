-- lib/io/wtape.lua
-- W/ tape's transport from IO (3.6 design §6.3, S.lib.io_wtape): six action
-- rows, each sending one command over the ii bus and showing what it last
-- sent (Strata cannot read W/'s state). No params and no target. Command
-- names are crow's descriptor's (docs/design/3.6-facts/crow-ii.md §2, W/).
-- While the bus is not Strata's (or the ii module is absent) a row sends
-- nothing and flashes, and the section's status is [--].
-- Unverified on the device until the 4.0 hardware check.

return function(S)
  local M = {}

  local WTAPE = {
    device = "wtape",
    section = "wtape",
    unled_text = "ii bus is not strata's",
    unled_status = "[--]",
    unsent = "-",
    -- one per row: a toggle sends command with 1 then 0, a push sends it bare
    rows = {
      {label = "record", command = "record", toggle = true},
      {label = "play", command = "play", toggle = true},
      {label = "reverse", command = "reverse"},
      {label = "loop start", command = "loop_start"},
      {label = "loop end", command = "loop_end"},
      {label = "loop", command = "loop_active", toggle = true},
    },
  }
  M.WTAPE = WTAPE

  -- shown[label] is the text of what the row last sent; level[label] the
  -- value a toggle sent last
  local shown, level = {}, {}

  -- set only by a layout state, so the page renders show the leading looks
  -- where no ii module (or a bus that does not lead) is present: the row
  -- then records what it would send and sends nothing
  local layout_leading = false

  local function leading()
    if layout_leading then return true end
    local ii = S.lib.io_ii
    return ii ~= nil and ii.leads() and true or false
  end

  local function send(...)
    local ii = S.lib.io_ii
    if ii and not layout_leading then ii.send(...) end
  end

  local function press(spec)
    if not leading() then
      S.lib.ui_flash.start("hints", WTAPE.unled_text, nil, S.constants.UI_PAGES.index.IO)
      return
    end
    if spec.toggle then
      local value = level[spec.label] == 1 and 0 or 1
      send(WTAPE.device, spec.command, value)
      level[spec.label] = value
      shown[spec.label] = value == 1 and "on" or "off"
    else
      send(WTAPE.device, spec.command)
      shown[spec.label] = "sent"
    end
    request_redraw()
  end

  S.register_io_section({
    name = WTAPE.section,
    title = "w/ tape",
    rows = function()
      local rows = {}
      for _, spec in ipairs(WTAPE.rows) do
        rows[#rows + 1] = {label = spec.label, kind = "action", hint = spec.label,
          run = function() press(spec) end,
          text = function() return shown[spec.label] or WTAPE.unsent end}
      end
      return rows
    end,
    status = function()
      if not leading() then return WTAPE.unled_status end
      return nil
    end,
    layout_states = {
      {name = "the bus not leading", setup = function() end},
      {name = "leading before any command", setup = function() layout_leading = true end},
      {name = "leading after commands", setup = function()
        layout_leading = true
        for _, spec in ipairs(WTAPE.rows) do press(spec) end
      end},
    },
  })

  return M
end
