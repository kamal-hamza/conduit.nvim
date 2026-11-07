local conduit = require("conduit")

conduit.setup({
    default_agent = "mock",
    agents = { mock = { cmd = vim.v.progpath, args = { "-l", "tests/mock_agent.lua" } } },
    log_level = vim.log.levels.OFF,
})
-- Keep the thread index out of the user's data directory.
require("conduit.history").path = vim.fn.tempname() .. "/threads.json"

local function transcript(chat)
    return table.concat(vim.api.nvim_buf_get_lines(chat.transcript, 0, -1, false), "\n")
end

local function send(chat, text)
    vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, { text })
    chat:submit()
    wait_for(function()
        return not chat.busy
    end, "turn to finish")
end

test("rpc: initialize handshake", function()
    local agent = require("conduit.agent").new("mock", require("conduit.config").options.agents.mock)
    local done, err
    agent:start(function(e)
        done, err = true, e
    end)
    wait_for(function()
        return done
    end, "initialize")
    assert(not err, err)
    assert(assert(agent.info).protocolVersion == 1)
    agent:stop()
end)

test("chat: streams agent message chunks into the transcript", function()
    local chat = assert(conduit.new())
    send(chat, "hi there")
    local text = transcript(chat)
    assert(text:find("## You\n\nhi there", 1, true), text)
    assert(text:find("### Thinking\n\npondering", 1, true), text)
    assert(text:find("## mock\n\nHello from mock\nyou said: hi there", 1, true), text)
    assert(chat.session_id == "mock-session")
end)

test("chat: tool calls, permissions and fs read/write", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "hello", "world" }, path)

    local orig_select = vim.ui.select
    local prompt
    vim.ui.select = function(items, opts, cb)
        prompt = opts.prompt
        cb(items[1])
    end

    local chat = assert(conduit.new())
    send(chat, "edit " .. path)
    vim.ui.select = orig_select

    assert(prompt == "mock wants to Edit " .. path, tostring(prompt))
    local text = transcript(chat)
    assert(text:find("✓ Edit " .. path, 1, true), text)
    assert(text:find("- [x] Read file", 1, true), text)
    assert(not text:find("[~]", 1, true), "plan should be replaced in place:\n" .. text)
    assert(text:find("first line was: hello", 1, true), text)
    assert(vim.deep_equal(vim.fn.readfile(path), { "HELLO", "WORLD" }))
end)

test("fs: reads prefer unsaved buffer contents", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "on disk" }, path)
    vim.cmd.edit(path)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "in buffer" })
    local fs = require("conduit.fs")
    assert(assert(fs.read({ path = path })).content == "in buffer\n")

    fs.write({ path = path, content = "written\n" })
    assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "written")
    assert(not vim.bo.modified)
    assert(vim.fn.readfile(path)[1] == "written")
    vim.cmd("bwipeout!")
end)

test("agent: missing executable reports an error", function()
    local agent = require("conduit.agent").new("nope", { cmd = "conduit-does-not-exist" })
    local err
    agent:start(function(e)
        err = e
    end)
    assert(err and err:find("executable not found"), err)
end)

test("chat: uses its own filetypes with diagnostics disabled", function()
    local chat = assert(conduit.new())
    assert(vim.bo[chat.transcript].filetype == "conduit")
    assert(vim.bo[chat.input].filetype == "conduit_input")
    assert(not vim.diagnostic.is_enabled({ bufnr = chat.input }))
end)

test("options: config options, defaults and set_option", function()
    local config = require("conduit.config").options
    config.agents.mock.options = { effort = "low" }
    local chat = assert(conduit.new())
    local done
    chat:ensure_session(function()
        done = true
    end)
    wait_for(function()
        return done
    end, "session")
    config.agents.mock.options = nil

    local options = require("conduit.options")
    local sid = assert(chat.session_id)
    local opts = chat.agent:get_options(sid)
    assert(assert(options.find(opts, "effort")).current == "low", "default should be applied")
    assert(assert(options.find(opts, "thought_level")).id == "effort", "effort is found by category")

    done = false
    chat.agent:set_option(sid, "model", "smart", function(err)
        assert(not err, err)
        done = true
    end)
    wait_for(function()
        return done
    end, "set_option")
    assert(assert(options.find(chat.agent:get_options(sid), "model")).current == "smart")
    chat:_refresh_winbar()
    local winbar = vim.api.nvim_get_option_value("winbar", { win = assert((chat:wins())) })
    assert(winbar:find("SMART · LOW", 1, true), winbar)
end)

test("options: legacy modes and models", function()
    local config = require("conduit.config").options
    config.agents.legacy = { cmd = vim.v.progpath, args = { "-l", "tests/mock_agent.lua", "--legacy" } }
    local chat = assert(conduit.new("legacy"))
    local done
    chat:ensure_session(function()
        done = true
    end)
    wait_for(function()
        return done
    end, "session")
    local options = require("conduit.options")
    local sid = assert(chat.session_id)
    local opts = chat.agent:get_options(sid)
    assert(assert(options.find(opts, "mode")).current == "ask")
    done = false
    chat.agent:set_option(sid, "model", "m2", function(err)
        assert(not err, err)
        done = true
    end)
    wait_for(function()
        return done
    end, "set_model")
    assert(assert(options.find(opts, "model")).current == "m2")
end)

