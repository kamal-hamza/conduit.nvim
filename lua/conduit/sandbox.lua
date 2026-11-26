--- What agents may do. Three layers, all under `sandbox` in the config:
---
--- - Paths: `fs/*` requests, edits and redirections must stay inside the roots
---   (the working directory plus `sandbox.roots`); outside them they're refused
---   or asked about (`sandbox.outside`).
--- - Commands: a policy of allow/deny patterns answers ACP `terminal/create`
---   requests and permission requests for commands the agent runs itself
---   (Claude, Codex). Commands are split into parts first, so `git status && rm
---   -rf x` can't ride on an allowed prefix.
--- - Isolation: commands conduit runs for the agent (ACP terminals) run in an
---   OS sandbox, `sandbox-exec` on macOS or `bwrap` on Linux: writes only to
---   the roots and temp dirs, and no network unless allowed.
---
--- The patterns are a guardrail, not a boundary: a determined command can get
--- past a pattern. Isolation is the boundary, and it only covers commands that
--- conduit runs.
local config = require("conduit.config")
local fs = require("conduit.fs")

local M = {}

---@alias conduit.Decision "allow"|"deny"|"ask"

---@return conduit.SandboxConfig
local function opts()
    return config.options.sandbox
end

---@return boolean
function M.enabled()
    return opts().enabled ~= false
end

---Canonical roots: the working directory and `sandbox.roots`.
---@return string[]
function M.roots()
    local out = { fs.canonical(vim.fn.getcwd()) }
    for _, root in ipairs(opts().roots or {}) do
        table.insert(out, fs.canonical(vim.fn.expand(root) --[[@as string]]))
    end
    return out
end

---@param path string
---@param cwd? string Base for relative paths
---@return string
local function absolute(path, cwd)
    path = vim.fn.expand(path) --[[@as string]]
    if not vim.startswith(path, "/") and not path:match("^%a:[/\\]") then
        path = vim.fs.joinpath(cwd or vim.fn.getcwd(), path)
    end
    return fs.canonical(path)
end

---Whether `path` is inside one of the roots.
---@param path string
---@param cwd? string
---@return boolean
function M.inside(path, cwd)
    local abs = absolute(path, cwd)
    for _, root in ipairs(M.roots()) do
        if abs == root or vim.startswith(abs, root:gsub("/$", "") .. "/") then
            return true
        end
    end
    return false
end

---Decide on paths the agent wants to touch.
---@param paths string[]
---@param cwd? string
---@return conduit.Decision decision, string? reason
function M.check_paths(paths, cwd)
    if not M.enabled() then
        return "allow"
    end
    for _, path in ipairs(paths) do
        if not M.inside(path, cwd) then
            return opts().outside == "ask" and "ask" or "deny",
                ("%s is outside the project"):format(vim.fn.fnamemodify(path, ":~"))
        end
    end
    return "allow"
end

---@class conduit.CommandParts
---@field parts string[] Simple commands, trimmed, wrappers (`env`, `nohup`, ...) removed
---@field substitution boolean The line uses `$(...)` or backticks
---@field redirects string[] Files written with `>` or `>>`

-- Commands that run the rest of their arguments as a command.
local WRAPPERS = { env = true, command = true, exec = true, nohup = true, time = true, nice = true, xargs = true }

---Drop leading `VAR=value` assignments and wrappers, so `env sudo x` is seen as `sudo x`.
---@param part string
---@return string
local function unwrap(part)
    while true do
        local before = part
        part = part:gsub("^%(+%s*", ""):gsub("^[%a_][%w_]*=%S*%s+", "")
        local word, rest = part:match("^(%S+)%s+(.*)$")
        if word and rest and WRAPPERS[word] then
            part = rest:gsub("^%-%S*%s+", "")
        elseif word == "timeout" and rest then
            part = rest:gsub("^%S+%s+", "")
        end
        if part == before then
            return vim.trim((part:gsub("%)+$", "")))
        end
    end
end

