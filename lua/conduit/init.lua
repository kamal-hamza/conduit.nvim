local config = require("conduit.config")
local threads = require("conduit.threads")

---@class conduit.Api
---@field current? conduit.Chat The current thread (read-only, see `conduit.threads`)
local M = {}

M.version = "0.1.0"

---@type table<string, conduit.Agent>
M.agents = {}

setmetatable(M, {
    __index = function(_, key)
        if key == "current" then
            return threads.current
        end
    end,
})

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

---Start a new thread (chat + ACP session) with `name`, or the default agent.
---Earlier threads stay alive; switch back with `threads()` or `thread_next()`.
---@param name? string
---@return conduit.Chat?
function M.new(name)
    local agent = M.agent(name)
    if not agent then
        return
    end
    local chat = require("conduit.ui.chat").new(agent)
    threads.switch(chat)
    chat:open()
    return chat
end

---Open the current thread, creating one if needed. Naming another agent switches
---to its most recent thread, or starts one.
---@param name? string
---@return conduit.Chat?
function M.open(name)
    local current = threads.current
    if current and (not name or current.agent.name == name) then
        current:open()
        return current
    end
    for i = #threads.list, 1, -1 do
        local chat = threads.list[i]
        if chat.agent.name == name then
            threads.switch(chat)
            chat:open()
            return chat
        end
    end
    return M.new(name)
end

function M.toggle()
    if threads.current then
        threads.current:toggle()
    else
        M.open()
    end
end

---Pick a thread: live ones, past ones (when the agent can load sessions), or a new one.
---@param name? string Agent whose past threads to list; defaults to the current thread's
function M.threads(name)
    local agent = name and M.agent(name) or nil
    if name and not agent then
        return
    end
    threads.pick(agent)
end

---Continue where you left off: the current or most recent thread with `name`
---(or the default agent), reopening past threads when the agent supports it.
---@param name? string
function M.continue_thread(name)
    local agent = M.agent(name)
    if agent then
        threads.continue(agent)
    end
end

---Switch to the next thread.
---@return conduit.Chat?
function M.thread_next()
    return threads.cycle(1)
end

---Switch to the previous thread.
---@return conduit.Chat?
function M.thread_prev()
    return threads.cycle(-1)
end

---Close the current thread. It stays in the history (see `threads()`) when the
---agent can reopen sessions.
function M.thread_close()
    if threads.current then
        threads.close(threads.current)
    end
end

---Delete the current thread for good, from the agent's history too when supported.
---@param opts? { force?: boolean } Skip the confirmation
function M.thread_delete(opts)
    local chat = threads.current
    if not chat then
        return
    end
    local function delete()
        local sid = chat.session_id or chat.resume_id
        if sid then
            threads.delete(chat.agent, sid)
        else
            threads.close(chat)
        end
    end
    if opts and opts.force then
        return delete()
    end
    vim.ui.select({ "Delete", "Cancel" }, {
        prompt = ("Delete thread %q permanently?"):format(chat:display_title()),
    }, function(choice)
        if choice == "Delete" then
            delete()
        end
    end)
end

---Fork the current thread into a new one with the same context, if the agent supports it.
function M.thread_fork()
    if threads.current then
        threads.fork(threads.current)
    end
end

---Rename the current thread. Prompts for the title when omitted.
---@param title? string
function M.thread_rename(title)
    local chat = threads.current
    if not chat then
        return
    end
    local function rename(text)
        text = text and vim.trim(text) or ""
        if text ~= "" then
            chat:rename(text, function(err)
                if err then
                    vim.notify("[conduit] could not rename the thread: " .. err, vim.log.levels.WARN)
                end
            end)
        end
    end
    if title then
        return rename(title)
    end
    vim.ui.input({ prompt = "Thread title: ", default = chat.title }, rename)
end

---Cancel running inline edits, or else the current chat turn.
function M.cancel()
    if require("conduit.inline").cancel() then
        return
    end
    if threads.current then
        threads.current:cancel()
    end
end

---Pick or set a session option on the current chat, e.g. `M.option("model", "opus")`.
---@param key? string Option id or category (`model`, `effort`, `mode`, ...)
---@param value? string
function M.option(key, value)
    local chat = threads.current or M.new()
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
    require("conduit.ui.prompt").open({
        title = line1 == line2 and ("Line %d"):format(line1) or ("Lines %d-%d"):format(line1, line2),
        mode = mode or "auto",
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
    local chat = require("conduit.ui.chat").new(agent)
    chat:adopt(session_id, history)
    threads.switch(chat, { open = false })
    return chat
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
