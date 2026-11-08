--- Terminals: commands the agent runs through the client (ACP `terminal/*`), and
--- "display terminals" that agents running commands themselves (Claude, Codex)
--- report in tool call `_meta` (`terminal_info`, `terminal_output[_delta]`,
--- `terminal_exit`). Both keep their output here so the chat can show it.
--- Spec: https://agentclientprotocol.com/protocol/terminals
local config = require("conduit.config")

local uv = vim.uv

local SIGNALS = {
    [1] = "SIGHUP",
    [2] = "SIGINT",
    [3] = "SIGQUIT",
    [6] = "SIGABRT",
    [9] = "SIGKILL",
    [13] = "SIGPIPE",
    [14] = "SIGALRM",
    [15] = "SIGTERM",
}

-- Milliseconds between SIGTERM and SIGKILL when killing a command.
local KILL_GRACE_MS = 2000

---ACP `TerminalExitStatus`.
---@class conduit.ExitStatus
---@field exitCode? integer
---@field signal? string

---@class conduit.Terminal
---@field id string
---@field session_id? string
---@field command? string The command line, for display
---@field chunks string[] Output not yet joined
---@field size integer Bytes in `chunks`
---@field truncated boolean Earlier output was dropped to stay under `limit`
---@field limit integer Most bytes of output to keep
---@field exit? conduit.ExitStatus Set once the command has exited
---@field proc? vim.SystemObj The running command
---@field spawned boolean conduit runs the command (`terminal/create`), not a display terminal
---@field released boolean
---@field waiters fun(status: conduit.ExitStatus)[] Pending `terminal/wait_for_exit` replies
---@field subscribers table<any, fun(term: conduit.Terminal)>
local Terminal = {}
Terminal.__index = Terminal

---Terminals with a running process, killed when Neovim exits.
---@type table<conduit.Terminal, true>
local live = setmetatable({}, { __mode = "k" })
local leave_autocmd = false

---@param id string
---@param opts? { session_id?: string, command?: string, limit?: integer }
---@return conduit.Terminal
function Terminal.new(id, opts)
    opts = opts or {}
    local limit = config.options.terminal.output_limit
    local requested = opts.limit
    if requested and requested >= 0 then
        limit = math.min(requested, limit)
    end
    return setmetatable({
        id = id,
        session_id = opts.session_id,
        command = opts.command,
        chunks = {},
        size = 0,
        truncated = false,
        limit = limit,
        released = false,
        spawned = false,
        waiters = {},
        subscribers = {},
    }, Terminal)
end

---Drop leading UTF-8 continuation bytes, so a cut never starts mid-character.
---@param s string
---@return string
local function utf8_start(s)
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then
            break
        end
        i = i + 1
    end
    return i == 1 and s or s:sub(i)
end