---Split a shell command line into simple commands at unquoted `&&`, `||`,
---`;`, `|`, `&` and newlines, noting command substitution and redirections.
---@param line string
---@return conduit.CommandParts
function M.split(line)
    local parts, redirects = {}, {} ---@type string[], string[]
    local substitution = false
    local cur, quote = {}, nil ---@type string[], string?
    local i, n = 1, #line
    local function flush()
        local part = unwrap(vim.trim(table.concat(cur)))
        if part ~= "" then
            table.insert(parts, part)
        end
        cur = {}
    end
    while i <= n do
        local c = line:sub(i, i)
        if quote then
            if c == quote then
                quote = nil
            elseif quote == '"' and (c == "`" or line:sub(i, i + 1) == "$(") then
                substitution = true
            elseif c == "\\" and quote == '"' then
                table.insert(cur, c)
                i = i + 1
                c = line:sub(i, i)
            end
            table.insert(cur, c)
        elseif c == "'" or c == '"' then
            quote = c
            table.insert(cur, c)
        elseif c == "\\" then
            table.insert(cur, line:sub(i, i + 1))
            i = i + 1
        elseif c == "`" or line:sub(i, i + 1) == "$(" then
            substitution = true
            table.insert(cur, c)
        elseif c == ";" or c == "\n" or c == "|" or c == "&" then
            -- `2>&1` and `&>` are redirections, not separators.
            local prev = line:sub(i - 1, i - 1)
            if c == "&" and (prev == ">" or prev == "<" or line:sub(i + 1, i + 1) == ">") then
                table.insert(cur, c)
            else
                flush()
                if (c == "|" or c == "&") and line:sub(i + 1, i + 1) == c then
                    i = i + 1
                end
            end
        elseif c == ">" then
            local target = line:sub(i + 1):match("^>?%s*([^%s;&|<>]+)")
            if target and not target:match("^&") then
                table.insert(redirects, (target:gsub("^['\"]", ""):gsub("['\"]$", "")))
            end
            table.insert(cur, c)
        else
            table.insert(cur, c)
        end
        i = i + 1
    end
    flush()
    return { parts = parts, substitution = substitution, redirects = redirects }
end

---@param part string
---@param patterns string[]
---@return string? pattern The first that matches
local function matches(part, patterns)
    for _, pattern in ipairs(patterns or {}) do
        local ok, found = pcall(string.find, part, pattern)
        if ok and found then
            return pattern
        end
    end
end

-- Redirections that never touch a real file.
local HARMLESS = { ["/dev/null"] = true, ["/dev/stdout"] = true, ["/dev/stderr"] = true }

---Decide on a command line (or several lines of one script).
---@param command string|string[]
---@param cwd? string
---@return conduit.Decision decision, string? reason
function M.check_command(command, cwd)
    if not M.enabled() then
        return "allow"
    end
    local line = type(command) == "table" and table.concat(command, "\n") or command --[[@as string]]
    local policy = opts().commands or {}
    local split = M.split(line)
    for _, part in ipairs(split.parts) do
        local rule = matches(part, policy.deny)
        if rule then
            return "deny", ("`%s` is blocked by sandbox.commands.deny"):format(part)
        end
    end
    for _, target in ipairs(split.redirects) do
        if not HARMLESS[target] then
            local decision, reason = M.check_paths({ target }, cwd)
            if decision ~= "allow" then
                return decision, "writes " .. (reason or target)
            end
        end
    end
    if #split.parts == 0 then
        return "ask", "empty command"
    end
    if split.substitution then
        return policy.default == "deny" and "deny" or "ask", "uses command substitution"
    end
    for _, part in ipairs(split.parts) do
        if not matches(part, policy.allow) then
            local default = policy.default or "ask"
            return default, default ~= "allow" and ("`%s` isn't in sandbox.commands.allow"):format(part) or nil
        end
    end
    return "allow"
end

---Absolute paths a tool call touches: its locations and diffs.
---@param call table ACP ToolCall
---@param cwd? string
---@return string[]
function M.tool_paths(call, cwd)
    local out = {} ---@type string[]
    for _, loc in ipairs(type(call.locations) == "table" and call.locations or {}) do
        if type(loc) == "table" and type(loc.path) == "string" and loc.path ~= "" then
            table.insert(out, absolute(loc.path, cwd))
        end
    end
    for _, item in ipairs(type(call.content) == "table" and call.content or {}) do
        if type(item) == "table" and item.type == "diff" and type(item.path) == "string" then
            table.insert(out, absolute(item.path, cwd))
        end
    end
    local raw = type(call.rawInput) == "table" and call.rawInput or {}
    for _, key in ipairs({ "file_path", "path", "notebook_path" }) do
        if type(raw[key]) == "string" and raw[key] ~= "" then
            table.insert(out, absolute(raw[key], cwd))
        end
    end
    return out
