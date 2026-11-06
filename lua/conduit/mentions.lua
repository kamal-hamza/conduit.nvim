--- `@` mentions in prompts: files, directories and special context such as
--- `@diagnostics`. Provides completion items (for blink.cmp or the native
--- popup) and turns mentions into ACP content blocks when sending.
local config = require("conduit.config")

local M = {}

-- Files larger than this are sent as links for the agent to read itself.
M.max_embed_bytes = 256 * 1024
M.max_dir_entries = 300
M.max_items = 100

-- Characters allowed in a mention; mentions end at whitespace.
local PATH_CHARS = "[^%s`'\"<>()%[%]{}]"

-- Indexed by vim.diagnostic.severity values.
---@type table<integer, string>
local severity_names = { "error", "warning", "info", "hint" }

---@class conduit.MentionCtx
---@field root string Directory relative paths resolve against
---@field buf? integer The buffer `@buffer` / `@selection` refer to

---@class conduit.Special
---@field description string
---@field resolve fun(ctx: conduit.MentionCtx): string? Context text, or nil if unavailable

---@param lines string[]
---@param max integer
---@return string
local function clip(lines, max)
    if #lines > max then
        local rest = #lines - max
        lines = vim.list_slice(lines, 1, max)
        table.insert(lines, ("… (%d more)"):format(rest))
    end
    return table.concat(lines, "\n")
end

---@param buf integer
---@return string
local function buf_label(buf, root)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then
        return "[No Name]"
    end
    return vim.fs.relpath(root, name) or vim.fn.fnamemodify(name, ":~")
end

---Special mentions, completed and resolved by name.
---@type table<string, conduit.Special>
M.specials = {
    buffer = {
        description = "Contents of the buffer you were last in",
        resolve = function(ctx)
            if not ctx.buf or not vim.api.nvim_buf_is_valid(ctx.buf) then
                return nil
            end
            local lines = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)
            return ("Buffer %s (%s):\n```%s\n%s\n```"):format(
                buf_label(ctx.buf, ctx.root),
                vim.bo[ctx.buf].filetype,
                vim.bo[ctx.buf].filetype,
                table.concat(lines, "\n")
            )
        end,
    },
    selection = {
        description = "Your last visual selection",
        resolve = function(ctx)
            if not ctx.buf or not vim.api.nvim_buf_is_valid(ctx.buf) then
                return nil
            end
            local s = vim.api.nvim_buf_get_mark(ctx.buf, "<")[1]
            local e = vim.api.nvim_buf_get_mark(ctx.buf, ">")[1]
            if s == 0 or e == 0 then
                return nil
            end
            local lines = vim.api.nvim_buf_get_lines(ctx.buf, s - 1, e, false)
            return ("Selection from %s, lines %d-%d:\n```%s\n%s\n```"):format(
                buf_label(ctx.buf, ctx.root),
                s,
                e,
                vim.bo[ctx.buf].filetype,
                table.concat(lines, "\n")
            )
        end,
    },
    diagnostics = {
        description = "Errors and warnings in open buffers",
        resolve = function(ctx)
            local out = {}
            for _, d in ipairs(vim.diagnostic.get()) do
                if vim.api.nvim_buf_is_valid(d.bufnr) then
                    table.insert(
                        out,
                        ("%s:%d:%d: %s: %s"):format(
                            buf_label(d.bufnr, ctx.root),
                            d.lnum + 1,
                            d.col + 1,
                            severity_names[d.severity] or "diagnostic",
                            (d.message:gsub("\n", " "))
                        )
                    )
                end
            end
            if #out == 0 then
                return "Diagnostics: none."
            end
            table.sort(out)
            return "Diagnostics:\n" .. clip(out, 300)
        end,
    },
    quickfix = {
        description = "Entries in the quickfix list",
        resolve = function(ctx)
            local out = {}
            for _, item in ipairs(vim.fn.getqflist()) do
                local where = item.bufnr > 0 and ("%s:%d: "):format(buf_label(item.bufnr, ctx.root), item.lnum) or ""
                table.insert(out, where .. vim.trim(item.text))
            end
            if #out == 0 then
                return "Quickfix list: empty."
            end
            return "Quickfix list:\n" .. clip(out, 300)
        end,
    },
    diff = {
        description = "Uncommitted changes (git diff HEAD)",
        resolve = function(ctx)
            local res = vim.system({ "git", "diff", "HEAD" }, { cwd = ctx.root }):wait(5000)
            if res.code ~= 0 then
                return nil
            end
            if vim.trim(res.stdout or "") == "" then
                return "Git diff: no uncommitted changes."
            end
            local diff = res.stdout or ""
            if #diff > M.max_embed_bytes then
                diff = diff:sub(1, M.max_embed_bytes) .. "\n… (truncated)"
            end
            return "Git diff (uncommitted changes):\n```diff\n" .. diff .. "\n```"
        end,
    },
}

