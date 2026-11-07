--- An animated progress indicator: a timer that calls back with each frame.
local M = {}

local INTERVAL = 80

---@class conduit.Spinner
---@field frames string[]
---@field index integer
---@field on_frame fun(frame: string)
---@field timer? uv.uv_timer_t
local Spinner = {}
Spinner.__index = Spinner

---@param on_frame fun(frame: string) Called (outside fast context) on every tick
---@return conduit.Spinner
function M.new(on_frame)
    return setmetatable({
        frames = require("conduit.config").options.ui.spinner,
        index = 1,
        on_frame = on_frame,
    }, Spinner)
end

---@return string
function Spinner:frame()
    return self.frames[self.index] or ""
end

function Spinner:is_running()
    return self.timer ~= nil
end

---Start ticking. Idempotent.
function Spinner:start()
    if self.timer or #self.frames <= 1 then
        return
    end
    local timer = assert(vim.uv.new_timer())
    self.timer = timer
    -- Timer callbacks run in a fast context; touch the UI only once scheduled.
    timer:start(
        INTERVAL,
        INTERVAL,
        vim.schedule_wrap(function()
            if self.timer ~= timer then
                return
            end
            self.index = self.index % #self.frames + 1
            self.on_frame(self:frame())
        end)
    )
end

---Stop ticking. Idempotent.
function Spinner:stop()
    local timer = self.timer
    self.timer = nil
    if timer then
        timer:stop()
        timer:close()
    end
end

return M
