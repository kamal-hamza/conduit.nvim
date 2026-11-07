-- A minimal ACP agent used by the test suite. Run with `nvim -l tests/mock_agent.lua`.
--
-- Prompts of the form `edit <path>` read the file's first line, ask for
-- permission, then upper-case the file. Inline requests get the selection back
-- upper-cased in <replace>, or an answer for questions ("explain…" or ask
-- mode). Prompts starting "follow:" get a follow-up answer. `title <text>`
-- names the session with a `session_info_update`. Anything else is echoed back.
--
-- Pass `--legacy` to advertise `modes`/`models` instead of `configOptions`.
--
-- Threads: `--threads=load,list,resume,close,delete,fork,title` advertises those
-- session capabilities. Every session's history is recorded so session/load can
-- replay it. `--seed` starts with past sessions (see `seed()`); session/list
-- pages two at a time.
--
-- MCP: `--mcp=http,sse` advertises those transports. Every session method echoes
-- the `mcpServers` it received in `_meta.mcpServers`.
io.stdout:setvbuf("no")

local argv = _G.arg or {}
local legacy = vim.tbl_contains(argv, "--legacy")
local caps = {}
local mcp_caps = vim.empty_dict()
for _, a in ipairs(argv) do
    local list = a:match("^%-%-threads=(.+)$")
    for cap in (list or ""):gmatch("[^,]+") do
        caps[cap] = true
    end
    for transport in (a:match("^%-%-mcp=(.+)$") or ""):gmatch("[^,]+") do
        mcp_caps[transport] = true
    end
end

---@class MockSession
---@field cwd string
---@field title? string
---@field updated_at string
---@field history table[] Recorded session updates, replayed by session/load
---@field closed? boolean

---@type table<string, MockSession>
local store = {}
local RECORDED = {
    user_message_chunk = true,
    agent_message_chunk = true,
    agent_thought_chunk = true,
    tool_call = true,
    tool_call_update = true,
    plan = true,
}
-- Current agent message id per session, attached to agent chunks.
local message_ids = {}
local turns = 0

local function now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end
local config = {
    model = { "fast", { "fast", "smart" } },
    effort = { "high", { "low", "high" } },
}

local function send(msg)
    msg.jsonrpc = "2.0"
    io.stdout:write(vim.json.encode(msg) .. "\n")
end

local next_id = 0
local function request(method, params)
    next_id = next_id + 1
    local id = next_id
    send({ id = id, method = method, params = params })
    for line in io.lines() do
        local msg = vim.json.decode(line)
        if msg.id == id and not msg.method then
            return msg.result, msg.error
        end
    end
    os.exit(0)
end

local function update(sid, u)
    local s = store[sid] --[[@as MockSession?]]
    if s and RECORDED[u.sessionUpdate] then
        table.insert(s.history, u)
    end
    send({ method = "session/update", params = { sessionId = sid, update = u } })
end

local function say(sid, text)
    update(sid, {
        sessionUpdate = "agent_message_chunk",
        messageId = message_ids[sid],
        content = { type = "text", text = text },
    })
end

local function text_chunk(kind, id, text)
    return { sessionUpdate = kind, messageId = id, content = { type = "text", text = text } }
end

local function seed()
    local cwd = vim.fn.getcwd()
    store["past-1"] = {
        cwd = cwd,
        title = "Old work",
        updated_at = "2026-01-03T10:00:00Z",
        history = {
            text_chunk("user_message_chunk", "u1", "hello past"),
            text_chunk("agent_message_chunk", "a1", "hi from the past"),
            { sessionUpdate = "tool_call", toolCallId = "old", title = "Read notes", status = "completed" },
            { sessionUpdate = "tool_call", toolCallId = "sh", title = "Run make\nand make test", status = "failed" },
            text_chunk("user_message_chunk", "u2", "first part"),
            text_chunk("user_message_chunk", "u3", "second part"),
            text_chunk("agent_message_chunk", "a3", "both parts answered"),
        },
    }
    store["past-2"] = {
        cwd = cwd,
        title = "Older work",
        updated_at = "2026-01-02T10:00:00Z",
        history = { text_chunk("user_message_chunk", "u1", "older question") },
    }
    store["past-3"] = { cwd = cwd, updated_at = "2026-01-01T10:00:00Z", history = {} }
    store["elsewhere"] = {
        cwd = "/somewhere/else",
        title = "Other project",
        updated_at = "2026-01-04T10:00:00Z",
        history = {},
    }
