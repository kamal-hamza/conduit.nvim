# conduit.nvim

A minimal way to use AI coding agents in Neovim, over the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP).

conduit keeps Neovim a text editor. There is no chat panel and no agent
dashboard: you select some lines and say what you want.

- **Changes land in the file.** If you asked for a change, the agent's rewrite
  replaces the selection while you keep working, as hunks you accept or reject.
- **Explanations open in a sidebar.** If you asked a question, the answer
  streams into a read-only split that never steals focus.
- **Everything is kept.** Every answer (the whole conversation and the tools it
  ran), every edit and every change the agent made to a file itself goes into a
  per-project history you can browse, reopen, follow up on and revert.
- **The agent is sandboxed.** It can only touch files in your project, a policy
  decides which commands it may run (or asks you), and commands Neovim runs for
  it are isolated by the OS.

Neovim acts as the ACP **client**: conduit launches an agent (Claude Code,
Gemini CLI, Codex, or any other ACP agent) as a subprocess and talks JSON-RPC to
it over stdio. The agent reads and writes files **through your buffers**, so it
sees unsaved changes and its edits land in buffers you can undo.

## Requirements

- Neovim >= 0.11
- An ACP agent on your `PATH`, for example:
  - Claude Code: `npx @agentclientprotocol/claude-agent-acp` (needs Node)
  - Gemini CLI: `gemini --experimental-acp`
  - Codex: `npx @agentclientprotocol/codex-acp`
