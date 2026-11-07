--- Local thread index: session ids, titles, working directories and timestamps.
--- Transcripts stay with the agent; this only remembers which sessions exist, so
--- agents that can load sessions but not list them still get a thread history,
--- and so user-chosen titles and hidden (inline) sessions survive restarts.
local config = require("conduit.config")
local log = require("conduit.log")

local M = {}

---Where the index is stored. Tests point it elsewhere.
M.path = vim.fn.stdpath("data") .. "/conduit/threads.json"

local MAX_THREADS = 500
local MAX_HIDDEN = 500

---@class conduit.ThreadInfo: conduit.SessionRef
---@field agent string
---@field title? string
---@field custom_title? boolean Set by the user; agent-generated titles don't replace it
---@field updated_at? string ISO 8601

---@class conduit.HistoryData
---@field threads conduit.ThreadInfo[]
---@field hidden string[] Keys of sessions to leave out of thread lists

---@type conduit.HistoryData?
local data

---@return string
function M.now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
end

---@param agent string
---@param sid string
---@return string
local function key(agent, sid)
    return agent .. "\t" .. sid
end

---@return boolean
local function persist()
    return config.options.threads.persist
end

---@return conduit.HistoryData
local function load()
    if data then
        return data
    end
    data = { threads = {}, hidden = {} }
    if not persist() or vim.fn.filereadable(M.path) == 0 then
        return data
    end
    local ok, decoded = pcall(function()
        return vim.json.decode(
            table.concat(vim.fn.readfile(M.path), "\n"),
            { luanil = { object = true, array = true } }
        )
    end)
    if not ok or type(decoded) ~= "table" then
        log.warn(("ignoring unreadable thread index %s"):format(M.path))
        return data
    end
    for _, t in ipairs(type(decoded.threads) == "table" and decoded.threads or {}) do
        if type(t) == "table" and type(t.agent) == "string" and type(t.session_id) == "string" then
            table.insert(data.threads, t)
        end
    end
    for _, k in ipairs(type(decoded.hidden) == "table" and decoded.hidden or {}) do
        if type(k) == "string" then
            table.insert(data.hidden, k)
        end
    end
    return data
end

local function save()
    if not persist() or not data then
        return
    end
    local ok, err = pcall(function()
        vim.fn.mkdir(vim.fs.dirname(M.path), "p")
        vim.fn.writefile({ vim.json.encode(data) }, M.path)
    end)
    if not ok then
        log.warn(("could not write thread index %s: %s"):format(M.path, err))
    end
end

---Drop the in-memory copy so the next call re-reads the file (for tests).
function M.reset()
    data = nil
end

---@param agent string
---@param sid string
---@return conduit.ThreadInfo?
function M.get(agent, sid)
    for _, t in ipairs(load().threads) do
        if t.agent == agent and t.session_id == sid then
            return t
        end
    end
end

---Add or update a thread. Fields left nil keep their stored value.
---@param info conduit.ThreadInfo
function M.record(info)
    local d = load()
    local entry = M.get(info.agent, info.session_id)
    if not entry then
        entry = { agent = info.agent, session_id = info.session_id, cwd = info.cwd }
        table.insert(d.threads, entry)
    end
    for k, v in pairs(info) do
        entry[k] = v
    end
    entry.updated_at = info.updated_at or entry.updated_at or M.now()
    if #d.threads > MAX_THREADS then
        table.sort(d.threads, function(a, b)
            return (a.updated_at or "") > (b.updated_at or "")
        end)
        for i = #d.threads, MAX_THREADS + 1, -1 do
            d.threads[i] = nil
        end
    end
    save()
end

---@param agent string
---@param sid string
function M.remove(agent, sid)
    local d = load()
    for i, t in ipairs(d.threads) do
        if t.agent == agent and t.session_id == sid then
            table.remove(d.threads, i)
            break
        end
    end
    save()
end

---Threads for `agent` (optionally only those in `cwd`), most recent first.
---@param agent string
---@param cwd? string
---@return conduit.ThreadInfo[]
function M.list(agent, cwd)
    local out = {}
    for _, t in ipairs(load().threads) do
        if t.agent == agent and (not cwd or t.cwd == cwd) and not M.is_hidden(agent, t.session_id) then
            table.insert(out, vim.deepcopy(t))
        end
    end
    table.sort(out, function(a, b)
        return (a.updated_at or "") > (b.updated_at or "")
    end)
    return out
end

---Leave a session out of thread lists (e.g. an inline request's session).
---@param agent string
---@param sid string
function M.hide(agent, sid)
    local d = load()
    if M.is_hidden(agent, sid) then
        return
    end
    table.insert(d.hidden, key(agent, sid))
    while #d.hidden > MAX_HIDDEN do
        table.remove(d.hidden, 1)
    end
    save()
end

---@param agent string
---@param sid string
function M.unhide(agent, sid)
    local d = load()
    local k = key(agent, sid)
    for i, h in ipairs(d.hidden) do
        if h == k then
            table.remove(d.hidden, i)
            return save()
        end
    end
end

---@param agent string
---@param sid string
---@return boolean
function M.is_hidden(agent, sid)
    return vim.tbl_contains(load().hidden, key(agent, sid))
end

return M
