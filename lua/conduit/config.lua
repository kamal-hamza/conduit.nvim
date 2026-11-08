local M = {}

---@class conduit.AgentSpec
---@field cmd string Executable to launch
---@field args? string[] Arguments passed to `cmd`
---@field env? table<string, string> Extra environment variables
---@field options? table<string, string> Session options applied to every new session, keyed by
---option id or category, e.g. `{ model = "opus", effort = "high", mode = "acceptEdits" }`
---@field mcp_servers? conduit.McpServers MCP servers for this agent, replacing global ones of the
---same name; `false` leaves a global server out

---@class conduit.ThreadsConfig
---@field scope "cwd"|"all" Which past threads to list: this directory's, or all of them
---@field persist boolean Keep a local index of threads (ids and titles, not transcripts)
---@field max_listed integer Most past threads to fetch from the agent
---@field hide_inline boolean Leave inline requests' sessions out of thread lists
---@field notify boolean Notify when a thread you're not looking at finishes or needs permission

---@class conduit.UiConfig
---@field width number
---@field input_height integer
---@field icons boolean
---@field spinner string[]
---@field picker "auto"|"snacks"|"telescope"|"fzf_lua"|"mini_pick"|"select"|conduit.PickerProvider
---@field thread_bar boolean
---@field inline { width: { min: integer, max: integer } }

---@class conduit.ToolsConfig
---@field diff_lines integer Most diff lines shown per tool call before it's expanded
---@field output_lines integer Most output lines shown per tool call before it's expanded
---@field hide_output table<string, boolean> Tool kinds whose output stays hidden until expanded

---@class conduit.Config
---@field default_agent string
---@field agents table<string, conduit.AgentSpec>
---@field ui conduit.UiConfig
---@field inline { agent?: string, options: table<string, string>, mcp_servers: boolean }
---@field mcp_servers conduit.McpServers
---@field mentions { completion: "auto"|"blink"|"native" }
---@field threads conduit.ThreadsConfig
---@field tools conduit.ToolsConfig
---@field log_level integer
M.defaults = {
    default_agent = "claude",
    agents = {
        claude = { cmd = "npx", args = { "-y", "@agentclientprotocol/claude-agent-acp" } },
        gemini = { cmd = "gemini", args = { "--experimental-acp" } },
        codex = { cmd = "npx", args = { "-y", "@agentclientprotocol/codex-acp" } },
    },
    ui = {
        -- Fraction of the editor width (<= 1) or an absolute column count.
        width = 0.4,
        input_height = 6,
        -- Nerd Font glyphs in float titles.
        icons = false,
        -- Progress animation frames; a single frame disables the animation.
        spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
        -- Picker for threads and search: "auto" uses snacks.nvim, telescope.nvim, fzf-lua
        -- or mini.pick when loaded (in that order), else vim.ui.select. Or name one, or
        -- pass a function that takes a conduit.PickerSpec.
        picker = "auto",
        -- Show threads as tabs in the chat's winbar; state and options move to the
        -- prompt's winbar.
        thread_bar = true,
        inline = {
            -- Width of the inline prompt and answer floats, in columns.
            width = { min = 40, max = 84 },
        },
    },
    inline = {
        -- Agent for inline edits; defaults to `default_agent`.
        agent = nil,
        -- Session options for inline edits, layered over the agent's `options`.
        options = {},
        -- Give inline sessions the MCP servers too. Each inline request opens a new
        -- session, so the agent would start every server per request.
        mcp_servers = false,
    },
    -- MCP servers handed to the agent for every session, keyed by name, e.g.
    -- `github = { command = "github-mcp", env = { TOKEN = function() return os.getenv("GH") end } }`
    -- or `docs = { type = "http", url = "https://example.com/mcp", headers = {} }`.
    -- conduit doesn't run them; the agent does.
    mcp_servers = {},
    mentions = {
        -- `@` completion: "auto" uses blink.cmp when it's loaded, else the native popup.
        completion = "auto",
    },
    threads = {
        -- Past threads to offer: "cwd" (sessions started in the current directory) or "all".
        scope = "cwd",
        -- Remember threads (session ids and titles, never transcripts) in
        -- stdpath("data")/conduit/threads.json. Agents that can load sessions but not
        -- list them rely on it for their history.
        persist = true,
        max_listed = 200,
        -- Leave inline requests' sessions out of thread lists.
        hide_inline = true,
        -- Notify when a thread you're not looking at finishes a turn or asks for permission.
        notify = true,
    },
    -- Tool calls in the chat: diffs and output are previewed under each call, up to
    -- these many lines; <CR> on a call shows all of it.
    tools = {
        diff_lines = 20,
        output_lines = 8,
        -- Kinds whose output (often a whole file) stays hidden until expanded.
        hide_output = { read = true, search = true, fetch = true },
    },
    log_level = vim.log.levels.WARN,
}

---@type conduit.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
