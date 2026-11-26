--- The answer sidebar: a read-only split that shows one conversation, either an
--- inline answer as it streams in or an entry from the history. It's where
--- explanations go; edits happen in the file itself. It never takes focus on
--- its own (`:Conduit answer` or `<C-w>` gets you in).
local config = require("conduit.config")
local hl = require("conduit.ui.hl")

---@class conduit.SidebarSource
---@field job? conduit.InlineJob A live inline request
---@field entry? conduit.HistoryEntry A history entry

---@class conduit.Sidebar
---@field buf? integer
---@field win? integer
---@field source conduit.SidebarSource
local M = { source = {} }

local HELP = {
    { "f", "ask a follow-up (continues a history entry in a new session)" },
    { "a", "replace the request's lines with the answer's last code block" },
    { "gf", "go to the request's lines" },
    { "[[, ]]", "older / newer answer from the history" },
    { "gh", "browse the history" },
    { "<C-c>", "cancel the reply" },
    { "q", "close the sidebar" },
}

---The last fenced code block in markdown `text`, if any.
---@param text string
---@return string[]?
function M.last_code_block(text)
    local code ---@type string?
    for body in text:gmatch("```[^\n]*\n(.-)\n```") do
        code = body
    end
    return code and vim.split(code, "\n", { plain = true })
end

---@return boolean
function M.is_open()
    return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

---The text shown for the current source.
---@return string
local function text()
    local src = M.source
    if src.job then
        return src.job:_display()
    elseif src.entry then
        return require("conduit.history").markdown(src.entry)
    end
    return ""
end

---Answer entries of the history, newest first, for `[[` and `]]`.
---@return conduit.HistoryEntry[]
local function answers()
    return vim.tbl_filter(function(e)
        return e.kind == "answer"
    end, require("conduit.history").load())
end