end
if vim.tbl_contains(argv, "--seed") then
    seed()
end

local handlers = {}

handlers.initialize = function()
    local session_caps = vim.empty_dict()
    for _, cap in ipairs({ "list", "resume", "close", "delete", "fork", "title" }) do
        if caps[cap] then
            session_caps[cap] = vim.empty_dict()
        end
    end
    return {
        protocolVersion = 1,
        agentCapabilities = {
            loadSession = caps.load == true,
            sessionCapabilities = session_caps,
            promptCapabilities = { embeddedContext = true },
            mcpCapabilities = mcp_caps,
        },
        authMethods = {},
    }
end

local function config_options()
    local out = {}
    for _, id in ipairs({ "model", "effort" }) do
        local current, values = unpack(config[id])
        local options = vim.tbl_map(function(v)
            return { value = v, name = v:upper() }
        end, values)
        table.insert(out, {
            id = id,
            name = id,
            category = id == "effort" and "thought_level" or id,
            type = "select",
            currentValue = current,
            options = options,
        })
    end
    return out
end

local sessions = 0
handlers["session/new"] = function(params)
    sessions = sessions + 1
    local sid = sessions == 1 and "mock-session" or ("mock-session-" .. sessions)
    store[sid] = { cwd = params.cwd, updated_at = now(), history = {} }
    if legacy then
        return {
            sessionId = sid,
            modes = {
                currentModeId = "ask",
                availableModes = { { id = "ask", name = "Ask" }, { id = "code", name = "Code" } },
            },
            models = {
                currentModelId = "m1",
                availableModels = { { modelId = "m1", name = "M1" }, { modelId = "m2", name = "M2" } },
            },
        }
    end
    return { sessionId = sid, configOptions = config_options() }
end

handlers["session/set_config_option"] = function(params)
    config[params.configId][1] = params.value
    return { configOptions = config_options() }
end

handlers["session/set_mode"] = function()
    return vim.empty_dict()
end

handlers["session/set_model"] = function()
    return vim.empty_dict()
end

local NOT_FOUND = { code = -32002, message = "Resource not found" }

local function need(cap)
    if not caps[cap] then
        return { code = -32601, message = "Method not found" }
    end
end

