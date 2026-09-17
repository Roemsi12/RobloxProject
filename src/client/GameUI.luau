--!strict
-- Player-facing feedback: damage and heal flashes, equipped weapon, currency,
-- loot and upgrade messages, the inventory panel (I), and duel status.
--
-- Separate from DebugHUD on purpose. DebugHUD is a tuning instrument that
-- goes away at build-order step 10; this is the game's actual UI, kept as
-- plain labels until then. It renders what the server reports and never
-- computes an outcome itself.
--
-- Laid out to stay clear of DebugHUD, which owns the top-left corner.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CombatConstants = require(Shared.CombatConstants)
local DungeonDefs = require(Shared.DungeonDefs)
local LootTables = require(Shared.LootTables)
local Loadout = require(Shared.Loadout)
local PostureMath = require(Shared.PostureMath)
local Remotes = require(Shared.Remotes)

local GameUI = {}

local POSTURE_CALM = Color3.fromRGB(235, 195, 80)
local POSTURE_DANGER = Color3.fromRGB(255, 90, 50)
local POSTURE_BROKEN = Color3.fromRGB(255, 60, 50)

-- The local player's weapon, for its critical's cooldown.
local currentWeaponId: string? = nil

local INVENTORY_ACTION = "ToggleInventory"

local GOLD = Color3.fromRGB(255, 215, 0)
local GOOD = Color3.fromRGB(120, 255, 120)
local BAD = Color3.fromRGB(255, 120, 120)
local DUEL = Color3.fromRGB(200, 200, 255)

-- Inventory rows are coloured by rarity, so a good find stands out.
local RARITY_COLORS: { [string]: Color3 } = {
	common = Color3.fromRGB(225, 225, 225),
	uncommon = Color3.fromRGB(110, 230, 120),
	rare = Color3.fromRGB(90, 160, 255),
	epic = Color3.fromRGB(200, 110, 255),
}

-- itemId -> display name, from the same shared LootTables the server built the
-- item from (an ItemInstance carries no name of its own).
local ITEM_NAMES: { [string]: string } = {}
for _, descriptor in LootTables do
	ITEM_NAMES[descriptor.itemId] = descriptor.name
end
ITEM_NAMES[DungeonDefs.TREASURE_LOOT.itemId] = DungeonDefs.TREASURE_LOOT.name

-- DungeonNotice tones.
local NOTICE_COLORS: { [string]: Color3 } = {
	good = Color3.fromRGB(120, 255, 140),
	bad = Color3.fromRGB(255, 120, 120),
	info = Color3.fromRGB(220, 220, 235),
	danger = Color3.fromRGB(140, 200, 255),
	victory = Color3.fromRGB(255, 215, 90),
}

local PANEL_COLOR = Color3.fromRGB(18, 16, 22)
local PANEL_EDGE = Color3.fromRGB(120, 100, 70)

-- Rounded corners and a thin warm edge: one look for every panel.
local function stylePanel(frame: GuiObject)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = PANEL_EDGE
	stroke.Transparency = 0.35
	stroke.Thickness = 1.5
	stroke.Parent = frame
end

