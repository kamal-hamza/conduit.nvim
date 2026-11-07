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

    local agents = package.loaded["conduit"] and require("conduit").agents or {}

    vim.health.start("conduit.nvim: MCP servers")
    local mcp = require("conduit.mcp")
    local any_server = false
    for name, spec in vim.spairs(options.agents) do
        local agent = agents[name]
        -- Transport support is only known once the agent has started.
        local caps = agent and agent.info and mcp.capabilities(agent) or nil
        for server_name, server in vim.spairs(mcp.configured(spec)) do
            any_server = true
            local label = ("%s: %s"):format(name, server_name)
            if not mcp.enabled(server) then
                vim.health.info(label .. " (disabled)")
            else
                ---@cast server conduit.McpServer
                local entry, err = mcp.build(server_name, server, caps)
                local kind = server.type or "stdio"
                if not entry then
                    vim.health.warn(("%s (%s): %s"):format(label, kind, err))
                else
                    local target = entry.command or entry.url
                    local note = ""
                    if not caps and kind ~= "stdio" then
                        note = "; start the agent to check it supports " .. kind
                    end
                    vim.health.ok(("%s (%s): `%s`%s"):format(label, kind, target, note))
                end
            end
        end
    end
    if not any_server then
        vim.health.info("None configured (`mcp_servers`)")
    end
    if options.inline.mcp_servers ~= true then
        vim.health.info("Inline requests run without MCP servers (`inline.mcp_servers`)")
    end

    vim.health.start("conduit.nvim: threads")
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
end

return M
