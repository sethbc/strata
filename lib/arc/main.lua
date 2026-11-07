-- lib/arc/main.lua
-- The MAIN page's arc rings: density, the selected voice's main param,
-- grain size (grain pitch for an input voice, whose main param already is
-- grain size) and grain density; with ALT held, the selected voice's grain
-- pitch, grain spread, level and pan (none for Sub: its ring is dark).
-- Sets arc_delta, arc_redraw, arc_alt_delta and arc_alt_redraw on MAIN's
-- S.registry.pages record.

return function(S)
  local M = {}

  -- ALT rings: param id suffixes after "v<i>_", rings 1-4
  local ARC_MAIN_ALT_KEYS = {"grain_pitch", "grain_spread", "amp", "pan"}

  -- Brightness by voice state: the primary ring (the main param) and the others
  local ARC_MAIN_LEVELS = {primary_active = 15, active = 12, primary_stopped = 4, stopped = 3}

  local function voice_prefix()
    return "v" .. S.selected_voice .. "_"
  end

  -- Ring n's param id (nil: the ring is dark and ignores turns)
  local function main_ring_param(n)
    local prefix = voice_prefix()
    if n == 1 then return "master_density" end
    if n == 2 then return main_param_id(S.selected_voice) end
    if n == 3 then
      -- an input voice's main param (ring 2) is grain size: ring 3 is pitch
      local uses_input = not voice_uses_synth(S.selected_voice) and not voice_uses_buffer(S.selected_voice)
      return prefix .. (uses_input and "grain_pitch" or "grain_size")
    end
    if n == 4 then return prefix .. "grain_density" end
    return nil
  end

  local function main_alt_ring_param(n)
    local suffix = ARC_MAIN_ALT_KEYS[n]
    if suffix == nil then return nil end
    if suffix == "pan" and S.voices[S.selected_voice].params.pan == nil then return nil end  -- Sub
    return voice_prefix() .. suffix
  end

  local function ring_level(active, primary)
    if primary then
      return active and ARC_MAIN_LEVELS.primary_active or ARC_MAIN_LEVELS.primary_stopped
    end
    return active and ARC_MAIN_LEVELS.active or ARC_MAIN_LEVELS.stopped
  end

  local function arc_main_delta(n, delta)
    local param_id = main_ring_param(n)
    if param_id then arc_sweep_param(param_id, delta) end
  end

  -- Every ring is drawn across its param's controlspec range (as the sweep
  -- moves it); ring 1 (density) is always bright, ring 2 (the main param)
  -- the primary voice ring
  local function arc_main_redraw(arc_port)
    local active = S.voices[S.selected_voice].active
    arc_ring_fill_param(arc_port, 1, main_ring_param(1), ARC_MAIN_LEVELS.primary_active)
    for n = 2, 4 do
      arc_ring_fill_param(arc_port, n, main_ring_param(n), ring_level(active, n == 2))
    end
  end

  local function arc_main_alt_delta(n, delta)
    local param_id = main_alt_ring_param(n)
    if param_id then arc_sweep_param(param_id, delta) end
  end

  -- Pan spans 0, so arc_ring_fill_param draws it from the top both ways
  local function arc_main_alt_redraw(arc_port)
    local active = S.voices[S.selected_voice].active
    for n = 1, #ARC_MAIN_ALT_KEYS do
      local param_id = main_alt_ring_param(n)
      if param_id then arc_ring_fill_param(arc_port, n, param_id, ring_level(active, false)) end
    end
  end

  -- MAIN's record (lib/pages/main.lua) gains its rings: arc_delta and
  -- arc_redraw in lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  -- (the ALT ones while ALT is held)
  local record = S.registry.pages[S.constants.UI_PAGES.index.MAIN]
  assert(record, "lib/arc/main.lua: no MAIN page record in S.registry.pages")
  record.arc_delta = arc_main_delta
  record.arc_redraw = arc_main_redraw
  record.arc_alt_delta = arc_main_alt_delta
  record.arc_alt_redraw = arc_main_alt_redraw

  return M
end
