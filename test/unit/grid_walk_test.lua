-- test/unit/grid_walk_test.lua
-- 3.9's package 3b (its design's section 6, the grid walk): seeded walks
-- of grid keys on the four layouts (the 256, the 128h, the 128v, the 64),
-- one h.walk a layout. Its ops: a key down (any key the grid shows: a
-- pane key on whatever page its pane shows, a strip key; now and then a
-- key already down pressed again, a release that never came), a held key
-- up, the clock advanced 0.05 to 0.6 s, a pane's page (and on the 64 its
-- half) changed, the 64's chooser opened and closed, a voice's pattern
-- replaced (S.lib.sequencer.replace_pattern), the grid unplugged and
-- plugged, a rotation (S.lib.grid_core.set_rotation). A small model of the
-- grid core keeps, per key the core holds, what its release should do:
-- toggle its step (a held step whose gesture still stands), nothing (a
-- level key, a consumed key: one that opened the step editor or took a
-- level, a key whose gesture ended) or end a hold (the 64's NV, fill, a
-- positions HD key), with the patterns it expects and the step editor it
-- expects open. After every op `after` compares the model with
-- S.patterns, S.grid_held and the open step editor (and the chooser on
-- the 64), and every invariant runs; at the end every key goes up, and
-- then no hold clock lives, no positions record holds a key, no scan is
-- held and no step editor is open. The model reads the core's rules from
-- docs/notes/lua/grid-core.md (Machines, `grid keys`, and the step-level
-- gesture), not from its code; what it observes is only when a pattern
-- was replaced (every whole-pattern change goes through replace_pattern:
-- a scene recall, CL and RN, a paste), which it wraps and passes on.
-- Run alone: lua test/run.lua grid_walk

return function(h)
local local_value = h.local_value

-- The walk's numbers: the seeds, the steps, the clock's steps (seconds),
-- the weights of the ops, the window (s) two timed events of one clock op
-- must be apart for the model to order them (the stub's tick is 1 ms;
-- closer than this the model takes the order the code shows), the margin
-- a clock op's end keeps from a deadline the model predicts, the shares
-- of the presses and page changes the walk favors, the port, positions'
-- HD key, the buffer voices
local GRID_WALK = {
  seeds = { 2026, 15838, 95028, 11 },
  steps = 400,
  clock_min = 0.05, clock_max = 0.6,
  tie_window = 0.003, end_margin = 0.004,
  strip_share = 4,       -- one press in strip_share is a strip key
  patterns_share = 3,    -- one page change in patterns_share shows patterns, one positions
  favored_share = 3,     -- one press in favored_share takes a key whose release ends a hold
  fill_key = 2,          -- the upper strip's FL
  repress_share = 12,    -- one press in repress_share presses a key already down
  port = 1,
  hold_mark = 7,         -- positions side 2: x 7 is the voice's HD key
  buffer_voices = 3,     -- voices 1-3 read buffer slots 1-3 (positions keys act)
  finish_seconds = 1,    -- after the last key up: every retired clock wakes, every stale record ends
}
local WALK = GRID_WALK

