--!strict
-- The way into the dungeon: a gate in the camp with a ready-check queue, and
-- the portcullis that makes the gate the way in rather than a suggestion.
--
-- A ready check rather than a party requirement: the first player to queue
-- starts a short countdown, anyone who queues before it ends goes in with
-- them, and a solo player on a quiet server still gets in when it expires. A
-- queue that waits for N players would strand the only person online, which
-- is most servers most of the time.
--
-- Like the weapon stands and the anvil, this is diegetic:
-- ProximityPrompt.Triggered already fires server-side with the player
-- attached, so queueing needs no client-callable remote. Only the countdown
-- goes back to the client, so it can show the wait.
--
-- The dungeon lives in this same server (DungeonService builds it north of
-- the camp), so "entering" is a teleport across the Workspace, never a
-- TeleportService hop to another place.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Palette = require(Shared.Palette)
local Remotes = require(Shared.Remotes)

local DungeonService = require(script.Parent.DungeonService)
local RoomTemplates = require(script.Parent.RoomTemplates)

local QueueService = {}

-- How long the ready check runs once the first player joins it.
local COUNTDOWN = 10
-- How often the countdown is checked.
local TICK = 0.25
-- The gate stands between the weapon stands and the camp's north door.
local GATE_OFFSET = Vector3.new(0, 0, 13)
-- Where players are spread as they arrive, so two never land inside each
-- other.
local ARRIVAL_SPREAD = 6

local queue: { Player } = {}
local entersAt: number? = nil
local gateLight: PointLight? = nil

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local function publish(player: Player, queued: boolean)
	if player.Parent then
		Remotes.get("DungeonQueueChanged"):FireClient(player, {
			queued = queued,
			count = #queue,
			entersAt = if queued then entersAt else nil,
		})
	end
end

local function publishAll()
	for _, player in queue do
		publish(player, true)
	end
end

local function notice(player: Player, text: string, tone: string)
	if player.Parent then
		Remotes.get("DungeonNotice"):FireClient(player, { text = text, tone = tone })
	end
end

-- The gate burns while a ready check is running, so anyone in the camp can
-- see one is open without reading any UI.
local function setGateLit(lit: boolean)
	local light = gateLight
	if light then
		light.Brightness = if lit then 5 else 1.2
		light.Range = if lit then 32 else 16
	end
end

local function removeFromQueue(player: Player): boolean
	local index = table.find(queue, player)
	if not index then
		return false
	end

	table.remove(queue, index)
	if #queue == 0 then
		entersAt = nil
		setGateLit(false)
	end
	return true
end

