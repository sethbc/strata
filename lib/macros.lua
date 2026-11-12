-- lib/macros.lua
-- The sixteen macros (3.4, design §4): the params macro_1 .. macro_16 (the
-- group strata_macros, which lib/params_setup.lua's macros record adds
-- through add_params), each moving up to eight targets (S.macros[m].targets,
-- {id, min, max}: a param id or v<i>_main, and the fractions of the
-- target's range the macro's 0 and 1 reach), applied by one clock for all
-- sixteen (S.macro_clock: a macro's next tick, at most MACROS.apply_hz
-- times a second, every write inside S.lib.engine_sync.deferrable). Scenes,
-- a transition and morph set a macro silently (set_silently, the scene
-- field's own set), so the scene's own target values stand. An LFO on a
-- macro (the global destinations macro 1 .. macro 16) moves its targets'
-- engine values, never a param: extra offsets on the Lua targets, the
-- matrix's fast extras on the fast ones, each through the LFOs' round
-- robin. The four banks of four are one shown bank (bank, set_bank), a
-- view only. Learn (learn, cancel_learn) takes the next hand-touched
-- target. The targets are stored in scenes (the block macros), beside each
-- PSET (<path_base>.macros.data) and in data/strata/macros.data, all
-- sparse, through S.lib.data_files. Registers the sources macro1 ..
-- macro16, the load and save steps, the clock's cleanup and the "macro
-- apply" and "macro learn" invariants. S.lib.macros holds the functions
-- and MACROS (the tunables).

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_MACROS = S.constants.NUM_MACROS
  local MACRO_BANK_SIZE = S.constants.MACRO_BANK_SIZE
  local MACRO_TARGETS = S.constants.MACRO_TARGETS

  -- apply_hz: applies a second at most, per macro; learn_seconds: how long
  -- learn waits for a touch; the files' format and names; never: the
  -- params no macro targets besides the macros themselves (a macro on a
  -- macro or on the morph could start a loop); lfo_skips: the target ids an
  -- LFO on a macro leaves alone (an LFO's own rate and depth, a matrix
  -- depth: no feedback, and no engine sender for an extra offset)
  local MACROS = {
    apply_hz = 30,
    learn_seconds = 10,
    save_delay = 0.1,  -- s from a change of the targets to the live file's write
    banks = math.floor(NUM_MACROS / MACRO_BANK_SIZE),
    epsilon = 1e-9,
    data_version = 1,
    live_file = "macros.data",          -- in data/strata/
    side_suffix = ".macros.data",       -- after a PSET's path without .pset
    backup_suffix = ".bak",
    never = {morph = true, morph_a = true, morph_b = true},
    lfo_skips = {"^strata_lfo%d+_rate$", "^strata_lfo%d+_depth$", "^matrix_%d+_depth$"},
  }
  M.MACROS = MACROS

  local function macro_id(m) return "macro_" .. m end
  local function source_key(m) return "macro" .. m end  -- the extra offsets' and the source's key

  local function is_index(value, count)
    return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= count
  end

  local function empty_row() return {id = "", min = 0, max = 1} end

  -- Per macro, its rows: S.macros[m].targets[k] = {id, min, max}, id ""
  -- for an empty row
  S.macros = {}
  for m = 1, NUM_MACROS do
    local targets = {}
    for k = 1, MACRO_TARGETS do targets[k] = empty_row() end
    S.macros[m] = {targets = targets}
  end
  S.macro_clock = nil        -- the apply clock, while a macro waits
  S.macro_learn_clock = nil  -- the learn timeout, while learn waits

  ---------------------------------------------------------------------------
  -- What a macro can target (design §4.2)
  ---------------------------------------------------------------------------

  local function is_control(id)
    local index = params.lookup[id]
    return index ~= nil and params.params[index].t == params.tCONTROL
  end

  local function never_target(id)
    return MACROS.never[id] or id:match("^macro_%d+$") ~= nil
  end

  -- The targets, built from the params that exist (rebuilt when params are
  -- added, so it is read after init): ids in order, known[id], labels[id]
  local catalog = {count = nil, ids = {}, known = {}, labels = {}}

  local function build_catalog()
    local ids, known, labels = {}, {}, {}
    local function add(id, label)
      if known[id] or never_target(id) then return end
      ids[#ids + 1] = id
      known[id] = true
      labels[id] = label
    end
    for _, entry in ipairs(S.LFO_DESTINATIONS) do
      local voice = entry.label:match("^v(%d+) main$")
      if voice then
        add("v" .. voice .. "_main", entry.label)
      else
        local id = entry.resolve()
        if id and is_control(id) then add(id, entry.label) end
      end
    end
    for n = 1, S.constants.NUM_LFOS do
      for _, field in ipairs({"rate", "depth"}) do
        local id = S.lib.lfos.param_id(n, field)
        if is_control(id) then add(id, "L" .. n .. " " .. field) end
      end
    end
    for k = 1, S.constants.MATRIX_SLOTS do
      local id = "matrix_" .. k .. "_depth"
      if is_control(id) then add(id, "R" .. k .. " depth") end
    end
    catalog = {count = #params.params, ids = ids, known = known, labels = labels}
  end

  local function current_catalog()
    if catalog.count ~= #params.params then build_catalog() end
    return catalog
  end

  -- Every target id (design §4.2): every LFO destination but none and the
  -- macros (a voice's main entry as v<i>_main), then each LFO's rate and
  -- depth, then each matrix routing's depth, only those whose params exist
  function M.target_ids()
    local ids = {}
    for index, id in ipairs(current_catalog().ids) do ids[index] = id end
    return ids
  end

  -- A target's label: its LFO destination's (v3 pitch, rev mix, v3 main),
  -- L<n> rate or depth, R<k> depth; an unknown id is its own text
  function M.target_label(id)
    return current_catalog().labels[id] or tostring(id)
  end

  -- The param a row's id moves now: v<i>_main through main_param_id (it
  -- follows the voice's source), a known id itself; nil for an empty row
  -- or an id this version has no target for
  local function resolve(id)
    if id == "" or not current_catalog().known[id] then return nil end
    local voice = id:match("^v(%d+)_main$")
    if voice then return main_param_id(tonumber(voice)) end
    return id
  end

  local function lfo_skips(id)
    for _, pattern in ipairs(MACROS.lfo_skips) do
      if id:match(pattern) then return true end
    end
    return false
  end

  ---------------------------------------------------------------------------
  -- An LFO on a macro (design §4.4): the targets' engine values move
  ---------------------------------------------------------------------------

  -- Per macro and row, the extra it holds: {id = the resolved param, fast}.
  -- Per macro, what its extras were last worked out from (computed[m]:
  -- the stored macro value, the targets' revision and each row's resolved
  -- param, false for none), and the targets' revision, which every change
  -- of a row raises
  local extras, computed, revisions = {}, {}, {}
  for m = 1, NUM_MACROS do
    extras[m] = {}
    revisions[m] = 0
  end

  local function fast_key(m, id) return source_key(m) .. " " .. id end

  -- The matrix sums a fast destination's extras into its setFastOffset
  -- (lib/matrix.lua); without a matrix a fast target does nothing
  local function set_fast_extra(m, id, value)
    local matrix = S.lib.matrix
    if matrix and matrix.set_fast_extra then matrix.set_fast_extra(source_key(m), id, value) end
  end

  local function send_target(id) send_param_to_engine(id, params:get(id)) end

  -- Clear row k's extra, its target sent again in the round robin
  local function clear_extra(m, k)
    local held = extras[m][k]
    if not held then return end
    extras[m][k] = nil
    if held.fast then
      S.lib.lfos.mark_due(fast_key(m, held.id), function() set_fast_extra(m, held.id, nil) end)
    else
      S.lib.engine_sync.set_extra_offset(source_key(m), held.id, nil)
      S.lib.lfos.mark_due(held.id, function() send_target(held.id) end)
    end
  end

  local function clear_extras(m)
    for k = 1, MACRO_TARGETS do clear_extra(m, k) end
  end

  -- What macro_<m>'s engine sender gets: the macro as an LFO modulates it
  -- (the stored value when nothing does). Per target, the difference
  -- between the target at that value and at the stored one: a Lua
  -- target's extra offset, a fast target's m in half ranges for the
  -- matrix (S.lib.lfos.m_for), each sent through the round robin; LFO-param
  -- and matrix-depth targets are skipped. The stored value clears every
  -- extra
  local function lfo_moved(m, value)
    value = util.clamp(value, 0, 1)
    local stored = params:get(macro_id(m))
    local seen = {stored = stored, revision = revisions[m], ids = {}}
    for k = 1, MACRO_TARGETS do
      local row = S.macros[m].targets[k]
      local id = resolve(row.id)
      seen.ids[k] = id or false
      local held = extras[m][k]
      if held and held.id ~= id then clear_extra(m, k) end  -- a main entry that resolves elsewhere now
      if value == stored or not id or lfo_skips(id) then
        clear_extra(m, k)
      else
        local spec = params:lookup_param(id).controlspec
        local at_stored = spec:map(row.min + stored * (row.max - row.min))
        local at_value = spec:map(row.min + value * (row.max - row.min))
        if S.lib.lfos.fast_destination(id) then
          extras[m][k] = {id = id, fast = true}
          local offset = S.lib.lfos.m_for(id, at_stored, at_value)
          S.lib.lfos.mark_due(fast_key(m, id), function() set_fast_extra(m, id, offset) end)
        else
          extras[m][k] = {id = id, fast = false}
          S.lib.engine_sync.set_extra_offset(source_key(m), id, at_value - at_stored)
          S.lib.lfos.mark_due(id, function() send_target(id) end)
        end
      end
    end
    computed[m] = seen
  end

  for m = 1, NUM_MACROS do
    S.engine_senders[macro_id(m)] = function(value) lfo_moved(m, value) end
  end

  -- Whether an LFO modulates macro m now (its Lua destination is the macro)
  local function modulated(m)
    local id = macro_id(m)
    for n = 1, S.constants.NUM_LFOS do
      if S.lfo_last_dest[n] == id then return true end
    end
    return false
  end

  -- Whether macro m's extras were worked out from what holds now: the
  -- stored value, the rows (their revision) and where each row resolves
  local function extras_current(m)
    local seen = computed[m]
    if not seen or seen.stored ~= params:get(macro_id(m)) or seen.revision ~= revisions[m] then return false end
    for k, row in ipairs(S.macros[m].targets) do
      if (resolve(row.id) or false) ~= seen.ids[k] then return false end
    end
    return true
  end

  -- The LFO step only sends a macro again once its modulated value moves,
  -- which a change of the stored value under the LFO's clamp, an edited or
  -- loaded row and a main entry resolving elsewhere never do: at each step
  -- (S.lib.lfos.on_step, after the LFOs, before the round robin's sends), a
  -- macro an LFO modulates, or one holding an extra, whose extras are no
  -- longer current has them worked out again from the macro as the LFOs
  -- modulate it now
  S.lib.lfos.on_step(function()
    for m = 1, NUM_MACROS do
      if (modulated(m) or next(extras[m]) ~= nil) and not extras_current(m) then
        lfo_moved(m, S.lib.engine_sync.with_lfo_offsets(macro_id(m), params:get(macro_id(m))))
      end
    end
  end)

  ---------------------------------------------------------------------------
  -- Applying (design §4.1)
  ---------------------------------------------------------------------------

  -- pending[m]: macro m waits for the clock; last[m]: its last apply's time
  local applying = {pending = {}, last = {}}
  local apply_errors = {}

  local function any_pending() return next(applying.pending) ~= nil end

  local function stop_clock()
    if S.macro_clock then
      clock.cancel(S.macro_clock)
      S.macro_clock = nil
    end
  end

  -- Drop macro m's waiting apply (every macro's when m is nil); the clock
  -- stops once none waits
  local function cancel_pending(m)
    if m then applying.pending[m] = nil else applying.pending = {} end
    if not any_pending() then stop_clock() end
  end

  local function set_target_value(id, fraction)
    params:set(id, params:lookup_param(id).controlspec:map(fraction))
  end

  -- Set every target with a known id to min + value x (max - min) of its
  -- range, along its warp, inside deferrable: the targets' actions send,
  -- the screen shows them and scenes capture them. Each row's set is
  -- contained: one that raises prints once (per row and message) and the
  -- other rows are still set
  local function apply_now(m)
    applying.pending[m] = nil
    applying.last[m] = util.time()
    local value = params:get(macro_id(m))
    S.lib.engine_sync.deferrable(function()
      for k = 1, MACRO_TARGETS do
        local row = S.macros[m].targets[k]
        local id = resolve(row.id)
        if id then
          S.lib.ui_frame.contained_call(apply_errors, m .. " " .. k, "macro " .. m .. " row " .. k .. " apply",
            set_target_value, id, row.min + value * (row.max - row.min))
        end
      end
    end)
  end

  -- The one clock for every macro: from its next tick, each waiting macro
  -- applies once 1 / apply_hz has passed since its last apply; it sleeps to
  -- the next one due and ends when none waits. An apply that raises prints
  -- once and the others go on
  local function start_clock()
    if S.macro_clock then return end
    S.macro_clock = clock.run(function()
      clock.sleep(0)
      while any_pending() do
        local now, next_due = util.time(), nil
        for m = 1, NUM_MACROS do
          if applying.pending[m] then
            local due = (applying.last[m] or -math.huge) + 1 / MACROS.apply_hz
            if due <= now + MACROS.epsilon then
              S.lib.ui_frame.contained_call(apply_errors, m, "macro " .. m .. " apply", apply_now, m)
            else
              next_due = next_due and math.min(next_due, due) or due
            end
          end
        end
        if next_due then clock.sleep(math.max(0, next_due - util.time())) end
      end
      S.macro_clock = nil
    end)
  end

  local function mark_pending(m)
    applying.pending[m] = true
    start_clock()
  end

  -- Apply macro m now (the clock's apply, for code that must not wait)
  function M.apply(m)
    if not is_index(m, NUM_MACROS) then return end
    apply_now(m)
    if not any_pending() then stop_clock() end
  end

  -- What a scene recall, a transition step and morph call (the scene
  -- field's set): the value without an apply, since the scene holds every
  -- target's own value; a hand move still waiting is dropped
  function M.set_silently(m, value)
    if not is_index(m, NUM_MACROS) then return end
    params:set(macro_id(m), value, true)
    cancel_pending(m)
  end

  ---------------------------------------------------------------------------
  -- The targets and their files
  ---------------------------------------------------------------------------

  -- The targets as stored (scenes, PSETs, the live file): sparse, [m][k] =
  -- {id, min, max} for the rows with an id only
  local function sparse()
    local block = {}
    for m = 1, NUM_MACROS do
      for k = 1, MACRO_TARGETS do
        local row = S.macros[m].targets[k]
        if row.id ~= "" then
          block[m] = block[m] or {}
          block[m][k] = {id = row.id, min = row.min, max = row.max}
        end
      end
    end
    return block
  end

  local function is_fraction(value)
    return type(value) == "number" and value == value and value >= 0 and value <= 1
  end

  -- What is wrong with a stored block, or nil: a table of macros 1-16,
  -- each a table of rows 1-8, each {id = a non-empty string, min and max
  -- in 0..1}. An id this version lacks is not wrong (kept verbatim)
  local function block_problem(block)
    if type(block) ~= "table" then return "no table of macros" end
    for m, rows in pairs(block) do
      if not is_index(m, NUM_MACROS) or type(rows) ~= "table" then return "no macro " .. tostring(m) end
      for k, row in pairs(rows) do
        if not is_index(k, MACRO_TARGETS) then return "macro " .. m .. " has no row " .. tostring(k) end
        if type(row) ~= "table" or type(row.id) ~= "string" or row.id == "" or not is_fraction(row.min)
            or not is_fraction(row.max) then
          return "macro " .. m .. " row " .. k .. " is no target"
        end
      end
    end
    return nil
  end

  -- Replace every row from a stored block (nil: every row empty); every
  -- extra an LFO held goes first
  local function load_block(block)
    for m = 1, NUM_MACROS do
      clear_extras(m)
      revisions[m] = revisions[m] + 1
      local rows = block and block[m]
      for k = 1, MACRO_TARGETS do
        local row = rows and rows[k]
        S.macros[m].targets[k] = row and {id = row.id, min = row.min, max = row.max} or empty_row()
      end
    end
  end

  -- A console line for every row whose id this version has no target for
  -- (a later or earlier release's param): kept, saved again, and it does
  -- nothing
  local function report_unknown(path)
    local known = current_catalog().known
    for m = 1, NUM_MACROS do
      for k = 1, MACRO_TARGETS do
        local id = S.macros[m].targets[k].id
        if id ~= "" and not known[id] then
          print("macros: " .. path .. ": macro " .. m .. " row " .. k .. " targets " .. id
            .. ", unknown here; kept, and it does nothing")
        end
      end
    end
  end

  -- Write the targets to path (none too, so a PSET saved over never keeps
  -- an older side file). Returns whether it was written
  local function write_file(path)
    local written, detail = S.lib.data_files.write(path, {version = MACROS.data_version, macros = sparse()})
    if not written then print("error: macros not saved to " .. path .. " (" .. tostring(detail) .. ")") end
    return written
  end

  -- Load the targets from path: a missing file loads them empty; one that
  -- cannot be used is set aside (path .. ".bak", ...) with a console line,
  -- and they load empty
  local function read_file(path)
    local loaded, problem, detail = S.lib.data_files.read(path)
    local why
    if loaded == nil and problem ~= "missing" then
      why = tostring(detail)
    elseif loaded ~= nil then
      if type(loaded) ~= "table" or loaded.version ~= MACROS.data_version then
        why = "not a version " .. MACROS.data_version .. " macros file"
      else
        why = block_problem(loaded.macros)
      end
    end
    if why then
      local backup, failure = S.lib.data_files.set_aside(path, MACROS.backup_suffix)
      print("error loading macros file " .. path .. ": " .. why .. "; "
        .. (backup and ("kept as " .. backup) or ("not moved: " .. tostring(failure))))
      loaded = nil
    end
    load_block(loaded and loaded.macros or nil)
    report_unknown(path)
  end

  -- The live file follows the targets once it has been loaded (a start
  -- step that failed never overwrites it): one write MACROS.save_delay s
  -- after the first change of a burst (MOD's E3 sets a row a detent),
  -- carrying the newest targets, from S.macro_save_clock; the cleanup step
  -- writes at once
  local live = {dir = _path.data .. "strata/", loaded = false}
  S.macro_save_clock = nil

  local function write_live()
    if not live.loaded then return end
    if util.file_exists(live.dir) == false then util.make_dir(live.dir) end
    write_file(live.dir .. MACROS.live_file)
  end

  local function save_live()
    if not live.loaded or S.macro_save_clock then return end
    S.macro_save_clock = clock.run(function()
      clock.sleep(MACROS.save_delay)
      S.macro_save_clock = nil
      write_live()
    end)
  end

  local function cancel_save()
    if S.macro_save_clock then
      clock.cancel(S.macro_save_clock)
      S.macro_save_clock = nil
    end
  end

  local function targets_changed()
    save_live()
    request_redraw()
    grid_redraw()
  end

  local function fraction_or(value, default)
    if type(value) ~= "number" or value ~= value then return default end
    return util.clamp(value, 0, 1)
  end

  local function set_row(m, k, id, min, max)
    clear_extra(m, k)
    revisions[m] = revisions[m] + 1
    if id == "" then
      S.macros[m].targets[k] = empty_row()
    else
      S.macros[m].targets[k] = {id = id, min = fraction_or(min, 0), max = fraction_or(max, 1)}
    end
    targets_changed()
  end

  -- Macro m's rows, a copy ({id, min, max} each); nil for no macro
  function M.targets(m)
    if not is_index(m, NUM_MACROS) then return nil end
    local rows = {}
    for k, row in ipairs(S.macros[m].targets) do rows[k] = {id = row.id, min = row.min, max = row.max} end
    return rows
  end

  -- Set row k of macro m: id one of target_ids() ("" empties the row),
  -- min and max clamped to 0..1 (min above max inverts). Saves the live
  -- file. Returns whether the row was set
  function M.set_target(m, k, id, min, max)
    if not (is_index(m, NUM_MACROS) and is_index(k, MACRO_TARGETS) and type(id) == "string") then return false end
    if id ~= "" and not current_catalog().known[id] then return false end
    set_row(m, k, id, min, max)
    return true
  end

  ---------------------------------------------------------------------------
  -- Learn (design §4.5)
  ---------------------------------------------------------------------------

  local learning = nil  -- {m, k} while learn waits for a touch

  function M.cancel_learn()
    if S.macro_learn_clock then
      clock.cancel(S.macro_learn_clock)
      S.macro_learn_clock = nil
    end
    if learning then
      learning = nil
      request_redraw()
    end
  end

  -- Arm learn for row k of macro m: the next hand-touched param that is a
  -- target becomes the row's id, at min 0 and max 1; cancel_learn (MOD's K2
  -- and page change) or learn_seconds without a touch cancels it. Returns
  -- whether it is armed
  function M.learn(m, k)
    if not (is_index(m, NUM_MACROS) and is_index(k, MACRO_TARGETS)) then return false end
    M.cancel_learn()
    learning = {m = m, k = k}
    S.macro_learn_clock = clock.run(function()
      clock.sleep(MACROS.learn_seconds)
      S.macro_learn_clock = nil
      learning = nil
      request_redraw()
    end)
    request_redraw()
    return true
  end

  -- The macro and row learn waits for, or nil
  function M.learning()
    if learning then return learning.m, learning.k end
    return nil
  end

  -- The target a touched param is: itself when it is one, else the main
  -- entry of the voice whose main param it is; nil when it is no target
  local function learnable(param_id)
    if current_catalog().known[param_id] and not param_id:match("^v%d+_main$") then return param_id end
    for voice_idx = 1, NUM_VOICES do
      local id = "v" .. voice_idx .. "_main"
      if main_param_id(voice_idx) == param_id and current_catalog().known[id] then return id end
    end
    return nil
  end

  S.register_param_touch(function(param_id)
    if not learning then return end
    local id = learnable(param_id)
    if not id then
      header_flash("not a macro target")
      return
    end
    local m, k = learning.m, learning.k
    M.cancel_learn()
    set_row(m, k, id, 0, 1)
    header_flash("M" .. m .. " > " .. M.target_label(id))
  end)

  ---------------------------------------------------------------------------
  -- Banks (design §4.6): a view only, session state
  ---------------------------------------------------------------------------

  local shown = {bank = 1}

  local function bank_of(m) return math.floor((m - 1) / MACRO_BANK_SIZE) + 1 end

  function M.bank() return shown.bank end

  -- Bank b's macro numbers, {4b - 3, ..., 4b} ({} for no bank)
  function M.bank_macros(b)
    local numbers = {}
    if not is_index(b, MACROS.banks) then return numbers end
    for index = 1, MACRO_BANK_SIZE do numbers[index] = (b - 1) * MACRO_BANK_SIZE + index end
    return numbers
  end

  -- Show bank b on every surface (MOD, its rings, the grids), with a flash;
  -- it moves no macro and sends nothing. Returns whether b is a bank
  function M.set_bank(b)
    if not is_index(b, MACROS.banks) then return false end
    shown.bank = b
    local numbers = M.bank_macros(b)
    header_flash("macros " .. numbers[1] .. "-" .. numbers[#numbers])
    request_redraw()
    grid_redraw()
    return true
  end

  -- Whether any macro of bank b has a target this version knows
  function M.bank_has_targets(b)
    for _, m in ipairs(M.bank_macros(b)) do
      for _, row in ipairs(S.macros[m].targets) do
        if resolve(row.id) then return true end
      end
    end
    return false
  end

  ---------------------------------------------------------------------------
  -- Params, registrations
  ---------------------------------------------------------------------------

  local function percent(param) return string.format("%d %%", math.floor(param:get() * 100 + 0.5)) end

  -- The group strata_macros (the menu record "macros" of
  -- lib/params_setup.lua adds it): each action waits for the clock
  function M.add_params()
    params:add_group("strata_macros", "macros", NUM_MACROS)
    for m = 1, NUM_MACROS do
      params:add{type = "control", id = macro_id(m), name = "macro " .. m,
        controlspec = controlspec.new(0, 1, "lin", 0, 0, ""), formatter = percent,
        action = function() mark_pending(m) end}
    end
  end

  -- MOD's macro row text: the first target's label and how many more
  -- (v3 pitch +2), "-" without one
  local function describe(m)
    local count, first = 0, nil
    for _, row in ipairs(S.macros[m].targets) do
      if row.id ~= "" then
        count = count + 1
        first = first or M.target_label(row.id)
      end
    end
    if count == 0 then return "-" end
    if count == 1 then return first end
    return first .. " +" .. (count - 1)
  end

  for m = 1, NUM_MACROS do
    -- the value, set silently by a recall, a transition and morph
    S.register_scene_field({id = macro_id(m), default = 0, set = function(value) M.set_silently(m, value) end})
    -- an LFO on macro m (design §4.4)
    S.register_lfo_global_destination("macro " .. m, macro_id(m))
    -- the source (design §10.1), shown in its bank; MOD opens the target
    -- view itself on K3
    S.register_mod_source({
      key = source_key(m),
      name = "M" .. m,
      section = "macros",
      range = {0, 1},
      value = function() return params:get(macro_id(m)) end,
      describe = function() return describe(m) end,
      visible = function() return bank_of(m) == shown.bank end,
      row = {
        enc = function(d) enc_param_delta(3, macro_id(m), d) end,
        fine_enc = function(d) delta_with_detent(macro_id(m), d, {fine = true}) end,
        hints = function(alt)
          if alt then return "" end
          return "K3:targets E3:value"
        end,
      },
    })
  end

  -- The scene block (design §4.3): the targets, sparse; discrete, so a
  -- fade applies them at its end, before the macro values. The recall
  -- redraws once it is applied
  S.register_scene_block({
    key = "macros",
    default = function() return {} end,
    capture = sparse,
    validate = function(value) return block_problem(value) == nil end,
    apply = function(value)
      load_block(value)
      save_live()
    end,
    discrete = true,
  })

  -- The PSET's side file: written with every PSET save (empty too), read
  -- after every PSET load (every waiting apply dropped first: the read ran
  -- the macros' actions, and the PSET holds its targets' own values),
  -- deleted with the PSET
  S.register_pset_hook({
    name = "macros",
    write = function(path_base) write_file(path_base .. MACROS.side_suffix) end,
    read = function(path_base)
      cancel_pending(nil)
      read_file(path_base .. MACROS.side_suffix)
      targets_changed()
    end,
    delete = function(path_base) os.remove(path_base .. MACROS.side_suffix) end,
  })

  -- The live file: loaded at init, saved at cleanup and as the targets change
  S.register_start(S.constants.START_ORDER.macros_load, function()
    read_file(live.dir .. MACROS.live_file)
    live.loaded = true
    request_redraw()
    grid_redraw()
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.macros_save, function()
    cancel_save()
    write_live()
  end)

  -- Cleanup cancels the apply clock (nothing waiting is applied) and learn
  S.register_cleanup(S.constants.CLEANUP_ORDER.macros, function()
    cancel_pending(nil)
    M.cancel_learn()
  end)

  -- A macro waits exactly while the apply clock runs, and that clock is a
  -- live coroutine
  S.register_invariant("macro apply", function()
    if any_pending() ~= (S.macro_clock ~= nil) then
      return "a macro waits: " .. tostring(any_pending()) .. ", but the clock is " .. tostring(S.macro_clock)
    end
    local thread = S.macro_clock and clock.threads and clock.threads[S.macro_clock]
    if S.macro_clock and type(thread) == "thread" and coroutine.status(thread) == "dead" then
      return "the macro clock " .. tostring(S.macro_clock) .. " has ended"
    end
  end)

  -- Learn waits exactly while its timeout clock runs
  S.register_invariant("macro learn", function()
    if (learning ~= nil) ~= (S.macro_learn_clock ~= nil) then
      return "learn waits: " .. tostring(learning ~= nil) .. ", but its clock is " .. tostring(S.macro_learn_clock)
    end
  end)

  return M
end
