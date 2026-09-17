--!strict
-- The way into the dungeon: three gates in the hub's north wall, each with its
-- own ready-check queue.
--
-- A ready check rather than a party requirement: the first player to step up
-- to a gate starts a short countdown, anyone who joins that gate before it ends
-- goes in with them, and a solo player on a quiet server still gets in when it
-- expires. A queue that waits for N players would strand the only person
-- online, which is most servers most of the time.
--
-- Three gates rather than one, because the hub has three: a player can pick a
-- line rather than joining the only one there is, and a group that missed a
-- countdown can start their own at the next gate along instead of waiting out
-- someone else's. The countdowns are independent — one gate firing does not
-- touch the others.
--
-- All three currently open on the same dungeon. There is one generated dungeon
-- in the world at a time (`DungeonService`), so the gates are three doors into
-- it rather than three different places; making them three difficulties would
-- mean a dungeon per gate, which is a much larger change than the gates
-- themselves.
--
-- Like the altars and the forge, this is diegetic: `ProximityPrompt.Triggered`
-- already fires server-side with the player attached, so queueing needs no
-- client-callable remote. Only the countdown goes back to the client, so it
-- can show the wait.
--
-- The dungeon lives in this same server (`DungeonService` builds it well north
-- of the hub), so "entering" is a teleport across the Workspace, never a
-- `TeleportService` hop to another place.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Stonework = require(script.Parent.Parent.Stonework)
local DungeonService = require(script.Parent.DungeonService)

local QueueService = {}

-- How long a gate's ready check runs once the first player joins it.
local COUNTDOWN = 10
-- How often the countdowns are checked.
local TICK = 0.25
-- Where players are spread as they arrive, so two never land inside each
-- other.
local ARRIVAL_SPREAD = 7

export type GateDef = {
	-- Shown on the prompt and on the client's status line.
	name: string,
	-- The gate's flame, and the colour of its veil in the north wall.
	color: Color3,
}

-- In the order the gates stand across the north wall, west to east. The colours
-- are also what LobbyBuilder lights each portal with, so a gate reads the same
-- from the far end of the hall as it does from the prompt.
local GATES: { GateDef } = {
	{ name = "The Ossuary Gate", color = Color3.fromRGB(255, 150, 70) },
	{ name = "The Hollow Gate", color = Color3.fromRGB(110, 200, 255) },
	{ name = "The Weeping Gate", color = Color3.fromRGB(190, 90, 255) },
}

type Gate = {
	def: GateDef,
	queue: { Player },
	entersAt: number?,
	light: PointLight?,
	fire: Fire?,
}

local gates: { Gate } = {}

-- The gate a player is waiting at, so leaving or disconnecting doesn't have to
-- search all three.
local waitingAt: { [Player]: Gate } = {}

function QueueService.gateColors(): { Color3 }
	local colors = {}
	for _, def in GATES do
		table.insert(colors, def.color)
	end
	return colors
end

local function publish(gate: Gate, player: Player, queued: boolean)
	if player.Parent then
		Remotes.get("DungeonQueueChanged"):FireClient(player, {
			queued = queued,
			gate = gate.def.name,
			count = #gate.queue,
			entersAt = if queued then gate.entersAt else nil,
		})
	end
end

local function publishAll(gate: Gate)
	for _, player in gate.queue do
		publish(gate, player, true)
	end
end

local function notice(player: Player, text: string, tone: string)
	if player.Parent then
		Remotes.get("DungeonNotice"):FireClient(player, { text = text, tone = tone })
	end
end

-- A gate burns high while its ready check is running, so anyone in the hall
-- can see which line is about to leave without reading any UI.
local function setLit(gate: Gate, lit: boolean)
	local light = gate.light
	if light then
		light.Brightness = if lit then 6 else 2
		light.Range = if lit then 46 else 22
	end
	local fire = gate.fire
	if fire then
		fire.Size = if lit then 11 else 5
	end
end

local function removeFromQueue(gate: Gate, player: Player): boolean
	local index = table.find(gate.queue, player)
	if not index then
		return false
	end

	table.remove(gate.queue, index)
	waitingAt[player] = nil
	if #gate.queue == 0 then
		gate.entersAt = nil
		setLit(gate, false)
	end
	return true
end

