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
local AbilityDefs = require(Shared.AbilityDefs)
local LootTables = require(Shared.LootTables)
local Loadout = require(Shared.Loadout)
local PostureMath = require(Shared.PostureMath)
local Remotes = require(Shared.Remotes)
local SkillTreeDefs = require(Shared.SkillTreeDefs)

local CameraLock = require(script.Parent.CameraLock)

local GameUI = {}

-- The server's last word on this player's level and tree. Everything the
-- panel draws comes from here, so the panel can never disagree with the
-- server about what has been bought.
type Progression = {
	level: number,
	into: number,
	toNext: number,
	points: number,
	spent: number,
	weaponId: string?,
	skills: SkillTreeDefs.Allocation,
}

local POSTURE_CALM = Color3.fromRGB(235, 195, 80)
local POSTURE_DANGER = Color3.fromRGB(255, 90, 50)
local POSTURE_BROKEN = Color3.fromRGB(255, 60, 50)

-- The local player's weapon, for its critical's cooldown.
local currentWeaponId: string? = nil

-- slot -> AbilityDefs id, from the skill tree. What the HUD draws, and the
-- reason an ability key shows nothing until its branch is finished.
local unlockedAbilities: { [number]: string } = {}

-- The keys the abilities sit on, in branch order. Matches CombatClient.
local ABILITY_KEY_NAMES = { "Z", "X", "C" }

local INVENTORY_ACTION = "ToggleInventory"
local SKILLS_ACTION = "ToggleSkills"
local CLOSE_LOOT_ACTION = "CloseLoot"

-- Levels are their own colour: not the gold of coins, not the red of a fight.
local XP_COLOR = Color3.fromRGB(150, 200, 255)

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

--[[ The chest's loot menu ]]

-- Opening a chest shows what is inside and lets you take it a row at a time,
-- rather than pushing everything into your bags at once. Nothing here decides
-- anything: a click asks the server for a slot, and the panel is redrawn from
-- whatever the server says the chest holds afterwards. Two players looking in
-- the same chest therefore see the same rows disappear.
local LOOT_ROW_HEIGHT = 46

type LootRow = {
	slot: number,
	itemId: string,
	name: string,
	flavor: string,
	rarity: string,
	taken: boolean,
}

local function buildLootPanel(gui: ScreenGui, onTake: (string, number?, boolean) -> ()): (Frame, (any) -> ())
	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(380, 330)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.05
	panel.Visible = false
	panel.Parent = gui
	stylePanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -24, 0, 26)
	title.Position = UDim2.fromOffset(12, 10)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.TextColor3 = Color3.fromRGB(255, 215, 140)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Chest"
	title.Parent = panel

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, -24, 0, 16)
	hint.Position = UDim2.new(0, 12, 1, -26)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 12
	hint.TextColor3 = Color3.fromRGB(150, 140, 125)
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Text = "Click to take  ·  anything you leave stays in the chest  ·  Esc to close"
	hint.Parent = panel

	local list = Instance.new("Frame")
	list.Position = UDim2.fromOffset(12, 44)
	list.Size = UDim2.new(1, -24, 1, -76)
	list.BackgroundTransparency = 1
	list.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	-- Rows are rebuilt on every update rather than reconciled: a chest holds a
	-- handful of things, and rebuilding is the version that can't leave a row
	-- showing the wrong state.
	local function clear()
		for _, child in list:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
	end

	local function addRow(order: number, name: string, detail: string, color: Color3, taken: boolean, take: () -> ())
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, 0, 0, LOOT_ROW_HEIGHT)
		row.BackgroundColor3 = Color3.fromRGB(28, 25, 32)
		row.BackgroundTransparency = if taken then 0.7 else 0.15
		row.AutoButtonColor = not taken
		row.Text = ""
		row.LayoutOrder = order
		row.Parent = list
		stylePanel(row)

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -16, 0, 18)
		label.Position = UDim2.fromOffset(8, 5)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 14
		label.TextColor3 = if taken then Color3.fromRGB(110, 104, 116) else color
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = if taken then `{name}  —  taken` else name
		label.Parent = row

		local sub = Instance.new("TextLabel")
		sub.Size = UDim2.new(1, -16, 0, 16)
		sub.Position = UDim2.fromOffset(8, 24)
		sub.BackgroundTransparency = 1
		sub.Font = Enum.Font.Gotham
		sub.TextSize = 12
		sub.TextColor3 = Color3.fromRGB(150, 140, 125)
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextTruncate = Enum.TextTruncate.AtEnd
		sub.Text = detail
		sub.Parent = row

		if not taken then
			row.MouseButton1Click:Connect(take)
		end
	end

	local openChestId: string? = nil

	local function refresh(payload: any)
		local chestId = payload.chestId
		if type(chestId) ~= "string" then
			return
		end

		-- An update about a chest someone else is standing at is not ours.
		if panel.Visible and openChestId ~= chestId then
			return
		end
		openChestId = chestId

		clear()

		local left = 0

		if payload.coins and payload.coins > 0 then
			local taken = payload.coinsTaken == true
			if not taken then
				left += 1
			end
			addRow(1, `{payload.coins} coins`, "Loose coin, scattered across the bottom.", GOLD, taken, function()
				onTake(chestId, nil, true)
			end)
		end

		for _, row in payload.rows or {} do
			local entry = row :: LootRow
			if not entry.taken then
				left += 1
			end
			addRow(
				1 + entry.slot,
				entry.name,
				entry.flavor,
				RARITY_COLORS[entry.rarity] or Color3.fromRGB(225, 225, 225),
				entry.taken,
				function()
					onTake(chestId, entry.slot, false)
				end
			)
		end

		title.Text = if left > 0 then `Chest — {left} thing(s) left` else "Chest — empty"
		hint.Text = if payload.inventoryFull
			then "Your inventory is full — nothing can be taken until you make room"
			else "Click to take  ·  anything you leave stays in the chest  ·  Esc to close"
		hint.TextColor3 = if payload.inventoryFull then BAD else Color3.fromRGB(150, 140, 125)

		panel.Visible = true
	end

	return panel, refresh
