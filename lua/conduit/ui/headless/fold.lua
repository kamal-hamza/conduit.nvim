--- Headless fold: whether a block (a thinking section, a tool call) is open,
--- and how many lines it hides.
local store = require("conduit.ui.headless.store")

local M = {}

---@class conduit.FoldModel: conduit.Store
---@field open boolean
---@field lines integer
local Fold = store.extend({})
Fold.__index = Fold

---@param open? boolean
---@return conduit.FoldModel
function M.new(open)
    local self = setmetatable({ open = open or false, lines = 0 }, Fold)
    store.init(self)
    return self
end

function Fold:toggle()
    self.open = not self.open
    self:changed()
end

---@param n integer
function Fold:set_lines(n)
    if n ~= self.lines then
        self.lines = n
        self:changed()
    end
end

return M
