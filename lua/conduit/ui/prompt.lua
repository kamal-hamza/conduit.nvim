--- A small floating prompt with `@` mention completion, used instead of
--- vim.ui.input for inline requests.
local hl = require("conduit.ui.hl")

local M = {}

---@alias conduit.InlineMode "auto"|"edit"|"ask"

local modes = { "auto", "edit", "ask" }
local mode_names = { auto = "Auto", edit = "Edit", ask = "Ask" }
local mode_hl = { auto = "ConduitModeAuto", edit = "ConduitModeEdit", ask = "ConduitModeAsk" }

local ns = vim.api.nvim_create_namespace("conduit.prompt")

-- One line of text plus the border: the least room the float needs.
local MIN_ROOM = 3
local MAX_HEIGHT = 8

---@class conduit.PromptAnchor
---@field win integer Window showing the range
---@field first integer 0-based first row of the range
---@field last integer 0-based last row of the range

---@class conduit.PromptOpts
---@field title string Context shown after the agent and mode, e.g. `init.lua:3-5`
---@field agent? string Agent name shown first in the title
---@field mode? conduit.InlineMode Initial mode; omit for a prompt without modes
---@field anchor? conduit.PromptAnchor Range to open next to; defaults to the cursor
---@field commands? fun(): conduit.Command[] Agent commands to complete after a leading `/`
---@field on_submit fun(text: string, mode?: conduit.InlineMode)

---Accept the open completion item, if any.
---@return boolean accepted
local function accept_completion()
    local ok, cmp = pcall(require, "blink.cmp")
    if ok and package.loaded["blink.cmp"] and cmp.is_menu_visible() then
        cmp.accept()
        return true
    end
    if vim.fn.pumvisible() == 1 then
        vim.api.nvim_feedkeys(vim.keycode("<C-y>"), "n", false)
        return true
    end
    return false
end

---A leading `?` forces ask mode and `!` forces edit mode.
---@param text string
---@param mode? conduit.InlineMode
---@return string text, conduit.InlineMode? mode
function M.parse_prefix(text, mode)
    if not mode then
        return text, nil
    end
    local prefix, rest = text:match("^([?!])%s*(.*)$")
    if prefix == "?" then
        return rest or "", "ask"
    elseif prefix == "!" then
        return rest or "", "edit"
    end
    return text, mode
end

---Window-relative screen row (1-based) of 0-based buffer `row`, if visible.
---@param win integer
---@param row integer
---@return integer?
local function win_row(win, row)
    local pos = vim.fn.screenpos(win, row + 1, 1)
    if pos.row == 0 then
        return nil
    end
    return math.floor(pos.row - vim.fn.win_screenpos(win)[1] + 1)
end

---Where to open: under the range, else over it, else at the cursor. Opening
---at the cursor alone often covers the very lines the request is about.
---@param anchor? conduit.PromptAnchor
---@return vim.api.keyset.win_config
function M.placement(anchor)
    if anchor and vim.api.nvim_win_is_valid(anchor.win) then
        local height = vim.api.nvim_win_get_height(anchor.win)
        local below = win_row(anchor.win, anchor.last)
        if below and height - below >= MIN_ROOM then
            return { relative = "win", win = anchor.win, bufpos = { anchor.last, 0 }, row = 1, col = 0 }
        end
        local above = win_row(anchor.win, anchor.first)
        if above and above - 1 >= MIN_ROOM then
            return {
                relative = "win",
                win = anchor.win,
                bufpos = { anchor.first, 0 },
                row = 0,
                col = 0,
                anchor = "SW",
            }
        end
    end
    return { relative = "cursor", row = 1, col = 0 }
end