end

--[[ Levels and the skill tree ]]

-- One node, drawn where the tree says it sits. Its whole state — ranks,
-- whether it is affordable, what it does — is redrawn from the server's last
-- word rather than tracked here, so a refused spend can never leave the panel
-- showing a rank that wasn't bought.
local NODE_WIDTH = 92
local NODE_HEIGHT = 56

-- The panel is a fixed size, so the canvas inside it is too. Written down
-- rather than read from AbsoluteSize: a frame has no measured size until
-- Roblox has laid it out, and the tree is built the first time the server
-- sends progression — which can be well before that. Reading it then would
-- stack every node in the top-left corner.
local PANEL_WIDTH = 900
local PANEL_HEIGHT = 520
local CANVAS_WIDTH = PANEL_WIDTH - 24
local CANVAS_HEIGHT = PANEL_HEIGHT - 108

local function buildNodeButton(
	parent: Instance,
	node: SkillTreeDefs.Node,
	place: (GuiObject, number, number) -> (),
	onSpend: (string) -> (),
	onHover: (SkillTreeDefs.Node?) -> ()
): (Progression) -> ()
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(NODE_WIDTH, NODE_HEIGHT)
	button.BackgroundColor3 = PANEL_COLOR
	button.BackgroundTransparency = 0.1
	button.AutoButtonColor = false
	button.Text = ""
	-- Above the branches drawn behind it.
	button.ZIndex = 3
	button.Parent = parent
	stylePanel(button)
	place(button, node.column, node.tier)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -10, 0, 30)
	title.Position = UDim2.fromOffset(5, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 12
	title.TextWrapped = true
	title.ZIndex = 4
	title.Text = node.name
	title.Parent = button

	local ranks = Instance.new("TextLabel")
	ranks.Size = UDim2.new(1, -10, 0, 14)
	ranks.Position = UDim2.new(0, 5, 1, -19)
	ranks.BackgroundTransparency = 1
	ranks.Font = Enum.Font.GothamBold
	ranks.TextSize = 11
	ranks.ZIndex = 4
	ranks.Parent = button

	button.MouseButton1Click:Connect(function()
		onSpend(node.id)
	end)
	button.MouseEnter:Connect(function()
		onHover(node)
	end)
	button.MouseLeave:Connect(function()
		onHover(nil)
	end)

	return function(state: Progression)
		local bought = state.skills[node.id] or 0
		local weaponId = state.weaponId or ""
		local available = state.points - state.spent
		local unlocked = SkillTreeDefs.isUnlocked(weaponId, state.skills, node.id)
		local canBuy = SkillTreeDefs.canSpend(weaponId, state.skills, node.id, state.points).ok

		ranks.Text = `{bought} / {node.maxRank}`

		if bought >= node.maxRank then
			title.TextColor3 = XP_COLOR
			ranks.TextColor3 = XP_COLOR
			button.BackgroundTransparency = 0.1
		elseif not unlocked then
			title.TextColor3 = Color3.fromRGB(105, 100, 112)
			ranks.TextColor3 = Color3.fromRGB(85, 82, 92)
			button.BackgroundTransparency = 0.6
		elseif canBuy and available > 0 then
			title.TextColor3 = GOOD
			ranks.TextColor3 = GOOD
			button.BackgroundTransparency = 0
		else
			title.TextColor3 = Color3.fromRGB(215, 210, 200)
			ranks.TextColor3 = Color3.fromRGB(150, 140, 125)
			button.BackgroundTransparency = 0.35
		end
	end
end

-- The branch between a node and the one it grows from: a real line drawn
-- between two points, not a column divider. The connections are what make
-- this a tree rather than a list, and they are what tells a player at a
-- glance what buying a node opens up.
local function buildBranch(parent: Instance, fromX: number, fromY: number, toX: number, toY: number): (boolean) -> ()
	local dx = toX - fromX
	local dy = toY - fromY

	local line = Instance.new("Frame")
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.Position = UDim2.fromOffset((fromX + toX) / 2, (fromY + toY) / 2)
	line.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), 3)
	line.Rotation = math.deg(math.atan2(dy, dx))
	line.BorderSizePixel = 0
	line.ZIndex = 2
	line.Parent = parent

	return function(lit: boolean)
		line.BackgroundColor3 = if lit then XP_COLOR else Color3.fromRGB(70, 66, 78)
		line.BackgroundTransparency = if lit then 0.25 else 0.5
	end
