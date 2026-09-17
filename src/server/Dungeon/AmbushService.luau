--!strict
-- Ambush rooms: walk far enough in and the gates slam shut behind you. The
-- enemies come in waves out of the floor, and when the last wave falls the
-- gates open and the chest unlocks.
--
-- Replaces the trap room, which tested dodging random floor plates rather
-- than anything combat teaches. An ambush tests the combat itself, under
-- pressure: more enemies than a normal room, arriving on their own schedule,
-- with nowhere to back off to.
--
-- If everyone inside dies (or leaves before the gates close and nobody is
-- left), the ambush gives up after a few seconds: the survivors of the
-- current wave vanish, the gates open, and it re-arms for the next attempt.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local DungeonDefs = require(Shared.DungeonDefs)
local DungeonLayout = require(Shared.DungeonLayout)
local Remotes = require(Shared.Remotes)
local RigDefs = require(Shared.RigDefs)

local Characters = require(script.Parent.Parent.Combat.Characters)
local CombatServer = require(script.Parent.Parent.Combat.CombatServer)
local EnemyAI = require(script.Parent.Parent.Combat.EnemyAI)
local CurrencyService = require(script.Parent.Parent.Economy.CurrencyService)
local ProgressionService = require(script.Parent.Parent.Progression.ProgressionService)
local PvPCombatServer = require(script.Parent.Parent.PvP.PvPCombatServer)
local RoomTemplates = require(script.Parent.RoomTemplates)

local AmbushService = {}

local POLL = 0.25
local GATE_HEIGHT = 9.4
local GATE_COLOR = Color3.fromRGB(170, 80, 255)
local GATE_SEALED_TRANSPARENCY = 0.1

type State = "armed" | "springing" | "sealed" | "cleared"

export type Hooks = {
	-- Every enemy the ambush spawns, so the dungeon can tear it down later.
	onSpawned: (EnemyAI.Enemy) -> (),
	-- The last wave fell.
	onCleared: () -> (),
}

local function notice(text: string, tone: string)
	Remotes.get("DungeonNotice"):FireAllClients({ text = text, tone = tone })
end

local function livingPlayersIn(bounds: RoomTemplates.Bounds): number
	local count = 0
	for _, player in Players:GetPlayers() do
		local root = Characters.getRoot(player)
		if root and Characters.isAlive(player) and not PvPCombatServer.isDueling(player) then
			local p = root.Position
			if p.X >= bounds.minX and p.X <= bounds.maxX and p.Z >= bounds.minZ and p.Z <= bounds.maxZ then
				count += 1
			end
		end
	end
	return count
end

local function inset(bounds: RoomTemplates.Bounds, amount: number): RoomTemplates.Bounds
	return {
		minX = bounds.minX + amount,
		maxX = bounds.maxX - amount,
		minZ = bounds.minZ + amount,
		maxZ = bounds.maxZ - amount,
	}
end

-- A shimmering barrier across a doorway, invisible and passable until sealed.
local function buildGate(room: RoomTemplates.Room, side: DungeonLayout.Side, parent: Instance): Part
	local dir = DungeonLayout.DIRECTION[side]
	local centre = room.centre.Position + Vector3.new(dir.x, 0, dir.z) * (room.size / 2 + 0.5)
	local alongX = dir.z ~= 0

	local gate = Instance.new("Part")
	gate.Name = "AmbushGate"
	gate.Anchored = true
	gate.CanCollide = false
	gate.CanQuery = false
	gate.CanTouch = false
	gate.CastShadow = false
	gate.Material = Enum.Material.ForceField
	gate.Color = GATE_COLOR
	gate.Transparency = 1
	gate.Size = if alongX
		then Vector3.new(RoomTemplates.DOOR_WIDTH + 0.6, GATE_HEIGHT, 1)
		else Vector3.new(1, GATE_HEIGHT, RoomTemplates.DOOR_WIDTH + 0.6)
	gate.CFrame = CFrame.new(centre + Vector3.new(0, GATE_HEIGHT / 2, 0))
	gate.Parent = parent

	local light = Instance.new("PointLight")
	light.Color = GATE_COLOR
	light.Brightness = 0
	light.Range = 14
	light.Parent = gate

	return gate
end

local function setGates(gates: { Part }, sealed: boolean)
	for _, gate in gates do
		gate.CanCollide = sealed
		local light = gate:FindFirstChildOfClass("PointLight")
		TweenService:Create(gate, TweenInfo.new(if sealed then 0.25 else 0.6), {
			Transparency = if sealed then GATE_SEALED_TRANSPARENCY else 1,
		}):Play()
		if light then
			TweenService:Create(light, TweenInfo.new(0.4), { Brightness = if sealed then 2.5 else 0 }):Play()
		end
	end
end

