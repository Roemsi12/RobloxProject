--!strict
-- Runs the dungeon: generates one, tracks rooms being cleared and the boss
-- fight, pays out when the boss falls, then replaces the dungeon with a new
-- one.
--
-- A run's lifecycle:
--   running   — the dungeon is up. Rooms stay cleared once cleared.
--   cleared   — the boss is dead. Every player in the dungeon is paid, and a
--               countdown to the next dungeon starts.
--   resetting — players are brought back to the hub, the old dungeon is torn
--               down and a new one generated. Then running again.
--
-- The whole dungeon, entry hall included, is torn down and rebuilt on a reset.
-- Nobody loses the floor under them, because everything that has to survive a
-- run — the class altars, the forge, the three gates — stands in the hub,
-- which this module never touches.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local DungeonDefs = require(Shared.DungeonDefs)
local DungeonLayout = require(Shared.DungeonLayout)
local LootTables = require(Shared.LootTables)
local Remotes = require(Shared.Remotes)

local CombatServer = require(script.Parent.Parent.Combat.CombatServer)
local Characters = require(script.Parent.Parent.Combat.Characters)
local EnemyAI = require(script.Parent.Parent.Combat.EnemyAI)
local CurrencyService = require(script.Parent.Parent.Economy.CurrencyService)
local InventoryService = require(script.Parent.Parent.InventoryService)
local PvPCombatServer = require(script.Parent.Parent.PvP.PvPCombatServer)
local SpawnService = require(script.Parent.Parent.SpawnService)
local DungeonGenerator = require(script.Parent.DungeonGenerator)

local DungeonService = {}

export type Phase = "running" | "cleared" | "resetting"

-- How often the boss room is checked for players.
local ENCOUNTER_POLL = 0.3
-- Time for characters to land back in the hub before the old dungeon goes.
local RESET_SETTLE = 0.5

local origin = CFrame.new()
local current: DungeonGenerator.BuiltDungeon? = nil
local phase: Phase = "running"
local runNumber = 0
local roomsCleared = 0
local roomsTotal = 0
local resetAt: number? = nil

local encounterActive = false
local lastPlayerInBossRoom = 0

-- The whole run's state as one table: which run it is, what phase it is
-- in, and how far through the rooms. Built in one place so every send
-- agrees about shape.
local function statusPayload(): { [string]: any }
	return {
		run = runNumber,
		phase = phase,
		roomsCleared = roomsCleared,
		roomsTotal = roomsTotal,
		resetAt = resetAt,
	}
end

-- Tells every client the run's current state. Called after anything that
-- changes it, rather than on a timer.
local function publishStatus()
	Remotes.get("DungeonUpdated"):FireAllClients(statusPayload())
end

-- A one-line banner on every client's screen. `tone` picks its colour:
-- "good", "danger" or neutral.
local function notice(text: string, tone: string)
	Remotes.get("DungeonNotice"):FireAllClients({ text = text, tone = tone })
end

-- The boss encounter's state, or nil when there is no dungeon to describe
-- one for. `defeated` marks the send that reports the kill.
local function encounterPayload(active: boolean, defeated: boolean?): { [string]: any }?
	local dungeon = current
	if not dungeon then
		return nil
	end
	return {
		enemyId = dungeon.boss.id,
		name = dungeon.boss.def.displayName,
		active = active,
		defeated = defeated == true,
	}
end

-- Starts or ends the boss encounter and tells every client. Returns early
-- if nothing changed, so it is safe to call every frame — except for a
-- defeat, which always sends.
local function setEncounter(active: boolean, defeated: boolean?)
	if encounterActive == active and not defeated then
		return
	end
	encounterActive = active

	local payload = encounterPayload(active, defeated)
	if payload then
		Remotes.get("BossEncounter"):FireAllClients(payload)
	end
end

-- Players who count as being in the dungeon: everyone not in a duel.
local function dungeonPlayers(): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		if not PvPCombatServer.isDueling(player) then
			table.insert(list, player)
		end
	end
	return list
end

-- Whether anyone is standing inside the boss room's floor. What starts
-- the encounter: the boss wakes when someone walks in, not when the room
-- is generated.
local function anyPlayerInBossRoom(dungeon: DungeonGenerator.BuiltDungeon): boolean
	local bounds = dungeon.bossRoom.room.floorBounds
	for _, player in dungeonPlayers() do
		local root = Characters.getRoot(player)
		if root and Characters.isAlive(player) then
			local p = root.Position
			if p.X >= bounds.minX and p.X <= bounds.maxX and p.Z >= bounds.minZ and p.Z <= bounds.maxZ then
				return true
			end
		end
	end
	return false
end

--[[ Run lifecycle ]]

local generateRun: () -> ()

-- Tears the dungeon down and builds the next one. Guarded against running
-- twice, since both a boss kill and a wipe can ask for it.
local function resetRun()
	local dungeon = current
	if not dungeon or phase == "resetting" then
		return
	end

	phase = "resetting"
	resetAt = nil
	publishStatus()

	for _, player in dungeonPlayers() do
		SpawnService.sendToStart(player)
	end
	task.wait(RESET_SETTLE)

	for _, cleanup in dungeon.cleanups do
		cleanup()
	end
	for _, built in dungeon.rooms do
		for _, enemy in built.enemies do
			CombatServer.despawnEnemy(enemy)
		end
	end
	dungeon.folder:Destroy()
	current = nil

	generateRun()
	notice("A new dungeon has formed", "info")
