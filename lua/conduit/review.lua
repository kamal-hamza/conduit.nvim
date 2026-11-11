--- Review of agent edits. Most agents (Claude, Codex) write files themselves, so
--- edits can't be held back for approval. Instead each file's content is saved
--- before the agent first touches it (its baseline), and the difference between
--- that and the file now is shown as hunks to accept or reject: accepting moves
--- the baseline forward, rejecting puts the baseline's lines back.
local config = require("conduit.config")
local fs = require("conduit.fs")

local M = {}

---A change between the baseline and the current text, as `vim.text.diff` indices.
---@class conduit.ReviewHunk
---@field old_start integer 1-based first baseline line; with `old_count` 0, the line the new lines follow
---@field old_count integer
---@field new_start integer 1-based first current line; with `new_count` 0, the line the removed lines followed
---@field new_count integer

---Who made a change: a session handler and one of its tool calls.
---@class conduit.ReviewSource
---@field handler conduit.SessionHandler
---@field id string Tool call id, or "inline" for inline replies

---@class conduit.ReviewFile
---@field path string Canonical path
---@field existed boolean Whether the file existed before the agent touched it
---@field baseline string[] Lines before the agent's edits (accepted hunks included)
---@field eol boolean The baseline ended with a newline
---@field exists boolean Whether the file exists now
---@field hunks conduit.ReviewHunk[]
---@field pending table<string, true> Running tool calls that touch the file, by key
---@field sources table<string, conduit.ReviewSource> Tool calls that touched the file, by key
---@field conflict? boolean The agent changed the file on disk under unsaved changes in its buffer
---@field gone? boolean The file was deleted on disk while its buffer is loaded

---A tool call as far as review cares: what it touches and how it's going.
---@class conduit.ReviewTool
---@field handler conduit.SessionHandler
---@field id string
---@field kind? string
---@field status? string
---@field content? table[]
---@field locations? table[]
---@field paths table<string, true> Canonical paths already snapshotted for it

---@type table<string, conduit.ReviewFile>
M.files = {}

-- Tool calls in flight, by key.
---@type table<string, conduit.ReviewTool>
local tools = {}

-- How each finished tool call's changes were reviewed, by key.
---@type table<string, "accepted"|"rejected"|"reviewed">
local outcomes = {}

-- Short ids for handlers, so tool call keys are strings.
local handler_ids = setmetatable({}, { __mode = "k" }) ---@type table<conduit.SessionHandler, integer>
local handler_count = 0

local EDIT_KINDS = { edit = true, delete = true, move = true } ---@type table<string, true?>
local DONE = { completed = true, failed = true } ---@type table<string, true?>

---@param handler conduit.SessionHandler
---@param id string
---@return string
local function key_of(handler, id)
    local hid = handler_ids[handler]
    if not hid then
        handler_count = handler_count + 1
        hid = handler_count
        handler_ids[handler] = hid
    end
    return ("%d/%s"):format(hid, id)
end

---Whether edits made for `handler` are reviewed (`review.enabled` plus the
---`review.chat` or `review.inline` switch for where they come from).
---@param handler conduit.SessionHandler
---@return boolean
function M.wants(handler)
    local opts = config.options.review
    if not opts or not opts.enabled then
        return false
    end
    return opts[handler.source or "chat"] == true
end

---Turn review on or off, everywhere or for one source.
---@param source? "chat"|"inline"
---@return boolean enabled The new state
function M.toggle(source)
    local opts = config.options.review
    local key = source or "enabled"
    opts[key] = not opts[key]
    local what = source and ("review of %s edits"):format(source) or "review of agent edits"
    vim.notify(("[conduit] %s %s"):format(what, opts[key] and "on" or "off"), vim.log.levels.INFO)
    return opts[key]
end

---@param text string
---@return string[] lines, boolean eol
local function split(text)
    local lines = vim.split(text, "\n", { plain = true })
    local eol = #lines > 1 and lines[#lines] == ""
    if eol then
        table.remove(lines)
    end
    return lines, eol
end

---@param lines string[]
---@return string
local function join(lines)
    return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

---@param path string
---@return string[]? lines, boolean eol Nil when the file can't be read
local function read_disk(path)
    local f = io.open(path, "rb")
    if not f then
        return nil, false
    end
    local text = f:read("*a") or ""
    f:close()
    -- An empty file reads as one empty line, like an empty buffer.
    if text == "" then
        return { "" }, false
    end
    return split(text)
end

