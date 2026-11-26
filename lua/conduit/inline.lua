--- Inline requests on a range of a buffer: the only way to use the agent. In
--- "auto" mode the agent decides whether to rewrite the range in place or
--- answer; "edit" and "ask" force one or the other. Edits land in the file as
--- they're ready (as hunks to review); answers stream into the sidebar, which
--- never takes focus. Each request runs in its own session and is kept in the
--- history.
local config = require("conduit.config")
local hl = require("conduit.ui.hl")

local M = {}

local ns = vim.api.nvim_create_namespace("conduit.inline")

---@class conduit.InlineJob: conduit.SessionHandler
---@field agent conduit.Agent
---@field buf integer
---@field win integer Window the request was made from
---@field line1 integer 1-based first line when the request was made
---@field line2 integer
---@field mode conduit.InlineMode
---@field kind? "edit"|"answer" What the reply turned out to be; nil until known
---@field session_id? string
---@field text string The current turn's reply
---@field history { role: "user"|"agent", text: string }[]
---@field tools table<string, table> Tool calls seen this session, by id
---@field tool_order string[] Tool call ids in the order they started
---@field terminals conduit.Terminal[] Commands run (or refused) through ACP terminals
---@field prior string Earlier turns of the answer conversation, as shown
---@field history_id? string The job's entry in the history
---@field busy boolean
---@field cancelled boolean
---@field detached? boolean The sidebar moved on while this was still answering
---@field marks { first: integer, last: integer, hl?: integer, status?: integer } Extmark ids
---@field spinner conduit.Spinner
---@field phase? string What the agent is doing, while busy
---@field indent string Leading whitespace of the range's first line, for the status line
---@field writes integer `b:conduit_writes` when the request started
---@field cleaned? boolean
local Job = {}
Job.__index = Job

---Jobs with a turn in flight, for :Conduit cancel.
---@type table<conduit.InlineJob, true>
M.jobs = {}

local CONTEXT = [[

Don't use tools to edit the selected lines: the editor applies your replacement itself. If the request needs changes to other files, make them with your tools; the user reviews them. Files and context mentioned with @ in the request are attached.

Request: %s

Lines %d-%d of `%s`:
````%s
%s
````]]

local PROMPTS = {
    auto = [[You are helping with a selection in Neovim. Decide what the request below needs:
- If it asks you to change, fix, add to or rewrite the code, reply with ONLY <replace>, then the full replacement for the selected lines in one fenced code block, then </replace>. No other text.
- Otherwise (a question, an explanation, a review), answer concisely in Markdown, without <replace>.]],
    edit = [[You are making an inline edit in Neovim. Rewrite the selected lines according to the request below.
Reply with ONLY <replace>, then the full replacement for the selected lines in one fenced code block, then </replace>. No other text.]],
    ask = [[You are answering a question about a selection in Neovim. Answer the request below concisely in Markdown. Do not rewrite the code unless asked to show an example.]],
}

local CONTINUE = [[

This continues an earlier conversation about the same lines:
<conversation>
%s
</conversation>]]

local REPLACE = "<replace>"

---Pull the replacement out of a reply: the body of `<replace>…</replace>` if
---present, then everything between the first opening fence and the last
---closing fence, so code that itself contains fences survives.
---@param text string
---@return string
function M.extract(text)
    text = text:match("<replace>(.-)</replace>") or text:match("<replace>(.*)$") or text
    return text:match("```+[^\n]*\n(.*)\n```+") or vim.trim(text)
end

---@return integer? first, integer? last 0-based rows of the range
function Job:_range()
    if not vim.api.nvim_buf_is_valid(self.buf) then
        return nil, nil
    end
    local first = vim.api.nvim_buf_get_extmark_by_id(self.buf, ns, self.marks.first, {})[1]
    local last = vim.api.nvim_buf_get_extmark_by_id(self.buf, ns, self.marks.last, {})[1]
    return first, last
end

---@param msg? string What the agent is doing; nil when it's done
function Job:_status(msg)
    self.phase = msg
    if msg then
        self.spinner:start()
    else
        self.spinner:stop()
    end
    self:_render_status()
end