handlers["session/list"] = function(params)
    local err = need("list")
    if err then
        return nil, err
    end
    local all = {}
    for sid, s in pairs(store) do
        if not params.cwd or params.cwd == s.cwd then
            table.insert(all, { sessionId = sid, cwd = s.cwd, title = s.title, updatedAt = s.updated_at })
        end
    end
    table.sort(all, function(a, b)
        return a.updatedAt > b.updatedAt
    end)
    local first = tonumber(params.cursor or "1") --[[@as integer?]]
    if not first then
        return nil, { code = -32602, message = "Invalid cursor" }
    end
    local page = vim.list_slice(all, first, first + 1)
    return { sessions = page, nextCursor = first + 2 <= #all and tostring(first + 2) or nil }
end

handlers["session/load"] = function(params)
    local err = need("load")
    if err then
        return nil, err
    end
    local s = store[params.sessionId]
    if not s then
        return nil, NOT_FOUND
    end
    -- Replay without recording, then respond.
    for _, u in ipairs(s.history) do
        send({ method = "session/update", params = { sessionId = params.sessionId, update = u } })
    end
    s.closed = nil
    return { configOptions = config_options() }
end

handlers["session/resume"] = function(params)
    local err = need("resume")
    if err then
        return nil, err
    end
    -- Sessions from an earlier process aren't in the store; resume them empty.
    store[params.sessionId] = store[params.sessionId] or { cwd = params.cwd, updated_at = now(), history = {} }
    store[params.sessionId].closed = nil
    return { configOptions = config_options() }
end

handlers["session/close"] = function(params)
    local err = need("close")
    if err then
        return nil, err
    end
    local s = store[params.sessionId]
    if not s or s.closed then
        return nil, NOT_FOUND
    end
    s.closed = true
    return vim.empty_dict()
end

handlers["session/delete"] = function(params)
    local err = need("delete")
    if err then
        return nil, err
    end
    store[params.sessionId] = nil
    return vim.empty_dict()
end

local forks = 0
handlers["session/fork"] = function(params)
    local err = need("fork")
    if err then
        return nil, err
    end
    local s = store[params.sessionId]
    if not s then
        return nil, NOT_FOUND
    end
    forks = forks + 1
    local sid = "fork-" .. forks
    store[sid] = { cwd = params.cwd, updated_at = now(), history = vim.deepcopy(s.history) }
    return { sessionId = sid, configOptions = config_options() }
end

handlers["session/set_title"] = function(params)
    local err = need("title")
    if err then
        return nil, err
    end
    local s = store[params.sessionId]
    if not s then
        return nil, NOT_FOUND
    end
    -- Normalize, to check the client shows the stored title.
    s.title = vim.trim(params.title)
    return { title = s.title }
end

handlers["session/prompt"] = function(params)
    local sid = params.sessionId
    local text = params.prompt[1].text
    turns = turns + 1
    message_ids[sid] = "a" .. turns
    local s = store[sid]
    if s then
        s.updated_at = now()
        table.insert(s.history, text_chunk("user_message_chunk", "u" .. turns, text))
    end
    update(sid, { sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "pondering" } })

    local code = text:match("````[^\n]*\n(.-)\n````")
    local inline_request = text:match("Request: (.-)\n\nLines")
    if inline_request and code then
        if text:find("You are answering", 1, true) or inline_request:match("^explain") then
            say(sid, "This code **adds** things.\n\n```lua\n")
            say(sid, "return 42\n```\n")
        else
            -- Split the tag across chunks to exercise routing.
            say(sid, "<rep")
            say(sid, "lace>\n```lua\n" .. code:upper() .. "\n```\n</replace>")
        end
        return { stopReason = "end_turn" }
    end
    local title = text:match("^title (.+)$")
    if title then
        if s then
            s.title = title
        end
        update(sid, { sessionUpdate = "session_info_update", title = title })
        say(sid, "renamed")
        return { stopReason = "end_turn" }
    end
    if text:match("^follow:") then
        say(sid, "Follow-up answer to: " .. text)
        return { stopReason = "end_turn" }
    end

    local path = text:match("^edit (.+)$")
    if not path then
        say(sid, "Hello ")
        say(sid, "from mock\nyou said: " .. text)
        for i = 2, #params.prompt do
            local b = params.prompt[i]
            local uri = b.uri or b.resource.uri
            say(sid, ("\n%s %s %d"):format(b.type, uri:match("[^/]+/?$"), b.resource and #b.resource.text or 0))
        end
        return { stopReason = "end_turn" }
    end

    update(sid, {
        sessionUpdate = "plan",
        entries = { { content = "Read file", status = "in_progress", priority = "high" } },
    })
    update(sid, { sessionUpdate = "tool_call", toolCallId = "t1", title = "Edit " .. path, kind = "edit" })
    local read = request("fs/read_text_file", { sessionId = sid, path = path, line = 1, limit = 1 })
    local perm = request("session/request_permission", {
        sessionId = sid,
        toolCall = { toolCallId = "t1" },
        options = {
            { optionId = "allow", name = "Allow", kind = "allow_once" },
            { optionId = "reject", name = "Reject", kind = "reject_once" },
        },
    })
    if perm.outcome.optionId ~= "allow" then
        update(sid, { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "failed" })
        return { stopReason = "end_turn" }
    end
    local full = request("fs/read_text_file", { sessionId = sid, path = path })
    request("fs/write_text_file", { sessionId = sid, path = path, content = full.content:upper() })
    update(sid, { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "completed" })
    update(sid, {
        sessionUpdate = "plan",
        entries = { { content = "Read file", status = "completed", priority = "high" } },
    })
    say(sid, "first line was: " .. read.content)
    return { stopReason = "end_turn" }
end

local OPENS_SESSION = {
    ["session/new"] = true,
    ["session/load"] = true,
    ["session/resume"] = true,
    ["session/fork"] = true,
}

for line in io.lines() do
    local msg = vim.json.decode(line)
    local handler = msg.method and handlers[msg.method]
    if msg.id ~= nil and handler then
        local result, err = handler(msg.params or {})
        if type(result) == "table" and OPENS_SESSION[msg.method] then
            result._meta = { mcpServers = msg.params.mcpServers or vim.NIL }
        end
        if err then
            send({ id = msg.id, error = err })
        else
            send({ id = msg.id, result = result == nil and vim.empty_dict() or result })
        end
    elseif msg.id ~= nil and msg.method then
        send({ id = msg.id, error = { code = -32601, message = "Method not found" } })
    end
end
