--- The `HelpFloat` view: `g?` lists the keys of the current surface. Driven by
--- a headless help model; `/` filters, `q`/`<Esc>` close.
local component = require("conduit.ui.component")
local hl = require("conduit.ui.hl")
local surface = require("conduit.ui.surface")

local M = {}

local ns = vim.api.nvim_create_namespace("conduit.help")

---@type { win: integer, model: conduit.HelpModel }?
M.current = nil

---Show `keys` (`{ key, description }` pairs) in a float.
---@param title string
---@param keys [string, string][]
---@return conduit.HelpModel
function M.open(title, keys)
    hl.setup()
    if M.current and vim.api.nvim_win_is_valid(M.current.win) then
        vim.api.nvim_win_close(M.current.win, true)
    end
    local model = require("conduit.ui.headless.help").new(title, keys)
    local origin = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "conduit_help"
    vim.bo[buf].modifiable = false
    local view = surface.buffer(buf, ns)
    local win ---@type integer?

    local function render()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        if not model.is_open then
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
            if vim.api.nvim_win_is_valid(origin) then
                pcall(vim.api.nvim_set_current_win, origin)
            end
            return
        end
        view.draw(
            component.render("HelpFloat", { title = model.title, entries = model:entries(), query = model.query })
        )
        local width = 20
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
        end
        local cfg = {
            relative = "editor",
            row = math.max(0, math.floor((vim.o.lines - vim.api.nvim_buf_line_count(buf)) / 2) - 2),
            col = math.max(0, math.floor((vim.o.columns - width) / 2)),
            width = math.min(width, vim.o.columns - 4),
            height = math.max(1, math.min(vim.api.nvim_buf_line_count(buf), vim.o.lines - 4)),
        }
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_config(win, cfg)
        else
            win = vim.api.nvim_open_win(
                buf,
                true,
                vim.tbl_extend("force", cfg, { style = "minimal", border = hl.border(), zindex = 250 })
            )
            vim.wo[win].winhighlight = hl.WINHIGHLIGHT
            M.current = { win = win, model = model }
        end
    end
    model:subscribe(render)
    model:open()

    local function map(lhs, fn)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "conduit help" })
    end
    for _, lhs in ipairs({ "q", "<Esc>", "g?" }) do
        map(lhs, function()
            model:close()
        end)
    end
    map("/", function()
        vim.ui.input({ prompt = "Filter keys: ", default = model.query }, function(query)
            if query and model.is_open then
                model:filter(query)
            end
        end)
    end)
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            vim.schedule(function()
                if model.is_open and win and vim.api.nvim_get_current_win() ~= win then
                    model:close()
                end
            end)
        end,
    })
    return model
end

return M
