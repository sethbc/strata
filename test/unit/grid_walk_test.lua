-- test/unit/grid_walk_test.lua
-- 3.9's package 3b (its design's section 6, the grid walk), extended by
-- the grid sequencer's 6b (its design's section 7): seeded walks of grid
-- keys on the four layouts (the 256, the 128h, the 128v, the 64), one
-- h.walk a layout. Its ops: a key down (any key the grid shows: a pane key
-- on whatever page and side its pane shows, a strip key; now and then a
-- key already down pressed again, a release that never came), a held key
-- up, the clock advanced 0.05 to 0.6 s, a pane's page, side (and on the 64
-- its half) changed, the 64's chooser opened and closed, a voice's pattern
-- replaced (S.lib.sequencer.replace_pattern), the grid unplugged and
-- plugged, a rotation (S.lib.grid_core.set_rotation), K2 with the step
-- editor open, and the rework's keys pressed on purpose: a key of patterns'
-- lane side or of the voices page's perform side, a second key of a held
-- step's or cell's line, the play key, a sparse voice's step tapped, a
-- loop (held across a bar when its voice will switch), an HD key, an
-- order built with OR. A small model of the grid core and of the two
-- sides keeps, per key the core holds, what its release should do: toggle
-- its step (a held step whose gesture still stands), tap its cell (a lane
-- cell), nothing (a second key, "level" in the model: a loop on side 1, a
-- level or value A on side 2; a consumed key; a key whose gesture ended)
-- or end a hold (NV, fill, a positions HD key, a loop, a roll), with the
-- patterns it expects, the step editor and step view it expects open, the
-- picked voice and LN's arming. After every op `after` compares the model
-- with S.patterns, S.grid_held, the open step editor, the step view, the
-- picked voice, LN, each voice's roll and loop, a running voice's last
-- seqGate against the gate rule (and the chooser on the 64), and every
-- invariant runs; at the end every key goes up, and then no hold the core
-- armed lives, fill is not held, no step view shows, no voice rolls and
-- no unlatched loop lives (read before any wait), and a second on no hold
-- clock is pending or retired, no roll lives, no positions record holds a
-- key, no scan is held, no step editor is open, every running voice's
-- last seqGate is the rule's, LN tapped and taken through a page change is
-- disarmed, and with the patterns stopped no letter waits. It also holds
-- each key's press against the core's still, and at each key event the
-- cell value, the loop, the length, the mode and the latch the key leaves
-- against 3b's rules, worked out by hand (VALUES). The model reads the
-- rules from the notes (docs/notes/lua/grid/walk.md says which, what it
-- checks and what it does not), not from the code; it reads as given only
-- what no key of the walk decides (a cell's value before a key acts on it,
-- a lane's length before LN's key, the voice's length, its mode once a
-- mode key's press is checked), and observes only
-- when a pattern was replaced (every whole-pattern change goes through
-- replace_pattern: a scene recall, CL and RN, a paste, a letter's switch),
-- which it wraps and passes on.
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
  steps = 500,
  clock_min = 0.05, clock_max = 0.6,
  tie_window = 0.003, end_margin = 0.004,
  strip_share = 4,       -- one press in strip_share is a strip key
  patterns_share = 4,    -- one page change in patterns_share shows patterns, one positions, one voices
  favored_share = 3,     -- one press in favored_share takes a key whose release ends a hold
  fill_key = 2,          -- the upper strip's FL
  repress_share = 12,    -- one press in repress_share presses a key already down
  port = 1,
  hold_mark = 7,         -- positions side 2: x 7 is the voice's HD key
  buffer_voices = 3,     -- voices 1-3 read buffer slots 1-3 (positions keys act)
  stop_share = 4,        -- the play op stops playing patterns one time in stop_share
  order_letters = 3,     -- an order op taps one to order_letters letters
  bar_seconds = 2.2,     -- past a bar at 120 BPM (a loop op waits it for a switch under the loop)
  finish_seconds = 1,    -- after the last key up: every retired clock wakes, every stale record ends
}
local WALK = GRID_WALK

-- The two sides the rework added, in pane coordinates (the pages' notes:
-- docs/notes/lua/grid/pages/patterns.md and voices.md): patterns' side 2,
-- its lines (line 1 the hits, 2-6 the lanes) and its utility line (LN, B,
-- the voices from first_voice_x); the voices page's perform side (the roll
-- keys from first_roll, FL)
local UTILITY = { line = 7, modes = { "pulse", "move", "accent" }, ln_x = 4, first_target_x = 5, targets = 4, b_x = 9,
  first_voice_x = 10 }
local LANE_LINES = { "hits", "a", "b", "chance", "repeats", "gate" }
local PERFORM_KEYS = { mute = 1, solo = 2, first_letter = 3, order = 7, latch = 8, first_roll = 9, rolls = 4,
  first_mode = 13, fill = 16 }

