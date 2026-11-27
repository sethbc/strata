-- Run from Maiden's matron REPL with Strata playing. See the device protocol
-- in docs/notes/engine/files.md. Each writer makes one normal user WAV.
return function(writers)
  assert(writers == 1 or writers == 2 or writers == 3 or writers == 4, "choose 1 to 4 writers")
  -- Read the running script's actual pending receipts without adding a
  -- measurement hook to its save or poll handlers.
  local S
  local index = 1
  while true do
    local name, value = debug.getupvalue(init, index)
    if not name then break end
    if name == "S" then S = value; break end
    index = index + 1
  end
  assert(S and S.buffers, "load Strata first")
  for slot = 1, writers do
    assert(S.buffers[slot].seconds > 0 and #S.buffers[slot].pending_saves == 0,
      "load audio and let earlier saves finish in slot " .. slot)
  end

  return clock.run(function()
    local before = osc.event
    local starts, delays, paths, lengths, sent, rtts = {}, {}, {}, {}, {}, {}
    local seq, pending, max_gap = 0, writers, 0
    local token = tostring(util.time())
    local function event(path, args, from)
      if path == "/strata/check/save/pong" and args[1] == token and sent[args[2]] then
        rtts[#rtts + 1] = (util.time() - sent[args[2]]) * 1000
        sent[args[2]] = nil
      elseif before then before(path, args, from) end
    end
    osc.event = event
    local ok, problem = xpcall(function()
      _norns.audio_get_xrun_count()  -- reset matron's counter for this trial
      local last = util.time()
      for slot = 1, writers do
        starts[slot] = util.time()
        lengths[slot] = S.buffers[slot].seconds
        assert(save_buffer(slot), "save refused in slot " .. slot)
        paths[slot] = S.buffers[slot].pending_saves[1].path
      end
      while pending > 0 do
        local now = util.time()
        max_gap = math.max(max_gap, now - last)
        last = now
        for slot = 1, writers do
          if not delays[slot] and #S.buffers[slot].pending_saves == 0 then
            delays[slot] = (now - starts[slot]) * 1000
            pending = pending - 1
          end
        end
        if now - starts[1] >= 120 then break end
        if pending > 0 then
          seq = seq + 1
          sent[seq] = now
          osc.send({"127.0.0.1", 57120}, "/strata/check/save/ping", {token, seq})
          clock.sleep(0.01)
        end
      end
      local xruns = _norns.audio_get_xrun_count()
      clock.sleep(0.2)  -- receive the last probes before counting losses
      table.sort(rtts)
      local function latency(fraction)
        return rtts[math.ceil(#rtts * fraction)] or -1
      end
      print(string.format("save bench tier=%s writers=%d xruns=%d sent=%d lost=%d p99_ms=%.2f max_ms=%.2f observation_gap_ms=%.2f",
        S.performance.tier, writers, xruns, seq, seq - #rtts, latency(0.99), latency(1), max_gap * 1000))
      -- Keep samples for a pooled p99 when a short standard-tier write
      -- produces fewer than 100 replies in a trial.
      local samples = {}
      for i, rtt in ipairs(rtts) do samples[i] = string.format("%.2f", rtt) end
      print("osc_rtt_ms=" .. table.concat(samples, ","))
      if pending > 0 then
        for slot = 1, writers do
          local receipt = delays[slot] and string.format("receipt_ms=%.2f", delays[slot])
            or string.format("receipt=pending waited_ms=%.2f", (last - starts[slot]) * 1000)
          print(string.format("slot=%d %s path=%s", slot, receipt, paths[slot]))
        end
        error("receipt timed out")
      end
      for slot = 1, writers do
        local channels, frames, rate = audio.file_info(paths[slot])
        print(string.format("slot=%d receipt_ms=%.2f path=%s channels=%s frames=%s rate=%s",
          slot, delays[slot], paths[slot], tostring(channels), tostring(frames), tostring(rate)))
        assert(channels == 2 and rate > 0 and math.abs(frames / rate - lengths[slot]) < 0.01,
          "missing or short WAV for slot " .. slot)
      end
      assert(#rtts > 0, "no OSC echoes; check the Maiden SC responder")
    end, debug.traceback)
    if osc.event == event then osc.event = before end
    if not ok then error(problem) end
  end)
end
