--!strict
-- What an enemy's state looks like beyond its animation: a red flash when it
-- starts an attack that can't be parried, a danger zone under attacks that hit
-- all around, a tint while it's staggered by a parry, and grey once dead.
--
-- A parryable attack gets a glint, not a prompt: its weapon catches the light
-- and flickers through the windup, building toward the hit. The read is still
-- the windup pose — the archetype tells you what is coming and the glint only
-- says when, on the weapon itself rather than in a corner of the screen. It is
-- deliberately slight. A cue loud enough to parry off on its own would replace
-- the thing the telegraph system exists to test — see DESIGN.md, which records
-- why the closing ring and the wind-up glow were removed and why this is not
-- them coming back.
--
-- The two cues do different jobs and look nothing alike, which is the point:
-- a red flash over the whole rig means the answer has changed (dodge, don't
-- block), and a glint on the blade means the usual answer, now.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local EnemyDefs = require(Shared.EnemyDefs)
local Remotes = require(Shared.Remotes)
local RigDefs = require(Shared.RigDefs)

local TelegraphVFX = {}

local UNPARRYABLE_COLOR = Color3.fromRGB(255, 40, 30)
local STAGGER_COLOR = Color3.fromRGB(90, 130, 255)
local DEAD_COLOR = Color3.fromRGB(40, 40, 40)

-- How long the unparryable flash takes to fade.
local FLASH_FADE = 0.45
local STAGGER_STRENGTH = 0.35
local DEAD_STRENGTH = 0.85

-- Server-side EnemyAI tags every enemy model with this.
local ENEMY_TAG = "Enemy"

-- Danger zones: a flat disc covering the attack's real hit volume, filling in
-- toward impact and gone shortly after.
local ZONE_THICKNESS = 0.15
local ZONE_START_TRANSPARENCY = 0.9
local ZONE_END_TRANSPARENCY = 0.5
local ZONE_LINGER = 0.2

-- The glint on a parryable weapon.
--
-- Multiplied rather than blended toward a colour of its own, so every weapon
-- glints as its own material: a steel edge flares, a leather grip barely
-- moves, bone and claw come up dull. A small part is added on top so a nearly
-- black blade still shows something.
local GLINT_GAIN = 0.55
local GLINT_LIFT = 0.10
-- How sharply it builds toward the hit. Above 1, so most of it happens late.
local GLINT_BUILD = 1.7
-- Two speeds that never line up, so it reads as light catching an unsteady
-- edge rather than something pulsing on a timer.
local GLINT_FAST = 27.3
local GLINT_SLOW = 41.7
-- Gone shortly after the hit, however the hit turned out.
local GLINT_LINGER = 0.12

type Glinting = {
	part: BasePart,
	base: Color3,
}

type Glint = {
	parts: { Glinting },
	-- When the tell has landed and the flicker starts, and when it peaks.
	startTime: number,
	impactTime: number,
}

type Zone = {
	part: Part,
	startTime: number,
	impactTime: number,
}

-- enemyId -> its danger zone, while one is up.
local zones: { [string]: Zone } = {}
-- enemyId -> its weapon's glint, while a parryable attack winds up.
local glints: { [string]: Glint } = {}
-- enemyId -> client clock time the stagger tint should clear.
local staggeredUntil: { [string]: number } = {}
local dead: { [string]: boolean } = {}
local tints: { [string]: Highlight } = {}

-- By tag rather than by scanning Workspace: dungeon enemies live inside a
-- folder, not at the top level.
local function findEnemyModel(enemyId: string): Model?
	for _, tagged in CollectionService:GetTagged(ENEMY_TAG) do
		if tagged:IsA("Model") and tagged:GetAttribute("EnemyId") == enemyId then
			return tagged
		end
	end
	return nil
end

-- The standing tint (stagger or death), one per enemy, parented to the rig so
-- it goes when the rig does.
local function tintFor(enemyId: string, model: Model): Highlight
	local existing = tints[enemyId]
	if existing and existing.Parent == model then
		return existing
	end

	local tint = Instance.new("Highlight")
	tint.Name = "StateTint"
	tint.Adornee = model
	tint.DepthMode = Enum.HighlightDepthMode.Occluded
	tint.Enabled = false
	tint.Parent = model

	tints[enemyId] = tint
	return tint
