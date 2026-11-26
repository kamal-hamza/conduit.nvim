--- conduit.nvim: an ACP agent in Neovim, used inline. Select lines, say what you
--- want: edits land in the file (as hunks to review), explanations open in the
--- sidebar. Everything is kept in the history, and the sandbox decides what the
--- agent may touch and run.
local config = require("conduit.config")

---@class conduit.Api
local M = {}

M.version = "0.2.0"

---@type table<string, conduit.Agent>
M.agents = {}

---@param opts? table
function M.setup(opts)
    config.setup(opts)
end

---Get (creating if needed) the agent called `name`, or the default agent.
---@param name? string
---@return conduit.Agent?
function M.agent(name)
    name = name or config.options.default_agent
    if not M.agents[name] then
        local spec = config.options.agents[name]
        if not spec then
            vim.notify(("[conduit] unknown agent %q"):format(name), vim.log.levels.ERROR)
            return nil
        end
        M.agents[name] = require("conduit.agent").new(name, spec)
    end
    return M.agents[name]
end

---@return string
local function inline_agent()
    return config.options.inline.agent or config.options.default_agent
end

---Make an inline request about lines `line1`..`line2` of the current buffer:
---the agent rewrites them in place or answers in the sidebar.
---@param line1 integer
---@param line2 integer
---@param instruction? string Prompted for when omitted
---@param mode? conduit.InlineMode "auto" (default: the agent decides), "edit" or "ask"
---@return conduit.InlineJob? job When `instruction` is given
function M.inline(line1, line2, instruction, mode)
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    if vim.bo[buf].filetype == "conduit" then
        return vim.notify("[conduit] make requests from a file, not the sidebar (f follows up)", vim.log.levels.INFO)
    end
    local function run(text, chosen, overrides)
        local agent = M.agent(inline_agent())
        if agent then
            return require("conduit.inline").run({
                agent = agent,
                buf = buf,
                win = win,
                line1 = line1,
                line2 = line2,
                instruction = text,
                mode = chosen or mode,
                options = overrides,
            })
        end
    end
    if instruction and instruction ~= "" then
        local text, chosen = require("conduit.ui.prompt").parse_prefix(instruction, mode or "auto")
        return run(text, chosen)
    end
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
    local lines = line1 == line2 and tostring(line1) or ("%d-%d"):format(line1, line2)
    local agent_name = inline_agent()
    require("conduit.ui.prompt").open({
        title = name ~= "" and ("%s:%s"):format(name, lines) or ("lines " .. lines),
        agent = agent_name,
        commands = function()
            -- No session yet: the agent's last known list, if it has run.
            local agent = M.agents[agent_name]
            return agent and agent:get_commands() or {}
        end,
        options = function()
            return require("conduit.inline").request_options(M.agents[agent_name])
        end,
        mode = mode or "auto",
        anchor = { win = win, first = line1 - 1, last = line2 - 1 },
        on_submit = run,
    })
end

---Inline question about lines `line1`..`line2`, answered in the sidebar.
---@param line1 integer
---@param line2 integer
---@param question? string Prompted for when omitted
function M.ask(line1, line2, question)
    M.inline(line1, line2, question, "ask")
end

---Inline edit of lines `line1`..`line2`, applied in place.
---@param line1 integer
---@param line2 integer
---@param instruction? string Prompted for when omitted
function M.edit(line1, line2, instruction)
    M.inline(line1, line2, instruction, "edit")
end

---Focus the answer sidebar (opening it on the latest answer). Answers never
---take focus on their own; this is how you get into one.
---@return boolean focused
function M.answer()
    return require("conduit.ui.sidebar").focus()
end

---Open the sidebar on the latest answer, or close it.
function M.sidebar()
    require("conduit.ui.sidebar").toggle()
end

---Browse the history: answers, edits and the agent's changes to files. Opens on
---the current buffer's entries (or the project's when it has none).
---@param opts? { scope?: "buffer"|"project", qf?: boolean } `qf` sends the entries to the quickfix list
function M.history(opts)
    opts = opts or {}
    if opts.qf then
        local history = require("conduit.history")
        local entries = history.load()
        if opts.scope ~= "project" then
            local file = vim.api.nvim_buf_get_name(0)
            local mine = vim.tbl_filter(function(e)
                return e.file == file
            end, entries)
            entries = #mine > 0 and mine or entries
        end
        return history.to_qf(entries)
    end
    require("conduit.ui.history_float").open({ scope = opts.scope })
end

