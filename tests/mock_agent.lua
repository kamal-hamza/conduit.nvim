-- A minimal ACP agent used by the test suite. Run with `nvim -l tests/mock_agent.lua`.
--
-- Prompts of the form `edit <path>` read the file's first line, ask for
-- permission (the request carries the tool call id and the proposed diff), then
-- upper-case the file. `run` and `run-argv` (also as inline requests starting
-- "run") ask permission for a multi-line command. `run tools` sends tool calls
-- with output, locations and diffs. Inline requests get the selection back
-- upper-cased in <replace>, or an answer for questions ("explain…" or ask
-- mode). Prompts starting "follow:" get a follow-up answer. `title <text>`
-- names the session with a `session_info_update`. `/review <args>` runs the
-- review command (see COMMANDS, advertised after every session/new, load,
-- resume and fork). Anything else is echoed back.
--
-- Edits on disk, like Claude and Codex make them (no fs/write_text_file):
-- `disk-edit <path>` replaces every line "old" with "new", `disk-create <path>`
-- writes a new file, `disk-delete <path>` removes one. Each sends a running tool
-- call, waits for a round trip, changes the file, then completes the call with its
-- diff. `disk-edit-fast <path>` changes the file before sending the tool call.
--
-- Pass `--legacy` to advertise `modes`/`models` instead of `configOptions`.
--
-- Threads: `--threads=load,list,resume,close,delete,fork,title` advertises those
-- session capabilities. Every session's history is recorded so session/load can
-- replay it. `--seed` starts with past sessions (see `seed()`); session/list
-- pages two at a time.
--
-- Images: `promptCapabilities.image` is advertised unless `--no-image` is
-- passed. Image blocks are echoed back as `image <name> <mimeType> <bytes>`.
--
-- MCP: `--mcp=http,sse` advertises those transports. Every session method echoes
-- the `mcpServers` it received in `_meta.mcpServers`.
--
-- Terminals: `term <json>` takes `{ create = <terminal/create params>, steps = {...} }`,
-- creates the terminal, shows it in a tool call, then runs each step: "wait",
-- "output", "kill", "release", or "sleep:<ms>". Each result (or error) is said on
-- its own line as `<step> <json>`. `display` reports a command it "ran itself"
-- through the `_meta` display-terminal extension. `caps` says the client's
-- capabilities as JSON.
io.stdout:setvbuf("no")

