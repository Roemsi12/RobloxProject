--!strict
-- The look of the world: god rays, depth of field, bloom, haze and a colour
-- grade that changes depending on which building the player is standing in.
--
-- This is the closest Roblox gets to what a shader pack does in Minecraft.
-- There is no way to write a fragment shader here, so the same *result* is put
-- together out of the parts that do exist:
--
--   * volumetric light — `SunRaysEffect` on the screen, and Beam shafts hung
--     under the hub's clerestory windows (`Stonework.lightShaft`), so the
--     light has a visible volume from inside as well as around the sun;
--   * real shadows — every ceiling casts one, which is what turns the sky off
--     indoors and leaves fire doing the lighting;
--   * atmospheric scattering — `Atmosphere`, thickened underground so distance
--     goes grey and the far end of a hall reads as far;
--   * bloom and exposure — light sources bleed, and the whole picture
--     brightens a little as you step out of a corridor into a hall;
--   * depth of field, held very gentle, so the background falls away without
--     making the game look like it is being filmed;
--   * a colour grade per place: the hub is warm and lifted, the dungeon is
--     cold and crushed.
--
-- All of it is created on the client, so every post-processing effect here is
-- this player's own. Nothing in this module is authoritative over anything;
-- turning it off changes only what the picture looks like.
--
-- The one thing it needs from the server is where the hub is, which it reads
-- off the Lobby model's attributes rather than over a remote: the hall never
-- moves, and a joining player gets the attributes with the model.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AtmosphereFX = {}

type Look = {
	-- ColorCorrection.
	brightness: number,
	contrast: number,
	saturation: number,
	tint: Color3,
	-- Atmosphere.
	density: number,
	haze: number,
	glare: number,
	fog: Color3,
	decay: Color3,
	-- Bloom.
	bloom: number,
	bloomThreshold: number,
	-- Screen-space sun shafts, and how far out the picture goes soft.
	rays: number,
	blur: number,
	focus: number,
	-- Lighting.ExposureCompensation.
	exposure: number,
}

-- Above ground, and the only place in the game daylight reaches: warm, open,
-- and far enough to see across that walking back out of a gate feels like
-- relief.
--
-- Exposure and bloom are held *below* the dungeon's, not above. The hall is
-- lit by a dozen windows, three dozen torches, five chandelier rings and
-- fifteen braziers; that much overlapping light is not brighter to the eye
-- than one torch is, it is just white. What makes the hub read as the brighter
-- place is the cold daylight in it and the distance you can see, not the
-- exposure it is graded at.
local HUB: Look = {
	brightness = -0.02,
	contrast = 0.12,
	saturation = -0.02,
	-- Very slightly cool, and deliberately not warm: the place file.s own
	-- ColorGrade already lays a warm tint over everything, and two warm grades
	-- stacked turned the hall.s cold stone floor orange.
	tint = Color3.fromRGB(248, 250, 255),
	density = 0.26,
	haze = 1.0,
	glare = 0.32,
	fog = Color3.fromRGB(126, 120, 136),
	decay = Color3.fromRGB(88, 74, 92),
	bloom = 0.5,
	bloomThreshold = 1.85,
	rays = 0.18,
	blur = 0.2,
	focus = 38,
	exposure = -0.05,
}

-- Underground. Colder, thicker and contrastier: the far end of a hall goes
-- grey, torchlight is the only warm thing in the frame, and the blacks are
-- crushed enough that what a torch does not reach reads as genuinely dark.
local DUNGEON: Look = {
	brightness = -0.03,
	contrast = 0.20,
	saturation = -0.14,
	tint = Color3.fromRGB(236, 243, 255),
	density = 0.46,
	haze = 2.1,
	glare = 0.1,
	fog = Color3.fromRGB(96, 92, 112),
	decay = Color3.fromRGB(54, 46, 68),
	bloom = 0.6,
	bloomThreshold = 1.5,
	rays = 0.05,
	blur = 0.34,
	focus = 24,
	exposure = 0.1,
}

-- How fast the picture settles into a new place, as a fraction of the distance
-- remaining per second. Slow on purpose: this is meant to read as eyes
-- adjusting, and anything quicker reads as a cut.
local ADAPT = 2.2

type Bounds = { minX: number, maxX: number, minZ: number, maxZ: number }

local player = Players.LocalPlayer

local grade: ColorCorrectionEffect
local rays: SunRaysEffect
local depth: DepthOfFieldEffect
local atmosphere: Atmosphere?
local bloom: BloomEffect?

-- The look currently on screen, eased toward whichever preset the player is
-- standing in.
local current: Look = table.clone(DUNGEON)
local hubBounds: Bounds? = nil

