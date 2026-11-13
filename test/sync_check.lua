-- test/sync_check.lua
-- Static Lua <-> SuperCollider command sync check.
-- Extracts every engine.<name>(...) call from strata.lua and lib/**/*.lua
-- (the script's Lua files) and every
-- this.addCommand(\<name>, "<sig>", ...) from the engine source,
-- lib/Engine_Strata.sc and lib/engine/*.sc (stubs.engine_sources; skipping
-- commented-out ones), then checks that the two name sets are equal and
-- that every Lua call passes exactly as many arguments as its signature
-- declares.
-- Any other use of `engine` is an error, because the check cannot see what
-- it calls: engine[name](...), engine.voiceOn passed or stored without a
-- call (local f = engine.voiceOn), engine:method(), a call without
-- parentheses (engine.loadBuffer "x") or the engine table itself used as a
-- value (local e = engine). Only engine.name (the engine the script loads)
-- may be read or set; a table key or function parameter named engine
-- ({ engine = 1 }, function(engine)) and #engine name no command and pass.
--
-- Standalone:  lua test/sync_check.lua   (exit status 1 on mismatch)
-- As a module: require("sync_check").run(repo_root) -> ok, problems, summary
--              require("sync_check").check_sources(lua_sources, sc_source) -> the same
--                (lua_sources: { { path = "lib/x.lua", text = source }, ... })
--              require("sync_check").check(lua_source, sc_source) -> the same, one source

local sync_check = {}

-- The engine source is parsed by the engine stub's parser, which skips
-- SuperCollider comments (norns_stubs.lua sits next to this file)
local script_dir = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local stubs = require("norns_stubs")

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local contents = file:read("*a")
  file:close()
  return contents
end

-- Replace comments with spaces and string literal contents with "_" so
-- that commas and parentheses inside them are not counted.
local function sanitize_lua(source)
  local output = {}
  local index = 1
  local length = #source
  while index <= length do
    local char = source:sub(index, index)
    local two = source:sub(index, index + 1)
    if two == "--" then
      local long_open = source:match("^%-%-%[(=*)%[", index)
      local close_index
      if long_open then
        local _, finish = source:find("]" .. long_open .. "]", index, true)
        close_index = finish or length
      else
        close_index = (source:find("\n", index, true) or (length + 1)) - 1
      end
      table.insert(output, (source:sub(index, close_index):gsub("[^\n]", " ")))
      index = close_index + 1
    elseif char == '"' or char == "'" then
      local cursor = index + 1
      while cursor <= length do
        local inner = source:sub(cursor, cursor)
        if inner == "\\" then
          cursor = cursor + 2
        elseif inner == char then
          break
        else
          cursor = cursor + 1
        end
      end
      table.insert(output, char .. string.rep("_", cursor - index - 1) .. char)
      index = cursor + 1
    elseif source:match("^%[=*%[", index) then
      local equals = source:match("^%[(=*)%[", index)
      local _, finish = source:find("]" .. equals .. "]", index, true)
      finish = finish or length
      table.insert(output, '"' .. string.rep("_", finish - index - 1) .. '"')
      index = finish + 1
    else
      table.insert(output, char)
      index = index + 1
    end
  end
  return table.concat(output)
end

-- Count the top-level arguments of the call whose "(" is at open_index
local function count_arguments(source, open_index)
  local depth = 0
  local commas = 0
  local has_content = false
  for index = open_index, #source do
    local char = source:sub(index, index)
    if char == "(" or char == "{" or char == "[" then
      depth = depth + 1
    elseif char == ")" or char == "}" or char == "]" then
      depth = depth - 1
      if depth == 0 then
        if not has_content then return 0 end
        return commas + 1
      end
    elseif depth == 1 then
      if char == "," then
        commas = commas + 1
      elseif not char:match("%s") then
        has_content = true
      end
    end
  end
  error("unbalanced parentheses after offset " .. open_index)
end

local function line_number(source, offset)
  local _, newlines = source:sub(1, offset):gsub("\n", "")
  return newlines + 1
end

-- Whether the `engine` at `start` is the global (not x.engine or x:engine;
-- `"a" .. engine` is a concatenation)
local function is_global_engine(sanitized, start)
  local before = sanitized:sub(1, start - 1):match("([%.:]*)%s*$")
  return not (before:match("[%.:]$") and before ~= "..")
end

function sync_check.lua_calls(lua_source)
  local sanitized = sanitize_lua(lua_source)
  local calls = {}
  local search_from = 1
  while true do
    local start, finish, name = sanitized:find("%f[%w_]engine%s*%.%s*([%a_][%w_]*)%s*%(", search_from)
    if not start then break end
    if is_global_engine(sanitized, start) then
      table.insert(calls, {
        name = name,
        arg_count = count_arguments(sanitized, finish),
        line = line_number(sanitized, start),
      })
    end
    search_from = finish + 1
  end
  return calls
end

-- The innermost bracket ("{", "(" or "[") still open at `offset`, or nil
local function innermost_open_bracket(sanitized, offset)
  local depth = 0
  for index = offset - 1, 1, -1 do
    local char = sanitized:sub(index, index)
    if char == ")" or char == "}" or char == "]" then
      depth = depth + 1
    elseif char == "(" or char == "{" or char == "[" then
      if depth == 0 then return char end
      depth = depth - 1
    end
  end
  return nil
end

-- Whether the `engine` token from `start` to `finish` names no global
-- value: a table constructor key ({ engine = 1 }), a function parameter
-- (function(a, engine)) or the operand of # (#engine reads no command)
local function names_no_global(sanitized, start, finish)
  local before = sanitized:sub(math.max(1, start - 300), start - 1)
  local after = sanitized:sub(finish + 1, finish + 40)
  if before:match("#%s*$") then return true end
  if before:match("%f[%w_]function%f[^%w_]%s*[%w_%.:]*%s*%([%w_,%s%.]*$") then return true end
  local is_key = before:match("[{,;]%s*$") and after:match("^%s*=") and not after:match("^%s*==")
  return is_key and innermost_open_bracket(sanitized, start) == "{" or false
end

-- Every use of the global `engine` that is not an engine.<name>(...) call,
-- engine.name, a table key or parameter named engine, or #engine:
-- { line = n, text = description }
function sync_check.lua_reference_problems(lua_source)
  local sanitized = sanitize_lua(lua_source)
  local problems = {}
  local function problem(offset, text)
    table.insert(problems, { line = line_number(sanitized, offset), text = text })
  end
  local search_from = 1
  while true do
    local start, finish = sanitized:find("%f[%w_]engine%f[^%w_]", search_from)
    if not start then break end
    search_from = finish + 1
    if is_global_engine(sanitized, start) then
      local after = sanitized:sub(finish + 1)
      local name, rest = after:match("^%s*%.%s*([%a_][%w_]*)()")
      if name then
        local follows = after:sub(rest):match("^%s*(.?)")
        if follows ~= "(" and name ~= "name" then
          problem(start, "engine." .. name .. " is used without a call, so the check cannot see its arguments")
        end
      elseif after:match("^%s*%[") then
        problem(start, "engine[...] names a command the check cannot see")
      elseif after:match("^%s*:") then
        problem(start, "engine:method() is not an engine command call")
      elseif not names_no_global(sanitized, start, finish) then
        problem(start, "the engine table is used as a value, so the check cannot see what it calls")
      end
    end
  end
  return problems
end

-- name -> signature of every addCommand that is not commented out
function sync_check.sc_commands(sc_source)
  return stubs.engine_signatures_from_source(sc_source)
end

-- Commands the engine has before the script calls them (empty: 3.4's five
-- fast-modulation commands, pending until the Lua that calls each landed,
-- are all called now). A pending command may go uncalled; one a script
-- file calls fails the check, as does a name the engine does not have, so
-- the list never outlives its use. One name per line: a release whose
-- engine lands a command before its caller adds it here, and the caller's
-- change removes it.
sync_check.PENDING_COMMANDS = {
  "noteOn",
  "noteOff",
  "noteExpression",
  "setNotePool",
}

-- lua_sources: { { path = "strata.lua" | "lib/...", text = source }, ... },
-- the script's Lua files. Problems name the file and line (<path>:<line>);
-- a command counts as called when any of the files calls it. pending: the
-- commands not called yet (default PENDING_COMMANDS)
function sync_check.check_sources(lua_sources, sc_source, pending)
  local commands = sync_check.sc_commands(sc_source)
  local problems = {}
  local lua_names = {}
  local call_count = 0
  local pending_names = {}
  for _, name in ipairs(pending or sync_check.PENDING_COMMANDS) do
    pending_names[name] = true
    if not commands[name] then
      table.insert(problems, "engine." .. name .. " is pending but the engine has no such command: remove it from PENDING_COMMANDS")
    end
  end

  for _, source in ipairs(lua_sources) do
    for _, reference in ipairs(sync_check.lua_reference_problems(source.text)) do
      table.insert(problems, string.format("%s:%d %s", source.path, reference.line, reference.text))
    end

    for _, call in ipairs(sync_check.lua_calls(source.text)) do
      call_count = call_count + 1
      lua_names[call.name] = true
      local signature = commands[call.name]
      if not signature then
        table.insert(problems, string.format("%s:%d engine.%s has no addCommand in the engine",
          source.path, call.line, call.name))
      elseif #signature ~= call.arg_count then
        table.insert(problems, string.format("%s:%d engine.%s passes %d args, signature \"%s\" takes %d",
          source.path, call.line, call.name, call.arg_count, signature, #signature))
      end
      if pending_names[call.name] then
        table.insert(problems, string.format("%s:%d engine.%s is called but still pending: remove it from PENDING_COMMANDS",
          source.path, call.line, call.name))
      end
    end
  end

  local command_names, pending_count = {}, 0
  for name in pairs(commands) do table.insert(command_names, name) end
  table.sort(command_names)
  for _, name in ipairs(command_names) do
    if pending_names[name] then
      pending_count = pending_count + 1
    elseif not lua_names[name] then
      table.insert(problems, "engine command \\" .. name .. " is never called from the script's Lua files")
    end
  end

  local summary = string.format("%d engine.* call sites in %d Lua files, %d engine commands (%d pending)",
    call_count, #lua_sources, #command_names, pending_count)
  return #problems == 0, problems, summary
end

-- One Lua source, reported as strata.lua
function sync_check.check(lua_source, sc_source)
  return sync_check.check_sources({ { path = "strata.lua", text = lua_source } }, sc_source)
end

-- The script's Lua files under repo_root: strata.lua first, then every
-- lib/**/*.lua in sorted order, as { path = <path from repo_root>, text = ... }
function sync_check.lua_sources(repo_root)
  local sources = { { path = "strata.lua", text = read_file(repo_root .. "/strata.lua") } }
  local listing = assert(io.popen('cd "' .. repo_root .. '" && find lib -name "*.lua" | sort'))
  for path in listing:read("*a"):gmatch("[^\n]+") do
    table.insert(sources, { path = path, text = read_file(repo_root .. "/" .. path) })
  end
  listing:close()
  return sources
end

function sync_check.run(repo_root)
  return sync_check.check_sources(sync_check.lua_sources(repo_root), stubs.engine_sources(repo_root))
end

sync_check.sanitize_lua = sanitize_lua

-- standalone use
if arg and arg[0] and arg[0]:match("sync_check%.lua$") then
  local test_dir = arg[0]:match("^(.*)[/\\]") or "."
  local ok, problems, summary = sync_check.run(test_dir .. "/..")
  print(summary)
  for _, problem in ipairs(problems) do print("  " .. problem) end
  print(ok and "sync check passed" or "sync check FAILED")
  os.exit(ok and 0 or 1)
end

return sync_check