---@param path string
---@param lines string[]
---@param eol boolean
---@return boolean ok
local function write_disk(path, lines, eol)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = io.open(path, "wb")
    if not f then
        return false
    end
    f:write(table.concat(lines, "\n") .. (eol and "\n" or ""))
    f:close()
    return true
end

---@param buf integer
---@return string[]
local function buf_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---Write a buffer back to its file, as the agent's own writes do.
---@param buf integer
local function save(buf)
    pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent write!")
    end)
end

---The file's text now: its buffer when that's what it shows, else the disk.
---@param file conduit.ReviewFile
---@return string[] lines, boolean exists, integer? buf
local function current(file)
    local buf = fs.find_buf(file.path)
    if buf and not file.conflict and not file.gone then
        return buf_lines(buf), true, buf
    end
    local lines = read_disk(file.path)
    if lines then
        return lines, true, nil
    end
    return {}, false, nil
end

---@param file conduit.ReviewFile
---@return conduit.ReviewHunk[]
local function compute(file)
    local lines, exists = current(file)
    file.exists = exists
    local diff_fn = vim.text.diff or rawget(vim, "diff")
    local a = file.existed and join(file.baseline) or ""
    local b = exists and join(lines) or ""
    if a == b then
        return {}
    end
    local indices = diff_fn(a, b, { result_type = "indices" }) --[[@as integer[][] ]]
    local hunks = {} ---@type conduit.ReviewHunk[]
    for _, h in ipairs(indices) do
        table.insert(hunks, { old_start = h[1], old_count = h[2], new_start = h[3], new_count = h[4] })
    end
    return hunks
end

---Whether the file has something to review.
---@param file conduit.ReviewFile
---@return boolean
local function changed(file)
    return #file.hunks > 0 or file.existed ~= file.exists
end

---@param file conduit.ReviewFile
local function notify_change(file)
    for _, src in pairs(file.sources) do
        local fn = src.handler.review_changed
        if fn then
            fn(src.handler, src.id)
        end
    end
    vim.api.nvim_exec_autocmds("User", { pattern = "ConduitReviewChanged", data = { path = file.path } })
end

local function ui()
    return require("conduit.ui.review")
end

---@param file conduit.ReviewFile
local function drop(file)
    M.files[file.path] = nil
    local buf = fs.find_buf(file.path)
    if buf then
        ui().detach(buf)
    end
    notify_change(file)
end

---Draw (or clear) the overlay in the file's buffer.
---@param file conduit.ReviewFile
local function redraw(file)
    local buf = fs.find_buf(file.path)
    if not buf then
        return
    end
    if #file.hunks > 0 and file.exists and not file.conflict and not file.gone then
        ui().attach(buf, file)
    else
        ui().detach(buf)
    end
end

local augroup ---@type integer?
-- Set while `sync` reloads a buffer, whose BufReadPost must not refresh mid-refresh.
local reloading = false

---Refresh files when their buffers are opened or written. Idempotent.
local function watch()
    if augroup then
        return
    end
    augroup = vim.api.nvim_create_augroup("conduit.review", { clear = true })
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
        group = augroup,
        callback = function(ev)
            local name = vim.api.nvim_buf_get_name(ev.buf)
            local file = name ~= "" and M.files[fs.canonical(name)]
            if file and not reloading then
                if ev.event == "BufWritePost" then
                    -- The buffer and the disk agree again.
                    file.conflict, file.gone = nil, nil
                end
                M.refresh(file.path)
            end
        end,
    })
end

---Save the file's baseline unless it already has one, and note who's touching it.
---@param path string
---@param src? conduit.ReviewSource
---@param pending? boolean The source is a tool call that's still running
---@return conduit.ReviewFile
local function snapshot(path, src, pending)
    path = fs.canonical(path)
    local file = M.files[path] ---@type conduit.ReviewFile?
    if not file then
        file = {
            path = path,
            existed = false,
            baseline = {},
            eol = true,
            exists = false,
            hunks = {},
            pending = {},
            sources = {},
        }
        local lines, exists, buf = current(file)
        file.existed, file.exists, file.baseline = exists, exists, lines
        if buf then
            file.eol = vim.bo[buf].eol
        elseif exists then
            local _, eol = read_disk(path)
            file.eol = eol
        end
        M.files[path] = file
        watch()
    end
    if src then
        local key = key_of(src.handler, src.id)
        file.sources[key] = src
        if pending then
            file.pending[key] = true
        end
    end
    return file
end