test("inline: extracts the outermost fenced block", function()
    local extract = require("conduit.inline").extract
    assert(extract("sure:\n```lua\nlocal x = 1\n```\n") == "local x = 1")
    assert(extract("````md\n```lua\nx\n```\n````") == "```lua\nx\n```")
    assert(extract("  bare  ") == "bare")
end)

test("inline: rewrites the selected lines", function()
    vim.cmd.enew()
    vim.bo.filetype = "lua"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep", "local a = 1", "local b = 2", "keep" })
    conduit.inline(2, 3, "uppercase it")
    local inline = require("conduit.inline")
    wait_for(function()
        return next(inline.jobs) == nil
    end, "inline edit")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(vim.deep_equal(lines, { "keep", "LOCAL A = 1", "LOCAL B = 2", "keep" }), vim.inspect(lines))
    assert(#vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {}) == 0, "marks should be cleared")
    vim.cmd("bwipeout!")
end)

---Text of a float's title or footer chunks.
---@param win integer
---@param key "title"|"footer"
---@return string
local function chunks_text(win, key)
    local cfg = vim.api.nvim_win_get_config(win) --[[@as table]]
    return table.concat(vim.tbl_map(function(c)
        return c[1]
    end, cfg[key] or {}))
end

local function fixture()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/sub", "p")
    vim.fn.writefile({ "alpha" }, root .. "/a.lua")
    vim.fn.writefile({ "bravo" }, root .. "/sub/b.lua")
    return root
end

test("mentions: parses existing files and directories only", function()
    local root = fixture()
    local mentions = require("conduit.mentions")
    local found = mentions.parse("see @a.lua, and @sub/ but not me@example.com or @missing.lua", root)
    assert(#found == 2, vim.inspect(found))
    assert(found[1].rel == "a.lua" and not found[1].dir)
    assert(found[2].rel == "sub" and found[2].dir)
end)

test("mentions: embeds content when supported, links otherwise", function()
    local root = fixture()
    local mentions = require("conduit.mentions")
    local embed = { info = { agentCapabilities = { promptCapabilities = { embeddedContext = true } } } }
    local blocks = mentions.blocks("@a.lua @sub", embed, { root = root })
    assert(#blocks == 3)
    assert(blocks[2].type == "resource" and blocks[2].resource.text == "alpha\n", vim.inspect(blocks[2]))
    assert(blocks[3].resource.text:find("b.lua", 1, true), blocks[3].resource.text)
    local links = mentions.blocks("@a.lua", { info = {} }, { root = root })
    assert(links[2].type == "resource_link" and links[2].name == "a.lua")
    assert(links[2].uri == vim.uri_from_fname(root .. "/a.lua"))
end)

test("mentions: fuzzy candidates include files and directories", function()
    local root = fixture()
    local mentions = require("conduit.mentions")
    local words = function(query)
        return vim.tbl_map(function(i)
            return i.word
        end, mentions.items(query, root))
    end
    assert(vim.tbl_contains(words("sbb"), "sub/b.lua"), vim.inspect(words("sbb")))
    assert(vim.tbl_contains(words(""), "sub/"))
    assert(vim.tbl_contains(words(""), "diagnostics"), "specials are offered")
    local ranked = words("su")
    assert(ranked[1] == "sub/", "path-prefix directories rank first: " .. vim.inspect(ranked))
end)

test("mentions: typing @ opens completion in the input", function()
    local chat = assert(conduit.new())
    vim.api.nvim_set_current_win(assert(select(2, chat:wins())))
    local items
    local orig = vim.fn.complete
    require("conduit.mentions").reset()
    vim.fn.complete = function(col, list)
        items = { col = col, list = list }
    end
    -- Cursor on the trailing "x" stands in for the insert-mode cursor after "co".
    vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, { "hi @lua/cox" })
    vim.api.nvim_win_set_cursor(0, { 1, 10 })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = chat.input })
    vim.fn.complete = orig
    assert(items and items.col == 5, vim.inspect(items))
    local words = vim.tbl_map(function(i)
        return i.word
    end, items.list)
    assert(vim.tbl_contains(words, "lua/conduit/"), vim.inspect(words))
end)

test("chat: @mentions are sent as resources", function()
    local chat = assert(conduit.new())
    send(chat, "look at @tests/run.lua and @lua/conduit/ui/")
    local text = transcript(chat)
    assert(text:find("resource run.lua %d+"), text)
    assert(text:find("resource ui %d+"), text)
end)

test("prompt: floating input submits its text and closes", function()
    local got
    local buf, win = require("conduit.ui.prompt").open({
        title = "Edit",
        on_submit = function(text)
            got = text
        end,
    })
    vim.cmd.stopinsert()
    assert(vim.bo[buf].filetype == "conduit_input" and vim.b[buf].completion == false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "make it @a.lua", "" })
    vim.api.nvim_buf_call(buf, function()
        vim.fn.maparg("<CR>", "n", false, true).callback()
    end)
    wait_for(function()
        return got ~= nil
    end, "submit")
    assert(got == "make it @a.lua", got)
    assert(not vim.api.nvim_win_is_valid(win))
