--- An ACP agent subprocess. Neovim acts as the ACP *client*.
--- Spec: https://agentclientprotocol.com
local Rpc = require("conduit.rpc")
local log = require("conduit.log")
local options = require("conduit.options")

local PROTOCOL_VERSION = 1
local AUTH_REQUIRED = -32000
local NOT_FOUND = -32002

---Optional session features an agent may advertise in `initialize`.
---`load` is the top-level `loadSession`; the rest live in `sessionCapabilities`
---(`fork` and `title` are still unstable in ACP).
---@alias conduit.SessionCap "load"|"list"|"resume"|"close"|"delete"|"fork"|"title"

---@class conduit.SessionRef
---@field session_id string
---@field cwd string

---@class conduit.SessionHandler
---@field on_update fun(self, update: table)
---@field request_permission fun(self, params: table, respond: fun(err: table?, result: any))
---@field on_agent_exit fun(self, code: integer)

---@class conduit.Agent
---@field name string
---@field spec conduit.AgentSpec
---@field rpc? conduit.Rpc
---@field info? table Result of `initialize`
---@field state "idle"|"starting"|"ready"
---@field sessions table<string, conduit.SessionHandler>
---@field options table<string, conduit.Option[]> Session options by session id
local Agent = {}
Agent.__index = Agent

---@param err table|string
---@return string
local function errmsg(err)
    if type(err) == "table" then
        local msg = err.message or vim.inspect(err)
        local details = type(err.data) == "table" and err.data.details
        return details and ("%s: %s"):format(msg, details) or msg
    end
    return tostring(err)
end

---@param name string
---@param spec conduit.AgentSpec
function Agent.new(name, spec)
    return setmetatable({ name = name, spec = spec, state = "idle", sessions = {}, options = {}, waiting = {} }, Agent)
end

---Spawn the agent and run the `initialize` handshake.
---@param cb fun(err: string?)
function Agent:start(cb)
    if self.state == "ready" then
        return cb(nil)
    end
    table.insert(self.waiting, cb)
    if self.state == "starting" then
        return
    end
    self.state = "starting"

    -- check if the agent cmd is executable
    local cmd = { self.spec.cmd, unpack(self.spec.args or {}) }
    if vim.fn.executable(self.spec.cmd) == 0 then
        return self:_started(("executable not found: %s"):format(self.spec.cmd))
    end

    -- create rpc object
    local rpc, err = Rpc.start(cmd, {
        cwd = vim.fn.getcwd(),
        env = self.spec.env,
        on_request = function(method, params, respond)
            self:_on_request(method, params, respond)
        end,
        on_notification = function(method, params)
            self:_on_notification(method, params)
        end,
        on_stderr = function(data)
            log.debug(("%s stderr: %s"):format(self.name, data))
        end,
        on_exit = function(code)
            self:_on_exit(code)
        end,
    })
    -- if not rpc then return error
    if not rpc then
        return self:_started(err)
    end
    -- store rpc instance
    self.rpc = rpc

    -- initial rpc request handshake
    rpc:request("initialize", {
        protocolVersion = PROTOCOL_VERSION,
        -- no terminal capabilties, only fs
        clientCapabilities = {
            fs = { readTextFile = true, writeTextFile = true },
            terminal = false,
        },
        clientInfo = { name = "conduit.nvim", version = require("conduit").version },
    }, function(e, result)
        if e then
            rpc:stop()
            return self:_started("initialize failed: " .. errmsg(e))
        end
        self.info = result or {}
        self.state = "ready"
        self:_started(nil)
    end)
end

function Agent:_started(err)
    if err then
        self.state = "idle"
    end
    local waiting = self.waiting
    self.waiting = {}
    for _, cb in ipairs(waiting) do
        cb(err)
    end
end

---Send a request, failing cleanly if the agent process isn't running
---(e.g. it exited after a session was created).
---@param method string
---@param params table
---@param cb fun(err: table?, result: any)
function Agent:_request(method, params, cb)
    if not self.rpc then
        return cb({ code = -32603, message = ("%s is not running"):format(self.name) })
    end
    self.rpc:request(method, params, cb)
end

---Whether the agent advertised an optional session feature. Only known once started.
---@param cap conduit.SessionCap
---@return boolean
function Agent:supports(cap)
    local caps = self.info and self.info.agentCapabilities or {}
    if cap == "load" then
        return caps.loadSession == true
    end
    local session_caps = caps.sessionCapabilities
    return type(session_caps) == "table" and session_caps[cap] ~= nil
end

