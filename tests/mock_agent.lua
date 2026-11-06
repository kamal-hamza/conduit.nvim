-- A minimal ACP agent used by the test suite. Run with `nvim -l tests/mock_agent.lua`.
--
-- Prompts of the form `edit <path>` read the file's first line, ask for
-- permission, then upper-case the file. Inline requests get the selection back
-- upper-cased in <replace>, or an answer for questions ("explain…" or ask
-- mode). Prompts starting "follow:" get a follow-up answer. Anything else is
-- echoed back.
--
-- Pass `--legacy` to advertise `modes`/`models` instead of `configOptions`.
io.stdout:setvbuf("no")

local legacy = vim.tbl_contains(_G.arg or {}, "--legacy")
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
    send({ method = "session/update", params = { sessionId = sid, update = u } })
end

local function say(sid, text)
    update(sid, { sessionUpdate = "agent_message_chunk", content = { type = "text", text = text } })
end

local handlers = {}

handlers.initialize = function()
    return {
        protocolVersion = 1,
        agentCapabilities = { loadSession = false, promptCapabilities = { embeddedContext = true } },
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
handlers["session/new"] = function()
    sessions = sessions + 1
    local sid = sessions == 1 and "mock-session" or ("mock-session-" .. sessions)
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

handlers["session/prompt"] = function(params)
    local sid = params.sessionId
    local text = params.prompt[1].text
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

for line in io.lines() do
    local msg = vim.json.decode(line)
    local handler = msg.method and handlers[msg.method]
    if msg.id ~= nil and handler then
        send({ id = msg.id, result = handler(msg.params) })
    elseif msg.id ~= nil and msg.method then
        send({ id = msg.id, error = { code = -32601, message = "Method not found" } })
    end
end
