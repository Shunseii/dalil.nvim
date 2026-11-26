-- Runs as `nvim -l`: forwards the arguments to the user's Neovim (the socket in $DALIL_NVIM) and prints the answer.

local server = os.getenv("DALIL_NVIM")
if not server or server == "" then
  io.stderr:write("dalil-nvim: DALIL_NVIM isn't set; this command works from the dalil.nvim chat\n")
  os.exit(2)
end

local ok, chan = pcall(vim.fn.sockconnect, "pipe", server, { rpc = true })
if not ok or chan == 0 then
  io.stderr:write("dalil-nvim: can't reach Neovim at " .. server .. "\n")
  os.exit(2)
end

local args = {}
for i = 1, #arg do
  args[i] = arg[i]
end

local called, out = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return require('dalil.agent').cli(...)", { args })
if not called then
  io.stderr:write("dalil-nvim: " .. tostring(out) .. "\n")
  os.exit(1)
end
io.stdout:write(out, "\n")
