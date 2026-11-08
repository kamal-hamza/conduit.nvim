local M = {}

function M.check()
    vim.health.start("conduit.nvim")
    if vim.fn.has("nvim-0.11") == 1 then
        vim.health.ok("Neovim >= 0.11")
    else
        vim.health.error("Neovim >= 0.11 is required")
    end

    local options = require("conduit.config").options
    vim.health.start("conduit.nvim: agents")
    for name, spec in vim.spairs(options.agents) do
        local cmdline = table.concat({ spec.cmd, unpack(spec.args or {}) }, " ")
        if vim.fn.executable(spec.cmd) == 1 then
            vim.health.ok(("%s: `%s`"):format(name, cmdline))
        else
            vim.health.warn(("%s: `%s` not found in PATH"):format(name, spec.cmd))
        end
    end

    vim.health.start("conduit.nvim: threads")
    local agents = package.loaded["conduit"] and require("conduit").agents or {}
    local any = false
    for name, agent in vim.spairs(agents) do
        if agent.info then
            any = true
            local caps = vim.tbl_filter(function(cap)
                return agent:supports(cap)
            end, { "load", "list", "resume", "close", "delete", "fork", "title" })
            if #caps == 0 then
                vim.health.info(("%s: live threads only (no session capabilities)"):format(name))
            else
                vim.health.ok(("%s: %s"):format(name, table.concat(caps, ", ")))
            end
        end
    end
    if not any then
        vim.health.info("Start an agent to see which thread features it supports")
    end

    local threads = options.threads
    vim.health.info(
        threads.persist and ("Thread index: " .. require("conduit.history").path) or "Thread index disabled"
    )
    vim.health.info("Log file: " .. require("conduit.log").path)

    vim.health.start("conduit.nvim: commands")
    any = false
    for name, agent in vim.spairs(agents) do
        local list = agent.last_commands or {}
        if #list > 0 then
            any = true
            local names = vim.tbl_map(function(cmd)
                return "/" .. cmd.name
            end, list)
            vim.health.ok(("%s: %d commands: %s"):format(name, #list, table.concat(names, ", ")))
        end
    end
    if not any then
        vim.health.info("No agent has advertised slash commands yet (start a chat to see them)")
    end
end

return M
