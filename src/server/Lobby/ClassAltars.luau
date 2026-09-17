--!strict
-- Three altars in the hub's west aisle, one per class. Interacting with one
-- takes up that class: you leave whatever you were carrying on its altar and
-- pick up this one's weapon.
--
-- This replaces the three weapon stands that stood in the old camp. Nothing
-- about how class works changed — a class still *is* the weapon you carry
-- (`Loadout`), and there is still no stored class anywhere — but the altars
-- say so out loud. Standing in front of the Assassin's altar and taking the
-- daggers is the same act as the old "equip Daggers" prompt, and reads like a
-- choice about who you are rather than a choice about loot.
--
-- Diegetic, like the forge and the gates: `ProximityPrompt.Triggered` already
-- fires server-side with the player attached, so choosing a class needs no
-- client-callable remote. Only the outcome goes back to the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Loadout = require(Shared.Loadout)
local Remotes = require(Shared.Remotes)

local EquipService = require(script.Parent.Parent.EquipService)
local Stonework = require(script.Parent.Parent.Stonework)
local WeaponVisuals = require(script.Parent.Parent.WeaponVisuals)
local LobbyService = require(script.Parent.LobbyService)

local ClassAltars = {}

type Altar = {
	weaponId: string,
	accent: Color3,
	-- What the altar says it is for. The class name comes from the weapon.
	creed: string,
	-- How the weapon hangs over the altar: degrees about X (90 stands a
	-- forward-pointing blade upright), and how high its grip floats.
	tilt: number,
	height: number,
}

-- In the order the altars stand down the aisle, south to north.
local ALTARS: { Altar } = {
	{
		weaponId = "SwordAndShield",
		accent = Color3.fromRGB(120, 190, 255),
		creed = "Hold the line",
		tilt = 90,
		height = 1.6,
	},
	{
		weaponId = "Daggers",
		accent = Color3.fromRGB(200, 110, 255),
		creed = "Strike once",
		tilt = 90,
		height = 1.8,
	},
	{
		weaponId = "Staff",
		accent = Color3.fromRGB(110, 255, 170),
		creed = "Keep them standing",
		tilt = 0,
		height = 3.2,
	},
}

local RUNE_SEGMENTS = 10
local RUNE_RADIUS = 4.2

