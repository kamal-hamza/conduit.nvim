local M = {}

M.path = vim.fs.joinpath(vim.fn.stdpath("log") --[[@as string]], "conduit.log")

local names = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }

---@param level integer
---@param msg string
function M.log(level, msg)
    local f = io.open(M.path, "a")
    if f then
        f:write(("[%s] %s %s\n"):format(os.date("%F %T"), names[level + 1] or "?", msg))
        f:close()
    end
    if level >= require("conduit.config").options.log_level then
        vim.notify("[conduit] " .. msg, level)
    end
end

function M.debug(msg)
    M.log(vim.log.levels.DEBUG, msg)
end

function M.info(msg)
    M.log(vim.log.levels.INFO, msg)
end

function M.warn(msg)
    M.log(vim.log.levels.WARN, msg)
end

function M.error(msg)
    M.log(vim.log.levels.ERROR, msg)
end

return M
