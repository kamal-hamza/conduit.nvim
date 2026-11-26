--- History of everything the agent did, per project: answers (the whole
--- conversation, with the tools and commands it ran), inline edits, and changes
--- the agent made to files itself, each with what became of it (applied,
--- accepted, rejected, reverted).
---
--- Stored as append-only JSONL under stdpath("state")/conduit/history/: each
--- line is a whole entry or a patch to one (`{ id, outcome }`, `{ id, removed }`),
--- merged on load and compacted when the file grows past twice the cap.
local config = require("conduit.config")
local log = require("conduit.log")

local M = {}

---Where the history files live. Tests point it elsewhere.
M.dir = vim.fn.stdpath("state") .. "/conduit/history"

-- Files larger than this keep only their diff, so a change can't be reverted from the history.
local MAX_SNAPSHOT = 256 * 1024

---A tool call the agent made during a request.
---@class conduit.HistoryTool
---@field id string
---@field kind? string
---@field title string
---@field status? string
---@field decision? string How its permission request was answered
---@field reason? string

---A command run (or refused) through an ACP terminal.
---@class conduit.HistoryCommand
---@field command string
---@field decision? string
---@field isolated? boolean
---@field refused? string
---@field exit? string

---@class conduit.HistoryEntry
---@field id string
---@field time integer Unix time
---@field kind "answer"|"edit"|"change"
---@field file string Absolute path ("" for unnamed buffers)
---@field line1 integer 1-based, inclusive
---@field line2 integer
---@field prompt string What the user asked
---@field agent? string
---@field model? string
---@field effort? string
---@field text? string The conversation as shown (answers)
---@field turns? { role: "user"|"agent", text: string }[] The conversation (answers)
---@field old? string[] The lines before (edits)
---@field new? string[] The lines after (edits)
---@field diff? string The agent's change as a unified diff (changes)
---@field kept? string What was kept of it after review
---@field before? string The file before the change (changes; small files only)
---@field after? string The file after the change, before review
---@field created? boolean The agent created the file (changes)
---@field deleted_file? boolean The agent deleted the file (changes)
---@field tools? conduit.HistoryTool[]
---@field commands? conduit.HistoryCommand[]
---@field outcome? "applied"|"accepted"|"rejected"|"partial"|"pending"|"reverted"
---@field removed? boolean Deleted from the history

local counter = 0

---@return boolean
local function enabled()
    return config.options.history.enabled
end

---The history file for the current project (one per working directory).
---@return string
function M.path()
    local cwd = vim.fn.getcwd()
    return ("%s/%s.jsonl"):format(M.dir, (cwd:gsub("[^%w%-_.]", "%%")))
end

---@param record table
local function append(record)
    if not enabled() then
        return
    end
    local path = M.path()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local ok, err = pcall(vim.fn.writefile, { vim.json.encode(record) }, path, "a")
    if not ok then
        log.warn("could not write the history: " .. tostring(err))
    end
end

---@return string
local function new_id()
    counter = counter + 1
    return ("%d-%d-%d"):format(os.time(), vim.uv.os_getpid(), counter)
end

---All entries of this project, newest first, patches applied, removed ones dropped.
---@return conduit.HistoryEntry[]
function M.load()
    local path = M.path()
    if vim.fn.filereadable(path) == 0 then
        return {}
    end
    local by_id, order = {}, {} ---@type table<string, conduit.HistoryEntry>, string[]
    local lines = vim.fn.readfile(path)
    for _, line in ipairs(lines) do
        local ok, record = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
        if ok and type(record) == "table" and type(record.id) == "string" then
            local entry = by_id[record.id]
            if entry then
                for k, v in pairs(record) do
                    entry[k] = v
                end
            elseif record.kind then
                by_id[record.id] = record
                table.insert(order, record.id)
            end
        end
    end
    local out = {}
    for _, id in ipairs(order) do
        local entry = by_id[id]
        if not entry.removed then
            table.insert(out, entry)
        end
    end
    table.sort(out, function(a, b)
        return a.time > b.time or (a.time == b.time and a.id > b.id)
    end)
    local max = config.options.history.max_entries
    if #lines > 2 * max then
        M._compact(out, max)
    end
    if #out > max then
        out = vim.list_slice(out, 1, max)
    end
    return out
end

