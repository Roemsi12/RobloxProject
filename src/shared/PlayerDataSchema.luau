--!strict
-- The saved shape of a player's progress, and every rule for trusting it:
-- defaults, version migration, sanitisation, and session locking.
--
-- Pure Luau — no Roblox API — so it's unit-tested. DataService does the
-- DataStore I/O and asks this module every question about what it read.
--
-- Two rules run through all of it:
--
-- 1. Never overwrite what we can't understand. Data written by a newer
--    version of the game, or data that isn't a record at all, is reported
--    rather than replaced. Replacing it would be permanent data loss.
--
-- 2. Sanitising fixes shapes; it never drops ids it doesn't recognise. A
--    weapon, class or item this server doesn't know may simply be newer than
--    this server. During a rollback, an older server loading and re-saving a
--    profile must not delete progress made on content it hasn't heard of.

local AppearanceDefs = require(script.Parent.AppearanceDefs)
local EconomyDefs = require(script.Parent.EconomyDefs)
local ProgressionDefs = require(script.Parent.ProgressionDefs)

local PlayerDataSchema = {}

PlayerDataSchema.CURRENT_VERSION = 3

-- Keeps a single record comfortably inside the DataStore value size limit.
PlayerDataSchema.MAX_INVENTORY = 500

-- Keeps counts finite and exactly representable (below 2^53).
local MAX_COUNT = 1e15

-- Ranks are clamped per node by SkillTreeDefs when they're read, which is the
-- only place that knows what each node's cap is. This is just a sane ceiling
-- so a saved rank can't be an astronomical number.
local MAX_RANK = 99

export type ItemInstance = {
	itemId: string,
	rarity: string,
	upgradeLevel: number,
	classTag: string?,
}

export type PlayerData = {
	version: number,
	coins: number,
	-- classTag -> count
	crystals: { [string]: number },
	-- Shaped as a table so armour slots can join the weapon later.
	equipped: { weapon: string? },
	-- weaponId -> level
	upgradeLevels: { [string]: number },
	inventory: { ItemInstance },
	-- Total XP ever earned. The level is derived from it rather than stored,
	-- so re-tuning the curve re-levels everyone instead of leaving them at a
	-- level their XP no longer justifies (ProgressionDefs).
	xp: number,
	-- weaponId -> nodeId -> ranks. Per weapon for the same reason
	-- upgradeLevels is: your weapon is your class (SkillTreeDefs).
	skills: { [string]: { [string]: number } },
	-- How their character looks. Every field is an id from AppearanceDefs,
	-- which owns what those ids mean and what an unknown one falls back to.
	appearance: AppearanceDefs.Look,
}

-- Which server currently owns a profile. Stored alongside the data.
export type SessionLock = {
	jobId: string,
	-- os.time() of the owner's last save.
	heartbeat: number,
}

-- "new": nothing stored yet. "future_version": written by a newer game
-- version. "corrupt": not a record we can read. Only "ok" and "new" may be
-- written back.
export type MigrationStatus = "ok" | "new" | "future_version" | "corrupt"

function PlayerDataSchema.default(): PlayerData
	return {
		version = PlayerDataSchema.CURRENT_VERSION,
		coins = 0,
		crystals = {},
		equipped = {},
		upgradeLevels = {},
		inventory = {},
		xp = 0,
		skills = {},
		appearance = AppearanceDefs.default(),
	}
end

--[[ Sanitising ]]

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A whole, non-negative count within `max`. Anything that isn't a finite
-- number becomes 0.
local function toCount(value: unknown, max: number): number
	if not isFiniteNumber(value) then
		return 0
	end

	return math.clamp(math.floor(value :: number), 0, max)
end

-- String keys to counts. Entries whose key isn't a string or whose value isn't
-- a finite number are malformed and dropped; every well-formed entry is kept,
-- whether or not this server recognises the key.
local function sanitizeCountMap(value: unknown, max: number): { [string]: number }
	local result = {}
	if type(value) ~= "table" then
		return result
	end

	for key, count in value :: { [any]: any } do
		if type(key) == "string" and isFiniteNumber(count) then
			result[key] = toCount(count, max)
		end
	end

	return result
end

-- weaponId -> nodeId -> ranks. Two levels of the same rule as
-- sanitizeCountMap: fix the shape, keep every id, recognised or not.
local function sanitizeSkills(value: unknown): { [string]: { [string]: number } }
	local result = {}
	if type(value) ~= "table" then
		return result
	end

	for weaponId, nodes in value :: { [any]: any } do
		if type(weaponId) == "string" then
			result[weaponId] = sanitizeCountMap(nodes, MAX_RANK)
		end
	end

	return result
end

local function sanitizeItem(value: unknown): ItemInstance?
	if type(value) ~= "table" then
		return nil
	end

	local item = value :: { [string]: any }
	if type(item.itemId) ~= "string" or item.itemId == "" or type(item.rarity) ~= "string" then
		return nil
	end

	local classTag = item.classTag
	if classTag ~= nil and type(classTag) ~= "string" then
		return nil
	end

	return {
		itemId = item.itemId,
		rarity = item.rarity,
		upgradeLevel = toCount(item.upgradeLevel, EconomyDefs.MAX_UPGRADE_LEVEL),
		classTag = classTag,
	}
end

