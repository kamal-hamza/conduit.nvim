--- A chat: one ACP session rendered as a markdown transcript plus an input buffer.
local config = require("conduit.config")
local options = require("conduit.options")

local ns = vim.api.nvim_create_namespace("conduit")

local status_icons = {
    pending = "○",
    in_progress = "◐",
    completed = "✓",
    failed = "✗",
}

local plan_icons = {
    pending = "[ ]",
    in_progress = "[~]",
    completed = "[x]",
}

---@class conduit.Chat: conduit.SessionHandler
---@field agent conduit.Agent
---@field session_id? string
---@field transcript integer
---@field input integer
---@field busy boolean
---@field tools table<string, table>
local Chat = {}
Chat.__index = Chat

local count = 0

---@param content? table ACP ContentBlock
---@return string
local function content_text(content)
    if not content then
        return ""
    elseif content.type == "text" then
        return content.text or ""
    elseif content.type == "resource_link" then
        return ("[%s](%s)"):format(content.name or content.uri, content.uri)
    elseif content.type == "resource" and content.resource then
        return content.resource.text or ("<%s>"):format(content.resource.uri)
    end
    return ("<%s>"):format(content.type or "unknown")
end

local function scratch(name, ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].filetype = ft
    vim.diagnostic.enable(false, { bufnr = buf })
    pcall(vim.treesitter.start, buf, "markdown")
    return buf
end

---@param agent conduit.Agent
---@return conduit.Chat
function Chat.new(agent)
    count = count + 1
    local self = setmetatable({ agent = agent, busy = false, tools = {}, last_kind = nil }, Chat)
    self.transcript = scratch(("conduit://%s/%d"):format(agent.name, count), "conduit")
    self.input = scratch(("conduit://%s/%d/input"):format(agent.name, count), "conduit_input")
    vim.bo[self.transcript].modifiable = false
    require("conduit.ui.render").attach(self.transcript)
    require("conduit.mentions").attach(self.input)
    self:_keymaps()
    return self
end

function Chat:_keymaps()
    local function map(mode, lhs, fn, desc)
        vim.keymap.set(mode, lhs, fn, { buffer = self.input, desc = desc })
    end
    map("n", "<CR>", function()
        self:submit()
    end, "Send prompt")
    map("i", "<C-s>", function()
        vim.cmd.stopinsert()
        self:submit()
    end, "Send prompt")
    map("n", "<C-c>", function()
        self:cancel()
    end, "Cancel turn")
    for _, buf in ipairs({ self.input, self.transcript }) do
        vim.keymap.set("n", "q", function()
            self:close()
        end, { buffer = buf, desc = "Close chat" })
        vim.keymap.set("n", "go", function()
            self:pick_option()
        end, { buffer = buf, desc = "Session options (model, effort, mode)" })
    end
end

---@return integer? transcript_win, integer? input_win
function Chat:wins()
    local t = vim.fn.bufwinid(self.transcript)
    local i = vim.fn.bufwinid(self.input)
    return t ~= -1 and t or nil, i ~= -1 and i or nil
end

function Chat:is_open()
    return self:wins() ~= nil
end

function Chat:open()
    local twin, iwin = self:wins()
    if not twin then
        local ui = config.options.ui
        local width = math.floor(ui.width <= 1 and vim.o.columns * ui.width or ui.width)
        vim.cmd("botright vsplit")
        twin = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(twin, self.transcript)
        vim.api.nvim_win_set_width(twin, width)
        vim.cmd("belowright split")
        iwin = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(iwin, self.input)
        vim.api.nvim_win_set_height(iwin, ui.input_height)
        for _, win in ipairs({ twin, iwin }) do
            vim.wo[win].wrap = true
            vim.wo[win].linebreak = true
            vim.wo[win].number = false
            vim.wo[win].relativenumber = false
            vim.wo[win].signcolumn = "no"
            vim.wo[win].winfixwidth = true
        end
        vim.wo[iwin].winfixheight = true
        self:_refresh_winbar()
        self:_scroll()
    end
    vim.api.nvim_set_current_win(iwin or twin)
end

function Chat:close()
    local twin, iwin = self:wins()
    for _, win in ipairs({ iwin, twin }) do
        if win and #vim.api.nvim_list_wins() > 1 then
            vim.api.nvim_win_close(win, false)
        end
    end
end

function Chat:toggle()
    if self:is_open() then
        self:close()
    else
        self:open()
    end
end

