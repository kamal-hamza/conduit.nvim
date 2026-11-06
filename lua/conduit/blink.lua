--- blink.cmp source for `@` mentions in conduit prompt buffers. Registered
--- automatically when blink.cmp is loaded; see `mentions.attach`.
local mentions = require("conduit.mentions")

-- LSP CompletionItemKind values.
local kinds = { file = 17, buffer = 17, dir = 19, special = 18 }

local Source = {}
Source.__index = Source

function Source.new(opts)
    return setmetatable({ opts = opts or {} }, Source)
end

function Source.enabled(_)
    return vim.bo.filetype == "conduit_input"
end

function Source.get_trigger_characters(_)
    return { "@" }
end

function Source.get_completions(_, ctx, callback)
    local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
    local start, query = mentions.query(ctx.line:sub(1, col))
    if not start or not query then
        return callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    end
    -- Replace everything typed after the `@` (0-based byte columns).
    local range = { start = { line = row, character = start }, ["end"] = { line = row, character = col } }
    local items = {}
    for i, item in ipairs(mentions.items(query)) do
        local icon, hl = mentions.icon(item)
        table.insert(items, {
            label = item.word,
            kind = kinds[item.kind],
            kind_icon = icon,
            kind_hl = hl,
            filterText = item.word,
            -- Keep conduit's ranking among equally good fuzzy matches.
            sortText = ("%04d"):format(i),
            textEdit = { newText = item.word, range = range },
            data = item,
        })
    end
    -- The query can include `/` and `.`, which blink doesn't treat as keyword
    -- characters, so ask again as the user types.
    callback({ is_incomplete_forward = true, is_incomplete_backward = true, items = items })
end

---Preview: the head of a file, a directory listing, or what a special mention sends.
function Source.resolve(_, item, callback)
    local data = item.data or {}
    local doc
    if data.kind == "special" then
        doc = ("**@%s**: %s"):format(data.word, mentions.specials[data.word].description)
    elseif data.kind == "dir" then
        doc = mentions.dir_listing(data.path:gsub("/$", ""), data.word:gsub("/$", ""))
    elseif data.path then
        local f = io.open(data.path, "r")
        if f then
            local head = f:read(4096) or ""
            f:close()
            if not head:find("\0", 1, true) then
                local ft = vim.filetype.match({ filename = data.path }) or ""
                local lines = vim.list_slice(vim.split(head, "\n", { plain = true }), 1, 40)
                doc = ("```%s\n%s\n```"):format(ft, table.concat(lines, "\n"))
            end
        end
    end
    callback(vim.tbl_extend("force", item, {
        documentation = doc and { kind = "markdown", value = doc } or nil,
    }))
end

---After accepting a directory, reopen the menu to keep drilling down.
function Source.execute(_, _, item, callback, default)
    default()
    callback()
    if item.data and item.data.kind == "dir" then
        vim.schedule(function()
            ---@diagnostic disable-next-line: unresolved-require
            require("blink.cmp").show({ providers = { "conduit" } })
        end)
    end
end

return Source