---Show the spinner above the range, and the phase in the sidebar while it shows this job.
function Job:_render_status()
    local sidebar = require("conduit.ui.sidebar")
    if sidebar.source.job == self then
        sidebar.status()
    end
    local first = self:_range()
    if self.cleaned or not first then
        return
    end
    if not self.phase then
        if self.marks.status then
            vim.api.nvim_buf_del_extmark(self.buf, ns, self.marks.status)
            self.marks.status = nil
        end
        return
    end
    self.marks.status = vim.api.nvim_buf_set_extmark(self.buf, ns, first, 0, {
        id = self.marks.status,
        virt_lines = {
            {
                { self.indent },
                { self.spinner:frame() .. " ", "ConduitSpinner" },
                -- Just the spinner and the agent: what it's doing shows in the sidebar.
                { self.agent.name, "ConduitInlineStatus" },
            },
        },
        virt_lines_above = true,
    })
end

---Decide whether the reply so far is an edit or an answer.
function Job:_route()
    if self.kind then
        return
    end
    if self.mode == "edit" then
        self.kind = "edit"
        return
    elseif self.mode == "ask" then
        return self:_open_answer()
    end
    local head = self.text:gsub("^%s+", "")
    if vim.startswith(head, REPLACE) then
        self.kind = "edit"
    elseif #head >= #REPLACE or not vim.startswith(REPLACE, head) then
        self:_open_answer()
    end
end

---The reply is an explanation: show it in the sidebar, without taking focus.
function Job:_open_answer()
    self.kind = "answer"
    require("conduit.ui.sidebar").show({ job = self })
end

---The window showing the code, if any.
---@return integer?
function Job:_code_win()
    if not vim.api.nvim_buf_is_valid(self.buf) then
        return nil
    end
    if vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_buf(self.win) == self.buf then
        return self.win
    end
    local win = vim.fn.bufwinid(self.buf)
    return win ~= -1 and win or nil
end

---The answer conversation as shown: earlier turns plus the current reply.
---@return string
function Job:_display()
    return self.prior .. self.text
end

---@param id string
---@param fields table
function Job:_tool(id, fields)
    if not self.tools[id] then
        table.insert(self.tool_order, id)
    end
    -- Remember what we learn about tool calls: permission requests may only carry the id.
    self.tools[id] = vim.tbl_extend("force", self.tools[id] or {}, fields)
end

function Job:on_update(update)
    local kind = update.sessionUpdate
    if kind == "agent_message_chunk" and update.content and update.content.type == "text" then
        self.text = self.text .. update.content.text
        self:_route()
        if self.kind == "answer" then
            self:_status("writing…")
            if not self.detached then
                require("conduit.ui.sidebar").update(self)
            end
        elseif self.kind == "edit" then
            -- Completed lines inside the code block streamed so far.
            local _, lines = (self.text:match("```[^\n]*\n(.*)$") or ""):gsub("\n", "")
            self:_status(("writing · %d %s"):format(lines, lines == 1 and "line" or "lines"))
        end
    elseif kind == "agent_thought_chunk" then
        self:_status("thinking…")
    elseif kind == "tool_call" and type(update.toolCallId) == "string" then
        self:_tool(update.toolCallId, update)
        local title = type(update.title) == "string" and update.title:match("^[^\n]*") or nil
        self:_status(title or "running a tool…")
    elseif kind == "tool_call_update" and type(update.toolCallId) == "string" then
        self:_tool(update.toolCallId, update)
    end
end

---@param params table
---@param respond fun(err: table?, result: any)
---@param reason? string Why the sandbox is asking
function Job:request_permission(params, respond, reason)
    local permission = require("conduit.ui.permission")
    local call = params.toolCall or {}
    permission.ask(self.agent.name, permission.merge(self.tools[call.toolCallId], call), params, respond, reason)
end

---@param id string
---@param decision string
---@param reason? string
function Job:on_decision(id, decision, reason)
    if id ~= "" then
        self:_tool(id, { toolCallId = id, decision = decision, reason = reason })
    end
end

---@param term conduit.Terminal
function Job:on_terminal(term)
    table.insert(self.terminals, term)
end

function Job:on_agent_exit(code)
    self.session_id = nil
    self:_turn_done(("agent exited (code %d)"):format(code))
end

---Send `text` (with mention blocks resolved from `request`) as a turn.
---@param text string Full prompt text
---@param request string What the user typed, for mentions and history
---@param extra? table[] Content blocks to send after the mentions
function Job:_send(text, request, extra)
    self.busy = true
    self.text = ""
    M.jobs[self] = true
    table.insert(self.history, { role = "user", text = request })
    local blocks = require("conduit.mentions").blocks(request, self.agent, { buf = self.buf })
    blocks[1] = { type = "text", text = text }
    vim.list_extend(blocks, extra or {})
    self.agent:prompt(assert(self.session_id), blocks, function(err, result)
        if not err and result and result.stopReason == "cancelled" then
            self.cancelled = true
        end
        self:_turn_done(err)
    end)
