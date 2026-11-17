--- Headless picker: a list of items, a filter query and a cursor. Views (the
--- `Picker` float, or any picker plugin) render it and call its actions.
local store = require("conduit.ui.headless.store")

local M = {}

---@class conduit.PickerModelItem
---@field value any
---@field label string
---@field description? string

---@class conduit.PickerModelOpts
---@field items conduit.PickerModelItem[]
---@field title? string
---@field current? any Value of the item marked as current (the cursor starts there)
---@field on_pick fun(item: conduit.PickerModelItem)
---@field on_cancel? fun()

---@class conduit.PickerModel: conduit.Store
---@field items conduit.PickerModelItem[]
---@field title? string
---@field current? any
---@field query string
---@field cursor integer 1-based index into `filtered`
---@field filtered conduit.PickerModelItem[]
---@field done boolean
---@field on_pick fun(item: conduit.PickerModelItem)
---@field on_cancel? fun()
local Picker = store.extend({})
Picker.__index = Picker

---@param opts conduit.PickerModelOpts
---@return conduit.PickerModel
function M.new(opts)
    local self = setmetatable({
        items = opts.items,
        title = opts.title,
        current = opts.current,
        query = "",
        cursor = 1,
        filtered = {},
        done = false,
        on_pick = opts.on_pick,
        on_cancel = opts.on_cancel,
    }, Picker)
    store.init(self)
    self:_refilter()
    for i, item in ipairs(self.filtered) do
        if item.value == opts.current then
            self.cursor = i
        end
    end
    return self
end

function Picker:_refilter()
    local q = self.query:lower()
    self.filtered = vim.tbl_filter(function(item)
        return q == "" or item.label:lower():find(q, 1, true) ~= nil
    end, self.items)
    self.cursor = math.max(1, math.min(self.cursor, #self.filtered))
end

---@return conduit.PickerModelItem?
function Picker:selected()
    return self.filtered[self.cursor]
end

---@param n? integer
function Picker:next(n)
    if #self.filtered > 0 then
        self.cursor = (self.cursor - 1 + (n or 1)) % #self.filtered + 1
        self:changed()
    end
end

---@param n? integer
function Picker:prev(n)
    self:next(-(n or 1))
end

---@param query string
function Picker:filter(query)
    self.query = query
    self:_refilter()
    self:changed()
end

---Pick the `n`th visible item directly.
---@param n integer
function Picker:pick(n)
    if self.filtered[n] then
        self.cursor = n
        self:confirm()
    end
end

function Picker:confirm()
    local item = self:selected()
    if self.done or not item then
        return
    end
    self.done = true
    self:changed()
    self.on_pick(item)
end

function Picker:cancel()
    if self.done then
        return
    end
    self.done = true
    self:changed()
    if self.on_cancel then
        self.on_cancel()
    end
end

return M
