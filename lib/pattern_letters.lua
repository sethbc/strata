-- lib/pattern_letters.lua
-- Four patterns a voice (3.9 grid sequencer, package 4a, design section 3,
-- Variations, and section 6; S.lib.pattern_letters): the letters A to D,
-- the one each voice plays, and the patterns of the others it has used. A
-- pattern is the whole of it (S.lib.sequencer.whole: the levels, the
-- steps' settings, the lane lengths); the playing one stays in
-- S.patterns, S.pattern_steps and S.lib.lanes, so every reader of those is
-- untouched, and only the patterns not playing are kept here. A switch
-- stores the playing pattern under its letter and loads the other through
-- the sequencer's one door (replace_whole). The scene block variations
-- keeps them, with each voice's order. 4b: while the patterns play a
-- switch waits for the next bar of the sequencer's own count
-- (S.lib.sequencer.on_bar), and an order walks its letters a bar each. See
-- docs/notes/lua/pattern-letters.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL

  M.LETTERS = {"A", "B", "C", "D"}

  -- The letters' tunables, in one table
  local VARIATIONS = {
    first = "A",          -- the letter every voice plays at first
    max_order = 8,        -- an order holds up to eight letters (4b)
    pattern_keys = {levels = true, steps = true, lanes = true},
  }
  M.VARIATIONS = VARIATIONS

  local is_letter = {}
  for _, letter in ipairs(M.LETTERS) do is_letter[letter] = true end

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx == math.floor(voice_idx) and voice_idx >= 1
      and voice_idx <= NUM_VOICES
  end

  local function whole_between(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
  end

  -- A copy of a table of plain values and tables of them
  local function copy_of(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, inner in pairs(value) do copy[key] = copy_of(inner) end
    return copy
  end

  -- A voice's letters as the block holds them: {current, order, order_on,
  -- slots = {[letter] = pattern}}, slots holding only the used letters not
  -- playing
  local function fresh_voice()
    return {current = VARIATIONS.first, order = {}, order_on = false, slots = {}}
  end

  local voices = {}
  for voice_idx = 1, NUM_VOICES do voices[voice_idx] = fresh_voice() end

  -- 4b: what lives only while the patterns play, never stored: per voice
  -- the letter waiting for the next bar (nil for none) and the order's
  -- place, the index of the entry it played last (nil: its first entry at
  -- the next bar)
  local live = {waiting = {}, place = {}}

  -- The letter the voice plays (nil for no voice)
  function M.current(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    return voices[voice_idx].current
  end

  -- Whether the voice has used a letter: the playing one is used; another
  -- once a switch has stored a pattern under it, an empty one included
  function M.used(voice_idx, letter)
    if not valid_voice(voice_idx) or not is_letter[letter] then return false end
    local state = voices[voice_idx]
    return state.current == letter or state.slots[letter] ~= nil
  end

  -- Switch the voice to a letter now: the playing pattern is stored under
  -- the playing letter, then the other is loaded through replace_whole. A
  -- letter never used is first given a copy of the playing pattern, so
  -- the voice plays on unchanged; a used one is loaded as it is, empty or
  -- not. The playing letter, a bad voice or a bad letter does nothing.
  -- 4b: it leaves nothing waiting for the voice. load_letter is the switch
  -- without the grid's repaint, for the bar (whose step repaints the grid once);
  -- true when it loaded a pattern
  local function load_letter(voice_idx, letter)
    local state = voices[voice_idx]
    live.waiting[voice_idx] = nil
    if state.current == letter then return false end
    local seq = S.lib.sequencer
    local playing = seq.whole(voice_idx)
    local pattern = state.slots[letter] or seq.whole(voice_idx)
    state.slots[state.current], state.slots[letter], state.current = playing, nil, letter
    seq.replace_whole(voice_idx, pattern)
    request_redraw()
    return true
  end

  function M.switch_now(voice_idx, letter)
    if not valid_voice(voice_idx) or not is_letter[letter] then return end
    if load_letter(voice_idx, letter) then grid_redraw() end
  end

  -- 4b: the bar and the order ----------------------------------------------

  -- Up to max_order letters, keyed 1..n with no hole
  local function valid_order(order)
    if type(order) ~= "table" then return false end
    local count, last = 0, 0
    for index, letter in pairs(order) do
      if not whole_between(index, 1, VARIATIONS.max_order) or not is_letter[letter] then return false end
      count, last = count + 1, math.max(last, index)
    end
    return count == last
  end

  -- The letter waiting for the voice's next bar, or nil
  function M.waiting(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    return live.waiting[voice_idx]
  end

  -- The voice's order, a copy of its letters, and whether it is on (nil
  -- for no voice)
  function M.order(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    local state = voices[voice_idx]
    return copy_of(state.order), state.order_on
  end

  -- A switch by hand (the grid's letter keys, SEQ): it turns the voice's
  -- order off. With the patterns stopped it switches now (switch_now);
  -- while they play the letter waits for the next bar, the waiting letter
  -- again switches now, another letter replaces the one waiting, and the
  -- playing letter cancels the wait. A bad voice or letter does nothing
  function M.switch(voice_idx, letter)
    if not valid_voice(voice_idx) or not is_letter[letter] then return end
    voices[voice_idx].order_on = false
    if not S.pattern_playing or live.waiting[voice_idx] == letter then
      load_letter(voice_idx, letter)  -- repainted below, once
    elseif voices[voice_idx].current == letter then
      live.waiting[voice_idx] = nil
    else
      live.waiting[voice_idx] = letter
    end
    grid_redraw()
    request_redraw()
  end

  -- Turn the voice's order on (clearing a letter waiting; its place is its
  -- first entry, taken at the next bar) or off. An order with no letter is
  -- never on
  function M.set_order_on(voice_idx, on)
    if not valid_voice(voice_idx) or type(on) ~= "boolean" then return end
    local state = voices[voice_idx]
    on = on and #state.order > 0
    if on and not state.order_on then live.waiting[voice_idx], live.place[voice_idx] = nil, nil end
    state.order_on = on
    grid_redraw()
    request_redraw()
  end

  -- Set the voice's order (a copy) as the block's check holds it
  -- (valid_order: up to max_order letters, each one of LETTERS, keyed 1..n
  -- with no hole; anything else is refused), and turn it on, from its first
  -- entry; an empty one turns it off
  function M.set_order(voice_idx, letters)
    if not valid_voice(voice_idx) or not valid_order(letters) then return end
    voices[voice_idx].order, voices[voice_idx].order_on = copy_of(letters), false
    M.set_order_on(voice_idx, true)
  end

  -- A stop of the patterns (lib/sequencer.lua's pattern_clock_stop): no
  -- letter waits once they are stopped
  function M.end_waits()
    for voice_idx = 1, NUM_VOICES do live.waiting[voice_idx] = nil end
  end

  -- At each bar of the sequencer's own count (S.lib.sequencer.on_bar,
  -- after a chain link due then and before the bar's first step): each
  -- voice takes the letter waiting, or, with its order on, the order's next
  -- entry, wrapping (its first at the patterns' start, first, and after
  -- the order was turned on); an entry equal to the playing letter
  -- switches nothing. After a late wake that skipped bars the order moves
  -- on by the bars that passed (bars), wrapping, and switches once, to the
  -- entry it lands on, never loading those between (review round 1). The grid is repainted by the bar's step (one repaint
  -- a beat), so no switch here repaints it
  local function at_bar(first, bars)
    for voice_idx = 1, NUM_VOICES do
      local state, letter = voices[voice_idx], live.waiting[voice_idx]
      if first then live.place[voice_idx] = nil end
      if letter then
        load_letter(voice_idx, letter)
      elseif state.order_on and #state.order > 0 then
        local place = live.place[voice_idx]
        place = ((place or 0) + (bars or 1) - 1) % #state.order + 1
        live.place[voice_idx] = place
        load_letter(voice_idx, state.order[place])
      end
    end
  end
  S.lib.sequencer.on_bar(at_bar)

  -- The invariant pattern letters (docs/notes/lua/pattern-letters.md): a
  -- letter waits only while the patterns play and no order is on, and is
  -- not the one playing; every voice plays one of LETTERS
  S.register_invariant("pattern letters", function()
    for voice_idx = 1, NUM_VOICES do
      local state, letter = voices[voice_idx], live.waiting[voice_idx]
      if not is_letter[state.current] then
        return "voice " .. voice_idx .. " plays " .. tostring(state.current) .. ", none of the letters"
      end
      if letter ~= nil and (not S.pattern_playing or state.order_on or letter == state.current
          or not is_letter[letter]) then
        return "voice " .. voice_idx .. ": " .. tostring(letter) .. " waits with the patterns "
          .. (S.pattern_playing and "playing" or "stopped") .. ", the order " .. (state.order_on and "on" or "off")
          .. " and " .. tostring(state.current) .. " playing"
      end
    end
    return nil
  end)

  -- The block's check -------------------------------------------------------

  -- Sixteen whole levels 0..MAX_STEP_LEVEL and no other key
  local function valid_levels(levels)
    if type(levels) ~= "table" then return false end
    local count = 0
    for step, level in pairs(levels) do
      if not whole_between(step, 1, PATTERN_LENGTH) or not whole_between(level, 0, MAX_STEP_LEVEL) then return false end
      count = count + 1
    end
    return count == PATTERN_LENGTH
  end

  -- A block of NUM_VOICES empty tables but voice_idx's: value
  local function one_voice_block(voice_idx, value)
    local block = {}
    for index = 1, NUM_VOICES do block[index] = {} end
    block[voice_idx] = value
    return block
  end

  -- A stored pattern of the voice: levels as the patterns' check holds
  -- them (lib/scenes.lua's validate_scene), steps as the steps block's
  -- (S.lib.sequencer.valid_steps) and lanes as the lanes block's
  -- (S.lib.lanes.valid_block), each held for its own voice, and no other key
  local function valid_pattern(voice_idx, pattern)
    if type(pattern) ~= "table" then return false end
    for key in pairs(pattern) do
      if not VARIATIONS.pattern_keys[key] then return false end
    end
    return valid_levels(pattern.levels) and type(pattern.steps) == "table" and type(pattern.lanes) == "table"
      and S.lib.sequencer.valid_steps(one_voice_block(voice_idx, pattern.steps))
      and S.lib.lanes.valid_block(one_voice_block(voice_idx, pattern.lanes))
  end

  local VOICE_KEYS = {current = true, order = true, order_on = true, slots = true}

  local function valid_voice_letters(voice_idx, entry)
    if type(entry) ~= "table" then return false end
    for key in pairs(entry) do
      if not VOICE_KEYS[key] then return false end
    end
    if not is_letter[entry.current] or not valid_order(entry.order) or type(entry.order_on) ~= "boolean" then
      return false
    end
    if type(entry.slots) ~= "table" then return false end
    for letter, pattern in pairs(entry.slots) do
      if not is_letter[letter] or letter == entry.current or not valid_pattern(voice_idx, pattern) then return false end
    end
    return true
  end

  -- Whether a variations block holds NUM_VOICES voices' letters, each as
  -- the block keeps them
  local function valid_block(block)
    if type(block) ~= "table" then return false end
    for voice_idx, entry in pairs(block) do
      if not valid_voice(voice_idx) or not valid_voice_letters(voice_idx, entry) then return false end
    end
    for voice_idx = 1, NUM_VOICES do
      if block[voice_idx] == nil then return false end
    end
    return true
  end

  -- Every voice's letters as a block (a copy)
  function M.capture()
    local block = {}
    for voice_idx = 1, NUM_VOICES do block[voice_idx] = copy_of(voices[voice_idx]) end
    return block
  end

  -- Every voice's letters from a (valid) block, a copy of it: a recall's, a
  -- chain link's (lib/sequencer.lua's load_chain_scene), a chain start's
  -- undo (lib/mutation.lua). A voice the block lacks is on A alone. The
  -- playing pattern is not touched: a recall and a link load it with the
  -- patterns, steps and lanes blocks. Redraws are the caller's, as for
  -- every block. 4b (ruling 4b-3): it clears every waiting letter and
  -- order's place, so a recall or a link on the bar of a wait wins,
  -- whichever runs first
  function M.apply_block(block)
    for voice_idx = 1, NUM_VOICES do
      live.waiting[voice_idx], live.place[voice_idx] = nil, nil
      local entry = type(block) == "table" and block[voice_idx]
      voices[voice_idx] = type(entry) == "table" and copy_of(entry) or fresh_voice()
      -- an order with no letter is never on (a file's is read as off)
      if #voices[voice_idx].order == 0 then voices[voice_idx].order_on = false end
    end
  end

  -- The variations scene block: per voice the playing letter, the order and
  -- whether it is on, and the patterns not playing; switched at a
  -- transition's end. A scene without it is filled with letter A alone
  S.register_scene_block({
    key = "variations",
    default = function()
      local block = {}
      for voice_idx = 1, NUM_VOICES do block[voice_idx] = fresh_voice() end
      return block
    end,
    capture = M.capture,
    validate = valid_block,
    apply = M.apply_block,
    discrete = true,
  })

  return M
end
