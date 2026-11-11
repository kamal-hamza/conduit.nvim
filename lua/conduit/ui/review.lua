--- The review overlay in a file's buffer: the agent's lines highlighted, the
--- lines it removed shown as virtual lines, and buffer-local keys to move between
--- hunks and accept or reject them. Owned by `conduit.review`.
local M = {}

local ns = vim.api.nvim_create_namespace("conduit.review")

-- Recompute this long after the last edit in a reviewed buffer.
local DEBOUNCE_MS = 80

---@class conduit.ReviewKeys
---@field next? string|false
---@field prev? string|false
---@field accept? string|false
---@field reject? string|false
---@field accept_file? string|false
---@field reject_file? string|false

---Buffers showing the overlay: the user's buffer-local maps we replaced, to restore.
---@type table<integer, { saved: table[], lhs: string[] }>
local attached = {}

local pending = {} ---@type table<integer, true?>

---@return conduit.ReviewKeys
local function keys()
    return require("conduit.config").options.review.keys or {}
end

---@param buf integer
---@return string?
local function path_of(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    return name ~= "" and require("conduit.fs").canonical(name) or nil
end

---Lines as virtual lines, padded so the highlight reads as whole lines.
---@param buf integer
---@param lines string[]
---@return [string, string][][]
local function removed(buf, lines)
    local width = vim.o.columns
    local out = {}
    for _, line in ipairs(lines) do
        local text = line:gsub("\t", (" "):rep(vim.bo[buf].tabstop))
        local pad = math.max(0, width - vim.fn.strdisplaywidth(text))
        table.insert(out, { { text .. (" "):rep(pad), "ConduitReviewDelete" } })
    end
    return out
end

---@return [string, string][]?
local function hint()
    local k = keys()
    local parts = {}
    if k.accept then
        table.insert(parts, k.accept .. " accept")
    end
    if k.reject then
        table.insert(parts, k.reject .. " reject")
    end
    return #parts > 0 and { { "  " .. table.concat(parts, " · "), "ConduitReviewHint" } } or nil
end

---Draw the file's hunks in `buf`.
---@param buf integer
---@param file conduit.ReviewFile
function M.render(buf, file)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local count = vim.api.nvim_buf_line_count(buf)
    local virt_hint = hint()
    for _, h in ipairs(file.hunks) do
        local old = removed(buf, vim.list_slice(file.baseline, h.old_start, h.old_start + h.old_count - 1))
        if h.new_count > 0 then
            local row = h.new_start - 1
            local group = h.old_count > 0 and "ConduitReviewChange" or "ConduitReviewAdd"
            for r = row, math.min(row + h.new_count, count) - 1 do
                vim.api.nvim_buf_set_extmark(buf, ns, r, 0, {
                    line_hl_group = group,
                    sign_text = "▎",
                    sign_hl_group = "ConduitReviewSign",
                    virt_text = r == row and virt_hint or nil,
                    virt_lines = r == row and #old > 0 and old or nil,
                    virt_lines_above = true,
                })
            end
        elseif #old > 0 then
            -- Only removed lines: show them after the line they followed.
            local above = h.new_start == 0
            local row = math.min(above and 0 or h.new_start - 1, count - 1)
            vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                sign_text = "▁",
                sign_hl_group = "ConduitReviewSign",
                virt_text = virt_hint,
                virt_lines = old,
                virt_lines_above = above,
            })
        end
    end
end

---@param buf integer
---@return conduit.ReviewHunk[]
local function hunks(buf)
    local path = path_of(buf)
    local file = path and require("conduit.review").files[path]
    return file and file.hunks or {}
end

---Move to the next (`dir` 1) or previous (-1) hunk.
---@param dir 1|-1
function M.jump(dir)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local target ---@type integer?
    for _, h in ipairs(hunks(vim.api.nvim_get_current_buf())) do
        local first = math.max(h.new_start, 1)
        if dir > 0 and first > lnum and (not target or first < target) then
            target = first
        elseif dir < 0 and first < lnum and (not target or first > target) then
            target = first
        end
    end
    if target then
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(0, { math.min(target, vim.api.nvim_buf_line_count(0)), 0 })
    end