---List the agent's changes waiting for review in the quickfix list, or turn
---review on or off (`action = "toggle"`).
---@param action? "toggle"
function M.review(action)
    local review = require("conduit.review")
    if action == "toggle" then
        review.toggle()
        return
    end
    local items = review.qflist()
    if #items == 0 then
        return vim.notify("[conduit] no agent changes to review", vim.log.levels.INFO)
    end
    vim.fn.setqflist({}, " ", { title = "conduit review", items = items })
    vim.cmd("botright copen")
end

---@param action "accept"|"reject"
---@param all? boolean
local function review_files(action, all)
    local review = require("conduit.review")
    if all and action == "accept" then
        return review.accept_all()
    elseif all then
        return review.reject_all()
    end
    local name = vim.api.nvim_buf_get_name(0)
    local path = name ~= "" and require("conduit.fs").canonical(name)
    if not path or not review.files[path] then
        return vim.notify("[conduit] no agent changes to review in this buffer", vim.log.levels.INFO)
    end
    review[action](path)
end

---Accept the agent's changes to the current file, or to every file.
---@param all? boolean
function M.accept(all)
    review_files("accept", all)
end

---Reject the agent's changes to the current file, or to every file.
---@param all? boolean
function M.reject(all)
    review_files("reject", all)
end

---Pick or set a session option for inline requests, e.g. `M.option("model", "opus")`.
---It becomes the default for new requests (`inline.options`).
---@param key? string Option id or category (`model`, `effort`, `mode`, ...)
---@param value? string
function M.option(key, value)
    local options = require("conduit.options")
    local agent = M.agent(inline_agent())
    if not agent then
        return
    end
    local list = require("conduit.inline").request_options(agent)
    if #list == 0 then
        return vim.notify(
            "[conduit] make a request first: the agent lists its options per session",
            vim.log.levels.INFO
        )
    end
    local function set(option, v)
        local sandbox = require("conduit.sandbox")
        local is_mode = option.category == "mode" or option.legacy == "mode" or option.id == "mode"
        if is_mode and sandbox.enabled() and not config.options.sandbox.bypass and sandbox.is_bypass(v) then
            return vim.notify(
                ("[conduit] mode %q skips every permission check; set sandbox.bypass = true to allow it"):format(v),
                vim.log.levels.WARN
            )
        end
        config.options.inline.options[option.id] = v
        vim.notify(("[conduit] %s = %s for new requests"):format(option.name or option.id, v), vim.log.levels.INFO)
    end
    local function pick_value(option)
        if value then
            return set(option, value)
        end
        vim.ui.select(option.choices, {
            prompt = option.name or option.id,
            format_item = function(c)
                return (c.value == option.current and "● " or "  ") .. (c.name or c.value)
            end,
        }, function(choice)
            if choice then
                set(option, choice.value)
            end
        end)
    end
    if key then
        local option = options.find(list, key)
        if not option then
            return vim.notify(("[conduit] %s has no %q option"):format(agent.name, key), vim.log.levels.WARN)
        end
        return pick_value(option)
    end
    vim.ui.select(list, {
        prompt = "Option",
        format_item = function(o)
            return ("%s: %s"):format(o.name or o.id, options.current_name(o) or "")
        end,
    }, function(option)
        if option then
            pick_value(option)
        end
    end)
end

---What the sandbox allows, as lines (for `:Conduit sandbox`).
---@return string[]
function M.sandbox_info()
    local sandbox = require("conduit.sandbox")
    local cfg = config.options.sandbox
    if not sandbox.enabled() then
        return { "sandbox: off (sandbox.enabled = false)" }
    end
    local lines = {
        "roots: " .. table.concat(
            vim.tbl_map(function(r)
                return vim.fn.fnamemodify(r, ":~")
            end, sandbox.roots()),
            ", "
        ),
        "outside the roots: " .. cfg.outside,
        ("commands: %d allowed, %d denied patterns, otherwise %s"):format(
            #cfg.commands.allow,
            #cfg.commands.deny,
            cfg.commands.default
        ),
    }
    if cfg.isolation.enabled then
        local backend = sandbox.backend()
        table.insert(
            lines,
            ("isolation: %s, network %s, env %s"):format(
                backend or ("unavailable (" .. cfg.isolation.unavailable .. ")"),
                cfg.isolation.network and "on" or "off",
                cfg.isolation.env
            )
        )
    else
        table.insert(lines, "isolation: off")
    end
    table.insert(lines, "bypass mode: " .. (cfg.bypass and "allowed" or "blocked"))
    return lines
end

---Cancel running inline requests.
function M.cancel()
    require("conduit.inline").cancel()
end

---Stop all agent processes.
function M.stop()
    for _, agent in pairs(M.agents) do
        agent:stop()
    end
end

return M
