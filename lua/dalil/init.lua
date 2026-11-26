local session = require("dalil.session")
local ui = require("dalil.ui")
local vim_session = require("dalil.vim_session")

local M = {}

---@class dalil.Config
---@field cmd string[] the ACP adapter command
---@field claude_cmd string the Claude Code CLI the adapter runs
---@field env? table<string, string> extra environment for the adapter
---@field mode? string permission mode to start sessions in ("default", "acceptEdits", "plan", "auto", "bypassPermissions"); nil keeps your Claude Code default
---@field width dalil.Width chat width as a fraction of Neovim: a number, or { narrow, wide, breakpoint } to use `wide` when Neovim's pane takes at least `breakpoint` of the screen (herdr or tmux)
---@field input_height integer
---@field refs dalil.RefStyle how references show: "snippet" (the cited code), "short" (shortest unique file name) or "full" (the path as written)
---@field background string|false|nil the chat's background: a hex colour, false to keep it transparent like the editor, nil for the colorscheme's float background a little darker (solid even when the terminal is translucent)
---@field show_thinking boolean show Claude's thinking as a dimmed quote in the transcript
local defaults = {
  cmd = { "claude-agent-acp" },
  claude_cmd = "claude",
  env = nil,
  mode = nil,
  width = { narrow = 0.38, wide = 0.4, breakpoint = 0.6 },
  input_height = 6,
  show_thinking = true,
  background = nil,
  refs = "snippet",
}

M.config = vim.deepcopy(defaults)

---`color` (0xRRGGBB) with each channel scaled by `factor`.
local function shade(color, factor)
  local r, g, b = bit.rshift(color, 16), bit.band(bit.rshift(color, 8), 0xff), bit.band(color, 0xff)
  local function scale(channel)
    return math.min(math.floor(channel * factor + 0.5), 255)
  end
  return string.format("#%02x%02x%02x", scale(r), scale(g), scale(b))
end

---The chat's background, or nil to leave it transparent.
local function chat_background()
  if M.config.background == false then
    return nil
  end
  if type(M.config.background) == "string" then
    return M.config.background
  end
  -- A terminal draws its default background colour translucent, so match the theme but not that exact colour.
  for _, group in ipairs({ "NormalFloat", "Normal" }) do
    local bg = vim.api.nvim_get_hl(0, { name = group, link = false }).bg
    if bg then
      return shade(bg, 0.9)
    end
  end
end

local function set_highlights()
  local bg = chat_background()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  vim.api.nvim_set_hl(0, "DalilNormal", { fg = normal.fg, bg = bg })
  -- Chips stand out from the cursor line: a shade lighter than it, in the info colour; the one under the cursor is inverted.
  local info = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false }).fg or vim.api.nvim_get_hl(0, { name = "Function", link = false }).fg
  local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg or vim.api.nvim_get_hl(0, { name = "Pmenu", link = false }).bg
  vim.api.nvim_set_hl(0, "DalilRefChip", { fg = info, bg = cursorline and shade(cursorline, 1.25) or nil })
  vim.api.nvim_set_hl(0, "DalilRefChipActive", { fg = bg or normal.bg or 0, bg = info, bold = true })
  local winbar = vim.api.nvim_get_hl(0, { name = "WinBar", link = false })
  vim.api.nvim_set_hl(0, "DalilWinBar", { fg = winbar.fg, bold = winbar.bold, bg = bg })

  local links = {
    DalilRef = "Underlined",
    DalilRefFlash = "IncSearch",
    DalilTitle = "Title",
    DalilInputTitle = "Title",
    DalilUserHeader = "DiffText",
    DalilAgentHeader = "DiffAdd",
    DalilTool = "Comment",
    DalilToolPending = "DiagnosticWarn",
    DalilToolDone = "DiagnosticOk",
    DalilToolFailed = "DiagnosticError",
    DalilNotice = "Comment",
    DalilThought = "Comment",
    DalilError = "DiagnosticError",
    DalilBusy = "DiagnosticWarn",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target })
  end
end

local function prepare()
  ui.setup_buffers({ send = M.send, cancel = session.cancel, close = M.close })
end

function M.open()
  prepare()
  ui.open({ width = M.config.width, input_height = M.config.input_height })
  session.ensure_started()
end

function M.close()
  ui.close()
end

function M.toggle()
  if ui.is_open() then
    M.close()
  else
    M.open()
  end
