-- One Claude Code session over ACP: starts the adapter, sends prompts, and routes its updates to the UI.

local Rpc = require("dalil.rpc")
local ui = require("dalil.ui")
local permission = require("dalil.permission")
local conversations = require("dalil.conversations")

local M = {}

local PLUGIN_ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local SYSTEM_PROMPT = [=[
You are running inside Neovim, in the dalil.nvim chat. The user reads your replies in an editor buffer where every file reference becomes a link that opens the file in their code window. Whenever you mention specific code, cite it as path:line or path:start-end (for example src/app.ts:42 or src/app.ts:42-58), with the path relative to the working directory, or starting with ~/ for files outside it (such as the Neovim config). Don't wrap the reference in a markdown link.

A message may start with an <editor-context> block saying which file and line the user has open. The user doesn't see it.

When the user asks about errors or warnings, or what Neovim is showing, look at their running Neovim with the dalil-nvim command:
  dalil-nvim diagnostics [path...]   LSP and linter diagnostics for these files, or every open buffer
  dalil-nvim open <path...>          load files so their language servers report diagnostics (wait a moment, then ask for diagnostics)
  dalil-nvim buffers                 open file buffers and the language servers attached to each
  dalil-nvim messages                recent :messages, where Neovim's own errors show up
  dalil-nvim lua '<code>'            run Lua in their Neovim and print the result, to check an option or reload a module
Don't run those unless the question calls for it.

dalil-nvim also asks the language servers running in their Neovim, which have already indexed the project and see unsaved edits. Prefer these to grep when you need to know what a symbol is or how code connects:
  dalil-nvim definition <path:line[:col]> [symbol]       where the symbol is defined (also type-definition, implementation)
  dalil-nvim references <path:line[:col]> [symbol]       every use of it across the project
  dalil-nvim hover <path:line[:col]> [symbol]            its type and docs
  dalil-nvim calls <path:line[:col]> [symbol]            who calls this function, and what it calls
  dalil-nvim symbols <path>                              outline of a file
  dalil-nvim workspace-symbols <query>                   find a symbol by name across the project
Without a column, [symbol] names the word on that line to ask about, e.g. dalil-nvim definition src/app.ts:42 fetchJobs.

You can also annotate their code in the editor with hints: short notes shown above lines, like the ones the user asks for with :DalilHint. Use them when the user asks for hints, notes or annotations in their code:
  dalil-nvim hint <path:line[-end]> '<text>'   show a hint above those lines (replaces any hint it overlaps)
  dalil-nvim hints [path]                      the hints showing, and where
  dalil-nvim hint-delete <path[:line[-end]]>   delete hints in a file, or on those lines
A hint is one plain-text sentence of at most 20 words saying what the code does and why it's there, not restating the syntax. Put it on the line or range it explains (for a function, its signature line). Line numbers are the buffer's current ones; a hint disappears if the user edits its lines.

The user's Neovim config is at %s, and you may read and edit it. It's LazyVim: lua/config/ holds options.lua, keymaps.lua, autocmds.lua and lazy.lua (which LazyVim extras are on), and lua/plugins/ holds one plugin spec per file. Installed plugins' source is under %s. This chat is the dalil.nvim plugin, at %s. A changed plugin spec takes effect after the user restarts Neovim; say so rather than trying to reload it.]=]

local state = {
  rpc = nil, ---@type table?
  session_id = nil, ---@type string?
  starting = false,
  queue = {}, ---@type fun()[]
  modes = {}, ---@type { id: string, name: string }[]
  config_options = {}, ---@type table[]
  commands = {}, ---@type { name: string, description?: string }[]
  busy = false,
  conv = nil, ---@type dalil.Conversation?
  config = {}, ---@type dalil.Config
}

local function mode_name(id)
  for _, mode in ipairs(state.modes) do
    if mode.id == id then
      return mode.name
    end
  end
  return id
end

local function model_option()
  for _, option in ipairs(state.config_options) do
    if option.id == "model" or option.category == "model" then
      return option
    end
  end
end

local function render_model()
  local option = model_option()
  if not option then
    return
  end
  for _, choice in ipairs(option.options or {}) do
    if choice.value == option.currentValue then
      ui.set_status({ model = choice.name })
      return
    end
  end
  ui.set_status({ model = option.currentValue })
end

local function set_busy(busy)
  state.busy = busy
  ui.set_status({ busy = busy })
end

---The open conversation, created on first use.
---@return dalil.Conversation
local function conv()
  if not state.conv then
    state.conv = conversations.new(vim.fn.getcwd())
  end
  return state.conv
end

local function persist()
  if state.conv and state.conv.saved then
    conversations.write(state.conv)
  end
end

---Adds an event to the conversation, merging streamed text into the event it continues.
---@param event dalil.Event
local function record(event)
  local events = conv().events
  local last = events[#events]
  if (event.type == "agent" or event.type == "thought") and last and last.type == event.type then
    last.text = last.text .. event.text
  else
    table.insert(events, event)
  end
end

local function record_tool(id, update)
  local events = conv().events
  for i = #events, 1, -1 do
    local event = events[i]
    if event.type == "tool" and event.id == id then
      event.title = update.title or event.title
      event.status = update.status or event.status
      event.kind = update.kind or event.kind
      return
    end
  end
  table.insert(events, { type = "tool", id = id, title = update.title or "Tool", status = update.status or "pending", kind = update.kind })
end

local function notice(text, hl)
  ui.notice(text, hl)
  record({ type = "notice", text = text, hl = hl })
end

local function render_saved()
  ui.set_status({ saved = state.conv ~= nil and state.conv.saved, title = state.conv and state.conv.title or "" })
end

local function on_update(update)
  local kind = update.sessionUpdate
  if kind == "agent_message_chunk" then
    if update.content and update.content.type == "text" then
      ui.agent_text(update.content.text)
      record({ type = "agent", text = update.content.text })
    end
  elseif kind == "agent_thought_chunk" then
    if state.config.show_thinking and update.content and update.content.type == "text" then
      ui.thought_text(update.content.text)
      record({ type = "thought", text = update.content.text })
    end
  elseif kind == "tool_call" or kind == "tool_call_update" then
    local tool = ui.tool(update.toolCallId, { title = update.title, status = update.status, kind = update.kind })
    record_tool(update.toolCallId, update)
    if update.status == "completed" and tool and tool.kind == "edit" then
      vim.cmd.checktime()
    end
  elseif kind == "current_mode_update" then
    ui.set_status({ mode = mode_name(update.currentModeId) })
  elseif kind == "config_option_update" then
    state.config_options = update.configOptions or state.config_options
    render_model()
  elseif kind == "available_commands_update" then
    state.commands = update.availableCommands or {}
  elseif kind == "session_info_update" then
    if update.title then
      conv().title = update.title
      ui.set_status({ title = update.title })
      persist()
    end
  elseif kind == "usage_update" then
    if update.used and update.size and update.size > 0 then
      ui.set_status({ context = string.format("%d%% ctx", math.floor(update.used / update.size * 100 + 0.5)) })
    end
  end
end

local function on_request(method, params, respond)
  if method == "session/request_permission" then
    permission.ask(params, respond)
  else
    respond(nil, { code = -32601, message = "dalil.nvim doesn't handle " .. method })
  end
end

local function on_exit(code)
  local was_running = state.rpc ~= nil
  state.rpc, state.session_id, state.starting = nil, nil, false
  set_busy(false)
  if was_running and code ~= 0 and code ~= 143 then
    notice("Claude stopped (exit code " .. code .. "). Your next message continues the conversation.", "DalilError")
  end
end

local function flush_queue()
  local queue = state.queue
  state.queue = {}
  for _, fn in ipairs(queue) do
    fn()
  end
end

local function system_prompt()
  local text = SYSTEM_PROMPT:format(
    vim.fn.fnamemodify(vim.fn.stdpath("config"), ":~"),
    vim.fn.fnamemodify(vim.fn.stdpath("data") .. "/lazy", ":~"),
    vim.fn.fnamemodify(PLUGIN_ROOT, ":~")
  )
  return { mode = "append", content = { { type = "text", text = text } } }
end

---The Neovim config, so Claude can read and edit it from any project.
local function additional_directories(cwd)
  local config = vim.fn.resolve(vim.fn.stdpath("config"))
  if vim.startswith(vim.fn.resolve(cwd) .. "/", config .. "/") then
    return {}
  end
  return { config }
end

---A session finished starting; `owner` is the conversation it was started for.
local function session_ready(result, owner)
  if state.conv ~= owner then
    -- You switched conversations while it started; drop it.
    state.rpc:request("session/close", { sessionId = result.sessionId })
    return
  end
  state.starting = false
  state.session_id = result.sessionId
  conv().session_id = result.sessionId
  state.modes = result.modes and result.modes.availableModes or state.modes
  state.config_options = result.configOptions or state.config_options
  if result.modes then
    ui.set_status({ mode = mode_name(result.modes.currentModeId) })
  end
  render_model()
  if state.config.mode then
    M.set_mode(state.config.mode)
  end
  flush_queue()
end

local function session_failed(err)
  state.starting = false
  state.queue = {}
  set_busy(false)
  notice("Couldn't start a session: " .. (err and err.message or "no result"), "DalilError")
end

---@param owner dalil.Conversation
local function create_session(owner)
  state.rpc:request("session/new", {
    cwd = owner.cwd,
    mcpServers = {},
    additionalDirectories = additional_directories(owner.cwd),
    systemPrompt = system_prompt(),
  }, function(err, result)
    if state.conv ~= owner then
      return
    end
    if err or not result then
      return session_failed(err)
    end
    session_ready(result, owner)
  end)
end

---Starts a Claude session for the open conversation: resumes its earlier one when it has one.
local function new_session()
  local current = conv()
  ui.set_cwd(current.cwd)
  if not current.session_id then
    return create_session(current)
  end
  local resume_id = current.session_id
  state.rpc:request("session/resume", {
    sessionId = resume_id,
    cwd = current.cwd,
    mcpServers = {},
    additionalDirectories = additional_directories(current.cwd),
    systemPrompt = system_prompt(),
  }, function(err, result)
    if state.conv ~= current then
      return
    end
    if err then
      notice("Couldn't resume the Claude session, so this continues in a new one that doesn't remember the earlier messages.", "DalilError")
      return create_session(current)
    end
    result = result or {}
    result.sessionId = result.sessionId or resume_id
    session_ready(result, current)
  end)
end

local function agent_env()
  local env = {}
  local claude = vim.fn.exepath(state.config.claude_cmd)
  if claude ~= "" then
    env.CLAUDE_CODE_EXECUTABLE = claude
  end
  if state.config.show_thinking then
    env.CLAUDE_CODE_THINKING_DISPLAY = "summarized"
  end
  local server = vim.v.servername ~= "" and vim.v.servername or vim.fn.serverstart()
  env.DALIL_NVIM = server
  env.PATH = PLUGIN_ROOT .. "/bin:" .. vim.env.PATH
  return vim.tbl_extend("force", env, state.config.env or {})
end

---Runs `fn` once a session is ready, starting the adapter and a session if needed.
local function with_session(fn)
  if state.session_id then
    return fn()
  end
  table.insert(state.queue, fn)
  if state.starting then
    return
  end
  state.starting = true
  if state.rpc then
    return new_session()
  end
  ui.set_status({ mode = "starting…" })
  state.rpc = Rpc.start({
    cmd = state.config.cmd,
    env = agent_env(),
    on_request = on_request,
    on_notification = function(method, params)
      if method == "session/update" and params.sessionId == state.session_id then
        on_update(params.update or {})
      end
    end,
    on_exit = on_exit,
  })
  state.rpc:request("initialize", {
    protocolVersion = 1,
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false },
    clientInfo = { name = "dalil.nvim", version = "0.1.0" },
  }, function(err)
    if err then
      state.starting = false
      state.queue = {}
      notice("Couldn't start Claude: " .. (err.message or vim.inspect(err)), "DalilError")
      return
    end
    new_session()
  end)
end

---@param config dalil.Config
function M.configure(config)
  state.config = config
end

function M.ensure_started()
  with_session(function() end)
end

---@param opts { text: string, context?: { path: string, line: integer } }
function M.prompt(opts)
  ui.user_message(opts.text)
  record({ type = "user", text = opts.text })
  persist()
  set_busy(true)
  with_session(function()
    local blocks = {}
    if opts.context then
      table.insert(blocks, {
        type = "text",
        text = string.format("<editor-context>\nThe user has %s open, cursor on line %d.\n</editor-context>", opts.context.path, opts.context.line),
      })
    end
    table.insert(blocks, { type = "text", text = opts.text })
    state.rpc:request("session/prompt", { sessionId = state.session_id, prompt = blocks }, function(err, result)
      set_busy(false)
      if err then
        notice("Error: " .. (err.message or vim.inspect(err)), "DalilError")
      elseif result and result.stopReason == "cancelled" then
        notice("Cancelled.")
      elseif result and result.stopReason ~= "end_turn" then
        notice("Stopped: " .. tostring(result.stopReason))
      end
      persist()
    end)
  end)
end

function M.cancel()
  if state.rpc and state.session_id and state.busy then
    state.rpc:notify("session/cancel", { sessionId = state.session_id })
  end
end

---@param mode_id string
function M.set_mode(mode_id)
  with_session(function()
    state.rpc:request("session/set_mode", { sessionId = state.session_id, modeId = mode_id }, function(err)
      if err then
        notice("Couldn't switch mode: " .. (err.message or ""), "DalilError")
      else
        ui.set_status({ mode = mode_name(mode_id) })
      end
    end)
  end)
end

function M.pick_mode()
  with_session(function()
    vim.ui.select(state.modes, {
      prompt = "Permission mode",
      format_item = function(mode)
        return mode.name .. (mode.description and ("  — " .. mode.description) or "")
      end,
    }, function(choice)
      if choice then
        M.set_mode(choice.id)
      end
    end)
  end)
end

function M.pick_model()
  with_session(function()
    local option = model_option()
    if not option then
      return vim.notify("This session has no model option", vim.log.levels.WARN)
    end
    vim.ui.select(option.options or {}, {
      prompt = "Model",
      format_item = function(choice)
        return choice.name .. (choice.description and ("  — " .. choice.description) or "")
      end,
    }, function(choice)
      if not choice then
        return
      end
      state.rpc:request("session/set_config_option", { sessionId = state.session_id, configId = option.id, value = choice.value }, function(err, result)
        if err then
          notice("Couldn't switch model: " .. (err.message or ""), "DalilError")
          return
        end
        if result and result.configOptions then
          state.config_options = result.configOptions
        else
          option.currentValue = choice.value
        end
        render_model()
      end)
    end)
  end)
end

---@return { name: string, description?: string }[]
function M.commands()
  return state.commands
end

local function close_session()
  if state.rpc and state.session_id then
    M.cancel()
    state.rpc:request("session/close", { sessionId = state.session_id })
  end
  state.session_id = nil
  state.starting = false
  state.queue = {}
  set_busy(false)
end

---Starts a fresh conversation; a saved one stays in the history.
function M.reset()
  close_session()
  state.conv = nil
  ui.clear()
  render_saved()
end

---Shows a saved conversation; the next message continues its Claude session.
---@param saved dalil.Conversation
---The open conversation, if one has started.
---@return dalil.Conversation?
function M.current()
  return state.conv
end

function M.open_conversation(saved)
  close_session()
  state.conv = saved
  ui.clear()
  ui.set_cwd(saved.cwd)
  for _, event in ipairs(saved.events) do
    if event.type == "user" then
      ui.user_message(event.text)
    elseif event.type == "agent" then
      ui.agent_text(event.text)
    elseif event.type == "thought" then
      if state.config.show_thinking then
        ui.thought_text(event.text)
      end
    elseif event.type == "tool" then
      ui.tool(event.id, { title = event.title, status = event.status, kind = event.kind })
    elseif event.type == "notice" then
      ui.notice(event.text, event.hl)
    end
  end
  render_saved()
  ui.scroll_to_end()
end

---Saves the open conversation; from then on it saves after every message.
function M.save()
  local current = conv()
  if conversations.question_count(current) == 0 then
    return vim.notify("dalil: nothing to save yet", vim.log.levels.INFO)
  end
  if current.saved then
    return vim.notify("dalil: this conversation is already saved", vim.log.levels.INFO)
  end
  current.saved = true
  conversations.write(current)
  render_saved()
end

---Lists saved conversations and opens the one picked.
---@param opts { all: boolean } all projects, not just the current directory's
function M.pick_conversation(opts)
  local saved = conversations.list({ cwd = (not opts.all) and vim.fn.getcwd() or nil })
  if #saved == 0 then
    return vim.notify("dalil: no saved conversations" .. (opts.all and "" or " for this directory (:DalilHistory! lists all)"), vim.log.levels.INFO)
  end
  vim.ui.select(saved, {
    prompt = opts.all and "Saved conversations" or ("Saved conversations in " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~")),
    format_item = function(item)
      local parts = { conversations.display_title(item), conversations.question_count(item) .. " questions", conversations.ago(item.updated_at) }
      if opts.all then
        table.insert(parts, vim.fn.fnamemodify(item.cwd, ":~"))
      end
      return table.concat(parts, " · ")
    end,
  }, function(choice)
    if choice then
      M.open_conversation(choice)
    end
  end)
end

function M.rename()
  local current = conv()
  vim.ui.input({ prompt = "Conversation title: ", default = conversations.display_title(current) }, function(title)
    if title and vim.trim(title) ~= "" then
      current.title = vim.trim(title)
      persist()
      render_saved()
    end
  end)
end

---Deletes the open conversation from the saved ones and starts a fresh one.
function M.delete()
  local current = state.conv
  if not current or not current.saved then
    return vim.notify("dalil: this conversation isn't saved", vim.log.levels.INFO)
  end
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete “" .. conversations.display_title(current) .. "”?" }, function(choice)
    if choice == "Delete" then
      conversations.delete(current.id)
      M.reset()
    end
  end)
end

function M.stop()
  if state.rpc then
    local rpc = state.rpc
    state.rpc = nil
    rpc:stop()
  end
end

return M
