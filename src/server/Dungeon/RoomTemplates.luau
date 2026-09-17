--!strict
-- Room geometry: a flagstone floor, tall walls with an arched doorway on any
-- side that needs one, carved bays and stone sentinels, a ribbed ceiling, the
-- variant's inner layout (pillars, ruins, a throne hall), props and torches.
-- Also the corridors between rooms, so every piece of dungeon shares one look.
--
-- The pieces themselves — walls, arches, pillars, torches, statues, banners,
-- ceilings — come from Stonework, which the hub builds from too. What lives
-- here is the composition: how a crypt is laid out, which is what makes it
-- read as a crypt rather than as the great hall upstairs.
--
-- One module rather than a RoomTemplates/ folder: each variant is a short
-- geometry recipe, not enough content to warrant its own file — the same way
-- WeaponDefs and EnemyDefs keep every entry in one module.
--
-- Rooms are only ever translated, never rotated, so walls, corridors and the
-- leash are all axis-aligned. Dressing (trim, arches, doors, banners, statues,
-- barrels, torches, rubble, the ceiling) is decoration: it never collides, and
-- never changes a room's size, doors or leash. Only the floor, the lower
-- walls, the door posts, the statue plinths and the variant's pillars stop
-- anything — those are the things a player expects to stop them, and the
-- things an enemy's leash is measured against.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DungeonDefs = require(ReplicatedStorage.Shared.DungeonDefs)
local Stonework = require(script.Parent.Parent.Stonework)

local RoomTemplates = {}

RoomTemplates.DOOR_WIDTH = DungeonDefs.CORRIDOR_WIDTH
-- The clear height of a doorway, up to where its arch springs. Anything meant
-- to fill a doorway — a portcullis, a gate — sizes itself from this.
RoomTemplates.DOOR_HEIGHT = 12

-- How tall the stonework reads, and how much of it is actually solid.
--
-- Nobody can jump fourteen studs, so every stud above COLLIDE_HEIGHT is pure
-- decoration — and building it non-query means the camera passes straight
-- through it. That is what lets a hall be more than twice as tall as a player
-- can reach without the camera jamming into a wall every time someone backs up
-- against one. Raising the whole wall as one solid slab would have made every
-- room feel grander and play worse.
local WALL_HEIGHT = 32
local COLLIDE_HEIGHT = 14
local WALL_THICKNESS = 1.5

-- Corridors stay low and tunnelled. Stepping out of a fourteen-stud passage
-- into a thirty-two-stud hall is what sells the hall; making both tall would
-- flatten the contrast and cost twice the parts.
local CORRIDOR_HEIGHT = 14

-- How far inside the walls an enemy's leash stops, so a rig backed against a
-- wall doesn't clip into it. Scaled by the rig's size where it's used.
RoomTemplates.LEASH_INSET = 3

-- Pillars are five studs through — better than twice a player's width, which
-- is the point of them: a pillar you can hide a Shambler behind, not a post.
local PILLAR_THICKNESS = 5

local TORCH_HEIGHT = 9
-- Where the doorway arch springs from, and how wide its ring is.
local ARCH_SPRING = RoomTemplates.DOOR_HEIGHT
local ARCH_RADIUS = 5.8
local VOUSSOIRS = 9
-- Height of the carved bays between buttresses.
local BAY_TOP = 20
-- Below this width a room is too small to line with sentinels: it reads as
-- cluttered rather than grand.
local STATUE_MIN_SIZE = 60

local DEFAULT_TORCH = Stonework.TORCH_FIRE

local WALL_SPEC: Stonework.WallSpec = {
	height = WALL_HEIGHT,
	collideHeight = COLLIDE_HEIGHT,
	thickness = WALL_THICKNESS,
	courseAt = BAY_TOP + 0.8,
}

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

local part = Stonework.part
local decor = Stonework.decor

--[[ Doorways ]]