---Open a session with `method` (session/new, load, resume or fork), retrying once
---after authentication, and record its options.
---@param method string
---@param params table
---@param handler conduit.SessionHandler
---@param cb fun(err: string?, session_id: string?, result: table?)
---@param defaults? table<string, string> Options to apply once the session exists
function Agent:_open_session(method, params, handler, cb, defaults)
    -- session/load replays history as session/update notifications *before* it
    -- responds, so the handler has to be registered under the known id first.
    local known = (method == "session/load" or method == "session/resume") and params.sessionId or nil
    local function attempt(retry)
        if known then
            self.sessions[known] = handler
        end
        self:_request(method, params, function(err, result)
            if err and known and self.sessions[known] == handler then
                self.sessions[known] = nil
            end
            if err and err.code == AUTH_REQUIRED and retry then
                return self:authenticate(function(auth_err)
                    if auth_err then
                        return cb(auth_err)
                    end
                    attempt(false)
                end)
            elseif err then
                return cb(errmsg(err))
            end
            result = result or {}
            local sid = known or result.sessionId
            if type(sid) ~= "string" then
                return cb(method .. " returned no session id")
            end
            self.sessions[sid] = handler
            self.options[sid] = options.from_session(result)
            if not defaults then
                return cb(nil, sid, result)
            end
            self:_apply_defaults(sid, defaults, function()
                cb(nil, sid, result)
            end)
        end)
    end
    attempt(true)
end

---Create a session, then apply the agent's configured default options
---(`spec.options`) merged with `overrides`.
---@param cwd string
---@param handler conduit.SessionHandler
---@param cb fun(err: string?, session_id: string?, result: table?)
---@param overrides? table<string, string>
function Agent:new_session(cwd, handler, cb, overrides)
    local defaults = vim.tbl_extend("force", self.spec.options or {}, overrides or {})
    self:_open_session("session/new", { cwd = cwd, mcpServers = {} }, handler, cb, defaults)
end

---Load a past session (`loadSession`). The agent replays its history through
---`handler:on_update` before `cb` runs. Its options are kept as they were.
---@param ref conduit.SessionRef
---@param handler conduit.SessionHandler
---@param cb fun(err: string?, session_id: string?, result: table?)
function Agent:load_session(ref, handler, cb)
    local params = { sessionId = ref.session_id, cwd = ref.cwd, mcpServers = {} }
    self:_open_session("session/load", params, handler, cb)
end

---Resume a past session without replaying its history (`sessionCapabilities.resume`).
---@param ref conduit.SessionRef
---@param handler conduit.SessionHandler
---@param cb fun(err: string?, session_id: string?, result: table?)
function Agent:resume_session(ref, handler, cb)
    local params = { sessionId = ref.session_id, cwd = ref.cwd, mcpServers = {} }
    self:_open_session("session/resume", params, handler, cb)
end

---Fork a session into a new one with the same context (`sessionCapabilities.fork`).
---@param ref conduit.SessionRef The session to fork
---@param handler conduit.SessionHandler Handler for the new session
---@param cb fun(err: string?, session_id: string?, result: table?)
function Agent:fork_session(ref, handler, cb)
    local params = { sessionId = ref.session_id, cwd = ref.cwd, mcpServers = {} }
    self:_open_session("session/fork", params, handler, cb)
end

---List past sessions (`sessionCapabilities.list`), following `nextCursor` pages.
---@param opts { cwd?: string, max?: integer }
---@param cb fun(err: string?, sessions: table[]) ACP SessionInfo objects
function Agent:list_sessions(opts, cb)
    local out, max = {}, opts.max or 200
    local function page(cursor)
        self:_request("session/list", { cwd = opts.cwd, cursor = cursor }, function(err, result)
            if err then
                return cb(errmsg(err), out)
            end
            for _, info in ipairs(result and result.sessions or {}) do
                if #out >= max then
                    break
                end
                if type(info.sessionId) == "string" then
                    table.insert(out, info)
                end
            end
            local next_cursor = result and result.nextCursor
            if type(next_cursor) == "string" and #out < max then
                return page(next_cursor)
            end
            cb(nil, out)
        end)
    end
    page(nil)
end

---Forget a session and, if the agent supports `session/close`, free its resources
---there. Closing an unknown session counts as success.
---@param sid string
---@param cb? fun(err: string?)
function Agent:close_session(sid, cb)
    cb = cb
        or function(err)
            if err then
                log.warn(("could not close session %s: %s"):format(sid, err))
            end
        end
    self.sessions[sid] = nil
    self.options[sid] = nil
    if not self.rpc or not self:supports("close") then
        return cb(nil)
    end
    self:_request("session/close", { sessionId = sid }, function(err)
        cb(err and err.code ~= NOT_FOUND and errmsg(err) or nil)
    end)
end

---Delete a session from the agent's history (`sessionCapabilities.delete`).
---@param sid string
---@param cb fun(err: string?, deleted: boolean) `deleted` is false when unsupported
function Agent:delete_session(sid, cb)
    if not self:supports("delete") then
        return cb(nil, false)
    end
    self:_request("session/delete", { sessionId = sid }, function(err)
        if err and err.code ~= NOT_FOUND then
            return cb(errmsg(err), false)
        end
        cb(nil, true)
    end)
end