---Rewrite the file with the newest `max` entries only.
---@param entries conduit.HistoryEntry[] Newest first
---@param max integer
function M._compact(entries, max)
    local keep = {}
    for i = math.min(#entries, max), 1, -1 do
        table.insert(keep, vim.json.encode(entries[i]))
    end
    pcall(vim.fn.writefile, keep, M.path())
end

---The entry with `id`, if it's still in the history.
---@param id string
---@return conduit.HistoryEntry?
function M.get(id)
    for _, entry in ipairs(M.load()) do
        if entry.id == id then
            return entry
        end
    end
end

---@param job conduit.InlineJob
---@return table
local function base(job)
    local status = job.session_id and require("conduit.ui.status").of(job.agent, job.session_id) or nil
    local first, last = job:_range()
    local name = vim.api.nvim_buf_is_valid(job.buf) and vim.api.nvim_buf_get_name(job.buf) or ""
    local request = job.history[1]
    return {
        id = new_id(),
        time = os.time(),
        file = name,
        line1 = (first or job.line1 - 1) + 1,
        line2 = (last or first or job.line2 - 1) + 1,
        prompt = request and request.text or "",
        agent = job.agent.name,
        model = status and status.model,
        effort = status and status.effort,
    }
end

---What the job did besides replying: its tool calls and terminal commands.
---@param job conduit.InlineJob
---@return { tools?: conduit.HistoryTool[], commands?: conduit.HistoryCommand[] }
local function activity(job)
    local tools = {} ---@type conduit.HistoryTool[]
    for _, id in ipairs(job.tool_order) do
        local t = job.tools[id] or {}
        local title = type(t.title) == "string" and (t.title:match("^%s*([^\n]*)") or "") or ""
        table.insert(tools, {
            id = id,
            kind = t.kind,
            title = title ~= "" and title or (t.kind or "tool"),
            status = t.status,
            decision = t.decision,
            reason = t.reason,
        })
    end
    local commands = {} ---@type conduit.HistoryCommand[]
    for _, term in ipairs(job.terminals) do
        table.insert(commands, {
            command = term.command or "",
            decision = term.decision,
            isolated = term.isolated,
            refused = term.refused,
            exit = term.exit and (term:exit_text() or "ok") or nil,
        })
    end
    return { tools = #tools > 0 and tools or nil, commands = #commands > 0 and commands or nil }
end

---Remember an answer, or update it after a follow-up.
---@param job conduit.InlineJob
function M.record_answer(job)
    local act = activity(job)
    local text = job:_display()
    if job.history_id then
        return append({
            id = job.history_id,
            text = text,
            turns = job.history,
            tools = act.tools,
            commands = act.commands,
        })
    end
    local entry = base(job)
    entry.kind, entry.text, entry.turns = "answer", text, job.history
    entry.tools, entry.commands = act.tools, act.commands
    job.history_id = entry.id
    append(entry)
end

---Remember an applied inline edit.
---@param job conduit.InlineJob
---@param first integer 0-based first row of the range
---@param old string[]
---@param new string[]
---@param pending boolean The edit waits for review
function M.record_edit(job, first, old, new, pending)
    local entry = base(job)
    local act = activity(job)
    entry.kind, entry.old, entry.new = "edit", old, new
    entry.line1, entry.line2 = first + 1, first + math.max(1, #new)
    entry.outcome = pending and "pending" or "applied"
    entry.tools, entry.commands = act.tools, act.commands
    job.history_id = entry.id
    append(entry)
end

---@param path string
---@return string?
local function read_text(path)
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.size > MAX_SNAPSHOT then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

---The file's text as the user sees it: its buffer when loaded, else the disk.
---@param path string
---@return string?
local function current_text(path)
    local buf = require("conduit.fs").find_buf(path)
    if buf then
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        return vim.bo[buf].eol and text .. "\n" or text
    end
    return read_text(path)
end

---@class conduit.ChangeRecord
---@field file string
---@field diff string
---@field before? string
---@field created? boolean
---@field deleted_file? boolean
---@field prompt? string
---@field agent? string

---Remember a change the agent made to a file itself. Returns the entry's id.
---@param change conduit.ChangeRecord
---@return string
function M.record_change(change)
    local id = new_id()
    local before = change.before
    if before and #before > MAX_SNAPSHOT then
        before = nil
    end
    local line = tonumber(change.diff:match("@@ %-%d+,?%d* %+(%d+)")) or 1
    append({
        id = id,
        time = os.time(),
        kind = "change",
        file = change.file,
        line1 = math.max(1, line),
        line2 = math.max(1, line),
        prompt = change.prompt or "",
        agent = change.agent,
        diff = change.diff,
        before = before,
        after = not change.deleted_file and current_text(change.file) or nil,
        created = change.created or nil,
        deleted_file = change.deleted_file or nil,
        outcome = "pending",
    })
    return id
end

---Update fields of an entry. A change's new diff also refreshes its snapshot.
---@param id string
---@param fields table
---@param file? string The change's file, when `fields.diff` is set
function M.patch(id, fields, file)
    if fields.diff and file then
        fields.after = current_text(file)
    end
    append(vim.tbl_extend("force", fields, { id = id }))
end

---Record what became of a job's entry (an answer's code applied, ...).
---@param job conduit.InlineJob
---@param outcome "applied"|"rejected"|"pending"|"reverted"
---@param edit? { first: integer, old: string[], new: string[] } The lines an applied answer replaced
function M.outcome(job, outcome, edit)
    if not job.history_id then
        return
    end
    local patch = { id = job.history_id, outcome = outcome } ---@type table
    if edit then
        patch.old, patch.new = edit.old, edit.new
        patch.line1, patch.line2 = edit.first + 1, edit.first + math.max(1, #edit.new)
    end
    append(patch)
end

---@param id string
---@param outcome "applied"|"accepted"|"rejected"|"partial"|"pending"|"reverted"
function M.set_outcome(id, outcome)
    append({ id = id, outcome = outcome })
end

---@param id string
function M.delete(id)
    append({ id = id, removed = true })
end

---The buffer of `entry`'s file, loaded.
---@param entry conduit.HistoryEntry
---@return integer?
function M.entry_buf(entry)
    if entry.file == "" or (vim.fn.filereadable(entry.file) == 0 and vim.fn.bufexists(entry.file) == 0) then
        return nil
    end
    local buf = vim.fn.bufadd(entry.file)
    vim.fn.bufload(buf)
    return buf
end

---Open `entry`'s file at its range in `win` (default: the current window).
---@param entry conduit.HistoryEntry
---@param win? integer
function M.jump(entry, win)
    local buf = M.entry_buf(entry)
    if not buf then
        return vim.notify("[conduit] that entry's file is gone", vim.log.levels.WARN)
    end
    win = win or vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    local line = math.max(1, math.min(entry.line1 or 1, vim.api.nvim_buf_line_count(buf)))
    vim.api.nvim_win_set_cursor(win, { line, 0 })
end

---@param path string
---@param text string
---@return boolean ok
local function write_text(path, text)
    local fs = require("conduit.fs")
    local buf = fs.find_buf(path)
    if buf then
        local lines = vim.split(text, "\n", { plain = true })
        if #lines > 1 and lines[#lines] == "" then
            table.remove(lines)
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd("silent write!")
        end)
        return true
    end
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = io.open(path, "wb")
    if not f then
        return false
    end
    f:write(text)
    f:close()
    return true
end

---Put a change's file back as it was, if it still holds what the agent wrote.
---@param entry conduit.HistoryEntry
---@return boolean reverted
local function revert_change(entry)
    local fs = require("conduit.fs")
    if entry.deleted_file then
        if not entry.before then
            vim.notify("[conduit] the file was too large to keep; restore it with git", vim.log.levels.WARN)
            return false
        elseif vim.uv.fs_stat(entry.file) then
            vim.notify("[conduit] the file exists again; not reverting", vim.log.levels.WARN)
            return false
        end
        return write_text(entry.file, entry.before)
    end
    if entry.after == nil or (not entry.created and entry.before == nil) then
        vim.notify("[conduit] the file was too large to keep; revert it with git", vim.log.levels.WARN)
        return false
    end
    if current_text(entry.file) ~= entry.after then
        vim.notify("[conduit] the file changed since the agent's edit; not reverting", vim.log.levels.WARN)
        return false
    end
    if entry.created then
        local buf = fs.find_buf(entry.file)
        os.remove(entry.file)
        if buf then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
        return true
    end
    return write_text(entry.file, assert(entry.before))
end

---Undo an edit or change, if the file still holds what it wrote.
---@param entry conduit.HistoryEntry
---@return boolean reverted
function M.revert(entry)
    if entry.outcome == "reverted" then
        vim.notify("[conduit] already reverted", vim.log.levels.INFO)
        return false
    elseif entry.kind == "change" then
        if not revert_change(entry) then
            return false
        end
        -- A change still under review is done with.
        local review = require("conduit.review")
        local file = review.files[require("conduit.fs").canonical(entry.file)] ---@type conduit.ReviewFile?
        if file then
            review.refresh(entry.file)
        end
    elseif entry.old then
        local buf = M.entry_buf(entry)
        local new, old = entry.new or {}, entry.old or {}
        if not buf then
            return false
        end
        local first = entry.line1 - 1
        local current = vim.api.nvim_buf_get_lines(buf, first, first + #new, false)
        if not vim.deep_equal(current, new) then
            vim.notify("[conduit] those lines changed since the edit; not reverting", vim.log.levels.WARN)
            return false
        end
        vim.api.nvim_buf_set_lines(buf, first, first + #new, false, old)
    else
        vim.notify("[conduit] only edits and changes can be reverted", vim.log.levels.WARN)
        return false
    end
    M.set_outcome(entry.id, "reverted")
    entry.outcome = "reverted"
    return true
end

---Where an entry applies, for lists.
---@param entry conduit.HistoryEntry
---@return string
function M.where(entry)
    local name = entry.file ~= "" and vim.fn.fnamemodify(entry.file, ":~:.") or "[No Name]"
    if entry.kind == "change" then
        return name
    end
    return ("%s:%d-%d"):format(name, entry.line1, entry.line2)
end

---@param entry conduit.HistoryEntry
---@return string[]
local function activity_lines(entry)
    local out = {} ---@type string[]
    for _, t in ipairs(entry.tools or {}) do
        local note = t.decision and (" (%s)"):format(t.decision) or ""
        table.insert(
            out,
            ("- %s `%s`%s%s"):format(t.kind or "tool", t.title, t.status and (" " .. t.status) or "", note)
        )
    end
    for _, c in ipairs(entry.commands or {}) do
        local note ---@type string
        if c.refused then
            note = "refused: " .. c.refused
        else
            local bits = { c.decision, c.isolated and "isolated" or "not isolated", c.exit }
            note = table.concat(
                vim.tbl_filter(function(s)
                    return s ~= nil
                end, bits),
                ", "
            )
        end
        table.insert(out, ("- ran `%s` (%s)"):format(c.command, note))
    end
    return out
end

---The entry as markdown, for the sidebar and previews.
---@param entry conduit.HistoryEntry
---@return string
function M.markdown(entry)
    local prompt = (entry.prompt:gsub("\n.*", ""))
    local parts =
        { prompt ~= "" and ("**%s** · %s"):format(prompt, M.where(entry)) or ("**%s**"):format(M.where(entry)) }
    if entry.outcome and entry.outcome ~= "pending" then
        table.insert(parts, "_" .. entry.outcome .. "_")
    end
    if entry.text then
        table.insert(parts, entry.text)
    end
    if entry.old or entry.new then
        local diff = {}
        for _, l in ipairs(entry.old or {}) do
            table.insert(diff, "-" .. l)
        end
        for _, l in ipairs(entry.new or {}) do
            table.insert(diff, "+" .. l)
        end
        table.insert(parts, "```diff\n" .. table.concat(diff, "\n") .. "\n```")
    end
    if entry.diff and entry.diff ~= "" then
        local what = entry.created and "Created" or entry.deleted_file and "Deleted" or "Changed"
        table.insert(parts, ("%s by %s:"):format(what, entry.agent or "the agent"))
        table.insert(parts, "```diff\n" .. entry.diff:gsub("\n$", "") .. "\n```")
    end
    local activity = activity_lines(entry)
    if #activity > 0 then
        table.insert(parts, "Tools:\n" .. table.concat(activity, "\n"))
    end
    return table.concat(parts, "\n\n")
end

---Send entries to the quickfix list.
---@param entries conduit.HistoryEntry[]
function M.to_qf(entries)
    local items = {}
    for _, e in ipairs(entries) do
        table.insert(items, {
            filename = e.file,
            lnum = e.line1 or 1,
            end_lnum = e.line2,
            text = ("%s: %s"):format(e.kind, (e.prompt:gsub("\n.*", ""))),
        })
    end
    vim.fn.setqflist({}, " ", { title = "conduit history", items = items })
    vim.cmd("botright copen")
end

return M
