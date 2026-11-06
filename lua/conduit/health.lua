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
    vim.health.info("Log file: " .. require("conduit.log").path)
end

return M