-- The ring of wedge stones over a doorway, an outer moulding around it, and
-- the mark of the place above that. `frame` looks out through the side; the
-- ring is laid on the inner face.
local function addArch(model: Instance, frame: CFrame, wallZ: number)
	local face = wallZ - WALL_THICKNESS / 2 - 0.25

	Stonework.arch(model, frame, {
		springAt = ARCH_SPRING,
		radius = ARCH_RADIUS,
		face = face,
		stones = VOUSSOIRS,
		depth = 2.8,
		thickness = 1.6,
	})

	decor(model, "ArchLabel", Vector3.new(RoomTemplates.DOOR_WIDTH + 6.4, 0.6, 0.6), frame * CFrame.new(0, ARCH_SPRING + ARCH_RADIUS + 2.2, face), Stonework.TRIM, Enum.Material.Slate)
	decor(model, "ArchSigil", Vector3.new(1.6, 1.6, 0.3), frame * CFrame.new(0, ARCH_SPRING + ARCH_RADIUS + 3.7, face) * CFrame.Angles(0, 0, math.rad(45)), Stonework.GOLD, Enum.Material.Metal)
end

-- One leaf of a pair of doors, standing open flat against the wall. Doors are
-- never shut — a shut door would block the corridor the room is reached by —
-- so they are pure dressing, and say "this was built to be closed".
local function addDoorLeaf(model: Instance, frame: CFrame, sign: number, wallZ: number)
	local width = 4.4
	local height = ARCH_SPRING - 0.8
	local hinge = sign * (RoomTemplates.DOOR_WIDTH / 2 + 0.2)
	local leaf = frame
		* CFrame.new(hinge + sign * width / 2, height / 2, wallZ - WALL_THICKNESS / 2 - 0.5)
		* CFrame.Angles(0, math.rad(-8 * sign), 0)

	decor(model, "DoorLeaf", Vector3.new(width, height, 0.4), leaf, Stonework.WOOD, Enum.Material.WoodPlanks)
	for _, y in { height / 2 - 1.0, 0, -height / 2 + 1.0 } do
		decor(model, "DoorBand", Vector3.new(width + 0.12, 0.45, 0.55), leaf * CFrame.new(0, y, 0), Stonework.IRON, Enum.Material.Metal)
	end
	decor(model, "DoorBrace", Vector3.new(width + 0.12, 0.3, 0.5), leaf * CFrame.Angles(0, 0, math.rad(40)), Stonework.RUST, Enum.Material.Metal)
	decor(model, "DoorRing", Vector3.new(0.7, 0.7, 0.2), leaf * CFrame.new(-sign * (width / 2 - 0.7), 0.6, -0.3), Stonework.RUST, Enum.Material.Metal)
end

--[[ One side of a room ]]