end

---@param err? string
function Job:_turn_done(err)
    if not self.busy then
        return
    end
    self.busy = false
    M.jobs[self] = nil
    if self.text ~= "" then
        table.insert(self.history, { role = "agent", text = self.text })
    end

    if not self.kind and vim.trim(self.text) ~= "" and not err and not self.cancelled then
        -- A reply too short to have committed either way (e.g. "<rep") is an answer.
        self:_open_answer()
    end

    if self.kind == "answer" then
        if err then
            self.text = self.text .. ("\n\n> error: %s"):format(err)
        elseif self.cancelled then
            self.text = self.text .. "\n\n> cancelled"
            self.cancelled = false
        end
        self:_status(nil)
        self:_undecorate()
        require("conduit.history").record_answer(self)
        if self.detached then
            return self:close()
        end
        require("conduit.ui.sidebar").update(self)
        return
    end

    -- Edit (or nothing at all): apply and finish.
    local first, last = self:_range()
    self:_cleanup()
    local review = require("conduit.review")
    local history = require("conduit.history")
    if self.cancelled then
        return vim.notify("[conduit] inline request cancelled", vim.log.levels.INFO)
    elseif err then
        return vim.notify("[conduit] inline request failed: " .. err, vim.log.levels.ERROR)
    elseif (vim.b[self.buf].conduit_writes or 0) ~= self.writes then
        return vim.notify("[conduit] the agent edited the file directly; not applying its reply", vim.log.levels.WARN)
    elseif not first or not last or vim.trim(self.text) == "" then
        if #self.tool_order > 0 then
            -- It worked through tools alone (e.g. edited other files): keep a record.
            history.record_answer(self)
            return vim.notify("[conduit] the agent replied with tools only; see :Conduit review", vim.log.levels.INFO)
        end
        return vim.notify("[conduit] inline request produced nothing to apply", vim.log.levels.WARN)
    end
    local lines = vim.split(M.extract(self.text), "\n", { plain = true })
    local path = review.wants_replies() and review.snapshot_buf(self, self.buf) or nil
    local old = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
    vim.api.nvim_buf_set_lines(self.buf, first, last + 1, false, lines)
    M.flash(self.buf, first, first + #lines - 1)
    history.record_edit(self, first, old, lines, path ~= nil)
    if path then
        review.link(path, self.history_id)
        review.refresh(path)
    end
end

---Remove the request's highlight and spinner, keeping the range marks (for `a`).
function Job:_undecorate()
    if not vim.api.nvim_buf_is_valid(self.buf) then
        return
    end
    local marks = self.marks
    if marks.hl then
        pcall(vim.api.nvim_buf_del_extmark, self.buf, ns, marks.hl)
        marks.hl = nil
    end
    if marks.status then
        pcall(vim.api.nvim_buf_del_extmark, self.buf, ns, marks.status)
        marks.status = nil
    end
end

---Drop the session and buffer decorations. Idempotent.
function Job:_cleanup()
    if self.cleaned then
        return
    end
    self.cleaned = true
    self.spinner:stop()
    if self.busy then
        self:cancel()
    end
    M.jobs[self] = nil
    if self.session_id then
        self.agent:close_session(self.session_id)
    end
    if vim.api.nvim_buf_is_valid(self.buf) then
        for _, id in pairs(self.marks) do
            pcall(vim.api.nvim_buf_del_extmark, self.buf, ns, id)
        end
    end
end

function Job:close()
    self:_cleanup()
end

---Replace the range with the last code block of the answer.
function Job:apply_code()
    local code = require("conduit.ui.sidebar").last_code_block(self:_display())
    local first, last = self:_range()
    if self.cleaned then
        return vim.notify("[conduit] that request is over", vim.log.levels.WARN)
    elseif not code then
        return vim.notify("[conduit] the answer has no code block to apply", vim.log.levels.WARN)
    elseif not first or not last then
        return vim.notify("[conduit] the original lines are gone", vim.log.levels.WARN)
    end
    local review = require("conduit.review")
    local path = review.wants_replies() and review.snapshot_buf(self, self.buf) or nil
    local old = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
    vim.api.nvim_buf_set_lines(self.buf, first, last + 1, false, code)
    vim.api.nvim_buf_set_extmark(self.buf, ns, first + #code - 1, 0, { id = self.marks.last })
    require("conduit.history").outcome(self, path and "pending" or "applied", { first = first, old = old, new = code })
    if path then
        review.link(path, self.history_id)
        review.refresh(path)
    end
    M.flash(self.buf, first, first + #code - 1)
end

---Ask a follow-up question in the same session.
---@param question? string Prompted for when omitted
function Job:follow_up(question)
    if self.busy then
        return vim.notify("[conduit] still answering, <C-c> to cancel", vim.log.levels.WARN)
    elseif not self.session_id or self.cleaned then
        return vim.notify("[conduit] the session has ended", vim.log.levels.WARN)
    end
    local function send(text)
        self.prior = self:_display() .. ("\n\n---\n\n**You:** %s\n\n"):format(text)
        self.text = ""
        self:_send(text, text)
        require("conduit.ui.sidebar").update(self)
        self:_status("thinking…")
    end
    if question then
        return send(question)
    end
    local anchor ---@type conduit.PromptAnchor?
    local win, first, last = self:_code_win(), self:_range()
    if win and first and last and vim.api.nvim_get_current_win() == win then
        anchor = { win = win, first = first, last = last }
    end
    require("conduit.ui.prompt").open({
        title = "Follow up",
        agent = self.agent.name,
        anchor = anchor,
        commands = function()
            return self.session_id and self.agent:get_commands(self.session_id) or {}
        end,
        on_submit = send,
    })
end

function Job:cancel()
    if not self.busy then
        return
    end
    self.cancelled = true
    if self.session_id then
        self.agent:cancel(self.session_id)
    end
end

---The options an inline request on `agent` would start with: the agent's last
---known options with its defaults and `inline.options` applied. Empty before the
---agent has opened a session.
---@param agent? conduit.Agent
---@return conduit.Option[]
function M.request_options(agent)
    if not agent then
        return {}
    end
    local options = require("conduit.options")
    local list = vim.deepcopy(agent.last_options)
    local defaults = vim.tbl_extend("force", agent.spec.options or {}, config.options.inline.options)
    for key, value in pairs(defaults) do
        local option = options.find(list, key)
        if option then
            option.current = value
        end
    end
    return list
end

---@class conduit.InlineOpts
---@field agent conduit.Agent
---@field buf integer
---@field win? integer
---@field line1 integer 1-based, inclusive
---@field line2 integer 1-based, inclusive
---@field instruction string
---@field mode? conduit.InlineMode Defaults to "auto"
---@field options? table<string, string> Session options for this request, over `inline.options`
---@field continues? conduit.HistoryEntry An earlier answer this request follows up on

---@param opts conduit.InlineOpts
---@return conduit.InlineJob
function M.run(opts)
    hl.setup()
    local buf = opts.buf
    local count = vim.api.nvim_buf_line_count(buf)
    local line2 = math.max(1, math.min(opts.line2, count))
    local line1 = math.max(1, math.min(opts.line1, line2))
    local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
    local self = setmetatable({
        agent = opts.agent,
        buf = buf,
        win = opts.win or vim.api.nvim_get_current_win(),
        line1 = line1,
        line2 = line2,
        mode = opts.mode or "auto",
        text = "",
        prior = "",
        history = {},
        tools = {},
        tool_order = {},
        terminals = {},
        busy = false,
        cancelled = false,
        writes = vim.b[buf].conduit_writes or 0,
        indent = (" "):rep(vim.api.nvim_buf_call(buf, function()
            return vim.fn.indent(line1)
        end)),
        cwd = vim.fn.getcwd(),
    }, Job)
    self.spinner = require("conduit.ui.spinner").new(function()
        self:_render_status()
    end)
    self.marks = {
        first = vim.api.nvim_buf_set_extmark(buf, ns, line1 - 1, 0, {}),
        last = vim.api.nvim_buf_set_extmark(buf, ns, line2 - 1, 0, {}),
        -- One ranged mark puts the line highlight and the sign on every line.
        hl = vim.api.nvim_buf_set_extmark(buf, ns, line1 - 1, 0, {
            end_row = line2 - 1,
            end_col = #(lines[#lines] or ""),
            line_hl_group = "ConduitInlinePending",
            sign_text = "▎",
            sign_hl_group = "ConduitInlineSign",
        }),
    }
    M.jobs[self] = true
    self:_status("starting…")

    local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
    path = path ~= "" and path or "[No Name]"
    local ft = vim.bo[buf].filetype
    local code = table.concat(lines, "\n")
    local prompt, extra
    if opts.continues then
        self.mode = "ask"
        self.prior = (opts.continues.text or "") .. ("\n\n---\n\n**You:** %s\n\n"):format(opts.instruction)
        prompt = PROMPTS.ask
            .. CONTINUE:format(opts.continues.text or "")
            .. CONTEXT:format(opts.instruction, line1, line2, path, ft, code)
    elseif require("conduit.commands").parse(opts.instruction) then
        -- An agent command only runs when the prompt starts with it, so send it
        -- unwrapped with the selection attached, and show the result as an answer.
        self.mode = "ask"
        prompt = opts.instruction
        extra = {
            {
                type = "text",
                text = ("<context name=%q>\nLines %d-%d of `%s`:\n````%s\n%s\n````\n</context>"):format(
                    "selection",
                    line1,
                    line2,
                    path,
                    ft,
                    code
                ),
            },
        }
    else
        prompt = PROMPTS[self.mode] .. CONTEXT:format(opts.instruction, line1, line2, path, ft, code)
    end

    if opts.continues then
        -- Asked from the sidebar: it shows the conversation from the start.
        self:_open_answer()
    end

    local function fail(err)
        self.busy = true
        self:_turn_done(err)
    end
    self.agent:start(function(err)
        if err or self.cancelled then
            return fail(err)
        end
        self.agent:new_session(
            self.cwd,
            self,
            function(serr, sid)
                self.session_id = sid
                if serr or self.cancelled then
                    return fail(serr)
                end
                self:_status("thinking…")
                self:_send(prompt, opts.instruction, extra)
            end,
            vim.tbl_extend("force", config.options.inline.options, opts.options or {}),
            { mcp = config.options.inline.mcp_servers }
        )
    end)
    return self
end

---Follow up on a history entry: a new request on the same lines, with the
---earlier conversation as context, answered in the sidebar.
---@param entry conduit.HistoryEntry
---@param question? string Prompted for when omitted
function M.continue(entry, question)
    local buf = require("conduit.history").entry_buf(entry)
    if not buf then
        return vim.notify("[conduit] that entry's file is gone", vim.log.levels.WARN)
    end
    local agent = require("conduit").agent(entry.agent or config.options.inline.agent)
    if not agent then
        return
    end
    local function run(text)
        if not text or vim.trim(text) == "" then
            return
        end
        local win = vim.fn.bufwinid(buf)
        M.run({
            agent = agent,
            buf = buf,
            win = win ~= -1 and win or require("conduit.ui.sidebar").code_win(),
            line1 = entry.line1,
            line2 = entry.line2,
            instruction = text,
            mode = "ask",
            continues = entry,
        })
    end
    if question then
        return run(question)
    end
    require("conduit.ui.prompt").open({
        title = "Follow up",
        agent = agent.name,
        commands = function()
            return agent:get_commands()
        end,
        on_submit = run,
    })
end

local flash_ns = vim.api.nvim_create_namespace("conduit.inline.flash")

---Briefly highlight rows `first`..`last` (0-based) that an edit just replaced.
---@param buf integer
---@param first integer
---@param last integer
function M.flash(buf, first, last)
    if not vim.api.nvim_buf_is_valid(buf) or last < first then
        return
    end
    local id = vim.api.nvim_buf_set_extmark(buf, flash_ns, first, 0, {
        end_row = last,
        line_hl_group = "ConduitInlineAdded",
    })
    vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_del_extmark, buf, flash_ns, id)
        end
    end, 1500)
end

---Go to `job`'s range in `win` (default: the window showing it, else the current one).
---@param job conduit.InlineJob
---@param win? integer
function M.reveal(job, win)
    if not vim.api.nvim_buf_is_valid(job.buf) then
        return
    end
    win = job:_code_win() or win or vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win)
    if vim.api.nvim_win_get_buf(win) ~= job.buf then
        vim.api.nvim_win_set_buf(win, job.buf)
    end
    local first = job:_range()
    if first then
        vim.api.nvim_win_set_cursor(win, { first + 1, 0 })
    end
end

---Cancel all running inline requests.
---@return boolean any Whether there was anything to cancel
function M.cancel()
    local any = false
    for job in pairs(M.jobs) do
        job:cancel()
        any = true
    end
    return any
end

return M