end

---Decide on a permission request: the command it runs and the paths it touches.
---@param call table The request's tool call, merged over what's known about it
---@param cwd? string
---@return conduit.Decision decision, string? reason
function M.check_tool(call, cwd)
    if not M.enabled() then
        return "ask"
    end
    local kind = call.kind
    local paths = M.tool_paths(call, cwd)
    if kind ~= "fetch" and kind ~= "search" or #paths > 0 then
        local decision, reason = M.check_paths(paths, cwd)
        if decision ~= "allow" then
            return decision, reason
        end
    end
    local info = require("conduit.ui.permission").describe(call)
    if info.command then
        return M.check_command(info.command, cwd)
    end
    -- Everything else is up to the user, as the agent asked.
    return "ask"
end

---The option of a permission request that carries out `decision` once.
---@param options table[] ACP PermissionOption list
---@param decision "allow"|"deny"
---@return table?
function M.option_for(options, decision)
    local want = decision == "allow" and "allow_once" or "reject_once"
    local fallback = decision == "allow" and "allow_always" or "reject_always"
    local found
    for _, option in ipairs(options or {}) do
        if option.kind == want then
            return option
        elseif option.kind == fallback and decision == "deny" then
            -- Refusing for good is still a refusal; allowing for good is not ours to choose.
            found = found or option
        end
    end
    return found
end

-- Isolation ---------------------------------------------------------------

local backend_cache ---@type string|false|nil

---The OS sandbox available here: "sandbox-exec" (macOS), "bwrap" (Linux) or nil.
---@return string?
function M.backend()
    if backend_cache == nil then
        if vim.fn.has("mac") == 1 and vim.fn.executable("sandbox-exec") == 1 then
            backend_cache = "sandbox-exec"
        elseif vim.fn.has("linux") == 1 and vim.fn.executable("bwrap") == 1 then
            backend_cache = "bwrap"
        else
            backend_cache = false
        end
    end
    return backend_cache or nil
end

---For tests: pretend `name` is (or no backend is) installed.
---@param name? string|false
function M._set_backend(name)
    backend_cache = name
end

---Directories sandboxed commands may write: the roots, `isolation.writable`
---and the temp dirs, resolved through symlinks (the kernel sees real paths).
---@return string[]
function M.writable()
    local out, seen = {}, {} ---@type string[], table<string, true>
    local function add(dir)
        if type(dir) ~= "string" or dir == "" then
            return
        end
        local real = vim.uv.fs_realpath(vim.fn.expand(dir) --[[@as string]])
        if real and not seen[real] then
            seen[real] = true
            table.insert(out, real)
        end
    end
    for _, root in ipairs(M.roots()) do
        add(root)
    end
    for _, dir in ipairs(opts().isolation.writable or {}) do
        add(dir)
    end
    add("/tmp")
    add(os.getenv("TMPDIR"))
    add(vim.fn.fnamemodify(vim.fn.tempname(), ":h:h"))
    return out
end

---@param s string
---@return string
local function sb_string(s)
    return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---The sandbox-exec profile: everything allowed except writes outside
---`writable` and, unless allowed, the network.
---@param writable string[]
---@param network boolean
---@return string
function M.profile(writable, network)
    local lines = {
        "(version 1)",
        "(allow default)",
        "(deny file-write*)",
        "(allow file-write*",
    }
    for _, dir in ipairs(writable) do
        table.insert(lines, "  (subpath " .. sb_string(dir) .. ")")
    end
    vim.list_extend(lines, {
        '  (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty") (literal "/dev/dtracehelper")',
        '  (regex #"^/dev/fd/") (regex #"^/dev/ttys"))',
    })
    if not network then
        table.insert(lines, "(deny network*)")
        table.insert(lines, "(allow network* (remote unix-socket))")
    end
    return table.concat(lines, "\n")
