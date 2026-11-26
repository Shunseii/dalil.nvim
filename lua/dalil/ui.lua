-- The chat layout: a transcript buffer with an input buffer under it, in a split on the right.

local refs = require("dalil.refs")

local M = {}

local ns = vim.api.nvim_create_namespace("dalil_chat")
local anchor_ns = vim.api.nvim_create_namespace("dalil_tool_anchors")

local state = {
  chat_buf = nil, ---@type integer?
  input_buf = nil, ---@type integer?
  chat_win = nil, ---@type integer?
  input_win = nil, ---@type integer?
  code_win = nil, ---@type integer?
  cwd = vim.fn.getcwd(),
  block = nil, ---@type "user"|"agent"|"tool"|"notice"|nil
  agent_header = false,
  thoughts = {}, ---@type { mark: integer, text: string, expanded: boolean, body_count: integer }[]
  thought = nil,
  tools = {}, ---@type table<string, { mark: integer, title: string, status: string, kind?: string }>
  status = {},
  scan_timer = nil,
}

local schedule_scan

local STATUS_ICON = { pending = "○", in_progress = "◐", completed = "✓", failed = "✗" }
local STATUS_HL = { pending = "DalilToolPending", in_progress = "DalilToolPending", completed = "DalilToolDone", failed = "DalilToolFailed" }

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function scratch_buf(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, opts.name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = opts.filetype
  return buf
end

---@param handlers { send: fun(), cancel: fun(), close: fun() }
function M.setup_buffers(handlers)
  if valid_buf(state.chat_buf) then
    return
  end
  state.chat_buf = scratch_buf({ name = "dalil://chat", filetype = "dalil" })
  vim.bo[state.chat_buf].modifiable = false
  vim.treesitter.language.register("markdown", "dalil")
  pcall(vim.treesitter.start, state.chat_buf, "markdown")

  state.input_buf = scratch_buf({ name = "dalil://input", filetype = "dalil_input" })
  vim.treesitter.language.register("markdown", "dalil_input")
  pcall(vim.treesitter.start, state.input_buf, "markdown")

  local function map(buf, mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, nowait = true })
  end

  local function open_ref()
    local ref = refs.at_cursor()
    if ref then
      refs.open(ref, M.code_window())
    end
  end

  local function preview_ref()
    local ref = refs.at_cursor()
    if ref then
      refs.preview(ref)
    end
  end

  local chat = state.chat_buf
  map(chat, "n", "<CR>", open_ref, "Open reference")
  map(chat, "n", "gf", open_ref, "Open reference")
  map(chat, "n", "gr", open_ref, "Go to reference")
  map(chat, "n", "K", preview_ref, "Preview reference")
  map(chat, "n", "<Tab>", function()
    if not M.toggle_thought() then
      refs.jump(1)
    end
  end, "Expand/collapse thinking")
  map(chat, "n", "]r", function() refs.jump(1) end, "Next reference")
  map(chat, "n", "[r", function() refs.jump(-1) end, "Previous reference")
  map(chat, "n", "q", handlers.close, "Close chat")
  map(chat, "n", "<C-c>", handlers.cancel, "Cancel")
  for _, key in ipairs({ "i", "a", "o", "I", "A", "O" }) do
    map(chat, "n", key, function() M.focus_input({ insert = true }) end, "Write a message")
  end

  local input = state.input_buf
  map(input, "n", "<CR>", handlers.send, "Send")
  map(input, "i", "<C-s>", handlers.send, "Send")
  map(input, "n", "<C-s>", handlers.send, "Send")
  map(input, { "n", "i" }, "<C-c>", handlers.cancel, "Cancel")
  map(input, "n", "q", handlers.close, "Close chat")
  map(input, "n", "K", preview_ref, "Preview reference")
  map(input, "n", "gr", open_ref, "Go to reference")

  -- The cursor moves over a chip as if it were one character, and the chip under it shows selected.
  for _, buf in ipairs({ chat, input }) do
    map(buf, "n", "l", function() refs.move_right(vim.v.count1) end, "Right (over references)")
    map(buf, "n", "<Right>", function() refs.move_right(vim.v.count1) end, "Right (over references)")
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      callback = function()
        refs.snap()
        refs.update_active()
      end,
    })
  end
  vim.api.nvim_create_autocmd("CursorMovedI", { buffer = input, callback = refs.update_active })

  -- References typed, pasted or added to the message show as chips there too.
  vim.api.nvim_buf_attach(input, false, {
    on_lines = function()
      schedule_scan(input)
    end,
  })

  local group = vim.api.nvim_create_augroup("dalil_ui", { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if win == state.chat_win or win == state.input_win then
        state.last_agent = { win = win }
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local entering_agent = win == state.chat_win or win == state.input_win
      if not entering_agent then
        if not state.focusing and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" and vim.api.nvim_win_get_config(win).relative == "" then
          state.code_win = win
        end
        return
      end
      local previous = vim.fn.win_getid(vim.fn.winnr("#"))
      local from_outside = previous ~= state.chat_win and previous ~= state.input_win
      local last = state.last_agent
      if state.focusing or not from_outside or not last or not valid_win(last.win) then
        return
      end
      -- Coming back from the code: return to whichever chat window you left.
      vim.schedule(function()
        if vim.api.nvim_get_current_win() == win and last.win ~= win then
          vim.api.nvim_set_current_win(last.win)
        end
      end)
    end,
  })