local argv = _G.arg or {}
local legacy = vim.tbl_contains(argv, "--legacy")
local images = not vim.tbl_contains(argv, "--no-image")
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
            {
                sessionUpdate = "tool_call",
                toolCallId = "sh",
                title = "Run make\nand make test",
                status = "failed",
                content = { { type = "content", content = { type = "text", text = "make: *** no rule" } } },
            },
            text_chunk("user_message_chunk", "u2", "first part"),
            text_chunk("user_message_chunk", "u3", "second part"),
            text_chunk("agent_message_chunk", "a3", "both parts answered"),
        },
    }
    store["past-2"] = {
        cwd = cwd,
        title = "Older work",
        updated_at = "2026-01-02T10:00:00Z",
        history = {
            text_chunk("user_message_chunk", "u1", "older question"),
            {
                sessionUpdate = "user_message_chunk",
                messageId = "u1",
                content = { type = "image", mimeType = "image/png", data = "", uri = "file:///tmp/shot.png" },
            },
        },
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

-- Slash commands, advertised just after a session is created or restored
-- (like real agents, which send them once the response is out).
local COMMANDS = {
    { name = "review", description = "Review the current changes", input = { hint = "optional focus" } },
    { name = "compact", description = "Summarize the conversation to save context" },
}

---Run after the current response is sent.
---@type fun()[]
local after = {}

---@param sid string
local function advertise(sid)
    table.insert(after, function()
        send({
            method = "session/update",
            params = {
                sessionId = sid,
                update = { sessionUpdate = "available_commands_update", availableCommands = COMMANDS },
            },
        })
    end)
end

local client_caps = {}

handlers.initialize = function(params)
    client_caps = params.clientCapabilities or {}
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
            promptCapabilities = { embeddedContext = true, image = images },
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
    advertise(sid)
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
    advertise(params.sessionId)
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
    advertise(params.sessionId)
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
    advertise(sid)
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

---@param path string
---@return string?
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

---@param path string
---@param text string
local function write_file(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

---`disk-*` prompts: change a file directly, reporting it through tool calls only.
---@param sid string
---@param op string
---@param path string
local function disk_change(sid, op, path)
    local before = read_file(path)
    local changed ---@type string?
    if op == "disk-edit" or op == "disk-edit-fast" then
        local lines = vim.split(assert(before), "\n", { plain = true })
        for i, line in ipairs(lines) do
            if line == "old" then
                lines[i] = "new"
            end
        end
        changed = table.concat(lines, "\n")
    elseif op == "disk-create" then
        changed = "created\nby the agent\n"
    end
    local function change()
        if changed then
            write_file(path, changed)
        else
            os.remove(path)
        end
    end
    local id = "disk-" .. turns
    if op == "disk-edit-fast" then
        change()
    end
    update(sid, {
        sessionUpdate = "tool_call",
        toolCallId = id,
        title = (op == "disk-delete" and "Delete " or "Edit ") .. path,
        kind = op == "disk-delete" and "delete" or "edit",
        status = "pending",
        locations = { { path = path } },
    })
    if op ~= "disk-edit-fast" then
        -- The client has handled the tool call once it answers.
        request("fs/read_text_file", { sessionId = sid, path = vim.fn.getcwd() .. "/Makefile", limit = 1 })
        change()
    end
    local content = nil
    if changed then
        content = { { type = "diff", path = path, oldText = before or vim.NIL, newText = changed } }
    end
    update(sid, { sessionUpdate = "tool_call_update", toolCallId = id, status = "completed", content = content })
    say(sid, "done " .. op)
    return { stopReason = "end_turn" }
end

---`run`: a multi-line command whose permission request carries the details
---itself (`run-argv` sends the command as a `bash -lc` argv). Replies with the
---chosen option.
---@param sid string
---@param argv boolean
local function run_command(sid, argv)
    local script = "echo one\necho two\necho three"
    local raw = { command = argv and { "/bin/bash", "-lc", script } or script }
    update(sid, { sessionUpdate = "tool_call", toolCallId = "r1", title = "echo one\necho two", kind = "execute" })
    local perm = request("session/request_permission", {
        sessionId = sid,
        toolCall = { toolCallId = "r1", rawInput = raw, locations = { { path = "/tmp/conduit-run" } } },
        options = {
            { optionId = "allow", name = "Allow", kind = "allow_once" },
            { optionId = "reject", name = "Reject", kind = "reject_once" },
        },
    })
    update(sid, { sessionUpdate = "tool_call_update", toolCallId = "r1", status = "completed" })
    say(sid, "chose " .. tostring(perm.outcome.optionId or perm.outcome.outcome))
    return { stopReason = "end_turn" }
end

---@param sid string
---@param spec { create: table, steps?: string[] }
local function run_terminal(sid, spec)
    local create = spec.create
    create.sessionId = sid
    local created, err = request("terminal/create", create)
    if err then
        say(sid, "\ncreate " .. vim.json.encode(err))
        return { stopReason = "end_turn" }
    end
    local tid = created.terminalId
    say(sid, "\ncreate " .. vim.json.encode(created))
    update(sid, {
        sessionUpdate = "tool_call",
        toolCallId = "term-call",
        title = create.command,
        kind = "execute",
        status = "in_progress",
        content = { { type = "terminal", terminalId = tid } },
    })
    for _, step in ipairs(spec.steps or {}) do
        local ms = step:match("^sleep:(%d+)$")
        if ms then
            vim.uv.sleep(tonumber(ms) --[[@as integer]])
        else
            local result, rerr = request("terminal/" .. (step == "wait" and "wait_for_exit" or step), {
                sessionId = sid,
                terminalId = tid,
            })
            say(sid, ("\n%s %s"):format(step, vim.json.encode(rerr or result)))
        end
    end
    update(sid, { sessionUpdate = "tool_call_update", toolCallId = "term-call", status = "completed" })
    return { stopReason = "end_turn" }
end

---A command the agent ran itself, shown through `_meta` (Claude's extension).
---@param sid string
local function display_terminal(sid)
    local info = { terminal_id = "disp-1" }
    update(sid, {
        sessionUpdate = "tool_call",
        toolCallId = "disp-1",
        title = "make test",
        kind = "execute",
        status = "in_progress",
        -- Only `_meta` names the terminal; later updates carry just their own keys.
        _meta = { terminal_info = info },
    })
    for _, data in ipairs({ "building\n", "\27[31mfailed\27[0m\n" }) do
        update(sid, {
            sessionUpdate = "tool_call_update",
            toolCallId = "disp-1",
            _meta = { terminal_output_delta = { terminal_id = "disp-1", data = data } },
        })
    end
    update(sid, {
        sessionUpdate = "tool_call_update",
        toolCallId = "disp-1",
        status = "failed",
        _meta = { terminal_exit = { terminal_id = "disp-1", exit_code = 2 } },
    })
    say(sid, "ran it")
    return { stopReason = "end_turn" }
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
    if inline_request and inline_request:match("^run") then
        return run_command(sid, false)
    end
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
    local review = text:match("^/review%s*(.*)$")
    if review then
        local context = 0
        for i = 2, #params.prompt do
            if params.prompt[i].type == "text" then
                context = context + 1
            end
        end
        say(sid, ("ran review: %s (%d context)"):format(review, context))
        return { stopReason = "end_turn" }
    end
    if text == "run tools" then
        local cwd = s and s.cwd or vim.fn.getcwd()
        update(sid, {
            sessionUpdate = "tool_call",
            toolCallId = "run",
            title = "Run make",
            kind = "execute",
            status = "in_progress",
        })
        local out = {}
        for i = 1, 20 do
            out[i] = "out " .. i
        end
        -- Already fenced, with a nested fence inside, the way agents send output.
        out[2] = "````md"
        out[3] = "```"
        update(sid, {
            sessionUpdate = "tool_call_update",
            toolCallId = "run",
            status = "completed",
            content = {
                {
                    type = "content",
                    content = { type = "text", text = "`````console\n" .. table.concat(out, "\n") .. "\n`````" },
                },
            },
        })
        update(sid, {
            sessionUpdate = "tool_call",
            toolCallId = "read",
            title = "Read notes.md",
            kind = "read",
            status = "completed",
            locations = { { path = cwd .. "/notes.md", line = 3 } },
            content = { { type = "content", content = { type = "text", text = "secret body\nline two" } } },
        })
        update(sid, {
            sessionUpdate = "tool_call",
            toolCallId = "new",
            title = "Write new.lua",
            kind = "edit",
            status = "completed",
            content = { { type = "diff", path = cwd .. "/new.lua", newText = "print(1)\n" } },
        })
        local old, new = {}, {}
        for i = 1, 30 do
            old[i], new[i] = "a " .. i, "b " .. i
        end
        update(sid, {
            sessionUpdate = "tool_call",
            toolCallId = "big",
            title = "Edit big.txt",
            kind = "edit",
            status = "completed",
            content = {
                {
                    type = "diff",
                    path = cwd .. "/big.txt",
                    oldText = table.concat(old, "\n"),
                    newText = table.concat(new, "\n"),
                },
            },
        })
        say(sid, "tools done")
        return { stopReason = "end_turn" }
    end
    if text:match("^follow:") then
        say(sid, "Follow-up answer to: " .. text)
        return { stopReason = "end_turn" }
    end

    local term = text:match("^term (.+)$")
    if term then
        return run_terminal(sid, vim.json.decode(term))
    end
    if text == "display" then
        return display_terminal(sid)
    end
    if text == "caps" then
        say(sid, "\ncaps " .. vim.json.encode(client_caps))
        return { stopReason = "end_turn" }
    end

    if text == "run" or text == "run-argv" then
        return run_command(sid, text == "run-argv")
    end

    local op, target = text:match("^(disk%-[%w-]+) (.+)$")
    if op then
        return disk_change(sid, op, target)
    end

    local path = text:match("^edit (.+)$")
    if not path then
        say(sid, "Hello ")
        say(sid, "from mock\nyou said: " .. text)
        for i = 2, #params.prompt do
            local b = params.prompt[i]
            local uri = b.uri or b.resource.uri
            local name = uri:match("[^/]+/?$")
            if b.type == "image" then
                say(sid, ("\nimage %s %s %d"):format(name, b.mimeType, #vim.base64.decode(b.data)))
            else
                say(sid, ("\n%s %s %d"):format(b.type, name, b.resource and #b.resource.text or 0))
            end
        end
        return { stopReason = "end_turn" }
    end

    update(sid, {
        sessionUpdate = "plan",
        entries = { { content = "Read file", status = "in_progress", priority = "high" } },
    })
    update(sid, { sessionUpdate = "tool_call", toolCallId = "t1", title = "Edit " .. path, kind = "edit" })
    update(sid, { sessionUpdate = "tool_call_update", toolCallId = "t1", locations = { { path = path, line = 1 } } })
    local read = request("fs/read_text_file", { sessionId = sid, path = path, line = 1, limit = 1 })
    local full = request("fs/read_text_file", { sessionId = sid, path = path })
    -- The proposed edit travels with the permission request, as Claude's adapter does.
    local perm = request("session/request_permission", {
        sessionId = sid,
        toolCall = {
            toolCallId = "t1",
            content = { { type = "diff", path = path, oldText = full.content, newText = full.content:upper() } },
        },
        options = {
            { optionId = "allow", name = "Allow", kind = "allow_once" },
            { optionId = "reject", name = "Reject", kind = "reject_once" },
        },
    })
    if perm.outcome.optionId ~= "allow" then
        update(sid, { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "failed" })
        return { stopReason = "end_turn" }
    end
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
            rawset(result, "_meta", { mcpServers = msg.params.mcpServers or vim.NIL })
        end
        if err then
            send({ id = msg.id, error = err })
        else
            send({ id = msg.id, result = result == nil and vim.empty_dict() or result })
        end
        local queued = after
        after = {}
        for _, fn in ipairs(queued) do
            fn()
        end
    elseif msg.id ~= nil and msg.method then
        send({ id = msg.id, error = { code = -32601, message = "Method not found" } })
    end
end