end

---Accept or reject the hunk at the cursor, or the whole file.
---@param action "accept"|"reject"
---@param whole? boolean
function M.act(action, whole)
    local buf = vim.api.nvim_get_current_buf()
    local path = path_of(buf)
    local review = require("conduit.review")
    if not path or not review.files[path] then
        return vim.notify("[conduit] nothing to review in this buffer", vim.log.levels.INFO)
    end
    local hunk = nil ---@type conduit.ReviewHunk?
    if not whole then
        hunk = review.hunk_at(path, vim.api.nvim_win_get_cursor(0)[1])
        if not hunk then
            return vim.notify("[conduit] no change under the cursor", vim.log.levels.INFO)
        end
    end
    review[action](path, hunk)
end

local ACTIONS = {
    next = {
        "Next agent change",
        function()
            M.jump(1)
        end,
    },
    prev = {
        "Previous agent change",
        function()
            M.jump(-1)
        end,
    },
    accept = {
        "Accept the agent's change",
        function()
            M.act("accept")
        end,
    },
    reject = {
        "Reject the agent's change",
        function()
            M.act("reject")
        end,
    },
    accept_file = {
        "Accept the agent's changes to the file",
        function()
            M.act("accept", true)
        end,
    },
    reject_file = {
        "Reject the agent's changes to the file",
        function()
            M.act("reject", true)
        end,
    },
}

---@param buf integer
local function map(buf)
    local state = { saved = {}, lhs = {} }
    for name, spec in pairs(ACTIONS) do
        local lhs = keys()[name]
        if lhs then
            local existing = vim.fn.maparg(lhs, "n", false, true) --[[@as table]]
            if existing.buffer == 1 then
                table.insert(state.saved, existing)
            end
            vim.keymap.set("n", lhs, spec[2], { buffer = buf, desc = spec[1] })
            table.insert(state.lhs, lhs)
        end
    end
    attached[buf] = state
end

---Show the overlay and keys in `buf` (redrawing if already there).
---@param buf integer
---@param file conduit.ReviewFile
function M.attach(buf, file)
    require("conduit.ui.hl").setup()
    if not attached[buf] then
        vim.api.nvim_buf_call(buf, function()
            map(buf)
        end)
        local group = vim.api.nvim_create_augroup("conduit.review.buf", { clear = false })
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            group = group,
            buffer = buf,
            callback = function()
                if pending[buf] then
                    return
                end
                pending[buf] = true
                vim.defer_fn(function()
                    pending[buf] = nil
                    local path = vim.api.nvim_buf_is_valid(buf) and path_of(buf)
                    if path then
                        require("conduit.review").refresh(path)
                    end
                end, DEBOUNCE_MS)
            end,
        })
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = group,
            buffer = buf,
            callback = function()
                attached[buf] = nil
            end,
        })
    end
    M.render(buf, file)
end

---Remove the overlay and keys from `buf`, restoring maps they replaced.
---@param buf integer
function M.detach(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        attached[buf] = nil
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local state = attached[buf]
    if not state then
        return
    end
    attached[buf] = nil
    pcall(vim.api.nvim_clear_autocmds, { group = "conduit.review.buf", buffer = buf })
    vim.api.nvim_buf_call(buf, function()
        for _, lhs in ipairs(state.lhs) do
            pcall(vim.keymap.del, "n", lhs, { buffer = buf })
        end
        for _, saved in ipairs(state.saved) do
            vim.fn.mapset("n", false, saved)
        end
    end)
end

---Whether `buf` shows the overlay.
---@param buf integer
---@return boolean
function M.attached(buf)
    return attached[buf] ~= nil
end

M.ns = ns

return M
