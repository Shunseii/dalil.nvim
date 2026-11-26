-- Finds `path:line` references in the chat, marks them as links, and opens them in the code window.

local M = {}

local ns = vim.api.nvim_create_namespace("dalil_refs")
local flash_ns = vim.api.nvim_create_namespace("dalil_ref_flash")

---@class dalil.Ref
---@field path string absolute path
---@field lnum? integer
---@field lend? integer
---@field col? integer

---@type table<integer, table<integer, dalil.Ref>> buf -> extmark id -> ref
local marks = {}

---@type table<integer, table<integer, string>> buf -> extmark id -> chip text
local chips = {}

---@type table<integer, integer?> buf -> extmark id of the chip under the cursor
local active = {}

local CHIP_ICON = ""

local PATH_CHARS = "[%w_%.%-/~@%+]+"

---The file a path in the chat names: absolute, or relative to the session's directory or the Neovim config.
local function resolve(path, cwd, cache)
  if path:sub(1, 1) == "~" then
    return vim.fs.normalize(vim.fn.expand(path))
  elseif path:sub(1, 1) == "/" then
    return vim.fs.normalize(path)
  end
  local candidates = { cwd, vim.fn.stdpath("config") }
  for _, root in ipairs(candidates) do
    local full = vim.fs.normalize(root .. "/" .. path)
    if cache[full] == nil then
      local stat = vim.uv.fs_stat(full)
      cache[full] = stat ~= nil and stat.type == "file"
    end
    if cache[full] then
      return full
    end
  end
  return vim.fs.normalize(cwd .. "/" .. path)
end

local function is_file(path, cache)
  if cache[path] == nil then
    local stat = vim.uv.fs_stat(path)
    cache[path] = stat ~= nil and stat.type == "file"
  end
  return cache[path]
end

local function parse_position(rest)
  local patterns = {
    { "^:(%d+)%-(%d+)", "range" },
    { "^:(%d+):(%d+)", "col" },
    { "^#L(%d+)%-L(%d+)", "range" },
    { "^:(%d+)", "line" },
    { "^#L(%d+)", "line" },
  }
  for _, entry in ipairs(patterns) do
    local s, e, a, b = rest:find(entry[1])
    if s then
      local first = tonumber(a)
      if entry[2] == "range" then
        return { lnum = first, lend = tonumber(b), length = e }
      elseif entry[2] == "col" then
        return { lnum = first, col = tonumber(b), length = e }
      end
      return { lnum = first, length = e }
    end
  end
  return { length = 0 }
end

---@param line string
---@param cwd string
---@param cache table
---@return { start: integer, finish: integer, ref: dalil.Ref }[]
local function find_in_line(line, cwd, cache)
  local found = {}
  local init = 1
  while true do
    local s, e = line:find(PATH_CHARS, init)
    if not s then
      break
    end
    local token = line:sub(s, e)
    local trimmed = token:gsub("[%.,]+$", "")
    local token_end = s + #trimmed - 1
    init = e + 1

    local looks_like_path = trimmed:find("[/%.]") and trimmed ~= "." and trimmed ~= ".."
    if looks_like_path then
      local path = resolve(trimmed, cwd, cache)
      if is_file(path, cache) then
        local pos = parse_position(line:sub(token_end + 1))
        local finish = token_end + pos.length
        table.insert(found, {
          start = s - 1,
          finish = finish,
          ref = { path = path, lnum = pos.lnum, lend = pos.lend, col = pos.col },
        })
        init = math.max(init, finish + 1)
      end
    end
  end
  return found
end

---Re-marks every reference in `buf`.
---@alias dalil.RefStyle "snippet"|"short"|"full"

---@type dalil.RefStyle
local style = "snippet"
local SNIPPET_WIDTH = 48

---@param opts { style: dalil.RefStyle }
function M.configure(opts)
  style = opts.style
end

local function position_suffix(ref)
  if not ref.lnum then
    return ""
  end
  return ":" .. ref.lnum .. (ref.lend and ref.lend ~= ref.lnum and ("-" .. ref.lend) or "")
end

