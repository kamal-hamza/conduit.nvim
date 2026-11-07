--- A floating markdown window anchored under a line of a buffer, for
--- streaming inline answers.
local hl = require("conduit.ui.hl")

local M = {}

---@class conduit.Answer
---@field buf integer
---@field win integer
---@field parent integer Window the float is anchored to
---@field max_height integer
local Answer = {}
Answer.__index = Answer

---@class conduit.AnswerOpts
---@field win integer Window to anchor to
---@field row integer 0-based buffer row to open below
---@field title conduit.Chunks
---@field keys? table<string, fun()> Normal-mode keymaps in the float
---@field on_close? fun()

---@param opts conduit.AnswerOpts
---@return conduit.Answer
function M.open(opts)
    hl.setup()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "conduit"
    vim.diagnostic.enable(false, { bufnr = buf })
    pcall(vim.treesitter.start, buf, "markdown")
    vim.bo[buf].modifiable = false

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "win",
        win = opts.win,
        bufpos = { opts.row, 0 },
        row = 1,
        col = 0,
        width = hl.width(opts.win),
        height = 1,
        style = "minimal",
        border = hl.border(),
        title = opts.title,
        title_pos = "left",
    })
    vim.wo[win].wrap = true
    vim.wo[win].winhighlight = hl.WINHIGHLIGHT
    vim.wo[win].linebreak = true
    vim.wo[win].conceallevel = 2
    require("conduit.ui.render").attach(buf)

    local self = setmetatable({
        buf = buf,
        win = win,
        parent = opts.win,
        max_height = math.max(5, math.floor(vim.o.lines * 0.5)),
    }, Answer)

    for lhs, fn in pairs(opts.keys or {}) do
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "conduit answer" })
    end
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            if opts.on_close then
                vim.schedule(opts.on_close)
            end
        end,
    })
    return self
end

function Answer:is_open()
    return vim.api.nvim_win_is_valid(self.win)
end

---Append streamed text, growing the window and following the end of the text
---while the cursor is on the last line.
---@param text string
function Answer:append(text)
    if text == "" or not vim.api.nvim_buf_is_valid(self.buf) then
        return
    end
    local follow = self:is_open() and vim.api.nvim_win_get_cursor(self.win)[1] == vim.api.nvim_buf_line_count(self.buf)
    vim.bo[self.buf].modifiable = true
    local last = vim.api.nvim_buf_line_count(self.buf) - 1
    local col = #vim.api.nvim_buf_get_lines(self.buf, last, last + 1, false)[1]
    vim.api.nvim_buf_set_text(self.buf, last, col, last, col, vim.split(text, "\n", { plain = true }))
    vim.bo[self.buf].modifiable = false
    require("conduit.ui.render").refresh(self.buf)
    if not self:is_open() then
        return
    end
    local height = vim.api.nvim_win_text_height(self.win, {}).all
    vim.api.nvim_win_set_height(self.win, math.max(1, math.min(self.max_height, height)))
    if follow then
        vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(self.buf), 0 })
    end
end

---@param chunks conduit.Chunks
function Answer:footer(chunks)
    if self:is_open() then
        vim.api.nvim_win_set_config(self.win, { footer = chunks, footer_pos = "right" })
    end
end

---@return string
function Answer:text()
    return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
end

---The last fenced code block in the answer, if any.
---@return string[]?
function Answer:code_block()
    local code
    for body in self:text():gmatch("```[^\n]*\n(.-)\n```") do
        code = body
    end
    return code and vim.split(code, "\n", { plain = true })
end

function Answer:close()
    if self:is_open() then
        vim.api.nvim_win_close(self.win, true)
    end
end

return M
