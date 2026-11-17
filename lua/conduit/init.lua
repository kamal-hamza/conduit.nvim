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
---@param opts? conduit.PickOpts
function M.threads(name, opts)
    local agent = name and M.agent(name) or nil
    if name and not agent then
        return
    end
    threads.pick(agent, opts)
end

---Reopen a thread by session id, or pick one of the agent's past threads.
---@param id? string
---@param name? string Agent; defaults to the current thread's, else the default agent
function M.resume(id, name)
    local agent = name and M.agent(name) or nil
    if name and not agent then
        return
    end
    threads.resume(id, agent)
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

---Switch to the thread used before the current one.
---@return conduit.Chat?
function M.thread_alternate()
    return threads.alternate()
end

---Go to a thread by number (as in the thread bar), session id or title.
---@param target? string Opens the picker when omitted or ambiguous
---@return conduit.Chat?
function M.thread_goto(target)
    return threads.jump(target)
end

---Search the transcripts of live threads for `pattern` (plain text, smartcase).
---@param pattern? string Prompted for when omitted
---@param opts? { qf?: boolean } Send matches to the quickfix list instead of the picker
---@return conduit.SearchMatch[]?
function M.thread_search(pattern, opts)
    return threads.search(pattern, opts)
end

---Thread counts and the current thread, for statuslines.
---@return conduit.Status
function M.status()
    return threads.status()
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
    threads.confirm_delete(chat:display_title(), delete)
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

---Pick one of the agent's slash commands (`/review`, `/compact`, ...) and start
---the current chat's prompt with it, ready for arguments. With `name`, skip the picker.
---@param name? string Command name, with or without the leading `/`
function M.commands(name)
    local chat = threads.current or M.new()
    if not chat then
        return
    end
    if name then
        return chat:insert_command((name:gsub("^/", "")))
    end
    chat:ensure_session(function(err)
        if err then
            return vim.notify("[conduit] " .. err, vim.log.levels.ERROR)
        end
        local list = chat.agent:get_commands(chat.session_id)
        if #list == 0 then
            return vim.notify(("[conduit] %s has no commands"):format(chat.agent.name), vim.log.levels.INFO)
        end
        local commands = require("conduit.commands")
        vim.ui.select(list, {
            prompt = "Command",
            format_item = function(cmd)
                local hint = commands.hint(cmd)
                local desc = type(cmd.description) == "string" and cmd.description or ""
                return ("/%s%s%s"):format(
                    cmd.name,
                    hint and (" " .. hint) or "",
                    desc ~= "" and (" — " .. desc) or ""
                )
            end,
        }, function(cmd)
            if cmd then
                chat:insert_command(cmd.name)
            end
        end)
    end)
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

---Move session option `key` of the current chat `count` steps through its
---values (negative goes back), e.g. `M.cycle_option("effort", 1)`.
---@param key string Option id or category (`effort`, `mode`, ...)
---@param count? integer Defaults to 1
function M.cycle_option(key, count)
    local chat = threads.current or M.new()
    if chat then
        chat:cycle_option(key, count or 1)
    end
end