local function makeLabel(parent: Instance, size: UDim2, position: UDim2, textSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = size
	label.Position = position
	label.BackgroundColor3 = PANEL_COLOR
	label.BackgroundTransparency = 0.25
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.TextSize = textSize
	label.Parent = parent
	stylePanel(label)
	return label
end

-- A quick swell and settle, to draw the eye to a value that just changed.
local function bump(label: GuiObject)
	local scale = label:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = label
	end
	local uiScale = scale :: UIScale
	uiScale.Scale = 1.15
	TweenService:Create(uiScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- A transparent label that fades in with a message and back out.
local function makeFlashLabel(parent: Instance, position: UDim2): (string, Color3, number) -> ()
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(420, 32)
	label.Position = position
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.BackgroundTransparency = 1
	label.TextTransparency = 1
	label.TextStrokeTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 22
	label.TextWrapped = true
	label.Parent = parent

	return function(text: string, color: Color3, seconds: number)
		label.Text = text
		label.TextColor3 = color
		label.TextTransparency = 0
		label.TextStrokeTransparency = 0.5
		bump(label)
		-- Holds for most of its time, then fades, so it can actually be read.
		local fade = TweenInfo.new(seconds * 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, seconds * 0.65)
		TweenService:Create(label, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end
end

-- A small heading inside the inventory panel.
local function buildSectionLabel(parent: Instance, text: string, y: number)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -16, 0, 18)
	label.Position = UDim2.fromOffset(8, y)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(150, 140, 125)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.Parent = parent
end

-- The inventory panel. The equipped weapon gets its own section above the
-- loot list rather than a row inside it: you carry exactly one, it never
-- stacks, it has no rarity, and it is the most important thing on the panel.
-- Listing it as an item would also mean inventing an itemId for every weapon
-- and paying the save format's inventory cap for something that is always
-- exactly one.
local function buildInventory(parent: Instance): (Frame, Frame, TextLabel)
	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(268, 348)
	panel.Position = UDim2.new(1, -284, 0, 16)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.15
	panel.Visible = false
	panel.Parent = parent
	stylePanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(255, 215, 140)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.Text = "Inventory (I)"
	title.Parent = panel

	buildSectionLabel(panel, "WEAPON", 34)

	local weaponRow = Instance.new("TextLabel")
	weaponRow.Size = UDim2.new(1, -16, 0, 26)
	weaponRow.Position = UDim2.fromOffset(8, 52)
	weaponRow.BackgroundTransparency = 1
	weaponRow.TextColor3 = Color3.fromRGB(150, 150, 150)
	weaponRow.Font = Enum.Font.Gotham
	weaponRow.TextSize = 16
	weaponRow.TextXAlignment = Enum.TextXAlignment.Left
	weaponRow.Text = "None — take one from a stand"
	weaponRow.Parent = panel

	local divider = Instance.new("Frame")
	divider.Size = UDim2.new(1, -16, 0, 1)
	divider.Position = UDim2.fromOffset(8, 84)
	divider.BorderSizePixel = 0
	divider.BackgroundColor3 = PANEL_EDGE
	divider.BackgroundTransparency = 0.5
	divider.Parent = panel

	buildSectionLabel(panel, "ITEMS", 92)

	local list = Instance.new("Frame")
	list.Size = UDim2.new(1, -16, 1, -122)
	list.Position = UDim2.fromOffset(8, 114)
	list.BackgroundTransparency = 1
	list.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Parent = list

	return panel, list, weaponRow
end

-- The dungeon run on screen: progress at the top, the boss bar during the boss
-- fight, big announcements for clears, and the countdown to the next dungeon.
local function buildDungeonHUD(gui: ScreenGui)
	local status = makeLabel(gui, UDim2.fromOffset(340, 26), UDim2.new(0.5, -170, 0, 40), 15)
	status.TextColor3 = Color3.fromRGB(230, 220, 200)
	status.Text = "Dungeon"

	-- Boss bar.
	local bossFrame = Instance.new("Frame")
	bossFrame.Size = UDim2.fromOffset(520, 48)
	bossFrame.Position = UDim2.new(0.5, -260, 0, 74)
	bossFrame.BackgroundColor3 = PANEL_COLOR
	bossFrame.BackgroundTransparency = 0.2
	bossFrame.Visible = false
	bossFrame.Parent = gui
	stylePanel(bossFrame)

	local bossName = Instance.new("TextLabel")
	bossName.Size = UDim2.new(1, 0, 0, 20)
	bossName.Position = UDim2.fromOffset(0, 3)
	bossName.BackgroundTransparency = 1
	bossName.Font = Enum.Font.GothamBlack
	bossName.TextSize = 16
	bossName.TextColor3 = Color3.fromRGB(170, 215, 255)
	bossName.Parent = bossFrame

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -24, 0, 14)
	track.Position = UDim2.fromOffset(12, 26)
	track.BackgroundColor3 = Color3.fromRGB(35, 30, 38)
	track.BorderSizePixel = 0
	track.Parent = bossFrame
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 4)
	trackCorner.Parent = track

	-- A pale bar that lags behind the real one, so a big hit is visible as a
	-- chunk falling away.
	local trail = Instance.new("Frame")
	trail.Size = UDim2.fromScale(1, 1)
	trail.BackgroundColor3 = Color3.fromRGB(255, 230, 200)
	trail.BorderSizePixel = 0
	trail.Parent = track

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(190, 40, 60)
	fill.BorderSizePixel = 0
	fill.Parent = track

	for _, bar in { trail, fill } do
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = bar
	end

	-- Big centre-screen announcements.
	local banner = Instance.new("TextLabel")
	banner.Size = UDim2.fromOffset(800, 60)
	banner.Position = UDim2.fromScale(0.5, 0.28)
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.BackgroundTransparency = 1
	banner.Font = Enum.Font.GothamBlack
	banner.TextSize = 38
	banner.TextStrokeTransparency = 1
	banner.TextTransparency = 1
	banner.Parent = gui

	local function announce(text: string, color: Color3, seconds: number)
		banner.Text = text
		banner.TextColor3 = color
		banner.TextTransparency = 0
		banner.TextStrokeTransparency = 0.4
		bump(banner)
		local fade = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, seconds)
		TweenService:Create(banner, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end

	local run: { [string]: any } = { run = 0, phase = "running", roomsCleared = 0, roomsTotal = 0 }
	local bossId: string? = nil

	-- The dungeon ready-check. While you are queued you are standing in camp,
	-- so the countdown is more use on this line than room progress is.
	local queued: { [string]: any } = { active = false, count = 0 }

	local function renderStatus()
		if queued.active then
			local seconds = math.max(math.ceil((queued.entersAt or 0) - Workspace:GetServerTimeNow()), 0)
			status.Text = if queued.count > 1
				then `Entering the dungeon in {seconds}s  ·  {queued.count} waiting`
				else `Entering the dungeon in {seconds}s`
			status.TextColor3 = NOTICE_COLORS.danger
			return
		end

		if run.phase == "cleared" and typeof(run.resetAt) == "number" then
			local seconds = math.max(math.ceil(run.resetAt - Workspace:GetServerTimeNow()), 0)
			status.Text = `Dungeon cleared! A new one forms in {seconds}s`
			status.TextColor3 = NOTICE_COLORS.victory
		elseif run.phase == "resetting" then
			status.Text = "The dungeon shifts…"
			status.TextColor3 = NOTICE_COLORS.info
		else
			status.Text = `Dungeon {run.run}  ·  Rooms cleared {run.roomsCleared}/{run.roomsTotal}`
			status.TextColor3 = Color3.fromRGB(230, 220, 200)
		end
	end

	Remotes.get("DungeonUpdated").OnClientEvent:Connect(function(payload)
		local previousCleared = run.roomsCleared
		run = payload
		renderStatus()
		if payload.roomsCleared ~= previousCleared then
			bump(status)
		end
	end)

	Remotes.get("DungeonNotice").OnClientEvent:Connect(function(payload)
		local color = NOTICE_COLORS[payload.tone] or NOTICE_COLORS.info
		local big = payload.tone == "victory" or payload.tone == "danger"
		announce(payload.text, color, if big then 2.5 else 1.4)
	end)

	-- Every enemy's latest health fraction, so the bar is right the moment the
	-- fight starts, not only after the first hit.
	local healthFractions: { [string]: number } = {}

	Remotes.get("BossEncounter").OnClientEvent:Connect(function(payload)
		bossId = payload.enemyId
		bossName.Text = payload.name
		bossFrame.Visible = payload.active

		local fraction = healthFractions[payload.enemyId] or 1
		fill.Size = UDim2.fromScale(fraction, 1)
		trail.Size = UDim2.fromScale(fraction, 1)
	end)

	Remotes.get("EnemyHealthChanged").OnClientEvent:Connect(function(payload)
		local fraction = if payload.maxHealth > 0 then math.clamp(payload.health / payload.maxHealth, 0, 1) else 0
		healthFractions[payload.enemyId] = fraction

		if payload.enemyId ~= bossId then
			return
		end

		fill.Size = UDim2.fromScale(fraction, 1)
		TweenService:Create(trail, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.25), {
			Size = UDim2.fromScale(fraction, 1),
		}):Play()
	end)

	Remotes.get("DungeonQueueChanged").OnClientEvent:Connect(function(payload)
		queued.active = payload.queued == true
		queued.count = payload.count or 0
		queued.entersAt = payload.entersAt
		renderStatus()
	end)

	-- Both countdowns tick on their own; the server only sends when they change.
	local lastTick = 0
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local counting = queued.active or run.phase == "cleared"
		if counting and now - lastTick >= 0.25 then
			lastTick = now
			renderStatus()
		end
	end)
