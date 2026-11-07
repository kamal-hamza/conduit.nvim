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

local subcommands = {
    open = function(args)
        require("conduit").open(args[1])
    end,
    new = function(args)
        require("conduit").new(args[1])
    end,
    toggle = function()
        require("conduit").toggle()
    end,
    threads = function(args)
        require("conduit").threads(args[1])
    end,
    continue = function(args)
        require("conduit").continue_thread(args[1])
    end,
    thread = function(args)
        local conduit = require("conduit")
        local action = table.remove(args, 1)
        local actions = {
            new = function()
                conduit.new()
            end,
            next = conduit.thread_next,
            prev = conduit.thread_prev,
            close = conduit.thread_close,
            delete = function()
                conduit.thread_delete()
            end,
            fork = conduit.thread_fork,
            rename = function()
                conduit.thread_rename(#args > 0 and table.concat(args, " ") or nil)
            end,
        }
        local fn = actions[action or ""]
        if not fn then
            return vim.notify(
                "[conduit] usage: :Conduit thread new|next|prev|close|delete|fork|rename [title]",
                vim.log.levels.ERROR
            )
        end
        fn()
    end,
    cancel = function()
        require("conduit").cancel()
    end,
    stop = function()
        require("conduit").stop()
    end,
    add = function(_, cmd)
        require("conduit").add_range(cmd.line1, cmd.line2)
    end,
    inline = function(args, cmd)
        require("conduit").inline(cmd.line1, cmd.line2, table.concat(args, " "))
    end,
    ask = function(args, cmd)
        require("conduit").ask(cmd.line1, cmd.line2, table.concat(args, " "))
    end,
    edit = function(args, cmd)
        require("conduit").edit(cmd.line1, cmd.line2, table.concat(args, " "))
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
    log = function()
        vim.cmd.split(require("conduit.log").path)
    end,
}

local takes_agent = { open = true, new = true, threads = true, continue = true }
local takes_value = { model = "model", effort = "effort", mode = "mode" }
local thread_actions = { "new", "next", "prev", "close", "delete", "fork", "rename" }

---Option ids, or values of option `key`, from the current chat's session.
---@param key? string
---@return string[]
local function session_options(key)
    local chat = package.loaded["conduit"] and require("conduit").current
    if not chat or not chat.session_id then
        return {}
    end
    local options = require("conduit.options")
    local opts = chat.agent:get_options(chat.session_id)
    if not key then
        return vim.tbl_map(function(o)
            return o.id
        end, opts)
    end
    local option = options.find(opts, key)
    return option and vim.tbl_map(function(c)
        return c.value
    end, option.choices) or {}
end

vim.api.nvim_create_user_command("Conduit", function(cmd)
    local args = vim.deepcopy(cmd.fargs)
    local sub = table.remove(args, 1) or "toggle"
    local fn = subcommands[sub]
    if not fn then
        return vim.notify("[conduit] unknown subcommand: " .. sub, vim.log.levels.ERROR)
    end
    fn(args, cmd)
end, {
    nargs = "*",
    range = true,
    desc = "Chat with an ACP agent",
    complete = function(_, line)
        local words = vim.split(line, "%s+", { trimempty = false })
        local candidates = {}
        if #words == 2 then
            candidates = vim.tbl_keys(subcommands)
        elseif #words == 3 and takes_agent[words[2]] then
            candidates = vim.tbl_keys(require("conduit.config").options.agents)
        elseif #words == 3 and takes_value[words[2]] then
            candidates = session_options(takes_value[words[2]])
        elseif #words == 3 and words[2] == "thread" then
            candidates = vim.deepcopy(thread_actions)
        elseif #words == 3 and words[2] == "option" then
            candidates = session_options()
        elseif #words == 4 and words[2] == "option" then
            candidates = session_options(words[3])
        end
        table.sort(candidates)
        return vim.tbl_filter(function(s)
            return vim.startswith(s, words[#words])
        end, candidates)
    end,
})
