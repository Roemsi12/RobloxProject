--!strict
-- Room geometry: a flagstone floor, tall walls with an arched doorway on any
-- side that needs one, carved bays and stone sentinels, the variant's inner
-- layout (pillars, ruins, a throne hall), props and torches. Also the
-- corridors between rooms, so every piece of dungeon shares one look.
--
-- One module rather than a RoomTemplates/ folder: each variant is a short
-- geometry recipe, not enough content to warrant its own file — the same way
-- WeaponDefs and EnemyDefs keep every entry in one module.
--
-- Rooms are only ever translated, never rotated, so walls, corridors and the
-- leash are all axis-aligned. Dressing (trim, arches, doors, banners, statues,
-- barrels, torches, rubble) is decoration: it never collides, and never
-- changes a room's size, doors or leash. Only the floor, the lower walls, the
-- door posts, the statue plinths and the variant's pillars stop anything —
-- those are the things a player expects to stop them, and the things an
-- enemy's leash is measured against.
--
-- Colours come from Palette, the same one the weapons and rigs draw from: the
-- iron on a door band is the iron on a skeleton's helm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DungeonDefs = require(ReplicatedStorage.Shared.DungeonDefs)
local Palette = require(ReplicatedStorage.Shared.Palette)

local RoomTemplates = {}

RoomTemplates.DOOR_WIDTH = DungeonDefs.CORRIDOR_WIDTH

-- How tall the stonework reads, and how much of it is actually solid.
--
-- Nobody can jump twelve studs, so every stud above COLLIDE_HEIGHT is pure
-- decoration — and building it non-query means the camera passes straight
-- through it. That is what lets a hall be twice as tall as a player can reach
-- without the camera jamming into a wall every time someone backs up against
-- one. Raising the whole wall as one solid slab would have made every room
-- feel grander and play worse.
local WALL_HEIGHT = 22
local COLLIDE_HEIGHT = 12
local WALL_THICKNESS = 1

-- Corridors stay low and tunnelled. Stepping out of an eleven-stud passage
-- into a twenty-two-stud hall is what sells the hall; making both tall would
-- flatten the contrast and cost twice the parts.
local CORRIDOR_HEIGHT = 11

-- How far inside the walls an enemy's leash stops, so a rig backed against a
-- wall doesn't clip into it. Scaled by the rig's size where it's used.
RoomTemplates.LEASH_INSET = 3

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local FLOOR_COLOR = rgb(Palette.FLOOR)
local WALL_COLOR = rgb(Palette.WALL)
local TRIM_COLOR = rgb(Palette.TRIM)
local PILLAR_COLOR = rgb(Palette.PILLAR)
local RUBBLE_COLOR = rgb(Palette.RUBBLE)
local MORTAR_COLOR = rgb(Palette.MORTAR)
local IRON_COLOR = rgb(Palette.IRON)
local RUST_COLOR = rgb(Palette.RUST)
local WOOD_COLOR = rgb(Palette.ROT_WOOD)
local BONE_COLOR = rgb(Palette.OLD_BONE)
local BANNER_COLOR = rgb(Palette.CRIMSON)
local GOLD_COLOR = rgb(Palette.GOLD)
local DEFAULT_TORCH = rgb(Palette.TORCH_FIRE)
local GHOST_FIRE = rgb(Palette.GHOST_FIRE)
-- Statues are cut from a paler stone than the walls, so they read as carved
-- rather than as lumps of the wall that happen to stick out.
local STATUE_COLOR = rgb(Palette.mix(Palette.PILLAR, Palette.BONE, 0.22))

local TORCH_HEIGHT = 8
-- Where the doorway arch springs from, and how wide its ring is.
local ARCH_SPRING = 9
local ARCH_RADIUS = 4.6
local VOUSSOIRS = 9
-- Height of the carved bays between buttresses.
local BAY_TOP = 15

export type Side = "North" | "South" | "East" | "West"

