--!strict
-- Chests: locked behind a barrier until every guard in their room is dead,
-- then opened, and emptied a piece at a time through a loot menu.
--
-- A chest with no guards is open from the start. Guards in a dungeon don't
-- respawn, so "every guard dead" is also a one-time latch: once unlocked, a
-- chest stays unlocked.
--
-- What's inside is decided when the chest is made, not when it's opened, so a
-- missing loot row fails at dungeon generation instead of in a player's hands.
--
-- Opening shows what's inside rather than pushing it into your bags. You take
-- what you want, one row at a time, and anything you leave stays in the chest
-- for whoever comes next. That matters for three reasons: a full inventory no
-- longer means a chest you daren't open, a party can split a chest without
-- racing for the prompt, and seeing what you found is worth more than a line
-- of text telling you afterwards.
--
-- The chest, not the player, owns its contents, and every take is checked
-- here: the client names a slot, never an item.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local LootTables = require(Shared.LootTables)
local Remotes = require(Shared.Remotes)

local EnemyAI = require(script.Parent.Parent.Combat.EnemyAI)
local CurrencyService = require(script.Parent.Parent.Economy.CurrencyService)
local InventoryService = require(script.Parent.Parent.InventoryService)

local WOOD_COLOR = Color3.fromRGB(110, 70, 40)
local IRON_COLOR = Color3.fromRGB(50, 48, 52)
local GOLD_COLOR = Color3.fromRGB(230, 180, 60)

local BODY_SIZE = Vector3.new(3.2, 1.8, 2.2)
local LID_SIZE = Vector3.new(3.3, 0.7, 2.3)

-- Positive about X tips the lid's front edge up and back over the hinge.
local LID_OPEN_ANGLE = math.rad(105)

local ChestService = {}

-- How far from a chest a take is still honoured. Generous compared with the
-- prompt's own 8 studs, because a player nudged by an enemy mid-menu should
-- not silently stop being able to take what they are looking at.
local REACH = 16

type Slot = {
	descriptor: LootTables.LootDescriptor,
	taken: boolean,
}

type Record = {
	id: string,
	chest: Part,
	slots: { Slot },
	coins: number,
	coinsTaken: boolean,
	-- Set once the chest unlocks. Switched off when nothing is left, so an
	-- emptied chest stops offering to be searched.
	prompt: ProximityPrompt?,
}

local chests: { [string]: Record } = {}

-- How many rows the chest panel still has anything in. Zero means the
-- chest is empty and can close for good.
local function rowsLeft(record: Record): number
	local count = if record.coinsTaken or record.coins <= 0 then 0 else 1
	for _, slot in record.slots do
		if not slot.taken then
			count += 1
		end
	end
	return count
end

-- What the menu draws. Taken rows are sent too, greyed out rather than
-- vanishing, so a row never moves out from under the pointer mid-click.
local function contentsOf(record: Record): { [string]: any }
	local rows = {}
	for index, slot in record.slots do
		table.insert(rows, {
			slot = index,
			itemId = slot.descriptor.itemId,
			name = slot.descriptor.name,
			flavor = slot.descriptor.flavor,
			rarity = slot.descriptor.rarity,
			taken = slot.taken,
		})
	end

	return {
		chestId = record.id,
		coins = record.coins,
		coinsTaken = record.coinsTaken,
		rows = rows,
	}
end

-- An emptied chest stops inviting you over.
local function refreshPrompt(record: Record)
	local prompt = record.prompt
	if not prompt then
		return
	end

	local left = rowsLeft(record)
	prompt.Enabled = left > 0
	prompt.ActionText = if left > 0 then "Search" else "Empty"
end

-- Sends a chest's contents: to one player when they open it, to everyone
-- looking at it when someone takes something out.
local function publish(record: Record, player: Player?)
	local payload = contentsOf(record)
	if player then
		Remotes.get("ChestOpened"):FireClient(player, payload)
	else
		-- Everyone with the menu open sees a row go as someone else takes it.
		Remotes.get("ChestContentsChanged"):FireAllClients(payload)
	end
end

-- Whether the player is still close enough to the chest to take from it.
-- Checked on every take, not just on open: the panel stays up while they
-- walk away.
local function withinReach(player: Player, record: Record): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or not record.chest.Parent then
		return false
	end
	return (root.Position - record.chest.Position).Magnitude <= REACH
end

