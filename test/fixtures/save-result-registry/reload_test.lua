-- NORNS_DIR=<norns> lua test/run.lua --dir test/fixtures/save-result-registry
-- Run separately: this installs the real matron poll registry and Lua entry
-- point alongside Strata's engine and clock stubs.
return function(h)
  h.test("norns dispatches an old numbered poll to the replacement save handler", function()
    local root = assert(os.getenv("NORNS_DIR"))
    package.path = root .. "/lua/?.lua;" .. root .. "/lua/lib/?.lua;" .. package.path
    for _, name in ipairs({"core/engine", "core/hook", "core/script", "core/state", "core/encoders", "util"}) do
      package.loaded[name] = {}
    end
    local function zero() return 0 end
    local native = {adc_rev = zero, platform = zero, platform_factory = zero, platform_shield = zero, stop_poll = zero}
    _norns, _path = native, {}
    local Poll = require("core/poll")
    dofile(root .. "/lua/core/norns.lua")

    local function session(key)
      local c = h.load_strata()
      h.finish_startup(c)
      local S = h.local_value("S")
      load_buffer(1, "/tmp/example.wav")
      c.polls.fire("bufferState", c.polls.buffer_state_value(1, 1, 4))
      S.lib.samples.set(1, "key", key)
      h.assert_true(save_buffer(1))
      native.report.polls({{4, "bufferSaveResult"}}, 1)
      return c, S, Poll.set("bufferSaveResult", c.polls.polls.bufferSaveResult.callback)
    end

    local old, _, first = session(50)
    local old_callback = first.callback
    old.save_result(16, true)
    cleanup()
    _norns = native
    Poll.clear_all()
    local fresh, S, second = session(62)
    h.assert_true(first ~= second)
    local copied_key
    S.lib.samples.store_file = function(_, record) copied_key = record.key end
    old_callback(16)
    native.poll(4, 16) -- same queued index+float, now routed through second
    h.assert_equal(copied_key, nil)
    h.assert_equal(#S.buffers[1].pending_saves, 1)
    fresh.save_result(16, true)
    native.poll(4, 16)
    h.assert_equal(copied_key, 62)
    h.assert_equal(#S.buffers[1].pending_saves, 0)
  end)
end
