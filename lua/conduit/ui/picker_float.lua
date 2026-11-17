--- The `Picker` view: a small keyboard-driven float over a headless picker.
--- `j`/`k` move, `1`-`9` pick directly, `/` filters, `<CR>` confirms,
--- `<Esc>`/`q` cancel.
local component = require("conduit.ui.component")
local hl = require("conduit.ui.hl")
local surface = require("conduit.ui.surface")

local M = {}

local ns = vim.api.nvim_create_namespace("conduit.picker")

local HELP = {
    { "j, k", "move (counts work)" },
    { "1-9", "pick that row" },
    { "/", "filter" },
    { "<CR>", "pick" },
    { "<Esc>, q", "cancel" },
}

---@class conduit.PickerView
---@field model conduit.PickerModel
---@field buf integer
---@field win integer

---Open a picker float for `opts` (see `conduit.PickerModelOpts`).
---@param opts conduit.PickerModelOpts
---@return conduit.PickerView
function M.open(opts)
    hl.setup()
    local origin = vim.api.nvim_get_current_win()
    local model ---@type conduit.PickerModel
    local win ---@type integer?
    local function close()
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_win_is_valid(origin) then
            vim.api.nvim_set_current_win(origin)
        end
    end
    model = require("conduit.ui.headless.picker").new({
        items = opts.items,
        title = opts.title,
        current = opts.current,
        on_pick = function(item)
            close()
            opts.on_pick(item)
        end,
        on_cancel = function()
            close()
            if opts.on_cancel then
                opts.on_cancel()
            end
        end,
    })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "conduit_picker"
    vim.bo[buf].modifiable = false

    local function size()
        local width = 20
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
        end
        return math.min(width, vim.o.columns - 4), math.max(1, math.min(vim.api.nvim_buf_line_count(buf), 15))
    end

    local view = surface.buffer(buf, ns)
    local function render()
        if model.done or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        view.draw(component.render("Picker", { model = model }))
        if win and vim.api.nvim_win_is_valid(win) then
            local width, height = size()
            vim.api.nvim_win_set_config(win, { width = width, height = height })
            local row = model.cursor + (model.query ~= "" and 1 or 0)
            pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
        end
    end
    render()

    local width, height = size()
    win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        height = height,
        style = "minimal",
        border = hl.border(),
        title = opts.title and { { " " .. opts.title .. " ", "ConduitTitle" } } or nil,
        title_pos = opts.title and "left" or nil,
    })
    vim.wo[win].winhighlight = hl.WINHIGHLIGHT
    vim.wo[win].cursorline = false
    model:subscribe(render)
    render()

    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
    end
    for _, lhs in ipairs({ "j", "<Down>", "<C-n>", "<Tab>" }) do
        map(lhs, function()
            model:next(vim.v.count1)
        end, "Next item")
    end
    for _, lhs in ipairs({ "k", "<Up>", "<C-p>", "<S-Tab>" }) do
        map(lhs, function()
            model:prev(vim.v.count1)
        end, "Previous item")
    end
    for n = 1, 9 do
        map(tostring(n), function()
            model:pick(n)
        end, "Pick item " .. n)
    end
    map("<CR>", function()
        model:confirm()
    end, "Pick")
    for _, lhs in ipairs({ "<Esc>", "q" }) do
        map(lhs, function()
            model:cancel()
        end, "Cancel")
    end
    map("/", function()
        vim.ui.input({ prompt = "Filter: ", default = model.query }, function(query)
            if query and not model.done then
                model:filter(query)
            end
        end)
    end, "Filter")
    map("g?", function()
        require("conduit.ui.help_float").open("conduit picker", HELP)
    end, "Show keys")
    vim.api.nvim_create_autocmd("WinLeave", {
        buffer = buf,
        callback = function()
            -- Going to another window cancels; a float (an input plugin's filter
            -- prompt, the key list) doesn't.
            vim.schedule(function()
                local cur = vim.api.nvim_get_current_win()
                if not model.done and cur ~= win and vim.api.nvim_win_get_config(cur).relative == "" then
                    model:cancel()
                end
            end)
        end,
    })
    return { model = model, buf = buf, win = win }
end

return M
