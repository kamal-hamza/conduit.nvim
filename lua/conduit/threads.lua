--- Threads: chats (an ACP session plus its buffers). Live threads are the ones in
--- this Neovim; one is current, and switching swaps its buffers into the chat
--- windows. Past threads come from the agent (`session/list`) or, for agents that
--- can load sessions but not list them, from the local index (`conduit.history`).
--- Everything beyond live threads depends on what the agent advertises.
local config = require("conduit.config")
local history = require("conduit.history")
local log = require("conduit.log")
local picker = require("conduit.ui.picker")

local M = {}

---@type conduit.Chat[] In creation order
M.list = {}

---@type conduit.Chat?
M.current = nil

-- Bumped on every switch; `chat.last_used` orders threads by recent use.
local tick = 0

---@param chat conduit.Chat
---@return integer?
function M.index(chat)
    for i, c in ipairs(M.list) do
        if c == chat then
            return i
        end
    end
end

---@param agent string
---@param sid string
---@return conduit.Chat?
function M.find(agent, sid)
    for _, chat in ipairs(M.list) do
        if chat.agent.name == agent and (chat.session_id == sid or chat.resume_id == sid) then
            return chat
        end
    end
end

---Redraw every visible chat's winbar (thread counts change with the list).
local function refresh()
    for _, chat in ipairs(M.list) do
        if chat:is_open() then
            chat:_refresh_winbar()
        end
    end
end

---Fire `User ConduitThread<event>` with the thread's agent, session id and title.
---@param event "Created"|"Switched"|"Closed"|"Updated"
---@param chat conduit.Chat
function M.emit(event, chat)
    local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "ConduitThread" .. event,
        modeline = false,
        data = { agent = chat.agent.name, session_id = chat.session_id, title = chat:display_title() },
    })
    if not ok then
        log.warn(("ConduitThread%s autocmd failed: %s"):format(event, err))
    end
end

---A thread's title or state changed: redraw winbars (the thread bar shows every
---thread) and fire `ConduitThreadUpdated`.
---@param chat conduit.Chat
function M.changed(chat)
    refresh()
    if not M.index(chat) then
        if chat:is_open() then
            chat:_refresh_winbar()
        end
        return
    end
    M.emit("Updated", chat)
end

---Register a new thread. Doesn't make it current; see `switch`.
---@param chat conduit.Chat
---@return conduit.Chat
function M.add(chat)
    if not M.index(chat) then
        table.insert(M.list, chat)
        M.emit("Created", chat)
    end
    return chat
end

---Make `chat` the current thread. If the previous thread is on screen, its
---windows show `chat` instead; otherwise `chat` opens unless `opts.open` is false.
---@param chat conduit.Chat
---@param opts? { open?: boolean }
function M.switch(chat, opts)
    M.add(chat)
    local prev = M.current ---@type conduit.Chat?
    M.current = chat
    tick = tick + 1
    chat.last_used = tick
    chat.unread = false
    if prev and prev ~= chat then
        local twin, iwin = prev:wins()
        if twin and iwin then
            chat:show(twin, iwin)
        elseif twin or iwin then
            prev:close()
        end
    end
    if not chat:is_open() and not (opts and opts.open == false) then
        chat:open()
    end
    refresh()
    if prev ~= chat then
        M.emit("Switched", chat)
    end
end

---Switch to the thread `delta` places after the current one, wrapping around.
---@param delta integer
---@return conduit.Chat?
function M.cycle(delta)
    local n = #M.list
    if n == 0 then
        return nil
    end
    local i = M.current and M.index(M.current) or 1
    local chat = assert(M.list[(i - 1 + delta) % n + 1])
    M.switch(chat)
    return chat
end