---The shortest path tails that tell apart the different files cited in the chat.
---@param paths string[]
---@return table<string, string>
local function short_names(paths)
  local names = {}
  local depth = 1
  local pending = vim.deepcopy(paths)
  while #pending > 0 and depth < 20 do
    local by_tail = {}
    for _, path in ipairs(pending) do
      local parts = vim.split(path, "/", { plain = true })
      local tail = table.concat(vim.list_slice(parts, math.max(#parts - depth + 1, 1), #parts), "/")
      by_tail[tail] = by_tail[tail] or {}
      table.insert(by_tail[tail], path)
    end
    pending = {}
    for tail, group in pairs(by_tail) do
      if #group == 1 then
        names[group[1]] = tail
      else
        vim.list_extend(pending, group)
      end
    end
    depth = depth + 1
  end
  for _, path in ipairs(pending) do
    names[path] = path
  end
  return names
end

---The cited line's code, trimmed to fit a chip; nil when there's no line or it's blank.
local function snippet(ref, file_cache)
  if not ref.lnum then
    return nil
  end
  local key = ref.path .. ":" .. ref.lnum
  if file_cache[key] == nil then
    local ok, lines = pcall(vim.fn.readfile, ref.path, "", ref.lnum)
    local text = ok and lines[ref.lnum] and vim.trim(lines[ref.lnum]) or ""
    file_cache[key] = text
  end
  local text = file_cache[key]
  -- A line of bare brackets says nothing about the code; the file name says more.
  if select(2, text:gsub("[%w_]", "")) < 3 then
    return nil
  end
  -- An ellipsis whenever the chip shows less than the reference covers: a cut line, or the first of several.
  local more_lines = ref.lend and ref.lend > ref.lnum
  if vim.fn.strchars(text) > SNIPPET_WIDTH then
    text = vim.fn.strcharpart(text, 0, SNIPPET_WIDTH - 1) .. "…"
  elseif more_lines then
    text = text .. " …"
  end
  return text
end

---@param ref dalil.Ref
---@param names table<string, string>
---@param file_cache table
local function label(ref, names, file_cache)
  if style == "snippet" then
    local code = snippet(ref, file_cache)
    if code then
      return code
    end
  end
  return names[ref.path] .. position_suffix(ref)
end

---@param text string
---@return string
local function chip_text(text)
  return " " .. CHIP_ICON .. " " .. text .. " "
end

---Chips written into the buffer from an earlier scan, dropping any whose text has since been deleted.
---@return table<integer, { start: integer, finish: integer }[]> row -> chip ranges
local function written_chips(buf)
  local by_row = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    local chip = chips[buf] and chips[buf][id]
    local gone = details.invalid or details.end_row ~= row or details.end_col <= col
    if chip and chip.written and not gone then
      by_row[row] = by_row[row] or {}
      table.insert(by_row[row], { start = col, finish = details.end_col })
    else
      vim.api.nvim_buf_del_extmark(buf, ns, id)
      if marks[buf] then
        marks[buf][id] = nil
      end
      if chips[buf] then
        chips[buf][id] = nil
      end
    end
  end
  return by_row
end

local function overlaps(ranges, hit)
  for _, range in ipairs(ranges or {}) do
    if hit.start < range.finish and hit.finish > range.start then
      return true
    end
  end
  return false
end

---Marks every reference in `buf` that isn't one yet. Unless the style is "full", each one shows as a chip.
---With `write`, a chip's text replaces the path in the buffer (wrapping counts hidden text, so a hidden path
---would leave a gap the width of the path); otherwise the path stays and is hidden behind the chip, so
---the buffer keeps the raw text. Mid-stream, a reference at the very end of the text waits until something
---follows it or the reply is `settled`, since its line number may still be arriving.
---@param opts { buf: integer, cwd: string, write?: boolean, settled?: boolean }
function M.scan(opts)
  local buf = opts.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  marks[buf] = marks[buf] or {}
  chips[buf] = chips[buf] or {}
  local written = written_chips(buf)
  active[buf] = nil

  local cache = {}
  local hits = {}
  local seen, paths = {}, {}
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row, line in ipairs(all_lines) do
    for _, hit in ipairs(find_in_line(line, opts.cwd, cache)) do
      if not overlaps(written[row - 1], hit) then
        hit.row = row - 1
        hit.at_end = row == #all_lines and hit.finish >= #line
        table.insert(hits, hit)
        if not seen[hit.ref.path] then
          seen[hit.ref.path] = true
          table.insert(paths, hit.ref.path)
        end
      end
    end
  end

  local names = short_names(paths)
  local file_cache = {}
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  -- Right to left, so writing a chip doesn't move the references still to come; extmarks to the right shift with it.
  for i = #hits, 1, -1 do
    local hit = hits[i]
    local id
    if style == "full" then
      id = vim.api.nvim_buf_set_extmark(buf, ns, hit.row, hit.start, { end_col = hit.finish, hl_group = "DalilRef" })
      chips[buf][id] = nil
    elseif opts.write and (opts.settled or not hit.at_end) then
      local text = chip_text(label(hit.ref, names, file_cache))
      vim.api.nvim_buf_set_text(buf, hit.row, hit.start, hit.row, hit.finish, { text })
      id = vim.api.nvim_buf_set_extmark(buf, ns, hit.row, hit.start, {
        end_col = hit.start + #text,
        hl_group = "DalilRefChip",
        invalidate = true,
      })
      chips[buf][id] = { written = true }
    else
      local text = chip_text(label(hit.ref, names, file_cache))
      id = vim.api.nvim_buf_set_extmark(buf, ns, hit.row, hit.start, {
        end_col = hit.finish,
        hl_group = "DalilRef",
        conceal = "",
        virt_text = { { text, "DalilRefChip" } },
        virt_text_pos = "inline",
      })
      chips[buf][id] = { text = text }
    end
    marks[buf][id] = hit.ref
  end
  vim.bo[buf].modifiable = modifiable
  if buf == vim.api.nvim_get_current_buf() then
    M.update_active()
  end
end

---The reference under the cursor: its extmark id and the byte range of the path the chip hides.
---@return { id: integer, row: integer, start: integer, finish: integer }?
local function chip_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local found = vim.api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  for _, mark in ipairs(found) do
    if not mark[4].invalid and col >= mark[3] and col < mark[4].end_col then
      return { id = mark[1], row = row, start = mark[3], finish = mark[4].end_col }
    end
  end
end

local function paint_chip(buf, id, hl)
  local chip = chips[buf] and chips[buf][id]
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
  if not chip or not pos[1] or pos[3].invalid then
    return
  end
  if chip.written then
    vim.api.nvim_buf_set_extmark(buf, ns, pos[1], pos[2], { id = id, end_col = pos[3].end_col, hl_group = hl, invalidate = true })
    return
  end
  vim.api.nvim_buf_set_extmark(buf, ns, pos[1], pos[2], {
    id = id,
    end_col = pos[3].end_col,
    hl_group = "DalilRef",
    conceal = "",
    virt_text = { { chip.text, hl } },
    virt_text_pos = "inline",
  })
end

---Draws the chip under the cursor as selected, and the one before it as normal again.
function M.update_active()
  local buf = vim.api.nvim_get_current_buf()
  local chip = chip_at_cursor()
  local id = chip and chip.id
  if active[buf] == id then
    return
  end
  if active[buf] then
    paint_chip(buf, active[buf], "DalilRefChip")
  end
  if id then
    paint_chip(buf, id, "DalilRefChipActive")
  end
  active[buf] = id
end

---@type table<integer, { row: integer, col: integer }> win -> cursor after the last move
local last_cursor = {}

---Keeps the cursor off the hidden path behind a chip. A move forward from the chip (w, e, f…) lands past it;
---any other move into it lands on its start.
function M.snap()
  local win = vim.api.nvim_get_current_win()
  local chip = chip_at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if chip and col > chip.start then
    local previous = last_cursor[win]
    local from_chip_start = previous and previous.row == row and previous.col == chip.start
    local line_length = #vim.api.nvim_get_current_line()
    col = (from_chip_start and chip.finish < line_length) and chip.finish or chip.start
    vim.api.nvim_win_set_cursor(0, { row, col })
  end
  last_cursor[win] = { row = row, col = col }
end

---`l` that steps over a chip in one move.
---@param count integer
function M.move_right(count)
  for _ = 1, count do
    local chip = chip_at_cursor()
    if chip then
      local line = vim.api.nvim_get_current_line()
      if chip.finish >= #line then
        return
      end
      vim.api.nvim_win_set_cursor(0, { chip.row, chip.finish })
    else
      vim.cmd("normal! l")
    end
  end
end

---@return dalil.Ref?
function M.at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local found = vim.api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  for _, mark in ipairs(found) do
    local id, _, start_col, details = mark[1], mark[2], mark[3], mark[4]
    if not details.invalid and col >= start_col and col < details.end_col then
      return marks[buf] and marks[buf][id]
    end
  end
end

---Moves the cursor to the next (`1`) or previous (`-1`) reference.
function M.jump(direction)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local found = vim.tbl_filter(function(mark)
    return not mark[4].invalid
  end, vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true }))
  if direction < 0 then
    found = vim.iter(found):rev():totable()
  end
  for _, mark in ipairs(found) do
    local mrow, mcol = mark[2] + 1, mark[3]
    local after = mrow > row or (mrow == row and mcol > col)
    local before = mrow < row or (mrow == row and mcol < col)
    if (direction > 0 and after) or (direction < 0 and before) then
      vim.api.nvim_win_set_cursor(0, { mrow, mcol })
      return
    end
  end
