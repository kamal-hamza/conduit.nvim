--- A small floating prompt with `@` mention completion, used instead of
--- vim.ui.input for inline requests.
local M = {}

---@alias conduit.InlineMode "auto"|"edit"|"ask"

local modes = { "auto", "edit", "ask" }
local mode_names = { auto = "Auto", edit = "Edit", ask = "Ask" }

---@class conduit.PromptOpts
---@field title string
---@field mode? conduit.InlineMode Initial mode; omit for a prompt without modes
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

---@param opts conduit.PromptOpts
---@return integer buf, integer win
function M.open(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "conduit_input"
    vim.diagnostic.enable(false, { bufnr = buf })
    pcall(vim.treesitter.start, buf, "markdown")
    require("conduit.mentions").attach(buf)

    local mode = opts.mode
    local function title()
        if not mode then
            return (" %s "):format(opts.title)
        end
        return (" %s · %s "):format(opts.title, mode_names[mode])
    end
    local footer = mode and " <CR> submit · <C-t> mode · ? ask · ! edit · @ context · <Esc><Esc> cancel "
        or " <CR> submit · <S-CR> newline · @ context · <Esc><Esc> cancel "

    local width = math.max(40, math.min(84, vim.o.columns - 8))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        height = 1,
        style = "minimal",
        border = "rounded",
        title = title(),
        title_pos = "left",
        footer = footer,
        footer_pos = "right",
    })
    vim.wo[win].wrap = true

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

    local function map(modes_, lhs, fn)
        vim.keymap.set(modes_, lhs, fn, { buffer = buf, nowait = true })
    end
    map({ "i", "n" }, "<CR>", function()
        if not accept_completion() then
            submit()
        end
    end)
    map("i", "<S-CR>", function()
        vim.api.nvim_put({ "", "" }, "c", false, true)
    end)
    if mode then
        map({ "i", "n" }, "<C-t>", function()
            local i = (vim.fn.index(modes, mode) + 1) % #modes
            mode = modes[i + 1]
            vim.api.nvim_win_set_config(win, { title = title(), title_pos = "left" })
        end)
    end
    map("n", "<Esc>", close)
    map("n", "q", close)
    map("i", "<C-c>", function()
        vim.cmd.stopinsert()
        close()
    end)

    -- Grow with the text, up to 8 lines.
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = buf,
        callback = function()
            if vim.api.nvim_win_is_valid(win) then
                local height = vim.api.nvim_win_text_height(win, {}).all
                vim.api.nvim_win_set_height(win, math.max(1, math.min(8, height)))
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })

    vim.cmd.startinsert()
    return buf, win
end

return M
