-- Type-checks Teal files against the game's API definitions.
-- usage: lua tools/check.lua <tf3_dir> <file.tl>...
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local game = arg[1]
package.path = root .. "/.tools/?.lua;" .. package.path
local tl = require("tl")
package.path = table.concat({
	root .. "/tools/?.d.tl",
	root .. "/mod/pgrace_closest_consumer/tealdef/?.d.tl",
	game .. "/api/tealdef/?.d.tl",
	game .. "/base/tealdef/?.d.tl",
}, ";") .. ";" .. package.path

local total = 0
for i = 2, #arg do
	local env = tl.new_env({ predefined_modules = { "check_def" }, defaults = { gen_target = "5.1" } })
	local result, err = tl.check_file(arg[i], env)
	if not result then
		print(arg[i] .. ": " .. tostring(err))
		total = total + 1
	else
		for _, list in ipairs({ result.syntax_errors or {}, result.type_errors or {} }) do
			for _, e in ipairs(list) do
				print(("%s:%d:%d: %s"):format(e.filename, e.y, e.x, e.msg))
				total = total + 1
			end
		end
	end
end
print(total .. " error(s)")
os.exit(total == 0 and 0 or 1)