function Chat:_refresh_winbar()
    local twin, iwin = self:wins()
    local parts = { self.busy and "working…" or (self.session_id and "ready" or "not started") }
    local opts = self.session_id and self.agent:get_options(self.session_id) or {}
    for _, key in ipairs({ "model", "thought_level", "mode" }) do
        local option = options.find(opts, key)
        if option then
            table.insert(parts, options.current_name(option))
        end
    end
    if twin then
        local status = table.concat(parts, " · "):gsub("%%", "%%%%")
        vim.wo[twin].winbar = ("%%#Title# %s %%*%%= %s "):format(self.agent.name, status)
    end
    if iwin then
        vim.wo[iwin].winbar = " prompt %= <CR> send · @ file · <C-c> cancel · go options · q close "
    end
end

function Chat:_set_busy(busy)
    self.busy = busy
    self:_refresh_winbar()
end

function Chat:_scroll()
    local twin = self:wins()
    if twin and twin ~= vim.api.nvim_get_current_win() then
        vim.api.nvim_win_set_cursor(twin, { vim.api.nvim_buf_line_count(self.transcript), 0 })
    end
end

---Run `fn` with the transcript temporarily modifiable.
function Chat:_edit(fn)
    local buf = self.transcript
    vim.bo[buf].modifiable = true
    local ok, err = pcall(fn, buf)
    vim.bo[buf].modifiable = false
    self:_scroll()
    require("conduit.ui.render").refresh(buf)
    if not ok then
        error(err)
    end
end

---Append `text` to the end of the transcript, continuing the last line.
---@param text string
function Chat:_append_text(text)
    if text == "" then
        return
    end
    self:_edit(function(buf)
        local last = vim.api.nvim_buf_line_count(buf) - 1
        local col = #vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
        vim.api.nvim_buf_set_text(buf, last, col, last, col, vim.split(text, "\n", { plain = true }))
    end)
end

---Append whole lines; returns the 0-based row of the first appended line.
---@param lines string[]
---@return integer
function Chat:_append_lines(lines)
    local row = 0
    self:_edit(function(buf)
        local n = vim.api.nvim_buf_line_count(buf)
        local empty = n == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
        row = empty and 0 or n
        vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, lines)
    end)
    return row
end

---Start a new transcript section unless we're already in one of this kind.
function Chat:_section(kind, header)
    if self.last_kind == kind then
        return
    end
    self.last_kind = kind
    -- The trailing empty line is where streamed text continues.
    self:_append_lines({ "", header, "", "" })
end

---@param tool table
local function tool_line(tool)
    return ("%s %s"):format(status_icons[tool.status or "pending"] or "•", tool.title or tool.kind or "tool call")
end

