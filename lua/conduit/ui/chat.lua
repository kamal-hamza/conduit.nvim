--- A chat: one ACP session rendered as a markdown transcript plus an input buffer.
local component = require("conduit.ui.component")
local config = require("conduit.config")
local status = require("conduit.ui.status")
local surface = require("conduit.ui.surface")
local tool_ui = require("conduit.ui.tool")

local ns = vim.api.nvim_create_namespace("conduit")
local placeholder_ns = vim.api.nvim_create_namespace("conduit.placeholder")
-- One mark per section header (`## You`, `## agent`, `### Thinking`), so headers
-- are told apart from markdown headings inside messages.
local sections_ns = vim.api.nvim_create_namespace("conduit.sections")
-- Decorations redrawn from the section marks: role rules, user-turn shading, folds.
local decor_ns = vim.api.nvim_create_namespace("conduit.decor")

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
---@field tools table<string, conduit.ChatTool>
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
---@field following table<conduit.ChatTool, conduit.Terminal> Terminals whose output tool calls show live
---@field spinner conduit.Spinner Animates the state chip while busy
---@field opts_model conduit.OptionsModel Headless session options (model, effort, mode)
---@field actions table<string, fun()> Chip click handlers (with `ui.mouse`)
---@field mounts { chips: conduit.Mount, placeholder: conduit.Mount }
---@field sections table<integer, conduit.ChatSection> Section headers by mark id
---@field decorate_queued? boolean
local Chat = {}

---@class conduit.ChatSection
---@field kind "user"|"agent"|"thought"
---@field label string
---@field fold? conduit.FoldModel Thinking sections fold, closed by default
Chat.__index = Chat

---Accumulated `tool_call` + `tool_call_update` fields, plus where the call is drawn.
---@class conduit.ChatTool
---@field toolCallId string
---@field title? string
---@field kind? string
---@field status? string
---@field content? table[]
---@field locations? { path: string, line?: integer }[]
---@field block? { mark: integer, size: integer } First line and line count in the transcript
---@field expanded? boolean Shown without the preview limits
---@field _meta? table May name a display terminal (`terminal_info`)
---@field redraw_queued? boolean A redraw for new terminal output is pending

local count = 0

-- Redraw a tool call for new terminal output at most this often.
local REDRAW_MS = 50

local content_text = tool_ui.content_text

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
    local self =
        setmetatable({ agent = agent, busy = false, tools = {}, following = {}, sections = {}, last_kind = nil }, Chat)
    self.transcript = scratch(("conduit://%s/%d"):format(agent.name, count), "conduit")
    self.input = scratch(("conduit://%s/%d/input"):format(agent.name, count), "conduit_input")
    vim.bo[self.transcript].modifiable = false
    require("conduit.ui.render").attach(self.transcript)
    require("conduit.mentions").attach(self.input, {
        commands = function()
            return self.agent:get_commands(self.session_id)
        end,
    })
    self.opts_model = require("conduit.ui.headless.options").new(function()
        return self.session_id and self.agent:get_options(self.session_id) or {}
    end, function(option, value)
        self:_apply_option(option, value)
    end)
    self.actions = {
        model = function()
            self:pick_option("model")
        end,
        effort = function()
            self:pick_option("effort")
        end,
        mode = function()
            self:pick_option("mode")
        end,
    }
    self.spinner = require("conduit.ui.spinner").new(function()
        self.mounts.chips:update()
    end)
    self.mounts = {
        chips = component.mount(
            surface.winbar(function()
                return select(2, self:wins())
            end),
            "ChipBar",
            function()
                return { status = status.of_chat(self), actions = self.actions }
            end
        ),
        placeholder = component.mount(
            surface.extmark(self.input, placeholder_ns, function()
                return 0, 0
            end, { virt_text_pos = "overlay" }),
            "Placeholder",
            function()
                local lines = vim.api.nvim_buf_get_lines(self.input, 0, -1, false)
                if #lines > 1 or (lines[1] or "") ~= "" then
                    return nil
                end
                return { hints = self:_hints() }
            end
        ),
    }
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
        buffer = self.input,
        callback = function()
            self.mounts.placeholder:update()
        end,
    })
    self:_keymaps()
    return self
