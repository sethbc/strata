-- lib/positions.lua
-- Moving a voice's read position: jumps and loops (the grid's position
-- rows), four bookmarks per buffer voice (v<i>_bookmark_1..4, a registered
-- voice-param record), the scan hold, the arc scrub's friction glide
-- (scrub_friction), and the grid's bookmark strip and LEDs. Positions are
-- fractions of the slot's valid region. Transient state (the hold, the
-- glide's rate, the last recalled bookmark) is never a param, a scene or
-- a PSET value. See docs/notes/lua/positions.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_BOOKMARKS = S.constants.NUM_BOOKMARKS
  local SCRUB = S.constants.SCRUB
  local PLAYHEADS = S.constants.PLAYHEADS

  -- The grid's levels (design 3.3 section 9): a cell outside the loop is
  -- outside + round(peak x outside_range), inside it inside + round(peak x
  -- inside_range)
  M.LEVELS = {
    outside = 1, outside_range = 2, inside = 4, inside_range = 4, held = 11, record_head = 13, playhead = 15,
    bookmark = 6, recalled = 10, stored = 15, key_down = 15, key_up = 4, whole = 15,
  }
  local LEVELS = M.LEVELS
  -- a position a rounding away from a cell's fraction still counts as inside
  local JUMP_TOLERANCE = 1e-6
  -- the strip's non-bookmark keys
  local STRIP_KEYS = {"store", "hold", "whole"}
  -- the position row's cells on the page-5 grids (the change signature)
  local DISPLAY_CELLS = 16

  -- per voice: the scan hold, its holders (a set: "grid:<port>", "arc",
  -- "caller"; held exactly while it is not empty), the glide's rate (as
  -- sent), the last recalled bookmark, the glide clock and the ring's
  -- recent turns
  local scan_hold, holders, glide_rate, recalled, glide_clock, turns = {}, {}, {}, {}, {}, {}
  for voice_idx = 1, NUM_VOICES do
    scan_hold[voice_idx], holders[voice_idx], glide_rate[voice_idx] = false, {}, 0
  end

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx >= 1 and voice_idx <= NUM_VOICES and voice_idx % 1 == 0
  end

  local function valid_bookmark(n)
    return type(n) == "number" and n >= 1 and n <= NUM_BOOKMARKS and n % 1 == 0
  end

  local function buffer_voice(voice_idx)
    return valid_voice(voice_idx) and voice_uses_buffer(voice_idx)
  end

  local function param_id(voice_idx, key) return "v" .. voice_idx .. "_" .. key end

  local function loop_of(voice_idx)
    return params:get(param_id(voice_idx, "loop_start")), params:get(param_id(voice_idx, "loop_length"))
  end

  -- The transient state, for the playhead estimate and the tests
  function M.scan_held(voice_idx) return valid_voice(voice_idx) and scan_hold[voice_idx] or false end
  -- Whether one holder is in a voice's set of scan holders
  function M.holds_scan(voice_idx, holder)
    return valid_voice(voice_idx) and holder ~= nil and holders[voice_idx][holder] == true
  end
  function M.scrub_rate(voice_idx) return valid_voice(voice_idx) and glide_rate[voice_idx] or 0 end

  -- A voice's bookmark n (0-1), or nil
  function M.bookmark(voice_idx, n)
    if not valid_voice(voice_idx) or not valid_bookmark(n) then return nil end
    return params:get(param_id(voice_idx, "bookmark_" .. n))
  end

  -- The bookmark a voice last recalled, or nil
  function M.last_recalled(voice_idx)
    return valid_voice(voice_idx) and recalled[voice_idx] or nil
  end

  -- Send a grain param to a voice's engine synth while it runs
  local function send_grain(voice_idx, name, value)
    if S.voices[voice_idx].active then engine.setGrainParam(voice_idx - 1, name, value) end
  end

  -- The glide's rate changes: bring the playhead estimate up to now at the
  -- old rate first
  local function set_scrub_rate(voice_idx, rate)
    S.lib.playheads.advance(voice_idx)
    glide_rate[voice_idx] = rate
    send_grain(voice_idx, "scrubRate", rate)
  end

  local function cancel_glide_clock(voice_idx)
    if glide_clock[voice_idx] then
      clock.cancel(glide_clock[voice_idx])
      glide_clock[voice_idx] = nil
    end
  end

  -- End a voice's glide at once, and forget its recent ring turns unless
  -- the caller is the next turn
  local function end_glide(voice_idx, keep_turns)
    cancel_glide_clock(voice_idx)
    if not keep_turns then turns[voice_idx] = nil end
    if glide_rate[voice_idx] ~= 0 then set_scrub_rate(voice_idx, 0) end
  end

  -- The hold changes (the holders were just changed to match): bring the
  -- playhead estimate up to now first
  local function set_scan_hold(voice_idx, on)
    S.lib.playheads.advance(voice_idx)
    scan_hold[voice_idx] = on
    send_grain(voice_idx, "scanHold", on and 1 or 0)
  end

  -- A holder (any non-nil key, "caller" by default; the grid passes
  -- "grid:<port>", the arc "arc") holds or lets go of a voice's own scan:
  -- scanHold 1 stops it, not the glide. Only a buffer voice can be held;
  -- a release counts whatever the voice's source is now. The scan stays
  -- held while any holder remains
  function M.hold_scan(voice_idx, on, holder)
    if not valid_voice(voice_idx) then return end
    if holder == nil then holder = "caller" end
    local voice_holders = holders[voice_idx]
    if on then
      if not buffer_voice(voice_idx) then return end
      local was_empty = next(voice_holders) == nil
      voice_holders[holder] = true
      if was_empty then set_scan_hold(voice_idx, true) end
    elseif voice_holders[holder] then
      voice_holders[holder] = nil
      if next(voice_holders) == nil and scan_hold[voice_idx] then set_scan_hold(voice_idx, false) end
    end
  end

  -- Jump a buffer voice to p (0-1 of the slot). Inside its loop buf_pos
  -- becomes p's place in the loop; outside, the loop becomes the whole slot
  -- and buf_pos p. A running voice's scan restarts, the playhead estimate
  -- too, and a glide ends. Everything but those goes through params:set
  function M.jump(voice_idx, p)
    if not buffer_voice(voice_idx) or type(p) ~= "number" or p ~= p then return end
    p = math.max(0, math.min(1, p))
    local start, length = loop_of(voice_idx)
    if p >= start - JUMP_TOLERANCE and p < start + length - JUMP_TOLERANCE then
      params:set(param_id(voice_idx, "buf_pos"), math.max(0, math.min(1, (p - start) / length)))
    else
      params:set(param_id(voice_idx, "loop_start"), 0)
      params:set(param_id(voice_idx, "loop_length"), 1)
      params:set(param_id(voice_idx, "buf_pos"), p)
    end
    end_glide(voice_idx)
    send_grain(voice_idx, "t_scanReset", 1)
    S.lib.playheads.reset(voice_idx)
  end

  -- Set a buffer voice's loop to [a, b] (fractions, a <= b): the start, then
  -- the length (the order the loop clamps need), then a jump to a
  function M.set_loop(voice_idx, a, b)
    if not buffer_voice(voice_idx) or type(a) ~= "number" or type(b) ~= "number" then return end
    a = math.max(0, math.min(1, a))
    b = math.max(a, math.min(1, b))
    params:set(param_id(voice_idx, "loop_start"), a)
    params:set(param_id(voice_idx, "loop_length"), b - a)
    M.jump(voice_idx, a)
  end

  -- The loop back to the whole slot, with no jump
  local function whole_loop(voice_idx)
    if not buffer_voice(voice_idx) then return end
    params:set(param_id(voice_idx, "loop_start"), 0)
    params:set(param_id(voice_idx, "loop_length"), 1)
  end

  function M.recall_bookmark(voice_idx, n)
    if not buffer_voice(voice_idx) or not valid_bookmark(n) then return end
    M.jump(voice_idx, M.bookmark(voice_idx, n))
    recalled[voice_idx] = n
  end

  -- Bookmark n becomes the voice's playhead, or, stopped, its buf_pos mapped
  -- into its loop
  function M.store_bookmark(voice_idx, n)
    if not buffer_voice(voice_idx) or not valid_bookmark(n) then return end
    local position = S.lib.playheads.position(voice_idx)
    if not position then
      local start, length = loop_of(voice_idx)
      position = start + params:get(param_id(voice_idx, "buf_pos")) * length
    end
    params:set(param_id(voice_idx, "bookmark_" .. n), math.max(0, math.min(1, position)))
  end

  -- The glide -----------------------------------------------------------

  -- The ring's speed over its last SCRUB.window_seconds, in loop fractions a
  -- second (the samples are buf_pos after each turn)
  local function ring_speed(voice_idx)
    local samples = turns[voice_idx]
    if not samples or #samples < 2 then return 0 end
    local last = samples[#samples]
    local first = last
    for index = #samples - 1, 1, -1 do
      if last.time - samples[index].time > SCRUB.window_seconds + 1e-9 then break end
      first = samples[index]
    end
    if last.time <= first.time then return 0 end
    return (last.position - first.position) / (last.time - first.time)
  end

  local function glide(voice_idx)
    clock.sleep(SCRUB.release_seconds)
    local speed = ring_speed(voice_idx)
    turns[voice_idx] = nil
    if math.abs(speed) < SCRUB.stop_rate then
      glide_clock[voice_idx] = nil
      return
    end
    set_scrub_rate(voice_idx, speed)
    local dt = 1 / PLAYHEADS.update_hz
    while true do
      clock.sleep(dt)
      local tau = SCRUB.max_glide_seconds * (1 - params:get("scrub_friction") / 100)
      local rate = tau > 0 and glide_rate[voice_idx] * math.exp(-dt / tau) or 0
      if math.abs(rate) < SCRUB.stop_rate then rate = 0 end
      set_scrub_rate(voice_idx, rate)
      if rate == 0 then break end
    end
    glide_clock[voice_idx] = nil
  end

  -- The arc's ring 1 turned the voice's buf_pos (called after the change):
  -- a running glide ends, and when the ring then stays still for
  -- SCRUB.release_seconds a glide starts at its speed, unless the friction is
  -- 100% (the ring is direct)
  function M.scrub_turned(voice_idx)
    if not buffer_voice(voice_idx) then return end
    end_glide(voice_idx, true)
    if params:get("scrub_friction") >= 100 then return end
    local now = util.time()
    local samples = turns[voice_idx] or {}
    samples[#samples + 1] = {time = now, position = params:get(param_id(voice_idx, "buf_pos"))}
    while #samples > 2 and now - samples[2].time > SCRUB.window_seconds do table.remove(samples, 1) end
    turns[voice_idx] = samples
    glide_clock[voice_idx] = clock.run(function() glide(voice_idx) end)
  end

  -- The grid's held keys ----------------------------------------------

  -- per port: the record kept in the grid core's port state (so an unplug
  -- forgets it): {held = {voice, cell, cells, page} (the position key held),
  -- hold = {[voice] = page}, store = {[voice] = page} (the 256's store keys,
  -- one per voice), store_down = page (the one store key of a layout that
  -- selects a grid voice; nil while up), pressed = {[voice] = key}}.
  -- `records` names each record this module made, to find it again when
  -- the port's state is gone
  local records = {}

  local function record_of(port)
    local state = S.lib.grid_core.port_state(port)
    if not state.positions then state.positions = {hold = {}, store = {}, pressed = {}} end
    records[port] = state.positions
    return state.positions
  end

  -- End what a port's record holds that is stale: everything when its grid
  -- was removed (its state is gone), and each key pressed on a page the
  -- grid no longer shows
  local function end_stale_port(port, record)
    local gone = S.lib.grid_core.port_state(port).positions ~= record
    local page = S.lib.grid_core.page(port)
    for voice_idx, pressed_page in pairs(record.hold) do
      if gone or pressed_page ~= page then
        record.hold[voice_idx] = nil
        M.hold_scan(voice_idx, false, "grid:" .. port)
      end
    end
    for voice_idx, pressed_page in pairs(record.store) do
      if gone or pressed_page ~= page then
        record.store[voice_idx] = nil
        record.pressed[voice_idx] = nil
      end
    end
    if record.store_down and (gone or record.store_down ~= page) then
      record.store_down = nil
      record.pressed = {}
    end
    if record.held and (gone or record.held.page ~= page) then record.held = nil end
    if gone then records[port] = nil end
  end

  -- The playhead clock calls it every tick
  function M.end_stale_holds()
    for port, record in pairs(records) do end_stale_port(port, record) end
  end

  -- Whether test(record) holds for the port's record (with a port) or for
  -- any port's (without one)
  local function any_record(test, port)
    if port ~= nil then return records[port] ~= nil and test(records[port]) and true or false end
    for _, record in pairs(records) do
      if test(record) then return true end
    end
    return false
  end

  -- A position press also makes the voice the grid voice on the layouts
  -- whose record says so (the 128s and the 64; never the 256, whose rows
  -- are one voice each), and their one strip acts for the grid voice
  local function selects_grid_voice(port)
    local layout = S.lib.grid_core.layout_of(port)
    return layout ~= nil and layout.selects_grid_voice == true
  end

  -- Whether a port's store is down for a voice: its one store key on a
  -- layout that selects a grid voice (store follows the grid voice), the
  -- voice's own key on the 256
  local function storing(record, voice_idx)
    return record.store_down ~= nil or record.store[voice_idx] ~= nil
  end

  -- A key of a row of `cells` cells (design 3.3 section 5.2): a press jumps
  -- to its cell's start; with another key of the row held, it sets the loop
  -- from the lower cell's start to the higher cell's end. Only buffer voices
  -- respond; a release only ends the hold
  function M.grid_key(port, voice_idx, cell, cells, z)
    if not valid_voice(voice_idx) or type(cells) ~= "number" or cells < 1 or cells % 1 ~= 0 then return end
    if type(cell) ~= "number" or cell < 1 or cell > cells or cell % 1 ~= 0 then return end
    if records[port] then end_stale_port(port, records[port]) end
    if z == 0 then
      local record = records[port]
      local held = record and record.held
      if held and held.voice == voice_idx and held.cells == cells and held.cell == cell then record.held = nil end
      return
    end
    if not buffer_voice(voice_idx) then return end
    if selects_grid_voice(port) then select_grid_voice(voice_idx) end
    local record = record_of(port)
    local held = record.held
    if held and held.voice == voice_idx and held.cells == cells and held.cell ~= cell then
      local low, high = math.min(held.cell, cell), math.max(held.cell, cell)
      M.set_loop(voice_idx, (low - 1) / cells, high / cells)
      return
    end
    record.held = {voice = voice_idx, cell = cell, cells = cells, page = S.lib.grid_core.page(port)}
    M.jump(voice_idx, (cell - 1) / cells)
  end

  -- The strip's keys: 1-4 (recall; with store held, store), "store" and
  -- "hold" (held), "whole" (the loop back to the whole slot)
  function M.strip_key(port, voice_idx, key, z)
    if not valid_voice(voice_idx) then return end
    if records[port] then end_stale_port(port, records[port]) end
    local page = S.lib.grid_core.page(port)
    if valid_bookmark(key) then
      if z == 1 then
        local record = record_of(port)
        if storing(record, voice_idx) then
          M.store_bookmark(voice_idx, key)
          record.pressed[voice_idx] = key
        else
          M.recall_bookmark(voice_idx, key)
        end
      elseif records[port] then
        -- on the layouts that select a grid voice the release ends the key
        -- for whichever voice it was pressed for (the grid voice may have
        -- changed since, as for hold and store, #221); the 256's ends only
        -- its own voice's
        local pressed = records[port].pressed
        if selects_grid_voice(port) then
          for pressed_voice, pressed_key in pairs(pressed) do
            if pressed_key == key then pressed[pressed_voice] = nil end
          end
        elseif pressed[voice_idx] == key then
          pressed[voice_idx] = nil
        end
      end
    elseif key == "store" then
      if z == 1 then
        -- on the layouts that select a grid voice store is the port's (one
        -- key, for whatever voice the grid shows); the 256 has one per voice
        if selects_grid_voice(port) then
          record_of(port).store_down = page
        else
          record_of(port).store[voice_idx] = page
        end
      elseif records[port] then
        -- the port's one store key's release ends it, whatever voice it
        -- names (#221); the 256's ends only its own voice's
        if selects_grid_voice(port) then
          records[port].store_down = nil
          records[port].pressed = {}
        else
          records[port].store[voice_idx] = nil
          records[port].pressed[voice_idx] = nil
        end
      end
    elseif key == "hold" then
      if z == 1 then
        record_of(port).hold[voice_idx] = page
        M.hold_scan(voice_idx, true, "grid:" .. port)
      else
        -- likewise one hold key per port where a grid voice is selected:
        -- the release ends the hold for every held voice (each once)
        local ended = {[voice_idx] = true}
        if records[port] then
          if selects_grid_voice(port) then
            for held_voice in pairs(records[port].hold) do ended[held_voice] = true end
            records[port].hold = {}
          else
            records[port].hold[voice_idx] = nil
          end
        end
        for held_voice in pairs(ended) do M.hold_scan(held_voice, false, "grid:" .. port) end
      end
    elseif key == "whole" and z == 1 then
      whole_loop(voice_idx)
    end
  end

  -- LEDs ------------------------------------------------------------------

  local function round(value) return math.floor(value + 0.5) end
  local context_cache = {}  -- row_context's last result per voice and cell count

  -- What a position row needs from a voice, fetched once for all its cells:
  -- nil when it is not a buffer voice or its slot holds nothing. A stopped
  -- voice shows where it will start (its buf_pos in its loop)
  local function row_context(voice_idx, cells)
    if not buffer_voice(voice_idx) then return nil end
    local slot = voice_buffer_slot(voice_idx)
    if not S.buffers[slot] or (S.buffers[slot].seconds or 0) <= 0 then return nil end
    local start, length = loop_of(voice_idx)
    local head = S.lib.playheads.position(voice_idx)
    if not head then head = start + params:get(param_id(voice_idx, "buf_pos")) * length end
    local record_head = S.lib.playheads.record_head(slot)
    local held_cells, held_key = {}, ""
    for _, record in pairs(records) do
      local held = record.held
      if held and held.voice == voice_idx and held.cells == cells then
        held_cells[held.cell] = true
        held_key = held_key .. held.cell .. ";"
      end
    end
    local head_cell = S.lib.playheads.cell_of(head, cells)
    local record_cell = record_head and S.lib.playheads.cell_of(record_head, cells)
    -- the context (its bins table above all) is reused within one instant
    -- while nothing it shows changed, so a redraw's cells share one
    local now = util.time()
    local key = table.concat({start, length, head_cell, record_cell or "-", S.buffers[slot].seconds, held_key}, ",")
    local cached = context_cache[voice_idx .. ":" .. cells]
    if cached and cached.time == now and cached.key == key then return cached.context end
    local context = {
      bins = S.lib.waveforms.bins(slot, cells), start = start, length = length, cells = cells,
      head_cell = head_cell, record_cell = record_cell, held_cells = held_cells,
    }
    context_cache[voice_idx .. ":" .. cells] = {time = now, key = key, context = context}
    return context
  end

  local function cell_level(context, cell)
    if cell == context.head_cell then return LEVELS.playhead end
    if cell == context.record_cell then return LEVELS.record_head end
    if context.held_cells[cell] then return LEVELS.held end
    local middle = (cell - 0.5) / context.cells
    local peak = context.bins and context.bins[cell] or 0
    if middle >= context.start and middle < context.start + context.length then
      return LEVELS.inside + round(peak * LEVELS.inside_range)
    end
    return LEVELS.outside + round(peak * LEVELS.outside_range)
  end

  -- The LED level of cell `cell` of a voice's row of `cells` cells (0 for a
  -- voice that is not a buffer voice, or whose slot is empty)
  function M.grid_level(voice_idx, cell, cells)
    if not valid_voice(voice_idx) or type(cells) ~= "number" or cells < 1 or cells % 1 ~= 0 then return 0 end
    if type(cell) ~= "number" or cell < 1 or cell > cells or cell % 1 ~= 0 then return 0 end
    local context = row_context(voice_idx, cells)
    return context and cell_level(context, cell) or 0
  end

  -- The LED level of one of a voice's strip keys (1-4, "store", "hold",
  -- "whole"). With a port, "store" and a stored bookmark read only that
  -- port's keys (each grid shows its own); without one, any port's
  function M.strip_level(voice_idx, key, port)
    if not valid_voice(voice_idx) then return 0 end
    if valid_bookmark(key) then
      if any_record(function(record) return storing(record, voice_idx) and record.pressed[voice_idx] == key end, port) then
        return LEVELS.stored
      end
      if recalled[voice_idx] == key then return LEVELS.recalled end
      return LEVELS.bookmark
    elseif key == "hold" then
      -- the hold itself, whoever holds it
      return scan_hold[voice_idx] and LEVELS.key_down or LEVELS.key_up
    elseif key == "store" then
      return any_record(function(record) return storing(record, voice_idx) end, port) and LEVELS.key_down or LEVELS.key_up
    elseif key == "whole" then
      local start, length = loop_of(voice_idx)
      return start < 1e-9 and length > 1 - 1e-9 and LEVELS.whole or LEVELS.key_up
    end
    return 0
  end

  -- Everything a page-5 grid shows, as one string: it changes when any LED
  -- level does (the playhead clock redraws then), and with a bookmark's
  -- value, which a recall or a scene fade moves
  function M.display_signature()
    local parts = {}
    for voice_idx = 1, NUM_VOICES do
      local context = row_context(voice_idx, DISPLAY_CELLS)
      for cell = 1, DISPLAY_CELLS do
        parts[#parts + 1] = context and cell_level(context, cell) or 0
      end
      for n = 1, NUM_BOOKMARKS do
        parts[#parts + 1] = M.strip_level(voice_idx, n)
        parts[#parts + 1] = string.format("%.6f", params:get(param_id(voice_idx, "bookmark_" .. n)))
      end
      for _, key in ipairs(STRIP_KEYS) do parts[#parts + 1] = M.strip_level(voice_idx, key) end
    end
    return table.concat(parts, ",")
  end

  -- Params and registrations --------------------------------------------

  -- The positions group of the PARAMS menu
  function M.add_params()
    params:add_group("strata_positions", "positions", 1)
    params:add{
      type = "control",
      id = "scrub_friction",
      name = "scrub friction",
      controlspec = controlspec.new(0, 100, "lin", 0, 100, "%", 0.01),
    }
  end

  local function fraction_text(param) return string.format("%.3f", param:get()) end

  local bookmark_keys, scene_defaults, scene_ranges = {}, {}, {}
  for n = 1, NUM_BOOKMARKS do
    local key = "bookmark_" .. n
    bookmark_keys[n] = key
    scene_defaults[key] = (n - 1) / NUM_BOOKMARKS
    scene_ranges[key] = {0, 1}
  end

  -- VOICE's layout tests and page renders: each voice on buffer 1, the
  -- cursor on its first bookmark
  local layout_states = {}
  for voice_idx = 1, NUM_VOICES do
    table.insert(layout_states, {
      name = string.format("v%d buffer bookmark 1", voice_idx),
      setup = function()
        S.selected_voice = voice_idx
        params:set(param_id(voice_idx, "source"), S.constants.SOURCE_SYNTH + 1)
        S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(param_id(voice_idx, bookmark_keys[1])))
      end,
    })
  end

  local record
  record = {
    name = "bookmarks",
    count = NUM_BOOKMARKS,
    add = function(voice_idx)
      for n, key in ipairs(bookmark_keys) do
        S.lib.params_setup.add_voice_extra(voice_idx, record, key, {
          type = "control",
          name = "bookmark " .. n,
          controlspec = controlspec.new(0, 1, "lin", 0, scene_defaults[key]),
          formatter = fraction_text,
        })
      end
    end,
    scene_defaults = scene_defaults,
    scene_ranges = scene_ranges,
    -- a started voice never inherits a glide or a hold
    sync = function(voice_idx)
      cancel_glide_clock(voice_idx)
      turns[voice_idx] = nil
      glide_rate[voice_idx], scan_hold[voice_idx], holders[voice_idx] = 0, false, {}
      engine.setGrainParam(voice_idx - 1, "scrubRate", 0)
      engine.setGrainParam(voice_idx - 1, "scanHold", 0)
    end,
    voice_rows = {
      section = "bookmarks",
      rows = bookmark_keys,
      when = function(voice_idx) return buffer_voice(voice_idx) end,
    },
    layout_states = layout_states,
    fader = false,
  }
  S.register_voice_params(record)

  -- A grain restart (a running voice's source switch; a voiceOn) ends the
  -- glide; a source switch forgets the last recalled bookmark
  S.register_grain_restart(function(voice_idx)
    end_glide(voice_idx)
    recalled[voice_idx] = nil  -- source-change hooks never run during a scene recall; this does
  end)
  S.register_source_change(function(voice_idx) recalled[voice_idx] = nil end)

  -- cleanup: no glide runs on, no scan stays held (every holder lets go)
  S.register_cleanup(S.constants.CLEANUP_ORDER.scrub_glide, function()
    for voice_idx = 1, NUM_VOICES do
      cancel_glide_clock(voice_idx)
      turns[voice_idx] = nil
      if glide_rate[voice_idx] ~= 0 then set_scrub_rate(voice_idx, 0) end
      for holder in pairs(holders[voice_idx]) do M.hold_scan(voice_idx, false, holder) end
    end
  end)

  -- A voice's scan is held exactly while it has a holder
  S.register_invariant("scan holds", function()
    for voice_idx = 1, NUM_VOICES do
      local has_holder = next(holders[voice_idx]) ~= nil
      if scan_hold[voice_idx] ~= has_holder then
        return "voice " .. voice_idx .. ": scan held " .. tostring(scan_hold[voice_idx])
          .. " with " .. (has_holder and "holders" or "no holder")
      end
    end
  end)

  -- A port holds store one way only: its one store key (store_down) on a
  -- layout that selects a grid voice, a key per voice (store) on the others
  S.register_invariant("strip store", function()
    for port, record in pairs(records) do
      local layout = S.lib.grid_core.port_state(port).positions == record and S.lib.grid_core.layout_of(port)
      if layout and layout.selects_grid_voice and next(record.store) ~= nil then
        return "grid " .. port .. " selects a grid voice but holds store per voice"
      elseif layout and not layout.selects_grid_voice and record.store_down ~= nil then
        return "grid " .. port .. " has a store key per voice but holds the port's store"
      end
    end
  end)

  return M
end
