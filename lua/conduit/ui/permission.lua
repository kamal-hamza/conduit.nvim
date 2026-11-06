local M = {}

---Show a `session/request_permission` request in vim.ui.select.
---@param agent_name string
---@param title string What the agent wants to do
---@param params table
---@param respond fun(err: table?, result: any)
function M.ask(agent_name, title, params, respond)
    vim.ui.select(params.options or {}, {
        prompt = ("%s wants to %s"):format(agent_name, title),
        format_item = function(option)
            return option.name
        end,
    }, function(choice)
        if choice then
            respond(nil, { outcome = { outcome = "selected", optionId = choice.optionId } })
        else
            respond(nil, { outcome = { outcome = "cancelled" } })
        end
    end)
end

return M
