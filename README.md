# dalil.nvim

A Claude Code chat inside Neovim. When Claude mentions code as `path:line`, the reference becomes a link: press `<CR>` on it to open that file at that line in your code window, or `K` to preview the lines in a float.

It talks to Claude Code through the [Agent Client Protocol](https://agentclientprotocol.com) (ACP), using the [`claude-agent-acp`](https://github.com/agentclientprotocol/claude-agent-acp) adapter. The adapter runs your local `claude`, so it uses your Claude Code login (subscription, not an API key) and loads your user and project settings: skills, plugins, hooks and `CLAUDE.md`.

## Requirements

- Neovim 0.11 or later
- Claude Code installed and signed in, as `claude` on your `PATH`
- The adapter: `npm install -g @agentclientprotocol/claude-agent-acp`

Run `:checkhealth dalil` to check all three. If `ANTHROPIC_API_KEY` is set in Neovim's environment, Claude Code bills the API instead of your subscription; the health check warns about it.

## Install (lazy.nvim)

```lua
{
  dir = "~/Projects/dalil.nvim",
  name = "dalil.nvim",
  event = "VeryLazy", -- so restoring a Vim session can bring back its chat
  cmd = { "Dalil", "DalilOpen", "DalilNew", "DalilAsk", "DalilAdd", "DalilAddFile", "DalilMode", "DalilModel", "DalilCancel", "DalilSave", "DalilHistory", "DalilRename", "DalilDelete" },
  opts = {},
  keys = {
    { "<leader>a", "", desc = "+ai", mode = { "n", "v" } },
    { "<leader>ac", "<cmd>Dalil<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>DalilOpen<cr>", desc = "Focus Claude" },
    { "<leader>an", "<cmd>DalilNew<cr>", desc = "New Claude session" },
    { "<leader>aS", "<cmd>DalilSave<cr>", desc = "Save Claude conversation" },
    { "<leader>ah", "<cmd>DalilHistory<cr>", desc = "Saved conversations (this project)" },
    { "<leader>aH", "<cmd>DalilHistory!<cr>", desc = "Saved conversations (all)" },
    { "<leader>ab", "<cmd>DalilAddFile<cr>", desc = "Add current buffer" },
    { "<leader>as", ":DalilAdd<cr>", mode = "v", desc = "Send selection to Claude" },
    { "<leader>am", "<cmd>DalilMode<cr>", desc = "Claude permission mode" },
    { "<leader>aM", "<cmd>DalilModel<cr>", desc = "Claude model" },
    { "<leader>ax", "<cmd>DalilCancel<cr>", desc = "Cancel Claude" },
  },
}
```

## Options

```lua
{
  cmd = { "claude-agent-acp" }, -- the ACP adapter
  claude_cmd = "claude",        -- the Claude Code CLI the adapter runs
  env = nil,                    -- extra environment for the adapter
  mode = nil,                   -- "default" | "acceptEdits" | "plan" | "auto" | "bypassPermissions"; nil keeps your Claude Code default
  width = { narrow = 0.38, wide = 0.4, breakpoint = 0.6 }, -- chat width as a fraction of Neovim: `wide` when Neovim's pane takes at least `breakpoint` of the screen (asks herdr or tmux), else `narrow`; or a plain number
  input_height = 6,
  show_thinking = true,
  background = nil,             -- chat background: nil = the colorscheme's float colour a little darker (solid even in a translucent terminal), a hex colour, or false to stay transparent
  refs = "snippet",             -- how references show: "snippet" (the cited code), "short" (shortest unique file name) or "full" (the path as written)         -- show Claude's thinking, collapsed to one line until you press <Tab> on it
}
```

## Using it

`:Dalil` opens the chat on the right: the transcript on top, the message box under it. The first message starts Claude in Neovim's working directory.

Each message also tells Claude which file and line your code window has open, so "what does this function do" works without naming the file.

| Where | Key | Does |
|---|---|---|
| Message box | `<CR>` (normal), `<C-s>` | Send |
| Message box, transcript | `<C-c>` | Cancel Claude's turn |
| Message box, transcript | `q` | Close the chat |
| Transcript | `<CR>`, `gr`, `gf` | Open the reference under the cursor in the code window |
| Transcript | `K` | Preview the reference in a float |
| Transcript | `]r`, `[r` | Next, previous reference |
| Transcript | `<Tab>` | Expand or collapse the thinking block under the cursor |
| Transcript | `i`, `a`, `o` | Jump to the message box |

References show as chips. By default a chip shows the first line of the cited code (`spawn("claude", claudeArgs(…`), or the file name when that line is blank or only brackets. `K` shows where it points and the lines around it. With `refs = "short"` chips show the shortest file name that tells the cited files apart (`main/ask.ts:54`).

When you move from your code back to the chat with `<C-w>` or `<C-h>`/`<C-l>`, you land in the chat window you left: the transcript where you were reading, or the message box.

`:DalilAdd` (or a visual selection with `<leader>as`) puts `path:start-end` for those lines into the message box. Slash commands and skills work as messages: type `/review`.

When Claude wants to run a tool that needs permission, a float shows the diff or command and a picker asks which answer to give. Closing the picker answers No. When Claude edits a file you have open, the buffer reloads.

The status bar shows the conversation's title, whether it's saved, the permission mode, the model and how full the context is. `:DalilMode` and `:DalilModel` change the mode and model.

## Diagnostics and your Neovim config

Claude can look at your running Neovim when you ask about it ("what errors am I getting?"). The chat puts a `dalil-nvim` command on Claude's `PATH`, connected to your Neovim through its RPC socket:

| Command | Shows |
|---|---|
| `dalil-nvim diagnostics [path...]` | LSP and linter diagnostics for those files, or every open buffer |
| `dalil-nvim open <path...>` | loads files so their language servers report diagnostics |
| `dalil-nvim buffers` | open file buffers and the language servers attached to each |
| `dalil-nvim messages` | recent `:messages`, where Neovim's own errors show up |
| `dalil-nvim lua '<code>'` | runs Lua in your Neovim and prints the result |

Claude runs it only when your question calls for it; diagnostics aren't sent with every message.

Your Neovim config (`stdpath("config")`) is added to every session's directories, so Claude can read and edit it from any project, and the system prompt says how a LazyVim config is laid out. References into the config become links too.

## Saved conversations

A new conversation isn't saved: it's gone when you start another one or quit. `:DalilSave` saves it with everything so far, and from then on it saves after every message. Saved conversations live in `stdpath("data")/dalil/conversations`, one JSON file each.

`:DalilHistory` lists the saved conversations started in the current directory, most recent first; `:DalilHistory!` lists every directory's. Opening one shows its transcript, and your next message continues its Claude session, so Claude remembers it. `:DalilRename` changes its title (Claude names it after the first message), and `:DalilDelete` deletes it.

`:DalilNew` starts a fresh conversation; a saved one stays in the history.

## Vim sessions

Writing a session (`:mksession`, or persistence.nvim, which LazyVim uses for "Restore Session") also records the chat's conversation and whether the chat was open. Loading that session brings the conversation back, continuing its Claude session, and reopens the chat if it was open. This works for unsaved conversations too; they still don't appear in `:DalilHistory`. The plugin has to be loaded before the session is, hence `event = "VeryLazy"` above.

## How references are found

After each update the transcript is scanned for words that look like paths (they contain `/` or `.`) and name a file that exists, relative to the session's working directory or absolute. A position after the path is optional: `:42`, `:42-58`, `:42:7`, `#L42` or `#L42-L58`. The session's system prompt asks Claude to cite code in that form.
