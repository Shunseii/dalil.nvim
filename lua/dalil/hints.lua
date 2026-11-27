-- Hints: a short note from Claude shown above lines you mark, saying what the code does and why it's there.
-- Each hint is a one-off `claude -p` call, sent the marked lines, the function around them and what the
-- language server knows about the names in them, so it rarely needs to look further.

local M = {}

local ns = vim.api.nvim_create_namespace("dalil_hints")
local group = vim.api.nvim_create_augroup("dalil_hints", { clear = true })

local PLUGIN_ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local HINT_ICON = "󰌵"
local MAX_SCOPE_LINES = 200
local CONTEXT_LINES = 40
local MAX_NAMES = 8
local LSP_WAIT_MS = 2000
local TIMEOUT_MS = 120000

local SYSTEM_PROMPT = [[
You write hints for a code editor: a short note shown above lines the user marked, saying what the code does and why it's there, in the context of the code around it.

Write a single sentence of at most 20 words. Plain text: no markdown, no backticks, no preamble, and don't start with "This line" or "This code". Explain the purpose, not a restatement of the syntax: what a value is for, why a check exists, what would break without it, what a call does that its name doesn't say.

The message gives you the marked lines, the code around them and what the language server knows about the names in them; that's usually enough. If it isn't, you can read or search files, or run dalil-nvim (definition, references, hover, calls with <path:line> <symbol>) to ask the user's language servers. Keep that quick: answer as soon as you know.]]

---@class dalil.HintsConfig
---@field model string
---@field effort string
---@field deep_model string
---@field deep_effort string
---@field claude_cmd string

---@type dalil.HintsConfig
local config = { model = "sonnet", effort = "low", deep_model = "opus", deep_effort = "medium", claude_cmd = "claude" }

---@class dalil.Hint
---@field mark integer extmark over the hinted lines
---@field lines string[] the hinted lines as they were when asked about
---@field text? string
---@field status "pending"|"done"
---@field job? vim.SystemObj

---@type table<integer, dalil.Hint[]>
local hints = {}

local shown = true

---@param opts dalil.HintsConfig
function M.configure(opts)
  config = vim.tbl_extend("force", config, opts)
end

-- Rendering

local function window_width(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return 80
  end
  local info = vim.fn.getwininfo(win)[1]
  return vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
end

local function wrap(text, width)
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = word
    elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
      line = line .. " " .. word
    else
      table.insert(out, line)
      line = word
    end
  end
  if line ~= "" then
    table.insert(out, line)
  end
  return out
end

---The virtual lines a hint shows above its first line, indented to match it.
local function virt_lines(buf, row, hint)
  local indent = vim.api.nvim_buf_call(buf, function()
    return vim.fn.indent(row + 1)
  end)
  local pad = string.rep(" ", indent)
  if hint.status == "pending" then
    return { { { pad .. HINT_ICON .. " …", "DalilHintPending" } } }
  end
  local width = math.max(math.min(window_width(buf) - indent - 3, 100), 30)
  local out = {}
  for i, line in ipairs(wrap(hint.text, width)) do
    local prefix = i == 1 and (HINT_ICON .. " ") or "  "
    table.insert(out, { { pad .. prefix .. line, "DalilHint" } })
  end
  return out
end

local function mark_position(buf, hint)
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, hint.mark, { details = true })
  if not pos[1] or pos[3].invalid then
    return nil
  end
  return { row = pos[1], end_row = pos[3].end_row or pos[1], end_col = pos[3].end_col or 0 }
end

local function render(buf, hint)
  local pos = mark_position(buf, hint)
  if not pos then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, ns, pos.row, 0, {
    id = hint.mark,
    end_row = pos.end_row,
    end_col = pos.end_col,
    invalidate = true,
    virt_lines = shown and virt_lines(buf, pos.row, hint) or nil,
    virt_lines_above = true,
  })
end

local function render_all()
  for buf, list in pairs(hints) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, hint in ipairs(list) do
        render(buf, hint)
      end
    end
  end
end

-- Keeping hints true

local function remove(buf, hint)
  if hint.job then
    hint.job:kill(15)
    hint.job = nil
  end
  pcall(vim.api.nvim_buf_del_extmark, buf, ns, hint.mark)
  local list = hints[buf] or {}
  for i, other in ipairs(list) do
    if other == hint then
      table.remove(list, i)
      break
    end
  end
end

---Whether the hinted lines still read as they did when the hint was asked for.
local function still_true(buf, hint)
  local pos = mark_position(buf, hint)
  if not pos then
    return false
  end
  local current = vim.api.nvim_buf_get_lines(buf, pos.row, pos.end_row + 1, false)
  return vim.deep_equal(current, hint.lines)
end

---Drops hints whose lines have been edited; they may no longer be right.
local function drop_stale(buf)
  for _, hint in ipairs(vim.list_slice(hints[buf] or {})) do
    if not still_true(buf, hint) then
      remove(buf, hint)
    end
  end
end

local watched = {}

local function watch(buf)
  if watched[buf] then
    return
  end
  watched[buf] = true
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      drop_stale(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      for _, hint in ipairs(hints[buf] or {}) do
        if hint.job then
          hint.job:kill(15)
        end
      end
      hints[buf] = nil
      watched[buf] = nil
    end,
  })
