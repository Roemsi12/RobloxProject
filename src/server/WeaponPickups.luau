--!strict
-- Three physical weapon stands in the start room — not a menu. Interacting
-- with one equips that weapon, and a different one can be picked up freely
-- later: the real cost of respeccing comes from class-specific crystals, not a
-- lock (DESIGN.md).
--
-- ProximityPrompt.Triggered fires on the server with the player already
-- attached, so equipping needs no RemoteEvent and adds no client-callable
-- path. Each stand shows the weapon it gives (WeaponVisuals), lit in its
-- class's colour, so the choice reads from across the room.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Loadout = require(Shared.Loadout)
local Remotes = require(Shared.Remotes)

local DungeonService = require(script.Parent.Dungeon.DungeonService)
local EquipService = require(script.Parent.EquipService)
local WeaponVisuals = require(script.Parent.WeaponVisuals)

local WeaponPickups = {}

local PEDESTAL_SIZE = Vector3.new(2.4, 3, 2.4)

type Stand = {
	weaponId: string,
	accent: Color3,
	-- The pedestal's centre, from the start room's origin.
	offset: Vector3,
	-- How the weapon is posed above the pedestal: degrees about X (90 stands a
	-- forward-pointing blade upright), and how high its grip floats.
	tilt: number,
	height: number,
}

local STANDS: { Stand } = {
	{ weaponId = "SwordAndShield", accent = Color3.fromRGB(120, 190, 255), offset = Vector3.new(-6, 1.5, 5), tilt = 90, height = 1.0 },
	{ weaponId = "Daggers", accent = Color3.fromRGB(200, 110, 255), offset = Vector3.new(0, 1.5, 5), tilt = 90, height = 1.2 },
	{ weaponId = "Staff", accent = Color3.fromRGB(110, 255, 170), offset = Vector3.new(6, 1.5, 5), tilt = 0, height = 2.6 },
}

local function makePedestal(stand: Stand, originCFrame: CFrame): Part
	local pedestal = Instance.new("Part")
	pedestal.Name = `{stand.weaponId}Pickup`
	pedestal.Size = PEDESTAL_SIZE
	pedestal.Anchored = true
	pedestal.CanCollide = true
	pedestal.Material = Enum.Material.Slate
	pedestal.Color = Color3.fromRGB(70, 66, 72)
	pedestal.CFrame = originCFrame * CFrame.new(stand.offset)
	pedestal.Parent = Workspace

	-- A glowing inlay on top, in the class's colour.
	local inlay = Instance.new("Part")
	inlay.Name = "Inlay"
	inlay.Size = Vector3.new(PEDESTAL_SIZE.X - 0.5, 0.1, PEDESTAL_SIZE.Z - 0.5)
	inlay.Anchored = true
	inlay.CanCollide = false
	inlay.CanQuery = false
	inlay.Material = Enum.Material.Neon
	inlay.Color = stand.accent
	inlay.CFrame = pedestal.CFrame * CFrame.new(0, PEDESTAL_SIZE.Y / 2 + 0.05, 0)
	inlay.Parent = pedestal

	local light = Instance.new("PointLight")
	light.Color = stand.accent
	light.Brightness = 1.5
	light.Range = 10
	light.Parent = inlay

	return pedestal
end

function WeaponPickups.start(originCFrame: CFrame)
	for _, stand in STANDS do
		local def = Loadout.getDef(stand.weaponId)
		local pedestal = makePedestal(stand, originCFrame)

		local displayCFrame = pedestal.CFrame
			* CFrame.new(0, PEDESTAL_SIZE.Y / 2 + stand.height, 0)
			* CFrame.Angles(math.rad(stand.tilt), 0, 0)
		local display = WeaponVisuals.buildDisplay(stand.weaponId, displayCFrame)
		if display then
			display.Parent = pedestal
		end

		local prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = `{def.displayName} ({def.classTag})`
		prompt.ActionText = "Equip"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 8
		prompt.Parent = pedestal

		local weaponId = stand.weaponId
		prompt.Triggered:Connect(function(player)
			-- You carry one weapon, and you change it in camp or not at all.
			-- The stands only stand here, so reaching one already means being
			-- in camp — but the rule is checked rather than assumed, so it
			-- survives anyone later putting a stand somewhere else.
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root or not root:IsA("BasePart") or not DungeonService.isInCamp(root.Position) then
				Remotes.get("DungeonNotice"):FireClient(player, {
					text = "You can only change weapons in camp",
					tone = "bad",
				})
				return
			end

			local previous = EquipService.getWeaponId(player)
			if previous == weaponId then
				return
			end

			if EquipService.setWeapon(player, weaponId) then
				local taken = Loadout.getDef(weaponId).displayName
				-- Swapping returns the old weapon to its stand rather than
				-- adding to a collection: one weapon, always.
				local text = if previous
					then `You leave the {Loadout.getDef(previous).displayName} and take the {taken}`
					else `You take the {taken}`
				Remotes.get("DungeonNotice"):FireClient(player, { text = text, tone = "good" })
			end
		end)
	end
end

return WeaponPickups
