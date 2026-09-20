--!strict
-- The blacksmith: a physical anvil in the hub that upgrades whichever weapon
-- the player has equipped, for coins plus class crystals at the higher tiers.
--
-- Diegetic rather than a shop menu, matching the class altars:
-- ProximityPrompt.Triggered already fires server-side with the player, so the
-- interaction needs no client-callable remote into spending currency. Only the
-- outcome goes back to the client.
--
-- Owns the economy half of upgrading: it decides the price and takes payment,
-- then hands off to EquipService, which owns weapon state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local EconomyDefs = require(Shared.EconomyDefs)
local Loadout = require(Shared.Loadout)
local Palette = require(Shared.Palette)
local Remotes = require(Shared.Remotes)

local EquipService = require(script.Parent.Parent.EquipService)
local CurrencyService = require(script.Parent.CurrencyService)

local BlacksmithService = {}

export type UpgradeOutcome = {
	success: boolean,
	-- Player-facing reason on failure. The client renders it; it never
	-- computes the price itself.
	reason: string?,
	newLevel: number?,
}

-- Attempts one upgrade of whatever the player is carrying, and says what
-- happened. Charges only on success; every refusal — nothing equipped,
-- already maxed, not enough materials — comes back as its own outcome so
-- the client can say which.
function BlacksmithService.tryUpgrade(player: Player): UpgradeOutcome
	local weaponId = EquipService.getWeaponId(player)
	if not weaponId then
		return { success = false, reason = "Equip a weapon first" }
	end

	local level = EquipService.getUpgradeLevel(player, weaponId)
	if level >= EconomyDefs.MAX_UPGRADE_LEVEL then
		return { success = false, reason = "Already at max upgrade level" }
	end

	local cost = EconomyDefs.getUpgradeCost(level)
	local class = Loadout.classOf(weaponId)

	if not CurrencyService.trySpend(player, cost.coins, class, cost.crystals) then
		local reason = if cost.crystals > 0
			then string.format("Need %d coins and %d %s crystals", cost.coins, cost.crystals, class)
			else string.format("Need %d coins", cost.coins)
		return { success = false, reason = reason }
	end

	return { success = true, newLevel = EquipService.applyUpgrade(player, weaponId) }
end

-- A palette colour ({0-255, 0-255, 0-255}) as a Color3.
local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local IRON = rgb(Palette.IRON)
local RUST = rgb(Palette.RUST)
local STONE = rgb(Palette.PILLAR)
local TRIM = rgb(Palette.TRIM)
local TIMBER = rgb(Palette.OAK)
local DARK_TIMBER = rgb(Palette.shade(Palette.OAK, 0.6))
local THATCH = rgb(Palette.shade(Palette.ROPE, 0.75))
local EMBER = rgb(Palette.TORCH_EMBER)

-- One anchored, non-colliding part of the forge's structure.
local function piece(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
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

-- The forge itself: a brick hearth with a hood and a chimney, burning hot
-- enough to light this whole corner of the hub. This is the warmest light in
-- the game, on purpose: the hall around it is lit by a sun it cannot reach and
-- by fires that are all colder than this one.
local function buildForge(parent: Instance, at: CFrame)
	local hearth = piece(parent, "Forge", Vector3.new(4.5, 2.6, 3), at * CFrame.new(0, 1.3, 0), STONE, Enum.Material.Brick)
	hearth.CanCollide = true
	hearth.CanQuery = true

	piece(parent, "ForgeLip", Vector3.new(5, 0.4, 3.5), at * CFrame.new(0, 2.7, 0), TRIM, Enum.Material.Slate)
	local coals = piece(parent, "Coals", Vector3.new(3.2, 0.3, 2.2), at * CFrame.new(0, 2.9, 0), EMBER, Enum.Material.Neon)

	-- The hood and chimney carrying the smoke up through the roof.
	piece(parent, "ForgeHood", Vector3.new(4.8, 2.2, 3.2), at * CFrame.new(0, 5.4, 0.6), STONE, Enum.Material.Brick)
	piece(parent, "ForgeChimney", Vector3.new(2.4, 6, 2.4), at * CFrame.new(0, 9, 1.2), STONE, Enum.Material.Brick)
	piece(parent, "ForgeChimneyCap", Vector3.new(3, 0.5, 3), at * CFrame.new(0, 12.1, 1.2), TRIM, Enum.Material.Slate)

	-- The bellows beside it.
	piece(parent, "Bellows", Vector3.new(1.4, 0.8, 2.4), at * CFrame.new(-3.2, 2.2, 0.4), DARK_TIMBER, Enum.Material.Wood)
	piece(parent, "BellowsNozzle", Vector3.new(0.4, 0.4, 1.2), at * CFrame.new(-2.2, 2.2, -0.9), IRON, Enum.Material.Metal)
	piece(parent, "BellowsHandle", Vector3.new(0.25, 0.25, 2), at * CFrame.new(-3.2, 3.0, 1.4) * CFrame.Angles(math.rad(18), 0, 0), TIMBER, Enum.Material.Wood)

	local fire = Instance.new("Fire")
	fire.Size = 5
	fire.Heat = 10
	fire.Color = Color3.fromRGB(255, 150, 50)
	fire.SecondaryColor = Color3.fromRGB(190, 40, 10)
	fire.Parent = coals

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 70)
	light.Brightness = 4
	light.Range = 34
	light.Shadows = true
	light.Parent = coals
