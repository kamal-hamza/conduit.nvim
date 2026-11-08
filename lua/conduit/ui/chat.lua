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

local KEYS_HINT = "<CR> send · @ file · <C-c> cancel · go options · gs threads · g<Tab> alternate · q close"

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
---@field title? string Set by the agent (`session_info_update`), the user, or from the first prompt
---@field custom_title? boolean The user named the thread; agent titles don't replace it
---@field cwd? string Working directory of the session
---@field loading? boolean A past session is being loaded
---@field replaying? boolean History is being replayed into the transcript
---@field muted? boolean Ignore replayed content (reloading a session that's already shown)
---@field resume_id? string Session to restore on the next prompt (after the agent exited)
---@field message_id? string ACP `messageId` of the message being rendered
---@field last_kind? string
---@field plan? { mark: integer, size: integer }
---@field last_used? integer When it was last made current (see `conduit.threads`)
---@field unread? boolean Finished a turn while you weren't looking at it
---@field waiting? boolean A permission request is waiting for an answer
local Chat = {}
Chat.__index = Chat

local count = 0

---@param content? table ACP ContentBlock
---@param link_resources? boolean Show embedded resources as links (e.g. replayed @mentions)
---@return string
local function content_text(content, link_resources)
    if not content then
        return ""
    elseif content.type == "text" then
        return content.text or ""
    elseif content.type == "resource_link" then
        return ("[%s](%s)"):format(content.name or content.uri, content.uri)
    elseif content.type == "resource" and content.resource then
        local uri = content.resource.uri or ""
        if link_resources then
            return ("\n[%s](%s)"):format(uri:match("[^/]+/?$") or uri, uri)
        end
        return content.resource.text or ("<%s>"):format(uri)
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
    require("conduit.ui.hl").setup()
    count = count + 1
    local self = setmetatable({ agent = agent, busy = false, tools = {}, last_kind = nil }, Chat)
    self.transcript = scratch(("conduit://%s/%d"):format(agent.name, count), "conduit")
    self.input = scratch(("conduit://%s/%d/input"):format(agent.name, count), "conduit_input")
    vim.bo[self.transcript].modifiable = false
    require("conduit.ui.render").attach(self.transcript)
    require("conduit.mentions").attach(self.input, {
        commands = function()
            return self.agent:get_commands(self.session_id)
        end,
    })
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
        vim.keymap.set("n", "gs", function()
            require("conduit.threads").pick()
        end, { buffer = buf, desc = "Pick a thread" })
        vim.keymap.set("n", "gn", function()
            require("conduit").new(self.agent.name)
        end, { buffer = buf, desc = "New thread" })
        vim.keymap.set("n", "]t", function()
            require("conduit.threads").cycle(1)
        end, { buffer = buf, desc = "Next thread" })
        vim.keymap.set("n", "[t", function()
            require("conduit.threads").cycle(-1)
        end, { buffer = buf, desc = "Previous thread" })
        vim.keymap.set("n", "g<Tab>", function()
            require("conduit.threads").alternate()
        end, { buffer = buf, desc = "Alternate thread" })
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
        vim.api.nvim_win_set_width(twin, width)
        vim.cmd("belowright split")
        iwin = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_height(iwin, ui.input_height)
        self:show(twin, iwin)
    end
    vim.api.nvim_set_current_win(iwin or twin)
end

---Show this chat in existing windows (e.g. when switching threads).
---@param twin integer Transcript window
---@param iwin integer Input window
function Chat:show(twin, iwin)
    vim.api.nvim_win_set_buf(twin, self.transcript)
    vim.api.nvim_win_set_buf(iwin, self.input)
    for _, win in ipairs({ twin, iwin }) do
        vim.wo[win].wrap = true
        vim.wo[win].linebreak = true
        vim.wo[win].number = false
        vim.wo[win].relativenumber = false
        vim.wo[win].signcolumn = "no"
        vim.wo[win].winfixwidth = true
    end
    vim.wo[iwin].winfixheight = true
    self.unread = false
    self:_refresh_winbar()
    self:_scroll()
end

---@return string
function Chat:display_title()
    return self.title or "New thread"
end

---Use the first line of the first prompt as the title until the agent names the session.
---@param text string
function Chat:_default_title(text)
    if self.title then
        return
    end
    local line = vim.trim(vim.split(text, "\n", { plain = true })[1] or "")
    if line ~= "" then
        self.title = vim.fn.strcharlen(line) > 50 and (vim.fn.strcharpart(line, 0, 49) .. "…") or line
    end
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
    local state = self.loading and "loading…"
        or self.busy and "working…"
        or self.session_id and "ready"
        or self.resume_id and "disconnected"
        or "not started"
    local parts = { state }
    local opts = self.session_id and self.agent:get_options(self.session_id) or {}
    for _, key in ipairs({ "model", "thought_level", "mode" }) do
        local option = options.find(opts, key)
        if option then
            table.insert(parts, options.current_name(option))
        end
    end
    local function escape(s)
        return (s:gsub("%%", "%%%%"))
    end
    local threads = require("conduit.threads")
    local status = escape(table.concat(parts, " · "))
    -- The thread bar takes the whole transcript winbar, so state and options move
    -- to the prompt's.
    local bar = config.options.ui.thread_bar and threads.index(self) ~= nil
    if twin then
        if bar then
            vim.wo[twin].winbar = threads.bar(self, vim.api.nvim_win_get_width(twin) - 1)
        else
            local title = ("%s · %s"):format(self.agent.name, self:display_title())
            local i, n = threads.index(self), #threads.list
            if i and n > 1 then
                title = ("%s (%d/%d)"):format(title, i, n)
            end
            vim.wo[twin].winbar = ("%%#Title# %s %%*%%= %s "):format(escape(title), status)
        end
    end
    if iwin then
        local left = bar and escape(self.agent.name) .. " · " .. status or "prompt"
        local keys = KEYS_HINT
        if #self.agent:get_commands(self.session_id) > 0 then
            keys = keys:gsub("@ file · ", "@ file · / command · ", 1)
        end
        vim.wo[iwin].winbar = (" %s %%= %s "):format(left, keys)
    end
end

function Chat:_set_busy(busy)
    self.busy = busy
    require("conduit.threads").changed(self)
end

---Whether you can see this thread: it's current and its windows are open.
---@return boolean
function Chat:_visible()
    return require("conduit.threads").current == self and self:is_open()
end

---Tell the user about a thread they aren't looking at.
---@param msg string
function Chat:_alert(msg)
    if config.options.threads.notify then
        vim.notify(("[conduit] %s: %s"):format(self:display_title(), msg), vim.log.levels.INFO)
    end
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
    -- A replay can be thousands of chunks; scroll and render once at the end.
    if not self.replaying then
        self:_scroll()
        require("conduit.ui.render").refresh(buf)
    end
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
---@param kind string
---@param header string
---@param message_id? string ACP `messageId`; a new id starts a new section of the same kind
---@return boolean started
function Chat:_section(kind, header, message_id)
    if message_id and message_id ~= self.message_id then
        if self.message_id and self.last_kind == kind then
            self.last_kind = nil
        end
        self.message_id = message_id
    end
    if self.last_kind == kind then
        return false
    end
    self.last_kind = kind
    -- The trailing empty line is where streamed text continues.
    self:_append_lines({ "", header, "", "" })
    return true
end

---Empty the transcript (before replaying a session into it).
function Chat:_clear()
    self:_edit(function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end)
    self.tools, self.plan, self.last_kind, self.message_id = {}, nil, nil, nil
end

---Replace the transcript with a copy of `other`'s (e.g. for a fork).
---@param other conduit.Chat
function Chat:copy_transcript(other)
    local lines = vim.api.nvim_buf_get_lines(other.transcript, 0, -1, false)
    self:_clear()
    self:_edit(function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end)
end

---@param tool table
---@return string
local function tool_line(tool)
    local title = tool.title or tool.kind or "tool call"
    -- Titles can span lines (e.g. a multi-line shell command); show the first.
    local first = title:match("^[^\n]*")
    if first ~= title then
        first = first .. " …"
    end
    return ("%s %s"):format(status_icons[tool.status or "pending"] or "•", first)
end

local CONTENT_UPDATES = {
    agent_message_chunk = true,
    agent_thought_chunk = true,
    user_message_chunk = true,
    tool_call = true,
    tool_call_update = true,
    plan = true,
}

---@param update table ACP SessionUpdate
function Chat:on_update(update)
    local kind = update.sessionUpdate
    if self.muted and CONTENT_UPDATES[kind] then
        return
    end
    if kind == "agent_message_chunk" then
        self:_section("agent", "## " .. self.agent.name, update.messageId)
        self:_append_text(content_text(update.content))
    elseif kind == "agent_thought_chunk" then
        self:_section("thought", "### Thinking", update.messageId)
        self:_append_text(content_text(update.content))
    elseif kind == "user_message_chunk" then
        if self:_section("user", "## You", update.messageId) then
            -- A new turn (when replaying): plans are per turn.
            self.plan = nil
        end
        self:_append_text(content_text(update.content, true))
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
        if #pos > 0 then
            self:_edit(function(buf)
                vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + 1, false, { tool_line(tool) })
            end)
        end
    elseif kind == "plan" then
        local lines = { "", "### Plan" }
        for _, entry in ipairs(update.entries or {}) do
            table.insert(lines, ("- %s %s"):format(plan_icons[entry.status] or "[ ]", entry.content))
        end
        local plan = self.plan
        local pos = plan and vim.api.nvim_buf_get_extmark_by_id(self.transcript, ns, plan.mark, {})
        if plan and pos and #pos > 0 then
            -- Plans are sent in full each time; replace this turn's plan in place.
            self:_edit(function(buf)
                vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + plan.size, false, lines)
            end)
            plan.size = #lines
        else
            local row = self:_append_lines(lines)
            self.plan = { mark = vim.api.nvim_buf_set_extmark(self.transcript, ns, row, 0, {}), size = #lines }
            self.last_kind = "plan"
        end
    elseif kind == "available_commands_update" then
        -- The agent keeps the list (see `Agent:get_commands`); show the `/` hint.
        self:_refresh_winbar()
    elseif kind == "session_info_update" then
        -- rpc decodes JSON null as nil, so a cleared title keeps the old one.
        if type(update.title) == "string" and update.title ~= "" and not self.custom_title then
            self.title = update.title
        end
        self:_record(type(update.updatedAt) == "string" and update.updatedAt or nil)
        require("conduit.threads").changed(self)
    elseif kind == "current_mode_update" or kind == "config_option_update" then
        -- The agent keeps the option state; just redraw.
        self:_refresh_winbar()
    end
end

function Chat:request_permission(params, respond)
    local call = params.toolCall or {}
    local known = self.tools[call.toolCallId] or {}
    local title = call.title or known.title or "run a tool"
    self.waiting = true
    require("conduit.threads").changed(self)
    if not self:_visible() then
        self:_alert("needs permission to " .. title)
    end
    require("conduit.ui.permission").ask(self.agent.name, title, params, function(err, result)
        self.waiting = false
        require("conduit.threads").changed(self)
        respond(err, result)
    end)
end

function Chat:on_agent_exit(code)
    -- Keep the transcript and remember the session, to restore it on the next prompt.
    self.resume_id = self.session_id or self.resume_id
    self.session_id = nil
    self.muted, self.replaying = false, false
    self:_set_busy(false)
    self:_notice(("agent exited (code %d)"):format(code))
end

---Save this thread to the local index.
---@param updated_at? string ISO 8601; defaults to now
function Chat:_record(updated_at)
    local sid = self.session_id
    if not sid then
        return
    end
    require("conduit.history").record({
        agent = self.agent.name,
        session_id = sid,
        cwd = self.cwd or vim.fn.getcwd(),
        title = self.title,
        custom_title = self.custom_title or nil,
        updated_at = updated_at,
    })
end

---Name the thread. User titles stick: the agent's generated titles won't replace them.
---Agents that support `session/set_title` store it too.
---@param title string
---@param cb? fun(err: string?)
function Chat:rename(title, cb)
    cb = cb or function() end
    self.title, self.custom_title = title, true
    self:_record()
    require("conduit.threads").changed(self)
    if not self.session_id then
        return cb(nil)
    end
    self.agent:set_title(self.session_id, title, function(err, stored)
        if err then
            return cb(err)
        end
        self.title = stored or title
        self:_record()
        require("conduit.threads").changed(self)
        cb(nil)
    end)
end

---Open a past session in this (empty) chat: load it, replaying its history into
---the transcript, or resume it without history when that's all the agent can do.
---@param info conduit.ThreadInfo
---@param cb? fun(err: string?)
function Chat:load(info, cb)
    cb = cb or function() end
    self.cwd = info.cwd
    self.title = self.title or info.title
    self.custom_title = self.custom_title or info.custom_title
    self.loading = true
    self:_set_busy(true)
    local function opened(err, sid)
        self.loading, self.replaying = false, false
        self:_set_busy(false)
        if err then
            self:_notice("could not open the thread: " .. err)
            return cb(err)
        end
        self.session_id = sid
        self:_record(info.updated_at)
        self:_scroll()
        require("conduit.ui.render").refresh(self.transcript)
        self:_refresh_winbar()
        cb(nil)
    end
    self.agent:start(function(err)
        if err then
            return opened(err)
        end
        local ref = { session_id = info.session_id, cwd = info.cwd }
        if self.agent:supports("load") then
            self:_clear()
            self.replaying = true
            self.agent:load_session(ref, self, opened)
        elseif self.agent:supports("resume") then
            self.agent:resume_session(ref, self, function(rerr, sid)
                if not rerr then
                    self:_notice("resumed; the agent doesn't replay earlier messages")
                end
                opened(rerr, sid)
            end)
        else
            opened(self.agent.name .. " can't load sessions")
        end
    end)
end

---Restore `resume_id` after the agent restarted: resume it, or reload it without
---re-rendering the transcript we still have, or else start over.
---@param cb fun(err: string?)
function Chat:_reconnect(cb)
    local ref = { session_id = assert(self.resume_id), cwd = self.cwd or vim.fn.getcwd() }
    local function done(err, sid)
        self.muted = false
        self.resume_id = nil
        if err then
            self:_notice(("could not restore the session (%s), starting a new one"):format(err))
            return self:ensure_session(cb)
        end
        self.session_id = sid
        self:_record()
        self:_refresh_winbar()
        cb(nil)
    end
    if self.agent:supports("resume") then
        self.agent:resume_session(ref, self, done)
    elseif self.agent:supports("load") then
        self.muted = true
        self.agent:load_session(ref, self, done)
    else
        self.resume_id = nil
        self:_notice(self.agent.name .. " can't restore sessions; starting a new one without the earlier context")
        self:ensure_session(cb)
    end
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
        if self.resume_id then
            return self:_reconnect(cb)
        end
        local cwd = vim.fn.getcwd()
        self.agent:new_session(cwd, self, function(serr, session_id)
            self.session_id = session_id
            self.cwd = cwd
            self:_record()
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
    self.cwd = vim.fn.getcwd()
    for _, msg in ipairs(history) do
        if msg.role == "user" then
            self:_default_title(msg.text)
            self:_section("user", "## You")
        else
            self:_section("agent", "## " .. self.agent.name)
        end
        self:_append_text(msg.text)
    end
    self:_record()
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
    self:_default_title(text)
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
            if require("conduit.threads").index(self) and not self:_visible() then
                self.unread = true
                self:_alert(perr and "the turn failed" or "the agent replied")
            end
            self:_set_busy(false)
            self:_record()
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

---Start the prompt with `/name ` (replacing any command already there) and
---focus the input, ready for the command's arguments.
---@param name string
function Chat:insert_command(name)
    self:open()
    local lines = vim.api.nvim_buf_get_lines(self.input, 0, -1, false)
    local rest = (lines[1] or ""):gsub("^/[^%s/]*%s*", "")
    lines[1] = ("/%s %s"):format(name, rest)
    vim.api.nvim_buf_set_lines(self.input, 0, -1, false, lines)
    local _, iwin = self:wins()
    if iwin then
        vim.api.nvim_set_current_win(iwin)
        if rest == "" then
            vim.api.nvim_win_set_cursor(iwin, { 1, #lines[1] })
            vim.cmd.startinsert({ bang = true })
        else
            -- On the first character after `/name `; insert goes before it.
            vim.api.nvim_win_set_cursor(iwin, { 1, #name + 2 })
            vim.cmd.startinsert()
        end
    end
    require("conduit.commands").update_hint(self.input)
end

---Append text to the input buffer (e.g. a code selection as context).
---@param lines string[]
function Chat:add_context(lines)
    local existing = vim.api.nvim_buf_get_lines(self.input, 0, -1, false)
    local empty = #existing == 1 and existing[1] == ""
    vim.api.nvim_buf_set_lines(self.input, empty and 0 or -1, -1, false, lines)
end

function Chat:destroy()
    self:cancel()
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
