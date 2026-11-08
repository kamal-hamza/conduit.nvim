--- Tool calls in the chat transcript: a status line, the files the call touched
--- and a preview of its content (diffs and output), expandable in place.
--- Pure formatting: turns ACP tool call state into lines; `conduit.Chat` owns the buffer.
local M = {}

---@class conduit.ToolDiff ACP `ToolCallContent` of type "diff"
---@field type "diff"
---@field path string
---@field oldText? string Absent (JSON null) when the call creates the file
---@field newText string

---@class conduit.ToolFormatOpts
---@field expanded? boolean Show everything, without the preview limits
---@field cwd? string Paths under it are shown relative to it
---@field diff_lines integer Most diff lines in a collapsed preview
---@field output_lines integer Most output lines in a collapsed preview
---@field hide_output table<string, boolean> Tool kinds whose output is hidden until expanded

local STATUS_ICONS = {
    pending = "○",
    in_progress = "◐",
    completed = "✓",
    failed = "✗",
}

-- Locations listed in a collapsed block (search hits can be many).
local MAX_LOCATIONS = 5

---@param content? table ACP ContentBlock
---@param link_resources? boolean Show embedded resources as links (e.g. replayed @mentions)
---@return string
function M.content_text(content, link_resources)
    if not content then
        return ""
    elseif content.type == "text" then
        return content.text or ""
    elseif content.type == "resource_link" then
        return ("[%s](%s)"):format(content.name or content.uri, content.uri)
    elseif content.type == "resource" and content.resource then
        local uri = content.resource.uri or ""
        if link_resources then
            return ("\n[%s](%s)"):format(uri:match("[^/]+/?$") or uri, uri)
        end
        return content.resource.text or ("<%s>"):format(uri)
    elseif content.type == "image" then
        local uri = content.uri
        local text = "[image]"
        if type(uri) == "string" and uri ~= "" then
            text = ("[image: %s](%s)"):format(uri:match("[^/]+$") or uri, uri)
        end
        return link_resources and "\n" .. text or text
    end
    return ("<%s>"):format(content.type or "unknown")
end

---The status line: icon and the first line of the title.
---@param tool table
---@return string
function M.header(tool)
    local title = tool.title or tool.kind or "tool call"
    -- Titles can span lines (e.g. a multi-line shell command); show the first.
    local first = title:match("^[^\n]*")
    if first ~= title then
        first = first .. " …"
    end
    return ("%s %s"):format(STATUS_ICONS[tool.status or "pending"] or "•", first)
end

