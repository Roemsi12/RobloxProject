--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EconomyDefs = require(Shared.EconomyDefs)
local AppearanceDefs = require(Shared.AppearanceDefs)
local PlayerDataSchema = require(Shared.PlayerDataSchema)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local CURRENT = PlayerDataSchema.CURRENT_VERSION

-- A complete, current-version profile. The fixture every test starts
-- from, so a case is one field changed rather than a record rebuilt.
local function validRecord(): { [string]: any }
	return {
		version = CURRENT,
		coins = 320,
		crystals = { Tank = 2, Healer = 1 },
		equipped = { weapon = "Staff" },
		upgradeLevels = { Staff = 3, Daggers = 1 },
		inventory = {
			{ itemId = "PracticeToken", rarity = "common", upgradeLevel = 0 },
			{ itemId = "BoneHiltShard", rarity = "uncommon", upgradeLevel = 0 },
		},
		xp = 1500,
		skills = { Staff = { kind_hand = 2 } },
		appearance = AppearanceDefs.default(),
	}
end

describe("PlayerDataSchema.default", function()
	it("starts a new player with nothing, at the current version", function()
		expect(PlayerDataSchema.default()).toEqual({
			version = CURRENT,
			coins = 0,
			crystals = {},
			equipped = {},
			upgradeLevels = {},
			inventory = {},
			xp = 0,
			skills = {},
			appearance = AppearanceDefs.default(),
		})
	end)

	it("returns a fresh table every time", function()
		local a = PlayerDataSchema.default()
		a.coins = 99
		expect(PlayerDataSchema.default().coins).toBe(0)
	end)
end)

describe("PlayerDataSchema appearance", function()
	it("gives a record with no look the default one", function()
		local record = validRecord()
		record.appearance = nil
		expect(PlayerDataSchema.sanitize(record).appearance).toEqual(AppearanceDefs.default())
	end)

	-- The opposite of the rule for ids everywhere else in this file. An
	-- unrecognised weapon may simply be newer than this server and is kept; an
	-- unrecognised hairstyle is a character with no hair, so it falls back.
	it("falls an unknown choice back without losing the rest of the look", function()
		local record = validRecord()
		record.appearance = {
			build = "standard",
			skin = "corpse",
			hair = "something_this_server_has_never_heard_of",
			hairColor = "white",
			face = "hollowed",
			marking = "scar",
			garb = "plate",
			garbColor = "iron",
			trimColor = "gold",
		}

		local clean = PlayerDataSchema.sanitize(record).appearance
		expect(clean.hair).toBe(AppearanceDefs.default().hair)
		-- Everything the server does recognise survives.
		expect(clean.skin).toBe("corpse")
		expect(clean.face).toBe("hollowed")
		expect(clean.garb).toBe("plate")
		expect(clean.trimColor).toBe("gold")
	end)

	it("survives a look that isn't a record at all", function()
		local record = validRecord()
		record.appearance = "penguin"
		expect(PlayerDataSchema.sanitize(record).appearance).toEqual(AppearanceDefs.default())
	end)

	-- Everyone who played before the mirror existed has a version-2 profile.
	it("carries a pre-appearance profile forward", function()
		local old = validRecord()
		old.version = 2
		old.appearance = nil

		local data, status = PlayerDataSchema.migrate(old)
		expect(status).toBe("ok")
		expect(data.coins).toBe(old.coins)
		expect(data.appearance).toEqual(AppearanceDefs.default())
	end)
end)