end

local function settle(enemyId: string, model: Model)
	local tint = tintFor(enemyId, model)

	local color: Color3? = nil
	local strength = 0
	if dead[enemyId] then
		color, strength = DEAD_COLOR, DEAD_STRENGTH
	else
		local until_ = staggeredUntil[enemyId]
		if until_ and os.clock() < until_ then
			color, strength = STAGGER_COLOR, STAGGER_STRENGTH
		end
	end

	if not color then
		tint.Enabled = false
		return
	end

	tint.Enabled = true
	tint.FillColor = color
	tint.OutlineColor = color
	tint.FillTransparency = 1 - strength * 0.7
	tint.OutlineTransparency = 1 - strength
end

-- A quick red flash over the whole rig: "this one can't be parried".
local function flashUnparryable(model: Model)
	local flash = Instance.new("Highlight")
	flash.Name = "UnparryableFlash"
	flash.Adornee = model
	flash.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	flash.FillColor = UNPARRYABLE_COLOR
	flash.OutlineColor = UNPARRYABLE_COLOR
	flash.FillTransparency = 0.35
	flash.OutlineTransparency = 0
	flash.Parent = model

	TweenService:Create(flash, TweenInfo.new(FLASH_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	}):Play()
	task.delay(FLASH_FADE + 0.05, function()
		flash:Destroy()
	end)
end

-- A disc on the floor under the enemy, sized to the attack's hit volume. Only
-- for attacks that hit all around: their radius can be larger than the range
-- they're used from, so without it there's no way to know how far to go.
-- Created on this client only.
local function makeZone(root: BasePart, radius: number): Part
	local part = Instance.new("Part")
	part.Name = "DangerZone"
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = UNPARRYABLE_COLOR
	part.Transparency = ZONE_START_TRANSPARENCY
	part.Size = Vector3.new(ZONE_THICKNESS, radius * 2, radius * 2)

	local floorY = root.Position.Y - root.Size.Y / 2
	-- A cylinder's axis runs along its X, so rolling it 90 degrees lays it flat.
	part.CFrame = CFrame.new(root.Position.X, floorY + ZONE_THICKNESS / 2 + 0.02, root.Position.Z)
		* CFrame.Angles(0, 0, math.rad(90))
	part.Parent = Workspace
	return part
end

local function clearZone(enemyId: string)
	local zone = zones[enemyId]
	if zone then
		zone.part:Destroy()
		zones[enemyId] = nil
	end
end

-- Puts every glinting part back to the colour it was built with.
--
-- Always through here, and always from the colour recorded when the glint
-- started: a part left bright is a permanently glowing sword, and this is a
-- local change to a replicated rig, so nothing from the server will come along
-- and correct it.
local function clearGlint(enemyId: string)
	local glint = glints[enemyId]
	if not glint then
		return
	end

	for _, glinting in glint.parts do
		if glinting.part.Parent then
			glinting.part.Color = glinting.base
		end
	end
	glints[enemyId] = nil
end

-- The weapon's parts, with the colours to put back afterwards.
local function glintingParts(model: Model, rigId: string): { Glinting }
	local found: { Glinting } = {}
	for _, name in RigDefs.weaponParts(rigId) do
		local part = model:FindFirstChild(name, true)
		if part and part:IsA("BasePart") then
			table.insert(found, { part = part, base = part.Color })
		end
	end
	return found
end

-- How much the weapon is catching the light at this moment: the two speeds
-- beating against each other, under a build toward the hit.
local function glintAt(glint: Glint, now: number): number
	local windup = glint.impactTime - glint.startTime
	local build = if windup > 0 then math.clamp((now - glint.startTime) / windup, 0, 1) else 1
	local elapsed = now - glint.startTime
	local wave = math.sin(elapsed * GLINT_FAST) * 0.6 + math.sin(elapsed * GLINT_SLOW) * 0.4
	return build ^ GLINT_BUILD * (0.5 + 0.5 * wave)
end