-- The altar itself. `at` stands where the altar goes, looking into the hall —
-- so its local +Z is the wall behind it, and everything the player reads is
-- hung on -Z.
--
-- Returns the plinth, which is the part that collides and carries the prompt.
local function buildAltar(parent: Instance, at: CFrame, altar: Altar, className: string, weaponName: string): Part
	-- Three steps up, each turned a little, so the altar reads as raised
	-- ground rather than a table someone left in the aisle.
	for step = 1, 3 do
		local side = 16 - step * 2.4
		Stonework.part(parent, "AltarStep", Vector3.new(side, 0.55, side), at * CFrame.new(0, 0.275 + (step - 1) * 0.55, 0) * CFrame.Angles(0, math.rad(step * 15), 0), Stonework.TRIM, Enum.Material.Slate)
	end
	local top = at * CFrame.new(0, 1.65, 0)

	-- The stele behind it, carrying the class's mark. Tall enough to be the
	-- thing you see from the far end of the hall, which is how you find your
	-- altar without walking the whole aisle.
	Stonework.decor(parent, "AltarStele", Vector3.new(9, 26, 1.6), top * CFrame.new(0, 13, 3.4), Stonework.WALL_DARK, Enum.Material.Granite)
	Stonework.decor(parent, "AltarSteleTrim", Vector3.new(10.2, 1.0, 2.4), top * CFrame.new(0, 26.2, 3.4), Stonework.TRIM, Enum.Material.Slate)
	Stonework.decor(parent, "AltarSteleFoot", Vector3.new(10.2, 1.0, 2.4), top * CFrame.new(0, 0.5, 3.4), Stonework.TRIM, Enum.Material.Slate)
	local sigil = Stonework.decor(parent, "AltarSigil", Vector3.new(5.4, 5.4, 0.5), top * CFrame.new(0, 16, 2.5) * CFrame.Angles(0, 0, math.rad(45)), altar.accent, Enum.Material.Neon)
	sigil.CastShadow = false
	Stonework.decor(parent, "AltarSigilRing", Vector3.new(7.6, 7.6, 0.3), top * CFrame.new(0, 16, 2.7), Stonework.GOLD, Enum.Material.Metal)

	local steleLight = Instance.new("PointLight")
	steleLight.Color = altar.accent
	steleLight.Brightness = 1.6
	steleLight.Range = 20
	steleLight.Shadows = false
	steleLight.Parent = sigil

	-- Braziers either side, burning in the class's colour.
	for _, sign in { -1, 1 } do
		Stonework.brazier(parent, at * CFrame.new(sign * 8.5, 0, 1.5), altar.accent, 0.9, false)
	end

	-- The plinth: the station itself. It collides, and it is what carries the
	-- prompt; everything else on the altar is dressing.
	local plinth = Stonework.part(parent, `{className}Altar`, Vector3.new(4.4, 3.4, 3.6), top * CFrame.new(0, 1.7, 0), Stonework.PILLAR, Enum.Material.Granite)
	Stonework.decor(parent, "AltarPlinthCap", Vector3.new(5.4, 0.5, 4.6), plinth.CFrame * CFrame.new(0, 1.7, 0), Stonework.TRIM, Enum.Material.Slate)
	Stonework.decor(parent, "AltarPlinthFoot", Vector3.new(5.4, 0.5, 4.6), plinth.CFrame * CFrame.new(0, -1.7, 0), Stonework.TRIM, Enum.Material.Slate)
	Stonework.decor(parent, "AltarInlay", Vector3.new(4.0, 0.12, 3.2), plinth.CFrame * CFrame.new(0, 1.98, 0), altar.accent, Enum.Material.Neon).CastShadow = false

	-- A ring of runes turning in the air over the plinth, at the height the
	-- weapon floats. Ten short bars on a circle: at this size nobody reads a
	-- circle as ten bars, they read it as a ring.
	local runeAt = plinth.CFrame * CFrame.new(0, 2.6 + altar.height, 0)
	for index = 1, RUNE_SEGMENTS do
		local angle = index * 2 * math.pi / RUNE_SEGMENTS
		local side = 2 * RUNE_RADIUS * math.tan(math.pi / RUNE_SEGMENTS)
		Stonework.decor(
			parent,
			"AltarRune",
			Vector3.new(side * 0.7, 0.18, 0.5),
			runeAt * CFrame.Angles(0, -angle, 0) * CFrame.new(0, 0, RUNE_RADIUS),
			altar.accent,
			Enum.Material.Neon
		).CastShadow = false
	end

	local weaponLight = Instance.new("PointLight")
	weaponLight.Color = altar.accent
	weaponLight.Brightness = 2.0
	weaponLight.Range = 18
	weaponLight.Shadows = false
	weaponLight.Parent = plinth

	-- The weapon itself, hanging over the plinth: the choice, shown rather
	-- than named.
	local display = WeaponVisuals.buildDisplay(altar.weaponId, plinth.CFrame * CFrame.new(0, 2.6 + altar.height, 0) * CFrame.Angles(math.rad(altar.tilt), 0, 0))
	if display then
		display.Parent = plinth
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = `Altar of the {className}`
	prompt.ActionText = `Take up the {weaponName}`
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.Parent = plinth

	return plinth
end

-- `anchors` come from LobbyBuilder, one per altar, in the same order as
-- ALTARS. Fewer anchors than altars would silently drop a class, so the count
-- is asserted rather than trusted.
function ClassAltars.start(anchors: { CFrame })
	assert(#anchors >= #ALTARS, `The hub gave {#anchors} altar anchors; {#ALTARS} classes need one each`)

	local folder = Instance.new("Folder")
	folder.Name = "ClassAltars"
	folder.Parent = Workspace

	for index, altar in ALTARS do
		local def = Loadout.getDef(altar.weaponId)
		local plinth = buildAltar(folder, anchors[index], altar, def.classTag, def.displayName)

		local prompt = plinth:FindFirstChildOfClass("ProximityPrompt") :: ProximityPrompt
		local weaponId = altar.weaponId
		local creed = altar.creed

		prompt.Triggered:Connect(function(player)
			-- You carry one weapon, and you change it in the hub or not at
			-- all. The altars only stand here, so reaching one already means
			-- being in the hub — but the rule is checked rather than assumed,
			-- so it survives anyone later putting an altar somewhere else.
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root or not root:IsA("BasePart") or not LobbyService.isInside(root.Position) then
				Remotes.get("DungeonNotice"):FireClient(player, {
					text = "You can only change class in the hub",
					tone = "bad",
				})
				return
			end

			local previous = EquipService.getWeaponId(player)
			if previous == weaponId then
				return
			end

			if not EquipService.setWeapon(player, weaponId) then
				return
			end

			-- Swapping returns the old weapon to its own altar rather than
			-- adding to a collection: one weapon, always.
			local text = if previous
				then `You lay down the {Loadout.getDef(previous).displayName} and take up the {def.displayName}. {creed}.`
				else `You take up the {def.displayName}. {creed}.`
			Remotes.get("DungeonNotice"):FireClient(player, { text = text, tone = "good" })
		end)
	end
end

return ClassAltars
