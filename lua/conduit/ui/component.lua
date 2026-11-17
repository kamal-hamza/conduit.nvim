--- React-style components. A component is a pure `render(props)` that returns
--- spans (or lines of spans); a surface (see `conduit.ui.surface`) draws them.
--- Data flows one way: props come from models (`conduit.ui.status`, the headless
--- models in `conduit.ui.headless`), and nothing reaches back up except the
--- callbacks a model hands down.
---
--- Users can replace or add components with `ui.components`:
--- `components = { Chip = function(props, builtin) return builtin(props) end }`.
local M = {}

---A run of text with an optional highlight group.
---@class conduit.Span
---@field [1] string
---@field [2]? string
---@field click? fun() Mouse handler, used by winbar surfaces when `ui.mouse` is on
---@field raw? boolean Statusline code (e.g. `%=`), passed through by statusline surfaces and dropped elsewhere

---@alias conduit.Spans conduit.Span[]

---@class conduit.ComponentSpec
---@field name string
---@field render fun(props: table): table `conduit.Spans`, or `conduit.Spans[]` for block components

---@type table<string, conduit.ComponentSpec>
local registry = {}

---Register a component.
---@param spec conduit.ComponentSpec
---@return conduit.ComponentSpec
function M.define(spec)
    registry[spec.name] = spec
    return spec
end

---Render component `name` with `props`, honouring `ui.components` overrides. An
---override that errors falls back to the built-in, so a broken config can't
---break the chat.
---@param name string
---@param props? table
---@return table
function M.render(name, props)
    props = props or {}
    if not registry.Chip then
        require("conduit.ui.components")
    end
    local spec = registry[name]
    local override = (require("conduit.config").options.ui.components or {})[name]
    if override then
        local builtin = spec and spec.render or function()
            return {}
        end
        local ok, out = pcall(override, props, builtin)
        if ok and type(out) == "table" then
            return out
        end
        require("conduit.log").warn(("ui.components.%s failed: %s"):format(name, tostring(out)))
    end
    if not spec then
        error(("unknown component %q"):format(name))
    end
    return spec.render(props)
end

---Plain text of rendered spans (for tests and width calculations).
---@param spans conduit.Spans
---@return string
function M.text(spans)
    local parts = {}
    for _, span in ipairs(spans) do
        if not span.raw then
            parts[#parts + 1] = span[1]
        end
    end
    return table.concat(parts)
end

---Cheap identity of a render result, so mounts only redraw when it changes.
---@param out table
---@return string
local function key(out)
    local parts = {}
    local function walk(t)
        for _, v in ipairs(t) do
            if type(v) == "table" then
                if type(v[1]) == "string" then
                    parts[#parts + 1] = v[1] .. "\1" .. (v[2] or "") .. (v.click and "\2" or "")
                else
                    parts[#parts + 1] = "\3"
                    walk(v)
                end
            end
        end
    end
    walk(out)
    return table.concat(parts, "\0")
end

---Where a component is drawn.
---@class conduit.Surface
---@field draw fun(out: table)
---@field clear? fun()
---@field valid? fun(): boolean False once the window or buffer is gone

---A component mounted on a surface. It re-renders on `update()` and whenever the
---status model changes, and only redraws when the output differs.
---@class conduit.Mount
---@field name string
---@field surface conduit.Surface
---@field props fun(): table?
---@field last? string
---@field sub? integer Status subscription
local Mount = {}
Mount.__index = Mount

---@param surface conduit.Surface
---@param name string Component name
---@param props fun(): table? Returns the props; nil clears the surface
---@return conduit.Mount
function M.mount(surface, name, props)
    local self = setmetatable({ name = name, surface = surface, props = props }, Mount)
    self.sub = require("conduit.ui.status").subscribe(function()
        self:update()
    end)
    self:update()
    return self
end

---Re-render now. Redraws only if the output changed (or `force`).
---@param force? boolean
function Mount:update(force)
    if self.surface.valid and not self.surface.valid() then
        return self:unmount()
    end
    local props = self.props()
    if not props then
        if self.last ~= nil and self.surface.clear then
            self.surface.clear()
        end
        self.last = nil
        return
    end
    local out = M.render(self.name, props)
    local k = key(out)
    if force or k ~= self.last then
        self.last = k
        self.surface.draw(out)
    end
end

function Mount:unmount()
    if self.sub then
        require("conduit.ui.status").unsubscribe(self.sub)
        self.sub = nil
    end
    if self.surface.clear and (not self.surface.valid or self.surface.valid()) then
        self.surface.clear()
    end
    self.last = nil
end

return M