end

-- The tree panel (K). Each weapon's tree is drawn once, the first time it is
-- needed, and shown or hidden after that — swapping weapon in camp shouldn't
-- pay to rebuild a tree you already looked at.
local function buildSkillPanel(gui: ScreenGui, onSpend: (string) -> ()): (Frame, (Progression) -> ())
	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.05
	panel.Visible = false
	panel.Parent = gui
	stylePanel(panel)

	local heading = Instance.new("TextLabel")
	heading.Size = UDim2.new(1, -24, 0, 24)
	heading.Position = UDim2.fromOffset(12, 10)
	heading.BackgroundTransparency = 1
	heading.Font = Enum.Font.GothamBold
	heading.TextSize = 18
	heading.TextColor3 = Color3.fromRGB(255, 215, 140)
	heading.TextXAlignment = Enum.TextXAlignment.Left
	heading.Text = "Skills"
	heading.Parent = panel

	-- The ability the held weapon carries, above its tree: it is the thing
	-- that changes most when you swap weapon, so it reads first.
	local abilityLabel = Instance.new("TextLabel")
	abilityLabel.Size = UDim2.new(1, -24, 0, 18)
	abilityLabel.Position = UDim2.fromOffset(12, 34)
	abilityLabel.BackgroundTransparency = 1
	abilityLabel.Font = Enum.Font.Gotham
	abilityLabel.TextSize = 13
	abilityLabel.TextColor3 = XP_COLOR
	abilityLabel.TextXAlignment = Enum.TextXAlignment.Left
	abilityLabel.Parent = panel

	-- One line at the bottom for whatever the pointer is over, rather than
	-- every node shouting its numbers at once.
	local detail = Instance.new("TextLabel")
	detail.Size = UDim2.new(1, -24, 0, 34)
	detail.Position = UDim2.new(0, 12, 1, -42)
	detail.BackgroundTransparency = 1
	detail.Font = Enum.Font.Gotham
	detail.TextSize = 13
	detail.TextColor3 = Color3.fromRGB(200, 195, 185)
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextWrapped = true
	detail.Parent = panel

	local canvas = Instance.new("Frame")
	canvas.Position = UDim2.fromOffset(12, 60)
	canvas.Size = UDim2.fromOffset(CANVAS_WIDTH, CANVAS_HEIGHT)
	canvas.BackgroundTransparency = 1
	canvas.ClipsDescendants = true
	canvas.Parent = panel

	type Branch = { node: SkillTreeDefs.Node, light: (boolean) -> () }
	type Built = {
		holder: Frame,
		refresh: { (Progression) -> () },
		branches: { Branch },
	}

	local built: { [string]: Built } = {}
	local shown: string? = nil
	local hovered: SkillTreeDefs.Node? = nil
	local latest: Progression? = nil

	local function describeHover()
		local node = hovered
		if not node then
			detail.Text = ""
			return
		end

		local state = latest
		local bought = if state then state.skills[node.id] or 0 else 0
		local perRank = table.concat(SkillTreeDefs.describe(node.effects, 1), "   ")
		local line = `{node.name}  ({bought}/{node.maxRank})  —  {node.description}`

		-- A capstone's real payoff is the key it unlocks, so it leads.
		local granted = if node.ability then AbilityDefs.get(node.ability) else nil
		if granted then
			line = `{node.name}  ({bought}/{node.maxRank})  —  unlocks {granted.name}: {granted.description}`
		end

		if bought > 0 and bought < node.maxRank then
			local owned = table.concat(SkillTreeDefs.describe(node.effects, bought), "   ")
			detail.Text = `{line}\nNow: {owned}     Next rank: {perRank}`
		else
			detail.Text = `{line}\nPer rank: {perRank}`
		end
	end

	local function buildTree(weaponId: string)
		local tree = SkillTreeDefs.treeFor(weaponId)
		if not tree then
			return
		end

		local holder = Instance.new("Frame")
		holder.Size = UDim2.fromScale(1, 1)
		holder.BackgroundTransparency = 1
		holder.Visible = false
		holder.Parent = canvas

		local columns = SkillTreeDefs.columns(tree)
		local tiers = SkillTreeDefs.tiers(tree)

		-- Nodes are placed by hand rather than by a layout object: a tree is a
		-- graph, and a list layout can only make rows and columns.
		local function centreOf(column: number, tier: number): (number, number)
			return (column + 0.5) / columns * CANVAS_WIDTH, (tier - 0.5) / tiers * CANVAS_HEIGHT
		end

		local function place(object: GuiObject, column: number, tier: number)
			local x, y = centreOf(column, tier)
			object.AnchorPoint = Vector2.new(0.5, 0.5)
			object.Position = UDim2.fromOffset(x, y)
		end

		local entry: Built = { holder = holder, refresh = {}, branches = {} }

		-- Branches first, so every node is drawn on top of its own lines.
		for _, node in tree.nodes do
			local required = node.requires
			local parent = if required then SkillTreeDefs.findNode(weaponId, required) else nil
			if parent then
				local fromX, fromY = centreOf(parent.column, parent.tier)
				local toX, toY = centreOf(node.column, node.tier)
				table.insert(entry.branches, {
					node = node,
					light = buildBranch(holder, fromX, fromY + NODE_HEIGHT / 2, toX, toY - NODE_HEIGHT / 2),
				})
			end
		end

		for _, node in tree.nodes do
			local refresher = buildNodeButton(holder, node, place, onSpend, function(over)
				hovered = over
				describeHover()
			end)
			table.insert(entry.refresh, refresher)
		end

		built[weaponId] = entry
	end

	local function refresh(state: Progression)
		latest = state

		local weaponId = state.weaponId
		if not weaponId then
			heading.Text = "Skills"
			abilityLabel.Text = "Pick a weapon from a stand — each has its own tree and its own ability."
			if shown and built[shown] then
				built[shown].holder.Visible = false
				shown = nil
			end
			return
		end

		if not built[weaponId] then
			buildTree(weaponId)
		end

		local entry = built[weaponId]
		if not entry then
			return
		end

		if shown ~= weaponId then
			if shown and built[shown] then
				built[shown].holder.Visible = false
			end
			entry.holder.Visible = true
			shown = weaponId
		end

		local available = state.points - state.spent
		heading.Text = `{Loadout.getDef(weaponId).displayName} — level {state.level}, {available} point(s) to spend`

		-- What each key does, or what it would do. A locked branch says what
		-- is at the end of it, which is the argument for going down it.
		local tree = SkillTreeDefs.treeFor(weaponId)
		local unlocked = SkillTreeDefs.abilities(weaponId, state.skills)
		local parts = {}
		if tree then
			for slot, branch in tree.branches do
				local abilityId = unlocked[slot]
				for _, node in tree.nodes do
					if node.branch == branch and node.ability then
						local def = AbilityDefs.get(node.ability)
						if def then
							table.insert(
								parts,
								if abilityId
									then `[{ABILITY_KEY_NAMES[slot]}] {def.name}`
									else `[{ABILITY_KEY_NAMES[slot]}] {def.name} (locked)`
							)
						end
					end
				end
			end
		end
		abilityLabel.Text = table.concat(parts, "     ")

		for _, refresher in entry.refresh do
			refresher(state)
		end

		-- A branch lights once the node it leads to is bought, so the path a
		-- player has taken through the tree is visible as a shape.
		for _, branch in entry.branches do
			branch.light((state.skills[branch.node.id] or 0) > 0)
		end

		describeHover()
	end

	return panel, refresh
