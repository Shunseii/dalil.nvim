-- JSON-RPC 2.0 over a child process's stdio, one message per line (ACP's stdio transport).

local Rpc = {}
Rpc.__index = Rpc

local DECODE_OPTS = { luanil = { object = true, array = true } }

---@class dalil.RpcOpts
---@field cmd string[]
---@field env? table<string, string>
---@field cwd? string
---@field on_request fun(method: string, params: table, respond: fun(result?: table, err?: table))
---@field on_notification fun(method: string, params: table)
---@field on_stderr? fun(data: string)
---@field on_exit fun(code: integer)

---@param opts dalil.RpcOpts
function Rpc.start(opts)
  local self = setmetatable({ next_id = 0, pending = {}, partial = "", opts = opts }, Rpc)
  self.proc = vim.system(opts.cmd, {
    stdin = true,
    cwd = opts.cwd,
    env = opts.env,
    stdout = function(_, data)
      if data then
        self:_read(data)
      end
    end,
    stderr = function(_, data)
      if data and opts.on_stderr then
        vim.schedule(function()
          opts.on_stderr(data)
        end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      for _, callback in pairs(self.pending) do
        callback({ message = "agent exited" }, nil)
      end
      self.pending = {}
      opts.on_exit(result.code)
    end)
  end)
  return self
end

function Rpc:_read(data)
  self.partial = self.partial .. data
  while true do
    local newline = self.partial:find("\n", 1, true)
    if not newline then
      return
    end
    local line = self.partial:sub(1, newline - 1)
    self.partial = self.partial:sub(newline + 1)
    if line ~= "" then
      vim.schedule(function()
        self:_dispatch(line)
      end)
    end
  end
end

function Rpc:_dispatch(line)
  local ok, msg = pcall(vim.json.decode, line, DECODE_OPTS)
  if not ok or type(msg) ~= "table" then
    return
  end
  if msg.method and msg.id ~= nil then
    self.opts.on_request(msg.method, msg.params or {}, function(result, err)
      self:_write({ jsonrpc = "2.0", id = msg.id, result = err == nil and (result or vim.empty_dict()) or nil, error = err })
    end)
  elseif msg.method then
    self.opts.on_notification(msg.method, msg.params or {})
  elseif msg.id ~= nil then
    local callback = self.pending[msg.id]
    self.pending[msg.id] = nil
    if callback then
      callback(msg.error, msg.result)
    end
  end
end

function Rpc:_write(msg)
  if self.proc then
    pcall(self.proc.write, self.proc, vim.json.encode(msg) .. "\n")
  end
end

---@param method string
---@param params table
---@param callback? fun(err?: table, result?: table)
function Rpc:request(method, params, callback)
  self.next_id = self.next_id + 1
  self.pending[self.next_id] = callback or function() end
  self:_write({ jsonrpc = "2.0", id = self.next_id, method = method, params = params })
end

function Rpc:notify(method, params)
  self:_write({ jsonrpc = "2.0", method = method, params = params })
end

function Rpc:stop()
  if self.proc then
    pcall(self.proc.kill, self.proc, 15)
    self.proc = nil
  end
end

return Rpc
