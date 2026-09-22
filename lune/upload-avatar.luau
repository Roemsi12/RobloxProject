--!strict
-- Uploads the avatar textures in art/avatar/textures to Roblox as Image assets
-- and writes their ids into src/shared/AvatarTextures.luau.
--
--   lune run upload-avatar --user-id 12345
--   lune run upload-avatar --group-id 67890
--   lune run upload-avatar --user-id 12345 --force shirt_tunic eyes_glow
--
-- Run from the repository root. Needs an Open Cloud API key in the
-- ROBLOX_API_KEY environment variable (create.roblox.com -> Open Cloud ->
-- API Keys, Assets API read + write), owned by the same user or group passed
-- here. Upload under whoever owns the experience, or the images may not load
-- in it.
--
-- Only textures whose id is still 0 are uploaded; name textures after --force
-- to replace particular ones. The registry is rewritten after every upload,
-- so an interrupted run keeps what it did and a re-run picks up the rest.

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local TEXTURES = "art/avatar/textures"
local REGISTRY = "src/shared/AvatarTextures.luau"
local API = "https://apis.roblox.com/assets/v1"

local function fail(message: string): never
	print(message)
	process.exit(1)
	error(message)
end

-- Arguments
local creator: { [string]: string }? = nil
local force: { [string]: boolean } = {}
do
	local args = process.args
	local i = 1
	while i <= #args do
		local arg = args[i]
		if arg == "--user-id" then
			creator = { userId = args[i + 1] }
			i += 2
		elseif arg == "--group-id" then
			creator = { groupId = args[i + 1] }
			i += 2
		elseif arg == "--force" then
			for j = i + 1, #args do
				force[args[j]] = true
			end
			break
		else
			fail(`unknown argument {arg}`)
		end
	end
end

if not creator then
	fail("pass --user-id <id> or --group-id <id>")
end

local key = process.env.ROBLOX_API_KEY
if not key or key == "" then
	fail("set ROBLOX_API_KEY to an Open Cloud API key with Assets read + write")
end

local function send(method: string, url: string, body: string?, contentType: string?): any
	local headers: { [string]: string } = { ["x-api-key"] = key :: string }
	if contentType then
		headers["Content-Type"] = contentType
	end
	local response = net.request({ url = url, method = method :: any, headers = headers, body = body })
	if not response.ok then
		fail(`{method} {url} failed: {response.statusCode} {response.body}`)
	end
	return if response.body ~= "" then serde.decode("json", response.body) else {}
end

-- Uploads one PNG and waits for Roblox to hand back its asset id.
local function upload(name: string, path: string): number
	local boundary = `----avatar{math.random(1e9)}{os.time()}`
	local meta = serde.encode("json", {
		assetType = "Image",
		displayName = name,
		description = "Dungeon crawler avatar texture",
		creationContext = { creator = creator },
	})
	local body = table.concat({
		`--{boundary}\r\nContent-Disposition: form-data; name="request"\r\n\r\n{meta}\r\n`,
		`--{boundary}\r\nContent-Disposition: form-data; name="fileContent"; filename="{name}.png"\r\n`,
		"Content-Type: image/png\r\n\r\n",
		fs.readFile(path),
		`\r\n--{boundary}--\r\n`,
	})

	local operation = send("POST", `{API}/assets`, body, `multipart/form-data; boundary={boundary}`)

	-- Uploads are asynchronous: poll until the operation carries an asset id.
	for _ = 1, 60 do
		if operation.done and operation.response then
			return tonumber(operation.response.assetId) :: number
		end
		task.wait(1.5)
		operation = send("GET", `{API}/{operation.path}`)
	end
	return fail(`{name}: upload never finished`)
end

local source = fs.readFile(REGISTRY)

local names: { string } = {}
for name, id in source:gmatch("\n\t([%w_]+) = (%d+),") do
	if tonumber(id) == 0 or force[name] then
		table.insert(names, name)
	end
end

if #names == 0 then
	print("every texture already has an id (use --force <name> to replace one)")
	return
end

for _, name in names do
	local path = `{TEXTURES}/{name}.png`
	if not fs.isFile(path) then
		print(`skip {name}: no {path}`)
		continue
	end
	local id = upload(name, path)
	source = source:gsub(`(\n\t{name} = )%d+,`, `%1{id},`)
	fs.writeFile(REGISTRY, source)
	print(`{name} -> {id}`)
end

print("done")
