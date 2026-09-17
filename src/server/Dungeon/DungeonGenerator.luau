--!strict
-- Builds a DungeonLayout into the world: rooms, corridors, enemies, chests,
-- the shrine and the ambush. Everything it makes goes in one folder, so a
-- finished dungeon can be torn down whole (DungeonService).
--
-- The layout decides everything random; this module only places things. The
-- one exception is cosmetic (rubble, ruin angles), which doesn't need to be
-- reproducible.
--
-- The Start room is built along with everything else, and torn down with it.
-- It holds nothing and is not clearable: it is the entry hall the gates drop a
-- party into, with its one door north into the first fight. It used to be the
-- camp, and outlived every dungeon because the stations stood in it — those
-- now stand in the hub, which is its own building somewhere else entirely.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local DungeonDefs = require(Shared.DungeonDefs)
local DungeonLayout = require(Shared.DungeonLayout)
local LootTables = require(Shared.LootTables)
local RigDefs = require(Shared.RigDefs)

local CombatServer = require(script.Parent.Parent.Combat.CombatServer)
local EnemyAI = require(script.Parent.Parent.Combat.EnemyAI)
local CurrencyService = require(script.Parent.Parent.Economy.CurrencyService)
local ProgressionService = require(script.Parent.Parent.Progression.ProgressionService)
local AmbushService = require(script.Parent.AmbushService)
local ChestService = require(script.Parent.ChestService)
local RoomTemplates = require(script.Parent.RoomTemplates)
local ShrineService = require(script.Parent.ShrineService)

local DungeonGenerator = {}

export type BuiltRoom = {
	node: DungeonLayout.RoomNode,
	room: RoomTemplates.Room,
	-- The room's floor centre, looking in from its entrance: local -Z is
	-- deeper into the room, +Z back toward the door.
	frame: CFrame,
	-- Every enemy the room has had, including ambush waves as they arrive.
	enemies: { EnemyAI.Enemy },
	-- Whether clearing this room counts toward the dungeon's progress.
	clearable: boolean,
	cleared: boolean,
	clearedCallbacks: { () -> () },
}

export type BuiltDungeon = {
	folder: Folder,
	layout: DungeonLayout.Layout,
	rooms: { BuiltRoom },
	boss: EnemyAI.Enemy,
	bossRoom: BuiltRoom,
	-- Run when the dungeon is torn down (stops ambushes).
	cleanups: { () -> () },
}

-- Runs `callback` once, when every enemy in the room is dead (or an ambush's
-- last wave falls). Only clearable rooms ever fire.
function DungeonGenerator.onRoomCleared(built: BuiltRoom, callback: () -> ())
	table.insert(built.clearedCallbacks, callback)
end

local function markCleared(built: BuiltRoom)
	if built.cleared then
		return
	end
	built.cleared = true
	for _, callback in built.clearedCallbacks do
		local ok, err = pcall(callback)
		if not ok then
			warn(`Room cleared callback failed: {err}`)
		end
	end
end

-- A room with its enemies already standing in it is cleared when they're all
-- dead. Dungeon enemies don't respawn, so each death counts once.
local function trackClear(built: BuiltRoom)
	local remaining = #built.enemies
	for _, enemy in built.enemies do
		local counted = false
		EnemyAI.onDeath(enemy, function()
			if counted then
				return
			end
			counted = true
			remaining -= 1
			if remaining == 0 then
				markCleared(built)
			end
		end)
	end
end

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

-- The room's floor centre, facing inward from its entrance.
local function roomFrame(origin: CFrame, node: DungeonLayout.RoomNode): CFrame
	local centre = (origin * CFrame.new(node.x, 0, node.z)).Position
	local entrance = node.entrance or "South"
	local dir = DungeonLayout.DIRECTION[entrance]
	-- From the entrance wall toward the far side.
	local inward = Vector3.new(-dir.x, 0, -dir.z)
	return CFrame.lookAt(centre, centre + inward)
end

-- Where a room's enemies stand, in its frame: fanned across the room just
-- past the middle, so players see all of them from the door.
local function enemyOffsets(count: number, size: number): { Vector3 }
	if count <= 1 then
		return { Vector3.new(0, 0, -size * 0.1) }
	end

	local offsets = {}
	local spread = size * 0.5
	for i = 1, count do
		local t = (i - 1) / (count - 1) - 0.5
		-- The middle of the line stands a little further back.
		local depth = -size * 0.12 - (0.5 - math.abs(t)) * size * 0.12
		table.insert(offsets, Vector3.new(t * spread, 0, depth))
	end
	return offsets
end

