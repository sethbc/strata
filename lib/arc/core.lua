-- lib/arc/core.lua
-- The arc Strata follows (S.arc_device, S.arc_connected) and what every
-- page's rings share: the sweep, the plain and bipolar ring fills, the
-- carried ticks of whole-step rings (S.arc_ticks), attaching the vport,
-- hot-plug, and the dispatch to the page records' arc_delta and arc_redraw
-- (arc_alt_delta and arc_alt_redraw while ALT is held) and arc_button
-- (lib/arc/<page>.lua set the ring fields, lib/pages/<page>.lua the
-- button). The functions that were global stay global, defined here.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  -- A bipolar ring at exactly 0 lights LED 1 this dim, so it never looks dead
  local ARC_BIPOLAR_ZERO_LEVEL = 3

  -- Arc device (the arc vport from arc.connect); SETUP shows S.arc_connected
  S.arc_device = nil
  S.arc_connected = false

  -- Per key (any string, e.g. "lfo:4"): the ticks a whole-step ring has
  -- turned that are not yet worth a whole step (arc_whole_steps)
  S.arc_ticks = {}

  -- Arc functions

  -- Arc pages follow the screen page: S.registry.pages[S.ui_page].arc_delta
  -- handles ring turns and its arc_redraw draws the rings between
  -- arc_redraw's clear and refresh; while ALT is held (S.alt_held) its
  -- arc_alt_delta and arc_alt_redraw do, when it has them. A page without
  -- rings (SETUP) ignores turns and leaves its rings off.

  -- A continuous ring: UI_PAGES.ARC_TICKS_PER_SWEEP ticks sweep the control
  -- param's whole range. The ticks move its 0-1 raw value by delta /
  -- ARC_TICKS_PER_SWEEP (delta_with_detent, lib/ui/detent.lua, which also
  -- holds a range through 0 at 0 for DETENT.arc_ticks ticks), so the sweep
  -- follows the warp (exp params sweep evenly) and the step only quantizes
  -- the value read back. The arc has no fine mode.
  -- Control params only.
  function arc_sweep_param(param_id, delta)
    delta_with_detent(param_id, nil, {arc_ticks = delta})
  end

  -- Fill ring n from 0 to fraction (0-1) of a turn. Every ring draws through
  -- here or arc_ring_fill_bipolar: the end angle stays just below a full
  -- turn, so a ring at its maximum lights all 64 LEDs instead of none
  function arc_ring_fill(arc_port, ring, fraction, level)
    local turn = math.pi * 2
    local clamped = math.max(0, math.min(1, fraction))
    arc_port:segment(ring, 0, math.min(clamped * turn, turn - UI_PAGES.ARC_FULL_TURN_MARGIN), level)
  end

  -- Fill a ring that shows a whole-step position (a cursor, a level, a row)
  -- from 0 to fraction like arc_ring_fill, but the first position (fraction
  -- 0) lights LED 1 so it never looks like a ring that is off
  function arc_ring_fill_position(arc_port, ring, fraction, level)
    if fraction <= 0 then
      arc_port:led(ring, 1, level)
    else
      arc_ring_fill(arc_port, ring, fraction, level)
    end
  end

  -- Fill ring n from 12 o'clock toward the param's value, measured from the
  -- param's own 0 (param_value_fraction(id, 0), not the ring's middle):
  -- clockwise for a value above 0, counter-clockwise below it. Like
  -- arc_ring_fill, a fill stays just short of a whole turn, so it never lights
  -- nothing. At exactly 0 only LED 1 lights, at ARC_BIPOLAR_ZERO_LEVEL.
  function arc_ring_fill_bipolar(arc_port, ring, param_id, level)
    local turn = math.pi * 2
    local fraction = math.max(-1, math.min(1, param_fraction(param_id) - param_value_fraction(param_id, 0)))
    local angle = fraction * turn
    local limit = turn - UI_PAGES.ARC_FULL_TURN_MARGIN
    if angle > 0 then
      arc_port:segment(ring, 0, math.min(angle, limit), level)
    elseif angle < 0 then
      arc_port:segment(ring, turn + math.max(angle, -limit), turn, level)
    else
      arc_port:led(ring, 1, ARC_BIPOLAR_ZERO_LEVEL)
    end
  end

  -- Fill a ring showing a param: bipolar when its range spans 0
  -- (param_spans_zero), else from 0 like every other ring
  function arc_ring_fill_param(arc_port, ring, param_id, level)
    if param_spans_zero(param_id) then
      arc_ring_fill_bipolar(arc_port, ring, param_id, level)
    else
      arc_ring_fill(arc_port, ring, param_fraction(param_id), level)
    end
  end

  -- Whole steps in a ring's carried ticks plus delta, for rings that step
  -- whole values (ticks_per_step ticks a step); the rest is kept under key
  -- for the next turn. A page change forgets every key's carry (set_ui_page)
  function arc_whole_steps(key, delta, ticks_per_step)
    local ticks = (S.arc_ticks[key] or 0) + delta
    local steps = ticks >= 0 and math.floor(ticks / ticks_per_step) or -math.floor(-ticks / ticks_per_step)
    S.arc_ticks[key] = ticks - steps * ticks_per_step
    return steps
  end

  -- Forget the carried ticks of key, or of every key when key is nil
  function forget_arc_ticks(key)
    if key == nil then
      S.arc_ticks = {}
    else
      S.arc_ticks[key] = nil
    end
  end

  -- LFO ring 4's carried ticks belong to one LFO's clocked rate: forget them
  -- when the selected LFO (E2 on the LFO page) or its mode changes, so they
  -- never step another param. lib/arc/lfo.lua keys its rings "lfo:<ring>"
  function forget_arc_lfo_period_ticks()
    forget_arc_ticks("lfo:4")
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
    local port = device.port
    -- an arc norns gave no vport is on no vport at all: never followed
    if port == nil or port < 1 or port > UI_PAGES.ARC_PORTS then return end
    if S.arc_connected and S.arc_device ~= arc.connect(port) then return end  -- already following another arc
    attach_arc(port)
    request_redraw()  -- its rings, and SETUP shows the arc state
    print("arc connected")
  end

  function arc.remove(device)
    local port = device.port
    if port == nil or port < 1 or port > UI_PAGES.ARC_PORTS then return end  -- never the followed arc
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

  -- SYSTEM > DEVICES moves an arc to another port through norns'
  -- update_devices() alone (lua/core/menu/devices.lua): no arc.add, no
  -- arc.remove. Run as the norns menu closes: when the followed vport holds
  -- no device, follow the first vport holding one, or disconnect; when it
  -- holds one, it is connected
  function M.reconcile()
    if S.arc_device == nil or S.arc_device.device == nil then
      local port = first_arc_port()
      if port then
        attach_arc(port)
        print("arc connected on port " .. port)
      elseif S.arc_connected then
        S.arc_connected = false
        print("arc disconnected")
      end
    else
      S.arc_connected = true
    end
    request_redraw()  -- the rings of the arc now followed, and SETUP's arc state
  end

  S.register_menu_close(function() M.reconcile() end)

  -- The current page's ring handler: alt_field (arc_alt_delta,
  -- arc_alt_redraw) while ALT is held and the page has it, else plain_field;
  -- nil when the page has neither
  local function page_ring_handler(plain_field, alt_field)
    local record = S.registry.pages[S.ui_page]
    if S.alt_held and record[alt_field] then return record[alt_field] end
    return record[plain_field]
  end

  function arc_delta(n, delta)
    local page_delta = page_ring_handler("arc_delta", "arc_alt_delta")
    if page_delta then page_delta(n, delta) end  -- nil: the page ignores turns
    request_redraw()
  end

  -- The button (2025 arc models): a press calls the page record's
  -- arc_button (MAIN's is K3); a page without one ignores it
  function arc_key(n, s)
    if s ~= 1 then return end
    local button = S.registry.pages[S.ui_page].arc_button
    if button then
      button()
      request_redraw()
    end
  end

  function arc_redraw()
    if S.arc_device == nil or S.arc_device.device == nil then return end
    S.lib.ui_cursors.clamp_all()  -- rows may have shrunk under a cursor (lib/ui/cursors.lua)

    S.arc_device:all(0)
    local page_redraw = page_ring_handler("arc_redraw", "arc_alt_redraw")
    if page_redraw then page_redraw(S.arc_device) end  -- nil: rings stay off
    S.arc_device:refresh()
  end

  -- Connect the arc at init
  S.register_start(S.constants.START_ORDER.arc, function()
    arc_init()
  end)

  -- SETUP's "arc: connected" is exactly the followed vport holding a device
  S.register_invariant("arc connection", function()
    local holds_device = S.arc_device ~= nil and S.arc_device.device ~= nil
    if S.arc_connected ~= holds_device then
      return "S.arc_connected is " .. tostring(S.arc_connected) .. " but the followed vport "
        .. (holds_device and "holds" or "holds no") .. " device"
    end
  end)

  -- Leave the arc dark on exit, the last cleanup step
  S.register_cleanup(S.constants.CLEANUP_ORDER.arc_dark, function()
    if S.arc_device then
      S.arc_device:all(0)
      S.arc_device:refresh()
    end
  end)

  return M
end
