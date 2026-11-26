--- An ACP agent subprocess. Neovim acts as the ACP *client*.
--- Spec: https://agentclientprotocol.com
local Rpc = require("conduit.rpc")
local Terminal = require("conduit.terminal")
local log = require("conduit.log")
local mcp = require("conduit.mcp")
local options = require("conduit.options")
local review = require("conduit.review")
local sandbox = require("conduit.sandbox")

local PROTOCOL_VERSION = 1
local AUTH_REQUIRED = -32000
local NOT_FOUND = -32002

---Optional session features an agent may advertise in `sessionCapabilities`.
---Requests are one-shot sessions, so only `close` matters.
---@alias conduit.SessionCap "close"

---@class conduit.SessionHandler
---@field on_update fun(self, update: table)
---@field request_permission fun(self, params: table, respond: fun(err: table?, result: any), reason: string?)
---@field on_agent_exit fun(self, code: integer)
---@field cwd? string Working directory of the session (default for terminals)
---@field tools? table<string, table> Tool calls seen so far, by id (permission requests may only carry the id)
---@field review_changed? fun(self, tool_call_id: string) The review state of a tool call's files changed
---@field on_decision? fun(self, tool_call_id: string, decision: conduit.Decision|string, reason: string?) The sandbox
---answered a permission request (or passed it on to the user)
---@field on_terminal? fun(self, term: conduit.Terminal) A command started (or was refused) for the session

---A slash command the agent advertises (`available_commands_update`).
---@class conduit.Command
---@field name string Without the leading `/`
---@field description? string
---@field input? { hint?: string } Present when the command takes arguments

