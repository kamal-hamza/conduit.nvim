# conduit.nvim

Chat with CLI coding agents from inside Neovim over the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP).

Neovim acts as the ACP **client**: conduit launches an agent (Claude Code,
Gemini CLI, Codex, or any other ACP-speaking agent) as a subprocess and talks
JSON-RPC to it over stdio. The agent streams its replies, tool calls and plans
into a chat buffer. It reads and writes files **through your buffers**, so it
sees unsaved changes and its edits land in buffers you can undo.

> Status: early. The core protocol (initialize, auth, sessions, prompts,
> streaming updates, permissions, `fs/*`, terminals, session config options,
> threads) works, along with inline edits and answers.

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
    picker = "auto",   -- "auto", "snacks", "telescope", "fzf_lua", "mini_pick", "select" or a function
    thread_bar = true, -- threads as tabs in the chat winbar
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
    notify = true,       -- notify when a thread you aren't looking at replies or needs permission
  },
  tools = {
    diff_lines = 20,     -- diff lines previewed under a tool call, before <CR> expands it
    output_lines = 8,    -- output lines previewed under a tool call
    hide_output = { read = true, search = true, fetch = true }, -- kinds whose output starts hidden
  },
  terminal = {
    enabled = true,          -- let agents run commands through Neovim (ACP terminals)
    output_limit = 1048576,  -- most bytes of output kept per command (oldest dropped first)
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
| `:Conduit resume [session-id]` | Reopen a thread by session id, or pick one of the agent's past threads |
| `:Conduit thread new\|next\|prev` | Start or cycle through threads |
| `:Conduit thread alt` | Switch to the thread you used before this one |
| `:Conduit thread goto {n\|title\|id}` | Go to a thread by its number in the thread bar, its title (or a unique part of it) or its session id |
| `:Conduit thread search [--qf] [text]` | Search the transcripts of live threads; `--qf` sends matches to the quickfix list |
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
| `:Conduit commands [name]` | Pick one of the agent's slash commands and start the prompt with it |
| `:Conduit cancel` | Cancel running inline edits, or else the current turn |
| `:Conduit stop` | Kill all agent processes |
| `:Conduit log` | Open the log file |

In the prompt buffer, `<CR>` (normal mode) or `<C-s>` (insert mode) sends the
prompt and `<C-c>` cancels the turn. In both chat buffers, `go` picks a session
option and `q` closes the chat. The chat's winbar shows the thread bar (see
below), and the prompt's winbar shows the agent, its state and the current
model, effort and mode. Permission requests open in `vim.ui.select`, showing
the tool's kind (`edit`, `execute`, ...), the paths it touches and the full
command, every line of it.

### Tool calls

Each tool call shows its status and title in the transcript. Below that come
the files it touched, the diff of any edit it made or proposes, and its output.
Diffs and output are cut to `tools.diff_lines` and `tools.output_lines`. Output
from `read`, `search` and `fetch` calls (often a whole file) stays hidden until
you expand it. When an agent asks permission for an edit, the proposed diff is
drawn before the prompt opens. In the transcript:

| Key | Action |
| --- | --- |
| `<CR>` | Expand or collapse the tool call under the cursor |
| `gd` | Open its diff side by side in a new tab (`q` closes it) |
| `gf` | Open the first file it touched, at the reported line |

Diffs are highlighted by the treesitter `diff` parser, which Neovim doesn't
bundle (`:TSInstall diff`); `:checkhealth conduit` reports whether it's there.

### Terminals

Agents can ask Neovim to run commands for them (ACP terminals). conduit runs
each one as a process in the session's directory with the environment the agent
asks for, and sends back its combined stdout and stderr, how much was dropped,
and how it exited. Commands are killed when the agent releases them, when their
thread closes, when the agent exits, and when Neovim quits. A command that
arrives as a whole shell line with no arguments runs through `sh -c`.

A tool call that runs a command shows the last `tools.output_lines` lines of
its output, updated live, then the exit code or signal if it failed. `<CR>`
expands it to the whole output. Agents that run commands themselves, such as
Claude Code and Codex, report their output the same way. Set
`terminal.enabled = false` to stop offering terminals to agents; output from
agents that run commands themselves is still shown.

### Threads

