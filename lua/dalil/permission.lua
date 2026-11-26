-- Shows what a tool wants to do, then asks which permission option to answer with.

local M = {}

local diff = (vim.text and vim.text.diff) or vim.diff

local function details(tool_call)
  for _, item in ipairs(tool_call.content or {}) do
    if item.type == "diff" then
      local old = item.oldText or ""
      local new = item.newText or ""
      local header = { "--- " .. vim.fn.fnamemodify(item.path, ":~:."), "+++ " .. vim.fn.fnamemodify(item.path, ":~:.") }
      local body = vim.split(diff(old .. "\n", new .. "\n", { ctxlen = 3 }), "\n", { plain = true, trimempty = true })
      return vim.list_extend(header, body), "diff"
    end
  end
  local input = tool_call.rawInput or {}
  if input.command then
    return vim.split(input.command, "\n", { plain = true }), "sh"
  end
  if next(input) then
    return vim.split(vim.inspect(input), "\n", { plain = true }), "lua"
  end
  return nil
end

local function show(lines, ft, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  vim.bo[buf].modifiable = false
  local width = math.min(math.floor(vim.o.columns * 0.8), 120)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.5))
  return vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = math.max(height, 1),
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    style = "minimal",
    zindex = 40,
  })
end

---@param params { toolCall: table, options: { optionId: string, name: string, kind: string }[] }
---@param respond fun(result: table)
function M.ask(params, respond)
  local tool_call = params.toolCall or {}
  local title = vim.split(tool_call.title or "Claude wants to use a tool", "\n", { plain = true })[1]
  local lines, ft = details(tool_call)
  local win = lines and show(lines, ft, title) or nil

  vim.ui.select(params.options, {
    prompt = "Allow: " .. title,
    format_item = function(option)
      return option.name
    end,
  }, function(choice)
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Dismissing the picker counts as "No", so Claude doesn't wait on an answer that never comes.
    choice = choice
      or vim.iter(params.options):find(function(option)
        return option.kind == "reject_once"
      end)
    if choice then
      respond({ outcome = { outcome = "selected", optionId = choice.optionId } })
    else
      respond({ outcome = { outcome = "cancelled" } })
    end
  end)
end

return M
