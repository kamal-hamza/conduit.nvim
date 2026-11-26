--- The history list (`:Conduit history`): one line per entry in a borderless
--- float, driven by a headless history model. Keys: `j`/`k` move, `/` filters,
--- `<Tab>` switches between this buffer and the project, `<CR>` shows the entry
--- in the sidebar, `gf` jumps, `f` follows up, `r` re-runs, `u` reverts, `dd` deletes.
local component = require("conduit.ui.component")
local history = require("conduit.history")
local hl = require("conduit.ui.hl")
local surface = require("conduit.ui.surface")

local M = {}

local ns = vim.api.nvim_create_namespace("conduit.history")

local HELP = {
    { "j, k", "move (counts work)" },
    { "/", "filter by prompt, file, answer or diff" },
    { "<Tab>", "this buffer / the whole project" },
    { "<CR>", "show the entry in the sidebar" },
    { "gf", "go to the lines (or file)" },
    { "f", "follow up on an answer" },
    { "r", "re-run the request on the lines" },
    { "u", "revert an edit or change (if the file is unchanged since)" },
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
            lines[1] = { { (" no history for %s · <Tab> switches"):format(where), "ConduitMuted" } }
        end
        view.draw(lines)
        pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, model.cursor), 0 })
    end
    model:subscribe(render)
    render()

    local function close()
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
        if model:selected() then
            close()
            model:run("show")
        end
    end, "Show in the sidebar")
    map("gf", function()
        if model:selected() then
            close()
            model:run("jump")
        end
    end, "Jump")
    map("f", function()
        local entry = model:selected()
        if entry and entry.kind == "answer" then
            close()
            model:run("follow_up")
        end
    end, "Follow up")
    map("r", function()
        local entry = model:selected()
        if entry and entry.kind ~= "change" then
            close()
            model:run("rerun")
        end
    end, "Re-run")
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

---The default actions: show, jump, follow up, re-run, revert, delete.
---@param origin integer
---@return conduit.HistoryActions
function M.actions(origin)
    return {
        show = function(entry)
            require("conduit.ui.sidebar").show({ entry = entry })
        end,
        jump = function(entry)
            history.jump(entry, origin)
        end,
        follow_up = function(entry)
            require("conduit.inline").continue(entry)
        end,
        rerun = function(entry)
            history.jump(entry, origin)
            local buf = vim.api.nvim_win_get_buf(origin)
            local last = math.min(entry.line2, vim.api.nvim_buf_line_count(buf))
            require("conduit").inline(
                math.min(entry.line1, last),
                last,
                entry.prompt,
                entry.kind == "edit" and "edit" or "ask"
            )
        end,
        revert = function(entry)
            return history.revert(entry)
        end,
        delete = function(entry)
            history.delete(entry.id)
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
        entries = history.load(),
        file = vim.api.nvim_buf_get_name(0),
        scope = opts and opts.scope,
        actions = M.actions(origin),
    })
    return open_view(model, origin)
end

return M