describe("PlayerDataSchema.migrate", function()
	it("treats a missing record as a new player", function()
		local data, status = PlayerDataSchema.migrate(nil)
		expect(status).toBe("new")
		expect(data).toEqual(PlayerDataSchema.default())
	end)

	it("passes a valid current record through intact", function()
		local data, status = PlayerDataSchema.migrate(validRecord())
		expect(status).toBe("ok")
		expect(data).toEqual(validRecord())
	end)

	-- Everyone who played before levels existed has a version-1 profile
	-- sitting in the DataStore. It must load, keep its coins, and simply
	-- start at level 1 rather than being read as corrupt.
	it("carries a pre-levels profile forward", function()
		local old = validRecord()
		old.version = 1
		old.xp = nil
		old.skills = nil

		local data, status = PlayerDataSchema.migrate(old)
		expect(status).toBe("ok")
		expect(data.version).toBe(CURRENT)
		expect(data.coins).toBe(320)
		expect(data.xp).toBe(0)
		expect(data.skills).toEqual({})
	end)

	-- A server running older code must never overwrite a profile a newer
	-- server wrote — that would silently delete the newer progress.
	it("refuses a record from a newer game version", function()
		local record = validRecord()
		record.version = CURRENT + 1
		local _, status = PlayerDataSchema.migrate(record)
		expect(status).toBe("future_version")
	end)

	it("reports a stored value that isn't a record as corrupt", function()
		for _, raw in { "hello", 42, true } do
			local _, status = PlayerDataSchema.migrate(raw)
			expect(status).toBe("corrupt")
		end
	end)

	it("reports a record without a usable version as corrupt", function()
		for _, version in { "1", 0, -1, 1.5, 0 / 0 } do
			local record = validRecord()
			record.version = version
			local _, status = PlayerDataSchema.migrate(record)
			expect(status).toBe("corrupt")
		end

		local unversioned = validRecord()
		unversioned.version = nil
		local _, status = PlayerDataSchema.migrate(unversioned)
		expect(status).toBe("corrupt")
	end)
end)