function TelegraphVFX.start()
	Remotes.get("EnemyTelegraphStart").OnClientEvent:Connect(function(payload)
		clearZone(payload.enemyId)
		clearGlint(payload.enemyId)
		staggeredUntil[payload.enemyId] = nil

		local model = findEnemyModel(payload.enemyId)
		local root = model and model.PrimaryPart
		if not model or not root then
			return
		end
		settle(payload.enemyId, model)

		local defId = model:GetAttribute("EnemyDefId")
		local def = if typeof(defId) == "string" then EnemyDefs[defId] else nil
		local attack = def and def.attacks[payload.attackId]

		if payload.parryable then
			-- From the moment the tell has landed, not from the start of the
			-- windup. An attack still snapping into its pose is not yet
			-- readable, and a glint that starts before the silhouette does
			-- would be telling the player to parry something they cannot see
			-- yet. `telegraphDuration` is `leadTime` plus exactly that beat,
			-- so what is left of it is the beat itself.
			local settleTime = if attack then math.max(payload.duration - attack.leadTime, 0) else 0
			local parts = if typeof(defId) == "string" then glintingParts(model, defId) else {}
			if #parts > 0 then
				glints[payload.enemyId] = {
					parts = parts,
					startTime = payload.impactTime - payload.duration + settleTime,
					impactTime = payload.impactTime,
				}
			end
			return
		end

		flashUnparryable(model)

		if attack and attack.arcDegrees >= 360 then
			zones[payload.enemyId] = {
				part = makeZone(root, attack.range),
				startTime = payload.impactTime - payload.duration,
				impactTime = payload.impactTime,
			}
		end
	end)

	Remotes.get("EnemyStaggered").OnClientEvent:Connect(function(payload)
		clearZone(payload.enemyId)
		-- Whether it was parried or merely flinched, the swing it was building
		-- toward isn't coming: the weapon stops glinting for it.
		clearGlint(payload.enemyId)

		-- A flinch shows as the rig's hurt animation; only a parry's stagger
		-- tints, marking the punish window.
		if payload.kind ~= "stagger" then
			return
		end

		-- Tracked rather than just painted, so a punish hit landing during the
		-- stagger doesn't clear the tint.
		staggeredUntil[payload.enemyId] = os.clock() + payload.duration
		local model = findEnemyModel(payload.enemyId)
		if model then
			settle(payload.enemyId, model)
		end
	end)

	Remotes.get("EnemyHealthChanged").OnClientEvent:Connect(function(payload)
		dead[payload.enemyId] = not payload.alive or nil
		if not payload.alive then
			staggeredUntil[payload.enemyId] = nil
			clearZone(payload.enemyId)
			clearGlint(payload.enemyId)
		end

		local model = findEnemyModel(payload.enemyId)
		if model then
			settle(payload.enemyId, model)
		end
	end)

	RunService.RenderStepped:Connect(function()
		local now = Workspace:GetServerTimeNow()

		for enemyId, zone in zones do
			if not zone.part.Parent or now > zone.impactTime + ZONE_LINGER then
				clearZone(enemyId)
				continue
			end

			local duration = zone.impactTime - zone.startTime
			local t = if duration > 0 then math.clamp((now - zone.startTime) / duration, 0, 1) else 1
			zone.part.Transparency = ZONE_START_TRANSPARENCY + (ZONE_END_TRANSPARENCY - ZONE_START_TRANSPARENCY) * t
		end

		for enemyId, glint in glints do
			if now > glint.impactTime + GLINT_LINGER then
				clearGlint(enemyId)
				continue
			end

			local strength = glintAt(glint, now)
			for _, glinting in glint.parts do
				local part = glinting.part
				if not part.Parent then
					continue
				end
				local base = glinting.base
				local gain = 1 + GLINT_GAIN * strength
				local lift = GLINT_LIFT * strength
				part.Color = Color3.new(
					math.min(base.R * gain + lift, 1),
					math.min(base.G * gain + lift, 1),
					math.min(base.B * gain + lift, 1)
				)
			end
		end

		-- Clear stagger tints whose time is up.
		local clock = os.clock()
		for enemyId, until_ in staggeredUntil do
			if clock >= until_ then
				staggeredUntil[enemyId] = nil
				local model = findEnemyModel(enemyId)
				if model then
					settle(enemyId, model)
				end
			end
		end
	end)
end

return TelegraphVFX