end)

test("mentions: special context (@buffer, @selection, @diagnostics, @quickfix)", function()
    local mentions = require("conduit.mentions")
    vim.cmd.enew()
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
    vim.api.nvim_buf_set_mark(buf, "<", 2, 0, {})
    vim.api.nvim_buf_set_mark(buf, ">", 3, 0, {})
    local ns = vim.api.nvim_create_namespace("conduit.test")
    vim.diagnostic.set(
        ns,
        buf,
        { { lnum = 1, col = 0, message = "bad two", severity = vim.diagnostic.severity.ERROR } }
    )
    vim.fn.setqflist({ { bufnr = buf, lnum = 3, text = "look here" } })

    local found = mentions.parse("fix @diagnostics in @selection, see @buffer and @quickfix.")
    assert(#found == 4 and found[1].special == "diagnostics", vim.inspect(found))

    local blocks = mentions.blocks("@buffer @selection @diagnostics @quickfix", nil, { buf = buf })
    local texts = vim.tbl_map(function(b)
        return b.text
    end, vim.list_slice(blocks, 2))
    assert(texts[1]:find("one\ntwo\nthree", 1, true), texts[1])
    assert(texts[2]:find("lines 2-3:\n```lua\ntwo\nthree", 1, true), texts[2])
    assert(texts[3]:find(":2:1: error: bad two", 1, true), texts[3])
    assert(texts[4]:find(":3: look here", 1, true), texts[4])
    vim.diagnostic.reset(ns, buf)
    vim.fn.setqflist({})
    vim.cmd("bwipeout!")
end)

test("blink: source returns ranked items with a text edit after @", function()
    local source = require("conduit.blink").new()
    ---@type { is_incomplete_forward: boolean, items: table[] }?
    local got
    source:get_completions({ cursor = { 1, 14 }, line = "check @lua/cond please" }, function(res)
        got = res
    end)
    got = assert(got)
    assert(got.is_incomplete_forward)
    local first = got.items[1]
    assert(first.label == "lua/conduit/", vim.inspect(first))
    assert(first.kind == 19 and first.textEdit.newText == "lua/conduit/")
    local range = first.textEdit.range
    assert(range.start.character == 7 and range["end"].character == 14, vim.inspect(range))

    ---@type table?
    local resolved
    local file
    for _, item in ipairs(got.items) do
        if item.label == "lua/conduit/init.lua" then
            file = item
        end
    end
    source:resolve(assert(file), function(r)
        resolved = r
    end)
    resolved = assert(resolved)
    assert(resolved.documentation.value:find("```lua", 1, true), vim.inspect(resolved.documentation))

    ---@type { items: table[] }?
    local inside_word
    source:get_completions({ cursor = { 1, 9 }, line = "email me@x" }, function(res)
        inside_word = res
    end)
    assert(#assert(inside_word).items == 0, "no completion inside words")
end)

local function inline_buf()
    vim.cmd.enew()
    vim.bo.filetype = "lua"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep", "local a = 1", "local b = 2", "keep" })
    return vim.api.nvim_get_current_buf()
end

local function wait_turn(job)
    wait_for(function()
        return not job.busy and job.session_id ~= nil or job.cleaned
    end, "inline turn")
end

test("inline: auto mode answers questions in a float under the selection", function()
    local buf = inline_buf()
    local job = assert(conduit.inline(2, 3, "explain this"))
    wait_turn(job)
    assert(job.kind == "answer" and job.answer and job.answer:is_open(), "answer float should be open")
    local text = job.answer:text()
    assert(text:find("This code **adds** things.", 1, true), text)
    assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "local a = 1", "buffer must not change")
    assert(vim.api.nvim_win_get_config(job.answer.win).relative == "win")
    assert(chunks_text(job.answer.win, "title"):find("mock", 1, true), chunks_text(job.answer.win, "title"))
    local footer = chunks_text(job.answer.win, "footer")
    assert(footer:find("a apply", 1, true) and footer:find("g? keys", 1, true), footer)
    assert(not job.spinner:is_running(), "spinner should stop when the turn ends")

    job:follow_up("follow: more please")
    wait_turn(job)
    text = job.answer:text()
    assert(text:find("**You:** follow: more please", 1, true), text)
    assert(text:find("Follow-up answer to: follow: more please", 1, true), text)

    -- `a` applies the last code block from the answer to the selection.
    job:apply_code()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert(vim.deep_equal(lines, { "keep", "return 42", "keep" }), vim.inspect(lines))
    assert(not job.answer:is_open())
    assert(#vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}) == 0, "marks should be cleared")
    assert(job.agent.sessions[job.session_id] == nil, "session should be released")
    vim.cmd("bwipeout!")
end)

test("inline: a leading ? forces ask mode", function()
    inline_buf()
    local job = assert(conduit.inline(2, 3, "? uppercase it"))
    wait_turn(job)
    assert(job.mode == "ask" and job.kind == "answer", vim.inspect({ job.mode, job.kind }))
    job:close()
    vim.cmd("bwipeout!")
end)

test("inline: answers can move into the chat with their session", function()
    inline_buf()
    local job = assert(conduit.inline(2, 3, "explain this"))
    wait_turn(job)
    local sid = job.session_id
    job:to_chat()
    local chat = assert(conduit.current)
    assert(chat.session_id == sid and chat.agent.sessions[sid] == chat)
    local text = transcript(chat)
    assert(text:find("## You\n\nexplain this", 1, true), text)
    assert(text:find("This code **adds** things.", 1, true), text)
    assert(require("conduit.threads").index(chat), "adopted chat is a thread")
    assert(chat.title == "explain this", tostring(chat.title))
    send(chat, "hi again")
    assert(transcript(chat):find("you said: hi again", 1, true))
    vim.cmd("only")
    vim.cmd("bwipeout!")
end)

test("prompt: <C-t> cycles the mode and prefixes override it", function()
    local parse = require("conduit.ui.prompt").parse_prefix
    assert(select(2, parse("? why", "auto")) == "ask" and parse("? why", "auto") == "why")
    assert(select(2, parse("!fix it", "ask")) == "edit")
    assert(select(2, parse("plain", "edit")) == "edit")

    local got_mode
    local buf, win = require("conduit.ui.prompt").open({
        title = "Lines 1-2",
        mode = "auto",
        on_submit = function(_, mode)
            got_mode = mode
        end,
    })
    vim.cmd.stopinsert()
    assert(chunks_text(win, "title"):find("Auto", 1, true), chunks_text(win, "title"))
    vim.api.nvim_buf_call(buf, function()
        vim.fn.maparg("<C-t>", "n", false, true).callback()
    end)
    assert(chunks_text(win, "title"):find("Edit", 1, true), chunks_text(win, "title"))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "do it" })
    vim.api.nvim_buf_call(buf, function()
        vim.fn.maparg("<CR>", "n", false, true).callback()
    end)
    wait_for(function()
        return got_mode ~= nil
    end, "submit")
    assert(got_mode == "edit", got_mode)
end)

