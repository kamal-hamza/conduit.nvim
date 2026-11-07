--- Threads: chats (an ACP session plus its buffers). Live threads are the ones in
--- this Neovim; one is current, and switching swaps its buffers into the chat
--- windows. Past threads come from the agent (`session/list`) or, for agents that
--- can load sessions but not list them, from the local index (`conduit.history`).
--- Everything beyond live threads depends on what the agent advertises.
local config = require("conduit.config")
local history = require("conduit.history")
local log = require("conduit.log")

local M = {}

---@type conduit.Chat[] In creation order
M.list = {}

---@type conduit.Chat?
M.current = nil

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

---Register a new thread. Doesn't make it current; see `switch`.
---@param chat conduit.Chat
---@return conduit.Chat
function M.add(chat)
    if not M.index(chat) then
        table.insert(M.list, chat)
    end
    return chat
end

---Make `chat` the current thread. If the previous thread is on screen, its
---windows show `chat` instead; otherwise `chat` opens unless `opts.open` is false.
---@param chat conduit.Chat
---@param opts? { open?: boolean }
function M.switch(chat, opts)
    M.add(chat)
    local prev = M.current
    M.current = chat
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
    local chat = M.list[(i - 1 + delta) % n + 1]
    M.switch(chat)
    return chat
end

---Close a live thread: cancel its turn, wipe its buffers and release the session
---(`session/close` when supported). It stays in the thread history, so agents that
---can load sessions can reopen it. If it was current, the next thread (or the
---previous, for the last one) takes its place on screen.
---@param chat conduit.Chat
function M.close(chat)
    local i = M.index(chat)
    if not i then
        return
    end
    table.remove(M.list, i)
    if M.current == chat then
        M.current = nil
        local neighbour = M.list[i] or M.list[i - 1]
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
    if not y then
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
    local local_offset = os.difftime(now, os.time(os.date("!*t", now) --[[@as osdateparam]]))
    local epoch = os.time(t --[[@as osdateparam]]) + local_offset
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if sign then
        local offset = (tonumber(oh) * 60 + tonumber(om)) * 60
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
function M.past(agent, cb)
    agent:start(function(err)
        if err then
            return cb({}, err)
        end
        local cwd = config.options.threads.scope == "cwd" and vim.fn.getcwd() or nil
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
                    title = custom and known.title or s.title or (known and known.title),
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
            return M.open(agent, latest)
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

---@param chat conduit.Chat
---@return string
function M.label(chat)
    local parts = { chat:display_title(), chat.agent.name }
    if chat.busy then
        table.insert(parts, chat.loading and "loading…" or "working…")
    end
    return ("%s %s"):format(chat == M.current and "●" or " ", table.concat(parts, " · "))
end

---@param item conduit.PickItem
---@return string
local function format_item(item)
    if item.chat then
        return M.label(item.chat)
    elseif item.info then
        local info = item.info
        local parts = { info.title or info.session_id, info.agent }
        local ago = M.ago(info.updated_at)
        if ago then
            table.insert(parts, ago)
        end
        if config.options.threads.scope == "all" and info.cwd ~= vim.fn.getcwd() then
            table.insert(parts, vim.fn.fnamemodify(info.cwd, ":~"))
        end
        return "  " .. table.concat(parts, " · ")
    end
    return "+ New thread"
end

---Pick a thread: live threads first, then `agent`'s past threads, then "New thread".
---@param agent? conduit.Agent Whose past threads to offer; defaults to the current thread's
function M.pick(agent)
    agent = agent or (M.current and M.current.agent) or require("conduit").agent()
    ---@type conduit.PickItem[]
    local items = {}
    for _, chat in ipairs(M.list) do
        table.insert(items, { chat = chat })
    end
    local function choose()
        table.insert(items, { new = true })
        vim.ui.select(items, { prompt = "Conduit threads", format_item = format_item }, function(item)
            if not item then
                return
            elseif item.chat then
                M.switch(item.chat)
                item.chat:open()
            elseif item.info and agent then
                M.open(agent, item.info)
            elseif item.new then
                require("conduit").new(agent and agent.name)
            end
        end)
    end
    if not agent then
        return choose()
    end
    M.past(agent, function(list, err)
        if err then
            vim.notify(("[conduit] could not list %s threads: %s"):format(agent.name, err), vim.log.levels.WARN)
        end
        for _, info in ipairs(list) do
            table.insert(items, { info = info })
        end
        choose()
    end)
end

return M
