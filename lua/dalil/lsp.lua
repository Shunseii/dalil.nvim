-- Language-server lookups for the `dalil-nvim` command, answered by the servers running in the user's Neovim:
-- they've already indexed the project and see unsaved edits.

local M = {}

local TIMEOUT = 10000
local MAX_RESULTS = 80

local function relative(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

---Loads `path` (without listing it) and waits for a language server that handles `method` to attach.
---@return integer? buf, string? err
local function buffer_with_server(path, method)
  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) == 0 then
    return nil, path .. ": no such file"
  end
  local buf = vim.fn.bufadd(full)
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  if vim.bo[buf].filetype == "" then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("filetype detect")
    end)
  end
  local attached = vim.wait(5000, function()
    return #vim.lsp.get_clients({ bufnr = buf, method = method }) > 0
  end, 50)
  if not attached then
    local names = vim.tbl_map(function(client)
      return client.name
    end, vim.lsp.get_clients({ bufnr = buf }))
    local which = #names > 0 and (" (attached: " .. table.concat(names, ", ") .. ")") or " (none attached)"
    return nil, relative(full) .. ": no language server here answers " .. method .. which
  end
  return buf
end

---Parses `path:line[:col]`; without a column, `symbol` (or the line's first word) picks one.
---@return { path: string, row: integer, col: integer }?, string? err
local function parse_target(target, symbol)
  local path, line, col = target:match("^(.-):(%d+):(%d+)$")
  if not path then
    path, line = target:match("^(.-):(%d+)$")
  end
  if not path then
    return nil, "expected path:line or path:line:col, got " .. target
  end
  return { path = path, row = tonumber(line) - 1, col = col and tonumber(col) - 1, symbol = symbol }
end

local CONTENT_MODIFIED = -32801

---Like vim.lsp.buf_request_sync, but asks again while a server that's still loading the project answers
---"content modified".
local function request(buf, method, params)
  local results
  for _ = 1, 8 do
    results = vim.lsp.buf_request_sync(buf, method, params, TIMEOUT)
    local busy = false
    for _, response in pairs(results or {}) do
      busy = busy or (response.err ~= nil and response.err.code == CONTENT_MODIFIED)
    end
    if not busy then
      return results
    end
    vim.wait(1000)
  end
  return results
end

local function line_text(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

---The byte column to ask about: the given one, else where `symbol` appears on the line, else its first word.
---@return integer?, string? err
local function resolve_col(buf, target)
  local text = line_text(buf, target.row)
  if target.col then
    return target.col
  end
  if target.symbol then
    local escaped = vim.pesc(target.symbol)
    local s = text:find("%f[%w_]" .. escaped .. "%f[^%w_]") or text:find(escaped, 1, true)
    if not s then
      return nil, string.format("%s:%d doesn't contain %q: %s", target.path, target.row + 1, target.symbol, vim.trim(text))
    end
    -- In `ui.code_context` or `db::query` the name being asked about is the last part.
    local last_part = target.symbol:find("[%w_]+$")
    return s - 1 + (last_part and last_part - 1 or 0)
  end
  local s = text:find("[%w_]")
  return s and s - 1 or 0
end

local function position_params(buf, row, col)
  return function(client)
    local text = line_text(buf, row)
    local character = vim.str_utfindex(text, client.offset_encoding, math.min(col, #text), false)
    return { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = { line = row, character = character } }
  end
end

local file_lines = {}

local function source_line(path, row)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.trim(line_text(buf, row))
  end
  if not file_lines[path] then
    local ok, lines = pcall(vim.fn.readfile, path)
    file_lines[path] = ok and lines or {}
  end
  return vim.trim(file_lines[path][row + 1] or "")
end

---`path:line: code` for each location, nearest file first, without duplicates.
local function format_locations(results)
  local seen, out = {}, {}
  for _, response in pairs(results or {}) do
    local result = response.result
    if result and result.uri or (result and result.targetUri) then
      result = { result }
    end
    for _, loc in ipairs(result or {}) do
      local uri = loc.uri or loc.targetUri
      local range = loc.range or loc.targetSelectionRange
      if uri and range then
        local path = vim.uri_to_fname(uri)
        local key = path .. ":" .. range.start.line
        if not seen[key] then
          seen[key] = true
          table.insert(out, string.format("%s:%d: %s", relative(path), range.start.line + 1, source_line(path, range.start.line)))
        end
      end
    end
  end
  if #out > MAX_RESULTS then
    local total = #out
    out = vim.list_slice(out, 1, MAX_RESULTS)
    table.insert(out, string.format("… %d more", total - MAX_RESULTS))
  end
  return out
end

local function first_error(results)
  for _, response in pairs(results or {}) do
    if response.err then
      return response.err.message or vim.inspect(response.err)
    end
  end
end

---@param opts { method: string, target: string, symbol?: string, extra?: table, empty: string }
local function locations(opts)
  local target, err = parse_target(opts.target, opts.symbol)
  if not target then
    return { err }
  end
  local buf, buf_err = buffer_with_server(target.path, opts.method)
  if not buf then
    return { buf_err }
  end
  local col, col_err = resolve_col(buf, target)
  if not col then
    return { col_err }
  end
  local base = position_params(buf, target.row, col)
  local results = request(buf, opts.method, function(client)
    return vim.tbl_extend("force", base(client), opts.extra or {})
  end)
  if not results then
    return { "the language server didn't answer within " .. TIMEOUT / 1000 .. "s" }
  end
  local out = format_locations(results)
  if #out == 0 then
    return { first_error(results) or opts.empty }
  end
  return out
end

local function hover(target_arg, symbol)
  local target, err = parse_target(target_arg, symbol)
  if not target then
    return { err }
  end
  local buf, buf_err = buffer_with_server(target.path, "textDocument/hover")
  if not buf then
    return { buf_err }
  end
  local col, col_err = resolve_col(buf, target)
  if not col then
    return { col_err }
  end
  local results = request(buf, "textDocument/hover", position_params(buf, target.row, col))
  local out = {}
  for _, response in pairs(results or {}) do
    local contents = response.result and response.result.contents
    if contents then
      local lines = vim.lsp.util.convert_input_to_markdown_lines(contents)
      vim.list_extend(out, vim.split(vim.trim(table.concat(lines, "\n")), "\n", { plain = true }))
    end
  end
  return #out > 0 and out or { first_error(results) or "nothing to show here" }
end

local SYMBOL_KIND = {}
for name, number in pairs(vim.lsp.protocol.SymbolKind) do
  if type(number) == "number" then
    SYMBOL_KIND[number] = name:lower()
  end
end

local function symbols(path)
  local buf, err = buffer_with_server(path, "textDocument/documentSymbol")
  if not buf then
    return { err }
  end
  local results = request(buf, "textDocument/documentSymbol", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
  local out = {}
  local function add(list, depth)
    for _, symbol in ipairs(list or {}) do
      local range = symbol.selectionRange or symbol.range or (symbol.location and symbol.location.range)
      local line = range and (":" .. (range.start.line + 1)) or ""
      table.insert(out, string.format("%s%s %s  %s%s", string.rep("  ", depth), SYMBOL_KIND[symbol.kind] or "?", symbol.name, relative(path), line))
      add(symbol.children, depth + 1)
    end
  end
  for _, response in pairs(results or {}) do
    add(response.result, 0)
  end
  return #out > 0 and out or { first_error(results) or "no symbols" }
end

---Symbols named like `query` across the project.
local function workspace_symbols(query)
  local clients = vim.tbl_filter(function(client)
    return client:supports_method("workspace/symbol")
  end, vim.lsp.get_clients())
  if #clients == 0 then
    return { "no running language server searches the workspace; open a file of that language first (dalil-nvim open <path>)" }
  end
  local out, seen = {}, {}
  for _, client in ipairs(clients) do
    local response = client:request_sync("workspace/symbol", { query = query }, TIMEOUT)
    for _, symbol in ipairs(response and response.result or {}) do
      local loc = symbol.location
      if loc and loc.uri and loc.range then
        local path = vim.uri_to_fname(loc.uri)
        local entry = string.format("%s %s  %s:%d", SYMBOL_KIND[symbol.kind] or "?", symbol.name, relative(path), loc.range.start.line + 1)
        if not seen[entry] and #out < MAX_RESULTS then
          seen[entry] = true
          table.insert(out, entry)
        end
      end
    end
  end
  return #out > 0 and out or { "no symbols match " .. query }
end

local function call_item_line(item)
  local path = vim.uri_to_fname(item.uri)
  local row = (item.selectionRange or item.range).start.line
  return string.format("%s  %s:%d", item.name, relative(path), row + 1)
end

---Who calls the function at the target, and what it calls.
local function calls(target_arg, symbol)
  local method = "textDocument/prepareCallHierarchy"
  local target, err = parse_target(target_arg, symbol)
  if not target then
    return { err }
  end
  local buf, buf_err = buffer_with_server(target.path, method)
  if not buf then
    return { buf_err }
  end
  local col, col_err = resolve_col(buf, target)
  if not col then
    return { col_err }
  end
  local client = vim.lsp.get_clients({ bufnr = buf, method = method })[1]
  local prepared = client:request_sync(method, position_params(buf, target.row, col)(client), TIMEOUT, buf)
  local item = prepared and prepared.result and prepared.result[1]
  if not item then
    return { (prepared and prepared.err and prepared.err.message) or "no function or method at that position" }
  end
  local out = { "function: " .. call_item_line(item), "", "called from:" }
  local incoming = client:request_sync("callHierarchy/incomingCalls", { item = item }, TIMEOUT, buf)
  local before = #out
  for _, call in ipairs(incoming and incoming.result or {}) do
    local from = call.from
    for _, range in ipairs(call.fromRanges or {}) do
      local path = vim.uri_to_fname(from.uri)
      table.insert(out, string.format("  %s:%d: %s  (in %s)", relative(path), range.start.line + 1, source_line(path, range.start.line), from.name))
    end
  end
  if #out == before then
    table.insert(out, "  (no callers found)")
  end
  table.insert(out, "")
  table.insert(out, "calls:")
  before = #out
  local outgoing = client:request_sync("callHierarchy/outgoingCalls", { item = item }, TIMEOUT, buf)
  local library_calls = {}
  for _, call in ipairs(outgoing and outgoing.result or {}) do
    -- Built-ins and dependencies (String.trim, lodash…) are named, not located; their source isn't the project's.
    if vim.uri_to_fname(call.to.uri):find("/node_modules/", 1, true) then
      table.insert(library_calls, call.to.name)
    else
      table.insert(out, "  " .. call_item_line(call.to))
    end
  end
  if #library_calls > 0 then
    table.insert(out, "  library: " .. table.concat(library_calls, ", "))
  end
  if #out == before then
    table.insert(out, "  (none found)")
  end
  return out
end

M.USAGE = [[
  definition <path:line[:col]> [symbol]       where the symbol is defined
  type-definition <path:line[:col]> [symbol]  where its type is defined
  implementation <path:line[:col]> [symbol]   implementations of an interface or abstract method
  references <path:line[:col]> [symbol]       every use of the symbol across the project
  hover <path:line[:col]> [symbol]            its type and docs
  calls <path:line[:col]> [symbol]            who calls this function, and what it calls
  symbols <path>                              outline of a file
  workspace-symbols <query>                   symbols named like query, across the project
    Without a column, [symbol] says which word on the line to ask about (else its first word).]]

---@param command string
---@param args string[]
---@return string[]?
function M.run(command, args)
  if command == "definition" then
    return locations({ method = "textDocument/definition", target = args[1], symbol = args[2], empty = "no definition found" })
  elseif command == "type-definition" then
    return locations({ method = "textDocument/typeDefinition", target = args[1], symbol = args[2], empty = "no type definition found" })
  elseif command == "implementation" then
    return locations({ method = "textDocument/implementation", target = args[1], symbol = args[2], empty = "no implementations found" })
  elseif command == "references" then
    return locations({
      method = "textDocument/references",
      target = args[1],
      symbol = args[2],
      extra = { context = { includeDeclaration = false } },
      empty = "no references found",
    })
  elseif command == "hover" then
    return hover(args[1], args[2])
  elseif command == "calls" then
    return calls(args[1], args[2])
  elseif command == "symbols" then
    return symbols(args[1])
  elseif command == "workspace-symbols" then
    return workspace_symbols(table.concat(args, " "))
  end
end

return M