end

-- Context for Claude

local SCOPE_WORDS = { "function", "method", "def", "class", "impl", "module", "struct", "interface", "lambda", "closure", "arrow", "fn_item", "do_block" }

local function is_scope(node_type)
  for _, word in ipairs(SCOPE_WORDS) do
    if node_type:find(word, 1, true) then
      return true
    end
  end
  return false
end

---The rows (0-based, inclusive) of the smallest function, class or similar around the marked lines; a window of
---lines around them when there's no parser or the scope is too long to send.
local function scope_rows(buf, first, last)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local fallback = { math.max(first - CONTEXT_LINES, 0), math.min(last + CONTEXT_LINES, line_count - 1) }
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return fallback
  end
  local tree = parser:parse()[1]
  if not tree then
    return fallback
  end
  local last_line = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
  local node = tree:root():named_descendant_for_range(first, 0, last, #last_line)
  while node do
    if is_scope(node:type()) then
      local start_row, _, end_row = node:range()
      if start_row < first or end_row > last then
        if end_row - start_row > MAX_SCOPE_LINES then
          return fallback
        end
        return { math.min(start_row, first), math.max(end_row, last) }
      end
    end
    node = node:parent()
  end
  return fallback
end

local function numbered(buf, from, to, first, last)
  local out = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, from, to + 1, false)) do
    local row = from + i - 1
    local marker = (row >= first and row <= last) and ">" or " "
    table.insert(out, string.format("%s%5d  %s", marker, row + 1, line))
  end
  return table.concat(out, "\n")
end

---The distinct names on the marked lines, with where each first appears.
local function names_in(buf, first, last)
  local found, seen = {}, {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, last + 1, false)) do
    local init = 1
    while #found < MAX_NAMES do
      local s, e = line:find("[%a_][%w_]*", init)
      if not s then
        break
      end
      local name = line:sub(s, e)
      if not seen[name] and #name > 1 then
        seen[name] = true
        table.insert(found, { name = name, row = first + i - 1, col = s - 1 })
      end
      init = e + 1
    end
  end
  return found
end

local function hover_text(result)
  local contents = result and result.contents
  if not contents then
    return nil
  end
  local lines = vim.lsp.util.convert_input_to_markdown_lines(contents)
  local kept = {}
  for _, line in ipairs(lines) do
    if not line:match("^```") and vim.trim(line) ~= "" then
      table.insert(kept, line)
    end
    if #kept >= 6 then
      break
    end
  end
  return #kept > 0 and table.concat(kept, "\n") or nil
end

---What the language servers say about each name on the marked lines; calls back with them, or nothing after a
---short wait, so a slow server doesn't hold up the hint.
local function language_server_notes(buf, first, last, callback)
  if #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/hover" }) == 0 then
    return callback({})
  end
  local names = names_in(buf, first, last)
  local notes, pending, done = {}, #names, false
  local function finish()
    if not done then
      done = true
      callback(notes)
    end
  end
  if pending == 0 then
    return finish()
  end
  for _, entry in ipairs(names) do
    vim.lsp.buf_request_all(buf, "textDocument/hover", function(client)
      local text = vim.api.nvim_buf_get_lines(buf, entry.row, entry.row + 1, false)[1] or ""
      local character = vim.str_utfindex(text, client.offset_encoding, entry.col, false)
      return { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = { line = entry.row, character = character } }
    end, function(results)
      for _, response in pairs(results or {}) do
        local text = hover_text(response.result)
        if text then
          table.insert(notes, { name = entry.name, text = text })
          break
        end
      end
      pending = pending - 1
      if pending == 0 then
        finish()
      end
    end)
  end
  vim.defer_fn(finish, LSP_WAIT_MS)
