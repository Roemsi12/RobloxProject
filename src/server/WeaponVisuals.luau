--!strict
-- Builds weapon models from WeaponModelDefs: in each player's hands, and on
-- display above the class altars.
--
-- Server-built so every player sees what everyone else is holding. Pieces are
-- welded, massless and non-colliding, so they never change how a character
-- moves or what combat hit-reg reads (that uses the HumanoidRootPart only).
-- The character also carries the weapon's id as an attribute, which every
-- client reads to pick that player's fighting stance.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponModelDefs = require(ReplicatedStorage.Shared.WeaponModelDefs)

local EquipService = require(script.Parent.EquipService)

local WeaponVisuals = {}

-- R6 avatars have no hands or forearms; the nearest whole arm stands in.
local R6_FALLBACK: { [string]: string } = {
	RightHand = "Right Arm",
	LeftHand = "Left Arm",
	LeftLowerArm = "Left Arm",
	RightLowerArm = "Right Arm",
}

-- Where a hand holds things, if the avatar says.
local GRIP_ATTACHMENT: { [string]: string } = {
	RightHand = "RightGripAttachment",
	LeftHand = "LeftGripAttachment",
}

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local function vec(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

-- The piece's offset from the part it hangs from, in that part's space.
local function pieceOffset(piece: WeaponModelDefs.PieceDef): CFrame
	local rotation = piece.rotation or { 0, 0, 0 }
	return CFrame.new(vec(piece.offset))
		* CFrame.Angles(math.rad(rotation[1]), math.rad(rotation[2]), math.rad(rotation[3]))
end

local function makePiece(piece: WeaponModelDefs.PieceDef, def: WeaponModelDefs.WeaponModelDef, level: number): Part
	local part = Instance.new("Part")
	part.Name = piece.name
	part.Size = vec(piece.size)
	part.Color = rgb(piece.color)
	part.Material = (Enum.Material :: any)[piece.material or "SmoothPlastic"]
	part.Shape = (Enum.PartType :: any)[piece.shape or "Block"]
	part.Transparency = piece.transparency or 0
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	if piece.glow then
		local look = WeaponModelDefs.upgradeLook(level)
		local glowColor = rgb(def.glowColor)

		if look.neon then
			part.Material = Enum.Material.Neon
			part.Color = glowColor
		end

		if look.lightBrightness > 0 then
			local light = Instance.new("PointLight")
			light.Color = glowColor
			light.Brightness = look.lightBrightness
			light.Range = 8
			light.Shadows = false
			light.Parent = part
		end

		if look.sparkleRate > 0 then
			local sparkles = Instance.new("ParticleEmitter")
			sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			sparkles.Color = ColorSequence.new(glowColor)
			sparkles.LightEmission = 1
			sparkles.Size = NumberSequence.new(0.25, 0)
			sparkles.Lifetime = NumberRange.new(0.4, 0.8)
			sparkles.Speed = NumberRange.new(0.5, 1.5)
			sparkles.SpreadAngle = Vector2.new(180, 180)
			sparkles.Rate = look.sparkleRate
			sparkles.Parent = part
		end
	end

	return part
end

-- A weapon laid out around a single point, anchored, for a display stand.
-- Pieces keep their positions relative to each other by body part, so the
-- sword and shield of a set are shown side by side rather than overlapping.
function WeaponVisuals.buildDisplay(weaponId: string, cframe: CFrame): Model?
	local def = WeaponModelDefs.MODELS[weaponId]
	if not def then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = `{weaponId}Display`

	-- Each body part's pieces get their own spot along the stand.
	local groupOffsets: { [string]: Vector3 } = {}
	local groupCount = 0
	for _, piece in def.pieces do
		if not groupOffsets[piece.attachTo] then
			groupOffsets[piece.attachTo] = Vector3.new(groupCount * 1.6, 0, 0)
			groupCount += 1
		end
	end
	local centreShift = Vector3.new((groupCount - 1) * 0.8, 0, 0)

	for _, piece in def.pieces do
		local part = makePiece(piece, def, 0)
		part.Anchored = true
		part.CastShadow = false
		part.CFrame = cframe * CFrame.new(groupOffsets[piece.attachTo] - centreShift) * pieceOffset(piece)
		part.Parent = model
	end

	return model
end

local function bodyPart(character: Model, name: string): (BasePart?, boolean)
	local part = character:FindFirstChild(name)
	if part and part:IsA("BasePart") then
		return part, false
	end

	local fallback = R6_FALLBACK[name]
	local r6 = fallback and character:FindFirstChild(fallback)
	if r6 and r6:IsA("BasePart") then
		return r6, true
	end

	return nil, false
end

local function detach(character: Model)
	local existing = character:FindFirstChild(WeaponModelDefs.MODEL_NAME)
	if existing then
		existing:Destroy()
	end
	character:SetAttribute(WeaponModelDefs.WEAPON_ATTRIBUTE, nil)
end

local function attach(character: Model, weaponId: string, level: number)
	detach(character)
	character:SetAttribute(WeaponModelDefs.WEAPON_ATTRIBUTE, weaponId)

	local def = WeaponModelDefs.MODELS[weaponId]
	if not def then
		return
	end

	local model = Instance.new("Model")
	model.Name = WeaponModelDefs.MODEL_NAME

	for _, piece in def.pieces do
		local part0, isFallback = bodyPart(character, piece.attachTo)
		if not part0 then
			continue
		end

		-- Hands hold from their grip point when the avatar has one. On an R6
		-- arm, the hand is at the bottom of the arm.
		local anchor = CFrame.identity
		local gripName = GRIP_ATTACHMENT[piece.attachTo]
		local grip = gripName and part0:FindFirstChild(gripName)
		if grip and grip:IsA("Attachment") then
			anchor = CFrame.new(grip.Position)
		elseif isFallback then
			anchor = CFrame.new(0, -part0.Size.Y / 2, 0)
		end

		local part = makePiece(piece, def, level)
		local c0 = anchor * pieceOffset(piece)
		part.CFrame = part0.CFrame * c0
		part.Parent = model

		local weld = Instance.new("Weld")
		weld.Part0 = part0
		weld.Part1 = part
		weld.C0 = c0
		weld.Parent = part
	end

	model.Parent = character
end

local function refresh(player: Player)
	local character = player.Character
	if not character then
		return
	end

	local weaponId = EquipService.getWeaponId(player)
	if weaponId then
		attach(character, weaponId, EquipService.getUpgradeLevel(player, weaponId))
	else
		detach(character)
	end
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		-- Body parts can arrive a moment after the character itself.
		character:WaitForChild("RightHand", 3)
		character:WaitForChild("LeftLowerArm", 1)
		if player.Character == character then
			refresh(player)
		end
	end)
end

function WeaponVisuals.start()
	EquipService.onChanged(function(player)
		refresh(player)
	end)

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
		task.spawn(refresh, player)
	end
end

return WeaponVisuals
