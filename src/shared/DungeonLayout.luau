--!strict
-- Generates a random dungeon layout: which rooms exist, where they sit, what
-- each is for, how big it is, what's in it, and how corridors join them.
-- Pure — no Roblox API. The server builds what this describes
-- (DungeonGenerator).
--
-- Seeded: the same seed always gives the same dungeon, which is what makes
-- the rules testable across hundreds of layouts, and a reported bad layout
-- reproducible.
--
-- How it's built:
--   1. The Start room sits at the origin with one door, to the north (+Z).
--      Nothing is ever placed south of it, which keeps that side free for the
--      duel arena.
--   2. A main path winds away from it, one room at a time, each placed off a
--      random free side of the last. Its purposes are fixed in shape: fights,
--      with one Elite and one Ambush among them, then a Shrine, then the Boss.
--   3. Treasure branches sprout off main-path fights as dead ends.
--   4. A room is only placed where it and its corridor overlap nothing
--      already there. A main path that paints itself into a corner throws the
--      whole attempt away and starts again; a branch that can't fit is simply
--      skipped.
--
-- Coordinates are room centres in studs on the floor plane: x east, z north.

local DungeonDefs = require(script.Parent.DungeonDefs)

local DungeonLayout = {}

export type Side = "North" | "South" | "East" | "West"

export type RoomNode = {
	id: number,
	purpose: DungeonDefs.RoomPurpose,
	sizeClass: DungeonDefs.SizeClass,
	-- Width in studs; rooms are square.
	size: number,
	variant: DungeonDefs.RoomVariant,
	x: number,
	z: number,
	-- Steps along the main path from the Start. A branch room shares the
	-- depth of the main-path room it hangs off.
	depth: number,
	mainPath: boolean,
	-- The room this one was reached from; nil only for the Start.
	parentId: number?,
	-- The side the way back toward the Start is on; nil only for the Start.
	entrance: Side?,
	-- Side -> the room through that door.
	doors: { [Side]: number },
	-- EnemyDefs ids placed in the room when it's built.
	enemies: { string },
	-- Ambush rooms only: EnemyDefs ids per wave, arriving once it springs.
	waves: { { string } },
	hasChest: boolean,
}

export type Corridor = {
	fromId: number,
	toId: number,
	-- Centre of the corridor floor.
	x: number,
	z: number,
	length: number,
	-- Runs east-west when true, north-south when false.
	alongX: boolean,
}

export type Layout = {
	seed: number,
	rooms: { RoomNode },
	corridors: { Corridor },
	startId: number,
	shrineId: number,
	bossId: number,
}

type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }

DungeonLayout.SIDES = { "North", "East", "South", "West" } :: { Side }

DungeonLayout.DIRECTION = {
	North = { x = 0, z = 1 },
	South = { x = 0, z = -1 },
	East = { x = 1, z = 0 },
	West = { x = -1, z = 0 },
} :: { [Side]: { x: number, z: number } }

DungeonLayout.OPPOSITE = {
	North = "South",
	South = "North",
	East = "West",
	West = "East",
} :: { [Side]: Side }

-- Rooms and corridors keep at least this much clear space from anything that
-- isn't joined to them, so walls never touch.
local CLEARANCE = 3
local MAX_ATTEMPTS = 200

--[[ Random numbers ]]

-- Park-Miller "minimal standard" generator. Chosen because every
-- intermediate product stays below 2^53, so it's exact in Luau's doubles and
-- gives identical sequences everywhere the code runs.
export type Rng = { state: number }

local MODULUS = 2147483647
local MULTIPLIER = 48271

-- A generator seeded from one number. Its own rather than Roblox's
-- `Random`, so this module stays pure and a seed produces the same dungeon
-- on the server, in a test and under Lune.
function DungeonLayout.newRng(seed: number): Rng
	local state = math.floor(math.abs(seed)) % (MODULUS - 1) + 1
	return { state = state }
end

-- A number in (0, 1).
function DungeonLayout.nextNumber(rng: Rng): number
	rng.state = (rng.state * MULTIPLIER) % MODULUS
	return rng.state / MODULUS
end

-- An integer in [min, max].
function DungeonLayout.nextInt(rng: Rng, min: number, max: number): number
	if max <= min then
		return min
	end
	return math.min(min + math.floor(DungeonLayout.nextNumber(rng) * (max - min + 1)), max)
end

