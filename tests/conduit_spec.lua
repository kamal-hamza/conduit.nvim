local conduit = require("conduit")

conduit.setup({
    default_agent = "mock",
    agents = { mock = { cmd = vim.v.progpath, args = { "-l", "tests/mock_agent.lua" } } },
    log_level = vim.log.levels.OFF,
})

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
    for _, fn in ipairs({ "open", "new", "toggle", "cancel", "stop", "add_range", "inline", "ask", "edit", "option" }) do
        assert(type(conduit[fn]) == "function", "missing conduit." .. fn)
    end
    local complete = vim.fn.getcompletion("Conduit ", "cmdline")
    for _, sub in ipairs({ "inline", "ask", "edit", "stop", "model", "effort", "mode" }) do
        assert(vim.tbl_contains(complete, sub), "missing subcommand " .. sub)
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