test("prompt: title shows agent, mode and context; prefixes update it live", function()
    vim.cmd.enew()
    local code_win = vim.api.nvim_get_current_win()
    local buf, win = require("conduit.ui.prompt").open({
        title = "init.lua:3-5",
        agent = "mock",
        mode = "auto",
        anchor = { win = code_win, first = 0, last = 0 },
        on_submit = function() end,
    })
    vim.cmd.stopinsert()
    local title = chunks_text(win, "title")
    assert(title:find("mock", 1, true) and title:find("Auto", 1, true), title)
    assert(title:find("init.lua:3-5", 1, true), title)
    local footer = chunks_text(win, "footer")
    assert(footer:find("<CR> send", 1, true) and footer:find("g? keys", 1, true), footer)

    local ns = vim.api.nvim_create_namespace("conduit.prompt")
    local function placeholder()
        return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0
    end
    assert(placeholder(), "empty prompt shows a placeholder")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "? why" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    assert(chunks_text(win, "title"):find("Ask", 1, true), chunks_text(win, "title"))
    assert(not placeholder(), "placeholder goes away once there's text")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!fix" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    assert(chunks_text(win, "title"):find("Edit", 1, true), chunks_text(win, "title"))

    vim.api.nvim_win_close(win, true)
    vim.cmd("bwipeout!")
end)

test("prompt: opens under the range, above it near the bottom, else at the cursor", function()
    vim.cmd.enew()
    vim.cmd("only")
    local win = vim.api.nvim_get_current_win()
    local lines = {}
    for i = 1, 200 do
        lines[i] = "line " .. i
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("normal! zt")
    local placement = require("conduit.ui.prompt").placement
    local height = vim.api.nvim_win_get_height(win)

    local below = placement({ win = win, first = 1, last = 2 })
    assert(below.relative == "win" and below.bufpos[1] == 2 and below.row == 1, vim.inspect(below))

    local above = placement({ win = win, first = height - 3, last = height - 1 })
    assert(above.relative == "win" and above.bufpos[1] == height - 3 and above.anchor == "SW", vim.inspect(above))

    local hidden = placement({ win = win, first = 150, last = 160 })
    assert(hidden.relative == "cursor", vim.inspect(hidden))
    vim.cmd("bwipeout!")
end)

test("inline: shows a spinner status and marks the range while running", function()
    local buf = inline_buf()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "    local a = 1" })
    local job = assert(conduit.inline(2, 3, "uppercase it"))
    assert(job.spinner:is_running(), "spinner runs while busy")
    local ns = vim.api.nvim_create_namespace("conduit.inline")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local status, range
    for _, m in ipairs(marks) do
        local d = m[4] or {}
        if d.virt_lines then
            status = d
        elseif d.line_hl_group then
            range = d
        end
    end
    assert(range and range.line_hl_group == "ConduitInlinePending" and range.sign_hl_group == "ConduitInlineSign")
    assert(status and status.virt_lines_above, vim.inspect(marks))
    local line = table.concat(vim.tbl_map(function(c)
        return c[1]
    end, status.virt_lines[1]))
    assert(vim.startswith(line, "    "), "status is indented like the range: " .. line)
    assert(line:find("mock", 1, true) and line:find(":Conduit cancel", 1, true), line)

    wait_for(function()
        return job.cleaned
    end, "inline edit")
    assert(not job.spinner:is_running(), "spinner stops when done")
    vim.cmd("bwipeout!")
