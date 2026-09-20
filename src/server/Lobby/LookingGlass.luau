--!strict
-- The looking glass: a standing mirror in the hub's east aisle, opposite the
-- class altars. Interacting with it opens the character editor.
--
-- Diegetic, like the altars and the forge. `ProximityPrompt.Triggered` fires
-- server-side with the player attached, so opening the editor needs no
-- client-callable remote of its own — the client is told to open, it never
-- asks. That matters more here than it looks: the editor is the one screen
-- that writes to a saved profile, and a remote a client could fire at will is
-- a remote that can be fired from inside a dungeon, mid-parry.
--
-- The glass itself is not a real reflection. Roblox has no mirrors; what reads
-- as one is a dark polished slab with a faint highlight and a frame heavy
-- enough that the eye takes it for a mirror and stops asking.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Palette = require(ReplicatedStorage.Shared.Palette)

local AppearanceService = require(script.Parent.Parent.AppearanceService)
local Stonework = require(script.Parent.Parent.Stonework)
local LobbyService = require(script.Parent.LobbyService)

local LookingGlass = {}

local GLASS_HEIGHT = 9
local GLASS_WIDTH = 5
local FRAME = 0.55

-- A palette colour ({0-255, 0-255, 0-255}) as a Color3.
local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

-- Builds the mirror and its prompt. The prompt opens the character editor
-- on that player's client, and refuses outside the hub — nothing that
-- edits a profile happens mid-run.
function LookingGlass.start(anchor: CFrame)
	local model = Instance.new("Model")
	model.Name = "LookingGlass"

	local trim = rgb(Palette.GOLD)
	local dark = rgb(Palette.VOID)

	-- Backed against the wall, so the frame is what stands proud of it and the
	-- glass sits in shadow behind.
	local base = anchor * CFrame.new(0, 0, -0.6)

	Stonework.part(model, "GlassPlinth", Vector3.new(GLASS_WIDTH + 2.4, 1.2, 3), base * CFrame.new(0, 0.6, 0), rgb(Palette.PILLAR), Enum.Material.Granite)
	Stonework.decor(model, "GlassPlinthCap", Vector3.new(GLASS_WIDTH + 3, 0.4, 3.6), base * CFrame.new(0, 1.35, 0), trim, Enum.Material.Metal)

	local glassMid = 1.2 + GLASS_HEIGHT / 2

	-- The glass: dark, polished, barely reflective. Glass proper would show
	-- the empty void behind the wall, which is worse than not reflecting.
	local glass = Stonework.decor(
		model,
		"Glass",
		Vector3.new(GLASS_WIDTH, GLASS_HEIGHT, 0.3),
		base * CFrame.new(0, glassMid, 0.6),
		dark,
		Enum.Material.Glass
	)
	glass.Reflectance = 0.35

	-- A highlight down one side, which is what actually sells it as a surface
	-- rather than a hole.
	local sheen = Stonework.decor(
		model,
		"GlassSheen",
		Vector3.new(1.1, GLASS_HEIGHT - 1.4, 0.1),
		base * CFrame.new(-GLASS_WIDTH / 4, glassMid + 0.3, 0.46),
		rgb(Palette.STEEL),
		Enum.Material.Neon
	)
	sheen.Transparency = 0.86

	-- The frame.
	for _, side in { -1, 1 } do
		Stonework.decor(model, "GlassFrameSide", Vector3.new(FRAME, GLASS_HEIGHT + FRAME * 2, 0.7), base * CFrame.new(side * (GLASS_WIDTH / 2 + FRAME / 2), glassMid, 0.55), trim, Enum.Material.Metal)
	end
	Stonework.decor(model, "GlassFrameTop", Vector3.new(GLASS_WIDTH + FRAME * 2, FRAME, 0.7), base * CFrame.new(0, glassMid + GLASS_HEIGHT / 2 + FRAME / 2, 0.55), trim, Enum.Material.Metal)
	Stonework.decor(model, "GlassFrameFoot", Vector3.new(GLASS_WIDTH + FRAME * 2, FRAME, 0.7), base * CFrame.new(0, glassMid - GLASS_HEIGHT / 2 - FRAME / 2, 0.55), trim, Enum.Material.Metal)

	-- A crest over the top, so it reads as a fixture of the hall rather than
	-- furniture someone left there.
	Stonework.decor(model, "GlassCrest", Vector3.new(2.2, 1.4, 0.5), base * CFrame.new(0, glassMid + GLASS_HEIGHT / 2 + 1.5, 0.55), trim, Enum.Material.Metal)
	Stonework.decor(model, "GlassCrestWingRight", Vector3.new(1.6, 0.5, 0.45), base * CFrame.new(1.7, glassMid + GLASS_HEIGHT / 2 + 1.1, 0.55), trim, Enum.Material.Metal)
	Stonework.decor(model, "GlassCrestWingLeft", Vector3.new(1.6, 0.5, 0.45), base * CFrame.new(-1.7, glassMid + GLASS_HEIGHT / 2 + 1.1, 0.55), trim, Enum.Material.Metal)

	-- Its own light, aimed at whoever stands in front of it. Shadowless: the
	-- hall already rations shadow-casting lights, and this one exists to show
	-- a face rather than to fall across the floor.
	local lamp = Instance.new("PointLight")
	lamp.Brightness = 1.6
	lamp.Range = 16
	lamp.Color = rgb(Palette.TORCH_FIRE)
	lamp.Shadows = false
	lamp.Parent = glass

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Look at yourself"
	prompt.ObjectText = "Looking Glass"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = glass

	prompt.Triggered:Connect(function(player)
		-- In the hall or not at all, for the same reason the forge and the
		-- altars check: nothing that edits a profile happens mid-run.
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and not LobbyService.isInside(root.Position) then
			return
		end

		AppearanceService.openEditor(player)
	end)

	model.Parent = Workspace
end

return LookingGlass