- For terminal isolation: macOS (`sandbox-exec` is built in) or Linux with
  [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`)

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kamal-hamza/conduit.nvim",
  cmd = "Conduit",
  opts = {},
  keys = {
    { "<leader>ai", "<Plug>(conduit-inline)", mode = { "n", "x" }, desc = "Ask or edit inline" },
    { "<leader>ae", "<Plug>(conduit-edit)", mode = { "n", "x" }, desc = "Edit inline" },
    { "<leader>a?", "<Plug>(conduit-ask)", mode = { "n", "x" }, desc = "Ask about the lines" },
    { "<leader>aa", "<Plug>(conduit-answer)", desc = "Focus the answer sidebar" },
    { "<leader>as", "<Plug>(conduit-sidebar)", desc = "Toggle the answer sidebar" },
    { "<leader>ah", "<Plug>(conduit-history)", desc = "Agent history" },
  },
}
```

`<Plug>` mappings: `(conduit-inline)`, `-ask`, `-edit` (normal or visual mode),
`-answer`, `-sidebar`, `-history`, `-cancel`, `-model`, `-options`.

## Usage

Select some lines and press your inline key (or run `:'<,'>Conduit`). A small
prompt opens under the selection with `@` completion. Its title shows the
agent, the mode, the model and effort the request will use, and the lines it's
about.

- **Auto** (default): the agent decides. Ask for a change and the selection is
  rewritten in place as one undoable change; ask a question and the answer
  opens in the sidebar.
- **Edit** / **Ask** force one or the other. Cycle with `<C-t>`, or start the
  prompt with `!` (edit) or `?` (ask).

In the prompt, `<CR>` sends, `<S-CR>` adds a line, `<C-o>` changes the model,
effort or any other option for this request only, `<C-c>` (insert) or `q` /
`<Esc>` (normal) closes it, and `g?` lists every key. While the agent works, a
spinner and its name sit above the lines.

If the request needs changes to other files, the agent makes them with its own
tools; they show up as hunks to review in those files (see below).

| Command | Description |
| --- | --- |
| `:'<,'>Conduit` | Open the prompt for the lines |
| `:'<,'>Conduit inline [request]` | Edit the lines or answer a question about them |
| `:'<,'>Conduit ask [question]` | Answer a question about the lines, in the sidebar |
| `:'<,'>Conduit edit [instruction]` | Rewrite the lines in place |
| `:Conduit answer` | Focus the sidebar (opening it on the latest answer) |
| `:Conduit sidebar` | Open or close the sidebar |
| `:Conduit history [qf\|all]` | Browse the history (this buffer, or `all` of the project); `qf` sends it to the quickfix list |
| `:Conduit review [toggle]` | List the agent's changes waiting for review, or turn review on or off |
| `:Conduit accept [all]` / `:Conduit reject [all]` | Accept or reject the agent's changes to the current file, or every file |
| `:Conduit model [value]` / `effort` / `mode` | Pick or set the model, effort or mode for new requests |
| `:Conduit option [id] [value]` | Pick or set any session option for new requests |
| `:Conduit sandbox` | Show what the sandbox allows |
| `:Conduit cancel` | Cancel running requests |
| `:Conduit stop` | Kill all agent processes |
| `:Conduit log` | Open the log file |

### The answer sidebar

Answers stream into a read-only split on the right (`ui.sidebar`). It never
takes focus on its own, so you keep editing while the agent explains. The
sidebar's winbar shows what the agent is doing. A new answer replaces the
previous one, which stays in the history. In the sidebar:

| Key | Action |
| --- | --- |
| `f` | Ask a follow-up in the same session (on a history entry: a new request with the old conversation as context) |
| `a` | Replace the request's lines with the answer's last code block |
| `gf` | Go to the request's lines |
| `[[` / `]]` | Older / newer answer from the history |
| `gh` | Browse the history |
| `<C-c>` | Cancel the reply |
| `q` | Close the sidebar |
| `g?` | List the keys |

### Reviewing edits

Agents like Claude Code and Codex write files themselves, so conduit can't hold
an edit back for approval. Instead it keeps each file's content from before the
agent first touched it, and shows what changed as hunks you accept or decline.
Inline rewrites of your selection work the same way (`review.replies`).

When an edit lands, the file's buffer reloads (if it has no unsaved changes),
the agent's lines are highlighted and the lines it removed show as virtual
lines above them:

| Key | Action |
| --- | --- |
| `]r` / `[r` | Next / previous change |
| `<localleader>a` | Accept the change under the cursor |
| `<localleader>r` | Reject it: its old lines come back, and the file is saved |
| `<localleader>A` / `<localleader>R` | Accept / reject every change in the file |

Rejecting a created file deletes it; rejecting a deletion recreates the file.
Editing a reviewed buffer yourself updates the hunks, and undoing a change by
hand clears it. `:Conduit review` lists every change in the quickfix list. If
the agent rewrites a file whose buffer has unsaved changes, the buffer is left
alone and the file is marked as a conflict; rejecting it writes back what the
buffer had when the agent started. `review.enabled = false` applies edits as
they come. conduit fires `User ConduitReviewChanged` (with `{ path }` in
`data`) whenever a file's review state changes.

### History

Everything the agent does is kept per project in
`stdpath("state")/conduit/history`:

- **Answers**: the request, the whole conversation (follow-ups included), and
  the tools the agent ran with how each permission request was answered.
- **Edits**: the lines before and after, and whether they were applied,
  accepted, rejected or reverted.
- **Changes**: files the agent changed with its own tools, as a diff, with what
  you kept after review.
- **Commands**: commands run through Neovim, whether the sandbox allowed,
  asked or refused them, whether they were isolated, and how they exited.

`:Conduit history` lists the current buffer's entries (`<Tab>` switches to the
whole project):

| Key | Action |
| --- | --- |
| `j` / `k` | Move |
| `/` | Filter by prompt, file, answer, diff or kind (`answer`, `edit`, `change`) |
| `<CR>` | Show the entry in the sidebar |
| `gf` | Go to its lines (or file) |
| `f` | Follow up on an answer |
| `r` | Re-run the request on the lines |
| `u` | Revert an edit or change, if the file hasn't changed since |
| `dd` | Delete the entry |

`history.max_entries` caps it per project (default 1000).

### Sandbox

conduit decides what the agent may do in three layers (`sandbox`):