end

local function remember_code_window()
  local win = vim.api.nvim_get_current_win()
  if win ~= state.chat_win and win ~= state.input_win and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
    state.code_win = win
  end
end

---The window references open in: the last code window you used, else any normal window, else a new split.
function M.code_window()
  if valid_win(state.code_win) then
    return state.code_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if win ~= state.chat_win and win ~= state.input_win and vim.bo[buf].buftype == "" and vim.api.nvim_win_get_config(win).relative == "" then
      state.code_win = win
      return win
    end
  end
  vim.api.nvim_set_current_win(state.chat_win)
  vim.cmd("leftabove vnew")
  state.code_win = vim.api.nvim_get_current_win()
  return state.code_win
end

---The file and cursor line of the code window, for the context Claude gets with each message.
---@return { path: string, line: integer }?
function M.code_context()
  local win = valid_win(state.code_win) and state.code_win or nil
  if not win then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return nil
  end
  return { path = vim.fn.fnamemodify(name, ":."), line = vim.api.nvim_win_get_cursor(win)[1] }
end

function M.is_open()
  return valid_win(state.chat_win)
end

---@alias dalil.Width number|{ narrow: number, wide: number, breakpoint: number }

---How much of the screen's width Neovim's pane takes (0-1), from herdr or tmux; nil when neither says.
local function screen_share()
  local pane = vim.env.HERDR_PANE_ID
  if pane and vim.fn.executable("herdr") == 1 then
    local ok, result = pcall(function()
      return vim.system({ "herdr", "pane", "layout" }, { text = true }):wait(1000)
    end)
    if ok and result.code == 0 then
      local decoded, data = pcall(vim.json.decode, result.stdout)
      local layout = decoded and data.result and data.result.layout
      if layout and layout.area and layout.area.width > 0 then
        for _, p in ipairs(layout.panes or {}) do
          if p.pane_id == pane then
            return p.rect.width / layout.area.width
          end
        end
      end
    end
  end
  if vim.env.TMUX and vim.fn.executable("tmux") == 1 then
    local result = vim.system({ "tmux", "display-message", "-p", "#{pane_width} #{window_width}" }, { text = true }):wait(1000)
    local pane_width, window_width = (result.stdout or ""):match("(%d+) (%d+)")
    if pane_width and tonumber(window_width) > 0 then
      return tonumber(pane_width) / tonumber(window_width)
    end
  end
  return nil
end

---The chat's width in columns. A number is a fraction of the editor. A table picks `wide` when Neovim's pane
---takes at least `breakpoint` of the screen, else `narrow`.
---@param width dalil.Width
function M.chat_width(width)
  local fraction = width
  if type(width) == "table" then
    local share = screen_share()
    fraction = (share and share >= width.breakpoint) and width.wide or width.narrow
  end
  return math.max(math.floor(vim.o.columns * fraction), math.min(40, vim.o.columns - 20))