---Set a session's title (`sessionCapabilities.title`). `cb` gets the title the
---agent stored, which may be normalized.
---@param sid string
---@param title string
---@param cb fun(err: string?, title: string?)
function Agent:set_title(sid, title, cb)
    if not self:supports("title") then
        return cb(nil, title)
    end
    self:_request("session/set_title", { sessionId = sid, title = title }, function(err, result)
        if err then
            return cb(errmsg(err))
        end
        cb(nil, type(result) == "table" and type(result.title) == "string" and result.title or title)
    end)
end

---@param sid string
---@param defaults table<string, string>
---@param cb fun()
function Agent:_apply_defaults(sid, defaults, cb)
    local keys = vim.tbl_keys(defaults)
    table.sort(keys)
    local function step(i)
        local key = keys[i]
        if not key then
            return cb()
        end
        local option = options.find(self.options[sid] or {}, key)
        if not option then
            log.warn(("%s has no %q option, ignoring default"):format(self.name, key))
            return step(i + 1)
        end
        if option.current == defaults[key] then
            return step(i + 1)
        end
        self:set_option(sid, option.id, defaults[key], function(err)
            if err then
                log.warn(("could not set %s=%s: %s"):format(key, defaults[key], err))
            end
            step(i + 1)
        end)
    end
    step(1)
end

---@param sid string
---@return conduit.Option[]
function Agent:get_options(sid)
    return self.options[sid] or {}
end

---@param sid string
---@param id string Option id
---@param value string
---@param cb? fun(err: string?)
function Agent:set_option(sid, id, value, cb)
    cb = cb or function(err)
        if err then
            log.error(err)
        end
    end
    local option = options.find(self:get_options(sid), id)
    if not option then
        return cb(("unknown option %q"):format(id))
    end
    local method, params
    if option.legacy == "mode" then
        method, params = "session/set_mode", { sessionId = sid, modeId = value }
    elseif option.legacy == "model" then
        method, params = "session/set_model", { sessionId = sid, modelId = value }
    else
        method, params = "session/set_config_option", { sessionId = sid, configId = option.id, value = value }
    end
    self:_request(method, params, function(err, result)
        if err then
            return cb(errmsg(err))
        end
        if result and result.configOptions then
            self.options[sid] = options.from_config_options(result.configOptions)
        else
            option.current = value
        end
        cb(nil)
    end)
end

---Ask the user to pick one of the agent's advertised auth methods.
---@param cb fun(err: string?)
function Agent:authenticate(cb)
    local methods = self.info and self.info.authMethods or {}
    if #methods == 0 then
        return cb(self.name .. " requires authentication but advertised no auth methods")
    end
    vim.ui.select(methods, {
        prompt = self.name .. " requires authentication",
        format_item = function(m)
            return m.description and ("%s: %s"):format(m.name, m.description) or m.name
        end,
    }, function(choice)
        if not choice then
            return cb("authentication cancelled")
        end
        self:_request("authenticate", { methodId = choice.id }, function(err)
            cb(err and errmsg(err) or nil)
        end)
    end)
end

---@param session_id string
---@param prompt table[] ACP ContentBlocks
---@param cb fun(err: string?, result: table?)
function Agent:prompt(session_id, prompt, cb)
    self:_request("session/prompt", { sessionId = session_id, prompt = prompt }, function(err, result)
        cb(err and errmsg(err) or nil, result)
    end)
end

---@param session_id string
function Agent:cancel(session_id)
    if self.rpc then
        self.rpc:notify("session/cancel", { sessionId = session_id })
    end
end

function Agent:stop()
    if self.rpc then
        self.rpc:stop()
    end
end

function Agent:_on_request(method, params, respond)
    if method == "fs/read_text_file" then
        local result, err = require("conduit.fs").read(params)
        respond(err, result)
    elseif method == "fs/write_text_file" then
        local result, err = require("conduit.fs").write(params)
        respond(err, result)
    elseif method == "session/request_permission" then
        local session = self.sessions[params.sessionId]
        if not session then
            return respond(nil, { outcome = { outcome = "cancelled" } })
        end
        session:request_permission(params, respond)
    else
        respond({ code = -32601, message = "Method not found: " .. method })
    end
end

function Agent:_on_notification(method, params)
    if method == "session/update" then
        local sid, update = params.sessionId, params.update
        if update.sessionUpdate == "config_option_update" then
            self.options[sid] = options.from_config_options(update.configOptions or {})
        elseif update.sessionUpdate == "current_mode_update" then
            local mode = options.find(self:get_options(sid), "mode")
            if mode then
                mode.current = update.currentModeId
            end
        end
        local session = self.sessions[sid]
        if session then
            session:on_update(params.update)
        end
    else
        log.debug(("%s: unhandled notification %s"):format(self.name, method))
    end
end

function Agent:_on_exit(code)
    log.debug(("%s exited with code %d"):format(self.name, code))
    local was_starting = self.state == "starting"
    self.state = "idle"
    self.rpc = nil
    local sessions = self.sessions
    self.sessions = {}
    self.options = {}
    for _, session in pairs(sessions) do
        session:on_agent_exit(code)
    end
    if was_starting then
        self:_started(("agent exited during startup (code %d), see :Conduit log"):format(code))
    end
end

return Agent