-- 3b's values from a key's place along the keys shown (16, or a 64's 8),
-- worked out by hand from the patterns page's notes (norns' util.round
-- rounds halves up), never by the page's code: the level (the hits, value
-- A and B) max(1, round(place * 15 / keys)); repeats max(1, round(place *
-- 4 / keys)); chance by level, round(level * 100 / 15). Gate is the
-- level's place on the voice's gate length spec: the walk knows its two
-- ends (level 1 its minimum, 15 its maximum) and only a range between.
-- What a tap gives an empty cell before any value is set on its lane
-- (gate: the voice's gate length)
local VALUES = {
  level = { [16] = { 1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 10, 11, 12, 13, 14, 15 }, [8] = { 2, 4, 6, 8, 9, 11, 13, 15 } },
  repeats = { [16] = { 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4 }, [8] = { 1, 1, 2, 2, 3, 3, 4, 4 } },
  chance = { 7, 13, 20, 27, 33, 40, 47, 53, 60, 67, 73, 80, 87, 93, 100 },
  first = { a = 15, b = 15, chance = 53, repeats = 2 },
}

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

-- An entry per key the core holds (by key name): {name, px, py, pane (a
-- pane key's; nil for a strip key), kind "step" | "level" | "cell" |
-- "cell second" | "nv" | "other", voice, step, second (a held step's
-- second key: "loop" on patterns' side 1, "hits" on side 2's line 1),
-- fired (its hold fired), lane, id and index (a lane cell's), consumed,
-- dropped (its gesture ended), gone (its press ended: a pane change, a
-- press again, the port forgotten), deadline (a held step's editor hold,
-- NV's chooser hold), order (the press's number), hd (positions HD's
-- voice), fill (a fill key: the strip's FL, or the perform side's,
-- `perform_fill`), roll (a perform roll key's rate), switched (a loop's
-- key whose voice a letter's switch replaced since)}. The rest of the
-- model: the patterns, the open editor's key, the chooser, the picked
-- voice and LN's arming (patterns' page state, {pane}), and per voice the
-- key whose loop and whose roll it holds, and the key whose press the
-- voice's loop carries (`carriers`: the last held step whose second key
-- made it, kept when it latches, the final review's I1)
local Model = {}

function Model.new(S)
  local patterns = {}
  for voice = 1, S.constants.NUM_VOICES do
    patterns[voice] = {}
    for step = 1, S.constants.PATTERN_LENGTH do patterns[voice][step] = S.patterns[voice][step] end
  end
  return { entries = {}, patterns = patterns, editor = nil, chooser = false, order = 0, picked = 1, ln = nil,
    loops = {}, rolls = {}, carriers = {}, last = {} }
end

-- Whether an entry's press still stands (its key's still): held, its
-- press not ended
function Model.live(model, entry)
  return entry ~= nil and model.entries[entry.name] == entry and not entry.gone
end

-- The pane the step view shows on (patterns' side 2 by the rule of
-- docs/notes/lua/grid/keys.md, step view): the editor's key's own pane if
-- it shows side 2, else the first pane that does; {pane, voice, step} or
-- nil (no editor, or no pane on side 2)
function Walk.view(state)
  local editor, layout = state.model.editor, Walk.layout(state)
  if editor == nil or layout == nil then return nil end
  local S, core = state.S, state.core
  -- while settle ends a changed pane's keys, the pane's page before the
  -- change: the core reads the view in set_pane before it keeps the new one
  local before = state.view_pages or {}
  local function lane_side(pane)
    if before[pane] then return before[pane] == S.constants.GRID_PAGES.patterns .. ":2" end
    return core.page(WALK.port, pane) == S.constants.GRID_PAGES.patterns and core.side(WALK.port, pane) == 2
  end
  local pane = editor.pane and lane_side(editor.pane) and editor.pane
  for index = 1, layout.panes do
    if not pane and lane_side(index) then pane = index end
  end
  return pane and { pane = pane, voice = editor.voice, step = editor.step } or nil
end

-- The step editor opens for `entry` (its hold fired): the view's pane
-- before (the first editor's) and after end their keys but the editor's
-- key. Inside a tie (state.doubt) the order is the code's, so the ends
-- wait for compare's choice (state.view_deferred)
function Model.open_editor(state, entry)
  local model = state.model
  if state.doubt then
    model.editor, state.view_deferred = entry, true
    return
  end
  local before, old = Walk.view(state), model.editor
  model.editor = entry
  if before then Model.end_pane(state, before.pane, old) end
  Model.view_started(state)
end

-- The view the editor now shows (if any) starts: its pane's keys end but
-- the editor's key; counted, and counted again when a key stays held on
-- another pane
function Model.view_started(state)
  local model, view = state.model, Walk.view(state)
  if view == nil then
    if model.editor then state.counts.editor_without_view = state.counts.editor_without_view + 1 end
    return
  end
  Model.end_pane(state, view.pane, model.editor)
  state.counts.view_opened = state.counts.view_opened + 1
  for _, entry in pairs(model.entries) do
    if entry ~= model.editor and entry.pane and entry.pane ~= view.pane then
      state.counts.view_other_pane_held = state.counts.view_other_pane_held + 1
      return
    end
  end
end

-- The step editor closes (its key's release or gesture's end, K2): its
-- view's pane ends its keys but the editor's key
function Model.close_editor(state)
  local model = state.model
  if model.editor == nil then return end
  if state.doubt then
    model.editor, state.view_deferred = nil, true
    return
  end
  local view, old = Walk.view(state), model.editor
  model.editor = nil
  if view then Model.end_pane(state, view.pane, old) end
end

-- A key's gesture ends: a step or a cell no longer acts at its release
-- (the step editor's key closes the editor), a perform FL no longer
-- holds fill
function Model.drop(state, entry)
  if entry.kind == "step" or entry.kind == "level" or entry.kind == "cell" or entry.kind == "cell second" then
    entry.dropped, entry.deadline = true, nil
  end
  if entry.perform_fill then entry.fill = nil end
  if state.model.editor == entry then Model.close_editor(state) end
end

-- A pane's keys end (a page, side or half change; the chooser opening;
-- the step view's start or end on it, `spare` the editor's key): their
-- gestures and their presses end (NV, a strip key, goes on)
function Model.end_pane(state, pane, spare)
  local ended = {}
  for _, entry in pairs(state.model.entries) do
    if entry.pane == pane and entry ~= spare then ended[#ended + 1] = entry end
  end
  table.sort(ended, function(a, b) return a.order < b.order end)
  for _, entry in ipairs(ended) do
    entry.gone = true
    Model.drop(state, entry)
  end
end

-- The port is forgotten (unplug, plug, a rotation): nothing held, the
-- picked voice and LN forgotten with its page state
function Model.forget(state)
  local model = state.model
  for _, entry in pairs(model.entries) do entry.gone = true end
  model.entries, model.editor, model.chooser, model.picked, model.ln, model.last = {}, nil, false, 1, nil, {}
end

-- The voice's pattern replaced: its step keys' gestures end, on every
-- pane (a lane's held cell stays), but the held step whose press the
-- voice's live loop carries (the final review's I1: a loop's end writes
-- nothing, so a further key still moves it); a letter's switch
-- (`switched`) is noted on the key holding the voice's loop. Whether the
-- loop lives is read as given: the walk does not predict a length cut's
function Model.replaced(state, voice, switched)
  local model = state.model
  local carrier = model.carriers[voice]
  local kept = Model.live(model, carrier) and state.S.lib.loop_roll.loop(voice) ~= nil and carrier or nil
  for _, entry in pairs(model.entries) do
    if entry.voice == voice and (entry.kind == "step" or entry.kind == "level") and entry ~= kept then
      Model.drop(state, entry)
    end
  end
  if kept and not kept.dropped then kept.kept_loop = true end
  local holder = model.loops[voice]
  if switched and Model.live(model, holder) then holder.switched = true end
end

-- The voice's held step on the port and view: a step entry (not a second
-- key) whose gesture stands, pressed on the same view (`second`: "loop"
-- is patterns' side 1, "hits" side 2's line 1; the final review's M1: a
-- second key pairs only with a held step of its own view)
function Model.held_step(model, voice, second)
  for _, entry in pairs(model.entries) do
    if entry.kind == "step" and entry.voice == voice and entry.second == second and not entry.dropped then
      return entry
    end
  end
  return nil
end

-- The port's held cell of a lane's line: a cell entry whose gesture stands
function Model.held_cell(model, id)
  for _, entry in pairs(model.entries) do
    if entry.kind == "cell" and entry.id == id and not entry.dropped then return entry end
  end
  return nil
end

-- The ops' parts --------------------------------------------------------

-- A pane's offset and keys shown (a 64's half: 8 keys)
function Walk.geometry(state, pane)
  local _, kind = Walk.layout(state)
  local keys = state.S.lib.grid_pane.LINE_KEYS
  local half_keys = math.floor(keys / 2)
  if kind == "64" then return (Walk.half(state, pane) - 1) * half_keys, half_keys end
  return 0, keys
end

-- Before an op: each pane's view and page, which held keys wait for a
-- hold, each voice's roll
function Walk.before(state)
  local views, pages, pending, rolling = {}, {}, {}, {}
  local layout = Walk.layout(state)
  for pane = 1, layout and layout.panes or 0 do
    views[pane] = state.core.view(WALK.port, pane)
    pages[pane] = state.core.page(WALK.port, pane) .. ":" .. state.core.side(WALK.port, pane)
  end
  for name, entry in pairs(state.model.entries) do
    pending[name] = state.core.hold_pending(WALK.port, entry.px, entry.py)
  end
  for voice = 1, state.S.constants.NUM_VOICES do rolling[voice] = state.S.lib.loop_roll.rolling(voice) end
  state.views, state.pages, state.pending, state.replaces, state.rolling_before = views, pages, pending, {}, rolling
  state.toggled_off = {}
end

-- After an op (Walk.after_op): a pane whose page or side changed disarms
-- LN there; a pane whose view changed ends its keys (a roll key's live
-- roll among them); a replaced voice ends its step keys and its pattern
-- is read again
function Walk.settle(state)
  local layout, model = Walk.layout(state), state.model
  if layout then
    for pane = 1, layout.panes do
      local page = state.core.page(WALK.port, pane) .. ":" .. state.core.side(WALK.port, pane)
      if model.ln and model.ln.pane == pane and state.pages[pane] ~= nil and state.pages[pane] ~= page then
        model.ln = nil
        state.counts.ln_disarmed_by_page = state.counts.ln_disarmed_by_page + 1
      end
      if state.views[pane] ~= nil and state.views[pane] ~= state.core.view(WALK.port, pane) then
        for name, entry in pairs(model.entries) do
          if entry.pane == pane then
            if state.pending[name] then state.counts.hold_ended_by_page = state.counts.hold_ended_by_page + 1 end
            if state.core.hold_pending(WALK.port, entry.px, entry.py) then
              state.problems[#state.problems + 1] = "key " .. name .. ": its pane's view changed and its hold still waits"
            end
            if entry.roll and model.rolls[entry.voice] == entry and state.rolling_before[entry.voice] == entry.roll then
              state.counts.roll_ended_by_page = state.counts.roll_ended_by_page + 1
            end
          end
        end
        state.view_pages = { [pane] = state.pages[pane] }
        Model.end_pane(state, pane)
        state.view_pages = nil
      end
    end
  end
  for _, replace in ipairs(state.replaces) do Model.replaced(state, replace.voice, replace.switched) end
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

-- A value set on a lane's cell (a tap, a second key, a step view's bar):
-- value A or B of a lane that follows, on a step that is off, turns it on
-- at 15 (docs/notes/lua/grid/pages/patterns.md, Must not break)
function Walk.value_set(state, voice, lane, cell)
  local pattern = state.model.patterns[voice]
  if (lane == "a" or lane == "b") and state.S.lib.lanes.length(voice, lane) == nil and pattern[cell] == 0 then
    pattern[cell] = state.S.constants.MAX_STEP_LEVEL
  end
end

-- A lane's value from a key's place (3b's rules, VALUES): {exact = v},
-- or for gate between its ends {low, high} (both excluded)
function Walk.lane_value(state, voice, lane, position, keys)
  local level = VALUES.level[keys][position]
  if lane == "a" or lane == "b" then return { exact = level } end
  if lane == "chance" then return { exact = VALUES.chance[level] } end
  if lane == "repeats" then return { exact = VALUES.repeats[keys][position] } end
  local spec = params:lookup_param("v" .. voice .. "_seq_gate_length").controlspec
  if level == 1 then return { exact = spec.minval } end
  if level == state.S.constants.MAX_STEP_LEVEL then return { exact = spec.maxval } end
  return { low = spec.minval, high = spec.maxval }
end

-- Whether a value is the one predicted (nil: none)
function Walk.value_matches(predicted, value)
  if predicted == nil then return value == nil end
  if value == nil then return false end
  if predicted.exact ~= nil then return math.abs(value - predicted.exact) < 1e-9 end
  return value > predicted.low and value < predicted.high
end

function Walk.value_text(predicted)
  if predicted == nil then return "none" end
  if predicted.exact ~= nil then return tostring(predicted.exact) end
  return "between " .. predicted.low .. " and " .. predicted.high
end

-- A check the press or release being modeled must pass once the core has
-- it (run by Walk.press and Walk.release after the key event): fn returns
-- a problem, or nil
function Walk.expect(state, fn) state.expect[#state.expect + 1] = fn end

function Walk.run_expected(state)
  for _, fn in ipairs(state.expect) do
    local problem = fn()
    if problem then state.problems[#state.problems + 1] = problem end
  end
  state.expect = {}
end

-- The cell's value must be `predicted` after the key event
function Walk.expect_value(state, voice, cell, lane, predicted, what)
  Walk.expect(state, function()
    local value = state.S.lib.sequencer.step_attr(voice, cell, state.S.lib.lanes.STEP_KEYS[lane])
    if Walk.value_matches(predicted, value) then return nil end
    return "voice " .. voice .. " cell " .. cell .. " " .. lane .. ": " .. tostring(value) .. " after " .. what
      .. ", 3b's rules give " .. Walk.value_text(predicted)
  end)
end

-- What a tap gives an empty cell: the port's last value set on the lane,
-- else the lane's first (gate: the voice's gate length)
function Walk.tap_value(state, voice, lane)
  return state.model.last[lane] or (VALUES.first[lane] and { exact = VALUES.first[lane] })
    or { exact = params:get("v" .. voice .. "_seq_gate_length") }
end

-- A held step's second key, before its hold fired: on side 1 the voice
-- loops between the two keys (cut to its length; no level), held by the
-- held key; on side 2's line 1 the held step takes the level from the
-- second key's place along the held key's pane, in move value A (an off
-- step on at 15)
function Walk.second_effect(state, held, second_step)
  local S, model = state.S, state.model
  if held.second == "loop" then
    local voice, length = held.voice, params:get("v" .. held.voice .. "_seq_length")
    local lo, hi = math.min(held.step, second_step), math.max(held.step, second_step)
    if lo > length then
      -- wholly past the length: no loop is made, the voice's stays
      lo, hi = S.lib.loop_roll.loop(voice)
    else
      hi = math.min(hi, length)
      model.loops[voice], model.carriers[voice] = held, held
      held.made_loop = voice
      if held.kept_loop then state.counts.loop_end_after_replacement = state.counts.loop_end_after_replacement + 1 end
      state.counts.loop_made = state.counts.loop_made + 1
    end
    Walk.expect(state, function()
      local got_lo, got_hi = S.lib.loop_roll.loop(voice)
      if got_lo == lo and got_hi == hi then return nil end
      return "voice " .. voice .. ": the loop " .. tostring(got_lo) .. " to " .. tostring(got_hi) .. " after its second key, "
        .. "the keys give " .. tostring(lo) .. " to " .. tostring(hi)
    end)
    return
  end
  local offset, width = Walk.geometry(state, held.pane)
  local position = second_step - offset
  if position < 1 or position > width then return end
  state.counts.hits_second = state.counts.hits_second + 1
  local pattern = model.patterns[held.voice]
  if S.lib.sequencer.step_mode(held.voice) == "move" then
    if pattern[held.step] == 0 then pattern[held.step] = S.constants.MAX_STEP_LEVEL end
    Walk.expect_value(state, held.voice, held.step, "a", { exact = VALUES.level[width][position] }, "a hits second key")
  else
    pattern[held.step] = VALUES.level[width][position]
  end
end

-- A step key of `voice` (side 1's line, side 2's hits): its voice's
-- second key if the voice has a held step, else a held step
function Walk.step_press(state, entry, voice, step, second)
  local held = Model.held_step(state.model, voice, second)
  entry.voice = voice
  if held then
    held.consumed, held.deadline = true, nil
    entry.kind, entry.step, entry.consumed = "level", step, true
    state.counts.second_key = state.counts.second_key + 1
    if not held.fired then Walk.second_effect(state, held, step) end
  else
    entry.kind, entry.step, entry.second = "step", step, second
    entry.deadline = util.time() + state.S.constants.GRID_HOLD.step_edit_seconds
  end
end

-- A lane's cell key (side 2's lines 2-6): the line's second key if it
-- has a held cell (the held cell takes the value), else a held cell
function Walk.cell_press(state, entry, voice, lane, x)
  local id = "patterns " .. voice .. " " .. lane
  local held = Model.held_cell(state.model, id)
  entry.voice, entry.lane, entry.id = voice, lane, id
  if held then
    held.consumed = true
    entry.kind, entry.consumed = "cell second", true
    Walk.value_set(state, voice, lane, held.index)
    state.counts.cell_second = state.counts.cell_second + 1
    -- the held cell takes the value of this key's place along its own pane,
    -- kept as the port's last for the lane
    local offset, width = Walk.geometry(state, entry.pane)
    local predicted = Walk.lane_value(state, voice, lane, x - offset, width)
    state.model.last[lane] = predicted
    Walk.expect_value(state, voice, held.index, lane, predicted, "a second key")
  else
    entry.kind, entry.index = "cell", x
  end
end

-- A mode key: the voice's mode is the key's after its press
function Walk.expect_mode(state, voice, mode)
  Walk.expect(state, function()
    local got = state.S.lib.sequencer.step_mode(voice)
    if got == mode then return nil end
    return "voice " .. voice .. ": mode " .. tostring(got) .. " after its " .. mode .. " key"
  end)
end

-- The utility line (side 2's line 7), acting at its press: x 4 arms LN on
-- the pane or disarms it, x 10-16 pick a voice (the modes, the targets and
-- B change no level)
function Walk.utility_press(state, entry, x, pane)
  local model = state.model
  if UTILITY.modes[x] then
    Walk.expect_mode(state, model.picked, UTILITY.modes[x])
  elseif x == UTILITY.ln_x then
    if model.ln and model.ln.pane == pane then
      model.ln = nil
    else
      model.ln = { pane = pane }
      state.counts.ln_armed = state.counts.ln_armed + 1
    end
  elseif x == UTILITY.b_x then
    entry.b = true
  elseif x >= UTILITY.first_target_x and x < UTILITY.first_target_x + UTILITY.targets then
    for _, other in pairs(model.entries) do
      if other.b and other.pane == pane and Model.live(model, other) then
        state.counts.b_target = state.counts.b_target + 1
        break
      end
    end
  elseif x >= UTILITY.first_voice_x then
    model.picked = x - UTILITY.first_voice_x + 1
  end
end

-- A bar of the step view (lines 1-6), at its press: the level from the
-- key's place (every mode); a lane's value from it, a value key clearing
-- its cell, a free lane's bar nothing (value A or B set on an off step
-- turns it on)
function Walk.view_press(state, view, x, y, pane)
  local S = state.S
  local offset, width = Walk.geometry(state, pane)
  local position, lane = x - offset, LANE_LINES[y]
  if lane == nil then return end
  state.counts.view_bar = state.counts.view_bar + 1
  local voice, step = view.voice, view.step
  if lane == "hits" then
    state.model.patterns[voice][step] = VALUES.level[width][position]
    return
  end
  local before = S.lib.sequencer.step_attr(voice, step, S.lib.lanes.STEP_KEYS[lane])
  if S.lib.lanes.length(voice, lane) then  -- a free lane's bar: nothing
    Walk.expect_value(state, voice, step, lane, before ~= nil and { exact = before } or nil, "a free lane's bar key")
    return
  end
  -- the bar's value (chance: 100 for a set step with no prob) and its
  -- key, the first place whose value reaches it (gate's: not known)
  local shown = before
  if lane == "chance" and shown == nil and state.model.patterns[voice][step] > 0 then shown = 100 end
  local key
  if shown ~= nil and lane ~= "gate" then
    key = width
    for place = width, 1, -1 do
      if Walk.lane_value(state, voice, lane, place, width).exact >= shown then key = place end
    end
  end
  local predicted = Walk.lane_value(state, voice, lane, position, width)
  if key == position then  -- the value's own key clears the cell
    Walk.expect_value(state, voice, step, lane, nil, "its value key on the step view")
    return
  end
  if lane == "gate" and shown ~= nil then
    -- the key of a gate value is not known: cleared, or the place's value
    -- (then the port's last for gate)
    Walk.expect(state, function()
      local value = S.lib.sequencer.step_attr(voice, step, S.lib.lanes.STEP_KEYS.gate)
      if value == nil then return nil end
      state.model.last.gate = predicted
      if Walk.value_matches(predicted, value) then return nil end
      return "voice " .. voice .. " cell " .. step .. " gate: " .. value .. " after a step view bar key, 3b's rules give "
        .. Walk.value_text(predicted) .. " or none"
    end)
    return
  end
  state.model.last[lane] = predicted
  Walk.expect_value(state, voice, step, lane, predicted, "a step view bar key")
  Walk.value_set(state, voice, lane, step)
end

-- A key of the patterns page: side 1's step keys (a press picks the
-- line's voice); side 2's step view while it shows on the pane, else the
-- utility line, LN's spent press, the hits and the lanes' cells
function Walk.press_patterns(state, entry, where, side)
  local model = state.model
  if side == 1 then
    model.picked = where.y
    Walk.step_press(state, entry, where.y, where.x, "loop")
    return
  end
  state.counts.lane_side_key = state.counts.lane_side_key + 1
  local view = Walk.view(state)
  if view and view.pane == where.pane then
    Walk.view_press(state, view, where.x, where.y, where.pane)
    return
  end
  if where.y == UTILITY.line then
    Walk.utility_press(state, entry, where.x, where.pane)
    return
  end
  local lane = LANE_LINES[where.y]
  if model.ln and model.ln.pane == where.pane then
    -- LN's spent press: line 1 sets the voice's length to x; a lane's
    -- length is x, or follows again when x is its length already
    entry.consumed, model.ln = true, nil
    state.counts.ln_spent = state.counts.ln_spent + 1
    local S, voice, x = state.S, model.picked, where.x
    local expected = x
    if lane ~= "hits" and S.lib.lanes.length(voice, lane) == x then expected = nil end
    Walk.expect(state, function()
      local got = lane == "hits" and params:get("v" .. voice .. "_seq_length") or S.lib.lanes.length(voice, lane)
      if got == expected then return nil end
      return "voice " .. voice .. " " .. lane .. ": length " .. tostring(got) .. " after LN's key " .. x .. ", not "
        .. tostring(expected)
    end)
    return
  end
  if lane == "hits" then
    Walk.step_press(state, entry, model.picked, where.x, "hits")
  else
    Walk.cell_press(state, entry, model.picked, lane, where.x)
  end
end

-- A key of the voices page's perform side: a roll key with the patterns
-- playing holds the voice's roll; FL holds fill (the rest is observed:
-- a letter's switch through replace_pattern, the latch through loop_roll)
function Walk.press_perform(state, entry, where)
  local S = state.S
  state.counts.perform_key = state.counts.perform_key + 1
  local rate = where.x - PERFORM_KEYS.first_roll + 1
  if rate >= 1 and rate <= PERFORM_KEYS.rolls and S.pattern_playing then
    local before = state.model.rolls[where.y]
    if Model.live(state.model, before) then state.counts.roll_replaced = state.counts.roll_replaced + 1 end
    entry.voice, entry.roll = where.y, rate
    state.model.rolls[where.y] = entry
    state.counts.roll_pressed = state.counts.roll_pressed + 1
  elseif where.x == PERFORM_KEYS.fill then
    entry.fill, entry.perform_fill = true, true
  elseif where.x == PERFORM_KEYS.latch then
    state.counts.latch_pressed = state.counts.latch_pressed + 1
    Walk.expect_latch(state, where.y)
  elseif where.x >= PERFORM_KEYS.first_mode and UTILITY.modes[where.x - PERFORM_KEYS.first_mode + 1] then
    Walk.expect_mode(state, where.y, UTILITY.modes[where.x - PERFORM_KEYS.first_mode + 1])
  end
end

-- LP (press_latch, docs/notes/lua/loop-roll.md): a latched loop ends with
-- its latch; a held loop is latched, the same loop; with no loop the latch
-- is armed, or disarmed if it was
function Walk.expect_latch(state, voice)
  local roll = state.S.lib.loop_roll
  local lo, hi = roll.loop(voice)
  local latched, armed = roll.latched(voice), roll.armed(voice)
  if lo and not latched then state.counts.latch_held = state.counts.latch_held + 1 end
  Walk.expect(state, function()
    local got_lo, got_hi = roll.loop(voice)
    local now = "loop " .. tostring(got_lo) .. " to " .. tostring(got_hi) .. ", latched " .. tostring(roll.latched(voice))
      .. ", armed " .. tostring(roll.armed(voice))
    local right
    if lo and latched then
      right = got_lo == nil and not roll.latched(voice) and not roll.armed(voice)
    elseif lo then
      right = got_lo == lo and got_hi == hi and roll.latched(voice)
    else
      right = got_lo == nil and roll.armed(voice) == not armed
    end
    if right then return nil end
    return "voice " .. voice .. ": LP left " .. now .. " (before: loop " .. tostring(lo) .. " to " .. tostring(hi)
      .. ", latched " .. tostring(latched) .. ", armed " .. tostring(armed) .. ")"
  end)
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
    old.gone = true
    Model.drop(state, old)
    model.entries[name] = nil
  end
  model.order = model.order + 1
  state.expect = {}
  local entry = { name = name, px = px, py = py, kind = "other", order = model.order,
    pane = where and not where.strip and where.pane }
  local _, layout_kind = Walk.layout(state)
  if where and where.strip == "chooser" then
    entry.kind, entry.deadline = "nv", util.time() + S.constants.GRID_HOLD.chooser_seconds
  elseif where and where.strip == "fill" then
    entry.fill = true
  elseif where and not where.strip then
    local page, side = core.page(WALK.port, where.pane), core.side(WALK.port, where.pane)
    if layout_kind == "64" and model.chooser then
      entry.consumed = true  -- a chooser key: consumed, its release does nothing
    elseif page == S.constants.GRID_PAGES.patterns then
      Walk.press_patterns(state, entry, where, side)
    elseif page == S.constants.GRID_PAGES.voices and side == 2 then
      Walk.press_perform(state, entry, where)
    elseif page == S.constants.GRID_PAGES.positions and side == 2 and where.x == WALK.hold_mark
        and voice_uses_buffer(where.y) then
      entry.hd = where.y
    end
  end
  model.entries[name] = entry
  state.context.grid.press(WALK.port, px, py, 1)
  -- the press's own still, which compare holds against the model's `gone`
  entry.still = core.still(WALK.port, px, py)
  Walk.run_expected(state)
end

-- A release's model: a held step toggles, a held cell taps (a value
-- cleared, or one given: an off step of a following A or B on), the
-- editor's key closes the editor, a roll's key ends its roll
function Walk.release_model(state, entry)
  local S, model = state.S, state.model
  if entry.kind == "step" and not entry.consumed and not entry.dropped then
    local pattern = model.patterns[entry.voice]
    if pattern[entry.step] ~= 0 then state.toggled_off[entry.voice] = true end
    pattern[entry.step] = pattern[entry.step] == 0 and S.constants.MAX_STEP_LEVEL or 0
    state.counts.step_toggled = state.counts.step_toggled + 1
  elseif entry.kind == "cell" and not entry.consumed and not entry.dropped then
    state.counts.cell_tap = state.counts.cell_tap + 1
    if S.lib.sequencer.step_attr(entry.voice, entry.index, S.lib.lanes.STEP_KEYS[entry.lane]) == nil then
      Walk.value_set(state, entry.voice, entry.lane, entry.index)
    end
  end
  if entry.kind == "nv" then model.chooser = false end
  model.entries[entry.name] = nil
  entry.gone = true
  if model.editor == entry then Model.close_editor(state) end
  if entry.roll and model.rolls[entry.voice] == entry then
    model.rolls[entry.voice] = nil
  elseif entry.roll and Model.live(model, model.rolls[entry.voice]) then
    state.counts.roll_earlier_released = state.counts.roll_earlier_released + 1
  end
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
  local loop_voice, loop_live
  state.expect = {}
  -- every latched loop, which no key's release ends
  local latched = {}
  for voice = 1, S.constants.NUM_VOICES do
    if S.lib.loop_roll.latched(voice) then latched[voice] = { S.lib.loop_roll.loop(voice) } end
  end
  if entry then
    if layout_kind == "64" and entry.pane and model.chooser then
      state.counts.release_under_chooser = state.counts.release_under_chooser + 1
    end
    if model.loops[entry.voice] == entry and not entry.gone then
      model.loops[entry.voice] = nil
      if not S.lib.loop_roll.latched(entry.voice) then
        loop_voice, loop_live = entry.voice, S.lib.loop_roll.loop(entry.voice) ~= nil
      end
    end
    -- a lane cell's value: a tap clears it, or gives an empty one the
    -- port's last value for the lane (else its first); a cell its second
    -- key consumed, or its pane's change ended, keeps it
    if entry.kind == "cell" then
      local before = S.lib.sequencer.step_attr(entry.voice, entry.index, S.lib.lanes.STEP_KEYS[entry.lane])
      local predicted = before ~= nil and { exact = before } or nil
      if not entry.consumed and not entry.dropped then
        predicted = before == nil and Walk.tap_value(state, entry.voice, entry.lane) or nil
      end
      Walk.expect_value(state, entry.voice, entry.index, entry.lane, predicted, "its cell key's release")
    end
    Walk.release_model(state, entry)
  end
  state.context.grid.press(WALK.port, finger.px, finger.py, 0)
  if core.hold_pending(WALK.port, finger.px, finger.py) then
    state.problems[#state.problems + 1] = "key " .. name .. ": released and its hold still waits"
  end
  Walk.run_expected(state)
  for voice, bounds in pairs(latched) do
    local lo, hi = S.lib.loop_roll.loop(voice)
    if lo ~= bounds[1] or hi ~= bounds[2] or not S.lib.loop_roll.latched(voice) then
      state.problems[#state.problems + 1] = "voice " .. voice .. ": its latched loop " .. tostring(bounds[1]) .. " to "
        .. tostring(bounds[2]) .. " is " .. tostring(lo) .. " to " .. tostring(hi) .. " after key " .. name .. "'s release"
    elseif entry and entry.made_loop == voice then
      state.counts.latched_loop_released = state.counts.latched_loop_released + 1
    end
  end
  if loop_voice then
    if entry.switched and loop_live then
      state.counts.loop_released_after_switch = state.counts.loop_released_after_switch + 1
    end
    if S.lib.loop_roll.loop(loop_voice) and not S.lib.loop_roll.latched(loop_voice) then
      state.problems[#state.problems + 1] = "voice " .. loop_voice .. ": its unlatched loop outlived its key " .. name
    end
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
    events[#events + 1] = { time = replace.time, voice = replace.voice, switched = replace.switched,
      order = -1000000 + index }
  end
  table.sort(events, function(a, b)
    if a.time ~= b.time then return a.time < b.time end
    return a.order < b.order
  end)
  -- the events in groups, each event closer than tie_window to the one
  -- before it in the same group (a group of one is in no doubt)
  local groups = {}
  for index, event in ipairs(events) do
    if index == 1 or event.time - events[index - 1].time >= WALK.tie_window then groups[#groups + 1] = {} end
    local group = groups[#groups]
    group[#group + 1] = event
  end
  -- `possible`, while a tie leaves the editor's key to the code: the keys
  -- (entries, or false for none) the editor may be open for, each once,
  -- over every order of the group's events. A held step whose hold is due
  -- (its gesture standing as the group starts) may be the last to open
  -- it, unless its gesture ended; the editor from before stays only when
  -- every due hold's gesture may end before it fires; none is a result
  -- only when an event of the group ends the gesture of a key the editor
  -- may be open for (a replacement, NV's hold). nil: no doubt. In doubt,
  -- the step view's ends wait for compare's choice (Model.open_editor)
  local possible, editor_before = nil, model.editor
  state.clock_editor, state.clock_view = model.editor, Walk.view(state)
  for _, group in ipairs(groups) do
    local due = {}
    for _, event in ipairs(group) do
      if event.entry and event.entry.kind == "step" and event.entry.deadline and not event.entry.dropped then
        due[#due + 1] = event.entry
      end
    end
    state.doubt = #group > 1 or possible ~= nil
    for _, event in ipairs(group) do
      if event.voice then
        Model.replaced(state, event.voice, event.switched)
      elseif event.entry.deadline then
        local entry = event.entry
        entry.deadline = nil
        state.counts.hold_fired = state.counts.hold_fired + 1
        if entry.kind == "step" and not entry.dropped then
          entry.consumed, entry.fired = true, true
          Model.open_editor(state, entry)
        elseif entry.kind == "nv" then
          model.chooser = true
          Model.end_pane(state, 1)
        end
      end
    end
    state.doubt = false
    -- a tie, or any group after one (a group of one in no doubt narrows
    -- the set by the same rule)
    if #group > 1 or possible then
      if #group > 1 then state.counts.tied = state.counts.tied + 1 end
      local before = possible or { editor_before or false }
      local next_possible = {}
      local function add(entry)
        for _, known in ipairs(next_possible) do
          if known == entry then return end
        end
        next_possible[#next_possible + 1] = entry
      end
      local every_due_ended, some_ended = true, false
      for _, entry in ipairs(due) do
        if entry.dropped then some_ended = true else every_due_ended = false; add(entry) end
      end
      for _, entry in ipairs(before) do
        if entry and entry.dropped then
          some_ended = true
        elseif every_due_ended then
          add(entry)
        end
      end
      if some_ended then add(false) end
      possible = next_possible
    end
    editor_before = model.editor
  end
  state.possible = possible
  Walk.read_replaced(state)
end

-- After a tie, the editor the code opened is known (compare): the step
-- view's ends the tie left waiting run as that key's open (or the first
-- editor's close) would have run them
function Walk.settle_view(state)
  if not state.view_deferred then return end
  state.view_deferred = false
  local model = state.model
  if model.editor == state.clock_editor then return end
  if state.clock_view then Model.end_pane(state, state.clock_view.pane, state.clock_editor) end
  Model.view_started(state)
end

-- The comparisons ------------------------------------------------------

-- The engine's last seqGate per voice, read on from the calls the stub
-- logged since the last read
function Walk.read_gates(state)
  local calls = state.context.engine_calls
  if #calls < state.calls_read then state.calls_read = 0 end
  for index = state.calls_read + 1, #calls do
    local call = calls[index]
    if call.name == "setGrainParam" and call.args[2] == "seqGate" then state.last_gate[call.args[1] + 1] = call.args[3] end
  end
  state.calls_read = #calls
end

-- What the model and the call log say beside the patterns and the keys:
-- the picked voice, LN on each pane, the step view, each voice's roll and
-- loop, and a running voice's last seqGate against the gate rule (ruling
-- 1b-2); a pulse voice whose gate opened at its last step's tap is counted
function Walk.compare_sides(state)
  local S, model, core, problems = state.S, state.model, state.core, state.problems
  local patterns_page = S.lib.grid_pages_patterns
  if patterns_page.voice(WALK.port) ~= model.picked then
    problems[#problems + 1] = "the picked voice: " .. patterns_page.voice(WALK.port) .. ", the model's " .. model.picked
  end
  local layout = Walk.layout(state)
  for pane = 1, layout and layout.panes or 0 do
    local armed = model.ln ~= nil and model.ln.pane == pane
    if patterns_page.ln_armed(WALK.port, pane) ~= armed then
      problems[#problems + 1] = "LN on pane " .. pane .. ": " .. tostring(not armed) .. ", the model's " .. tostring(armed)
    end
  end
  local view, shown = Walk.view(state), core.step_view(WALK.port)
  local expected_view = view and (view.voice .. " " .. view.step .. " pane " .. view.pane) or "none"
  local shown_view = shown and (shown.voice .. " " .. shown.step .. " pane " .. shown.pane) or "none"
  if expected_view ~= shown_view then
    problems[#problems + 1] = "step view: expected " .. expected_view .. ", shown " .. shown_view
  end
  local roll = S.lib.loop_roll
  for voice = 1, S.constants.NUM_VOICES do
    if not S.pattern_playing then model.rolls[voice] = nil end  -- a stop ends every roll
    local holder = model.rolls[voice]
    local rate = Model.live(model, holder) and holder.roll or nil
    if roll.rolling(voice) ~= rate then
      problems[#problems + 1] = "voice " .. voice .. " rolls at " .. tostring(roll.rolling(voice)) .. ", the model's "
        .. tostring(rate)
    end
    local looper = model.loops[voice]
    if looper and (roll.latched(voice) or not Model.live(model, looper)) then
      model.loops[voice] = nil
      if roll.loop(voice) and not roll.latched(voice) then
        problems[#problems + 1] = "voice " .. voice .. ": its unlatched loop outlived its key's press"
      end
    end
  end
  Walk.read_gates(state)
  local seq = S.lib.sequencer
  for voice = 1, S.constants.NUM_VOICES do
    local wanted = seq.gate_wanted(voice)
    if S.voices[voice].active then
      if state.last_gate[voice] ~= wanted then
        problems[#problems + 1] = "voice " .. voice .. ": the engine's last seqGate " .. tostring(state.last_gate[voice])
          .. ", the rule's " .. wanted
      end
      if state.toggled_off[voice] and state.wanted[voice] == 1 and wanted == 0 and seq.step_mode(voice) == "pulse"
          and S.pattern_playing and not seq.has_set_step(voice) then
        state.counts.pulse_opened = state.counts.pulse_opened + 1
      end
    end
    state.wanted[voice] = wanted
  end
end

function Walk.compare(state)
  local S, model, core, problems = state.S, state.model, state.core, state.problems
  -- the open editor: two timed events within tie_window leave its key to
  -- the code, among the keys Walk.clock found possible (none, only where
  -- the tie could close it); the model then follows the one that opened
  local editor = S.lib.pages_seq.step_editor()
  local possible = state.possible
  state.possible = nil
  if possible then
    local found, names = nil, {}
    for _, entry in ipairs(possible) do
      names[#names + 1] = entry and (entry.voice .. " " .. entry.step) or "none"
      if entry == false and editor == nil then found = false end
      if entry and editor and entry.voice == editor.voice and entry.step == editor.step then found = entry end
    end
    if found == nil then
      problems[#problems + 1] = "step editor: after a tie, open " .. (editor and (editor.voice .. " " .. editor.step)
        or "none") .. ", not one of " .. table.concat(names, ", ")
    else
      model.editor = found or nil
    end
  end
  Walk.settle_view(state)
  -- each held key's press: ended (the core's still false) exactly where
  -- the model's `gone` says (a pane's end, the step view's start or end)
  for name, entry in pairs(model.entries) do
    if entry.still and entry.still() == (entry.gone == true) then
      problems[#problems + 1] = "key " .. name .. ": its press's still is " .. tostring(entry.still())
        .. ", the model's press " .. (entry.gone and "ended" or "standing")
    elseif entry.gone then
      state.counts.press_ended = state.counts.press_ended + 1
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
  Walk.compare_sides(state)
end

-- The ops ---------------------------------------------------------------

local OPS = {}

-- Whether the core holds any key of the port: a row with a press time
-- (S.grid_held keeps a column its keys' releases emptied)
function Walk.any_held(state)
  for _, rows in pairs(state.S.grid_held[WALK.port] or {}) do
    if next(rows) ~= nil then return true end
  end
  return false
end

-- Unplugged, a key down plugs the grid back first (an unplugged grid
-- stays out only for the ops before the next press)
function Walk.plug(state)
  Model.forget(state)
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
  -- one release in favored_share lets go a loop's key whose voice a
  -- letter's switch replaced since (its loop must end with it)
  if random(WALK.favored_share) == 1 then
    for _, name in ipairs(down) do
      local entry = state.model.entries[name]
      if entry and entry.switched and state.model.loops[entry.voice] == entry then
        Walk.release(state, name)
        return
      end
    end
  end
  Walk.release(state, down[random(#down)])
end }

OPS.clock = { 5, "clock", function(state, random)
  local span = WALK.clock_max - WALK.clock_min
  Walk.clock(state, WALK.clock_min + span * (random(1000) - 1) / 999)
end }

-- Unplugged, a page change still reaches the port (set_page takes a port
-- with no grid, on pane 1), and the plug that follows starts the grid
-- over on its start pages
OPS.page = { 2, "page", function(state, random)
  local layout, layout_kind = Walk.layout(state)
  if layout == nil then
    state.counts.page_unplugged = state.counts.page_unplugged + 1
    layout_kind = state.layout
  end
  local S = state.S
  local pane = random(layout and layout.panes or 1)
  local pick = random(WALK.patterns_share)
  local page = (pick == 1 and S.constants.GRID_PAGES.patterns) or (pick == 2 and S.constants.GRID_PAGES.positions)
    or (pick == 3 and S.constants.GRID_PAGES.voices) or random(S.constants.GRID_PAGES.count)
  local record = S.registry.grid_pages[page]
  local side = random(record and record.sides or 1)
  state.core.set_page(WALK.port, page, pane, side)
  if layout_kind == "64" and random(2) == 1 then state.core.set_half(WALK.port, pane, random(2)) end
  grid_redraw()
end }

-- K2 while the step editor is open: the editor (and its step view) closes,
-- its key still down (its release then closes and toggles nothing)
OPS.k2 = { 1, "K2", function(state)
  if state.S.lib.pages_seq.step_editor() == nil then return end
  local handler = state.context.menu.key or rawget(_G, "key")
  Model.close_editor(state)
  handler(2, 1)
  handler(2, 0)
  state.counts.k2_closed = state.counts.k2_closed + 1
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
    if Walk.any_held(state) then state.counts.unplug_with_key_held = state.counts.unplug_with_key_held + 1 end
    Model.forget(state)
    state.context.grid.unplug(WALK.port)
  else
    Walk.plug(state)
  end
end }

-- Unplugged, a rotation is written and kept, and the plug that follows
-- turns the grid to it
OPS.rotation = { 1, "rotation", function(state, random)
  if Walk.device(state) == nil then state.counts.rotation_unplugged = state.counts.rotation_unplugged + 1 end
  local rotation = random(state.core.MAX_ROTATION + 1) - 1
  if rotation ~= state.core.rotation(WALK.port) then Model.forget(state) end
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

-- The rework's sides, pressed on purpose (a random key reaches them too
-- seldom): a pane shows patterns' side 2 or the perform side (shown first
-- when it shows neither), then one of its keys, the keys whose gestures
-- the model follows favored. Each press is the walk's own key down
local SIDE_KEYS = {
  -- patterns' side 2: {weight, x, y} (x or y a kind: drawn); the view's
  -- bars (lines 1-6) while it shows there
  lanes = { { 4, nil, 1 }, { 3, nil, "lane" }, { 2, UTILITY.ln_x, UTILITY.line }, { 1, UTILITY.b_x, UTILITY.line },
    { 1, "target", UTILITY.line }, { 1, "voice", UTILITY.line }, { 1, "mode", UTILITY.line } },
  -- the perform side: the letters, OR, the rolls, FL, LP, the modes, MU/SO
  perform = { { 3, "letter" }, { 2, PERFORM_KEYS.order }, { 3, "roll" }, { 1, PERFORM_KEYS.fill },
    { 1, PERFORM_KEYS.latch }, { 1, "mode" }, { 1, "mute" } },
}

function Walk.weighted(list, random)
  local total = 0
  for _, item in ipairs(list) do total = total + item[1] end
  local pick = random(total)
  for _, item in ipairs(list) do
    pick = pick - item[1]
    if pick <= 0 then return item end
  end
end

-- The physical key of pane key (x, y), a 64's other half shown first when
-- the key is off the half shown
function Walk.shown_key(state, pane, x, y)
  local layout, kind = Walk.layout(state)
  local px, py = state.S.lib.grid_pane.physical(layout, pane, x, y, Walk.half(state, pane))
  if px == nil and kind == "64" then
    state.core.set_half(WALK.port, pane, 3 - Walk.half(state, pane))
    px, py = state.S.lib.grid_pane.physical(layout, pane, x, y, Walk.half(state, pane))
  end
  return px, py
end

-- A key of a new side, drawn (Walk.press then models it)
function Walk.side_key_place(state, random, page, pane)
  local S = state.S
  if page == S.constants.GRID_PAGES.voices then
    local x = Walk.weighted(SIDE_KEYS.perform, random)[2]
    if x == "letter" then x = PERFORM_KEYS.first_letter - 1 + random(#S.lib.pattern_letters.LETTERS)
    elseif x == "roll" then x = PERFORM_KEYS.first_roll - 1 + random(PERFORM_KEYS.rolls)
    elseif x == "mode" then x = PERFORM_KEYS.first_mode - 1 + random(#UTILITY.modes)
    elseif x == "mute" then x = random(2) == 1 and PERFORM_KEYS.mute or PERFORM_KEYS.solo end
    return x, random(S.constants.NUM_VOICES)
  end
  local view = Walk.view(state)
  if view and view.pane == pane then return random(S.lib.grid_pane.LINE_KEYS), random(#LANE_LINES) end
  local item = Walk.weighted(SIDE_KEYS.lanes, random)
  local x, y = item[2], item[3]
  if y == "lane" then y = 1 + random(#LANE_LINES - 1) end
  if x == nil then x = random(S.lib.grid_pane.LINE_KEYS)
  elseif x == "target" then x = UTILITY.first_target_x - 1 + random(UTILITY.targets)
  elseif x == "voice" then x = UTILITY.first_voice_x - 1 + random(S.constants.NUM_VOICES)
  elseif x == "mode" then x = random(#UTILITY.modes) end
  return x, y
end

OPS.side_key = { 4, "a new side's key", function(state, random)
  local layout = Walk.layout(state)
  if layout == nil or state.model.chooser then return end
  local S, core = state.S, state.core
  local pages = S.constants.GRID_PAGES
  local pane = random(layout.panes)
  local page, side = core.page(WALK.port, pane), core.side(WALK.port, pane)
  if side ~= 2 or (page ~= pages.patterns and page ~= pages.voices) then
    page = random(2) == 1 and pages.patterns or pages.voices
    core.set_page(WALK.port, page, pane, 2)
    Walk.settle(state)
    Walk.before(state)
  end
  local x, y = Walk.side_key_place(state, random, page, pane)
  -- LN armed here: one lane key in two at the lane's length (it follows
  -- again)
  local lane = page == pages.patterns and LANE_LINES[y]
  if lane and lane ~= "hits" and state.model.ln and state.model.ln.pane == pane and random(2) == 1 then
    x = S.lib.lanes.length(state.model.picked, lane) or x
  end
  local px, py = Walk.shown_key(state, pane, x, y)
  -- (a 64's half change ends the pane's keys before the press)
  Walk.settle(state)
  Walk.before(state)
  if px == nil or state.fingers[key_name(px, py)] then return end
  Walk.press(state, px, py)
  local entry = state.model.entries[key_name(px, py)]
  local how = random(3)
  if entry and (entry.kind == "cell" or entry.kind == "step" or page == pages.voices) and how == 1 then
    Walk.release(state, key_name(px, py))  -- a tap
  elseif entry and (entry.kind == "cell" or entry.kind == "step") and how == 2 then
    -- a second key of its line at once (before the hold), let go
    local offset, width = Walk.geometry(state, pane)
    local sx, sy = S.lib.grid_pane.physical(layout, pane, offset + random(width), y, Walk.half(state, pane))
    if sx and not state.fingers[key_name(sx, sy)] then
      Walk.press(state, sx, sy)
      Walk.release(state, key_name(sx, sy))
    end
    -- a cell's: both let go, then another cell of the line tapped (an
    -- empty one takes the value the second key set)
    if entry.kind == "cell" then
      Walk.release(state, key_name(px, py))
      local tx, ty = S.lib.grid_pane.physical(layout, pane, offset + random(width), y, Walk.half(state, pane))
      if tx and not state.fingers[key_name(tx, ty)] then
        Walk.press(state, tx, ty)
        Walk.release(state, key_name(tx, ty))
      end
    end
  elseif entry and entry.b then
    -- B held, then a target (not shown with B on a 64's half), B left down
    local target_x = UTILITY.first_target_x - 1 + random(UTILITY.targets)
    local tx, ty = S.lib.grid_pane.physical(layout, pane, target_x, UTILITY.line, Walk.half(state, pane))
    if tx and not state.fingers[key_name(tx, ty)] then
      Walk.press(state, tx, ty)
      Walk.release(state, key_name(tx, ty))
    end
  end
end }

-- LN on purpose: the lane side shown, LN tapped (armed), then one of: a
-- lane's key (spent: at a lane's length one time in two, which then
-- follows again, else anywhere on a lane's line), a side change (LN
-- disarms), a 64's half change (LN stays armed), or nothing
OPS.ln = { 1, "LN", function(state, random)
  local layout, kind = Walk.layout(state)
  if layout == nil or state.model.chooser then return end
  local S, core = state.S, state.core
  local pane = random(layout.panes)
  if core.page(WALK.port, pane) ~= S.constants.GRID_PAGES.patterns or core.side(WALK.port, pane) ~= 2 then
    core.set_page(WALK.port, S.constants.GRID_PAGES.patterns, pane, 2)
  end
  local px, py = Walk.shown_key(state, pane, UTILITY.ln_x, UTILITY.line)
  Walk.settle(state)
  Walk.before(state)
  if px == nil or state.fingers[key_name(px, py)] or Walk.view(state) then return end
  if state.model.ln and state.model.ln.pane == pane then  -- armed already: the tap disarms, then arms again
    Walk.press(state, px, py)
    Walk.release(state, key_name(px, py))
  end
  Walk.press(state, px, py)
  Walk.release(state, key_name(px, py))
  local how = random(4)
  if how == 1 then
    local offset, width = Walk.geometry(state, pane)
    local line, at = 1 + random(#LANE_LINES - 1), nil
    if random(2) == 1 then
      for lane_line = 2, #LANE_LINES do
        local length = S.lib.lanes.length(state.model.picked, LANE_LINES[lane_line])
        if length and length > offset and length <= offset + width then line, at = lane_line, length end
      end
    end
    local lx, ly = S.lib.grid_pane.physical(layout, pane, at or offset + random(width), line, Walk.half(state, pane))
    if lx and not state.fingers[key_name(lx, ly)] then
      Walk.press(state, lx, ly)
      Walk.release(state, key_name(lx, ly))
    end
  elseif how == 2 then
    core.set_page(WALK.port, S.constants.GRID_PAGES.patterns, pane, 1)
  elseif how == 3 and kind == "64" then
    core.set_half(WALK.port, pane, 3 - Walk.half(state, pane))
  end
end }

-- A second key: another key of a held step's or a held cell's line, on
-- the held key's pane (a loop on side 1, a level or a value on side 2)
OPS.second = { 2, "second key", function(state, random)
  local held = {}
  for _, entry in pairs(state.model.entries) do
    if (entry.kind == "step" or entry.kind == "cell") and not entry.dropped and entry.pane then held[#held + 1] = entry end
  end
  if #held == 0 then return end
  table.sort(held, function(a, b) return a.order < b.order end)
  local entry = held[random(#held)]
  local where = Walk.locate(state, entry.px, entry.py)
  if where == nil then return end
  local offset, width = Walk.geometry(state, where.pane)
  local x = offset + random(width)
  if x == where.x then return end
  local px, py = state.S.lib.grid_pane.physical(Walk.layout(state), where.pane, x, where.y, Walk.half(state, where.pane))
  if px and not state.fingers[key_name(px, py)] then Walk.press(state, px, py) end
end }

-- The play key tapped (the 64's NV, let go before its hold): the patterns
-- start, or stop one time in stop_share (the bars, rolls and waits want
-- them playing)
OPS.play = { 1, "play", function(state, random)
  local layout = Walk.layout(state)
  if layout == nil or state.model.chooser then return end
  if state.S.pattern_playing and random(WALK.stop_share) ~= 1 then return end
  local px, py = state.S.lib.grid_pane.physical(layout, 1, 1, state.S.constants.NUM_VOICES + 1, 1)
  local name = key_name(px, py)
  if state.fingers[name] then return end
  Walk.press(state, px, py)
  Walk.release(state, name)
end }

-- A set step of the voice with the fewest (its first inside its length)
-- tapped on a pane showing patterns' side 1: a pulse voice's last step's
-- clearing opens its gate
OPS.tap_fewest = { 1, "tap a sparse voice's step", function(state, random)
  local layout = Walk.layout(state)
  if layout == nil or state.model.chooser then return end
  local S, core = state.S, state.core
  local pane
  for index = 1, layout.panes do
    if not pane and core.page(WALK.port, index) == S.constants.GRID_PAGES.patterns and core.side(WALK.port, index) == 1 then
      pane = index
    end
  end
  if pane == nil then
    pane = random(layout.panes)
    core.set_page(WALK.port, S.constants.GRID_PAGES.patterns, pane, 1)
  end
  -- the running voice with the fewest set steps (any voice while none runs)
  local best, best_count, best_step, best_active
  for voice = 1, S.constants.NUM_VOICES do
    local count, first = 0, nil
    for step = 1, params:get("v" .. voice .. "_seq_length") do
      if S.patterns[voice][step] > 0 then count, first = count + 1, first or step end
    end
    local active = S.voices[voice].active == true
    local better = best_count == nil or (active and not best_active) or (active == best_active and count < best_count)
    if count > 0 and better then best, best_count, best_step, best_active = voice, count, first, active end
  end
  if best == nil then return end
  local px, py = Walk.shown_key(state, pane, best_step, best)
  Walk.settle(state)
  Walk.before(state)
  if px == nil or state.fingers[key_name(px, py)] then return end
  Walk.press(state, px, py)
  Walk.release(state, key_name(px, py))
end }

-- The step view on purpose: a hits key of the lane side held past its
-- hold (the view opens on its pane), a bar key pressed and let go, then
-- the key let go, K2, or the key left down
OPS.view = { 1, "a step view", function(state, random)
  local layout = Walk.layout(state)
  if layout == nil or state.model.chooser then return end
  local S, core = state.S, state.core
  local pane = random(layout.panes)
  if core.page(WALK.port, pane) ~= S.constants.GRID_PAGES.patterns or core.side(WALK.port, pane) ~= 2 then
    core.set_page(WALK.port, S.constants.GRID_PAGES.patterns, pane, 2)
  end
  local offset, width = Walk.geometry(state, pane)
  local px, py = Walk.shown_key(state, pane, offset + random(width), 1)
  Walk.settle(state)
  Walk.before(state)
  if px == nil or state.fingers[key_name(px, py)] or Walk.view(state) then return end
  Walk.press(state, px, py)
  Walk.clock(state, S.constants.GRID_HOLD.step_edit_seconds + WALK.clock_min)
  Walk.compare(state)  -- (the hold's tie, if any, settled)
  local view = Walk.view(state)
  if view then
    local view_offset, view_width = Walk.geometry(state, view.pane)
    local bx, by = S.lib.grid_pane.physical(layout, view.pane, view_offset + random(view_width), random(#LANE_LINES),
      Walk.half(state, view.pane))
    if bx and not state.fingers[key_name(bx, by)] then
      Walk.press(state, bx, by)
      Walk.release(state, key_name(bx, by))
    end
  end
  local how = random(3)
  if how == 1 and state.fingers[key_name(px, py)] then
    Walk.release(state, key_name(px, py))
  elseif how == 2 then
    OPS.k2[3](state)
  end
end }

-- Two roll keys of one voice on the perform side (the patterns playing):
-- both down, the later's roll replacing the earlier's, then one let go,
-- either first (the other stays down)
OPS.two_rolls = { 0.5, "two roll keys", function(state, random)
  local layout = Walk.layout(state)
  if layout == nil or state.model.chooser or not state.S.pattern_playing then return end
  local S, core = state.S, state.core
  local pane, voice = random(layout.panes), random(S.constants.NUM_VOICES)
  if core.page(WALK.port, pane) ~= S.constants.GRID_PAGES.voices or core.side(WALK.port, pane) ~= 2 then
    core.set_page(WALK.port, S.constants.GRID_PAGES.voices, pane, 2)
  end
  local first = PERFORM_KEYS.first_roll - 1 + random(PERFORM_KEYS.rolls)
  local second = PERFORM_KEYS.first_roll - 1 + random(PERFORM_KEYS.rolls)
  local ax, ay = Walk.shown_key(state, pane, first, voice)
  local bx, by = S.lib.grid_pane.physical(layout, pane, second, voice, Walk.half(state, pane))
  Walk.settle(state)
  Walk.before(state)
  if first == second or ax == nil or bx == nil or state.fingers[key_name(ax, ay)] or state.fingers[key_name(bx, by)] then
    return
  end
  Walk.press(state, ax, ay)
  Walk.press(state, bx, by)
  if random(2) == 1 then Walk.release(state, key_name(ax, ay)) else Walk.release(state, key_name(bx, by)) end
end }

-- A loop made on patterns' side 1: a step held, a second key of its line
-- pressed and let go, the held key left down (a voice whose order is on,
-- or whose letter waits, first: its bar's switch replaces the pattern
-- under the loop's key)
OPS.loop = { 1, "a loop", function(state, random)
  local layout = Walk.layout(state)
  if layout == nil or state.model.chooser then return end
  local S, core = state.S, state.core
  local pane = random(layout.panes)
  local voice = random(S.constants.NUM_VOICES)
  for candidate = 1, S.constants.NUM_VOICES do
    if select(2, S.lib.pattern_letters.order(candidate)) or S.lib.pattern_letters.waiting(candidate) then voice = candidate end
  end
  -- how the loop goes on (when its voice will not switch at the bar): 1,
  -- the latch armed first (LP on the perform side), so the loop is
  -- latched at once and its key let go (it stays); 2, on a 256, LP on the
  -- other pane latches the held loop and one time in two its key goes; 3,
  -- the key left down; 4, with the patterns playing, a letter of the
  -- voice tapped first on the perform side (it waits for the bar)
  local how = random(4)
  if how == 4 and S.pattern_playing then
    core.set_page(WALK.port, S.constants.GRID_PAGES.voices, pane, 2)
    local letter_x = PERFORM_KEYS.first_letter - 1 + random(#S.lib.pattern_letters.LETTERS)
    local tx, ty = Walk.shown_key(state, pane, letter_x, voice)
    Walk.settle(state)
    Walk.before(state)
    if tx and not state.fingers[key_name(tx, ty)] then
      Walk.press(state, tx, ty)
      Walk.release(state, key_name(tx, ty))
    end
  end
  if how == 1 and not S.lib.loop_roll.loop(voice) and not S.lib.loop_roll.armed(voice) then
    core.set_page(WALK.port, S.constants.GRID_PAGES.voices, pane, 2)
    local lx, ly = Walk.shown_key(state, pane, PERFORM_KEYS.latch, voice)
    Walk.settle(state)
    Walk.before(state)
    if lx and not state.fingers[key_name(lx, ly)] then
      Walk.press(state, lx, ly)
      Walk.release(state, key_name(lx, ly))
    end
  end
  if core.page(WALK.port, pane) ~= S.constants.GRID_PAGES.patterns or core.side(WALK.port, pane) ~= 1 then
    core.set_page(WALK.port, S.constants.GRID_PAGES.patterns, pane, 1)
  end
  local offset, width = Walk.geometry(state, pane)
  local first, second = offset + random(width), offset + random(width)
  local px, py = Walk.shown_key(state, pane, first, voice)
  local sx, sy = S.lib.grid_pane.physical(layout, pane, second, voice, Walk.half(state, pane))
  Walk.settle(state)
  Walk.before(state)
  if first == second or px == nil or sx == nil or state.fingers[key_name(px, py)] or state.fingers[key_name(sx, sy)] then
    return
  end
  Walk.press(state, px, py)
  Walk.press(state, sx, sy)
  Walk.release(state, key_name(sx, sy))
  -- a voice that will switch at the bar: the held key across a bar, then
  -- let go (its loop ends with it)
  local letters = S.lib.pattern_letters
  if S.pattern_playing and (select(2, letters.order(voice)) or letters.waiting(voice)) then
    Walk.clock(state, WALK.bar_seconds)
    if state.fingers[key_name(px, py)] then Walk.release(state, key_name(px, py)) end
  elseif how == 1 and S.lib.loop_roll.latched(voice) then
    Walk.release(state, key_name(px, py))  -- a latched loop's key let go: the loop stays
  elseif how == 2 and layout.panes == 2 then
    local other = 3 - pane
    if core.page(WALK.port, other) ~= S.constants.GRID_PAGES.voices or core.side(WALK.port, other) ~= 2 then
      core.set_page(WALK.port, S.constants.GRID_PAGES.voices, other, 2)
    end
    Walk.settle(state)
    Walk.before(state)
    local lx, ly = S.lib.grid_pane.physical(layout, other, PERFORM_KEYS.latch, voice, 1)
    if lx and not state.fingers[key_name(lx, ly)] then
      Walk.press(state, lx, ly)
      Walk.release(state, key_name(lx, ly))
    end
    if random(2) == 1 and state.fingers[key_name(px, py)] then Walk.release(state, key_name(px, py)) end
  end
end }

-- A positions HD key pressed (side 2 shown first), held a moment and let
-- go: a buffer voice's scan held until its release
OPS.hd = { 0.5, "an HD key", function(state, random)
  local layout = Walk.layout(state)
  if layout == nil or state.model.chooser then return end
  local S, core = state.S, state.core
  local pane = random(layout.panes)
  if core.page(WALK.port, pane) ~= S.constants.GRID_PAGES.positions or core.side(WALK.port, pane) ~= 2 then
    core.set_page(WALK.port, S.constants.GRID_PAGES.positions, pane, 2)
  end
  local px, py = Walk.shown_key(state, pane, WALK.hold_mark, random(WALK.buffer_voices))
  Walk.settle(state)
  Walk.before(state)
  if px == nil or state.fingers[key_name(px, py)] then return end
  Walk.press(state, px, py)
  Walk.clock(state, WALK.clock_min)
  Walk.release(state, key_name(px, py))
end }

-- An order built on the perform side: OR held, one to three letters
-- tapped, OR let go (the order on, from its first letter at the next bar)
OPS.order = { 1, "an order", function(state, random)
  local layout = Walk.layout(state)
  if layout == nil or state.model.chooser then return end
  local S, core = state.S, state.core
  local pane, voice = random(layout.panes), random(S.constants.NUM_VOICES)
  if core.page(WALK.port, pane) ~= S.constants.GRID_PAGES.voices or core.side(WALK.port, pane) ~= 2 then
    core.set_page(WALK.port, S.constants.GRID_PAGES.voices, pane, 2)
  end
  local px, py = Walk.shown_key(state, pane, PERFORM_KEYS.order, voice)
  Walk.settle(state)
  Walk.before(state)
  if px == nil or state.fingers[key_name(px, py)] then return end
  Walk.press(state, px, py)
  for _ = 1, random(WALK.order_letters) do
    local lx, ly = S.lib.grid_pane.physical(layout, pane, PERFORM_KEYS.first_letter - 1 + random(#S.lib.pattern_letters.LETTERS), voice,
      Walk.half(state, pane))
    if lx and not state.fingers[key_name(lx, ly)] then
      Walk.press(state, lx, ly)
      Walk.release(state, key_name(lx, ly))
    end
  end
  Walk.release(state, key_name(px, py))
end }

local function ops_for(layout)
  local list = { OPS.key_down, OPS.key_up, OPS.clock, OPS.page, OPS.replace, OPS.plug, OPS.rotation, OPS.k2,
    OPS.side_key, OPS.second, OPS.play, OPS.tap_fewest, OPS.order, OPS.loop, OPS.hd, OPS.two_rolls, OPS.view, OPS.ln }
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

-- The end's LN check: LN on pane 1's lane side, armed (tapped if the walk
-- left it disarmed), and a page change and back disarms it (the grid
-- plugged first)
function Walk.ln_check(state, problems)
  local S, core = state.S, state.core
  if Walk.device(state) == nil then Walk.plug(state) end
  local layout = Walk.layout(state)
  core.set_page(WALK.port, S.constants.GRID_PAGES.patterns, 1, 2)
  core.set_half(WALK.port, 1, 1)
  local px, py = S.lib.grid_pane.physical(layout, 1, UTILITY.ln_x, UTILITY.line, 1)
  if not S.lib.grid_pages_patterns.ln_armed(WALK.port, 1) then
    state.context.grid.press(WALK.port, px, py, 1)
    state.context.grid.press(WALK.port, px, py, 0)
  end
  if not S.lib.grid_pages_patterns.ln_armed(WALK.port, 1) then problems[#problems + 1] = "LN: its tap did not arm it" end
  core.set_page(WALK.port, S.constants.GRID_PAGES.scenes, 1, 1)
  core.set_page(WALK.port, S.constants.GRID_PAGES.patterns, 1, 2)
  if S.lib.grid_pages_patterns.ln_armed(WALK.port, 1) then problems[#problems + 1] = "LN: armed after a page change" end
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
  local problems = state.problems
  -- with every key up, before any wait: no hold the core armed still lives
  -- (a hold never stopped would fire and clear itself during the wait)
  for _, hold in ipairs(state.hold_handles) do
    if S.lib.clocks.alive(hold.handle) then
      problems[#problems + 1] = "key " .. hold.key .. ": its hold clock lives with every key up"
    end
  end
  if S.lib.conditions.fill() then problems[#problems + 1] = "fill is held with every key up" end
  -- no step view, no roll and no unlatched loop with every key up
  if state.core.step_view(WALK.port) then problems[#problems + 1] = "a step view is shown with every key up" end
  for voice = 1, S.constants.NUM_VOICES do
    if S.lib.loop_roll.rolling(voice) then problems[#problems + 1] = "voice " .. voice .. " rolls with every key up" end
    if S.lib.loop_roll.loop(voice) and not S.lib.loop_roll.latched(voice) then
      problems[#problems + 1] = "voice " .. voice .. " has an unlatched loop with every key up"
    end
  end
  state.context.clock.run_for(WALK.finish_seconds)
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
  -- a second on, every dead roll's record is gone; a running voice's last
  -- seqGate is the rule's
  for voice in pairs(h.registered_invariant("roll").upvalue("ROLL").rolls) do
    problems[#problems + 1] = "voice " .. voice .. "'s roll lives a second after every key went up"
  end
  Walk.read_gates(state)
  for voice = 1, S.constants.NUM_VOICES do
    if S.voices[voice].active and state.last_gate[voice] ~= S.lib.sequencer.gate_wanted(voice) then
      problems[#problems + 1] = "voice " .. voice .. ": the engine's last seqGate " .. tostring(state.last_gate[voice])
        .. ", the rule's " .. S.lib.sequencer.gate_wanted(voice)
    end
  end
  Walk.ln_check(state, problems)
  if S.pattern_playing then pattern_clock_stop() end
  for voice = 1, S.constants.NUM_VOICES do
    if S.lib.pattern_letters.waiting(voice) then
      problems[#problems + 1] = "voice " .. voice .. ": a letter waits with the patterns stopped"
    end
  end
  return problems
end

local COUNTERS = { "hold_fired", "hold_ended_by_page", "release_under_chooser", "unplug_with_key_held",
  "step_toggled", "second_key", "fill_released", "hold_key_released", "page_unplugged", "rotation_unplugged",
  "tied", "lane_side_key", "perform_key", "hits_second", "cell_tap", "cell_second", "ln_armed", "ln_spent",
  "ln_disarmed_by_page", "view_opened", "view_other_pane_held", "view_bar", "k2_closed", "loop_made",
  "loop_released_after_switch", "roll_pressed", "roll_ended_by_page", "order_bar", "pulse_opened",
  "editor_without_view", "b_target", "latch_pressed", "latch_held", "latched_loop_released", "roll_replaced",
  "roll_earlier_released", "press_ended", "loop_end_after_replacement" }

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
    cols = pane.device.native_cols, rows = pane.device.native_rows, problems = {}, replaces = {}, counts = {},
    layout = layout, hold_handles = {}, calls_read = 0, last_gate = {}, wanted = {}, toggled_off = {} }
  for _, counter in ipairs(COUNTERS) do state.counts[counter] = 0 end
  for voice = 1, S.constants.NUM_VOICES do state.wanted[voice] = S.lib.sequencer.gate_wanted(voice) end
  -- every hold the core arms, kept (a pending hold's handle, read from the
  -- core's hold_clocks once on_hold returns) so the end can ask whether one
  -- still lives
  local on_hold = S.lib.grid_core.on_hold
  local hold_clocks = h.registered_invariant("grid keys").upvalue("hold_clocks")
  S.lib.grid_core.on_hold = function(port, x, y, seconds, fn)
    on_hold(port, x, y, seconds, fn)
    local handle = hold_clocks[port] and hold_clocks[port][x] and hold_clocks[port][x][y]
    if handle then state.hold_handles[#state.hold_handles + 1] = { handle = handle, key = key_name(x, y) } end
  end
  -- every whole-pattern change, observed and passed on: the model ends the
  -- voice's step keys and reads its pattern again. A letter's switch
  -- (replace_whole with the voice's playing letter changed) is marked, and
  -- counted as an order's bar when the voice's order is on
  local replace_pattern = S.lib.sequencer.replace_pattern
  local letters = {}
  for voice = 1, S.constants.NUM_VOICES do letters[voice] = S.lib.pattern_letters.current(voice) end
  S.lib.sequencer.replace_pattern = function(voice, steps)
    state.replaces[#state.replaces + 1] = { voice = voice, time = util.time(), switched = state.switching == voice }
    -- a recall sets the letters before its patterns: no switch of ours
    if state.switching ~= voice then letters[voice] = S.lib.pattern_letters.current(voice) end
    return replace_pattern(voice, steps)
  end
  local replace_whole = S.lib.sequencer.replace_whole
  S.lib.sequencer.replace_whole = function(voice, pattern)
    local letter = S.lib.pattern_letters.current(voice)
    if letter ~= letters[voice] then
      letters[voice] = letter
      if select(2, S.lib.pattern_letters.order(voice)) then state.counts.order_bar = state.counts.order_bar + 1 end
      state.switching = voice
    end
    local ok, problem = xpcall(replace_whole, debug.traceback, voice, pattern)
    state.switching = nil
    if not ok then error(problem, 0) end
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
-- second key after it sets nothing (3.9's 5a); a page change ends a held step;
-- the walk's comparisons find nothing wrong on the way. And the
-- comparison is no rubber stamp: a step set behind the model's back is
-- named
h.test("the grid walk's model: taps, the editor's hold, a second key and a page change, by hand", function()
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
  h.assert_equal(S.patterns[2][6], 0, "a second key after the hold sets nothing (3.9's 5a: side 1's second key loops)")
  run_op(state, Walk.release, key_name(12, 2))
  h.assert_equal(problems_of(run_op(state, Walk.release, key_name(6, 2))), "", "the editor's key up")
  h.assert_equal(h.shown_step_editor(), nil, "the editor closed")
  h.assert_equal(S.patterns[2][6], 0, "and its step stayed off")
  run_op(state, Walk.press, 3, 3)
  run_op(state, function(walk_state_now)
    walk_state_now.core.set_page(WALK.port, S.constants.GRID_PAGES.scenes, 1, 1)
  end)
  h.assert_equal(problems_of(run_op(state, Walk.release, key_name(3, 3))), "", "a held step up after a page change")
  h.assert_equal(S.patterns[3][3], 0, "its step did not toggle")
  h.assert_true(state.counts.hold_fired == 1 and state.counts.second_key == 1 and state.counts.step_toggled == 1,
    "the counters followed")
  S.patterns[4][1] = 9
  h.assert_equal(problems_of(run_op(state, Walk.clock, 0.1)), "voice 4 step 1: 9, the model's 0",
    "a change the model did not make is named")
end)

-- A tie (two held steps pressed at one instant, their holds due in one
-- tick) leaves the editor's key to the code, but an editor must be open
-- for one of them: none open is named
h.test("the grid walk's tie: the editor is open for one of the keys whose holds were due, and none open is named",
  function()
  for _, close in ipairs({ false, true }) do
    local context = h.load_strata()
    h.finish_startup(context)
    local state = walk_state(context, "128h", function() return 0 end)
    local S = state.S
    run_op(state, Walk.press, 5, 1)
    run_op(state, Walk.press, 6, 2)
    local problems = run_op(state, function(walk_now)
      Walk.clock(walk_now, 0.4)
      if close then S.lib.pages_seq.close_step_editor(WALK.port) end  -- behind the model's back
    end)
    h.assert_equal(state.counts.tied, 1, "the two holds were one tie")
    if close then
      h.assert_equal(table.concat(problems, "; "), "step editor: after a tie, open none, not one of 1 5, 2 6; "
        .. "step editor: expected 2 6 1, open none", "no editor after the tie is named")
    else
      h.assert_equal(table.concat(problems, "; "), "", "the editor the code opened is one of the two")
      h.assert_true(h.shown_step_editor() == "1 5 1" or h.shown_step_editor() == "2 6 1", "open for one of them")
    end
  end
end)

-- A tie that can leave no editor closed: voice 3's step holds the editor;
-- two held steps of voices 1 and 2 pressed at one instant have their
-- patterns replaced at one instant (a tie of replacements, neither the
-- editor's voice) before their holds come due (a tie of holds whose
-- gestures ended). Neither tie can close voice 3's editor, so its editor
-- closed behind the model's back is named, and the set names each key once
h.test("the grid walk's tie: no editor is allowed only where an event of the tie can leave none", function()
  for _, close in ipairs({ false, true }) do
    local context = h.load_strata()
    h.finish_startup(context)
    local state = walk_state(context, "128h", function() return 0 end)
    local S = state.S
    run_op(state, Walk.press, 1, 3)
    run_op(state, Walk.clock, 0.4)
    h.assert_equal(h.shown_step_editor(), "3 1 1", "voice 3's step 1 holds the editor")
    run_op(state, Walk.press, 5, 1)
    run_op(state, Walk.press, 6, 2)
    local problems = run_op(state, function(walk_now)
      clock.run(function()
        clock.sleep(0.1)
        S.lib.sequencer.replace_pattern(1, {})
        S.lib.sequencer.replace_pattern(2, {})
      end)
      Walk.clock(walk_now, 0.4)
      if close then S.lib.pages_seq.close_step_editor(WALK.port) end  -- behind the model's back
    end)
    h.assert_equal(state.counts.tied, 2, "the replacements were one tie, the holds another")
    if close then
      h.assert_equal(table.concat(problems, "; "), "step editor: after a tie, open none, not one of 3 1; "
        .. "step editor: expected 3 1 1, open none", "an editor closed where no event could close it is named")
    else
      h.assert_equal(table.concat(problems, "; "), "", "voice 3's editor stays")
      h.assert_equal(h.shown_step_editor(), "3 1 1", "still open")
    end
  end
end)

-- The model of the lane side by hand, on the 128h: a hits key's second
-- key sets its level from its place; a following lane A's tap gives the
-- cell a value and turns its step on; LN armed sets a lane's length with
-- the next lane key and disarms, and a page change disarms it; a hits key
-- held past the hold opens the step view on its pane, whose bar sets the
-- level, and K2 closes both with the key still down. The comparisons find
-- nothing wrong on the way
h.test("the grid walk's model: the lane side's second key, a tap, LN and the step view, by hand", function()
  local context = h.load_strata()
  h.finish_startup(context)
  local state = walk_state(context, "128h", function() return 0 end)
  local S = state.S
  local function ok(list, what) h.assert_equal(table.concat(list, "; "), "", what) end
  local function page(page_index, side)
    return run_op(state, function(now) now.core.set_page(WALK.port, page_index, 1, side) end)
  end
  ok(page(S.constants.GRID_PAGES.patterns, 2), "the lane side shown")
  ok(run_op(state, Walk.press, 5, 1), "voice 1's hits key 5 down")
  ok(run_op(state, Walk.press, 12, 1), "a second key at 12")
  h.assert_equal(S.patterns[1][5], S.lib.grid_core.level_for_position(12, 16), "step 5 takes 12's level")
  ok(run_op(state, Walk.release, key_name(12, 1)), "the second key up")
  ok(run_op(state, Walk.release, key_name(5, 1)), "the held key up toggles nothing")
  ok(run_op(state, Walk.press, 3, 2), "lane A's cell 3 down")
  ok(run_op(state, Walk.release, key_name(3, 2)), "and up: a tap")
  h.assert_equal(S.patterns[1][3], S.constants.MAX_STEP_LEVEL, "the value turned step 3 on")
  ok(run_op(state, Walk.press, UTILITY.ln_x, UTILITY.line), "LN tapped")
  ok(run_op(state, Walk.release, key_name(UTILITY.ln_x, UTILITY.line)), "LN up: armed")
  ok(run_op(state, Walk.press, 6, 2), "lane A's key 6 while LN is armed")
  ok(run_op(state, Walk.release, key_name(6, 2)), "and up")
  h.assert_equal(S.lib.lanes.length(1, "a"), 6, "lane A's length is 6")
  ok(run_op(state, Walk.press, UTILITY.ln_x, UTILITY.line), "LN tapped again")
  ok(run_op(state, Walk.release, key_name(UTILITY.ln_x, UTILITY.line)), "armed again")
  ok(page(S.constants.GRID_PAGES.scenes, 1), "a page change")
  ok(page(S.constants.GRID_PAGES.patterns, 2), "back on the lane side: LN disarmed, as the model says")
  ok(run_op(state, Walk.press, 8, 1), "the hits key 8 down")
  ok(run_op(state, Walk.clock, 0.4), "held past its hold: the editor and the view")
  h.assert_equal(S.lib.grid_core.step_view(WALK.port).pane, 1, "the view is on the key's pane")
  ok(run_op(state, Walk.press, 16, 1), "the level bar's last key")
  h.assert_equal(S.patterns[1][8], S.constants.MAX_STEP_LEVEL, "step 8 at 15")
  ok(run_op(state, Walk.release, key_name(16, 1)), "the bar key up")
  ok(run_op(state, OPS.k2[3]), "K2")
  h.assert_equal(S.lib.grid_core.step_view(WALK.port), nil, "the view closed with the key still down")
  ok(run_op(state, Walk.release, key_name(8, 1)), "the key up toggles nothing")
  h.assert_equal(S.patterns[1][8], S.constants.MAX_STEP_LEVEL, "step 8 stays on")
  h.assert_true(state.counts.hits_second == 1 and state.counts.cell_tap == 1 and state.counts.ln_spent == 1
    and state.counts.ln_disarmed_by_page == 1 and state.counts.view_opened == 1 and state.counts.view_bar == 1
    and state.counts.k2_closed == 1, "the counters followed")
end)

-- The perform side by hand, on the 128h with the patterns playing: a roll
-- key held rolls its voice at its rate, and a page change ends the roll;
-- after its voice's letter switched a further key moves the loop's end
-- (the final review's I1, which no seed reaches), and the loop's key let
-- go ends the loop
h.test("the grid walk's model: a roll ended by a page change and a loop moved and let go after a letter's switch, by hand",
  function()
  local context = h.load_strata()
  h.finish_startup(context)
  local state = walk_state(context, "128h", function() return local_value("S").constants.MAX_STEP_LEVEL end)
  local S = state.S
  local function ok(list, what) h.assert_equal(table.concat(list, "; "), "", what) end
  local function page(page_index, side)
    return run_op(state, function(now) now.core.set_page(WALK.port, page_index, 1, side) end)
  end
  pattern_clock_start()
  ok(page(S.constants.GRID_PAGES.voices, 2), "the perform side shown")
  ok(run_op(state, Walk.press, PERFORM_KEYS.first_roll + 1, 2), "voice 2's R2 down")
  h.assert_equal(S.lib.loop_roll.rolling(2), 2, "voice 2 rolls at 2")
  ok(page(S.constants.GRID_PAGES.patterns, 1), "a page change ends the roll")
  h.assert_equal(S.lib.loop_roll.rolling(2), nil, "no roll")
  ok(run_op(state, Walk.release, key_name(PERFORM_KEYS.first_roll + 1, 2)), "R2 up")
  ok(run_op(state, Walk.press, 4, 3), "voice 3's step 4 held")
  ok(run_op(state, Walk.press, 9, 3), "a second key: the loop 4 to 9")
  ok(run_op(state, Walk.release, key_name(9, 3)), "the second key up")
  ok(run_op(state, function() S.lib.pattern_letters.switch(3, "B") end), "B waits for voice 3")
  ok(run_op(state, Walk.clock, WALK.bar_seconds), "the bar: B plays")
  h.assert_equal(S.lib.pattern_letters.current(3), "B", "B")
  h.assert_true(S.lib.loop_roll.loop(3) ~= nil, "the loop outlived the switch")
  ok(run_op(state, Walk.press, 12, 3), "a further key: the loop 4 to 12")
  ok(run_op(state, Walk.release, key_name(12, 3)), "the further key up toggles nothing")
  h.assert_equal(select(2, S.lib.loop_roll.loop(3)), 12, "the loop's end moved")
  h.assert_equal(state.counts.loop_end_after_replacement, 1, "the model kept the loop's key across the switch")
  ok(run_op(state, Walk.release, key_name(4, 3)), "the loop's key up ends it")
  h.assert_equal(S.lib.loop_roll.loop(3), nil, "no loop")
  h.assert_true(state.counts.roll_ended_by_page == 1 and state.counts.loop_released_after_switch == 1,
    "the counters followed")
  pattern_clock_stop()
end)

-- The end's new lines, each against its fault made behind the walk's
-- back on a fresh script: a loop no key holds, a roll no key holds, a step
-- view with every key up, a letter left waiting by a stop, LN left armed
-- by a page change and a running voice whose last seqGate is not the rule
h.test("the grid walk's end names a loop, a roll, a step view, a waiting letter, LN and a seqGate left behind", function()
  local cases = {
    { "voice 1 has an unlatched loop with every key up", function(S)
      S.lib.loop_roll.set_loop(1, 2, 5, function() return true end)
    end },
    { "voice 1's roll lives a second after every key went up", function(S)
      pattern_clock_start()
      S.lib.loop_roll.roll(1, 2, function() return true end)
    end },
    { "a step view is shown with every key up", function(S)
      S.lib.grid_core.step_view = function() return { voice = 1, step = 1, pane = 1 } end
    end },
    { "voice 1: a letter waits with the patterns stopped", function(S)
      S.lib.pattern_letters.end_waits = function() end
      pattern_clock_start()
      S.lib.pattern_letters.switch(1, "B")
    end },
    { "LN: armed after a page change", function(S)
      S.lib.grid_core.page_changes = function() return 0 end
    end },
    { "voice 4: the engine's last seqGate", function(S)
      toggle_voice(4)  -- a synth voice (voices 1-3 read empty buffer slots)
      engine.setGrainParam(3, "seqGate", 1 - S.lib.sequencer.gate_wanted(4))
    end },
  }
  for _, case in ipairs(cases) do
    local context = h.load_strata()
    h.finish_startup(context)
    local state = walk_state(context, "128h", function() return 0 end)
    case[2](state.S)
    local problems = table.concat(finish(state), "\n")
    h.assert_true(problems:find(case[1], 1, true) ~= nil, "names " .. case[1] .. ":\n" .. problems)
  end
end)

-- The end check on a 256: a tempo key held into its repeat and let go, a
-- fill key held and the grid unplugged under it, then every key up: no
-- hold lives and fill is not held (read before the end's wait, when a
-- hold never stopped would still live)
h.test("the grid walk's end: a tempo key's repeat and a fill held through an unplug leave nothing", function()
  local context = h.load_strata()
  h.finish_startup(context)
  local state = walk_state(context, "256", function() return 0 end)
  local S = state.S
  local layout = Walk.layout(state)
  local strip_line = S.constants.NUM_VOICES + 1
  local tempo_x, tempo_y = S.lib.grid_pane.physical(layout, 2, 2, strip_line, 1)  -- the lower strip's T+
  local fill_x, fill_y = S.lib.grid_pane.physical(layout, 1, WALK.fill_key, strip_line, 1)
  run_op(state, Walk.press, tempo_x, tempo_y)
  run_op(state, Walk.clock, 0.7)
  h.assert_equal(table.concat(run_op(state, Walk.release, key_name(tempo_x, tempo_y)), "; "), "", "T+ up")
  run_op(state, Walk.press, fill_x, fill_y)
  h.assert_true(S.lib.conditions.fill(), "FL holds fill")
  run_op(state, OPS.plug[3])
  h.assert_true(#state.hold_handles >= 2, "the walk kept T+'s holds")
  h.assert_equal(table.concat(finish(state), "; "), "", "nothing lives at the end")
end)

for _, layout in ipairs({ "256", "128h", "128v", "64" }) do
  local reached = { "hold_fired", "hold_ended_by_page", "unplug_with_key_held", "step_toggled", "second_key",
    "hold_key_released", "page_unplugged", "rotation_unplugged", "lane_side_key", "perform_key", "hits_second",
    "cell_tap", "cell_second", "ln_armed", "ln_spent", "ln_disarmed_by_page", "view_opened", "view_bar", "k2_closed",
    "loop_made", "loop_released_after_switch", "roll_pressed", "roll_ended_by_page", "order_bar", "pulse_opened",
    "editor_without_view", "latch_pressed", "latched_loop_released", "roll_replaced", "roll_earlier_released",
    "press_ended" }
  -- a step view opened with a key held on another pane, and LP latching a
  -- held loop (its key on the other pane): the 256's two panes
  if layout == "256" then
    reached[#reached + 1] = "view_other_pane_held"
    reached[#reached + 1] = "latch_held"
  end
  -- a target with B held: the 64 never shows them together
  if layout ~= "64" then reached[#reached + 1] = "b_target" end
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
