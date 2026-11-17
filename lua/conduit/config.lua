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

---@class conduit.TerminalConfig
---@field enabled boolean Offer to run the agent's commands (ACP `terminal` capability)
---@field output_limit integer Most bytes of output kept per command

---@class conduit.UiKeys Keys in the chat (input and transcript); false disables one
---@field model string|false Pick the model
---@field effort_next string|false Next effort level (takes a count)
---@field effort_prev string|false Previous effort level (takes a count)
---@field mode_next string|false Next mode (takes a count)
---@field options string|false Pick any session option
---@field help string|false List the keys

---@class conduit.UiConfig
---@field width number
---@field input_height integer
---@field icons boolean|"nerd"
---@field spinner string[]
---@field picker "auto"|"snacks"|"telescope"|"fzf_lua"|"mini_pick"|"select"|conduit.PickerProvider
---@field thread_bar boolean
---@field inline { width: { min: integer, max: integer }, max_height: integer }
---@field keys conduit.UiKeys
---@field mouse boolean
---@field border? string|string[]
---@field components table<string, fun(props: table, builtin: fun(props: table): table): table>
---@field remember_options boolean

---@class conduit.ToolsConfig
---@field diff_lines integer Most diff lines shown per tool call before it's expanded
---@field output_lines integer Most output lines shown per tool call before it's expanded
---@field hide_output table<string, boolean> Tool kinds whose output stays hidden until expanded

---@class conduit.ReviewConfig
---@field enabled boolean Review agent edits at all; false applies them as they come
---@field chat boolean Review edits made during chat turns
---@field inline boolean Review edits from inline requests (their replies and any tool edits)
---@field keys conduit.ReviewKeys Buffer-local keys in files with changes to review; false disables one

---@class conduit.InlineConfig
---@field agent? string
---@field options table<string, string>
---@field mcp_servers boolean
---@field answer "peek"|"chat"|"float" Where answers go
---@field history { enabled: boolean, max_entries: integer }

---@class conduit.Config
---@field default_agent string
---@field agents table<string, conduit.AgentSpec>
---@field ui conduit.UiConfig
---@field inline conduit.InlineConfig
---@field mcp_servers conduit.McpServers
---@field mentions { completion: "auto"|"blink"|"native" }
---@field threads conduit.ThreadsConfig
---@field tools conduit.ToolsConfig
---@field terminal conduit.TerminalConfig
---@field review conduit.ReviewConfig
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
        -- Glyphs: true (Unicode: ◆ ◐ ⏵ ✓), false (ASCII only) or "nerd" (Nerd Font).
        icons = true,
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
            -- Most lines an unfocused answer float shows.
            max_height = 10,
        },
        -- Chat keys (input and transcript buffers); false disables one. Every action
        -- is also a <Plug>(conduit-...) mapping and a require("conduit") function.
        keys = {
            model = "<M-m>",
            effort_next = "<M-e>",
            effort_prev = "<M-E>",
            mode_next = "<S-Tab>",
            options = "go",
            help = "g?",
        },
        -- Click the status chips to change options. Off: everything is on keys.
        mouse = false,
        -- Border for conduit floats. nil: answers have none, prompts follow 'winborder'.
        border = nil,
        -- Replace or add components by name, e.g.
        -- `Chip = function(props, builtin) return builtin(props) end` (see :h conduit-components).
        components = {},
        -- Options you pick in a chat become the defaults for new threads (this session).
        remember_options = false,
    },
    inline = {
        -- Agent for inline edits; defaults to `default_agent`.
        agent = nil,
        -- Session options for inline edits, layered over the agent's `options`.
        options = {},
        -- Give inline sessions the MCP servers too. Each inline request opens a new
        -- session, so the agent would start every server per request.
        mcp_servers = false,
        -- Where answers go: "peek" (an unfocused float or virtual lines by the code),
        -- "chat" (the chat panel) or "float" (a focused float, the old behaviour).
        answer = "peek",
        -- Every inline answer and edit, per project, separate from chat threads.
        history = { enabled = true, max_entries = 500 },
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
    terminal = {
        -- Let agents run commands through Neovim (ACP terminals). Agents that run
        -- commands themselves (Claude, Codex) still show their output in the chat.
        enabled = true,
        -- Most bytes of output kept per command; the oldest output is dropped first.
        -- Agents can ask for less.
        output_limit = 1024 * 1024,
    },
    -- Review of agent edits: files the agent changes keep their earlier content, and
    -- the changes show in the file as hunks to accept or reject. Off, edits apply as
    -- they come (combine with the agent's `mode = "acceptEdits"` option for no prompts at all).
    review = {
        enabled = true,
        chat = true,
        -- Inline requests stay fire-and-forget unless this is on.
        inline = false,
        keys = {
            next = "]r",
            prev = "[r",
            accept = "<localleader>a",
            reject = "<localleader>r",
            accept_file = "<localleader>A",
            reject_file = "<localleader>R",
        },
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
