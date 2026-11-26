--- conduit's built-in components. Each is a pure function of its props; see
--- `conduit.ui.component` for how they are rendered and mounted.
local component = require("conduit.ui.component")
local hl = require("conduit.ui.hl")

local define = component.define
local M = {}

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

local KIND_HL = { answer = "ConduitHistoryAnswer", edit = "ConduitHistoryEdit", change = "ConduitHistoryChange" }

---One history entry. Props: `entry` (`conduit.HistoryEntry`), `now`, `cursor?`.
define({
    name = "HistoryLine",
    render = function(p)
        local e = p.entry ---@type conduit.HistoryEntry
        local glyph = hl.glyph(e.kind)
        local name = e.file ~= "" and vim.fn.fnamemodify(e.file, ":~:.") or "[No Name]"
        local where = e.kind == "change" and name or ("%s:%d"):format(name, e.line1 or 1)
        local prompt = (e.prompt:gsub("\n.*", ""))
        if e.kind == "change" then
            local what = e.created and "created" or e.deleted_file and "deleted" or "changed"
            prompt = prompt ~= "" and ("%s · %s"):format(what, prompt) or what
        end
        local outcome = e.outcome and e.outcome ~= "pending" and (" " .. e.outcome) or ""
        return {
            { " " .. glyph .. " ", KIND_HL[e.kind] or "ConduitHistoryAnswer" },
            { where .. "  ", "ConduitContext" },
            { prompt, p.cursor and "ConduitPickerCursor" or nil },
            { outcome, "ConduitMuted" },
            { "  " .. age(math.max(0, p.now - e.time)), "ConduitMuted" },
        }
    end,
})

return M