end

-- A rack of finished blades against the back wall: the shop's stock, and the
-- quickest way to say "weapons are made here" without a sign.
local function buildRack(parent: Instance, at: CFrame)
	piece(parent, "RackPost", Vector3.new(0.3, 4, 0.3), at * CFrame.new(-2.4, 2, 0), DARK_TIMBER, Enum.Material.Wood)
	piece(parent, "RackPostFar", Vector3.new(0.3, 4, 0.3), at * CFrame.new(2.4, 2, 0), DARK_TIMBER, Enum.Material.Wood)
	piece(parent, "RackRail", Vector3.new(5.2, 0.3, 0.3), at * CFrame.new(0, 3.6, 0), DARK_TIMBER, Enum.Material.Wood)
	piece(parent, "RackShelf", Vector3.new(5.2, 0.3, 1.0), at * CFrame.new(0, 0.6, 0), DARK_TIMBER, Enum.Material.Wood)

	-- Four blades leaning on the rail at slightly different angles.
	for index = 0, 3 do
		local x = -1.8 + index * 1.2
		local lean = math.rad(-8 + index * 5)
		local blade = at * CFrame.new(x, 1.9, 0.1) * CFrame.Angles(0, 0, lean)
		piece(parent, "RackBlade", Vector3.new(0.12, 2.8, 0.34), blade, rgb(Palette.DARK_STEEL), Enum.Material.Metal)
		piece(parent, "RackGuard", Vector3.new(0.8, 0.16, 0.2), blade * CFrame.new(0, -1.2, 0), RUST, Enum.Material.Metal)
		piece(parent, "RackGrip", Vector3.new(0.18, 0.7, 0.18), blade * CFrame.new(0, -1.7, 0), rgb(Palette.DARK_LEATHER), Enum.Material.Fabric)
	end
end

-- The shop around the anvil: a stone footing, timber posts, a pitched roof,
-- the forge, a rack of blades, a quench trough and a hanging sign.
--
-- `at` looks out of the shop's open front, so its local -Z is the way in and
-- +Z is the back wall.
local function buildShop(parent: Instance, at: CFrame)
	piece(parent, "ShopFloor", Vector3.new(15, 0.4, 12), at * CFrame.new(0, 0.2, 1), TRIM, Enum.Material.Slate).CanCollide = true
	piece(parent, "ShopBackWall", Vector3.new(15, 8, 0.8), at * CFrame.new(0, 4, 6.6), STONE, Enum.Material.Brick).CanCollide = true

	-- Corner posts and the beams they carry.
	for _, x in { -7, 7 } do
		for _, z in { -4.4, 6.2 } do
			piece(parent, "ShopPost", Vector3.new(0.9, 8, 0.9), at * CFrame.new(x, 4, z), DARK_TIMBER, Enum.Material.Wood)
		end
		piece(parent, "ShopBeam", Vector3.new(0.7, 0.7, 11), at * CFrame.new(x, 8.2, 1), DARK_TIMBER, Enum.Material.Wood)
	end
	piece(parent, "ShopLintel", Vector3.new(15, 0.8, 0.8), at * CFrame.new(0, 8.2, -4.4), DARK_TIMBER, Enum.Material.Wood)

	-- A pitched roof, open at the gable ends so the forge light spills out.
	for _, sign in { -1, 1 } do
		piece(
			parent,
			"ShopRoof",
			Vector3.new(15.6, 0.5, 7.4),
			at * CFrame.new(0, 9.7, 1 + sign * 3.1) * CFrame.Angles(math.rad(sign * 26), 0, 0),
			THATCH,
			Enum.Material.WoodPlanks
		)
	end
	piece(parent, "ShopRidge", Vector3.new(15.8, 0.6, 0.9), at * CFrame.new(0, 11.4, 1), DARK_TIMBER, Enum.Material.Wood)

	buildForge(parent, at * CFrame.new(4.6, 0.4, 4.2))
	buildRack(parent, at * CFrame.new(-4.6, 0.4, 6.0))

	-- The quench trough, and a barrel of billets.
	piece(parent, "Trough", Vector3.new(3.4, 1.4, 1.8), at * CFrame.new(-5.4, 1.1, 1.4), DARK_TIMBER, Enum.Material.Wood)
	piece(parent, "TroughWater", Vector3.new(3.0, 0.2, 1.4), at * CFrame.new(-5.4, 1.75, 1.4), Color3.fromRGB(46, 62, 66), Enum.Material.Glass).Transparency = 0.35
	piece(parent, "Barrel", Vector3.new(1.7, 2.4, 1.7), at * CFrame.new(6.2, 1.6, -2.6), rgb(Palette.ROT_WOOD), Enum.Material.WoodPlanks)
	for _, y in { 1.0, 2.2 } do
		piece(parent, "BarrelHoop", Vector3.new(1.85, 0.25, 1.85), at * CFrame.new(6.2, y, -2.6), RUST, Enum.Material.Metal)
	end

	-- The sign: a hammer crossed over an anvil, hung from the lintel.
	piece(parent, "SignChain", Vector3.new(0.12, 1.2, 0.12), at * CFrame.new(0, 7.5, -4.6), IRON, Enum.Material.Metal)
	piece(parent, "SignBoard", Vector3.new(4.4, 2.2, 0.3), at * CFrame.new(0, 6.0, -4.6), DARK_TIMBER, Enum.Material.Wood)
	piece(parent, "SignAnvil", Vector3.new(2.2, 0.5, 0.15), at * CFrame.new(0, 5.6, -4.8), IRON, Enum.Material.Metal)
	piece(parent, "SignAnvilWaist", Vector3.new(0.8, 0.5, 0.15), at * CFrame.new(0, 5.2, -4.8), IRON, Enum.Material.Metal)
	piece(parent, "SignHammer", Vector3.new(2.6, 0.3, 0.15), at * CFrame.new(0, 6.5, -4.8) * CFrame.Angles(0, 0, math.rad(-22)), RUST, Enum.Material.Metal)
	piece(parent, "SignHammerHead", Vector3.new(0.7, 0.8, 0.2), at * CFrame.new(1.1, 6.95, -4.8), IRON, Enum.Material.Metal)
