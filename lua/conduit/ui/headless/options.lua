--- Headless session options: model, effort, mode and the live choices, with
--- actions to cycle, set or pick a value. Views: the chat's chips, the inline
--- prompt title and statuslines; keys call the actions.
local options = require("conduit.options")

local M = {}

---@class conduit.OptionsModel
---@field get fun(): conduit.Option[] The current options
---@field apply fun(option: conduit.Option, value: string) Sets a value
local Model = {}
Model.__index = Model

---@param get fun(): conduit.Option[]
---@param apply fun(option: conduit.Option, value: string)
---@return conduit.OptionsModel
function M.new(get, apply)
    return setmetatable({ get = get, apply = apply }, Model)
end

---The value `count` steps after the current one, wrapping around (negative
---counts go backwards).
---@param option conduit.Option
---@param count integer
---@return string?
function M.step(option, count)
    local n = #option.choices
    if n == 0 then
        return nil
    end
    local index = 0
    for i, c in ipairs(option.choices) do
        if c.value == option.current then
            index = i
        end
    end
    if index == 0 then
        -- Unknown current value: forward starts at the first, backward at the last.
        index = count > 0 and 0 or 1
    end
    return option.choices[(index - 1 + count) % n + 1].value
end

---@param key string
---@return conduit.Option?
function Model:find(key)
    return options.find(self.get(), key)
end

---Move option `key` `count` steps (default 1; negative goes back).
---@param key string
---@param count? integer
---@return boolean found
function Model:cycle(key, count)
    local option = self:find(key)
    if not option then
        vim.notify(("[conduit] the agent has no %s option"):format(key), vim.log.levels.WARN)
        return false
    end
    local value = M.step(option, count or 1)
    if value and value ~= option.current then
        self.apply(option, value)
    end
    return true
end

---@param key string
---@param value string
---@return boolean found
function Model:set(key, value)
    local option = self:find(key)
    if not option then
        return false
    end
    self.apply(option, value)
    return true
end

---Pick a value for `key` (or an option first, then a value) in the keyboard picker.
---@param key? string
function Model:open_picker(key)
    local view = require("conduit.ui.picker_float")
    local function pick_value(option)
        view.open({
            title = option.name,
            current = option.current,
            items = vim.tbl_map(function(c)
                return { value = c.value, label = c.name, description = c.description }
            end, option.choices),
            on_pick = function(item)
                if item.value ~= option.current then
                    self.apply(option, item.value)
                end
            end,
        })
    end
    if key then
        local option = self:find(key)
        if not option then
            return vim.notify(("[conduit] the agent has no %s option"):format(key), vim.log.levels.WARN)
        end
        return pick_value(option)
    end
    local opts = self.get()
    if #opts == 0 then
        return vim.notify("[conduit] the agent exposes no session options", vim.log.levels.WARN)
    end
    view.open({
        title = "Options",
        items = vim.tbl_map(function(o)
            return { value = o, label = o.name, description = options.current_name(o) }
        end, opts),
        on_pick = function(item)
            -- Open the value picker once this one has closed.
            vim.schedule(function()
                pick_value(item.value)
            end)
        end,
    })
end

return M