end

---Hints for the empty input.
---@return string[]
function Chat:_hints()
    local hints = { "Ask anything", "@ context" }
    if #self.agent:get_commands(self.session_id) > 0 then
        table.insert(hints, "/ commands")
    end
    local help = config.options.ui.keys.help
    if help then
        table.insert(hints, help .. " keys")
    end
    return hints
end

---Keys of the chat, for `g?`.
---@return [string, string][]
function Chat:_help()
    local k = config.options.ui.keys
    local rk = config.options.review.keys or {}
    local out = {
        { "<CR>", "send (normal mode)" },
        { "<C-s>", "send (insert mode)" },
        { "<C-c>", "cancel the turn" },
        { "@", "attach a file, @buffer, @selection, @diagnostics, ..." },
        { "/", "at the start: run an agent command" },
    }
    local optional = {
        { k.model, "pick the model" },
        { k.effort_next, "next effort level (takes a count)" },
        { k.effort_prev, "previous effort level (takes a count)" },
        { k.mode_next, "next mode (takes a count)" },
        { k.options, "pick any session option" },
    }
    for _, o in ipairs(optional) do
        if o[1] then
            table.insert(out, o)
        end
    end
    vim.list_extend(out, {
        { "gs", "pick a thread" },
        { "gn", "new thread" },
        { "]t, [t", "next / previous thread" },
        { "g<Tab>", "alternate thread" },
        { "<CR>", "transcript: expand or collapse a tool call or thinking" },
        { "gd", "transcript: the tool call's diff" },
        { "gf", "transcript: the file the tool call touched" },
    })
    if rk.accept_file then
        table.insert(out, { rk.accept_file, "transcript: accept the tool call's changes" })
    end
    if rk.reject_file then
        table.insert(out, { rk.reject_file, "transcript: reject the tool call's changes" })
    end
    table.insert(out, { "q", "close the chat" })
    if k.help then
        table.insert(out, { k.help, "this list (/ filters)" })
    end
    return out
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
    local function tmap(lhs, fn, fallback, desc)
        vim.keymap.set("n", lhs, function()
            if not fn() then
                vim.cmd.normal({ fallback, bang = true })
            end
        end, { buffer = self.transcript, desc = desc })
    end
    tmap("<CR>", function()
        return self:toggle_tool() or self:toggle_fold()
    end, vim.keycode("<CR>"), "Expand or collapse the tool call or thinking")
    tmap("gd", function()
        return self:open_tool_diff()
    end, "gd", "Show the tool call's diff")
    tmap("gf", function()
        return self:open_tool_location()
    end, "gf", "Open the file the tool call touched")
    local rkeys = config.options.review.keys or {}
    if rkeys.accept_file then
        tmap(rkeys.accept_file, function()
            return self:review_tool("accept")
        end, rkeys.accept_file, "Accept the tool call's changes")
    end
    if rkeys.reject_file then
        tmap(rkeys.reject_file, function()
            return self:review_tool("reject")
        end, rkeys.reject_file, "Reject the tool call's changes")
    end
    for _, buf in ipairs({ self.input, self.transcript }) do
        vim.keymap.set("n", "q", function()
            self:close()
        end, { buffer = buf, desc = "Close chat" })
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
    self:_option_keymaps()
end

