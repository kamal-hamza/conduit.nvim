# conduit.nvim

Chat with CLI coding agents from inside Neovim over the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP).

Neovim acts as the ACP **client**: conduit launches an agent (Claude Code,
Gemini CLI, Codex, or any other ACP-speaking agent) as a subprocess and talks
JSON-RPC to it over stdio. The agent streams its replies, tool calls and plans
into a chat buffer. It reads and writes files **through your buffers**, so it
sees unsaved changes and its edits land in buffers you can undo.

> Status: early. The core protocol (initialize, auth, sessions, prompts,
> streaming updates, permissions, `fs/*`, session config options) works, along
> with inline edits and answers. Terminals and session loading aren't implemented yet.

## Requirements

- Neovim >= 0.11
- An ACP agent on your `PATH`, for example:
  - Claude Code: `npx @agentclientprotocol/claude-agent-acp` (needs Node)
  - Gemini CLI: `gemini --experimental-acp`
  - Codex: `npx @agentclientprotocol/codex-acp`

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kamal-hamza/conduit.nvim",
  cmd = "Conduit",
  opts = {},
  keys = {
    { "<leader>at", "<cmd>Conduit toggle<cr>", desc = "Toggle agent chat" },
    { "<leader>an", "<cmd>Conduit new<cr>", desc = "New agent chat" },
    { "<leader>am", "<cmd>Conduit model<cr>", desc = "Pick agent model" },
    { "<leader>ai", ":Conduit inline<cr>", mode = { "n", "v" }, desc = "Inline edit or question" },
    { "<leader>as", ":Conduit add<cr>", mode = "v", desc = "Add selection to chat" },
  },
}
```

## Configuration

These are the defaults:

```lua
require("conduit").setup({
  default_agent = "claude",
  agents = {
    claude = { cmd = "npx", args = { "-y", "@agentclientprotocol/claude-agent-acp" } },
    gemini = { cmd = "gemini", args = { "--experimental-acp" } },
    codex = { cmd = "npx", args = { "-y", "@agentclientprotocol/codex-acp" } },
    -- my_agent = { cmd = "my-agent", args = { "--acp" }, env = { FOO = "bar" } },
  },
  ui = {
    width = 0.4,       -- fraction of the editor width, or a column count
    input_height = 6,
    icons = false,     -- Nerd Font glyphs in float titles
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }, -- one frame turns the animation off
    inline = {
      width = { min = 40, max = 84 }, -- inline prompt and answer float width
    },
  },
  inline = {
    agent = nil,       -- agent for inline edits, defaults to default_agent
    options = {},      -- session options for inline edits, e.g. { model = "haiku", effort = "low" }
    mcp_servers = false, -- give inline sessions the MCP servers too
  },
  mcp_servers = {},    -- MCP servers handed to the agent, see below
  mentions = {
    completion = "auto", -- "auto" (blink.cmp if loaded), "blink" or "native"
  },
  threads = {
    scope = "cwd",       -- past threads to offer: "cwd" (this directory) or "all"
    persist = true,      -- remember thread ids and titles (not transcripts) on disk
    max_listed = 200,    -- most past threads to fetch from the agent
    hide_inline = true,  -- leave inline requests' sessions out of thread lists
  },
  log_level = vim.log.levels.WARN,
})
```

Each agent also takes `options`, which are applied to every new session:

```lua
agents = {
  claude = {
    cmd = "npx",
    args = { "-y", "@agentclientprotocol/claude-agent-acp" },
    options = { model = "opus", effort = "high", mode = "acceptEdits" },
  },
},
```

Keys are option ids or ACP categories (`model`, `mode`, `thought_level`), and
`effort` is accepted as an alias for `thought_level`. The values depend on the
agent; `:Conduit option` lists what yours offers.

### MCP servers

`mcp_servers` lists [MCP](https://modelcontextprotocol.io) servers that conduit
passes to the agent when it opens a session (`mcpServers` in ACP). The agent
starts them and can use their tools in that session. conduit never runs or talks
to them itself.

```lua
require("conduit").setup({
  mcp_servers = {
    github = {
      command = "github-mcp",  -- looked up in PATH and sent as an absolute path
      args = {},
      env = { GITHUB_TOKEN = function() return os.getenv("GH_TOKEN") end },
    },
    docs = { type = "http", url = "https://example.com/mcp", headers = { Authorization = "Bearer ..." } },
  },
  agents = {
    -- Per-agent servers replace global ones of the same name; false leaves one out.
    gemini = { cmd = "gemini", args = { "--experimental-acp" }, mcp_servers = { docs = false } },
  },
})
```

- `type` is `"stdio"` (the default), `"http"` or `"sse"`. Stdio servers take
  `command`, `args` and `env`. HTTP and SSE servers take `url` and `headers`.
- Values in `env`, `headers` and `args` can be functions. They're called when
  a session opens, so tokens don't have to live in your config.
- `enabled = false` (or a function that returns false) turns a server off.
- A list of servers with `name` fields works too.
- Servers that can't be sent are skipped with a warning: the command isn't in
  PATH, `url` is missing, or the agent doesn't support the transport. Agents
  advertise HTTP and SSE support in `mcpCapabilities`; every agent supports stdio.
- Inline requests open a new session each time, so they leave MCP servers out
  unless you set `inline.mcp_servers = true`. An inline conversation moved into
  the chat keeps its session, and with it no servers.
- `:checkhealth conduit` shows what each agent would get.

Claude Code already loads servers from its own config (`~/.claude.json`,
`.mcp.json`). A server listed there and here starts twice, so use `mcp_servers`
for servers you want with every agent.

## Usage

| Command | Description |
| --- | --- |
| `:Conduit` / `:Conduit toggle` | Toggle the chat window |
| `:Conduit open [agent]` | Open the current thread, or the latest thread with `agent` (starting one if needed) |
| `:Conduit new [agent]` | Start a new thread (fresh session); earlier threads stay alive |
| `:Conduit threads [agent]` | Pick a live or past thread, or start a new one |
| `:Conduit continue [agent]` | Go back to the latest thread, reopening a past one if none is live |
| `:Conduit thread new\|next\|prev` | Start or cycle through threads |
| `:Conduit thread close` | Close the current thread (it stays in the history) |
| `:Conduit thread delete` | Delete the current thread for good, after confirming |
| `:Conduit thread fork` | Fork the current thread into a new one with the same context |
| `:Conduit thread rename [title]` | Rename the current thread |
| `:'<,'>Conduit add` | Add the selected lines to the prompt as a fenced block |
| `:'<,'>Conduit inline [request]` | Edit the selection or answer a question about it, inline |
| `:'<,'>Conduit ask [question]` | Answer a question about the selection in a float |
| `:'<,'>Conduit edit [instruction]` | Rewrite the selection in place |
| `:Conduit model [value]` | Pick or set the model |
| `:Conduit effort [value]` | Pick or set the reasoning effort |
| `:Conduit mode [value]` | Pick or set the mode (e.g. plan, accept edits) |
| `:Conduit option [id] [value]` | Pick or set any session option |
| `:Conduit cancel` | Cancel running inline edits, or else the current turn |
| `:Conduit stop` | Kill all agent processes |
| `:Conduit log` | Open the log file |

In the prompt buffer, `<CR>` (normal mode) or `<C-s>` (insert mode) sends the
prompt and `<C-c>` cancels the turn. In both chat buffers, `go` picks a session
option and `q` closes the chat. The winbar shows the thread title, the current
model, effort and mode. Permission requests open in `vim.ui.select`.

### Threads

Each chat is a thread: one ACP session with its own transcript. `:Conduit new`
starts another thread without discarding the current one, and switching swaps
the thread into the same chat windows. In the chat buffers, `gs` picks a thread,
`]t` / `[t` cycle through them and `gn` starts a new one. Threads are titled by
the agent (`session_info_update`), by you (`:Conduit thread rename`), or by your
first prompt until then. Inline answers moved into the chat become threads too.

What else you get depends on what the agent advertises, so it works with any ACP
agent:

| Agent capability | What it adds |
| --- | --- |
| none | Live threads for as long as Neovim runs |
| `loadSession` | Reopen past threads with their transcript (from conduit's local index) |
| `sessionCapabilities.list` | Past threads come from the agent, including ones started elsewhere (e.g. its CLI) |
| `sessionCapabilities.resume` | Threads reconnect without replaying history after the agent restarts |
| `sessionCapabilities.close` / `delete` | Closing frees the session; deleting removes it from the agent's history |
| `sessionCapabilities.fork` / `title` | `:Conduit thread fork`; renames are stored by the agent |

The picker lists live threads, then past threads for the current agent in this
directory (`threads.scope`), then "New thread". If the agent process exits, the
transcript stays and the next prompt restores the session (resume, else a silent
reload, else a fresh session with a notice). `:checkhealth conduit` shows what
each running agent supports. The local index lives at
`stdpath("data")/conduit/threads.json` and holds only ids, titles, directories
and timestamps.

Chat buffers use the `conduit` and `conduit_input` filetypes, so markdown
linters and LSPs leave them alone, and they get markdown highlighting from
treesitter. If [markview.nvim](https://github.com/OXY2DEV/markview.nvim) is
loaded, conduit attaches it to the transcript and answer floats itself (markview
skips scratch buffers by default). For other renderers, add the `conduit`
filetype to their config.

### `@` mentions

Type `@` in the chat prompt or the inline prompt to attach context. A
completion menu fuzzy-matches project paths (git-tracked and untracked files,
respecting `.gitignore`), ranking path and file-name prefix matches first, then
directories and open buffers. With nothing typed yet it shows the special
mentions, your open buffers and the top-level directories.

| Mention | Sends |
| --- | --- |
| `@path/to/file.lua` | The file's contents (from its buffer if open, so unsaved changes are included) |
| `@src/` | A listing of the directory, two levels deep |
| `@buffer` | The buffer you were last in |
| `@selection` | Your last visual selection in that buffer |
| `@diagnostics` | Errors, warnings and hints from all open buffers |
| `@quickfix` | The quickfix list |
| `@diff` | Uncommitted changes (`git diff HEAD`) |

Absolute and `~/` paths work too. Mentions that don't match anything are left
as plain text, so email addresses and decorators are safe. Use `@./diff` for a
file that shares a name with a special mention.

**Completion:** with [blink.cmp](https://github.com/saghen/blink.cmp) loaded,
conduit registers a `conduit` source for its prompt buffers automatically. You
get file-type icons and previews in the documentation window, the menu stays
open while you type a path (even with `menu.auto_show = false`), and accepting
a directory reopens it so you can keep drilling down. Without blink it uses the
native completion popup. Force one with `mentions = { completion = "blink" }`
or `"native"`.

If an agent doesn't accept embedded context, mentions are sent as links for it
to read itself. Files over 256 KB and binary files are always sent as links.

### Inline requests

Select some lines and run `:'<,'>Conduit inline` (`<leader>ai` in the example
keymaps). A floating prompt opens under the selection (or above it, near the
bottom of the window), with `@` completion. Its title shows the agent, the mode
and the lines it's about. Ask for a change or ask a question in the same prompt:

- **Auto** (default): the agent decides. If you ask for a change, the
  selection is rewritten in place as one undoable change. If you ask a
  question, the answer streams into a float under the selection.
- **Edit** / **Ask** force one or the other. Cycle modes with `<C-t>`, or start
  the prompt with `!` (edit) or `?` (ask); the title updates as you type.

In the prompt, `<CR>` sends, `<S-CR>` adds a line, `<C-c>` (insert) or `q` /
`<Esc>` (normal) closes it, and `g?` (normal) lists every key.

In the answer float:

| Key | Action |
| --- | --- |
| `a` | Apply the answer's last code block to the selection |
| `f` | Ask a follow-up in the same session |
| `c` | Move the conversation into the chat window, keeping the session |
| `<C-c>` | Cancel the answer |
| `q` / `<Esc>` | Close |
| `g?` | List these keys |

While the request runs, the selection is marked in the sign column and a
spinner above it shows what the agent is doing (thinking, running a tool,
writing). The mark stays while the answer is open. You can also pass the request on the command line, e.g.
`:'<,'>Conduit inline why is this slow?`. `:Conduit ask` and `:Conduit edit`
force a mode. Each request runs in its own throwaway session, so set
`inline.options` to a fast model and low effort to make them quick.

The floats and inline decorations use these highlight groups, linked to
standard groups by default:

| Group | Default link | Used for |
| --- | --- | --- |
| `ConduitNormal`, `ConduitBorder`, `ConduitTitle` | `NormalFloat`, `FloatBorder`, `FloatTitle` | Float background, border, answer title |
| `ConduitAgent` | `Title` | Agent name in titles and the status line |
| `ConduitContext` | `Comment` | File and lines in the prompt title |
| `ConduitModeAuto`, `ConduitModeEdit`, `ConduitModeAsk` | `Special`, `DiagnosticWarn`, `DiagnosticInfo` | Mode label |
| `ConduitHintKey`, `ConduitHintDesc` | `Special`, `Comment` | Key hints in footers |
| `ConduitPlaceholder` | `Comment` | Empty prompt placeholder |
| `ConduitSpinner` | `DiagnosticInfo` | Progress spinner |
| `ConduitInlinePending`, `ConduitInlineSign` | `CursorLine`, `DiagnosticInfo` | The range while a request runs |
| `ConduitInlineStatus` | `Comment` | Progress text |

Run `:checkhealth conduit` to check that your agents can be found.

## Development

```sh
make test     # headless test suite, drives a mock ACP agent (tests/mock_agent.lua)
make lint     # stylua --check
```

```
lua/conduit/
├── init.lua      -- public API, chat/agent registry
├── config.lua    -- defaults + setup()
├── rpc.lua       -- newline-delimited JSON-RPC over vim.system stdio
├── agent.lua     -- ACP client: handshake, sessions, agent→client requests
├── fs.lua        -- fs/read_text_file, fs/write_text_file (buffer-aware)
├── options.lua   -- session options (configOptions + legacy modes/models)
├── inline.lua    -- in-place edits of a buffer range
├── mentions.lua  -- @ mentions: items, ranking, special context, resource blocks
├── blink.lua     -- blink.cmp source for @ mentions
├── ui/chat.lua   -- transcript + input buffers, session/update rendering
├── ui/prompt.lua  -- floating prompt for inline requests (modes, @ completion)
├── ui/answer.lua  -- floating answer window anchored under the selection
├── ui/hl.lua      -- highlight groups and float helpers (borders, key hints)
├── ui/spinner.lua -- animated progress indicator
├── ui/render.lua  -- markview.nvim integration
├── ui/permission.lua
├── health.lua    -- :checkhealth conduit
└── log.lua
```
