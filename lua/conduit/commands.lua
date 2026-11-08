--- Agent slash commands (`/review`, `/compact`, ...). Agents advertise them with
--- `available_commands_update`; running one is just sending a prompt that
--- starts with `/name`. This module completes them at the start of a prompt
--- buffer and shows the command's input hint as ghost text.
local M = {}

local ns = vim.api.nvim_create_namespace("conduit.commands")

---Per-buffer command lists. Functions, because the session (and so the list)
---often doesn't exist yet when the buffer is created.
---@type table<integer, fun(): conduit.Command[]>
local sources = {}

---Commands available in `buf`.
---@param buf integer
---@return conduit.Command[]
function M.list(buf)
    local source = sources[buf]
    if not source then
        return {}
    end
    local ok, list = pcall(source)
    return ok and type(list) == "table" and list or {}
end

---@param buf integer
---@param name string
---@return conduit.Command?
function M.find(buf, name)
    for _, cmd in ipairs(M.list(buf)) do
        if cmd.name == name then
            return cmd
        end
    end
end

---@param cmd conduit.Command
---@return string?
function M.hint(cmd)
    local hint = type(cmd.input) == "table" and cmd.input.hint
    return type(hint) == "string" and hint ~= "" and hint or nil
end

---If a command name is being typed at the very start of the prompt, return
---the 1-based byte index of its `/` and the text typed after it.
---@param before string Text before the cursor on its line
---@param row integer 0-based line of the cursor
---@return integer?, string?
function M.query(before, row)
    if row ~= 0 then
        return nil
    end
    local query = before:match("^/([^%s/]*)$")
    if query then
        return 1, query
    end
end

---Split prompt text into a command name and its arguments, if it starts with one.
---@param text string
---@return string? name, string? args
function M.parse(text)
    local name, args = text:match("^/([^%s/]+)%s*(.*)$")
    if name then
        return name, args
    end
end

---Commands matching `query`, best first: prefix matches in the agent's order,
---then other fuzzy matches.
---@param buf integer
---@param query string
---@return conduit.Command[]
function M.items(buf, query)
    local list = M.list(buf)
    if query == "" then
        return list
    end
    local q = query:lower()
    local out, seen = {}, {}
    for _, cmd in ipairs(list) do
        if vim.startswith(cmd.name:lower(), q) then
            table.insert(out, cmd)
            seen[cmd.name] = true
        end
    end
    local rest = vim.tbl_filter(function(cmd)
        return not seen[cmd.name]
    end, list)
    vim.list_extend(out, vim.fn.matchfuzzy(rest, query, { key = "name" }))
    return out
end

---Show the input hint after `/name ` while no arguments have been typed.
---@param buf integer
function M.update_hint(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 2, false)
    local name, space = (lines[1] or ""):match("^/([^%s/]+)(%s*)$")
    if not name or #lines > 1 then
        return
    end
    local cmd = M.find(buf, name)
    local hint = cmd and M.hint(cmd)
    if hint then
        vim.api.nvim_buf_set_extmark(buf, ns, 0, #lines[1], {
            virt_text = { { (space == "" and " " or "") .. hint, "ConduitPlaceholder" } },
            virt_text_pos = "inline",
        })
    end
end

---Offer `source`'s commands in `buf` and show input hints as you type.
---@param buf integer
---@param source fun(): conduit.Command[]
function M.attach(buf, source)
    require("conduit.ui.hl").setup()
    sources[buf] = source
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
        buffer = buf,
        callback = function()
            M.update_hint(buf)
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            sources[buf] = nil
        end,
    })
end

return M