---Keys for options and help (`ui.keys`), in both buffers.
function Chat:_option_keymaps()
    local k = config.options.ui.keys
    ---@type [string|false, string|string[], fun(), string][]
    local maps = {
        {
            k.model,
            { "n", "i" },
            function()
                self:pick_option("model")
            end,
            "Pick the model",
        },
        {
            k.effort_next,
            { "n", "i" },
            function()
                self:cycle_option("effort", vim.v.count1)
            end,
            "Next effort level",
        },
        {
            k.effort_prev,
            { "n", "i" },
            function()
                self:cycle_option("effort", -vim.v.count1)
            end,
            "Previous effort level",
        },
        {
            k.mode_next,
            "n",
            function()
                self:cycle_option("mode", vim.v.count1)
            end,
            "Next mode",
        },
        {
            k.options,
            "n",
            function()
                self:pick_option()
            end,
            "Session options (model, effort, mode)",
        },
        {
            k.help,
            "n",
            function()
                require("conduit.ui.help_float").open("conduit chat", self:_help())
            end,
            "Show keys",
        },
    }
    for _, m in ipairs(maps) do
        if m[1] then
            for _, buf in ipairs({ self.input, self.transcript }) do
                vim.keymap.set(m[2], m[1], m[3], { buffer = buf, desc = m[4] })
            end
        end
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
        -- Hides markdown markup and folded thinking (`conceal_lines` needs it).
        vim.wo[win].conceallevel = 2
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
    local twin = self:wins()
    local threads = require("conduit.threads")
    -- The thread bar takes the transcript's winbar; status chips are always in
    -- the input's.
    if twin then
        if config.options.ui.thread_bar and threads.index(self) ~= nil then
            vim.wo[twin].winbar = threads.bar(self, vim.api.nvim_win_get_width(twin) - 1)
        else
            vim.wo[twin].winbar = surface.statusline(component.render("TitleBar", {
                agent = self.agent.name,
                title = self:display_title(),
                index = threads.index(self),
                count = #threads.list,
            }))
        end
    end
    self.mounts.chips:update(true)
    self.mounts.placeholder:update()
    self:_queue_decorate()
end

function Chat:_set_busy(busy)
    self.busy = busy
    if busy then
        self.spinner:start()
    else
        self.spinner:stop()
    end
    status.emit()
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
---@param fn fun(buf: integer)
---@param keep_view? boolean Don't scroll to the end (the user is editing in place)
function Chat:_edit(fn, keep_view)
    local buf = self.transcript
    vim.bo[buf].modifiable = true
    local ok, err = pcall(fn, buf)
    vim.bo[buf].modifiable = false
    -- A replay can be thousands of chunks; scroll and render once at the end.
    if not self.replaying then
        if not keep_view then
            self:_scroll()
        end
        require("conduit.ui.render").refresh(buf)
    end
    self:_queue_decorate()
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
    local row = self:_append_lines({ "", header, "", "" })
    self:_mark_section(row + 1, kind)
    return true
end

---Remember a section header at `row`.
---@param row integer 0-based
---@param kind string
function Chat:_mark_section(row, kind)
    if kind ~= "user" and kind ~= "agent" and kind ~= "thought" then
        return
    end
    local id = vim.api.nvim_buf_set_extmark(self.transcript, sections_ns, row, 0, {})
    self.sections[id] = {
        kind = kind,
        label = kind == "user" and "You" or self.agent.name,
        fold = kind == "thought" and require("conduit.ui.headless.fold").new(false) or nil,
    }
end

---Redraw decorations once this tick's edits are done.
function Chat:_queue_decorate()
    if self.decorate_queued then
        return
    end
    self.decorate_queued = true
    vim.schedule(function()
        self.decorate_queued = false
        self:_decorate()
    end)
end