-- One row, taken. The client names a slot and nothing else: it can't invent
-- an item, take a row twice, or take one from across the dungeon.
local function onTake(player: Player, payload: unknown)
	if type(payload) ~= "table" then
		return
	end

	local request = payload :: { [string]: any }
	local record = if type(request.chestId) == "string" then chests[request.chestId] else nil
	if not record or not withinReach(player, record) then
		return
	end

	if request.coins == true then
		if record.coinsTaken or record.coins <= 0 then
			return
		end
		record.coinsTaken = true
		CurrencyService.grant(player, record.coins, 0)
		publish(record, nil)
		refreshPrompt(record)
		return
	end

	local index = request.slot
	if type(index) ~= "number" then
		return
	end

	local slot = record.slots[index]
	if not slot or slot.taken then
		return
	end

	-- Checked at the moment of taking, not when the chest opened: a full bag
	-- leaves the row where it is rather than eating it.
	if not InventoryService.hasRoom(player) then
		Remotes.get("ChestOpened"):FireClient(player, {
			chestId = record.id,
			inventoryFull = true,
			coins = record.coins,
			coinsTaken = record.coinsTaken,
			rows = contentsOf(record).rows,
		})
		return
	end

	slot.taken = true
	InventoryService.addItem(player, {
		itemId = slot.descriptor.itemId,
		rarity = slot.descriptor.rarity,
		upgradeLevel = 0,
		classTag = slot.descriptor.classTag,
	})
	publish(record, nil)
	refreshPrompt(record)
end

-- Listens for take requests. Chests themselves are built by the dungeon
-- as it generates, not here.
function ChestService.start()
	Remotes.get("ChestTakeItem").OnServerEvent:Connect(onTake)
end

export type ChestSpec = {
	-- Where the chest stands on the floor. Its front (the lock) faces this
	-- CFrame's look direction.
	floorCFrame: CFrame,
	-- Every one must be dead before the chest opens. Empty means unlocked,
	-- unless `startsLocked`.
	guards: { EnemyAI.Enemy },
	-- Locked until the unlock function createChest returns is called, for a
	-- room whose guards don't exist yet (an ambush).
	startsLocked: boolean?,
	-- Every row the chest holds. A list rather than one item so a vault can
	-- be worth walking to.
	loot: { LootTables.LootDescriptor },
	-- Extra coins for whoever opens it.
	coins: number,
	name: string,
	parent: Instance,
}

-- An anchored, non-colliding part of a chest's dressing. Non-colliding so
-- the lid's hinge and the bands never catch a player walking past.
local function decor(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Parent = parent
	return part
end

-- The lid, hinged along the back of the body's top edge. Returns the lid and
-- the hinge it turns about.
local function buildLid(chest: Part): (Part, CFrame)
	local top = chest.CFrame * CFrame.new(0, BODY_SIZE.Y / 2, 0)
	local hinge = top * CFrame.new(0, 0, BODY_SIZE.Z / 2)
	local lid = decor(chest, "Lid", LID_SIZE, hinge * CFrame.new(0, LID_SIZE.Y / 2, -LID_SIZE.Z / 2), WOOD_COLOR, Enum.Material.WoodPlanks)

	-- The iron band and gold lock move with the lid, so they're welded to it.
	local band = decor(lid, "LidBand", Vector3.new(0.35, LID_SIZE.Y + 0.05, LID_SIZE.Z + 0.05), lid.CFrame, IRON_COLOR, Enum.Material.Metal)
	local lock = decor(lid, "Lock", Vector3.new(0.6, 0.6, 0.2), lid.CFrame * CFrame.new(0, -0.25, -LID_SIZE.Z / 2 - 0.1), GOLD_COLOR, Enum.Material.Metal)
	for _, piece in { band, lock } do
		piece.Anchored = false
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = lid
		weld.Part1 = piece
		weld.Parent = piece
	end

	return lid, hinge
end

-- Swings the lid open about its hinge, keeping the lid's offset from that
-- hinge so it turns rather than jumping to a new place.
local function openLid(lid: Part, hinge: CFrame)
	local closedOffset = hinge:ToObjectSpace(lid.CFrame)
	local opened = hinge * CFrame.Angles(LID_OPEN_ANGLE, 0, 0) * closedOffset

	TweenService:Create(lid, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = opened }):Play()
end

-- A shower of gold from the open chest. Emitters switched on and off on the
-- server replicate; a one-shot Emit() would only play on the server.
local function goldBurst(chest: Part)
	local attachment = Instance.new("Attachment")
	attachment.Position = Vector3.new(0, BODY_SIZE.Y / 2, 0)
	attachment.Parent = chest

	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkles.Color = ColorSequence.new(GOLD_COLOR)
	sparkles.LightEmission = 1
	sparkles.Size = NumberSequence.new(0.6, 0)
	sparkles.Lifetime = NumberRange.new(0.6, 1.1)
	sparkles.Speed = NumberRange.new(8, 14)
	sparkles.EmissionDirection = Enum.NormalId.Top
	sparkles.SpreadAngle = Vector2.new(40, 40)
	sparkles.Acceleration = Vector3.new(0, -18, 0)
	sparkles.Rate = 120
	sparkles.Parent = attachment

	task.delay(0.35, function()
		sparkles.Enabled = false
	end)
	task.delay(2, function()
		attachment:Destroy()
	end)
