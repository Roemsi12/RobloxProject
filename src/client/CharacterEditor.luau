--!strict
-- The character editor, opened at the hub's looking glass.
--
-- Every row, every swatch and every option comes from AppearanceDefs.
-- CATEGORIES; there is not one hardcoded hairstyle or colour in this file. A
-- new choice is a row in that table and it appears here, which is the whole
-- reason the look is described as data rather than as code.
--
-- The panel previews by asking the server, not by pretending. Picking an
-- option fires SetAppearance and the character is rebuilt for real, so what
-- the player is looking at while they decide is exactly what everyone else
-- sees — there is no separate preview rig that could drift out of step with
-- the thing it previews. That costs a remote per click, which is fine for a
-- screen you can only open standing at a mirror in town.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local AppearanceDefs = require(Shared.AppearanceDefs)
local Remotes = require(Shared.Remotes)

local CharacterEditor = {}

local PANEL_COLOR = Color3.fromRGB(18, 16, 22)
local PANEL_EDGE = Color3.fromRGB(120, 100, 70)
local ROW_COLOR = Color3.fromRGB(28, 25, 32)
local CHOSEN = Color3.fromRGB(235, 195, 80)
local TEXT = Color3.fromRGB(226, 220, 210)
local MUTED = Color3.fromRGB(150, 140, 125)

local PANEL_WIDTH = 430
local PANEL_HEIGHT = 560
local ROW_HEIGHT = 62
local SWATCH = 26
local CLOSE_ACTION = "CloseCharacterEditor"

local localPlayer = Players.LocalPlayer

-- The look as last confirmed by the server. Every edit is made against this
-- rather than against what the panel last sent, so a rejected or sanitised
-- field doesn't compound.
local current: AppearanceDefs.Look = AppearanceDefs.default()
-- category id -> redraw its selection.
local refreshers: { [string]: () -> () } = {}

local panel: Frame? = nil
local open = false

-- The one look every panel and button in this file shares: rounded
-- corners and a thin warm edge, matching GameUI's panels.
local function stylePanel(frame: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = PANEL_EDGE
	stroke.Transparency = 0.35
	stroke.Thickness = 1.5
	stroke.Parent = frame
end

-- A palette colour ({0-255, 0-255, 0-255}) as a Color3.
local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

-- Send the whole look rather than the one field that changed. The server
-- sanitises every field of whatever arrives anyway, so a partial update would
-- buy nothing and would need its own merge rule on the far side.
local function commit()
	Remotes.get("SetAppearance"):FireServer({ appearance = current })
end

-- Picks a choice for one category: updates the look, redraws that row's
-- selection, and sends the whole look to the server.
--
-- The single funnel every edit goes through, whichever row it came from.
-- Does nothing if the choice is already the current one, so re-clicking a
-- swatch costs no remote.
local function choose(categoryId: string, choiceId: string)
	if (current :: any)[categoryId] == choiceId then
		return
	end
	(current :: any)[categoryId] = choiceId

	local refresh = refreshers[categoryId]
	if refresh then
		refresh()
	end
	commit()
end

--[[ Rows ]]

-- A colour row: a line of swatches, the chosen one ringed.
local function buildColorRow(parent: Instance, category: AppearanceDefs.Category, y: number)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -20, 0, ROW_HEIGHT)
	row.Position = UDim2.fromOffset(10, y)
	row.BackgroundColor3 = ROW_COLOR
	row.BackgroundTransparency = 0.35
	row.Parent = parent
	stylePanel(row, 6)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -16, 0, 16)
	title.Position = UDim2.fromOffset(10, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = MUTED
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = string.upper(category.label)
	title.Parent = row

	local strip = Instance.new("Frame")
	strip.Size = UDim2.new(1, -20, 0, SWATCH + 6)
	strip.Position = UDim2.fromOffset(10, 26)
	strip.BackgroundTransparency = 1
	strip.Parent = row

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 5)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = strip

	local rings: { [string]: UIStroke } = {}

	for _, choice in AppearanceDefs.choicesFor(category) do
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(SWATCH, SWATCH)
		button.BackgroundColor3 = rgb(choice.rgb)
		button.Text = ""
		button.AutoButtonColor = false
		button.Parent = strip

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 5)
		corner.Parent = button

		local ring = Instance.new("UIStroke")
		ring.Color = CHOSEN
		ring.Thickness = 2
		ring.Transparency = 1
		ring.Parent = button
		rings[choice.id] = ring

		-- The label only appears on hover: ten named swatches in a row is a
		-- wall of text, and the colour is the thing being chosen anyway.
		button.MouseEnter:Connect(function()
			title.Text = `{string.upper(category.label)}  ·  {choice.label}`
		end)
		button.MouseLeave:Connect(function()
			title.Text = string.upper(category.label)
		end)

		button.Activated:Connect(function()
			choose(category.id, choice.id)
		end)
	end

	refreshers[category.id] = function()
		local chosen = (current :: any)[category.id]
		for id, ring in rings do
			ring.Transparency = if id == chosen then 0 else 1
		end
	end
