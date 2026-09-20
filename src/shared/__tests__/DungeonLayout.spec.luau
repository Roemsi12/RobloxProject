--!strict
-- The dungeon generator's promises, checked across hundreds of seeds: every
-- dungeon has exactly one way to the boss, nothing overlaps, every room can
-- be reached, and each room holds what its purpose says.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DungeonDefs = require(Shared.DungeonDefs)
local DungeonLayout = require(Shared.DungeonLayout)
local EnemyDefs = require(Shared.EnemyDefs)
local LootTables = require(Shared.LootTables)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local SEEDS = 300

-- expect() on a { label, value } pair, so a failure names what failed
-- rather than just saying false was not true.
local function check(label: string, value: boolean)
	expect({ label, value }).toEqual({ label, true })
end

local layouts: { DungeonLayout.Layout } = {}
for seed = 1, SEEDS do
	layouts[seed] = DungeonLayout.generate(seed * 7919)
end

-- Runs a check against every pre-generated layout, labelled by seed — so
-- a failure names the seed that reproduces it.
local function eachLayout(callback: (label: string, layout: DungeonLayout.Layout) -> ())
	for index, layout in layouts do
		callback(`seed #{index}`, layout)
	end
end

-- How many of a layout's rooms satisfy a predicate.
local function countWhere(layout: DungeonLayout.Layout, predicate: (DungeonLayout.RoomNode) -> boolean): number
	local count = 0
	for _, room in layout.rooms do
		if predicate(room) then
			count += 1
		end
	end
	return count
end

-- How many rooms have a given purpose, optionally counting only those on
-- the main path.
local function countPurpose(layout: DungeonLayout.Layout, purpose: string, mainPathOnly: boolean): number
	return countWhere(layout, function(room)
		return room.purpose == purpose and (room.mainPath or not mainPathOnly)
	end)
end

-- How many doors a room has.
local function doorCount(room: DungeonLayout.RoomNode): number
	local count = 0
	for _ in room.doors do
		count += 1
	end
	return count
end

-- A compact fingerprint, to compare two layouts for equality.
local function fingerprint(layout: DungeonLayout.Layout): string
	local parts = {}
	for _, room in layout.rooms do
		table.insert(parts, `{room.id}:{room.purpose}:{room.size}:{room.x},{room.z}:{table.concat(room.enemies, "+")}`)
	end
	return table.concat(parts, "|")
end

describe("DungeonLayout random numbers", function()
	it("repeats exactly for the same seed", function()
		local a = DungeonLayout.newRng(12345)
		local b = DungeonLayout.newRng(12345)
		for _ = 1, 50 do
			expect(DungeonLayout.nextNumber(a)).toBe(DungeonLayout.nextNumber(b))
		end
	end)

	it("keeps integers inside their bounds", function()
		local rng = DungeonLayout.newRng(99)
		for _ = 1, 500 do
			local value = DungeonLayout.nextInt(rng, 3, 7)
			check(`{value} in 3..7`, value >= 3 and value <= 7 and value == math.floor(value))
		end
	end)
end)

