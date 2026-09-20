--!strict
-- 1v1 PvP arena (build-order step 9). One shared arena and one active duel at a
-- time — a third or fourth queued player waits for the current duel to end.
-- Multiple concurrent arenas are a reasonable later enhancement, not a gap:
-- PvP is a secondary mode reusing PvE's combat system, not something that
-- needs day-one matchmaking scale (DESIGN.md).
--
-- Owns the arena room, the queue, and who is dueling whom. PvPCombatServer
-- owns resolving swings and parries within whatever duel this module says is
-- running — the same split as DungeonGenerator (places enemies) vs.
-- CombatServer (resolves combat against them).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local RoomTemplates = require(script.Parent.Parent.Dungeon.RoomTemplates)
local Duelist = require(script.Parent.Duelist)

-- Well clear of the hub, and on the opposite side of it from the dungeon,
-- which is generated far to the north — so no run of combat rooms can ever
-- reach it.
local ARENA_OFFSET = Vector3.new(0, 0, -260)
-- Where a finished duel puts the two of them back: in front of the stand they
-- queued at, not in the middle of the hall.
local RETURN_OFFSET = Vector3.new(0, 3, -6)
local SPAWN_INSET = 22
local RETURN_DELAY = 1

local ArenaService = {}

type Duel = {
	players: { Player },
	duelists: { [Player]: Duelist.Duelist },
}

local queue: { Player } = {}
local activeDuel: Duel? = nil
local originReturnCFrame = CFrame.new()
local arenaBaseCFrame = CFrame.new()

-- Tells one duelist where they stand: queued, duelling, or done. Checks
-- they are still in the game first, since a duel can end because someone
-- left.
local function publishStatus(player: Player, status: string, opponentName: string?, message: string?)
	if player.Parent then
		Remotes.get("PvPStatusChanged"):FireClient(player, {
			status = status,
			opponentName = opponentName,
			message = message,
		})
	end
end

-- Puts a player's character somewhere, if they have one.
local function teleportTo(player: Player, cframe: CFrame)
	local character = player.Character
	if character and character:FindFirstChild("HumanoidRootPart") then
		character:PivotTo(cframe)
	end
end

-- Sends both duelists' health to both of them. Called after anything that
-- changes either.
function ArenaService.publishHealth()
	local duel = activeDuel
	if not duel then
		return
	end

	local a, b = duel.players[1], duel.players[2]
	local healthA, healthB = duel.duelists[a].health, duel.duelists[b].health

	if a.Parent then
		Remotes.get("PvPHealthChanged"):FireClient(a, { yours = healthA, opponent = healthB })
	end
	if b.Parent then
		Remotes.get("PvPHealthChanged"):FireClient(b, { yours = healthB, opponent = healthA })
	end
end

-- Starts duels while there are two people waiting and no duel running.
-- A loop rather than a single check: the pair it pulls may have left, in
-- which case it should go straight on to the next pair.
local function tryStartNextDuel()
	while activeDuel == nil and #queue >= 2 do
		local a = table.remove(queue, 1) :: Player
		local b = table.remove(queue, 1) :: Player

		-- Anyone who left while queued is dropped; whoever's still here keeps
		-- their place at the front.
		if not (a.Parent and b.Parent) then
			if a.Parent then
				table.insert(queue, 1, a)
			elseif b.Parent then
				table.insert(queue, 1, b)
			end
			continue
		end

		activeDuel = {
			players = { a, b },
			duelists = { [a] = Duelist.new(a), [b] = Duelist.new(b) },
		}

		-- A CFrame's default facing is -Z. The player at -Z is turned around so
		-- the two start facing each other rather than one facing the wall.
		teleportTo(a, arenaBaseCFrame * CFrame.new(0, 3, -SPAWN_INSET) * CFrame.Angles(0, math.pi, 0))
		teleportTo(b, arenaBaseCFrame * CFrame.new(0, 3, SPAWN_INSET))

		publishStatus(a, "dueling", b.Name)
		publishStatus(b, "dueling", a.Name)
		ArenaService.publishHealth()
	end
end

