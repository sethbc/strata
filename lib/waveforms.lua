-- lib/waveforms.lua
-- Peaks of each buffer slot's audio, for the BUFFER page's waveform.
-- Neutral until its Wave 1 package (3.3's waveforms): the functions answer
-- as pinned below and send nothing.

return function(S)
  local M = {}

  -- A slot's audio changed: its peaks are stale
  function M.stale(slot) end
  -- A slot's peaks, or nil when it has none
  function M.peaks(slot) return nil end
  -- A slot's peaks in n bins, or nil
  function M.bins(slot, n) return nil end

  return M
end
