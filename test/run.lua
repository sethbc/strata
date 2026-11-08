-- test/run.lua
-- Off-device test harness for strata. Run from the repo root:
--   lua test/run.lua [filter]      (or)      luajit test/run.lua [filter]
-- Runs the tests of every test/unit/*_test.lua or, with a filter, of the
-- unit files whose name contains it (`lua test/run.lua scenes`). The shared
-- harness is test/helpers.lua. Exits non-zero if any test fails.

local test_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "test"
package.path = test_dir .. "/?.lua;" .. package.path

local h = require("helpers")
local filter = arg and arg[1]

local loaded = h.load_unit_files(test_dir .. "/unit", filter, h)
if #loaded == 0 then
  h.real_print("no unit file in " .. test_dir .. "/unit matches '" .. tostring(filter) .. "'")
  os.exit(1)
end

local failures = 0
for _, entry in ipairs(h.tests) do
  local ok, err = h.run_test(entry.func)
  print = h.real_print
  if ok then
    h.real_print("ok   " .. entry.name)
  else
    failures = failures + 1
    h.real_print("FAIL " .. entry.name .. "\n     " .. tostring(err):gsub("\n", "\n     "))
  end
end

h.remove_tree(h.data_root)

h.real_print(string.format("\n%d tests, %d failures", #h.tests, failures))
os.exit(failures == 0 and 0 or 1)