---@param path string
---@param cwd? string
---@return string
function M.relpath(path, cwd)
    if cwd and cwd ~= "" then
        local prefix = cwd:gsub("/$", "") .. "/"
        if path:sub(1, #prefix) == prefix then
            return path:sub(#prefix + 1)
        end
    end
    return vim.fn.fnamemodify(path, ":~")
end

---Split text into lines, dropping carriage returns and one trailing newline.
---@param text string
---@return string[]
local function split(text)
    local lines = vim.split((text:gsub("\r", "")), "\n", { plain = true })
    if #lines > 1 and lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end
M.split = split

---The diff entries of a tool call.
---@param tool table
---@return conduit.ToolDiff[]
function M.diffs(tool)
    local out = {}
    for _, entry in ipairs(type(tool.content) == "table" and tool.content or {}) do
        if type(entry) == "table" and entry.type == "diff" and type(entry.path) == "string" then
            table.insert(out, entry)
        end
    end
    return out
end

-- Unified diffs keyed by the entry they came from. `content` is replaced (never
-- mutated) by updates, so a status-only update reuses the cached diff.
---@class conduit.ToolDiffStats
---@field lines string[] Unified diff hunks
---@field added integer
---@field removed integer
---@field new_file boolean

---@type table<conduit.ToolDiff, conduit.ToolDiffStats|nil>
local diff_cache = setmetatable({}, { __mode = "k" })

---@param text? string
---@return string
local function with_newline(text)
    if type(text) ~= "string" or text == "" then
        return ""
    end
    -- Without it, the diff reports "\ No newline at end of file".
    return text:sub(-1) == "\n" and text or text .. "\n"
end

---@param entry conduit.ToolDiff
---@return conduit.ToolDiffStats
function M.diff(entry)
    local cached = diff_cache[entry]
    if cached then
        return cached
    end
    local new_file = type(entry.oldText) ~= "string"
    -- `vim.diff` became `vim.text.diff` in Neovim 0.12; 0.11 only has the old name
    -- (rawget: naming it directly is flagged as deprecated).
    local diff_fn = vim.text.diff or rawget(vim, "diff")
    local hunks = diff_fn(with_newline(entry.oldText), with_newline(entry.newText), {
        result_type = "unified",
        ctxlen = 3,
    }) --[[@as string]]
    local lines = hunks == "" and {} or split(hunks)
    local added, removed = 0, 0
    for _, line in ipairs(lines) do
        local c = line:sub(1, 1)
        if c == "+" then
            added = added + 1
        elseif c == "-" then
            removed = removed + 1
        end
    end
    local result = { lines = lines, added = added, removed = removed, new_file = new_file }
    diff_cache[entry] = result
    return result
end

---If `text` is exactly one fenced code block, return its body and info string.
---Agents often fence their output already (Claude: ```console). Re-fencing it
---ourselves lets the preview be cut safely: a cut that dropped the closing fence
---would leave the rest of the transcript inside a code block.
---@param lines string[]
---@return string[] body, string lang
local function unwrap(lines)
    local n = #lines
    while n > 0 and vim.trim(lines[n] or "") == "" do
        n = n - 1
    end
    local fence, info = (lines[1] or ""):match("^%s*(```+)%s*([^`]*)$")
    if not fence or n < 2 or vim.trim(lines[n] or "") ~= fence then
        return lines, ""
    end
    local closing = "^%s*" .. ("`"):rep(#fence) .. "`*%s*$"
    for i = 2, n - 1 do
        if (lines[i] or ""):match(closing) then
            return lines, ""
        end
    end
    return vim.list_slice(lines, 2, n - 1), vim.trim(info or "")
end

---Wrap `body` in a fence longer than any run of backticks inside it.
---@param out string[]
---@param body string[]
---@param lang string
local function fenced(out, body, lang)
    local longest = 2
    for _, line in ipairs(body) do
        for run in line:gmatch("`+") do
            longest = math.max(longest, #run)
        end
    end
    local fence = ("`"):rep(longest + 1)
    table.insert(out, fence .. lang)
    vim.list_extend(out, body)
    table.insert(out, fence)
end

---Take up to `budget` lines (all of them when `budget` is nil).
---@param lines string[]
---@param budget? integer
---@return string[] shown, integer hidden
local function take(lines, budget)
    if not budget or #lines <= budget then
        return lines, 0
    end
    return vim.list_slice(lines, 1, budget), #lines - budget
end

---@param n integer
---@param one string Noun for a single line
---@param many string Noun for several
---@param verb string
---@return string
local function hint(n, one, many, verb)
    return ("… %d %s (`<CR>` to %s)"):format(n, n == 1 and one or many, verb)
end

---The tool call as transcript lines: status line, locations, diffs and output.
---@param tool table Accumulated `tool_call` + `tool_call_update` fields
---@param opts conduit.ToolFormatOpts
---@return string[]
function M.lines(tool, opts)
    local out = { M.header(tool) }
    local expanded = opts.expanded
    local diffs = M.diffs(tool)

    local diffed = {}
    for _, d in ipairs(diffs) do
        diffed[d.path] = true
    end
    local locs = {}
    for _, loc in ipairs(type(tool.locations) == "table" and tool.locations or {}) do
        if type(loc) == "table" and type(loc.path) == "string" and not diffed[loc.path] then
            local s = M.relpath(loc.path, opts.cwd)
            if type(loc.line) == "number" then
                s = ("%s:%d"):format(s, loc.line)
            end
            table.insert(locs, "`" .. s .. "`")
        end
    end
    if #locs > 0 then
        local shown, more = take(locs, not expanded and MAX_LOCATIONS or nil)
        local line = "→ " .. table.concat(shown, ", ")
        table.insert(out, more > 0 and ("%s +%d more"):format(line, more) or line)
    end

    local diff_budget = not expanded and opts.diff_lines or nil
    local hidden_diff = 0
    for _, entry in ipairs(diffs) do
        local d = M.diff(entry)
        local path = M.relpath(entry.path, opts.cwd)
        local stats = d.new_file and ("new file, +%d"):format(d.added) or ("+%d −%d"):format(d.added, d.removed)
        if #d.lines == 0 then
            stats = "no changes"
        end
        table.insert(out, ("`%s` (%s)"):format(path, stats))
        local shown, hidden = take(d.lines, diff_budget)
        if #shown > 0 then
            fenced(out, shown, "diff")
        end
        hidden_diff = hidden_diff + hidden
        if diff_budget then
            diff_budget = diff_budget - #shown
        end
    end
    if hidden_diff > 0 then
        table.insert(out, hint(hidden_diff, "more diff line", "more diff lines", "expand"))
    end

    local hide = not expanded and tool.kind and opts.hide_output[tool.kind]
    local out_budget = not expanded and (hide and 0 or opts.output_lines) or nil
    local hidden_out = 0
    for _, entry in ipairs(type(tool.content) == "table" and tool.content or {}) do
        if type(entry) == "table" and entry.type == "content" then
            local text = M.content_text(entry.content)
            if vim.trim(text) ~= "" then
                local body, lang = unwrap(split(text))
                local shown, hidden = take(body, out_budget)
                if #shown > 0 then
                    fenced(out, shown, lang)
                end
                hidden_out = hidden_out + hidden
                if out_budget then
                    out_budget = out_budget - #shown
                end
            end
        end
    end
    if hidden_out > 0 then
        if hide or opts.output_lines <= 0 then
            table.insert(out, hint(hidden_out, "line of output", "lines of output", "show"))
        else
            table.insert(out, hint(hidden_out, "more line", "more lines", "expand"))
        end
    end
    return out
end

return M