---Close a live thread: cancel its turn, wipe its buffers and release the session
---(`session/close` when supported). It stays in the thread history, so agents that
---can load sessions can reopen it. If it was current, the thread used before it
---takes its place on screen.
---@param chat conduit.Chat
function M.close(chat)
    local i = M.index(chat)
    if not i then
        return
    end
    M.emit("Closed", chat)
    table.remove(M.list, i)
    if M.current == chat then
        M.current = nil
        local neighbour = M.mru()[1]
        if neighbour then
            local twin, iwin = chat:wins()
            M.switch(neighbour, { open = false })
            if twin and iwin then
                neighbour:show(twin, iwin)
            end
        end
    end
    local sid = chat.session_id
    chat:destroy()
    if sid then
        chat.agent:close_session(sid)
    end
    refresh()
end

---Delete a thread for good: close it if it's live, delete the session from the
---agent's history (`session/delete`) when supported, and forget it locally. If
---the agent can't delete it, it's hidden from thread lists instead.
---@param agent conduit.Agent
---@param sid string
---@param cb? fun(err: string?)
function M.delete(agent, sid, cb)
    cb = cb
        or function(err)
            if err then
                vim.notify("[conduit] " .. err, vim.log.levels.ERROR)
            end
        end
    local chat = M.find(agent.name, sid)
    if chat then
        M.close(chat)
    end
    history.remove(agent.name, sid)
    if not agent:supports("list") then
        return cb(nil)
    end
    agent:delete_session(sid, function(err, deleted)
        if not deleted then
            -- Still in session/list; keep it out of ours.
            history.hide(agent.name, sid)
        end
        cb(err and ("could not delete the session: " .. err) or nil)
    end)
end

---@param iso? string ISO 8601 timestamp
---@return integer? seconds since the epoch
function M.parse_time(iso)
    if type(iso) ~= "string" then
        return nil
    end
    local y, mo, d, h, mi, s, rest = iso:match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)%.?%d*(.*)$")
    if not (y and mo and d and h and mi and s and rest) then
        return nil
    end
    local t = {
        year = tonumber(y),
        month = tonumber(mo),
        day = tonumber(d),
        hour = tonumber(h),
        min = tonumber(mi),
        sec = tonumber(s),
        isdst = false,
    }
    -- os.time() reads the table as local time; shift to UTC, then apply the offset.
    local now = os.time()
    local local_offset = os.difftime(now, os.time(os.date("!*t", now) --[[@as std.osdateparam]]))
    local epoch = os.time(t --[[@as std.osdateparam]]) + local_offset
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if sign then
        local offset = ((tonumber(oh) or 0) * 60 + (tonumber(om) or 0)) * 60
        epoch = sign == "+" and epoch - offset or epoch + offset
    end
    return math.floor(epoch)
end

---@param iso? string
---@return string? "5m ago", "3d ago", ...
function M.ago(iso)
    local t = M.parse_time(iso)
    if not t then
        return nil
    end
    local secs = math.max(0, os.time() - t)
    for _, unit in ipairs({ { 86400 * 365, "y" }, { 86400 * 30, "mo" }, { 86400, "d" }, { 3600, "h" }, { 60, "m" } }) do
        if secs >= unit[1] then
            return ("%d%s ago"):format(math.floor(secs / unit[1]), unit[2])
        end
    end
    return "just now"
end