end

-- The XP bar sits under the status stack in the bottom-left, thin and quiet:
-- it changes on every kill, and a bar that shouts every few seconds becomes a
-- bar nobody reads.
local function buildLevelBar(gui: ScreenGui): (Progression) -> ()
	local label = makeLabel(gui, UDim2.fromOffset(260, 22), UDim2.new(0, 16, 1, -148), 15)
	label.TextColor3 = XP_COLOR
	label.Text = "Level 1"

	local track = Instance.new("Frame")
	track.Position = UDim2.new(0, 16, 1, -126)
	track.Size = UDim2.fromOffset(260, 4)
	track.BackgroundColor3 = Color3.fromRGB(25, 22, 28)
	track.BorderSizePixel = 0
	track.Parent = gui

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = XP_COLOR
	fill.BorderSizePixel = 0
	fill.Parent = track

	return function(state: Progression)
		local text = `Level {state.level}`
		if state.points - state.spent > 0 then
			-- The one thing worth interrupting for: a point going unspent.
			text ..= `  ·  {state.points - state.spent} point(s) to spend  [K]`
		end
		if label.Text ~= text then
			label.Text = text
			bump(label)
		end

		local fraction = if state.toNext > 0 then state.into / state.toNext else 1
		TweenService:Create(fill, TweenInfo.new(0.25), { Size = UDim2.fromScale(fraction, 1) }):Play()
	end
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

	local dodgeCover = makeCooldown(gui, "Q", UDim2.new(0.5, -110, 1, -84))
	local criticalCover = makeCooldown(gui, "R", UDim2.new(0.5, -72, 1, -84))

	-- One box per branch of the skill tree, hidden until that branch's
	-- capstone is bought. An empty key with a cover on it would read as a
	-- cooldown that never ends.
	local abilityCovers = {}
	for slot = 1, #ABILITY_KEY_NAMES do
		local cover = makeCooldown(gui, ABILITY_KEY_NAMES[slot], UDim2.new(0.5, -34 + (slot - 1) * 38, 1, -84));
		(cover.Parent :: GuiObject).Visible = false
		table.insert(abilityCovers, cover)
	end

	local posture = 0
	local postureUpdatedAt = 0
	local postureDamagedAt = -math.huge
	local dodgeReadyAt = 0
	local criticalReadyAt = 0
	local abilityReadyAt: { number } = {}
	-- Both come from the server, because the skill tree can raise either
	-- (SkillTreeDefs). The constants are only the starting point.
	local maxPosture = CombatConstants.MAX_POSTURE
	local postureRegen = CombatConstants.POSTURE_REGEN_PER_SECOND

	Remotes.get("CombatStateChanged").OnClientEvent:Connect(function(payload)
		posture = payload.posture
		postureUpdatedAt = payload.postureUpdatedAt
		postureDamagedAt = payload.postureDamagedAt
		dodgeReadyAt = payload.dodgeReadyAt
		criticalReadyAt = payload.criticalReadyAt
		abilityReadyAt = payload.abilityReadyAt or {}
		maxPosture = payload.maxPosture or CombatConstants.MAX_POSTURE
		postureRegen = payload.postureRegen or CombatConstants.POSTURE_REGEN_PER_SECOND
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
			local current = PostureMath.regenerate(posture, postureUpdatedAt, postureDamagedAt, now, postureRegen)
			local fraction = math.clamp(current / maxPosture, 0, 1)
			track.Visible = fraction > 0.001
			fill.Size = UDim2.fromScale(fraction, 1)
			-- Warmer and redder as it nears breaking.
			fill.BackgroundColor3 = POSTURE_CALM:Lerp(POSTURE_DANGER, fraction)
		end

		dodgeCover.Size = UDim2.fromScale(1, math.clamp((dodgeReadyAt - now) / CombatConstants.DODGE_COOLDOWN, 0, 1))

		local weaponId = currentWeaponId
		local criticalCooldown = if weaponId then Loadout.getDef(weaponId).attack.critical.cooldown else 1
		criticalCover.Size = UDim2.fromScale(1, math.clamp((criticalReadyAt - now) / criticalCooldown, 0, 1))

		-- Drawn against each ability's own cooldown, which the skill tree can
		-- shorten; a fixed one would empty the cover at the wrong rate.
		for slot, cover in abilityCovers do
			local abilityId = unlockedAbilities[slot]
			local ability = if abilityId then AbilityDefs.get(abilityId) else nil
			;(cover.Parent :: GuiObject).Visible = ability ~= nil
			if ability then
				local remaining = (abilityReadyAt[slot] or 0) - now
				cover.Size = UDim2.fromScale(1, math.clamp(remaining / ability.cooldown, 0, 1))
			end
		end
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
	local flashUpgrade = makeFlashLabel(gui, UDim2.new(0.5, 0, 0, 170))
	local flashDuel = makeFlashLabel(gui, UDim2.new(0.5, 0, 0, 210))

	buildDungeonHUD(gui)
	buildCombatHUD(gui)

	local inventoryPanel, inventoryList, inventoryWeapon = buildInventory(gui)

	local lootPanel, refreshLoot = buildLootPanel(gui, function(chestId, slot, coins)
		Remotes.get("ChestTakeItem"):FireServer({ chestId = chestId, slot = slot, coins = coins })
	end)

	local updateLevel = buildLevelBar(gui)
	local skillPanel, refreshSkills = buildSkillPanel(gui, function(nodeId)
		-- The server decides; this only asks. The panel redraws when the
		-- ProgressionChanged that follows a successful spend arrives, so a
		-- refusal simply leaves it as it was.
		Remotes.get("SpendSkillPoint"):FireServer({ weaponId = currentWeaponId, nodeId = nodeId })
	end)

	local flashLevel = makeFlashLabel(gui, UDim2.new(0.5, 0, 0, 250))

	Remotes.get("ProgressionChanged").OnClientEvent:Connect(function(payload)
		local state: Progression = {
			level = payload.level,
			into = payload.into,
			toNext = payload.toNext,
			points = payload.points,
			spent = payload.spent,
			weaponId = payload.weaponId,
			skills = payload.skills or {},
		}
		unlockedAbilities = if state.weaponId then SkillTreeDefs.abilities(state.weaponId, state.skills) else {}
		updateLevel(state)
		refreshSkills(state)
	end)

	Remotes.get("LevelGained").OnClientEvent:Connect(function(payload)
		local points = payload.points or 1
		flashLevel(`Level {payload.level} — {points} skill point(s). Press K`, XP_COLOR, 4)
	end)

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
		refreshLoot(payload)
		CameraLock.setCursorFree(true)
	end)

	-- Someone took a row, possibly the player themselves. Only redrawn while
	-- the menu is open: an update about a chest across the dungeon is noise.
	Remotes.get("ChestContentsChanged").OnClientEvent:Connect(function(payload)
		if lootPanel.Visible then
			refreshLoot(payload)
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

	-- The tree panel needs the mouse, which the locked camera is holding.
	-- Opening it hands the cursor back and closing it takes it again, so
	-- spending a point never means fighting the camera for the pointer.
	-- Esc closes the loot menu before Roblox's own menu sees it.
	ContextActionService:BindAction(CLOSE_LOOT_ACTION, function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin or not lootPanel.Visible then
			return Enum.ContextActionResult.Pass
		end
		lootPanel.Visible = false
		CameraLock.setCursorFree(skillPanel.Visible)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Escape)

	ContextActionService:BindAction(SKILLS_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			skillPanel.Visible = not skillPanel.Visible
			CameraLock.setCursorFree(skillPanel.Visible)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.K)
end

return GameUI