---Draw the transcript's decorations from its section marks. The buffer itself
---stays plain markdown (for yank, search and copies); headers are drawn over:
---`## You` and the turn's first `## agent` become labelled rules, later agent
---headers in the same turn are hidden, user turns are shaded, and thinking
---sections fold to one line.
function Chat:_decorate()
    local buf = self.transcript
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, decor_ns, 0, -1)
    local component = require("conduit.ui.component")
    local marks = vim.api.nvim_buf_get_extmarks(buf, sections_ns, 0, -1, {})
    local count = vim.api.nvim_buf_line_count(buf)
    local twin = self:wins()
    local width = 80
    if twin then
        width = vim.api.nvim_win_get_width(twin) - vim.fn.getwininfo(twin)[1].textoff
    end
    local function decor(row, opts)
        opts.priority = 200
        pcall(vim.api.nvim_buf_set_extmark, buf, decor_ns, row, 0, opts)
    end
    local prev ---@type conduit.ChatSection?
    for i, m in ipairs(marks) do
        local row, sec = m[2], self.sections[m[1]]
        if sec then
            -- The section runs to the blank line before the next header.
            local stop = marks[i + 1] and marks[i + 1][2] - 2 or count - 1
            local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
            local pad = (" "):rep(math.max(0, vim.fn.strdisplaywidth(lines[1] or "") - width))
            if sec.kind == "thought" then
                local fold = assert(sec.fold)
                local n = 0
                for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, row + 1, stop + 1, false)) do
                    n = n + (vim.trim(line) ~= "" and 1 or 0)
                end
                local spans = component.render("ThinkingFold", { lines = n, open = fold.open })
                local text = component.text(spans)
                spans[#spans + 1] = { (" "):rep(math.max(0, width - vim.fn.strdisplaywidth(text))) .. pad }
                decor(row, { virt_text = require("conduit.ui.surface").chunks(spans), virt_text_pos = "overlay" })
                if not fold.open and stop > row then
                    -- One ranged mark (end_row is inclusive) however long the thinking.
                    decor(row + 1, { end_row = stop, conceal_lines = "" })
                end
            elseif sec.kind == "agent" and prev and prev.kind ~= "user" then
                -- The agent picking up after a tool call or thinking: no new rule.
                decor(row, { end_row = math.min(row + 1, math.max(row, stop)), conceal_lines = "" })
            else
                local spans = component.render("RoleRule", { label = sec.label, role = sec.kind, width = width })
                decor(row, { virt_text = require("conduit.ui.surface").chunks(spans), virt_text_pos = "overlay" })
                if sec.kind == "user" and stop >= row + 2 then
                    decor(row + 2, { end_row = stop, line_hl_group = "ConduitUserTurn" })
                end
            end
            prev = sec
        end
    end
end

---Open or close the thinking section under the cursor (or at `row`).
---@param row? integer 0-based
---@return boolean toggled
function Chat:toggle_fold(row)
    local twin = self:wins()
    if not row then
        if not twin then
            return false
        end
        row = vim.api.nvim_win_get_cursor(twin)[1] - 1
    end
    local marks = vim.api.nvim_buf_get_extmarks(self.transcript, sections_ns, { row, 0 }, 0, { limit = 1 })
    local m = marks[1]
    local sec = m and self.sections[m[1]]
    if not sec or not sec.fold then
        return false
    end
    -- Only from the header, or from inside an open section.
    if m[2] ~= row and not sec.fold.open then
        return false
    end
    sec.fold:toggle()
    self:_decorate()
    if twin and not sec.fold.open then
        vim.api.nvim_win_set_cursor(twin, { m[2] + 1, 0 })
    end
    return true
end

---Recreate section marks from header lines (for transcripts copied as text).
function Chat:_rescan_sections()
    local headers = { ["## You"] = "user", ["## " .. self.agent.name] = "agent", ["### Thinking"] = "thought" }
    local lines = vim.api.nvim_buf_get_lines(self.transcript, 0, -1, false)
    for i, line in ipairs(lines) do
        local kind = headers[line]
        if kind and (i == 1 or lines[i - 1] == "") then
            self:_mark_section(i - 1, kind)
        end
    end
end

---Stop following terminal output.
function Chat:_unfollow()
    for tool, term in pairs(self.following) do
        term:unsubscribe(tool)
    end
    self.following = {}
end

---Redraw a tool call as its terminals produce output (debounced).
---@param tool conduit.ChatTool
function Chat:_follow_terminals(tool)
    for _, id in ipairs(tool_ui.terminal_ids(tool)) do
        local term = self.agent:terminal(id)
        if term and self.following[tool] ~= term then
            local old = self.following[tool] ---@type conduit.Terminal?
            if old then
                old:unsubscribe(tool)
            end
            self.following[tool] = term
            term:subscribe(tool, function()
                if tool.redraw_queued then
                    return
                end
                tool.redraw_queued = true
                vim.defer_fn(function()
                    tool.redraw_queued = false
                    if self.tools[tool.toolCallId] == tool and vim.api.nvim_buf_is_valid(self.transcript) then
                        self:_render_tool(tool)
                    end
                end, REDRAW_MS)
            end)
        end
    end
end

---Empty the transcript (before replaying a session into it).
function Chat:_clear()
    self:_unfollow()
    self:_edit(function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        vim.api.nvim_buf_clear_namespace(buf, sections_ns, 0, -1)
    end)
    self.tools, self.plan, self.last_kind, self.message_id = {}, nil, nil, nil
    self.sections = {}
end

---Replace the transcript with a copy of `other`'s (e.g. for a fork).
---@param other conduit.Chat
function Chat:copy_transcript(other)
    local lines = vim.api.nvim_buf_get_lines(other.transcript, 0, -1, false)
    self:_clear()
    self:_edit(function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end)
    self:_rescan_sections()
    -- Keep the tool blocks expandable in the copy.
    for id, tool in pairs(other.tools) do
        local block = tool.block
        local pos = block and vim.api.nvim_buf_get_extmark_by_id(other.transcript, ns, block.mark, {})
        if block and pos and #pos > 0 then
            local copy = vim.deepcopy(tool)
            copy.redraw_queued = nil
            copy.block = {
                mark = vim.api.nvim_buf_set_extmark(self.transcript, ns, pos[1], 0, { right_gravity = false }),
                size = block.size,
            }
            self.tools[id] = copy
        end
    end
end

---@param tool conduit.ChatTool
---@return string[]
function Chat:_tool_lines(tool)
    local opts = config.options.tools
    return tool_ui.lines(tool, {
        expanded = tool.expanded,
        cwd = self.cwd or vim.fn.getcwd(),
        diff_lines = opts.diff_lines,
        output_lines = opts.output_lines,
        hide_output = opts.hide_output or {},
        terminal = function(id)
            return self.agent:terminal(id)
        end,
        review = require("conduit.review").tool_state(self, tool.toolCallId),
    })
end

---The review state of a tool call's files changed: redraw its status line.
---@param id string
function Chat:review_changed(id)
    local tool = self.tools[id]
    if tool and tool.block and vim.api.nvim_buf_is_valid(self.transcript) then
        self:_render_tool(tool, true)
    end
end

---Accept or reject every change in the files the tool call at the cursor touched.
---@param action "accept"|"reject"
---@return boolean found
function Chat:review_tool(action)
    local tool = self:_tool_at_cursor()
    if not tool then
        return false
    end
    local review = require("conduit.review")
    local paths = {} ---@type string[]
    for _, file in ipairs(review.list()) do
        for _, src in pairs(file.sources) do
            if src.handler == self and src.id == tool.toolCallId then
                table.insert(paths, file.path)
                break
            end
        end
    end
    if #paths == 0 then
        vim.notify("[conduit] this tool call has no changes to review", vim.log.levels.INFO)
    end
    for _, path in ipairs(paths) do
        review[action](path)
    end
    return true
end

---Draw a tool call: append its block, or redraw it in place.
---@param tool conduit.ChatTool
---@param keep_view? boolean Don't scroll to the end
function Chat:_render_tool(tool, keep_view)
    local lines = self:_tool_lines(tool)
    local block = tool.block
    local pos = block and vim.api.nvim_buf_get_extmark_by_id(self.transcript, ns, block.mark, {})
    if block and pos and #pos > 0 then
        self:_edit(function(buf)
            vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + block.size, false, lines)
        end, keep_view)
        block.size = #lines
        return
    end
    self.last_kind = "tool"
    local row = self:_append_lines(vim.list_extend({ "" }, lines)) + 1
    -- Left gravity: redrawing the block replaces the marked line, which must not
    -- push the mark onto the line below.
    tool.block = {
        mark = vim.api.nvim_buf_set_extmark(self.transcript, ns, row, 0, { right_gravity = false }),
        size = #lines,
    }