end

-- The anvil itself: the station that carries the prompt, on its stump.
local function dressAnvil(anvil: Part)
	local base = anvil.CFrame * CFrame.new(0, -anvil.Size.Y / 2, 0)
	piece(anvil, "Stump", Vector3.new(2.6, 1.4, 2.0), base * CFrame.new(0, 0.7, 0), DARK_TIMBER, Enum.Material.Wood)
	piece(anvil, "Waist", Vector3.new(1.4, 0.8, 1.0), base * CFrame.new(0, 1.8, 0), IRON, Enum.Material.Metal)
	piece(anvil, "Face", Vector3.new(3.4, 0.6, 1.4), base * CFrame.new(0, 2.5, 0), IRON, Enum.Material.Metal)
	piece(anvil, "Horn", Vector3.new(1.0, 0.4, 0.8), base * CFrame.new(2.1, 2.55, 0), IRON, Enum.Material.Metal)

	local hammerAt = base * CFrame.new(-0.6, 2.95, 0) * CFrame.Angles(0, math.rad(25), 0)
	piece(anvil, "HammerHandle", Vector3.new(0.2, 0.2, 1.8), hammerAt, TIMBER, Enum.Material.Wood)
	piece(anvil, "HammerHead", Vector3.new(0.5, 0.5, 0.9), hammerAt * CFrame.new(0, 0.05, -0.9) * CFrame.Angles(0, math.rad(90), 0), IRON, Enum.Material.Metal)
	piece(anvil, "Tongs", Vector3.new(0.18, 0.18, 2.2), base * CFrame.new(1.0, 2.9, 0.3) * CFrame.Angles(0, math.rad(-40), 0), IRON, Enum.Material.Metal)
end

-- `shopAt` is where the forge stands, looking out of its own open front. The
-- hub decides that, the way it decides where the altars and the gates go.
function BlacksmithService.start(shopAt: CFrame)
	local shop = Instance.new("Folder")
	shop.Name = "Blacksmith"
	shop.Parent = Workspace

	buildShop(shop, shopAt)

	-- The anvil's iron body is the station itself: it collides and carries
	-- the prompt. The rest is dressing.
	local anvil = Instance.new("Part")
	anvil.Name = "Anvil"
	anvil.Anchored = true
	anvil.CanCollide = true
	anvil.Size = Vector3.new(2.4, 1.4, 1.8)
	anvil.Color = STONE
	anvil.Material = Enum.Material.Slate
	anvil.Transparency = 1
	anvil.CFrame = shopAt * CFrame.new(0, 1.1, 1.5)
	anvil.Parent = shop
	dressAnvil(anvil)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = "Blacksmith"
	prompt.ActionText = "Upgrade Weapon"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.Parent = anvil

	prompt.Triggered:Connect(function(player)
		local outcome = BlacksmithService.tryUpgrade(player)
		Remotes.get("UpgradeResult"):FireClient(player, outcome)
	end)
end

return BlacksmithService
