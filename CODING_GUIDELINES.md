# Coding guidelines

How Lua is written in conduit.nvim. The goal is code that reads like the
surrounding code, type-checks cleanly under emmylua_ls, and behaves well inside
someone else's editor.

## Formatting

StyLua owns formatting (`.stylua.toml`): 4-space indents, 120 columns, double
quotes, parentheses on every call. Run `make format`; don't hand-format against
it. `.editorconfig` covers non-Lua files (2 spaces for YAML/JSON, tabs in the
Makefile).

## Modules

- One module per file. Return a single table, conventionally `M`:

  ```lua
  local M = {}

  function M.do_thing() end

  return M
  ```

- No globals. The only globals are `vim` and, in tests, `test` and `wait_for`.
- Require dependencies at the top of the file when they're always needed.
  Require lazily, inside the function, when the module is only needed on some
  paths or would create a cycle (`require("conduit.ui.permission").ask(...)`).
- `plugin/conduit.lua` runs at startup for every user, so it must stay cheap:
  define commands and autocmds and defer everything else to `require` inside
  callbacks.

## Classes

Use metatables with `__index`, and a `new` constructor:

```lua
---@class conduit.Thing
---@field name string
---@field count integer
local Thing = {}
Thing.__index = Thing

---@param name string
---@return conduit.Thing
function Thing.new(name)
    return setmetatable({ name = name, count = 0 }, Thing)
end

function Thing:bump()
    self.count = self.count + 1
end
```

- Use `:` for methods that use `self` and `.` for everything else. When an
  external API calls your function with `:` but you don't need `self` (blink
  sources, for example), declare it with `.` and an explicit `_` first parameter.
- Prefix private methods and fields with `_` (`Agent:_on_exit`).

## Naming

- `snake_case` for locals, functions, fields and module names.
- `PascalCase` for class tables (`Agent`, `Chat`) and `UPPER_CASE` for
  constants (`PROTOCOL_VERSION`, `KEYS_HINT`).
- Type names are namespaced: `conduit.Agent`, `conduit.InlineOpts`.
- Neovim handles say what they are: `buf`, `win`, `ns`, `row` (0-based), `lnum`
  or `line1` (1-based). Never mix 0- and 1-based indices without a comment.

## Type annotations

We use LuaCATS / EmmyLua annotations, and **code must not add emmylua_ls
diagnostics**. Treat its warnings as bugs; several have been real ones (an rpc
handle that's nil after the agent exits, an untyped field hiding a typo).

- Annotate every public function's parameters and returns, and every class's
  fields, including ones only set later (`---@field marks {...}`).
- Mark optional values with `?` and handle them. Prefer narrowing over casts:

  ```lua
  local sid = assert(self.session_id)        -- invariant: must exist here
  local answer = self.answer
  if not answer then return end              -- may legitimately be missing
  ```

- Use `--[[@as T]]` only when the type system can't express a fact you know
  (e.g. `vim.fn.stdpath("log") --[[@as string]]`).
- Annotate a parameter with the narrowest type it needs
  (`{ info?: table }` rather than `conduit.Agent` when only `info` is read).
- `---@diagnostic disable-next-line: <code>` is allowed only for optional
  dependencies (`unresolved-require` on blink.cmp/markview), with a comment
  saying why. Never disable diagnostics for a whole file.

## Nil, errors and results

- Async results use callbacks shaped `cb(err, result)`, where `err` is a
  `string?` for callers and an ACP/JSON-RPC error table (`{ code, message }`)
  at the transport layer. Convert at the boundary (`errmsg` in `agent.lua`).
- Functions that can fail synchronously return `result, err` (`fs.read`).
- Don't throw for expected failures (missing executable, agent exited, file not
  found). Return or report them. `error()`/`assert()` are for programmer
  errors and invariants.
- Wrap calls into optional or user-supplied code in `pcall`.

## Async and the event loop

- Callbacks from `vim.system`, `vim.uv` timers and other luv handles run in a
  fast context where most of the API is unavailable. Hop back with
  `vim.schedule` (or `vim.schedule_wrap`) before touching buffers, windows or
  options.
- Use `vim.defer_fn` for debouncing and for "after the current event finishes"
  work. Document why when the delay matters (see `mentions.attach`).
- Never block the UI. `vim.system():wait()` is acceptable only with a short
  timeout and for cheap commands (`git ls-files`), and the result should be cached.

## Buffers, windows and UI

- Scratch buffers: `nvim_create_buf(false, true)`, set `bufhidden`, give them a
  `conduit*` filetype, and disable diagnostics (`vim.diagnostic.enable(false,
  { bufnr = buf })`).
- Read-only buffers stay `modifiable = false`; toggle it only around
  programmatic edits (see `Chat:_edit`).
- Track positions that must survive edits with extmarks in a module namespace,
  not stored line numbers.
- Keymaps are buffer-local (`{ buffer = buf }`) with a `desc`. Never set
  global mappings; that's the user's config.
- Define highlight groups with `default = true` and link to standard groups so
  colorschemes can override them.
- Validate windows and buffers before use (`nvim_win_is_valid`,
  `nvim_buf_is_valid`); async callbacks often outlive them.
- User-facing messages go through `vim.notify` with a `[conduit]` prefix and an
  appropriate level. Debug detail goes to the log (`log.debug`).

## Respect the user's editor

- Prefer `vim.ui.select` / `vim.ui.input`-style hooks so pickers and UI plugins
  apply. Use a custom float only when the hook can't do the job (e.g. `@`
  completion in prompts).
- Work with whatever completion setup the user has: integrate with blink.cmp
  when present, fall back to native completion.
- Edits to user buffers must be a single undo step where possible
  (one `nvim_buf_set_lines`), and must not run if the buffer changed underneath
  in a way that makes them unsafe.

## Comments

- Comment *why*, not *what*: protocol quirks, plugin interactions and
  non-obvious invariants. A gotcha worth listing in AGENTS.md deserves a
  comment at the code it affects.
- Module files start with a `---` summary of what the module is for.
- Match the surrounding comment density; don't narrate obvious code.

## Tests

- Every behaviour change and bug fix gets a test in `tests/conduit_spec.lua`.
- Drive real code paths. Stub only at edges: `vim.ui.select`, `vim.fn.complete`,
  and the agent (the mock).
- Tests are typed code too: use `assert(...)` to narrow optionals rather than
  sprinkling diagnostics suppressions.
