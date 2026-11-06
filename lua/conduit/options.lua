--- Session options (model, effort, mode, ...) normalized across ACP's
--- `configOptions` and the older `modes` / `models` session fields.
local M = {}

---@class conduit.Choice
---@field value string
---@field name string
---@field description? string

---@class conduit.Option
---@field id string
---@field name string
---@field category? string
---@field current? string
---@field choices conduit.Choice[]
---@field legacy? "mode"|"model" Set via session/set_mode or session/set_model

---@param choices table[]
---@return conduit.Choice[]
local function flatten(choices)
    local out = {}
    for _, c in ipairs(choices or {}) do
        if c.options then
            -- Grouped select options.
            vim.list_extend(out, flatten(c.options))
        else
            table.insert(out, { value = c.value, name = c.name or c.value, description = c.description })
        end
    end
    return out
end

---@param config_options table[]
---@return conduit.Option[]
function M.from_config_options(config_options)
    local out = {}
    for _, o in ipairs(config_options) do
        if o.type == nil or o.type == "select" then
            table.insert(out, {
                id = o.id,
                name = o.name or o.id,
                category = o.category,
                current = o.currentValue,
                choices = flatten(o.options),
            })
        end
    end
    return out
end

---Build the option list from a `session/new` (or load/resume) result.
---@param result table
---@return conduit.Option[]
function M.from_session(result)
    if result.configOptions then
        return M.from_config_options(result.configOptions)
    end
    local out = {}
    if result.modes then
        local choices = {}
        for _, m in ipairs(result.modes.availableModes or {}) do
            table.insert(choices, { value = m.id, name = m.name, description = m.description })
        end
        table.insert(out, {
            id = "mode",
            name = "Mode",
            category = "mode",
            current = result.modes.currentModeId,
            choices = choices,
            legacy = "mode",
        })
    end
    if result.models then
        local choices = {}
        for _, m in ipairs(result.models.availableModels or {}) do
            table.insert(choices, { value = m.modelId, name = m.name, description = m.description })
        end
        table.insert(out, {
            id = "model",
            name = "Model",
            category = "model",
            current = result.models.currentModelId,
            choices = choices,
            legacy = "model",
        })
    end
    return out
end

-- Friendly names for ACP's standard option categories.
local aliases = { effort = "thought_level" }

---@param options conduit.Option[]
---@param key string Option id or category (e.g. "model", "effort", "thought_level")
---@return conduit.Option?
function M.find(options, key)
    for _, o in ipairs(options) do
        if o.id == key then
            return o
        end
    end
    for _, o in ipairs(options) do
        if o.category == key then
            return o
        end
    end
    if aliases[key] then
        return M.find(options, aliases[key])
    end
end

---@param option conduit.Option
---@return string
function M.current_name(option)
    for _, c in ipairs(option.choices) do
        if c.value == option.current then
            return c.name
        end
    end
    return option.current or "?"
end

---Let the user pick an option (unless `key` is given) and then a value.
---@param options conduit.Option[]
---@param key? string
---@param cb fun(option: conduit.Option, value: string)
function M.pick(options, key, cb)
    local function pick_value(option)
        vim.ui.select(option.choices, {
            prompt = option.name,
            format_item = function(c)
                local mark = c.value == option.current and "● " or "  "
                return mark .. c.name .. (c.description and (" — " .. c.description) or "")
            end,
        }, function(choice)
            if choice then
                cb(option, choice.value)
            end
        end)
    end

    if key then
        local option = M.find(options, key)
        if not option then
            return vim.notify(("[conduit] agent has no %q option"):format(key), vim.log.levels.WARN)
        end
        return pick_value(option)
    end
    if #options == 0 then
        return vim.notify("[conduit] agent exposes no session options", vim.log.levels.WARN)
    end
    vim.ui.select(options, {
        prompt = "Session option",
        format_item = function(o)
            return ("%s: %s"):format(o.name, M.current_name(o))
        end,
    }, function(option)
        if option then
            pick_value(option)
        end
    end)
end

return M