end)

test("highlights: conduit groups survive :colorscheme", function()
    require("conduit.ui.hl").setup()
    vim.cmd.colorscheme("default")
    local pending = vim.api.nvim_get_hl(0, { name = "ConduitInlinePending" })
    assert(pending.link == "CursorLine", vim.inspect(pending))
    assert(vim.api.nvim_get_hl(0, { name = "ConduitModeEdit" }).link == "DiagnosticWarn")
end)

test("api: every :Conduit subcommand resolves", function()
    local fns = { "open", "new", "toggle", "cancel", "stop", "add_range", "inline", "ask", "edit", "option" }
    vim.list_extend(fns, { "threads", "continue_thread", "thread_next", "thread_prev", "thread_close" })
    vim.list_extend(fns, { "thread_delete", "thread_fork", "thread_rename" })
    for _, fn in ipairs(fns) do
        assert(type(conduit[fn]) == "function", "missing conduit." .. fn)
    end
    local complete = vim.fn.getcompletion("Conduit ", "cmdline")
    local subs = { "inline", "ask", "edit", "stop", "model", "effort", "mode", "threads", "thread", "continue" }
    for _, sub in ipairs(subs) do
        assert(vim.tbl_contains(complete, sub), "missing subcommand " .. sub)
    end
    local actions = vim.fn.getcompletion("Conduit thread ", "cmdline")
    for _, action in ipairs({ "new", "next", "prev", "close", "delete", "fork", "rename" }) do
        assert(vim.tbl_contains(actions, action), "missing thread action " .. action)
    end
end)

test("agent: requests after the agent exits fail cleanly", function()
    local agent = require("conduit.agent").new("mock", require("conduit.config").options.agents.mock)
    local err
    agent:prompt("gone", {}, function(e)
        err = e
    end)
    assert(err == "mock is not running", err)
end)

---Delete every thread and close the chat windows, for tests that count threads.
local function reset_threads()
    local threads = require("conduit.threads")
    while threads.list[1] do
        threads.close(threads.list[1])
    end
    vim.cmd("silent! only")
end

---@param buf integer
---@param lhs string
local function press(buf, lhs)
    vim.api.nvim_buf_call(buf, function()
        vim.fn.maparg(lhs, "n", false, true).callback()
    end)
end

