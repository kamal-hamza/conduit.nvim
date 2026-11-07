local config = require("conduit.config")

local M = {}

M.version = "0.1.0"

---@type table<string, conduit.Agent>
M.agents = {}

---@type conduit.Chat?
M.current = nil

---@param opts? table
function M.setup(opts)
    config.setup(opts)
end

---Get (creating if needed) the agent called `name`, or the default agent.
---@param name? string
---@return conduit.Agent?
function M.agent(name)
    name = name or config.options.default_agent
    if not M.agents[name] then
        local spec = config.options.agents[name]
        if not spec then
            vim.notify(("[conduit] unknown agent %q"):format(name), vim.log.levels.ERROR)
            return nil
        end
        M.agents[name] = require("conduit.agent").new(name, spec)
    end
    return M.agents[name]
end

---Start a fresh chat (new ACP session) with `name`, or the default agent.
---@param name? string
---@return conduit.Chat?
function M.new(name)
    local agent = M.agent(name)
    if not agent then
        return
    end
    if M.current then
        M.current:close()
    end
    M.current = require("conduit.ui.chat").new(agent)
    M.current:open()
    return M.current
end

---Open the current chat, creating one if needed. Switching agents starts a new chat.
---@param name? string
---@return conduit.Chat?
function M.open(name)
    if M.current and (not name or M.current.agent.name == name) then
        M.current:open()
        return M.current
    end
    return M.new(name)
end

function M.toggle()
    if M.current then
        M.current:toggle()
    else
        M.open()
    end
end

---Cancel running inline edits, or else the current chat turn.
function M.cancel()
    if require("conduit.inline").cancel() then
        return
    end
    if M.current then
        M.current:cancel()
    end
end

---Pick or set a session option on the current chat, e.g. `M.option("model", "opus")`.
---@param key? string Option id or category (`model`, `effort`, `mode`, ...)
---@param value? string
function M.option(key, value)
    local chat = M.current or M.new()
    if chat then
        chat:pick_option(key, value)
    end
end

---Make an inline request about lines `line1`..`line2` of the current buffer:
---the agent rewrites them in place or answers in a float under them.
---@param line1 integer
---@param line2 integer
---@param instruction? string Prompted for when omitted
---@param mode? conduit.InlineMode "auto" (default: the agent decides), "edit" or "ask"
---@return conduit.InlineJob? job When `instruction` is given
function M.inline(line1, line2, instruction, mode)
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local function run(text, chosen)
        local agent = M.agent(config.options.inline.agent)
        if agent then
            return require("conduit.inline").run({
                agent = agent,
                buf = buf,
                win = win,
                line1 = line1,
                line2 = line2,
                instruction = text,
                mode = chosen or mode,
            })
        end
    end
    if instruction and instruction ~= "" then
        local text, chosen = require("conduit.ui.prompt").parse_prefix(instruction, mode or "auto")
        return run(text, chosen)
    end
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
    local lines = line1 == line2 and tostring(line1) or ("%d-%d"):format(line1, line2)
    require("conduit.ui.prompt").open({
        title = name ~= "" and ("%s:%s"):format(name, lines) or ("lines " .. lines),
        agent = config.options.inline.agent or config.options.default_agent,
        mode = mode or "auto",
        anchor = { win = win, first = line1 - 1, last = line2 - 1 },
        on_submit = run,
    })
end

---Inline question about lines `line1`..`line2`, answered in a float.
---@param line1 integer
---@param line2 integer
---@param question? string Prompted for when omitted
function M.ask(line1, line2, question)
    M.inline(line1, line2, question, "ask")
end

---Inline edit of lines `line1`..`line2`, applied in place.
---@param line1 integer
---@param line2 integer
---@param instruction? string Prompted for when omitted
function M.edit(line1, line2, instruction)
    M.inline(line1, line2, instruction, "edit")
end

---Open a chat on an existing session (e.g. an inline conversation).
---@param agent conduit.Agent
---@param session_id string
---@param history { role: "user"|"agent", text: string }[]
---@return conduit.Chat
function M.adopt(agent, session_id, history)
    if M.current then
        M.current:close()
    end
    M.current = require("conduit.ui.chat").new(agent)
    M.current:adopt(session_id, history)
    return M.current
end

---Stop all agent processes.
function M.stop()
    for _, agent in pairs(M.agents) do
        agent:stop()
    end
end

---Add lines `line1`..`line2` of the current buffer to the chat input as a fenced block.
---@param line1 integer
---@param line2 integer
---@return conduit.Chat?
function M.add_range(line1, line2)
    local buf = vim.api.nvim_get_current_buf()
    local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
    local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
    local block = { ("```%s %s:%d-%d"):format(vim.bo[buf].filetype, path, line1, line2) }
    vim.list_extend(block, lines)
    table.insert(block, "```")
    table.insert(block, "")
    local chat = M.open()
    if chat then
        chat:add_context(block)
    end
    return chat
end

return M