end

-- One cooldown square: a key letter with a dark cover that drains away as the
-- move comes back.
local function makeCooldown(parent: Instance, key: string, position: UDim2): (Frame, TextLabel)
	local box = Instance.new("Frame")
	box.Size = UDim2.fromOffset(30, 30)
	box.Position = position
	box.BackgroundColor3 = PANEL_COLOR
	box.BackgroundTransparency = 0.2
	box.Parent = parent
	stylePanel(box)

	local cover = Instance.new("Frame")
	cover.AnchorPoint = Vector2.new(0, 1)
	cover.Position = UDim2.fromScale(0, 1)
	cover.Size = UDim2.fromScale(1, 0)
	cover.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	cover.BackgroundTransparency = 0.35
	cover.BorderSizePixel = 0
	cover.ZIndex = 2
	cover.Parent = box
	local coverCorner = Instance.new("UICorner")
	coverCorner.CornerRadius = UDim.new(0, 8)
	coverCorner.Parent = cover

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 15
	label.TextColor3 = Color3.fromRGB(235, 230, 220)
	label.Text = key
	label.ZIndex = 3
	label.Parent = box

	return cover, label
end

-- Posture and cooldowns, low in the middle of the screen. The posture bar only
-- shows while there's posture to show; it fills as blocks land and flashes
-- when the guard breaks.
local function buildCombatHUD(gui: ScreenGui)
	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, -96)
	track.Size = UDim2.fromOffset(240, 8)
	track.BackgroundColor3 = Color3.fromRGB(25, 22, 28)
	track.BackgroundTransparency = 0.2
	track.BorderSizePixel = 0
	track.Visible = false
	track.Parent = gui
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(235, 195, 80)
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local dodgeCover = makeCooldown(gui, "Q", UDim2.new(0.5, -34, 1, -84))
	local criticalCover = makeCooldown(gui, "R", UDim2.new(0.5, 4, 1, -84))

	local posture = 0
	local postureUpdatedAt = 0
	local postureDamagedAt = -math.huge
	local dodgeReadyAt = 0
	local criticalReadyAt = 0

	Remotes.get("CombatStateChanged").OnClientEvent:Connect(function(payload)
		posture = payload.posture
		postureUpdatedAt = payload.postureUpdatedAt
		postureDamagedAt = payload.postureDamagedAt
		dodgeReadyAt = payload.dodgeReadyAt
		criticalReadyAt = payload.criticalReadyAt
	end)

	-- A broken guard shows as a full red bar draining away.
	local BREAK_FLASH = 0.6
	local breakFlashUntil = 0
	Remotes.get("PlayerHit").OnClientEvent:Connect(function(payload)
		if payload.guardBroken then
			breakFlashUntil = os.clock() + BREAK_FLASH
			track.Visible = true
			fill.BackgroundColor3 = POSTURE_BROKEN
			fill.Size = UDim2.fromScale(1, 1)
			TweenService:Create(fill, TweenInfo.new(BREAK_FLASH), { Size = UDim2.fromScale(0, 1) }):Play()
		end
	end)

	-- Predicted forward on this client between the server's updates.
	RunService.RenderStepped:Connect(function()
		local now = Workspace:GetServerTimeNow()

		if os.clock() >= breakFlashUntil then
			local current = PostureMath.regenerate(posture, postureUpdatedAt, postureDamagedAt, now)
			local fraction = math.clamp(current / CombatConstants.MAX_POSTURE, 0, 1)
			track.Visible = fraction > 0.001
			fill.Size = UDim2.fromScale(fraction, 1)
			-- Warmer and redder as it nears breaking.
			fill.BackgroundColor3 = POSTURE_CALM:Lerp(POSTURE_DANGER, fraction)
		end

		dodgeCover.Size = UDim2.fromScale(1, math.clamp((dodgeReadyAt - now) / CombatConstants.DODGE_COOLDOWN, 0, 1))

		local weaponId = currentWeaponId
		local criticalCooldown = if weaponId then Loadout.getDef(weaponId).attack.critical.cooldown else 1
		criticalCover.Size = UDim2.fromScale(1, math.clamp((criticalReadyAt - now) / criticalCooldown, 0, 1))
	end)