end

---@param width dalil.Width
function M.resize(width)
  if M.is_open() then
    vim.api.nvim_win_set_width(state.chat_win, M.chat_width(width))
  end
end

---@param opts { width: dalil.Width, input_height: integer }
function M.open(opts)
  remember_code_window()
  if M.is_open() then
    M.focus_input({ insert = false })
    return
  end
  state.focusing = true
  vim.cmd("botright vsplit")
  state.chat_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.chat_win, state.chat_buf)
  vim.api.nvim_win_set_width(state.chat_win, M.chat_width(opts.width))

  vim.cmd("belowright split")
  state.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
  vim.api.nvim_win_set_height(state.input_win, opts.input_height)

  for _, win in ipairs({ state.chat_win, state.input_win }) do
    local wo = vim.wo[win]
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.wrap = true
    wo.linebreak = true
    wo.spell = false
    wo.winfixwidth = true
    wo.conceallevel = 2
  end
  for _, win in ipairs({ state.chat_win, state.input_win }) do
    vim.wo[win].winhighlight = "Normal:DalilNormal,NormalNC:DalilNormal,EndOfBuffer:DalilNormal,SignColumn:DalilNormal,WinBar:DalilWinBar,WinBarNC:DalilWinBar"
  end
  vim.wo[state.chat_win].concealcursor = "nc"
  vim.wo[state.input_win].concealcursor = "nic"
  state.focusing = false
  vim.wo[state.input_win].winfixheight = true
  vim.wo[state.input_win].winbar = "%#DalilInputTitle# Message %#Comment# <CR> send · <C-c> cancel · q close"
  M.render_status()
  M.scroll_to_end()
end

function M.close()
  for _, win in ipairs({ state.input_win, state.chat_win }) do
    if valid_win(win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
      vim.api.nvim_win_close(win, true)
    end
  end
  state.chat_win, state.input_win = nil, nil
  if valid_win(state.code_win) then
    vim.api.nvim_set_current_win(state.code_win)
  end
end

---@param opts { insert: boolean }
function M.focus_input(opts)
  if valid_win(state.input_win) then
    state.focusing = true
    vim.api.nvim_set_current_win(state.input_win)
    state.focusing = false
    if opts.insert then
      vim.cmd("startinsert!")
    end
  end
end

---Takes the input text and clears the input.
---@return string
function M.take_input()
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"))
  if text ~= "" then
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })
  end
  return text
end