---The current chat's status chips as a statusline string (model, effort, mode,
---context use), for lualine and friends: `lualine_x = { require("conduit").statusline }`.
---Refresh on the `User ConduitStatus` autocmd. Empty without a chat.
---@param opts? { context?: boolean, agent?: boolean } Show context use (default true) and the agent name
---@return string
function M.statusline(opts)
    opts = opts or {}
    local chat = threads.current
    if not chat then
        return ""
    end
    local component = require("conduit.ui.component")
    local info = require("conduit.ui.status").of_chat(chat)
    if opts.context == false then
        info.context = nil
    end
    local spans = vim.tbl_filter(function(span)
        -- A statusline component shouldn't split the bar with `%=`.
        return not span.raw
    end, component.render("ChipBar", { status = info, agent = opts.agent }))
    return vim.trim(require("conduit.ui.surface").statusline(spans))
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
    local function run(text, chosen, overrides)
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
                options = overrides,
            })
        end
    end
    if instruction and instruction ~= "" then
        local text, chosen = require("conduit.ui.prompt").parse_prefix(instruction, mode or "auto")
        return run(text, chosen)
    end
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
    local lines = line1 == line2 and tostring(line1) or ("%d-%d"):format(line1, line2)
    local agent_name = config.options.inline.agent or config.options.default_agent
    require("conduit.ui.prompt").open({
        title = name ~= "" and ("%s:%s"):format(name, lines) or ("lines " .. lines),
        agent = agent_name,
        commands = function()
            -- No session yet: the agent's last known list, if it has run.
            local agent = M.agents[agent_name]
            return agent and agent:get_commands() or {}
        end,
        options = function()
            return require("conduit.inline").request_options(M.agents[agent_name])
        end,
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

---Focus the inline answer nearest the cursor (or the most recent one on screen).
---Answers never take focus on their own; this is how you get into one.
---@return boolean focused
function M.answer()
    return require("conduit.inline").focus()
end

---List the inline answers still around (shown or collapsed) and go to one.
function M.answers()
    local inline = require("conduit.inline")
    local jobs = inline.list()
    if #jobs == 0 then
        return vim.notify("[conduit] no inline answers", vim.log.levels.INFO)
    end
    require("conduit.ui.picker_float").open({
        title = "Answers",
        items = vim.tbl_map(function(job)
            local first = job:_range() or 0
            local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(job.buf), ":~:.")
            local request = job.history[1] and job.history[1].text:gsub("\n.*", "") or ""
            return {
                value = job,
                label = request,
                description = ("%s:%d"):format(name ~= "" and name or "[No Name]", first + 1),
            }
        end, jobs),
        on_pick = function(item)
            inline.reveal(item.value)
        end,
    })
end

---Browse the inline history: every inline answer and edit, separate from chat
---threads. Opens on the current buffer's entries (or the project's when it has none).
---@param opts? { scope?: "buffer"|"project", qf?: boolean } `qf` sends the entries to the quickfix list
function M.history(opts)
    opts = opts or {}
    if opts.qf then
        local entries = require("conduit.inline_history").load()
        if opts.scope ~= "project" then
            local file = vim.api.nvim_buf_get_name(0)
            local mine = vim.tbl_filter(function(e)
                return e.file == file
            end, entries)
            entries = #mine > 0 and mine or entries
        end
        return require("conduit.inline_history").to_qf(entries)
    end
    require("conduit.ui.history_float").open({ scope = opts.scope })
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

---List the agent's changes waiting for review in the quickfix list, or turn
---review on or off (`action = "toggle"`, everywhere or for `source`).
---@param action? "toggle"
---@param source? "chat"|"inline"
function M.review(action, source)
    local review = require("conduit.review")
    if action == "toggle" then
        review.toggle(source)
        return
    end
    local items = review.qflist()
    if #items == 0 then
        return vim.notify("[conduit] no agent changes to review", vim.log.levels.INFO)
    end
    vim.fn.setqflist({}, " ", { title = "conduit review", items = items })
    vim.cmd("botright copen")
end

---@param action "accept"|"reject"
---@param all? boolean
local function review_files(action, all)
    local review = require("conduit.review")
    if all and action == "accept" then
        return review.accept_all()
    elseif all then
        return review.reject_all()
    end
    local name = vim.api.nvim_buf_get_name(0)
    local path = name ~= "" and require("conduit.fs").canonical(name)
    if not path or not review.files[path] then
        return vim.notify("[conduit] no agent changes to review in this buffer", vim.log.levels.INFO)
    end
    review[action](path)
end

---Accept the agent's changes to the current file, or to every file.
---@param all? boolean
function M.accept(all)
    review_files("accept", all)
end

---Reject the agent's changes to the current file, or to every file.
---@param all? boolean
function M.reject(all)
    review_files("reject", all)
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
