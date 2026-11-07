--- Pickers: one spec, shown with whichever picker the user has (snacks.nvim,
--- telescope.nvim, fzf-lua, mini.pick) or `vim.ui.select`. Specs can stream in
--- more items (`load`), preview the highlighted item and bind actions to keys.
--- Actions close the picker first; callers reopen it when it should stay up.
local config = require("conduit.config")

local M = {}

---@class conduit.PickerItem
---@field text string What fuzzy matching runs against
---@field segments [string, string?][] Displayed text as `{ text, highlight }` chunks
---@field data any

---@class conduit.PickerAction
---@field key string Key in `<C-x>` notation
---@field desc string
---@field fn fun(item: conduit.PickerItem?)

---@class conduit.PickerSpec
---@field title string
---@field items fun(): conduit.PickerItem[] The items so far
---@field load? fun(done: fun()) Fetch more items; `items()` includes them once `done` runs
---@field query? string Initial query
---@field preview? fun(item: conduit.PickerItem): string[], string? Lines and filetype
---@field on_select fun(item: conduit.PickerItem)
---@field actions? conduit.PickerAction[]

---@alias conduit.PickerProvider fun(spec: conduit.PickerSpec)

---@param item conduit.PickerItem
---@return string
function M.label(item)
    local parts = {}
    for _, seg in ipairs(item.segments) do
        table.insert(parts, seg[1])
    end
    return table.concat(parts)
end

---Run `fn` after the picker has closed and focus is back where it was.
---@param fn fun(...)
---@param ... any
local function later(fn, ...)
    local args = vim.F.pack_len(...)
    vim.schedule(function()
        fn(vim.F.unpack_len(args))
    end)
end

---@param spec conduit.PickerSpec
---@param item conduit.PickerItem
---@return string[] lines, string? filetype
local function preview(spec, item)
    if not spec.preview then
        return {}, nil
    end
    local ok, lines, ft = pcall(spec.preview, item)
    if not ok then
        return { "preview failed: " .. tostring(lines) }, nil
    end
    return lines or {}, ft
end

---@type table<string, conduit.PickerProvider>
local providers = {}

---`vim.ui.select`: waits for `load`, has no preview, and confirms on select.
---Actions aren't reachable here; their commands work on the current thread.
---@param spec conduit.PickerSpec
function providers.select(spec)
    local function show()
        local items = spec.items()
        local query = spec.query and spec.query:lower()
        if query and query ~= "" then
            local matches = vim.tbl_filter(function(item)
                return item.text:lower():find(query, 1, true) ~= nil
            end, items)
            items = #matches > 0 and matches or items
        end
        vim.ui.select(items, { prompt = spec.title, format_item = M.label }, function(item)
            if item then
                spec.on_select(item)
            end
        end)
    end
    if spec.load then
        spec.load(show)
    else
        show()
    end
end

-- The picker plugins are optional and only required once chosen, hence the
-- unresolved-require suppressions below.

---@param spec conduit.PickerSpec
function providers.snacks(spec)
    ---@diagnostic disable-next-line: unresolved-require
    local snacks = require("snacks")
    local function items()
        return vim.tbl_map(function(item)
            return { text = item.text, conduit = item }
        end, spec.items())
    end
    local actions, keys = {}, {}
    for i, action in ipairs(spec.actions or {}) do
        local name = "conduit_" .. i
        actions[name] = {
            desc = action.desc,
            action = function(p, item)
                p:close()
                later(action.fn, item and item.conduit)
            end,
        }
        keys[action.key] = { name, mode = { "n", "i" }, desc = action.desc }
    end
    local picker = snacks.picker.pick({
        title = spec.title,
        pattern = spec.query,
        finder = items,
        format = function(item)
            return item.conduit.segments
        end,
        preview = function(ctx)
            local lines, ft = preview(spec, ctx.item.conduit)
            ctx.preview:reset()
            ctx.preview:set_lines(lines)
            if ft then
                ctx.preview:highlight({ ft = ft })
            end
        end,
        confirm = function(p, item)
            p:close()
            if item then
                later(spec.on_select, item.conduit)
            end
        end,
        actions = actions,
        win = { input = { keys = keys }, list = { keys = keys } },
    })
    if spec.load then
        spec.load(function()
            if picker and not picker.closed then
                picker:find()
            end
        end)
    end
