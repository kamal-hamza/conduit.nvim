--- Inline history: every inline answer and edit, kept per project and separate
--- from chat threads (`history.lua` is the thread index; this never sees chats).
--- Stored as append-only JSONL under stdpath("state")/conduit/inline/: each line
--- is a whole entry or a patch to one (`{ id, outcome }`, `{ id, deleted }`),
--- merged on load and compacted when the file grows past twice the cap.
local config = require("conduit.config")
local log = require("conduit.log")

local M = {}

---Where the history files live. Tests point it elsewhere.
M.dir = vim.fn.stdpath("state") .. "/conduit/inline"

---@class conduit.InlineEntry
---@field id string
---@field time integer Unix time
---@field kind "answer"|"edit"
---@field file string Absolute path ("" for unnamed buffers)
---@field line1 integer 1-based, inclusive
---@field line2 integer
---@field prompt string What the user asked
---@field agent string
---@field model? string
---@field effort? string
---@field text? string The answer (answers)
---@field old? string[] The lines before (edits)
---@field new? string[] The lines after (edits)
---@field outcome? "applied"|"rejected"|"pending"|"reverted"
---@field deleted? boolean

local counter = 0

---@return boolean
local function enabled()
    return config.options.inline.history.enabled
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
        log.warn("could not write the inline history: " .. tostring(err))
    end
end

---All entries of this project, newest first, patches applied, deleted ones dropped.
---@return conduit.InlineEntry[]
function M.load()
    local path = M.path()
    if vim.fn.filereadable(path) == 0 then
        return {}
    end
    local by_id, order = {}, {} ---@type table<string, conduit.InlineEntry>, string[]
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
        if not entry.deleted then
            table.insert(out, entry)
        end
    end
    table.sort(out, function(a, b)
        return a.time > b.time or (a.time == b.time and a.id > b.id)
    end)
    local max = config.options.inline.history.max_entries
    if #lines > 2 * max then
        M._compact(out, max)
    end
    if #out > max then
        out = vim.list_slice(out, 1, max)
    end
    return out
end

---Rewrite the file with the newest `max` entries only.
---@param entries conduit.InlineEntry[] Newest first
---@param max integer
function M._compact(entries, max)
    local keep = {}
    for i = math.min(#entries, max), 1, -1 do
        table.insert(keep, vim.json.encode(entries[i]))
    end
    pcall(vim.fn.writefile, keep, M.path())
end

---@param job conduit.InlineJob
---@return table
local function base(job)
    counter = counter + 1
    local status = job.session_id and require("conduit.ui.status").of(job.agent, job.session_id) or nil
    local first, last = job:_range()
    local name = vim.api.nvim_buf_is_valid(job.buf) and vim.api.nvim_buf_get_name(job.buf) or ""
    local request = job.history[1]
    return {
        id = ("%d-%d-%d"):format(os.time(), vim.uv.os_getpid(), counter),
        time = os.time(),
        file = name,
        line1 = (first or 0) + 1,
        line2 = (last or first or 0) + 1,
        prompt = request and request.text or "",
        agent = job.agent.name,
        model = status and status.model,
        effort = status and status.effort,
    }
end

---Remember an inline answer, or update it after a follow-up.
---@param job conduit.InlineJob
function M.record_answer(job)
    local text = job.model and job:_display() or job.text
    if job.history_id then
        return append({ id = job.history_id, text = text })
    end
    local entry = base(job)
    entry.kind, entry.text = "answer", text
    job.history_id = entry.id
    append(entry)
end

---Remember an applied inline edit.
---@param job conduit.InlineJob
---@param first integer 0-based first row of the range
---@param old string[]
---@param new string[]
function M.record_edit(job, first, old, new)
    local entry = base(job)
    entry.kind, entry.old, entry.new = "edit", old, new
    entry.line1, entry.line2 = first + 1, first + math.max(1, #new)
    entry.outcome = require("conduit.review").wants(job) and "pending" or "applied"
    job.history_id = entry.id
    append(entry)
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
---@param outcome "applied"|"rejected"|"pending"|"reverted"
function M.set_outcome(id, outcome)
    append({ id = id, outcome = outcome })
end

---@param id string
function M.delete(id)
    append({ id = id, deleted = true })
end

---The buffer of `entry`'s file, loaded.
---@param entry conduit.InlineEntry
---@return integer?
local function entry_buf(entry)
    if entry.file == "" then
        return nil
    end
    local buf = vim.fn.bufadd(entry.file)
    vim.fn.bufload(buf)
    return buf
end

---Open `entry`'s file at its range in `win` (default: the current window).
---@param entry conduit.InlineEntry
---@param win? integer
function M.jump(entry, win)
    local buf = entry_buf(entry)
    if not buf then
        return vim.notify("[conduit] that entry has no file", vim.log.levels.WARN)
    end
    win = win or vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    local line = math.min(entry.line1, vim.api.nvim_buf_line_count(buf))
    vim.api.nvim_win_set_cursor(win, { line, 0 })
end

---Put an applied edit's old lines back, if its range still holds what the edit wrote.
---@param entry conduit.InlineEntry
---@return boolean reverted
function M.revert(entry)
    if entry.kind ~= "edit" and not entry.old then
        vim.notify("[conduit] only applied edits can be reverted", vim.log.levels.WARN)
        return false
    elseif entry.outcome == "reverted" then
        vim.notify("[conduit] already reverted", vim.log.levels.INFO)
        return false
    end
    local buf = entry_buf(entry)
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
    M.set_outcome(entry.id, "reverted")
    entry.outcome = "reverted"
    return true
end

---The entry as markdown, for previews and the chat.
---@param entry conduit.InlineEntry
---@return string
function M.markdown(entry)
    local where = ("%s:%d-%d"):format(vim.fn.fnamemodify(entry.file, ":~:."), entry.line1, entry.line2)
    local parts = { ("**%s** · %s"):format(entry.prompt, where) }
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
    return table.concat(parts, "\n\n")
end

---Send entries to the quickfix list.
---@param entries conduit.InlineEntry[]
function M.to_qf(entries)
    local items = {}
    for _, e in ipairs(entries) do
        table.insert(items, {
            filename = e.file,
            lnum = e.line1,
            end_lnum = e.line2,
            text = ("%s: %s"):format(e.kind, (e.prompt:gsub("\n.*", ""))),
        })
    end
    vim.fn.setqflist({}, " ", { title = "conduit inline history", items = items })
    vim.cmd("botright copen")
end

return M
