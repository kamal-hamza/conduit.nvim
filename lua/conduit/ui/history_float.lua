--- The inline history list (`:Conduit history`): one line per entry in a
--- borderless float, driven by a headless history model. Keys: `j`/`k` move, `/`
--- filters, `<Tab>` switches between this buffer and the project, `<CR>` jumps,
--- `p` previews, `r` re-runs, `c` moves to the chat, `u` reverts, `dd` deletes.
local component = require("conduit.ui.component")
local hl = require("conduit.ui.hl")
local inline_history = require("conduit.inline_history")
local surface = require("conduit.ui.surface")

local M = {}

local ns = vim.api.nvim_create_namespace("conduit.history")

local HELP = {
    { "j, k", "move (counts work)" },
    { "/", "filter by prompt, file or answer" },
    { "<Tab>", "this buffer / the whole project" },
    { "<CR>", "jump to the range" },
    { "p", "preview the answer or diff" },
    { "r", "re-run the request on the range" },
    { "c", "send the entry to a new chat" },
    { "u", "revert an applied edit (if the lines are unchanged)" },
    { "dd", "delete the entry" },
    { "q, <Esc>", "close" },
}

---@class conduit.HistoryView
---@field model conduit.HistoryModel
---@field buf integer
---@field win integer

---@param model conduit.HistoryModel
---@param origin integer Window the list was opened from (jumps land there)
---@return conduit.HistoryView
local function open_view(model, origin)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "conduit_history"
    vim.bo[buf].modifiable = false
    local view = surface.buffer(buf, ns)
    local width = math.min(100, vim.o.columns - 4)
    local height = math.min(15, math.max(1, vim.o.lines - 6))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = hl.content_border(),
        zindex = 60,
    })
    vim.wo[win].winhighlight = hl.WINHIGHLIGHT
    vim.wo[win].cursorline = false
    local preview ---@type integer?

    local function close_preview()
        if preview and vim.api.nvim_win_is_valid(preview) then
            vim.api.nvim_win_close(preview, true)
        end
        preview = nil
    end

    local function render()
        if not vim.api.nvim_win_is_valid(win) then
            return
        end
        local lines = {} ---@type conduit.Spans[]
        local now = os.time()
        for i, entry in ipairs(model.filtered) do
            lines[i] = component.render("HistoryLine", { entry = entry, now = now, cursor = i == model.cursor })
        end
        if #lines == 0 then
            local where = model.scope == "buffer" and "this buffer" or "this project"
            lines[1] = { { (" no inline history for %s · <Tab> switches"):format(where), "ConduitMuted" } }
        end
        view.draw(lines)
        pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, model.cursor), 0 })
        close_preview()
    end
    model:subscribe(render)
    render()

    local function close()
        close_preview()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_win_is_valid(origin) then
            vim.api.nvim_set_current_win(origin)
        end
    end

    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
    end
    for _, lhs in ipairs({ "j", "<Down>", "<C-n>" }) do
        map(lhs, function()
            model:next(vim.v.count1)
        end, "Next entry")
    end
    for _, lhs in ipairs({ "k", "<Up>", "<C-p>" }) do
        map(lhs, function()
            model:prev(vim.v.count1)
        end, "Previous entry")
    end
    map("/", function()
        vim.ui.input({ prompt = "Filter: ", default = model.query }, function(query)
            if query then
                model:filter(query)
            end
        end)
    end, "Filter")
    map("<Tab>", function()
        model:toggle_scope()
    end, "Buffer or project")
    map("<CR>", function()
        local entry = model:selected()
        if entry then
            close()
            inline_history.jump(entry, origin)
        end
    end, "Jump")
    map("p", function()
        local entry = model:selected()
        if not entry then
            return
        end
        if preview then
            return close_preview()
        end
        local pbuf = vim.api.nvim_create_buf(false, true)
        vim.bo[pbuf].bufhidden = "wipe"
        vim.bo[pbuf].filetype = "conduit"
        pcall(vim.treesitter.start, pbuf, "markdown")
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, vim.split(inline_history.markdown(entry), "\n"))
        vim.bo[pbuf].modifiable = false
        require("conduit.ui.render").attach(pbuf)
        -- Under the list when there's room, over its lower half otherwise; never focused.
        local room = vim.o.lines - (vim.api.nvim_win_get_position(win)[1] + height + 3)
        preview = vim.api.nvim_open_win(pbuf, false, {
            relative = "win",
            win = win,
            row = room >= 6 and height + 1 or math.floor(height / 2),
            col = 0,
            width = width,
            height = math.max(3, math.min(12, room >= 6 and room or math.ceil(height / 2))),
            style = "minimal",
            border = hl.content_border(),
            focusable = false,
            zindex = 61,
        })
        vim.wo[preview].wrap = true
        vim.wo[preview].conceallevel = 2
        vim.wo[preview].winhighlight = "NormalFloat:ConduitAnswer"
    end, "Preview")
    map("r", function()
        local entry = model:selected()
        if entry then
            close()
            model:run("rerun")
        end
    end, "Re-run")
    map("c", function()
        local entry = model:selected()
        if entry then
            close()
            model:run("to_chat")
        end
    end, "Send to a chat")
    map("u", function()
        model:run("revert")
    end, "Revert the edit")
    map("dd", function()
        model:run("delete")
    end, "Delete the entry")
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        map(lhs, close, "Close")
    end
    map("g?", function()
        require("conduit.ui.help_float").open("conduit history", HELP)
    end, "Show keys")
    vim.api.nvim_create_autocmd("WinLeave", {
        buffer = buf,
        callback = function()
            vim.schedule(function()
                local cur = vim.api.nvim_get_current_win()
                if cur ~= win and vim.api.nvim_win_get_config(cur).relative == "" then
                    close()
                end
            end)
        end,
    })
    return { model = model, buf = buf, win = win }
end

---The default actions: jump, re-run, send to chat, revert, delete.
---@param origin integer
---@return conduit.HistoryActions
function M.actions(origin)
    return {
        jump = function(entry)
            inline_history.jump(entry, origin)
        end,
        rerun = function(entry)
            inline_history.jump(entry, origin)
            local buf = vim.api.nvim_win_get_buf(origin)
            local last = math.min(entry.line2, vim.api.nvim_buf_line_count(buf))
            require("conduit").inline(
                math.min(entry.line1, last),
                last,
                entry.prompt,
                entry.kind == "edit" and "edit" or "ask"
            )
        end,
        to_chat = function(entry)
            local conduit = require("conduit")
            local chat = conduit.new()
            if chat then
                chat:add_context(vim.split(inline_history.markdown(entry), "\n"))
            end
        end,
        revert = function(entry)
            return inline_history.revert(entry)
        end,
        delete = function(entry)
            inline_history.delete(entry.id)
        end,
    }
end

---Open the list for the current buffer (or the project when it has no entries).
---@param opts? { scope?: "buffer"|"project" }
---@return conduit.HistoryView
function M.open(opts)
    hl.setup()
    local origin = vim.api.nvim_get_current_win()
    local model = require("conduit.ui.headless.history").new({
        entries = inline_history.load(),
        file = vim.api.nvim_buf_get_name(0),
        scope = opts and opts.scope,
        actions = M.actions(origin),
    })
    return open_view(model, origin)
end

return M
