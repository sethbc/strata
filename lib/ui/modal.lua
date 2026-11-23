-- lib/ui/modal.lua
-- The modal screen owner (3.4, design §0.1): a stack of owners, the top one
-- taking the screen and the controls from the page while it is pushed
-- (3.4's step editor). strata.lua's enc (E2 and E3; E1 does nothing), key
-- (K2 and K3, presses and releases; K1 still sets ALT) and redraw (after
-- the file selector's check: the header, then the owner's body and hints)
-- and lib/arc/core.lua's arc_delta, arc_key and arc_redraw go to top()
-- while one is pushed. Fields of this module's table (S.lib.ui_modal):
-- push, pop, top, key (strata.lua's K2/K3 while an owner is pushed: a
-- release reaches an owner only if its press did), held_seconds (how long
-- the top owner's key has been held, #866) and forget_presses.
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

  -- Per key (2, 3): the owner its press went to, until its release, and
  -- when it went down (util.time()). Only a press an owner saw releases
  -- into it: a key that went down on the page (or on another owner)
  -- releases into nothing. Only the top owner has presses: a push forgets
  -- the covered owner's (#866)
  local pressed = {}
  local pressed_at = {}

  -- Forget every owner's held keys: a push (the covered owner's), and
  -- forget_held_keys (the norns menu, the file selector and a name entry
  -- take the releases)
  function M.forget_presses()
    for n in pairs(pressed) do pressed[n] = nil end
    for n in pairs(pressed_at) do pressed_at[n] = nil end
  end

  local function index_of(owner)
    for index, pushed in ipairs(stack) do
      if pushed == owner then return index end
    end
    return nil
  end

  -- Push an owner on top: it takes the screen, the encoders, K2, K3 and
  -- the arc from now on. The covered owner, or the page, forgets its held
  -- keys (their releases go to the new owner, which never saw the presses;
  -- #866: the grid's step editor may cover any owner). An owner already on
  -- the stack is an error
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
    M.forget_presses()
    S.lib.ui_keys.forget_presses()
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
      if press_owner == owner then pressed[n], pressed_at[n] = nil, nil end
    end
    request_redraw()
  end

  -- The owner the screen and controls go to, or nil (the page has them)
  function M.top()
    return stack[#stack]
  end

  -- K2 or K3 (z 1 down, 0 up) while an owner is pushed (strata.lua's key):
  -- a press goes to the top owner's key(n, 1), a release to its key(n, 0)
  -- only when that owner saw the press; the press is forgotten after the
  -- release, so the owner's release reads held_seconds, and also when the
  -- release raises (the error is raised again after)
  function M.key(n, z)
    local owner = M.top()
    if not owner then return end
    if z == 1 then
      pressed[n], pressed_at[n] = owner, util.time()
      if owner.key then owner.key(n, 1) end
    else
      local press_owner = pressed[n]
      local released, release_error = true, nil
      if press_owner == owner and owner.key then released, release_error = xpcall(owner.key, with_traceback, n, 0) end
      pressed[n], pressed_at[n] = nil, nil
      if not released then error(release_error, 0) end
    end
  end

  -- How long key n has been held on owner, in seconds, or nil: up, or the
  -- owner is not the top one, or it never saw the press (it went down on
  -- the page or on another owner, or was forgotten)
  function M.held_seconds(owner, n)
    if owner == nil or M.top() ~= owner or pressed[n] ~= owner then return nil end
    return util.time() - pressed_at[n]
  end

  -- No owner is on the stack twice, every key down on an owner is on the
  -- top one (a push forgets the covered owner's), and a key has a press
  -- time exactly while it is down on an owner
  S.register_invariant("modal owner", function()
    local seen = {}
    for index, owner in ipairs(stack) do
      if seen[owner] then return "owner " .. tostring(owner) .. " is on the stack at " .. seen[owner] .. " and " .. index end
      seen[owner] = index
    end
    for n, press_owner in pairs(pressed) do
      if not seen[press_owner] then return "key " .. tostring(n) .. " is down on an owner that is not pushed" end
      if press_owner ~= M.top() then return "key " .. tostring(n) .. " is down on a covered owner" end
      if pressed_at[n] == nil then return "key " .. tostring(n) .. " is down on an owner with no press time" end
    end
    for n in pairs(pressed_at) do
      if pressed[n] == nil then return "key " .. tostring(n) .. " has a press time and no owner" end
    end
  end)

  return M
end
