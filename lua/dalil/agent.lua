-- What the `dalil-nvim` command runs inside the user's Neovim, for Claude to look at the editor.

local M = {}

local SEVERITY = { "error", "warning", "info", "hint" }

local function relative(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

local function file_buffers()
  return vim.tbl_filter(function(buf)
    return vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
  end, vim.api.nvim_list_bufs())
end

local function buffer_diagnostics(buf)
  local diagnostics = vim.diagnostic.get(buf)
  table.sort(diagnostics, function(a, b)
    if a.severity ~= b.severity then
      return a.severity < b.severity
    end
    return a.lnum < b.lnum
  end)
  local name = relative(vim.api.nvim_buf_get_name(buf))
  local lines = {}
  for _, d in ipairs(diagnostics) do
    local source = d.source and (" [" .. d.source .. (d.code and (" " .. tostring(d.code)) or "") .. "]") or ""
    local message = d.message:gsub("\n", " ")
    table.insert(lines, string.format("%s:%d:%d: %s: %s%s", name, d.lnum + 1, d.col + 1, SEVERITY[d.severity] or "?", message, source))
  end
  return lines
end

---@param paths string[] files to report on; every open buffer when empty
local function diagnostics(paths)
  local out = {}
  if #paths == 0 then
    for _, buf in ipairs(file_buffers()) do
      vim.list_extend(out, buffer_diagnostics(buf))
    end
    return #out > 0 and out or { "No diagnostics in any open buffer." }
  end
  for _, path in ipairs(paths) do
    local buf = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
    if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
      table.insert(out, path .. ": not open in Neovim, so it has no diagnostics. Run `dalil-nvim open " .. path .. "` to load it.")
    else
      local lines = buffer_diagnostics(buf)
      vim.list_extend(out, #lines > 0 and lines or { relative(vim.api.nvim_buf_get_name(buf)) .. ": no diagnostics" })
    end
  end
  return out
end

---Loads a file into a hidden buffer so its language servers attach and report diagnostics.
local function open(paths)
  local out = {}
  for _, path in ipairs(paths) do
    local buf = vim.fn.bufadd(vim.fn.fnamemodify(path, ":p"))
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    if vim.bo[buf].filetype == "" then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("filetype detect")
      end)
    end
    table.insert(out, "Loaded " .. relative(vim.api.nvim_buf_get_name(buf)) .. "; language servers report diagnostics after a moment.")
  end
  return out
end

local function buffers()
  local out = {}
  for _, buf in ipairs(file_buffers()) do
    local clients = vim.tbl_map(function(client)
      return client.name
    end, vim.lsp.get_clients({ bufnr = buf }))
    local modified = vim.bo[buf].modified and " (unsaved changes)" or ""
    local lsp = #clients > 0 and (" lsp: " .. table.concat(clients, ", ")) or ""
    table.insert(out, relative(vim.api.nvim_buf_get_name(buf)) .. modified .. lsp)
  end
  return #out > 0 and out or { "No file buffers open." }
end

local function messages()
  local output = vim.api.nvim_exec2("messages", { output = true }).output
  local lines = vim.split(output, "\n", { plain = true, trimempty = true })
  return #lines > 0 and vim.list_slice(lines, math.max(#lines - 60, 1), #lines) or { "No messages." }
end

local function run_lua(code)
  local printed = {}
  local original_print = print
  print = function(...)
    local parts = vim.tbl_map(function(value)
      return type(value) == "string" and value or vim.inspect(value)
    end, { ... })
    table.insert(printed, table.concat(parts, " "))
  end
  local chunk, compile_err = load("return " .. code, "dalil-nvim")
  if not chunk then
    chunk, compile_err = load(code, "dalil-nvim")
  end
  local results
  if chunk then
    results = { pcall(chunk) }
  end
  print = original_print
  if not chunk then
    return { "error: " .. compile_err }
  end
  if not results[1] then
    return vim.list_extend(printed, { "error: " .. tostring(results[2]) })
  end
  for i = 2, table.maxn(results) do
    vim.list_extend(printed, vim.split(vim.inspect(results[i]), "\n", { plain = true }))
  end
  return #printed > 0 and printed or { "ok" }
end

local USAGE = [[
usage: dalil-nvim <command> [args]
  diagnostics [path...]   diagnostics for these files, or every open buffer
  open <path...>          load files so their language servers report diagnostics
  buffers                 open file buffers and their language servers
  messages                recent :messages (where Neovim's errors show up)
  lua <code>              run Lua in Neovim and print the result]]

---@param args string[]
---@return string
function M.cli(args)
  local command = args[1]
  local rest = vim.list_slice(args, 2)
  local out
  if command == "diagnostics" then
    out = diagnostics(rest)
  elseif command == "open" and #rest > 0 then
    out = open(rest)
  elseif command == "buffers" then
    out = buffers()
  elseif command == "messages" then
    out = messages()
  elseif command == "lua" and #rest > 0 then
    out = run_lua(table.concat(rest, " "))
  else
    out = { USAGE }
  end
  return table.concat(out, "\n")
end

return M
