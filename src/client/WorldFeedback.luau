--!strict
-- Feedback drawn in the world rather than on the screen: enemy health bars,
-- floating damage numbers, and the flash and sparks of a landed parry or hit.
--
-- Everything here is created on this client only and renders what the server
-- already reported; nothing here decides an outcome. Gray-box on purpose — no
-- uploaded assets, only Roblox's built-in defaults — until real art arrives.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local EnemyDefs = require(Shared.EnemyDefs)
local Remotes = require(Shared.Remotes)

local WorldFeedback = {}

-- Server-side EnemyAI tags every enemy model with this.
local ENEMY_TAG = "Enemy"

local BAR_WIDTH = 120
local BAR_MAX_DISTANCE = 70

local HIT_COLOR = Color3.fromRGB(255, 90, 90)
local PARRY_COLOR = Color3.fromRGB(255, 255, 255)
local RIPOSTE_COLOR = Color3.fromRGB(255, 190, 90)
local HIT_SPARK_COLOR = Color3.fromRGB(255, 225, 170)

type Bar = {
	gui: BillboardGui,
	fill: Frame,
}

type Health = {
	health: number,
	maxHealth: number,
	alive: boolean,
}

local bars: { [string]: Bar } = {}
-- Latest reported health, kept even for enemies whose model this client
-- doesn't have yet, so a bar can be built the moment one appears.
local healthById: { [string]: Health } = {}
local guiParent: Instance

-- The model for an enemy id, by tag. By tag rather than by scanning
-- Workspace: dungeon enemies live inside a folder, not at the top level.
local function findEnemyModel(enemyId: string): Model?
	for _, tagged in CollectionService:GetTagged(ENEMY_TAG) do
		if tagged:IsA("Model") and tagged:GetAttribute("EnemyId") == enemyId then
			return tagged
		end
	end

	return nil
end

--[[ Health bars ]]

local function applyHealth(bar: Bar, health: Health)
	local fraction = if health.maxHealth > 0 then math.clamp(health.health / health.maxHealth, 0, 1) else 0
	bar.fill.Size = UDim2.fromScale(fraction, 1)
	bar.gui.Enabled = health.alive
end

-- The floating health bar over one enemy, or nil if its rig has no root
-- to hang from yet.
local function buildBar(model: Model, enemyId: string): Bar?
	local root = model.PrimaryPart
	if not root then
		return nil
	end

	local defId = model:GetAttribute("EnemyDefId")
	local def = if typeof(defId) == "string" then EnemyDefs[defId] else nil

	local gui = Instance.new("BillboardGui")
	gui.Name = `HealthBar_{enemyId}`
	gui.Adornee = root
	gui.Size = UDim2.fromOffset(BAR_WIDTH, 30)
	gui.StudsOffset = Vector3.new(0, root.Size.Y / 2 + 1.5, 0)
	gui.MaxDistance = BAR_MAX_DISTANCE
	-- Lives under PlayerGui, which would otherwise rebuild it on every respawn.
	gui.ResetOnSpawn = false
	gui.Parent = guiParent

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, 0, 0, 16)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.SourceSansBold
	name.TextSize = 14
	name.TextColor3 = Color3.fromRGB(255, 255, 255)
	name.TextStrokeTransparency = 0.4
	name.Text = if def then def.displayName else enemyId
	name.Parent = gui

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 8)
	track.Position = UDim2.fromOffset(0, 18)
	track.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	track.BorderSizePixel = 0
	track.Parent = gui

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(200, 55, 55)
	fill.BorderSizePixel = 0
	fill.Parent = track

	local bar = { gui = gui, fill = fill }
	bars[enemyId] = bar

	local health = healthById[enemyId]
	if health then
		applyHealth(bar, health)
	end

	return bar
end

-- Gives a newly spawned enemy its health bar.
local function onEnemyAdded(instance: Instance)
	if not instance:IsA("Model") then
		return
	end

	local enemyId = instance:GetAttribute("EnemyId")
	if typeof(enemyId) ~= "string" or bars[enemyId] then
		return
	end

	-- The primary part may replicate a moment after the model itself. Polled
	-- with a limit rather than awaited on a signal, so a model removed in the
	-- meantime doesn't leave this thread waiting forever.
	local waited = 0
	while not instance.PrimaryPart and instance.Parent and waited < 10 do
		waited += task.wait(0.2)
	end

	if instance.PrimaryPart and not bars[enemyId] then
		buildBar(instance, enemyId)
	end
end

-- Takes an enemy's health bar away with its model.
local function onEnemyRemoved(instance: Instance)
	local enemyId = instance:GetAttribute("EnemyId")
	local bar = if typeof(enemyId) == "string" then bars[enemyId] else nil
	if bar then
		bar.gui:Destroy()
		bars[enemyId :: string] = nil
	end
end

--[[ Floating numbers ]]

