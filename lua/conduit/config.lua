local M = {}

---@class conduit.AgentSpec
---@field cmd string Executable to launch
---@field args? string[] Arguments passed to `cmd`
---@field env? table<string, string> Extra environment variables
---@field options? table<string, string> Session options applied to every new session, keyed by
---option id or category, e.g. `{ model = "opus", effort = "high", mode = "acceptEdits" }`
---@field mcp_servers? conduit.McpServers MCP servers for this agent, replacing global ones of the
---same name; `false` leaves a global server out
---@field session_meta? table Extra `_meta` for `session/new`, merged over what the sandbox sends
---(e.g. `{ claudeCode = { options = { ... } } }` for Claude's adapter)

---@class conduit.TerminalConfig
---@field enabled boolean Offer to run the agent's commands (ACP `terminal` capability)
---@field output_limit integer Most bytes of output kept per command

---@class conduit.UiConfig
---@field icons boolean|"nerd"
---@field spinner string[]
---@field inline { width: { min: integer, max: integer } }
---@field sidebar { width: number, position: "right"|"left" }
---@field border? string|string[]
---@field components table<string, fun(props: table, builtin: fun(props: table): table): table>

---@class conduit.ReviewConfig
---@field enabled boolean Review agent edits; false applies them as they come
---@field replies boolean Review inline replies (the rewritten selection) too
---@field keys conduit.ReviewKeys Buffer-local keys in files with changes to review; false disables one

---@class conduit.InlineConfig
---@field agent? string
---@field options table<string, string>
---@field mcp_servers boolean

---@class conduit.HistoryConfig
---@field enabled boolean
---@field max_entries integer

---@class conduit.CommandPolicy
---@field default "ask"|"allow"|"deny" For commands no rule matches
---@field allow string[] Lua patterns; a command runs without asking when every part matches one
---@field deny string[] Lua patterns; a command is refused when any part matches one

---@class conduit.IsolationConfig
---@field enabled boolean Run ACP terminal commands in an OS sandbox (sandbox-exec, bwrap)
---@field network boolean Let sandboxed commands use the network
---@field writable string[] Directories sandboxed commands may write besides the roots and temp dirs
---@field env "inherit"|"minimal" Pass Neovim's environment, or only PATH, HOME, locale and the like
---@field unavailable "ask"|"run"|"deny" What to do when no OS sandbox is installed

---@class conduit.SandboxConfig
---@field enabled boolean
---@field roots string[] Directories the agent may touch besides the working directory
---@field outside "deny"|"ask" File access and edits outside the roots
---@field commands conduit.CommandPolicy
---@field isolation conduit.IsolationConfig
---@field bypass boolean Allow the agent's own "bypass permissions" mode (it skips every check)

---@class conduit.Config
---@field default_agent string
---@field agents table<string, conduit.AgentSpec>
---@field ui conduit.UiConfig
---@field inline conduit.InlineConfig
---@field history conduit.HistoryConfig
---@field mcp_servers conduit.McpServers
---@field mentions { completion: "auto"|"blink"|"native" }
---@field terminal conduit.TerminalConfig
---@field review conduit.ReviewConfig
---@field sandbox conduit.SandboxConfig
---@field log_level integer
M.defaults = {
    default_agent = "claude",
    agents = {
        claude = { cmd = "npx", args = { "-y", "@agentclientprotocol/claude-agent-acp" } },
        gemini = { cmd = "gemini", args = { "--experimental-acp" } },
        codex = { cmd = "npx", args = { "-y", "@agentclientprotocol/codex-acp" } },
    },
    ui = {
        -- Glyphs: true (Unicode: ◆ ◐ ⏵ ✓), false (ASCII only) or "nerd" (Nerd Font).
        icons = true,
        -- Progress animation frames; a single frame disables the animation.
        spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
        inline = {
            -- Width of the inline prompt, in columns.
            width = { min = 40, max = 84 },
        },
        -- Where answers are shown. `width` is a fraction of the editor (<= 1) or columns.
        sidebar = { width = 0.35, position = "right" },
        -- Border for conduit floats. nil: prompts follow 'winborder'.
        border = nil,
        -- Replace or add components by name, e.g.
        -- `HistoryLine = function(props, builtin) return builtin(props) end` (see :h conduit-components).
        components = {},
    },
    inline = {
        -- Agent for inline requests; defaults to `default_agent`.
        agent = nil,
        -- Session options for inline requests, layered over the agent's `options`.
        options = {},
        -- Give inline sessions the MCP servers too. Each request opens a new session,
        -- so the agent starts every server per request.
        mcp_servers = false,
    },
    -- Every answer, edit, agent change and command, per project, in
    -- stdpath("state")/conduit/history.
    history = { enabled = true, max_entries = 1000 },
    -- MCP servers handed to the agent for every session, keyed by name, e.g.
    -- `github = { command = "github-mcp", env = { TOKEN = function() return os.getenv("GH") end } }`
    -- or `docs = { type = "http", url = "https://example.com/mcp", headers = {} }`.
    -- conduit doesn't run them; the agent does.
    mcp_servers = {},
    mentions = {
        -- `@` completion: "auto" uses blink.cmp when it's loaded, else the native popup.
        completion = "auto",
    },
    terminal = {
        -- Let agents run commands through Neovim (ACP terminals), under `sandbox`.
        -- Agents that run commands themselves (Claude, Codex) ask for permission
        -- instead, and the same command policy answers those requests.
        enabled = true,
        -- Most bytes of output kept per command; the oldest output is dropped first.
        output_limit = 1024 * 1024,
    },
    -- Review of agent edits: files the agent changes keep their earlier content, and
    -- the changes show in the file as hunks to accept or reject.
    review = {
        enabled = true,
        replies = true,
        keys = {
            next = "]r",
            prev = "[r",
            accept = "<localleader>a",
            reject = "<localleader>r",
            accept_file = "<localleader>A",
            reject_file = "<localleader>R",
        },
    },
    -- What agents may do: which files they can touch, which commands they can run
    -- (asked, allowed or refused), and how ACP terminal commands are isolated.
    sandbox = {
        enabled = true,
        -- The working directory is always a root.
        roots = {},
        outside = "deny",
        -- Commands are split at `&&`, `||`, `;`, `|` and newlines; each part is
        -- matched on its own. Command substitution (`$(...)`, backticks) always asks.
        commands = {
            default = "ask",
            -- Read-only commands that run without asking.
            allow = {
                "^ls%f[%s%z]",
                "^pwd$",
                "^cat%f[%s%z]",
                "^head%f[%s%z]",
                "^tail%f[%s%z]",
                "^wc%f[%s%z]",
                "^rg%f[%s%z]",
                "^grep%f[%s%z]",
                "^git status%f[%s%z]",
                "^git diff%f[%s%z]",
                "^git log%f[%s%z]",
                "^git show%f[%s%z]",
            },
            deny = {
                "^sudo%f[%s%z]",
                "^doas%f[%s%z]",
                "^su%f[%s%z]",
                "^rm%s.*%-%a*[rR]%a*f",
                "^rm%s.*%-%a*f%a*[rR]",
                "^rm%s.*%-%-recursive",
                "^mkfs",
                "^dd%s",
                "^shutdown%f[%s%z]",
                "^reboot%f[%s%z]",
                "^chmod%s+%-R%s+777",
                "^git push%s.*%-%-force",
                "^git push%s.*%-f%f[%s%z]",
                "^git reset%s+%-%-hard",
                "^git clean%s+%-%a*f",
                -- Piping into a shell (`curl ... | sh`).
                "^sh$",
                "^bash$",
                "^zsh$",
            },
        },
        isolation = {
            enabled = true,
            network = false,
            writable = {},
            env = "inherit",
            unavailable = "ask",
        },
        bypass = false,
    },
    log_level = vim.log.levels.WARN,
}

---@type conduit.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    -- Pattern lists replace the defaults instead of merging index by index.
    local cmds = opts and opts.sandbox and opts.sandbox.commands
    for _, key in ipairs({ "allow", "deny" }) do
        if cmds and cmds[key] then
            M.options.sandbox.commands[key] = vim.deepcopy(cmds[key])
        end
    end
end

return M
