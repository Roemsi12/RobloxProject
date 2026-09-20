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

-- R6 avatars have no hands, forearms or a split torso; the nearest whole part
-- stands in.
local R6_FALLBACK: { [string]: string } = {
	RightHand = "Right Arm",
	LeftHand = "Left Arm",
	LeftLowerArm = "Left Arm",
	RightLowerArm = "Right Arm",
	UpperTorso = "Torso",
	LowerTorso = "Torso",
}

-- Where a hand holds things, if the avatar says.
local GRIP_ATTACHMENT: { [string]: string } = {
	RightHand = "RightGripAttachment",
	LeftHand = "LeftGripAttachment",
}

-- A palette colour ({0-255, 0-255, 0-255}) as a Color3. Every colour in the
-- data files is a plain table so those files stay Roblox-free.
local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

-- A three-number table as a Vector3, for sizes and offsets out of data files.
local function vec(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

-- The piece's offset from the part it hangs from, in that part's space.
local function pieceOffset(piece: WeaponModelDefs.PieceDef): CFrame
	local rotation = piece.rotation or { 0, 0, 0 }
	return CFrame.new(vec(piece.offset))
		* CFrame.Angles(math.rad(rotation[1]), math.rad(rotation[2]), math.rad(rotation[3]))
end

-- One piece of a weapon as a Part, including its upgrade glow: a light, a
-- sparkle emitter and eventually Neon, from the weapon's level.
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

-- The part a piece should hang on, and whether it is an R6 stand-in.
-- R6 avatars have no hands, forearms or split torso, so the nearest whole
-- part is used and the caller adjusts.
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

-- Removes the weapon model and clears the character's weapon attribute.
-- Clearing the attribute matters: every client picks a player's stance
-- from it, and a stale one leaves them posed around a weapon they no
-- longer hold.
local function detach(character: Model)
	local existing = character:FindFirstChild(WeaponModelDefs.MODEL_NAME)
	if existing then
		existing:Destroy()
	end
	character:SetAttribute(WeaponModelDefs.WEAPON_ATTRIBUTE, nil)
end

-- Builds a weapon onto a character and marks what they are carrying.
-- Replaces whatever was there. A weapon with no model in WeaponModelDefs
-- still sets the attribute, so the stance is right even with nothing drawn.
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
		--
		-- That shift is for hands only. A piece hanging off the torso — a
		-- quiver, a sheath — is already placed against the middle of the part
		-- it is on, and dropping it half a torso on an R6 body would put it
		-- through the hips.
		local anchor = CFrame.identity
		local gripName = GRIP_ATTACHMENT[piece.attachTo]
		local grip = gripName and part0:FindFirstChild(gripName)
		if grip and grip:IsA("Attachment") then
			anchor = CFrame.new(grip.Position)
		elseif isFallback and gripName then
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

-- Redraws whatever the player is currently equipped with, at its current
-- upgrade level. Called on equip, on upgrade and on respawn.
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

-- Redraws a player's weapon on every new character. Waits for the arm
-- parts first — they can arrive a moment after the character itself, and
-- welding to a part that is not there yet silently drops the piece.
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

-- Keeps every player's drawn weapon in step with what they have equipped.
-- Started before any profile loads, so a saved weapon is in hand from the
-- first frame.
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