end

-- The sphere that keeps players out of a vault until it is unlocked.
-- A ball rather than a box: a vault door is round, and a box would leave
-- corners a player could stand in.
local function buildBarrier(chest: Part): Part
	local barrier = Instance.new("Part")
	barrier.Name = "Barrier"
	barrier.Shape = Enum.PartType.Ball
	barrier.Anchored = true
	barrier.CanCollide = false
	barrier.CanQuery = false
	barrier.CanTouch = false
	barrier.CastShadow = false
	barrier.Size = Vector3.new(5, 5, 5)
	barrier.CFrame = chest.CFrame * CFrame.new(0, 0.5, 0)
	barrier.Color = Color3.fromRGB(255, 60, 60)
	barrier.Material = Enum.Material.ForceField
	barrier.Parent = chest

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 60, 60)
	light.Brightness = 1
	light.Range = 8
	light.Parent = barrier

	return barrier
end

-- Returns the chest, and a function that unlocks it (safe to call twice).
function ChestService.createChest(spec: ChestSpec): (Part, () -> ())
	assert(#spec.loot > 0, `Chest "{spec.name}" was built with nothing in it`)

	-- The body is the chest: it collides, and carries the prompt once unlocked.
	local chest = Instance.new("Part")
	chest.Name = spec.name
	chest.Anchored = true
	chest.CanCollide = true
	chest.Size = BODY_SIZE
	chest.CFrame = spec.floorCFrame * CFrame.new(0, BODY_SIZE.Y / 2, 0)
	chest.Color = WOOD_COLOR
	chest.Material = Enum.Material.WoodPlanks
	chest.Parent = spec.parent

	for _, x in { -1.1, 1.1 } do
		decor(chest, "Band", Vector3.new(0.35, BODY_SIZE.Y + 0.05, BODY_SIZE.Z + 0.05), chest.CFrame * CFrame.new(x, 0, 0), IRON_COLOR, Enum.Material.Metal)
	end

	local slots: { Slot } = {}
	for _, descriptor in spec.loot do
		table.insert(slots, { descriptor = descriptor, taken = false })
	end

	local record: Record = {
		id = spec.name,
		chest = chest,
		slots = slots,
		coins = spec.coins,
		coinsTaken = spec.coins <= 0,
		prompt = nil,
	}
	assert(chests[record.id] == nil, `Two chests named "{record.id}"`)
	chests[record.id] = record

	local lid, hinge = buildLid(chest)
	local locked = #spec.guards > 0 or spec.startsLocked == true
	local barrier: Part? = if locked then buildBarrier(chest) else nil
	local opened = false
	local unlocked = false

	-- Drops the vault barrier, once. Guarded, because every enemy in the room
	-- dying calls it and only the first should do anything.
	local function unlock()
		if unlocked then
			return
		end
		unlocked = true

		if barrier then
			barrier:Destroy()
			barrier = nil
		end

		-- A warm glow saying "this is yours now".
		local glow = Instance.new("PointLight")
		glow.Name = "UnlockedGlow"
		glow.Color = GOLD_COLOR
		glow.Brightness = 2
		glow.Range = 12
		glow.Parent = lid

		-- No prompt exists until the chest unlocks, so a locked chest simply
		-- cannot be interacted with.
		local prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = "Chest"
		prompt.ActionText = "Open"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 8
		prompt.Parent = chest
		record.prompt = prompt

		-- Opening is not the same as emptying any more, so the prompt stays:
		-- a second player can look inside, and the first can come back for
		-- what they left. It reads "Open" until something has been taken.
		prompt.Triggered:Connect(function(player)
			if not opened then
				opened = true
				openLid(lid, hinge)
				goldBurst(chest)
				glow.Brightness = 0.8
			end

			prompt.ActionText = "Search"
			publish(record, player)
		end)
	end

	if not locked then
		unlock()
		return chest, unlock
	end

	if #spec.guards == 0 then
		return chest, unlock
	end

	local remaining = #spec.guards
	for _, guard in spec.guards do
		local counted = false
		EnemyAI.onDeath(guard, function()
			-- Each guard counts once, even if something revived it.
			if counted then
				return
			end
			counted = true

			remaining -= 1
			if remaining == 0 then
				unlock()
			end
		end)
	end

	return chest, unlock
end

return ChestService