end

---Wrap `cmd` for `backend`.
---@param cmd string[]
---@param backend string
---@param cwd string
---@return string[]
function M.wrap_with(cmd, backend, cwd)
    local iso = opts().isolation
    local writable = M.writable()
    if backend == "sandbox-exec" then
        return vim.list_extend({ "sandbox-exec", "-p", M.profile(writable, iso.network) }, cmd)
    end
    local args = { "bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--die-with-parent" }
    for _, dir in ipairs(writable) do
        vim.list_extend(args, { "--bind", dir, dir })
    end
    if not iso.network then
        table.insert(args, "--unshare-net")
    end
    vim.list_extend(args, { "--chdir", cwd, "--" })
    return vim.list_extend(args, cmd)
end

-- Variables kept with `isolation.env = "minimal"`.
local MINIMAL_ENV = { "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR" }

---The environment for a command: Neovim's (or the minimal set) plus `extra`.
---@param extra? table<string, string>
---@return table<string, string>? env, boolean clear Pass `clear` to vim.system's `clear_env`
function M.env(extra)
    if not M.enabled() or opts().isolation.env ~= "minimal" then
        return extra, false
    end
    local env = {} ---@type table<string, string>
    for _, name in ipairs(MINIMAL_ENV) do
        env[name] = os.getenv(name)
    end
    return vim.tbl_extend("force", env, extra or {}), true
end

---How to run `cmd` for the agent: wrapped in the OS sandbox when isolation is
---on and available. `isolated` is false when the command runs as is.
---@param cmd string[]
---@param cwd string
---@return string[]? cmd, boolean isolated, string? err Nil `cmd` when it must not run
---@return conduit.Decision? unavailable What `isolation.unavailable` says, when no backend exists
function M.wrap(cmd, cwd)
    if not M.enabled() or not opts().isolation.enabled then
        return cmd, false
    end
    local backend = M.backend()
    if backend then
        return M.wrap_with(cmd, backend, cwd), true
    end
    local fallback = opts().isolation.unavailable
    if fallback == "deny" then
        return nil, false, "no OS sandbox (sandbox-exec or bwrap) is installed"
    end
    return cmd, false, nil, fallback == "run" and "allow" or "ask"
end

---Ask the user about something the policy left open. `cb(true)` allows it once.
---@param agent_name string
---@param what string What the agent wants, e.g. "run `make`"
---@param reason? string Why it's being asked
---@param cb fun(allowed: boolean)
function M.ask(agent_name, what, reason, cb)
    local prompt = ("%s wants to %s"):format(agent_name, what)
    if reason then
        prompt = prompt .. "\nsandbox: " .. reason
    end
    vim.ui.select({ "Allow once", "Deny" }, { prompt = prompt }, function(choice)
        cb(choice == "Allow once")
    end)
end

---`_meta` for `session/new` that carries the sandbox into agents that run tools
---themselves. Claude's adapter takes Claude Code options under `claudeCode`:
---an `ask` rule for Bash makes every command come back to us as a permission
---request (ask rules beat the user's allow rules), Claude Code's own sandbox
---isolates the commands it runs, and bypass mode is removed from the session.
---Other agents ignore `_meta` they don't know.
---@return table?
function M.session_meta()
    if not M.enabled() then
        return nil
    end
    local cfg = opts()
    local settings = { permissions = { ask = { "Bash" } } } ---@type table
    if cfg.isolation.enabled then
        settings.sandbox = { enabled = true, autoAllowBashIfSandboxed = false }
    end
    local options = { settings = settings } ---@type table
    if not cfg.bypass then
        options.allowDangerouslySkipPermissions = false
    end
    local meta = { claudeCode = { options = options } } ---@type table
    local roots = M.roots()
    if #roots > 1 then
        meta.additionalRoots = vim.list_slice(roots, 2)
    end
    return meta
end

---Whether a session option value is the agent's "skip all permission checks" mode.
---@param value string
---@return boolean
function M.is_bypass(value)
    local v = value:lower():gsub("[%s_%-]", "")
    return v == "bypasspermissions" or v == "bypass" or v == "yolo" or v == "fullaccess"
end

return M
