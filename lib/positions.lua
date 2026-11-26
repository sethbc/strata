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
    -- a bookmark that waits for its beat or bar (#593) blinks between these,
    -- each for waiting_ticks of the playhead clock's ticks (no steady level
    -- stands clear of 6, 10 and 15 on a varibright grid); since #876 every
    -- waiting key blinks so, through S.lib.grid_core.waiting_level, whose
    -- levels these name (the grid core's LEVELS, S.constants.GRID_LEVELS)
    waiting_high = S.constants.GRID_LEVELS.waiting_high, waiting_low = S.constants.GRID_LEVELS.waiting_low,
    waiting_ticks = S.constants.GRID_LEVELS.waiting_ticks, waiting_phases = S.constants.GRID_LEVELS.waiting_phases,
    -- 3.7's slice rows (design §10): a slice that exists, its key held, the
    -- slice playing, none; the strip's bank keys: the bank shown, one that
    -- holds slices, one that holds none
    slice = 9, slice_held = 11, slice_playing = 15, slice_none = 0,
    bank_shown = 15, bank_filled = 4, bank_empty = 0,
  }
  local LEVELS = M.LEVELS
  -- a position a rounding away from a cell's fraction still counts as inside
  local JUMP_TOLERANCE = 1e-6
  -- the strip's non-bookmark keys
  local STRIP_KEYS = {"store", "hold", "whole"}
  -- the position row's cells on the page-5 grids (the change signature)
  local DISPLAY_CELLS = S.constants.GRID_PAGES.position_cells
  -- 3.7's slice rows (design §10, decision 13): a bank is a row's
  -- bank_size cells (slices 1-16, 17-32, ...), the strip's NUM_BOOKMARKS
  -- keys pick it, a grid key's note key is port x port_key + slice (plan
  -- ruling 17)
  local SLICE_ROW = {bank_size = DISPLAY_CELLS, port_key = 100}
  -- whether the slice rows' bind listener is in (hear_binds)
  local binds_heard = false

  -- per voice: the scan hold, its holders (a set: "grid:<port>", "arc",
  -- "caller"; held exactly while it is not empty), the glide's rate (as
  -- sent), the last recalled bookmark, the glide clock and the ring's
  -- recent turns
  -- (fling: per voice, while its clock runs, {turned_at = the latest turn's time, gliding = bool})
  local scan_hold, holders, glide_rate, recalled, glide_clock, turns, fling = {}, {}, {}, {}, {}, {}, {}
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

  -- The bookmark a voice last recalled, while it still has the source it
  -- recalled it on, or nil
  function M.last_recalled(voice_idx)
    local last = valid_voice(voice_idx) and recalled[voice_idx]
    if last and last.source == S.voices[voice_idx].source then return last.bookmark end
    return nil
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

  -- End a voice's glide clock (a handle of S.lib.clocks): stopped, so one
  -- whose wake may be posted retires and ends at that wake (#870); at
  -- cleanup canceled at once
  local function stop_glide_clock(voice_idx, at_cleanup)
    if glide_clock[voice_idx] then
      if at_cleanup then
        S.lib.clocks.cancel(glide_clock[voice_idx])
      else
        S.lib.clocks.stop(glide_clock[voice_idx])
      end
      glide_clock[voice_idx] = nil
      fling[voice_idx] = nil
    end
  end

  -- End a voice's glide at once, and forget its recent ring turns unless
  -- the caller is the next turn
  local function end_glide(voice_idx, keep_turns)
    stop_glide_clock(voice_idx)
    if not keep_turns then turns[voice_idx] = nil end
    if glide_rate[voice_idx] ~= 0 then set_scrub_rate(voice_idx, 0) end
  end

  -- The hold changes (the holders were just changed to match): bring the
  -- playhead estimate up to now first. Every grid's hold key shows it,
  -- whoever changed it (a grid key, the arc, a grid that left, cleanup),
  -- and so does BUFFER's ALT ring 1 (#934)
  local hold_estimate_errors = {}
  local function set_scan_hold(voice_idx, on)
    S.lib.ui_frame.contained_call(hold_estimate_errors, voice_idx, "scan hold estimate", S.lib.playheads.advance, voice_idx)
    scan_hold[voice_idx] = on
    send_grain(voice_idx, "scanHold", on and 1 or 0)
    grid_redraw()
    request_redraw()
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
    -- 3.9 grid sequencer (2a, fix round 1): a held step value on the
    -- position ends first, so the jump is heard (a step's own bookmark wins
    -- over that step's value)
    S.lib.sequencer.end_held_value(voice_idx, "position")
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

  -- Restart a running buffer voice's scan at 0 now, and the playhead with
  -- it: t_scanReset and the playhead's reset (3.7: a scan mode change,
  -- lib/scan.lua; the engine's mode change never restarts the scan itself)
  function M.restart_scan(voice_idx)
    if not buffer_voice(voice_idx) then return end
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
    recalled[voice_idx] = {bookmark = n, source = S.voices[voice_idx].source}
  end

  -- A user's bookmark recall (a grid's strip key, BUFFER's bm field; 3.4,
  -- design §8.9): at the next beat or bar quantize_actions names (key
  -- bookmark<v>), at once while it is off. waiting_bookmark(v) is the
  -- bookmark that waits: the number the waiting recall keeps as its detail
  function M.recall_bookmark_quantized(voice_idx, n)
    if not buffer_voice(voice_idx) or not valid_bookmark(n) then return end
    S.lib.quantize.schedule("bookmark" .. voice_idx, function() M.recall_bookmark(voice_idx, n) end,
      "v" .. voice_idx .. " bm " .. n, n)
  end

  function M.waiting_bookmark(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    return S.lib.quantize.waiting_detail("bookmark" .. voice_idx)
  end

  -- The cell a voice's waiting jump or two-key loop was pressed on (the
  -- detail grid_key schedules it with, #876), or nil: none waits, or the
  -- position key's action is a slice's play, which keeps none
  function M.waiting_cell(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    local detail = S.lib.quantize.waiting_detail("position" .. voice_idx)
    return type(detail) == "table" and detail.cell or nil
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

  -- The glide's two steps: it starts at the ring's speed (unless that is
  -- below SCRUB.stop_rate), then decays with the friction, one step per
  -- playhead update, until the rate is 0
  local function start_glide(voice_idx)
    local speed = ring_speed(voice_idx)
    turns[voice_idx] = nil
    if math.abs(speed) >= SCRUB.stop_rate then set_scrub_rate(voice_idx, speed) end
  end

  local function decay_glide(voice_idx)
    local tau = SCRUB.max_glide_seconds * (1 - params:get("scrub_friction") / 100)
    local rate = tau > 0 and glide_rate[voice_idx] * math.exp(-1 / PLAYHEADS.update_hz / tau) or 0
    if math.abs(rate) < SCRUB.stop_rate then rate = 0 end
    set_scrub_rate(voice_idx, rate)
  end

  -- Each glide step runs through the frame's contained_call (#517): an
  -- error is printed with its traceback, once per distinct message per
  -- voice (a good step forgets it), and never ends the glide's clock: the
  -- glide runs on while its rate is not 0
  local glide_errors = {}  -- per voice: the error message its glide last printed
  -- One clock per run of turns (#515): it reads the voice's latest turn
  -- (fling[voice].turned_at) and waits until the ring has stayed still for
  -- SCRUB.release_seconds, then glides; a turn that comes meanwhile (the
  -- glide's rate already set to 0 by scrub_turned) sends it back to
  -- waiting (`fling`, above). Every sleep is outside the protected call and
  -- goes through the clock's handle: a stopped glide returns at once,
  -- touching nothing (a newer glide may own the voice's state by then)
  local function glide(voice_idx, handle)
    local contained_call = S.lib.ui_frame.contained_call
    local state = fling[voice_idx]
    while true do
      if not state.gliding then
        local remaining = state.turned_at + SCRUB.release_seconds - util.time()
        if remaining > 1e-6 then
          if not handle.sleep(remaining) then return end
        else
          state.gliding = true
          contained_call(glide_errors, voice_idx, "scrub glide", start_glide, voice_idx)
          if glide_rate[voice_idx] == 0 then break end
        end
      else
        if not handle.sleep(1 / PLAYHEADS.update_hz) then return end
        if state.gliding then
          contained_call(glide_errors, voice_idx, "scrub glide", decay_glide, voice_idx)
          if glide_rate[voice_idx] == 0 then break end
        end
      end
    end
    fling[voice_idx] = nil
    glide_clock[voice_idx] = nil
  end

  -- The arc's ring 1 turned the voice's buf_pos (called after the change):
  -- a running glide ends, and when the ring then stays still for
  -- SCRUB.release_seconds a glide starts at its speed, unless the friction is
  -- 100% (the ring is direct)
  function M.scrub_turned(voice_idx)
    if not buffer_voice(voice_idx) then return end
    if params:get("scrub_friction") >= 100 then
      end_glide(voice_idx, true)
      return
    end
    -- a running glide ends at once; its clock (if any) stays and waits again
    if glide_rate[voice_idx] ~= 0 then set_scrub_rate(voice_idx, 0) end
    local now = util.time()
    local samples = turns[voice_idx] or {}
    samples[#samples + 1] = {time = now, position = params:get(param_id(voice_idx, "buf_pos"))}
    while #samples > 2 and now - samples[2].time > SCRUB.window_seconds do table.remove(samples, 1) end
    turns[voice_idx] = samples
    if glide_clock[voice_idx] then
      fling[voice_idx].turned_at, fling[voice_idx].gliding = now, false
    else
      fling[voice_idx] = {turned_at = now, gliding = false}
      glide_clock[voice_idx] = S.lib.clocks.run(function(handle) glide(voice_idx, handle) end)
    end
  end

  -- The grid's held keys ----------------------------------------------

  -- per port: the record kept in the grid core's port state (so an unplug
  -- forgets it): {held = {voice, cell, cells, pane, still} (the position
  -- key held), hold = {[voice] = {[pane] = still}}, store = {[voice] =
  -- {[pane] = still}} (a store key per voice and pane), pressed = {[voice]
  -- = {key, panes = {[pane] = still}}} (the latest stored bookmark and
  -- its presses), bank = {[voice] = the slice bank shown, nil for 1},
  -- slices = {[voice] = {[cell] = the slice key held: {n, pane, still, token,
  -- released}}}}. `still` is the press's own test that its key is still
  -- held (held_still, below). `records` names each record this module
  -- made, to find it again when the port's state is gone
  local records = {}

  -- The grid page passes pane.still for this physical press. A release,
  -- another press, a pane change, the chooser opening or the grid leaving
  -- ends it. The next key or tick clears stale records. A direct call
  -- without a predicate keeps its record until release or port removal.
  local function held_always() return true end
  local function held_still(still) return type(still) == "function" and still or held_always end

  local function record_of(port)
    local state = S.lib.grid_core.port_state(port)
    if not state.positions then state.positions = {hold = {}, store = {}, pressed = {}, bank = {}, slices = {}} end
    records[port] = state.positions
    return state.positions
  end

  -- The slice rows (3.7, design §10) ------------------------------------

  -- Whether a voice's position row shows slices: it reads a buffer, its
  -- `slices` option is not off and its slot has slices (S.lib.slices)
  function M.slice_row(voice_idx)
    return valid_voice(voice_idx) and S.lib.slices.takes_notes(voice_idx) == true
  end

  -- The count of slices the slot a voice reads holds (0 for none)
  local function slot_slices(voice_idx)
    local slot = buffer_voice(voice_idx) and voice_buffer_slot(voice_idx)
    if not slot then return 0 end
    return S.lib.slices.count(slot)
  end

  local function first_slice(bank) return (bank - 1) * SLICE_ROW.bank_size + 1 end

  local function bank_holds_slices(voice_idx, bank) return slot_slices(voice_idx) >= first_slice(bank) end

  -- The bank a port shows for a voice: its pick, or 1 when it has none or
  -- the slot's slices no longer reach the pick's first
  function M.bank(port, voice_idx)
    local record = records[port]
    local bank = valid_voice(voice_idx) and record and record.bank[voice_idx] or 1
    if not bank_holds_slices(voice_idx, bank) then return 1 end
    return bank
  end

  -- The bank a key reads (a slice key's press, a bank key's): a pick the
  -- slices no longer reach is forgotten here, so it never comes back when
  -- they reach again (markers deleted and added back with no bind)
  local function read_bank(port, voice_idx)
    local bank = M.bank(port, voice_idx)
    local record = records[port]
    if record and record.bank[voice_idx] ~= nil and record.bank[voice_idx] ~= bank then record.bank[voice_idx] = nil end
    return bank
  end

  -- A bind or unbind of a slot (S.lib.samples.on_bind): each pick of a
  -- voice reading it that its slices no longer reach goes back to 1. Only
  -- state changes: a listener never sends and never yields
  local function forget_unreached_banks(slot)
    for _, record in pairs(records) do
      for voice_idx, bank in pairs(record.bank) do
        if voice_buffer_slot(voice_idx) == slot and not bank_holds_slices(voice_idx, bank) then record.bank[voice_idx] = nil end
      end
    end
  end

  -- The listener goes in at the first pick of a bank (no pick exists to
  -- forget before one), once
  local function hear_binds()
    if binds_heard then return end
    binds_heard = true
    S.lib.samples.on_bind(forget_unreached_banks)
  end

  -- Whether a voice is in one shot with a moving scan, where a slice plays
  -- to its end whatever its key does (S.lib.scan.pass_seconds is a number)
  local function plays_to_end(voice_idx)
    return type(S.lib.scan.pass_seconds(voice_idx, 1)) == "number"
  end

  local function slice_note_key(port, n) return port * SLICE_ROW.port_key + n end

  -- A slice key's press: its slice plays at once, or at the beat or bar
  -- (the position key's quantized action, so a press replaces a waiting
  -- jump or slice of the voice). A cell with no slice does nothing
  local function press_slice_key(port, voice_idx, cell, pane, still)
    local n = first_slice(read_bank(port, voice_idx)) + cell - 1
    if n > slot_slices(voice_idx) then return end
    local entry = {n = n, pane = pane, still = held_still(still)}
    local note_key = slice_note_key(port, n)
    local _, token = S.lib.quantize.schedule("position" .. voice_idx, function()
      S.lib.slices.play(voice_idx, n, {owner = "grid", key = note_key, velocity = 1})
      -- released while it waited, and the release did not take it back
      if entry.released then S.lib.slices.note_off(voice_idx, "grid", note_key) end
    end, "v" .. voice_idx .. " sl " .. n)
    entry.token = token
    local held = record_of(port).slices
    held[voice_idx] = held[voice_idx] or {}
    held[voice_idx][cell] = entry
  end

  -- A slice key ends (its release, its grid's page change or removal): a
  -- play that still waits is taken back, but in one shot with a moving
  -- scan, where a tap plays at the beat; a play that ran gets its note off
  local function end_slice_key(port, voice_idx, entry)
    local action = "position" .. voice_idx
    if entry.token and S.lib.quantize.waiting(action, entry.token) then
      if plays_to_end(voice_idx) then
        entry.released = true
      else
        S.lib.quantize.cancel(action)
      end
      return
    end
    S.lib.slices.note_off(voice_idx, "grid", slice_note_key(port, entry.n))
  end

  -- The release of a slice key the port holds for a voice's cell: true
  -- when there was one. Each line is one voice's, so a release names the
  -- voice it was pressed for; two lines can hold the same cell
  local function release_slice_key(port, record, voice_idx, cell)
    local held = record.slices[voice_idx]
    local entry = held and held[cell]
    if not entry then return false end
    held[cell] = nil
    end_slice_key(port, voice_idx, entry)
    return true
  end

  -- End what a port's record holds that is stale: everything when its grid
  -- was removed (its state is gone), and each key whose `still` says its
  -- release can no longer come (held_still, above)
  local function end_stale_port(port, record)
    local state = S.lib.grid_core.existing_port_state(port)  -- a gone port gets no state back
    local gone = state == nil or state.positions ~= record
    local function stale(still) return gone or not still() end
    -- a voice's hold and store are held per pane (both panes of a 256 can
    -- show them): each stale pane's key leaves, and the key ends with its
    -- last
    local function stale_panes(panes)
      for pane, still in pairs(panes) do
        if stale(still) then panes[pane] = nil end
      end
      return next(panes) == nil
    end
    for voice_idx, panes in pairs(record.hold) do
      if stale_panes(panes) then
        record.hold[voice_idx] = nil
        M.hold_scan(voice_idx, false, "grid:" .. port)
      end
    end
    for voice_idx, panes in pairs(record.store) do
      if stale_panes(panes) then
        record.store[voice_idx] = nil
        record.pressed[voice_idx] = nil
      end
    end
    for voice_idx, pressed in pairs(record.pressed) do
      if stale_panes(pressed.panes) then record.pressed[voice_idx] = nil end
    end
    local held = record.held
    if held and stale(held.still) then record.held = nil end
    -- a slice key whose release can no longer come ends now
    for voice_idx, held in pairs(record.slices) do
      for cell, entry in pairs(held) do
        if stale(entry.still) then
          held[cell] = nil
          end_slice_key(port, voice_idx, entry)
        end
      end
    end
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

  -- Whether a port's store is down for a voice: the voice's own store key
  -- in any pane (3.8: every layout's lines are one voice each)
  local function storing(record, voice_idx)
    return record.store[voice_idx] ~= nil
  end

  -- A key held per pane (store, hold): `keys` is the record's table for
  -- the key ({[voice] = {[pane] = still}}, the pane it was pressed on and
  -- its still). Down adds the pane; up removes it and returns true when no
  -- pane holds the voice's key any more
  local function key_down(keys, voice_idx, pane, still)
    keys[voice_idx] = keys[voice_idx] or {}
    keys[voice_idx][pane] = held_still(still)
  end

  local function key_up(keys, voice_idx, pane)
    local held = keys[voice_idx]
    if held == nil then return true end
    held[pane] = nil
    if next(held) ~= nil then return false end
    keys[voice_idx] = nil
    return true
  end

  -- A key of a row of `cells` cells (design 3.3 section 5.2): a press jumps
  -- to its cell's start; with another key of the row held, it sets the loop
  -- from the lower cell's start to the higher cell's end. Only buffer voices
  -- respond; a release only ends the hold. On a voice whose row shows
  -- slices (M.slice_row) a key plays its slice of the port's bank instead,
  -- and its release ends it. pane (1 by default) is the grid pane the key
  -- is on; still (optional) is the press's test that its key is still held
  -- (held_still, above): the press ends at the next key or tick once it
  -- says false
  function M.grid_key(port, voice_idx, cell, cells, z, pane, still)
    if not valid_voice(voice_idx) or type(cells) ~= "number" or cells < 1 or cells % 1 ~= 0 then return end
    if type(cell) ~= "number" or cell < 1 or cell > cells or cell % 1 ~= 0 then return end
    if records[port] then end_stale_port(port, records[port]) end
    if z == 0 then
      local record = records[port]
      if record and release_slice_key(port, record, voice_idx, cell) then return end
      -- Both panes can hold the same cell. Only the current anchor's key releases it.
      local held = record and record.held
      if held and held.pane == (pane or 1) and held.voice == voice_idx and held.cells == cells and held.cell == cell then
        record.held = nil
      end
      return
    end
    if not buffer_voice(voice_idx) then return end
    if cells == SLICE_ROW.bank_size and M.slice_row(voice_idx) then
      press_slice_key(port, voice_idx, cell, pane or 1, still)
      return
    end
    local record = record_of(port)
    local held = record.held
    if held and held.voice == voice_idx and held.cells == cells and held.cell ~= cell then
      local low, high = math.min(held.cell, cell), math.max(held.cell, cell)
      S.lib.quantize.schedule("position" .. voice_idx, function() M.set_loop(voice_idx, (low - 1) / cells, high / cells) end,
        "v" .. voice_idx .. " jump", {voice = voice_idx, cell = cell})
      return
    end
    record.held = {voice = voice_idx, cell = cell, cells = cells, pane = pane or 1, still = held_still(still)}
    S.lib.quantize.schedule("position" .. voice_idx, function() M.jump(voice_idx, (cell - 1) / cells) end,
      "v" .. voice_idx .. " jump", {voice = voice_idx, cell = cell})
  end

  -- The strip's keys: 1-4 (recall; with store held, store), "store" and
  -- "hold" (held), "whole" (the loop back to the whole slot). pane (1 by
  -- default) and still (optional) as for grid_key
  function M.strip_key(port, voice_idx, key, z, pane, still)
    if not valid_voice(voice_idx) then return end
    if records[port] then end_stale_port(port, records[port]) end
    pane = pane or 1
    -- a press on a voice that reads no buffer records nothing (its keys are
    -- dark and do nothing); releases always end what they ended before
    if z == 1 and not buffer_voice(voice_idx) then return end
    -- while the voice's row shows slices, keys 1-4 pick the port's bank
    -- (one that holds none is not picked), store held or not
    if z == 1 and valid_bookmark(key) and M.slice_row(voice_idx) then
      read_bank(port, voice_idx)
      if bank_holds_slices(voice_idx, key) then
        record_of(port).bank[voice_idx] = key
        hear_binds()
      end
      return
    end
    if valid_bookmark(key) then
      if z == 1 then
        local record = record_of(port)
        if storing(record, voice_idx) then
          M.store_bookmark(voice_idx, key)
          local pressed = record.pressed[voice_idx]
          if not pressed or pressed.key ~= key then
            pressed = {key = key, panes = {}}
            record.pressed[voice_idx] = pressed
          end
          pressed.panes[pane] = held_still(still)
        else
          M.recall_bookmark_quantized(voice_idx, key)
        end
      elseif records[port] then
        local pressed = records[port].pressed[voice_idx]
        if pressed and pressed.key == key then
          pressed.panes[pane] = nil
          if next(pressed.panes) == nil then records[port].pressed[voice_idx] = nil end
        end
      end
    elseif key == "store" then
      if z == 1 then
        key_down(record_of(port).store, voice_idx, pane, still)
      elseif records[port] and key_up(records[port].store, voice_idx, pane) then
        records[port].pressed[voice_idx] = nil
      end
    elseif key == "hold" then
      if z == 1 then
        key_down(record_of(port).hold, voice_idx, pane, still)
        M.hold_scan(voice_idx, true, "grid:" .. port)
      elseif not records[port] or key_up(records[port].hold, voice_idx, pane) then
        M.hold_scan(voice_idx, false, "grid:" .. port)
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
    if not S.lib.playheads.has_audio(slot) then return nil end  -- as BUFFER's heads (#433)
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
    -- the context (its bins table above all) is reused while nothing it
    -- shows changed (the key holds everything a cell's level reads, and the
    -- peaks table's identity: the waveforms module replaces it when a slot's
    -- peaks change), so a redraw's cells share one. Never keyed by the
    -- time: the device's clock moves between two calls (#398)
    local peaks = S.lib.waveforms.peaks(slot)
    local key = table.concat({start, length, head_cell, record_cell or "-", S.buffers[slot].seconds, held_key}, ",")
    local cached = context_cache[voice_idx .. ":" .. cells]
    if cached and cached.key == key and cached.peaks == peaks then return cached.context end
    local context = {
      bins = S.lib.waveforms.bins(slot, cells), start = start, length = length, cells = cells,
      head_cell = head_cell, record_cell = record_cell, held_cells = held_cells,
    }
    context_cache[voice_idx .. ":" .. cells] = {key = key, peaks = peaks, context = context}
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

  -- What a slice row needs, once for all its cells: the port's bank's
  -- first slice, the count, the slices playing and the slice keys held
  -- (the port's; with no port, any port's, and bank 1)
  local function slice_context(voice_idx, port)
    local playing, held = {}, {}
    for _, n in ipairs(S.lib.slices.playing(voice_idx)) do playing[n] = true end
    for record_port, record in pairs(records) do
      if port == nil or record_port == port then
        for _, entry in pairs(record.slices[voice_idx] or {}) do held[entry.n] = true end
      end
    end
    return {first = first_slice(M.bank(port, voice_idx)), count = slot_slices(voice_idx), playing = playing, held = held}
  end

  local function slice_level(context, cell)
    local n = context.first + cell - 1
    if n > context.count then return LEVELS.slice_none end
    if context.playing[n] then return LEVELS.slice_playing end
    if context.held[n] then return LEVELS.slice_held end
    return LEVELS.slice
  end

  -- The LED level of cell `cell` of a voice's row of `cells` cells (0 for a
  -- voice that is not a buffer voice, or whose slot is empty); a slice
  -- row's at the port's bank
  function M.grid_level(voice_idx, cell, cells, port)
    if not valid_voice(voice_idx) or type(cells) ~= "number" or cells < 1 or cells % 1 ~= 0 then return 0 end
    if type(cell) ~= "number" or cell < 1 or cell > cells or cell % 1 ~= 0 then return 0 end
    if cells == SLICE_ROW.bank_size and M.slice_row(voice_idx) then return slice_level(slice_context(voice_idx, port), cell) end
    local context = row_context(voice_idx, cells)
    if not context then return 0 end
    -- the cell a waiting jump or loop was pressed on blinks once its key
    -- is up (#876; held, it shows the hold)
    if M.waiting_cell(voice_idx) == cell and not context.held_cells[cell] then
      return S.lib.grid_core.waiting_level()
    end
    return cell_level(context, cell)
  end

  -- The LED level of one of a voice's strip keys (1-4, "store", "hold",
  -- "whole"). With a port, "store" and a stored bookmark read only that
  -- port's keys (each grid shows its own); without one, any port's
  function M.strip_level(voice_idx, key, port)
    -- no key of a voice that reads no buffer does anything: all dark (#445)
    if not buffer_voice(voice_idx) then return 0 end
    if valid_bookmark(key) and M.slice_row(voice_idx) then
      if M.bank(port, voice_idx) == key then return LEVELS.bank_shown end
      return bank_holds_slices(voice_idx, key) and LEVELS.bank_filled or LEVELS.bank_empty
    end
    if valid_bookmark(key) then
      if any_record(function(record)
        local pressed = record.pressed[voice_idx]
        if pressed and pressed.key == key then
          -- A page change redraws before the stale sweep. Another grid can
          -- keep the same bookmark bright in the shared display signature.
          for _, still in pairs(pressed.panes) do
            if still() then return true end
          end
        end
      end, port) then
        return LEVELS.stored
      end
      if M.waiting_bookmark(voice_idx) == key then return S.lib.grid_core.waiting_level() end
      if M.last_recalled(voice_idx) == key then return LEVELS.recalled end
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
  -- value, which a recall or a scene fade moves. A slice row's levels and
  -- bank keys differ by port: they go in for no port and for each port
  -- this module has a record of (a port with none shows what no port does)
  local function add_slice_levels(parts, voice_idx)
    local ports = {}
    for port in pairs(records) do ports[#ports + 1] = port end
    table.sort(ports)
    for index = 0, #ports do
      local port = ports[index]  -- nil first
      local context = slice_context(voice_idx, port)
      for cell = 1, DISPLAY_CELLS do parts[#parts + 1] = slice_level(context, cell) end
      for n = 1, NUM_BOOKMARKS do parts[#parts + 1] = M.strip_level(voice_idx, n, port) end
    end
  end

  function M.display_signature()
    local parts = {}
    for voice_idx = 1, NUM_VOICES do
      if M.slice_row(voice_idx) then
        add_slice_levels(parts, voice_idx)
      else
        local context = row_context(voice_idx, DISPLAY_CELLS)
        for cell = 1, DISPLAY_CELLS do
          parts[#parts + 1] = context and cell_level(context, cell) or 0
        end
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

  -- randomize_draws: VOICE's ALT+K2 on the bookmarks section (#557), four
  -- uniform 0-1 positions in ascending order. VOICE draws them in row order,
  -- each set before the next is drawn, so bookmark n draws the lowest of the
  -- NUM_BOOKMARKS - n + 1 uniform positions left above bookmark n - 1 (above
  -- 0 for the first): 1 - (1 - previous) * u ^ (1 / left)
  local bookmark_keys, scene_defaults, scene_ranges, randomize_draws = {}, {}, {}, {}
  for n = 1, NUM_BOOKMARKS do
    local key = "bookmark_" .. n
    bookmark_keys[n] = key
    scene_defaults[key] = (n - 1) / NUM_BOOKMARKS
    scene_ranges[key] = {0, 1}
    randomize_draws[key] = function(voice_idx)
      local previous = n > 1 and params:get(param_id(voice_idx, bookmark_keys[n - 1])) or 0
      return 1 - (1 - previous) * math.random() ^ (1 / (NUM_BOOKMARKS - n + 1))
    end
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
        S.lib.params_setup.add_voice_param(voice_idx, record, key, {
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
      stop_glide_clock(voice_idx)
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
    randomize = randomize_draws,
  }
  S.register_voice_params(record)

  -- A grain restart (a running voice's source switch; a voiceOn) ends the
  -- glide; a source switch forgets the last recalled bookmark. A stopped
  -- voice's scene recall runs neither hook: last_recalled's source check
  -- covers it
  S.register_grain_restart(function(voice_idx)
    end_glide(voice_idx)
    recalled[voice_idx] = nil  -- a running voice's source switch, in a scene recall too (the source-change hook below never runs in one)
  end)
  S.register_source_change(function(voice_idx) recalled[voice_idx] = nil end)

  -- cleanup: no glide runs on, no scan stays held (every holder lets go)
  S.register_cleanup(S.constants.CLEANUP_ORDER.scrub_glide, function()
    for voice_idx = 1, NUM_VOICES do
      stop_glide_clock(voice_idx, true)
      turns[voice_idx] = nil
      if glide_rate[voice_idx] ~= 0 then set_scrub_rate(voice_idx, 0) end
      for holder in pairs(holders[voice_idx]) do M.hold_scan(voice_idx, false, holder) end
    end
  end)

  -- A glide's rate is sent only while its clock runs (3.9, #907): a rate
  -- with no clock would leave the engine gliding for good
  S.register_invariant("scrub glide", function()
    for voice_idx = 1, NUM_VOICES do
      if glide_rate[voice_idx] ~= 0 and not glide_clock[voice_idx] then
        return "voice " .. voice_idx .. " glides at rate " .. tostring(glide_rate[voice_idx]) .. " with no clock"
      end
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

  return M
end
