--!strict
-- The hub: one enormous vaulted hall, and the only place a player stands that
-- is not the dungeon.
--
-- Everything in the game that is not a fight happens here — choosing a class
-- at an altar, upgrading at the forge, queueing at one of the three gates — so
-- the hall is built to be walked through rather than fought in. Its shape is a
-- cathedral nave: two rows of pillars running the length of it with an arcade
-- of arches between them, wide aisles outside those, the three gates in the
-- north wall at the far end, and the dais you arrived on behind you.
--
-- This module builds stone and nothing else. It knows *where* the forge stands
-- and where the altars stand, because that is a question about the building,
-- but it does not know what a forge or an altar *does* — it hands back the
-- frames, and BlacksmithService, ClassAltars and QueueService put their
-- stations on them. That split is why the hall can be rearranged without
-- touching a line of station code.
--
-- The pieces come from Stonework, the same kit the dungeon is cut from. The
-- hub is not a different world; it is the same world, above ground and swept.
--
-- Like a dungeon room, the hall is only ever translated, never rotated, so
-- every frame in here is the hall's centre times an offset.

local Stonework = require(script.Parent.Parent.Stonework)

local LobbyBuilder = {}

--[[ The shape of the hall ]]

-- Interior floor, east-west by north-south. Big enough that the far wall is a
-- silhouette rather than a surface when you spawn.
local HALL_X = 150
local HALL_Z = 190

-- Walls read fifty-eight studs and are solid to fifteen. Everything above is
-- decoration, which keeps the camera out of it — the same rule the dungeon
-- runs on, at nearly twice the height.
local WALL_HEIGHT = 58
local COLLIDE_HEIGHT = 15
local WALL_THICKNESS = 3
-- Where the string course runs, and how high the carved bays reach.
local BAY_TOP = 24

-- The nave: two rows of pillars this far either side of the centre line.
local NAVE_HALF = 40
-- Pillars are six and a half studs through — well over twice the width of the
-- player walking between them, which is the whole point. A pillar you can put
-- your back against and not be seen around reads as structure; a two-stud post
-- reads as scaffolding.
local PILLAR_THICKNESS = 6.5
local PILLAR_Z = { -75, -45, -15, 15, 45, 75 }
-- The arcade between them: where the rings spring from, and how far they reach.
local ARCADE_SPRING = 24
local ARCADE_RADIUS = 13

-- Clerestory windows sit high in the long walls, one over each bay — which is
-- why their places are computed from the bay rhythm rather than listed: a
-- window that lands on a buttress reads as a mistake, and hard-coding the two
-- lists separately is how that happens the next time a number changes.
local WINDOW_Y = 44
-- Banners hang below the window sills and above the mounted arms. That band is
-- narrow, and it is the reason both numbers are here rather than inlined.
local BANNER_TOP = 34
local DAYLIGHT = Color3.fromRGB(204, 222, 255)

-- Where the three gates stand in the north wall, and how big each opening is.
local GATE_X = { -48, 0, 48 }
local GATE_WIDTH = 16
local GATE_HEIGHT = 24
local GATE_DEPTH = 9
-- How far in front of the wall the ready-check station stands.
local GATE_STAND_BACK = 13

-- Where each station stands in its aisle.
local ALTAR_X = -56
local ALTAR_Z = { -42, 0, 42 }
local FORGE_X = 56
local DUEL_AT = Vector3.new(52, 0, -66)

-- The dais at the south end that players arrive on.
local DAIS_Z = -80
local DAIS_X_HALF = 26
local DAIS_Z_HALF = 13
local DAIS_HEIGHT = 1.6

local WALL_SPEC: Stonework.WallSpec = {
	height = WALL_HEIGHT,
	collideHeight = COLLIDE_HEIGHT,
	thickness = WALL_THICKNESS,
	courseAt = BAY_TOP + 1.2,
}