-- Lays out a wall's bays: buttresses at regular intervals, a carved panel in
-- each bay between them, and a statue in every other bay on a wall long
-- enough to carry one.
local function dressWall(model: Model, frame: CFrame, length: number, wallZ: number, hasDoor: boolean, statues: boolean)
	-- Wider bays than the first pass, because the rooms are wider. Keeping the
	-- old thirteen-stud rhythm at this size would have put twelve sentinels in
	-- an average room — three hundred parts of statue per room, in a dungeon
	-- that rebuilds itself every clear.
	local spacing = 20
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
			Stonework.buttress(model, frame * CFrame.new(x, 0, face - 0.35), WALL_HEIGHT, BAY_TOP, 2.4)
		end
	end

	-- Bays sit between consecutive buttresses, and at both ends.
	for index = 0, count do
		local from = -length / 2 + step * index
		local to = -length / 2 + step * (index + 1)
		local centre = (from + to) / 2
		local width = (to - from) - 3.0
		if width < 3 or not clear(centre, width / 2 + 1) then
			continue
		end

		Stonework.bay(model, frame * CFrame.new(centre, 0, face - 0.15), width, BAY_TOP)
		-- No extra yaw: the wall frame's +Z points out through the wall, so
		-- its -Z already points into the room, which is the way a statue
		-- faces. The half-turn that used to be here turned every sentinel in
		-- the game around to stare at the wall behind it.
		if statues and index % 2 == 0 then
			Stonework.statue(model, frame * CFrame.new(centre, 0, face - 1.9))
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
			Stonework.wall(model, "WallSegment", segment + WALL_THICKNESS, frame * CFrame.new(x, WALL_HEIGHT / 2, wallZ), WALL_SPEC)

			-- A heavy post either side of the doorway, up to the springing.
			local postX = sign * (RoomTemplates.DOOR_WIDTH / 2 + 0.8)
			part(model, "DoorPost", Vector3.new(1.6, ARCH_SPRING, 2.4), frame * CFrame.new(postX, ARCH_SPRING / 2, wallZ), Stonework.TRIM, Enum.Material.Slate)
			decor(model, "DoorPostCap", Vector3.new(2.2, 0.5, 2.8), frame * CFrame.new(postX, ARCH_SPRING, wallZ), Stonework.PILLAR, Enum.Material.Granite)
			decor(model, "DoorPostFoot", Vector3.new(2.2, 0.5, 2.8), frame * CFrame.new(postX, 0.25, wallZ), Stonework.PILLAR, Enum.Material.Granite)

			addDoorLeaf(model, frame, sign, wallZ)
		end

		-- The wall above the opening. Solid only as high as anything else,
		-- so the camera can follow a player through the doorway.
		local solid = math.max(COLLIDE_HEIGHT - ARCH_SPRING, 0)
		local head = WALL_HEIGHT - ARCH_SPRING
		part(
			model,
			"DoorHead",
			Vector3.new(RoomTemplates.DOOR_WIDTH + 3.2, solid, WALL_THICKNESS),
			frame * CFrame.new(0, ARCH_SPRING + solid / 2, wallZ),
			Stonework.WALL,
			Enum.Material.Cobblestone
		)
		decor(
			model,
			"DoorHeadUpper",
			Vector3.new(RoomTemplates.DOOR_WIDTH + 3.2, head - solid, WALL_THICKNESS),
			frame * CFrame.new(0, ARCH_SPRING + solid + (head - solid) / 2, wallZ),
			Stonework.WALL,
			Enum.Material.Cobblestone
		)
		addArch(model, frame, wallZ)
	else
		Stonework.wall(model, "Wall", size + WALL_THICKNESS * 2, frame * CFrame.new(0, WALL_HEIGHT / 2, wallZ), WALL_SPEC)
	end

	dressWall(model, frame, size, wallZ, hasDoor, statues)

	-- Torches spaced along the wall, always clear of the doorway. A room this
	-- size needs more than the two the first pass hung on it, or the middle of
	-- every wall falls into the dark.
	local lights = math.clamp(math.floor(size / 26), 1, 3)
	for index = 1, lights do
		local x = -size / 2 + (size / (lights + 1)) * index
		if hasDoor and math.abs(x) < RoomTemplates.DOOR_WIDTH / 2 + 3 then
			continue
		end
		local mount = frame * CFrame.new(x, TORCH_HEIGHT, size / 2)
		local inward = frame * CFrame.new(x, TORCH_HEIGHT, 0)
		Stonework.torch(model, CFrame.lookAt(mount.Position, inward.Position), torchColor)
	end
end

--[[ Props ]]

-- Dressing that belongs to every room: things left in the corners, webs in
-- the angles, and chains out of the dark above. Scaled to the room, kept to
-- the edges and out of the doorways.
local function addProps(model: Model, centre: CFrame, size: number)
	local edge = size / 2 - 3.5

	for _, xSign in { -1, 1 } do
		for _, zSign in { -1, 1 } do
			Stonework.cobweb(model, centre * CFrame.new(xSign * (size / 2 - 1.8), 11, zSign * (size / 2 - 1.8)), 5)
		end
	end

	local clutter = math.max(math.floor(size / 12), 3)
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
			Stonework.barrel(model, base)
		elseif roll < 0.68 then
			Stonework.crate(model, base)
		else
			Stonework.bones(model, base)
		end
	end

	-- Chains are built link by link, so a long one is twenty parts. Two or
	-- three short ones read the same from the floor as five long ones and cost
	-- a fifth as much.
	for _ = 1, math.random(2, 3) do
		local x = (math.random() - 0.5) * (size - 20)
		local z = (math.random() - 0.5) * (size - 20)
		Stonework.chain(model, centre * CFrame.new(x, WALL_HEIGHT - 1.4, z), 7 + math.random() * 7)
	end