---@type { root: string, time: integer, files: string[], dirs: string[] }?
local cache

---Relative file and directory paths under `root`: git-tracked plus untracked
---(respecting .gitignore) when in a repo, otherwise a bounded directory walk.
---@param root string
---@return string[] files, string[] dirs
function M.paths(root)
    if cache and cache.root == root and vim.uv.now() - cache.time < 10000 then
        return cache.files, cache.dirs
    end
    local files = {}
    local res = vim.system({ "git", "ls-files", "--cached", "--others", "--exclude-standard" }, { cwd = root })
        :wait(2000)
    if res.code == 0 and res.stdout then
        files = vim.split(res.stdout, "\n", { trimempty = true })
    else
        for name, type in
            vim.fs.dir(root, {
                depth = 6,
                skip = function(dir)
                    local base = vim.fs.basename(dir)
                    return not base:match("^%.") and base ~= "node_modules"
                end,
            })
        do
            if type == "file" then
                table.insert(files, name)
                if #files >= 5000 then
                    break
                end
            end
        end
    end

    local seen, dirs = {}, {}
    for _, file in ipairs(files) do
        local dir = vim.fn.fnamemodify(file, ":h")
        while dir ~= "." and dir ~= "" and not seen[dir] do
            seen[dir] = true
            table.insert(dirs, dir .. "/")
            dir = vim.fn.fnamemodify(dir, ":h")
        end
    end
    table.sort(dirs)
    cache = { root = root, time = vim.uv.now(), files = files, dirs = dirs }
    return files, dirs
end

---@class conduit.MentionItem
---@field word string Text inserted after `@`
---@field kind "file"|"dir"|"buffer"|"special"
---@field detail? string
---@field path? string Absolute path, for files and directories

---@return table<string, true> Relative paths of listed file buffers
local function open_buffers(root)
    local out = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if vim.bo[buf].buflisted and vim.bo[buf].buftype == "" and name ~= "" then
            local rel = vim.fs.relpath(root, name)
            if rel then
                out[rel] = true
            end
        end
    end
    return out
end

---Completion items for the text typed after `@`, best first.
---@param query string
---@param root? string
---@return conduit.MentionItem[]
function M.items(query, root)
    root = root or vim.fn.getcwd()
    local files, dirs = M.paths(root)
    local buffers = open_buffers(root)
    local q = query:lower()
    local out = {}

    local names = vim.tbl_keys(M.specials)
    table.sort(names)
    for _, name in ipairs(names) do
        if vim.startswith(name, q) then
            table.insert(out, { word = name, kind = "special", detail = M.specials[name].description })
        end
    end

    local function item(rel)
        local dir = rel:sub(-1) == "/"
        return {
            word = rel,
            kind = dir and "dir" or (buffers[rel] and "buffer" or "file"),
            path = vim.fs.joinpath(root, rel),
            detail = buffers[rel] and "open buffer" or nil,
        }
    end

    if query == "" then
        -- Nothing typed yet: open buffers, then top-level directories.
        local rels = vim.tbl_keys(buffers)
        table.sort(rels)
        for _, rel in ipairs(rels) do
            table.insert(out, item(rel))
        end
        for _, dir in ipairs(dirs) do
            if not dir:sub(1, -2):find("/", 1, true) then
                table.insert(out, item(dir))
            end
        end
        return vim.list_slice(out, 1, M.max_items)
    end

    -- Fuzzy match, then rank: path prefix > file name prefix > other matches,
    -- with directories and open buffers ahead within each tier.
    local all = vim.list_extend(vim.list_extend({}, dirs), files)
    local matched = vim.fn.matchfuzzy(all, query, { limit = M.max_items * 3 })
    local ranked = {}
    for i, rel in ipairs(matched) do
        local lower = rel:lower()
        local base = vim.fs.basename(rel:gsub("/$", "")):lower()
        local tier = vim.startswith(lower, q) and 0 or (vim.startswith(base, q) and 1 or 2)
        local boost = rel:sub(-1) == "/" and 0 or (buffers[rel] and 1 or 2)
        table.insert(ranked, { rel = rel, key = tier * 10 + boost, i = i })
    end
    table.sort(ranked, function(a, b)
        if a.key ~= b.key then
            return a.key < b.key
        end
        return a.i < b.i
    end)
    for _, r in ipairs(ranked) do
        table.insert(out, item(r.rel))
        if #out >= M.max_items then
            break
        end
    end
    return out
