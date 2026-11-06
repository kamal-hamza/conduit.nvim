--- Markdown rendering for conduit's buffers. markview.nvim skips `nofile`
--- buffers by default, so attach it explicitly and re-render as text streams in.
local M = {}

local pending = {}

---@param buf integer
function M.attach(buf)
    if not package.loaded["markview"] then
        return
    end
    pcall(function()
        -- Optional dependency, only required once it's loaded.
        ---@diagnostic disable-next-line: unresolved-require
        local actions = require("markview.actions")
        actions.attach(buf)
        actions.enable(buf)
    end)
end

---Re-render `buf` soon (debounced), after programmatic changes.
---@param buf integer
function M.refresh(buf)
    if not package.loaded["markview"] or pending[buf] then
        return
    end
    pending[buf] = true
    vim.defer_fn(function()
        pending[buf] = nil
        if vim.api.nvim_buf_is_valid(buf) then
            ---@diagnostic disable-next-line: unresolved-require
            pcall(require("markview").render, buf)
        end
    end, 80)
end

return M