local function spawnEnemies(built: BuiltRoom, folder: Folder)
	local node = built.node
	local offsets = enemyOffsets(#node.enemies, node.size)
	local door = built.frame * CFrame.new(0, 0, node.size / 2)

	for index, defId in node.enemies do
		local rootHeight = RigDefs.rootSize(defId)[2]
		local floorPoint = (built.frame * CFrame.new(offsets[index])).Position
		local position = floorPoint + Vector3.new(0, rootHeight / 2, 0)

		-- A bigger rig stops further from the walls, so it never clips into one.
		local inset = RoomTemplates.LEASH_INSET * RigDefs.scaleOf(defId)
		local bounds = RoomTemplates.leashBounds(built.room, inset)

		local enemy = CombatServer.spawnEnemy(defId, position, door.Position, bounds, folder, { respawns = false })
		CurrencyService.trackEnemy(enemy)
		ProgressionService.trackEnemy(enemy)
		table.insert(built.enemies, enemy)
	end
end

-- Returns the chest's unlock function.
local function addChest(built: BuiltRoom, folder: Folder): () -> ()
	local node = built.node
	local purpose = DungeonDefs.PURPOSES[node.purpose]
	local isAmbush = node.purpose == "Ambush"

	-- Against the far wall, lock facing the door: the prize is behind the fight.
	local spot = built.frame * CFrame.new(0, 0, -(node.size / 2 - 4))
	local floorCFrame = CFrame.lookAt(spot.Position, (built.frame * CFrame.new(0, 0, node.size / 2)).Position)

	-- What's inside reflects who guarded it: the room's first enemy, or the
	-- ambush's first attacker. Unguarded treasure is a relic.
	local leaderId = if isAmbush then node.waves[1] and node.waves[1][1] else (built.enemies[1] and built.enemies[1].defId)
	local loot = if leaderId then LootTables[leaderId] else DungeonDefs.TREASURE_LOOT
	assert(loot, `No LootTables entry for "{leaderId}"`)

	-- A vault holds a relic *and* a trophy from whatever guards the room it
	-- branches off, so a chest menu has something to choose between rather
	-- than one row to click.
	local contents = { loot }
	if purpose == DungeonDefs.PURPOSES.Treasure and leaderId then
		table.insert(contents, DungeonDefs.TREASURE_LOOT)
	end

	local _, unlock = ChestService.createChest({
		floorCFrame = floorCFrame,
		-- An ambush's attackers don't exist yet; the ambush unlocks it.
		guards = if isAmbush then {} else built.enemies,
		startsLocked = isAmbush,
		loot = contents,
		coins = purpose.chestCoins,
		name = `Room{node.id}_Chest`,
		parent = folder,
	})
	return unlock
end

-- A few heaps of coins around a treasure chest, so a vault looks like one.
local function addHoard(built: BuiltRoom, folder: Folder)
	local node = built.node
	for _, x in { -5, 5 } do
		local heap = Instance.new("Part")
		heap.Name = "CoinHeap"
		heap.Anchored = true
		heap.CanCollide = false
		heap.CanQuery = false
		heap.Shape = Enum.PartType.Ball
		heap.Size = Vector3.new(3, 3, 3)
		heap.CFrame = built.frame * CFrame.new(x, -0.9, -(node.size / 2 - 5))
		heap.Color = Color3.fromRGB(230, 180, 60)
		heap.Material = Enum.Material.Foil
		heap.Parent = folder
	end
end

function DungeonGenerator.build(layout: DungeonLayout.Layout, origin: CFrame, parent: Instance): BuiltDungeon
	local folder = Instance.new("Folder")
	folder.Name = `Dungeon_{layout.seed}`
	folder.Parent = parent

	local rooms: { BuiltRoom } = {}
	local byId: { [number]: BuiltRoom } = {}
	local cleanups: { () -> () } = {}

	for _, node in layout.rooms do
		local doors: { [RoomTemplates.Side]: boolean } = {}
		for side in node.doors do
			doors[side] = true
		end

		local frame = roomFrame(origin, node)
		local room = RoomTemplates.build({
			variant = node.variant,
			size = node.size,
			doors = doors,
			entrance = node.entrance,
			torchColor = rgb(DungeonDefs.PURPOSES[node.purpose].torchColor),
		}, frame)
		room.model.Name = `Room{node.id}_{node.purpose}`
		room.model.Parent = folder

		local isAmbush = node.purpose == "Ambush"
		local built: BuiltRoom = {
			node = node,
			room = room,
			frame = frame,
			enemies = {},
			clearable = DungeonDefs.PURPOSES[node.purpose].clearable and (#node.enemies > 0 or isAmbush),
			cleared = false,
			clearedCallbacks = {},
		}
		table.insert(rooms, built)
		byId[node.id] = built

		spawnEnemies(built, folder)
		if built.clearable and not isAmbush then
			trackClear(built)
		end

		local unlockChest: (() -> ())? = nil
		if node.hasChest then
			unlockChest = addChest(built, folder)
		end

		if node.purpose == "Treasure" then
			addHoard(built, folder)
		elseif node.purpose == "Shrine" then
			ShrineService.build(frame, room.model)
		elseif isAmbush then
			table.insert(cleanups, AmbushService.start(room, node, room.model, {
				onSpawned = function(enemy)
					table.insert(built.enemies, enemy)
				end,
				onCleared = function()
					if unlockChest then
						unlockChest()
					end
					markCleared(built)
				end,
			}))
		end
	end

	for _, corridor in layout.corridors do
		local centre = (origin * CFrame.new(corridor.x, 0, corridor.z)).Position
		RoomTemplates.buildCorridor(folder, centre, corridor.length, corridor.alongX)
	end

	local bossRoom = byId[layout.bossId]
	local boss = bossRoom and bossRoom.enemies[1]
	assert(bossRoom and boss, "Dungeon built without a boss")

	return {
		folder = folder,
		layout = layout,
		rooms = rooms,
		boss = boss,
		bossRoom = bossRoom,
		cleanups = cleanups,
	}
end

return DungeonGenerator
