--!strict
-- Loads the game's src/shared modules outside Roblox, for Lune scripts.
--
-- `SharedModules.load(dir).Name` returns what src/shared/Name.luau returns,
-- loading it (and whatever it requires as `script.Parent.X`) on first use.
--
-- Modules run in a sandbox where `game`, `workspace` and `Instance` are traps
-- that name the rule they broke: the modules loaded this way are the ones
-- ARCHITECTURE.md says must not touch the Roblox API. RigAssembly is the one
-- exception loaded here, and it's safe because it only ever uses the API it
-- is handed.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local SharedModules = {}

-- Passed as `require` inside modules: `script.Parent.X` has already been
-- resolved to X's value by the folder proxy.
local function passThroughRequire(module: any): any
	return module
end

-- A stand-in global that errors on any use, naming the rule it broke.
-- How `game`, `workspace` and `Instance` are made unavailable: a module
-- that reaches for one fails here rather than quietly becoming untestable.
local function robloxTrap(globalName: string): any
	local message = `{globalName} used by a shared module — pure modules must not call the Roblox API`
	return setmetatable({}, {
		__index = function()
			error(message, 2)
		end,
		__call = function()
			error(message, 2)
		end,
	})
end

-- Loads every module in a directory into a table, lazily, in a sandbox
-- with the Roblox globals trapped.
--
-- Sources are read up front because `fs.readFile` yields, and yielding is
-- not allowed inside the metamethod that resolves `script.Parent.X`.
function SharedModules.load(dir: string): any
	if not fs.isDir(dir) then
		error(`Can't find {dir}. Run Lune scripts from the repository root.`, 2)
	end

	-- Read up front: fs.readFile yields, and yielding isn't allowed inside the
	-- __index metamethod that resolves `script.Parent.X`.
	local sources: { [string]: string } = {}
	for _, entry in fs.readDir(dir) do
		local name = string.match(entry, "^(.+)%.luau$")
		if name and fs.isFile(`{dir}/{entry}`) then
			sources[name] = fs.readFile(`{dir}/{entry}`)
		end
	end

	local loaded: { [string]: any } = {}
	local loading: { [string]: boolean } = {}
	local folder = {}

	-- One module by name, compiled and cached on first use. Recurses through
	-- whatever it requires, so asking for one module pulls in its dependencies.
	local function loadModule(name: string): any
		if loaded[name] ~= nil then
			return loaded[name]
		end

		local source = sources[name]
		if not source then
			error(`no shared module named "{name}"`, 3)
		end

		if loading[name] then
			error(`circular require involving "{name}"`, 3)
		end
		loading[name] = true

		local chunk = luau.load(source, {
			debugName = `{dir}/{name}.luau`,
			environment = {
				script = { Parent = folder, Name = name },
				require = passThroughRequire,
				game = robloxTrap("game"),
				workspace = robloxTrap("workspace"),
				Instance = robloxTrap("Instance"),
			},
		})

		-- Clear the in-progress flag even when loading fails, or every later
		-- require of this module would misreport the failure as a cycle.
		local ok, value = pcall(chunk)
		loading[name] = nil
		if not ok then
			error(value, 0)
		end

		loaded[name] = value
		return value
	end

	return setmetatable(folder, {
		__index = function(_, key)
			return loadModule(key)
		end,
	})
end

return SharedModules
