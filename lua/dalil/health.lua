local M = {}

function M.check()
  local config = require("dalil").config
  vim.health.start("dalil.nvim")

  local adapter = config.cmd[1]
  if vim.fn.executable(adapter) == 1 then
    vim.health.ok(adapter .. " found: " .. vim.fn.exepath(adapter))
  else
    vim.health.error(adapter .. " not found", { "npm install -g @agentclientprotocol/claude-agent-acp" })
  end

  if vim.fn.executable(config.claude_cmd) == 1 then
    vim.health.ok("Claude Code found: " .. vim.fn.exepath(config.claude_cmd))
  else
    vim.health.warn(config.claude_cmd .. " not found; the adapter falls back to its bundled Claude CLI")
  end

  if vim.env.ANTHROPIC_API_KEY and vim.env.ANTHROPIC_API_KEY ~= "" then
    vim.health.warn("ANTHROPIC_API_KEY is set, so Claude Code bills the API instead of your subscription")
  else
    vim.health.ok("ANTHROPIC_API_KEY not set; your Claude Code login is used")
  end
end

return M