---@class conduit.Agent
---@field name string
---@field spec conduit.AgentSpec
---@field rpc? conduit.Rpc
---@field info? table Result of `initialize`
---@field state "idle"|"starting"|"ready"
---@field sessions table<string, conduit.SessionHandler>
---@field options table<string, conduit.Option[]> Session options by session id
---@field commands table<string, conduit.Command[]> Slash commands by session id
---@field last_commands conduit.Command[] Most recent command list from any session
---@field last_options conduit.Option[] Most recent options of any session (for prompts opened before a session)
---@field usage table<string, conduit.Usage> Context use by session id (`usage_update`)
---@field terminals table<string, conduit.Terminal> Terminals by id: commands run for the agent and
---display terminals it reports, kept (with their output) until their session closes
---@field terminal_count integer
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
    return setmetatable({
        name = name,
        spec = spec,
        state = "idle",
        sessions = {},
        options = {},
        commands = {},
        last_commands = {},
        last_options = {},
        usage = {},
        waiting = {},
        terminals = {},
        terminal_count = 0,
    }, Agent)
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
        clientCapabilities = {
            fs = { readTextFile = true, writeTextFile = true },
            terminal = require("conduit.config").options.terminal.enabled,
            -- Display terminals: agents that run commands themselves (Claude,
            -- Codex) report their output in tool call `_meta` instead.
            _meta = { terminal_output = true, terminal_output_delta = true },
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
    local session_caps = caps.sessionCapabilities
    return type(session_caps) == "table" and session_caps[cap] ~= nil
end

---Create a session (retrying once after authentication), record its options,
---then apply the agent's configured default options (`spec.options`) merged
---with `overrides`.
---@param cwd string
---@param handler conduit.SessionHandler
---@param cb fun(err: string?, session_id: string?, result: table?)
---@param overrides? table<string, string>
---@param opts? { mcp?: boolean } `mcp = false` opens the session without MCP servers
function Agent:new_session(cwd, handler, cb, overrides, opts)
    local defaults = vim.tbl_extend("force", self.spec.options or {}, overrides or {})
    local servers = (opts and opts.mcp == false) and {} or mcp.servers(self)
    local params = { cwd = cwd, mcpServers = servers } ---@type table
    local meta = vim.tbl_deep_extend("force", sandbox.session_meta() or {}, self.spec.session_meta or {})
    if next(meta) then
        params._meta = meta
    end
    local function attempt(retry)
        self:_request("session/new", params, function(err, result)
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
            local sid = result.sessionId
            if type(sid) ~= "string" then
                return cb("session/new returned no session id")
            end
            self.sessions[sid] = handler
            self:_set_options(sid, options.from_session(result))
            self:_apply_defaults(sid, defaults, function()
                cb(nil, sid, result)
            end)
        end)
    end
    attempt(true)
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
    self.usage[sid] = nil
    self.commands[sid] = nil
    self:_release_terminals(sid)
    if not self.rpc or not self:supports("close") then
        return cb(nil)
    end
    self:_request("session/close", { sessionId = sid }, function(err)
        cb(err and err.code ~= NOT_FOUND and errmsg(err) or nil)
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

---Slash commands for a session. Without a known list for `sid` (or with no
---`sid`, before a session exists) this falls back to the last list any session
---received: agents advertise the same commands for every session, and they
---often arrive just after `session/new` responds.
---@param sid? string
---@return conduit.Command[]
function Agent:get_commands(sid)
    return sid and self.commands[sid] or self.last_commands
end

---@param sid string
---@param opts conduit.Option[]
function Agent:_set_options(sid, opts)
    self.options[sid] = opts
    if #opts > 0 then
        self.last_options = opts
    end
    require("conduit.ui.status").emit()
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
    if option.category == "mode" or option.legacy == "mode" or option.id == "mode" then
        local cfg = require("conduit.config").options.sandbox
        if sandbox.enabled() and not cfg.bypass and sandbox.is_bypass(value) then
            return cb(("mode %q skips every permission check; set sandbox.bypass = true to allow it"):format(value))
        end
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
            self:_set_options(sid, options.from_config_options(result.configOptions))
        else
            option.current = value
            require("conduit.ui.status").emit()
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
        local handler = self.sessions[session_id] ---@type conduit.SessionHandler?
        if handler then
            review.turn_done(handler)
        end
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

---Run `fn` if the sandbox lets the agent touch `paths`; otherwise answer with an error.
---@param paths string[]
---@param what string For the prompt, e.g. "write foo.lua"
---@param respond fun(err: table?, result: any)
---@param fn fun()
function Agent:_guard_paths(paths, what, respond, fn)
    local decision, reason = sandbox.check_paths(paths)
    if decision == "allow" then
        return fn()
    end
    local function refuse()
        log.debug(("%s: refused to %s: %s"):format(self.name, what, reason or ""))
        respond({ code = -32603, message = ("blocked by the conduit sandbox: %s"):format(reason or what) })
    end
    if decision == "deny" then
        return refuse()
    end
    sandbox.ask(self.name, what, reason, function(allowed)
        if allowed then
            fn()
        else
            refuse()
        end
    end)
end

function Agent:_on_request(method, params, respond)
    if method == "fs/read_text_file" then
        local path = tostring(params.path)
        self:_guard_paths({ path }, "read " .. vim.fn.fnamemodify(path, ":~:."), respond, function()
            local result, err = require("conduit.fs").read(params)
            respond(err, result)
        end)
    elseif method == "fs/write_text_file" then
        local path = tostring(params.path)
        self:_guard_paths({ path }, "write " .. vim.fn.fnamemodify(path, ":~:."), respond, function()
            local session = self.sessions[params.sessionId] ---@type conduit.SessionHandler?
            if session then
                review.before_write(session, params.path)
            end
            local result, err = require("conduit.fs").write(params)
            if session and not err then
                review.after_write(params.path)
            end
            respond(err, result)
        end)
    elseif vim.startswith(method, "terminal/") then
        self:_terminal_request(method, params, respond)
    elseif method == "session/request_permission" then
        local session = self.sessions[params.sessionId]
        if not session then
            return respond(nil, { outcome = { outcome = "cancelled" } })
        end
        review.on_permission(session, params.toolCall)
        self:_permission(session, params, respond)
    else
        respond({ code = -32601, message = "Method not found: " .. method })
    end
end

---Answer a permission request from the sandbox policy when it can, else ask the user.
---@param session conduit.SessionHandler
---@param params table
---@param respond fun(err: table?, result: any)
function Agent:_permission(session, params, respond)
    local call = params.toolCall or {}
    local known = session.tools and session.tools[call.toolCallId]
    local merged = require("conduit.ui.permission").merge(known, call)
    local decision, reason = sandbox.check_tool(merged, session.cwd)
    local id = type(call.toolCallId) == "string" and call.toolCallId or ""
    local option = decision ~= "ask" and sandbox.option_for(params.options, decision) or nil
    if decision == "deny" and not option then
        -- No way to say no once: cancelling the request refuses it too.
        option = { optionId = nil }
    end
    if option then
        log.debug(("%s: sandbox %s %s: %s"):format(self.name, decision, merged.title or id, reason or ""))
        if session.on_decision then
            session:on_decision(id, decision, reason)
        end
        if decision == "deny" then
            vim.notify(("[conduit] refused: %s"):format(reason or (merged.title or "tool call")), vim.log.levels.WARN)
        end
        if not option.optionId then
            return respond(nil, { outcome = { outcome = "cancelled" } })
        end
        return respond(nil, { outcome = { outcome = "selected", optionId = option.optionId } })
    end
    session:request_permission(params, function(err, result)
        if session.on_decision then
            local chosen = result and result.outcome and result.outcome.optionId
            local picked = "deny"
            for _, o in ipairs(params.options or {}) do
                if o.optionId == chosen and type(o.kind) == "string" and vim.startswith(o.kind, "allow") then
                    picked = "allow"
                end
            end
            session:on_decision(id, "asked: " .. picked, reason)
        end
        respond(err, result)
    end, reason)
end

---@param method string
---@param params table
---@param respond fun(err: table?, result: any)
function Agent:_terminal_request(method, params, respond)
    if not require("conduit.config").options.terminal.enabled then
        return respond({ code = -32601, message = "Method not found: " .. method })
    end
    local sid = params.sessionId
    if method == "terminal/create" then
        return self:_terminal_create(params, respond)
    end
    local term = self.terminals[params.terminalId]
    if not term or not term.spawned or term.released or term.session_id ~= sid then
        return respond({ code = -32602, message = "Unknown terminal: " .. tostring(params.terminalId) })
    end
    if method == "terminal/output" then
        respond(nil, term:output_result())
    elseif method == "terminal/wait_for_exit" then
        term:wait(function(status)
            respond(nil, { exitCode = status.exitCode, signal = status.signal })
        end)
    elseif method == "terminal/kill" then
        term:kill()
        respond(nil, vim.empty_dict())
    elseif method == "terminal/release" then
        term:release()
        respond(nil, vim.empty_dict())
    else
        respond({ code = -32601, message = "Method not found: " .. method })
    end
end

---`terminal/create`, under the sandbox: the command policy decides whether it
---runs (or asks), and isolation wraps it in the OS sandbox.
---@param params table
---@param respond fun(err: table?, result: any)
function Agent:_terminal_create(params, respond)
    local sid = params.sessionId
    local session = self.sessions[sid] ---@type conduit.SessionHandler?
    local cwd = Terminal.cwd(params, session and session.cwd or vim.fn.getcwd())
    local argv, shown = Terminal.argv(params)
    local exe = argv and argv[1]
    if not argv or not exe then
        return respond({ code = -32602, message = "missing command" })
    elseif vim.fn.executable(exe) == 0 then
        -- Checked here: wrapped in the OS sandbox, a missing command would only fail later.
        return respond({ code = -32603, message = ("could not run %s: executable not found"):format(exe) })
    end
    local function report(term)
        if session and session.on_terminal then
            session:on_terminal(term)
        end
    end
    local function refuse(reason)
        log.debug(("%s: refused to run %s: %s"):format(self.name, shown, reason))
        local term = Terminal.new("refused", { session_id = sid, command = shown })
        term.refused = reason
        report(term)
        respond({ code = -32603, message = ("blocked by the conduit sandbox: %s"):format(reason) })
    end
    local wrapped, isolated, wrap_err, unavailable = sandbox.wrap(argv, cwd)
    if not wrapped then
        return refuse(wrap_err or "isolation unavailable")
    end
    local function run(decision)
        self.terminal_count = self.terminal_count + 1
        local id = "term-" .. self.terminal_count
        local term, err = Terminal.spawn(id, params, cwd, { argv = wrapped, isolated = isolated })
        if not term then
            return respond({ code = -32603, message = ("could not run %s: %s"):format(params.command, err) })
        end
        term.decision = decision
        log.debug(("%s: terminal %s runs %s%s"):format(self.name, id, shown, isolated and " (isolated)" or ""))
        self.terminals[id] = term
        report(term)
        respond(nil, { terminalId = id })
    end
    local decision, reason = sandbox.check_command(shown, cwd)
    if decision == "deny" then
        return refuse(reason or "denied")
    end
    if unavailable == "ask" then
        -- No OS sandbox: even allowed commands need a yes, since nothing contains them.
        decision = "ask"
        reason = (reason and (reason .. "; ") or "") .. "no OS sandbox (sandbox-exec or bwrap) is installed"
    end
    if decision == "ask" then
        return sandbox.ask(self.name, ("run `%s`"):format(shown), reason, function(ok)
            if ok then
                run("asked")
            else
                refuse("declined")
            end
        end)
    end
    run("allowed")
end

---Track a display terminal from a tool call's `_meta` (the `terminal_output`
---extension), before the session handler renders the update.
---@param sid string
---@param meta table
function Agent:_display_terminal(sid, meta)
    local info = meta.terminal_info or meta.terminal_output or meta.terminal_output_delta or meta.terminal_exit
    local id = type(info) == "table" and info.terminal_id
    if type(id) ~= "string" then
        return
    end
    local term = self.terminals[id]
    if not term then
        term = Terminal.new(id, { session_id = sid })
        self.terminals[id] = term
    end
    if type(meta.terminal_output) == "table" and type(meta.terminal_output.data) == "string" then
        term:set_output(meta.terminal_output.data)
    end
    if type(meta.terminal_output_delta) == "table" and type(meta.terminal_output_delta.data) == "string" then
        term:append(meta.terminal_output_delta.data)
    end
    if type(meta.terminal_exit) == "table" then
        local exit = meta.terminal_exit
        term:exited({
            exitCode = type(exit.exit_code) == "number" and math.floor(exit.exit_code) or nil,
            signal = type(exit.signal) == "string" and exit.signal or nil,
        })
    end
end

---Kill and forget a session's terminals.
---@param sid string
function Agent:_release_terminals(sid)
    for id, term in pairs(self.terminals) do
        if term.session_id == sid then
            term:release()
            self.terminals[id] = nil
        end
    end
end

---Look up a terminal (live, released or display) to show in a tool call.
---@param id string
---@return conduit.Terminal?
function Agent:terminal(id)
    return self.terminals[id]
end

function Agent:_on_notification(method, params)
    if method == "session/update" then
        local sid, update = params.sessionId, params.update
        if update.sessionUpdate == "config_option_update" then
            self:_set_options(sid, options.from_config_options(update.configOptions or {}))
        elseif update.sessionUpdate == "usage_update" then
            local usage = require("conduit.ui.status").parse_usage(update)
            if usage then
                self.usage[sid] = usage
                require("conduit.ui.status").emit()
            end
        elseif update.sessionUpdate == "available_commands_update" then
            local list = type(update.availableCommands) == "table" and update.availableCommands or {}
            self.commands[sid] = list
            self.last_commands = list
        elseif update.sessionUpdate == "current_mode_update" then
            local mode = options.find(self:get_options(sid), "mode")
            if mode then
                mode.current = update.currentModeId
                require("conduit.ui.status").emit()
            end
        end
        if type(update._meta) == "table" then
            self:_display_terminal(sid, update._meta)
        end
        local session = self.sessions[sid] ---@type conduit.SessionHandler?
        if session then
            -- Before the handler draws the update, so tool calls show their review state.
            review.on_update(session, params.update)
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
    self.usage = {}
    self.commands = {}
    for _, term in pairs(self.terminals) do
        term:release()
    end
    self.terminals = {}
    for _, session in pairs(sessions) do
        session:on_agent_exit(code)
    end
    if was_starting then
        self:_started(("agent exited during startup (code %d), see :Conduit log"):format(code))
    end
end

return Agent