local function sendIn(gate: Gate)
	local entry = DungeonService.entryCFrame()
	if not entry then
		-- The dungeon is being rebuilt. Hold the queue and try again shortly
		-- rather than dropping anyone into a torn-down run.
		gate.entersAt = Workspace:GetServerTimeNow() + 2
		publishAll(gate)
		return
	end

	local entering = table.clone(gate.queue)
	table.clear(gate.queue)
	gate.entersAt = nil
	setLit(gate, false)

	for index, player in entering do
		waitingAt[player] = nil
		publish(gate, player, false)

		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			-- Fanned across the entry hall so a group doesn't stack up.
			local across = (index - (#entering + 1) / 2) * ARRIVAL_SPREAD
			character:PivotTo(entry * CFrame.new(across, 0, 0))
			notice(player, "You descend into the dungeon", "danger")
		end
	end
end

--[[ The muster post ]]

-- The station at a gate: a plinth carrying a bowl of the gate's fire, a
-- standard behind it, and the prompt. The portal itself — the opening, the
-- arch, the veil — belongs to the hall (`LobbyBuilder`); this is only the
-- thing you interact with in front of it.
--
-- `at` stands in front of the portal looking into it, so local -Z is the way
-- through and +Z is back down the hall.
local function buildPost(parent: Instance, at: CFrame, def: GateDef): (Part, PointLight?, Fire?)
	for step = 1, 2 do
		local side = 11 - step * 2.0
		Stonework.part(parent, "PostStep", Vector3.new(side, 0.5, side), at * CFrame.new(0, 0.25 + (step - 1) * 0.5, 0), Stonework.TRIM, Enum.Material.Slate)
	end

	local plinth = Stonework.part(parent, "DungeonGate", Vector3.new(3.6, 3.6, 3.6), at * CFrame.new(0, 2.8, 0), Stonework.TRIM, Enum.Material.Slate)
	Stonework.decor(parent, "PostCap", Vector3.new(4.6, 0.5, 4.6), plinth.CFrame * CFrame.new(0, 1.8, 0), Stonework.PILLAR, Enum.Material.Granite)
	Stonework.decor(parent, "PostMark", Vector3.new(2.2, 2.2, 0.3), plinth.CFrame * CFrame.new(0, 0.2, 1.85) * CFrame.Angles(0, 0, math.rad(45)), def.color, Enum.Material.Neon).CastShadow = false

	-- The bowl of fire on top of it: the thing that changes when a ready check
	-- is running.
	local coals = Stonework.brazier(parent, plinth.CFrame * CFrame.new(0, 1.9, 0), def.color, 0.8)

	-- A standard either side, in the gate's colour, so the post reads as a
	-- muster point rather than a bollard.
	for _, sign in { -1, 1 } do
		local poleAt = at * CFrame.new(sign * 7, 0, 1)
		Stonework.part(parent, "StandardPole", Vector3.new(0.5, 16, 0.5), poleAt * CFrame.new(0, 8, 0), Stonework.IRON, Enum.Material.Metal)
		Stonework.decor(parent, "StandardFinial", Vector3.new(1.0, 1.4, 1.0), poleAt * CFrame.new(0, 16.6, 0), Stonework.GOLD, Enum.Material.Metal)
		Stonework.decor(parent, "StandardCloth", Vector3.new(0.2, 7.5, 3.4), poleAt * CFrame.new(sign * -1.8, 11.5, 0), def.color, Enum.Material.Fabric)
	end

	return plinth, coals:FindFirstChildOfClass("PointLight"), coals:FindFirstChildOfClass("Fire")
end

--[[ Lifecycle ]]

-- `anchors` come from LobbyBuilder, one per gate, in the same order as GATES.
function QueueService.start(anchors: { CFrame })
	assert(#anchors >= #GATES, `The hub gave {#anchors} gate anchors; {#GATES} gates need one each`)

	local folder = Instance.new("Folder")
	folder.Name = "DungeonGates"
	folder.Parent = Workspace

	for index, def in GATES do
		local plinth, light, fire = buildPost(folder, anchors[index], def)

		local gate: Gate = {
			def = def,
			queue = {},
			entersAt = nil,
			light = light,
			fire = fire,
		}
		table.insert(gates, gate)
		setLit(gate, false)

		local prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = def.name
		prompt.ActionText = "Queue"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 12
		prompt.Parent = plinth

		prompt.Triggered:Connect(function(player)
			-- Triggering again at the gate you are waiting at leaves its
			-- queue, the same way the duel stand works.
			if removeFromQueue(gate, player) then
				publish(gate, player, false)
				notice(player, `You step back from {def.name}`, "info")
				publishAll(gate)
				return
			end

			-- Stepping up to a second gate moves you rather than putting you
			-- in both: whichever countdown fires first would otherwise send a
			-- player who is also still listed at the other one.
			local previous = waitingAt[player]
			if previous then
				removeFromQueue(previous, player)
				publishAll(previous)
			end

			table.insert(gate.queue, player)
			waitingAt[player] = gate
			if gate.entersAt == nil then
				gate.entersAt = Workspace:GetServerTimeNow() + COUNTDOWN
				setLit(gate, true)
			end
			notice(player, `{def.name} opens shortly`, "info")
			publishAll(gate)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		local gate = waitingAt[player]
		if gate and removeFromQueue(gate, player) then
			publishAll(gate)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(TICK)
			local now = Workspace:GetServerTimeNow()
			for _, gate in gates do
				local at = gate.entersAt
				if not at or now < at then
					continue
				end
				if #gate.queue == 0 then
					gate.entersAt = nil
					setLit(gate, false)
				else
					sendIn(gate)
				end
			end
		end
	end)
end

-- Whether this player is waiting at any gate. The class altars allow a swap
-- while queued — the countdown is exactly when you would want to change your
-- mind about what to bring.
function QueueService.isQueued(player: Player): boolean
	return waitingAt[player] ~= nil
end

return QueueService