end

---If the text before the cursor ends in a mention being typed, return the
---1-based byte index of its `@` and the text typed after it.
---@param before string
---@return integer?, string?
function M.query(before)
    local start, _, query = before:find("@(" .. PATH_CHARS .. "*)$")
    if not start or (start > 1 and not before:sub(start - 1, start - 1):match("%s")) then
        return nil
    end
    return start, query
end

---@param item conduit.MentionItem
---@return string icon, string? hl
function M.icon(item)
    if item.kind == "special" then
        return "", "Special"
    elseif item.kind == "dir" then
        return "", "Directory"
    end
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
        local icon, hl = devicons.get_icon(vim.fs.basename(item.word), nil, { default = true })
        return icon, hl
    end
    local mini_ok, mini = pcall(require, "mini.icons")
    if mini_ok then
        local icon, hl = mini.get("file", item.word)
        return icon, hl
    end
    return "", nil
end

---@return boolean
local function use_blink()
    local mode = config.options.mentions.completion
    if mode == "native" then
        return false
    elseif mode == "blink" then
        return true
    end
    return package.loaded["blink.cmp"] ~= nil
end

local blink_registered = false

---Register the blink.cmp source for prompt buffers (once).
local function register_blink()
    if blink_registered then
        return
    end
    blink_registered = true
    -- Optional dependency, only required once it's loaded.
    ---@diagnostic disable-next-line: unresolved-require
    local cmp = require("blink.cmp")
    ---@diagnostic disable-next-line: unresolved-require
    local providers = require("blink.cmp.config").sources.providers
    if not providers.conduit then
        cmp.add_source_provider("conduit", { module = "conduit.blink", name = "Conduit", score_offset = 100 })
    end
    cmp.add_filetype_source("conduit_input", "conduit")
end

---Native-popup fallback: refresh the menu on every keystroke after `@`.
local function native_trigger()
    local col = vim.fn.col(".") - 1
    local start, query = M.query(vim.api.nvim_get_current_line():sub(1, col))
    if not start or not query then
        return
    end
    local items = vim.tbl_map(function(i)
        local icon = M.icon(i)
        return {
            word = i.word,
            abbr = icon .. " " .. i.word,
            kind = i.kind,
            menu = i.detail,
            icase = 1,
            equal = 1,
        }
    end, M.items(query))
    vim.fn.complete(start + 1, items)
end

---Set up `@` completion in insert mode in `buf`.
---@param buf integer
function M.attach(buf)
    if use_blink() then
        register_blink()
        -- Keep the menu open while typing a mention, even with `menu.auto_show`
        -- off: blink starts a new context at `/` and `.`, which would hide it.
        vim.api.nvim_create_autocmd("TextChangedI", {
            buffer = buf,
            callback = function()
                local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col(".") - 1)
                if not M.query(before) then
                    return
                end
                -- Deferred: blink hides the menu for the new context after this event.
                vim.defer_fn(function()
                    ---@diagnostic disable-next-line: unresolved-require
                    local cmp = require("blink.cmp")
                    if vim.fn.mode() == "i" and not cmp.is_menu_visible() then
                        cmp.show({ providers = { "conduit" } })
                    end
                end, 20)
            end,
        })
        return
    end
    -- blink.cmp and friends honour this; we drive the native popup ourselves.
    vim.b[buf].completion = false
    vim.bo[buf].completeopt = "menu,menuone,noinsert,popup"
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
        buffer = buf,
        callback = native_trigger,
    })