end

---@param spec conduit.PickerSpec
function providers.telescope(spec)
    ---@diagnostic disable-next-line: unresolved-require
    local pickers = require("telescope.pickers")
    ---@diagnostic disable-next-line: unresolved-require
    local finders = require("telescope.finders")
    ---@diagnostic disable-next-line: unresolved-require
    local previewers = require("telescope.previewers")
    ---@diagnostic disable-next-line: unresolved-require
    local conf = require("telescope.config").values
    ---@diagnostic disable-next-line: unresolved-require
    local actions = require("telescope.actions")
    ---@diagnostic disable-next-line: unresolved-require
    local state = require("telescope.actions.state")

    local function finder()
        return finders.new_table({
            results = spec.items(),
            entry_maker = function(item)
                return {
                    value = item,
                    ordinal = item.text,
                    display = function()
                        local text, hls, col = {}, {}, 0
                        for _, seg in ipairs(item.segments) do
                            table.insert(text, seg[1])
                            if seg[2] then
                                table.insert(hls, { { col, col + #seg[1] }, seg[2] })
                            end
                            col = col + #seg[1]
                        end
                        return table.concat(text), hls
                    end,
                }
            end,
        })
    end

    local picker = pickers.new({}, {
        prompt_title = spec.title,
        default_text = spec.query,
        finder = finder(),
        sorter = conf.generic_sorter({}),
        previewer = spec.preview and previewers.new_buffer_previewer({
            define_preview = function(self, entry)
                local lines, ft = preview(spec, entry.value)
                vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
                if ft then
                    ---@diagnostic disable-next-line: unresolved-require
                    require("telescope.previewers.utils").highlighter(self.state.bufnr, ft)
                end
            end,
        }) or nil,
        attach_mappings = function(bufnr, map)
            local function selected()
                local entry = state.get_selected_entry()
                return entry and entry.value
            end
            actions.select_default:replace(function()
                local item = selected()
                actions.close(bufnr)
                if item then
                    later(spec.on_select, item)
                end
            end)
            for _, action in ipairs(spec.actions or {}) do
                map({ "i", "n" }, action.key, function()
                    local item = selected()
                    actions.close(bufnr)
                    later(action.fn, item)
                end, { desc = action.desc })
            end
            return true
        end,
    })
    picker:find()
    if spec.load then
        spec.load(function()
            if picker.prompt_bufnr and vim.api.nvim_buf_is_valid(picker.prompt_bufnr) then
                picker:refresh(finder(), { reset_prompt = false })
            end
        end)
    end
end

---`<C-d>` → `ctrl-d`, for fzf's --bind.
---@param key string
---@return string
local function fzf_key(key)
    local mod, k = key:match("^<([CcMmAa])%-(.+)>$")
    if not mod or not k then
        return key:lower()
    end
    return (mod:lower() == "c" and "ctrl-" or "alt-") .. k:lower()
end

---fzf-lua: waits for `load`, then shows numbered lines (the number maps back to
---the item and is hidden from the display).
---@param spec conduit.PickerSpec
function providers.fzf(spec)
    ---@diagnostic disable-next-line: unresolved-require
    local fzf = require("fzf-lua")
    local function show()
        local items = spec.items()
        ---@param selected? string[]
        ---@return conduit.PickerItem?
        local function lookup(selected)
            local idx = selected and selected[1] and tonumber(selected[1]:match("^(%d+)\t"))
            return idx and items[idx] or nil
        end
        local fzf_actions = {
            ["default"] = function(selected)
                local item = lookup(selected)
                if item then
                    later(spec.on_select, item)
                end
            end,
        }
        for _, action in ipairs(spec.actions or {}) do
            fzf_actions[fzf_key(action.key)] = function(selected)
                later(action.fn, lookup(selected))
            end
        end
        local lines = {}
        for i, item in ipairs(items) do
            lines[i] = ("%d\t%s"):format(i, M.label(item))
        end
        fzf.fzf_exec(lines, {
            prompt = spec.title .. "> ",
            query = spec.query,
            fzf_opts = { ["--delimiter"] = "\t", ["--with-nth"] = "2..", ["--no-multi"] = true },
            preview = spec.preview and function(selected)
                local item = lookup(selected)
                return item and (preview(spec, item)) or {}
            end or nil,
            actions = fzf_actions,
        })
    end
    if spec.load then
        spec.load(show)
    else
        show()
    end
end

---@param spec conduit.PickerSpec
function providers.mini(spec)
    ---@diagnostic disable-next-line: unresolved-require
    local pick = require("mini.pick")
    -- mini.pick deep-copies its items, so they only carry an index into `all`.
    ---@type conduit.PickerItem[]
    local all = {}
    local function items()
        all = spec.items()
        local out = {}
        for i, item in ipairs(all) do
            out[i] = { text = M.label(item), idx = i }
        end
        return out
    end
    ---@param entry? { idx: integer }
    ---@return conduit.PickerItem?
    local function lookup(entry)
        return entry and all[entry.idx] or nil
    end
    local mappings = {}
    for i, action in ipairs(spec.actions or {}) do
        mappings["conduit_" .. i] = {
            char = action.key,
            func = function()
                local matches = pick.get_picker_matches()
                later(action.fn, lookup(matches and matches.current))
                return true -- stop the picker
            end,
        }
    end
    if spec.load then
        spec.load(function()
            if pick.is_picker_active() then
                pick.set_picker_items(items())
            end
        end)
    end
    if spec.query and spec.query ~= "" then
        vim.schedule(function()
            if pick.is_picker_active() then
                pick.set_picker_query(vim.split(spec.query, ""))
            end
        end)
    end
    pick.start({
        source = {
            name = spec.title,
            items = items(),
            preview = function(buf, entry)
                local item = lookup(entry)
                if not item then
                    return
                end
                local lines, ft = preview(spec, item)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
                if ft then
                    pcall(vim.treesitter.start, buf, vim.treesitter.language.get_lang(ft) or ft)
                end
            end,
            choose = function(entry)
                local item = lookup(entry)
                if item then
                    later(spec.on_select, item)
                end
            end,
        },
        mappings = mappings,
    })
end

---@type [string, string, conduit.PickerProvider][] Detection order: module, name, provider
local DETECT = {
    { "snacks", "snacks", providers.snacks },
    { "telescope", "telescope", providers.telescope },
    { "fzf-lua", "fzf_lua", providers.fzf },
    { "mini.pick", "mini_pick", providers.mini },
}

---The provider `ui.picker` selects: "auto" uses the first picker plugin that's
---loaded, a name forces one, and a function is used as is.
---@return conduit.PickerProvider
function M.provider()
    local choice = config.options.ui.picker
    if type(choice) == "function" then
        return choice
    elseif choice == "select" then
        return providers.select
    end
    for _, entry in ipairs(DETECT) do
        local module, name, provider = entry[1], entry[2], entry[3]
        if choice == name then
            if pcall(require, module) then
                return provider
            end
            vim.notify(("[conduit] picker %q isn't installed; using vim.ui.select"):format(name), vim.log.levels.WARN)
            return providers.select
        elseif choice == "auto" and package.loaded[module] then
            -- snacks can be loaded with its picker disabled.
            local loaded = package.loaded[module] --[[@as table]]
            if module ~= "snacks" or loaded.picker then
                return provider
            end
        end
    end
    return providers.select
end

---Show `spec` in the configured picker.
---@param spec conduit.PickerSpec
function M.pick(spec)
    local provider = M.provider()
    local ok, err = pcall(provider, spec)
    if not ok and provider ~= providers.select then
        require("conduit.log").warn("picker failed, falling back to vim.ui.select: " .. tostring(err))
        providers.select(spec)
    elseif not ok then
        error(err)
    end
end

return M
