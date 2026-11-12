-- stub_pattern_time.lua
-- Stand-in for norns' lua/lib/pattern_time.lua, returned by
-- require("pattern_time") in the harness: the library's code line by line
-- (new, clear, set_time_factor, rec_start, rec_stop, watch, rec_event,
-- overdub_event, start, next_event, stop, set_overdub), over the stub's
-- metro (a timer runs only when a test calls its event) and util.time()
-- (the clock's time). The module returns a constructor, so each install
-- builds a fresh library table, as each norns script load gets one. Uses
-- the metro, util and print globals installed by norns_stubs.

return function()
  local pattern = {}
  pattern.__index = pattern

  function pattern.new()
    local i = {}
    setmetatable(i, pattern)
    i.rec = 0
    i.play = 0
    i.overdub = 0
    i.prev_time = 0
    i.event = {}
    i.time = {}
    i.count = 0
    i.step = 0
    i.time_factor = 1

    i.metro = metro.init(function() i:next_event() end, 1, 1)

    i.process = function(_) print("event") end

    return i
  end

  function pattern:clear()
    self.metro:stop()
    self.rec = 0
    self.play = 0
    self.overdub = 0
    self.prev_time = 0
    self.event = {}
    self.time = {}
    self.count = 0
    self.step = 0
    self.time_factor = 1
  end

  function pattern:set_time_factor(f)
    self.time_factor = f or 1
  end

  function pattern:rec_start()
    print("pattern rec start")
    self.rec = 1
  end

  function pattern:rec_stop()
    if self.rec == 1 then
      self.rec = 0
      if self.count ~= 0 then
        local t = self.prev_time
        self.prev_time = util.time()
        self.time[self.count] = self.prev_time - t
      else
        print("pattern_time: no events recorded")
      end
    else print("pattern_time: not recording")
    end
  end

  function pattern:watch(e)
    if self.rec == 1 then
      self:rec_event(e)
    elseif self.overdub == 1 then
      self:overdub_event(e)
    end
  end

  function pattern:rec_event(e)
    local c = self.count + 1
    if c == 1 then
      self.prev_time = util.time()
    else
      local t = self.prev_time
      self.prev_time = util.time()
      self.time[c-1] = self.prev_time - t
    end
    self.count = c
    self.event[c] = e
  end

  function pattern:overdub_event(e)
    local c = self.step + 1
    local t = self.prev_time
    self.prev_time = util.time()
    local a = self.time[c-1]
    self.time[c-1] = self.prev_time - t
    table.insert(self.time, c, a - self.time[c-1])
    table.insert(self.event, c, e)
    self.step = self.step + 1
    self.count = self.count + 1
  end

  function pattern:start()
    if self.count > 0 then
      self.prev_time = util.time()
      self.process(self.event[1])
      self.play = 1
      self.step = 1
      self.metro.time = self.time[1] * self.time_factor
      self.metro:start()
    end
  end

  function pattern:next_event()
    self.prev_time = util.time()
    if self.step == self.count then self.step = 1
    else self.step = self.step + 1 end
    self.process(self.event[self.step])
    self.metro.time = self.time[self.step] * self.time_factor
    self.metro:start()
  end

  function pattern:stop()
    if self.play == 1 then
      self.play = 0
      self.overdub = 0
      self.metro:stop()
    else print("pattern_time: not playing") end
  end

  function pattern:set_overdub(s)
    if s==1 and self.play == 1 and self.rec == 0 then
      self.overdub = 1
    else
      self.overdub = 0
    end
  end

  return pattern
end
