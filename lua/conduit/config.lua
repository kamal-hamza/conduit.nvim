local M = {}

---@class conduit.AgentSpec
---@field cmd string Executable to launch
---@field args? string[] Arguments passed to `cmd`
---@field env? table<string, string> Extra environment variables
---@field options? table<string, string> Session options applied to every new session, keyed by
---option id or category, e.g. `{ model = "opus", effort = "high", mode = "acceptEdits" }`

---@class conduit.ThreadsConfig
---@field scope "cwd"|"all" Which past threads to list: this directory's, or all of them
---@field persist boolean Keep a local index of threads (ids and titles, not transcripts)
---@field max_listed integer Most past threads to fetch from the agent
---@field hide_inline boolean Leave inline requests' sessions out of thread lists

---@class conduit.UiConfig
---@field width number
---@field input_height integer
---@field icons boolean
---@field spinner string[]
---@field inline { width: { min: integer, max: integer } }

---@class conduit.Config
---@field default_agent string
---@field agents table<string, conduit.AgentSpec>
---@field ui conduit.UiConfig
---@field inline { agent?: string, options: table<string, string> }
---@field mentions { completion: "auto"|"blink"|"native" }
---@field threads conduit.ThreadsConfig
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
    },
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
