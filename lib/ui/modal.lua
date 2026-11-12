-- lib/ui/modal.lua
-- The modal screen owner (3.4, design §0.1): a stack of owners, the top one
-- taking the screen and the controls from the page while it is pushed
-- (3.4's step editor). strata.lua's enc (E2 and E3; E1 does nothing), key
-- (K2 and K3, presses and releases; K1 still sets ALT) and redraw (after
-- the file selector's check: the header, then the owner's body and hints)
-- and lib/arc/core.lua's arc_delta, arc_key and arc_redraw go to top()
-- while one is pushed. Fields of this module's table (S.lib.ui_modal):
-- push, pop, top, and key (strata.lua's K2/K3 while an owner is pushed: a
-- release reaches an owner only if its press did).
--
-- An owner is {draw = fn(), hints = fn(alt_held) -> string, enc = fn(n, d),
-- key = fn(n, z), arc_delta = fn(n, d), arc_key = fn(n, z), arc_redraw =
-- fn(arc_port), animates = fn() -> boolean}: only draw is required; a
-- missing handler ignores its input. animates, read by the frame clock
-- (lib/ui/frame.lua) as a page's is, draws every frame while true (#592).

return function(S)
  local M = {}

  local OWNER_HANDLERS = {"hints", "enc", "key", "arc_delta", "arc_key", "arc_redraw", "animates"}

  -- The pushed owners, the top one last. Local: push and pop are the only
  -- ways on and off
  local stack = {}

  -- Per key (2, 3): the owner its press went to, until its release. Only a
  -- press an owner saw releases into it: a key that went down on the page
  -- (or on another owner) releases into nothing
  local pressed = {}

  local function index_of(owner)
    for index, pushed in ipairs(stack) do
      if pushed == owner then return index end
    end
    return nil
  end

  -- Push an owner on top: it takes the screen, the encoders, K2, K3 and
  -- the arc from now on. An owner already on the stack is an error
  function M.push(owner)
    if type(owner) ~= "table" or type(owner.draw) ~= "function" then
      error("ui_modal.push: an owner is a table with a draw function", 2)
    end
    for _, field in ipairs(OWNER_HANDLERS) do
      if owner[field] ~= nil and type(owner[field]) ~= "function" then
        error("ui_modal.push: an owner's " .. field .. " is a function", 2)
      end
    end
    if index_of(owner) then error("ui_modal.push: the owner is already pushed", 2) end
    table.insert(stack, owner)
    request_redraw()
  end

  -- Take an owner off the stack, wherever it is; an owner not on it:
  -- nothing. Its keys still down release into nothing
  function M.pop(owner)
    local index = index_of(owner)
    if not index then return end
    table.remove(stack, index)
    for n, press_owner in pairs(pressed) do
      if press_owner == owner then pressed[n] = nil end
    end
    request_redraw()
  end

  -- The owner the screen and controls go to, or nil (the page has them)
  function M.top()
    return stack[#stack]
  end

  -- K2 or K3 (z 1 down, 0 up) while an owner is pushed (strata.lua's key):
  -- a press goes to the top owner's key(n, 1), a release to its key(n, 0)
  -- only when that owner saw the press
  function M.key(n, z)
    local owner = M.top()
    if not owner then return end
    if z == 1 then
      pressed[n] = owner
      if owner.key then owner.key(n, 1) end
    else
      local press_owner = pressed[n]
      pressed[n] = nil
      if press_owner == owner and owner.key then owner.key(n, 0) end
    end
  end

  -- No owner is on the stack twice, and every key down on an owner is on
  -- one that is pushed
  S.register_invariant("modal owner", function()
    local seen = {}
    for index, owner in ipairs(stack) do
      if seen[owner] then return "owner " .. tostring(owner) .. " is on the stack at " .. seen[owner] .. " and " .. index end
      seen[owner] = index
    end
    for n, press_owner in pairs(pressed) do
      if not seen[press_owner] then return "key " .. tostring(n) .. " is down on an owner that is not pushed" end
    end
  end)

  return M
end
