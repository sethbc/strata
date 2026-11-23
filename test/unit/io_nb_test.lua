-- test/unit/io_nb_test.lua
-- The nb host (lib/io/nb.lua, S.lib.io_nb, 3.6 design §7): each voice can
-- play one player an installed nb voice mod put in the global note_players,
-- and Strata does an nb host's eight duties itself
-- (docs/design/3.6-facts/checks.md §1, cited below by duty). Players come
-- from the nb stub (test/stub_nb.lua): plain tables with only the methods
-- a test names, added before the script loads.
-- Run alone: lua test/run.lua io_nb

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, assert_screen_layout = h.show_page, h.assert_screen_layout

-- Load with the players given (each {name, methods, inherited}) in
-- note_players before the script runs, as a voice mod's script_pre_init
-- hook leaves them; before (optional) runs first in before_load
local function started(players, before)
  local made = {}
  local context = load_strata({ before_load = function(context)
    if before then before(context) end
    for _, player in ipairs(players or {}) do
      made[player[1]] = context.nb.add_player(player[1], player[2], player[3])
    end
  end })
  finish_startup(context)
  return context, local_value("S"), made
end

local function calls_named(player, method)
  local list = {}
  for _, call in ipairs(player.calls) do
    if call[1] == method then list[#list + 1] = call end
  end
  return list
end

local function count(player, method) return #calls_named(player, method) end

local function options(id) return table.concat(params:lookup_param(id).options, " ") end

local function choose(voice, name) params:set("v" .. voice .. "_out_nb_key", name) end

local function nb_target(S)
  for _, target in ipairs(S.registry.note_targets) do
    if target.name == "nb" then return target end
  end
end

local function voice_rows(S)
  local rows = {}
  for _, row in ipairs(S.lib.pages_io.rows()) do
    if row.section == "voice" then rows[#rows + 1] = row end
  end
  return rows
end

local function write_pset(context, name)
  local path = context.data_dir .. name .. ".pset"
  params:write(path)
  return path
end

local ALL = { "note_on", "note_off", "stop_all", "active", "inactive", "add_params" }

-- Another nb host choosing and leaving a player, as nb's player base counts
-- (checks.md §1, duty 5: a nil entry means not chosen; it activates on nil
-- and removes the entry at 0): the test's own lines, no nb code
local function other_host_chooses(name)
  if nb_player_refcounts[name] == nil then
    nb_player_refcounts[name] = 1
    return true  -- it would call active
  end
  nb_player_refcounts[name] = nb_player_refcounts[name] + 1
  return false
end

local function other_host_leaves(name)
  if nb_player_refcounts[name] == nil then return false end
  nb_player_refcounts[name] = nb_player_refcounts[name] - 1
  if nb_player_refcounts[name] == 0 then
    nb_player_refcounts[name] = nil
    return true  -- it would call inactive
  end
  return false
end

-- A player whose method raises (a raw field, as a mod writes it); its calls still recorded
local function raising(player, method)
  player[method] = function(_, ...)
    table.insert(player.calls, { method, ... })
    error("probe " .. method .. " broke")
  end
end

test("with no voice mod the list is none and nothing is called", function()
  -- duty 1: nil or empty note_players gives the list none
  for _, before in ipairs({ function() _G.note_players = nil end, function() end }) do
    local _, S = started({}, before)
    for voice = 1, S.constants.NUM_VOICES do
      assert_equal(options("v" .. voice .. "_out_nb"), "none", "voice " .. voice .. "'s one option")
      assert_equal(S.lib.io_keyed.key("v" .. voice .. "_out_nb"), "none")
      assert_true(not nb_target(S).routed(voice), "not routed")
    end
    assert_equal(S.lib.io_nb.NB.none, "none")
    assert_equal(params.lookup["nb_sentinel_param"], nil, "no entry, no params to guard: no sentinel")
    assert_equal(params.lookup["strata_nb_players"], nil, "and no separator")
    toggle_voice(2)
    cleanup()
  end
end)

test("the group strata_out_nb holds each voice's option and its hidden key", function()
  local _, S = started({ { "alpha" } })
  local group = params:lookup_param("strata_out_nb")
  assert_true(group ~= nil, "the group exists")
  assert_equal(group.n, 2 * S.constants.NUM_VOICES, "14 params")
  for voice = 1, S.constants.NUM_VOICES do
    local key = params:lookup_param("v" .. voice .. "_out_nb_key")
    assert_true(key.hidden, "the key is hidden")
    assert_equal(params.lookup["v" .. voice .. "_out_nb_key"], params.lookup["v" .. voice .. "_out_nb"] + 1)
  end
end)

test("the list is the mods' players, sorted, without another host's midi players", function()
  -- duty 2 (a choice): midi: entries are nb's own MIDI players; a name a PSET cannot keep
  -- (docs/notes/lua/io/keyed.md) is left out with one console line
  local context = started({ { "zeta" }, { "alpha" }, { "midi: box 1" }, { "12" }, { " pad" },
    { "two\nlines" } })
  assert_equal(options("v1_out_nb"), "none alpha zeta")
  local newline_lines = 0
  for _, line in ipairs(context.printed) do
    if line:find('strata: nb player "two\\nlines" left out: a newline', 1, true) then newline_lines = newline_lines + 1 end
  end
  assert_equal(newline_lines, 1, "a name with a newline: one line, the newline written as \\n")
  for _, name in ipairs({ "12", " pad" }) do
    local lines = 0
    for _, line in ipairs(context.printed) do
      if line:find('"' .. name .. '"', 1, true) and line:find("nb", 1, true) then lines = lines + 1 end
    end
    assert_equal(lines, 1, "one console line names " .. name)
  end
end)

test("a name is left out by the keyed module's own check, with its reason", function()
  -- one check (S.lib.io_keyed.refuses), so the list never holds a key add would raise on
  local context = load_strata({
    before_load = function(c) c.nb.add_player("alpha"); c.nb.add_player("zeta") end,
    before_init = function()
      local keyed = local_value("S").lib.io_keyed
      local real = keyed.refuses
      keyed.refuses = function(key)
        if key == "zeta" then return "probe reason" end
        return real(key)
      end
    end })
  assert_equal(options("v1_out_nb"), "none alpha")
  local lines = 0
  for _, line in ipairs(context.printed) do
    if line == 'strata: nb player "zeta" left out: probe reason' then lines = lines + 1 end
  end
  assert_equal(lines, 1, "one line with the keyed module's reason")
end)

test("with defaults a player gets add_params once and nothing else", function()
  -- duty 7: every entry's own add_params, in name order (midi: included), then the hidden sentinel
  local order = {}
  local _, _, players = started({ { "zeta" }, { "alpha" }, { "midi: box 1" } })
  for name, player in pairs(players) do
    assert_equal(count(player, "add_params"), 1, name .. "'s add_params once")
    assert_equal(#player.calls, 1, name .. ": nothing else")
  end
  assert_true(params.lookup["nb_sentinel_param"] ~= nil, "the sentinel exists")
  local sentinel = params:lookup_param("nb_sentinel_param")
  assert_equal(sentinel.t, params.tBINARY)
  assert_true(sentinel.hidden, "and is hidden")
  assert_equal(params.lookup["strata_nb_players"], params.lookup["strata_out_nb"] + 15,
    "a separator ends the group before the players' params")
  -- the order: each player's own add_params logs its name
  started({}, function(context)
    for _, name in ipairs({ "zeta", "alpha", "midi: box 1" }) do
      local player = context.nb.add_player(name, { "note_on" })
      player.add_params = function() order[#order + 1] = name end
    end
  end)
  assert_equal(table.concat(order, "|"), "alpha|midi: box 1|zeta", "in name order")
  -- another host added them already: no add_params at all
  local _, _, again = started({ { "alpha" } }, function()
    params:add_binary("nb_sentinel_param", "nb_sentinel_param")
  end)
  assert_equal(count(again.alpha, "add_params"), 0, "the sentinel there: none")
end)

test("a method is called only when the mod wrote it", function()
  -- duty 3: rawget, never a metatable another host put on the table
  local _, S, players = started({ { "wrapped", { "note_on", "note_off" }, { "stop_all", "count_up", "active" } },
    { "own", { "note_on", "note_off", "stop_all" } } })
  local wrapped, own = players.wrapped, players.own
  choose(2, "wrapped"); choose(3, "own")
  local target = nb_target(S)
  target.note_on(2, "s1", 60, 0.5, { source = "step" }); target.note_off(2, "s1")
  toggle_voice(2)
  assert_equal(count(wrapped, "stop_all"), 0, "no inherited stop_all")
  assert_equal(count(wrapped, "count_up"), 0, "no inherited count_up")
  assert_equal(count(wrapped, "active"), 0, "no inherited active")
  assert_equal(count(wrapped, "note_on"), 1, "its own note_on")
  assert_true(getmetatable(wrapped) ~= nil, "its metatable left as it was")
  toggle_voice(3)  -- started (only voice 2 runs after start-up)
  assert_equal(count(own, "stop_all"), 0, "a start stops nothing")
  toggle_voice(3)
  assert_equal(count(own, "stop_all"), 1, "its own stop_all at the voice's stop")
end)

test("choosing a player names it, counts it and activates it once", function()
  -- duties 4, 5, 6
  local _, S, players = started({ { "alpha", ALL } })
  local alpha = players.alpha
  params:set("v2_out_nb", 2)
  assert_equal(S.lib.io_keyed.key("v2_out_nb"), "alpha")
  assert_equal(alpha.name, "alpha", "named before it is activated")
  assert_equal(nb_player_refcounts.alpha, 1)
  assert_equal(count(alpha, "active"), 1, "its own active once")
  choose(3, "alpha")
  assert_equal(nb_player_refcounts.alpha, 2)
  assert_equal(count(alpha, "active"), 1, "no second active")
  choose(2, "none")
  assert_equal(count(alpha, "inactive"), 0, "still chosen by voice 3")
  params:set("v3_out_nb", 1)
  assert_equal(nb_player_refcounts.alpha, nil, "removed at 0, as nb's count_down does")
  assert_equal(count(alpha, "inactive"), 1, "its own inactive once")
end)

test("the refcounts table is created when missing and never replaced", function()
  -- duty 5
  local shared = {}
  local _, _, players = started({ { "alpha", ALL } }, function() _G.nb_player_refcounts = shared end)
  choose(1, "alpha")
  assert_true(nb_player_refcounts == shared, "the same table")
  assert_equal(shared.alpha, 1)
  assert_equal(count(players.alpha, "active"), 1)
  -- another host's count: chosen there too, so Strata's choice activates nothing
  local _, _, others = started({ { "beta", ALL } }, function() _G.nb_player_refcounts = { beta = 1 } end)
  choose(1, "beta")
  assert_equal(nb_player_refcounts.beta, 2)
  assert_equal(count(others.beta, "active"), 0, "already active through the other host")
end)

test("a player with no active of its own gets nb's default, and delayed_active a second later", function()
  -- duty 6
  local context, S, players = started({ { "late", { "note_on", "note_off", "delayed_active" } } })
  local late = players.late
  choose(2, "late")
  assert_equal(late.is_active, true)
  assert_true(late.active_routine ~= nil, "a clock held in active_routine")
  context.clock.run_for(S.lib.io_nb.NB.delayed_seconds * 0.5)
  assert_equal(count(late, "delayed_active"), 0, "not before the second")
  context.clock.run_for(S.lib.io_nb.NB.delayed_seconds * 0.6)
  assert_equal(count(late, "delayed_active"), 1, "after it, once")
  -- deselected within the second: the clock canceled, no delayed_active
  choose(2, "none")
  assert_equal(late.is_active, false)
  choose(3, "late")
  context.clock.run_for(S.lib.io_nb.NB.delayed_seconds * 0.5)
  choose(3, "none")
  assert_equal(late.is_active, false)
  assert_equal(late.active_routine, nil, "the clock gone")
  context.clock.run_for(S.lib.io_nb.NB.delayed_seconds * 2)
  assert_equal(count(late, "delayed_active"), 1, "no second delayed_active")
end)

test("the activation clock stopped as its wake is posted: no clock error, and nothing more happens", function()
  -- #870 (duty 6): the player deselected after matron posted the clock's resume and before Lua
  -- delivered it; the clock ends at that wake and calls no delayed_active
  local context, S, players = started({ { "late", { "note_on", "note_off", "delayed_active" } } })
  local late = players.late
  choose(2, "late")
  local id = late.active_routine
  assert_true(id ~= nil, "a clock held in active_routine")
  -- deselected and chosen again in that gap: a new activation, its own clock
  local new_id
  context.clock.advance_until(id, function()
    choose(2, "none")
    choose(2, "late")
    new_id = late.active_routine
  end)
  assert_equal(#context.clock.take_errors(), 0, "no resume reached a canceled clock")
  assert_equal(clock.threads[id], nil, "the old clock ended at its wake")
  assert_equal(count(late, "delayed_active"), 0, "the old clock's wake calls no delayed_active")
  assert_true(new_id ~= nil and new_id ~= id, "a new clock")
  assert_equal(late.active_routine, new_id, "the new activation's clock is left alone")
  context.clock.run_for(S.lib.io_nb.NB.delayed_seconds * 1.1)
  assert_equal(count(late, "delayed_active"), 1, "the new activation's, once, a second after it")
  assert_equal(late.active_routine, nil, "and its clock gone")
end)

test("a player this module activated is deactivated though another host emptied the refcounts", function()
  -- duty 5: nbin's nb:init empties the table after Strata's init
  local _, _, players = started({ { "alpha", ALL }, { "plain", { "note_on", "note_off" } } })
  choose(2, "alpha"); choose(3, "plain")
  _G.nb_player_refcounts = {}
  choose(2, "none"); choose(3, "none")
  assert_equal(count(players.alpha, "inactive"), 1, "its own inactive once")
  assert_equal(players.plain.is_active, false, "the default's")
  -- and chosen by two voices: the first to leave does not deactivate it
  choose(2, "alpha"); choose(3, "alpha")
  _G.nb_player_refcounts = {}
  choose(2, "none")
  assert_equal(count(players.alpha, "inactive"), 1, "voice 3 still has it")
  choose(3, "none")
  assert_equal(count(players.alpha, "inactive"), 2)
end)

test("a stale is_active is cleared before the first count", function()
  -- duty 6: a carried-over entry with is_active from an earlier host
  local context, S, players = started({}, function(context)
    local player = context.nb.add_player("carried", { "note_on", "note_off", "delayed_active" })
    player.is_active = true
  end)
  local carried = players.carried or note_players.carried
  assert_equal(carried.is_active, false, "cleared at init")
  choose(1, "carried")
  assert_equal(carried.is_active, true)
  context.clock.run_for(S.lib.io_nb.NB.delayed_seconds * 1.1)
  assert_equal(count(carried, "delayed_active"), 1, "its activation still runs")
end)

test("a note goes to the voice's player as a whole note and a velocity", function()
  local _, S, players = started({ { "alpha" } })
  local alpha = players.alpha
  choose(2, "alpha")
  local target = nb_target(S)
  assert_true(target.routed(2), "voice 2 routed")
  assert_true(not target.routed(1), "voice 1 not")
  target.note_on(2, "s1", 60.4, 0.5, { source = "step" })
  local on = calls_named(alpha, "note_on")[1]
  assert_equal(on[2], 60); assert_equal(on[3], 0.5)
  target.note_off(2, "s1")
  assert_equal(calls_named(alpha, "note_off")[1][2], 60)
  target.note_on(2, "m61", 60.6, 1, { source = "midi", owner = "midi", key = 61 })
  assert_equal(calls_named(alpha, "note_on")[2][2], 61)
  target.note_off(2, "m61")
  assert_equal(calls_named(alpha, "note_off")[2][2], 61)
end)

test("a route change ends the voice's notes on the player they started on", function()
  local _, S, players = started({ { "alpha" }, { "beta" } })
  choose(2, "alpha")
  S.lib.io_targets.route_changed(2)
  local target = nb_target(S)
  -- through the core, so the off goes where the on went
  local event = { voice = 2, pitches = { 62 }, velocity = 0.7, beat = clock.get_beats(), gate_beats = 1000 }
  for _, output in ipairs(S.registry.step_outputs) do
    if output.name == "targets" then output.play(event) end
  end
  assert_equal(count(players.alpha, "note_on"), 1)
  choose(2, "beta")
  assert_equal(count(players.alpha, "note_off"), 1, "the old player's off")
  assert_equal(count(players.beta, "note_off"), 0)
  assert_true(target.routed(2))
end)

test("a voice's stop, cleanup and a PSET load stop the players that can be stopped", function()
  local context, S, players = started({ { "alpha", { "note_on", "note_off", "stop_all" } },
    { "beta", { "note_on", "note_off", "stop_all" } }, { "plain", { "note_on", "note_off" } } })
  choose(2, "alpha"); choose(3, "beta"); choose(4, "plain")
  toggle_voice(2)
  assert_equal(count(players.alpha, "stop_all"), 1, "voice 2's player")
  assert_equal(count(players.beta, "stop_all"), 0, "not voice 3's")
  local path = write_pset(context, "stops")
  params:read(path)
  assert_equal(count(players.alpha, "stop_all"), 2, "a PSET load: alpha")
  assert_equal(count(players.beta, "stop_all"), 1, "and beta")
  cleanup()
  assert_equal(count(players.alpha, "stop_all"), 3, "cleanup: alpha")
  assert_equal(count(players.beta, "stop_all"), 2, "and beta")
end)

test("a PSET keeps a player by name through a changed list", function()
  -- duty 8 (plan ruling 24: the keyed module keeps the name)
  local context = started({ { "alpha" } })
  choose(2, "alpha")
  local path = write_pset(context, "alpha")
  local _, S = started({ { "aaa" }, { "alpha" } })
  params:read(path)
  assert_equal(options("v2_out_nb"), "none aaa alpha")
  assert_equal(params:get("v2_out_nb"), 3, "alpha selected")
  assert_equal(S.lib.io_keyed.key("v2_out_nb"), "alpha")
  local lacking_context, lacking = started({ { "aaa" } })
  params:read(path)
  assert_equal(params:get("v2_out_nb"), 1, "none shown")
  assert_equal(params:get("v2_out_nb_key"), "alpha", "the name kept")
  assert_equal(lacking.lib.io_keyed.key("v2_out_nb"), "none")
  assert_true(not nb_target(lacking).routed(2), "nothing routed")
  local kept = write_pset(lacking_context, "kept")
  local _, again = started({ { "alpha" } })
  params:read(kept)
  assert_equal(again.lib.io_keyed.key("v2_out_nb"), "alpha", "a later load with it present selects it")
end)

test("a PSET read moving a voice between players counts each once", function()
  -- the keyed action runs at each key set, a read included: no double count, no activation lost
  local context, _, players = started({ { "alpha", ALL }, { "zeta", ALL } })
  local alpha, zeta = players.alpha, players.zeta
  choose(2, "alpha")
  local with_alpha = write_pset(context, "with_alpha")
  choose(2, "zeta")
  local with_zeta = write_pset(context, "with_zeta")
  choose(2, "none")
  local with_none = write_pset(context, "with_none")
  choose(2, "alpha")
  assert_equal(count(alpha, "active"), 2)
  params:read(with_alpha)
  assert_equal(nb_player_refcounts.alpha, 1, "the same player again: no second count")
  assert_equal(count(alpha, "active"), 2, "and no second active")
  params:read(with_zeta)
  assert_equal(nb_player_refcounts.alpha, nil)
  assert_equal(nb_player_refcounts.zeta, 1)
  assert_equal(count(alpha, "inactive"), 2, "alpha left")
  assert_equal(count(zeta, "active"), 2, "zeta chosen")
  params:read(with_none)
  assert_equal(nb_player_refcounts.zeta, nil)
  assert_equal(count(zeta, "inactive"), 2, "zeta left")
  params:read(with_none)
  assert_equal(count(zeta, "inactive"), 2, "none again: nothing")
  params:read(with_alpha)
  assert_equal(nb_player_refcounts.alpha, 1)
  assert_equal(count(alpha, "active"), 3, "alpha chosen by the read")
end)

test("a chosen player warns on IO, and marks the title while Strata does not lead", function()
  -- design §7, decision 21 (its line shortened to fit the row)
  local context, S = started({ { "alpha" } })
  local function warned()
    for _, row in ipairs(voice_rows(S)) do
      if row.shown == "nb mods send on their own" then return true end
    end
    return false
  end
  local function marked() return voice_rows(S)[1].status == "[!]" end
  local nb_row
  for _, row in ipairs(voice_rows(S)) do
    if row.param_id == "v" .. S.selected_voice .. "_out_nb" then nb_row = row end
  end
  assert_true(nb_row ~= nil and nb_row.label == "nb", "the param row nb")
  assert_true(not warned() and not marked(), "no voice with a player: neither")
  choose(5, "alpha")
  assert_true(warned(), "any voice with a player: the row")
  -- the warning fits a status row whole (design §7's "nb voices send on their own" is 2 px too wide)
  local io_page = S.lib.pages_io.IO_PAGE
  assert_true(screen.text_extents(S.lib.io_nb.NB.warning) <= io_page.value_right - io_page.row_indent,
    "the warning is never cut")
  for _, bus in ipairs({ "off", "teletype" }) do
    S.lib.io_rig.set("ii_bus", bus)
    assert_true(marked(), "ii_bus " .. bus .. ": [!]")
  end
  S.lib.io_rig.set("ii_bus", "strata")
  assert_true(not marked(), "ii_bus strata: no mark")
  assert_true(warned(), "the row stays")
  S.lib.io_rig.set("ii_bus", "off")
  show_page("IO"); S.lib.pages_io.show_section("voice"); redraw()
  assert_screen_layout(context, "IO voice section with an nb player")
  choose(5, "none")
  assert_true(not warned() and not marked(), "none again: neither")
end)

test("a player's own crow or ii lines never count as Strata's", function()
  -- design §7: the player records its calls apart from the crow stub
  local context, S, players = started({ { "jf voice" } })
  context.crow.plug()
  choose(2, "jf voice")
  local target = nb_target(S)
  for k = 1, 4 do
    target.note_on(2, "s" .. k, 60 + k, 0.8, { source = "step" })
    target.note_off(2, "s" .. k)
  end
  assert_equal(count(players["jf voice"], "note_on"), 4, "the player got its notes")
  for _, line in ipairs(context.crow.sent) do
    assert_true(line:sub(1, 3) ~= "ii.", "no ii line from Strata: " .. line)
  end
end)

test("a player Strata leaves is activated again by another host's choice", function()
  -- duty 5 against nb's count_up: the entry goes, so the other host sees nil and activates
  local _, _, players = started({ { "alpha", ALL } })
  choose(2, "alpha"); choose(2, "none")
  assert_equal(nb_player_refcounts.alpha, nil, "no entry left")
  assert_true(other_host_chooses("alpha"), "the other host activates it")
  assert_equal(nb_player_refcounts.alpha, 1)
  -- Strata choosing it now neither activates it again nor, on leaving, deactivates it
  choose(3, "alpha")
  assert_equal(nb_player_refcounts.alpha, 2)
  assert_equal(count(players.alpha, "active"), 1, "Strata's own activation only")
  choose(3, "none")
  assert_equal(nb_player_refcounts.alpha, 1, "the other host's count kept")
  assert_equal(count(players.alpha, "inactive"), 1, "Strata's own deactivation only")
  assert_true(other_host_leaves("alpha"), "the other host's leave ends it")
end)

test("a player another host holds is neither activated nor deactivated by Strata", function()
  local _, _, players = started({ { "beta", ALL } }, function() _G.nb_player_refcounts = { beta = 1 } end)
  choose(2, "beta")
  assert_equal(nb_player_refcounts.beta, 2)
  choose(2, "none")
  assert_equal(nb_player_refcounts.beta, 1, "left at 1")
  assert_equal(count(players.beta, "active"), 0, "no active")
  assert_equal(count(players.beta, "inactive"), 0, "no inactive")
end)

test("a player whose add_params raises leaves init and the other players whole", function()
  local context = load_strata({ before_load = function(c)
    raising(c.nb.add_player("alpha"), "add_params")
    c.nb.add_player("zeta")
  end })
  finish_startup(context)
  h.claim_script_errors(context, 1, "strata: nb player alpha add_params failed: ", "probe add_params broke")
  local S = local_value("S")
  assert_equal(count(note_players.zeta, "add_params"), 1, "the next player's add_params ran")
  assert_true(params.lookup["nb_sentinel_param"] ~= nil, "the sentinel added")
  assert_true(params.lookup["tapeloop"] ~= nil, "the groups after it added")
  assert_equal(options("v1_out_nb"), "none alpha zeta", "both listed")
  choose(1, "alpha")
  assert_equal(nb_player_refcounts.alpha, 1)
  assert_true(nb_target(S).routed(1))
end)

test("a player whose note_on, active or stop_all raises acts as if the call returned", function()
  local context, S, players = started({ { "alpha", ALL }, { "zeta", ALL } })
  raising(players.alpha, "active")
  choose(2, "alpha")
  h.claim_script_errors(context, 1, "strata: nb player alpha active failed: ", "probe active broke")
  assert_equal(nb_player_refcounts.alpha, 1, "counted")
  assert_equal(S.lib.io_keyed.key("v2_out_nb"), "alpha", "chosen")
  choose(3, "zeta")
  assert_equal(count(players.zeta, "active"), 1, "the next player activated")
  raising(players.alpha, "note_on")
  local target = nb_target(S)
  target.note_on(2, "s1", 60, 0.5, { source = "step" })
  h.claim_script_errors(context, 1, "strata: nb player alpha note_on failed: ", "probe note_on broke")
  target.note_on(3, "s1", 64, 0.5, { source = "step" })
  assert_equal(count(players.zeta, "note_on"), 1, "the other voice's player plays")
  target.note_off(2, "s1")
  assert_equal(calls_named(players.alpha, "note_off")[1][2], 60, "the off still reaches the player")
  raising(players.alpha, "stop_all")
  cleanup()
  h.claim_script_errors(context, 1, "strata: nb player alpha stop_all failed: ", "probe stop_all broke")
  assert_equal(count(players.zeta, "stop_all"), 1, "the other player still stopped")
  assert_equal(nb_player_refcounts.alpha, 1, "counts untouched")
  assert_equal(nb_player_refcounts.zeta, 1)
end)

test("the keyed module's PSET hook runs before this module's, so a read ends on the players it chose", function()
  -- register_pset_hook appends, the hooks run in registration order, and lib/io/keyed.lua is included first
  local context, S, players = started({ { "alpha", ALL }, { "zeta", ALL } })
  local order = {}
  for index, hook in ipairs(S.registry.pset_hooks) do order[hook.name] = index end
  assert_true(order.io_keyed < order.io_nb, "io_keyed's hook first")
  local alpha, zeta = players.alpha, players.zeta
  choose(2, "zeta")
  local with_zeta = write_pset(context, "order_zeta")
  choose(2, "alpha")
  params:read(with_zeta)
  assert_equal(S.lib.io_keyed.key("v2_out_nb"), "zeta", "the new player chosen")
  assert_equal(nb_player_refcounts.zeta, 1, "counted once")
  assert_equal(count(zeta, "active"), 2, "activated once by the read")
  assert_equal(count(alpha, "inactive"), 1, "the old one released once")
  assert_equal(count(zeta, "stop_all"), 1, "stop_all reaches the player chosen after the read")
  assert_equal(count(alpha, "stop_all"), 0, "not the one it left")
  -- a PSET saved before the param (no key line): the keyed hook puts the voice on none, then this hook runs
  local file = io.open(with_zeta, "r")
  local text = file:read("*a")
  file:close()
  local older = context.data_dir .. "order_older.pset"
  file = io.open(older, "w")
  file:write((text:gsub('"v2_out_nb_key"[^\n]*\n', "")))
  file:close()
  params:read(older)
  assert_equal(S.lib.io_keyed.key("v2_out_nb"), "none", "the keyed hook chose none")
  assert_equal(nb_player_refcounts.zeta, nil, "released")
  assert_equal(count(zeta, "stop_all"), 1, "no stop_all for a player no voice has after the read")
end)

test("the nb params stay out of scenes, LFOs, macros, fader pages, randomize, mutation and drift", function()
  -- the plan's Params constraint: PSET-only
  local _, S = started({ { "alpha" } })
  local ids = {}
  for voice = 1, S.constants.NUM_VOICES do
    ids["v" .. voice .. "_out_nb"] = true
    ids["v" .. voice .. "_out_nb_key"] = true
  end
  capture_scene(1)
  local function walk(value, path)
    if type(value) ~= "table" then return end
    for key, inner in pairs(value) do
      assert_true(not ids[key], "a scene holds " .. tostring(key) .. " at " .. path)
      walk(inner, path .. "." .. tostring(key))
    end
  end
  walk(S.scenes[1], "scene 1")
  for _, destination in ipairs(S.LFO_DESTINATIONS) do
    local id = destination.resolve()
    assert_true(not ids[id or ""], "an LFO destination " .. tostring(id))
  end
  for _, id in ipairs(S.lib.macros.target_ids()) do assert_true(not ids[id], "a macro target " .. id) end
  for _, record in ipairs(S.registry.macro_targets) do assert_true(not ids[record.id], "registered " .. record.id) end
  for _, source in ipairs({ 1, 2, 10 }) do  -- synth, buffer 1, input
    params:set("v1_source", source)
    for _, id in ipairs(fader_param_ids(1)) do assert_true(not ids[id], "a fader param " .. id .. " (" .. source .. ")") end
  end
  params:set("v1_source", 1)
  -- the voices checked run and are unlocked, whatever start-up left: mutation and drift touch only
  -- active, unlocked voices (lib/mutation.lua), and randomize skips a locked one
  for _, voice in ipairs({ 1, 4 }) do
    if not S.voices[voice].active then toggle_voice(voice) end
    if S.locked[voice] then toggle_lock(voice) end
    assert_true(S.voices[voice].active and not S.locked[voice], "voice " .. voice .. " runs, unlocked")
  end
  choose(1, "alpha"); choose(4, "alpha")
  -- each effect's positive control: a param of the voice moved. What makes each hold (the seed does
  -- not: pairs() order over a voice's params changes which draw each param gets):
  -- the randomize: twenty randomizes, each drawing many continuous params uniformly over their range,
  -- so not one of them moving cannot happen; the mutation: at probability 1 every synth param but amp
  -- and pan moves each step by a continuous delta, twenty steps, on a param mostly not at a range edge;
  -- the drift: the grain pitch starts mid-range at 1 (its base with it), where a step of at most 0.002
  -- a tick never meets the 0.25 and 4 clamps, and the check is "moved at some tick of fifty" (a tick's
  -- step is 0 only when its draw is exactly 0.5)
  local function snapshot(voice)
    local copy = {}
    for _, key in ipairs(S.voices[voice].param_order) do copy[key] = S.voices[voice].values[key] end
    copy.grain_pitch = S.voices[voice].values.grain_pitch
    return copy
  end
  local function moved(before, voice)
    local now = snapshot(voice)
    for key, value in pairs(before) do
      if now[key] ~= value then return true end
    end
    return false
  end
  math.randomseed(11)
  local before = snapshot(1)
  for _ = 1, 20 do randomize_voice(1) end
  assert_true(moved(before, 1), "MAIN's randomize moved voice 1")
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  local before_mutation = { snapshot(1), snapshot(4) }
  for _ = 1, 20 do gentle_mutate() end
  assert_true(moved(before_mutation[1], 1), "the mutation moved voice 1")
  assert_true(moved(before_mutation[2], 4), "the mutation moved voice 4")
  local drifted = {}
  for _, voice in ipairs({ 1, 4 }) do params:set("v" .. voice .. "_grain_pitch", 1) end
  for _ = 1, 50 do
    drift_update()
    for _, voice in ipairs({ 1, 4 }) do
      if S.voices[voice].values.grain_pitch ~= 1 then drifted[voice] = true end
    end
  end
  assert_true(drifted[1], "the drift moved voice 1's grain pitch at some tick")
  assert_true(drifted[4], "the drift moved voice 4's grain pitch at some tick")
  assert_equal(S.lib.io_keyed.key("v1_out_nb"), "alpha", "voice 1 keeps its player")
  assert_equal(S.lib.io_keyed.key("v4_out_nb"), "alpha", "voice 4 too")
  assert_equal(nb_player_refcounts.alpha, 2, "counted as before")
end)

test("two Strata voices on a player another host holds neither activate nor deactivate it", function()
  -- the other host's count of 1 (it chose the player first), then voices 2 and 3, leaving in each order
  for _, leaving in ipairs({ { 2, 3 }, { 3, 2 } }) do
    local _, _, players = started({ { "beta", ALL } }, function() _G.nb_player_refcounts = {} end)
    assert_true(other_host_chooses("beta"), "the other host activates it")
    choose(2, "beta")
    assert_equal(nb_player_refcounts.beta, 2)
    choose(3, "beta")
    assert_equal(nb_player_refcounts.beta, 3)
    choose(leaving[1], "none")
    assert_equal(nb_player_refcounts.beta, 2, "voice " .. leaving[1] .. " left first")
    choose(leaving[2], "none")
    assert_equal(nb_player_refcounts.beta, 1, "then voice " .. leaving[2])
    assert_equal(count(players.beta, "active"), 0, "no active from Strata")
    assert_equal(count(players.beta, "inactive"), 0, "no inactive from Strata")
    assert_true(other_host_leaves("beta"), "the other host's own leave ends it")
    assert_equal(nb_player_refcounts.beta, nil)
  end
end)

end