local function sanitizeInventory(value: unknown): { ItemInstance }
	local result = {}
	if type(value) ~= "table" then
		return result
	end

	-- Numeric walk rather than generic iteration, so order is preserved and a
	-- stray non-array key can't sneak in.
	local list = value :: { any }
	for index = 1, #list do
		if #result >= PlayerDataSchema.MAX_INVENTORY then
			break
		end

		local item = sanitizeItem(list[index])
		if item then
			table.insert(result, item)
		end
	end

	return result
end

-- A clean copy of `raw` in the current shape. Always returns a new table, so
-- the result can be handed around without aliasing whatever it was built from.
function PlayerDataSchema.sanitize(raw: unknown): PlayerData
	if type(raw) ~= "table" then
		return PlayerDataSchema.default()
	end

	local record = raw :: { [string]: any }

	local equippedWeapon: string? = nil
	if type(record.equipped) == "table" and type(record.equipped.weapon) == "string" then
		equippedWeapon = record.equipped.weapon
	end

	return {
		version = PlayerDataSchema.CURRENT_VERSION,
		coins = toCount(record.coins, MAX_COUNT),
		crystals = sanitizeCountMap(record.crystals, MAX_COUNT),
		equipped = { weapon = equippedWeapon },
		-- A lowered upgrade cap is a deliberate balance change, so levels are
		-- clamped to the current one.
		upgradeLevels = sanitizeCountMap(record.upgradeLevels, EconomyDefs.MAX_UPGRADE_LEVEL),
		inventory = sanitizeInventory(record.inventory),
		-- Held at what the level cap is worth, so a maxed player's XP doesn't
		-- climb forever with nothing to show for it.
		xp = ProgressionDefs.cap(toCount(record.xp, MAX_COUNT)),
		skills = sanitizeSkills(record.skills),
		-- Unlike the id rule above, a look is sanitised *down* to ids this
		-- server knows. It has to be: an unknown hairstyle is not progress
		-- being preserved, it is a character with no hair. AppearanceDefs
		-- falls each unknown field back on its own rather than replacing the
		-- whole look, so a newer server's choice of hair doesn't cost the
		-- player their face as well.
		appearance = AppearanceDefs.sanitize(record.appearance),
	}
end

--[[ Migration ]]

-- migrations[n] turns a version-n record into a version-(n+1) record. Add a
-- step here and bump CURRENT_VERSION together.
local migrations: { [number]: (any) -> any } = {
	-- 1 -> 2: XP and skill trees arrived. Everyone who played before them
	-- starts at level 1 with an empty tree rather than being paid XP for
	-- runs nobody recorded — sanitize fills both in, so there is nothing to
	-- copy across. The step exists to say that out loud, and because a
	-- missing step is treated as corrupt data.
	[1] = function(data: any): any
		return data
	end,

	-- 2 -> 3: characters became the game's own body rather than the player's
	-- Roblox avatar, so a look is saved. Everyone who played before it gets
	-- the default one, which sanitize fills in — the same "nothing to copy
	-- across, but say so" step as above. Their first visit to the mirror is
	-- where they become someone.
	[2] = function(data: any): any
		return data
	end,
}

-- Turns whatever was stored into current-version data, and says whether it
-- may be written back. For "future_version" and "corrupt", the returned data
-- is only a placeholder — the caller must not save it.
function PlayerDataSchema.migrate(raw: unknown): (PlayerData, MigrationStatus)
	if raw == nil then
		return PlayerDataSchema.default(), "new"
	end

	if type(raw) ~= "table" then
		return PlayerDataSchema.default(), "corrupt"
	end

	local record = raw :: { [string]: any }
	local version = record.version
	-- Every record this game writes carries a version, so one without a valid
	-- version didn't come from us.
	if not isFiniteNumber(version) or version ~= math.floor(version) or version < 1 then
		return PlayerDataSchema.default(), "corrupt"
	end

	if version > PlayerDataSchema.CURRENT_VERSION then
		return PlayerDataSchema.default(), "future_version"
	end

	local data: any = record
	local at = version :: number
	while at < PlayerDataSchema.CURRENT_VERSION do
		local step = migrations[at]
		if not step then
			return PlayerDataSchema.default(), "corrupt"
		end

		data = step(data)
		at += 1
	end

	return PlayerDataSchema.sanitize(data), "ok"
end

--[[ Session locking ]]

-- Whether the server `jobId` may take ownership of a profile. It may if nobody
-- holds it, if it already does, or if the holder has stopped heartbeating for
-- longer than `staleAfter` seconds — a crashed server never releases its lock.
function PlayerDataSchema.canClaim(lock: unknown, jobId: string, now: number, staleAfter: number): boolean
	if type(lock) ~= "table" then
		return true
	end

	local held = lock :: { [string]: any }
	if held.jobId == jobId then
		return true
	end

	-- A lock we can't read is treated as no lock rather than a permanent block.
	if not isFiniteNumber(held.heartbeat) then
		return true
	end

	return now - held.heartbeat > staleAfter
end

-- Whether `jobId` still owns the profile. Checked before every save: if
-- another server took over, this one must stop writing.
function PlayerDataSchema.isOwnedBy(lock: unknown, jobId: string): boolean
	return type(lock) == "table" and (lock :: { [string]: any }).jobId == jobId
end

return PlayerDataSchema
