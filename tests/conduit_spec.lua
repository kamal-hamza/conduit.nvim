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

---A window's winbar without highlight groups.
---@param win integer
---@return string
local function winbar_text(win)
    return (vim.wo[win].winbar:gsub("%%#[%w_]+#", ""):gsub("%%%*", ""))
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
    local shown ---@type string?
    local chat = assert(conduit.new())
    vim.ui.select = function(items, opts, cb)
        prompt, shown = opts.prompt, transcript(chat)
        cb(items[1])
    end

    send(chat, "edit " .. path)
    vim.ui.select = orig_select

    -- Kind and location come from the earlier tool call: the request only adds the diff.
    local rel = vim.fn.fnamemodify(path, ":~:.")
    assert(prompt == ("mock wants to Edit %s\nkind: edit\n  %s:1"):format(path, rel), tostring(prompt))
    -- The diff sent with the permission request is drawn before asking.
    assert(shown and shown:find("○ Edit " .. path, 1, true), shown)
    assert(shown:find("(+2 −2)\n```diff\n@@ -1,2 +1,2 @@\n-hello\n-world\n+HELLO\n+WORLD\n```", 1, true), shown)
    local text = transcript(chat)
    -- The status-only update that completes the call keeps its diff.
    assert(
        text:find("✓ Edit " .. path .. "\n`" .. vim.fn.fnamemodify(path, ":~") .. "` (+2 −2)\n```diff", 1, true),
        text
    )
    assert(text:find("- [x] Read file", 1, true), text)
    assert(not text:find("[~]", 1, true), "plan should be replaced in place:\n" .. text)
    assert(text:find("first line was: hello", 1, true), text)
    assert(vim.deep_equal(vim.fn.readfile(path), { "HELLO", "WORLD" }))
end)

---Headings of a markdown text, as parsed by treesitter (so not ones inside code blocks).
---@param text string
---@return string[]
local function headings(text)
    local parser = vim.treesitter.get_string_parser(text, "markdown")
    local root = assert(parser:parse())[1]:root()
    local query = vim.treesitter.query.parse("markdown", "(atx_heading) @h")
    local out = {}
    for _, node in query:iter_captures(root, text) do
        table.insert(out, (vim.treesitter.get_node_text(node, text):gsub("\n$", "")))
    end
    return out
end

---0-based row of the first transcript line starting with `prefix`.
local function row_of(chat, prefix)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(chat.transcript, 0, -1, false)) do
        if vim.startswith(line, prefix) then
            return i - 1
        end
    end
    error("no line starting with " .. prefix)
end

