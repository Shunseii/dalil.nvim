-- Saved conversations: one JSON file each under stdpath("data")/dalil/conversations.

local M = {}

---@alias dalil.Event
---| { type: "user", text: string }
---| { type: "agent", text: string }
---| { type: "thought", text: string }
---| { type: "tool", id: string, title: string, status: string, kind?: string }
---| { type: "notice", text: string, hl?: string }

---@class dalil.Conversation
---@field id string
---@field cwd string
---@field session_id? string the Claude session the next message continues
---@field title string
---@field created_at integer
---@field updated_at integer
---@field events dalil.Event[]
---@field saved boolean

local function dir()
  return vim.fn.stdpath("data") .. "/dalil/conversations"
end

local function path(id)
  return dir() .. "/" .. id .. ".json"
end

---@param cwd string
---@return dalil.Conversation
function M.new(cwd)
  local now = os.time()
  return {
    id = os.date("%Y%m%d-%H%M%S", now) .. "-" .. vim.fn.sha256(tostring(vim.uv.hrtime())):sub(1, 6),
    cwd = cwd,
    title = "",
    created_at = now,
    updated_at = now,
    events = {},
    saved = false,
  }
end

---@param conv dalil.Conversation
function M.write(conv)
  vim.fn.mkdir(dir(), "p")
  conv.updated_at = os.time()
  local data = vim.deepcopy(conv)
  data.saved = nil
  local tmp = path(conv.id) .. ".tmp"
  vim.fn.writefile({ vim.json.encode(data) }, tmp)
  vim.uv.fs_rename(tmp, path(conv.id))
end

---@param id string
---@return dalil.Conversation?
function M.read(id)
  local ok, lines = pcall(vim.fn.readfile, path(id))
  if not ok or #lines == 0 then
    return nil
  end
  local decoded, conv = pcall(vim.json.decode, table.concat(lines, "\n"), { luanil = { object = true, array = true } })
  if not decoded or type(conv) ~= "table" then
    return nil
  end
  conv.saved = true
  conv.events = conv.events or {}
  return conv
end

---@param id string
function M.delete(id)
  vim.fn.delete(path(id))
end

---Saved conversations, most recently used first; only those started in `cwd` when it's given.
---@param opts { cwd?: string }
---@return dalil.Conversation[]
function M.list(opts)
  local found = {}
  for name, kind in vim.fs.dir(dir()) do
    if kind == "file" and name:match("%.json$") then
      local conv = M.read(name:gsub("%.json$", ""))
      if conv and (not opts.cwd or conv.cwd == opts.cwd) then
        table.insert(found, conv)
      end
    end
  end
  table.sort(found, function(a, b)
    return a.updated_at > b.updated_at
  end)
  return found
end

---@param conv dalil.Conversation
---@return integer
function M.question_count(conv)
  return #vim.tbl_filter(function(event)
    return event.type == "user"
  end, conv.events)
end

---A title for the list: Claude's, else the first question.
---@param conv dalil.Conversation
function M.display_title(conv)
  if conv.title ~= "" then
    return conv.title
  end
  for _, event in ipairs(conv.events) do
    if event.type == "user" then
      local first = vim.split(event.text, "\n", { plain = true })[1]
      return #first > 60 and (first:sub(1, 57) .. "...") or first
    end
  end
  return "Untitled"
end

---@param time integer
function M.ago(time)
  local seconds = os.time() - time
  if seconds < 60 then
    return "just now"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m ago"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h ago"
  elseif seconds < 86400 * 7 then
    return math.floor(seconds / 86400) .. "d ago"
  end
  return os.date("%Y-%m-%d", time)
end

return M