describe("DungeonLayout generation", function()
	it("gives the same dungeon for the same seed, and different ones for different seeds", function()
		expect(fingerprint(DungeonLayout.generate(4242))).toBe(fingerprint(DungeonLayout.generate(4242)))

		local distinct = {}
		local count = 0
		for _, layout in layouts do
			local key = fingerprint(layout)
			if not distinct[key] then
				distinct[key] = true
				count += 1
			end
		end
		check(`{count} distinct layouts from {SEEDS} seeds`, count > SEEDS * 0.9)
	end)

	it("has exactly one Start, Shrine, Boss, Elite and Ambush, the Ambush on the main path", function()
		eachLayout(function(label, layout)
			for _, purpose in { "Start", "Shrine", "Boss", "Elite" } do
				expect({ label, purpose, countPurpose(layout, purpose, false) }).toEqual({ label, purpose, 1 })
			end
			expect({ label, "Ambush", countPurpose(layout, "Ambush", true) }).toEqual({ label, "Ambush", 1 })
			expect({ label, "Ambush", countPurpose(layout, "Ambush", false) }).toEqual({ label, "Ambush", 1 })
		end)
	end)

	it("keeps the main path within its length", function()
		eachLayout(function(label, layout)
			local length = countWhere(layout, function(r)
				return r.mainPath and r.purpose ~= "Start"
			end)
			check(`{label} main path {length}`, length >= DungeonDefs.MAIN_PATH_LENGTH.min and length <= DungeonDefs.MAIN_PATH_LENGTH.max)
		end)
	end)

	it("reaches the boss only through the shrine, by a single door", function()
		eachLayout(function(label, layout)
			local boss = DungeonLayout.getRoom(layout, layout.bossId)
			local shrine = DungeonLayout.getRoom(layout, layout.shrineId)
			expect({ label, doorCount(boss) }).toEqual({ label, 1 })
			expect({ label, boss.parentId }).toEqual({ label, shrine.id })
			expect({ label, doorCount(shrine) }).toEqual({ label, 2 })
		end)
	end)

	it("gives the Start a single door, facing north", function()
		eachLayout(function(label, layout)
			local start = DungeonLayout.getRoom(layout, layout.startId)
			expect({ label, doorCount(start) }).toEqual({ label, 1 })
			check(`{label} north door`, start.doors.North ~= nil)
			expect({ label, start.x, start.z }).toEqual({ label, 0, 0 })
		end)
	end)

	it("keeps every other room north of the Start, clear of the arena side", function()
		eachLayout(function(label, layout)
			local start = DungeonLayout.getRoom(layout, layout.startId)
			for _, room in layout.rooms do
				if room.id ~= start.id then
					check(`{label} room {room.id} north`, room.z - room.size / 2 >= start.size / 2 + DungeonDefs.CORRIDOR_LENGTH - 1e-6)
				end
			end
		end)
	end)

	it("never overlaps two rooms, or a corridor with a room it doesn't join", function()
		eachLayout(function(label, layout)
			for i, a in layout.rooms do
				for j = i + 1, #layout.rooms do
					local b = layout.rooms[j]
					check(
						`{label} rooms {a.id}/{b.id}`,
						not DungeonLayout.overlaps(DungeonLayout.roomRect(a, 0), DungeonLayout.roomRect(b, 0))
					)
				end
			end

			for _, corridor in layout.corridors do
				local rect = DungeonLayout.corridorRect(corridor, 0)
				for _, room in layout.rooms do
					if room.id ~= corridor.fromId and room.id ~= corridor.toId then
						check(
							`{label} corridor {corridor.fromId}-{corridor.toId} vs room {room.id}`,
							not DungeonLayout.overlaps(rect, DungeonLayout.roomRect(room, 0))
						)
					end
				end
			end
		end)
	end)

	it("joins rooms with matching doors on both sides, one corridor each", function()
		eachLayout(function(label, layout)
			local doorLinks = 0
			for _, room in layout.rooms do
				for side, otherId in room.doors do
					local other = DungeonLayout.getRoom(layout, otherId)
					expect({ label, other.doors[DungeonLayout.OPPOSITE[side]] }).toEqual({ label, room.id })

					-- The neighbour sits exactly one corridor away on that side.
					local dir = DungeonLayout.DIRECTION[side]
					local gap = room.size / 2 + DungeonDefs.CORRIDOR_LENGTH + other.size / 2
					expect({ label, other.x - room.x, other.z - room.z }).toEqual({ label, dir.x * gap, dir.z * gap })
					doorLinks += 1
				end
			end
			expect({ label, #layout.corridors * 2 }).toEqual({ label, doorLinks })
			expect({ label, #layout.corridors }).toEqual({ label, #layout.rooms - 1 })
		end)
	end)

	it("makes every room reachable from the Start", function()
		eachLayout(function(label, layout)
			local seen = { [layout.startId] = true }
			local queue = { layout.startId }
			while #queue > 0 do
				local room = DungeonLayout.getRoom(layout, table.remove(queue, 1) :: number)
				for _, otherId in room.doors do
					if not seen[otherId] then
						seen[otherId] = true
						table.insert(queue, otherId)
					end
				end
			end
			for _, room in layout.rooms do
				check(`{label} room {room.id} reachable`, seen[room.id] == true)
			end
		end)
	end)

	it("puts treasure in dead ends off the main path", function()
		eachLayout(function(label, layout)
			local treasures = 0
			for _, room in layout.rooms do
				if room.purpose == "Treasure" then
					treasures += 1
					check(`{label} treasure {room.id} off main path`, not room.mainPath)
					expect({ label, doorCount(room) }).toEqual({ label, 1 })
				end
			end
			check(`{label} has treasure`, treasures >= DungeonDefs.MIN_TREASURE_ROOMS)
		end)
	end)

	it("sizes and dresses each room from its purpose", function()
		eachLayout(function(label, layout)
			for _, room in layout.rooms do
				local def = DungeonDefs.PURPOSES[room.purpose]
				check(`{label} room {room.id} size class`, table.find(def.sizes, room.sizeClass) ~= nil)
				expect({ label, room.size }).toEqual({ label, DungeonDefs.SIZES[room.sizeClass] })
				check(`{label} room {room.id} variant`, table.find(def.variants, room.variant) ~= nil)
				expect({ label, room.hasChest }).toEqual({ label, def.hasChest })
			end
		end)
	end)

	it("places enemies only where the purpose allows, and the boss only in the boss room", function()
		eachLayout(function(label, layout)
			for _, room in layout.rooms do
				local tag = `{label} room {room.id} ({room.purpose})`
				for _, enemyId in room.enemies do
					check(`{tag} knows {enemyId}`, EnemyDefs[enemyId] ~= nil)
					check(`{tag} boss placement`, (enemyId == DungeonDefs.BOSS) == (room.purpose == "Boss"))
				end

				if room.purpose == "Boss" then
					expect({ tag, room.enemies }).toEqual({ tag, { DungeonDefs.BOSS } })
				elseif room.purpose == "Start" or room.purpose == "Shrine" then
					expect({ tag, #room.enemies }).toEqual({ tag, 0 })
				elseif room.purpose == "Ambush" then
					-- Nobody waits in the room: they all come in the waves.
					expect({ tag, #room.enemies }).toEqual({ tag, 0 })
					expect({ tag, #room.waves }).toEqual({ tag, #DungeonDefs.AMBUSH.waves })
					for index, wave in room.waves do
						expect({ tag, index, #wave }).toEqual({ tag, index, DungeonDefs.AMBUSH.waves[index] })
						for _, enemyId in wave do
							check(`{tag} wave {index} knows {enemyId}`, EnemyDefs[enemyId] ~= nil and enemyId ~= DungeonDefs.BOSS)
						end
					end
				elseif room.purpose == "Treasure" then
					check(`{tag} at most one guard`, #room.enemies <= 1)
				else
					local range = DungeonDefs.PURPOSES[room.purpose].enemyCount[room.sizeClass]
					check(`{tag} count`, range ~= nil and #room.enemies >= range.min and #room.enemies <= range.max)
				end

				if room.purpose == "Elite" then
					check(`{tag} leads with an elite`, table.find(DungeonDefs.POOLS.elite, room.enemies[1]) ~= nil)
				end

				if room.purpose ~= "Ambush" then
					expect({ tag, #room.waves }).toEqual({ tag, 0 })
				end
			end
		end)
	end)
end)

describe("DungeonDefs", function()
	it("only pools enemies that exist, never the boss", function()
		for poolName, pool in DungeonDefs.POOLS do
			for _, enemyId in pool do
				check(`{poolName}/{enemyId} exists`, EnemyDefs[enemyId] ~= nil)
				check(`{poolName}/{enemyId} not the boss`, enemyId ~= DungeonDefs.BOSS)
			end
		end
		check("boss exists", EnemyDefs[DungeonDefs.BOSS] ~= nil)
		check("boss has loot", LootTables[DungeonDefs.BOSS] ~= nil)
	end)

	it("defines every purpose's sizes, and enemy counts only for sizes it uses", function()
		for purpose, def in DungeonDefs.PURPOSES do
			check(`{purpose} has sizes`, #def.sizes > 0)
			check(`{purpose} has variants`, #def.variants > 0)
			for _, sizeClass in def.sizes do
				check(`{purpose} size {sizeClass}`, DungeonDefs.SIZES[sizeClass] ~= nil)
			end
			for sizeClass, range in def.enemyCount do
				check(`{purpose} counts {sizeClass}`, table.find(def.sizes, sizeClass) ~= nil)
				check(`{purpose} {sizeClass} range`, range.min >= 0 and range.min <= range.max)
			end
		end
	end)

	-- Enemies are leashed to their room. One that wants to stand further off
	-- than the smallest room it can be placed in allows would pin itself
	-- against a wall.
	it("fits every enemy's preferred range inside the smallest room it can appear in", function()
		local smallestForEnemy: { [string]: number } = {}
		-- Records the smallest room this enemy was ever placed in, so the test
		-- can check nothing big is ever put somewhere it would not fit.
		local function note(enemyId: string, size: number)
			smallestForEnemy[enemyId] = math.min(smallestForEnemy[enemyId] or math.huge, size)
		end

		local smallestRoom = math.huge
		for _, sizeClass in DungeonDefs.PURPOSES.Combat.sizes do
			smallestRoom = math.min(smallestRoom, DungeonDefs.SIZES[sizeClass])
		end
		for _, sizeClass in DungeonDefs.PURPOSES.Treasure.sizes do
			smallestRoom = math.min(smallestRoom, DungeonDefs.SIZES[sizeClass])
		end
		for _, pool in DungeonDefs.POOLS do
			for _, enemyId in pool do
				note(enemyId, smallestRoom)
			end
		end
		note(DungeonDefs.BOSS, DungeonDefs.SIZES[DungeonDefs.PURPOSES.Boss.sizes[1]])

		for enemyId, size in smallestForEnemy do
			local halfDiagonal = size / 2 * math.sqrt(2)
			check(`{enemyId} fits a {size}-stud room`, EnemyDefs[enemyId].preferredRange <= halfDiagonal)
		end
	end)

	it("has a real loot row for unguarded treasure", function()
		check("treasure item id", #DungeonDefs.TREASURE_LOOT.itemId > 0)
		check("treasure rarity", #DungeonDefs.TREASURE_LOOT.rarity > 0)
	end)
end)