test("chat: tool calls show diffs, output and locations, and expand in place", function()
    local chat = assert(conduit.new())
    send(chat, "run tools")
    local text = transcript(chat)

    -- Output: the agent's own fence is replaced by one longer than anything inside,
    -- and the preview is cut at `output_lines`.
    assert(
        text:find("✓ Run make\n`````console\nout 1\n````md\n```\nout 4\n", 1, true)
            and text:find("out 8\n`````\n… 12 more lines (`<CR>` to expand)\n", 1, true),
        text
    )
    assert(not text:find("out 9", 1, true), text)
    -- Read output stays hidden; its location is listed relative to the cwd.
    assert(text:find("✓ Read notes.md\n→ `notes.md:3`\n… 2 lines of output (`<CR>` to show)\n", 1, true), text)
    assert(not text:find("secret body", 1, true), text)
    -- New files and long diffs.
    assert(text:find("`new.lua` (new file, +1)\n```diff\n@@ -0,0 +1 @@\n+print(1)\n```", 1, true), text)
    assert(text:find("`big.txt` (+30 −30)\n```diff\n", 1, true), text)
    assert(text:find("… 41 more diff lines (`<CR>` to expand)", 1, true), text)
    -- Every fence is closed: the reply after the tools is still a heading.
    local hs = headings(text)
    assert(hs[#hs] == "## mock" and text:find("## mock\n\ntools done$"), vim.inspect(hs))

    -- <CR> on any line of a block expands it, and again collapses it.
    chat:open()
    local twin = assert(chat:wins())
    vim.api.nvim_set_current_win(twin)
    vim.api.nvim_win_set_cursor(twin, { row_of(chat, "→ `notes.md:3`") + 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "mx", false)
    text = transcript(chat)
    assert(text:find("→ `notes.md:3`\n```\nsecret body\nline two\n```\n", 1, true), text)
    assert(chat:toggle_tool(row_of(chat, "✓ Run make")))
    assert(transcript(chat):find("out 20\n`````\n\n✓ Read notes.md", 1, true), transcript(chat))
    assert(chat:toggle_tool(row_of(chat, "✓ Read notes.md")))
    assert(chat:toggle_tool(row_of(chat, "✓ Run make")))
    assert(chat:toggle_tool(row_of(chat, "`big.txt`") + 3))
    text = transcript(chat)
    assert(not text:find("secret body", 1, true) and not text:find("out 9", 1, true), text)
    assert(text:find("+b 30\n```\n\n## mock", 1, true), text)
    assert(not chat:toggle_tool(row_of(chat, "tools done")), "not a tool call")

    -- A copy (as in a fork) keeps the blocks expandable.
    local copy = assert(conduit.new())
    copy:copy_transcript(chat)
    assert(copy:toggle_tool(row_of(copy, "✓ Read notes.md")))
    assert(transcript(copy):find("secret body", 1, true) and not transcript(chat):find("secret body", 1, true))
end)

test("chat: gd shows a tool call's diff side by side, gf opens its file", function()
    local chat = assert(conduit.new())
    send(chat, "run tools")
    chat:open()
    local twin = assert(chat:wins())
    vim.api.nvim_set_current_win(twin)
    local tabs = #vim.api.nvim_list_tabpages()
    vim.api.nvim_win_set_cursor(twin, { row_of(chat, "`big.txt`") + 1, 0 })
    vim.api.nvim_feedkeys("gd", "mx", false)
    local wins = vim.api.nvim_tabpage_list_wins(0)
    assert(#vim.api.nvim_list_tabpages() == tabs + 1 and #wins == 2, "diff tab")
    local old = vim.api.nvim_win_get_buf(wins[1])
    local new = vim.api.nvim_win_get_buf(wins[2])
    assert(vim.wo[wins[1]].diff and vim.wo[wins[2]].diff)
    assert(vim.api.nvim_buf_get_lines(old, 0, 1, false)[1] == "a 1")
    assert(vim.api.nvim_buf_get_lines(new, 29, 30, false)[1] == "b 30")
    assert(vim.wo[wins[2]].winbar == "after: big.txt", vim.wo[wins[2]].winbar)
    vim.api.nvim_feedkeys("q", "mx", false)
    assert(#vim.api.nvim_list_tabpages() == tabs and not vim.api.nvim_buf_is_valid(old))

    vim.api.nvim_set_current_win(twin)
    vim.api.nvim_win_set_cursor(twin, { row_of(chat, "✓ Read notes.md") + 1, 0 })
    vim.api.nvim_feedkeys("gf", "mx", false)
    local win = vim.api.nvim_get_current_win()
    assert(win ~= twin and vim.api.nvim_buf_get_name(0) == vim.fn.getcwd() .. "/notes.md", vim.api.nvim_buf_get_name(0))
    vim.cmd("bwipeout!")
end)

test("permission: prompts show the kind, the full command and paths", function()
    local orig_select = vim.ui.select
    local prompts = {} ---@type string[]
    vim.ui.select = function(items, opts, cb)
        table.insert(prompts, opts.prompt)
        cb(items[2])
    end
    local chat = assert(conduit.new())
    send(chat, "run")
    send(chat, "run-argv")
    vim.ui.select = orig_select

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
    assert(transcript(chat):find("chose reject", 1, true), transcript(chat))
end)

test("permission: describe handles each rawInput shape and fallbacks", function()
    local describe = require("conduit.ui.permission").describe
    local info = describe({ kind = "execute", rawInput = { command = { "git", "status", "--short" } } })
    assert(info.title == "run a command", info.title)
    assert(vim.deep_equal(info.command, { "git status --short" }), vim.inspect(info.command))
    assert(vim.deep_equal(describe({ rawInput = { command = { "zsh", "-c", "a\nb\n" } } }).command, { "a", "b" }))

    info = describe({ title = "  Read\nmore", kind = "read", rawInput = { file_path = "/x" } })
    assert(info.title == "Read" and info.command == nil, vim.inspect(info))
    info = describe({ rawInput = vim.NIL, title = vim.NIL })
    assert(info.title == "run a tool" and info.kind == nil and #info.paths == 0, vim.inspect(info))

    local cwd_file = vim.fn.getcwd() .. "/lua/conduit/init.lua"
    info = describe({
        locations = { { path = cwd_file, line = 3 }, { path = cwd_file, line = 3 }, { path = "/abs/x" } },
        content = { { type = "diff", path = "/ignored" } },
    })
    assert(vim.deep_equal(info.paths, { "lua/conduit/init.lua:3", "/abs/x" }), vim.inspect(info.paths))
    info = describe({ kind = "edit", content = { { type = "content" }, { type = "diff", path = "/d.lua" } } })
    assert(info.title == "edit a file" and vim.deep_equal(info.paths, { "/d.lua" }), vim.inspect(info))
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
    -- With the thread bar on, state and options sit in the prompt's winbar.
    local _, iwin = chat:wins()
    local winbar = winbar_text(assert(iwin))
    assert(winbar:find("mock · ready · SMART · LOW", 1, true), winbar)
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
    local link = assert(links[2])
    assert(link.type == "resource_link" and link.name == "a.lua")
    assert(link.uri == vim.uri_from_fname(root .. "/a.lua"))
end)

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
    local orig, msgs = vim.notify, {}
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

test("mentions: images become image blocks when the agent accepts them", function()
    local root = image_fixture()
    local mentions = require("conduit.mentions")
    local blocks
    local msgs = capture_notify(function()
        -- No embeddedContext: images don't depend on it.
        blocks = mentions.blocks("look @shot.png and @photo.jpg", prompt_caps({ image = true }), { root = root })
    end)
    assert(#msgs == 0, vim.inspect(msgs))
    assert(#blocks == 3, vim.inspect(blocks))
    local png = assert(blocks[2])
    assert(png.type == "image" and png.mimeType == "image/png", vim.inspect(png))
    assert(vim.base64.decode(png.data) == PNG)
    assert(png.uri == vim.uri_from_fname(root .. "/shot.png"))
    assert(blocks[3].type == "image" and blocks[3].mimeType == "image/jpeg", vim.inspect(blocks[3]))
end)

test("mentions: images are links with a warning when not accepted or too large", function()
    local root = image_fixture()
    local mentions = require("conduit.mentions")
    local blocks
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
    assert(blocks[2].type == "resource_link", vim.inspect(blocks[2]))
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

test("mentions: typing @ opens completion in the input", function()
    local chat = assert(conduit.new())
    vim.api.nvim_set_current_win(assert(select(2, chat:wins())))
    local items ---@type { col: integer, list: table[] }?
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

test("inline: permission prompts include what the agent wants to run", function()
    inline_buf()
    local orig_select = vim.ui.select
    local prompt
    vim.ui.select = function(items, opts, cb)
        prompt = opts.prompt
        cb(items[1])
    end
    local job = assert(conduit.inline(2, 3, "run it"))
    wait_turn(job)
    vim.ui.select = orig_select
    assert(prompt, "no permission prompt")
    assert(prompt:find("^mock wants to echo one\nkind: execute\n"), prompt)
    assert(prompt:find("$ echo one\n  echo two\n  echo three", 1, true), prompt)
    assert(job.tools.r1 and job.tools.r1.status == "completed", vim.inspect(job.tools))
    job:close()
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
    table.insert(fns, "commands")
    vim.list_extend(fns, { "threads", "continue_thread", "thread_next", "thread_prev", "thread_close" })
    vim.list_extend(fns, { "thread_delete", "thread_fork", "thread_rename", "thread_alternate", "thread_goto" })
    vim.list_extend(fns, { "thread_search", "resume", "status" })
    for _, fn in ipairs(fns) do
        assert(type(conduit[fn]) == "function", "missing conduit." .. fn)
    end
    local complete = vim.fn.getcompletion("Conduit ", "cmdline")
    local subs =
        { "inline", "ask", "edit", "stop", "model", "effort", "mode", "threads", "thread", "continue", "resume" }
    table.insert(subs, "commands")
    for _, sub in ipairs(subs) do
        assert(vim.tbl_contains(complete, sub), "missing subcommand " .. sub)
    end
    local actions = vim.fn.getcompletion("Conduit thread ", "cmdline")
    for _, action in ipairs({ "new", "next", "prev", "alt", "goto", "search", "close", "delete", "fork", "rename" }) do
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
    twin, iwin = assert(twin), assert(iwin)
    local wins = #vim.api.nvim_list_wins()

    local b = assert(conduit.new())
    assert(#threads.list == 2 and threads.current == b and conduit.current == b)
    assert(#vim.api.nvim_list_wins() == wins, "reuses the chat windows")
    assert(vim.api.nvim_win_get_buf(twin) == b.transcript)
    assert(vim.api.nvim_win_get_buf(iwin) == b.input)
    assert(vim.api.nvim_buf_is_valid(a.transcript) and transcript(a):find("first thread", 1, true))
    assert(winbar_text(twin) == " 1 first thread │ 2 New thread ", winbar_text(twin))

    send(b, "second thread")
    assert(a.session_id ~= b.session_id)
    assert(not transcript(b):find("first thread", 1, true))

    press(b.input, "]t")
    assert(threads.current == a and vim.api.nvim_win_get_buf(twin) == a.transcript)
    assert(vim.wo[twin].winbar:find("ConduitThreadActive# 1 first thread", 1, true), vim.wo[twin].winbar)
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
    local labels ---@type string[]?
    vim.ui.select = function(items, opts, cb)
        labels = vim.tbl_map(assert(opts.format_item), items)
        cb(items[1])
    end
    press(b.input, "gs")
    vim.ui.select = orig_select
    labels = assert(labels)

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
    local title = assert(chat.title)
    assert(vim.fn.strcharlen(title) == 50 and vim.endswith(title, "…"), title)
    send(chat, "title Refactor the parser")
    assert(chat.title == "Refactor the parser", chat.title)
    local twin = assert(chat:wins())
    assert(winbar_text(twin) == " 1 Refactor the parser ", winbar_text(twin))

    -- Without the thread bar, the title and state share the chat's winbar.
    require("conduit.config").options.ui.thread_bar = false
    chat:_refresh_winbar()
    assert(winbar_text(twin):find("^ mock · Refactor the parser .* ready"), winbar_text(twin))
    require("conduit.config").options.ui.thread_bar = true
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

---@class conduit.test.Methods
---@field [integer] string
---@field last_params? table Params of the last session/load or session/resume

local ALL_CAPS = "--threads=load,list,resume,close,delete,fork,title"

---Register a mock agent with thread capabilities under a new name and start it.
---@param name string
---@param ... string Extra mock arguments
---@return conduit.Agent agent, conduit.test.Methods methods Requests sent to it, in order
local function thread_agent(name, ...)
    local config = require("conduit.config").options
    config.agents[name] = { cmd = vim.v.progpath, args = { "-l", "tests/mock_agent.lua", ... } }
    local agent = assert(conduit.agent(name))
    local methods = {} ---@type conduit.test.Methods
    local request = agent._request --[[@as fun(self: conduit.Agent, method: string, params: table, cb: fun(err: table?, result: any))]]
    ---@param self conduit.Agent
    ---@param method string
    ---@param params table
    ---@param cb fun(err: table?, result: any)
    local function spy(self, method, params, cb)
        table.insert(methods, method)
        if method == "session/load" or method == "session/resume" then
            methods.last_params = params
        end
        return request(self, method, params, cb)
    end
    rawset(agent, "_request", spy)
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
    local agent = conduit.agents[name] ---@type conduit.Agent?
    if agent then
        agent:stop()
        conduit.agents[name] = nil
    end
    require("conduit.config").options.agents[name] = nil
end

---@param methods conduit.test.Methods
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
    local labels ---@type string[]?
    vim.ui.select = function(items, opts, cb)
        labels = vim.tbl_map(assert(opts.format_item), items)
        for _, item in ipairs(items) do
            if choose(item.data) then
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
    return assert(labels)
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
    assert(vim.startswith(assert(labels[2]), "  Older work · past"), labels[2])
    assert(vim.startswith(assert(labels[3]), "  past-3 · past"), labels[3])
    assert(labels[4] == "+ New thread" and #labels == 4, vim.inspect(labels))

    local chat = assert(conduit.current)
    wait_for(function()
        return chat.session_id == "past-1" and not chat.busy
    end, "session/load")
    assert(assert(methods.last_params).cwd == vim.fn.getcwd())
    local text = transcript(chat)
    assert(text:find("## You\n\nhello past\n\n## past\n\nhi from the past", 1, true), text)
    assert(text:find("✓ Read notes\n\n✗ Run make …\n```\nmake: *** no rule\n```", 1, true), text)
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
    assert(vim.startswith(assert(labels[1]), "  remember me · loader"), vim.inspect(labels))
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
    local restored = rawget(chat, "session_id")
    assert(restored == sid, tostring(restored))
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
    local again ---@type { err: string? }?
    agent:close_session(sid, function(err)
        again = { err = err }
    end)
    wait_for(function()
        return again
    end, "second session/close")
    assert(assert(again).err == nil, "closing twice (-32002) counts as success")

    -- Closed threads stay in the history.
    local labels = pick(agent, function(item)
        return item.info ~= nil and item.info.session_id == sid
    end)
    assert(vim.startswith(assert(labels[1]), "  close me · closer"), vim.inspect(labels))
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
    thread_agent("forker", ALL_CAPS)
    local chat = assert(conduit.new("forker"))
    send(chat, "fork me")
    local forked ---@type conduit.Chat?
    threads.fork(chat, function(err, f)
        assert(not err, err)
        forked = f
    end)
    wait_for(function()
        return forked
    end, "session/fork")
    local fork = assert(forked)
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
    drop_agent("forker")
end)

test("threads: renamed titles stick and are stored by the agent", function()
    reset_threads()
    local _, methods = thread_agent("namer", ALL_CAPS)
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
    assert(chat:display_title() == "Custom name", "agent titles don't replace user titles")
    assert(assert(require("conduit.history").get("namer", assert(chat.session_id))).custom_title)
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

test("mcp: every session method sends the servers", function()
    local config = require("conduit.config").options
    config.mcp_servers = {
        tool = { command = "sh", env = { A = "1" } },
        docs = { type = "http", url = "https://example.com/mcp" },
        events = { type = "sse", url = "https://example.com/sse" },
    }
    local agent = thread_agent("mcper", ALL_CAPS, "--mcp=http")
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
    local ref = { session_id = sid, cwd = cwd }
    for _, method in ipairs({ "load_session", "resume_session", "fork_session" }) do
        servers = sent(function(cb)
            agent[method](agent, ref, null_handler, cb)
        end)
        assert(vim.deep_equal(servers, want), method .. ": " .. vim.inspect(servers))
    end
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

---Use a fake picker that records the spec it's given, for the duration of `fn`.
---@param fn fun(specs: table<integer, conduit.PickerSpec>)
local function with_picker(fn)
    local config = require("conduit.config").options
    local specs = {}
    config.ui.picker = function(spec)
        table.insert(specs, spec)
    end
    local ok, err = pcall(fn, specs)
    config.ui.picker = "auto"
    assert(ok, err)
end

---Labels of a picker spec's current items.
---@param spec conduit.PickerSpec
---@return string[]
local function spec_labels(spec)
    return vim.tbl_map(require("conduit.ui.picker").label, spec.items())
end

---Run a spec's `load` and wait for it.
---@param spec conduit.PickerSpec
local function spec_load(spec)
    local done = false
    assert(spec.load)(function()
        done = true
    end)
    wait_for(function()
        return done
    end, "picker items to load")
end

---@param spec conduit.PickerSpec
---@param pred fun(data: any): boolean
---@return conduit.PickerItem
local function spec_item(spec, pred)
    for _, item in ipairs(spec.items()) do
        if pred(item.data) then
            return item
        end
    end
    error("no such picker item in " .. vim.inspect(spec_labels(spec)))
end

---@param spec conduit.PickerSpec
---@param key string
---@return fun(item: conduit.PickerItem?)
local function spec_action(spec, key)
    for _, action in ipairs(spec.actions or {}) do
        if action.key == key then
            return action.fn
        end
    end
    error("no action on " .. key)
end

test("picker: auto picks an installed picker plugin, else vim.ui.select", function()
    local picker = require("conduit.ui.picker")
    local config = require("conduit.config").options
    local selected
    local orig_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
        selected = vim.tbl_map(assert(opts.format_item), items)
        cb(items[2])
    end
    local chosen
    ---@type conduit.PickerSpec
    local spec = {
        title = "Test",
        items = function()
            return {
                { text = "one", segments = { { "one" } }, data = 1 },
                { text = "two", segments = { { "t", "Special" }, { "wo" } }, data = 2 },
            }
        end,
        on_select = function(item)
            chosen = item.data
        end,
    }
    picker.pick(spec)
    vim.ui.select = orig_select
    assert(vim.deep_equal(selected, { "one", "two" }) and chosen == 2, vim.inspect(selected))

    -- A loaded snacks.nvim wins; its items keep the highlighted segments.
    local opts ---@type any
    package.loaded["snacks"] = {
        picker = {
            pick = function(o)
                opts = o
                return { closed = false }
            end,
        },
    }
    spec.actions = {
        {
            key = "<C-d>",
            desc = "Delete",
            fn = function(item)
                chosen = "deleted " .. assert(item).data
            end,
        },
    }
    picker.pick(spec)
    package.loaded["snacks"] = nil
    local items = opts.finder()
    assert(#items == 2 and items[2].text == "two")
    assert(vim.deep_equal(opts.format(items[2]), { { "t", "Special" }, { "wo" } }))
    assert(opts.win.input.keys["<C-d>"][1] == "conduit_1")
    local fake = {
        close = function() end,
    }
    opts.actions.conduit_1.action(fake, items[1])
    opts.confirm(fake, items[1])
    wait_for(function()
        return chosen == 1
    end, "the snacks confirm")

    -- fzf-lua gets numbered lines and fzf key names.
    package.loaded["fzf-lua"] = {
        fzf_exec = function(contents, o)
            opts = { contents = contents, o = o }
        end,
    }
    config.ui.picker = "fzf_lua"
    picker.pick(spec)
    config.ui.picker = "auto"
    package.loaded["fzf-lua"] = nil
    assert(vim.deep_equal(opts.contents, { "1\tone", "2\ttwo" }), vim.inspect(opts.contents))
    opts.o.actions["ctrl-d"]({ "2\ttwo" })
    wait_for(function()
        return chosen == "deleted 2"
    end, "the fzf action")
end)

test("threads: picker orders by recent use and streams in past threads", function()
    reset_threads()
    thread_agent("streamer", ALL_CAPS, "--seed")
    with_picker(function(specs)
        local a = assert(conduit.new("streamer"))
        send(a, "alpha")
        local b = assert(conduit.new("streamer"))
        send(b, "beta")
        local c = assert(conduit.new("streamer"))
        send(c, "gamma")
        require("conduit.threads").switch(a)
        -- Used most recently: a (current), c, b.
        conduit.threads("streamer")
        local spec = specs[1]
        assert(spec.title == "Conduit threads", spec.title)
        assert(
            vim.deep_equal(spec_labels(spec), {
                "  gamma · streamer",
                "  beta · streamer",
                "● alpha · streamer",
                "+ New thread",
            }),
            vim.inspect(spec_labels(spec))
        )
        spec_load(spec)
        local labels = spec_labels(spec)
        assert(vim.startswith(assert(labels[4]), "  Old work · streamer"), vim.inspect(labels))
        assert(labels[#labels] == "+ New thread", vim.inspect(labels))

        -- Previews: live threads show their transcript, past ones their details.
        local preview = assert(spec.preview)
        local lines, ft = preview(assert(spec.items()[1]))
        assert(ft == "markdown" and table.concat(lines, "\n"):find("you said: gamma", 1, true))
        lines = preview(spec_item(spec, function(d)
            return d.info and d.info.session_id == "past-1"
        end))
        assert(lines[1] == "# Old work" and vim.tbl_contains(lines, "- session: past-1"), vim.inspect(lines))

        -- <C-g> reopens with every directory's threads.
        spec_action(spec, "<C-g>")()
        local all = specs[2]
        assert(all.title == "Conduit threads (all directories)", all.title)
        spec_load(all)
        local found = false
        for _, label in ipairs(spec_labels(all)) do
            found = found or label:find("Other project", 1, true) ~= nil
        end
        assert(found, vim.inspect(spec_labels(all)))

        all.on_select(spec_item(all, function(d)
            return d.chat == b
        end))
        assert(conduit.current == b and b:is_open())
    end)
    drop_agent("streamer")
end)

test("threads: picker actions rename, delete and start threads", function()
    reset_threads()
    local threads = require("conduit.threads")
    local history = require("conduit.history")
    local agent, methods = thread_agent("actor", ALL_CAPS, "--seed")
    local orig_input, orig_select = vim.ui.input, vim.ui.select
    vim.ui.input = function(_, cb)
        cb("  Renamed ")
    end
    vim.ui.select = function(items, _, cb)
        cb(items[1]) -- "Delete"
    end
    local ok, err = pcall(with_picker, function(specs)
        local chat = assert(conduit.new("actor"))
        send(chat, "rename me")
        conduit.threads("actor")
        spec_action(specs[1], "<C-r>")(spec_item(specs[1], function(d)
            return d.chat == chat
        end))
        wait_for(function()
            return count(methods, "session/set_title") == 1
        end, "session/set_title")
        assert(chat.title == "Renamed" and #specs == 2, chat.title)

        -- Past threads are renamed locally.
        spec_load(specs[2])
        spec_action(specs[2], "<C-r>")(spec_item(specs[2], function(d)
            return d.info and d.info.session_id == "past-2"
        end))
        local known = assert(history.get("actor", "past-2"))
        assert(known.title == "Renamed" and known.custom_title)
        spec_load(specs[3])
        spec_item(specs[3], function(d)
            return d.info and d.info.session_id == "past-2" and d.info.title == "Renamed"
        end)

        spec_action(specs[3], "<C-d>")(spec_item(specs[3], function(d)
            return d.chat == chat
        end))
        wait_for(function()
            return count(methods, "session/delete") == 1 and #specs == 4
        end, "session/delete")
        assert(#threads.list == 0)

        spec_action(specs[4], "<C-n>")()
        assert(#threads.list == 1 and assert(conduit.current).agent == agent)
    end)
    vim.ui.input, vim.ui.select = orig_input, orig_select
    assert(ok, err)
    drop_agent("actor")
end)

test("threads: alternate, goto and resume", function()
    reset_threads()
    local threads = require("conduit.threads")
    thread_agent("jumper", ALL_CAPS, "--seed")
    local a = assert(conduit.new("jumper"))
    send(a, "Parser work")
    local b = assert(conduit.new("jumper"))
    send(b, "Lexer work")
    local c = assert(conduit.new("jumper"))
    send(c, "Docs")

    press(c.input, "g<Tab>")
    assert(threads.current == b)
    vim.cmd("Conduit thread alt")
    assert(threads.current == c)

    vim.cmd("Conduit thread goto 1")
    assert(threads.current == a)
    conduit.thread_goto("lexer WORK")
    assert(threads.current == b)
    conduit.thread_goto("doc")
    assert(threads.current == c)
    conduit.thread_goto(assert(a.session_id))
    assert(threads.current == a)
    assert(vim.tbl_contains(vim.fn.getcompletion("Conduit thread goto Lex", "cmdline"), "Lexer work"))

    with_picker(function(specs)
        -- Ambiguous: pick with the query.
        conduit.thread_goto("work")
        assert(specs[1] and specs[1].query == "work")

        -- resume without an id: past threads only.
        conduit.resume()
        local spec = specs[2]
        assert(spec.title == "Conduit: resume a thread", spec.title)
        assert(#spec.items() == 0)
        spec_load(spec)
        local labels = spec_labels(spec)
        assert(vim.startswith(assert(labels[1]), "  Old work · jumper") and #labels == 3, vim.inspect(labels))
    end)

    vim.cmd("Conduit resume " .. b.session_id)
    assert(threads.current == b)
    vim.cmd("Conduit resume past-2")
    local chat
    wait_for(function()
        chat = conduit.current
        return chat and chat.session_id == "past-2" and not chat.busy
    end, "past-2 to load")
    assert(transcript(chat):find("older question\n[image: shot.png](file:///tmp/shot.png)", 1, true), transcript(chat))
    drop_agent("jumper")
end)

test("threads: background turns and permission requests are flagged", function()
    reset_threads()
    local threads = require("conduit.threads")
    local notes = {}
    local orig_notify = vim.notify
    vim.notify = function(msg)
        table.insert(notes, msg)
    end
    local a = assert(conduit.new())
    send(a, "first")
    local b = assert(conduit.new())
    -- Start a turn in a, then look at b before it finishes.
    threads.switch(a)
    vim.api.nvim_buf_set_lines(a.input, 0, -1, false, { "background work" })
    a:submit()
    threads.switch(b)
    wait_for(function()
        return not a.busy
    end, "the background turn")
    vim.notify = orig_notify
    assert(a.unread, "flagged unread")
    assert(vim.tbl_contains(notes, "[conduit] first: the agent replied"), vim.inspect(notes))
    assert(threads.label(a) == "  first · mock · unread", threads.label(a))
    local twin = assert(b:wins())
    assert(winbar_text(twin):find("1 first ● │ 2 New thread", 1, true), winbar_text(twin))
    assert(conduit.status().unread == 1 and conduit.status().count == 2)
    threads.switch(a)
    assert(conduit.status().unread == 0, "switching marks it read")

    -- Permission requests: flagged while waiting for the answer.
    local path = vim.fn.tempname()
    vim.fn.writefile({ "x" }, path)
    local orig_select = vim.ui.select
    local answer ---@type fun()?
    vim.ui.select = function(items, _, cb)
        answer = function()
            cb(items[1])
        end
    end
    vim.api.nvim_buf_set_lines(a.input, 0, -1, false, { "edit " .. path })
    a:submit()
    wait_for(function()
        return a.waiting
    end, "the permission request")
    assert(threads.label(a):find("needs permission", 1, true), threads.label(a))
    assert(conduit.status().waiting == 1)
    assert(answer)()
    vim.ui.select = orig_select
    assert(not a.waiting)
    wait_for(function()
        return not a.busy
    end, "the turn to finish")
    reset_threads()
end)

test("threads: the thread bar fits narrow windows around the current thread", function()
    reset_threads()
    local threads = require("conduit.threads")
    local chats = {}
    for i = 1, 6 do
        chats[i] = assert(conduit.new())
        chats[i].title = ("Thread number %d with a long title"):format(i)
    end
    local function text(chat, width)
        return (threads.bar(chat, width):gsub("%%#[%w_]+#", ""):gsub("%%%*", ""))
    end
    local wide = text(chats[1], 400)
    assert(wide:find("1 Thread number 1 with a long t… │ 2 Thread number 2 wit… │", 1, true), wide)
    local narrow = text(chats[4], 40)
    assert(narrow:find("4 Thread number 4 with a …", 1, true), narrow)
    local medium = text(chats[4], 60)
    assert(medium == "‹ 4 Thread number 4 with a … │ 5 Thread nu… ›", medium)
    assert(vim.startswith(narrow, "‹") and vim.endswith(narrow, "›"), narrow)
    assert(vim.fn.strdisplaywidth(narrow) <= 40, narrow)
    chats[2].title = "100%"
    assert(threads.bar(chats[1], 400):find("100%%", 1, true), "escapes %")
    reset_threads()
end)

test("threads: search finds text in live transcripts", function()
    reset_threads()
    local threads = require("conduit.threads")
    local a = assert(conduit.new())
    send(a, "needle in alpha")
    local b = assert(conduit.new())
    send(b, "nothing here")
    with_picker(function(specs)
        local matches = assert(conduit.thread_search("NEEDLE"))
        assert(#matches == 0, "smartcase: upper case matches exactly")
        matches = assert(conduit.thread_search("needle"))
        -- The prompt and the echo in the reply.
        assert(#matches == 2 and matches[1].chat == a, vim.inspect(#matches))
        local spec = specs[1]
        local item = assert(spec.items()[2])
        local match = assert(item.segments[3])
        assert(match[1] == "needle" and match[2] == "ConduitSearchMatch")
        spec.on_select(item)
        assert(threads.current == a)
        local twin = assert(a:wins())
        assert(vim.api.nvim_get_current_win() == twin)
        local cursor = vim.api.nvim_win_get_cursor(twin)
        assert(cursor[1] == matches[2].lnum and cursor[2] == matches[2].col - 1, vim.inspect(cursor))
    end)
    vim.cmd("Conduit thread search --qf alpha")
    local qf = vim.fn.getqflist({ items = 0, title = 0 })
    assert(qf.title == "Conduit: alpha" and #qf.items == 2, vim.inspect(qf))
    assert(qf.items[1].bufnr == a.transcript)
    vim.cmd("cclose")
    reset_threads()
end)

test("threads: lifecycle events fire as User autocmds", function()
    reset_threads()
    local events = {}
    local group = vim.api.nvim_create_augroup("conduit.test.events", { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "ConduitThread*",
        callback = function(ev)
            table.insert(events, { ev.match, ev.data.title })
        end,
    })
    local a = assert(conduit.new())
    send(a, "evented")
    local b = assert(conduit.new())
    require("conduit.threads").close(b)
    vim.api.nvim_del_augroup_by_id(group)
    local names = vim.tbl_map(function(e)
        return e[1]
    end, events)
    assert(names[1] == "ConduitThreadCreated" and names[2] == "ConduitThreadSwitched", vim.inspect(names))
    assert(vim.tbl_contains(names, "ConduitThreadUpdated"))
    assert(vim.deep_equal(events[#events - 1], { "ConduitThreadClosed", "New thread" }), vim.inspect(events))
    assert(vim.deep_equal(events[#events], { "ConduitThreadSwitched", "evented" }), vim.inspect(events))
    reset_threads()
end)

test("chat: @ mentioned images reach the agent as image blocks", function()
    reset_threads()
    local root = image_fixture()
    local chat = assert(conduit.new())
    send(chat, "what is in @" .. root .. "/shot.png")
    local text = transcript(chat)
    assert(text:find(("image shot.png image/png %d"):format(#PNG), 1, true), text)
    reset_threads()
end)

test("chat: agents without image support get a link and a warning", function()
    reset_threads()
    local root = image_fixture()
    thread_agent("blind", "--no-image")
    local chat = assert(conduit.new("blind"))
    local msgs = capture_notify(function()
        send(chat, "what is in @" .. root .. "/shot.png")
    end)
    local text = transcript(chat)
    assert(text:find("resource_link shot.png 0", 1, true), text)
    assert(
        vim.iter(msgs):any(function(m)
            return m:find("doesn't accept images", 1, true) ~= nil
        end),
        vim.inspect(msgs)
    )
    drop_agent("blind")
end)

---A chat whose session has received the mock's slash commands.
---@return conduit.Chat
local function chat_with_commands()
    local chat = assert(conduit.new())
    send(chat, "hi")
    wait_for(function()
        return #chat.agent:get_commands(chat.session_id) > 0
    end, "available_commands_update")
    return chat
end

local function names(list)
    return vim.tbl_map(function(cmd)
        return cmd.name
    end, list)
end

test("commands: the agent keeps each session's slash commands", function()
    local agent = require("conduit.agent").new("cmds", require("conduit.config").options.agents.mock)
    local noop = function() end
    local handler = { on_update = noop, request_permission = noop, on_agent_exit = noop }
    local sid
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
    agent:close_session(sid)
    assert(agent.commands[sid] == nil, "closing forgets the session's commands")
    agent:stop()
end)

test("commands: typing / at the start of the prompt completes agent commands", function()
    local chat = chat_with_commands()
    vim.api.nvim_set_current_win(assert(select(2, chat:wins())))
    local orig = vim.fn.complete
    local calls = {}
    vim.fn.complete = function(col, list)
        table.insert(calls, { col = col, list = list })
    end
    -- Cursor on the trailing "x" stands in for the insert-mode cursor after "re".
    vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, { "/rex" })
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = chat.input })
    vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, { "hi /rex" })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = chat.input })
    vim.fn.complete = orig
    assert(#calls == 1, "only a leading / completes commands: " .. vim.inspect(calls))
    local first = calls[1].list[1]
    assert(calls[1].col == 2 and first.word == "review", vim.inspect(calls[1]))
    assert(first.menu == "optional focus" and first.info == "Review the current changes", vim.inspect(first))
    assert(vim.api.nvim_get_current_win() == select(2, chat:wins()))
    assert(chat.input and vim.wo.winbar:find("/ command", 1, true), vim.wo.winbar)
    vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, {})
end)

test("commands: the input hint shows after the command until arguments are typed", function()
    local chat = chat_with_commands()
    local ns = vim.api.nvim_get_namespaces()["conduit.commands"]
    local function hint(line)
        vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, { line })
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = chat.input })
        local marks = vim.api.nvim_buf_get_extmarks(chat.input, ns, 0, -1, { details = true })
        return marks[1] and marks[1][4].virt_text[1][1]
    end
    assert(hint("/review ") == "optional focus", tostring(hint("/review ")))
    assert(hint("/review") == " optional focus")
    assert(hint("/review auth") == nil, "hint hides once arguments are typed")
    assert(hint("/compact ") == nil, "commands without input have no hint")
    assert(hint("/nope ") == nil)
    vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, {})
end)

test("blink: / completes agent commands with their input hint", function()
    local chat = chat_with_commands()
    local source = require("conduit.blink").new()
    assert(vim.tbl_contains(source:get_trigger_characters(), "/"))
    ---@type { is_incomplete_forward: boolean, items: table[] }?
    local got
    source:get_completions({ cursor = { 1, 3 }, line = "/re", bufnr = chat.input }, function(res)
        got = res
    end)
    got = assert(got)
    local first = got.items[1]
    assert(first.label == "/review" and first.labelDetails.description == "optional focus", vim.inspect(first))
    assert(first.textEdit.newText == "review ", "commands with input get a trailing space")
    local range = first.textEdit.range
    assert(range.start.character == 1 and range["end"].character == 3, vim.inspect(range))
    ---@type table?
    local resolved
    source:resolve(first, function(r)
        resolved = r
    end)
    local doc = assert(resolved).documentation.value
    assert(doc:find("/review", 1, true) and doc:find("Review the current changes", 1, true), doc)

    ---@type { items: table[] }?
    local later
    source:get_completions({ cursor = { 2, 3 }, line = "/re", bufnr = chat.input }, function(res)
        later = res
    end)
    assert(#assert(later).items == 0, "commands only complete on the first line")
end)

test("commands: chat prompts starting with /name run the command", function()
    local chat = chat_with_commands()
    send(chat, "/review auth")
    local text = transcript(chat)
    assert(text:find("ran review: auth (0 context)", 1, true), text)
end)

test("commands: inline commands are sent unwrapped with the selection, as an answer", function()
    chat_with_commands():close()
    inline_buf()
    local job = assert(conduit.inline(2, 3, "/review naming"))
    wait_turn(job)
    assert(job.mode == "ask" and job.kind == "answer", vim.inspect({ job.mode, job.kind }))
    local text = assert(job.answer):text()
    assert(text:find("ran review: naming (1 context)", 1, true), text)
    job:close()

    -- The inline prompt completes from the agent's last list before a session exists.
    conduit.inline(2, 3)
    local buf = vim.api.nvim_get_current_buf()
    assert(vim.bo[buf].filetype == "conduit_input")
    assert(vim.deep_equal(names(require("conduit.commands").list(buf)), { "review", "compact" }))
    vim.cmd.stopinsert()
    vim.api.nvim_win_close(0, true)
    vim.cmd("bwipeout!")
end)

test("commands: :Conduit commands starts the prompt with the picked command", function()
    local chat = chat_with_commands()
    local orig = vim.ui.select
    local shown
    vim.ui.select = function(items, opts, cb)
        shown = vim.tbl_map(opts.format_item, items)
        cb(items[1])
    end
    vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, { "keep this" })
    vim.cmd("Conduit commands")
    vim.ui.select = orig
    vim.cmd.stopinsert()
    assert(shown and shown[1] == "/review optional focus — Review the current changes", vim.inspect(shown))
    local lines = vim.api.nvim_buf_get_lines(chat.input, 0, -1, false)
    assert(lines[1] == "/review keep this", vim.inspect(lines))
    vim.cmd("Conduit commands /compact")
    vim.cmd.stopinsert()
    lines = vim.api.nvim_buf_get_lines(chat.input, 0, -1, false)
    assert(lines[1] == "/compact keep this", vim.inspect(lines))
    assert(vim.tbl_contains(vim.fn.getcompletion("Conduit commands ", "cmdline"), "review"))
    vim.api.nvim_buf_set_lines(chat.input, 0, -1, false, {})
end)

---Results the mock said for each terminal step (`<step> <json>` lines), in order.
---@param chat conduit.Chat
---@return { step: string, value: table }[]
local function term_results(chat)
    local out = {}
    for _, line in ipairs(vim.api.nvim_buf_get_lines(chat.transcript, 0, -1, false)) do
        local step, json = line:match("^(%a+) ({.*})$")
        -- "term" is the prompt itself.
        if step and step ~= "term" then
            table.insert(out, { step = step, value = vim.json.decode(json, { luanil = { object = true } }) })
        end
    end
    return out
end

---Run a `term` prompt in a new chat.
---@param create table terminal/create params
---@param steps string[]
---@return conduit.Chat, table<string, table> results Last result per step
local function run_term(create, steps)
    local chat = assert(conduit.new())
    send(chat, "term " .. vim.json.encode({ create = create, steps = steps }))
    local by_step = {}
    for _, r in ipairs(term_results(chat)) do
        by_step[r.step] = r.value
    end
    return chat, by_step
end

test("terminal: the client advertises terminals and display terminals", function()
    local chat = assert(conduit.new())
    send(chat, "caps")
    local caps = assert(term_results(chat)[1]).value
    assert(caps.terminal == true, vim.inspect(caps))
    assert(caps._meta.terminal_output == true and caps._meta.terminal_output_delta == true, vim.inspect(caps))
end)

test("terminal: runs a command, reports output and exit code", function()
    local chat, r = run_term({ command = "sh", args = { "-c", "printf 'a\\nb\\n'; exit 3" } }, { "wait", "output" })
    assert(r.create and r.create.terminalId, vim.inspect(r))
    assert(r.wait.exitCode == 3 and r.wait.signal == nil, vim.inspect(r.wait))
    assert(r.output.output == "a\nb\n" and r.output.truncated == false, vim.inspect(r.output))
    assert(r.output.exitStatus.exitCode == 3, vim.inspect(r.output))
    local text = transcript(chat)
    assert(text:find("✓ sh\n```console\na\nb\n```\nexit code 3\n", 1, true), text)
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

test("terminal: kill stops the command and keeps its output", function()
    local chat, r = run_term(
        { command = "sh", args = { "-c", "echo started; sleep 30" } },
        { "sleep:300", "kill", "wait", "output" }
    )
    assert(r.wait.signal == "SIGTERM" and r.wait.exitCode == nil, vim.inspect(r.wait))
    assert(r.output.output == "started\n", vim.inspect(r.output))
    assert(transcript(chat):find("started\n```\nkilled by SIGTERM", 1, true), transcript(chat))
end)

test("terminal: released terminals reject requests but stay visible", function()
    local chat, r = run_term({ command = "echo", args = { "kept" } }, { "wait", "release", "output" })
    assert(r.output.code == -32602, vim.inspect(r.output))
    assert(transcript(chat):find("```console\nkept\n```", 1, true), transcript(chat))
end)

test("terminal: missing executables are reported to the agent", function()
    local _, r = run_term({ command = "conduit-no-such-cmd", args = { "x" } }, {})
    assert(r.create.code == -32603 and r.create.message:find("conduit%-no%-such%-cmd"), vim.inspect(r.create))
end)

test("terminal: disabled terminals aren't advertised or run", function()
    local config = require("conduit.config").options
    config.terminal.enabled = false
    local agent = thread_agent("noterm")
    local chat = assert(conduit.new("noterm"))
    send(chat, "caps")
    local caps = assert(term_results(chat)[1]).value
    send(chat, "term " .. vim.json.encode({ create = { command = "echo" } }))
    config.terminal.enabled = true
    assert(caps.terminal == false, vim.inspect(caps))
    local create = assert(term_results(chat)[2]).value
    assert(create.code == -32601, vim.inspect(create))
    assert(agent)
    drop_agent("noterm")
end)

test("terminal: running commands are killed when the agent exits", function()
    local agent = thread_agent("termexit")
    local chat = assert(conduit.new("termexit"))
    send(chat, "term " .. vim.json.encode({ create = { command = "sleep", args = { "30" } } }))
    local term = assert(agent.terminals["term-1"])
    local pid = assert(assert(term.proc).pid)
    agent:stop()
    wait_for(function()
        return term.exit ~= nil
    end, "command to be killed")
    assert(term.exit.signal == "SIGTERM", vim.inspect(term.exit))
    assert(next(agent.terminals) == nil)
    drop_agent("termexit")
    assert(not vim.uv.kill(pid, 0) or vim.uv.kill(pid, 0) ~= 0, "process still running")
end)

test("terminal: display terminals from tool call _meta render live", function()
    local chat = assert(conduit.new())
    send(chat, "display")
    wait_for(function()
        return transcript(chat):find("exit code 2", 1, true)
    end, "display terminal output")
    local text = transcript(chat)
    assert(text:find("✗ make test\n```console\nbuilding\nfailed\n```\nexit code 2\n", 1, true), text)
end)

test("terminal: long output shows the last lines and expands in place", function()
    local config = require("conduit.config").options
    config.tools.output_lines = 3
    local chat = run_term({ command = "sh", args = { "-c", "for i in 1 2 3 4 5 6; do echo line$i; done" } }, { "wait" })
    local text = transcript(chat)
    assert(
        text:find("✓ sh\n… 3 earlier lines (`<CR>` to expand)\n```console\nline4\nline5\nline6\n```\n", 1, true),
        text
    )
    local lines = vim.api.nvim_buf_get_lines(chat.transcript, 0, -1, false)
    local row = assert(vim.fn.index(lines, "✓ sh"))
    assert(chat:toggle_tool(row))
    config.tools.output_lines = 8
    text = transcript(chat)
    assert(text:find("✓ sh\n```console\nline1\nline2\nline3\nline4\nline5\nline6\n```\n", 1, true), text)
end)

test("terminal: display lines strip escapes and resolve carriage returns", function()
    local Terminal = require("conduit.terminal")
    local lines = Terminal.display_lines("\27[32mok\27[0m\r\n10%\r50%\r100%\nend")
    assert(vim.deep_equal(lines, { "ok", "100%", "end" }), vim.inspect(lines))
    assert(Terminal.sanitize("a\255b") == "a\239\191\189b")
    assert(Terminal.sanitize("é") == "é")
end)
