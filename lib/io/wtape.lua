-- lib/io/wtape.lua
-- W/ tape's transport from IO (3.6 design §6.3, S.lib.io_wtape): six action
-- rows, each sending one command over the ii bus and showing what it last
-- sent (Strata cannot read W/'s state). No params and no target. Command
-- names are crow's descriptor's (docs/design/3.6-facts/crow-ii.md §2, W/).
-- While the bus is not Strata's (or the ii module is absent) a row sends
-- nothing and flashes, and the section's status is [--]. A row changes what
-- it shows only when the bus queued its line (send returned true).
-- Unverified on the device until the 4.0 hardware check.

return function(S)
  local M = {}

  local WTAPE = {
    device = "wtape",
    section = "wtape",
    unled_text = "ii bus is not strata's",
    full_text = "ii queue full",
    unled_status = "[--]",
    unsent = "-",
    bus_section = "ii",
    bus_key = "ii_bus",
    bus_value = "strata",
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

  local function leading()
    local ii = S.lib.io_ii
    return ii ~= nil and ii.leads() and true or false
  end

  local function flash(text)
    S.lib.ui_flash.start("hints", text, nil, S.constants.UI_PAGES.index.IO)
  end

  local function press(spec)
    if not leading() then
      flash(WTAPE.unled_text)
      return
    end
    local value = spec.toggle and (level[spec.label] == 1 and 0 or 1) or nil
    local queued
    if spec.toggle then
      queued = S.lib.io_ii.send(WTAPE.device, spec.command, value)
    else
      queued = S.lib.io_ii.send(WTAPE.device, spec.command)
    end
    if not queued then
      flash(WTAPE.full_text)
      return
    end
    if spec.toggle then
      level[spec.label] = value
      shown[spec.label] = value == 1 and "on" or "off"
    else
      shown[spec.label] = "sent"
    end
    request_redraw()
  end

  -- The layout states below act as a player does, through the IO page's
  -- keys: on IO's page, S.lib.pages_io.go_to_row puts the cursor on the
  -- row (a rig row by its key, an action row by its id, its label; its E2
  -- turn ends the pinned view, so the page acts on the row)
  local function move_to(section, match)
    S.lib.ui_keys.set_ui_page(S.constants.UI_PAGES.index.IO)
    S.lib.pages_io.go_to_row("wtape", section, match)
  end

  local function has_row(section, key)
    for _, row in ipairs(S.lib.pages_io.rows()) do
      if row.section == section and row.key == key then return true end
    end
    return false
  end

  -- With the bus reachable (an ii module and the ii section's bus row) the
  -- setup plugs a crow and turns that row to Strata through the page; it
  -- raises when the bus still does not lead. Where it is not reachable the
  -- state stays on the not-leading look
  local function lead_the_bus(context)
    if not S.lib.io_ii or not has_row(WTAPE.bus_section, WTAPE.bus_key) then return false end
    context.crow.plug()
    move_to(WTAPE.bus_section, {key = WTAPE.bus_key})
    -- one detent at a time toward the value, by the spec's own order, and
    -- no more turns than the spec has values
    local choices = S.lib.io_rig.RIG.specs[WTAPE.bus_key].values
    local function place(value)
      for index, choice in ipairs(choices) do
        if choice == value then return index end
      end
    end
    for _ = 1, #choices do
      local from, goal = place(S.lib.io_rig.get(WTAPE.bus_key)), place(WTAPE.bus_value)
      if not goal or from == goal then break end
      enc(3, (from or 1) < goal and 1 or -1)
    end
    if not leading() then error("wtape layout: the bus does not lead after turning " .. WTAPE.bus_key, 2) end
    return true
  end

  local function press_rows_with_k3()
    for _, spec in ipairs(WTAPE.rows) do
      move_to(WTAPE.section, {id = spec.label})
      key(3, 1); key(3, 0)
    end
  end

  S.register_io_section({
    name = WTAPE.section,
    title = "w/ tape",
    rows = function()
      local rows = {}
      for _, spec in ipairs(WTAPE.rows) do
        rows[#rows + 1] = {label = spec.label, id = spec.label, kind = "action", hint = spec.label,
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
      {name = "leading before any command", setup = function(context)
        lead_the_bus(context)
        S.lib.pages_io.show_section(WTAPE.section)
      end},
      {name = "leading after commands", setup = function(context)
        if lead_the_bus(context) then press_rows_with_k3() end
        S.lib.pages_io.show_section(WTAPE.section)
      end},
    },
  })

  return M
end
