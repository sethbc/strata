-- lib/input_level.lua
-- The input level (3.4, design §10.3), S.lib.input_level: norns' two input
-- level polls (the only code that names them: a norns poll has one
-- callback) run from the start step to the cleanup step at poll_hz, on
-- every page (refresh() looks them up again, at the start and at each BUFFER
-- visit). levels() returns the last two amplitudes, value() the louder
-- one times input_follow_gain, clamped to 0..1, and on_level(fn) runs fn
-- after each poll value (BUFFER's input meter redraws from it, only while
-- it shows). Registers the modulation source `input` (section audio) and
-- the group strata_input (one param, input_follow_gain).

return function(S)
  local M = {}

  local INPUT_LEVEL = {poll_hz = 30, polls = {"amp_in_l", "amp_in_r"}, gain_param = "input_follow_gain",
    hint = "E3:gain"}
  M.INPUT_LEVEL = INPUT_LEVEL

  -- amps: the latest value per poll; polls: the poll objects, per name;
  -- started: between the start step and cleanup; listeners: on_level's
  local state = {amps = {}, polls = {}, started = false, listeners = {}, errors = {}}

  function M.add_params()
    params:add_group("strata_input", "input", 1)
    params:add{type = "control", id = INPUT_LEVEL.gain_param, name = "input follow gain",
      controlspec = controlspec.new(1, 30, "exp", 0, 4)}
  end

  -- The last polled amplitudes (left, right), 0 before the first
  function M.levels()
    return state.amps.amp_in_l or 0, state.amps.amp_in_r or 0
  end

  -- The source's value: 0..1
  function M.value()
    local left, right = M.levels()
    return util.clamp(math.max(left, right) * params:get(INPUT_LEVEL.gain_param), 0, 1)
  end

  -- fn() runs after each poll value, on any page
  function M.on_level(fn)
    if type(fn) ~= "function" then error("input_level.on_level: fn is a function", 2) end
    table.insert(state.listeners, fn)
  end

  local function polled(name, value)
    if type(value) ~= "number" or value ~= value then value = 0 end
    state.amps[name] = value
    -- each listener runs contained: one that raises prints once per distinct
    -- message and stops no other
    for index, fn in ipairs(state.listeners) do
      S.lib.ui_frame.contained_call(state.errors, index, "input level listener", fn)
    end
  end

  -- Look both polls up again with poll.set, give them the module's callback
  -- and rate and start them, stopping an object held before when it is a
  -- different one: norns replaces its poll objects whenever it re-registers
  -- the polls (an engine load), so the start step and each BUFFER visit call
  -- this (#438), and it does nothing outside the start step and cleanup. A
  -- norns without the polls leaves the level at 0
  function M.refresh()
    if not state.started then return end  -- only between the start step and cleanup
    for _, name in ipairs(INPUT_LEVEL.polls) do
      local input_poll = poll.set(name, function(value) polled(name, value) end)
      local old = state.polls[name]
      if old and old ~= input_poll then
        old:stop()
        old.callback = nil
      end
      state.polls[name] = input_poll
      if input_poll then
        input_poll.time = 1 / INPUT_LEVEL.poll_hz
        input_poll:start()
      end
    end
  end

  S.register_start(S.constants.START_ORDER.input_level, function()
    state.started = true
    M.refresh()
  end)

  S.register_cleanup(S.constants.CLEANUP_ORDER.input_meter, function()
    state.started = false
    for _, name in ipairs(INPUT_LEVEL.polls) do
      local input_poll = state.polls[name]
      if input_poll then
        input_poll:stop()
        input_poll.callback = nil  -- a value already on its way reaches nothing
      end
    end
  end)

  -- The polls run from the start step to cleanup
  S.register_invariant("input level", function()
    if not state.started then return nil end
    for _, name in ipairs(INPUT_LEVEL.polls) do
      local input_poll = state.polls[name]
      if input_poll and not input_poll.running then return name .. " is not running" end
    end
    return nil
  end)

  S.register_mod_source({key = "input", name = "IN", section = "audio", range = {0, 1},
    value = M.value,
    describe = function() return string.format("%d%%", math.floor(M.value() * 100 + 0.5)) end,
    row = {
      enc = function(d) enc_param_delta(3, INPUT_LEVEL.gain_param, d) end,
      fine_enc = function(d) delta_with_detent(INPUT_LEVEL.gain_param, d, {fine = true}) end,
      hints = function() return INPUT_LEVEL.hint end,
    }})

  return M
end