---Replace bytes that aren't valid UTF-8 with U+FFFD, so binary output can't
---produce invalid JSON.
---@param s string
---@return string
function Terminal.sanitize(s)
    if not s:find("[\128-\255]") then
        return s
    end
    local out, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local len = b < 0x80 and 1 or b >= 0xF0 and b < 0xF5 and 4 or b >= 0xE0 and 3 or b >= 0xC2 and 2 or 0
        local ok = len > 0 and i + len - 1 <= n
        for j = i + 1, ok and i + len - 1 or 0 do
            local c = s:byte(j)
            if c < 0x80 or c >= 0xC0 then
                ok = false
                break
            end
        end
        if ok then
            out[#out + 1] = s:sub(i, i + len - 1)
            i = i + len
        else
            out[#out + 1] = "\239\191\189"
            i = i + 1
        end
    end
    return table.concat(out)
end

---@return string
function Terminal:output()
    if #self.chunks > 1 then
        self.chunks = { table.concat(self.chunks) }
    end
    return self.chunks[1] or ""
end

function Terminal:_notify()
    for _, fn in pairs(self.subscribers) do
        pcall(fn, self)
    end
end

---Append output, dropping the oldest bytes beyond the limit.
---@param data string
function Terminal:append(data)
    if data == "" then
        return
    end
    table.insert(self.chunks, data)
    self.size = self.size + #data
    if self.size > self.limit then
        local all = table.concat(self.chunks)
        local kept = utf8_start(all:sub(#all - self.limit + 1))
        self.chunks, self.size, self.truncated = { kept }, #kept, true
    end
    self:_notify()
end

---Replace the whole output (a `terminal_output` snapshot).
---@param data string
function Terminal:set_output(data)
    self.chunks, self.size, self.truncated = {}, 0, false
    if #data > self.limit then
        data = utf8_start(data:sub(#data - self.limit + 1))
        self.truncated = true
    end
    self.chunks, self.size = { data }, #data
    self:_notify()
end

---Record the exit and answer everyone waiting for it.
---@param status conduit.ExitStatus
function Terminal:exited(status)
    if self.exit then
        return
    end
    self.exit = status
    self.proc = nil
    live[self] = nil
    local waiters = self.waiters
    self.waiters = {}
    for _, respond in ipairs(waiters) do
        respond(status)
    end
    self:_notify()
end

---ACP `terminal/output` result.
---@return table
function Terminal:output_result()
    return {
        output = Terminal.sanitize(self:output()),
        truncated = self.truncated,
        exitStatus = self.exit and { exitCode = self.exit.exitCode, signal = self.exit.signal } or nil,
    }
end

---Call `respond(status)` once the command exits (right away if it has).
---@param respond fun(status: conduit.ExitStatus)
function Terminal:wait(respond)
    if self.exit then
        return respond(self.exit)
    end
    table.insert(self.waiters, respond)
end

---@param key any
---@param fn fun(term: conduit.Terminal)
function Terminal:subscribe(key, fn)
    self.subscribers[key] = fn
end

---@param key any
function Terminal:unsubscribe(key)
    self.subscribers[key] = nil
end

---@param sig integer
function Terminal:_signal(sig)
    local proc = self.proc
    if not proc then
        return
    end
    -- The command leads its own process group (`detach`), so signal the group:
    -- `sh -c` would otherwise leave its children running.
    if vim.fn.has("win32") == 0 and proc.pid then
        if uv.kill(-proc.pid, sig) == 0 then
            return
        end
    end
    pcall(proc.kill, proc, sig)
end

---Kill the command, keeping its output (`terminal/kill`).
function Terminal:kill()
    if not self.proc or self.exit then
        return
    end
    self:_signal(15)
    vim.defer_fn(function()
        if self.proc and not self.exit then
            self:_signal(9)
        end
    end, KILL_GRACE_MS)
end

---Kill the command if it's running and stop accepting requests for it
---(`terminal/release`). The output stays for tool calls that show it.
function Terminal:release()
    self:kill()
    self.released = true
    self.waiters = {}
end

---Whether `command` is a whole shell command line rather than an executable.
---@param command string
---@param args string[]
---@return boolean
local function is_shell_line(command, args)
    return #args == 0 and vim.fn.executable(command) == 0 and command:find("[%s;&|<>$`'\"*?()]") ~= nil
end

---@param command string
---@param args string[]
---@return string
local function display_command(command, args)
    if #args == 0 then
        return command
    end
    local parts = { command }
    for _, a in ipairs(args) do
        parts[#parts + 1] = a:find("[%s'\"]") and vim.fn.shellescape(a) or a
    end
    return table.concat(parts, " ")
end

---Start a command for `terminal/create`.
---@param id string
---@param params table ACP `CreateTerminalRequest`
---@param default_cwd string Used when the request has no absolute `cwd`
---@return conduit.Terminal?, string?
function Terminal.spawn(id, params, default_cwd)
    local command = params.command
    if type(command) ~= "string" or command == "" then
        return nil, "missing command"
    end
    local args = type(params.args) == "table" and params.args or {}
    local cmd
    if is_shell_line(command, args) then
        -- Some agents send a whole shell line as the command.
        cmd = vim.fn.has("win32") == 1 and { "cmd.exe", "/s", "/c", command } or { "sh", "-c", command }
    else
        cmd = { command, unpack(args) }
    end
    local cwd = params.cwd
    if type(cwd) ~= "string" or not vim.startswith(cwd, "/") and not cwd:match("^%a:[/\\]") then
        cwd = default_cwd
    end
    if vim.fn.isdirectory(cwd) == 0 then
        return nil, "no such directory: " .. cwd
    end
    local env ---@type table<string, string>?
    for _, var in ipairs(type(params.env) == "table" and params.env or {}) do
        if type(var.name) == "string" then
            env = env or {}
            env[var.name] = tostring(var.value or "")
        end
    end

    local term = Terminal.new(id, {
        session_id = params.sessionId,
        command = display_command(command, args),
        limit = type(params.outputByteLimit) == "number" and params.outputByteLimit or nil,
    })
    local function on_output(_, data)
        if data then
            vim.schedule(function()
                term:append(data)
            end)
        end
    end
    local ok, proc = pcall(vim.system, cmd, {
        cwd = cwd,
        env = env,
        -- Its own process group, so kill() reaches the whole command.
        detach = true,
        stdout = on_output,
        stderr = on_output,
    }, function(obj)
        vim.schedule(function()
            local signal = obj.signal ~= 0 and (SIGNALS[obj.signal] or ("SIG" .. obj.signal)) or nil
            term:exited({ exitCode = not signal and obj.code or nil, signal = signal })
        end)
    end)
    if not ok then
        return nil, tostring(proc)
    end
    term.proc = proc
    term.spawned = true
    live[term] = true
    if not leave_autocmd then
        leave_autocmd = true
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = vim.api.nvim_create_augroup("conduit_terminal", { clear = true }),
            desc = "Kill commands started by conduit agents",
            callback = function()
                for t in pairs(live) do
                    t:_signal(9)
                end
            end,
        })
    end
    return term
end

---Text for showing output in a buffer: no ANSI escapes, carriage returns
---resolved (progress bars keep their last state), as lines.
---@param s string
---@return string[]
function Terminal.display_lines(s)
    s = s:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""):gsub("\27%][^\7\27]*\7", ""):gsub("\r\n", "\n")
    local lines = vim.split(s, "\n", { plain = true })
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    for i, line in ipairs(lines) do
        lines[i] = line:match("[^\r]*$"):gsub("[%z\1-\8\11-\31\127]", "")
    end
    return lines
end

---A short description of the exit, or nil while running or for a clean exit.
---@return string?
function Terminal:exit_text()
    local exit = self.exit
    if not exit then
        return nil
    elseif exit.signal then
        return "killed by " .. exit.signal
    elseif exit.exitCode and exit.exitCode ~= 0 then
        return "exit code " .. exit.exitCode
    end
end

return Terminal