export type Bounds = {
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

export type Lobby = {
	model: Model,
	-- Floor centre.
	centre: CFrame,
	-- The interior floor, for "is this player in the hub".
	bounds: Bounds,
	-- Where a character appears, already facing the gates.
	spawnCFrame: CFrame,
	-- One per gate, standing in front of its portal and looking into it.
	gateAnchors: { CFrame },
	-- One per class altar, backed against the west aisle wall and looking into
	-- the hall.
	altarAnchors: { CFrame },
	-- Looks out of the forge's open front, the way BlacksmithService wants it.
	forgeAnchor: CFrame,
	duelAnchor: CFrame,
}

local part = Stonework.part
local decor = Stonework.decor

-- Yaw that turns a hall-local frame so its +Z points out through that side,
-- and its X runs along the wall. The dungeon's rooms use the same convention.
local SIDE_YAW: { [string]: number } = {
	North = 0,
	East = math.rad(90),
	South = math.rad(180),
	West = math.rad(-90),
}

--[[ Floor ]]

-- The floor, its flagstone seams, the great figure at the centre of the nave,
-- a runner of worn carpet down it and the dais at the south end.
local function addFloor(model: Model, centre: CFrame)
	part(model, "Floor", Vector3.new(HALL_X + WALL_THICKNESS * 2, 2, HALL_Z + WALL_THICKNESS * 2), centre * CFrame.new(0, -1, 0), Stonework.FLOOR, Enum.Material.Slate)
	Stonework.flagstones(model, centre, HALL_X, HALL_Z)
	Stonework.floorInlay(model, centre, 26)

	-- A runner from the dais to the gates. Cloth is the only soft thing in the
	-- hall, and it tells a first-time player which way to walk without a
	-- single word of interface.
	decor(model, "Runner", Vector3.new(14, 0.12, HALL_Z - 36), centre * CFrame.new(0, 0.07, 6), Stonework.CRIMSON, Enum.Material.Fabric).CastShadow = false
	for _, sign in { -1, 1 } do
		decor(model, "RunnerEdge", Vector3.new(1.2, 0.14, HALL_Z - 36), centre * CFrame.new(sign * 7.6, 0.08, 6), Stonework.GOLD, Enum.Material.Fabric).CastShadow = false
	end

	-- The dais players arrive on: two steps up, so spawning reads as arriving
	-- somewhere rather than materialising on a floor.
	for step = 1, 2 do
		local inset = (step - 1) * 3
		local height = DAIS_HEIGHT * step / 2
		part(
			model,
			"Dais",
			Vector3.new((DAIS_X_HALF - inset) * 2, height, (DAIS_Z_HALF - inset) * 2),
			centre * CFrame.new(0, height / 2, DAIS_Z),
			Stonework.TRIM,
			Enum.Material.Slate
		)
	end
	Stonework.floorInlay(model, centre * CFrame.new(0, DAIS_HEIGHT, DAIS_Z), 9)

	-- Braziers at the front corners of the dais, so the first thing a player
	-- sees on arriving is firelight.
	for _, sign in { -1, 1 } do
		Stonework.brazier(model, centre * CFrame.new(sign * (DAIS_X_HALF + 5), 0, DAIS_Z + DAIS_Z_HALF - 2), Stonework.TORCH_FIRE, 1.3, false)
	end
end

--[[ Walls ]]

-- Where the buttresses stand along a wall of this length.
local function buttressOffsets(length: number): { number }
	local count = math.max(math.floor(length / 30) - 1, 1)
	local step = length / (count + 1)

	local offsets = {}
	for index = 1, count do
		table.insert(offsets, -length / 2 + step * index)
	end
	return offsets
end

-- The centre of each bay between them, and how wide it is. Everything hung on
-- a wall — panels, banners, statues, arms, windows — is placed off this, so
-- nothing ever lands on a buttress.
local function bayCentres(length: number): ({ number }, number)
	local count = math.max(math.floor(length / 30) - 1, 1)
	local step = length / (count + 1)

	local centres = {}
	for index = 0, count do
		table.insert(centres, -length / 2 + step * index + step / 2)
	end
	return centres, step - 5.4
end

-- Buttresses, carved bays, banners, sentinels, mounted arms and torches along
-- one wall. `frame`'s local X runs along the wall and +Z points out through it.
local function dressWall(model: Model, frame: CFrame, length: number, wallZ: number)
	local face = wallZ - WALL_THICKNESS / 2

	for _, x in buttressOffsets(length) do
		Stonework.buttress(model, frame * CFrame.new(x, 0, face - 0.35), WALL_HEIGHT, BAY_TOP, 4.2)
	end

	local centres, width = bayCentres(length)
	if width < 6 then
		return
	end

	for index, mid in centres do
		Stonework.bay(model, frame * CFrame.new(mid, 0, face - 0.15), width, BAY_TOP)

		-- A sentinel in every other bay, and arms and a banner in the ones
		-- between. Statues the whole way along reads as a warehouse of
		-- statues; alternating gives a wall this long something to rhyme.
		--
		-- No extra yaw on either: the frame's -Z already points into the hall,
		-- which is the way a statue and a trophy board both face.
		if index % 2 == 1 then
			Stonework.statue(model, frame * CFrame.new(mid, 0, face - 2.6), 1.6)
		else
			Stonework.trophy(model, frame * CFrame.new(mid, 13, face - 0.7), (index % 3) + 1)
			Stonework.banner(model, frame, mid, BANNER_TOP, face - 0.4, Stonework.CRIMSON, 1.2)
		end
	end

	-- Torches spaced wide. The first pass hung one every twenty-four studs and
	-- turned every surface in the hall orange, which is the one thing the
	-- palette exists to prevent: cold stone is what lets a fire read as a fire.
	local torches = math.max(math.floor(length / 36), 1)
	for index = 1, torches do
		local x = -length / 2 + (length / (torches + 1)) * index
		local mount = frame * CFrame.new(x, 9, face)
		local inward = frame * CFrame.new(x, 9, 0)
		Stonework.torch(model, CFrame.lookAt(mount.Position, inward.Position), Stonework.TORCH_FIRE, 1.0)
	end
end

-- A clerestory window: a tall opening high in the wall, its stone surround,
-- and the cold daylight coming through it. The pane is Neon rather than Glass
-- because there is nothing behind it — the hall is a sealed box, and the
-- window has to be its own light.
local function addWindow(model: Model, frame: CFrame, x: number, wallZ: number)
	local face = wallZ - WALL_THICKNESS / 2 - 0.2

	-- Held well back from opaque. A Neon pane at full strength is the
	-- brightest thing Roblox can draw, and twelve of them in one room blow the
	-- whole hall out to white however low the exposure goes.
	local pane = decor(model, "WindowPane", Vector3.new(8, 14, 0.5), frame * CFrame.new(x, WINDOW_Y, face), DAYLIGHT, Enum.Material.Neon)
	pane.Transparency = 0.55
	pane.CastShadow = false

	for _, sign in { -1, 1 } do
		decor(model, "WindowJamb", Vector3.new(1.4, 16, 1.2), frame * CFrame.new(x + sign * 4.7, WINDOW_Y, face), Stonework.PILLAR, Enum.Material.Granite)
	end
	decor(model, "WindowSill", Vector3.new(11, 1.0, 1.6), frame * CFrame.new(x, WINDOW_Y - 7.6, face), Stonework.TRIM, Enum.Material.Slate)
	decor(model, "WindowHead", Vector3.new(11, 1.0, 1.6), frame * CFrame.new(x, WINDOW_Y + 7.6, face), Stonework.TRIM, Enum.Material.Slate)
	decor(model, "WindowMullion", Vector3.new(0.6, 14, 0.7), frame * CFrame.new(x, WINDOW_Y, face - 0.2), Stonework.IRON, Enum.Material.Metal)
	for _, y in { -4.0, 0, 4.0 } do
		decor(model, "WindowTransom", Vector3.new(8, 0.5, 0.7), frame * CFrame.new(x, WINDOW_Y + y, face - 0.2), Stonework.IRON, Enum.Material.Metal)
	end

	Stonework.arch(model, frame * CFrame.new(x, 0, 0), {
		springAt = WINDOW_Y + 7.6,
		radius = 6.2,
		face = face,
		stones = 7,
		depth = 2.0,
		thickness = 2.6,
	})

	-- The window's own spill. No shadows: it is standing in for a sun the
	-- ceiling has already blocked, and it needs to reach the floor.
	--
	-- Kept dim and short. Twelve of these at the sixty-stud range they started
	-- at overlapped across the whole hall, and a dozen overlapping lights is
	-- not twelve times brighter to the eye — it is just white.
	local light = Instance.new("PointLight")
	light.Color = DAYLIGHT
	light.Brightness = 1.4
	light.Range = 44
	light.Shadows = false
	light.Parent = pane
end

-- One of the long walls, with its windows, and the shafts of daylight that
-- fall from them. Only the west wall casts shafts: they all have to lean the
-- same way, or the hall reads as lit by two suns.
local function addLongWall(model: Model, centre: CFrame, side: string, castsShafts: boolean)
	local frame = centre * CFrame.Angles(0, SIDE_YAW[side], 0)
	local wallZ = HALL_X / 2 + WALL_THICKNESS / 2
	-- West is -X, east is +X. The wall's local X runs along the hall, and
	-- which way along it flips with the side.
	local sign = if side == "West" then -1 else 1

	Stonework.wall(model, `{side}Wall`, HALL_Z + WALL_THICKNESS * 2, frame * CFrame.new(0, WALL_HEIGHT / 2, wallZ), WALL_SPEC)
	dressWall(model, frame, HALL_Z, wallZ)

	for _, along in bayCentres(HALL_Z) do
		addWindow(model, frame, along, wallZ)

		if not castsShafts then
			continue
		end

		-- The wall's local X runs along the hall; which way along it depends on
		-- the side, so the shaft's place in world Z has to be converted back.
		local z = along * -sign
		Stonework.lightShaft(
			model,
			(centre * CFrame.new(sign * (HALL_X / 2 - 2), WINDOW_Y, z)).Position,
			(centre * CFrame.new(sign * -12, 0.3, z + 14)).Position,
			10,
			20,
			DAYLIGHT
		)
	end
end

-- The south wall, behind the dais: solid, and the one wall a player sees
-- head-on as they arrive, so it carries the biggest carving in the hall.
local function addSouthWall(model: Model, centre: CFrame)
	local frame = centre * CFrame.Angles(0, SIDE_YAW.South, 0)
	local wallZ = HALL_Z / 2 + WALL_THICKNESS / 2

	Stonework.wall(model, "SouthWall", HALL_X + WALL_THICKNESS * 2, frame * CFrame.new(0, WALL_HEIGHT / 2, wallZ), WALL_SPEC)
	dressWall(model, frame, HALL_X, wallZ)

	-- A great relief above the dais: a ringed sigil with rays, the same figure
	-- inlaid in the floor beneath it.
	local face = wallZ - WALL_THICKNESS / 2 - 0.3
	decor(model, "ReliefDisc", Vector3.new(22, 22, 0.8), frame * CFrame.new(0, 34, face), Stonework.WALL_DARK, Enum.Material.Granite)
	decor(model, "ReliefRing", Vector3.new(18, 18, 1.0), frame * CFrame.new(0, 34, face - 0.3), Stonework.TRIM, Enum.Material.Slate)
	for _, angle in { 0, 45, 90, 135 } do
		decor(model, "ReliefRay", Vector3.new(26, 1.4, 0.5), frame * CFrame.new(0, 34, face - 0.5) * CFrame.Angles(0, 0, math.rad(angle)), Stonework.GOLD, Enum.Material.Metal)
	end
	decor(model, "ReliefBoss", Vector3.new(5, 5, 1.2), frame * CFrame.new(0, 34, face - 0.8) * CFrame.Angles(0, 0, math.rad(45)), Stonework.BRIGHT_GOLD, Enum.Material.Metal)
end

--[[ The gates ]]

-- One gate: an opening in the north wall, a deep alcove behind it, an arch
-- over it, and a veil of standing light filling it. Architecture only —
-- QueueService puts the ready-check station on the anchor in front of it.
local function addGatePortal(model: Model, frame: CFrame, x: number, wallZ: number, color: Color3)
	local face = wallZ - WALL_THICKNESS / 2
	local halfWidth = GATE_WIDTH / 2
	local alcoveMid = wallZ + GATE_DEPTH / 2 + WALL_THICKNESS / 2

	-- The alcove has its own floor. Without one, walking up to the veil is a
	-- fall out of the world.
	part(model, "GateAlcoveFloor", Vector3.new(GATE_WIDTH + 6, 2, GATE_DEPTH + WALL_THICKNESS + 2), frame * CFrame.new(x, -1, alcoveMid), Stonework.FLOOR, Enum.Material.Slate)

	for _, sign in { -1, 1 } do
		local jambX = x + sign * (halfWidth + 1.2)
		part(model, "GateJamb", Vector3.new(2.4, GATE_HEIGHT, GATE_DEPTH + WALL_THICKNESS), frame * CFrame.new(jambX, GATE_HEIGHT / 2, alcoveMid), Stonework.TRIM, Enum.Material.Slate)
		decor(model, "GateJambCap", Vector3.new(3.2, 0.8, GATE_DEPTH + WALL_THICKNESS + 0.6), frame * CFrame.new(jambX, GATE_HEIGHT, alcoveMid), Stonework.PILLAR, Enum.Material.Granite)
		decor(model, "GateJambFoot", Vector3.new(3.2, 0.9, GATE_DEPTH + WALL_THICKNESS + 0.6), frame * CFrame.new(jambX, 0.45, alcoveMid), Stonework.PILLAR, Enum.Material.Granite)
	end

	-- The wall above the opening, and the alcove's lid.
	local head = WALL_HEIGHT - GATE_HEIGHT
	decor(model, "GateHead", Vector3.new(GATE_WIDTH + 4.8, head, WALL_THICKNESS), frame * CFrame.new(x, GATE_HEIGHT + head / 2, wallZ), Stonework.WALL, Enum.Material.Cobblestone)
	decor(model, "GateAlcoveRoof", Vector3.new(GATE_WIDTH + 2, 1.2, GATE_DEPTH + WALL_THICKNESS), frame * CFrame.new(x, GATE_HEIGHT + 0.6, alcoveMid), Stonework.WALL_DARK, Enum.Material.Cobblestone)

	Stonework.arch(model, frame * CFrame.new(x, 0, 0), {
		springAt = GATE_HEIGHT,
		radius = halfWidth + 2.4,
		face = face - 0.4,
		stones = 9,
		depth = 3.0,
		thickness = 3.4,
	})

	-- The back of the alcove, and the veil hanging in front of it: the thing
	-- you are actually queueing to be pulled through.
	part(model, "GateBack", Vector3.new(GATE_WIDTH + 2, GATE_HEIGHT, 1.5), frame * CFrame.new(x, GATE_HEIGHT / 2, wallZ + GATE_DEPTH + WALL_THICKNESS / 2), Stonework.VOID, Enum.Material.Slate)

	local veil = decor(model, "GateVeil", Vector3.new(GATE_WIDTH - 1, GATE_HEIGHT - 2, 0.6), frame * CFrame.new(x, GATE_HEIGHT / 2 - 0.5, wallZ + GATE_DEPTH - 1.5), color, Enum.Material.Neon)
	veil.Transparency = 0.45
	veil.CastShadow = false

	local glow = Instance.new("PointLight")
	glow.Color = color
	glow.Brightness = 2.4
	glow.Range = 44
	glow.Shadows = false
	glow.Parent = veil

	-- Steps up to the threshold, and the threshold itself, lit in the gate's
	-- colour so you can tell the three apart from anywhere in the hall.
	for step = 1, 3 do
		decor(model, "GateStep", Vector3.new(GATE_WIDTH + 6 - step * 1.5, 0.4 * step, 2.2), frame * CFrame.new(x, 0.2 * step, wallZ - 4.4 + step * 1.1), Stonework.TRIM, Enum.Material.Slate)
	end
	decor(model, "GateThreshold", Vector3.new(GATE_WIDTH, 0.16, 3), frame * CFrame.new(x, 1.3, wallZ + 0.5), color, Enum.Material.Neon).CastShadow = false

	-- Sentinels flanking it, facing back down the hall, and the gate's mark
	-- burning above the arch.
	for _, sign in { -1, 1 } do
		Stonework.statue(model, frame * CFrame.new(x + sign * (halfWidth + 6), 0, wallZ - 5), 1.4)
	end
	decor(model, "GateSigil", Vector3.new(4.5, 4.5, 0.5), frame * CFrame.new(x, GATE_HEIGHT + halfWidth + 8, face - 0.5) * CFrame.Angles(0, 0, math.rad(45)), color, Enum.Material.Neon).CastShadow = false
end

-- The north wall: four stretches of wall with the three gates between them.
local function addNorthWall(model: Model, centre: CFrame, colors: { Color3 })
	local frame = centre * CFrame.Angles(0, SIDE_YAW.North, 0)
	local wallZ = HALL_Z / 2 + WALL_THICKNESS / 2
	local halfWidth = GATE_WIDTH / 2 + 2.4

	-- The edges of the four wall stretches, in order across the wall.
	local edges = { -HALL_X / 2 - WALL_THICKNESS }
	for _, x in GATE_X do
		table.insert(edges, x - halfWidth)
		table.insert(edges, x + halfWidth)
	end
	table.insert(edges, HALL_X / 2 + WALL_THICKNESS)

	for index = 1, #edges - 1, 2 do
		local from, to = edges[index], edges[index + 1]
		if to - from > 0.5 then
			Stonework.wall(model, "NorthWall", to - from, frame * CFrame.new((from + to) / 2, WALL_HEIGHT / 2, wallZ), WALL_SPEC)
		end
	end

	for index, x in GATE_X do
		addGatePortal(model, frame, x, wallZ, colors[index] or Stonework.GHOST_FIRE)
	end

	-- Torches on the stretches between the gates.
	for _, x in { -72, -24, 24, 72 } do
		local mount = frame * CFrame.new(x, 9, wallZ - WALL_THICKNESS / 2)
		local inward = frame * CFrame.new(x, 9, 0)
		Stonework.torch(model, CFrame.lookAt(mount.Position, inward.Position), Stonework.TORCH_FIRE, 1.0)
	end
end

--[[ The nave ]]

-- The pillars, the arcade of arches between them, the chandeliers hanging down
-- the middle and the braziers standing at their feet.
local function addNave(model: Model, centre: CFrame)
	for _, sign in { -1, 1 } do
		local x = sign * NAVE_HALF

		for index, z in PILLAR_Z do
			Stonework.pillar(model, centre * CFrame.new(x, 0, z), WALL_HEIGHT, PILLAR_THICKNESS, COLLIDE_HEIGHT)

			-- A torch bracketed to the nave face of every other pillar, so the
			-- walk down the middle is lit in pools rather than evenly. Even
			-- light down a hall this long is what makes it read as a corridor.
			if index % 2 == 0 then
				local mount = centre * CFrame.new(x - sign * PILLAR_THICKNESS / 2, 10, z)
				local inward = centre * CFrame.new(0, 10, z)
				Stonework.torch(model, CFrame.lookAt(mount.Position, inward.Position), Stonework.TORCH_FIRE, 1.2)
			end

			-- A brazier at the foot of every other pillar, on the aisle side.
			-- No shadows on these: a dozen shadow-casting lights down one hall
			-- is a frame-rate bill nobody can see being paid.
			if index % 2 == 1 then
				Stonework.brazier(model, centre * CFrame.new(x + sign * 7, 0, z), Stonework.TORCH_EMBER, 1.1, false)
			end

			-- The arcade: a ring springing from this pillar to the next, and a
			-- moulding over it. Rotated a quarter turn so the ring's width
			-- runs along the hall rather than across it.
			local nextZ = PILLAR_Z[index + 1]
			if not nextZ then
				continue
			end
			local midZ = (z + nextZ) / 2
			Stonework.arch(model, centre * CFrame.new(x, 0, midZ) * CFrame.Angles(0, math.rad(90), 0), {
				springAt = ARCADE_SPRING,
				radius = ARCADE_RADIUS,
				face = 0,
				stones = 7,
				depth = 2.6,
				thickness = 5.4,
			})
			decor(
				model,
				"ArcadeArchivolt",
				Vector3.new(PILLAR_THICKNESS + 1.4, 1.2, nextZ - z),
				centre * CFrame.new(x, ARCADE_SPRING + ARCADE_RADIUS + 2.4, midZ),
				Stonework.TRIM,
				Enum.Material.Slate
			)
		end
	end

	for _, z in { -60, -30, 0, 30, 60 } do
		Stonework.chandelier(model, centre * CFrame.new(0, WALL_HEIGHT - 1.5, z), 15, 7.5, Color3.fromRGB(255, 196, 128))
	end
end

--[[ Build ]]

-- `origin` is the floor centre of the hall in the world. `colors` is one
-- accent per gate, in the order the gates stand across the north wall.
function LobbyBuilder.build(origin: CFrame, colors: { Color3 }): Lobby
	local centre = CFrame.new(origin.Position)

	local model = Instance.new("Model")
	model.Name = "Lobby"

	addFloor(model, centre)
	addLongWall(model, centre, "West", true)
	addLongWall(model, centre, "East", false)
	addSouthWall(model, centre)
	addNorthWall(model, centre, colors)
	addNave(model, centre)

	Stonework.ceiling(model, centre, {
		height = WALL_HEIGHT,
		sizeX = HALL_X,
		sizeZ = HALL_Z,
		ribSpacing = 26,
		coffered = true,
	})

	-- Air, so the hall is not a photograph of a hall. Kept to the lower half,
	-- where the light shafts and the firelight actually catch it.
	Stonework.dust(model, centre * CFrame.new(0, 22, 0), Vector3.new(HALL_X - 20, 40, HALL_Z - 20), 24)

	local gateAnchors = {}
	for _, x in GATE_X do
		local stand = (centre * CFrame.new(x, 0, HALL_Z / 2 - GATE_STAND_BACK)).Position
		table.insert(gateAnchors, CFrame.lookAt(stand, (centre * CFrame.new(x, 0, HALL_Z / 2)).Position))
	end

	local altarAnchors = {}
	for _, z in ALTAR_Z do
		local stand = (centre * CFrame.new(ALTAR_X, 0, z)).Position
		table.insert(altarAnchors, CFrame.lookAt(stand, (centre * CFrame.new(0, 0, z)).Position))
	end

	local position = centre.Position
	return {
		model = model,
		centre = centre,
		bounds = {
			minX = position.X - HALL_X / 2,
			maxX = position.X + HALL_X / 2,
			minZ = position.Z - HALL_Z / 2,
			maxZ = position.Z + HALL_Z / 2,
		},
		-- Standing on the dais, facing the length of the hall to the gates.
		spawnCFrame = CFrame.lookAt(
			(centre * CFrame.new(0, DAIS_HEIGHT + 3.5, DAIS_Z)).Position,
			(centre * CFrame.new(0, DAIS_HEIGHT + 3.5, DAIS_Z + 30)).Position
		),
		gateAnchors = gateAnchors,
		altarAnchors = altarAnchors,
		forgeAnchor = CFrame.lookAt((centre * CFrame.new(FORGE_X, 0, 0)).Position, position),
		duelAnchor = CFrame.lookAt(
			(centre * CFrame.new(DUEL_AT)).Position,
			(centre * CFrame.new(0, 0, DUEL_AT.Z)).Position
		),
	}
end

return LobbyBuilder
