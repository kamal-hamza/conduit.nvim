--- conduit's built-in components. Each is a pure function of its props; see
--- `conduit.ui.component` for how they are rendered and mounted.
local component = require("conduit.ui.component")
local hl = require("conduit.ui.hl")

local define = component.define
local M = {}

---@param n integer
---@return string
local function plural(n, word)
    return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

---A labelled value: optional glyph, then the label.
---Props: `icon?`, `label`, `hl?`, `key?` (shown nowhere; kept for overrides), `on_click?`.
define({
    name = "Chip",
    render = function(p)
        local out = {} ---@type conduit.Spans
        if p.icon and p.icon ~= "" then
            out[#out + 1] = { p.icon .. " ", "ConduitChipIcon", click = p.on_click }
        end
        out[#out + 1] = { p.label, p.hl or "ConduitChip", click = p.on_click }
        return out
    end,
})

---Animated progress glyph. Props: `frame`.
define({
    name = "Spinner",
    render = function(p)
        return p.frame and p.frame ~= "" and { { p.frame, "ConduitSpinner" } } or {}
    end,
})

local STATE_TEXT = {
    working = "working",
    loading = "loading",
    disconnected = "disconnected",
    ["not started"] = "not started",
}

---The status chips: state, model, effort, mode and (right-aligned) context use.
---Props: `status` (`conduit.StatusInfo`), `chips?` (which to show, in order),
---`agent?` (show the agent name first), `actions?` (`{ model = fn, ... }` click handlers).
define({
    name = "ChipBar",
    render = function(p)
        local s = p.status ---@type conduit.StatusInfo
        local actions = p.actions or {}
        local out = { { " " } } ---@type conduit.Spans
        local function gap()
            if #out > 1 then
                out[#out + 1] = { "   " }
            end
        end
        if p.agent then
            out[#out + 1] = { s.agent, "ConduitAgent" }
        end
        if s.state == "working" or s.state == "loading" then
            gap()
            vim.list_extend(out, component.render("Spinner", { frame = s.frame }))
            out[#out + 1] = { (s.frame and s.frame ~= "" and " " or "") .. STATE_TEXT[s.state], "ConduitMuted" }
        elseif STATE_TEXT[s.state] then
            gap()
            out[#out + 1] = { STATE_TEXT[s.state], "ConduitMuted" }
        end
        for _, chip in ipairs(p.chips or { "model", "effort", "mode" }) do
            local value = s[chip]
            if value then
                gap()
                vim.list_extend(
                    out,
                    component.render("Chip", {
                        icon = hl.glyph(chip),
                        label = value,
                        hl = "ConduitChip",
                        key = chip,
                        on_click = actions[chip],
                    })
                )
            end
        end
        if s.context then
            out[#out + 1] = { "%=", raw = true }
            local high = s.context.percent >= 80
            out[#out + 1] = { ("ctx %d%%"):format(s.context.percent), high and "ConduitContextHigh" or "ConduitMuted" }
            if s.context.cost then
                out[#out + 1] = {
                    (" · %.2f %s"):format(s.context.cost.amount, s.context.cost.currency),
                    "ConduitMuted",
                }
            end
            out[#out + 1] = { " " }
        end
        return out
    end,
})

---Title of a chat without the thread bar. Props: `agent`, `title`, `index?`, `count?`.
define({
    name = "TitleBar",
    render = function(p)
        local out = { { " " }, { p.title, "ConduitTitleText" } } ---@type conduit.Spans
        if p.index and p.count and p.count > 1 then
            out[#out + 1] = { (" %d/%d"):format(p.index, p.count), "ConduitMuted" }
        end
        out[#out + 1] = { "%=", raw = true }
        out[#out + 1] = { p.agent .. " ", "ConduitMuted" }
        return out
    end,
})

---Ghost text in an empty input. Props: `hints` (strings).
define({
    name = "Placeholder",
    render = function(p)
        return { { table.concat(p.hints, " · "), "ConduitPlaceholder" } }
    end,
})

---Key list for `g?`. Props: `title`, `entries` (`{ key, description }` pairs), `query?`.
define({
    name = "HelpFloat",
    render = function(p)
        local width = 0
        for _, e in ipairs(p.entries) do
            width = math.max(width, vim.fn.strdisplaywidth(e[1]))
        end
        local lines = {} ---@type conduit.Spans[]
        lines[#lines + 1] = { { " " .. p.title, "ConduitTitleText" } }
        if p.query and p.query ~= "" then
            lines[#lines][2] = { "  /" .. p.query, "ConduitMuted" }
        end
        for _, e in ipairs(p.entries) do
            local pad = (" "):rep(width - vim.fn.strdisplaywidth(e[1]))
            lines[#lines + 1] = { { " " .. e[1] .. pad, "ConduitHintKey" }, { "  " .. e[2], "ConduitHintDesc" } }
        end
        if #p.entries == 0 then
            lines[#lines + 1] = { { " no matching keys", "ConduitMuted" } }
        end
        return lines
    end,
})

---Rows of the keyboard picker. Props: `model` (`conduit.PickerModel`).
define({
    name = "Picker",
    render = function(p)
        local model = p.model ---@type conduit.PickerModel
        local lines = {} ---@type conduit.Spans[]
        if model.query ~= "" then
            lines[#lines + 1] = { { " /" .. model.query, "ConduitMuted" } }
        end
        for i, item in ipairs(model.filtered) do
            local current = model.current ~= nil and item.value == model.current
            local row = {
                { i <= 9 and (" %d "):format(i) or "   ", "ConduitPickerIndex" },
                { current and (hl.glyph("current") .. " ") or "  ", "ConduitPickerCurrent" },
                { item.label, i == model.cursor and "ConduitPickerCursor" or nil },
            } ---@type conduit.Spans
            if item.description and item.description ~= "" then
                row[#row + 1] = { "  " .. item.description, "ConduitMuted" }
            end
            lines[#lines + 1] = row
        end
        if #model.filtered == 0 then
            lines[#lines + 1] = { { "   no matches", "ConduitMuted" } }
        end
        return lines
    end,
})

---Inline prompt title. Props: `agent?`, `mode?`, `mode_hl?`, `model?`, `effort?`, `range`.
define({
    name = "PromptTitle",
    render = function(p)
        local out = {} ---@type conduit.Spans
        if p.agent then
            out[#out + 1] = hl.agent(p.agent)
        end
        if p.mode then
            out[#out + 1] = { (" %s "):format(p.mode), p.mode_hl }
        end
        local opts = vim.tbl_filter(function(v)
            return v ~= nil and v ~= ""
        end, { p.model, p.effort })
        if #opts > 0 then
            out[#out + 1] = { (" %s "):format(table.concat(opts, "/")), "ConduitMuted" }
        end
        out[#out + 1] = { (" %s "):format(p.range), "ConduitContext" }
        return out
    end,
})

---A transcript role header drawn as a thin labelled rule. Props: `label`, `role`, `width`.
define({
    name = "RoleRule",
    render = function(p)
        local rule = hl.glyph("rule")
        local head = rule .. rule .. " "
        local label = p.label .. " "
        local rest = math.max(0, p.width - vim.fn.strdisplaywidth(head .. label))
        return {
            { head, "ConduitRule" },
            { label, p.role == "user" and "ConduitRoleUser" or "ConduitRoleAgent" },
            { rule:rep(rest), "ConduitRule" },
        }
    end,
})

---A tool call's status line. Props: `status?`, `title`.
define({
    name = "ToolCallLine",
    render = function(p)
        local glyph = hl.glyph(p.status or "pending")
        return { { (glyph ~= "" and glyph or "•") .. " " }, { p.title } }
    end,
})

---A collapsed (or open) thinking section header. Props: `lines`, `open`.
define({
    name = "ThinkingFold",
    render = function(p)
        local glyph = hl.glyph(p.open and "fold_open" or "fold_closed")
        local text = p.open and "thinking" or ("thought for " .. plural(p.lines, "line"))
        return { { glyph .. " " .. text, "ConduitThinking" } }
    end,
})

---Marker left on the range of a collapsed answer. No props.
define({
    name = "AnswerMarker",
    render = function()
        return { { " " .. hl.glyph("marker"), "ConduitAnswerMarker" } }
    end,
})

---Strip markdown markup that virtual text can't render.
---@param line string
---@return string
local function plain(line)
    line = line:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1"):gsub("`([^`]+)`", "%1")
    return (line:gsub("^#+%s+", ""))
end

---A short answer as virtual lines behind a thin bar. Props: `text`, `indent`.
define({
    name = "VirtLines",
    render = function(p)
        local lines = {} ---@type conduit.Spans[]
        local fence = false
        for _, line in ipairs(vim.split(vim.trim(p.text), "\n", { plain = true })) do
            if line:match("^%s*```") then
                fence = not fence
            else
                lines[#lines + 1] = {
                    { p.indent or "" },
                    { hl.glyph("bar") .. " ", "ConduitRule" },
                    { fence and line or plain(line), "ConduitAnswerVirt" },
                }
            end
        end
        return lines
    end,
})

---An answer shown without focus: virtual lines when short. The float itself is
---drawn by `conduit.ui.answer` (it holds markdown, not spans). Props: `text`, `indent`.
define({
    name = "AnswerPeek",
    render = function(p)
        return component.render("VirtLines", p)
    end,
})

---@param seconds integer
---@return string
local function age(seconds)
    if seconds < 60 then
        return "now"
    elseif seconds < 3600 then
        return ("%dm"):format(seconds / 60)
    elseif seconds < 86400 then
        return ("%dh"):format(seconds / 3600)
    end
    return ("%dd"):format(seconds / 86400)
end
M.age = age

---One inline history entry. Props: `entry` (`conduit.InlineEntry`), `now`, `cursor?`.
define({
    name = "HistoryLine",
    render = function(p)
        local e = p.entry ---@type conduit.InlineEntry
        local glyph = hl.glyph(e.kind == "edit" and "edit" or "answer")
        local where = ("%s:%d"):format(vim.fn.fnamemodify(e.file, ":~:."), e.line1)
        local prompt = (e.prompt:gsub("\n.*", ""))
        local outcome = e.outcome and e.outcome ~= "pending" and (" " .. e.outcome) or ""
        return {
            { " " .. glyph .. " ", e.kind == "edit" and "ConduitHistoryEdit" or "ConduitHistoryAnswer" },
            { where .. "  ", "ConduitContext" },
            { prompt, p.cursor and "ConduitPickerCursor" or nil },
            { outcome, "ConduitMuted" },
            { "  " .. age(math.max(0, p.now - e.time)), "ConduitMuted" },
        }
    end,
})

return M