end

-- A few loose stones along the walls, placed at random so no two rooms look
-- quite alike. Kept to the edges and out of doorways.
local function addRubble(model: Model, centre: CFrame, size: number)
	local edge = size / 2 - 2.5
	for _ = 1, math.random(4, 8) do
		local alongX = math.random() < 0.5
		local along = (math.random() - 0.5) * (size - 10)
		if math.abs(along) < RoomTemplates.DOOR_WIDTH / 2 + 2 then
			continue
		end

		local wallSide = if math.random() < 0.5 then -edge else edge
		local x = if alongX then along else wallSide
		local z = if alongX then wallSide else along
		Stonework.rubbleStone(model, centre * CFrame.new(x, 0, z))
	end
end

--[[ Variants ]]

-- Four pillars, a third of the way in from each corner: cover to break a
-- Spitter's line, and something to circle a melee enemy around. Floor to
-- ceiling, now that there is a ceiling for them to reach.
local function addPillarsLayout(model: Model, centre: CFrame, size: number)
	local at = size * 0.28
	for _, xSign in { -1, 1 } do
		for _, zSign in { -1, 1 } do
			Stonework.pillar(model, centre * CFrame.new(xSign * at, 0, zSign * at), WALL_HEIGHT, PILLAR_THICKNESS, COLLIDE_HEIGHT)
		end
	end
end

-- Broken, waist-high walls on the diagonals: cover that doesn't block the view
-- of a telegraph. Kept out of the centre, where enemies spawn, and off the
-- straight lines between doors.
local function addRuins(model: Model, centre: CFrame, size: number)
	for i = 0, 5 do
		local angle = math.rad(30 + 60 * i) + (math.random() - 0.5) * 0.3
		local radius = size * (0.26 + math.random() * 0.08)
		local length = 4 + math.random() * 4
		local height = 2.4 + math.random() * 1.8
		local base = centre * CFrame.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			* CFrame.Angles(0, angle + math.pi / 2 + (math.random() - 0.5) * 0.5, 0)

		part(model, "RuinWall", Vector3.new(length, height, 1.4), base * CFrame.new(0, height / 2, 0), Stonework.WALL, Enum.Material.Cobblestone)
		decor(model, "RuinCap", Vector3.new(length + 0.3, 0.3, 1.7), base * CFrame.new(0, height, 0), Stonework.TRIM, Enum.Material.Slate)
		decor(model, "RuinRubble", Vector3.new(1.2, 0.8, 1), base * CFrame.new(length / 2 + 0.6, 0.4, 0.8) * CFrame.Angles(0, 0.6, 0.3), Stonework.RUBBLE, Enum.Material.Slate)
		-- A broken column stump beside the ruin.
		if i % 2 == 0 then
			decor(model, "BrokenColumn", Vector3.new(2.6, 3.4 + math.random() * 3, 2.6), base * CFrame.new(-length / 2 - 1.8, 1.9, -0.5), Stonework.PILLAR, Enum.Material.Granite)
		end
	end
end

