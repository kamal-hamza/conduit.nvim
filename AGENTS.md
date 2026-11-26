# AGENTS.md

Guidance for AI coding agents (and humans) working on conduit.nvim. Read
[CODING_GUIDELINES.md](CODING_GUIDELINES.md) before writing Lua here.

## What this is

conduit.nvim is a minimal way to use AI agents in Neovim. It makes Neovim an
[Agent Client Protocol](https://agentclientprotocol.com) (ACP) **client**: it
spawns an ACP agent (Claude Code via `@agentclientprotocol/claude-agent-acp`,
Codex, Gemini CLI, ...) as a subprocess and talks newline-delimited JSON-RPC 2.0
to it over stdio.

The product is deliberately small and stays a text editor, not an agent IDE.
**The only way to use the agent is inline**, on a selection: edits are applied
to the file (as hunks to accept or reject), explanations stream into a
read-only sidebar that never takes focus. There is no chat panel, no threads,
no tool-call transcript. Everything is kept in a per-project history (answers,
edits, agent file changes, commands), and a sandbox decides which files the
agent may touch and which commands it may run. Keep new features inside that
shape; don't grow a chat back.

Pure Lua, no build step, no runtime dependencies. Requires Neovim >= 0.11.
blink.cmp and markview.nvim are optional integrations.

## Commands

```sh
make test     # headless suite: nvim --headless -u NONE -l tests/run.lua
make lint     # stylua --check lua plugin tests
make format   # stylua lua plugin tests
```

Run `make format` and `make test` before finishing any change. CI (GitHub
Actions) runs lint plus tests on Neovim stable and nightly.

Type checking uses **emmylua_ls** with `.luarc.json`. There's no CLI step in
CI, but changes must not introduce EmmyLua diagnostics (see the guidelines).

## Layout

```
plugin/conduit.lua      :Conduit command, filetype → markdown parser registration,
                        last-buffer tracking. Keep it cheap: no requires at load.
lua/conduit/
  init.lua              Public API (setup, inline, ask, edit, answer, sidebar, history,
                        review/accept/reject, option, sandbox_info, cancel, stop)
  config.lua            Defaults and setup()
  rpc.lua               JSON-RPC transport over vim.system stdio
  agent.lua             ACP client: initialize, auth, sessions, prompts, options, and
                        agent→client requests (fs/*, terminal/*, request_permission),
                        each passed through the sandbox
  sandbox.lua           Path roots, the command policy (split, allow/deny/ask), OS
                        isolation (sandbox-exec, bwrap), bypass-mode guard
  options.lua           Session options: ACP configOptions + legacy modes/models
  fs.lua                fs/read_text_file, fs/write_text_file (buffers first)
  review.lua            Review of agent edits: per-file baselines, hunks, accept/reject;
                        records agent changes in the history
  terminal.lua          terminal/* commands (vim.system, own process group) and display
                        terminals from tool call _meta
  mcp.lua               mcp_servers config → ACP mcpServers for session/new
  mentions.lua          @ mentions: completion items, ranking, specials, content blocks;
                        mentions.attach also wires up / commands
  commands.lua          / agent commands: per-buffer sources, items, input-hint ghost text
  blink.lua             blink.cmp source for @ mentions and / commands
  inline.lua            Inline requests (the only entry point): auto/edit/ask routing,
                        edits applied in place, answers to the sidebar, follow-ups,
                        continuing a history entry
  history.lua           Per-project history (JSONL): answers, edits, changes, tools and
                        commands; revert; markdown for the sidebar
  health.lua            :checkhealth conduit
  log.lua               File log + vim.notify
  ui/sidebar.lua        The answer sidebar: read-only split, never takes focus
  ui/component.lua      Component core: define/render (ui.components overrides), mount
  ui/components.lua     Built-in components (HelpFloat, Picker, PromptTitle, HistoryLine)
  ui/surface.lua        Surfaces: spans → statusline strings, extmarks, float titles, buffers
  ui/status.lua         Status model (model, effort, mode, context) + change events
  ui/headless/          Headless models: picker, options, help, history
  ui/picker_float.lua   Keyboard picker view (j/k, 1-9, /) over the headless picker
  ui/help_float.lua     g? key list view
  ui/history_float.lua  :Conduit history list view
  ui/prompt.lua         Floating prompt (modes, @ completion)
  ui/review.lua         Review overlay in file buffers (extmarks, virtual lines, keys)
  ui/hl.lua             Highlight groups (re-applied on ColorScheme), borders, key hints
  ui/spinner.lua        Animated progress indicator (uv timer)
  ui/permission.lua     Permission requests via vim.ui.select (with the sandbox's reason)
  ui/render.lua         markview.nvim integration
tests/
  run.lua               Minimal test runner (test(), wait_for())
  conduit_spec.lua      The suite
  mock_agent.lua        Scripted ACP agent the suite talks to
doc/conduit.txt         Vimdoc; keep in sync with README.md
```

## How the pieces fit

- `Agent` owns one subprocess and any number of sessions. Each session has a
  **handler** (`conduit.SessionHandler`: `on_update`, `request_permission`,
  `on_agent_exit`, and optionally `on_decision`, `on_terminal`). In the plugin
  that's always an inline `Job`; tests use a small harness. Session option
  state lives on the agent (`agent.options[sid]`), not on handlers.
- Every inline request opens its own session and closes it when the request is
  over (an edit lands, or the sidebar moves on from an answer).
- `Job:_route()` decides from the first few streamed characters whether the
  reply is an edit (`<replace>` + fenced block + `</replace>`) or an answer.
  Edits are applied when the turn ends; answers stream into `ui/sidebar.lua`.
  The sidebar shows one source at a time: a live job or a history entry.
- Everything agent→client goes through `sandbox.lua` first: `fs/*` paths
  (`_guard_paths`), `terminal/create` (policy, then OS isolation) and
  `session/request_permission` (`_permission`: the policy picks an
  allow_once/reject_once option itself, or passes the request to the handler
  with a reason). Decisions reach the handler through `on_decision`, so the
  history can record them.
- `review.lua` snapshots files before agent tool calls touch them and turns the
  difference into hunks. When a tool call finishes it records a `change` entry
  in the history; accepting/rejecting patches the entry's outcome. Inline
  replies are linked to their `edit` entry with `review.link`.
- History is append-only JSONL with patches (`{ id, outcome }`), merged on
  load. Never rewrite an entry in place except in `_compact`.
- Prompts are lists of ACP content blocks. `mentions.blocks()` turns typed
  text into a text block plus one block per `@` mention.
- UI is components + headless models. Components are pure `render(props)` →
  spans; surfaces draw them. Interactive state (pickers, help, history list)
  lives in `ui/headless/*`; keys call model actions, views subscribe. Test the
  models directly; test views through their spans or buffer lines.

## Testing

- Tests run against `tests/mock_agent.lua`, never a real agent. When you add
  protocol behaviour, teach the mock to exercise it and assert on the result.
- `session()` / `send(s, text)` in the spec are a minimal session handler for
  driving the agent directly (terminals, review, permissions); inline tests use
  `conduit.inline` and `wait_turn`. `reset_sidebar()` ends the sidebar's job.
- The suite's config adds the temp dir to `sandbox.roots`, sets
  `commands.default = "allow"` and `isolation.unavailable = "run"`, so CI
  without bwrap still runs terminals. Sandbox tests change these and restore
  them. The live isolation check only runs where an OS sandbox exists.
- The mock runs under `nvim -l`, so it can use `vim.json`. It reads stdin
  synchronously; `request()` blocks until the matching response arrives.
- The mock takes flags: `--legacy` (modes/models instead of configOptions),
  `--threads=close,...` (session capabilities), `--mcp=http,sse` (MCP
  transports) and `--no-image` (no `promptCapabilities.image`; image blocks are
  echoed as `image <name> <mime> <bytes>`).
  Echoed turns end with a `usage_update` (42% of 10k, 0.50 USD); inline requests
  starting "short" get a one-line answer.
  Prompts `term <json>` (terminal/create plus steps), `display` (the `_meta`
  display-terminal extension) and `caps` exercise terminals. `disk-edit`,
  `disk-create`, `disk-delete` and `disk-edit-fast <path>` change files directly,
  the way Claude does, reporting them through tool calls only. `session/new`
  echoes the `mcpServers` it received in `result._meta.mcpServers`. Tests
  register extra mock agents with flags through `extra_agent`.
- Use `wait_for(fn, what)` for anything async; it fails after 5 s.
- Tests share one Neovim instance. Clean up buffers (`bwipeout!`), restore
  stubs such as `vim.ui.select`, and reset config you change.
- Real-agent checks are manual and need network access and a login, so keep
  them out of the suite. When running a Claude agent from inside a Claude Code
  session, unset `CLAUDECODE` first or the agent refuses to start.

## Gotchas learned the hard way

- **Filetypes.** The sidebar uses `conduit` and the prompt `conduit_input`, not
  `markdown`, so markdown linters and LSPs leave them alone. The
  `vim.treesitter.language.register` call lives in `plugin/conduit.lua`. If it
  only runs when some module loads, highlighting and markview silently break
  for code paths that never load that module.
- **markview** ignores `nofile` buffers, so `ui/render.lua` attaches it
  explicitly and re-renders (debounced) after programmatic edits.
- **blink.cmp** starts a new completion context at non-keyword characters (`/`,
  `.`), which hides the menu when the user has `menu.auto_show = false`.
  `mentions.attach` re-shows it (deferred) while a mention is being typed.
  Floating prompts must accept blink's menu on `<CR>` before submitting.
- **Fast-event callbacks.** `vim.system` stdout/exit callbacks run in a luv
  fast context. Everything they do goes through `vim.schedule`.
- **ACP packages.** `@zed-industries/*` adapters are deprecated in favour of
  `@agentclientprotocol/*`. The old ones expose stale models and no
  `configOptions`.
- **Large refactors.** When removing or moving functions in `init.lua`, check
  that every `:Conduit` subcommand still resolves; there's a test for it, so
  keep it up to date when adding subcommands.

- **Slash commands arrive after `session/new` responds** (Claude's adapter
  sends `available_commands_update` a moment later), and the inline prompt
  opens before any session exists. Read commands lazily through the buffer's
  source function, and fall back to `agent.last_commands`.
- **Claude doesn't use ACP terminals.** Claude Code runs Bash itself, so the
  adapter ignores `clientCapabilities.terminal`. It reports output through the
  `_meta` display-terminal extension instead (`terminal_info`,
  `terminal_output[_delta]`, `terminal_exit`, opted into with
  `clientCapabilities._meta.terminal_output[_delta]`). Codex does the same.
  Both paths feed `conduit.Terminal`. Claude's own Bash is visible to us only
  as a permission request, and Claude's settings may allow commands without
  one. `sandbox.session_meta()` fixes that through the adapter's
  `_meta.claudeCode.options`: a Bash `ask` rule (ask beats the user's allow
  rules), Claude Code's own `sandbox.enabled`, and no bypass mode. Verified
  against claude-agent-acp 0.112: `ls` is allowed, `sudo ls` refused, anything
  else asked, all by the policy.
- **Agents write files themselves.** Claude's adapter never calls
  `fs/write_text_file`; Claude Code edits the disk, and its Edit diffs are
  snippets, not whole files. So `review.lua` snapshots a file when a running
  `edit`/`delete`/`move` tool call (or a permission request, or an fs write)
  first names it, and diffs against that when the call completes. In
  `acceptEdits` mode the write can beat our snapshot; the completed call's diff
  is then undone on the current text to rebuild the baseline.
- **Tool titles can contain newlines** (multi-line shell commands). Anything
  written with `nvim_buf_set_lines` or virtual text must be split or trimmed first.
- **Answers must never take focus on their own.** The sidebar opens with
  `nvim_open_win(buf, false, { split = ... })`; only `:Conduit answer` (and the
  history list's `<CR>`) focuses it. Focus changes inside `nvim_buf_call` are
  undone when it returns, so tests that check focus run mappings in the current
  window (`press_here`), not `press`.
- **macOS paths go through symlinks** (`/tmp` → `/private/tmp`, `/var` →
  `/private/var`). Sandbox roots and paths are compared after `fs.canonical`,
  and the sandbox-exec profile needs real paths (`fs_realpath`), or writes to
  temp dirs are denied.
- **Wrapped commands hide missing executables**: `sandbox-exec missing-cmd`
  spawns fine and fails later, so `terminal/create` checks `executable()` before
  wrapping.
- **History writes to stdpath("state")**; the suite points `history.dir` at a
  temp dir.

## Making changes

- Keep README.md and doc/conduit.txt in sync with user-facing changes
  (commands, keymaps, config, behaviour).
- Add a test for every bug fix and feature. Tests should fail without the change.
- Don't add runtime dependencies. Optional integrations must be detected
  (`package.loaded[...]`), never required unconditionally.
- Commit messages: imperative subject under ~70 chars, body explaining why.