end

---@param ref dalil.Ref
---@param win integer
function M.open(ref, win)
  vim.api.nvim_set_current_win(win)
  if vim.fs.normalize(vim.api.nvim_buf_get_name(0)) ~= ref.path then
    vim.cmd.edit(vim.fn.fnameescape(ref.path))
  end
  if not ref.lnum then
    return
  end
  local last = vim.api.nvim_buf_line_count(0)
  local lnum = math.min(ref.lnum, last)
  vim.api.nvim_win_set_cursor(0, { lnum, math.max((ref.col or 1) - 1, 0) })
  vim.cmd("normal! zz")
  local lend = math.min(ref.lend or lnum, last)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
  vim.hl.range(buf, flash_ns, "DalilRefFlash", { lnum - 1, 0 }, { lend - 1, -1 }, { timeout = 800 })
end

---@param ref dalil.Ref
function M.preview(ref)
  local context = 3
  local first = math.max((ref.lnum or 1) - context, 1)
  local last = (ref.lend or ref.lnum or 1) + context
  local ok, lines = pcall(vim.fn.readfile, ref.path, "", last)
  if not ok then
    return
  end
  lines = vim.list_slice(lines, first, last)
  if #lines == 0 then
    lines = { "" }
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = vim.filetype.match({ filename = ref.path }) or ""
  vim.bo[buf].modifiable = false
  if ref.lnum then
    local lend = math.min(ref.lend or ref.lnum, last)
    vim.hl.range(buf, flash_ns, "Visual", { ref.lnum - first, 0 }, { lend - first, -1 })
  end

  -- Open above the cursor when there isn't room below it, as in the message box at the bottom.
  local width = math.min(math.max(unpack(vim.tbl_map(vim.fn.strdisplaywidth, lines))) + 2, 100, vim.o.columns - 4)
  local screen_row = vim.fn.screenpos(0, vim.fn.line("."), 1).row
  local below = vim.o.lines - vim.o.cmdheight - screen_row - 2
  local above = screen_row - 3
  local place_above = below < #lines and above > below
  local height = math.max(math.min(#lines, place_above and above or below), 1)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = place_above and 0 or 1,
    col = 0,
    anchor = place_above and "SW" or "NW",
    width = math.max(width, 20),
    height = height,
    border = "rounded",
    style = "minimal",
    title = " " .. vim.fn.fnamemodify(ref.path, ":~:.") .. (ref.lnum and (":" .. ref.lnum) or "") .. " ",
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "WinScrolled" }, {
    buffer = vim.api.nvim_get_current_buf(),
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })
end

return M
