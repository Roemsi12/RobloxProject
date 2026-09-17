--!strict
-- Owns when characters exist, and where they appear.
--
-- Characters don't auto-load (CharacterAutoLoads is off in the place file,
-- and again here): a player gets a body only once DataService has loaded
-- their progress. Until then there is nothing to interact with, so nothing
-- can change a profile that hasn't been read yet — no race between loading
-- and playing.
--
-- Every character appears on the hub dais, and respawns there after death.

local Players = game:GetService("Players")

local SpawnService = {}

local spawnCFrame = CFrame.new()

-- Players whose profile is ready. Only they get (re)spawned.
local ready: { [Player]: boolean } = {}

-- Players already being watched, so one joining mid-startup isn't hooked up
-- twice.
local watched: { [Player]: boolean } = {}

local function watchCharacter(player: Player, character: Model)
	if character:WaitForChild("HumanoidRootPart", 5) then
		character:PivotTo(spawnCFrame)
	end

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end

	humanoid.Died:Connect(function()
		task.delay(Players.RespawnTime, function()
			-- Only the current character's death respawns, and only while the
			-- player is still ready and in the game.
			if ready[player] and player.Parent and player.Character == character then
				player:LoadCharacter()
			end
		end)
	end)
end

local function onPlayerAdded(player: Player)
	if watched[player] then
		return
	end
	watched[player] = true

	player.CharacterAdded:Connect(function(character)
		watchCharacter(player, character)
	end)

	-- In Studio the local player can arrive with a character before this runs.
	local existing = player.Character
	if existing then
		task.spawn(watchCharacter, player, existing)
	end
end

function SpawnService.start(cframe: CFrame)
	spawnCFrame = cframe

	-- Also set in default.project.json, which is what actually closes the
	-- window before this script runs. Kept here so the rule holds even in a
	-- place built some other way.
	Players.CharacterAutoLoads = false

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		ready[player] = nil
		watched[player] = nil
	end)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

-- Moves a living character back to the start room, a little apart from
-- anyone else sent there at the same moment.
function SpawnService.sendToStart(player: Player)
	local character = player.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then
		return
	end

	local spread = CFrame.new((math.random() - 0.5) * 8, 0, (math.random() - 0.5) * 4)
	character:PivotTo(spawnCFrame * spread)
end

-- Called once a player's profile is ready: gives them their first body, and
-- from then on respawns them after each death.
function SpawnService.spawn(player: Player)
	ready[player] = true

	if not player.Character then
		task.spawn(function()
			if player.Parent then
				player:LoadCharacter()
			end
		end)
	end
end

return SpawnService