end

-- The boss dying: reports it, pays everyone out, and schedules the reset.
-- Ignored unless the run is actually still running, so a late kill from a
-- run already being reset does nothing.
local function onBossDefeated()
	local dungeon = current
	if not dungeon or phase ~= "running" then
		return
	end

	phase = "cleared"
	resetAt = Workspace:GetServerTimeNow() + DungeonDefs.RESET_DELAY
	setEncounter(false, true)

	-- Everyone who was in the dungeon shares the clear: the reward, and a
	-- piece of the boss. Not just whoever landed the last hit, since the
	-- whole party fought for it.
	local reward = DungeonDefs.CLEAR_REWARD
	local bossLoot = LootTables[dungeon.boss.defId]
	for _, player in dungeonPlayers() do
		CurrencyService.grant(player, reward.coins, reward.crystals)
		if bossLoot and InventoryService.hasRoom(player) then
			InventoryService.addItem(player, {
				itemId = bossLoot.itemId,
				rarity = bossLoot.rarity,
				upgradeLevel = 0,
				classTag = bossLoot.classTag,
			})
			Remotes.get("ChestOpened"):FireClient(player, { chestId = "BossReward", loot = { bossLoot } })
		end
	end

	notice(`{dungeon.boss.def.displayName} has fallen!`, "victory")
	publishStatus()

	task.delay(DungeonDefs.RESET_DELAY, resetRun)
end

-- Watches one room's enemies and reports it cleared when the last of them
-- dies. `runId` is the guard against a room from a previous dungeon
-- reporting into the current one.
local function trackRoom(built: DungeonGenerator.BuiltRoom, runId: number)
	if not built.clearable then
		return
	end

	local purpose = DungeonDefs.PURPOSES[built.node.purpose]
	DungeonGenerator.onRoomCleared(built, function()
		if runNumber ~= runId then
			return
		end

		roomsCleared += 1
		-- The boss and the ambush announce their own ends.
		if built.node.purpose ~= "Boss" and built.node.purpose ~= "Ambush" then
			notice(`{purpose.displayName} cleared`, "good")
		end
		publishStatus()
	end)
end

generateRun = function()
	runNumber += 1
	local runId = runNumber

	local seed = math.random(1, 2 ^ 31 - 2)
	local layout = DungeonLayout.generate(seed)
	local dungeon = DungeonGenerator.build(layout, origin, Workspace)
	current = dungeon

	roomsCleared = 0
	roomsTotal = 0
	for _, built in dungeon.rooms do
		if built.clearable then
			roomsTotal += 1
		end
		trackRoom(built, runId)
	end

	encounterActive = false
	EnemyAI.onDeath(dungeon.boss, function()
		if runNumber == runId then
			onBossDefeated()
		end
	end)

	phase = "running"
	resetAt = nil
	publishStatus()
end

-- Builds the first dungeon at `originCFrame`, which is where its entry hall
-- goes; every room of every run grows north from there. Well away from the
-- hub, which is its own building and no longer part of any layout.
function DungeonService.start(originCFrame: CFrame)
	origin = originCFrame

	generateRun()

	-- A joining player needs to know where the run stands.
	Players.PlayerAdded:Connect(function(player)
		Remotes.get("DungeonUpdated"):FireClient(player, statusPayload())
		local payload = encounterPayload(encounterActive)
		if payload and encounterActive then
			Remotes.get("BossEncounter"):FireClient(player, payload)
		end
	end)

	-- The boss bar comes up when someone walks into the boss room, and goes
	-- once nobody has been in there for a few seconds.
	task.spawn(function()
		while true do
			task.wait(ENCOUNTER_POLL)
			local dungeon = current
			if not dungeon or phase ~= "running" or not dungeon.boss.alive then
				continue
			end

			local now = os.clock()
			if anyPlayerInBossRoom(dungeon) then
				lastPlayerInBossRoom = now
				if not encounterActive then
					setEncounter(true)
					notice(`{dungeon.boss.def.displayName} awakens`, "danger")
				end
			elseif encounterActive and now - lastPlayerInBossRoom > DungeonDefs.BOSS_ENCOUNTER_LINGER then
				setEncounter(false)
			end
		end
	end)

end

-- Where the gates drop players: the back of the dungeon's entry hall, facing
-- its one door north into the run. A room's `frame` looks deeper into it, so
-- +Z on it is back toward the wall behind them.
--
-- Arriving in the entry hall rather than in the first fight is the point of
-- keeping the Start room: a party lands together, in a room with nothing in
-- it, and walks into the dungeon on their own feet.
--
-- Returns nil while a dungeon is being torn down and rebuilt, which is the
-- signal for the queue to hold rather than send anyone into nothing.
function DungeonService.entryCFrame(): CFrame?
	local dungeon = current
	if not dungeon or phase ~= "running" then
		return nil
	end

	for _, built in dungeon.rooms do
		if built.node.id == dungeon.layout.startId then
			return built.frame * CFrame.new(0, 3, built.node.size / 2 - 8)
		end
	end

	return nil
end

return DungeonService
