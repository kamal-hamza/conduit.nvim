--- MCP server passthrough: turns `mcp_servers` from the config into the
--- `mcpServers` list sent with session/new, load, resume and fork. conduit never
--- runs these servers itself; the agent does.
--- Spec: https://agentclientprotocol.com/protocol/session-setup#mcp-servers
local log = require("conduit.log")

local M = {}

---A value that may be computed when a session opens (e.g. a token from the environment).
---@alias conduit.McpValue string|number|fun(): string

---@class conduit.McpServer
---@field type? "stdio"|"http"|"sse" Transport, "stdio" by default
---@field command? string Executable for stdio servers; resolved to an absolute path
---@field args? conduit.McpValue[] Arguments for stdio servers
---@field env? table<string, conduit.McpValue> Environment for stdio servers
---@field url? string Endpoint for http and sse servers
---@field headers? table<string, conduit.McpValue> HTTP headers for http and sse servers
---@field enabled? boolean|fun(): boolean Set to false (or return false) to leave the server out
---@field name? string Server name; only needed in the list form of `mcp_servers`

---Servers keyed by name, or a list of servers with `name` fields. `false` turns a
---global server off in an agent's `mcp_servers`.
---@alias conduit.McpServers table<string, conduit.McpServer|false>|conduit.McpServer[]

local TYPES = { stdio = true, http = true, sse = true }

-- Problems already reported, so each is warned about once per agent and server.
local warned = {}

---@param servers? conduit.McpServers
---@return table<string, conduit.McpServer|false>
local function by_name(servers)
    if type(servers) ~= "table" then
        return {}
    end
    if not vim.islist(servers) then
        return servers --[[@as table<string, conduit.McpServer|false>]]
    end
    local out = {}
    for i, server in ipairs(servers) do
        local name = type(server) == "table" and server.name
        out[type(name) == "string" and name or ("server " .. i)] = server
    end
    return out
end

---The servers configured for an agent: global `mcp_servers` with the agent's own
---`mcp_servers` replacing entries of the same name.
---@param spec { mcp_servers?: conduit.McpServers }
---@return table<string, conduit.McpServer|false>
function M.configured(spec)
    local global = require("conduit.config").options.mcp_servers
    return vim.tbl_extend("force", by_name(global), by_name(spec.mcp_servers))
end

---@param value any
---@return string? value, string? err
local function resolve(value)
    if type(value) == "function" then
        local ok, result = pcall(value)
        if not ok then
            return nil, tostring(result)
        end
        value = result
    end
    if type(value) == "number" then
        return tostring(value)
    elseif type(value) ~= "string" then
        return nil, "expected a string, got " .. type(value)
    end
    return value
end

---Turn a map into ACP's `{ name, value }` list, sorted by name. Errors never
---include values, which are often credentials.
---@param map any
---@param what string "env" or "headers", for error messages
---@return table[]? pairs, string? err
local function name_values(map, what)
    if map == nil then
        return {}
    elseif type(map) ~= "table" then
        return nil, what .. " must be a table"
    end
    local out = {}
    for _, key in ipairs(vim.tbl_keys(map)) do
        if type(key) ~= "string" then
            return nil, what .. " keys must be strings"
        end
        local value, err = resolve(map[key])
        if not value then
            return nil, ("%s.%s: %s"):format(what, key, err)
        end
        table.insert(out, { name = key, value = value })
    end
    table.sort(out, function(a, b)
        return a.name < b.name
    end)
    return out
end

---Build the ACP payload for one server.
---@param name string
---@param server conduit.McpServer
---@param caps? table Agent `mcpCapabilities`; nil skips the transport check
---@return table? entry, string? err Why the server can't be sent
function M.build(name, server, caps)
    local kind = server.type or "stdio"
    if not TYPES[kind] then
        return nil, ("unknown type %q"):format(tostring(kind))
    end

    if kind == "stdio" then
        if type(server.command) ~= "string" or server.command == "" then
            return nil, "missing command"
        end
        local command = vim.fn.exepath(server.command)
        if command == "" then
            return nil, ("command not found: %s"):format(server.command)
        end
        local args = {}
        for i, arg in ipairs(server.args or {}) do
            local value, err = resolve(arg)
            if not value then
                return nil, ("args[%d]: %s"):format(i, err)
            end
            args[i] = value
        end
        local env, err = name_values(server.env, "env")
        if not env then
            return nil, err
        end
        return { name = name, command = command, args = args, env = env }
    end

    if type(server.url) ~= "string" or server.url == "" then
        return nil, "missing url"
    end
    if caps and caps[kind] ~= true then
        return nil, ("the agent doesn't support %s MCP servers"):format(kind)
    end
    local headers, err = name_values(server.headers, "headers")
    if not headers then
        return nil, err
    end
    return { type = kind, name = name, url = server.url, headers = headers }
end

---Whether a configured server is turned on.
---@param server conduit.McpServer|false
---@return boolean
function M.enabled(server)
    if type(server) ~= "table" then
        return false
    end
    local enabled = server.enabled
    if type(enabled) == "function" then
        local ok, result = pcall(enabled)
        return ok and result ~= false
    end
    return enabled ~= false
end

---The agent's MCP transport capabilities (`agentCapabilities.mcpCapabilities`).
---@param agent { info?: table }
---@return table
function M.capabilities(agent)
    local caps = agent.info and agent.info.agentCapabilities
    local mcp = type(caps) == "table" and caps.mcpCapabilities
    return type(mcp) == "table" and mcp or {}
end

---The `mcpServers` list for a session with `agent`. Servers that can't be sent
---are left out with a warning (once per agent and server).
---@param agent { name: string, spec: conduit.AgentSpec, info?: table }
---@return table[]
function M.servers(agent)
    local caps = M.capabilities(agent)
    local out = {}
    for name, server in vim.spairs(M.configured(agent.spec)) do
        if M.enabled(server) then
            ---@cast server conduit.McpServer
            local entry, err = M.build(name, server, caps)
            if entry then
                table.insert(out, entry)
            else
                local key = ("%s/%s/%s"):format(agent.name, name, err)
                if not warned[key] then
                    warned[key] = true
                    log.warn(("MCP server %q skipped for %s: %s"):format(name, agent.name, err))
                end
            end
        end
    end
    return out
end

return M
