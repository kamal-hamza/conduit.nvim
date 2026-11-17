--- Headless inline answer: which phase an answer is in and the transitions
--- between them. Views (virtual lines, the peek float, the end-of-line marker,
--- the legacy float) render the phase; keys and autocmds call the actions.
---
---   running ─► short (≤ SHORT_LINES lines) or peek (more)
---   short/peek ─collapse─► collapsed ─expand─► short/peek
---   any shown phase ─focus─► focused ─blur─► short/peek
---   any ─close─► closed
local store = require("conduit.ui.headless.store")

local M = {}

---Answers up to this many lines show as virtual lines, without a window.
M.SHORT_LINES = 2

---@alias conduit.AnswerPhase "running"|"short"|"peek"|"collapsed"|"focused"|"closed"

---@class conduit.AnswerActions
---@field apply? fun()
---@field follow_up? fun()
---@field to_chat? fun()
---@field cancel? fun()

---@class conduit.AnswerModel: conduit.Store
---@field phase conduit.AnswerPhase
---@field text string
---@field done boolean The turn finished
---@field shape "short"|"peek" What the answer looks like when shown unfocused
---@field actions conduit.AnswerActions
local Answer = store.extend({})
Answer.__index = Answer

---@param actions? conduit.AnswerActions
---@return conduit.AnswerModel
function M.new(actions)
    local self = setmetatable({
        phase = "running",
        text = "",
        done = false,
        shape = "short",
        actions = actions or {},
    }, Answer)
    store.init(self)
    return self
end

---@param text string
---@return integer
function M.line_count(text)
    local trimmed = vim.trim(text)
    if trimmed == "" then
        return 0
    end
    return #vim.split(trimmed, "\n", { plain = true })
end

---@param phase conduit.AnswerPhase
function Answer:_go(phase)
    if self.phase ~= phase then
        self.phase = phase
    end
    self:changed()
end

---The whole reply so far.
---@param text string
function Answer:stream(text)
    if self.phase == "closed" then
        return
    end
    self.text = text
    -- Once an answer outgrows virtual lines it stays in the float.
    if self.shape == "short" and M.line_count(text) > M.SHORT_LINES then
        self.shape = "peek"
    end
    if self.phase == "running" or self.phase == "short" or self.phase == "peek" then
        return self:_go(M.line_count(text) == 0 and "running" or self.shape)
    end
    self:changed()
end

function Answer:finish()
    self.done = true
    self:changed()
end

---Hide the answer behind a marker. Only shown, unfocused answers collapse.
function Answer:collapse()
    if self.phase == "short" or self.phase == "peek" then
        self:_go("collapsed")
    end
end

function Answer:expand()
    if self.phase == "collapsed" then
        self:_go(self.shape)
    end
end

function Answer:focus()
    if self.phase ~= "closed" and (self.phase ~= "running" or self.text ~= "") then
        self:_go("focused")
    end
end

---Leave the focused float; the answer stays shown.
function Answer:blur()
    if self.phase == "focused" then
        self:_go(self.shape)
    end
end

function Answer:close()
    self:_go("closed")
end

function Answer:apply()
    if self.actions.apply then
        self.actions.apply()
    end
end

function Answer:follow_up()
    if self.actions.follow_up then
        self.actions.follow_up()
    end
end

function Answer:to_chat()
    if self.actions.to_chat then
        self.actions.to_chat()
    end
end

function Answer:cancel()
    if self.actions.cancel then
        self.actions.cancel()
    end
end

return M