export type Bounds = {
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

export type RoomSpec = {
	variant: DungeonDefs.RoomVariant,
	size: number,
	doors: { [Side]: boolean },
	-- The side the way in is on, so a hall's throne faces the door.
	entrance: Side?,
	torchColor: Color3?,
}

export type Room = {
	model: Model,
	-- The centre of the floor's top surface.
	centre: CFrame,
	size: number,
	-- The whole floor inside the walls, for "is anyone in this room".
	floorBounds: Bounds,
}

-- Yaw that turns a room-local frame so its +Z points out through `side`.
local SIDE_YAW: { [Side]: number } = {
	North = 0,
	East = math.rad(90),
	South = math.rad(180),
	West = math.rad(-90),
}

local function makePart(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Decoration a player walks through rather than snags on, and that the camera
-- sees straight through.
local function makeDecor(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): Part
	local part = makePart(parent, name, size, cframe, color, material)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

--[[ Walls ]]

-- A wall, solid to COLLIDE_HEIGHT and decorative above, with a darker cap
-- along its top, a dentil frieze under it, a string course at shoulder height
-- and a skirting along its base. `cframe` is the wall's centre at half
-- WALL_HEIGHT; its local X runs along the wall.
local function makeWall(model: Instance, name: string, length: number, cframe: CFrame)
	local base = cframe * CFrame.new(0, -WALL_HEIGHT / 2, 0)
	local upper = WALL_HEIGHT - COLLIDE_HEIGHT

	makePart(model, name, Vector3.new(length, COLLIDE_HEIGHT, WALL_THICKNESS), base * CFrame.new(0, COLLIDE_HEIGHT / 2, 0), WALL_COLOR, Enum.Material.Cobblestone)
	makeDecor(model, `{name}Upper`, Vector3.new(length, upper, WALL_THICKNESS), base * CFrame.new(0, COLLIDE_HEIGHT + upper / 2, 0), WALL_COLOR, Enum.Material.Cobblestone)

	makeDecor(model, `{name}Cap`, Vector3.new(length + 0.5, 0.8, WALL_THICKNESS + 0.6), base * CFrame.new(0, WALL_HEIGHT - 0.4, 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, `{name}Frieze`, Vector3.new(length, 0.5, WALL_THICKNESS + 0.4), base * CFrame.new(0, WALL_HEIGHT - 1.2, 0), PILLAR_COLOR, Enum.Material.Granite)
	makeDecor(model, `{name}Course`, Vector3.new(length, 0.4, WALL_THICKNESS + 0.35), base * CFrame.new(0, BAY_TOP + 0.8, 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, `{name}Skirt`, Vector3.new(length + 0.35, 1.0, WALL_THICKNESS + 0.35), base * CFrame.new(0, 0.5, 0), TRIM_COLOR, Enum.Material.Slate)
end

-- A buttress running the full height of the wall, with a moulded foot and a
-- carved capital where the bay arches spring from.
local function addButtress(model: Instance, at: CFrame)
	makeDecor(model, "Buttress", Vector3.new(2.0, WALL_HEIGHT - 1.6, 0.7), at * CFrame.new(0, (WALL_HEIGHT - 1.6) / 2, 0), PILLAR_COLOR, Enum.Material.Granite)
	makeDecor(model, "ButtressFoot", Vector3.new(2.6, 1.0, 1.1), at * CFrame.new(0, 0.5, 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "ButtressCapital", Vector3.new(2.6, 0.7, 1.1), at * CFrame.new(0, BAY_TOP, 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "ButtressCrown", Vector3.new(2.3, 0.6, 0.9), at * CFrame.new(0, WALL_HEIGHT - 1.8, 0), TRIM_COLOR, Enum.Material.Slate)
end

-- A recessed bay between two buttresses: a sunken panel with a moulded head.
-- This is most of what makes a long wall read as built rather than extruded.
local function addBay(model: Instance, at: CFrame, width: number)
	makeDecor(model, "BayPanel", Vector3.new(width, BAY_TOP - 2.4, 0.3), at * CFrame.new(0, (BAY_TOP - 2.4) / 2 + 1.2, 0), rgb(Palette.shade(Palette.WALL, 0.82)), Enum.Material.Cobblestone)
	makeDecor(model, "BayHead", Vector3.new(width + 0.5, 0.5, 0.55), at * CFrame.new(0, BAY_TOP - 1.0, 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "BaySill", Vector3.new(width + 0.5, 0.4, 0.55), at * CFrame.new(0, 1.2, 0), TRIM_COLOR, Enum.Material.Slate)
end

--[[ Statues ]]

-- A stone sentinel on a plinth: a hooded figure in a long robe, both hands
-- resting on a sword driven point-down in front of it. Carved from a paler
-- stone than the wall so it reads as a figure and not a buttress.
--
-- Only the plinth collides. The figure stands on top of it and against a
-- wall, so the plinth is the only part of it anyone can walk into anyway.
local function addStatue(model: Instance, base: CFrame)
	makePart(model, "StatuePlinth", Vector3.new(3.2, 2.0, 3.0), base * CFrame.new(0, 1.0, 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "StatuePlinthCap", Vector3.new(3.8, 0.45, 3.6), base * CFrame.new(0, 2.2, 0), PILLAR_COLOR, Enum.Material.Granite)
	makeDecor(model, "StatuePlinthFoot", Vector3.new(3.8, 0.45, 3.6), base * CFrame.new(0, 0.22, 0), PILLAR_COLOR, Enum.Material.Granite)

	-- The figure, from the hem up. What makes a stack of boxes read as a
	-- person is the taper: a wide hem, a waist narrower than both, shoulders
	-- wider than everything, and a head big enough to find. Equal-width boxes
	-- read as a pillar however many you stack. Marble rather than Granite for
	-- the same reason — at this size Granite's speckle is just noise, and the
	-- silhouette is doing all the work.
	local feet = base * CFrame.new(0, 2.4, 0)
	makeDecor(model, "StatueHem", Vector3.new(2.7, 1.4, 2.1), feet * CFrame.new(0, 0.7, 0), STATUE_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueRobe", Vector3.new(1.9, 3.0, 1.5), feet * CFrame.new(0, 2.9, 0), STATUE_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueChest", Vector3.new(2.3, 2.0, 1.5), feet * CFrame.new(0, 5.4, 0), STATUE_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueMantle", Vector3.new(3.4, 0.8, 2.1), feet * CFrame.new(0, 6.6, 0), PILLAR_COLOR, Enum.Material.Marble)

	-- Arms held clear of the body, folded down onto the pommel.
	makeDecor(model, "StatueArmRight", Vector3.new(0.6, 2.7, 0.6), feet * CFrame.new(1.35, 5.2, -0.5) * CFrame.Angles(math.rad(-12), 0, math.rad(7)), STATUE_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueArmLeft", Vector3.new(0.6, 2.7, 0.6), feet * CFrame.new(-1.35, 5.2, -0.5) * CFrame.Angles(math.rad(-12), 0, math.rad(-7)), STATUE_COLOR, Enum.Material.Marble)

	-- Head on a visible neck, under a great helm with a blank visor.
	makeDecor(model, "StatueNeck", Vector3.new(0.7, 0.6, 0.7), feet * CFrame.new(0, 7.1, 0), STATUE_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueHead", Vector3.new(1.3, 1.4, 1.3), feet * CFrame.new(0, 7.9, 0), STATUE_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueHelm", Vector3.new(1.55, 1.1, 1.55), feet * CFrame.new(0, 8.2, 0), PILLAR_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueVisor", Vector3.new(1.1, 0.25, 0.12), feet * CFrame.new(0, 7.9, -0.72), rgb(Palette.VOID))
	makeDecor(model, "StatueCrest", Vector3.new(0.3, 1.1, 1.7), feet * CFrame.new(0, 9.2, 0), PILLAR_COLOR, Enum.Material.Marble)

	-- The sword: point down in front of it, hands resting over the pommel.
	makeDecor(model, "StatueSwordPommel", Vector3.new(0.55, 0.55, 0.55), feet * CFrame.new(0, 4.6, -1.05), PILLAR_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueSwordGrip", Vector3.new(0.4, 1.3, 0.4), feet * CFrame.new(0, 3.85, -1.05), STATUE_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueSwordGuard", Vector3.new(2.2, 0.35, 0.45), feet * CFrame.new(0, 3.1, -1.05), PILLAR_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueSwordBlade", Vector3.new(0.5, 2.6, 0.24), feet * CFrame.new(0, 1.7, -1.05), STATUE_COLOR, Enum.Material.Marble)
	makeDecor(model, "StatueSwordTip", Vector3.new(0.3, 0.5, 0.2), feet * CFrame.new(0, 0.2, -1.05), STATUE_COLOR, Enum.Material.Marble)
end

--[[ Doorways ]]

-- The ring of wedge stones over a doorway, with a keystone at the top, and a
-- carved tympanum filling the head above it. Each stone is rotated to sit
-- radially, so the ring reads as cut stone rather than a row of bricks.
-- `frame` looks out through the side; the ring is laid on the inner face.
local function addArch(model: Instance, frame: CFrame, wallZ: number)
	local face = wallZ - WALL_THICKNESS / 2 - 0.25
	for index = 1, VOUSSOIRS do
		local angle = math.pi * (index - 0.5) / VOUSSOIRS
		local isKeystone = index == math.ceil(VOUSSOIRS / 2)
		local reach = if isKeystone then ARCH_RADIUS + 0.15 else ARCH_RADIUS
		local stone = frame
			* CFrame.new(math.cos(angle) * reach, ARCH_SPRING + math.sin(angle) * reach, face)
			* CFrame.Angles(0, 0, angle)

		makeDecor(
			model,
			if isKeystone then "Keystone" else "Voussoir",
			Vector3.new(if isKeystone then 1.8 else 1.4, 2.6, 0.8),
			stone,
			if isKeystone then TRIM_COLOR else PILLAR_COLOR,
			Enum.Material.Granite
		)
	end

	-- An outer moulding around the ring, and the mark of the place above it.
	makeDecor(model, "ArchLabel", Vector3.new(RoomTemplates.DOOR_WIDTH + 5.6, 0.6, 0.6), frame * CFrame.new(0, ARCH_SPRING + ARCH_RADIUS + 1.9, face), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "ArchSigil", Vector3.new(1.4, 1.4, 0.3), frame * CFrame.new(0, ARCH_SPRING + ARCH_RADIUS + 3.2, face) * CFrame.Angles(0, 0, math.rad(45)), GOLD_COLOR, Enum.Material.Metal)
end

-- One leaf of a pair of doors, standing open flat against the wall. Doors are
-- never shut — a shut door would block the corridor the room is reached by —
-- so they are pure dressing, and say "this was built to be closed".
local function addDoorLeaf(model: Instance, frame: CFrame, sign: number, wallZ: number)
	local width = 3.6
	local height = 8.2
	local hinge = sign * (RoomTemplates.DOOR_WIDTH / 2 + 0.2)
	local leaf = frame
		* CFrame.new(hinge + sign * width / 2, height / 2, wallZ - WALL_THICKNESS / 2 - 0.5)
		* CFrame.Angles(0, math.rad(-8 * sign), 0)

	makeDecor(model, "DoorLeaf", Vector3.new(width, height, 0.4), leaf, WOOD_COLOR, Enum.Material.WoodPlanks)
	for _, y in { height / 2 - 1.0, 0, -height / 2 + 1.0 } do
		makeDecor(model, "DoorBand", Vector3.new(width + 0.12, 0.45, 0.55), leaf * CFrame.new(0, y, 0), IRON_COLOR, Enum.Material.Metal)
	end
	makeDecor(model, "DoorBrace", Vector3.new(width + 0.12, 0.3, 0.5), leaf * CFrame.Angles(0, 0, math.rad(40)), RUST_COLOR, Enum.Material.Metal)
	makeDecor(model, "DoorRing", Vector3.new(0.7, 0.7, 0.2), leaf * CFrame.new(-sign * (width / 2 - 0.7), 0.6, -0.3), RUST_COLOR, Enum.Material.Metal)
end

--[[ Torches and light ]]

-- An iron sconce holding a burning brand. `cframe` is on the wall's inner
-- face, looking into the room.
local function addTorch(model: Instance, cframe: CFrame, color: Color3)
	makeDecor(model, "TorchBracket", Vector3.new(0.3, 0.3, 1.2), cframe * CFrame.new(0, -0.2, -0.6), IRON_COLOR, Enum.Material.Metal)
	makeDecor(model, "TorchArm", Vector3.new(0.24, 1.0, 0.24), cframe * CFrame.new(0, 0.15, -1.1) * CFrame.Angles(math.rad(18), 0, 0), IRON_COLOR, Enum.Material.Metal)
	makeDecor(model, "TorchBowl", Vector3.new(0.9, 0.55, 0.9), cframe * CFrame.new(0, 0.55, -1.25), IRON_COLOR, Enum.Material.Metal)

	local head = makeDecor(model, "Torch", Vector3.new(0.45, 1.0, 0.45), cframe * CFrame.new(0, 0.95, -1.25), rgb(Palette.shade(Palette.ROT_WOOD, 0.8)), Enum.Material.Wood)

	local fire = Instance.new("Fire")
	fire.Size = 3
	fire.Heat = 8
	fire.Color = color
	fire.SecondaryColor = color:Lerp(Color3.new(0, 0, 0), 0.5)
	fire.Parent = head

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 2.6
	light.Range = 30
	light.Shadows = true
	light.Parent = head
end

--[[ One side of a room ]]

-- Lays out a wall's bays: buttresses at regular intervals, a carved panel in
-- each bay between them, and a statue in every other bay on a wall long
-- enough to carry one. Returns nothing; everything is decoration.
local function dressWall(model: Model, frame: CFrame, length: number, wallZ: number, hasDoor: boolean, statues: boolean)
	local spacing = 13
	local count = math.max(math.floor(length / spacing) - 1, 0)
	if count <= 0 then
		return
	end

	local step = length / (count + 1)
	local face = wallZ - WALL_THICKNESS / 2

	-- Is x clear of the doorway?
	local function clear(x: number, margin: number): boolean
		return not hasDoor or math.abs(x) > RoomTemplates.DOOR_WIDTH / 2 + margin
	end

	for index = 1, count do
		local x = -length / 2 + step * index
		if clear(x, 2.5) then
			addButtress(model, frame * CFrame.new(x, 0, face - 0.35))
		end
	end

	-- Bays sit between consecutive buttresses, and at both ends.
	for index = 0, count do
		local from = -length / 2 + step * index
		local to = -length / 2 + step * (index + 1)
		local centre = (from + to) / 2
		local width = (to - from) - 2.6
		if width < 3 or not clear(centre, width / 2 + 1) then
			continue
		end

		addBay(model, frame * CFrame.new(centre, 0, face - 0.15), width)
		if statues and index % 2 == 0 then
			addStatue(model, frame * CFrame.new(centre, 0, face - 1.9) * CFrame.Angles(0, math.pi, 0))
		end
	end
end

-- One side of a room: a full wall, or two segments framing an arched doorway,
-- plus its bays, statues and torches.
local function addSide(model: Model, centre: CFrame, size: number, side: Side, hasDoor: boolean, torchColor: Color3, statues: boolean)
	-- Local +Z points out through this side; local X runs along its wall.
	local frame = centre * CFrame.Angles(0, SIDE_YAW[side], 0)
	local wallZ = size / 2 + WALL_THICKNESS / 2

	if hasDoor then
		local segment = (size - RoomTemplates.DOOR_WIDTH) / 2
		for _, sign in { -1, 1 } do
			local x = sign * (RoomTemplates.DOOR_WIDTH / 2 + segment / 2)
			makeWall(model, "WallSegment", segment + WALL_THICKNESS, frame * CFrame.new(x, WALL_HEIGHT / 2, wallZ))

			-- A heavy post either side of the doorway, up to the springing.
			local postX = sign * (RoomTemplates.DOOR_WIDTH / 2 + 0.7)
			makePart(model, "DoorPost", Vector3.new(1.4, ARCH_SPRING, 2.0), frame * CFrame.new(postX, ARCH_SPRING / 2, wallZ), TRIM_COLOR, Enum.Material.Slate)
			makeDecor(model, "DoorPostCap", Vector3.new(1.9, 0.5, 2.4), frame * CFrame.new(postX, ARCH_SPRING, wallZ), PILLAR_COLOR, Enum.Material.Granite)
			makeDecor(model, "DoorPostFoot", Vector3.new(1.9, 0.5, 2.4), frame * CFrame.new(postX, 0.25, wallZ), PILLAR_COLOR, Enum.Material.Granite)

			addDoorLeaf(model, frame, sign, wallZ)
		end

		-- The wall above the opening. Solid only as high as anything else,
		-- so the camera can follow a player through the doorway.
		local solid = math.max(COLLIDE_HEIGHT - ARCH_SPRING, 0)
		local head = WALL_HEIGHT - ARCH_SPRING
		makePart(
			model,
			"DoorHead",
			Vector3.new(RoomTemplates.DOOR_WIDTH + 2.8, solid, WALL_THICKNESS),
			frame * CFrame.new(0, ARCH_SPRING + solid / 2, wallZ),
			WALL_COLOR,
			Enum.Material.Cobblestone
		)
		makeDecor(
			model,
			"DoorHeadUpper",
			Vector3.new(RoomTemplates.DOOR_WIDTH + 2.8, head - solid, WALL_THICKNESS),
			frame * CFrame.new(0, ARCH_SPRING + solid + (head - solid) / 2, wallZ),
			WALL_COLOR,
			Enum.Material.Cobblestone
		)
		addArch(model, frame, wallZ)
	else
		makeWall(model, "Wall", size + WALL_THICKNESS * 2, frame * CFrame.new(0, WALL_HEIGHT / 2, wallZ))
	end

	dressWall(model, frame, size, wallZ, hasDoor, statues)

	-- Torches either side of centre on bigger walls, one on smaller ones,
	-- always clear of the doorway.
	local offsets = if size >= 52 then { -size / 4, size / 4 } else { size / 4 }
	for _, x in offsets do
		local mount = frame * CFrame.new(x, TORCH_HEIGHT, size / 2)
		local inward = frame * CFrame.new(x, TORCH_HEIGHT, 0)
		addTorch(model, CFrame.lookAt(mount.Position, inward.Position), torchColor)
	end
end

--[[ Floor ]]

-- Flagstone seams: thin dark strips ruling the floor into slabs, a few
-- cracked ones, and an inlaid figure at the centre of the room. Far cheaper
-- than laying an actual grid of tiles, and from standing height it reads the
-- same.
local function addFlagstones(model: Model, centre: CFrame, size: number)
	local slab = 9
	local lines = math.max(math.floor(size / slab) - 1, 1)
	local step = size / (lines + 1)

	for index = 1, lines do
		local at = -size / 2 + step * index
		makeDecor(model, "FloorSeam", Vector3.new(size, 0.06, 0.28), centre * CFrame.new(0, 0.02, at), MORTAR_COLOR, Enum.Material.Slate)
		makeDecor(model, "FloorSeam", Vector3.new(0.28, 0.06, size), centre * CFrame.new(at, 0.02, 0), MORTAR_COLOR, Enum.Material.Slate)
	end

	-- A ringed figure set into the middle of the floor. Rooms are fought in
	-- from the centre outward, so this is the piece of floor most often on
	-- screen.
	local ring = math.min(size * 0.3, 12)
	makeDecor(model, "InlayOuter", Vector3.new(ring * 2, 0.07, ring * 2), centre * CFrame.new(0, 0.03, 0) * CFrame.Angles(0, math.rad(45), 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "InlayInner", Vector3.new(ring * 1.5, 0.08, ring * 1.5), centre * CFrame.new(0, 0.04, 0), rgb(Palette.shade(Palette.FLOOR, 1.15)), Enum.Material.Slate)
	for _, angle in { 0, 45, 90, 135 } do
		makeDecor(model, "InlaySpoke", Vector3.new(ring * 1.9, 0.09, 0.5), centre * CFrame.new(0, 0.05, 0) * CFrame.Angles(0, math.rad(angle), 0), GOLD_COLOR, Enum.Material.Metal)
	end
	makeDecor(model, "InlayBoss", Vector3.new(2.2, 0.1, 2.2), centre * CFrame.new(0, 0.06, 0) * CFrame.Angles(0, math.rad(45), 0), GOLD_COLOR, Enum.Material.Metal)

	-- A handful of slabs that have sunk or cracked.
	for _ = 1, math.random(2, 4) do
		local x = (math.random() - 0.5) * (size - 12)
		local z = (math.random() - 0.5) * (size - 12)
		local cracked = makeDecor(
			model,
			"CrackedSlab",
			Vector3.new(slab * 0.8, 0.08, slab * 0.8),
			centre * CFrame.new(x, 0.03, z) * CFrame.Angles(0, math.random() * math.pi, 0),
			rgb(Palette.shade(Palette.FLOOR, 0.82)),
			Enum.Material.Slate
		)
		cracked.CastShadow = false
	end
end

--[[ Props ]]

local function addBarrel(model: Instance, base: CFrame)
	makeDecor(model, "Barrel", Vector3.new(1.7, 2.4, 1.7), base * CFrame.new(0, 1.2, 0), WOOD_COLOR, Enum.Material.WoodPlanks)
	for _, y in { 0.6, 1.8 } do
		makeDecor(model, "BarrelHoop", Vector3.new(1.85, 0.25, 1.85), base * CFrame.new(0, y, 0), RUST_COLOR, Enum.Material.Metal)
	end
end

local function addCrate(model: Instance, base: CFrame)
	local side = 1.6 + math.random() * 0.7
	makeDecor(model, "Crate", Vector3.new(side, side, side), base * CFrame.new(0, side / 2, 0), WOOD_COLOR, Enum.Material.WoodPlanks)
	makeDecor(model, "CrateBand", Vector3.new(side + 0.08, 0.2, side + 0.08), base * CFrame.new(0, side / 2, 0), rgb(Palette.shade(Palette.ROT_WOOD, 0.7)), Enum.Material.Wood)
end

-- What is left of somebody who came this way before.
local function addBones(model: Instance, base: CFrame)
	makeDecor(model, "Skull", Vector3.new(0.7, 0.7, 0.8), base * CFrame.new(0, 0.35, 0) * CFrame.Angles(0, math.random() * math.pi, math.rad(20)), BONE_COLOR)
	for _ = 1, 3 do
		makeDecor(
			model,
			"Bone",
			Vector3.new(0.22, 0.22, 1.5),
			base * CFrame.new((math.random() - 0.5) * 1.8, 0.14, (math.random() - 0.5) * 1.8) * CFrame.Angles(0, math.random() * math.pi, math.rad(90)),
			BONE_COLOR
		)
	end
end

-- A chain hanging out of the dark overhead. Long, now that there is height
-- above to hang it from.
local function addChain(model: Instance, top: CFrame, length: number)
	local links = math.max(math.floor(length / 0.9), 1)
	for index = 1, links do
		makeDecor(
			model,
			"ChainLink",
			Vector3.new(0.2, 0.8, 0.2),
			top * CFrame.new(0, -index * 0.85, 0) * CFrame.Angles(0, if index % 2 == 0 then 0 else math.rad(90), 0),
			IRON_COLOR,
			Enum.Material.Metal
		)
	end
	makeDecor(model, "ChainHook", Vector3.new(0.5, 0.5, 0.5), top * CFrame.new(0, -links * 0.85 - 0.4, 0), RUST_COLOR, Enum.Material.Metal)
end

-- A banner hanging from the string course, with a bar across the top. Long
-- enough to fill the wall above the bays.
local function addBanner(model: Instance, frame: CFrame, x: number, wallZ: number, color: Color3)
	local face = wallZ - WALL_THICKNESS / 2 - 0.25
	local top = WALL_HEIGHT - 2.2
	makeDecor(model, "BannerRod", Vector3.new(4.2, 0.26, 0.26), frame * CFrame.new(x, top, face), IRON_COLOR, Enum.Material.Metal)
	makeDecor(model, "Banner", Vector3.new(3.4, 9.0, 0.14), frame * CFrame.new(x, top - 4.6, face), color, Enum.Material.Fabric)
	makeDecor(model, "BannerTail", Vector3.new(1.7, 1.6, 0.14), frame * CFrame.new(x, top - 9.8, face), color, Enum.Material.Fabric)
	makeDecor(model, "BannerDevice", Vector3.new(1.5, 1.5, 0.08), frame * CFrame.new(x, top - 4.4, face - 0.1) * CFrame.Angles(0, 0, math.rad(45)), GOLD_COLOR, Enum.Material.Metal)
end

-- Cobweb in the angle of two walls, at a height where it is actually seen.
local function addCobweb(model: Instance, corner: CFrame)
	local web = makeDecor(model, "Cobweb", Vector3.new(4.0, 4.0, 0.08), corner * CFrame.Angles(0, math.rad(45), 0), Color3.fromRGB(196, 196, 186), Enum.Material.Fabric)
	web.Transparency = 0.62
	web.CastShadow = false
end

-- Dressing that belongs to every room: things left in the corners, webs in
-- the angles, and chains out of the dark above. Scaled to the room, kept to
-- the edges and out of the doorways.
local function addProps(model: Model, centre: CFrame, size: number)
	local edge = size / 2 - 3.5

	for _, xSign in { -1, 1 } do
		for _, zSign in { -1, 1 } do
			addCobweb(model, centre * CFrame.new(xSign * (size / 2 - 1.8), 9.5, zSign * (size / 2 - 1.8)))
		end
	end

	local clutter = math.max(math.floor(size / 14), 2)
	for _ = 1, clutter do
		local alongX = math.random() < 0.5
		local along = (math.random() - 0.5) * (size - 14)
		if math.abs(along) < RoomTemplates.DOOR_WIDTH / 2 + 3 then
			continue
		end

		local wallSide = if math.random() < 0.5 then -edge else edge
		local x = if alongX then along else wallSide
		local z = if alongX then wallSide else along
		local base = centre * CFrame.new(x, 0, z) * CFrame.Angles(0, math.random() * math.pi * 2, 0)

		local roll = math.random()
		if roll < 0.34 then
			addBarrel(model, base)
		elseif roll < 0.68 then
			addCrate(model, base)
		else
			addBones(model, base)
		end
	end

	for _ = 1, math.random(2, 3) do
		local x = (math.random() - 0.5) * (size - 18)
		local z = (math.random() - 0.5) * (size - 18)
		addChain(model, centre * CFrame.new(x, WALL_HEIGHT - 1.0, z), 6 + math.random() * 6)
	end
end

-- Ribs across the ceiling line. There is no ceiling — the camera looks down
-- through it — but ribs at the top of the walls close the room off overhead,
-- and at this height they are far above anything the camera does.
local function addCeilingRibs(model: Model, centre: CFrame, size: number)
	local spacing = 15
	local count = math.max(math.floor(size / spacing), 1)
	local step = size / (count + 1)
	for index = 1, count do
		local z = -size / 2 + step * index
		makeDecor(model, "CeilingRib", Vector3.new(size + 2, 1.0, 1.4), centre * CFrame.new(0, WALL_HEIGHT - 0.6, z), TRIM_COLOR, Enum.Material.Slate)
		makeDecor(model, "CeilingRibTrim", Vector3.new(size + 2, 0.3, 1.9), centre * CFrame.new(0, WALL_HEIGHT - 1.2, z), PILLAR_COLOR, Enum.Material.Granite)
	end
end

--[[ Variants ]]

local function addPillar(model: Model, base: CFrame, height: number)
	makePart(model, "Pillar", Vector3.new(2.4, math.min(height, COLLIDE_HEIGHT), 2.4), base * CFrame.new(0, math.min(height, COLLIDE_HEIGHT) / 2, 0), PILLAR_COLOR, Enum.Material.Granite)
	if height > COLLIDE_HEIGHT then
		makeDecor(model, "PillarUpper", Vector3.new(2.4, height - COLLIDE_HEIGHT, 2.4), base * CFrame.new(0, COLLIDE_HEIGHT + (height - COLLIDE_HEIGHT) / 2, 0), PILLAR_COLOR, Enum.Material.Granite)
	end
	makeDecor(model, "PillarBase", Vector3.new(3.4, 1.0, 3.4), base * CFrame.new(0, 0.5, 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "PillarCapital", Vector3.new(3.4, 0.8, 3.4), base * CFrame.new(0, height - 0.4, 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "PillarNecking", Vector3.new(2.8, 0.4, 2.8), base * CFrame.new(0, height - 1.2, 0), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "PillarBand", Vector3.new(2.7, 0.5, 2.7), base * CFrame.new(0, height * 0.5, 0), TRIM_COLOR, Enum.Material.Slate)
end

-- Four pillars, a third of the way in from each corner: cover to break a
-- Spitter's line, and something to circle a melee enemy around.
local function addPillarsLayout(model: Model, centre: CFrame, size: number)
	local at = size * 0.28
	for _, xSign in { -1, 1 } do
		for _, zSign in { -1, 1 } do
			addPillar(model, centre * CFrame.new(xSign * at, 0, zSign * at), 18)
		end
	end
end

-- Broken, waist-high walls on the diagonals: cover that doesn't block the view
-- of a telegraph. Kept out of the centre, where enemies spawn, and off the
-- straight lines between doors.
local function addRuins(model: Model, centre: CFrame, size: number)
	for i = 0, 3 do
		local angle = math.rad(45 + 90 * i) + (math.random() - 0.5) * 0.3
		local radius = size * (0.28 + math.random() * 0.06)
		local length = 2.5 + math.random() * 2
		local height = 2 + math.random() * 1.5
		local base = centre * CFrame.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			* CFrame.Angles(0, angle + math.pi / 2 + (math.random() - 0.5) * 0.5, 0)

		makePart(model, "RuinWall", Vector3.new(length, height, 1.2), base * CFrame.new(0, height / 2, 0), WALL_COLOR, Enum.Material.Cobblestone)
		makeDecor(model, "RuinCap", Vector3.new(length + 0.3, 0.3, 1.5), base * CFrame.new(0, height, 0), TRIM_COLOR, Enum.Material.Slate)
		makeDecor(model, "RuinRubble", Vector3.new(1.2, 0.8, 1), base * CFrame.new(length / 2 + 0.6, 0.4, 0.8) * CFrame.Angles(0, 0.6, 0.3), RUBBLE_COLOR, Enum.Material.Slate)
		-- A broken column stump beside the ruin.
		if i % 2 == 0 then
			makeDecor(model, "BrokenColumn", Vector3.new(1.8, 2.6 + math.random() * 2, 1.8), base * CFrame.new(-length / 2 - 1.4, 1.5, -0.5), PILLAR_COLOR, Enum.Material.Granite)
		end
	end
end

-- The boss's hall: two rows of tall pillars down the long axis, sentinels
-- lining the approach, banners of his colour, braziers of ghost fire, and a
-- throne against the wall opposite the door.
local function addHall(model: Model, centre: CFrame, size: number, entrance: Side?)
	local towardThrone = centre * CFrame.Angles(0, SIDE_YAW[entrance or "South"] + math.pi, 0)

	for _, x in { -size * 0.34, size * 0.34 } do
		for _, z in { -size * 0.3, 0, size * 0.3 } do
			addPillar(model, towardThrone * CFrame.new(x, 0, z), 20)
		end
	end

	-- Sentinels down the processional way, facing the aisle the player walks.
	for _, sign in { -1, 1 } do
		for _, z in { -size * 0.15, size * 0.15 } do
			addStatue(model, towardThrone * CFrame.new(sign * size * 0.22, 0, z) * CFrame.Angles(0, if sign > 0 then math.rad(-90) else math.rad(90), 0))
		end
	end

	local throneBack = towardThrone * CFrame.new(0, 0, size / 2 - 2)
	makePart(model, "ThroneDais", Vector3.new(14, 0.8, 6), throneBack * CFrame.new(0, 0.4, -1.4), TRIM_COLOR, Enum.Material.Slate)
	makePart(model, "ThroneDaisUpper", Vector3.new(10, 0.8, 4), throneBack * CFrame.new(0, 1.2, -0.8), TRIM_COLOR, Enum.Material.Slate)
	makeDecor(model, "ThroneStep", Vector3.new(16, 0.4, 1.6), throneBack * CFrame.new(0, 0.2, -4.2), TRIM_COLOR, Enum.Material.Slate)
	makePart(model, "ThroneSeat", Vector3.new(4.4, 2.8, 3.2), throneBack * CFrame.new(0, 3.0, -0.5), IRON_COLOR, Enum.Material.Metal)
	makeDecor(model, "ThroneBack", Vector3.new(5.0, 12, 0.9), throneBack * CFrame.new(0, 7.6, 0.8), IRON_COLOR, Enum.Material.Metal)
	makeDecor(model, "ThroneArmRight", Vector3.new(0.8, 0.8, 3.2), throneBack * CFrame.new(2.4, 4.4, -0.5), IRON_COLOR, Enum.Material.Metal)
	makeDecor(model, "ThroneArmLeft", Vector3.new(0.8, 0.8, 3.2), throneBack * CFrame.new(-2.4, 4.4, -0.5), IRON_COLOR, Enum.Material.Metal)
	for _, x in { -2.4, 0, 2.4 } do
		makeDecor(model, "ThroneSpike", Vector3.new(0.45, 2.2, 0.45), throneBack * CFrame.new(x, 14.6, 0.8), GOLD_COLOR, Enum.Material.Metal)
	end
	makeDecor(model, "ThroneSigil", Vector3.new(2.4, 2.4, 0.25), throneBack * CFrame.new(0, 10.5, 0.35) * CFrame.Angles(0, 0, math.rad(45)), GHOST_FIRE, Enum.Material.Neon)

	-- Banners down the long walls, in his colour.
	for _, sign in { -1, 1 } do
		local wall = towardThrone * CFrame.Angles(0, sign * math.rad(90), 0)
		for _, z in { -size * 0.22, size * 0.22 } do
			addBanner(model, wall, z, size / 2 + WALL_THICKNESS / 2, BANNER_COLOR)
		end
	end

	for _, x in { -7.5, 7.5 } do
		local brazier = makePart(model, "Brazier", Vector3.new(2.2, 3.2, 2.2), throneBack * CFrame.new(x, 1.6, -2.0), IRON_COLOR, Enum.Material.Metal)
		makeDecor(model, "BrazierBowl", Vector3.new(3.0, 0.9, 3.0), brazier.CFrame * CFrame.new(0, 1.7, 0), IRON_COLOR, Enum.Material.Metal)
		local flames = makeDecor(model, "Flames", Vector3.new(1.6, 0.2, 1.6), brazier.CFrame * CFrame.new(0, 2.2, 0), GHOST_FIRE, Enum.Material.Neon)

		local fire = Instance.new("Fire")
		fire.Size = 5
		fire.Heat = 10
		fire.Color = GHOST_FIRE
		fire.SecondaryColor = Color3.fromRGB(30, 60, 140)
		fire.Parent = flames

		local light = Instance.new("PointLight")
		light.Color = GHOST_FIRE
		light.Brightness = 3.5
		light.Range = 34
		light.Shadows = true
		light.Parent = flames
	end
end

-- A few loose stones along the walls, placed at random so no two rooms look
-- quite alike. Kept to the edges and out of doorways.
local function addRubble(model: Model, centre: CFrame, size: number)
	local edge = size / 2 - 2.5
	for _ = 1, math.random(3, 6) do
		local alongX = math.random() < 0.5
		local along = (math.random() - 0.5) * (size - 10)
		if math.abs(along) < RoomTemplates.DOOR_WIDTH / 2 + 2 then
			continue
		end

		local wallSide = if math.random() < 0.5 then -edge else edge
		local x = if alongX then along else wallSide
		local z = if alongX then wallSide else along

		local stone = 0.6 + math.random() * 1.2
		local rock = makeDecor(
			model,
			"Rubble",
			Vector3.new(stone, stone * 0.6, stone * (0.8 + math.random() * 0.4)),
			centre * CFrame.new(x, stone * 0.25, z) * CFrame.Angles(0, math.random() * math.pi, math.rad(math.random(-15, 15))),
			RUBBLE_COLOR,
			Enum.Material.Slate
		)
		rock.CastShadow = false
	end
end

-- `origin` is the room's floor centre in the world.
function RoomTemplates.build(spec: RoomSpec, origin: CFrame): Room
	local size = spec.size
	local centre = CFrame.new(origin.Position)
	local torchColor = spec.torchColor or DEFAULT_TORCH

	local model = Instance.new("Model")
	model.Name = `{spec.variant}Room`

	makePart(model, "Floor", Vector3.new(size + WALL_THICKNESS * 2, 1, size + WALL_THICKNESS * 2), centre * CFrame.new(0, -0.5, 0), FLOOR_COLOR, Enum.Material.Slate)
	addFlagstones(model, centre, size)

	-- Only rooms with wall enough to carry them get sentinels; a small room
	-- lined with statues reads as cluttered, not grand.
	local statues = size >= 40 and spec.variant ~= "Hall"

	for side in SIDE_YAW do
		addSide(model, centre, size, side, spec.doors[side] == true, torchColor, statues)
	end

	addCeilingRibs(model, centre, size)
	addRubble(model, centre, size)
	addProps(model, centre, size)

	if spec.variant == "Pillars" then
		addPillarsLayout(model, centre, size)
	elseif spec.variant == "Ruins" then
		addRuins(model, centre, size)
	elseif spec.variant == "Hall" then
		addHall(model, centre, size, spec.entrance)
	end

	local position = centre.Position
	local half = size / 2

	return {
		model = model,
		centre = centre,
		size = size,
		floorBounds = {
			minX = position.X - half,
			maxX = position.X + half,
			minZ = position.Z - half,
			maxZ = position.Z + half,
		},
	}
end

-- Where an enemy in this room may go: the floor, less `inset` from each wall.
function RoomTemplates.leashBounds(room: Room, inset: number): Bounds
	local bounds = room.floorBounds
	return {
		minX = bounds.minX + inset,
		maxX = bounds.maxX - inset,
		minZ = bounds.minZ + inset,
		maxZ = bounds.maxZ - inset,
	}
end

-- A walled passage centred on `centre` (floor level), `length` long, running
-- east-west when `alongX`, otherwise north-south. Walled so nobody walks off
-- the edge into the void, and kept low so the halls it joins feel tall.
function RoomTemplates.buildCorridor(parent: Instance, centre: Vector3, length: number, alongX: boolean): Model
	local model = Instance.new("Model")
	model.Name = "Corridor"

	-- Local Z runs along the corridor.
	local frame = CFrame.new(centre) * CFrame.Angles(0, if alongX then math.rad(90) else 0, 0)
	makePart(model, "Floor", Vector3.new(RoomTemplates.DOOR_WIDTH, 1, length), frame * CFrame.new(0, -0.5, 0), FLOOR_COLOR, Enum.Material.Slate)

	for _, sign in { -1, 1 } do
		local x = sign * (RoomTemplates.DOOR_WIDTH / 2 + WALL_THICKNESS / 2)
		local wall = frame * CFrame.new(x, CORRIDOR_HEIGHT / 2, 0) * CFrame.Angles(0, math.rad(90), 0)
		makePart(model, "CorridorWall", Vector3.new(length, CORRIDOR_HEIGHT, WALL_THICKNESS), wall, WALL_COLOR, Enum.Material.Cobblestone)
		makeDecor(model, "CorridorSkirt", Vector3.new(length, 0.9, WALL_THICKNESS + 0.3), wall * CFrame.new(0, -CORRIDOR_HEIGHT / 2 + 0.45, 0), TRIM_COLOR, Enum.Material.Slate)
		makeDecor(model, "CorridorCap", Vector3.new(length, 0.6, WALL_THICKNESS + 0.4), wall * CFrame.new(0, CORRIDOR_HEIGHT / 2 - 0.3, 0), TRIM_COLOR, Enum.Material.Slate)
	end

	-- Ribs overhead, so the passage reads as tunnelled rather than open.
	local ribs = math.max(math.floor(length / 6), 1)
	local ribStep = length / (ribs + 1)
	for index = 1, ribs do
		local z = -length / 2 + ribStep * index
		makeDecor(model, "CorridorRib", Vector3.new(RoomTemplates.DOOR_WIDTH + 2, 0.9, 1.1), frame * CFrame.new(0, CORRIDOR_HEIGHT - 0.5, z), TRIM_COLOR, Enum.Material.Slate)
	end

	-- One lantern overhead, so the walk between rooms isn't pitch dark.
	local lantern = makeDecor(model, "Lantern", Vector3.new(0.8, 1, 0.8), frame * CFrame.new(0, CORRIDOR_HEIGHT - 3, 0), Color3.fromRGB(255, 190, 110), Enum.Material.Neon)
	makeDecor(model, "LanternCage", Vector3.new(1.1, 1.3, 1.1), frame * CFrame.new(0, CORRIDOR_HEIGHT - 3, 0), IRON_COLOR, Enum.Material.Metal).Transparency = 0.55
	makeDecor(model, "LanternChain", Vector3.new(0.12, 2.2, 0.12), frame * CFrame.new(0, CORRIDOR_HEIGHT - 1.4, 0), IRON_COLOR, Enum.Material.Metal)
	local light = Instance.new("PointLight")
	light.Color = DEFAULT_TORCH
	light.Brightness = 1.4
	light.Range = 16
	light.Parent = lantern

	model.Parent = parent
	return model
end

return RoomTemplates
