--- Handlers for the ACP `fs/*` client methods. Loaded buffers take precedence
--- over the disk so agents see (and edit) what the user sees.
local M = {}

---Normalized path with symlinks resolved: Neovim names buffers by their real
---path, while agents may send one through a symlink (e.g. macOS's /var). A
---file that doesn't exist yet resolves through its directory, so it keeps the
---same name once it's created.
---@param path string
---@return string
function M.canonical(path)
    path = vim.fs.normalize(path)
    local real = vim.uv.fs_realpath(path)
    if real then
        return real
    end
    local dir = vim.uv.fs_realpath(vim.fs.dirname(path))
    return dir and vim.fs.joinpath(dir, vim.fs.basename(path)) or path
end
local canonical = M.canonical

---The loaded buffer for `path`, if any.
---@param path string
---@return integer?
function M.find_buf(path)
    path = canonical(path)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if vim.api.nvim_buf_is_loaded(buf) and name ~= "" and canonical(name) == path then
            return buf
        end
    end
end

---@param params { path: string, line?: integer, limit?: integer }
---@return table?, table?
function M.read(params)
    local content
    local buf = M.find_buf(params.path)
    if buf then
        content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        if vim.bo[buf].eol then
            content = content .. "\n"
        end
    else
        local f = io.open(params.path, "r")
        if not f then
            return nil, { code = -32002, message = "Resource not found: " .. params.path }
        end
        content = f:read("*a")
        f:close()
    end

    if params.line or params.limit then
        local lines = vim.split(content, "\n", { plain = true })
        local first = params.line or 1
        local last = params.limit and (first + params.limit - 1) or #lines
        content = table.concat(vim.list_slice(lines, first, last), "\n")
    end
    return { content = content }
end

---@param params { path: string, content: string }
---@return table?, table?
function M.write(params)
    local buf = M.find_buf(params.path)
    if buf then
        local lines = vim.split(params.content, "\n", { plain = true })
        if lines[#lines] == "" then
            table.remove(lines)
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        -- Lets inline edits notice the agent rewrote the file under them.
        vim.b[buf].conduit_writes = (vim.b[buf].conduit_writes or 0) + 1
        local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd("silent write!")
        end)
        if not ok then
            return nil, { code = -32603, message = tostring(err) }
        end
        return nil
    end

    vim.fn.mkdir(vim.fs.dirname(params.path), "p")
    local f, err = io.open(params.path, "w")
    if not f then
        return nil, { code = -32603, message = tostring(err) }
    end
    f:write(params.content)
    f:close()
    return nil
end

return M
