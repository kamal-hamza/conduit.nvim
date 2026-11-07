--- Inline requests on a range of a buffer. In "auto" mode the agent decides
--- whether to rewrite the range in place or answer in a float under it; "edit"
--- and "ask" force one or the other. Each request runs in its own session, so it
--- doesn't touch chat history (but can be moved into the chat).
local config = require("conduit.config")
local hl = require("conduit.ui.hl")

local M = {}

local ns = vim.api.nvim_create_namespace("conduit.inline")

---@class conduit.InlineJob: conduit.SessionHandler
---@field agent conduit.Agent
---@field buf integer
---@field win integer Window the request was made from
---@field mode conduit.InlineMode
---@field kind? "edit"|"answer" What the reply turned out to be; nil until known
---@field session_id? string
---@field text string The current turn's reply
---@field shown integer How much of `text` the answer float already shows
---@field history { role: "user"|"agent", text: string }[]
---@field answer? conduit.Answer
---@field busy boolean
---@field cancelled boolean
---@field marks { first: integer, last: integer, hl: integer, status?: integer } Extmark ids
---@field spinner conduit.Spinner
---@field phase? string What the agent is doing, while busy
---@field indent string Leading whitespace of the range's first line, for the status line
---@field writes integer `b:conduit_writes` when the request started
---@field cleaned? boolean
---@field adopted? boolean The chat took over the session
local Job = {}
Job.__index = Job

---Jobs with a turn in flight, for :Conduit cancel.
---@type table<conduit.InlineJob, true>
M.jobs = {}