local function lerp(from: number, to: number, alpha: number): number
	return from + (to - from) * alpha
end

local function blend(into: Look, target: Look, alpha: number)
	into.brightness = lerp(into.brightness, target.brightness, alpha)
	into.contrast = lerp(into.contrast, target.contrast, alpha)
	into.saturation = lerp(into.saturation, target.saturation, alpha)
	into.tint = into.tint:Lerp(target.tint, alpha)
	into.density = lerp(into.density, target.density, alpha)
	into.haze = lerp(into.haze, target.haze, alpha)
	into.glare = lerp(into.glare, target.glare, alpha)
	into.fog = into.fog:Lerp(target.fog, alpha)
	into.decay = into.decay:Lerp(target.decay, alpha)
	into.bloom = lerp(into.bloom, target.bloom, alpha)
	into.bloomThreshold = lerp(into.bloomThreshold, target.bloomThreshold, alpha)
	into.rays = lerp(into.rays, target.rays, alpha)
	into.blur = lerp(into.blur, target.blur, alpha)
	into.focus = lerp(into.focus, target.focus, alpha)
	into.exposure = lerp(into.exposure, target.exposure, alpha)
end

local function apply(look: Look)
	grade.Brightness = look.brightness
	grade.Contrast = look.contrast
	grade.Saturation = look.saturation
	grade.TintColor = look.tint

	rays.Intensity = look.rays

	depth.FarIntensity = look.blur
	depth.FocusDistance = look.focus
	depth.InFocusRadius = look.focus * 1.6

	Lighting.ExposureCompensation = look.exposure

	if atmosphere then
		atmosphere.Density = look.density
		atmosphere.Haze = look.haze
		atmosphere.Glare = look.glare
		atmosphere.Color = look.fog
		atmosphere.Decay = look.decay
	end

	if bloom then
		bloom.Intensity = look.bloom
		bloom.Threshold = look.bloomThreshold
	end
end

-- The hub's floor plan, read off the model the server built. Nil until the
-- model has replicated, which is why the dungeon look is the starting one:
-- guessing wrong and correcting is a visible flash, and guessing "somewhere
-- dark" is right everywhere except one building.
local function readHubBounds(lobby: Instance): Bounds?
	local minX = lobby:GetAttribute("MinX")
	local maxX = lobby:GetAttribute("MaxX")
	local minZ = lobby:GetAttribute("MinZ")
	local maxZ = lobby:GetAttribute("MaxZ")

	if type(minX) ~= "number" or type(maxX) ~= "number" or type(minZ) ~= "number" or type(maxZ) ~= "number" then
		return nil
	end
	return { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ }
end

local function inHub(position: Vector3): boolean
	local bounds = hubBounds
	if not bounds then
		return false
	end
	return position.X >= bounds.minX
		and position.X <= bounds.maxX
		and position.Z >= bounds.minZ
		and position.Z <= bounds.maxZ
end

function AtmosphereFX.start()
	grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "WorldGrade"
	-- Separate from the place file's ColorGrade and from ScreenFX's
	-- CombatGrade. Three effects that stack is the cheapest way to keep three
	-- reasons for tinting the screen — the art direction, where you are, and
	-- what just hit you — from overwriting one another.
	grade.Parent = Lighting

	rays = Instance.new("SunRaysEffect")
	rays.Name = "GodRays"
	rays.Spread = 0.95
	rays.Parent = Lighting

	depth = Instance.new("DepthOfFieldEffect")
	depth.Name = "WorldDepth"
	-- Nothing in front of the player is ever blurred. A dungeon crawler that
	-- softens the enemy you are about to parry is unplayable.
	depth.NearIntensity = 0
	depth.Parent = Lighting

	atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	bloom = Lighting:FindFirstChildOfClass("BloomEffect")

	-- Softer contact shadows. With a ceiling over every room, shadow edges are
	-- most of what the eye reads as geometry, and knife-sharp ones read as
	-- decals.
	Lighting.ShadowSoftness = 0.4

	apply(current)

	local lobby = Workspace:FindFirstChild("Lobby")
	if lobby then
		hubBounds = readHubBounds(lobby)
	end
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "Lobby" then
			hubBounds = readHubBounds(child)
		end
	end)

	RunService.RenderStepped:Connect(function(delta)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")

		local target = if root and root:IsA("BasePart") and inHub(root.Position) then HUB else DUNGEON
		blend(current, target, 1 - math.exp(-ADAPT * delta))
		apply(current)
	end)
end

return AtmosphereFX