---@param handler conduit.SessionHandler
---@param path string
---@return string
local function resolve(handler, path)
    if not vim.startswith(path, "/") and not path:match("^%a:[/\\]") then
        path = vim.fs.joinpath(handler.cwd or vim.fn.getcwd(), path)
    end
    return fs.canonical(path)
end

---Paths a tool call touches: its locations and diffs.
---@param tool conduit.ReviewTool
---@return string[]
local function tool_paths(tool)
    local out = {} ---@type string[]
    for _, loc in ipairs(type(tool.locations) == "table" and tool.locations or {}) do
        if type(loc) == "table" and type(loc.path) == "string" and loc.path ~= "" then
            table.insert(out, resolve(tool.handler, loc.path))
        end
    end
    for _, item in ipairs(type(tool.content) == "table" and tool.content or {}) do
        if type(item) == "table" and item.type == "diff" and type(item.path) == "string" then
            table.insert(out, resolve(tool.handler, item.path))
        end
    end
    return out
end

---@param tool conduit.ReviewTool
---@return boolean
local function edits(tool)
    if tool.kind and EDIT_KINDS[tool.kind] then
        return true
    end
    for _, item in ipairs(type(tool.content) == "table" and tool.content or {}) do
        if type(item) == "table" and item.type == "diff" then
            return true
        end
    end
    return false
end

---@param text string
---@return string
local function chomp(text)
    return (text:gsub("\n$", ""))
end

---The baseline was taken after the agent wrote the file (it can write before
---its tool call reaches us). Rebuild it by undoing the call's reported diffs on
---the current text.
---@param file conduit.ReviewFile
---@param tool conduit.ReviewTool
---@return boolean rebuilt
local function rebuild(file, tool)
    local lines = current(file)
    local text = table.concat(lines, "\n")
    local rebuilt = false
    local content = type(tool.content) == "table" and tool.content or {}
    for i = #content, 1, -1 do
        local d = content[i]
        if
            type(d) == "table"
            and d.type == "diff"
            and type(d.path) == "string"
            and type(d.newText) == "string"
            and resolve(tool.handler, d.path) == file.path
        then
            local new = chomp(d.newText)
            if type(d.oldText) ~= "string" then
                -- The call created the file.
                if text == new then
                    file.existed, file.baseline = false, {}
                    return true
                end
            elseif d.oldText ~= d.newText then
                local s, e = text:find(new, 1, true)
                if s and e then
                    text = text:sub(1, s - 1) .. chomp(d.oldText) .. text:sub(e + 1)
                    rebuilt = true
                end
            end
        end
    end
    if rebuilt then
        file.baseline = split(text .. "\n")
    end
    return rebuilt
end

---Bring the buffer up to date with the disk after the agent wrote the file.
---Unsaved changes are left alone and the file is marked as a conflict.
---@param file conduit.ReviewFile
local function sync(file)
    local was_conflict = file.conflict
    file.conflict, file.gone = nil, nil
    local buf = fs.find_buf(file.path)
    if not buf then
        return
    end
    local disk = read_disk(file.path)
    if not disk then
        file.gone = true
        return
    end
    if vim.deep_equal(buf_lines(buf), disk) then
        return
    end
    if vim.bo[buf].modified then
        file.conflict = true
        if not was_conflict then
            vim.notify(
                ("[conduit] the agent changed %s on disk, but its buffer has unsaved changes; see :Conduit review"):format(
                    vim.fn.fnamemodify(file.path, ":~:.")
                ),
                vim.log.levels.WARN
            )
        end
        return
    end
    reloading = true
    pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent! edit!")
    end)
    reloading = false
end

---Recompute a file's hunks and redraw it. Files left with nothing to review
---(and no running tool calls) are dropped.
---@param path string
---@param opts? { sync?: boolean, tool?: conduit.ReviewTool } `sync`: the agent may have written the disk
function M.refresh(path, opts)
    opts = opts or {}
    local file = M.files[fs.canonical(path)] ---@type conduit.ReviewFile?
    if not file then
        return
    end
    if opts.sync then
        sync(file)
    end
    file.hunks = compute(file)
    if not changed(file) and opts.tool and rebuild(file, opts.tool) then
        file.hunks = compute(file)
    end
    if not changed(file) and next(file.pending) == nil then
        return drop(file)
    end
    redraw(file)
    notify_change(file)
end

---@param tool conduit.ReviewTool
local function finish(tool)
    local key = key_of(tool.handler, tool.id)
    tools[key] = nil
    for path in pairs(tool.paths) do
        local file = M.files[path] ---@type conduit.ReviewFile?
        if file then
            file.pending[key] = nil
            M.refresh(path, { sync = true, tool = tool })
        end
    end
