local conduit = require("conduit")

conduit.setup({
    default_agent = "mock",
    agents = { mock = { cmd = vim.v.progpath, args = { "-l", "tests/mock_agent.lua" } } },
    log_level = vim.log.levels.OFF,
    sandbox = {
        -- Temp files are fair game; commands run unless a test says otherwise, and
        -- CI machines without an OS sandbox run them unisolated.
        roots = { vim.fn.fnamemodify(vim.fn.tempname(), ":h:h") },
        commands = { default = "allow" },
        isolation = { unavailable = "run" },
    },
})
-- Keep the history out of the user's directories.
require("conduit.history").dir = vim.fn.tempname() .. "/history"

---A session handler for tests that talk to the agent directly (what the chat
---used to be): collects the agent's text, tool calls, terminals and decisions.
---@class conduit.test.Session: conduit.SessionHandler
---@field agent conduit.Agent
---@field session_id? string
---@field text string
---@field tools table<string, table>
---@field terminals conduit.Terminal[]
---@field decisions table<string, string>
---@field history { role: string, text: string }[]
---@field exited? integer
---@field err? string
local Session = {}
Session.__index = Session

function Session:on_update(u)
    if u.sessionUpdate == "agent_message_chunk" and u.content and u.content.type == "text" then
        self.text = self.text .. u.content.text
    elseif (u.sessionUpdate == "tool_call" or u.sessionUpdate == "tool_call_update") and u.toolCallId then
        self.tools[u.toolCallId] = vim.tbl_extend("force", self.tools[u.toolCallId] or {}, u)
    end
end

function Session:request_permission(params, respond, reason)
    local permission = require("conduit.ui.permission")
    local call = params.toolCall or {}
    permission.ask(self.agent.name, permission.merge(self.tools[call.toolCallId], call), params, respond, reason)
end

function Session:on_agent_exit(code)
    self.exited = code
end

function Session:on_terminal(term)
    table.insert(self.terminals, term)
end

function Session:on_decision(id, decision)
    self.decisions[id] = decision
end

---@param name? string Agent
---@return conduit.test.Session
local function session(name)
    return setmetatable({
        agent = assert(conduit.agent(name)),
        text = "",
        tools = {},
        terminals = {},
        decisions = {},
        history = {},
        cwd = vim.fn.getcwd(),
    }, Session)
end

---Send `text` (with its @ mentions) as a turn, starting the session if needed.
---@param s conduit.test.Session
---@param text string
local function send(s, text)
    local done = false
    local function prompt()
        table.insert(s.history, { role = "user", text = text })
        local blocks = require("conduit.mentions").blocks(text, s.agent)
        s.agent:prompt(assert(s.session_id), blocks, function(err)
            s.err, done = err, true
        end)
    end
    if s.session_id then
        prompt()
    else
        s.agent:start(function(err)
            assert(not err, err)
            s.agent:new_session(s.cwd, s, function(serr, sid)
                assert(not serr, serr)
                s.session_id = sid
                prompt()
            end)
        end)
    end
    wait_for(function()
        return done
    end, "turn to finish")
end

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

-- A valid 1x1 PNG.
local PNG = vim.base64.decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)

---@param path string
---@param bytes string
local function write_bytes(path, bytes)
    local f = assert(io.open(path, "wb"))
    f:write(bytes)
    f:close()
end

---Image fixtures: shot.png, photo.jpg (JPEG signature only) and fake.png (text).
local function image_fixture()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    write_bytes(root .. "/shot.png", PNG)
    write_bytes(root .. "/photo.jpg", "\255\216\255\224\0\16JFIF\0rest")
    vim.fn.writefile({ "not really a png" }, root .. "/fake.png")
    return root
end

---Run `fn` with vim.notify captured; returns the messages.
---@param fn fun()
---@return string[]
local function capture_notify(fn)
    local orig = vim.notify
    local msgs = {} ---@type string[]
    vim.notify = function(msg)
        table.insert(msgs, msg)
    end
    local ok, err = pcall(fn)
    vim.notify = orig
    assert(ok, err)
    return msgs
end

local function prompt_caps(caps)
    return { info = { agentCapabilities = { promptCapabilities = caps } } }
end

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

---@param buf integer
---@param lhs string
local function press(buf, lhs)
    vim.api.nvim_buf_call(buf, function()
        vim.fn.maparg(lhs, "n", false, true).callback()
    end)
end

---Run a normal-mode mapping of the current buffer in the current window (unlike
---`press`, focus changes the mapping makes stick).
---@param lhs string
local function press_here(lhs)
    vim.fn.maparg(lhs, "n", false, true).callback()
end

---Stub vim.ui.select with `choose` (returns the item to pick, or nil) while `fn` runs.
---@param choose fun(items: any[], opts: table): any
---@param fn fun()
---@return string[] prompts
local function with_select(choose, fn)
    local orig = vim.ui.select
    local prompts = {} ---@type string[]
    vim.ui.select = function(items, opts, cb)
        table.insert(prompts, opts.prompt or "")
        cb(choose(items, opts))
    end
    local ok, err = pcall(fn)
    vim.ui.select = orig
    assert(ok, err)
    return prompts
end

---The sidebar's buffer text.
---@return string
local function sidebar_text()
    local sidebar = require("conduit.ui.sidebar")
    local buf = assert(sidebar.buf, "no sidebar buffer")
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function reset_sidebar()
    require("conduit.ui.sidebar").reset()
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.cmd("only")
    end
end

---A handler for sessions a test opens directly.
---@type conduit.SessionHandler
local null_handler = {
    on_update = function() end,
    request_permission = function(_, _, respond)
        respond(nil, { outcome = { outcome = "cancelled" } })
    end,
    on_agent_exit = function() end,
}

---Collect log warnings while `fn` runs.
---@param fn fun()
---@return string[]
local function warnings(fn)
    local log = require("conduit.log")
    local orig, out = log.warn, {}
    log.warn = function(msg)
        table.insert(out, msg)
    end
    local ok, err = pcall(fn)
    log.warn = orig
    assert(ok, err)
    return out
end

local ALL_CAPS = "--threads=load,list,resume,close,delete,fork,title"

---Register a mock agent with extra arguments under a new name and start it.
---@param name string
---@param ... string Extra mock arguments
---@return conduit.Agent agent
local function extra_agent(name, ...)
    local config = require("conduit.config").options
    config.agents[name] = { cmd = vim.v.progpath, args = { "-l", "tests/mock_agent.lua", ... } }
    local agent = assert(conduit.agent(name))
    local started
    agent:start(function(err)
        assert(not err, err)
        started = true
    end)
    wait_for(function()
        return started
    end, name .. " to start")
    return agent
end

---@param name string
local function drop_agent(name)
    local agent = conduit.agents[name] ---@type conduit.Agent?
    if agent then
        agent:stop()
        conduit.agents[name] = nil
    end
    require("conduit.config").options.agents[name] = nil
end

---@param list conduit.Command[]
---@return string[]
local function names(list)
    return vim.tbl_map(function(c)
        return c.name
    end, list)
end

---Results the mock said for each terminal step (`<step> <json>` lines), in order.
---@param s conduit.test.Session
---@return { step: string, value: table }[]
local function term_results(s)
    local out = {}
    for _, line in ipairs(vim.split(s.text, "\n", { plain = true })) do
        local step, json = line:match("^(%a+) ({.*})$")
        if step and json then
            table.insert(out, { step = step, value = vim.json.decode(json, { luanil = { object = true } }) })
        end
    end
    return out
end

---Run a `term` prompt in a new session.
---@param create table terminal/create params
---@param steps string[]
---@return conduit.test.Session, table<string, table> results Last result per step
local function run_term(create, steps)
    local s = session()
    send(s, "term " .. vim.json.encode({ create = create, steps = steps }))
    local by_step = {}
    for _, r in ipairs(term_results(s)) do
        by_step[r.step] = r.value
    end
    return s, by_step
end

-- Review helpers -----------------------------------------------------------

local review = require("conduit.review")
local review_ui = require("conduit.ui.review")

---A temp file with `lines`, its canonical path.
---@param lines string[]
---@return string
local function review_file(lines)
    local path = vim.fn.tempname()
    vim.fn.writefile(lines, path)
    return require("conduit.fs").canonical(path)
end

---The review entry for `path`, if it's tracked.
---@param path string
---@return conduit.ReviewFile?
local function tracked(path)
    local file = review.files[path] ---@type conduit.ReviewFile?
    return file
end

local function review_marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, review_ui.ns, 0, -1, { details = true })
end

---@param buf integer
---@param lhs string
---@return boolean
local function has_map(buf, lhs)
    return vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n", false, true).buffer == 1
    end)
end

local function review_cleanup()
    review.reset()
    reset_sidebar()
    vim.cmd("silent! %bwipeout!")
end

---Entries of this project's history.
---@return conduit.HistoryEntry[]
local function history_entries()
    return require("conduit.history").load()
end

local function clear_history()
    vim.fn.delete(require("conduit.history").path())
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