---Past threads for `agent` that aren't live, most recent first. Starts the agent
---(its capabilities are only known once it's running).
---@param agent conduit.Agent
---@param cb fun(threads: conduit.ThreadInfo[], err: string?)
---@param opts? { scope?: "cwd"|"all" } Overrides `threads.scope`
function M.past(agent, cb, opts)
    local scope = opts and opts.scope or config.options.threads.scope
    agent:start(function(err)
        if err then
            return cb({}, err)
        end
        local cwd = scope == "cwd" and vim.fn.getcwd() or nil
        local function finish(list, lerr)
            local out = {}
            for _, info in ipairs(list) do
                if not M.find(agent.name, info.session_id) and not history.is_hidden(agent.name, info.session_id) then
                    table.insert(out, info)
                end
            end
            table.sort(out, function(a, b)
                return (a.updated_at or "") > (b.updated_at or "")
            end)
            cb(out, lerr)
        end
        if not agent:supports("load") and not agent:supports("resume") then
            return finish({})
        elseif not agent:supports("list") then
            return finish(history.list(agent.name, cwd))
        end
        agent:list_sessions({ cwd = cwd, max = config.options.threads.max_listed }, function(lerr, sessions)
            if lerr then
                log.warn(("%s: session/list failed: %s"):format(agent.name, lerr))
                return finish(history.list(agent.name, cwd), lerr)
            end
            local list = {}
            for _, s in ipairs(sessions) do
                local known = history.get(agent.name, s.sessionId)
                local custom = known and known.custom_title
                table.insert(list, {
                    agent = agent.name,
                    session_id = s.sessionId,
                    cwd = type(s.cwd) == "string" and s.cwd or vim.fn.getcwd(),
                    title = known and custom and known.title or s.title or (known and known.title),
                    custom_title = custom or nil,
                    updated_at = s.updatedAt or (known and known.updated_at),
                })
            end
            finish(list)
        end)
    end)
end

---Open a past thread: switch to it if it's live, else load it into a new chat.
---@param agent conduit.Agent
---@param info conduit.ThreadInfo
---@param cb? fun(err: string?)
---@return conduit.Chat
function M.open(agent, info, cb)
    local live = M.find(agent.name, info.session_id)
    if live then
        M.switch(live)
        live:open()
        if cb then
            cb(nil)
        end
        return live
    end
    history.unhide(agent.name, info.session_id)
    local chat = require("conduit.ui.chat").new(agent)
    M.switch(chat)
    chat:open()
    chat:load(info, cb)
    return chat
end

---Continue where you left off with `agent`: its live thread if there is one, else
---its most recent past thread in this directory, else a new thread.
---@param agent conduit.Agent
function M.continue(agent)
    for i = #M.list, 1, -1 do
        if M.list[i].agent == agent then
            return require("conduit").open(agent.name)
        end
    end
    M.past(agent, function(list, err)
        local latest = list[1]
        if latest then
            M.open(agent, latest)
            return
        end
        if err then
            vim.notify("[conduit] could not list threads: " .. err, vim.log.levels.WARN)
        end
        require("conduit").open(agent.name)
    end)
end

---Fork `chat` into a new thread with the same context (`session/fork`).
---@param chat conduit.Chat
---@param cb? fun(err: string?, fork: conduit.Chat?)
function M.fork(chat, cb)
    cb = cb
        or function(err)
            if err then
                vim.notify("[conduit] " .. err, vim.log.levels.ERROR)
            end
        end
    local agent, sid = chat.agent, chat.session_id
    if not sid then
        return cb("the thread has no session to fork yet")
    elseif not agent:supports("fork") then
        return cb(agent.name .. " doesn't support forking sessions")
    end
    local fork = require("conduit.ui.chat").new(agent)
    fork.cwd = chat.cwd
    agent:fork_session({ session_id = sid, cwd = chat.cwd or vim.fn.getcwd() }, fork, function(err, fork_sid)
        if err then
            fork:destroy()
            return cb(err)
        end
        fork.session_id = fork_sid
        fork.title = ("%s (fork)"):format(chat:display_title())
        fork:copy_transcript(chat)
        fork:_notice("forked from " .. chat:display_title())
        fork:_record()
        M.switch(fork)
        fork:open()
        cb(nil, fork)
    end)
end

---@class conduit.PickItem
---@field chat? conduit.Chat A live thread
---@field info? conduit.ThreadInfo A past thread
---@field new? boolean Start a new thread
---@field agent? conduit.Agent Agent for a new thread

---@class conduit.PickOpts
---@field scope? "cwd"|"all" Overrides `threads.scope`
---@field past_only? boolean Only past threads (`:Conduit resume`)
---@field query? string Initial picker query

---State shown next to a thread: what it's doing or why it wants attention.
---@param chat conduit.Chat
---@return string? text, string? highlight, string? glyph
function M.state(chat)
    if chat.waiting then
        return "needs permission", "ConduitThreadWaiting", "!"
    elseif chat.loading then
        return "loading…", "ConduitThreadBusy", "◐"
    elseif chat.busy then
        return "working…", "ConduitThreadBusy", "◐"
    elseif chat.unread then
        return "unread", "ConduitThreadUnread", "●"
    end
end

---@param chat conduit.Chat
---@return [string, string?][]
local function chat_segments(chat)
    local segments = {
        { chat == M.current and "● " or "  ", "ConduitThreadActive" },
        { chat:display_title() },
        { " · " .. chat.agent.name, "ConduitThreadMeta" },
    }
    local state, hl = M.state(chat)
    if state then
        table.insert(segments, { " · " .. state, hl })
    end
    return segments
end

---@param info conduit.ThreadInfo
---@param scope "cwd"|"all"
---@return [string, string?][]
local function info_segments(info, scope)
    local meta = { info.agent }
    local ago = M.ago(info.updated_at)
    if ago then
        table.insert(meta, ago)
    end
    if scope == "all" and info.cwd ~= vim.fn.getcwd() then
        table.insert(meta, vim.fn.fnamemodify(info.cwd, ":~"))
    end
    return {
        { "  " },
        { info.title or info.session_id },
        { " · " .. table.concat(meta, " · "), "ConduitThreadMeta" },
    }
end

---Plain label for a live thread, as shown in the picker.
---@param chat conduit.Chat
---@return string
function M.label(chat)
    return picker.label({ text = "", segments = chat_segments(chat) })
end

---Live threads, most recently used first.
---@return conduit.Chat[]
function M.mru()
    local list = vim.list_slice(M.list)
    table.sort(list, function(a, b)
        return (a.last_used or 0) > (b.last_used or 0)
    end)
    return list
end

---Show `chat`: make it current and open it.
---@param chat conduit.Chat
local function focus(chat)
    M.switch(chat)
    chat:open()
end

---Switch to the thread used before the current one.
---@return conduit.Chat?
function M.alternate()
    for _, chat in ipairs(M.mru()) do
        if chat ~= M.current then
            focus(chat)
            return chat
        end
    end
    vim.notify("[conduit] no other thread to switch to", vim.log.levels.INFO)
end

---Ask before deleting a thread for good.
---@param title string
---@param fn fun()
function M.confirm_delete(title, fn)
    vim.ui.select({ "Delete", "Cancel" }, { prompt = ("Delete thread %q permanently?"):format(title) }, function(choice)
        if choice == "Delete" then
            fn()
        end
    end)
end

---Agents to list past threads from: `agent`, plus any other agent that's
---already running (starting an agent just to list its threads is too slow).
---@param agent conduit.Agent
---@return conduit.Agent[]
local function sources(agent)
    local out = { agent }
    local agents = require("conduit").agents
    local names = vim.tbl_keys(agents)
    table.sort(names)
    for _, name in ipairs(names) do
        local other = agents[name]
        if other ~= agent and other.state == "ready" then
            table.insert(out, other)
        end
    end
    return out
end

---@param item conduit.PickerItem
---@return string[] lines, string? filetype
local function preview_thread(item)
    local data = item.data ---@type conduit.PickItem
    local chat, info = data.chat, data.info
    if chat then
        if not vim.api.nvim_buf_is_valid(chat.transcript) then
            return {}, nil
        end
        local lines = vim.api.nvim_buf_get_lines(chat.transcript, 0, -1, false)
        if #lines == 1 and lines[1] == "" then
            lines = { "_No messages yet._" }
        end
        return lines, "markdown"
    elseif info then
        local lines = {
            "# " .. (info.title or info.session_id),
            "",
            "- agent: " .. info.agent,
            "- session: " .. info.session_id,
            "- directory: " .. vim.fn.fnamemodify(info.cwd, ":~"),
        }
        if info.updated_at then
            table.insert(lines, ("- updated: %s (%s)"):format(info.updated_at, M.ago(info.updated_at) or "?"))
        end
        vim.list_extend(lines, { "", "_Open the thread to load its transcript._" })
        return lines, "markdown"
    end
    return { ("Start a new thread with %s."):format(data.agent and data.agent.name or "the default agent") }, nil
end

---Pick a thread: live threads (most recently used first, the current one last),
---past threads from `agent` and any other running agent, then "New thread".
---Pickers that can stream show live threads at once and add past ones as they
---arrive. Keys: <C-d> delete, <C-r> rename, <C-f> fork, <C-n> new thread,
---<C-g> switch between this directory's past threads and all of them.
---@param agent? conduit.Agent Whose past threads to offer; defaults to the current thread's
---@param opts? conduit.PickOpts
function M.pick(agent, opts)
    opts = opts or {}
    agent = agent or (M.current and M.current.agent) or require("conduit").agent()
    local scope = opts.scope or config.options.threads.scope

    ---@type conduit.PickerItem[]
    local live, past = {}, {}
    if not opts.past_only then
        local order = M.mru()
        for i, chat in ipairs(order) do
            if chat == M.current then
                table.remove(order, i)
                table.insert(order, chat)
                break
            end
        end
        for _, chat in ipairs(order) do
            local segments = chat_segments(chat)
            local label = picker.label({ text = "", segments = segments })
            table.insert(live, {
                text = vim.trim(label) .. " " .. (chat.session_id or ""),
                segments = segments,
                data = { chat = chat },
            })
        end
    end
    ---@type conduit.PickerItem
    local new_item = {
        text = "New thread",
        segments = { { "+ New thread", "ConduitThreadNew" } },
        data = { new = true, agent = agent },
    }

    local function items()
        local out = vim.list_extend(vim.list_slice(live), past)
        if not opts.past_only then
            table.insert(out, new_item)
        end
        return out
    end

    ---@param done fun()
    local function load(done)
        local agents = sources(assert(agent))
        local pending = #agents
        ---@type conduit.ThreadInfo[]
        local infos = {}
        for _, a in ipairs(agents) do
            M.past(a, function(list, err)
                if err then
                    vim.notify(("[conduit] could not list %s threads: %s"):format(a.name, err), vim.log.levels.WARN)
                end
                vim.list_extend(infos, list)
                pending = pending - 1
                if pending > 0 then
                    return
                end
                table.sort(infos, function(x, y)
                    return (x.updated_at or "") > (y.updated_at or "")
                end)
                for _, info in ipairs(infos) do
                    local segments = info_segments(info, scope)
                    table.insert(past, {
                        text = ("%s %s %s %s"):format(info.title or "", info.agent, info.cwd, info.session_id),
                        segments = segments,
                        data = { info = info },
                    })
                end
                done()
            end, { scope = scope })
        end
    end

    local function reopen(o)
        M.pick(agent, vim.tbl_extend("force", opts, o or {}))
    end

    ---@type conduit.PickerAction[]
    local actions = {
        {
            key = "<C-d>",
            desc = "Delete thread",
            fn = function(item)
                local data = item and item.data ---@type conduit.PickItem?
                local chat, info = data and data.chat, data and data.info
                if chat then
                    M.confirm_delete(chat:display_title(), function()
                        local sid = chat.session_id or chat.resume_id
                        if not sid then
                            M.close(chat)
                            return reopen()
                        end
                        M.delete(chat.agent, sid, function(err)
                            if err then
                                vim.notify("[conduit] " .. err, vim.log.levels.ERROR)
                            end
                            reopen()
                        end)
                    end)
                elseif info then
                    local owner = require("conduit").agents[info.agent] ---@type conduit.Agent?
                    if not owner then
                        return
                    end
                    M.confirm_delete(info.title or info.session_id, function()
                        M.delete(owner, info.session_id, function(err)
                            if err then
                                vim.notify("[conduit] " .. err, vim.log.levels.ERROR)
                            end
                            reopen()
                        end)
                    end)
                end
            end,
        },
        {
            key = "<C-r>",
            desc = "Rename thread",
            fn = function(item)
                local data = item and item.data ---@type conduit.PickItem?
                local chat, info = data and data.chat, data and data.info
                if not chat and not info then
                    return
                end
                local current = chat and chat.title or info and info.title
                vim.ui.input({ prompt = "Thread title: ", default = current }, function(text)
                    text = text and vim.trim(text) or ""
                    if text == "" then
                        return reopen()
                    end
                    if chat then
                        chat:rename(text, function(err)
                            if err then
                                vim.notify("[conduit] could not rename the thread: " .. err, vim.log.levels.WARN)
                            end
                        end)
                    elseif info then
                        -- Not loaded, so there's no session to retitle; the local title wins in lists.
                        history.record({
                            agent = info.agent,
                            session_id = info.session_id,
                            cwd = info.cwd,
                            title = text,
                            custom_title = true,
                            updated_at = info.updated_at,
                        })
                    end
                    reopen()
                end)
            end,
        },
        {
            key = "<C-f>",
            desc = "Fork thread",
            fn = function(item)
                local data = item and item.data ---@type conduit.PickItem?
                if data and data.chat then
                    M.fork(data.chat)
                elseif data and data.info then
                    vim.notify("[conduit] open the thread before forking it", vim.log.levels.INFO)
                end
            end,
        },
        {
            key = "<C-n>",
            desc = "New thread",
            fn = function()
                require("conduit").new(agent and agent.name)
            end,
        },
        {
            key = "<C-g>",
            desc = "Toggle this directory / all directories",
            fn = function()
                reopen({ scope = scope == "all" and "cwd" or "all" })
            end,
        },
    }

    local title = opts.past_only and "Conduit: resume a thread" or "Conduit threads"
    if scope == "all" then
        title = title .. " (all directories)"
    end
    picker.pick({
        title = title,
        items = items,
        load = agent and load or nil,
        query = opts.query,
        preview = preview_thread,
        actions = actions,
        on_select = function(item)
            local data = item.data ---@type conduit.PickItem
            if data.chat then
                focus(data.chat)
            elseif data.info then
                local owner = require("conduit").agents[data.info.agent] ---@type conduit.Agent?
                if owner then
                    M.open(owner, data.info)
                end
            elseif data.new then
                require("conduit").new(data.agent and data.agent.name)
            end
        end,
    })
end

---Go to a live thread by number (as in the thread bar), session id or title
---(exact, or a unique part of it). Anything else opens the picker with `target`
---as the query.
---@param target? string
---@return conduit.Chat?
function M.jump(target)
    target = vim.trim(target or "")
    if target == "" then
        return M.pick()
    end
    if target:match("^%d+$") then
        local chat = M.list[assert(tonumber(target))] ---@type conduit.Chat?
        if chat then
            focus(chat)
            return chat
        end
        return vim.notify(("[conduit] there's no thread %s"):format(target), vim.log.levels.WARN)
    end
    local lower = target:lower()
    local partial = {}
    for _, chat in ipairs(M.list) do
        local title = chat:display_title():lower()
        if chat.session_id == target or chat.resume_id == target or title == lower then
            focus(chat)
            return chat
        elseif title:find(lower, 1, true) then
            table.insert(partial, chat)
        end
    end
    if #partial == 1 then
        focus(partial[1])
        return partial[1]
    end
    M.pick(nil, { query = target })
end

---Reopen a thread by session id: a live one, one from `agent`'s history, or any
---session the agent can load. Without an id, pick one of `agent`'s past threads.
---@param id? string
---@param agent? conduit.Agent Defaults to the current thread's, else the default agent
function M.resume(id, agent)
    agent = agent or (M.current and M.current.agent) or require("conduit").agent()
    if not agent then
        return
    end
    id = id and vim.trim(id) or ""
    if id == "" then
        return M.pick(agent, { past_only = true })
    end
    for _, chat in ipairs(M.list) do
        if chat.session_id == id or chat.resume_id == id then
            return focus(chat)
        end
    end
    M.past(agent, function(list)
        for _, info in ipairs(list) do
            if info.session_id == id then
                M.open(agent, info)
                return
            end
        end
        if agent:supports("load") or agent:supports("resume") then
            local known = history.get(agent.name, id)
            M.open(agent, known or { agent = agent.name, session_id = id, cwd = vim.fn.getcwd() })
            return
        end
        vim.notify(("[conduit] %s can't reopen session %s"):format(agent.name, id), vim.log.levels.ERROR)
    end, { scope = "all" })
end

---@class conduit.SearchMatch
---@field chat conduit.Chat
---@field lnum integer 1-based
---@field col integer 1-based byte column
---@field line string

---Search every live thread's transcript for `pattern` (plain text, smartcase).
---Matches open in the picker (jumping to the line), or go to the quickfix list
---with `opts.qf`. Prompts for the pattern when it's omitted.
---@param pattern? string
---@param opts? { qf?: boolean }
---@return conduit.SearchMatch[]?
function M.search(pattern, opts)
    opts = opts or {}
    if not pattern or pattern == "" then
        vim.ui.input({ prompt = "Search threads: " }, function(text)
            if text and text ~= "" then
                M.search(text, opts)
            end
        end)
        return nil
    end
    local ignorecase = pattern == pattern:lower()
    ---@type conduit.SearchMatch[]
    local matches = {}
    for _, chat in ipairs(M.list) do
        if vim.api.nvim_buf_is_valid(chat.transcript) then
            for lnum, line in ipairs(vim.api.nvim_buf_get_lines(chat.transcript, 0, -1, false)) do
                local col = (ignorecase and line:lower() or line):find(pattern, 1, true)
                if col then
                    table.insert(matches, { chat = chat, lnum = lnum, col = col, line = line })
                end
            end
        end
    end
    if #matches == 0 then
        vim.notify(("[conduit] no thread mentions %q"):format(pattern), vim.log.levels.INFO)
        return matches
    end
    if opts.qf then
        vim.fn.setqflist({}, " ", {
            title = "Conduit: " .. pattern,
            items = vim.tbl_map(function(m)
                return {
                    bufnr = m.chat.transcript,
                    lnum = m.lnum,
                    col = m.col,
                    text = ("%s │ %s"):format(m.chat:display_title(), m.line),
                }
            end, matches),
        })
        vim.cmd("botright copen")
        return matches
    end
    ---@type conduit.PickerItem[]
    local items = {}
    for _, m in ipairs(matches) do
        local stop = m.col + #pattern
        table.insert(items, {
            text = m.chat:display_title() .. " " .. m.line,
            segments = {
                { ("%s:%d "):format(m.chat:display_title(), m.lnum), "ConduitThreadMeta" },
                { m.line:sub(1, m.col - 1) },
                { m.line:sub(m.col, stop - 1), "ConduitSearchMatch" },
                { m.line:sub(stop) },
            },
            data = m,
        })
    end
    picker.pick({
        title = "Conduit search: " .. pattern,
        items = function()
            return items
        end,
        preview = function(item)
            local m = item.data ---@type conduit.SearchMatch
            if not vim.api.nvim_buf_is_valid(m.chat.transcript) then
                return {}, nil
            end
            local first = math.max(0, m.lnum - 6)
            return vim.api.nvim_buf_get_lines(m.chat.transcript, first, m.lnum + 30, false), "markdown"
        end,
        on_select = function(item)
            local m = item.data ---@type conduit.SearchMatch
            if not M.index(m.chat) then
                return
            end
            focus(m.chat)
            local twin = m.chat:wins()
            if twin then
                vim.api.nvim_set_current_win(twin)
                vim.api.nvim_win_set_cursor(twin, { m.lnum, m.col - 1 })
            end
        end,
    })
    return matches
end

---@param s string
---@return string
local function escape(s)
    return (s:gsub("%%", "%%%%"))
end

---@param s string
---@param max integer
---@return string
local function truncate(s, max)
    s = s:gsub("\n.*", "")
    return vim.fn.strcharlen(s) > max and (vim.fn.strcharpart(s, 0, max - 1) .. "…") or s
end

---@param chat conduit.Chat
---@param active boolean
---@param i integer
---@param max integer Longest title, in characters
---@param agents boolean Name the agent too
---@return { text: string, width: integer }
local function tab(chat, active, i, max, agents)
    local title = truncate(chat:display_title(), max)
    local label = agents and ("%d %s · %s"):format(i, chat.agent.name, title) or ("%d %s"):format(i, title)
    local _, glyph_hl, glyph = M.state(chat)
    local hl = active and "ConduitThreadActive" or "ConduitThreadInactive"
    local text = ("%%#%s# %s"):format(hl, escape(label))
    if glyph then
        text = ("%s %%#%s#%s"):format(text, glyph_hl, glyph)
    end
    return {
        text = text .. ("%%#%s# "):format(hl),
        width = vim.fn.strdisplaywidth(label) + 2 + (glyph and 2 or 0),
    }
end

---The thread bar: every live thread as a tab, numbered for `:Conduit thread goto`,
---with `chat`'s highlighted and fitted to `width` columns around it (‹ › mark
---tabs that didn't fit). Agent names show when threads use more than one agent.
---@param chat conduit.Chat
---@param width integer
---@return string winbar Statusline-format string
function M.bar(chat, width)
    local n = #M.list
    local agents = false
    for _, c in ipairs(M.list) do
        agents = agents or c.agent ~= chat.agent
    end
    ---@type { text: string, width: integer }[], integer
    local tabs, total = {}, 0
    -- Shorten titles when everything doesn't fit at the comfortable length.
    for _, max in ipairs({ { 30, 20 }, { 24, 10 } }) do
        tabs, total = {}, n - 1
        for i, c in ipairs(M.list) do
            local active = c == chat
            tabs[i] = tab(c, active, i, active and max[1] or max[2], agents and active)
            total = total + tabs[i].width
        end
        if total <= width then
            break
        end
    end
    local i = M.index(chat) or 1
    local budget = total > width and width - 4 or width
    local lo, hi = i, i
    local used = tabs[i] and tabs[i].width or 0 ---@type integer
    local grew = true
    while grew do
        grew = false
        local right, left = tabs[hi + 1], tabs[lo - 1]
        if right and used + 1 + right.width <= budget then
            hi, used, grew = hi + 1, used + 1 + right.width, true
        end
        if left and used + 1 + left.width <= budget then
            lo, used, grew = lo - 1, used + 1 + left.width, true
        end
    end
    local parts = {}
    for j = lo, hi do
        table.insert(parts, assert(tabs[j]).text)
    end
    local sep = "%#ConduitThreadSeparator#"
    return (lo > 1 and sep .. "‹" or "")
        .. table.concat(parts, sep .. "│")
        .. (hi < n and sep .. "›" or "")
        .. "%*"
end

---@class conduit.Status
---@field current? { title: string, agent: string, session_id?: string, busy: boolean }
---@field count integer Live threads
---@field busy integer Threads with a turn in progress
---@field unread integer Threads that finished a turn you haven't seen
---@field waiting integer Threads waiting for a permission answer

---Thread counts for statuslines.
---@return conduit.Status
function M.status()
    local status = { count = #M.list, busy = 0, unread = 0, waiting = 0 }
    for _, chat in ipairs(M.list) do
        status.busy = status.busy + (chat.busy and 1 or 0)
        status.unread = status.unread + (chat.unread and 1 or 0)
        status.waiting = status.waiting + (chat.waiting and 1 or 0)
    end
    local cur = M.current ---@type conduit.Chat?
    if cur then
        status.current = {
            title = cur:display_title(),
            agent = cur.agent.name,
            session_id = cur.session_id,
            busy = cur.busy,
        }
    end
    return status
end

return M