-- Ends the current duel, sends both duelists home and starts the next.
-- Ignores a loser who is not in this duel, so a late report from a duel
-- already over cannot end the one that replaced it.
local function endDuel(loser: Player, message: string?)
	local duel = activeDuel
	if not duel or not duel.duelists[loser] then
		return
	end

	local a, b = duel.players[1], duel.players[2]
	local winner = if loser == a then b else a

	publishStatus(winner, "idle", nil, message or `You defeated {loser.Name}!`)
	publishStatus(loser, "idle", nil, message or `{winner.Name} defeated you.`)

	activeDuel = nil

	task.delay(RETURN_DELAY, function()
		teleportTo(winner, originReturnCFrame)
		teleportTo(loser, originReturnCFrame)
		tryStartNextDuel()
	end)
end

-- `originCFrame` is the hub, which the arena is placed relative to;
-- `standCFrame` is where the duel stand goes in it, looking into the hall.
function ArenaService.start(originCFrame: CFrame, standCFrame: CFrame)
	originReturnCFrame = standCFrame * CFrame.new(RETURN_OFFSET)
	arenaBaseCFrame = originCFrame * CFrame.new(ARENA_OFFSET)

	local arena = RoomTemplates.build({ variant = "Empty", size = 62, doors = {} }, arenaBaseCFrame)
	arena.model.Name = "Arena"
	arena.model.Parent = Workspace

	local stand = Instance.new("Part")
	stand.Name = "DuelQueue"
	stand.Anchored = true
	stand.CanCollide = true
	stand.Size = Vector3.new(2, 4, 2)
	stand.Color = Color3.fromRGB(60, 58, 70)
	stand.Material = Enum.Material.Slate
	stand.CFrame = standCFrame * CFrame.new(0, 2, 0)
	stand.Parent = Workspace

	-- Crossed blades over a blue glow, so it reads as "fight here" from across
	-- the room. Decoration only.
	local glow = Instance.new("Part")
	glow.Name = "Glow"
	glow.Anchored = true
	glow.CanCollide = false
	glow.CanQuery = false
	glow.Material = Enum.Material.Neon
	glow.Color = Color3.fromRGB(40, 140, 255)
	glow.Size = Vector3.new(1.6, 0.1, 1.6)
	glow.CFrame = stand.CFrame * CFrame.new(0, 2.05, 0)
	glow.Parent = stand

	local light = Instance.new("PointLight")
	light.Color = glow.Color
	light.Brightness = 1.5
	light.Range = 10
	light.Parent = glow

	for _, angle in { 35, -35 } do
		local blade = Instance.new("Part")
		blade.Name = "CrossedBlade"
		blade.Anchored = true
		blade.CanCollide = false
		blade.CanQuery = false
		blade.Material = Enum.Material.Metal
		blade.Color = Color3.fromRGB(196, 202, 212)
		blade.Size = Vector3.new(0.15, 3, 0.35)
		blade.CFrame = stand.CFrame * CFrame.new(0, 3.6, 0) * CFrame.Angles(0, 0, math.rad(angle))
		blade.Parent = stand
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = "Duel Arena"
	prompt.ActionText = "Queue"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.Parent = stand

	-- Triggering again while queued leaves the queue.
	prompt.Triggered:Connect(function(player)
		local duel = activeDuel
		if duel and duel.duelists[player] then
			return
		end

		local queueIndex = table.find(queue, player)
		if queueIndex then
			table.remove(queue, queueIndex)
			publishStatus(player, "idle")
			return
		end

		table.insert(queue, player)
		publishStatus(player, "queued")
		tryStartNextDuel()
	end)

	Players.PlayerRemoving:Connect(function(player)
		local queueIndex = table.find(queue, player)
		if queueIndex then
			table.remove(queue, queueIndex)
		end

		local duel = activeDuel
		if duel and duel.duelists[player] then
			endDuel(player, `{player.Name} left the duel.`)
		end
	end)
end

-- This player's own Duelist, if they're in the active duel.
function ArenaService.getDuelist(player: Player): Duelist.Duelist?
	local duel = activeDuel
	if not duel then
		return nil
	end

	return duel.duelists[player]
end

-- The opposing Duelist and Player, or nil if `player` isn't dueling.
function ArenaService.getOpponent(player: Player): (Duelist.Duelist?, Player?)
	local duel = activeDuel
	if not duel or not duel.duelists[player] then
		return nil, nil
	end

	local a, b = duel.players[1], duel.players[2]
	local opponent = if player == a then b else a
	return duel.duelists[opponent], opponent
end

-- Called by PvPCombatServer once a duelist's health reaches zero.
function ArenaService.endDuel(loser: Player)
	endDuel(loser)
end

return ArenaService