end

-- An option row: the name of what is chosen, with arrows either side. A list
-- of nine hairstyles as buttons would not fit, and cycling is what a character
-- creator does anyway — you want to see each one on the body.
local function buildOptionRow(parent: Instance, category: AppearanceDefs.Category, y: number)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -20, 0, ROW_HEIGHT)
	row.Position = UDim2.fromOffset(10, y)
	row.BackgroundColor3 = ROW_COLOR
	row.BackgroundTransparency = 0.35
	row.Parent = parent
	stylePanel(row, 6)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -16, 0, 16)
	title.Position = UDim2.fromOffset(10, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = MUTED
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = string.upper(category.label)
	title.Parent = row

	local value = Instance.new("TextLabel")
	value.Size = UDim2.new(1, -96, 0, 26)
	value.Position = UDim2.fromOffset(48, 28)
	value.BackgroundTransparency = 1
	value.Font = Enum.Font.GothamBold
	value.TextSize = 17
	value.TextColor3 = TEXT
	value.Parent = row

	local choices = AppearanceDefs.choicesFor(category)

	-- Moves this row's choice `by` places, wrapping at either end so a row is
	-- never a dead end.
	local function step(by: number)
		local index = 1
		for at, choice in choices do
			if choice.id == (current :: any)[category.id] then
				index = at
			end
		end
		-- Wraps, so a row is never a dead end in either direction.
		local next = (index - 1 + by) % #choices + 1
		choose(category.id, choices[next].id)
	end

	-- One of a row's two cycle buttons.
	local function arrow(text: string, x: number, by: number)
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(32, 26)
		button.Position = UDim2.fromOffset(x, 28)
		button.BackgroundColor3 = PANEL_COLOR
		button.BackgroundTransparency = 0.2
		button.Font = Enum.Font.GothamBold
		button.TextSize = 18
		button.TextColor3 = CHOSEN
		button.Text = text
		button.Parent = row
		stylePanel(button, 5)

		button.Activated:Connect(function()
			step(by)
		end)
	end

	arrow("‹", 10, -1)
	arrow("›", PANEL_WIDTH - 20 - 52, 1)

	refreshers[category.id] = function()
		local chosen = AppearanceDefs.option(choices, (current :: any)[category.id])
		value.Text = chosen.label
	end
end

--[[ The panel ]]

local function redrawAll()
	for _, refresh in refreshers do
		refresh()
	end
end

-- Builds the whole panel: a row per category in CATEGORIES, in order, and
-- a Done button. Called once at startup and then only shown and hidden —
-- the rows are not rebuilt when the look changes, only their selections.
local function build(gui: ScreenGui): Frame
	local frame = Instance.new("Frame")
	frame.Name = "CharacterEditor"
	frame.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
	-- Off to the left, so the character it is editing is not behind it.
	frame.Position = UDim2.new(0, 40, 0.5, 0)
	frame.AnchorPoint = Vector2.new(0, 0.5)
	frame.BackgroundColor3 = PANEL_COLOR
	frame.BackgroundTransparency = 0.08
	frame.Visible = false
	frame.Parent = gui
	stylePanel(frame)

	local heading = Instance.new("TextLabel")
	heading.Size = UDim2.new(1, -20, 0, 26)
	heading.Position = UDim2.fromOffset(14, 12)
	heading.BackgroundTransparency = 1
	heading.Font = Enum.Font.GothamBold
	heading.TextSize = 20
	heading.TextColor3 = CHOSEN
	heading.TextXAlignment = Enum.TextXAlignment.Left
	heading.Text = "The Looking Glass"
	heading.Parent = frame

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, -20, 0, 16)
	hint.Position = UDim2.fromOffset(14, 36)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 12
	hint.TextColor3 = MUTED
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Text = "Changes are saved as you make them."
	hint.Parent = frame

	local scroller = Instance.new("ScrollingFrame")
	scroller.Size = UDim2.new(1, -8, 1, -108)
	scroller.Position = UDim2.fromOffset(4, 62)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 6
	scroller.ScrollBarImageColor3 = PANEL_EDGE
	scroller.Parent = frame

	local y = 4
	for _, category in AppearanceDefs.CATEGORIES do
		if category.kind == "color" then
			buildColorRow(scroller, category, y)
		else
			buildOptionRow(scroller, category, y)
		end
		y += ROW_HEIGHT + 8
	end
	scroller.CanvasSize = UDim2.fromOffset(0, y)

	local done = Instance.new("TextButton")
	done.Size = UDim2.new(1, -28, 0, 34)
	done.Position = UDim2.new(0, 14, 1, -44)
	done.BackgroundColor3 = ROW_COLOR
	done.Font = Enum.Font.GothamBold
	done.TextSize = 16
	done.TextColor3 = CHOSEN
	done.Text = "Done"
	done.Parent = frame
	stylePanel(done, 6)

	done.Activated:Connect(function()
		CharacterEditor.close()
	end)

	return frame
