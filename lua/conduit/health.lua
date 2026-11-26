local M = {}

function M.check()
    vim.health.start("conduit.nvim")
    if vim.fn.has("nvim-0.11") == 1 then
        vim.health.ok("Neovim >= 0.11")
    else
        vim.health.error("Neovim >= 0.11 is required")
    end

    local ok, has_md = pcall(vim.treesitter.language.add, "markdown")
    if ok and has_md then
        vim.health.ok("treesitter `markdown` parser (highlights answers in the sidebar)")
    else
        vim.health.warn("treesitter `markdown` parser not found: answers in the sidebar won't be highlighted")
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

    vim.health.start("conduit.nvim: prompt content")
    local any_prompt = false
    for name, agent in vim.spairs(agents) do
        if agent.info then
            any_prompt = true
            local caps = (agent.info.agentCapabilities or {}).promptCapabilities or {}
            local function yes(cap)
                return caps[cap] == true and "yes" or "no"
            end
            local line = ("%s: images %s, embedded context %s"):format(name, yes("image"), yes("embeddedContext"))
            if caps.image == true then
                vim.health.ok(line)
            else
                vim.health.info(line .. " (@ mentioned images are sent as links)")
            end
        end
    end
    if not any_prompt then
        vim.health.info("Start an agent to see whether it accepts images and embedded context")
    end

    vim.health.info("History: " .. require("conduit.history").path())
    vim.health.info("Log file: " .. require("conduit.log").path)

    vim.health.start("conduit.nvim: sandbox")
    local sandbox = require("conduit.sandbox")
    local scfg = options.sandbox
    if not sandbox.enabled() then
        vim.health.warn("The sandbox is off (`sandbox.enabled`): agents may touch any file and run any command")
    else
        for _, line in ipairs(require("conduit").sandbox_info()) do
            vim.health.info(line)
        end
        if scfg.isolation.enabled then
            local backend = sandbox.backend()
            if backend then
                vim.health.ok(("Terminal commands run in `%s`"):format(backend))
            else
                local msg = ("No OS sandbox found: terminal commands %s"):format(
                    scfg.isolation.unavailable == "deny" and "are refused"
                        or scfg.isolation.unavailable == "run" and "run unisolated"
                        or "ask before running unisolated"
                )
                if vim.fn.has("linux") == 1 then
                    vim.health.warn(msg, { "Install bubblewrap (`bwrap`)" })
                else
                    vim.health.warn(msg)
                end
            end
        end
        if scfg.bypass then
            vim.health.warn("`sandbox.bypass` lets agents switch to a mode that skips every check")
        end
    end
    vim.health.info(
        "Agents that run commands themselves are checked through their permission requests;"
            .. " Claude's adapter is told to ask for every Bash command and to use Claude Code's sandbox"
    )

    vim.health.start("conduit.nvim: terminals")
    local tcfg = options.terminal
    if tcfg.enabled then
        vim.health.ok(("Agents can run commands through Neovim (output limit %d bytes)"):format(tcfg.output_limit))
    else
        vim.health.info("Terminals are off (`terminal.enabled`); agents run commands themselves")
    end

    vim.health.start("conduit.nvim: commands")
    local any = false
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
        vim.health.info("No agent has advertised slash commands yet (make a request to see them)")
    end
end

return M