local CONTEXT = [[

Never use tools to edit files: the editor applies replacements itself. Files and context mentioned with @ in the request are attached.

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

local REPLACE = "<replace>"

---Answer float keys shown in its footer.
local KEYS = { { "a", "apply" }, { "f", "follow up" }, { "c", "chat" }, { "q", "close" }, { "g?", "keys" } }

---Answer float keys listed by `g?`.
local HELP = {
    { "a", "replace the lines with the answer's last code block" },
    { "f", "ask a follow-up in the same session" },
    { "c", "move the conversation into the chat" },
    { "<C-c>", "cancel the reply" },
    { "q, <Esc>", "close" },
}

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

---Show the phase above the range, or in the answer float's footer once it's open.
function Job:_render_status()
    local msg = self.phase
    if self.answer then
        if not msg then
            return self.answer:footer(hl.keys(KEYS))
        end
        local chunks = { ---@type conduit.Chunks
            { " " .. self.spinner:frame() .. " ", "ConduitSpinner" },
            { msg, "ConduitInlineStatus" },
        }
        return self.answer:footer(vim.list_extend(chunks, hl.keys({ { "<C-c>", "cancel" } })))
    end
    local first = self:_range()
    if self.cleaned or not first then
        return
    end
    if not msg then
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
                { self.agent.name, "ConduitAgent" },
                { " · " .. msg, "ConduitInlineStatus" },
                { "   :Conduit cancel", "ConduitHintDesc" },
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

function Job:_open_answer()
    self.kind = "answer"
    self:_status(nil)
    local _, last = self:_range()
    local win = self.win
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= self.buf then
        win = vim.fn.bufwinid(self.buf)
    end
    if win == -1 then
        -- The buffer isn't visible any more; anchor to the current window.
        win, last = vim.api.nvim_get_current_win(), nil
    end
    local request = (self.history[1].text:gsub("\n.*", ""))
    if vim.fn.strchars(request) > 50 then
        request = vim.fn.strcharpart(request, 0, 49) .. "…"
    end
    self.answer = require("conduit.ui.answer").open({
        win = win,
        row = last or vim.api.nvim_win_get_cursor(win)[1] - 1,
        title = { hl.agent(self.agent.name), { (" %s "):format(request), "ConduitTitle" } },
        keys = {
            q = function()
                self:close()
            end,
            ["<Esc>"] = function()
                self:close()
            end,
            a = function()
                self:apply_code()
            end,
            f = function()
                self:follow_up()
            end,
            c = function()
                self:to_chat()
            end,
            ["<C-c>"] = function()
                self:cancel()
            end,
            ["g?"] = function()
                hl.echo_keys("conduit answer", HELP)
            end,
        },
        on_close = function()
            self:_cleanup()
        end,
    })
    self.answer:append(self.text)
    self.shown = #self.text
end

function Job:on_update(update)
    local kind = update.sessionUpdate
    if kind == "agent_message_chunk" and update.content and update.content.type == "text" then
        self.text = self.text .. update.content.text
        self:_route()
        if self.kind == "answer" and self.answer then
            self.answer:append(self.text:sub(self.shown + 1))
            self.shown = #self.text
            self:_status("writing…")
        elseif self.kind == "edit" then
            -- Completed lines inside the code block streamed so far.
            local _, lines = (self.text:match("```[^\n]*\n(.*)$") or ""):gsub("\n", "")
            self:_status(("writing · %d %s"):format(lines, lines == 1 and "line" or "lines"))
        end
    elseif kind == "agent_thought_chunk" then
        self:_status("thinking…")
    elseif kind == "tool_call" then
        self:_status(update.title or "running a tool…")
    end
end

function Job:request_permission(params, respond)
    local title = (params.toolCall or {}).title or "run a tool"
    require("conduit.ui.permission").ask(self.agent.name, title, params, respond)
end

function Job:on_agent_exit(code)
    self.session_id = nil
    self:_turn_done(("agent exited (code %d)"):format(code))
end

---Send `text` (with mention blocks resolved from `request`) as a turn.
---@param text string Full prompt text
---@param request string What the user typed, for mentions and history
function Job:_send(text, request)
    self.busy = true
    self.text = ""
    self.shown = 0
    M.jobs[self] = true
    table.insert(self.history, { role = "user", text = request })
    local blocks = require("conduit.mentions").blocks(request, self.agent, { buf = self.buf })
    blocks[1] = { type = "text", text = text }
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

    if self.kind == "answer" and self.answer then
        if err then
            self.answer:append(("\n\n> error: %s"):format(err))
        elseif self.cancelled then
            self.answer:append("\n\n> cancelled")
            self.cancelled = false
        end
        return self:_status(nil)
    end

    -- Edit (or nothing at all): apply and finish.
    local first, last = self:_range()
    self:_cleanup()
    if self.cancelled then
        return vim.notify("[conduit] inline request cancelled", vim.log.levels.INFO)
    elseif err then
        return vim.notify("[conduit] inline request failed: " .. err, vim.log.levels.ERROR)
    elseif (vim.b[self.buf].conduit_writes or 0) ~= self.writes then
        return vim.notify("[conduit] the agent edited the file directly; not applying its reply", vim.log.levels.WARN)
    elseif not first or not last or vim.trim(self.text) == "" then
        return vim.notify("[conduit] inline request produced nothing to apply", vim.log.levels.WARN)
    end
    local lines = vim.split(M.extract(self.text), "\n", { plain = true })
    vim.api.nvim_buf_set_lines(self.buf, first, last + 1, false, lines)
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
    if self.session_id and not self.adopted then
        self.agent.sessions[self.session_id] = nil
        self.agent.options[self.session_id] = nil
    end
    if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
    end
end

function Job:close()
    if self.answer then
        self.answer:close()
    end
    self:_cleanup()
end

---Replace the range with the last code block of the answer.
function Job:apply_code()
    if not self.answer then
        return
    end
    local code = self.answer:code_block()
    local first, last = self:_range()
    if not code then
        return vim.notify("[conduit] the answer has no code block to apply", vim.log.levels.WARN)
    elseif not first or not last then
        return vim.notify("[conduit] the original lines are gone", vim.log.levels.WARN)
    end
    vim.api.nvim_buf_set_lines(self.buf, first, last + 1, false, code)
    self:close()
end

---Ask a follow-up question in the same session.
---@param question? string Prompted for when omitted
function Job:follow_up(question)
    local answer = self.answer
    if not answer then
        return
    elseif self.busy then
        return vim.notify("[conduit] still answering, <C-c> to cancel", vim.log.levels.WARN)
    elseif not self.session_id then
        return vim.notify("[conduit] the session has ended", vim.log.levels.WARN)
    end
    local function send(text)
        answer:append(("\n\n---\n\n**You:** %s\n\n"):format(text))
        self:_send(text, text)
        self:_status("thinking…")
    end
    if question then
        return send(question)
    end
    vim.api.nvim_set_current_win(answer.win)
    require("conduit.ui.prompt").open({ title = "Follow up", agent = self.agent.name, on_submit = send })
end

---Move the conversation into the chat window, keeping the session.
function Job:to_chat()
    if self.busy then
        return vim.notify("[conduit] still answering, <C-c> to cancel", vim.log.levels.WARN)
    elseif not self.session_id then
        return vim.notify("[conduit] the session has ended", vim.log.levels.WARN)
    end
    local chat = require("conduit").adopt(self.agent, self.session_id, self.history)
    self.adopted = true
    self.agent.sessions[self.session_id] = chat
    self:close()
    chat:open()
end

---@class conduit.InlineOpts
---@field agent conduit.Agent
---@field buf integer
---@field win? integer
---@field line1 integer 1-based, inclusive
---@field line2 integer 1-based, inclusive
---@field instruction string
---@field mode? conduit.InlineMode Defaults to "auto"

---@param opts conduit.InlineOpts
---@return conduit.InlineJob
function M.run(opts)
    hl.setup()
    local buf, line1, line2 = opts.buf, opts.line1, opts.line2
    local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
    local self = setmetatable({
        agent = opts.agent,
        buf = buf,
        win = opts.win or vim.api.nvim_get_current_win(),
        mode = opts.mode or "auto",
        text = "",
        shown = 0,
        history = {},
        busy = false,
        cancelled = false,
        writes = vim.b[buf].conduit_writes or 0,
        indent = (" "):rep(vim.api.nvim_buf_call(buf, function()
            return vim.fn.indent(line1)
        end)),
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
            end_col = #lines[#lines],
            line_hl_group = "ConduitInlinePending",
            sign_text = "▎",
            sign_hl_group = "ConduitInlineSign",
        }),
    }
    M.jobs[self] = true
    self:_status("starting…")

    local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
    local prompt = PROMPTS[self.mode]
        .. CONTEXT:format(
            opts.instruction,
            line1,
            line2,
            path ~= "" and path or "[No Name]",
            vim.bo[buf].filetype,
            table.concat(lines, "\n")
        )

    local function fail(err)
        self.busy = true
        self:_turn_done(err)
    end
    self.agent:start(function(err)
        if err or self.cancelled then
            return fail(err)
        end
        self.agent:new_session(vim.fn.getcwd(), self, function(serr, sid)
            self.session_id = sid
            if serr or self.cancelled then
                return fail(serr)
            end
            self:_status("thinking…")
            self:_send(prompt, opts.instruction)
        end, config.options.inline.options)
    end)
    return self
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