local function floatText(root: BasePart, text: string, color: Color3, size: number)
	local gui = Instance.new("BillboardGui")
	gui.Adornee = root
	gui.Size = UDim2.fromOffset(160, 40)
	gui.AlwaysOnTop = true
	gui.ResetOnSpawn = false

	-- A little sideways scatter so rapid hits don't stack into one number.
	local startOffset = Vector3.new((math.random() - 0.5) * 2, root.Size.Y / 2 + 2.5, 0)
	gui.StudsOffset = startOffset
	gui.Parent = guiParent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = size
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.Text = text
	label.Parent = gui

	-- Pops in oversized and settles, so a number lands like a hit rather than
	-- just appearing.
	local scale = Instance.new("UIScale")
	scale.Scale = 1.8
	scale.Parent = label
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	-- Arcs up and off to one side.
	local drift = Vector3.new((math.random() - 0.5) * 3, 3, 0)
	local rise = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, rise, { StudsOffset = startOffset + drift }):Play()
	TweenService:Create(label, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.55), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()

	task.delay(0.95, function()
		gui:Destroy()
	end)
end

--[[ Flashes and sparks ]]

local function flash(model: Model, color: Color3, duration: number)
	local highlight = Instance.new("Highlight")
	highlight.Adornee = model
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = 0.25
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	-- Under the model it lights, so it can't outlive it. Still created by this
	-- client, so only this player sees it.
	highlight.Parent = model

	TweenService:Create(highlight, TweenInfo.new(duration), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	}):Play()

	task.delay(duration + 0.05, function()
		highlight:Destroy()
	end)
end

-- A one-shot burst using ParticleEmitter's built-in default texture, so no
-- asset upload is needed.
local function sparks(root: BasePart, color: Color3, count: number?)
	local attachment = Instance.new("Attachment")
	attachment.Parent = root

	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 1
	emitter.Lifetime = NumberRange.new(0.25, 0.45)
	emitter.Speed = NumberRange.new(14, 24)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.5, 0)
	emitter.Drag = 4
	emitter.Parent = attachment

	emitter:Emit(count or 30)

	task.delay(1, function()
		attachment:Destroy()
	end)
end

-- Textures that ship inside the Roblox client, so none need uploading.
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

-- A free-standing point in the world to emit from, cleaned up after `life`.
local function worldEmitterAt(position: Vector3, life: number): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Position = position
	-- Terrain sits at the origin, so Position here is a world position.
	attachment.Parent = Workspace.Terrain
	task.delay(life, function()
		attachment:Destroy()
	end)
	return attachment
end

-- A brief light at a point, for flashes that should light up the room.
local function lightFlash(parent: Instance, color: Color3, brightness: number, range: number, seconds: number)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = parent
	TweenService:Create(light, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()
	task.delay(seconds + 0.05, function()
		light:Destroy()
	end)
end

-- A flat ring expanding across the floor from `center`.
local function ring(center: Vector3, radius: number, color: Color3, seconds: number)
	local part = Instance.new("Part")
	part.Name = "Shockwave"
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.15
	part.Size = Vector3.new(0.12, radius * 0.4, radius * 0.4)
	-- A cylinder's axis runs along its X, so rolling it 90 degrees lays it flat.
	part.CFrame = CFrame.new(center + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	part.Parent = Workspace

	TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.12, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()

	task.delay(seconds + 0.05, function()
		part:Destroy()
	end)
end

-- A heavy blow landing on the ground: a ring out to the real hit radius, a
-- ring of dust and a flash of light. Drawn at impact, when the danger zone
-- disappears, so the player sees exactly what just hit.
function WorldFeedback.shockwave(floorPosition: Vector3, radius: number, color: Color3)
	ring(floorPosition, radius, color, 0.45)
	ring(floorPosition, radius * 0.7, Color3.fromRGB(255, 255, 255), 0.3)

	local attachment = worldEmitterAt(floorPosition + Vector3.new(0, 0.5, 0), 3)
	lightFlash(attachment, color, 4, radius * 1.5, 0.4)

	local dust = Instance.new("ParticleEmitter")
	dust.Enabled = false
	dust.Texture = SMOKE_TEXTURE
	dust.Color = ColorSequence.new(Color3.fromRGB(150, 140, 125))
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.5),
		NumberSequenceKeypoint.new(1, 4.5),
	})
	dust.Lifetime = NumberRange.new(0.8, 1.4)
	dust.Speed = NumberRange.new(radius * 1.2, radius * 1.8)
	dust.Drag = 3
	-- Flat out across the floor in every direction.
	dust.EmissionDirection = Enum.NormalId.Top
	dust.SpreadAngle = Vector2.new(90, 5)
	dust.Rotation = NumberRange.new(0, 360)
	dust.RotSpeed = NumberRange.new(-40, 40)
	dust.Parent = attachment
	dust:Emit(40)
end

-- A short word popping off a player or enemy: BLOCK, GUARD BROKEN.
function WorldFeedback.popText(root: BasePart, text: string, color: Color3, size: number)
	floatText(root, text, color, size)
end

-- Sparks off a guard that took a hit.
function WorldFeedback.guardSparks(root: BasePart, color: Color3)
	sparks(root, color, 18)
end