end

function GameUI.start()
	local player = Players.LocalPlayer

	local gui = Instance.new("ScreenGui")
	gui.Name = "GameUI"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Damage and heal flashes are ScreenFX's: a vignette at the edges.

	-- Bottom-left status stack.
	local weaponLabel = makeLabel(gui, UDim2.fromOffset(260, 30), UDim2.new(0, 16, 1, -120), 18)
	weaponLabel.Text = "Weapon: none — pick one from a stand"

	local currencyLabel = makeLabel(gui, UDim2.fromOffset(260, 24), UDim2.new(0, 16, 1, -86), 16)
	currencyLabel.TextColor3 = GOLD
	currencyLabel.Text = "0 coins"

	local duelStatusLabel = makeLabel(gui, UDim2.fromOffset(260, 24), UDim2.new(0, 16, 1, -58), 16)
	duelStatusLabel.TextColor3 = DUEL
	duelStatusLabel.Visible = false

	local duelHealthLabel = makeLabel(gui, UDim2.fromOffset(260, 24), UDim2.new(0, 16, 1, -30), 16)
	duelHealthLabel.Visible = false

	-- Top-centre transient messages, below the dungeon status and boss bar.
	local flashLoot = makeFlashLabel(gui, UDim2.new(0.5, 0, 0, 130))
	local flashUpgrade = makeFlashLabel(gui, UDim2.new(0.5, 0, 0, 170))
	local flashDuel = makeFlashLabel(gui, UDim2.new(0.5, 0, 0, 210))

	buildDungeonHUD(gui)
	buildCombatHUD(gui)

	local inventoryPanel, inventoryList, inventoryWeapon = buildInventory(gui)

	-- Only ever false in Studio: a live server kicks rather than run a session
	-- it can't save. Said plainly, so a tester doesn't mistake it for a bug in
	-- saving.
	local unsavedNotice = makeLabel(gui, UDim2.fromOffset(420, 26), UDim2.new(0.5, -210, 0, 8), 16)
	unsavedNotice.TextColor3 = BAD
	unsavedNotice.Text = "Progress isn't being saved in this session (Studio has no DataStore access)"
	unsavedNotice.Visible = false

	Remotes.get("ProfileLoaded").OnClientEvent:Connect(function(payload)
		unsavedNotice.Visible = not payload.persistent
	end)

	Remotes.get("WeaponEquipped").OnClientEvent:Connect(function(payload)
		currentWeaponId = payload.weaponId
		local def = Loadout.getDef(payload.weaponId)
		local text = `Weapon: {def.displayName} ({payload.classTag})`
		if payload.upgradeLevel > 0 then
			text ..= ` +{payload.upgradeLevel}`
		end
		weaponLabel.Text = text
		bump(weaponLabel)

		-- The same weapon, in the inventory panel's own section.
		inventoryWeapon.Text = if payload.upgradeLevel > 0
			then `{def.displayName}  +{payload.upgradeLevel}  ({payload.classTag})`
			else `{def.displayName}  ({payload.classTag})`
		inventoryWeapon.TextColor3 = Color3.fromRGB(255, 215, 140)
	end)

	-- Only crystal types the player actually holds are listed, so an untouched
	-- class never shows up as "0" clutter.
	Remotes.get("CurrencyUpdated").OnClientEvent:Connect(function(payload)
		local text = string.format("%d coins", payload.coins)
		for class, amount in payload.crystals do
			if amount > 0 then
				text ..= string.format(" | %d %s", amount, class)
			end
		end
		if currencyLabel.Text ~= text then
			currencyLabel.Text = text
			bump(currencyLabel)
		end
	end)

	Remotes.get("UpgradeResult").OnClientEvent:Connect(function(payload)
		if payload.success then
			flashUpgrade(`Weapon upgraded to +{payload.newLevel}`, GOOD, 3)
		else
			flashUpgrade(payload.reason or "Upgrade failed", BAD, 3)
		end
	end)

	Remotes.get("ChestOpened").OnClientEvent:Connect(function(payload)
		if payload.inventoryFull then
			flashLoot("Inventory full — the chest stays shut for now", BAD, 3)
			return
		end

		local item = payload.loot[1]
		if item then
			flashLoot(`Found: {item.name} — {item.flavor}`, GOLD, 3)
		end
	end)

	Remotes.get("InventoryUpdated").OnClientEvent:Connect(function(payload)
		for _, child in inventoryList:GetChildren() do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		for _, item in payload.items do
			local row = Instance.new("TextLabel")
			row.Size = UDim2.new(1, 0, 0, 24)
			row.BackgroundTransparency = 1
			row.TextColor3 = RARITY_COLORS[item.rarity] or Color3.fromRGB(255, 255, 255)
			row.Font = Enum.Font.Gotham
			row.TextSize = 16
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.Text = `{ITEM_NAMES[item.itemId] or item.itemId} ({item.rarity})`
			row.Parent = inventoryList
		end
	end)

	Remotes.get("PvPStatusChanged").OnClientEvent:Connect(function(payload)
		if payload.status == "queued" then
			duelStatusLabel.Text = "Queued for duel…"
			duelStatusLabel.Visible = true
			duelHealthLabel.Visible = false
		elseif payload.status == "dueling" then
			duelStatusLabel.Text = `Dueling: {payload.opponentName or "?"}`
			duelStatusLabel.Visible = true
		else
			duelStatusLabel.Visible = false
			duelHealthLabel.Visible = false
		end

		if payload.message then
			flashDuel(payload.message, DUEL, 2)
		end
	end)

	Remotes.get("PvPHealthChanged").OnClientEvent:Connect(function(payload)
		duelHealthLabel.Text = string.format("You: %d | Opponent: %d", payload.yours, payload.opponent)
		duelHealthLabel.Visible = true
	end)

	Remotes.get("PvPParryResult").OnClientEvent:Connect(function(payload)
		flashDuel(payload.message, if payload.success then GOOD else BAD, 2)
	end)

	ContextActionService:BindAction(INVENTORY_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			inventoryPanel.Visible = not inventoryPanel.Visible
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.I)
end

return GameUI
