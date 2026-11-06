--- Newline-delimited JSON-RPC 2.0 over a child process' stdio.
---@class conduit.Rpc
---@field proc vim.SystemObj
---@field next_id integer
---@field pending table<integer, fun(err: table?, result: any)>
---@field closed boolean
---@field buf string Unparsed stdout
---@field opts conduit.RpcOpts
local Rpc = {}
Rpc.__index = Rpc

---@class conduit.RpcOpts
---@field cwd? string
---@field env? table<string, string>
---@field on_request? fun(method: string, params: any, respond: fun(err: table?, result: any))
---@field on_notification? fun(method: string, params: any)
---@field on_stderr? fun(data: string)
---@field on_exit? fun(code: integer, signal: integer)

local function decode(line)
    local options = {
        luanil = {
            object = true,
            array = true,
        },
    }
    return pcall(vim.json.decode, line, options)
end

---@param cmd string[]
---@param opts conduit.RpcOpts
---@return conduit.Rpc?, string?
function Rpc.start(cmd, opts)
    local table = {
        next_id = 0,
        pending = {},
        buf = "",
        opts = opts,
        closed = false
    }
    local self = setmetatable(table, Rpc)
    local ok, proc = pcall(vim.system, cmd, {
        cwd = opts.cwd,
        env = opts.env,
        stdin = true,
        stdout = function(_, data)
            if data then
                vim.schedule(function()
                    self:_on_stdout(data)
                end)
            end
        end,
        stderr = function(_, data)
            if data and opts.on_stderr then
                vim.schedule(function()
                    opts.on_stderr(data)
                end)
            end
        end,
    }, function(obj)
        vim.schedule(function()
            self:_on_exit(obj.code, obj.signal)
        end)
    end)
    if not ok then
        return nil, tostring(proc)
    end
    self.proc = proc
    return self
end

function Rpc:_send(msg)
    if self.closed then
        return
    end
    msg.jsonrpc = "2.0"
    pcall(self.proc.write, self.proc, vim.json.encode(msg) .. "\n")
end

---@param method string
---@param params? table
---@param cb? fun(err: table?, result: any)
function Rpc:request(method, params, cb)
    if self.closed then
        if cb then
            cb({ code = -32603, message = "agent process is not running" })
        end
        return
    end
    self.next_id = self.next_id + 1
    local id = self.next_id
    self.pending[id] = cb or function() end
    self:_send({ id = id, method = method, params = params or vim.empty_dict() })
end

---@param method string
---@param params? table
function Rpc:notify(method, params)
    self:_send({ method = method, params = params or vim.empty_dict() })
end

function Rpc:_on_stdout(data)
    self.buf = self.buf .. data
    while true do
        local nl = self.buf:find("\n", 1, true)
        if not nl then
            break
        end
        local line = self.buf:sub(1, nl - 1):gsub("\r$", "")
        self.buf = self.buf:sub(nl + 1)
        if line ~= "" then
            local ok, msg = decode(line)
            if ok and type(msg) == "table" then
                self:_dispatch(msg)
            elseif self.opts.on_stderr then
                -- Agents sometimes leak logs onto stdout; surface them as stderr.
                self.opts.on_stderr(line)
            end
        end
    end
end

function Rpc:_dispatch(msg)
    if msg.method and msg.id ~= nil then
        local id = msg.id
        local responded = false
        local function respond(err, result)
            if responded then
                return
            end
            responded = true
            if err then
                self:_send({ id = id, error = err })
            else
                self:_send({ id = id, result = result == nil and vim.NIL or result })
            end
        end
        if not self.opts.on_request then
            return respond({ code = -32601, message = "Method not found: " .. msg.method })
        end
        local ok, err = pcall(self.opts.on_request, msg.method, msg.params or {}, respond)
        if not ok then
            respond({ code = -32603, message = tostring(err) })
        end
    elseif msg.method then
        if self.opts.on_notification then
            self.opts.on_notification(msg.method, msg.params or {})
        end
    elseif msg.id ~= nil then
        local cb = self.pending[msg.id]
        self.pending[msg.id] = nil
        if cb then
            cb(msg.error, msg.result)
        end
    end
end

function Rpc:_on_exit(code, signal)
    self.closed = true
    local pending = self.pending
    self.pending = {}
    for _, cb in pairs(pending) do
        cb({ code = -32603, message = ("agent exited (code %d)"):format(code) })
    end
    if self.opts.on_exit then
        self.opts.on_exit(code, signal)
    end
end

function Rpc:stop()
    if self.closed then
        return
    end
    pcall(self.proc.write, self.proc, nil)
    pcall(self.proc.kill, self.proc, 15)
end

return Rpc
