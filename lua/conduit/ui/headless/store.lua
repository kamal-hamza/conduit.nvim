--- Shared plumbing for headless models: state plus change listeners. A headless
--- model owns state, transitions and key actions; views only render it, and keys
--- bind to model actions rather than windows (the headless component pattern).
local M = {}

---@class conduit.Store
---@field listeners table<integer, fun(model: table)>
---@field next_listener integer
local Store = {}
Store.__index = Store
M.Store = Store

---Mix the store into a model class: `setmetatable(Class, { __index = Store })`.
---@generic T
---@param class T
---@return T
function M.extend(class)
    return setmetatable(class, { __index = Store })
end

---@param self conduit.Store
function M.init(self)
    self.listeners = {}
    self.next_listener = 0
end

---@param fn fun(model: table)
---@return integer
function Store:subscribe(fn)
    self.next_listener = self.next_listener + 1
    self.listeners[self.next_listener] = fn
    return self.next_listener
end

---@param id integer
function Store:unsubscribe(id)
    self.listeners[id] = nil
end

function Store:changed()
    for _, fn in pairs(self.listeners) do
        fn(self)
    end
end

return M