end

---@param tool conduit.ReviewTool
local function track(tool)
    if not edits(tool) then
        return
    end
    local running = not (tool.status and DONE[tool.status])
    for _, path in ipairs(tool_paths(tool)) do
        if not tool.paths[path] and (running or M.files[path]) then
            tool.paths[path] = true
            snapshot(path, { handler = tool.handler, id = tool.id }, running)
        end
    end
end

---@param handler conduit.SessionHandler
---@param call table ACP ToolCall or ToolCallUpdate
---@return conduit.ReviewTool
local function merge(handler, call)
    local key = key_of(handler, call.toolCallId)
    local tool = tools[key] or { handler = handler, id = call.toolCallId, paths = {} }
    tools[key] = tool
    for _, field in ipairs({ "kind", "status", "content", "locations" }) do
        if call[field] ~= nil then
            tool[field] = call[field]
        end
    end
    return tool
end

---Watch a session update for edits: snapshot files before running tool calls
---change them, and review them when the calls finish.
---@param handler conduit.SessionHandler
---@param update table ACP SessionUpdate
function M.on_update(handler, update)
    local kind = update.sessionUpdate
    if kind ~= "tool_call" and kind ~= "tool_call_update" then
        return
    end
    -- Replayed history (session/load) changed nothing now.
    if type(update.toolCallId) ~= "string" or handler.replaying or handler.muted or not M.wants(handler) then
        return
    end
    local tool = merge(handler, update)
    track(tool)
    if tool.status and DONE[tool.status] then
        finish(tool)
    end
end

---A permission request comes before its tool call runs: snapshot what it touches.
---@param handler conduit.SessionHandler
---@param call? table The request's `toolCall`
function M.on_permission(handler, call)
    if type(call) ~= "table" or type(call.toolCallId) ~= "string" or not M.wants(handler) then
        return
    end
    track(merge(handler, call))
end

---Before an `fs/write_text_file`: snapshot the file.
---@param handler conduit.SessionHandler
---@param path string
function M.before_write(handler, path)
    if M.wants(handler) then
        snapshot(resolve(handler, path), { handler = handler, id = "fs" })
    end
end

---After an `fs/write_text_file`: show the change right away.
---@param path string
function M.after_write(path)
    if M.files[fs.canonical(path)] ~= nil then
        M.refresh(path)
    end
end

---Snapshot a buffer's file before conduit itself edits it for `handler` (inline replies).
---@param handler conduit.SessionHandler
---@param buf integer
---@return string? path Nil when the buffer has no file
function M.snapshot_buf(handler, buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" or vim.bo[buf].buftype ~= "" then
        return nil
    end
    return snapshot(name, { handler = handler, id = "inline" }).path
end

---A turn ended: tool calls that never finished (cancelled) don't hold files any longer.
---@param handler conduit.SessionHandler
function M.turn_done(handler)
    local hid = handler_ids[handler]
    if not hid then
        return
    end
    local prefix = hid .. "/"
    for key, tool in pairs(tools) do
        if vim.startswith(key, prefix) then
            finish(tool)
        end
    end
end

---@param file conduit.ReviewFile
---@param outcome "accepted"|"rejected"
local function record(file, outcome)
    for key in pairs(file.sources) do
        local was = outcomes[key]
        outcomes[key] = (was and was ~= outcome) and "reviewed" or outcome
    end
end

---The hunk at line `lnum` of the file, or the nearest one after it.
---@param path string
---@param lnum integer 1-based
---@return conduit.ReviewHunk?
function M.hunk_at(path, lnum)
    local file = M.files[fs.canonical(path)] ---@type conduit.ReviewFile?
    if not file then
        return nil
    end
    for _, h in ipairs(file.hunks) do
        local first = math.max(h.new_start, 1)
        local last = h.new_count > 0 and h.new_start + h.new_count - 1 or first
        if lnum >= first and lnum <= last then
            return h
        end
    end
end

---Accept a hunk, or the whole file: the agent's text becomes the baseline.
---@param path string
---@param hunk? conduit.ReviewHunk
function M.accept(path, hunk)
    local file = M.files[fs.canonical(path)] ---@type conduit.ReviewFile?
    if not file then
        return
    end
    record(file, "accepted")
    if not hunk or file.existed ~= file.exists then
        return drop(file)
    end
    local lines = current(file)
    local new = vim.list_slice(lines, hunk.new_start, hunk.new_start + hunk.new_count - 1)
    -- With no old lines, `old_start` is the line the new ones follow.
    local at = hunk.old_count > 0 and hunk.old_start or hunk.old_start + 1
    for _ = 1, hunk.old_count do
        table.remove(file.baseline, at)
    end
    for i, line in ipairs(new) do
        table.insert(file.baseline, at + i - 1, line)
    end
    M.refresh(file.path)
end

---Put the whole baseline back: rewrite, recreate or delete the file.
---@param file conduit.ReviewFile
local function restore(file)
    local buf = fs.find_buf(file.path)
    if not file.existed then
        os.remove(file.path)
        if buf then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    elseif buf and not file.conflict then
        local modified = vim.bo[buf].modified
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, file.baseline)
        -- A buffer that matched the disk is saved; unsaved edits (inline replies) stay unsaved.
        if not modified or file.gone then
            save(buf)
        end
    else
        write_disk(file.path, file.baseline, file.eol)
    end
    drop(file)
