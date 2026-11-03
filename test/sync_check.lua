-- test/sync_check.lua
-- Static Lua <-> SuperCollider command sync check.
-- Extracts every engine.<name>(...) call from strata.lua and every
-- this.addCommand(\<name>, "<sig>", ...) from lib/Engine_Strata.sc, then
-- checks that the two name sets are equal and that every Lua call passes
-- exactly as many arguments as its signature declares.
--
-- Standalone:  lua test/sync_check.lua   (exit status 1 on mismatch)
-- As a module: require("sync_check").run(repo_root) -> ok, report_lines

local sync_check = {}

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

function sync_check.lua_calls(lua_source)
  local sanitized = sanitize_lua(lua_source)
  local calls = {}
  local search_from = 1
  while true do
    local start, finish, name = sanitized:find("engine%.([%a_][%w_]*)%s*%(", search_from)
    if not start then break end
    table.insert(calls, {
      name = name,
      arg_count = count_arguments(sanitized, finish),
      line = line_number(sanitized, start),
    })
    search_from = finish + 1
  end
  return calls
end

function sync_check.sc_commands(sc_source)
  local commands = {}
  for name, signature in sc_source:gmatch('addCommand%(%s*\\(%w+)%s*,%s*"([^"]*)"') do
    commands[name] = signature
  end
  return commands
end

function sync_check.run(repo_root)
  local lua_source = read_file(repo_root .. "/strata.lua")
  local sc_source = read_file(repo_root .. "/lib/Engine_Strata.sc")
  local calls = sync_check.lua_calls(lua_source)
  local commands = sync_check.sc_commands(sc_source)
  local problems = {}
  local lua_names = {}

  for _, call in ipairs(calls) do
    lua_names[call.name] = true
    local signature = commands[call.name]
    if not signature then
      table.insert(problems, string.format("strata.lua:%d engine.%s has no addCommand in the engine",
        call.line, call.name))
    elseif #signature ~= call.arg_count then
      table.insert(problems, string.format("strata.lua:%d engine.%s passes %d args, signature \"%s\" takes %d",
        call.line, call.name, call.arg_count, signature, #signature))
    end
  end

  local command_names = {}
  for name in pairs(commands) do table.insert(command_names, name) end
  table.sort(command_names)
  for _, name in ipairs(command_names) do
    if not lua_names[name] then
      table.insert(problems, "engine command \\" .. name .. " is never called from strata.lua")
    end
  end

  local summary = string.format("%d engine.* call sites, %d engine commands", #calls, #command_names)
  return #problems == 0, problems, summary
end

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
