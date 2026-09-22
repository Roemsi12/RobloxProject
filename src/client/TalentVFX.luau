--!strict
-- What the skill-tree mechanics look like, where a number alone would not say
-- what happened: a chain of power leaping between enemies (`chainArc`), and a
-- mark hanging over an enemy a Ranger's critical has singled out
-- (`markOnCrit`).
--
-- Purely a picture of what the server already did. The damage shows as it
-- always does, through health bars and damage numbers.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Palette = require(Shared.Palette)
local Remotes = require(Shared.Remotes)

local TalentVFX = {}

local ENEMY_TAG = "Enemy"
local MARK_NAME = "QuarryMark"

-- How high above an enemy's root its mark floats, and how high on its body an
-- arc strikes.
local MARK_HEIGHT = 4.5
local ARC_HEIGHT = 1.5
-- How far a leaping arc kinks sideways, and how long it lingers.
local ARC_JITTER = 0.9
local ARC_LIFETIME = 0.22

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local ARC_COLOR = rgb(Palette.ARCANE)
local MARK_COLOR = rgb(Palette.CRIMSON)

local folder: Folder? = nil

local function effectFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "TalentVFX"
	created.Parent = Workspace
	folder = created
	return created
end

local function findEnemyModel(enemyId: string): Model?
	for _, tagged in CollectionService:GetTagged(ENEMY_TAG) do
		if tagged:IsA("Model") and tagged:GetAttribute("EnemyId") == enemyId then
			return tagged
		end
	end
	return nil
end

-- A lightning-like arc from one point to another: a few straight segments
-- with the joints pushed off the line, bright and gone in a blink.
local function arc(from: Vector3, to: Vector3)
	local start = from + Vector3.new(0, ARC_HEIGHT, 0)
	local finish = to + Vector3.new(0, ARC_HEIGHT, 0)
	local points = { start }
	local segments = 4
	for index = 1, segments - 1 do
		local along = start:Lerp(finish, index / segments)
		local jitter = Vector3.new(
			(math.random() - 0.5) * 2 * ARC_JITTER,
			(math.random() - 0.5) * 2 * ARC_JITTER,
			(math.random() - 0.5) * 2 * ARC_JITTER
		)
		table.insert(points, along + jitter)
	end
	table.insert(points, finish)

	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local segment = Instance.new("Part")
		segment.Anchored = true
		segment.CanCollide = false
		segment.CanQuery = false
		segment.CanTouch = false
		segment.CastShadow = false
		segment.Material = Enum.Material.Neon
		segment.Color = ARC_COLOR
		segment.Size = Vector3.new(0.14, 0.14, (b - a).Magnitude)
		segment.CFrame = CFrame.lookAt((a + b) / 2, b)
		segment.Parent = effectFolder()
		TweenService:Create(segment, TweenInfo.new(ARC_LIFETIME), { Transparency = 1, Size = Vector3.new(0.04, 0.04, segment.Size.Z) }):Play()
		Debris:AddItem(segment, ARC_LIFETIME + 0.05)
	end
end

-- A mark over an enemy for `duration` seconds. A second mark on the same
-- enemy replaces the first rather than stacking a second icon on it.
local function mark(enemyId: string, duration: number)
	local model = findEnemyModel(enemyId)
	local root = model and model.PrimaryPart
	if not model or not root then
		return
	end

	local existing = model:FindFirstChild(MARK_NAME)
	if existing then
		existing:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = MARK_NAME
	billboard.Adornee = root
	billboard.Size = UDim2.fromOffset(34, 34)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, MARK_HEIGHT, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0

	-- A diamond: the shape a hunter's mark reads as at any size.
	local diamond = Instance.new("Frame")
	diamond.AnchorPoint = Vector2.new(0.5, 0.5)
	diamond.Position = UDim2.fromScale(0.5, 0.5)
	diamond.Size = UDim2.fromScale(0.62, 0.62)
	diamond.Rotation = 45
	diamond.BackgroundColor3 = MARK_COLOR
	diamond.BorderSizePixel = 0
	diamond.Parent = billboard
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 235, 200)
	stroke.Thickness = 2
	stroke.Parent = diamond

	billboard.Parent = model

	-- Fades over its last second, so the end of it can be seen coming.
	TweenService:Create(diamond, TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, math.max(duration - 1, 0)), {
		BackgroundTransparency = 1,
	}):Play()
	Debris:AddItem(billboard, duration)
end

function TalentVFX.start()
	Remotes.get("ChainArc").OnClientEvent:Connect(function(payload)
		if typeof(payload.from) == "Vector3" and typeof(payload.to) == "Vector3" then
			arc(payload.from, payload.to)
		end
	end)
	Remotes.get("EnemyMarked").OnClientEvent:Connect(function(payload)
		if type(payload.enemyId) == "string" and type(payload.duration) == "number" then
			mark(payload.enemyId, payload.duration)
		end
	end)
end

return TalentVFX
