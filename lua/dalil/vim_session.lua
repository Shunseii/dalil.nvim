-- Keeps the chat with Vim sessions (:mksession, persistence.nvim, LazyVim's "Restore Session"): writing a
-- session remembers which conversation was open and whether the chat was showing; loading it brings both back.

local conversations = require("dalil.conversations")

local M = {}

---@class dalil.SessionState
---@field conversation? dalil.Conversation
---@field open boolean

local function state_path(session_file)
  local dir = vim.fn.stdpath("data") .. "/dalil/sessions"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. vim.fn.sha256(vim.fs.normalize(session_file)):sub(1, 16) .. ".json"
end

---@param opts { conversation?: dalil.Conversation, open: boolean }
function M.write(opts)
  local session_file = vim.v.this_session
  if session_file == "" then
    return
  end
  local conversation = opts.conversation
  if conversation and #conversation.events == 0 then
    conversation = nil
  end
  local data = vim.json.encode({ conversation = conversation, open = opts.open })
  vim.fn.writefile({ data }, state_path(session_file))
end

---What the session that was just loaded had in the chat; nil when it never used it.
---@return dalil.SessionState?
function M.read()
  local session_file = vim.v.this_session
  if session_file == "" then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, state_path(session_file))
  if not ok or #lines == 0 then
    return nil
  end
  local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"), { luanil = { object = true, array = true } })
  if not decoded or type(data) ~= "table" then
    return nil
  end
  local conversation = data.conversation
  if conversation and conversation.saved then
    -- A saved conversation may have moved on in another Neovim since; its file is the latest.
    conversation = conversations.read(conversation.id) or vim.tbl_extend("force", conversation, { saved = false })
  end
  if conversation then
    conversation.events = conversation.events or {}
  end
  return { conversation = conversation, open = data.open == true }
end

return M
