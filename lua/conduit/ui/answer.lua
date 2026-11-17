--- Inline answer windows. `M.peek` is the default view: a markdown float that
--- never takes focus (unless asked), placed right of the code when there's room,
--- else under it. `M.open` is the legacy view (`inline.answer = "float"`): a
--- focused, titled float under the range.
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
    return M.last_code_block(self:text())
end

function Answer:close()
    if self:is_open() then
        vim.api.nvim_win_close(self.win, true)
    end
end

---The last fenced code block in markdown `text`, if any.
---@param text string
---@return string[]?
function M.last_code_block(text)
    local code
    for body in text:gmatch("```[^\n]*\n(.-)\n```") do
        code = body
    end
    return code and vim.split(code, "\n", { plain = true })
end

local peek_ns = vim.api.nvim_create_namespace("conduit.answer.peek")

---@class conduit.PeekAnchor
---@field win fun(): integer? Window showing the code (looked up on every layout)
---@field range fun(): integer?, integer? 0-based first and last rows

---@class conduit.PeekOpts
---@field anchor conduit.PeekAnchor
---@field keys? table<string, fun()> Normal-mode keys, active while focused
---@field on_leave? fun() The focused float lost focus
---@field on_closed? fun() The window was closed by something else (`:q`, `<C-w>o`)

---A markdown float shown without focus. The buffer outlives the window, so the
---answer can hide and come back.
---@class conduit.Peek
---@field buf integer
---@field win? integer
---@field opts conduit.PeekOpts
---@field focused boolean
---@field closing? boolean
local Peek = {}
Peek.__index = Peek

---@param opts conduit.PeekOpts
---@return conduit.Peek
function M.peek(opts)
    hl.setup()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "conduit"
    vim.diagnostic.enable(false, { bufnr = buf })
    pcall(vim.treesitter.start, buf, "markdown")
    vim.bo[buf].modifiable = false
    require("conduit.ui.render").attach(buf)
    for lhs, fn in pairs(opts.keys or {}) do
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "conduit answer" })
    end
    local self = setmetatable({ buf = buf, opts = opts, focused = false }, Peek)
    vim.api.nvim_create_autocmd("WinLeave", {
        buffer = buf,
        callback = function()
            if self.focused then
                self.focused = false
                -- After the window switch, so the callback sees where focus went.
                vim.schedule(function()
                    if self:is_open() then
                        -- Back out of <C-w>w's way.
                        vim.api.nvim_win_set_config(assert(self.win), { focusable = false })
                    end
                    if opts.on_leave then
                        opts.on_leave()
                    end
                end)
            end
        end,
    })
    return self
end

function Peek:is_open()
    return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---Replace the text.
---@param text string
function Peek:set_text(text)
    if not vim.api.nvim_buf_is_valid(self.buf) then
        return
    end
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.bo[self.buf].modifiable = false
    require("conduit.ui.render").refresh(self.buf)
    if self:is_open() then
        self:_layout()
    end
end

---@return string
function Peek:text()
    return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
end

---Where the float goes: right of the visible code when the window has room for
---a float of at least `ui.inline.width.min`, else under the range.
---@return vim.api.keyset.win_config?
function Peek:_placement()
    local win = self.opts.anchor.win()
    local first, last = self.opts.anchor.range()
    if not win or not vim.api.nvim_win_is_valid(win) or not first or not last then
        return nil
    end
    local limits = require("conduit.config").options.ui.inline.width
    local info = vim.fn.getwininfo(win)[1]
    local code_buf = vim.api.nvim_win_get_buf(win)
    local longest = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(code_buf, info.topline - 1, info.botline, false)) do
        longest = math.max(longest, vim.fn.strdisplaywidth(line))
    end
    local free = info.width - info.textoff - longest - 4
    if free >= limits.min then
        return {
            relative = "win",
            win = win,
            bufpos = { first, 0 },
            row = 0,
            col = longest + 3,
            width = math.min(limits.max, free),
        }
    end
    return { relative = "win", win = win, bufpos = { last, 0 }, row = 1, col = 0, width = hl.width(win) }
end

---Size the window to the text (up to `ui.inline.max_height` unfocused) and keep
---the end of the text in view.
function Peek:_layout()
    local win = assert(self.win)
    local max = require("conduit.config").options.ui.inline.max_height
    if self.focused then
        max = math.max(max, math.floor(vim.o.lines * 0.5))
    end
    local height = vim.api.nvim_win_text_height(win, {}).all
    vim.api.nvim_win_set_height(win, math.max(1, math.min(max, height)))
    vim.api.nvim_buf_clear_namespace(self.buf, peek_ns, 0, -1)
    if not self.focused then
        local last = vim.api.nvim_buf_line_count(self.buf)
        vim.api.nvim_win_set_cursor(win, { last, 0 })
        local hidden = height - vim.api.nvim_win_get_height(win)
        if hidden > 0 then
            -- The view follows the end, so what doesn't fit is above.
            local top = vim.fn.getwininfo(win)[1].topline
            vim.api.nvim_buf_set_extmark(self.buf, peek_ns, top - 1, 0, {
                virt_text = { { ("+%d lines"):format(hidden), "ConduitMuted" } },
                virt_text_pos = "right_align",
            })
        end
    end
end

---Show the float, entering it when `focus`.
---@param focus? boolean
function Peek:show(focus)
    local placement = self:_placement()
    if not placement then
        return
    end
    local cfg = vim.tbl_extend("force", placement, {
        height = 1,
        style = "minimal",
        border = hl.content_border(),
        -- Out of <C-w>w's way unless it's being focused on purpose.
        focusable = focus or false,
        zindex = 40,
    })
    if self:is_open() then
        cfg.style = nil
        vim.api.nvim_win_set_config(assert(self.win), cfg)
    else
        self.win = vim.api.nvim_open_win(self.buf, false, cfg)
        local win = self.win
        vim.wo[win].wrap = true
        vim.wo[win].linebreak = true
        vim.wo[win].conceallevel = 2
        vim.wo[win].winhighlight = "NormalFloat:ConduitAnswer,FloatBorder:ConduitBorder,FloatTitle:ConduitTitle"
        vim.api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(win),
            once = true,
            callback = function()
                if self.win == win then
                    self.win, self.focused = nil, false
                    if not self.closing and self.opts.on_closed then
                        vim.schedule(self.opts.on_closed)
                    end
                end
            end,
        })
    end
    self.focused = focus or false
    self:_layout()
    if focus then
        vim.api.nvim_set_current_win(assert(self.win))
    end
end

---Close the window, keeping the text.
function Peek:hide()
    if self:is_open() then
        self.closing = true
        vim.api.nvim_win_close(assert(self.win), true)
        self.closing = false
    end
    self.win, self.focused = nil, false
end

function Peek:destroy()
    self:hide()
    if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
    end
end

return M