---@param text string
function M.append_input(text)
  local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
  local last = lines[#lines]
  if last == "" then
    vim.api.nvim_buf_set_lines(state.input_buf, #lines - 1, #lines, false, { text .. " " })
  else
    vim.api.nvim_buf_set_lines(state.input_buf, #lines - 1, #lines, false, { last .. " " .. text .. " " })
  end
end

function M.set_cwd(cwd)
  state.cwd = cwd
end

-- Transcript writing -------------------------------------------------------

local function at_end()
  if not valid_win(state.chat_win) then
    return true
  end
  return vim.api.nvim_win_get_cursor(state.chat_win)[1] >= vim.api.nvim_buf_line_count(state.chat_buf) - 1
end

function M.scroll_to_end()
  if valid_win(state.chat_win) then
    vim.api.nvim_win_set_cursor(state.chat_win, { vim.api.nvim_buf_line_count(state.chat_buf), 0 })
  end
end

local scan_timers = {}

---Re-marks the references in `buf` (the transcript by default) once edits pause.
function schedule_scan(buf)
  buf = buf or state.chat_buf
  local timer = scan_timers[buf]
  if timer then
    timer:stop()
  else
    timer = vim.uv.new_timer()
    scan_timers[buf] = timer
  end
  timer:start(80, 0, vim.schedule_wrap(function()
    local transcript = buf == state.chat_buf
    refs.scan({ buf = buf, cwd = state.cwd, write = transcript, settled = transcript and not state.status.busy })
  end))
end

local function edit(fn)
  local follow = at_end()
  vim.bo[state.chat_buf].modifiable = true
  fn(state.chat_buf)
  vim.bo[state.chat_buf].modifiable = false
  if follow then
    M.scroll_to_end()
  end
  schedule_scan()
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function is_empty(buf)
  local all = lines(buf)
  return #all == 1 and all[1] == ""
end

---Appends `new_lines` after the transcript, leaving one blank line before them.
local function append_paragraph(buf, new_lines)
  if is_empty(buf) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    return
  end
  local all = lines(buf)
  local count = #all
  if all[count] == "" then
    vim.api.nvim_buf_set_lines(buf, count - 1, count, false, new_lines)
    if count >= 2 and all[count - 1] ~= "" then
      vim.api.nvim_buf_set_lines(buf, count - 1, count - 1, false, { "" })
    end
  else
    vim.api.nvim_buf_set_lines(buf, count, count, false, vim.list_extend({ "" }, new_lines))
  end
end

local function header_mark(buf, row, hl)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = hl })
end

---@param text string
function M.user_message(text)
  edit(function(buf)
    append_paragraph(buf, vim.list_extend({ "## You", "" }, vim.split(text, "\n", { plain = true })))
    local all = lines(buf)
    for row = #all, 1, -1 do
      if all[row] == "## You" then
        header_mark(buf, row - 1, "DalilUserHeader")
        break
      end
    end
  end)
  state.block = "user"
  state.agent_header = false
  M.scroll_to_end()
end

local function ensure_agent_header(buf)
  if state.agent_header then
    return
  end
  append_paragraph(buf, { "## Claude" })
  header_mark(buf, vim.api.nvim_buf_line_count(buf) - 1, "DalilAgentHeader")
  state.agent_header = true
end

---Appends `text` to the end of the transcript, starting each new line with `prefix`.
local function append_stream(buf, text, prefix)
  local parts = vim.split(text, "\n", { plain = true })
  for i = 2, #parts do
    parts[i] = prefix .. parts[i]
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, count - 1, count, false)[1]
  vim.api.nvim_buf_set_text(buf, count - 1, #last, count - 1, #last, parts)
end

---@param text string
function M.agent_text(text)
  edit(function(buf)
    ensure_agent_header(buf)
    if state.block ~= "agent" then
      append_paragraph(buf, { "" })
    end
    append_stream(buf, text, "")
  end)
  state.block = "agent"
end

local function thought_header(thought)
  local words = select(2, thought.text:gsub("%S+", ""))
  return (thought.expanded and "▾" or "▸") .. " Thinking (" .. words .. " words)"
end

---Redraws a thinking block: its header line, and its text under it when expanded.
local function render_thought(buf, thought)
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, anchor_ns, thought.mark, {})
  local row = pos[1]
  if not row then
    return
  end
  local body = {}
  if thought.expanded then
    for _, line in ipairs(vim.split(vim.trim(thought.text), "\n", { plain = true })) do
      table.insert(body, "> " .. line)
    end
  end
  local header = thought_header(thought)
  local old_header = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  vim.api.nvim_buf_set_text(buf, row, 0, row, #old_header, { header })
  vim.api.nvim_buf_set_lines(buf, row + 1, row + 1 + thought.body_count, false, body)
  thought.body_count = #body
  vim.api.nvim_buf_clear_namespace(buf, ns, row, row + 1 + #body)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_row = row + #body, end_col = #(body[#body] or header), hl_group = "DalilThought", priority = 150 })
end

---Claude's thinking: one collapsed line that <Tab> expands.
---@param text string
function M.thought_text(text)
  edit(function(buf)
    ensure_agent_header(buf)
    if state.block ~= "thought" then
      local thought = { text = "", expanded = false, body_count = 0 }
      append_paragraph(buf, { thought_header(thought) })
      thought.mark = vim.api.nvim_buf_set_extmark(buf, anchor_ns, vim.api.nvim_buf_line_count(buf) - 1, 0, {})
      state.thought = thought
      table.insert(state.thoughts, thought)
    end
    state.thought.text = state.thought.text .. text
    render_thought(buf, state.thought)
  end)
  state.block = "thought"
end

---Expands or collapses the thinking block whose header is under the cursor.
---@return boolean toggled
function M.toggle_thought()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, thought in ipairs(state.thoughts) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(state.chat_buf, anchor_ns, thought.mark, {})
    if pos[1] and row >= pos[1] and row <= pos[1] + thought.body_count then
      thought.expanded = not thought.expanded
      edit(function(buf)
        render_thought(buf, thought)
      end)
      vim.api.nvim_win_set_cursor(0, { pos[1] + 1, 0 })
      return true
    end
  end
  return false
end

local function tool_line(tool)
  local title = vim.split(tool.title or "", "\n", { plain = true })[1] or ""
  if #title > 120 then
    title = title:sub(1, 117) .. "..."
  end
  return "  " .. (STATUS_ICON[tool.status] or "○") .. " " .. title
end

local function paint_tool(buf, row, tool)
  vim.api.nvim_buf_clear_namespace(buf, ns, row, row + 1)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #tool_line(tool), hl_group = "DalilTool" })
  vim.api.nvim_buf_set_extmark(buf, ns, row, 2, { end_col = 2 + #(STATUS_ICON[tool.status] or "○"), hl_group = STATUS_HL[tool.status] or "DalilToolPending", priority = 200 })
end

---@param id string
---@param update { title?: string, status?: string, kind?: string }
function M.tool(id, update)
  local tool = state.tools[id]
  edit(function(buf)
    if not tool then
      tool = { title = update.title or "Tool", status = update.status or "pending", kind = update.kind }
      if state.block == "tool" then
        local count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_buf_set_lines(buf, count, count, false, { tool_line(tool) })
      else
        ensure_agent_header(buf)
        append_paragraph(buf, { tool_line(tool) })
      end
      local row = vim.api.nvim_buf_line_count(buf) - 1
      tool.mark = vim.api.nvim_buf_set_extmark(buf, anchor_ns, row, 0, {})
      state.tools[id] = tool
      state.block = "tool"
      paint_tool(buf, row, tool)
      return
    end
    tool.title = update.title or tool.title
    tool.status = update.status or tool.status
    tool.kind = update.kind or tool.kind
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, anchor_ns, tool.mark, {})
    if pos[1] then
      local line = tool_line(tool)
      local old = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1] or ""
      vim.api.nvim_buf_set_text(buf, pos[1], 0, pos[1], #old, { line })
      paint_tool(buf, pos[1], tool)
    end
  end)
  return tool
end

---@param text string
---@param hl? string
function M.notice(text, hl)
  edit(function(buf)
    append_paragraph(buf, { text })
    local row = vim.api.nvim_buf_line_count(buf) - 1
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #text, hl_group = hl or "DalilNotice" })
  end)
  state.block = "notice"
end

function M.clear()
  vim.bo[state.chat_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.chat_buf, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(state.chat_buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(state.chat_buf, anchor_ns, 0, -1)
  vim.bo[state.chat_buf].modifiable = false
  state.tools = {}
  state.thoughts = {}
  state.thought = nil
  state.block = nil
  state.agent_header = false
end

-- Status bar ----------------------------------------------------------------

---@param update table
function M.set_status(update)
  state.status = vim.tbl_extend("force", state.status, update)
  M.render_status()
  if update.busy == false and state.chat_buf then
    -- The reply is complete, so a reference at its very end can become a chip now.
    schedule_scan()
  end
end

function M.render_status()
  if not valid_win(state.chat_win) then
    return
  end
  local s = state.status
  local parts = {}
  for _, part in ipairs({ s.saved and "saved" or "not saved", s.mode, s.model, s.context }) do
    if part and part ~= "" then
      table.insert(parts, (part:gsub("%%", "%%%%")))
    end
  end
  local title = s.title and s.title ~= "" and (" " .. s.title:gsub("%%", "%%%%")) or ""
  local busy = s.busy and "%#DalilBusy# ● working " or ""
  vim.wo[state.chat_win].winbar = "%#DalilTitle# Claude%*" .. "%#Comment#" .. title .. "%=" .. busy .. "%#Comment#" .. table.concat(parts, " · ") .. " "
end

return M