end

local function build_prompt(buf, first, last, notes, deep)
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
  local scope = scope_rows(buf, first, last)
  local parts = {
    string.format("File: %s (%s)", path, vim.bo[buf].filetype),
    string.format("Marked: lines %d-%d", first + 1, last + 1),
    "",
    "Code around them (marked lines start with >):",
    numbered(buf, scope[1], scope[2], first, last),
  }
  if #notes > 0 then
    table.insert(parts, "")
    table.insert(parts, "What the language server says about names on the marked lines:")
    for _, note in ipairs(notes) do
      table.insert(parts, "- " .. note.name .. ":\n" .. note.text)
    end
  end
  table.insert(parts, "")
  table.insert(parts, "Write the hint for the marked lines." .. (deep and " You may use up to two sentences and 40 words." or ""))
  return table.concat(parts, "\n")
end

-- Asking Claude

local function clean(text)
  text = vim.trim(text or "")
  text = text:gsub("`", ""):gsub("%*%*", ""):gsub("\n+", " ")
  return text
end

local function run_claude(opts)
  local cmd = {
    config.claude_cmd,
    "-p",
    "--model", opts.deep and config.deep_model or config.model,
    "--effort", opts.deep and config.deep_effort or config.effort,
    "--no-session-persistence",
    -- Leaving out the user's settings skips their hooks and plugins, which makes a hint several times faster.
    "--setting-sources", "project,local",
    "--tools", "Read,Grep,Glob,Bash",
    "--allowedTools", "Read,Grep,Glob,Bash(dalil-nvim:*)",
    "--system-prompt", SYSTEM_PROMPT,
    "--output-format", "json",
  }
  local env = {
    DALIL_NVIM = vim.v.servername,
    PATH = PLUGIN_ROOT .. "/bin:" .. (vim.env.PATH or ""),
  }
  return vim.system(cmd, { stdin = opts.prompt, cwd = vim.fn.getcwd(), env = env, text = true, timeout = TIMEOUT_MS }, opts.on_exit)
end

---Hints overlapping rows `first`-`last` (0-based) of `buf`.
local function overlapping(buf, first, last)
  local found = {}
  for _, hint in ipairs(hints[buf] or {}) do
    local pos = mark_position(buf, hint)
    if pos and pos.row <= last and pos.end_row >= first then
      table.insert(found, hint)
    end
  end
  return found
end

---Puts a new hint on rows `first`-`last` (0-based) of `buf`, replacing any it overlaps, and shows hints if they
---were hidden: asking for one means wanting to see it.
---@param opts { buf: integer, first: integer, last: integer, text?: string }
---@return dalil.Hint
local function place(opts)
  local buf, first, last = opts.buf, opts.first, opts.last
  for _, old in ipairs(overlapping(buf, first, last)) do
    remove(buf, old)
  end
  if not shown then
    shown = true
    render_all()
  end
  local lines = vim.api.nvim_buf_get_lines(buf, first, last + 1, false)
  local hint = {
    lines = lines,
    text = opts.text,
    status = opts.text and "done" or "pending",
    mark = vim.api.nvim_buf_set_extmark(buf, ns, first, 0, {
      end_row = last,
      end_col = #lines[#lines],
      invalidate = true,
    }),
  }
  hints[buf] = hints[buf] or {}
  table.insert(hints[buf], hint)
  watch(buf)
  render(buf, hint)
  return hint
end

---Asks Claude for a hint on lines `line1`-`line2` (1-based) of the current buffer.
---@param opts { line1: integer, line2: integer, deep?: boolean }
function M.request(opts)
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then
    return vim.notify("dalil: hints work in file buffers", vim.log.levels.WARN)
  end
  local first, last = opts.line1 - 1, opts.line2 - 1
  local hint = place({ buf = buf, first = first, last = last })

  language_server_notes(buf, first, last, function(notes)
    if not vim.tbl_contains(hints[buf] or {}, hint) then
      return
    end
    hint.job = run_claude({
      deep = opts.deep,
      prompt = build_prompt(buf, first, last, notes, opts.deep),
      on_exit = vim.schedule_wrap(function(result)
        hint.job = nil
        if not vim.api.nvim_buf_is_valid(buf) or not vim.tbl_contains(hints[buf] or {}, hint) then
          return
        end
        local ok, decoded = pcall(vim.json.decode, result.stdout or "")
        local text = ok and type(decoded) == "table" and not decoded.is_error and clean(decoded.result) or ""
        if text == "" then
          remove(buf, hint)
          local why = ok and type(decoded) == "table" and decoded.result or vim.trim(result.stderr or "")
          return vim.notify("dalil: no hint" .. (why ~= "" and (": " .. why) or ""), vim.log.levels.WARN)
        end
        if not still_true(buf, hint) then
          return remove(buf, hint)
        end
        hint.text = text
        hint.status = "done"
        render(buf, hint)
      end),
    })
  end)
