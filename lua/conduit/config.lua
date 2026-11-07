local M = {}

---@class conduit.AgentSpec
---@field cmd string Executable to launch
---@field args? string[] Arguments passed to `cmd`
---@field env? table<string, string> Extra environment variables
---@field options? table<string, string> Session options applied to every new session, keyed by
---option id or category, e.g. `{ model = "opus", effort = "high", mode = "acceptEdits" }`

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
    log_level = vim.log.levels.WARN,
}

---@type conduit.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