-- The boss's hall: two rows of tall pillars down the long axis, sentinels
-- lining the approach, banners of his colour, braziers of ghost fire, and a
-- throne against the wall opposite the door.
local function addHall(model: Model, centre: CFrame, size: number, entrance: Side?)
	local towardThrone = centre * CFrame.Angles(0, SIDE_YAW[entrance or "South"] + math.pi, 0)

	for _, x in { -size * 0.3, size * 0.3 } do
		for _, z in { -size * 0.3, 0, size * 0.3 } do
			Stonework.pillar(model, towardThrone * CFrame.new(x, 0, z), WALL_HEIGHT, PILLAR_THICKNESS + 1, COLLIDE_HEIGHT)
		end
	end

	-- Sentinels down the processional way, turned a quarter onto the aisle the
	-- player walks up. A statue faces its own -Z, so the one standing to the
	-- right of the aisle turns +90 to look back across it, not -90.
	for _, sign in { -1, 1 } do
		for _, z in { -size * 0.15, size * 0.15 } do
			Stonework.statue(model, towardThrone * CFrame.new(sign * size * 0.19, 0, z) * CFrame.Angles(0, sign * math.rad(90), 0), 1.3)
		end
	end

	local throneBack = towardThrone * CFrame.new(0, 0, size / 2 - 2)
	part(model, "ThroneDais", Vector3.new(18, 0.8, 8), throneBack * CFrame.new(0, 0.4, -1.8), Stonework.TRIM, Enum.Material.Slate)
	part(model, "ThroneDaisUpper", Vector3.new(13, 0.8, 5.4), throneBack * CFrame.new(0, 1.2, -1.0), Stonework.TRIM, Enum.Material.Slate)
	decor(model, "ThroneStep", Vector3.new(21, 0.4, 2.0), throneBack * CFrame.new(0, 0.2, -5.6), Stonework.TRIM, Enum.Material.Slate)
	part(model, "ThroneSeat", Vector3.new(5.4, 3.2, 3.8), throneBack * CFrame.new(0, 3.2, -0.6), Stonework.IRON, Enum.Material.Metal)
	decor(model, "ThroneBack", Vector3.new(6.2, 16, 1.0), throneBack * CFrame.new(0, 9.4, 0.9), Stonework.IRON, Enum.Material.Metal)
	decor(model, "ThroneArmRight", Vector3.new(0.9, 0.9, 3.8), throneBack * CFrame.new(3.0, 4.8, -0.6), Stonework.IRON, Enum.Material.Metal)
	decor(model, "ThroneArmLeft", Vector3.new(0.9, 0.9, 3.8), throneBack * CFrame.new(-3.0, 4.8, -0.6), Stonework.IRON, Enum.Material.Metal)
	for _, x in { -2.8, 0, 2.8 } do
		decor(model, "ThroneSpike", Vector3.new(0.5, 2.6, 0.5), throneBack * CFrame.new(x, 18.6, 0.9), Stonework.GOLD, Enum.Material.Metal)
	end
	decor(model, "ThroneSigil", Vector3.new(3.0, 3.0, 0.25), throneBack * CFrame.new(0, 13, 0.4) * CFrame.Angles(0, 0, math.rad(45)), Stonework.GHOST_FIRE, Enum.Material.Neon)

	-- Banners down the long walls, in his colour.
	for _, sign in { -1, 1 } do
		local wall = towardThrone * CFrame.Angles(0, sign * math.rad(90), 0)
		for _, z in { -size * 0.24, 0, size * 0.24 } do
			Stonework.banner(model, wall, z, WALL_HEIGHT - 3.0, size / 2 + WALL_THICKNESS / 2 - 0.3, Stonework.CRIMSON, 1.4)
		end
	end

	for _, x in { -9.5, 9.5 } do
		Stonework.brazier(model, throneBack * CFrame.new(x, 0, -3.0), Stonework.GHOST_FIRE, 1.3)
	end
end

--[[ Build ]]

