--- Headless inline history list: entries, a scope (this buffer or the whole
--- project), a filter and a cursor, plus the actions the list's keys run.
local store = require("conduit.ui.headless.store")

local M = {}

---@class conduit.HistoryActions
---@field jump? fun(entry: conduit.InlineEntry)
---@field preview? fun(entry: conduit.InlineEntry)
---@field rerun? fun(entry: conduit.InlineEntry)
---@field to_chat? fun(entry: conduit.InlineEntry)
---@field revert? fun(entry: conduit.InlineEntry): boolean?
---@field delete? fun(entry: conduit.InlineEntry)

---@class conduit.HistoryModelOpts
---@field entries conduit.InlineEntry[] Newest first
---@field file? string The buffer's file, for the "buffer" scope
---@field scope? "buffer"|"project"
---@field actions? conduit.HistoryActions

---@class conduit.HistoryModel: conduit.Store
---@field entries conduit.InlineEntry[]
---@field file? string
---@field scope "buffer"|"project"
---@field query string
---@field cursor integer
---@field filtered conduit.InlineEntry[]
---@field actions conduit.HistoryActions
local History = store.extend({})
History.__index = History

---@param opts conduit.HistoryModelOpts
---@return conduit.HistoryModel
function M.new(opts)
    local self = setmetatable({
        entries = opts.entries,
        file = opts.file,
        query = "",
        cursor = 1,
        filtered = {},
        actions = opts.actions or {},
    }, History)
    store.init(self)
    -- The buffer's own entries when it has any, else everything.
    self.scope = opts.scope or "buffer"
    self:_refilter()
    if not opts.scope and #self.filtered == 0 then
        self.scope = "project"
        self:_refilter()
    end
    return self
end

function History:_refilter()
    local q = self.query:lower()
    self.filtered = vim.tbl_filter(function(e)
        if self.scope == "buffer" and e.file ~= self.file then
            return false
        end
        return q == ""
            or e.prompt:lower():find(q, 1, true) ~= nil
            or e.file:lower():find(q, 1, true) ~= nil
            or (e.text or ""):lower():find(q, 1, true) ~= nil
    end, self.entries)
    self.cursor = math.max(1, math.min(self.cursor, #self.filtered))
end

---@return conduit.InlineEntry?
function History:selected()
    return self.filtered[self.cursor]
end

---@param n? integer
function History:next(n)
    if #self.filtered > 0 then
        self.cursor = math.max(1, math.min(#self.filtered, self.cursor + (n or 1)))
        self:changed()
    end
end

---@param n? integer
function History:prev(n)
    self:next(-(n or 1))
end

---@param query string
function History:filter(query)
    self.query = query
    self:_refilter()
    self:changed()
end

function History:toggle_scope()
    self.scope = self.scope == "buffer" and "project" or "buffer"
    self:_refilter()
    self:changed()
end

---Run action `name` on the selected entry.
---@param name "jump"|"preview"|"rerun"|"to_chat"|"revert"|"delete"
function History:run(name)
    local entry = self:selected()
    local action = self.actions[name]
    if not entry or not action then
        return
    end
    local result = action(entry)
    if name == "delete" then
        self.entries = vim.tbl_filter(function(e)
            return e ~= entry
        end, self.entries)
        self:_refilter()
    end
    if name == "delete" or (name == "revert" and result) then
        self:changed()
    end
end

return M
