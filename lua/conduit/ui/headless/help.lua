--- Headless help: the keys of one surface, filterable. The `HelpFloat` view
--- renders it for `g?`.
local store = require("conduit.ui.headless.store")

local M = {}

---@class conduit.HelpModel: conduit.Store
---@field title string
---@field keys [string, string][] `{ key, description }` pairs
---@field query string
---@field is_open boolean
local Help = store.extend({})
Help.__index = Help

---@param title string
---@param keys [string, string][]
---@return conduit.HelpModel
function M.new(title, keys)
    local self = setmetatable({ title = title, keys = keys, query = "", is_open = false }, Help)
    store.init(self)
    return self
end

---Keys matching the filter (by key or description).
---@return [string, string][]
function Help:entries()
    local q = self.query:lower()
    if q == "" then
        return self.keys
    end
    return vim.tbl_filter(function(k)
        return k[1]:lower():find(q, 1, true) ~= nil or k[2]:lower():find(q, 1, true) ~= nil
    end, self.keys)
end

function Help:open()
    self.is_open = true
    self:changed()
end

function Help:close()
    if self.is_open then
        self.is_open = false
        self:changed()
    end
end

---@param query string
function Help:filter(query)
    self.query = query
    self:changed()
end

return M