end

---Reject a hunk, or the whole file: put the baseline's lines back.
---@param path string
---@param hunk? conduit.ReviewHunk
function M.reject(path, hunk)
    local file = M.files[fs.canonical(path)] ---@type conduit.ReviewFile?
    if not file then
        return
    end
    record(file, "rejected")
    if not hunk or file.existed ~= file.exists or file.conflict or file.gone then
        return restore(file)
    end
    local old = vim.list_slice(file.baseline, hunk.old_start, hunk.old_start + hunk.old_count - 1)
    -- With no new lines, `new_start` is the line the removed ones followed.
    local first = hunk.new_count > 0 and hunk.new_start - 1 or hunk.new_start
    local lines, _, buf = current(file)
    if buf then
        local modified = vim.bo[buf].modified
        vim.api.nvim_buf_set_lines(buf, first, first + hunk.new_count, false, old)
        if not modified then
            save(buf)
        end
    else
        local _, eol = read_disk(file.path)
        for _ = 1, hunk.new_count do
            table.remove(lines, first + 1)
        end
        for i, line in ipairs(old) do
            table.insert(lines, first + i, line)
        end
        write_disk(file.path, lines, eol)
    end
    M.refresh(file.path)
end

---Files with changes to review, sorted by path.
---@return conduit.ReviewFile[]
function M.list()
    local out = {} ---@type conduit.ReviewFile[]
    for _, file in pairs(M.files) do
        if changed(file) then
            table.insert(out, file)
        end
    end
    table.sort(out, function(a, b)
        return a.path < b.path
    end)
    return out
end

function M.accept_all()
    for _, file in ipairs(M.list()) do
        M.accept(file.path)
    end
end

function M.reject_all()
    for _, file in ipairs(M.list()) do
        M.reject(file.path)
    end
end

---Quickfix items: one per hunk, or one per created or deleted file.
---@return vim.quickfix.entry[]
function M.qflist()
    local items = {} ---@type vim.quickfix.entry[]
    for _, file in ipairs(M.list()) do
        local note = file.conflict and " (conflict: the buffer has unsaved changes)" or ""
        if file.existed ~= file.exists then
            local what = file.exists and "created by the agent" or "deleted by the agent"
            table.insert(items, { filename = file.path, lnum = 1, text = what .. note })
        else
            for _, h in ipairs(file.hunks) do
                table.insert(items, {
                    filename = file.path,
                    lnum = math.max(h.new_start, 1),
                    text = ("+%d −%d%s"):format(h.new_count, h.old_count, note),
                })
            end
        end
    end
    return items
end

---Review state of a tool call, for its status line in the chat.
---@param handler conduit.SessionHandler
---@param id string
---@return string?
function M.tool_state(handler, id)
    local hid = handler_ids[handler]
    if not hid then
        return nil
    end
    local key = key_of(handler, id)
    for _, file in pairs(M.files) do
        if file.sources[key] and changed(file) then
            return "review pending"
        end
    end
    return outcomes[key]
end

---How many files changed for `handler` are waiting for review.
---@param handler conduit.SessionHandler
---@return integer
function M.pending_count(handler)
    local n = 0
    for _, file in ipairs(M.list()) do
        for _, src in pairs(file.sources) do
            if src.handler == handler then
                n = n + 1
                break
            end
        end
    end
    return n
end

---Forget everything (tests). Files are left as they are.
function M.reset()
    for _, file in pairs(M.files) do
        local buf = fs.find_buf(file.path)
        if buf then
            ui().detach(buf)
        end
    end
    M.files, tools, outcomes = {}, {}, {}
end

return M