Each chat is a thread: one ACP session with its own transcript. `:Conduit new`
starts another thread without discarding the current one, and switching swaps
the thread into the same chat windows. In the chat buffers, `gs` picks a thread,
`]t` / `[t` cycle through them, `g<Tab>` goes back to the previous one and `gn`
starts a new one. Threads are titled by the agent (`session_info_update`), by
you (`:Conduit thread rename`), or by your first prompt until then. Inline
answers moved into the chat become threads too.

The thread bar lists every live thread as a numbered tab (the numbers work with
`:Conduit thread goto`) and marks the ones that are working (`◐`), waiting for a
permission answer (`!`) or finished a turn you haven't seen yet (`●`). When the
window is too narrow, titles shrink and `‹` / `›` mark tabs that don't fit. Set
`ui.thread_bar = false` for a plain title instead. With `threads.notify` on,
conduit also tells you when a thread you aren't looking at replies or asks for
permission.

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

The picker lists live threads (most recently used first, the current one last),
then past threads, then "New thread". Past threads come from the current agent
and from any other agent that's already running, in this directory
(`threads.scope`). It uses [snacks.nvim](https://github.com/folke/snacks.nvim),
[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim),
[fzf-lua](https://github.com/ibhagwan/fzf-lua) or
[mini.pick](https://github.com/echasnovski/mini.pick) when one is loaded
(`ui.picker`), with a preview of each thread's transcript. Snacks, telescope and
mini.pick open at once and add past threads as they arrive. In those pickers:

| Key | Action |
| --- | --- |
| `<CR>` | Open the thread |
| `<C-d>` | Delete the thread (after confirming) |
| `<C-r>` | Rename the thread (past threads are renamed locally) |
| `<C-f>` | Fork the thread |
| `<C-n>` | Start a new thread |
| `<C-g>` | Switch between this directory's past threads and all of them |

Without a picker plugin, `vim.ui.select` lists the same threads and opens the
chosen one; the `:Conduit thread` commands cover the rest.

`:Conduit thread search` looks through live transcripts only (past transcripts
stay with the agent), matching case-insensitively unless the text has capitals.
Statuslines can show `require("conduit").status()`, which returns the current
thread and how many threads are live, busy, unread or waiting. conduit fires
`User` autocmds as threads change: `ConduitThreadCreated`,
`ConduitThreadSwitched`, `ConduitThreadUpdated` and `ConduitThreadClosed`, with
`{ agent, session_id, title }` in `data`.

If the agent process exits, the
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
| `@shot.png` | The image itself, if the agent accepts images (PNG, JPEG, GIF, WebP) |
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

**Images:** screenshots, mockups and diagrams are sent as ACP `image` blocks
when the agent advertises image support (`promptCapabilities.image`). Images
are recognised by their contents (PNG, JPEG, GIF or WebP), not their
extension. Images over 5 MB, or mentioned to an agent without image support,
are sent as links with a warning. `:checkhealth conduit` shows which running
agents accept images.

### Slash commands

Agents advertise their own commands (Claude Code has `/review`, `/compact`,
`/init`, ...). Type `/` at the very start of the chat prompt or the inline
prompt to complete them, with each command's description in the menu (blink's
documentation window, or the native popup's info). Commands that take
arguments show their input hint as ghost text after `/name ` until you type
some. `:Conduit commands` lists them in `vim.ui.select` instead, and
`:checkhealth conduit` shows what each running agent offers.

A prompt that starts with `/name` is sent unchanged, and the agent runs the
command. In the inline prompt, a command is sent as is (not wrapped in
conduit's edit instructions), with the selected lines attached as context, and
the reply opens in an answer float.

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
├── mentions.lua  -- @ mentions: items, ranking, special context, resource and image blocks
├── commands.lua  -- / agent commands: completion items, input hints
├── blink.lua     -- blink.cmp source for @ mentions and / commands
├── ui/chat.lua   -- transcript + input buffers, session/update rendering
├── ui/tool.lua   -- tool call blocks: status, locations, diffs, output
├── ui/prompt.lua  -- floating prompt for inline requests (modes, @ completion)
├── ui/answer.lua  -- floating answer window anchored under the selection
├── ui/hl.lua      -- highlight groups and float helpers (borders, key hints)
├── ui/spinner.lua -- animated progress indicator
├── ui/render.lua  -- markview.nvim integration
├── ui/permission.lua
├── health.lua    -- :checkhealth conduit
└── log.lua
```