-- True with the given probability. Advances the generator either way, so
-- adding a coin flip shifts every later roll — which is why tuning a
-- probability changes the whole layout for a seed, not just that decision.
local function chance(rng: Rng, probability: number): boolean
	return DungeonLayout.nextNumber(rng) < probability
end

-- One entry of a list, uniformly.
local function pick<T>(rng: Rng, list: { T }): T
	return list[DungeonLayout.nextInt(rng, 1, #list)]
end

-- A shuffled copy, Fisher-Yates. A copy rather than in place: the lists
-- passed in are shared definition tables that must not be reordered.
local function shuffled<T>(rng: Rng, list: { T }): { T }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = DungeonLayout.nextInt(rng, 1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

--[[ Geometry ]]

local function roomRect(x: number, z: number, size: number, grow: number): Rect
	local half = size / 2 + grow
	return { minX = x - half, maxX = x + half, minZ = z - half, maxZ = z + half }
end

-- The corridor between two joined rooms, as its node and its floor rect.
local function corridorBetween(parent: RoomNode, side: Side, childId: number): Corridor
	local dir = DungeonLayout.DIRECTION[side]
	local startOffset = parent.size / 2
	local length = DungeonDefs.CORRIDOR_LENGTH
	local centreOffset = startOffset + length / 2

	return {
		fromId = parent.id,
		toId = childId,
		x = parent.x + dir.x * centreOffset,
		z = parent.z + dir.z * centreOffset,
		length = length,
		alongX = dir.x ~= 0,
	}
end

-- The footprint a corridor occupies, including its walls, grown by `grow`
-- studs on every side. Used for overlap tests, where `grow` is the gap to
-- insist on between two pieces of dungeon.
function DungeonLayout.corridorRect(corridor: Corridor, grow: number): Rect
	-- Walls included: the corridor is its floor plus a wall each side.
	local halfWidth = DungeonDefs.CORRIDOR_WIDTH / 2 + 1 + grow
	local halfLength = corridor.length / 2
	if corridor.alongX then
		return {
			minX = corridor.x - halfLength,
			maxX = corridor.x + halfLength,
			minZ = corridor.z - halfWidth,
			maxZ = corridor.z + halfWidth,
		}
	end
	return {
		minX = corridor.x - halfWidth,
		maxX = corridor.x + halfWidth,
		minZ = corridor.z - halfLength,
		maxZ = corridor.z + halfLength,
	}
end

-- The footprint a room occupies, grown by `grow` studs on every side.
function DungeonLayout.roomRect(room: RoomNode, grow: number): Rect
	return roomRect(room.x, room.z, room.size, grow)
end

-- Strict overlap: rects that only touch along an edge don't count.
function DungeonLayout.overlaps(a: Rect, b: Rect): boolean
	return a.minX < b.maxX and b.minX < a.maxX and a.minZ < b.maxZ and b.minZ < a.maxZ
end

--[[ Generation ]]

type Draft = {
	rng: Rng,
	rooms: { RoomNode },
	corridors: { Corridor },
	startRect: Rect,
}

-- A size class for a room of this purpose, and the studs that class means.
-- Purposes list which sizes they allow, so a Boss room is never small.
local function sizeFor(rng: Rng, purpose: DungeonDefs.RoomPurpose): (DungeonDefs.SizeClass, number)
	local def = DungeonDefs.PURPOSES[purpose]
	local sizeClass = pick(rng, def.sizes)
	return sizeClass, DungeonDefs.SIZES[sizeClass]
end

-- Whether a new room (and the corridor to it) fits without overlapping
-- anything else, and stays north of the Start.
local function fits(draft: Draft, parent: RoomNode, x: number, z: number, size: number, corridor: Corridor): boolean
	local rect = roomRect(x, z, size, CLEARANCE)
	local tight = roomRect(x, z, size, 0)

	-- Wholly north of the Start room and the space its own door needs.
	if tight.minZ < draft.startRect.maxZ + DungeonDefs.CORRIDOR_LENGTH - 1e-6 then
		return false
	end

	local corridorRect = DungeonLayout.corridorRect(corridor, 0)

	for _, other in draft.rooms do
		if DungeonLayout.overlaps(rect, DungeonLayout.roomRect(other, 0)) then
			return false
		end
		-- The corridor may meet its own parent's wall, but nothing else.
		if other.id ~= parent.id and DungeonLayout.overlaps(corridorRect, DungeonLayout.roomRect(other, CLEARANCE)) then
			return false
		end
	end

	for _, other in draft.corridors do
		local otherRect = DungeonLayout.corridorRect(other, CLEARANCE)
		if DungeonLayout.overlaps(rect, otherRect) or DungeonLayout.overlaps(corridorRect, otherRect) then
			return false
		end
	end

	return true
end

-- Places a room of `purpose` off a free side of `parent`, trying `sides` (all
-- four by default) in a random order. Returns the new room, or nil if no side
-- has room for it.
local function attach(
	draft: Draft,
	parent: RoomNode,
	purpose: DungeonDefs.RoomPurpose,
	mainPath: boolean,
	depth: number,
	sides: { Side }?
): RoomNode?
	local rng = draft.rng
	local sizeClass, size = sizeFor(rng, purpose)
	local def = DungeonDefs.PURPOSES[purpose]

	for _, side in shuffled(rng, sides or DungeonLayout.SIDES) do
		if parent.doors[side] then
			continue
		end

		local dir = DungeonLayout.DIRECTION[side]
		local distance = parent.size / 2 + DungeonDefs.CORRIDOR_LENGTH + size / 2
		local x = parent.x + dir.x * distance
		local z = parent.z + dir.z * distance
		local id = #draft.rooms + 1
		local corridor = corridorBetween(parent, side, id)

		if not fits(draft, parent, x, z, size, corridor) then
			continue
		end

		local room: RoomNode = {
			id = id,
			purpose = purpose,
			sizeClass = sizeClass,
			size = size,
			variant = pick(rng, def.variants),
			x = x,
			z = z,
			depth = depth,
			mainPath = mainPath,
			parentId = parent.id,
			entrance = DungeonLayout.OPPOSITE[side],
			doors = { [DungeonLayout.OPPOSITE[side]] = parent.id },
			enemies = {},
			waves = {},
			hasChest = def.hasChest,
		}

		parent.doors[side] = id
		table.insert(draft.rooms, room)
		table.insert(draft.corridors, corridor)
		return room
	end

	return nil
end

-- The purposes of the rooms between the Start and the Shrine: fights, with
-- one Ambush (never first, so the dungeon opens with an ordinary fight) and
-- one Elite (in the back half, so it comes after a warm-up).
local function middlePurposes(rng: Rng, count: number): { DungeonDefs.RoomPurpose }
	local purposes: { DungeonDefs.RoomPurpose } = table.create(count, "Combat")

	local eliteFrom = math.max(math.floor(count / 2) + 1, 2)
	local eliteAt = DungeonLayout.nextInt(rng, eliteFrom, count)
	purposes[eliteAt] = "Elite"

	local ambushSlots = {}
	for i = 2, count do
		if i ~= eliteAt then
			table.insert(ambushSlots, i)
		end
	end
	if #ambushSlots > 0 then
		purposes[pick(rng, ambushSlots)] = "Ambush"
	end

	return purposes
end

-- Which enemy pool a room at this depth draws from. Rooms past
-- LATE_DEPTH pull from the harder list.
local function poolFor(depth: number): { string }
	return if depth >= DungeonDefs.LATE_DEPTH then DungeonDefs.POOLS.late else DungeonDefs.POOLS.early
end

-- Fills a room's enemy list. The Boss room gets exactly the boss and
-- nothing else; everything else draws a count and rolls that many from its
-- depth's pool.
local function populate(rng: Rng, room: RoomNode)
	if room.purpose == "Boss" then
		room.enemies = { DungeonDefs.BOSS }
		return
	end

	if room.purpose == "Treasure" then
		if chance(rng, DungeonDefs.TREASURE_GUARD_CHANCE) then
			room.enemies = { pick(rng, poolFor(room.depth)) }
		end
		return
	end

	if room.purpose == "Ambush" then
		local waves = {}
		for _, count in DungeonDefs.AMBUSH.waves do
			local wave = {}
			for _ = 1, count do
				table.insert(wave, pick(rng, poolFor(room.depth)))
			end
			table.insert(waves, wave)
		end
		room.waves = waves
		return
	end

	local range = DungeonDefs.PURPOSES[room.purpose].enemyCount[room.sizeClass]
	if not range then
		return
	end

	local count = DungeonLayout.nextInt(rng, range.min, range.max)
	local enemies = {}
	for i = 1, count do
		if room.purpose == "Elite" and i == 1 then
			table.insert(enemies, pick(rng, DungeonDefs.POOLS.elite))
		elseif room.purpose == "Elite" then
			table.insert(enemies, pick(rng, DungeonDefs.POOLS.late))
		else
			table.insert(enemies, pick(rng, poolFor(room.depth)))
		end
	end
	room.enemies = enemies
end

-- One attempt at a whole layout, or nil if it painted itself into a
-- corner.
--
-- Grows rooms outward from the Start, refusing any that would overlap
-- something already placed. Returning nil is normal and expected — see
-- `generate`, which simply tries again with the generator where this
-- attempt left it.
local function tryGenerate(rng: Rng): Layout?
	-- The Start is always at the origin, with its only door to the north.
	local startClass, startSize = sizeFor(rng, "Start")
	local start: RoomNode = {
		id = 1,
		purpose = "Start",
		sizeClass = startClass,
		size = startSize,
		variant = "Empty",
		x = 0,
		z = 0,
		depth = 0,
		mainPath = true,
		parentId = nil,
		entrance = nil,
		doors = {},
		enemies = {},
		waves = {},
		hasChest = false,
	}

	local draft: Draft = {
		rng = rng,
		rooms = { start },
		corridors = {},
		startRect = roomRect(0, 0, startSize, 0),
	}

	local pathLength = DungeonLayout.nextInt(rng, DungeonDefs.MAIN_PATH_LENGTH.min, DungeonDefs.MAIN_PATH_LENGTH.max)
	local purposes = middlePurposes(rng, pathLength - 2)
	table.insert(purposes, "Shrine")
	table.insert(purposes, "Boss")

	local previous = start
	local mainPath: { RoomNode } = {}
	for index, purpose in purposes do
		-- The first room is forced north, out of the Start's only door.
		local sides: { Side }? = if index == 1 then { "North" } else nil
		local room = attach(draft, previous, purpose, true, index, sides)

		if not room then
			return nil
		end
		table.insert(mainPath, room)
		previous = room
	end

	-- Treasure branches, off fights and traps only: never off the Start, the
	-- Shrine or the Boss, so the way into the boss stays a single door.
	local anchors = {}
	for _, room in mainPath do
		if room.purpose == "Combat" or room.purpose == "Elite" or room.purpose == "Ambush" then
			table.insert(anchors, room)
		end
	end

	local branchCount = DungeonLayout.nextInt(rng, DungeonDefs.BRANCHES.min, DungeonDefs.BRANCHES.max)
	local treasures = 0
	for _ = 1, branchCount do
		if #anchors == 0 then
			break
		end

		local anchor = pick(rng, anchors)
		local attachTo = anchor

		if chance(rng, DungeonDefs.LONG_BRANCH_CHANCE) then
			local mid = attach(draft, anchor, "Combat", false, anchor.depth)
			if mid then
				attachTo = mid
			end
		end

		if attach(draft, attachTo, "Treasure", false, anchor.depth) then
			treasures += 1
		end
	end

	if treasures < DungeonDefs.MIN_TREASURE_ROOMS then
		return nil
	end

	for _, room in draft.rooms do
		populate(rng, room)
	end

	return {
		seed = 0,
		rooms = draft.rooms,
		corridors = draft.corridors,
		startId = start.id,
		shrineId = mainPath[#mainPath - 1].id,
		bossId = mainPath[#mainPath].id,
	}
end

-- The layout for a seed. Retries `tryGenerate` up to MAX_ATTEMPTS, since
-- a failed attempt is a normal outcome rather than an error.
--
-- Deterministic: the same seed always gives the same dungeon, which is
-- what lets a bad layout be reproduced from the seed alone.
function DungeonLayout.generate(seed: number): Layout
	local rng = DungeonLayout.newRng(seed)
	for _ = 1, MAX_ATTEMPTS do
		local layout = tryGenerate(rng)
		if layout then
			layout.seed = seed
			return layout
		end
	end
	error(`DungeonLayout couldn't fit a dungeon for seed {seed} in {MAX_ATTEMPTS} attempts`)
end

-- A room by id. Asserts rather than returning nil: every id in a layout
-- comes from that same layout, so a miss is a bug in the caller.
function DungeonLayout.getRoom(layout: Layout, id: number): RoomNode
	local room = layout.rooms[id]
	assert(room and room.id == id, `No room {id} in layout`)
	return room
end

return DungeonLayout
