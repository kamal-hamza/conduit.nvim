--- Surfaces: adapters that draw component output into Neovim UI. Spans become
--- statusline strings (winbars, statuslines), extmark chunks (virtual text and
--- lines, overlays), float titles, or the lines of a scratch buffer.
local M = {}

---@param s string
---@return string
local function escape(s)
    return (s:gsub("%%", "%%%%"))
end

---Spans as a statusline string (`%#Group#text`). `raw` spans pass through.
---@param spans conduit.Spans
---@return string
function M.statusline(spans)
    local out = {}
    for _, span in ipairs(spans) do
        local text = span[1]
        if not span.raw then
            text = escape(text)
            if span[2] then
                text = ("%%#%s#%s%%*"):format(span[2], text)
            end
        end
        out[#out + 1] = text
    end
    return table.concat(out)
end

---Spans as `{ text, hl }` chunks for extmarks and float titles.
---@param spans conduit.Spans
---@return [string, string?][]
function M.chunks(spans)
    local out = {}
    for _, span in ipairs(spans) do
        if not span.raw then
            out[#out + 1] = { span[1], span[2] }
        end
    end
    return out
end

---A window's winbar. Output is `conduit.Spans`.
---@param win fun(): integer? The window, looked up on every draw
---@return conduit.Surface
function M.winbar(win)
    return {
        draw = function(spans)
            local w = win()
            if w and vim.api.nvim_win_is_valid(w) then
                vim.wo[w].winbar = M.statusline(spans)
            end
        end,
        clear = function()
            local w = win()
            if w and vim.api.nvim_win_is_valid(w) then
                vim.wo[w].winbar = ""
            end
        end,
    }
end

---One extmark in `buf`. Output is `conduit.Spans` for virtual text, or a list
---of them for virtual lines (`opts.lines`).
---@param buf integer
---@param ns integer
---@param pos fun(): integer?, integer? Row (0-based) and column; nil hides the mark
---@param opts? vim.api.keyset.set_extmark Extra extmark options, e.g. `virt_text_pos`
---@param lines? boolean Draw virtual lines instead of virtual text
---@return conduit.Surface
function M.extmark(buf, ns, pos, opts, lines)
    local id ---@type integer?
    local function clear()
        if id and vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
        end
        id = nil
    end
    return {
        valid = function()
            return vim.api.nvim_buf_is_valid(buf)
        end,
        draw = function(out)
            local row, col = pos()
            if not row then
                return clear()
            end
            local spec = vim.tbl_extend("force", opts or {}, { id = id })
            if lines then
                spec.virt_lines = vim.tbl_map(M.chunks, out)
            else
                spec.virt_text = M.chunks(out)
            end
            local ok, new = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col or 0, spec)
            if ok then
                id = new
            end
        end,
        clear = clear,
    }
end

---A float's title or footer. Output is `conduit.Spans`.
---@param win fun(): integer?
---@param field "title"|"footer"
---@param pos? "left"|"center"|"right"
---@return conduit.Surface
function M.float_title(win, field, pos)
    local function set(chunks)
        local w = win()
        if not w or not vim.api.nvim_win_is_valid(w) then
            return
        end
        local cfg = vim.api.nvim_win_get_config(w)
        -- Titles and footers need a top/bottom border.
        if cfg.border == nil or cfg.border == "none" or cfg.border == "" then
            return
        end
        vim.api.nvim_win_set_config(w, { [field] = chunks, [field .. "_pos"] = pos or "left" })
    end
    return {
        draw = function(spans)
            set(M.chunks(spans))
        end,
        clear = function()
            set("")
        end,
    }
end

---The whole content of a scratch buffer. Output is a list of `conduit.Spans`,
---one per line; highlights are applied with extmarks in `ns`.
---@param buf integer
---@param ns integer
---@return conduit.Surface
function M.buffer(buf, ns)
    return {
        valid = function()
            return vim.api.nvim_buf_is_valid(buf)
        end,
        draw = function(lines)
            local text, marks = {}, {}
            for row, spans in ipairs(lines) do
                local col, parts = 0, {}
                for _, span in ipairs(spans) do
                    local s = span.raw and "" or span[1]:gsub("\n", " ")
                    parts[#parts + 1] = s
                    if span[2] and #s > 0 then
                        marks[#marks + 1] = { row - 1, col, col + #s, span[2] }
                    end
                    col = col + #s
                end
                text[row] = table.concat(parts)
            end
            local modifiable = vim.bo[buf].modifiable
            vim.bo[buf].modifiable = true
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
            vim.bo[buf].modifiable = modifiable
            vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            for _, m in ipairs(marks) do
                vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
            end
        end,
    }
end

return M