end

-- Hides the panel and releases the Escape binding. Safe to call when
-- already closed.
function CharacterEditor.close()
	local frame = panel
	if not frame or not open then
		return
	end
	open = false
	ContextActionService:UnbindAction(CLOSE_ACTION)

	TweenService:Create(frame, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
	task.delay(0.12, function()
		if not open then
			frame.Visible = false
			frame.BackgroundTransparency = 0.08
		end
	end)
end

-- Shows the panel, starting from the look the server just sent. Binds
-- Escape as well as the Done button — Roblox's own menu takes that key
-- first, so the button is the affordance that always works.
function CharacterEditor.openWith(look: AppearanceDefs.Look?)
	local frame = panel
	if not frame then
		return
	end

	if look then
		current = AppearanceDefs.sanitize(look)
	end
	redrawAll()

	open = true
	frame.Visible = true

	-- Escape as well as the button, never instead of it. Escape is the Roblox
	-- menu's key first and this panel's second, and when the engine keeps it a
	-- panel with no button on it cannot be closed at all — which the loot panel
	-- found out the hard way.
	ContextActionService:BindAction(CLOSE_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			CharacterEditor.close()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Escape)
end

-- Builds the panel and listens for the two server events that drive it:
-- the look changing, and the looking glass telling this client to open.
function CharacterEditor.start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "CharacterEditorGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	panel = build(gui)
	redrawAll()

	-- The server's word on what the look is, whether it changed because this
	-- player edited it or because their profile just loaded.
	Remotes.get("AppearanceChanged").OnClientEvent:Connect(function(payload)
		current = AppearanceDefs.sanitize(payload and payload.appearance)
		redrawAll()
	end)

	Remotes.get("OpenAppearanceEditor").OnClientEvent:Connect(function(payload)
		CharacterEditor.openWith(payload and payload.appearance)
	end)
end

return CharacterEditor
