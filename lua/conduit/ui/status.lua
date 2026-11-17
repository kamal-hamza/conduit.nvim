--- The status model: agent, model, effort, mode, state and context use for a
--- chat (or any agent session), and change notifications. Every surface that
--- shows status (chat winbars, the inline prompt title, statuslines) reads from
--- here, so they always agree.
local M = {}

---@class conduit.Usage ACP `usage_update`
---@field used integer Tokens in context
---@field size integer Context window size
---@field cost? { amount: number, currency: string }

---@class conduit.StatusInfo
---@field agent string
---@field model? string Display name of the current model
---@field effort? string
---@field mode? string
---@field state "not started"|"loading"|"working"|"ready"|"disconnected"
---@field context? { used: integer, size: integer, percent: integer, cost?: { amount: number, currency: string } }
---@field frame? string Spinner frame while working
---@field options conduit.Option[] The session's options (for pickers)

---@type table<integer, fun()>
local listeners = {}
local next_id = 0
local scheduled = false

---@param fn fun()
---@return integer id
function M.subscribe(fn)
    next_id = next_id + 1
    listeners[next_id] = fn
    return next_id
end

---@param id integer
function M.unsubscribe(id)
    listeners[id] = nil
end

---Tell every listener the status changed. Coalesced into one notification per
---event-loop tick, so a burst of updates redraws once.
function M.emit()
    if scheduled then
        return
    end
    scheduled = true
    vim.schedule(function()
        scheduled = false
        for id, fn in pairs(listeners) do
            local ok, err = pcall(fn)
            if not ok then
                listeners[id] = nil
                require("conduit.log").warn("status listener failed: " .. tostring(err))
            end
        end
        -- Statusline plugins (lualine, ...) can refresh on this.
        vim.api.nvim_exec_autocmds("User", { pattern = "ConduitStatus", modeline = false })
    end)
end

---Normalize an ACP `usage_update`.
---@param update table
---@return conduit.Usage?
function M.parse_usage(update)
    local used, size = update.used, update.size
    if type(used) ~= "number" or type(size) ~= "number" or size <= 0 then
        return nil
    end
    local cost = type(update.cost) == "table" and update.cost or nil
    if cost and (type(cost.amount) ~= "number" or type(cost.currency) ~= "string") then
        cost = nil
    end
    return { used = math.floor(used), size = math.floor(size), cost = cost }
end

---Status of session `sid` on `agent` (or of the agent alone, before a session).
---@param agent conduit.Agent
---@param sid? string
---@param state? string Overrides the state ("working", "loading", ...)
---@return conduit.StatusInfo
function M.of(agent, sid, state)
    local options = require("conduit.options")
    local opts = sid and agent:get_options(sid) or {}
    local info = {
        agent = agent.name,
        state = state or (sid and "ready" or "not started"),
        options = opts,
    } ---@type conduit.StatusInfo
    for field, key in pairs({ model = "model", effort = "thought_level", mode = "mode" }) do
        local option = options.find(opts, key)
        if option then
            info[field] = options.current_name(option)
        end
    end
    local usage = sid and agent.usage and agent.usage[sid]
    if usage then
        info.context = {
            used = usage.used,
            size = usage.size,
            percent = math.floor(usage.used / usage.size * 100 + 0.5),
            cost = usage.cost,
        }
    end
    return info
end

---Status of a chat.
---@param chat conduit.Chat
---@return conduit.StatusInfo
function M.of_chat(chat)
    local state = chat.loading and "loading"
        or chat.busy and "working"
        or chat.session_id and "ready"
        or chat.resume_id and "disconnected"
        or "not started"
    local info = M.of(chat.agent, chat.session_id, state)
    if chat.busy and chat.spinner then
        info.frame = chat.spinner:frame()
    end
    return info
end

return M
