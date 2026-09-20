--!strict
-- Builds a rig's body from RigDefs: parts, Motor6D joints, and welded
-- decorations.
--
-- It uses only the Roblox-style API handed to it, never globals. The game
-- passes Roblox's own `Instance`, `CFrame` and friends; the animation
-- workbench generator passes @lune/roblox's. One implementation therefore
-- builds both the rigs enemies wear in game and the rigs animations are
-- refined on, so the two can't drift apart.
--
-- Not a pure module (it creates instances), so it isn't on ARCHITECTURE.md's
-- pure-module list, and no spec loads it; the workbench generator exercises
-- it and checks what it built.

local RigDefs = require(script.Parent.RigDefs)

local RigAssembly = {}

-- The slice of the Roblox API this module uses.
export type Api = {
	Instance: any,
	CFrame: any,
	Vector3: any,
	Color3: any,
	Enum: any,
}

local ORIGIN = { 0, 0, 0 }

local centers: { [string]: { number } } = { HumanoidRootPart = ORIGIN }
for _, part in RigDefs.SKELETON do
	centers[part.name] = part.center
end

-- The offset between two rig-space points, at the rig's scale.
local function offset(api: Api, from: { number }, to: { number }, scale: number?): any
	local s = scale or 1
	return api.CFrame.new((to[1] - from[1]) * s, (to[2] - from[2]) * s, (to[3] - from[3]) * s)
end

-- A palette colour as a Color3, through the API this module was handed —
-- never a global, which is what lets it run under Lune as well as in game.
local function color(api: Api, rgb: { number }): any
	return api.Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

-- A decoration's own rotation, in degrees, applied after its offset. Lets a
-- piece sit at an angle — a horn, a slanted pauldron, a strap across a chest —
-- without needing a part whose axes already point that way.
local function rotationOf(api: Api, degrees: { number }?): any
	if not degrees then
		-- CFrame.new() rather than CFrame.identity: both Roblox's CFrame and
		-- @lune/roblox's have the constructor, and this module runs under both.
		return api.CFrame.new()
	end
	return api.CFrame.Angles(math.rad(degrees[1]), math.rad(degrees[2]), math.rad(degrees[3]))
end

-- One part of a rig, with the size, colour, material and shape a style
-- asked for. Non-colliding: an enemy's collisions are its hitbox alone.
local function makePart(api: Api, name: string, size: any, rgb: { number }, material: string?, shape: string?): any
	local part = api.Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color(api, rgb)
	part.Material = api.Enum.Material[material or "SmoothPlastic"]
	if shape then
		part.Shape = api.Enum.PartType[shape]
	end
	part.TopSurface = api.Enum.SurfaceType.Smooth
	part.BottomSurface = api.Enum.SurfaceType.Smooth
	-- Visual only: the root is the hitbox and the only thing that collides.
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.Massless = true
	return part
end

-- Builds the body around `root`, which must already be where the rig should
-- stand, and parents it all to `parent`. Returns every body part by name,
-- including the root.
function RigAssembly.attach(api: Api, root: any, rigId: string, parent: any): { [string]: any }
	local style = RigDefs.styleOf(rigId)
	local scale = RigDefs.scaleOf(rigId)
	local parts: { [string]: any } = { HumanoidRootPart = root }
	local rootCFrame = root.CFrame

	for _, def in RigDefs.SKELETON do
		local partStyle = RigDefs.partStyle(style, def.name)
		local size = api.Vector3.new(
			def.size[1] * (partStyle.width or 1) * scale,
			def.size[2] * scale,
			def.size[3] * (partStyle.depth or 1) * scale
		)

		local part = makePart(api, def.name, size, partStyle.color, partStyle.material, nil)
		part.CFrame = rootCFrame * offset(api, ORIGIN, def.center, scale)
		part.Parent = parent

		-- R15 convention: the joint lives in the part it moves, and C0/C1 both
		-- point at the pivot, so a joint's Transform rotates about it.
		local joint = api.Instance.new("Motor6D")
		joint.Name = def.joint
		joint.Part0 = parts[def.parent]
		joint.Part1 = part
		joint.C0 = offset(api, centers[def.parent], def.pivot, scale)
		joint.C1 = offset(api, def.center, def.pivot, scale)
		joint.Parent = part

		parts[def.name] = part
	end

	for _, decoration in style.decorations do
		local host = parts[decoration.attachTo]
		local size = api.Vector3.new(decoration.size[1] * scale, decoration.size[2] * scale, decoration.size[3] * scale)
		local piece = makePart(api, decoration.name, size, decoration.color, decoration.material, decoration.shape)
		piece.Transparency = decoration.transparency or 0

		local placement = offset(api, ORIGIN, decoration.offset, scale) * rotationOf(api, decoration.rotation)
		piece.CFrame = host.CFrame * placement
		piece.Parent = parent

		local weld = api.Instance.new("Weld")
		weld.Name = `{decoration.name}Weld`
		weld.Part0 = host
		weld.Part1 = piece
		weld.C0 = placement
		weld.Parent = piece
	end

	return parts
end

-- What the Animation Editor needs to recognise a non-Humanoid rig, and what a
-- published animation plays through.
function RigAssembly.addAnimator(api: Api, model: any): any
	local controller = api.Instance.new("AnimationController")
	controller.Parent = model

	local animator = api.Instance.new("Animator")
	animator.Parent = controller

	return animator
end

-- A complete standalone rig: model, invisible root sized like an enemy
-- hitbox, body, and animator. Used by the workbench.
function RigAssembly.build(api: Api, rigId: string, cframe: any): any
	local model = api.Instance.new("Model")
	model.Name = rigId

	local rootSize = RigDefs.rootSize(rigId)
	local root = api.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = api.Vector3.new(rootSize[1], rootSize[2], rootSize[3])
	root.CFrame = cframe
	root.Anchored = true
	root.CanCollide = false
	root.Transparency = 1
	root.Parent = model

	model.PrimaryPart = root
	RigAssembly.attach(api, root, rigId, model)
	RigAssembly.addAnimator(api, model)

	return model
end

return RigAssembly
