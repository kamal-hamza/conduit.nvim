local M = {}

---What a permission request is about, pulled out of its tool call.
---@class conduit.PermissionInfo
---@field title string First line of the tool call's title (or a fallback from its kind)
---@field kind? string ACP ToolKind: read, edit, delete, move, search, execute, think, fetch, ...
---@field command? string[] Every line of the command, for tools that run one
---@field paths string[] Affected paths, relative to the cwd or home, with `:line` when known

-- Used when a tool call has no title.
local KIND_TITLES = {
    read = "read a file",
    edit = "edit a file",
    delete = "delete a file",
    move = "move a file",
    search = "search",
    execute = "run a command",
    fetch = "fetch a URL",
    switch_mode = "switch modes",
}

local SHELLS = { sh = true, bash = true, zsh = true, fish = true, dash = true }

---@param s string
---@return string[]
local function split_lines(s)
    local lines = vim.split((s:gsub("\n+$", "")), "\n", { plain = true })
    return lines
end

---The command a tool will run, from its `rawInput`. Agents shape this
---differently: Claude sends a string, Codex an argv list (often `bash -lc script`).
---@param raw any
---@return string[]?
local function command_lines(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local cmd = raw.command
    if type(cmd) == "string" and cmd ~= "" then
        return split_lines(cmd)
    end
    if type(cmd) ~= "table" or #cmd == 0 then
        return nil
    end
    local parts = {} ---@type string[]
    for _, part in ipairs(cmd) do
        if type(part) ~= "string" then
            return nil
        end
        table.insert(parts, part)
    end
    -- `bash -lc 'script'`: the script is what matters.
    local shell = vim.fs.basename(parts[1])
    if #parts == 3 and SHELLS[shell] and (parts[2] == "-c" or parts[2] == "-lc") then
        return split_lines(parts[3])
    end
    return { table.concat(parts, " ") }
end

---@param call table
---@return string[]
local function paths(call)
    local out, seen = {}, {} ---@type string[], table<string, boolean>
    local function add(path, line)
        if type(path) ~= "string" or path == "" then
            return
        end
        local shown = vim.fn.fnamemodify(path, ":~:.")
        if type(line) == "number" then
            shown = ("%s:%d"):format(shown, line)
        end
        if not seen[shown] then
            seen[shown] = true
            table.insert(out, shown)
        end
    end
    for _, loc in ipairs(type(call.locations) == "table" and call.locations or {}) do
        add(loc.path, loc.line)
    end
    if #out == 0 then
        -- No locations: edits still name their file in a diff.
        for _, item in ipairs(type(call.content) == "table" and call.content or {}) do
            if type(item) == "table" and item.type == "diff" then
                add(item.path)
            end
        end
    end
    return out
end

---Describe a tool call for a permission prompt. `call` is the request's
---`toolCall` merged over what's already known about it, since agents often
---send just the id.
---@param call table
---@return conduit.PermissionInfo
function M.describe(call)
    local kind = type(call.kind) == "string" and call.kind or nil
    local title = type(call.title) == "string" and vim.trim(call.title:match("^%s*([^\n]*)")) or ""
    if title == "" then
        title = KIND_TITLES[kind] or "run a tool"
    end
    return { title = title, kind = kind, command = command_lines(call.rawInput), paths = paths(call) }
end

---The prompt text: a header line, then the kind, paths and command.
---@param agent_name string
---@param info conduit.PermissionInfo
---@return string
function M.format(agent_name, info)
    local lines = { ("%s wants to %s"):format(agent_name, info.title) }
    if info.kind then
        table.insert(lines, "kind: " .. info.kind)
    end
    for _, path in ipairs(info.paths) do
        table.insert(lines, "  " .. path)
    end
    for i, line in ipairs(info.command or {}) do
        table.insert(lines, (i == 1 and "$ " or "  ") .. line)
    end
    return table.concat(lines, "\n")
end

---Show a `session/request_permission` request in vim.ui.select.
---@param agent_name string
---@param call table The request's tool call, merged over what's known about it
---@param params table
---@param respond fun(err: table?, result: any)
function M.ask(agent_name, call, params, respond)
    vim.ui.select(params.options or {}, {
        prompt = M.format(agent_name, M.describe(call)),
        format_item = function(option)
            return option.name
        end,
    }, function(choice)
        if choice then
            respond(nil, { outcome = { outcome = "selected", optionId = choice.optionId } })
        else
            respond(nil, { outcome = { outcome = "cancelled" } })
        end
    end)
end

---Merge a permission request's tool call over a known tool call.
---@param known table?
---@param call table?
---@return table
function M.merge(known, call)
    local merged = vim.tbl_extend("force", known or {}, call or {})
    merged.mark = nil
    return merged
end

return M