end

---Sends the input buffer's text.
function M.send()
  local text = ui.take_input()
  if text == "" then
    return
  end
  session.prompt({ text = text, context = ui.code_context() })
  vim.cmd("stopinsert")
end

---Sends `text` as a message, opening the chat if needed.
---@param text string
function M.ask(text)
  if not ui.is_open() then
    M.open()
  end
  session.prompt({ text = text, context = ui.code_context() })
end

---Adds a `path:start-end` reference for the given lines to the message being written.
---@param opts { line1: integer, line2: integer }
function M.add_range(opts)
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return vim.notify("dalil: this buffer has no file", vim.log.levels.WARN)
  end
  local path = vim.fn.fnamemodify(name, ":.")
  local ref = opts.line1 == opts.line2 and string.format("%s:%d", path, opts.line1) or string.format("%s:%d-%d", path, opts.line1, opts.line2)
  M.open()
  ui.append_input(ref)
  ui.focus_input({ insert = true })
end

---Adds a reference to the current file to the message being written.
function M.add_file()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return vim.notify("dalil: this buffer has no file", vim.log.levels.WARN)
  end
  M.open()
  ui.append_input(vim.fn.fnamemodify(name, ":."))
  ui.focus_input({ insert = true })
end

function M.new()
  prepare()
  session.reset()
  if not ui.is_open() then
    M.open()
  end
end

---Brings back the chat as the Vim session that was just loaded left it.
function M.restore()
  local saved = vim_session.read()
  if not saved then
    return
  end
  if saved.conversation then
    prepare()
    session.open_conversation(saved.conversation)
  end
  if saved.open then
    local code_win = vim.api.nvim_get_current_win()
    M.open()
    if vim.api.nvim_win_is_valid(code_win) then
      vim.api.nvim_set_current_win(code_win)
    end
  elseif ui.is_open() then
    M.close()
  end
end

---@param opts? dalil.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  session.configure(M.config)
  require("dalil.refs").configure({ style = M.config.refs })
  set_highlights()

  local group = vim.api.nvim_create_augroup("dalil", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = session.stop })
  -- persistence.nvim writes its session from a VimLeavePre autocmd, where SessionWritePost doesn't fire
  -- (autocmds don't nest), so it gets its own event.
  vim.api.nvim_create_autocmd({ "SessionWritePost", "User" }, {
    group = group,
    pattern = { "*", "PersistenceSavePost" },
    callback = function(event)
      if event.event == "User" and event.match ~= "PersistenceSavePost" then
        return
      end
      vim_session.write({ conversation = session.current(), open = ui.is_open() })
    end,
  })
  vim.api.nvim_create_autocmd("SessionLoadPost", {
    group = group,
    callback = function()
      vim.schedule(M.restore)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      ui.resize(M.config.width)
    end,
  })

  local commands = {
    Dalil = { M.toggle, "Toggle the Claude chat" },
    DalilOpen = { M.open, "Open the Claude chat" },
    DalilNew = { M.new, "Start a new Claude session" },
    DalilSave = { session.save, "Save the Claude conversation" },
    DalilRename = { session.rename, "Rename the Claude conversation" },
    DalilDelete = { session.delete, "Delete the saved Claude conversation" },
    DalilAddFile = { M.add_file, "Reference the current file in the Claude chat" },
    DalilCancel = { session.cancel, "Cancel Claude's current turn" },
    DalilMode = { session.pick_mode, "Pick Claude's permission mode" },
    DalilModel = { session.pick_model, "Pick Claude's model" },
  }
  for name, spec in pairs(commands) do
    vim.api.nvim_create_user_command(name, spec[1], { desc = spec[2] })
  end
  vim.api.nvim_create_user_command("DalilHistory", function(cmd)
    if not ui.is_open() then
      M.open()
    end
    session.pick_conversation({ all = cmd.bang })
  end, { bang = true, desc = "Open a saved Claude conversation (! for every directory)" })
  vim.api.nvim_create_user_command("DalilAdd", function(cmd)
    M.add_range({ line1 = cmd.line1, line2 = cmd.line2 })
  end, { range = true, desc = "Reference these lines in the Claude chat" })
  vim.api.nvim_create_user_command("DalilAsk", function(cmd)
    M.ask(cmd.args)
  end, { nargs = "+", desc = "Ask Claude" })
end

return M
