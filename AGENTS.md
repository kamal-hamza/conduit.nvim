# AGENTS.md

Guidance for AI coding agents (and humans) working on conduit.nvim. Read
[CODING_GUIDELINES.md](CODING_GUIDELINES.md) before writing Lua here.

## What this is

conduit.nvim makes Neovim an [Agent Client Protocol](https://agentclientprotocol.com)
(ACP) **client**. It spawns an ACP agent (Claude Code via
`@agentclientprotocol/claude-agent-acp`, Codex, Gemini CLI, ...) as a subprocess
and talks newline-delimited JSON-RPC 2.0 to it over stdio. Features: a chat
window, inline edits/answers on a selection, `@` context mentions, session
options (model, effort, mode), and buffer-aware `fs/*` handlers.

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
  init.lua              Public API (setup, open, new, inline, ask, edit, option, ...)
  config.lua            Defaults and setup()
  rpc.lua               JSON-RPC transport over vim.system stdio
  agent.lua             ACP client: initialize, auth, sessions, prompts, options,
                        and agent→client requests (fs/*, request_permission)
  options.lua           Session options: ACP configOptions + legacy modes/models
  fs.lua                fs/read_text_file, fs/write_text_file (buffers first)
  mentions.lua          @ mentions: completion items, ranking, specials, content blocks;
                        mentions.attach also wires up / commands
  commands.lua          / agent commands: per-buffer sources, items, input-hint ghost text
  blink.lua             blink.cmp source for @ mentions and / commands
  inline.lua            Inline requests: auto/edit/ask, answer float, follow-ups
  threads.lua           Threads: live registry, switching, picker, past threads, close/delete/fork
  history.lua           Local thread index (ids, titles, cwd, timestamps; never transcripts)
  health.lua            :checkhealth conduit
  log.lua               File log + vim.notify
  ui/chat.lua           Chat transcript + prompt buffers, session/update rendering
  ui/prompt.lua         Floating prompt (modes, @ completion)
  ui/answer.lua         Floating answer window anchored to a buffer line
  ui/hl.lua             Highlight groups (re-applied on ColorScheme), borders, key hints
  ui/spinner.lua        Animated progress indicator (uv timer)
  ui/permission.lua     Permission requests via vim.ui.select
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
  `on_agent_exit`), either a `Chat` or an inline `Job`. Session option state
  lives on the agent (`agent.options[sid]`), not on handlers.
- Every chat is a **thread** registered in `threads.lua`; `conduit.current` reads
  `threads.current`. Switching swaps the thread's buffers into the existing chat
  windows (`Chat:show`) rather than opening new ones.
- Thread features beyond live chats are gated on capabilities via
  `Agent:supports()` (`load` = `loadSession`, the rest are
  `sessionCapabilities.*`). Never call an optional session method without it.
- Moving an inline conversation into the chat (`Job:to_chat`) re-points
  `agent.sessions[sid]` at a new `Chat`. The ACP session itself is reused.
- Prompts are lists of ACP content blocks. `mentions.blocks()` turns typed
  text into a text block plus one block per `@` mention.
- Inline auto mode relies on a reply protocol: edits come back as
  `<replace>` + fenced block + `</replace>`; anything else is an answer.
  `Job:_route()` decides from the first few streamed characters.

## Testing

- Tests run against `tests/mock_agent.lua`, never a real agent. When you add
  protocol behaviour, teach the mock to exercise it and assert on the result.
- The mock runs under `nvim -l`, so it can use `vim.json`. It reads stdin
  synchronously; `request()` blocks until the matching response arrives.
- The mock takes flags: `--legacy` (modes/models instead of configOptions),
  `--threads=load,list,...` (session capabilities) and `--seed` (past sessions
  to list and load). Thread tests register extra mock agents with these.
- Use `wait_for(fn, what)` for anything async; it fails after 5 s.
- Tests share one Neovim instance. Clean up buffers (`bwipeout!`), restore
  stubs such as `vim.ui.select`, and reset config you change.
- Real-agent checks are manual and need network access and a login, so keep
  them out of the suite. When running a Claude agent from inside a Claude Code
  session, unset `CLAUDECODE` first or the agent refuses to start.

## Gotchas learned the hard way

- **Filetypes.** Chat buffers use `conduit` / `conduit_input`, not `markdown`,
  so markdown linters and LSPs leave them alone. The
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

- **session/load replays before it responds.** The history arrives as
  `session/update` notifications ahead of the response, so `_open_session`
  registers the handler under the known session id *before* sending the
  request. Otherwise the replay is silently dropped.
- **Slash commands arrive after `session/new` responds** (Claude's adapter
  sends `available_commands_update` a moment later), and the inline prompt
  opens before any session exists. Read commands lazily through the buffer's
  source function, and fall back to `agent.last_commands`.
- **Tool titles can contain newlines** (multi-line shell commands). Anything
  written with `nvim_buf_set_lines` must be split or trimmed first.

## Making changes

- Keep README.md and doc/conduit.txt in sync with user-facing changes
  (commands, keymaps, config, behaviour).
- Add a test for every bug fix and feature. Tests should fail without the change.
- Don't add runtime dependencies. Optional integrations must be detected
  (`package.loaded[...]`), never required unconditionally.
- Commit messages: imperative subject under ~70 chars, body explaining why.
