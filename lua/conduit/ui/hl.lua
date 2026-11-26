--- Highlight groups and small helpers shared by conduit's floats and inline
--- decorations: window borders, title badges and key hints.
local M = {}

---@type table<string, vim.api.keyset.highlight>
local GROUPS = {
    ConduitNormal = { link = "NormalFloat" },
    ConduitBorder = { link = "FloatBorder" },
    ConduitTitle = { link = "FloatTitle" },
    ConduitAgent = { link = "Title" },
    ConduitContext = { link = "Comment" },
    ConduitModeAuto = { link = "Special" },
    ConduitModeEdit = { link = "DiagnosticWarn" },
    ConduitModeAsk = { link = "DiagnosticInfo" },
    ConduitHintKey = { link = "Special" },
    ConduitHintDesc = { link = "Comment" },
    ConduitPlaceholder = { link = "Comment" },
    ConduitSpinner = { link = "DiagnosticInfo" },
    ConduitInlinePending = { link = "CursorLine" },
    ConduitInlineSign = { link = "DiagnosticInfo" },
    ConduitInlineStatus = { link = "Comment" },
    ConduitReviewAdd = { link = "DiffAdd" },
    ConduitReviewChange = { link = "DiffChange" },
    ConduitReviewDelete = { link = "DiffDelete" },
    ConduitReviewSign = { link = "DiagnosticInfo" },
    ConduitReviewHint = { link = "Comment" },
    ConduitMuted = { link = "Comment" },
    ConduitTitleText = { link = "Title" },
    ConduitInlineAdded = { link = "DiffAdd" },
    ConduitPickerCursor = { link = "CursorLine" },
    ConduitPickerCurrent = { link = "Special" },
    ConduitPickerIndex = { link = "Comment" },
    ConduitHistoryAnswer = { link = "DiagnosticInfo" },
    ConduitHistoryEdit = { link = "DiagnosticWarn" },
    ConduitHistoryChange = { link = "DiagnosticHint" },
}

---Glyph sets: `ui.icons = true` (Unicode, in most fonts), `false` (ASCII) or
---`"nerd"` (Nerd Font glyphs where they exist, Unicode for the rest).
local GLYPHS = {
    unicode = {
        model = "◆",
        thought_level = "◐",
        effort = "◐",
        mode = "⏵",
        current = "●",
        pending = "○",
        in_progress = "◐",
        completed = "✓",
        failed = "✗",
        answer = "?",
        edit = "~",
        change = "±",
        agent = "",
    },
    ascii = {
        model = "",
        thought_level = "",
        effort = "",
        mode = "",
        current = "*",
        pending = "o",
        in_progress = "~",
        completed = "+",
        failed = "x",
        answer = "?",
        edit = "~",
        change = "+",
        agent = "",
    },
    nerd = {
        model = "󰚩",
        effort = "󰓅",
        thought_level = "󰓅",
        mode = "󰘳",
        agent = "󰚩 ",
    },
}

---The glyph for `name` in the configured set.
---@param name string
---@return string
function M.glyph(name)
    local icons = require("conduit.config").options.ui.icons
    if icons == false then
        return GLYPHS.ascii[name] or ""
    elseif icons == "nerd" then
        return GLYPHS.nerd[name] or GLYPHS.unicode[name] or ""
    end
    return GLYPHS.unicode[name] or ""
end

local function apply()
    for name, spec in pairs(GROUPS) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
    end
end

local did_setup = false

---Define the highlight groups, and redefine them after `:colorscheme` (which
---clears everything, `default` links included). Idempotent.
function M.setup()
    if did_setup then
        return
    end
    did_setup = true
    apply()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("conduit.hl", { clear = true }),
        callback = apply,
    })
end

---`winhighlight` for conduit floats, so they can be themed separately.
M.WINHIGHLIGHT = "NormalFloat:ConduitNormal,FloatBorder:ConduitBorder,FloatTitle:ConduitTitle"

-- Borders without a top edge can't hold a title (nvim_open_win errors).
local NO_TITLE = { [""] = true, none = true, shadow = true }

---Border for floats with a title (prompts, pickers): `ui.border` when set, else
---the user's 'winborder', else rounded.
---@return string|string[]|nil
function M.border()
    local border = require("conduit.config").options.ui.border
    if border then
        return border
    end
    return NO_TITLE[vim.o.winborder] and "rounded" or nil
end

---Border for content floats (history list, help): none unless `ui.border` is set.
---@return string|string[]
function M.content_border()
    return require("conduit.config").options.ui.border or "none"
end

---Width of an inline prompt shown over `win`: `ui.inline.width` clamped to the
---window, and never wider than the editor.
---@param win integer
---@return integer
function M.width(win)
    local limits = require("conduit.config").options.ui.inline.width
    local avail = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) - 4 or vim.o.columns
    local width = math.max(limits.min, math.min(limits.max, avail))
    return math.max(1, math.min(width, vim.o.columns - 4))
end

---@alias conduit.Chunks [string, string?][]

---Title chunk for the agent, with an icon when `ui.icons` is on.
---@param name string
---@return [string, string]
function M.agent(name)
    return { (" %s%s "):format(M.glyph("agent"), name), "ConduitAgent" }
end

---Footer chunks for key hints, e.g. `{ { "<CR>", "send" }, { "q", "close" } }`.
---@param hints [string, string][] `{ key, description }` pairs
---@return conduit.Chunks
function M.keys(hints)
    local chunks = { { " " } } ---@type conduit.Chunks
    for i, hint in ipairs(hints) do
        if i > 1 then
            table.insert(chunks, { "  " })
        end
        table.insert(chunks, { hint[1], "ConduitHintKey" })
        table.insert(chunks, { " " .. hint[2], "ConduitHintDesc" })
    end
    table.insert(chunks, { " " })
    return chunks
end

---Echo `hints` as a list, for `g?`.
---@param title string
---@param hints [string, string][]
function M.echo_keys(title, hints)
    local width = 0
    for _, hint in ipairs(hints) do
        width = math.max(width, vim.fn.strdisplaywidth(hint[1]))
    end
    local chunks = { { title .. "\n", "ConduitAgent" } } ---@type conduit.Chunks
    for _, hint in ipairs(hints) do
        local pad = (" "):rep(width - vim.fn.strdisplaywidth(hint[1]))
        table.insert(chunks, { "  " .. hint[1] .. pad, "ConduitHintKey" })
        table.insert(chunks, { "  " .. hint[2] .. "\n", "ConduitHintDesc" })
    end
    vim.api.nvim_echo(chunks, false, {})
end

return M