end

---Loads `path` into a buffer (unlisted) so hints can go on it before it's opened.
---@return integer? buf, string? err
local function file_buffer(path)
  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) == 0 then
    return nil, path .. ": no such file"
  end
  local buf = vim.fn.bufadd(full)
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  return buf
end

---Parses `path`, `path:line` or `path:start-end` into a path and 1-based lines (nil when not given).
local function parse_lines(target)
  local path, first, last = target:match("^(.-):(%d+)%-(%d+)$")
  if not path then
    path, first = target:match("^(.-):(%d+)$")
    last = first
  end
  if not path then
    return target
  end
  return path, tonumber(first), tonumber(last)
end

-- What the `dalil-nvim hint`, `hints` and `hint-delete` commands run, for the chat's Claude to write hints itself.

---@param target string path:line or path:start-end
---@param text string
---@return string
function M.cli_add(target, text)
  local path, first, last = parse_lines(target)
  if not first then
    return "expected path:line or path:start-end, got " .. target
  end
  local buf, err = file_buffer(path)
  if not buf then
    return err
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if first < 1 or last > count or first > last then
    return string.format("%s has lines 1-%d; can't hint %d-%d", path, count, first, last)
  end
  text = vim.trim(text)
  if text == "" then
    return "the hint text is empty"
  end
  place({ buf = buf, first = first - 1, last = last - 1, text = text })
  local hidden = vim.fn.bufwinid(buf) == -1 and " (the file isn't on screen; it shows when they open it)" or ""
  return string.format("hinted %s:%d-%d%s", vim.fn.fnamemodify(path, ":~:."), first, last, hidden)
end

---@param path? string
---@return string
function M.cli_list(path)
  local out = {}
  for buf, list in pairs(hints) do
    local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
    if name ~= "" and (not path or name == vim.fn.fnamemodify(path, ":p")) then
      for _, hint in ipairs(list) do
        local pos = mark_position(buf, hint)
        if pos then
          local text = hint.status == "pending" and "(being written)" or hint.text
          table.insert(out, string.format("%s:%d-%d: %s", vim.fn.fnamemodify(name, ":~:."), pos.row + 1, pos.end_row + 1, text))
        end
      end
    end
  end
  table.sort(out)
  return #out > 0 and table.concat(out, "\n") or "no hints"
end

---@param target string path, path:line or path:start-end
---@return string
function M.cli_delete(target)
  local path, first, last = parse_lines(target)
  local buf = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
  if buf == -1 then
    return "no hints in " .. path
  end
  local count = 0
  for _, hint in ipairs(vim.list_slice(hints[buf] or {})) do
    local pos = mark_position(buf, hint)
    if not first or (pos and pos.row <= last - 1 and pos.end_row >= first - 1) then
      remove(buf, hint)
      count = count + 1
    end
  end
  return string.format("deleted %d hint%s", count, count == 1 and "" or "s")
end

---Deletes the hints on lines `line1`-`line2` (1-based) of the current buffer.
---@param opts { line1: integer, line2: integer }
function M.delete(opts)
  local buf = vim.api.nvim_get_current_buf()
  local found = overlapping(buf, opts.line1 - 1, opts.line2 - 1)
  if #found == 0 then
    return vim.notify("dalil: no hint here", vim.log.levels.INFO)
  end
  for _, hint in ipairs(found) do
    remove(buf, hint)
  end
end

---Deletes every hint in the current buffer.
function M.clear()
  local buf = vim.api.nvim_get_current_buf()
  for _, hint in ipairs(vim.list_slice(hints[buf] or {})) do
    remove(buf, hint)
  end
end

---Shows or hides every hint; hidden ones keep their text and come back as they were.
function M.toggle()
  shown = not shown
  render_all()
  vim.notify("dalil: hints " .. (shown and "shown" or "hidden"), vim.log.levels.INFO)
end

return M
