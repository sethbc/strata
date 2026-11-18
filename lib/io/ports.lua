-- lib/io/ports.lua
-- The MIDI ports (3.6 design §0.2), S.lib.io_ports: the one module that
-- sets midi.add, midi.remove (on norns' own module, whatever a mod put in
-- the global midi) and a MIDI vport's event. Each of norns' 16
-- ports takes any number of listeners (listen, unlisten), called in the
-- order their names were first registered, each contained; out(port) is a
-- port's vport for sending, device(port) its device's name; on_change tells
-- of a device arriving at or leaving a port (hot-plug, and a move made in
-- SYSTEM > DEVICES once the menu closes); claim gives a port one owner (a
-- controller, a remote grid), which lib/midi_in.lua then leaves alone;
-- on_settled tells of a port once its arrival or release has reached every
-- change and claim hook (MIDI out's zone setup goes from there, #772). The
-- start step keeps the hot-plug handlers it finds and calls them after its
-- own listeners; the cleanup step puts them back and clears every event it
-- set. See docs/notes/lua/io/ports.md.

return function(S)
  local M = {}

  -- norns' own MIDI module: the one its startup loaded (midi = require
  -- 'core/midi'), whatever a mod put in the global midi since. The nbout
  -- mod's facade there (from each script's pre-init hook to its cleanup)
  -- has no __newindex, so a handler assigned to it is never called by
  -- norns' hot-plug (#700). The global where norns' module is not found (the
  -- test stubs). The hot-plug handlers are installed and put back on it,
  -- and every vport is read from it: the facade's vports is a fresh copy at
  -- each read, with an entry of its own after norns' sixteen. Each function
  -- reads the vports once, never per port
  local function norns_midi()
    local loaded = package.loaded["core/midi"]
    if type(loaded) == "table" and type(loaded.vports) == "table" then return loaded end
    return midi
  end

  -- count: how many MIDI ports norns has (its own vports, 16), never a
  -- facade's count. Every other module reads the ports through this one:
  -- PORTS.count, out(port) and device(port)
  local PORTS = {count = #norns_midi().vports}
  M.PORTS = PORTS

  -- An ordered set of named functions: names in the order first registered
  local function new_set() return {names = {}, fns = {}} end

  -- listeners[port]: the port's set (nil without one); dispatchers[port]:
  -- the function the port's vport event is while it has listeners; owners:
  -- port -> name; seen: port -> the device last seen on it; hot_plug: the
  -- handlers found installed, and whether ours are
  local state = {
    listeners = {}, dispatchers = {}, owners = {}, seen = {}, errors = {}, leaving = {},
    changes = new_set(), claims = new_set(), settles = new_set(),
    -- telling: how many arrivals, departures and releases are being told
    -- (one inside another's hooks counts); unsettled: the ports whose
    -- arrival or release was told meanwhile, each once, in the order told;
    -- settling: their settled hooks are running
    telling = 0, unsettled = {}, settling = false,
    -- wrapped_*: a cleanup found something installed over ours, which then
    -- stays and still leads to ours; entered_*: ours is running
    hot_plug = {kept_add = nil, kept_remove = nil, installed = false, wrapped_add = false, wrapped_remove = false,
      entered_add = false, entered_remove = false},
  }

  local function valid_port(port)
    return type(port) == "number" and port % 1 == 0 and port >= 1 and port <= PORTS.count
  end

  local function require_name(kind, name)
    if type(name) ~= "string" or name == "" then error("io_ports." .. kind .. ": a name is a non-empty string", 3) end
  end

  local function require_fn(kind, fn)
    if type(fn) ~= "function" then error("io_ports." .. kind .. ": fn is a function", 3) end
  end

  local function set_entry(set, name, fn)
    if set.fns[name] == nil then set.names[#set.names + 1] = name end
    set.fns[name] = fn
  end

  local function remove_entry(set, name)
    if set.fns[name] == nil then return end
    set.fns[name] = nil
    for index, entry in ipairs(set.names) do
      if entry == name then table.remove(set.names, index) break end
    end
  end

  -- Each of set's functions in order, on a copy of the names (one may
  -- unlisten or register while they run), each contained: one that raises
  -- prints one line and the next still runs
  local function run_set(set, label, ...)
    local names = {}
    for index, name in ipairs(set.names) do names[index] = name end
    for _, name in ipairs(names) do
      local fn = set.fns[name]
      if fn then S.lib.ui_frame.contained_call(state.errors, label .. " " .. name, label .. " " .. name, fn, ...) end
    end
  end

  -- run() (which tells hooks of port's arrival, departure or release), then,
  -- unless it is inside another such telling, the settled hooks of each port
  -- whose arrival or release (settles) was told meanwhile: so a claim or
  -- release a hook made inside it is told before the port settles, and the
  -- port settles once. A telling inside a settled hook joins the ports
  -- still to settle. An error is raised again once the count is restored
  local function told(port, settles, run)
    state.telling = state.telling + 1
    local ran, problem = pcall(run)
    state.telling = state.telling - 1
    if settles then
      local queued = false
      for _, entry in ipairs(state.unsettled) do queued = queued or entry == port end
      if not queued then state.unsettled[#state.unsettled + 1] = port end
    end
    if state.telling == 0 and not state.settling then
      state.settling = true
      while #state.unsettled > 0 do
        run_set(state.settles, "midi settled hook", table.remove(state.unsettled, 1))
      end
      state.settling = false
    end
    if not ran then error(problem, 0) end
  end

  local function dispatcher(port)
    if state.dispatchers[port] == nil then
      state.dispatchers[port] = function(data)
        local set = state.listeners[port]
        if set then run_set(set, "midi port " .. port .. " listener", data) end
      end
    end
    return state.dispatchers[port]
  end

  -- fn(data) gets every message of the port; the same name again replaces
  -- its function and keeps its place. A port outside 1..16 does nothing
  function M.listen(port, name, fn)
    require_name("listen", name)
    require_fn("listen", fn)
    if not valid_port(port) then return nil end
    state.listeners[port] = state.listeners[port] or new_set()
    set_entry(state.listeners[port], name, fn)
    norns_midi().vports[port].event = dispatcher(port)
    return true
  end

  -- The port's last listener gone, its vport has no event
  function M.unlisten(port, name)
    local set = valid_port(port) and state.listeners[port]
    if not set then return end
    remove_entry(set, name)
    if #set.names > 0 then return end
    state.listeners[port] = nil
    local vport = norns_midi().vports[port]
    if vport.event == state.dispatchers[port] then vport.event = nil end
  end

  -- The port's vport, to send through, or nil
  function M.out(port)
    if not valid_port(port) then return nil end
    return norns_midi().vports[port]
  end

  -- The name of the device on the port, or nil. nil too from the moment its
  -- device's removal enters the module until removed returns: norns clears
  -- the vport only after midi.remove, so the vport still names a device
  -- that is leaving while the hooks run, and an owner that releases the port
  -- there would hand it on (#704)
  function M.device(port)
    if not valid_port(port) or state.leaving[port] then return nil end
    local vport = norns_midi().vports[port]
    if vport.device == nil then return nil end
    return vport.name
  end

  -- Whether the port's device has a device-level event handler set
  -- (norns' midi.devices[id].event, called before the vport's): Strata
  -- never sets one, and norns' midi.cleanup clears them, so a set one is
  -- another library's, as midigrid's on the Launchpad it takes
  -- (docs/design/3.6-facts/checks.md §7)
  function M.device_handled(port)
    if not valid_port(port) or state.leaving[port] then return false end
    local device = norns_midi().vports[port].device
    return device ~= nil and type(device.event) == "function"
  end

  -- fn(port, device_name | nil) when a device arrives at or leaves a port:
  -- an arrival names the device now there, a departure passes nil
  function M.on_change(name, fn)
    require_name("on_change", name)
    require_fn("on_change", fn)
    set_entry(state.changes, name, fn)
  end

  -- fn(port, owner | nil) at each change of a port's owner
  function M.on_claim(name, fn)
    require_name("on_claim", name)
    require_fn("on_claim", fn)
    set_entry(state.claims, name, fn)
  end

  -- fn(port) once a port's arrival (a hot-plug or a move in the menu) or its
  -- release has been told to every change and claim hook, any claim or
  -- release a hook made meanwhile included; never for a departure or a claim
  function M.on_settled(name, fn)
    require_name("on_settled", name)
    require_fn("on_settled", fn)
    set_entry(state.settles, name, fn)
  end

  -- The port for name: true when it is name's (now or already), false
  -- while another name holds it or outside 1..16
  function M.claim(port, name)
    require_name("claim", name)
    if not valid_port(port) then return false end
    local owner = state.owners[port]
    if owner == name then return true end
    if owner ~= nil then return false end
    state.owners[port] = name
    run_set(state.claims, "midi claim hook", port, name)
    request_redraw()  -- SETUP and IO show the owner
    return true
  end

  -- Only the owner's release frees the port
  function M.release(port, name)
    if not valid_port(port) or state.owners[port] == nil or state.owners[port] ~= name then return end
    state.owners[port] = nil
    told(port, true, function() run_set(state.claims, "midi claim hook", port, nil) end)
    request_redraw()
  end

  function M.owner(port)
    if not valid_port(port) then return nil end
    return state.owners[port]
  end

  -- fn(device) with the hot_plug flag entered set, unless it is set
  -- already: a call that comes back into the module's own handler through
  -- the chain returns at once, so the chain never loops. An error is raised
  -- again once the flag is cleared
  local function once(entered, fn, device)
    local hot_plug = state.hot_plug
    if hot_plug[entered] then return end
    hot_plug[entered] = true
    local ran, problem = pcall(fn, device)
    hot_plug[entered] = false
    if not ran then error(problem, 0) end
  end

  -- Hot-plug. norns puts a device on its vport before calling midi.add, and
  -- clears the vport only after midi.remove returns. A device on no port
  -- (all 16 named, or norns' virtual one) tells no listener. Between the
  -- start and cleanup steps the listeners hear of it; the kept handler is
  -- always called
  local function added(device)
    local port = device and device.port
    if state.hot_plug.installed and valid_port(port) then
      state.seen[port] = norns_midi().vports[port].device or device
      told(port, true, function() run_set(state.changes, "midi change hook", port, device.name) end)
    end
    if state.hot_plug.kept_add then state.hot_plug.kept_add(device) end
  end

  local function removed(device)
    local port = device and device.port
    local marked = state.hot_plug.installed and valid_port(port)
    if marked then state.leaving[port] = true end
    local ran, problem = pcall(function()
      if marked then
        state.seen[port] = nil
        told(port, false, function() run_set(state.changes, "midi change hook", port, nil) end)
      end
      if state.hot_plug.kept_remove then state.hot_plug.kept_remove(device) end
    end)
    if marked then state.leaving[port] = nil end
    if not ran then error(problem, 0) end
  end

  local function device_added(device) once("entered_add", added, device) end
  local function device_removed(device) once("entered_remove", removed, device) end

  -- As the norns menu closes: SYSTEM > DEVICES moves a device with
  -- update_devices() only (no midi.add, no midi.remove), so every port whose
  -- device is not the one last seen tells of the departure, then of the
  -- arrival, departures first. A visit that moves nothing tells nothing
  function M.reconcile()
    if not state.hot_plug.installed then return end
    local left, arrived, vports = {}, {}, norns_midi().vports
    for port = 1, PORTS.count do
      local current = vports[port].device
      if current ~= state.seen[port] then
        if state.seen[port] ~= nil then left[#left + 1] = port end
        if current ~= nil then arrived[#arrived + 1] = port end
        state.seen[port] = current
      end
    end
    for _, port in ipairs(left) do
      told(port, false, function() run_set(state.changes, "midi change hook", port, nil) end)
    end
    for _, port in ipairs(arrived) do
      told(port, true, function() run_set(state.changes, "midi change hook", port, vports[port].name) end)
    end
  end

  S.register_menu_close(function() M.reconcile() end)

  -- Installing again (init run twice) never chains ours to themselves:
  -- ours installed already, or a wrapper a cleanup left over ours (which
  -- leads to ours, still holding the kept handler), is left as it is and
  -- nothing more is kept
  S.register_start(S.constants.START_ORDER.io_ports, function()
    local hot_plug, module = state.hot_plug, norns_midi()
    local vports = module.vports
    for port = 1, PORTS.count do state.seen[port] = vports[port].device end
    if module.add ~= device_added and not hot_plug.wrapped_add then
      hot_plug.kept_add, module.add = module.add, device_added
    end
    if module.remove ~= device_removed and not hot_plug.wrapped_remove then
      hot_plug.kept_remove, module.remove = module.remove, device_removed
    end
    hot_plug.installed = true
  end)

  -- The hot-plug handlers found back, every event this module set cleared
  -- and its listeners forgotten. A handler something wrapped ours with since
  -- stays installed, and ours, still in its chain, then only calls the kept one
  S.register_cleanup(S.constants.CLEANUP_ORDER.io_ports, function()
    local hot_plug, module = state.hot_plug, norns_midi()
    hot_plug.installed = false
    if module.add == device_added then
      module.add, hot_plug.kept_add, hot_plug.wrapped_add = hot_plug.kept_add, nil, false
    else
      hot_plug.wrapped_add = true
    end
    if module.remove == device_removed then
      module.remove, hot_plug.kept_remove, hot_plug.wrapped_remove = hot_plug.kept_remove, nil, false
    else
      hot_plug.wrapped_remove = true
    end
    local vports = module.vports
    for port, fn in pairs(state.dispatchers) do
      if vports[port].event == fn then vports[port].event = nil end
    end
    state.listeners = {}
  end)

  -- A vport's event is the dispatcher exactly while the port has listeners
  S.register_invariant("midi ports", function()
    local vports = norns_midi().vports
    for port = 1, PORTS.count do
      local listening = state.listeners[port] ~= nil
      local dispatching = state.dispatchers[port] ~= nil and vports[port].event == state.dispatchers[port]
      if listening ~= dispatching then
        return "port " .. port .. (listening and " has listeners but its event is not the dispatcher"
          or " has no listener but its event is the dispatcher")
      end
    end
  end)

  return M
end