test("permission: describe handles each rawInput shape and fallbacks", function()
    local describe = require("conduit.ui.permission").describe
    local info = describe({ kind = "execute", rawInput = { command = { "git", "status", "--short" } } })
    assert(info.title == "run a command", info.title)
    assert(vim.deep_equal(info.command, { "git status --short" }), vim.inspect(info.command))
    assert(vim.deep_equal(describe({ rawInput = { command = { "zsh", "-c", "a\nb\n" } } }).command, { "a", "b" }))

    local read = describe({ title = "  Read\nmore", kind = "read", rawInput = { file_path = "/x" } })
    assert(read.title == "Read" and read.command == nil, vim.inspect(read))
    local empty = describe({ rawInput = vim.NIL, title = vim.NIL })
    assert(empty.title == "run a tool" and empty.kind == nil and #empty.paths == 0, vim.inspect(empty))

    local cwd_file = vim.fn.getcwd() .. "/lua/conduit/init.lua"
    local located = describe({
        locations = { { path = cwd_file, line = 3 }, { path = cwd_file, line = 3 }, { path = "/abs/x" } },
        content = { { type = "diff", path = "/ignored" } },
    })
    assert(vim.deep_equal(located.paths, { "lua/conduit/init.lua:3", "/abs/x" }), vim.inspect(located.paths))
    local edit = describe({ kind = "edit", content = { { type = "content" }, { type = "diff", path = "/d.lua" } } })
    assert(edit.title == "edit a file" and vim.deep_equal(edit.paths, { "/d.lua" }), vim.inspect(edit))
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
    local err ---@type string?
    agent:start(function(e)
        err = e
    end)
    assert(err and err:find("executable not found"), err)
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
    assert(#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("conduit.inline"), 0, -1, {}) == 0)
    -- The new lines flash briefly, without a window.
    local flash = vim.api.nvim_buf_get_extmarks(
        0,
        vim.api.nvim_create_namespace("conduit.inline.flash"),
        0,
        -1,
        { details = true }
    )
    assert(#flash == 1 and flash[1][2] == 1 and flash[1][4].end_row == 2, vim.inspect(flash))
    assert(flash[1][4].line_hl_group == "ConduitInlineAdded")
    vim.cmd("bwipeout!")
end)

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
    local link = assert(links[2])
    assert(link.type == "resource_link" and link.name == "a.lua")
    assert(link.uri == vim.uri_from_fname(root .. "/a.lua"))
end)

test("mentions: images become image blocks when the agent accepts them", function()
    local root = image_fixture()
    local mentions = require("conduit.mentions")
    local blocks = {} ---@type table[]
    local msgs = capture_notify(function()
        -- No embeddedContext: images don't depend on it.
        blocks = mentions.blocks("look @shot.png and @photo.jpg", prompt_caps({ image = true }), { root = root })
    end)
    assert(#msgs == 0, vim.inspect(msgs))
    assert(#blocks == 3, vim.inspect(blocks))
    local png = blocks[2]
    assert(png.type == "image" and png.mimeType == "image/png", vim.inspect(png))
    assert(vim.base64.decode(png.data) == PNG)
    assert(png.uri == vim.uri_from_fname(root .. "/shot.png"))
    assert(blocks[3].type == "image" and blocks[3].mimeType == "image/jpeg", vim.inspect(blocks[3]))
end)

test("mentions: images are links with a warning when not accepted or too large", function()
    local root = image_fixture()
    local mentions = require("conduit.mentions")
    local blocks = {} ---@type table[]
    local msgs = capture_notify(function()
        blocks = mentions.blocks("@shot.png", prompt_caps({ embeddedContext = true }), { root = root })
    end)
    local link = assert(blocks[2])
    assert(link.type == "resource_link" and link.name == "shot.png" and link.mimeType == "image/png")
    assert(#msgs == 1 and msgs[1]:find("doesn't accept images", 1, true), vim.inspect(msgs))

    local max = mentions.max_image_bytes
    mentions.max_image_bytes = 10
    msgs = capture_notify(function()
        blocks = mentions.blocks("@shot.png", prompt_caps({ image = true }), { root = root })
    end)
    mentions.max_image_bytes = max
    assert(assert(blocks[2]).type == "resource_link", vim.inspect(blocks[2]))
    assert(#msgs == 1 and msgs[1]:find("larger than", 1, true), vim.inspect(msgs))
end)

test("mentions: images are detected by content, not extension", function()
    local root = image_fixture()
    local mentions = require("conduit.mentions")
    local blocks = mentions.blocks("@fake.png", prompt_caps({ image = true, embeddedContext = true }), { root = root })
    local b = assert(blocks[2])
    assert(b.type == "resource" and b.resource.text == "not really a png\n", vim.inspect(b))
    assert(mentions.image_mime(root .. "/fake.png") == nil)
end)

test("mentions: completion marks image files", function()
    local root = image_fixture()
    local mentions = require("conduit.mentions")
    mentions.reset()
    local items = mentions.items("shot", root)
    mentions.reset()
    local item = assert(items[1])
    assert(item.word == "shot.png" and item.detail == "image", vim.inspect(item))
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
    local first = assert(got.items[1])
    assert(first.label == "lua/conduit/", vim.inspect(first))
    assert(first.kind == 19 and first.textEdit.newText == "lua/conduit/")
    local range = first.textEdit.range
    assert(range.start.character == 7 and range["end"].character == 14, vim.inspect(range))

    ---@type table?
    local resolved
    local file ---@type table?
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

test("inline: permission prompts include what the agent wants to run", function()
    reset_sidebar()
    inline_buf()
    -- The command runs in /tmp, outside the roots: without the sandbox, the user decides.
    require("conduit.config").options.sandbox.enabled = false
    local orig_select = vim.ui.select
    local prompt ---@type string?
    vim.ui.select = function(items, opts, cb)
        prompt = opts.prompt
        cb(items[1])
    end
    local job = assert(conduit.inline(2, 3, "run it"))
    wait_turn(job)
    vim.ui.select = orig_select
    require("conduit.config").options.sandbox.enabled = true
    assert(prompt, "no permission prompt")
    assert(prompt:find("^mock wants to echo one\nkind: execute\n"), prompt)
    assert(prompt:find("$ echo one\n  echo two\n  echo three", 1, true), prompt)
    assert(job.tools.r1 and job.tools.r1.status == "completed", vim.inspect(job.tools))
    reset_sidebar()
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
    assert(below.relative == "win" and assert(below.bufpos)[1] == 2 and below.row == 1, vim.inspect(below))

    local above = placement({ win = win, first = height - 3, last = height - 1 })
    assert(
        above.relative == "win" and assert(above.bufpos)[1] == height - 3 and above.anchor == "SW",
        vim.inspect(above)
    )

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
    local status ---@type table?
    local range ---@type table?
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
    -- Minimal: the spinner and the agent, nothing else.
    assert(vim.trim(line):match("^%S+ mock$"), line)

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

test("mcp: builds stdio and http servers in ACP shape", function()
    local config = require("conduit.config").options
    local sh = vim.fn.exepath("sh")
    config.mcp_servers = {
        local_tool = {
            command = "sh",
            args = { "-c", 42 },
            env = {
                ZED = "z",
                TOKEN = function()
                    return "secret"
                end,
            },
        },
        docs = { type = "http", url = "https://example.com/mcp", headers = { Authorization = "Bearer x" } },
    }
    local agent = {
        name = "fake",
        spec = { cmd = "fake" },
        info = { agentCapabilities = { mcpCapabilities = { http = true } } },
    }
    local servers = require("conduit.mcp").servers(agent)
    config.mcp_servers = {}
    assert(
        vim.deep_equal(servers, {
            {
                type = "http",
                name = "docs",
                url = "https://example.com/mcp",
                headers = { { name = "Authorization", value = "Bearer x" } },
            },
            {
                name = "local_tool",
                command = sh,
                args = { "-c", "42" },
                env = { { name = "TOKEN", value = "secret" }, { name = "ZED", value = "z" } },
            },
        }),
        vim.inspect(servers)
    )
end)

test("mcp: accepts a list and per-agent overrides", function()
    local config = require("conduit.config").options
    config.mcp_servers = {
        { name = "one", command = "sh" },
        { name = "two", command = "sh" },
        { name = "three", command = "sh", enabled = false },
    }
    local agent = {
        name = "fake",
        spec = { cmd = "fake", mcp_servers = { two = false, four = { command = "sh", args = { "x" } } } },
    }
    local names = vim.tbl_map(function(s)
        return s.name
    end, require("conduit.mcp").servers(agent))
    config.mcp_servers = {}
    assert(vim.deep_equal(names, { "four", "one" }), vim.inspect(names))
end)

test("mcp: skips servers it can't send, warning once each", function()
    local config = require("conduit.config").options
    config.mcp_servers = {
        nocmd = {},
        missing = { command = "conduit-no-such-mcp-server" },
        nourl = { type = "http" },
        http = { type = "http", url = "https://example.com/mcp" },
        weird = { type = "carrier-pigeon", url = "x" },
        broken = {
            command = "sh",
            env = {
                TOKEN = function()
                    error("hidden-value")
                end,
            },
        },
        ok = { command = "sh" },
    } --[[@as conduit.McpServers]] -- deliberately invalid entries
    local agent = { name = "skipper", spec = { cmd = "fake" }, info = { agentCapabilities = {} } }
    local mcp = require("conduit.mcp")
    local found ---@type table[]?
    local warned = warnings(function()
        found = mcp.servers(agent)
        mcp.servers(agent)
    end)
    local servers = assert(found)
    config.mcp_servers = {}
    assert(#servers == 1 and servers[1].name == "ok", vim.inspect(servers))
    assert(#warned == 6, vim.inspect(warned))
    local text = table.concat(warned, "\n")
    for _, want in ipairs({
        "missing command",
        "command not found: conduit-no-such-mcp-server",
        "missing url",
        "doesn't support http",
        'unknown type "carrier-pigeon"',
        "env.TOKEN",
    }) do
        assert(text:find(want, 1, true), want .. " in " .. text)
    end
end)

test("mcp: new sessions send the servers", function()
    local config = require("conduit.config").options
    config.mcp_servers = {
        tool = { command = "sh", env = { A = "1" } },
        docs = { type = "http", url = "https://example.com/mcp" },
        events = { type = "sse", url = "https://example.com/sse" },
    }
    local agent = extra_agent("mcper", ALL_CAPS, "--mcp=http")
    local sh = vim.fn.exepath("sh")
    local want = {
        { type = "http", name = "docs", url = "https://example.com/mcp", headers = {} },
        { name = "tool", command = sh, args = {}, env = { { name = "A", value = "1" } } },
    }

    ---@param open fun(cb: fun(err: string?, sid: string?, result: table?))
    ---@return table servers, string sid
    local function sent(open)
        local done = false
        local err ---@type string?
        local sid ---@type string?
        local result ---@type table?
        open(function(e, s, r)
            done, err, sid, result = true, e, s, r
        end)
        wait_for(function()
            return done
        end, "session to open")
        assert(not err, err)
        local meta = assert(assert(result)._meta) --[[@as table]]
        return meta.mcpServers, assert(sid)
    end

    local cwd = vim.fn.getcwd()
    local servers ---@type table
    local sid = "" ---@type string
    warnings(function()
        servers, sid = sent(function(cb)
            agent:new_session(cwd, null_handler, cb)
        end)
    end)
    assert(vim.deep_equal(servers, want), vim.inspect(servers))
    agent:close_session(sid)
    servers = sent(function(cb)
        agent:new_session(cwd, null_handler, cb, nil, { mcp = false })
    end)
    assert(vim.tbl_isempty(servers), vim.inspect(servers))
    config.mcp_servers = {}
    drop_agent("mcper")
end)

test("mcp: inline requests only get servers with inline.mcp_servers", function()
    local config = require("conduit.config").options
    config.mcp_servers = { tool = { command = "sh" } }
    local agent = assert(conduit.agent("mock"))
    local request = agent._request --[[@as fun(self: conduit.Agent, method: string, params: table, cb: fun(err: table?, result: any))]]
    local sent = {}
    ---@param self conduit.Agent
    ---@param method string
    ---@param params table
    ---@param cb fun(err: table?, result: any)
    local function spy(self, method, params, cb)
        if method == "session/new" then
            table.insert(sent, #params.mcpServers)
        end
        return request(self, method, params, cb)
    end
    rawset(agent, "_request", spy)
    local inline = require("conduit.inline")
    for _, enabled in ipairs({ false, true }) do
        config.inline.mcp_servers = enabled
        vim.cmd.enew()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local a = 1" })
        conduit.inline(1, 1, "uppercase it")
        wait_for(function()
            return next(inline.jobs) == nil
        end, "inline edit")
        vim.cmd("bwipeout!")
    end
    rawset(agent, "_request", nil) -- back to the class method
    config.inline.mcp_servers = false
    config.mcp_servers = {}
    assert(vim.deep_equal(sent, { 0, 1 }), vim.inspect(sent))
end)

test("commands: the agent keeps each session's slash commands", function()
    local agent = require("conduit.agent").new("cmds", require("conduit.config").options.agents.mock)
    local noop = function() end
    local handler = { on_update = noop, request_permission = noop, on_agent_exit = noop }
    local sid ---@type string?
    agent:start(function()
        agent:new_session(vim.fn.getcwd(), handler, function(_, s)
            sid = s
        end)
    end)
    wait_for(function()
        return sid and agent.commands[sid] ~= nil
    end, "commands for the new session")
    assert(vim.deep_equal(names(agent:get_commands(sid)), { "review", "compact" }))
    -- Before a session exists, the last list stands in.
    assert(vim.deep_equal(names(agent:get_commands()), { "review", "compact" }))
    local id = assert(sid)
    agent:close_session(id)
    assert(agent.commands[id] == nil, "closing forgets the session's commands")
    agent:stop()
end)

test("terminal: honours cwd and env", function()
    local dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    local _, r = run_term({
        command = "sh",
        args = { "-c", 'printf "%s %s" "$CONDUIT_TEST" "$(pwd -P)"' },
        cwd = dir,
        env = { { name = "CONDUIT_TEST", value = "hi" } },
    }, { "wait", "output" })
    assert(r.output.output == "hi " .. dir, vim.inspect(r.output))
end)

test("terminal: a whole command line without args runs in a shell", function()
    local _, r = run_term({ command = "echo one && echo two" }, { "wait", "output" })
    assert(r.wait.exitCode == 0, vim.inspect(r.wait))
    assert(r.output.output == "one\ntwo\n", vim.inspect(r.output))
end)

test("terminal: output beyond the byte limit drops the oldest output", function()
    -- "é" is two bytes: a cut at the limit lands mid-character and must skip it.
    local _, r = run_term({ command = "printf", args = { "0123456789é" }, outputByteLimit = 3 }, { "wait", "output" })
    assert(r.output.truncated == true, vim.inspect(r.output))
    assert(r.output.output == "9é", vim.inspect(r.output))
end)

test("terminal: missing executables are reported to the agent", function()
    local _, r = run_term({ command = "conduit-no-such-cmd", args = { "x" } }, {})
    assert(r.create.code == -32603 and r.create.message:find("conduit%-no%-such%-cmd"), vim.inspect(r.create))
end)

test("terminal: display lines strip escapes and resolve carriage returns", function()
    local Terminal = require("conduit.terminal")
    local lines = Terminal.display_lines("\27[32mok\27[0m\r\n10%\r50%\r100%\nend")
    assert(vim.deep_equal(lines, { "ok", "100%", "end" }), vim.inspect(lines))
    assert(Terminal.sanitize("a\255b") == "a\239\191\189b")
    assert(Terminal.sanitize("é") == "é")
end)

test("headless: picker filters, moves with counts and picks by number", function()
    local picked ---@type any
    local cancelled = false
    local model = require("conduit.ui.headless.picker").new({
        items = { { value = 1, label = "low" }, { value = 2, label = "medium" }, { value = 3, label = "high" } },
        current = 2,
        on_pick = function(item)
            picked = item.value
        end,
        on_cancel = function()
            cancelled = true
        end,
    })
    assert(model.cursor == 2, "cursor starts on the current item")
    model:next(2)
    assert(model.cursor == 1, "moves wrap: " .. model.cursor)
    model:filter("i")
    assert(#model.filtered == 2 and model.filtered[1].label == "medium", vim.inspect(model.filtered))
    model:pick(2)
    assert(picked == 3, tostring(picked))
    model:cancel()
    assert(not cancelled, "a finished picker can't be cancelled")
end)

test("headless: options step through values both ways", function()
    local step = require("conduit.ui.headless.options").step
    local option = {
        id = "effort",
        name = "effort",
        current = "low",
        choices = {
            { value = "low", name = "low" },
            { value = "mid", name = "mid" },
            { value = "high", name = "high" },
        },
    }
    assert(step(option, 1) == "mid" and step(option, 2) == "high" and step(option, -1) == "high")
    option.current = "unknown"
    assert(step(option, 1) == "low" and step(option, -1) == "high")
end)

test("prompt: title shows the request's model and effort; <C-o> changes them for it", function()
    vim.cmd.enew()
    local code_win = vim.api.nvim_get_current_win()
    local submitted ---@type table?
    local list = {
        {
            id = "model",
            name = "model",
            category = "model",
            current = "fast",
            choices = { { value = "fast", name = "FAST" }, { value = "smart", name = "SMART" } },
        },
        {
            id = "effort",
            name = "effort",
            category = "thought_level",
            current = "low",
            choices = { { value = "low", name = "LOW" }, { value = "high", name = "HIGH" } },
        },
    }
    local _, win = require("conduit.ui.prompt").open({
        title = "init.lua:1",
        agent = "mock",
        mode = "auto",
        anchor = { win = code_win, first = 0, last = 0 },
        options = function()
            return list
        end,
        on_submit = function(text, _, overrides)
            submitted = { text = text, overrides = overrides }
        end,
    })
    vim.cmd.stopinsert()
    assert(chunks_text(win, "title"):find("FAST/LOW", 1, true), chunks_text(win, "title"))

    -- <C-o>: pick "effort" (row 2), then "HIGH" (row 2).
    press_here("<C-o>")
    vim.api.nvim_feedkeys("2", "x", false)
    wait_for(function()
        return vim.bo.filetype == "conduit_picker"
            and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("LOW", 1, true)
    end, "value picker")
    vim.api.nvim_feedkeys("2", "x", false)
    assert(vim.api.nvim_get_current_win() == win, "focus returns to the prompt")
    assert(chunks_text(win, "title"):find("FAST/HIGH", 1, true), chunks_text(win, "title"))
    assert(list[2].current == "low", "the agent's options are untouched")

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "explain" })
    press_here("<CR>")
    wait_for(function()
        return submitted
    end, "submit")
    assert(submitted and submitted.overrides and submitted.overrides.effort == "high", vim.inspect(submitted))
    vim.cmd("bwipeout!")
end)

test("inline: request options reach the inline session", function()
    local buf = inline_buf()
    local job = require("conduit.inline").run({
        agent = assert(conduit.agent()),
        buf = buf,
        line1 = 2,
        line2 = 3,
        instruction = "explain this",
        options = { effort = "high" },
    })
    wait_turn(job)
    local option = require("conduit.options").find(job.agent:get_options(assert(job.session_id)), "effort")
    assert(option and option.current == "high", vim.inspect(option))
    job.agent:set_option(assert(job.session_id), "effort", "low")
    reset_sidebar()
    vim.cmd("bwipeout!")
end)

test("review: edits made on disk show as hunks in the open buffer", function()
    local path = review_file({ "a", "old", "b", "c", "d", "old", "e" })
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    local chat = session()
    send(chat, "disk-edit " .. path)

    -- The unmodified buffer was reloaded from disk.
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert(vim.deep_equal(lines, { "a", "new", "b", "c", "d", "new", "e" }), vim.inspect(lines))
    local file = assert(tracked(path), "file should be tracked")
    assert(vim.deep_equal(file.baseline, { "a", "old", "b", "c", "d", "old", "e" }), vim.inspect(file.baseline))
    assert(#file.hunks == 2, vim.inspect(file.hunks))

    -- Changed lines are highlighted, removed ones shown as virtual lines.
    local marks = review_marks(buf)
    local changed, virt = 0, {}
    for _, m in ipairs(marks) do
        local details = assert(m[4])
        if details.line_hl_group == "ConduitReviewChange" then
            changed = changed + 1
        end
        for _, vl in ipairs(details.virt_lines or {}) do
            table.insert(virt, vim.trim(vl[1][1]))
        end
    end
    assert(changed == 2, vim.inspect(marks))
    assert(vim.deep_equal(virt, { "old", "old" }), vim.inspect(virt))
    assert(has_map(buf, "]r") and has_map(buf, "<localleader>a"))

    -- ]r jumps between hunks.
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    review_ui.jump(1)
    assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
    review_ui.jump(1)
    assert(vim.api.nvim_win_get_cursor(0)[1] == 6)
    review_ui.jump(-1)
    assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
    review_cleanup()
end)

test("review: hunks are accepted and rejected one at a time", function()
    local path = review_file({ "a", "old", "b", "c", "d", "old", "e" })
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    local chat = session()
    send(chat, "disk-edit " .. path)
    vim.api.nvim_set_current_buf(buf)

    -- Reject the first hunk: its line comes back, in the buffer and on disk.
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    review_ui.act("reject")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert(vim.deep_equal(lines, { "a", "old", "b", "c", "d", "new", "e" }), vim.inspect(lines))
    assert(not vim.bo[buf].modified)
    assert(vim.deep_equal(vim.fn.readfile(path), lines))
    assert(#assert(tracked(path)).hunks == 1)

    -- Accept the second: nothing is left to review and the overlay goes away.
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    review_ui.act("accept")
    assert(tracked(path) == nil)
    assert(#review_marks(buf) == 0)
    assert(not has_map(buf, "]r") and not has_map(buf, "<localleader>a"))
    assert(vim.deep_equal(vim.fn.readfile(path), { "a", "old", "b", "c", "d", "new", "e" }))
    review_cleanup()
end)

test("review: rejecting restores files that aren't open", function()
    local path = review_file({ "old", "keep" })
    local chat = session()
    send(chat, "disk-edit " .. path)
    assert(vim.deep_equal(vim.fn.readfile(path), { "new", "keep" }))
    local items = review.qflist()
    assert(#items == 1 and items[1].text == "+1 −1" and items[1].lnum == 1, vim.inspect(items))
    review.reject(path)
    assert(vim.deep_equal(vim.fn.readfile(path), { "old", "keep" }))
    assert(tracked(path) == nil)
    review_cleanup()
end)

test("review: created and deleted files are restored by rejecting them", function()
    local chat = session()
    local created = require("conduit.fs").canonical(vim.fn.tempname())
    send(chat, "disk-create " .. created)
    assert(vim.uv.fs_stat(created))
    local items = review.qflist()
    assert(#items == 1 and items[1].text == "created by the agent", vim.inspect(items))
    review.reject(created)
    assert(not vim.uv.fs_stat(created), "created file should be removed")

    local deleted = review_file({ "precious", "lines" })
    send(chat, "disk-delete " .. deleted)
    assert(not vim.uv.fs_stat(deleted))
    local deleted_items = review.qflist()
    assert(#deleted_items == 1 and deleted_items[1].text == "deleted by the agent", vim.inspect(deleted_items))
    review.reject(deleted)
    assert(vim.deep_equal(vim.fn.readfile(deleted), { "precious", "lines" }))
    assert(#review.list() == 0)
    review_cleanup()
end)

test("review: a write that lands before its tool call is rebuilt from the diff", function()
    local path = review_file({ "a", "old", "b" })
    local chat = session()
    send(chat, "disk-edit-fast " .. path)
    local file = assert(tracked(path), "file should be tracked")
    assert(vim.deep_equal(file.baseline, { "a", "old", "b" }), vim.inspect(file.baseline))
    review.reject(path)
    assert(vim.deep_equal(vim.fn.readfile(path), { "a", "old", "b" }))
    review_cleanup()
end)

test("review: fs/write_text_file edits are reviewed in the buffer", function()
    local path = review_file({ "hello", "world" })
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    local orig_select = vim.ui.select
    vim.ui.select = function(items, _, cb)
        cb(items[1])
    end
    local chat = session()
    send(chat, "edit " .. path)
    vim.ui.select = orig_select
    assert(#assert(tracked(path)).hunks == 1)
    assert(#review_marks(buf) > 0)
    review.reject(path)
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "hello", "world" }))
    assert(vim.deep_equal(vim.fn.readfile(path), { "hello", "world" }))
    review_cleanup()
end)

test("review: unsaved changes in the buffer are left alone as a conflict", function()
    local path = review_file({ "old", "b" })
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    local orig_notify = vim.notify
    local warned ---@type string?
    vim.notify = function(msg)
        warned = msg
    end
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "mine" })
    local chat = session()
    send(chat, "disk-edit " .. path)
    vim.notify = orig_notify
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "old", "mine" }))
    local file = assert(tracked(path))
    assert(file.conflict)
    assert(warned and warned:find("unsaved changes", 1, true), tostring(warned))
    assert(#review_marks(buf) == 0)
    local item = assert(review.qflist()[1])
    assert(item.text and item.text:find("conflict", 1, true), vim.inspect(item))
    -- Rejecting puts back what the buffer had when the agent started.
    review.reject(path)
    assert(vim.deep_equal(vim.fn.readfile(path), { "old", "mine" }))
    review_cleanup()
end)

test("review: turned off, edits apply as before", function()
    local config = require("conduit.config").options
    config.review.enabled = false
    local path = review_file({ "old" })
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    local chat = session()
    send(chat, "disk-edit " .. path)
    config.review.enabled = true
    assert(next(review.files) == nil)
    assert(#review_marks(buf) == 0 and not has_map(buf, "]r"))
    assert(vim.deep_equal(vim.fn.readfile(path), { "new" }))
    review_cleanup()
end)

test("review: user edits recompute hunks; undoing the change by hand clears it", function()
    local path = review_file({ "old", "b" })
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    local chat = session()
    send(chat, "disk-edit " .. path)
    assert(tracked(path))
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "old" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    wait_for(function()
        return review.files[path] == nil
    end, "the review to clear")
    assert(#review_marks(buf) == 0)
    review_cleanup()
end)

test("review: :Conduit review lists changes; toggle and accept all", function()
    local a = review_file({ "old" })
    local b = review_file({ "x", "old" })
    local chat = session()
    send(chat, "disk-edit " .. a)
    send(chat, "disk-edit " .. b)
    vim.cmd("Conduit review")
    local qf = vim.fn.getqflist({ title = true, items = true })
    assert(qf.title == "conduit review" and #qf.items == 2, vim.inspect(qf))
    vim.cmd("cclose")

    local orig_notify = vim.notify
    vim.notify = function() end
    vim.cmd("Conduit review toggle")
    assert(require("conduit.config").options.review.enabled == false)
    vim.cmd("Conduit review toggle")
    vim.notify = orig_notify
    assert(require("conduit.config").options.review.enabled == true)

    vim.cmd("Conduit accept all")
    assert(#review.list() == 0)
    assert(vim.deep_equal(vim.fn.readfile(a), { "new" }) and vim.deep_equal(vim.fn.readfile(b), { "x", "new" }))
    review_cleanup()
end)

-- Sessions without a chat ---------------------------------------------------

test("agent: streams agent message chunks to the session handler", function()
    local s = session()
    send(s, "hi there")
    assert(s.text:find("Hello from mock\nyou said: hi there", 1, true), s.text)
    assert(s.session_id ~= nil)
end)

test("agent: permissions and fs read/write go through the handler", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "hello", "world" }, path)
    local s = session()
    local prompts = with_select(function(items)
        return items[1]
    end, function()
        send(s, "edit " .. path)
    end)
    -- Kind and location come from the earlier tool call: the request only adds the diff.
    local rel = vim.fn.fnamemodify(path, ":~:.")
    assert(prompts[1] == ("mock wants to Edit %s\nkind: edit\n  %s:1"):format(path, rel), tostring(prompts[1]))
    assert(s.text:find("first line was: hello", 1, true), s.text)
    assert(vim.deep_equal(vim.fn.readfile(path), { "HELLO", "WORLD" }))
    assert(s.decisions.t1 == "asked: allow", vim.inspect(s.decisions))
    review.reset()
end)

test("permission: prompts show the kind, the full command and paths", function()
    local config = require("conduit.config").options
    config.sandbox.enabled = false
    local s = session()
    local prompts = with_select(function(items)
        return items[2]
    end, function()
        send(s, "run")
        send(s, "run-argv")
    end)
    config.sandbox.enabled = true
    local expected = table.concat({
        "mock wants to echo one",
        "kind: execute",
        "  /tmp/conduit-run",
        "$ echo one",
        "  echo two",
        "  echo three",
    }, "\n")
    assert(prompts[1] == expected, tostring(prompts[1]))
    assert(prompts[2] == expected, "argv commands show the shell script:\n" .. tostring(prompts[2]))
    assert(s.text:find("chose reject", 1, true), s.text)
end)

---Open a session on `s` without sending anything.
---@param s conduit.test.Session
local function open(s)
    local done
    s.agent:start(function(err)
        assert(not err, err)
        s.agent:new_session(s.cwd, s, function(serr, sid)
            assert(not serr, serr)
            s.session_id, done = sid, true
        end)
    end)
    wait_for(function()
        return done
    end, "session")
end

test("options: config options, defaults and set_option", function()
    local config = require("conduit.config").options
    config.agents.mock.options = { effort = "low" }
    local s = session()
    open(s)
    config.agents.mock.options = nil
    local options = require("conduit.options")
    local sid = assert(s.session_id)
    local opts = s.agent:get_options(sid)
    assert(assert(options.find(opts, "effort")).current == "low", "default should be applied")
    assert(assert(options.find(opts, "thought_level")).id == "effort", "effort is found by category")
    local done
    s.agent:set_option(sid, "model", "smart", function(err)
        assert(not err, err)
        done = true
    end)
    wait_for(function()
        return done
    end, "set_option")
    assert(assert(options.find(s.agent:get_options(sid), "model")).current == "smart")
    s.agent:close_session(sid)
end)

test("options: legacy modes and models; bypass modes are refused", function()
    extra_agent("legacy", "--legacy")
    local s = session("legacy")
    open(s)
    local options = require("conduit.options")
    local sid = assert(s.session_id)
    local opts = s.agent:get_options(sid)
    assert(assert(options.find(opts, "mode")).current == "ask")
    local done, err
    s.agent:set_option(sid, "model", "m2", function(e)
        done, err = true, e
    end)
    wait_for(function()
        return done
    end, "set_model")
    assert(not err, err)
    assert(assert(options.find(opts, "model")).current == "m2")

    -- The sandbox can't see what a bypass mode lets through, so it's off limits.
    done, err = false, nil
    s.agent:set_option(sid, "mode", "bypassPermissions", function(e)
        done, err = true, e
    end)
    assert(done and err and err:find("sandbox.bypass", 1, true), tostring(err))
    assert(assert(options.find(opts, "mode")).current == "ask")
    local config = require("conduit.config").options
    config.sandbox.bypass = true
    done = false
    s.agent:set_option(sid, "mode", "code", function()
        done = true
    end)
    wait_for(function()
        return done
    end, "set_mode")
    config.sandbox.bypass = false
    drop_agent("legacy")
end)

test("mentions: typing @ opens completion in the prompt", function()
    local buf = require("conduit.ui.prompt").open({ title = "test", on_submit = function() end })
    vim.cmd.stopinsert()
    local items ---@type { col: integer, list: table[] }?
    local orig = vim.fn.complete
    require("conduit.mentions").reset()
    vim.fn.complete = function(col, list)
        items = { col = col, list = list }
    end
    -- Cursor on the trailing "x" stands in for the insert-mode cursor after "co".
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hi @lua/cox" })
    vim.api.nvim_win_set_cursor(0, { 1, 10 })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
    vim.fn.complete = orig
    vim.api.nvim_win_close(0, true)
    assert(items and items.col == 5, vim.inspect(items))
    local words = vim.tbl_map(function(i)
        return i.word
    end, items.list)
    assert(vim.tbl_contains(words, "lua/conduit/"), vim.inspect(words))
end)

test("mentions: @mentions are sent as resources", function()
    local s = session()
    send(s, "look at @tests/run.lua and @lua/conduit/ui/")
    assert(s.text:find("resource run.lua %d+"), s.text)
    assert(s.text:find("resource ui %d+"), s.text)
end)

test("mentions: images reach the agent as image blocks, or as links with a warning", function()
    local root = image_fixture()
    local s = session()
    send(s, "what is in @" .. root .. "/shot.png")
    assert(s.text:find(("image shot.png image/png %d"):format(#PNG), 1, true), s.text)

    extra_agent("blind", "--no-image")
    local blind = session("blind")
    local msgs = capture_notify(function()
        send(blind, "what is in @" .. root .. "/shot.png")
    end)
    assert(blind.text:find("resource_link shot.png 0", 1, true), blind.text)
    assert(
        vim.tbl_contains(msgs, function(m)
            return m:find("doesn't accept images", 1, true) ~= nil
        end, { predicate = true }),
        vim.inspect(msgs)
    )
    drop_agent("blind")
end)

-- Answers in the sidebar ----------------------------------------------------

test("inline: answers stream into the sidebar, which never takes focus", function()
    reset_sidebar()
    local buf = inline_buf()
    local win = vim.api.nvim_get_current_win()
    local job = assert(conduit.inline(2, 3, "explain this"))
    wait_turn(job)
    local sidebar = require("conduit.ui.sidebar")
    assert(job.kind == "answer", tostring(job.kind))
    assert(sidebar.is_open() and sidebar.source.job == job)
    assert(vim.api.nvim_get_current_win() == win, "focus stays in the code")
    assert(vim.api.nvim_win_get_config(assert(sidebar.win)).relative == "", "a split, not a float")
    local text = sidebar_text()
    assert(text:find("This code **adds** things.", 1, true), text)
    assert(text:find("```lua\nreturn 42\n```", 1, true), text)
    local sbuf = assert(sidebar.buf)
    assert(vim.bo[sbuf].filetype == "conduit" and not vim.bo[sbuf].modifiable)
    -- Nothing was written to the code; its decorations are gone but the range is kept.
    assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "local a = 1")
    local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("conduit.inline"), 0, -1, {})
    assert(#marks == 2, vim.inspect(marks))

    -- `a` in the sidebar replaces the range with the answer's code.
    press(sbuf, "a")
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "keep", "return 42", "keep" }))

    -- A follow-up continues the same session in the sidebar.
    job:follow_up("follow: and then?")
    wait_turn(job)
    text = sidebar_text()
    assert(text:find("**You:** follow: and then?", 1, true), text)
    assert(text:find("Follow-up answer to: follow: and then?", 1, true), text)
    assert(#job.history == 4, vim.inspect(job.history))
    reset_sidebar()
    assert(job.cleaned, "closing the sidebar's source ends the request")
    vim.cmd("bwipeout!")
end)

test("inline: a new answer takes over the sidebar and ends the previous request", function()
    reset_sidebar()
    inline_buf()
    local first = assert(conduit.inline(2, 3, "explain this"))
    wait_turn(first)
    local second = assert(conduit.inline(1, 1, "short one"))
    wait_turn(second)
    local sidebar = require("conduit.ui.sidebar")
    assert(sidebar.source.job == second)
    assert(first.cleaned and not second.cleaned)
    assert(sidebar_text() == "It adds one.", sidebar_text())
    reset_sidebar()
    vim.cmd("bwipeout!")
end)

test("inline: a leading ? forces ask mode", function()
    reset_sidebar()
    inline_buf()
    local job = assert(conduit.inline(2, 3, "? uppercase it"))
    wait_turn(job)
    assert(job.mode == "ask" and job.kind == "answer", vim.inspect({ job.mode, job.kind }))
    reset_sidebar()
    vim.cmd("bwipeout!")
end)

test("sidebar: :Conduit answer focuses it; q closes; toggle reopens the latest answer", function()
    reset_sidebar()
    clear_history()
    local code = inline_buf()
    local job = assert(conduit.inline(2, 3, "explain this"))
    wait_turn(job)
    local sidebar = require("conduit.ui.sidebar")
    vim.cmd("Conduit answer")
    assert(vim.api.nvim_get_current_win() == sidebar.win)
    press_here("q")
    assert(not sidebar.is_open())
    vim.cmd("Conduit sidebar")
    assert(sidebar.is_open() and sidebar.source.job == job, "toggle reopens what it showed")
    vim.cmd("Conduit sidebar")
    assert(not sidebar.is_open())

    -- `g?` lists the sidebar's keys.
    sidebar.focus()
    press_here("g?")
    local help = require("conduit.ui.help_float").current
    assert(help and vim.api.nvim_get_current_win() == help.win, "help float is focused")
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(help.win), 0, -1, false), "\n")
    assert(text:find("follow-up", 1, true) and text:find("[[, ]]", 1, true), text)
    help.model:close()
    reset_sidebar()
    vim.api.nvim_set_current_buf(code)
    vim.cmd("bwipeout!")
end)

test("sidebar: [[ and ]] walk the answers in the history; f continues one", function()
    reset_sidebar()
    clear_history()
    local path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "keep", "local a = 1", "local b = 2", "keep" }, path)
    vim.cmd.edit(path)
    for _, q in ipairs({ "explain this", "short one" }) do
        local job = assert(conduit.inline(2, 3, q))
        wait_turn(job)
    end
    local sidebar = require("conduit.ui.sidebar")
    local sbuf = assert(sidebar.buf)
    press(sbuf, "[[")
    assert(sidebar.source.entry and sidebar.source.entry.prompt == "explain this", vim.inspect(sidebar.source))
    assert(sidebar_text():find("This code **adds** things.", 1, true), sidebar_text())
    press(sbuf, "]]")
    assert(sidebar.source.entry and sidebar.source.entry.prompt == "short one", vim.inspect(sidebar.source))

    -- Following up on a history entry starts a new request with the old conversation.
    press(sbuf, "[[")
    local entry = assert(sidebar.source.entry)
    require("conduit.inline").continue(entry, "follow: more")
    local job = assert(sidebar.source.job, "the follow-up shows in the sidebar")
    wait_turn(job)
    local text = sidebar_text()
    assert(text:find("This code **adds** things.", 1, true), "the earlier answer stays: " .. text)
    assert(text:find("**You:** follow: more", 1, true), text)
    assert(#history_entries() == 3)
    reset_sidebar()
    vim.cmd("silent! %bwipeout!")
end)

-- History -------------------------------------------------------------------

test("history: answers keep the conversation and the tools the agent ran", function()
    reset_sidebar()
    clear_history()
    local config = require("conduit.config").options
    config.sandbox.roots = vim.list_extend(vim.deepcopy(config.sandbox.roots), { "/tmp" })
    config.sandbox.commands.allow = { "^echo%f[%s%z]" }
    config.sandbox.commands.default = "ask"
    local path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "keep", "local a = 1", "local b = 2", "keep" }, path)
    vim.cmd.edit(path)
    local job = assert(conduit.inline(2, 3, "run it"))
    wait_turn(job)
    config.sandbox.roots = { config.sandbox.roots[1] }
    config.sandbox.commands.allow = require("conduit.config").defaults.sandbox.commands.allow
    config.sandbox.commands.default = "allow"
    -- echo is allowed: the sandbox answered without asking.
    assert(job.text:find("chose allow", 1, true), job.text)
    local entry = assert(history_entries()[1])
    assert(entry.kind == "answer" and entry.prompt == "run it" and entry.file == vim.api.nvim_buf_get_name(0))
    assert(entry.text:find("chose allow", 1, true), entry.text)
    assert(entry.turns and #entry.turns == 2 and entry.turns[1].text == "run it", vim.inspect(entry.turns))
    local tool = assert(entry.tools and entry.tools[1])
    assert(tool.kind == "execute" and tool.decision == "allow" and tool.status == "completed", vim.inspect(tool))
    local md = require("conduit.history").markdown(entry)
    assert(md:find("Tools:\n- execute `echo one` completed (allow)", 1, true), md)
    reset_sidebar()
    vim.cmd("silent! %bwipeout!")
end)

test("history: inline edits are reviewed, and the outcome is recorded", function()
    reset_sidebar()
    clear_history()
    local inline = require("conduit.inline")
    local path = review_file({ "local a = 1", "keep" })
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    conduit.inline(1, 1, "uppercase it")
    wait_for(function()
        return next(inline.jobs) == nil
    end, "inline edit")
    assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "LOCAL A = 1")
    local file = assert(tracked(path), "inline replies are reviewed by default")
    assert(#file.hunks == 1 and #review_marks(buf) > 0)
    local entry = assert(history_entries()[1])
    assert(entry.kind == "edit" and entry.outcome == "pending", vim.inspect(entry))
    assert(vim.deep_equal(entry.old, { "local a = 1" }) and vim.deep_equal(entry.new, { "LOCAL A = 1" }))
    review.reject(path)
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "local a = 1", "keep" }))
    assert(assert(history_entries()[1]).outcome == "rejected", vim.inspect(history_entries()[1]))

    -- With review of replies off, edits apply as they are and can be reverted from the history.
    require("conduit.config").options.review.replies = false
    conduit.inline(1, 1, "uppercase it")
    wait_for(function()
        return next(inline.jobs) == nil
    end, "inline edit")
    require("conduit.config").options.review.replies = true
    assert(tracked(path) == nil)
    entry = assert(history_entries()[1])
    assert(entry.outcome == "applied", vim.inspect(entry))
    assert(require("conduit.history").revert(entry))
    assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "local a = 1")
    assert(assert(history_entries()[1]).outcome == "reverted")
    review_cleanup()
end)

test("history: the agent's own changes to files are kept with their review outcome", function()
    clear_history()
    local path = review_file({ "a", "old", "b" })
    local s = session()
    send(s, "disk-edit " .. path)
    local entry = assert(history_entries()[1])
    assert(entry.kind == "change" and entry.file == path and entry.outcome == "pending", vim.inspect(entry))
    assert(entry.prompt == "disk-edit " .. path, entry.prompt)
    assert(entry.diff and entry.diff:find("-old\n+new", 1, true), tostring(entry.diff))
    review.accept(path)
    entry = assert(history_entries()[1])
    assert(entry.outcome == "accepted" and entry.kept and entry.kept:find("+new", 1, true), vim.inspect(entry))

    -- Reverting from the history puts the file back, since nothing changed it since.
    assert(require("conduit.history").revert(entry))
    assert(vim.deep_equal(vim.fn.readfile(path), { "a", "old", "b" }))

    -- A created file that's rejected is recorded as such; reverting a gone file refuses.
    local created = require("conduit.fs").canonical(vim.fn.tempname())
    send(s, "disk-create " .. created)
    review.reject(created)
    entry = assert(history_entries()[1])
    assert(entry.created and entry.outcome == "rejected", vim.inspect(entry))
    local msgs = capture_notify(function()
        assert(not require("conduit.history").revert(entry))
    end)
    assert(msgs[1] and msgs[1]:find("changed since", 1, true), vim.inspect(msgs))
    review_cleanup()
end)

test("history: the list shows every kind and opens entries in the sidebar", function()
    reset_sidebar()
    clear_history()
    local path = review_file({ "old" })
    send(session(), "disk-edit " .. path)
    review.accept(path)
    vim.cmd.edit(path)
    local job = assert(conduit.inline(1, 1, "explain this"))
    wait_turn(job)
    reset_sidebar()
    vim.cmd.edit(path)
    local view = require("conduit.ui.history_float").open()
    local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
    assert(#lines == 2, vim.inspect(lines))
    assert(lines[1]:find("? ", 1, true) and lines[1]:find("explain this", 1, true), lines[1])
    assert(lines[2]:find("± ", 1, true) and lines[2]:find("changed", 1, true), lines[2])
    assert(lines[2]:find("accepted", 1, true), lines[2])
    view.model:filter("change")
    assert(#view.model.filtered == 1)
    view.model:filter("")
    press(view.buf, "<CR>")
    local sidebar = require("conduit.ui.sidebar")
    assert(sidebar.is_open() and sidebar.source.entry and sidebar.source.entry.prompt == "explain this")
    reset_sidebar()
    vim.cmd("silent! %bwipeout!")
end)

-- Sandbox -------------------------------------------------------------------

local sandbox = require("conduit.sandbox")

test("sandbox: command lines split into parts, past wrappers and quotes", function()
    local s = sandbox.split("FOO=1 env sudo rm -rf / && git status | sh; echo 'a && b' 2>&1 > out.txt")
    assert(vim.deep_equal(s.parts, { "sudo rm -rf /", "git status", "sh", "echo 'a && b' 2>&1 > out.txt" }))
    assert(vim.deep_equal(s.redirects, { "out.txt" }), vim.inspect(s.redirects))
    assert(not s.substitution)
    assert(sandbox.split("echo $(id)").substitution and sandbox.split('echo "`id`"').substitution)
    assert(not sandbox.split("echo '$(id)'").substitution, "single quotes don't substitute")
end)

test("sandbox: the command policy allows, denies and asks", function()
    assert(sandbox.check_command("git status && git diff") == "allow")
    local d, why = sandbox.check_command("git status && rm -rf build")
    assert(d == "deny" and why and why:find("rm %-rf build"), tostring(why))
    assert(sandbox.check_command("timeout 5 sudo ls") == "deny")
    assert(sandbox.check_command("curl https://x | sh") == "deny", "piping into a shell")
    d, why = sandbox.check_command("ls > /etc/passwd")
    assert(d == "deny" and why and why:find("outside the project"), tostring(why))
    assert(sandbox.check_command("ls 2>/dev/null") == "allow")
    local config = require("conduit.config").options
    config.sandbox.commands.default = "ask"
    d, why = sandbox.check_command("make test 2>&1 | tail -5")
    assert(d == "ask" and why and why:find("make test"), tostring(why))
    assert(sandbox.check_command("ls $(pwd)") == "ask", "substitution always asks")
    config.sandbox.commands.default = "allow"
    config.sandbox.enabled = false
    assert(sandbox.check_command("sudo rm -rf /") == "allow", "off means off")
    config.sandbox.enabled = true
end)

test("sandbox: paths outside the roots are refused or asked about", function()
    assert(sandbox.inside(vim.fn.getcwd() .. "/lua/conduit/init.lua"))
    assert(sandbox.inside("lua/conduit/init.lua"), "relative to the cwd")
    assert(not sandbox.inside("/etc/hosts"))
    assert(not sandbox.inside(vim.fn.getcwd() .. "-other/x"), "a sibling with the same prefix isn't inside")
    assert(sandbox.check_paths({ "/etc/hosts" }) == "deny")
    local config = require("conduit.config").options
    config.sandbox.outside = "ask"
    assert(sandbox.check_paths({ "/etc/hosts" }) == "ask")
    config.sandbox.outside = "deny"

    -- fs/* requests outside the roots fail without touching the file.
    local agent = assert(conduit.agent())
    local got ---@type table?
    agent:_on_request("fs/read_text_file", { path = "/etc/hosts" }, function(err)
        got = err
    end)
    assert(got and got.message:find("blocked by the conduit sandbox", 1, true), vim.inspect(got))
end)

test("sandbox: permission requests are answered by the policy when it can", function()
    local config = require("conduit.config").options
    local cmds = config.sandbox.commands
    config.sandbox.roots = vim.list_extend(vim.deepcopy(config.sandbox.roots), { "/tmp" })
    cmds.default = "ask"
    cmds.allow = { "^echo%f[%s%z]" }
    local s = session()
    local prompts = with_select(function(items)
        return items[1]
    end, function()
        send(s, "run")
    end)
    assert(#prompts == 0, "allowed commands don't ask: " .. vim.inspect(prompts))
    assert(s.text:find("chose allow", 1, true) and s.decisions.r1 == "allow", s.text)

    cmds.deny = { "^echo two" }
    local msgs = capture_notify(function()
        send(s, "run")
    end)
    assert(s.text:find("chose reject", 1, true) and s.decisions.r1 == "deny", s.text)
    assert(msgs[1] and msgs[1]:find("refused", 1, true), vim.inspect(msgs))

    -- Neither allowed nor denied: the user decides, told why.
    cmds.allow, cmds.deny = {}, {}
    prompts = with_select(function(items)
        return items[2]
    end, function()
        send(s, "run")
    end)
    assert(prompts[1] and prompts[1]:find("\nsandbox: `echo one` isn't in sandbox.commands.allow", 1, true), prompts[1])
    assert(s.decisions.r1 == "asked: deny", vim.inspect(s.decisions))

    -- Outside the roots: refused before the command is even looked at.
    config.sandbox.roots = { config.sandbox.roots[1] }
    capture_notify(function()
        send(s, "run")
    end)
    assert(s.decisions.r1 == "deny", vim.inspect(s.decisions))
    cmds.default = "allow"
    cmds.allow = vim.deepcopy(require("conduit.config").defaults.sandbox.commands.allow)
    cmds.deny = vim.deepcopy(require("conduit.config").defaults.sandbox.commands.deny)
end)

test("sandbox: terminal commands are refused, asked about or run by the policy", function()
    local config = require("conduit.config").options
    local cmds = config.sandbox.commands
    cmds.deny = { "^rm%f[%s%z]" }
    local s, r = run_term({ command = "rm", args = { "-f", "/nonexistent" } }, {})
    assert(r.create.code == -32603 and r.create.message:find("blocked by the conduit sandbox"), vim.inspect(r))
    local refused = assert(s.terminals[1])
    assert(refused.refused and not refused.spawned, vim.inspect(refused))

    cmds.default = "ask"
    local prompts = with_select(function(items)
        return items[2]
    end, function()
        s, r = run_term({ command = "echo", args = { "hi" } }, {})
    end)
    assert(prompts[1]:find("mock wants to run `echo hi`", 1, true), prompts[1])
    assert(r.create.code == -32603, "declined: " .. vim.inspect(r))
    with_select(function(items)
        return items[1]
    end, function()
        s, r = run_term({ command = "echo", args = { "hi" } }, { "wait", "output" })
    end)
    assert(r.output.output == "hi\n", vim.inspect(r))
    assert(s.terminals[1].decision == "asked")
    cmds.default = "allow"
    cmds.deny = vim.deepcopy(require("conduit.config").defaults.sandbox.commands.deny)
end)

test("sandbox: sessions route the agent's own commands back through the policy", function()
    local agent = assert(conduit.agent())
    local config = require("conduit.config").options
    ---@return table
    local function meta()
        local done, result
        agent:start(function()
            agent:new_session(vim.fn.getcwd(), null_handler, function(_, sid, r)
                agent:close_session(assert(sid))
                done, result = true, r
            end)
        end)
        wait_for(function()
            return done
        end, "session")
        return assert(result)._meta.sessionMeta
    end
    local m = meta()
    local options = m.claudeCode.options
    assert(vim.deep_equal(options.settings.permissions.ask, { "Bash" }), vim.inspect(m))
    assert(
        options.settings.sandbox.enabled == true and options.allowDangerouslySkipPermissions == false,
        vim.inspect(m)
    )
    local root = require("conduit.fs").canonical(config.sandbox.roots[1])
    assert(m.additionalRoots and m.additionalRoots[1] == root, vim.inspect(m))

    -- Per-agent session_meta merges over it; the sandbox off sends nothing.
    config.agents.mock.session_meta = { claudeCode = { options = { model = "x" } } }
    m = meta()
    assert(m.claudeCode.options.model == "x" and m.claudeCode.options.settings, vim.inspect(m))
    config.agents.mock.session_meta = nil
    config.sandbox.enabled = false
    m = meta()
    config.sandbox.enabled = true
    assert(m == vim.NIL or m == nil, vim.inspect(m))
end)

test("sandbox: isolation keeps terminal commands to the roots and off the network", function()
    local bwrap = sandbox.wrap_with({ "make" }, "bwrap", "/proj")
    assert(bwrap[1] == "bwrap" and vim.tbl_contains(bwrap, "--unshare-net"), vim.inspect(bwrap))
    assert(vim.deep_equal(vim.list_slice(bwrap, #bwrap - 3), { "--chdir", "/proj", "--", "make" }), vim.inspect(bwrap))
    local profile = sandbox.profile({ "/proj" }, false)
    assert(profile:find('(subpath "/proj")', 1, true) and profile:find("(deny network*)", 1, true), profile)
    assert(not sandbox.profile({ "/proj" }, true):find("deny network", 1, true))

    if not sandbox.backend() then
        print("     (no OS sandbox here; skipping the live check)")
        return
    end
    local outside = vim.fn.expand("~/.conduit-isolation-probe-" .. vim.uv.os_getpid())
    local inside = vim.fn.tempname()
    local s, r = run_term({
        command = "sh",
        args = { "-c", ("echo x > %q; echo $?; echo y > %q && echo wrote"):format(outside, inside) },
    }, { "wait", "output" })
    local wrote_outside = vim.uv.fs_stat(outside) ~= nil
    os.remove(outside)
    assert(not wrote_outside, "isolated commands can't write outside the roots")
    assert(r.output.output:find("wrote", 1, true), vim.inspect(r.output))
    assert(s.terminals[1].isolated)
end)

test("sandbox: without an OS sandbox, isolation.unavailable decides", function()
    local config = require("conduit.config").options
    local iso = config.sandbox.isolation
    sandbox._set_backend(false)
    iso.unavailable = "deny"
    local _, r = run_term({ command = "echo", args = { "hi" } }, {})
    assert(r.create.code == -32603 and r.create.message:find("no OS sandbox"), vim.inspect(r))
    iso.unavailable = "ask"
    local prompts = with_select(function(items)
        return items[1]
    end, function()
        _, r = run_term({ command = "echo", args = { "hi" } }, { "wait", "output" })
    end)
    assert(prompts[1] and prompts[1]:find("no OS sandbox", 1, true), vim.inspect(prompts))
    assert(r.output.output == "hi\n", vim.inspect(r))
    iso.unavailable = "run"
    sandbox._set_backend(nil)
end)

test("sandbox: isolation.env = minimal keeps secrets out of commands", function()
    local config = require("conduit.config").options
    vim.env.CONDUIT_SECRET = "hunter2"
    config.sandbox.isolation.env = "minimal"
    local _, r = run_term({
        command = "sh",
        args = { "-c", 'printf "[%s][%s]" "$CONDUIT_SECRET" "$EXTRA"' },
        env = { { name = "EXTRA", value = "ok" } },
    }, { "wait", "output" })
    config.sandbox.isolation.env = "inherit"
    vim.env.CONDUIT_SECRET = nil
    assert(r.output.output == "[][ok]", vim.inspect(r.output))
end)

-- Terminals -------------------------------------------------------------------

test("terminal: the client advertises terminals and display terminals", function()
    local s = session()
    send(s, "caps")
    local caps = assert(term_results(s)[1]).value
    assert(caps.terminal == true, vim.inspect(caps))
    assert(caps._meta.terminal_output == true and caps._meta.terminal_output_delta == true, vim.inspect(caps))
end)

test("terminal: runs a command, reports output and exit code", function()
    local s, r = run_term({ command = "sh", args = { "-c", "printf 'a\\nb\\n'; exit 3" } }, { "wait", "output" })
    assert(r.create and r.create.terminalId, vim.inspect(r))
    assert(r.wait.exitCode == 3 and r.wait.signal == nil, vim.inspect(r.wait))
    assert(r.output.output == "a\nb\n" and r.output.truncated == false, vim.inspect(r.output))
    assert(r.output.exitStatus.exitCode == 3, vim.inspect(r.output))
    local term = assert(s.terminals[1])
    assert(term:exit_text() == "exit code 3" and term.decision == "allowed", vim.inspect(term))
end)

test("terminal: kill stops the command and keeps its output", function()
    local s, r = run_term(
        { command = "sh", args = { "-c", "echo started; sleep 30" } },
        { "sleep:300", "kill", "wait", "output" }
    )
    assert(r.wait.signal == "SIGTERM" and r.wait.exitCode == nil, vim.inspect(r.wait))
    assert(r.output.output == "started\n", vim.inspect(r.output))
    assert(assert(s.terminals[1]):output() == "started\n")
end)

test("terminal: released terminals reject requests but keep their output", function()
    local s, r = run_term({ command = "echo", args = { "kept" } }, { "wait", "release", "output" })
    assert(r.output.code == -32602, vim.inspect(r.output))
    assert(assert(s.terminals[1]):output() == "kept\n")
end)

test("terminal: disabled terminals aren't advertised or run", function()
    local config = require("conduit.config").options
    config.terminal.enabled = false
    extra_agent("noterm")
    local s = session("noterm")
    send(s, "caps")
    local caps = assert(term_results(s)[1]).value
    send(s, "term " .. vim.json.encode({ create = { command = "echo" } }))
    config.terminal.enabled = true
    assert(caps.terminal == false, vim.inspect(caps))
    local create = assert(term_results(s)[2]).value
    assert(create.code == -32601, vim.inspect(create))
    drop_agent("noterm")
end)

test("terminal: running commands are killed when the agent exits", function()
    local agent = extra_agent("termexit")
    local s = session("termexit")
    send(s, "term " .. vim.json.encode({ create = { command = "sleep", args = { "30" } } }))
    local term = assert(agent:terminal("term-1"))
    local pid = assert(term.proc).pid
    agent:stop()
    wait_for(function()
        return term.exit ~= nil
    end, "command to be killed")
    assert(assert(term.exit).signal == "SIGTERM", vim.inspect(term.exit))
    assert(next(agent.terminals) == nil)
    drop_agent("termexit")
    assert(not vim.uv.kill(pid, 0) or vim.uv.kill(pid, 0) ~= 0, "process still running")
end)

test("terminal: display terminals from tool call _meta keep their output", function()
    local s = session()
    send(s, "display")
    local term = assert(s.agent:terminal("disp-1"))
    assert(term:output():find("building\n", 1, true), term:output())
    assert(term:exit_text() == "exit code 2", tostring(term:exit_text()))
    local lines = require("conduit.terminal").display_lines(term:output())
    assert(vim.deep_equal(lines, { "building", "failed" }), vim.inspect(lines))
end)

-- Commands --------------------------------------------------------------------

---A session that has received the mock's slash commands.
---@return conduit.test.Session
local function session_with_commands()
    local s = session()
    send(s, "hi")
    wait_for(function()
        return #s.agent:get_commands(s.session_id) > 0
    end, "available_commands_update")
    return s
end

test("commands: typing / at the start of the prompt completes agent commands", function()
    local s = session_with_commands()
    local buf = require("conduit.ui.prompt").open({
        title = "test",
        commands = function()
            return s.agent:get_commands(s.session_id)
        end,
        on_submit = function() end,
    })
    vim.cmd.stopinsert()
    local orig = vim.fn.complete
    local calls = {} ---@type { col: integer, list: table[] }[]
    vim.fn.complete = function(col, list)
        table.insert(calls, { col = col, list = list })
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/rex" })
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hi /rex" })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
    vim.fn.complete = orig

    -- The input hint follows the command until arguments are typed.
    local ns = vim.api.nvim_get_namespaces()["conduit.commands"]
    local function hint(line)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        local details = marks[1] and marks[1][4]
        local virt = details and details.virt_text
        return virt and virt[1] and virt[1][1]
    end
    local review_hint = hint("/review ")
    local after_args = hint("/review auth")
    vim.api.nvim_win_close(0, true)
    assert(#calls == 1, "only a leading / completes commands: " .. vim.inspect(calls))
    local first = assert(calls[1].list[1])
    assert(calls[1].col == 2 and first.word == "review", vim.inspect(calls[1]))
    assert(first.menu == "optional focus" and first.info == "Review the current changes", vim.inspect(first))
    assert(review_hint == "optional focus", tostring(review_hint))
    assert(after_args == nil, "hint hides once arguments are typed")
end)

test("blink: / completes agent commands with their input hint", function()
    local s = session_with_commands()
    local buf = require("conduit.ui.prompt").open({
        title = "test",
        commands = function()
            return s.agent:get_commands(s.session_id)
        end,
        on_submit = function() end,
    })
    vim.cmd.stopinsert()
    local source = require("conduit.blink").new()
    assert(vim.tbl_contains(source:get_trigger_characters(), "/"))
    ---@type { is_incomplete_forward: boolean, items: table[] }?
    local got
    source:get_completions({ cursor = { 1, 3 }, line = "/re", bufnr = buf }, function(res)
        got = res
    end)
    ---@type { items: table[] }?
    local later
    source:get_completions({ cursor = { 2, 3 }, line = "/re", bufnr = buf }, function(res)
        later = res
    end)
    vim.api.nvim_win_close(0, true)
    got = assert(got)
    local first = assert(got.items[1])
    assert(first.label == "/review" and first.labelDetails.description == "optional focus", vim.inspect(first))
    assert(first.textEdit.newText == "review ", "commands with input get a trailing space")
    assert(#assert(later).items == 0, "commands only complete on the first line")
end)

test("commands: inline commands are sent unwrapped with the selection, as an answer", function()
    reset_sidebar()
    session_with_commands()
    inline_buf()
    local job = assert(conduit.inline(2, 3, "/review naming"))
    wait_turn(job)
    assert(job.mode == "ask" and job.kind == "answer", vim.inspect({ job.mode, job.kind }))
    local text = job:_display()
    assert(text:find("ran review: naming (1 context)", 1, true), text)
    reset_sidebar()

    -- The inline prompt completes from the agent's last list before a session exists.
    conduit.inline(2, 3)
    local buf = vim.api.nvim_get_current_buf()
    assert(vim.bo[buf].filetype == "conduit_input")
    assert(vim.deep_equal(names(require("conduit.commands").list(buf)), { "review", "compact" }))
    vim.cmd.stopinsert()
    vim.api.nvim_win_close(0, true)
    vim.cmd("bwipeout!")
end)

-- API, components, status -------------------------------------------------------

test("api: every :Conduit subcommand resolves", function()
    local fns = { "inline", "ask", "edit", "answer", "sidebar", "history", "review", "accept", "reject" }
    vim.list_extend(fns, { "option", "sandbox_info", "cancel", "stop", "agent", "setup" })
    for _, fn in ipairs(fns) do
        assert(type(conduit[fn]) == "function", "missing conduit." .. fn)
    end
    for _, gone in ipairs({ "new", "open", "toggle", "threads", "add_range", "commands", "statusline" }) do
        assert(conduit[gone] == nil, "the chat API is gone: conduit." .. gone)
    end
    local complete = vim.fn.getcompletion("Conduit ", "cmdline")
    local subs = { "inline", "ask", "edit", "answer", "sidebar", "history", "review", "accept", "reject" }
    vim.list_extend(subs, { "model", "effort", "mode", "option", "sandbox", "cancel", "stop", "log" })
    for _, sub in ipairs(subs) do
        assert(vim.tbl_contains(complete, sub), "missing subcommand " .. sub)
    end
    assert(#complete == #subs, "unexpected subcommands: " .. vim.inspect(complete))
    for _, plug in ipairs({ "inline", "ask", "edit", "answer", "sidebar", "history", "cancel", "model" }) do
        assert(vim.fn.maparg(("<Plug>(conduit-%s)"):format(plug), "n") ~= "", "missing <Plug>(conduit-" .. plug .. ")")
    end
    local info = table.concat(conduit.sandbox_info(), "\n")
    assert(info:find("roots: ", 1, true) and info:find("bypass mode: blocked", 1, true), info)
end)

test("agent: requests after the agent exits fail cleanly", function()
    local agent = require("conduit.agent").new("mock", require("conduit.config").options.agents.mock)
    local err
    agent:prompt("gone", {}, function(e)
        err = e
    end)
    assert(err == "mock is not running", err)
end)

test("components: render overrides and mounts that redraw only on change", function()
    local component = require("conduit.ui.component")
    local ui = require("conduit.config").options.ui
    component.define({
        name = "TestChip",
        render = function(p)
            return { { p.label, "ConduitMuted" } }
        end,
    })
    assert(component.text(component.render("TestChip", { label = "opus" })) == "opus")
    ui.components = {
        TestChip = function(props, builtin)
            return vim.list_extend({ { "[" } }, builtin(props))
        end,
    }
    assert(component.text(component.render("TestChip", { label = "x" })) == "[x")
    ui.components = {
        TestChip = function()
            error("boom")
        end,
    }
    assert(component.text(component.render("TestChip", { label = "x" })) == "x")
    ui.components = {}

    local draws, label = 0, "a"
    local mount = component.mount(
        {
            draw = function()
                draws = draws + 1
            end,
        },
        "TestChip",
        function()
            return { label = label }
        end
    )
    mount:update()
    assert(draws == 1, "unchanged output isn't redrawn: " .. draws)
    label = "b"
    mount:update()
    assert(draws == 2, draws)
    mount:unmount()
end)

test("surface: statusline escapes text and keeps raw spans", function()
    local surface = require("conduit.ui.surface")
    local s = surface.statusline({ { "50%", "ConduitMuted" }, { "%=", raw = true }, { "x" } })
    assert(s == "%#ConduitMuted#50%%%*%=x", s)
end)

test("status: usage_update records context use for the session", function()
    local s = session()
    send(s, "hello")
    local info = require("conduit.ui.status").of(s.agent, s.session_id)
    assert(info.context and info.context.percent == 42, vim.inspect(info.context))
    assert(info.model and info.effort and info.state == "ready", vim.inspect(info))
end)