-- The arrangements a walk starts on, by layout (h.grid_pane's names)
local LAYOUT_START = { ["256"] = "256 top", ["128h"] = "128h", ["128v"] = "128v", ["64"] = "64 left" }

local function key_name(px, py) return px .. "," .. py end

-- The layout a size is (lib/grid/core.lua's grid_layout, by exact size)
local function layout_name(cols, rows)
  if cols == 16 and rows == 16 then return "256" end
  if cols == 16 and rows == 8 then return "128h" end
  if cols == 8 and rows == 16 then return "128v" end
  if cols == 8 and rows == 8 then return "64" end
  return nil
end

local Walk = {}

function Walk.device(state) return state.context.grid.vports[WALK.port].device end

function Walk.layout(state)
  local device = Walk.device(state)
  if device == nil then return nil, nil end
  local name = layout_name(device.cols, device.rows)
  return name and state.S.registry.grid_layouts[name], name
end

function Walk.half(state, pane) return state.core.half(WALK.port, pane) end

-- What a physical key is now: {pane, x, y} (pane coordinates, y 8 the
-- strip, `strip` its key's name), or nil, found through the layout's own
-- spec (S.lib.grid_pane.physical), never a physical coordinate of ours
function Walk.locate(state, px, py)
  local layout, name = Walk.layout(state)
  if layout == nil then return nil end
  local strip_line = state.S.constants.NUM_VOICES + 1
  for pane = 1, layout.panes do
    local half = Walk.half(state, pane)
    for y = 1, strip_line do
      for x = 1, state.S.lib.grid_pane.LINE_KEYS do
        local kx, ky = state.S.lib.grid_pane.physical(layout, pane, x, y, half)
        if kx == px and ky == py then
          local strip
          if y == strip_line then
            local spec_keys = (name == "64" and "small") or (pane == 2 and "lower") or "upper"
            strip = state.S.lib.grid_pane.STRIPS[spec_keys][x]
          end
          return { pane = pane, x = x, y = y, strip = strip }
        end
      end
    end
  end
  return nil
end

-- A key the grid shows, picked at random: a strip key one time in
-- strip_share, else a pane key; physical coordinates
function Walk.pick_key(state, random)
  local layout = Walk.layout(state)
  if layout == nil then return nil end
  local strip_line = state.S.constants.NUM_VOICES + 1
  for _ = 1, 20 do
    local pane = random(layout.panes)
    local y = random(WALK.strip_share) == 1 and strip_line or random(strip_line - 1)
    local x = random(state.S.lib.grid_pane.LINE_KEYS)
    -- one press in favored_share takes the key whose release ends a hold:
    -- a positions HD key of a buffer voice, the fill key (strip key 2)
    if random(WALK.favored_share) == 1 then
      if y == strip_line then
        x = WALK.fill_key
      elseif state.core.page(WALK.port, pane) == state.S.constants.GRID_PAGES.positions
          and state.core.side(WALK.port, pane) == 2 then
        x, y = WALK.hold_mark, random(WALK.buffer_voices)
      end
    end
    local px, py = state.S.lib.grid_pane.physical(layout, pane, x, y, Walk.half(state, pane))
    if px then return px, py end
  end
  return nil
end

-- The model ------------------------------------------------------------

-- An entry per key the core holds (by key name): {px, py, pane (a pane
-- key's; nil for a strip key), kind "step" | "level" | "nv" | "other",
-- voice, step, consumed, dropped, deadline (a held step's editor hold,
-- NV's chooser hold), order (the press's number), hd (positions HD's
-- voice), fill (the fill key)}
local Model = {}

function Model.new(S)
  local patterns = {}
  for voice = 1, S.constants.NUM_VOICES do
    patterns[voice] = {}
    for step = 1, S.constants.PATTERN_LENGTH do patterns[voice][step] = S.patterns[voice][step] end
  end
  return { entries = {}, patterns = patterns, editor = nil, chooser = false, order = 0 }
end

-- The step editor's key closes the editor when its gesture ends
function Model.drop(model, entry)
  if entry.kind == "step" or entry.kind == "level" then
    entry.dropped, entry.deadline = true, nil
  end
  if model.editor == entry then model.editor = nil end
end

-- A pane's keys end (a page, side or half change; the chooser opening):
-- their step gestures end and their holds stop (NV, a strip key, goes on)
function Model.end_pane(model, pane)
  for _, entry in pairs(model.entries) do
    if entry.pane == pane then Model.drop(model, entry) end
  end
end

-- The port is forgotten (unplug, plug, a rotation): nothing held
function Model.forget(model)
  model.entries, model.editor, model.chooser = {}, nil, false
end

-- The voice's pattern replaced: its step keys' gestures end, on every pane
function Model.replaced(model, voice)
  for _, entry in pairs(model.entries) do
    if entry.voice == voice and (entry.kind == "step" or entry.kind == "level") then Model.drop(model, entry) end
  end
end

-- The voice's held step on the port, other than `name`: a step entry
-- (not a level key) whose gesture stands
function Model.held_step(model, voice, name)
  for other, entry in pairs(model.entries) do
    if other ~= name and entry.kind == "step" and entry.voice == voice and not entry.dropped then return entry end
  end
  return nil
end

-- The ops' parts --------------------------------------------------------

-- Before an op: each pane's view, and which held keys wait for a hold
function Walk.before(state)
  local views, pending = {}, {}
  local layout = Walk.layout(state)
  for pane = 1, layout and layout.panes or 0 do views[pane] = state.core.view(WALK.port, pane) end
  for name, entry in pairs(state.model.entries) do
    pending[name] = state.core.hold_pending(WALK.port, entry.px, entry.py)
  end
  state.views, state.pending, state.replaces = views, pending, {}
end

-- After an op (Walk.after_op): a pane whose view changed ends its keys;
-- a replaced voice ends its step keys and its pattern is read again
function Walk.settle(state)
  local layout = Walk.layout(state)
  if layout then
    for pane = 1, layout.panes do
      if state.views[pane] ~= nil and state.views[pane] ~= state.core.view(WALK.port, pane) then
        for name, entry in pairs(state.model.entries) do
          if entry.pane == pane then
            if state.pending[name] then state.counts.hold_ended_by_page = state.counts.hold_ended_by_page + 1 end
            if state.core.hold_pending(WALK.port, entry.px, entry.py) then
              state.problems[#state.problems + 1] = "key " .. name .. ": its pane's view changed and its hold still waits"
            end
          end
        end
        Model.end_pane(state.model, pane)
      end
    end
  end
  for _, replace in ipairs(state.replaces) do Model.replaced(state.model, replace.voice) end
  Walk.read_replaced(state)
end

function Walk.read_replaced(state)
  for _, replace in ipairs(state.replaces) do
    for step = 1, state.S.constants.PATTERN_LENGTH do
      state.model.patterns[replace.voice][step] = state.S.patterns[replace.voice][step]
    end
  end
  state.replaces = {}
end

-- A press of physical key (px, py)
function Walk.press(state, px, py)
  local S, model, core = state.S, state.model, state.core
  local name = key_name(px, py)
  state.fingers[name] = { px = px, py = py }
  local device = Walk.device(state)
  if device == nil then return end
  -- a finger down since a rotation may be off the grid now: the core
  -- ignores a key outside the grid's size
  if px > device.cols or py > device.rows then
    state.context.grid.press(WALK.port, px, py, 1)
    return
  end
  local where = Walk.locate(state, px, py)
  local old = model.entries[name]
  if old then  -- a press with no release before it starts the key over
    Model.drop(model, old)
    model.entries[name] = nil
  end
  model.order = model.order + 1
  local entry = { px = px, py = py, kind = "other", order = model.order, pane = where and not where.strip and where.pane }
  local now = util.time()
  local _, layout_kind = Walk.layout(state)
  local hold = S.constants.GRID_HOLD
  if where and where.strip == "chooser" then
    entry.kind, entry.deadline = "nv", now + hold.chooser_seconds
  elseif where and where.strip == "fill" then
    entry.fill = true
  elseif where and not where.strip then
    local page, side = core.page(WALK.port, where.pane), core.side(WALK.port, where.pane)
    if layout_kind == "64" and model.chooser then
      entry.consumed = true  -- a chooser key: consumed, its release does nothing
    elseif page == S.constants.GRID_PAGES.patterns then
      local voice, step = where.y, where.x
      local width = layout_kind == "64" and 8 or 16
      local offset = layout_kind == "64" and (Walk.half(state, where.pane) - 1) * 8 or 0
      local held = Model.held_step(model, voice, name)
      entry.voice = voice
      if held then
        local level = math.max(1, math.floor((where.x - offset) * S.constants.MAX_STEP_LEVEL / width + 0.5))
        model.patterns[voice][held.step] = math.min(level, S.constants.MAX_STEP_LEVEL)
        held.consumed, held.deadline = true, nil
        entry.kind, entry.step, entry.consumed = "level", step, true
        state.counts.level_set = state.counts.level_set + 1
      else
        entry.kind, entry.step, entry.deadline = "step", step, now + hold.step_edit_seconds
      end
    elseif page == S.constants.GRID_PAGES.positions and side == 2 and where.x == WALK.hold_mark
        and voice_uses_buffer(where.y) then
      entry.hd = where.y
    end
  end
  model.entries[name] = entry
  state.context.grid.press(WALK.port, px, py, 1)
end

-- A release of a finger: what the model says its release does, then the
-- release itself and its checks
function Walk.release(state, name)
  local finger = state.fingers[name]
  state.fingers[name] = nil
  if Walk.device(state) == nil then return end  -- unplugged: the finger lifts, no event
  local S, model, core = state.S, state.model, state.core
  local entry = model.entries[name]
  local _, layout_kind = Walk.layout(state)
  if entry then
    if layout_kind == "64" and entry.pane and model.chooser then
      state.counts.release_under_chooser = state.counts.release_under_chooser + 1
    end
    if entry.kind == "step" and not entry.consumed and not entry.dropped then
      local pattern = model.patterns[entry.voice]
      pattern[entry.step] = pattern[entry.step] == 0 and S.constants.MAX_STEP_LEVEL or 0
      state.counts.step_toggled = state.counts.step_toggled + 1
    end
    if model.editor == entry then model.editor = nil end
    if entry.kind == "nv" then model.chooser = false end
    model.entries[name] = nil
  end
  state.context.grid.press(WALK.port, finger.px, finger.py, 0)
  if core.hold_pending(WALK.port, finger.px, finger.py) then
    state.problems[#state.problems + 1] = "key " .. name .. ": released and its hold still waits"
  end
  if entry and entry.fill then state.counts.fill_released = state.counts.fill_released + 1 end
  if entry and entry.fill and S.lib.conditions.fill() and params:get("seq_fill") ~= 1 then
    local other = false
    for other_name in pairs(state.fingers) do
      local other_entry = model.entries[other_name]
      if other_entry and other_entry.fill then other = true end
    end
    if not other then state.problems[#state.problems + 1] = "fill: still held after its key " .. name .. " came up" end
  end
  if entry and entry.hd then
    local other = false
    for other_name in pairs(state.fingers) do
      local other_entry = model.entries[other_name]
      if other_entry and other_entry.hd == entry.hd then other = true end
    end
    local where = Walk.locate(state, finger.px, finger.py)
    local reached = where and where.pane and core.page(WALK.port, where.pane) == S.constants.GRID_PAGES.positions
      and core.side(WALK.port, where.pane) == 2 and not model.chooser
    if reached and not other then state.counts.hold_key_released = state.counts.hold_key_released + 1 end
    if reached and not other and S.lib.positions.holds_scan(entry.hd, "grid:" .. WALK.port) then
      state.problems[#state.problems + 1] = "voice " .. entry.hd .. ": its scan still held after its HD key came up"
    end
  end
end

-- The clock advanced `seconds`, its end kept off every deadline the model
-- predicts. The model's timed events (held steps' editor holds, NV's
-- chooser hold) and the replacements the wrapper saw, in time order; two
-- closer than tie_window leave the order to the code (`tied`)
function Walk.clock(state, seconds)
  local model = state.model
  local start = util.time()
  local finish = start + seconds
  local moved = true
  while moved do
    moved = false
    for _, entry in pairs(model.entries) do
      if entry.deadline and math.abs(entry.deadline - finish) < WALK.end_margin then
        finish, moved = finish + 2 * WALK.end_margin, true
      end
    end
  end
  state.context.clock.run_for(finish - start)
  local events = {}
  for _, entry in pairs(model.entries) do
    if entry.deadline and entry.deadline <= finish then
      events[#events + 1] = { time = entry.deadline, entry = entry, order = entry.order }
    end
  end
  for index, replace in ipairs(state.replaces) do
    events[#events + 1] = { time = replace.time, voice = replace.voice, order = -1000000 + index }
  end
  table.sort(events, function(a, b)
    if a.time ~= b.time then return a.time < b.time end
    return a.order < b.order
  end)
  for index, event in ipairs(events) do
    local neighbor = events[index + 1]
    if neighbor and neighbor.time - event.time < WALK.tie_window then state.tied = true end
    if event.voice then
      Model.replaced(model, event.voice)
    elseif event.entry.deadline then
      local entry = event.entry
      entry.deadline = nil
      state.counts.hold_fired = state.counts.hold_fired + 1
      if entry.kind == "step" and not entry.dropped then
        entry.consumed = true
        model.editor = entry
      elseif entry.kind == "nv" then
        model.chooser = true
        Model.end_pane(model, 1)
      end
    end
  end
  Walk.read_replaced(state)
end

-- The comparisons ------------------------------------------------------

function Walk.compare(state)
  local S, model, core, problems = state.S, state.model, state.core, state.problems
  -- the open editor: two timed events within a tick leave its key to the
  -- code; the model follows what opened (a key it holds), or nothing
  local editor = S.lib.pages_seq.step_editor()
  if state.tied then
    state.tied = false
    model.editor = nil
    if editor then
      for _, entry in pairs(model.entries) do
        if entry.kind == "step" and entry.consumed and not entry.dropped and entry.voice == editor.voice
            and entry.step == editor.step then
          model.editor = entry
        end
      end
    end
  end
  local expected = model.editor and (model.editor.voice .. " " .. model.editor.step .. " " .. WALK.port) or "none"
  local shown = editor and (editor.voice .. " " .. editor.step .. " " .. editor.port) or "none"
  if expected ~= shown then problems[#problems + 1] = "step editor: expected " .. expected .. ", open " .. shown end
  for voice = 1, S.constants.NUM_VOICES do
    for step = 1, S.constants.PATTERN_LENGTH do
      if S.patterns[voice][step] ~= model.patterns[voice][step] then
        problems[#problems + 1] = "voice " .. voice .. " step " .. step .. ": " .. tostring(S.patterns[voice][step])
          .. ", the model's " .. tostring(model.patterns[voice][step])
        model.patterns[voice][step] = S.patterns[voice][step]
      end
    end
  end
  local held = S.grid_held[WALK.port] or {}
  for x, rows in pairs(held) do
    for y, time in pairs(rows) do
      if time ~= nil and model.entries[key_name(x, y)] == nil then
        problems[#problems + 1] = "key " .. key_name(x, y) .. ": held in S.grid_held, not in the model"
      end
    end
  end
  for name, entry in pairs(model.entries) do
    if core.held(WALK.port, entry.px, entry.py) == nil then
      problems[#problems + 1] = "key " .. name .. ": held in the model, not in S.grid_held"
    end
  end
  local port_state = core.existing_port_state(WALK.port)
  local chooser = port_state ~= nil and port_state.chooser == true
  if chooser ~= model.chooser then
    problems[#problems + 1] = "the chooser: shown " .. tostring(chooser) .. ", the model's " .. tostring(model.chooser)
  end
end

-- The ops ---------------------------------------------------------------

local OPS = {}

-- Unplugged, a key down plugs the grid back first (an unplugged grid
-- stays out only for the ops before the next press)
function Walk.plug(state)
  Model.forget(state.model)
  state.context.grid.plug(WALK.port, state.cols, state.rows)
end

OPS.key_down = { 8, "key down", function(state, random)
  if Walk.device(state) == nil then
    Walk.plug(state)
    return
  end
  local down = {}
  for name in pairs(state.fingers) do down[#down + 1] = name end
  table.sort(down)
  if #down > 0 and random(WALK.repress_share) == 1 then
    local finger = state.fingers[down[random(#down)]]
    Walk.press(state, finger.px, finger.py)
    return
  end
  local px, py = Walk.pick_key(state, random)
  if px then Walk.press(state, px, py) end
end }

OPS.key_up = { 7, "key up", function(state, random)
  local down = {}
  for name in pairs(state.fingers) do down[#down + 1] = name end
  if #down == 0 then return end
  table.sort(down)
  Walk.release(state, down[random(#down)])
end }

OPS.clock = { 5, "clock", function(state, random)
  local span = WALK.clock_max - WALK.clock_min
  Walk.clock(state, WALK.clock_min + span * (random(1000) - 1) / 999)
end }

OPS.page = { 2, "page", function(state, random)
  local layout, layout_kind = Walk.layout(state)
  if layout == nil then return end
  local S = state.S
  local pane = random(layout.panes)
  local pick = random(WALK.patterns_share)
  local page = (pick == 1 and S.constants.GRID_PAGES.patterns) or (pick == 2 and S.constants.GRID_PAGES.positions)
    or random(S.constants.GRID_PAGES.count)
  local record = S.registry.grid_pages[page]
  state.core.set_page(WALK.port, page, pane, random(record and record.sides or 1))
  if layout_kind == "64" and random(2) == 1 then state.core.set_half(WALK.port, pane, random(2)) end
  grid_redraw()
end }

OPS.replace = { 1, "replace pattern", function(state, random)
  local steps = {}
  for step = 1, state.S.constants.PATTERN_LENGTH do
    steps[step] = random(3) == 1 and random(state.S.constants.MAX_STEP_LEVEL) or 0
  end
  state.S.lib.sequencer.replace_pattern(random(state.S.constants.NUM_VOICES), steps)
end }

OPS.plug = { 0.6, "unplug or plug", function(state)
  if Walk.device(state) then
    local held = state.S.grid_held[WALK.port]
    if held and next(held) then state.counts.unplug_with_key_held = state.counts.unplug_with_key_held + 1 end
    Model.forget(state.model)
    state.context.grid.unplug(WALK.port)
  else
    Walk.plug(state)
  end
end }

OPS.rotation = { 0.5, "rotation", function(state, random)
  if Walk.device(state) == nil then return end
  local rotation = random(state.core.MAX_ROTATION + 1) - 1
  if rotation ~= state.core.rotation(WALK.port) then Model.forget(state.model) end
  state.core.set_rotation(WALK.port, rotation)
end }

-- The 64's chooser: NV pressed and held past its hold (the chooser opens),
-- or NV let go (it closes)
OPS.chooser = { 1.5, "chooser", function(state)
  local layout = Walk.layout(state)
  if layout == nil then return end
  local px, py = state.S.lib.grid_pane.physical(layout, 1, 1, state.S.constants.NUM_VOICES + 1, 1)
  local name = key_name(px, py)
  if state.fingers[name] then
    Walk.release(state, name)
  else
    Walk.press(state, px, py)
    Walk.clock(state, state.S.constants.GRID_HOLD.chooser_seconds + WALK.clock_min)
  end
end }

local function ops_for(layout)
  local list = { OPS.key_down, OPS.key_up, OPS.clock, OPS.page, OPS.replace, OPS.plug, OPS.rotation }
  if layout == "64" then list[#list + 1] = OPS.chooser end
  local wrapped = {}
  for _, op in ipairs(list) do
    wrapped[#wrapped + 1] = { op[1], op[2], function(state, random)
      state.problems = {}
      Walk.before(state)
      op[3](state, random)
      Walk.settle(state)
    end }
  end
  return wrapped
end

-- The end: every key up, the clock run on, then nothing of a key lives
local function finish(state)
  local S = state.S
  local names = {}
  for name in pairs(state.fingers) do names[#names + 1] = name end
  table.sort(names)
  state.problems = {}
  Walk.before(state)
  for _, name in ipairs(names) do Walk.release(state, name) end
  Walk.settle(state)
  Walk.compare(state)
  state.context.clock.run_for(WALK.finish_seconds)
  local problems = state.problems
  local hold_clocks = h.registered_invariant("grid keys").upvalue("hold_clocks")
  for port, columns in pairs(hold_clocks) do
    for x, rows in pairs(columns) do
      for y, handle in pairs(rows) do
        problems[#problems + 1] = "grid " .. port .. " key " .. key_name(x, y) .. ": a hold clock lives ("
          .. tostring(S.lib.clocks.alive(handle)) .. ")"
      end
    end
  end
  for id in pairs(S.lib.clocks.retired) do problems[#problems + 1] = "clock " .. tostring(id) .. " still retired" end
  local records
  local index = 1
  while true do
    local upvalue_name, value = debug.getupvalue(S.lib.positions.end_stale_holds, index)
    if upvalue_name == nil then break end
    if upvalue_name == "records" then records = value end
    index = index + 1
  end
  if records == nil then problems[#problems + 1] = "positions: no records to read" end
  for port, record in pairs(records or {}) do
    local held = record.held ~= nil or next(record.hold) ~= nil or next(record.store) ~= nil or next(record.pressed) ~= nil
    for _, cells in pairs(record.slices) do held = held or next(cells) ~= nil end
    if held then problems[#problems + 1] = "positions: port " .. port .. "'s record still holds a key" end
  end
  for voice = 1, S.constants.NUM_VOICES do
    if S.lib.positions.scan_held(voice) then problems[#problems + 1] = "voice " .. voice .. ": its scan is held" end
  end
  if S.lib.pages_seq.step_editor() then problems[#problems + 1] = "a step editor is open" end
  local port_state = state.core.existing_port_state(WALK.port)
  if port_state and port_state.chooser then problems[#problems + 1] = "the chooser is open" end
  if S.pattern_playing then pattern_clock_stop() end
  return problems
end

local COUNTERS = { "hold_fired", "hold_ended_by_page", "release_under_chooser", "unplug_with_key_held",
  "step_toggled", "level_set", "fill_released", "hold_key_released" }

-- The walk's state on a fresh script with a grid of the layout, every
-- pattern step as `fill` says (a function of voice and step), and every
-- whole-pattern change observed
local function walk_state(context, layout, fill)
  local S = local_value("S")
  local pane = h.grid_pane(context, LAYOUT_START[layout])
  for voice = 1, WALK.buffer_voices do params:set("v" .. voice .. "_source", S.constants.SOURCE_SYNTH + voice) end
  for voice = 1, S.constants.NUM_VOICES do
    for step = 1, S.constants.PATTERN_LENGTH do S.patterns[voice][step] = fill(voice, step) end
  end
  local state = { context = context, S = S, core = S.lib.grid_core, model = Model.new(S), fingers = {},
    cols = pane.device.native_cols, rows = pane.device.native_rows, problems = {}, replaces = {}, counts = {} }
  for _, counter in ipairs(COUNTERS) do state.counts[counter] = 0 end
  -- every whole-pattern change, observed and passed on: the model ends the
  -- voice's step keys and reads its pattern again
  local replace_pattern = S.lib.sequencer.replace_pattern
  S.lib.sequencer.replace_pattern = function(voice, steps)
    state.replaces[#state.replaces + 1] = { voice = voice, time = util.time() }
    return replace_pattern(voice, steps)
  end
  return state
end

-- Run one of the walk's ops by hand (the same wrapper as the walk's)
local function run_op(state, op, ...)
  local args = { ... }
  state.problems = {}
  Walk.before(state)
  op(state, (table.unpack or unpack)(args))
  Walk.settle(state)
  Walk.compare(state)
  return state.problems
end

-- The model by hand, on the 128h: a tap toggles its step; a key held past
-- the editor's hold opens the editor and its release toggles nothing; a
-- level key sets the held step's level; a page change ends a held step;
-- the walk's comparisons find nothing wrong on the way. And the
-- comparison is no rubber stamp: a step set behind the model's back is
-- named
h.test("the grid walk's model: taps, the editor's hold, a level key and a page change, by hand", function()
  local context = h.load_strata()
  h.finish_startup(context)
  local state = walk_state(context, "128h", function() return 0 end)
  local S = state.S
  local function problems_of(list) return table.concat(list, "; ") end
  h.assert_equal(problems_of(run_op(state, Walk.press, 5, 1)), "", "voice 1 step 5 pressed")
  h.assert_equal(problems_of(run_op(state, Walk.release, key_name(5, 1))), "", "and released")
  h.assert_equal(S.patterns[1][5], S.constants.MAX_STEP_LEVEL, "the tap toggled step 5 on")
  run_op(state, Walk.press, 6, 2)
  h.assert_equal(problems_of(run_op(state, Walk.clock, 0.4)), "", "voice 2 step 6 held past the editor's hold")
  h.assert_equal(h.shown_step_editor(), "2 6 1", "the editor is open for it")
  run_op(state, Walk.press, 12, 2)
  h.assert_equal(S.patterns[2][6], 11, "the level key at 12 of 16 set step 6's level (round(12 * 15 / 16))")
  run_op(state, Walk.release, key_name(12, 2))
  h.assert_equal(problems_of(run_op(state, Walk.release, key_name(6, 2))), "", "the editor's key up")
  h.assert_equal(h.shown_step_editor(), nil, "the editor closed")
  h.assert_equal(S.patterns[2][6], 11, "and its step kept its level")
  run_op(state, Walk.press, 3, 3)
  run_op(state, function(walk_state_now)
    walk_state_now.core.set_page(WALK.port, S.constants.GRID_PAGES.scenes, 1, 1)
  end)
  h.assert_equal(problems_of(run_op(state, Walk.release, key_name(3, 3))), "", "a held step up after a page change")
  h.assert_equal(S.patterns[3][3], 0, "its step did not toggle")
  h.assert_true(state.counts.hold_fired == 1 and state.counts.level_set == 1 and state.counts.step_toggled == 1,
    "the counters followed")
  S.patterns[4][1] = 9
  h.assert_equal(problems_of(run_op(state, Walk.clock, 0.1)), "voice 4 step 1: 9, the model's 0",
    "a change the model did not make is named")
end)

for _, layout in ipairs({ "256", "128h", "128v", "64" }) do
  local reached = { "hold_fired", "hold_ended_by_page", "unplug_with_key_held", "step_toggled", "level_set",
    "hold_key_released" }
  -- the 64 has the chooser and no fill key; the other layouts the reverse
  reached[#reached + 1] = layout == "64" and "release_under_chooser" or "fill_released"
  h.walk({
    name = "the grid walk on the " .. layout .. ": releases do what the model says, and every key ends",
    seeds = WALK.seeds,
    steps = WALK.steps,
    setup = function(context, random)
      local max_level = local_value("S").constants.MAX_STEP_LEVEL
      return walk_state(context, layout, function() return random(3) == 1 and max_level or 0 end)
    end,
    ops = ops_for(layout),
    after = function(state)
      Walk.compare(state)
      return state.problems
    end,
    finish = finish,
    reached = reached,
    counts = function(state) return state.counts end,
  })
end

end
