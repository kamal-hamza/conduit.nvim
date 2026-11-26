if vim.g.loaded_conduit then
    return
end
vim.g.loaded_conduit = true

-- conduit's buffers use their own filetypes so markdown linters, LSPs and
-- ftplugins leave them alone, but parse as markdown for highlighting and for
-- renderers like markview.nvim.
vim.treesitter.language.register("markdown", { "conduit", "conduit_input" })

-- Remember the last regular buffer, for `@buffer` and `@selection` mentions.
vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("conduit", { clear = true }),
    callback = function(ev)
        if vim.bo[ev.buf].buftype == "" then
            vim.g.conduit_last_buf = ev.buf
        end
    end,
})

-- <Plug> mappings for every action, so any key can be bound to them.
local plugs = {
    ["conduit-answer"] = function()
        require("conduit").answer()
    end,
    ["conduit-sidebar"] = function()
        require("conduit").sidebar()
    end,
    ["conduit-history"] = function()
        require("conduit").history()
    end,
    ["conduit-cancel"] = function()
        require("conduit").cancel()
    end,
    ["conduit-model"] = function()
        require("conduit").option("model")
    end,
    ["conduit-options"] = function()
        require("conduit").option()
    end,
}
for name, fn in pairs(plugs) do
    vim.keymap.set("n", ("<Plug>(%s)"):format(name), fn, { desc = "conduit: " .. name:gsub("^conduit%-", "") })
end
-- Inline requests on a visual selection (or the current line in normal mode).
for name, mode in pairs({ ["conduit-inline"] = "auto", ["conduit-ask"] = "ask", ["conduit-edit"] = "edit" }) do
    vim.keymap.set({ "n", "x" }, ("<Plug>(%s)"):format(name), function()
        local line1, line2 = vim.fn.line("v"), vim.fn.line(".")
        if line1 > line2 then
            line1, line2 = line2, line1
        end
        if vim.fn.mode():match("^[vV\22]") then
            vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
        end
        require("conduit").inline(line1, line2, nil, mode)
    end, { desc = "conduit: " .. mode .. " inline" })
end

local subcommands = {
    inline = function(args, cmd)
        require("conduit").inline(cmd.line1, cmd.line2, table.concat(args, " "))
    end,
    ask = function(args, cmd)
        require("conduit").ask(cmd.line1, cmd.line2, table.concat(args, " "))
    end,
    edit = function(args, cmd)
        require("conduit").edit(cmd.line1, cmd.line2, table.concat(args, " "))
    end,
    answer = function()
        require("conduit").answer()
    end,
    sidebar = function()
        require("conduit").sidebar()
    end,
    history = function(args)
        require("conduit").history({ qf = args[1] == "qf", scope = args[1] == "all" and "project" or nil })
    end,
    review = function(args)
        if args[1] and args[1] ~= "toggle" then
            return vim.notify("[conduit] usage: :Conduit review [toggle]", vim.log.levels.ERROR)
        end
        require("conduit").review(args[1])
    end,
    accept = function(args)
        require("conduit").accept(args[1] == "all")
    end,
    reject = function(args)
        require("conduit").reject(args[1] == "all")
    end,
    option = function(args)
        require("conduit").option(args[1], args[2])
    end,
    model = function(args)
        require("conduit").option("model", args[1])
    end,
    effort = function(args)
        require("conduit").option("effort", args[1])
    end,
    mode = function(args)
        require("conduit").option("mode", args[1])
    end,
    sandbox = function()
        vim.notify("[conduit] " .. table.concat(require("conduit").sandbox_info(), "\n"), vim.log.levels.INFO)
    end,
    cancel = function()
        require("conduit").cancel()
    end,
    stop = function()
        require("conduit").stop()
    end,
    log = function()
        vim.cmd.split(require("conduit.log").path)
    end,
}

local takes_value = { model = "model", effort = "effort", mode = "mode" }

---Option ids, or values of option `key`, for inline requests.
---@param key? string
---@return string[]
local function inline_options(key)
    local conduit = package.loaded["conduit"] and require("conduit")
    local config = require("conduit.config").options
    local agent = conduit and conduit.agents[config.inline.agent or config.default_agent]
    if not agent then
        return {}
    end
    local opts = require("conduit.inline").request_options(agent)
    if not key then
        return vim.tbl_map(function(o)
            return o.id
        end, opts)
    end
    local option = require("conduit.options").find(opts, key)
    return option and vim.tbl_map(function(c)
        return c.value
    end, option.choices) or {}
end

vim.api.nvim_create_user_command("Conduit", function(cmd)
    local args = vim.deepcopy(cmd.fargs)
    local sub = table.remove(args, 1)
    if not sub then
        -- Bare :Conduit (or :'<,'>Conduit) asks about the range.
        return require("conduit").inline(cmd.line1, cmd.line2)
    end
    local fn = subcommands[sub]
    if not fn then
        return vim.notify("[conduit] unknown subcommand: " .. sub, vim.log.levels.ERROR)
    end
    fn(args, cmd)
end, {
    nargs = "*",
    range = true,
    desc = "Inline requests to an ACP agent",
    complete = function(_, line)
        local words = vim.split(line, "%s+", { trimempty = false })
        local candidates = {}
        if #words == 2 then
            candidates = vim.tbl_keys(subcommands)
        elseif #words == 3 and takes_value[words[2]] then
            candidates = inline_options(takes_value[words[2]])
        elseif #words == 3 and words[2] == "review" then
            candidates = { "toggle" }
        elseif #words == 3 and words[2] == "history" then
            candidates = { "qf", "all" }
        elseif #words == 3 and (words[2] == "accept" or words[2] == "reject") then
            candidates = { "all" }
        elseif #words == 3 and words[2] == "option" then
            candidates = inline_options()
        elseif #words == 4 and words[2] == "option" then
            candidates = inline_options(words[3])
        end
        table.sort(candidates)
        return vim.tbl_filter(function(s)
            return vim.startswith(s, words[#words])
        end, candidates)
    end,
})