---Step `count` answers back (positive) or forward through the history.
---@param count integer
local function step(count)
    local list = answers()
    if #list == 0 then
        return vim.notify("[conduit] no answers in the history", vim.log.levels.INFO)
    end
    local src = M.source
    local id = src.entry and src.entry.id or (src.job and src.job.history_id)
    local at = 0
    for i, e in ipairs(list) do
        if e.id == id then
            at = i
            break
        end
    end
    local target = list[math.max(1, math.min(#list, at + count))]
    if target then
        M.show({ entry = target })
    end
end

---@param buf integer
local function map_keys(buf)
    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "conduit: " .. desc })
    end
    map("q", M.close, "close the sidebar")
    map("f", function()
        local src = M.source
        if src.job then
            src.job:follow_up()
        elseif src.entry then
            require("conduit.inline").continue(src.entry)
        end
    end, "follow up")
    map("a", function()
        local job = M.source.job
        if not job then
            return vim.notify("[conduit] open the answer's request to apply code from it", vim.log.levels.INFO)
        end
        job:apply_code()
    end, "apply the last code block")
    map("gf", function()
        local src = M.source
        local origin = M.code_win()
        if src.job then
            require("conduit.inline").reveal(src.job, origin)
        elseif src.entry then
            require("conduit.history").jump(src.entry, origin)
        end
    end, "go to the request")
    map("<C-c>", function()
        if M.source.job then
            M.source.job:cancel()
        end
    end, "cancel the reply")
    map("[[", function()
        step(vim.v.count1)
    end, "older answer")
    map("]]", function()
        step(-vim.v.count1)
    end, "newer answer")
    map("gh", function()
        require("conduit").history()
    end, "browse the history")
    map("g?", function()
        require("conduit.ui.help_float").open("conduit sidebar", HELP)
    end, "show keys")
end

---@return integer
local function ensure_buf()
    if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
        return M.buf
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    -- Parsed as markdown (see plugin/conduit.lua) without markdown's linters and LSPs.
    vim.bo[buf].filetype = "conduit"
    vim.bo[buf].modifiable = false
    pcall(vim.api.nvim_buf_set_name, buf, "conduit://answer")
    vim.diagnostic.enable(false, { bufnr = buf })
    map_keys(buf)
    require("conduit.ui.render").attach(buf)
    M.buf = buf
    return buf
end

---A normal window that isn't the sidebar, to go back to.
---@return integer
function M.code_win()
    local job = M.source.job
    local win = job and job:_code_win()
    if win then
        return win
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= M.win and vim.fn.win_gettype(w) == "" then
            return w
        end
    end
    return vim.api.nvim_get_current_win()
end

---@return integer
local function width()
    local w = config.options.ui.sidebar.width
    if w <= 1 then
        w = math.floor(vim.o.columns * w)
    end
    return math.max(20, math.min(math.floor(w), vim.o.columns - 20))
end

---Open the window (without entering it) if it isn't open.
local function open_win()
    if M.is_open() then
        return
    end
    hl.setup()
    local buf = ensure_buf()
    local right = config.options.ui.sidebar.position ~= "left"
    local win = vim.api.nvim_open_win(buf, false, {
        split = right and "right" or "left",
        win = -1,
        width = width(),
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].conceallevel = 2
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].spell = false
    vim.wo[win].winfixwidth = true
    vim.wo[win].cursorline = false
    M.win = win
end

---Redraw the winbar: agent, what it's doing, and the key hint.
function M.status()
    if not M.is_open() then
        return
    end
    local src = M.source
    local spans = {} ---@type conduit.Spans
    local job = src.job
    if job then
        spans[#spans + 1] = { " " .. job.agent.name, "ConduitAgent" }
        if job.busy then
            spans[#spans + 1] = { " " .. job.spinner:frame() .. " ", "ConduitSpinner" }
            spans[#spans + 1] = { job.phase or "working", "ConduitMuted" }
        end
    elseif src.entry then
        spans[#spans + 1] = { " history", "ConduitAgent" }
        spans[#spans + 1] = { " " .. os.date("%Y-%m-%d %H:%M", src.entry.time), "ConduitMuted" }
    end
    spans[#spans + 1] = { "%=", raw = true }
    spans[#spans + 1] = { "g? keys ", "ConduitMuted" }
    vim.wo[assert(M.win)].winbar = require("conduit.ui.surface").statusline(spans)
end

---Put the current text in the buffer. Follows the end while the sidebar isn't focused.
function M.render()
    local buf = M.buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local lines = vim.split(text(), "\n", { plain = true })
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    require("conduit.ui.render").refresh(buf)
    local win = M.win
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
        local job = M.source.job
        local row = job and job.busy and #lines or 1
        pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
    end
    M.status()
end

---Show a live request or a history entry. The previous request, if it's done,
---is closed (its session ends; it stays in the history).
---@param source conduit.SidebarSource
---@param opts? { focus?: boolean }
function M.show(source, opts)
    local prev = M.source.job
    M.source = source
    if prev and prev ~= source.job then
        if prev.busy then
            -- Let it finish in the background; it still lands in the history.
            prev.detached = true
        else
            prev:close()
        end
    end
    ensure_buf()
    open_win()
    M.render()
    if opts and opts.focus and M.win then
        vim.api.nvim_set_current_win(M.win)
    end
end

---Redraw if `job` is what the sidebar shows.
---@param job conduit.InlineJob
function M.update(job)
    if M.source.job == job then
        M.render()
    end
end

---Focus the sidebar, opening it on the latest answer if needed.
---@return boolean focused
function M.focus()
    if not M.is_open() then
        if not M.source.job and not M.source.entry then
            local latest = answers()[1]
            if not latest then
                vim.notify("[conduit] no answer to show", vim.log.levels.INFO)
                return false
            end
            M.source = { entry = latest }
        end
        ensure_buf()
        open_win()
        M.render()
    end
    vim.api.nvim_set_current_win(assert(M.win))
    return true
end

function M.close()
    if M.is_open() then
        local win = assert(M.win)
        if #vim.api.nvim_tabpage_list_wins(0) > 1 then
            vim.api.nvim_win_close(win, true)
        else
            vim.cmd.enew()
        end
    end
    M.win = nil
end

---Open on the latest answer, or close.
function M.toggle()
    if M.is_open() then
        return M.close()
    end
    if M.source.job or M.source.entry then
        ensure_buf()
        open_win()
        return M.render()
    end
    local latest = answers()[1]
    if not latest then
        return vim.notify("[conduit] no answer to show", vim.log.levels.INFO)
    end
    M.show({ entry = latest })
end

---Forget everything (tests).
function M.reset()
    M.close()
    local job = M.source.job
    M.source = {}
    if job and not job.busy then
        job:close()
    end
    if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
        vim.api.nvim_buf_delete(M.buf, { force = true })
    end
    M.buf = nil
end

return M