---@param update table ACP SessionUpdate
function Chat:on_update(update)
    local kind = update.sessionUpdate
    if kind == "agent_message_chunk" then
        self:_section("agent", "## " .. self.agent.name)
        self:_append_text(content_text(update.content))
    elseif kind == "agent_thought_chunk" then
        self:_section("thought", "### Thinking")
        self:_append_text(content_text(update.content))
    elseif kind == "user_message_chunk" then
        self:_section("user", "## You")
        self:_append_text(content_text(update.content))
    elseif kind == "tool_call" then
        self.last_kind = "tool"
        local tool = vim.deepcopy(update)
        local row = self:_append_lines({ "", tool_line(tool) }) + 1
        tool.mark = vim.api.nvim_buf_set_extmark(self.transcript, ns, row, 0, {})
        self.tools[update.toolCallId] = tool
    elseif kind == "tool_call_update" then
        local tool = self.tools[update.toolCallId]
        if not tool then
            return self:on_update(vim.tbl_extend("force", update, { sessionUpdate = "tool_call" }))
        end
        for k, v in pairs(update) do
            if k ~= "sessionUpdate" then
                tool[k] = v
            end
        end
        local pos = vim.api.nvim_buf_get_extmark_by_id(self.transcript, ns, tool.mark, {})
        if pos[1] then
            self:_edit(function(buf)
                vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + 1, false, { tool_line(tool) })
            end)
        end
    elseif kind == "plan" then
        local lines = { "", "### Plan" }
        for _, entry in ipairs(update.entries or {}) do
            table.insert(lines, ("- %s %s"):format(plan_icons[entry.status] or "[ ]", entry.content))
        end
        local pos = self.plan and vim.api.nvim_buf_get_extmark_by_id(self.transcript, ns, self.plan.mark, {})
        if pos and pos[1] then
            -- Plans are sent in full each time; replace this turn's plan in place.
            self:_edit(function(buf)
                vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + self.plan.size, false, lines)
            end)
            self.plan.size = #lines
        else
            local row = self:_append_lines(lines)
            self.plan = { mark = vim.api.nvim_buf_set_extmark(self.transcript, ns, row, 0, {}), size = #lines }
            self.last_kind = "plan"
        end
    elseif kind == "available_commands_update" then
        self.commands = update.availableCommands
    elseif kind == "current_mode_update" or kind == "config_option_update" then
        -- The agent keeps the option state; just redraw.
        self:_refresh_winbar()
    end
end

function Chat:request_permission(params, respond)
    local call = params.toolCall or {}
    local known = self.tools[call.toolCallId] or {}
    local title = call.title or known.title or "run a tool"
    require("conduit.ui.permission").ask(self.agent.name, title, params, respond)
end

function Chat:on_agent_exit(code)
    self.session_id = nil
    self:_set_busy(false)
    self:_notice(("agent exited (code %d)"):format(code))
end

---@param msg string
function Chat:_notice(msg)
    self.last_kind = nil
    self:_append_lines({ "", "> " .. msg })
end

---Start the agent and session if needed.
---@param cb fun(err: string?)
function Chat:ensure_session(cb)
    if self.session_id then
        return cb(nil)
    end
    self.agent:start(function(err)
        if err then
            return cb(err)
        end
        self.agent:new_session(vim.fn.getcwd(), self, function(serr, session_id)
            self.session_id = session_id
            self:_refresh_winbar()
            cb(serr)
        end)
    end)
end

---Take over an existing session, rendering its history so far.
---@param session_id string
---@param history { role: "user"|"agent", text: string }[]
function Chat:adopt(session_id, history)
    self.session_id = session_id
    for _, msg in ipairs(history) do
        if msg.role == "user" then
            self:_section("user", "## You")
        else
            self:_section("agent", "## " .. self.agent.name)
        end
        self:_append_text(msg.text)
    end
    self:_refresh_winbar()
end

---Pick a session option (model, effort, mode, ...) and apply it.
---@param key? string Option id or category; prompts for one when omitted
---@param value? string Value to set; prompts for one when omitted
function Chat:pick_option(key, value)
    self:ensure_session(function(err)
        if err then
            return self:_notice("error: " .. err)
        end
        local sid = assert(self.session_id)
        local function apply(option, v)
            self.agent:set_option(sid, option.id, v, function(serr)
                if serr then
                    return vim.notify("[conduit] " .. serr, vim.log.levels.ERROR)
                end
                self:_refresh_winbar()
            end)
        end
        local opts = self.agent:get_options(sid)
        local option = key and options.find(opts, key)
        if option and value then
            return apply(option, value)
        end
        options.pick(opts, key, apply)
    end)
end

---Send the input buffer as a prompt.
function Chat:submit()
    if self.busy then
        return vim.notify("[conduit] agent is still working, <C-c> to cancel", vim.log.levels.WARN)
    end
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(self.input, 0, -1, false), "\n"))
    if text == "" then
        return
    end
    vim.api.nvim_buf_set_lines(self.input, 0, -1, false, {})
    self.plan = nil
    self:_section("user", "## You")
    self:_append_text(text)
    self:_set_busy(true)

    self:ensure_session(function(err)
        if err then
            self:_set_busy(false)
            return self:_notice("error: " .. err)
        end
        local blocks = require("conduit.mentions").blocks(text, self.agent)
        self.agent:prompt(assert(self.session_id), blocks, function(perr, result)
            self:_set_busy(false)
            if perr then
                self:_notice("error: " .. perr)
            elseif result and result.stopReason ~= "end_turn" then
                self:_notice("stopped: " .. tostring(result.stopReason))
            end
        end)
    end)
end

function Chat:cancel()
    if self.busy and self.session_id then
        self.agent:cancel(self.session_id)
    end
end

---Append text to the input buffer (e.g. a code selection as context).
---@param lines string[]
function Chat:add_context(lines)
    local existing = vim.api.nvim_buf_get_lines(self.input, 0, -1, false)
    local empty = #existing == 1 and existing[1] == ""
    vim.api.nvim_buf_set_lines(self.input, empty and 0 or -1, -1, false, lines)
end

function Chat:destroy()
    self:close()
    if self.session_id then
        self.agent.sessions[self.session_id] = nil
    end
    for _, buf in ipairs({ self.input, self.transcript }) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
end

return Chat