end

---@class conduit.Mention
---@field name string As written after `@`
---@field special? string Special mention name
---@field rel? string
---@field abs? string
---@field dir? boolean

---Mentions in `text` that refer to something real, in order and deduplicated.
---@param text string
---@param root? string
---@return conduit.Mention[]
function M.parse(text, root)
    root = root or vim.fn.getcwd()
    local out, seen = {}, {}
    for token in (" " .. text):gmatch("%s@(" .. PATH_CHARS .. "+)") do
        -- Allow trailing sentence punctuation: "look at @foo.lua."
        for _, name in ipairs({ token, (token:gsub("[%.,;:!?]+$", "")) }) do
            if M.specials[name] then
                if not seen[name] then
                    seen[name] = true
                    table.insert(out, { name = name, special = name })
                end
                break
            end
            local expanded = name:gsub("^~", vim.env.HOME)
            local abs = vim.startswith(expanded, "/") and expanded or vim.fs.joinpath(root, expanded)
            abs = vim.fs.normalize(abs)
            local stat = vim.uv.fs_stat(abs)
            if stat then
                if not seen[abs] then
                    seen[abs] = true
                    table.insert(out, {
                        name = name,
                        rel = vim.fs.relpath(root, abs) or abs,
                        abs = abs,
                        dir = stat.type == "directory",
                    })
                end
                break
            end
        end
    end
    return out
end

---@param abs string
---@param rel string
---@return string
function M.dir_listing(abs, rel)
    local entries = {}
    for name, type in vim.fs.dir(abs, { depth = 2 }) do
        if not name:match("^%.") and not name:match("/%.") then
            table.insert(entries, type == "directory" and name .. "/" or name)
            if #entries >= M.max_dir_entries then
                table.insert(entries, "…")
                break
            end
        end
    end
    table.sort(entries)
    return ("Directory %s/ contains:\n%s"):format(rel, table.concat(entries, "\n"))
end

---@param mention conduit.Mention
---@param embed boolean Whether the agent accepts embedded resources
---@param ctx conduit.MentionCtx
---@return table? ContentBlock
local function block(mention, embed, ctx)
    if mention.special then
        local text = M.specials[mention.special].resolve(ctx)
        return text and { type = "text", text = ("<context name=%q>\n%s\n</context>"):format(mention.special, text) }
    end
    local abs, rel = mention.abs, mention.rel
    if not abs or not rel then
        return nil
    end
    local uri = vim.uri_from_fname(abs)
    local link = { type = "resource_link", uri = uri, name = rel }
    if not embed then
        return link
    end
    if mention.dir then
        local text = M.dir_listing(abs, rel)
        return { type = "resource", resource = { uri = uri, mimeType = "text/plain", text = text } }
    end
    local stat = vim.uv.fs_stat(abs)
    if stat and stat.size > M.max_embed_bytes then
        return link
    end
    local read = require("conduit.fs").read({ path = abs })
    if not read or read.content:find("\0", 1, true) then
        -- Missing or binary.
        return link
    end
    return { type = "resource", resource = { uri = uri, text = read.content } }
end

---Turn prompt text into ACP content blocks: the text itself, then one block per mention.
---@param text string
---@param agent? { info?: table } Only its capabilities are used, to check for embedded context support
---@param ctx? { root?: string, buf?: integer }
---@return table[]
function M.blocks(text, agent, ctx)
    ctx = ctx or {}
    ---@type conduit.MentionCtx
    local full = { root = ctx.root or vim.fn.getcwd(), buf = ctx.buf or M.last_buf() }
    local caps = agent and agent.info and agent.info.agentCapabilities or {}
    local embed = (caps.promptCapabilities or {}).embeddedContext == true
    local blocks = { { type = "text", text = text } }
    for _, mention in ipairs(M.parse(text, full.root)) do
        local b = block(mention, embed, full)
        if b then
            table.insert(blocks, b)
        end
    end
    return blocks
end

---The last regular buffer the user was in (tracked by plugin/conduit.lua).
---@return integer?
function M.last_buf()
    local buf = vim.g.conduit_last_buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
end

---Forget cached file lists (e.g. after creating files).
function M.reset()
    cache = nil
end

return M
