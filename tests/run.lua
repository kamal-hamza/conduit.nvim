-- Minimal test runner: `nvim --headless -u NONE -l tests/run.lua`
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd.runtime("plugin/conduit.lua")

local failures, total = 0, 0

---@param name string
---@param fn fun()
function _G.test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. "\n" .. tostring(err))
    end
end

---@param cond fun(): any Truthy when done
---@param msg string
function _G.wait_for(cond, msg)
    if not vim.wait(5000, cond, 10) then
        error("timed out waiting for: " .. msg, 2)
    end
end

for _, file in ipairs(vim.fn.glob("tests/*_spec.lua", false, true)) do
    dofile(file)
end

print(("\n%d/%d passed"):format(total - failures, total))
os.exit(failures > 0 and 1 or 0)