-- An enemy going down: a puff of dark smoke and a scatter of embers.
function WorldFeedback.deathBurst(root: BasePart)
	local attachment = worldEmitterAt(root.Position, 3)

	local smoke = Instance.new("ParticleEmitter")
	smoke.Enabled = false
	smoke.Texture = SMOKE_TEXTURE
	smoke.Color = ColorSequence.new(Color3.fromRGB(40, 36, 44))
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(1, 5),
	})
	smoke.Lifetime = NumberRange.new(0.9, 1.6)
	smoke.Speed = NumberRange.new(3, 7)
	smoke.SpreadAngle = Vector2.new(180, 180)
	smoke.Drag = 2
	smoke.Acceleration = Vector3.new(0, 3, 0)
	smoke.Rotation = NumberRange.new(0, 360)
	smoke.Parent = attachment
	smoke:Emit(18)

	local embers = Instance.new("ParticleEmitter")
	embers.Enabled = false
	embers.Texture = SPARKLE_TEXTURE
	embers.Color = ColorSequence.new(Color3.fromRGB(255, 170, 70))
	embers.LightEmission = 1
	embers.Size = NumberSequence.new(0.35, 0)
	embers.Lifetime = NumberRange.new(0.6, 1.1)
	embers.Speed = NumberRange.new(8, 16)
	embers.SpreadAngle = Vector2.new(180, 180)
	embers.Acceleration = Vector3.new(0, -20, 0)
	embers.Drag = 1
	embers.Parent = attachment
	embers:Emit(24)
end

-- Green motes rising around a healed character.
function WorldFeedback.healMotes(root: BasePart)
	local attachment = Instance.new("Attachment")
	attachment.Position = Vector3.new(0, -1.5, 0)
	attachment.Parent = root
	task.delay(2, function()
		attachment:Destroy()
	end)

	local motes = Instance.new("ParticleEmitter")
	motes.Enabled = false
	motes.Texture = SPARKLE_TEXTURE
	motes.Color = ColorSequence.new(Color3.fromRGB(120, 255, 160))
	motes.LightEmission = 1
	motes.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	motes.Lifetime = NumberRange.new(0.8, 1.2)
	motes.Speed = NumberRange.new(3, 6)
	motes.EmissionDirection = Enum.NormalId.Top
	motes.SpreadAngle = Vector2.new(35, 35)
	motes.Parent = attachment
	motes:Emit(26)

	lightFlash(attachment, Color3.fromRGB(120, 255, 160), 3, 14, 0.6)
end

-- Starts the world-space feedback: health bars, damage numbers, hit and
-- parry sparks, shockwaves, death bursts and heal motes. All of it is
-- this client's own view; none of it is replicated.
function WorldFeedback.start()
	guiParent = Players.LocalPlayer:WaitForChild("PlayerGui")

	CollectionService:GetInstanceAddedSignal(ENEMY_TAG):Connect(onEnemyAdded)
	CollectionService:GetInstanceRemovedSignal(ENEMY_TAG):Connect(onEnemyRemoved)
	for _, instance in CollectionService:GetTagged(ENEMY_TAG) do
		task.spawn(onEnemyAdded, instance)
	end

	Remotes.get("EnemyHealthChanged").OnClientEvent:Connect(function(payload)
		local health: Health = {
			health = payload.health,
			maxHealth = payload.maxHealth,
			alive = payload.alive,
		}
		healthById[payload.enemyId] = health

		local bar = bars[payload.enemyId]
		if bar then
			applyHealth(bar, health)
		end
	end)

	-- Only your own hits: AttackResult goes to the attacker alone.
	Remotes.get("AttackResult").OnClientEvent:Connect(function(payload)
		if not payload.hit or typeof(payload.enemyId) ~= "string" then
			return
		end

		local model = findEnemyModel(payload.enemyId)
		local root = model and model.PrimaryPart
		if not model or not root then
			return
		end

		local text = tostring(math.floor(payload.damage + 0.5))
		if payload.riposte then
			floatText(root, `{text}!`, RIPOSTE_COLOR, 34)
			sparks(root, RIPOSTE_COLOR, 28)
		else
			floatText(root, text, Color3.fromRGB(255, 255, 255), 26)
			sparks(root, HIT_SPARK_COLOR, 12)
		end

		flash(model, HIT_COLOR, 0.15)
	end)

	-- A landed parry against an enemy: the moment the whole system is built
	-- around, so it gets the biggest reaction. A duel parry names a player
	-- rather than an enemy and finds no model here, which is fine — GameUI
	-- covers duels.
	Remotes.get("ParryResult").OnClientEvent:Connect(function(payload)
		if not payload.success or typeof(payload.enemyId) ~= "string" then
			return
		end

		local model = findEnemyModel(payload.enemyId)
		local root = model and model.PrimaryPart
		if not model or not root then
			return
		end

		-- Sparks and a flash of light where the blades met; no text, no ring.
		sparks(root, PARRY_COLOR, 40)
		flash(model, PARRY_COLOR, 0.2)
		lightFlash(root, Color3.fromRGB(255, 240, 210), 5, 16, 0.25)
	end)
end

return WorldFeedback