describe("PlayerDataSchema.sanitize", function()
	it("clamps and floors counts", function()
		local record = validRecord()
		record.coins = -50
		expect(PlayerDataSchema.sanitize(record).coins).toBe(0)

		record.coins = 12.9
		expect(PlayerDataSchema.sanitize(record).coins).toBe(12)
	end)

	-- NaN and infinity can't be stored in a DataStore, and NaN compares false
	-- with everything, which would quietly break every "can afford" check.
	it("turns non-finite coins into zero", function()
		for _, bad in { 0 / 0, math.huge, -math.huge, "100" } do
			local record = validRecord()
			record.coins = bad
			expect(PlayerDataSchema.sanitize(record).coins).toBe(0)
		end
	end)

	it("drops malformed count entries but keeps well-formed ones", function()
		local record = validRecord()
		record.crystals = { Tank = 3, Healer = "lots", [5] = 2, Assassin = 0 / 0 }
		expect(PlayerDataSchema.sanitize(record).crystals).toEqual({ Tank = 3 })
	end)

	it("clamps upgrade levels to the current cap", function()
		local record = validRecord()
		record.upgradeLevels = { Staff = EconomyDefs.MAX_UPGRADE_LEVEL + 4, Daggers = -2 }
		expect(PlayerDataSchema.sanitize(record).upgradeLevels).toEqual({
			Staff = EconomyDefs.MAX_UPGRADE_LEVEL,
			Daggers = 0,
		})
	end)

	-- Rollback safety: an id this server doesn't know may be newer content.
	it("keeps ids it doesn't recognise", function()
		local record = validRecord()
		record.crystals = { Necromancer = 4 }
		record.upgradeLevels = { Greatsword = 2 }
		record.equipped = { weapon = "Greatsword" }
		record.inventory = { { itemId = "DragonScale", rarity = "legendary", upgradeLevel = 0 } }

		local data = PlayerDataSchema.sanitize(record)
		expect(data.crystals.Necromancer).toBe(4)
		expect(data.upgradeLevels.Greatsword).toBe(2)
		expect(data.equipped.weapon).toBe("Greatsword")
		expect(data.inventory[1].itemId).toBe("DragonScale")
	end)

	it("clears an equipped weapon that isn't a string", function()
		local record = validRecord()
		record.equipped = { weapon = 7 }
		expect(PlayerDataSchema.sanitize(record).equipped.weapon).toBeNil()

		record.equipped = "Staff"
		expect(PlayerDataSchema.sanitize(record).equipped.weapon).toBeNil()
	end)

	it("drops malformed inventory items and keeps the rest in order", function()
		local record = validRecord()
		record.inventory = {
			{ itemId = "PracticeToken", rarity = "common", upgradeLevel = 0 },
			"not an item",
			{ itemId = "", rarity = "common" },
			{ itemId = "NoRarity" },
			{ itemId = "BadClass", rarity = "common", classTag = 3 },
			{ itemId = "BoneHiltShard", rarity = "uncommon", upgradeLevel = -1, classTag = "Tank" },
		}

		expect(PlayerDataSchema.sanitize(record).inventory).toEqual({
			{ itemId = "PracticeToken", rarity = "common", upgradeLevel = 0 },
			{ itemId = "BoneHiltShard", rarity = "uncommon", upgradeLevel = 0, classTag = "Tank" },
		})
	end)

	it("caps the inventory length", function()
		local record = validRecord()
		record.inventory = {}
		for _ = 1, PlayerDataSchema.MAX_INVENTORY + 25 do
			table.insert(record.inventory, { itemId = "PracticeToken", rarity = "common", upgradeLevel = 0 })
		end

		expect(#PlayerDataSchema.sanitize(record).inventory).toBe(PlayerDataSchema.MAX_INVENTORY)
	end)

	it("rebuilds every field from a non-table", function()
		expect(PlayerDataSchema.sanitize("garbage")).toEqual(PlayerDataSchema.default())
	end)

	it("is idempotent", function()
		local messy = validRecord()
		messy.coins = 44.7
		messy.crystals = { Tank = "x", Healer = 2 }
		messy.inventory = { "junk", { itemId = "PracticeToken", rarity = "common" } }

		local once = PlayerDataSchema.sanitize(messy)
		expect(PlayerDataSchema.sanitize(once)).toEqual(once)
	end)

	-- The result is saved asynchronously; it must not share tables with live
	-- service state that could change before the write happens.
	it("never aliases the input", function()
		local record = validRecord()
		local data = PlayerDataSchema.sanitize(record)

		record.crystals.Tank = 999
		record.inventory[1].itemId = "Changed"

		expect(data.crystals.Tank).toBe(2)
		expect(data.inventory[1].itemId).toBe("PracticeToken")
	end)
end)

describe("PlayerDataSchema session locks", function()
	local STALE = 180
	local NOW = 1_000_000

	it("lets anyone claim an unlocked profile", function()
		expect(PlayerDataSchema.canClaim(nil, "server-a", NOW, STALE)).toBe(true)
	end)

	it("lets the owner keep its own lock", function()
		local lock = { jobId = "server-a", heartbeat = NOW - 5 }
		expect(PlayerDataSchema.canClaim(lock, "server-a", NOW, STALE)).toBe(true)
	end)

	-- The case locks exist for: two servers must never write one profile.
	it("refuses a profile another server holds fresh", function()
		local lock = { jobId = "server-a", heartbeat = NOW - 5 }
		expect(PlayerDataSchema.canClaim(lock, "server-b", NOW, STALE)).toBe(false)
	end)

	it("still refuses exactly at the stale threshold", function()
		local lock = { jobId = "server-a", heartbeat = NOW - STALE }
		expect(PlayerDataSchema.canClaim(lock, "server-b", NOW, STALE)).toBe(false)
	end)

	-- A crashed server never releases its lock.
	it("lets a profile be taken over once its lock goes stale", function()
		local lock = { jobId = "server-a", heartbeat = NOW - STALE - 1 }
		expect(PlayerDataSchema.canClaim(lock, "server-b", NOW, STALE)).toBe(true)
	end)

	it("treats an unreadable lock as no lock", function()
		expect(PlayerDataSchema.canClaim({ jobId = "server-a" }, "server-b", NOW, STALE)).toBe(true)
		expect(PlayerDataSchema.canClaim("locked", "server-b", NOW, STALE)).toBe(true)
	end)

	it("knows who owns a profile", function()
		local lock = { jobId = "server-a", heartbeat = NOW }
		expect(PlayerDataSchema.isOwnedBy(lock, "server-a")).toBe(true)
		expect(PlayerDataSchema.isOwnedBy(lock, "server-b")).toBe(false)
		expect(PlayerDataSchema.isOwnedBy(nil, "server-a")).toBe(false)
	end)
end)