1. **Paths.** `fs/*` requests, edits and shell redirections must stay inside
   the roots: the working directory plus `sandbox.roots`. Outside them they're
   refused (`outside = "deny"`, the default) or asked about (`"ask"`).
2. **Commands.** Before a command runs, its line is split at `&&`, `||`, `;`,
   `|` and newlines, wrappers like `env`, `nohup` and `timeout` are looked
   through, and each part is matched against `sandbox.commands`: refused if any
   part matches `deny`, run without asking if every part matches `allow`,
   otherwise `default` (`"ask"`). Command substitution (`$(...)`, backticks)
   always asks. The policy answers both ACP terminal requests and the
   permission requests of agents that run commands themselves (Claude Code's
   Bash tool, Codex), so a denied command is refused without a prompt and an
   allowed one runs without one. When it asks, the prompt says why.
3. **Isolation.** Commands Neovim runs for the agent (ACP terminals) run in an
   OS sandbox: `sandbox-exec` on macOS, `bwrap` on Linux. They can write only
   to the roots, `isolation.writable` and temp dirs, and have no network unless
   `isolation.network = true`. `isolation.env = "minimal"` passes only `PATH`,
   `HOME`, locale and the like, keeping tokens in your environment away from
   them. Without an OS sandbox, `isolation.unavailable` decides: `"ask"`
   (default), `"run"` or `"deny"`.

**Claude Code** runs Bash itself rather than through Neovim, and its own
permission settings may let it run commands without asking. So conduit passes
settings to Claude's adapter with every session (`_meta.claudeCode.options`):
an `ask` rule for Bash, which beats any allow rule in your Claude settings, so
every command comes back to conduit as a permission request for the policy to
answer; Claude Code's own sandbox (`sandbox.enabled`), which OS-isolates the
commands it runs when `isolation.enabled` is on; and the sandbox roots as
additional directories. Other agents ignore this. Add your own with an agent's
`session_meta`, which is merged over it.

Agents' "bypass permissions" modes skip every check, so conduit refuses to
switch to one, and removes it from Claude's sessions, unless
`sandbox.bypass = true`.

The patterns are a guardrail, not a security boundary: a determined command can
get past a pattern. OS isolation is the boundary. `:Conduit sandbox` and
`:checkhealth conduit` show what's in effect.

### `@` mentions

Type `@` in the prompt to attach context. A completion menu fuzzy-matches
project paths (git-tracked and untracked files, respecting `.gitignore`), then
directories and open buffers.

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