test("threads: new threads keep earlier ones alive in the same windows", function()
    reset_threads()
    local threads = require("conduit.threads")
    local a = assert(conduit.new())
    send(a, "first thread")
    local twin, iwin = a:wins()
    local wins = #vim.api.nvim_list_wins()

    local b = assert(conduit.new())
    assert(#threads.list == 2 and threads.current == b and conduit.current == b)
    assert(#vim.api.nvim_list_wins() == wins, "reuses the chat windows")
    assert(vim.api.nvim_win_get_buf(assert(twin)) == b.transcript)
    assert(vim.api.nvim_win_get_buf(assert(iwin)) == b.input)
    assert(vim.api.nvim_buf_is_valid(a.transcript) and transcript(a):find("first thread", 1, true))
    assert(vim.wo[twin].winbar:find("(2/2)", 1, true), vim.wo[twin].winbar)

    send(b, "second thread")
    assert(a.session_id ~= b.session_id)
    assert(not transcript(b):find("first thread", 1, true))

    press(b.input, "]t")
    assert(threads.current == a and vim.api.nvim_win_get_buf(twin) == a.transcript)
    assert(vim.wo[twin].winbar:find("first thread (1/2)", 1, true), vim.wo[twin].winbar)
    press(a.transcript, "[t")
    assert(threads.current == b)
    reset_threads()
end)

test("threads: picker lists live threads and switches", function()
    reset_threads()
    local threads = require("conduit.threads")
    local a = assert(conduit.new())
    send(a, "alpha")
    local b = assert(conduit.new())

    local orig_select = vim.ui.select
    local labels
    vim.ui.select = function(items, opts, cb)
        labels = vim.tbl_map(opts.format_item, items)
        cb(items[1])
    end
    press(b.input, "gs")
    vim.ui.select = orig_select

    assert(labels[1] == "  alpha · mock", labels[1])
    assert(labels[2] == "● New thread · mock", labels[2])
    assert(threads.current == a and a:is_open() and not b:is_open())
    reset_threads()
end)

test("threads: closing the current thread shows its neighbour", function()
    reset_threads()
    local threads = require("conduit.threads")
    local a = assert(conduit.new())
    send(a, "keep me")
    local b = assert(conduit.new())
    send(b, "drop me")
    local twin = assert(b:wins())
    local sid = assert(b.session_id)

    vim.cmd("Conduit thread close")
    assert(#threads.list == 1 and threads.current == a)
    assert(not vim.api.nvim_buf_is_valid(b.transcript) and not vim.api.nvim_buf_is_valid(b.input))
    assert(a.agent.sessions[sid] == nil, "session handler removed")
    assert(vim.api.nvim_win_get_buf(twin) == a.transcript)

    conduit.thread_close()
    assert(#threads.list == 0 and conduit.current == nil)
    assert(not vim.api.nvim_buf_is_valid(a.transcript))
    reset_threads()
end)

test("threads: titles come from the first prompt, then the agent", function()
    reset_threads()
    local chat = assert(conduit.new())
    assert(chat:display_title() == "New thread")
    send(chat, ("x"):rep(80))
    assert(vim.fn.strcharlen(chat.title) == 50 and vim.endswith(chat.title, "…"), chat.title)
    send(chat, "title Refactor the parser")
    assert(chat.title == "Refactor the parser", chat.title)
    local twin = assert(chat:wins())
    assert(vim.wo[twin].winbar:find("mock · Refactor the parser", 1, true), vim.wo[twin].winbar)
    reset_threads()
end)

test("threads: opening another agent reuses its latest thread", function()
    reset_threads()
    local config = require("conduit.config").options
    config.agents.other = config.agents.mock
    local a = assert(conduit.new())
    local b = assert(conduit.open("other"))
    assert(b ~= a and b.agent.name == "other")
    assert(conduit.open("mock") == a)
    assert(conduit.open("other") == b)
    config.agents.other = nil
    reset_threads()
    conduit.agents.other:stop()
    conduit.agents.other = nil
end)

local ALL_CAPS = "--threads=load,list,resume,close,delete,fork,title"

---Register a mock agent with thread capabilities under a new name and start it.
---@param name string
---@param ... string Extra mock arguments
---@return conduit.Agent agent, string[] methods Requests sent to it, in order
local function thread_agent(name, ...)
    local config = require("conduit.config").options
    config.agents[name] = { cmd = vim.v.progpath, args = { "-l", "tests/mock_agent.lua", ... } }
    local agent = assert(conduit.agent(name))
    local methods = {}
    local request = agent._request
    agent._request = function(self, method, params, cb)
        table.insert(methods, method)
        if method == "session/load" or method == "session/resume" then
            methods.last_params = params
        end
        return request(self, method, params, cb)
    end
    local started
    agent:start(function(err)
        assert(not err, err)
        started = true
    end)
    wait_for(function()
        return started
    end, name .. " to start")
    return agent, methods
end

---@param name string
local function drop_agent(name)
    reset_threads()
    if conduit.agents[name] then
        conduit.agents[name]:stop()
        conduit.agents[name] = nil
    end
    require("conduit.config").options.agents[name] = nil
end

---@param methods string[]
---@param method string
---@return integer
local function count(methods, method)
    return #vim.tbl_filter(function(m)
        return m == method
    end, methods)
end

---Run the thread picker for `agent`, choosing the first item `choose` accepts.
---@param agent? conduit.Agent
---@param choose fun(item: conduit.PickItem): boolean
---@return string[] labels
local function pick(agent, choose)
    local orig_select = vim.ui.select
    local labels
    vim.ui.select = function(items, opts, cb)
        labels = vim.tbl_map(opts.format_item, items)
        for _, item in ipairs(items) do
            if choose(item) then
                return cb(item)
            end
        end
        cb(nil)
    end
    require("conduit.threads").pick(agent)
    wait_for(function()
        return labels ~= nil
    end, "the thread picker")
    vim.ui.select = orig_select
    return labels
end

---@param haystack string
---@param needle string
---@return integer
local function occurrences(haystack, needle)
    local n, init = 0, 1
    while true do
        local i = haystack:find(needle, init, true)
        if not i then
            return n
        end
        n, init = n + 1, i + #needle
    end
end

test("threads: timestamps parse as UTC and honour offsets", function()
    local threads = require("conduit.threads")
    assert(threads.parse_time("2026-01-03T10:00:00Z") == 1767434400)
    assert(threads.parse_time("2026-01-03T10:00:00.123Z") == 1767434400)
    assert(threads.parse_time("2026-01-03T12:00:00+02:00") == 1767434400)
    assert(threads.parse_time("nonsense") == nil and threads.parse_time(nil) == nil)
    assert(threads.ago(os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 7200) --[[@as string]]) == "2h ago")
end)

test("threads: past sessions are listed across pages and replayed when opened", function()
    reset_threads()
    local agent, methods = thread_agent("past", ALL_CAPS, "--seed")
    local labels = pick(agent, function(item)
        return item.info ~= nil and item.info.session_id == "past-1"
    end)
    assert(count(methods, "session/list") == 2, "follows nextCursor")
    assert(labels[1] == "  Old work · past · " .. require("conduit.threads").ago("2026-01-03T10:00:00Z"), labels[1])
    assert(vim.startswith(labels[2], "  Older work · past"), labels[2])
    assert(vim.startswith(labels[3], "  past-3 · past"), labels[3])
    assert(labels[4] == "+ New thread" and #labels == 4, vim.inspect(labels))

    local chat = assert(conduit.current)
    wait_for(function()
        return chat.session_id == "past-1" and not chat.busy
    end, "session/load")
    assert(methods.last_params.cwd == vim.fn.getcwd())
    local text = transcript(chat)
    assert(text:find("## You\n\nhello past\n\n## past\n\nhi from the past", 1, true), text)
    assert(text:find("✓ Read notes\n\n✗ Run make …", 1, true), text)
    assert(text:find("## You\n\nfirst part\n\n## You\n\nsecond part\n\n## past\n\nboth parts answered", 1, true), text)
    assert(chat.title == "Old work" and chat:display_title() == "Old work")
    assert(require("conduit.history").get("past", "past-1"), "recorded in the index")

    send(chat, "picking up again")
    assert(transcript(chat):find("you said: picking up again", 1, true))

    -- Live threads aren't listed twice.
    labels = pick(agent, function()
        return false
    end)
    assert(labels[1] == "● Old work · past", labels[1])
    assert(not vim.tbl_contains(labels, "  Old work · past"), vim.inspect(labels))
    drop_agent("past")
end)

test("threads: agents without session capabilities only offer live threads", function()
    reset_threads()
    local agent, methods = thread_agent("plain")
    local chat = assert(conduit.new("plain"))
    send(chat, "only me")
    local labels = pick(agent, function()
        return false
    end)
    assert(vim.deep_equal(labels, { "● only me · plain", "+ New thread" }), vim.inspect(labels))
    assert(count(methods, "session/list") == 0 and count(methods, "session/load") == 0)
    drop_agent("plain")
end)

test("threads: load-only agents list threads from the local index", function()
    reset_threads()
    local history = require("conduit.history")
    local agent, methods = thread_agent("loader", "--threads=load")
    local chat = assert(conduit.new("loader"))
    send(chat, "remember me")
    local sid = assert(chat.session_id)
    require("conduit.threads").close(chat)

    history.reset() -- reread from disk
    assert(assert(history.get("loader", sid)).title == "remember me")
    local labels = pick(agent, function(item)
        return item.info ~= nil and item.info.session_id == sid
    end)
    assert(vim.startswith(labels[1], "  remember me · loader"), vim.inspect(labels))
    assert(count(methods, "session/list") == 0)
    local reopened = assert(conduit.current)
    wait_for(function()
        return reopened.session_id == sid and not reopened.busy
    end, "session/load")
    assert(
        transcript(reopened):find("## You\n\nremember me\n\n### Thinking\n\npondering", 1, true),
        transcript(reopened)
    )
    drop_agent("loader")
end)

test("threads: a corrupt index is ignored", function()
    local history = require("conduit.history")
    local path = history.path
    history.path = vim.fn.tempname()
    vim.fn.writefile({ "{not json" }, history.path)
    history.reset()
    assert(#history.list("mock") == 0)
    history.record({ agent = "mock", session_id = "s", cwd = "/" })
    history.reset()
    assert(history.get("mock", "s"), "rewritten")
    history.path = path
    history.reset()
end)

test("threads: sessions are resumed after the agent restarts", function()
    reset_threads()
    local agent, methods = thread_agent("resumer", ALL_CAPS)
    local chat = assert(conduit.new("resumer"))
    send(chat, "before exit")
    local sid = chat.session_id
    agent:stop()
    wait_for(function()
        return chat.resume_id == sid
    end, "the agent to exit")
    send(chat, "after exit")
    assert(chat.session_id == sid, tostring(chat.session_id))
    assert(count(methods, "session/resume") == 1)
    local text = transcript(chat)
    assert(occurrences(text, "you said: before exit") == 1, text)
    assert(text:find("you said: after exit", 1, true), text)
    drop_agent("resumer")
end)

test("threads: load-only agents reload a session without re-rendering it", function()
    reset_threads()
    local agent, methods = thread_agent("reloader", "--threads=load", "--seed")
    local chat =
        require("conduit.threads").open(agent, { agent = "reloader", session_id = "past-1", cwd = vim.fn.getcwd() })
    wait_for(function()
        return chat.session_id == "past-1" and not chat.busy
    end, "session/load")
    agent:stop()
    wait_for(function()
        return chat.resume_id == "past-1"
    end, "the agent to exit")
    send(chat, "still there?")
    assert(chat.session_id == "past-1" and count(methods, "session/load") == 2)
    local text = transcript(chat)
    assert(occurrences(text, "hi from the past") == 1, text)
    assert(text:find("you said: still there?", 1, true), text)
    drop_agent("reloader")
end)

test("threads: agents that can't restore sessions start over after exiting", function()
    reset_threads()
    local agent = thread_agent("forgetful")
    local chat = assert(conduit.new("forgetful"))
    send(chat, "first life")
    agent:stop()
    wait_for(function()
        return chat.resume_id ~= nil
    end, "the agent to exit")
    send(chat, "second life")
    assert(chat.session_id ~= nil and chat.resume_id == nil)
    local text = transcript(chat)
    assert(text:find("can't restore sessions; starting a new one without the earlier context", 1, true), text)
    assert(text:find("you said: second life", 1, true), text)
    drop_agent("forgetful")
end)

test("threads: closing releases the session; deleting removes it", function()
    reset_threads()
    local threads = require("conduit.threads")
    local history = require("conduit.history")
    local agent, methods = thread_agent("closer", ALL_CAPS)
    local chat = assert(conduit.new("closer"))
    send(chat, "close me")
    local sid = assert(chat.session_id)
    threads.close(chat)
    wait_for(function()
        return count(methods, "session/close") == 1
    end, "session/close")
    assert(agent.sessions[sid] == nil)
    local again
    agent:close_session(sid, function(err)
        again = { err = err }
    end)
    wait_for(function()
        return again
    end, "second session/close")
    assert(again.err == nil, "closing twice (-32002) counts as success")

    -- Closed threads stay in the history.
    local labels = pick(agent, function(item)
        return item.info ~= nil and item.info.session_id == sid
    end)
    assert(vim.startswith(labels[1], "  close me · closer"), vim.inspect(labels))
    local reopened = assert(conduit.current)
    wait_for(function()
        return reopened.session_id == sid and not reopened.busy
    end, "session/load")

    local orig_select = vim.ui.select
    local question
    vim.ui.select = function(items, opts, cb)
        question = opts.prompt
        cb(items[1])
    end
    vim.cmd("Conduit thread delete")
    vim.ui.select = orig_select
    assert(question == 'Delete thread "close me" permanently?', question)
    wait_for(function()
        return count(methods, "session/delete") == 1
    end, "session/delete")
    assert(#threads.list == 0 and history.get("closer", sid) == nil)
    labels = pick(agent, function()
        return false
    end)
    assert(vim.deep_equal(labels, { "+ New thread" }), vim.inspect(labels))
    drop_agent("closer")
end)

test("threads: deleting without session/delete hides the thread", function()
    reset_threads()
    local agent = thread_agent("hider", "--threads=load,list", "--seed")
    require("conduit.threads").delete(agent, "past-2")
    local labels = pick(agent, function()
        return false
    end)
    assert(not vim.tbl_contains(labels, "  Older work · hider"), vim.inspect(labels))
    for _, label in ipairs(labels) do
        assert(not label:find("Older work", 1, true), label)
    end
    drop_agent("hider")
end)

test("threads: forking copies the thread into a new session", function()
    reset_threads()
    local threads = require("conduit.threads")
    local agent = thread_agent("forker", ALL_CAPS)
    local chat = assert(conduit.new("forker"))
    send(chat, "fork me")
    local fork
    threads.fork(chat, function(err, f)
        assert(not err, err)
        fork = f
    end)
    wait_for(function()
        return fork
    end, "session/fork")
    assert(fork.session_id == "fork-1" and threads.current == fork and #threads.list == 2)
    assert(fork.title == "fork me (fork)", fork.title)
    local text = transcript(fork)
    assert(text:find("you said: fork me", 1, true) and text:find("forked from fork me", 1, true), text)
    send(fork, "only in the fork")
    assert(not transcript(chat):find("only in the fork", 1, true))

    local plain = assert(conduit.new())
    send(plain, "no forks here")
    local err
    threads.fork(plain, function(e)
        err = e
    end)
    assert(err == "mock doesn't support forking sessions", err)
    assert(agent)
    drop_agent("forker")
end)

test("threads: renamed titles stick and are stored by the agent", function()
    reset_threads()
    local agent, methods = thread_agent("namer", ALL_CAPS)
    local chat = assert(conduit.new("namer"))
    send(chat, "untitled")
    local done
    chat:rename("  Custom name ", function(err)
        done = { err = err }
    end)
    wait_for(function()
        return done
    end, "session/set_title")
    assert(count(methods, "session/set_title") == 1)
    assert(chat.title == "Custom name", chat.title)
    send(chat, "title Agent's idea")
    assert(chat.title == "Custom name", "agent titles don't replace user titles")
    assert(assert(require("conduit.history").get("namer", chat.session_id)).custom_title)
    assert(agent)
    drop_agent("namer")
end)

test("threads: inline requests stay out of thread lists", function()
    reset_threads()
    local config = require("conduit.config").options
    local agent, methods = thread_agent("inliner", ALL_CAPS)
    config.inline.agent = "inliner"
    inline_buf()
    local job = assert(conduit.inline(2, 3, "explain this"))
    wait_turn(job)
    local sid = assert(job.session_id)
    job:close()
    config.inline.agent = nil
    vim.cmd("bwipeout!")
    assert(count(methods, "session/close") == 1, "inline sessions are released")
    local labels = pick(agent, function()
        return false
    end)
    assert(vim.deep_equal(labels, { "+ New thread" }), vim.inspect(labels))
    assert(require("conduit.history").is_hidden("inliner", sid))
    drop_agent("inliner")
end)

test("threads: continue reopens the most recent past thread", function()
    reset_threads()
    thread_agent("continuer", ALL_CAPS, "--seed")
    vim.cmd("Conduit continue continuer")
    local chat
    wait_for(function()
        chat = conduit.current
        return chat and chat.session_id == "past-1" and not chat.busy
    end, "the latest thread to load")
    -- With a live thread, continue goes back to it.
    local other = assert(conduit.new())
    conduit.continue_thread("continuer")
    assert(conduit.current == chat and other ~= chat)
    drop_agent("continuer")
end)
