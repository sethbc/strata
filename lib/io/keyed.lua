-- lib/io/keyed.lua
-- A choice kept by key (3.6), S.lib.io_keyed: an option param for the menu
-- and the screen, and directly after it a hidden text param "<id>_key"
-- holding the chosen key. A PSET keeps the key, never the option's index,
-- so a list that gains an entry (a modulation source a later release
-- registers) never moves a saved choice onto another. crow's output
-- sources use it; MIDI out's CC slots and the nb selector are meant to.
-- Notes: docs/notes/lua/io/keyed.md

return function(S)
  local M = {}

  -- id -> {keys, index = {[key] = option index}, action}
  local records, order = {}, {}

  local function key_id(id) return id .. "_key" end

  -- key's option (the first for a key the list lacks) shown silently, and
  -- the action told the key in effect
  local function select(record, id, key, silent)
    local index = record.index[key]
    params:set(id, index or 1, true)
    if not silent then record.action(index and key or record.keys[1]) end
  end

  -- Add the option id (labels, one per key in order; the first key the
  -- default) and the hidden text param id .. "_key": two params, so a
  -- group's count allows for both. Choosing an option stores its key, then
  -- calls action(key); setting the key (a PSET load) selects its option
  -- silently and calls action with the key in effect
  function M.add(id, name, keys, labels, action)
    -- (a second id in one paramset is norns' own error; init run again
    -- adds the params to a fresh paramset and replaces the record)
    assert(type(id) == "string", "S.lib.io_keyed.add: an id")
    assert(type(keys) == "table" and #keys > 0 and #labels == #keys, "S.lib.io_keyed.add: one label per key")
    assert(type(action) == "function", "S.lib.io_keyed.add: an action")
    local record = {keys = keys, index = {}, action = action}
    for index, key in ipairs(keys) do record.index[key] = index end
    if records[id] == nil then order[#order + 1] = id end
    records[id] = record
    params:add_option(id, name, labels, 1)
    -- the index is never written to a PSET: the key is what is kept
    params:set_save(id, false)
    params:add_text(key_id(id), name .. " key", keys[1])
    params:hide(key_id(id))
    params:set_action(id, function(index)
      local key = keys[index] or keys[1]
      params:set(key_id(id), key, true)
      action(key)
    end)
    params:set_action(key_id(id), function(key) select(record, id, key, false) end)
  end

  -- The key in effect: the stored one when the list has it, else the first
  function M.key(id)
    local record = records[id]
    assert(record, "S.lib.io_keyed.key: no keyed param " .. tostring(id))
    local key = params:get(key_id(id))
    if record.index[key] then return key end
    return record.keys[1]
  end

  -- After a PSET read: each keyed param ends on the key the file holds
  -- (the first key when it holds none, a PSET saved before the param),
  -- whatever order the read set the option and the key in; one already
  -- there is left alone, so a plain read acts once
  S.register_pset_hook({name = "io_keyed", read = function(_, _, pset_path, silent)
    local file = io.open(pset_path, "r")
    if not file then return end
    local text = file:read("*a")
    file:close()
    for _, id in ipairs(order) do
      local record = records[id]
      local saved = text:match('"' .. (key_id(id):gsub("%p", "%%%0")) .. '"%s*:%s*([^\n]*)')
      local key = saved or record.keys[1]
      local index = record.index[key] or 1
      if params:get(key_id(id)) ~= key or params:get(id) ~= index then
        params:set(key_id(id), key, true)
        select(record, id, key, silent)
      end
    end
  end})

  return M
end