Absolute and `~/` paths work too. Mentions that don't match anything are left as
plain text. With [blink.cmp](https://github.com/saghen/blink.cmp) loaded,
conduit registers a `conduit` source for its prompt automatically; otherwise it
uses the native completion popup (`mentions.completion`). Agents that don't
accept embedded context get links instead; files over 256 KB and binary files
are always links.

### Slash commands

Agents advertise their own commands (Claude Code has `/review`, `/compact`,
...). Type `/` at the start of the prompt to complete them; commands that take
arguments show their input hint as ghost text. A command is sent as is, with
the selected lines attached, and the reply opens in the sidebar.

## Configuration

These are the defaults:

```lua
require("conduit").setup({
  default_agent = "claude",
  agents = {
    claude = { cmd = "npx", args = { "-y", "@agentclientprotocol/claude-agent-acp" } },
    gemini = { cmd = "gemini", args = { "--experimental-acp" } },
    codex = { cmd = "npx", args = { "-y", "@agentclientprotocol/codex-acp" } },
    -- Any agent: { cmd = "...", args = { ... }, env = { ... },
    --   options = { model = "...", effort = "high", mode = "default" },
    --   session_meta = { ... } }  -- extra `_meta` for session/new
  },
  ui = {
    icons = true,          -- true (Unicode), false (ASCII) or "nerd"
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    inline = { width = { min = 40, max = 84 } },  -- the prompt
    sidebar = { width = 0.35, position = "right" }, -- fraction of the editor, or columns
    border = nil,          -- nil follows 'winborder'
    components = {},       -- see :h conduit-components
  },
  inline = {
    agent = nil,           -- defaults to default_agent
    options = {},          -- session options for every request, e.g. { effort = "low" }
    mcp_servers = false,   -- give requests the MCP servers (each request is a new session)
  },
  history = { enabled = true, max_entries = 1000 },
  mcp_servers = {},
  mentions = { completion = "auto" },  -- "auto" | "blink" | "native"
  terminal = {
    enabled = true,                -- let agents run commands through Neovim (ACP terminals)
    output_limit = 1024 * 1024,    -- bytes of output kept per command
  },
  review = {
    enabled = true,
    replies = true,        -- review inline rewrites of the selection too
    keys = {
      next = "]r", prev = "[r",
      accept = "<localleader>a", reject = "<localleader>r",
      accept_file = "<localleader>A", reject_file = "<localleader>R",
    },
  },
  sandbox = {
    enabled = true,
    roots = {},            -- directories besides the working directory
    outside = "deny",      -- "deny" | "ask"
    commands = {
      default = "ask",     -- "ask" | "allow" | "deny"
      allow = { "^ls%f[%s%z]", "^cat%f[%s%z]", "^rg%f[%s%z]", "^git status%f[%s%z]", "^git diff%f[%s%z]", ... },
      deny = { "^sudo%f[%s%z]", "^rm%s.*%-%a*[rR]%a*f", "^git push%s.*%-%-force", "^git reset%s+%-%-hard", "^sh$", ... },
    },
    isolation = {
      enabled = true,
      network = false,
      writable = {},
      env = "inherit",     -- "inherit" | "minimal"
      unavailable = "ask", -- "ask" | "run" | "deny"
    },
    bypass = false,        -- allow the agent's bypass-permissions mode
  },
  log_level = vim.log.levels.WARN,
})
```

`commands.allow` and `commands.deny` are Lua patterns; setting either replaces
the default list rather than merging with it. `:Conduit model`, `effort`, `mode`
and `option` change `inline.options` for the rest of the session.

### MCP servers

`mcp_servers` lists [MCP](https://modelcontextprotocol.io) servers that conduit
passes to the agent when it opens a session. The agent starts them; conduit
never runs or talks to them itself.

```lua
require("conduit").setup({
  mcp_servers = {
    github = {
      command = "github-mcp",  -- looked up in PATH and sent as an absolute path
      env = { GITHUB_TOKEN = function() return os.getenv("GH_TOKEN") end },
    },
    docs = { type = "http", url = "https://example.com/mcp", headers = { Authorization = "Bearer ..." } },
  },
  inline = { mcp_servers = true },
})
```

- `type` is `"stdio"` (the default), `"http"` or `"sse"`. Stdio servers take
  `command`, `args` and `env`; HTTP and SSE servers take `url` and `headers`.
- Values in `env`, `headers` and `args` can be functions, called when a session
  opens. `enabled = false` (or a function returning false) turns one off.
- Per-agent `mcp_servers` replace global ones of the same name; `false` leaves
  one out.
- Every request opens a new session, so servers are left out unless
  `inline.mcp_servers = true`.

Claude Code already loads servers from its own config (`~/.claude.json`,
`.mcp.json`); a server listed there and here starts twice.

### Components

The few drawn pieces (the prompt title, pickers, help, history lines) are
components: pure functions from props to highlighted spans. Replace one in
`ui.components`; each gets its props and the built-in:

```lua
ui = {
  components = {
    HistoryLine = function(props, builtin)
      return vim.list_extend({ { "» " } }, builtin(props))
    end,
  },
},
```

Components: `HelpFloat`, `Picker`, `PromptTitle` and `HistoryLine`. See
`:h conduit-components` for their props.

## Development

```sh
make test     # headless test suite, drives a mock ACP agent (tests/mock_agent.lua)
make lint     # stylua --check
```

See [AGENTS.md](AGENTS.md) for how the pieces fit.