-- A burst of dark smoke where an enemy climbs out of the floor. Switched on and
-- off rather than Emit()ted, since only enabled emitters replicate.
local function spawnBurst(position: Vector3, parent: Instance)
	local holder = Instance.new("Part")
	holder.Name = "AmbushSpawnFX"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(3, 0.2, 3)
	holder.CFrame = CFrame.new(position)
	holder.Parent = parent

	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Color = ColorSequence.new(Color3.fromRGB(70, 30, 100))
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(1, 5),
	})
	smoke.Lifetime = NumberRange.new(0.8, 1.3)
	smoke.Speed = NumberRange.new(4, 9)
	smoke.EmissionDirection = Enum.NormalId.Top
	smoke.SpreadAngle = Vector2.new(35, 35)
	smoke.Rate = 60
	smoke.Parent = holder

	local light = Instance.new("PointLight")
	light.Color = GATE_COLOR
	light.Brightness = 3
	light.Range = 12
	light.Parent = holder

	task.delay(0.35, function()
		smoke.Enabled = false
		light.Enabled = false
	end)
	task.delay(2, function()
		holder:Destroy()
	end)
end

-- Arms an ambush room. Returns a function that stops it for good.
function AmbushService.start(
	room: RoomTemplates.Room,
	node: DungeonLayout.RoomNode,
	parent: Instance,
	hooks: Hooks
): () -> ()
	local def = DungeonDefs.AMBUSH
	local trigger = inset(room.floorBounds, def.triggerDepth)

	local gates: { Part } = {}
	for side in node.doors do
		table.insert(gates, buildGate(room, side, parent))
	end

	local active = true
	local state: State = "armed"
	-- Bumped on every reset, so callbacks from an abandoned attempt do nothing.
	local attempt = 0
	local waveIndex = 0
	local living: { EnemyAI.Enemy } = {}
	local emptySince: number? = nil

	local nextWave: () -> ()

	local function clear()
		state = "cleared"
		setGates(gates, false)
		notice("The ambush is broken", "good")
		hooks.onCleared()
	end

	local function spawnWave(ids: { string })
		local thisAttempt = attempt
		local remaining = #ids
		local offset = math.random() * math.pi * 2

		for index, defId in ids do
			local angle = offset + (index - 1) / #ids * math.pi * 2
			local radius = room.size * 0.3
			local floorPoint = room.centre.Position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			local position = floorPoint + Vector3.new(0, RigDefs.rootSize(defId)[2] / 2, 0)
			local bounds = RoomTemplates.leashBounds(room, RoomTemplates.LEASH_INSET * RigDefs.scaleOf(defId))

			spawnBurst(floorPoint, parent)
			local enemy = CombatServer.spawnEnemy(defId, position, room.centre.Position, bounds, parent, { respawns = false })
			CurrencyService.trackEnemy(enemy)
			ProgressionService.trackEnemy(enemy)
			hooks.onSpawned(enemy)
			table.insert(living, enemy)

			EnemyAI.onDeath(enemy, function()
				if not active or attempt ~= thisAttempt then
					return
				end
				remaining -= 1
				if remaining == 0 then
					task.delay(def.waveDelay, function()
						if active and attempt == thisAttempt and state == "sealed" then
							nextWave()
						end
					end)
				end
			end)
		end
	end

	nextWave = function()
		waveIndex += 1
		local ids = node.waves[waveIndex]
		if not ids then
			clear()
			return
		end

		table.clear(living)
		if waveIndex > 1 then
			notice(`Wave {waveIndex}`, "danger")
		end
		spawnWave(ids)
	end

	local function spring()
		state = "springing"
		local thisAttempt = attempt
		notice("Ambush!", "danger")

		task.delay(def.sealDelay, function()
			if not active or attempt ~= thisAttempt or state ~= "springing" then
				return
			end
			state = "sealed"
			emptySince = nil
			setGates(gates, true)
			nextWave()
		end)
	end

	local function reset()
		attempt += 1
		for _, enemy in living do
			if enemy.alive then
				CombatServer.despawnEnemy(enemy)
			end
		end
		table.clear(living)
		waveIndex = 0
		emptySince = nil
		setGates(gates, false)
		state = "armed"
	end

	task.spawn(function()
		while active do
			task.wait(POLL)
			if not active then
				break
			end

			if state == "armed" then
				if livingPlayersIn(trigger) > 0 then
					spring()
				end
			elseif state == "sealed" or state == "springing" then
				if livingPlayersIn(room.floorBounds) > 0 then
					emptySince = nil
				else
					local now = os.clock()
					emptySince = emptySince or now
					if now - (emptySince :: number) >= def.resetAfter then
						reset()
					end
				end
			end
		end
	end)

	return function()
		active = false
	end
end

return AmbushService