-- `origin` is the room's floor centre in the world.
function RoomTemplates.build(spec: RoomSpec, origin: CFrame): Room
	local size = spec.size
	local centre = CFrame.new(origin.Position)
	local torchColor = spec.torchColor or DEFAULT_TORCH

	local model = Instance.new("Model")
	model.Name = `{spec.variant}Room`

	part(model, "Floor", Vector3.new(size + WALL_THICKNESS * 2, 1, size + WALL_THICKNESS * 2), centre * CFrame.new(0, -0.5, 0), Stonework.FLOOR, Enum.Material.Slate)
	Stonework.flagstones(model, centre, size, size)
	Stonework.floorInlay(model, centre, math.min(size * 0.22, 14))

	-- Only rooms with wall enough to carry them get sentinels; a small room
	-- lined with statues reads as cluttered, not grand.
	local statues = size >= STATUE_MIN_SIZE and spec.variant ~= "Hall"

	for side in SIDE_YAW do
		addSide(model, centre, size, side, spec.doors[side] == true, torchColor, statues)
	end

	-- The ceiling goes on last, and is what makes the room a room: the sky is
	-- shut out, and the torches on the walls become the only light in it.
	-- Simpler than the hub's — ribs one way and no coffering, because a crypt
	-- is not a cathedral and there are a great many of them.
	Stonework.ceiling(model, centre, {
		height = WALL_HEIGHT,
		sizeX = size,
		sizeZ = size,
		ribSpacing = 18,
		coffered = false,
	})

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
-- east-west when `alongX`, otherwise north-south. Walled and roofed so nobody
-- walks off the edge into the void, and kept low so the halls it joins feel
-- tall.
function RoomTemplates.buildCorridor(parent: Instance, centre: Vector3, length: number, alongX: boolean): Model
	local model = Instance.new("Model")
	model.Name = "Corridor"

	-- Local Z runs along the corridor.
	local frame = CFrame.new(centre) * CFrame.Angles(0, if alongX then math.rad(90) else 0, 0)
	part(model, "Floor", Vector3.new(RoomTemplates.DOOR_WIDTH, 1, length), frame * CFrame.new(0, -0.5, 0), Stonework.FLOOR, Enum.Material.Slate)

	for _, sign in { -1, 1 } do
		local x = sign * (RoomTemplates.DOOR_WIDTH / 2 + WALL_THICKNESS / 2)
		local wall = frame * CFrame.new(x, CORRIDOR_HEIGHT / 2, 0) * CFrame.Angles(0, math.rad(90), 0)
		part(model, "CorridorWall", Vector3.new(length, CORRIDOR_HEIGHT, WALL_THICKNESS), wall, Stonework.WALL, Enum.Material.Cobblestone)
		decor(model, "CorridorSkirt", Vector3.new(length, 0.9, WALL_THICKNESS + 0.3), wall * CFrame.new(0, -CORRIDOR_HEIGHT / 2 + 0.45, 0), Stonework.TRIM, Enum.Material.Slate)
		decor(model, "CorridorCap", Vector3.new(length, 0.6, WALL_THICKNESS + 0.4), wall * CFrame.new(0, CORRIDOR_HEIGHT / 2 - 0.3, 0), Stonework.TRIM, Enum.Material.Slate)
	end

	-- A vaulted lid over the passage, with ribs under it.
	local roof = decor(
		model,
		"CorridorRoof",
		Vector3.new(RoomTemplates.DOOR_WIDTH + WALL_THICKNESS * 2 + 0.4, 1.2, length),
		frame * CFrame.new(0, CORRIDOR_HEIGHT + 0.6, 0),
		Stonework.WALL_DARK,
		Enum.Material.Cobblestone
	)
	roof.CastShadow = true

	local ribs = math.max(math.floor(length / 6), 1)
	local ribStep = length / (ribs + 1)
	for index = 1, ribs do
		local z = -length / 2 + ribStep * index
		decor(model, "CorridorRib", Vector3.new(RoomTemplates.DOOR_WIDTH + 2, 0.9, 1.1), frame * CFrame.new(0, CORRIDOR_HEIGHT - 0.5, z), Stonework.TRIM, Enum.Material.Slate)
	end

	-- Lanterns overhead, so the walk between rooms isn't pitch dark. More than
	-- one now that a corridor is twenty studs long and roofed over.
	local lanterns = math.max(math.round(length / 14), 1)
	for index = 1, lanterns do
		local z = -length / 2 + (length / (lanterns + 1)) * index
		local lantern = decor(model, "Lantern", Vector3.new(0.8, 1, 0.8), frame * CFrame.new(0, CORRIDOR_HEIGHT - 3.5, z), Color3.fromRGB(255, 190, 110), Enum.Material.Neon)
		decor(model, "LanternCage", Vector3.new(1.1, 1.3, 1.1), frame * CFrame.new(0, CORRIDOR_HEIGHT - 3.5, z), Stonework.IRON, Enum.Material.Metal).Transparency = 0.55
		decor(model, "LanternChain", Vector3.new(0.12, 2.4, 0.12), frame * CFrame.new(0, CORRIDOR_HEIGHT - 1.8, z), Stonework.IRON, Enum.Material.Metal)

		local light = Instance.new("PointLight")
		light.Color = DEFAULT_TORCH
		light.Brightness = 1.8
		light.Range = 22
		light.Parent = lantern
	end

	model.Parent = parent
	return model
end

return RoomTemplates
