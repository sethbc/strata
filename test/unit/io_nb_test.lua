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
  assert_equal(nb_player_refcounts.alpha, 0)
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
  -- duty 8 (ruling 24: the keyed module keeps the name)
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
  assert_equal(nb_player_refcounts.alpha, 0)
  assert_equal(nb_player_refcounts.zeta, 1)
  assert_equal(count(alpha, "inactive"), 2, "alpha left")
  assert_equal(count(zeta, "active"), 2, "zeta chosen")
  params:read(with_none)
  assert_equal(nb_player_refcounts.zeta, 0)
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

end