end

---The tool call drawn at a transcript row.
---@param row integer 0-based
---@return conduit.ChatTool?
function Chat:tool_at(row)
    for _, tool in pairs(self.tools) do
        local block = tool.block
        local pos = block and vim.api.nvim_buf_get_extmark_by_id(self.transcript, ns, block.mark, {})
        if block and pos and #pos > 0 and row >= pos[1] and row < pos[1] + block.size then
            return tool
        end
    end
end

---@return conduit.ChatTool?
function Chat:_tool_at_cursor()
    if vim.api.nvim_get_current_buf() ~= self.transcript then
        return nil
    end
    return self:tool_at(vim.api.nvim_win_get_cursor(0)[1] - 1)
end

---Expand or collapse the tool call at `row` (default: the cursor's).
---@param row? integer 0-based
---@return boolean toggled
function Chat:toggle_tool(row)
    local tool ---@type conduit.ChatTool?
    if row then
        tool = self:tool_at(row)
    else
        tool = self:_tool_at_cursor()
    end
    if not tool then
        return false
    end
    tool.expanded = not tool.expanded
    self:_render_tool(tool, true)
    -- Keep the cursor on the block's header line when it shrinks from under it.
    local twin = vim.fn.bufwinid(self.transcript)
    local pos = vim.api.nvim_buf_get_extmark_by_id(self.transcript, ns, assert(tool.block).mark, {})
    if twin ~= -1 and #pos > 0 and not tool.expanded then
        local cur = vim.api.nvim_win_get_cursor(twin)
        if cur[1] - 1 >= pos[1] + assert(tool.block).size then
            vim.api.nvim_win_set_cursor(twin, { pos[1] + 1, 0 })
        end
    end
    return true
end

---A normal window to open files in, away from the chat.
---@return integer
function Chat:_target_win()
    local twin, iwin = self:wins()
    local function usable(win)
        return win ~= 0
            and vim.api.nvim_win_is_valid(win)
            and win ~= twin
            and win ~= iwin
            and vim.fn.win_gettype(win) == "" -- not a float, preview or command-line window
    end
    local prev = vim.fn.win_getid(vim.fn.winnr("#"))
    if usable(prev) then
        return prev
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if usable(win) then
            return win
        end
    end
    vim.cmd("topleft vsplit")
    return vim.api.nvim_get_current_win()
end

---Open the first file the tool call at the cursor touched (`gf`).
---@return boolean opened
function Chat:open_tool_location()
    local tool = self:_tool_at_cursor()
    if not tool then
        return false
    end
    local loc = (tool.locations or {})[1]
    local diff = tool_ui.diffs(tool)[1]
    local path = loc and loc.path or diff and diff.path
    if not path then
        vim.notify("[conduit] this tool call has no file location", vim.log.levels.INFO)
        return true
    end
    local win = self:_target_win()
    vim.api.nvim_set_current_win(win)
    vim.cmd.edit(vim.fn.fnameescape(path))
    if loc and type(loc.line) == "number" then
        local line = math.max(1, math.min(loc.line, vim.api.nvim_buf_line_count(0)))
        vim.api.nvim_win_set_cursor(win, { line, 0 })
    end
    return true
end

local diff_count = 0

---Show a diff entry side by side in a new tab, with 'diff' mode on.
---@param entry conduit.ToolDiff
function Chat.open_diff(entry)
    diff_count = diff_count + 1
    local ft = vim.filetype.match({ filename = entry.path })
    local function side(label, text)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = "wipe"
        vim.api.nvim_buf_set_name(buf, ("conduit://diff/%d/%s/%s"):format(diff_count, label, entry.path))
        local lines = type(text) == "string" and text ~= "" and tool_ui.split(text) or {}
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        if ft then
            vim.bo[buf].filetype = ft
        end
        vim.keymap.set("n", "q", function()
            if #vim.api.nvim_list_tabpages() > 1 then
                vim.cmd.tabclose()
            else
                vim.cmd("only | enew")
            end
        end, { buffer = buf, desc = "Close diff" })
        return buf
    end
    local old, new = side("old", entry.oldText), side("new", entry.newText)
    vim.cmd("tab sbuffer " .. old)
    local owin = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vertical sbuffer " .. new)
    local nwin = vim.api.nvim_get_current_win()
    local path = vim.fn.fnamemodify(entry.path, ":~:.")
    for win, label in pairs({ [owin] = "before", [nwin] = "after" }) do
        vim.wo[win].winbar = ("%s: %s"):format(label, (path:gsub("%%", "%%%%")))
        vim.api.nvim_win_call(win, function()
            vim.cmd.diffthis()
        end)
    end
end

---Open the diff of the tool call at the cursor (`gd`), picking one if it has several.
---@return boolean found
function Chat:open_tool_diff()
    local tool = self:_tool_at_cursor()
    if not tool then
        return false
    end
    local diffs = tool_ui.diffs(tool)
    if #diffs == 0 then
        vim.notify("[conduit] this tool call has no diff", vim.log.levels.INFO)
    elseif #diffs == 1 then
        Chat.open_diff(diffs[1])
    else
        vim.ui.select(diffs, {
            prompt = "Diff",
            format_item = function(d)
                return tool_ui.relpath(d.path, self.cwd)
            end,
        }, function(choice)
            if choice then
                Chat.open_diff(choice)
            end
        end)
    end
    return true
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
        local tool = vim.deepcopy(update)
        tool.sessionUpdate = nil
        ---@cast tool conduit.ChatTool
        self.tools[update.toolCallId] = tool
        self:_render_tool(tool)
        self:_follow_terminals(tool)
    elseif kind == "tool_call_update" then
        local tool = self.tools[update.toolCallId]
        if not tool then
            return self:on_update(vim.tbl_extend("force", update, { sessionUpdate = "tool_call" }))
        end
        -- Fields that are present replace the old ones, `content` and `locations` included.
        for k, v in pairs(update) do
            if k == "_meta" and type(v) == "table" and type(tool._meta) == "table" then
                -- Later updates carry only their own keys (terminal output, exit);
                -- keep the earlier ones, such as `terminal_info`.
                tool._meta = vim.tbl_extend("force", tool._meta, v)
            elseif k ~= "sessionUpdate" then
                tool[k] = v
            end
        end
        self:_render_tool(tool)
        self:_follow_terminals(tool)
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
    local permission = require("conduit.ui.permission")
    local call = params.toolCall or {}
    -- `toolCall` is a ToolCallUpdate; it can carry the proposed diff, so draw it
    -- before asking.
    local id = call.toolCallId
    if type(id) == "string" and (self.tools[id] or call.title) then
        self:on_update(vim.tbl_extend("force", call, { sessionUpdate = "tool_call_update" }))
    end
    call = permission.merge(self.tools[call.toolCallId], call)
    self.waiting = true
    require("conduit.threads").changed(self)
    if not self:_visible() then
        self:_alert("needs permission to " .. permission.describe(call).title)
    end
    permission.ask(self.agent.name, call, params, function(err, result)
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

---Set an option on this chat's session, then redraw. With `ui.remember_options`
---the value also becomes the default for new threads.
---@param option conduit.Option
---@param value string
function Chat:_apply_option(option, value)
    local sid = self.session_id
    if not sid then
        return
    end
    self.agent:set_option(sid, option.id, value, function(err)
        if err then
            return vim.notify("[conduit] " .. err, vim.log.levels.ERROR)
        end
        if config.options.ui.remember_options then
            local spec = config.options.agents[self.agent.name]
            if spec then
                spec.options = spec.options or {}
                spec.options[option.category or option.id] = value
            end
        end
        self:_refresh_winbar()
    end)
end

---Pick a session option (model, effort, mode, ...) and apply it.
---@param key? string Option id or category; prompts for one when omitted
---@param value? string Value to set; prompts for one when omitted
function Chat:pick_option(key, value)
    self:ensure_session(function(err)
        if err then
            return self:_notice("error: " .. err)
        end
        if key and value then
            if not self.opts_model:set(key, value) then
                vim.notify(("[conduit] the agent has no %s option"):format(key), vim.log.levels.WARN)
            end
            return
        end
        self.opts_model:open_picker(key)
    end)
end

---Move option `key` `count` steps through its values (negative goes back).
---@param key string Option id or category, e.g. "effort" or "mode"
---@param count? integer
function Chat:cycle_option(key, count)
    self:ensure_session(function(err)
        if err then
            return self:_notice("error: " .. err)
        end
        self.opts_model:cycle(key, count or 1)
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
            local review = require("conduit.review")
            local changed = review.wants(self) and review.pending_count(self) or 0
            if changed > 0 then
                self:_notice(
                    ("%d %s waiting for review · :Conduit review"):format(changed, changed == 1 and "file" or "files")
                )
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
    self.spinner:stop()
    self.mounts.chips:unmount()
    self.mounts.placeholder:unmount()
    self:_unfollow()
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
