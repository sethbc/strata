-- lib/arc/core.lua
-- The arc Strata follows (S.arc_device, S.arc_connected) and what every
-- page's rings share: the sweep and the ring fill, attaching the vport,
-- hot-plug, and the dispatch to the page records' arc_delta and arc_redraw
-- (lib/arc/main.lua, fx.lua, lfo.lua, buffer.lua). The functions that were
-- global stay global, defined here.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  -- Arc device (the arc vport from arc.connect); SETUP shows S.arc_connected
  S.arc_device = nil
  S.arc_connected = false

  -- Arc functions

  -- Arc pages follow the screen page: S.registry.pages[S.ui_page].arc_delta
  -- handles ring turns and its arc_redraw draws the rings between
  -- arc_redraw's clear and refresh. A page without them (SETUP) ignores
  -- turns and leaves its rings off.

  -- A continuous ring: UI_PAGES.ARC_TICKS_PER_SWEEP ticks sweep the control
  -- param's whole range. params:delta moves its 0-1 raw value by delta *
  -- quantum, so the sweep follows the warp (exp params sweep evenly) and the
  -- step only quantizes the value read back.
  -- Control params only: it reads the param's controlspec.
  function arc_sweep_param(param_id, delta)
    local quantum = params:lookup_param(param_id).controlspec.quantum
    params:delta(param_id, delta / (UI_PAGES.ARC_TICKS_PER_SWEEP * quantum))
  end

  -- Fill ring n from 0 to fraction (0-1) of a turn. Every ring draws through
  -- here: the end angle stays just below a full turn, so a ring at its maximum
  -- lights all 64 LEDs instead of none
  function arc_ring_fill(arc_port, ring, fraction, level)
    local turn = math.pi * 2
    local clamped = math.max(0, math.min(1, fraction))
    arc_port:segment(ring, 0, math.min(clamped * turn, turn - UI_PAGES.ARC_FULL_TURN_MARGIN), level)
  end

  -- Ring 4's carried ticks belong to one LFO's clocked rate: forget them when
  -- the selected LFO (E2 on the LFO page) or its mode changes, so they never
  -- step another param. The ticks are the LFO rings' own (lib/arc/lfo.lua)
  function forget_arc_lfo_period_ticks()
    S.lib.arc_lfo.forget_period_ticks()
  end

  -- Arc handlers live on the vport only (as for grids): norns fires both
  -- device.delta/key and vports[port].delta/key, so setting them on the device
  -- as well would run every turn twice.
  local function attach_arc(port)
    if S.arc_device and S.arc_device ~= arc.connect(port) then
      -- following another vport now: the old one (e.g. the empty port-1
      -- fallback from init) must not keep handlers for a later arc
      S.arc_device.delta = nil
      S.arc_device.key = nil
    end
    S.arc_device = arc.connect(port)
    S.arc_device.delta = arc_delta
    S.arc_device.key = arc_key
    S.arc_connected = S.arc_device.device ~= nil
  end

  -- The first arc vport (in port order) holding a device, other than
  -- skipped_port; nil when there is none
  function first_arc_port(skipped_port)
    for candidate = 1, UI_PAGES.ARC_PORTS do
      if candidate ~= skipped_port and arc.connect(candidate).device then
        return candidate
      end
    end
    return nil
  end

  -- Strata follows one arc: at init the first vport holding a device (port 1
  -- preferred by being first); later, a hot-plugged arc connects only while none
  -- is connected, and removing the connected arc moves to the first other
  -- vport holding one, or disconnects.
  function arc_init()
    attach_arc(first_arc_port() or UI_PAGES.ARC_PORT)  -- the first frame draws its rings
  end

  function arc.add(device)
    local port = device.port or UI_PAGES.ARC_PORT
    if port < 1 or port > UI_PAGES.ARC_PORTS then return end
    if S.arc_connected and S.arc_device ~= arc.connect(port) then return end  -- already following another arc
    attach_arc(port)
    request_redraw()  -- its rings, and SETUP shows the arc state
    print("arc connected")
  end

  function arc.remove(device)
    local port = device.port or UI_PAGES.ARC_PORT
    if port < 1 or port > UI_PAGES.ARC_PORTS then return end
    if S.arc_device ~= arc.connect(port) then return end  -- not the arc Strata follows
    -- norns clears the removed vport only after arc.remove returns: skip it
    local next_port = first_arc_port(port)
    if next_port then
      attach_arc(next_port)
      print("arc disconnected; following the arc on port " .. next_port)
    else
      S.arc_connected = false
      print("arc disconnected")
    end
    request_redraw()  -- the rings of the arc now followed, and SETUP's arc state
  end

  function arc_delta(n, delta)
    local page_delta = S.registry.pages[S.ui_page].arc_delta
    if page_delta then page_delta(n, delta) end  -- nil: the page ignores turns
    request_redraw()
  end

  function arc_key(n, s)
    -- Button press (2025 arc): same as K3 on MAIN, nothing on other pages
    if s == 1 and S.ui_page == UI_PAGES.MAIN_PAGE then
      S.lib.pages_main.start_or_freeze_selected_voice()
      request_redraw()
    end
  end

  function arc_redraw()
    if S.arc_device == nil or S.arc_device.device == nil then return end
    S.lib.ui_cursors.clamp_all()  -- rows may have shrunk under a cursor (lib/ui/cursors.lua)

    S.arc_device:all(0)
    local page_redraw = S.registry.pages[S.ui_page].arc_redraw
    if page_redraw then page_redraw(S.arc_device) end  -- nil: rings stay off
    S.arc_device:refresh()
  end

  -- Leave the arc dark on exit, the last cleanup step
  S.register_cleanup(S.constants.CLEANUP_ORDER.arc_dark, function()
    if S.arc_device then
      S.arc_device:all(0)
      S.arc_device:refresh()
    end
  end)

  return M
end