---@param opts conduit.PromptOpts
---@return integer buf, integer win
function M.open(opts)
    hl.setup()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "conduit_input"
    vim.diagnostic.enable(false, { bufnr = buf })
    pcall(vim.treesitter.start, buf, "markdown")
    require("conduit.mentions").attach(buf, { commands = opts.commands })

    local mode = opts.mode

    ---The mode the request will be sent in, after any `?`/`!` prefix.
    ---@return conduit.InlineMode?
    local function effective_mode()
        local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
        if mode and opts.commands and require("conduit.commands").parse(first) then
            -- Agent commands run as-is and answer in a float (see `inline.run`).
            return "ask"
        end
        return select(2, M.parse_prefix(first, mode))
    end

    ---@return conduit.Chunks
    local function title()
        local chunks = {} ---@type conduit.Chunks
        if opts.agent then
            table.insert(chunks, hl.agent(opts.agent))
        end
        local shown = effective_mode()
        if shown then
            table.insert(chunks, { (" %s "):format(mode_names[shown]), mode_hl[shown] })
        end
        table.insert(chunks, { (" %s "):format(opts.title), "ConduitContext" })
        return chunks
    end

    local help = { { "<CR>", "send (accepts a completion first)" }, { "<S-CR>", "new line" } }
    if mode then
        vim.list_extend(help, {
            { "<C-t>", "cycle mode: Auto, Edit, Ask" },
            { "?", "at the start: ask, answer in a float" },
            { "!", "at the start: edit, rewrite the lines" },
        })
    end
    vim.list_extend(help, {
        { "@", "attach a file, @buffer, @selection, @diagnostics, ..." },
    })
    if opts.commands then
        table.insert(help, { "/", "at the start: run an agent command (/review, ...)" })
    end
    vim.list_extend(help, {
        { "<C-c>", "cancel (insert mode)" },
        { "q, <Esc>", "close (normal mode)" },
    })

    ---@return conduit.Chunks
    local function footer()
        local hints = { { "<CR>", "send" } }
        if mode then
            table.insert(hints, { "<C-t>", "mode" })
        end
        if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
            table.insert(hints, { "<C-c>", "cancel" })
        else
            vim.list_extend(hints, { { "q", "close" }, { "g?", "keys" } })
        end
        return hl.keys(hints)
    end

    local placeholder = mode and "Ask about these lines or describe an edit · @ adds context"
        or "Ask a follow-up · @ adds context"

    local anchor_win = opts.anchor and opts.anchor.win or vim.api.nvim_get_current_win()
    local win_opts = vim.tbl_extend("force", M.placement(opts.anchor), {
        width = hl.width(anchor_win),
        height = 1,
        style = "minimal",
        border = hl.border(),
        title = title(),
        title_pos = "left",
        footer = footer(),
        footer_pos = "right",
    })
    local win = vim.api.nvim_open_win(buf, true, win_opts)
    vim.wo[win].wrap = true
    vim.wo[win].winhighlight = hl.WINHIGHLIGHT

    local shown_mode = effective_mode()
    local function refresh()
        if not vim.api.nvim_win_is_valid(win) then
            return
        end
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        if #lines == 1 and lines[1] == "" then
            vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
                virt_text = { { placeholder, "ConduitPlaceholder" } },
                virt_text_pos = "overlay",
            })
        end
        if effective_mode() ~= shown_mode then
            shown_mode = effective_mode()
            vim.api.nvim_win_set_config(win, { title = title(), title_pos = "left" })
        end
        -- Grow with the text.
        local height = vim.api.nvim_win_text_height(win, {}).all
        vim.api.nvim_win_set_height(win, math.max(1, math.min(MAX_HEIGHT, height)))
    end

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    local function submit()
        local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
        vim.cmd.stopinsert()
        close()
        local final, final_mode = M.parse_prefix(text, mode)
        if final ~= "" then
            -- Leave the float before acting, so edits land in the original window.
            vim.schedule(function()
                opts.on_submit(final, final_mode)
            end)
        end
    end

    ---@param modes_ string|string[]
    ---@param lhs string
    ---@param fn fun()
    ---@param desc string
    local function map(modes_, lhs, fn, desc)
        vim.keymap.set(modes_, lhs, fn, { buffer = buf, nowait = true, desc = "conduit: " .. desc })
    end
    map({ "i", "n" }, "<CR>", function()
        if not accept_completion() then
            submit()
        end
    end, "send")
    map("i", "<S-CR>", function()
        vim.api.nvim_put({ "", "" }, "c", false, true)
    end, "new line")
    if mode then
        map({ "i", "n" }, "<C-t>", function()
            local i = (vim.fn.index(modes, mode) + 1) % #modes
            mode = modes[i + 1]
            shown_mode = effective_mode()
            vim.api.nvim_win_set_config(win, { title = title(), title_pos = "left" })
        end, "cycle mode")
    end
    map("n", "<Esc>", close, "close")
    map("n", "q", close, "close")
    map("n", "g?", function()
        hl.echo_keys("conduit prompt", help)
    end, "show keys")
    map("i", "<C-c>", function()
        vim.cmd.stopinsert()
        close()
    end, "cancel")

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = refresh })
    vim.api.nvim_create_autocmd("ModeChanged", {
        buffer = buf,
        callback = function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_set_config(win, { footer = footer(), footer_pos = "right" })
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })

    refresh()
    vim.cmd.startinsert()
    return buf, win
end

return M
