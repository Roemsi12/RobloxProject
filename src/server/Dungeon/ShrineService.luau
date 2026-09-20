--!strict
-- The shrine before the boss: a fountain that heals a player to full, once
-- per player per dungeon.
--
-- Placed right before the boss so a party walks into the fight at full
-- health however the dungeon went — the boss is the test, not the attrition
-- on the way. Once per player, so it can't be used mid-fight by running out
-- and back.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Characters = require(script.Parent.Parent.Combat.Characters)

local ShrineService = {}

local STONE = Color3.fromRGB(150, 146, 140)
local WATER = Color3.fromRGB(80, 230, 210)

-- One anchored part of a shrine.
local function part(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

-- Builds the fountain with its floor centre at `floorCFrame`.
function ShrineService.build(floorCFrame: CFrame, parent: Instance)
	local base = part(parent, "ShrineBasin", Vector3.new(1.2, 7, 7), floorCFrame * CFrame.new(0, 0.6, 0) * CFrame.Angles(0, 0, math.rad(90)), STONE, Enum.Material.Marble, Enum.PartType.Cylinder)

	local water = part(base, "Water", Vector3.new(0.2, 6, 6), floorCFrame * CFrame.new(0, 1.15, 0) * CFrame.Angles(0, 0, math.rad(90)), WATER, Enum.Material.Neon, Enum.PartType.Cylinder)
	water.CanCollide = false
	water.Transparency = 0.25

	local column = part(base, "Column", Vector3.new(1, 3.5, 1), floorCFrame * CFrame.new(0, 2.9, 0), STONE, Enum.Material.Marble)
	local orb = part(base, "Orb", Vector3.new(1.4, 1.4, 1.4), floorCFrame * CFrame.new(0, 5.2, 0), WATER, Enum.Material.Neon, Enum.PartType.Ball)
	orb.CanCollide = false
	column.CanCollide = false

	local light = Instance.new("PointLight")
	light.Color = WATER
	light.Brightness = 2.5
	light.Range = 20
	light.Parent = orb

	local motes = Instance.new("ParticleEmitter")
	motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	motes.Color = ColorSequence.new(WATER)
	motes.LightEmission = 1
	motes.Size = NumberSequence.new(0.35, 0)
	motes.Lifetime = NumberRange.new(1.5, 2.5)
	motes.Speed = NumberRange.new(0.5, 1.5)
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.Acceleration = Vector3.new(0, 1.5, 0)
	motes.Rate = 6
	motes.Parent = orb

	local used: { [Player]: boolean } = {}

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = "Shrine"
	prompt.ActionText = "Drink"
	prompt.HoldDuration = 0.6
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = base

	prompt.Triggered:Connect(function(player)
		if used[player] then
			Remotes.get("DungeonNotice"):FireClient(player, {
				text = "The shrine has nothing more to give you",
				tone = "bad",
			})
			return
		end

		local humanoid = Characters.getHumanoid(player)
		if not humanoid or humanoid.Health <= 0 then
			return
		end

		used[player] = true
		local healed = humanoid.MaxHealth - humanoid.Health
		humanoid.Health = humanoid.MaxHealth

		-- The same feedback as a burst heal: vignette, motes, sound.
		Remotes.get("HealBurst"):FireClient(player, { amount = healed, healerName = "Shrine" })
		Remotes.get("DungeonNotice"):FireClient(player, {
			text = "The shrine restores you",
			tone = "good",
		})
	end)
end

return ShrineService