local function sendIn()
	local entry = DungeonService.entryCFrame()
	if not entry then
		-- The dungeon is being rebuilt. Hold the queue and try again on the
		-- next tick rather than dropping anyone into a torn-down run.
		entersAt = Workspace:GetServerTimeNow() + 2
		publishAll()
		return
	end

	local entering = table.clone(queue)
	table.clear(queue)
	entersAt = nil
	setGateLit(false)

	for index, player in entering do
		publish(player, false)

		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			-- Fanned across the doorway so a group doesn't stack up.
			local across = (index - (#entering + 1) / 2) * ARRIVAL_SPREAD
			character:PivotTo(entry * CFrame.new(across, 0, 0))
			notice(player, "You descend into the dungeon", "danger")
		end
	end
end

--[[ The gate ]]

local function makePart(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Parent = parent
	return part
end

-- The portcullis in the camp's north doorway. Solid, so the queue is the way
-- into the dungeon; the run still ends by walking back through the corridor,
-- which nothing blocks from the far side.
local function buildPortcullis(originCFrame: CFrame, doorZ: number)
	local frame = originCFrame * CFrame.new(0, 0, doorZ)
	local width = RoomTemplates.DOOR_WIDTH
	local height = RoomTemplates.DOOR_HEIGHT

	local blocker = Instance.new("Part")
	blocker.Name = "Portcullis"
	blocker.Anchored = true
	blocker.CanCollide = true
	blocker.Size = Vector3.new(width, height, 0.6)
	blocker.CFrame = frame * CFrame.new(0, height / 2, 0)
	blocker.Transparency = 1
	blocker.Parent = Workspace

	-- The bars themselves are decoration hung on the blocker.
	for index = 0, 5 do
		local x = -width / 2 + width * index / 5
		makePart(blocker, "PortcullisBar", Vector3.new(0.35, height, 0.35), frame * CFrame.new(x, height / 2, 0), rgb(Palette.IRON), Enum.Material.Metal)
	end
	for _, y in { height * 0.25, height * 0.62, height - 0.4 } do
		makePart(blocker, "PortcullisRail", Vector3.new(width + 0.4, 0.4, 0.5), frame * CFrame.new(0, y, 0), rgb(Palette.RUST), Enum.Material.Metal)
	end
	-- Spiked feet, so it reads as a thing that came down rather than a fence.
	for index = 0, 5 do
		local x = -width / 2 + width * index / 5
		makePart(blocker, "PortcullisSpike", Vector3.new(0.35, 0.8, 0.35), frame * CFrame.new(x, 0.3, 0), rgb(Palette.DARK_STEEL), Enum.Material.Metal)
	end
end

-- The gate: two pillars carrying a lintel, a brazier between them that burns
-- while a ready check is running, and the prompt to join it.
local function buildGate(originCFrame: CFrame): Part
	local base = originCFrame * CFrame.new(GATE_OFFSET)

	local station = Instance.new("Part")
	station.Name = "DungeonGate"
	station.Anchored = true
	station.CanCollide = true
	station.Size = Vector3.new(2.6, 3.4, 2.6)
	station.CFrame = base * CFrame.new(0, 1.7, 0)
	station.Color = rgb(Palette.TRIM)
	station.Material = Enum.Material.Slate
	station.Parent = Workspace

	makePart(station, "GateBowl", Vector3.new(3.2, 0.9, 3.2), base * CFrame.new(0, 3.7, 0), rgb(Palette.IRON), Enum.Material.Metal)
	local coals = makePart(station, "GateCoals", Vector3.new(2.4, 0.3, 2.4), base * CFrame.new(0, 4.2, 0), rgb(Palette.GHOST_FIRE), Enum.Material.Neon)

	-- Two pillars and a lintel either side, so the brazier reads as a gateway.
	for _, sign in { -1, 1 } do
		local x = sign * 6
		makePart(station, "GatePillar", Vector3.new(2, 11, 2), base * CFrame.new(x, 5.5, 0), rgb(Palette.PILLAR), Enum.Material.Granite)
		makePart(station, "GatePillarCap", Vector3.new(2.8, 0.7, 2.8), base * CFrame.new(x, 11.2, 0), rgb(Palette.TRIM), Enum.Material.Slate)
		makePart(station, "GatePillarFoot", Vector3.new(2.8, 0.8, 2.8), base * CFrame.new(x, 0.4, 0), rgb(Palette.TRIM), Enum.Material.Slate)
		makePart(station, "GateSkull", Vector3.new(0.9, 0.9, 1.0), base * CFrame.new(x, 12.0, 0), rgb(Palette.OLD_BONE), Enum.Material.Marble)
	end
	makePart(station, "GateLintel", Vector3.new(14.4, 1.4, 2.4), base * CFrame.new(0, 12.2, 0), rgb(Palette.TRIM), Enum.Material.Slate)
	makePart(station, "GateSigil", Vector3.new(2, 2, 0.4), base * CFrame.new(0, 12.2, -1.2) * CFrame.Angles(0, 0, math.rad(45)), rgb(Palette.GOLD), Enum.Material.Metal)

	local fire = Instance.new("Fire")
	fire.Size = 5
	fire.Heat = 8
	fire.Color = rgb(Palette.GHOST_FIRE)
	fire.SecondaryColor = Color3.fromRGB(30, 60, 140)
	fire.Parent = coals

	local light = Instance.new("PointLight")
	light.Color = rgb(Palette.GHOST_FIRE)
	light.Brightness = 1.2
	light.Range = 16
	light.Shadows = true
	light.Parent = coals
	gateLight = light

	return station
end

--[[ Lifecycle ]]

function QueueService.start(originCFrame: CFrame, campSize: number)
	-- The camp's one door is north (+Z), on the far wall.
	buildPortcullis(originCFrame, campSize / 2)
	local station = buildGate(originCFrame)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = "The Dungeon"
	prompt.ActionText = "Queue"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.Parent = station

	-- Triggering again while queued leaves the queue, the same way the duel
	-- stand works.
	prompt.Triggered:Connect(function(player)
		if removeFromQueue(player) then
			publish(player, false)
			notice(player, "You step back from the gate", "info")
			publishAll()
			return
		end

		table.insert(queue, player)
		if entersAt == nil then
			entersAt = Workspace:GetServerTimeNow() + COUNTDOWN
			setGateLit(true)
		end
		notice(player, "The gate opens shortly", "info")
		publishAll()
	end)

	Players.PlayerRemoving:Connect(function(player)
		if removeFromQueue(player) then
			publishAll()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(TICK)
			local at = entersAt
			if at and Workspace:GetServerTimeNow() >= at then
				if #queue == 0 then
					entersAt = nil
					setGateLit(false)
				else
					sendIn()
				end
			end
		end
	end)
end

-- Whether this player is waiting at the gate. The weapon stands allow a swap
-- while queued — the countdown is exactly when you would want to change your
-- mind about what to bring.
function QueueService.isQueued(player: Player): boolean
	return table.find(queue, player) ~= nil
end

return QueueService
