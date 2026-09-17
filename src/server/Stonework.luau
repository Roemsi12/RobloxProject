--!strict
-- The masonry kit: the pieces every built place in this game is made of.
--
-- Two things build rooms now — the dungeon's RoomTemplates and the hub's
-- LobbyBuilder — and they have to look like the same world, cut by the same
-- masons. Everything both of them need lives here exactly once: the two part
-- constructors, walls, pillars, arches, torches, braziers, chandeliers,
-- statues, banners, chains, cobwebs, clutter, flagstones and ceilings.
--
-- What is *not* here is composition. How a wall's buttresses are spaced, where
-- a throne goes, which bay carries a statue — that is what makes a crypt read
-- differently from a great hall, and it belongs to whichever module is doing
-- the building.
--
-- Colours come from Palette, resolved once here, so the iron on a door band is
-- the iron on a chandelier's ring is the iron on a skeleton's helm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage.Shared.Palette)

local Stonework = {}

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

Stonework.rgb = rgb

Stonework.FLOOR = rgb(Palette.FLOOR)
Stonework.WALL = rgb(Palette.WALL)
Stonework.WALL_DARK = rgb(Palette.shade(Palette.WALL, 0.82))
Stonework.TRIM = rgb(Palette.TRIM)
Stonework.PILLAR = rgb(Palette.PILLAR)
Stonework.RUBBLE = rgb(Palette.RUBBLE)
Stonework.MORTAR = rgb(Palette.MORTAR)
Stonework.IRON = rgb(Palette.IRON)
Stonework.RUST = rgb(Palette.RUST)
Stonework.STEEL = rgb(Palette.STEEL)
Stonework.DARK_STEEL = rgb(Palette.DARK_STEEL)
Stonework.WOOD = rgb(Palette.ROT_WOOD)
Stonework.OAK = rgb(Palette.OAK)
Stonework.LINEN = rgb(Palette.LINEN)
Stonework.BONE = rgb(Palette.OLD_BONE)
Stonework.LEATHER = rgb(Palette.LEATHER)
Stonework.CRIMSON = rgb(Palette.CRIMSON)
Stonework.GOLD = rgb(Palette.GOLD)
Stonework.BRIGHT_GOLD = rgb(Palette.BRIGHT_GOLD)
Stonework.TORCH_FIRE = rgb(Palette.TORCH_FIRE)
Stonework.TORCH_EMBER = rgb(Palette.TORCH_EMBER)
Stonework.GHOST_FIRE = rgb(Palette.GHOST_FIRE)
Stonework.VOID = rgb(Palette.VOID)
-- Statues are cut from a paler stone than the walls, so they read as carved
-- rather than as lumps of the wall that happen to stick out.
Stonework.STATUE = rgb(Palette.mix(Palette.PILLAR, Palette.BONE, 0.22))

--[[ The two constructors ]]

function Stonework.part(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): Part
	local created = Instance.new("Part")
	created.Name = name
	created.Anchored = true
	created.CanCollide = true
	created.Size = size
	created.CFrame = cframe
	created.Color = color
	created.Material = material or Enum.Material.SmoothPlastic
	created.TopSurface = Enum.SurfaceType.Smooth
	created.BottomSurface = Enum.SurfaceType.Smooth
	created.Parent = parent
	return created
end

-- Decoration a player walks through rather than snags on, and that the camera
-- sees straight through. Everything above head height is built this way: it is
-- what lets a hall be sixty studs tall without the camera jamming into it
-- every time someone backs against a wall.
function Stonework.decor(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): Part
	local created = Stonework.part(parent, name, size, cframe, color, material)
	created.CanCollide = false
	created.CanQuery = false
	created.CanTouch = false
	return created
end

local part = Stonework.part
local decor = Stonework.decor

--[[ Walls ]]

export type WallSpec = {
	-- Overall height the wall reads as.
	height: number,
	-- How much of it is actually solid. Above this it is decoration, so the
	-- camera passes through.
	collideHeight: number,
	thickness: number,
	-- Where the string course runs, as a height. Skipped when nil.
	courseAt: number?,
}

-- A wall, solid to `collideHeight` and decorative above, with a darker cap
-- along its top, a dentil frieze under it, an optional string course at
-- shoulder height and a skirting along its base. `cframe` is the wall's centre
-- at half its height; its local X runs along the wall.
function Stonework.wall(parent: Instance, name: string, length: number, cframe: CFrame, spec: WallSpec)
	local base = cframe * CFrame.new(0, -spec.height / 2, 0)
	local upper = math.max(spec.height - spec.collideHeight, 0)

	part(parent, name, Vector3.new(length, spec.collideHeight, spec.thickness), base * CFrame.new(0, spec.collideHeight / 2, 0), Stonework.WALL, Enum.Material.Cobblestone)
	if upper > 0 then
		decor(parent, `{name}Upper`, Vector3.new(length, upper, spec.thickness), base * CFrame.new(0, spec.collideHeight + upper / 2, 0), Stonework.WALL, Enum.Material.Cobblestone)
	end

	decor(parent, `{name}Cap`, Vector3.new(length + 0.5, 0.8, spec.thickness + 0.6), base * CFrame.new(0, spec.height - 0.4, 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, `{name}Frieze`, Vector3.new(length, 0.5, spec.thickness + 0.4), base * CFrame.new(0, spec.height - 1.2, 0), Stonework.PILLAR, Enum.Material.Granite)
	decor(parent, `{name}Skirt`, Vector3.new(length + 0.35, 1.0, spec.thickness + 0.35), base * CFrame.new(0, 0.5, 0), Stonework.TRIM, Enum.Material.Slate)

	if spec.courseAt then
		decor(parent, `{name}Course`, Vector3.new(length, 0.4, spec.thickness + 0.35), base * CFrame.new(0, spec.courseAt, 0), Stonework.TRIM, Enum.Material.Slate)
	end
end

-- A buttress running the full height of a wall, with a moulded foot and a
-- carved capital where the bay arches spring from.
function Stonework.buttress(parent: Instance, at: CFrame, height: number, capitalAt: number, width: number)
	decor(parent, "Buttress", Vector3.new(width, height - 1.6, width * 0.35), at * CFrame.new(0, (height - 1.6) / 2, 0), Stonework.PILLAR, Enum.Material.Granite)
	decor(parent, "ButtressFoot", Vector3.new(width * 1.3, 1.0, width * 0.55), at * CFrame.new(0, 0.5, 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, "ButtressCapital", Vector3.new(width * 1.3, 0.7, width * 0.55), at * CFrame.new(0, capitalAt, 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, "ButtressCrown", Vector3.new(width * 1.15, 0.6, width * 0.45), at * CFrame.new(0, height - 1.8, 0), Stonework.TRIM, Enum.Material.Slate)
end

-- A recessed bay between two buttresses: a sunken panel with a moulded head.
-- This is most of what makes a long wall read as built rather than extruded.
function Stonework.bay(parent: Instance, at: CFrame, width: number, top: number)
	decor(parent, "BayPanel", Vector3.new(width, top - 2.4, 0.3), at * CFrame.new(0, (top - 2.4) / 2 + 1.2, 0), Stonework.WALL_DARK, Enum.Material.Cobblestone)
	decor(parent, "BayHead", Vector3.new(width + 0.5, 0.5, 0.55), at * CFrame.new(0, top - 1.0, 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, "BaySill", Vector3.new(width + 0.5, 0.4, 0.55), at * CFrame.new(0, 1.2, 0), Stonework.TRIM, Enum.Material.Slate)
end

--[[ Arches ]]

export type ArchSpec = {
	-- Where the ring springs from, and how far it reaches.
	springAt: number,
	radius: number,
	-- Along the frame's local Z: which face the ring is laid on.
	face: number,
	-- How many wedge stones make the ring. Odd numbers get a true keystone.
	stones: number,
	-- How deep each wedge stone reads, radially.
	depth: number,
	-- How wide each wedge stone is, around the ring.
	thickness: number,
}

-- The ring of wedge stones over an opening, with a keystone at the top. Each
-- stone is rotated to sit radially, so the ring reads as cut stone rather than
-- a row of bricks. `frame` looks out through the opening.
function Stonework.arch(parent: Instance, frame: CFrame, spec: ArchSpec)
	for index = 1, spec.stones do
		local angle = math.pi * (index - 0.5) / spec.stones
		local isKeystone = index == math.ceil(spec.stones / 2)
		local reach = if isKeystone then spec.radius + 0.15 else spec.radius
		local stone = frame
			* CFrame.new(math.cos(angle) * reach, spec.springAt + math.sin(angle) * reach, spec.face)
			* CFrame.Angles(0, 0, angle)

		decor(
			parent,
			if isKeystone then "Keystone" else "Voussoir",
			Vector3.new(if isKeystone then spec.thickness * 1.3 else spec.thickness, spec.depth, 0.8),
			stone,
			if isKeystone then Stonework.TRIM else Stonework.PILLAR,
			Enum.Material.Granite
		)
	end
end

--[[ Pillars ]]

-- A pillar with a moulded plinth, a fluted shaft and a carved capital. Solid
-- to `collideHeight` and decoration above, so a pillar can run all the way to
-- a ceiling without becoming a column the camera fights.
function Stonework.pillar(parent: Instance, base: CFrame, height: number, thickness: number, collideHeight: number)
	local solid = math.min(height, collideHeight)
	part(parent, "Pillar", Vector3.new(thickness, solid, thickness), base * CFrame.new(0, solid / 2, 0), Stonework.PILLAR, Enum.Material.Granite)
	if height > collideHeight then
		decor(parent, "PillarUpper", Vector3.new(thickness, height - collideHeight, thickness), base * CFrame.new(0, collideHeight + (height - collideHeight) / 2, 0), Stonework.PILLAR, Enum.Material.Granite)
	end

	local plinth = thickness * 1.42
	decor(parent, "PillarPlinth", Vector3.new(plinth, 1.2, plinth), base * CFrame.new(0, 0.6, 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, "PillarBase", Vector3.new(thickness * 1.2, 0.9, thickness * 1.2), base * CFrame.new(0, 1.65, 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, "PillarCapital", Vector3.new(plinth, 1.1, plinth), base * CFrame.new(0, height - 0.55, 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, "PillarNecking", Vector3.new(thickness * 1.15, 0.5, thickness * 1.15), base * CFrame.new(0, height - 1.5, 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, "PillarBand", Vector3.new(thickness * 1.1, 0.6, thickness * 1.1), base * CFrame.new(0, height * 0.46, 0), Stonework.TRIM, Enum.Material.Slate)

	-- Fluting: one shallow groove per face. On a shaft this thick a plain box
	-- reads as a crate stood on end.
	for _, yaw in { 0, 90, 180, 270 } do
		decor(
			parent,
			"PillarFlute",
			Vector3.new(thickness * 0.28, height - 3.6, 0.24),
			base * CFrame.Angles(0, math.rad(yaw), 0) * CFrame.new(0, height / 2 + 0.5, thickness / 2),
			Stonework.WALL_DARK,
			Enum.Material.Granite
		)
	end
end

--[[ Light ]]

-- An iron sconce holding a burning brand. `cframe` sits on the wall's inner
-- face, looking into the room.
--
-- Torchlight does not cast shadows. There are a lot of torches now that rooms
-- are this size, and Future lighting charges for every shadow-casting light;
-- the few lights that carry a place — chandeliers, braziers, the forge — pay
-- for shadows instead.
function Stonework.torch(parent: Instance, cframe: CFrame, color: Color3, scale: number?)
	local s = scale or 1
	decor(parent, "TorchBracket", Vector3.new(0.3, 0.3, 1.2) * s, cframe * CFrame.new(0, -0.2 * s, -0.6 * s), Stonework.IRON, Enum.Material.Metal)
	decor(parent, "TorchArm", Vector3.new(0.24, 1.0, 0.24) * s, cframe * CFrame.new(0, 0.15 * s, -1.1 * s) * CFrame.Angles(math.rad(18), 0, 0), Stonework.IRON, Enum.Material.Metal)
	decor(parent, "TorchBowl", Vector3.new(0.9, 0.55, 0.9) * s, cframe * CFrame.new(0, 0.55 * s, -1.25 * s), Stonework.IRON, Enum.Material.Metal)

	local head = decor(parent, "Torch", Vector3.new(0.45, 1.0, 0.45) * s, cframe * CFrame.new(0, 0.95 * s, -1.25 * s), rgb(Palette.shade(Palette.ROT_WOOD, 0.8)), Enum.Material.Wood)

	local fire = Instance.new("Fire")
	fire.Size = 3 * s
	fire.Heat = 8
	fire.Color = color
	fire.SecondaryColor = color:Lerp(Color3.new(0, 0, 0), 0.5)
	fire.Parent = head

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 2.6
	light.Range = 30 * s
	light.Shadows = false
	light.Parent = head
end

-- A standing bowl of fire on a stem. Returns the burning part, so whatever
-- owns it can turn it up — the gates do, while a ready check is running.
--
-- `shadows` defaults on: a brazier is one of the few lights that earns them.
-- A row of them lining a hall does not, so the hub turns them off there.
function Stonework.brazier(parent: Instance, base: CFrame, color: Color3, scale: number?, shadows: boolean?): Part
	local s = scale or 1

	part(parent, "BrazierStem", Vector3.new(1.4 * s, 3.0 * s, 1.4 * s), base * CFrame.new(0, 1.5 * s, 0), Stonework.IRON, Enum.Material.Metal)
	decor(parent, "BrazierFoot", Vector3.new(3.0 * s, 0.6 * s, 3.0 * s), base * CFrame.new(0, 0.3 * s, 0), Stonework.IRON, Enum.Material.Metal)
	decor(parent, "BrazierBowl", Vector3.new(3.4 * s, 1.2 * s, 3.4 * s), base * CFrame.new(0, 3.5 * s, 0), Stonework.IRON, Enum.Material.Metal)
	decor(parent, "BrazierRim", Vector3.new(3.8 * s, 0.35 * s, 3.8 * s), base * CFrame.new(0, 4.0 * s, 0), Stonework.RUST, Enum.Material.Metal)

	local coals = decor(parent, "BrazierCoals", Vector3.new(2.6 * s, 0.4 * s, 2.6 * s), base * CFrame.new(0, 4.1 * s, 0), color, Enum.Material.Neon)

	local fire = Instance.new("Fire")
	fire.Size = 6 * s
	fire.Heat = 10
	fire.Color = color
	fire.SecondaryColor = color:Lerp(Color3.new(0, 0, 0), 0.6)
	fire.Parent = coals

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 2.8
	light.Range = 34 * s
	light.Shadows = shadows ~= false
	light.Parent = coals

	-- Embers drifting up off the coals: the one thing in a still room that
	-- moves, which is what stops a lit brazier reading as a painted one.
	local embers = Instance.new("ParticleEmitter")
	embers.Name = "Embers"
	embers.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	embers.Color = ColorSequence.new(color)
	embers.LightEmission = 1
	embers.Rate = 9
	embers.Lifetime = NumberRange.new(1.6, 3.2)
	embers.Speed = NumberRange.new(2.5 * s, 5 * s)
	embers.SpreadAngle = Vector2.new(18, 18)
	embers.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5 * s),
		NumberSequenceKeypoint.new(1, 0),
	})
	embers.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	embers.Acceleration = Vector3.new(0, 4, 0)
	embers.Parent = coals

	return coals
end

-- An iron ring of candles hung on chains out of the dark overhead. This is the
-- light a great hall is read by: high, wide and warm, against all that cold
-- stone.
function Stonework.chandelier(parent: Instance, top: CFrame, drop: number, radius: number, color: Color3, shadows: boolean?)
	-- Three chains converging on the crown, rather than links: at this height
	-- nobody counts links, and three rings of them is sixty parts nobody sees.
	local lean = math.atan2(radius * 0.28, drop)
	for _, yaw in { 0, 120, 240 } do
		decor(
			parent,
			"ChandelierChain",
			Vector3.new(0.22, drop, 0.22),
			top * CFrame.Angles(0, math.rad(yaw), 0) * CFrame.new(0, -drop / 2, radius * 0.14) * CFrame.Angles(lean, 0, 0),
			Stonework.IRON,
			Enum.Material.Metal
		)
	end

	local hub = top * CFrame.new(0, -drop, 0)
	decor(parent, "ChandelierCrown", Vector3.new(1.6, 0.9, 1.6), hub * CFrame.new(0, 0.8, 0), Stonework.IRON, Enum.Material.Metal)
	decor(parent, "ChandelierBoss", Vector3.new(1.1, 1.4, 1.1), hub * CFrame.new(0, -0.7, 0), Stonework.RUST, Enum.Material.Metal)

	-- The ring, as eight straight segments laid round an octagon, with spokes
	-- back to the hub and a candle standing on each joint.
	local segments = 8
	local side = 2 * radius * math.tan(math.pi / segments)
	for index = 1, segments do
		local angle = (index - 0.5) * 2 * math.pi / segments
		decor(parent, "ChandelierRing", Vector3.new(side + 0.3, 0.45, 0.45), hub * CFrame.Angles(0, -angle, 0) * CFrame.new(0, 0, radius), Stonework.IRON, Enum.Material.Metal)
		decor(parent, "ChandelierSpoke", Vector3.new(0.22, 0.22, radius), hub * CFrame.Angles(0, -angle, 0) * CFrame.new(0, 0.55, radius / 2), Stonework.IRON, Enum.Material.Metal)
	end

	for index = 1, segments do
		local at = hub * CFrame.Angles(0, -index * 2 * math.pi / segments, 0) * CFrame.new(0, 0, radius)
		decor(parent, "Candle", Vector3.new(0.4, 1.5, 0.4), at * CFrame.new(0, 1.0, 0), Stonework.LINEN)
		local flame = decor(parent, "CandleFlame", Vector3.new(0.34, 0.8, 0.34), at * CFrame.new(0, 2.1, 0), color, Enum.Material.Neon)
		flame.CastShadow = false
	end

	local core = decor(parent, "ChandelierLight", Vector3.new(0.6, 0.6, 0.6), hub, color, Enum.Material.Neon)
	core.Transparency = 1
	core.CastShadow = false

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 2.6
	light.Range = radius * 2.5 + 22
	light.Shadows = shadows ~= false
	light.Parent = core
end

-- A shaft of daylight falling from a high window onto the floor. The one
-- effect that makes an interior read as an interior: everything else in the
-- room is lit by fire, and this is not.
--
-- A Beam rather than a stack of translucent slabs — it takes a transparency
-- falloff along its length for free, and `FaceCamera` keeps it reading as a
-- volume from every angle instead of a flat plane you can catch edge-on.
function Stonework.lightShaft(parent: Instance, from: Vector3, to: Vector3, topWidth: number, bottomWidth: number, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name = "LightShaft"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(from)
	anchor.Parent = parent

	local top = Instance.new("Attachment")
	top.Parent = anchor

	local bottom = Instance.new("Attachment")
	bottom.Position = anchor.CFrame:PointToObjectSpace(to)
	bottom.Parent = anchor

	local beam = Instance.new("Beam")
	beam.Attachment0 = top
	beam.Attachment1 = bottom
	beam.Width0 = topWidth
	beam.Width1 = bottomWidth
	beam.FaceCamera = true
	beam.LightInfluence = 0
	beam.LightEmission = 1
	beam.Segments = 6
	beam.Color = ColorSequence.new(color)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.82),
		NumberSequenceKeypoint.new(0.55, 0.88),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Parent = anchor
end

-- Motes turning slowly in the air of a room this size. Nothing else in the
-- frame moves when a player stands still; this is what keeps a hall from
-- reading as a photograph of one.
function Stonework.dust(parent: Instance, centre: CFrame, extent: Vector3, rate: number)
	local anchor = Instance.new("Part")
	anchor.Name = "Dust"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = extent
	anchor.CFrame = centre
	anchor.Parent = parent

	local motes = Instance.new("ParticleEmitter")
	motes.Name = "Motes"
	motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	motes.Color = ColorSequence.new(Color3.fromRGB(255, 235, 200))
	motes.LightEmission = 0.55
	motes.LightInfluence = 0.4
	motes.Rate = rate
	motes.Lifetime = NumberRange.new(9, 16)
	motes.Speed = NumberRange.new(0.2, 0.8)
	motes.Drag = 1.5
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.Rotation = NumberRange.new(0, 360)
	motes.RotSpeed = NumberRange.new(-8, 8)
	motes.Acceleration = Vector3.new(0.3, -0.25, 0.1)
	-- Emitted through the whole volume rather than off a face, so the air of
	-- the room is full of them rather than a fountain in the middle of it.
	motes.Shape = Enum.ParticleEmitterShape.Box
	motes.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	motes.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.18),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	motes.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.55),
		NumberSequenceKeypoint.new(0.8, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	motes.Parent = anchor
end

--[[ Carving ]]

-- A stone sentinel on a plinth: a hooded figure in a long robe, both hands
-- resting on a sword driven point-down in front of it.
--
-- What makes a stack of boxes read as a person is the taper: a wide hem, a
-- waist narrower than both, shoulders wider than everything, and a head big
-- enough to find. Equal-width boxes read as a pillar however many you stack.
--
-- Only the plinth collides. The figure stands on top of it and against a wall,
-- so the plinth is the only part of it anyone can walk into anyway.
function Stonework.statue(parent: Instance, base: CFrame, scale: number?)
	local s = scale or 1
	local function v(x: number, y: number, z: number): Vector3
		return Vector3.new(x * s, y * s, z * s)
	end
	local function at(x: number, y: number, z: number): CFrame
		return CFrame.new(x * s, y * s, z * s)
	end

	part(parent, "StatuePlinth", v(3.2, 2.0, 3.0), base * at(0, 1.0, 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, "StatuePlinthCap", v(3.8, 0.45, 3.6), base * at(0, 2.2, 0), Stonework.PILLAR, Enum.Material.Granite)
	decor(parent, "StatuePlinthFoot", v(3.8, 0.45, 3.6), base * at(0, 0.22, 0), Stonework.PILLAR, Enum.Material.Granite)

	local feet = base * at(0, 2.4, 0)
	decor(parent, "StatueHem", v(2.7, 1.4, 2.1), feet * at(0, 0.7, 0), Stonework.STATUE, Enum.Material.Marble)
	decor(parent, "StatueRobe", v(1.9, 3.0, 1.5), feet * at(0, 2.9, 0), Stonework.STATUE, Enum.Material.Marble)
	decor(parent, "StatueChest", v(2.3, 2.0, 1.5), feet * at(0, 5.4, 0), Stonework.STATUE, Enum.Material.Marble)
	decor(parent, "StatueMantle", v(3.4, 0.8, 2.1), feet * at(0, 6.6, 0), Stonework.PILLAR, Enum.Material.Marble)

	-- Arms held clear of the body, folded down onto the pommel.
	decor(parent, "StatueArmRight", v(0.6, 2.7, 0.6), feet * at(1.35, 5.2, -0.5) * CFrame.Angles(math.rad(-12), 0, math.rad(7)), Stonework.STATUE, Enum.Material.Marble)
	decor(parent, "StatueArmLeft", v(0.6, 2.7, 0.6), feet * at(-1.35, 5.2, -0.5) * CFrame.Angles(math.rad(-12), 0, math.rad(-7)), Stonework.STATUE, Enum.Material.Marble)

	-- Head on a visible neck, under a great helm with a blank visor.
	decor(parent, "StatueNeck", v(0.7, 0.6, 0.7), feet * at(0, 7.1, 0), Stonework.STATUE, Enum.Material.Marble)
	decor(parent, "StatueHead", v(1.3, 1.4, 1.3), feet * at(0, 7.9, 0), Stonework.STATUE, Enum.Material.Marble)
	decor(parent, "StatueHelm", v(1.55, 1.1, 1.55), feet * at(0, 8.2, 0), Stonework.PILLAR, Enum.Material.Marble)
	decor(parent, "StatueVisor", v(1.1, 0.25, 0.12), feet * at(0, 7.9, -0.72), Stonework.VOID)
	decor(parent, "StatueCrest", v(0.3, 1.1, 1.7), feet * at(0, 9.2, 0), Stonework.PILLAR, Enum.Material.Marble)

	-- The sword: point down in front of it, hands resting over the pommel.
	decor(parent, "StatueSwordPommel", v(0.55, 0.55, 0.55), feet * at(0, 4.6, -1.05), Stonework.PILLAR, Enum.Material.Marble)
	decor(parent, "StatueSwordGrip", v(0.4, 1.3, 0.4), feet * at(0, 3.85, -1.05), Stonework.STATUE, Enum.Material.Marble)
	decor(parent, "StatueSwordGuard", v(2.2, 0.35, 0.45), feet * at(0, 3.1, -1.05), Stonework.PILLAR, Enum.Material.Marble)
	decor(parent, "StatueSwordBlade", v(0.5, 2.6, 0.24), feet * at(0, 1.7, -1.05), Stonework.STATUE, Enum.Material.Marble)
	decor(parent, "StatueSwordTip", v(0.3, 0.5, 0.2), feet * at(0, 0.2, -1.05), Stonework.STATUE, Enum.Material.Marble)
end

-- A banner hanging from a rod, with a device sewn on it. `frame`'s local X
-- runs along the wall and +Z points out through it.
function Stonework.banner(parent: Instance, frame: CFrame, x: number, top: number, face: number, color: Color3, scale: number?)
	local s = scale or 1
	decor(parent, "BannerRod", Vector3.new(4.2 * s, 0.26, 0.26), frame * CFrame.new(x, top, face), Stonework.IRON, Enum.Material.Metal)
	decor(parent, "Banner", Vector3.new(3.4 * s, 9.0 * s, 0.14), frame * CFrame.new(x, top - 4.6 * s, face), color, Enum.Material.Fabric)
	decor(parent, "BannerTail", Vector3.new(1.7 * s, 1.6 * s, 0.14), frame * CFrame.new(x, top - 9.8 * s, face), color, Enum.Material.Fabric)
	decor(parent, "BannerDevice", Vector3.new(1.5 * s, 1.5 * s, 0.08), frame * CFrame.new(x, top - 4.4 * s, face - 0.1) * CFrame.Angles(0, 0, math.rad(45)), Stonework.GOLD, Enum.Material.Metal)
end

-- A chain hanging out of the dark overhead.
function Stonework.chain(parent: Instance, top: CFrame, length: number)
	local links = math.max(math.floor(length / 0.9), 1)
	for index = 1, links do
		decor(
			parent,
			"ChainLink",
			Vector3.new(0.2, 0.8, 0.2),
			top * CFrame.new(0, -index * 0.85, 0) * CFrame.Angles(0, if index % 2 == 0 then 0 else math.rad(90), 0),
			Stonework.IRON,
			Enum.Material.Metal
		)
	end
	decor(parent, "ChainHook", Vector3.new(0.5, 0.5, 0.5), top * CFrame.new(0, -links * 0.85 - 0.4, 0), Stonework.RUST, Enum.Material.Metal)
end

-- Cobweb in the angle of two walls, at a height where it is actually seen.
function Stonework.cobweb(parent: Instance, corner: CFrame, size: number)
	local web = decor(parent, "Cobweb", Vector3.new(size, size, 0.08), corner * CFrame.Angles(0, math.rad(45), 0), Color3.fromRGB(196, 196, 186), Enum.Material.Fabric)
	web.Transparency = 0.62
	web.CastShadow = false
end

--[[ Clutter ]]

function Stonework.barrel(parent: Instance, base: CFrame)
	decor(parent, "Barrel", Vector3.new(1.7, 2.4, 1.7), base * CFrame.new(0, 1.2, 0), Stonework.WOOD, Enum.Material.WoodPlanks)
	for _, y in { 0.6, 1.8 } do
		decor(parent, "BarrelHoop", Vector3.new(1.85, 0.25, 1.85), base * CFrame.new(0, y, 0), Stonework.RUST, Enum.Material.Metal)
	end
end

function Stonework.crate(parent: Instance, base: CFrame)
	local side = 1.6 + math.random() * 0.7
	decor(parent, "Crate", Vector3.new(side, side, side), base * CFrame.new(0, side / 2, 0), Stonework.WOOD, Enum.Material.WoodPlanks)
	decor(parent, "CrateBand", Vector3.new(side + 0.08, 0.2, side + 0.08), base * CFrame.new(0, side / 2, 0), rgb(Palette.shade(Palette.ROT_WOOD, 0.7)), Enum.Material.Wood)
end

-- What is left of somebody who came this way before.
function Stonework.bones(parent: Instance, base: CFrame)
	decor(parent, "Skull", Vector3.new(0.7, 0.7, 0.8), base * CFrame.new(0, 0.35, 0) * CFrame.Angles(0, math.random() * math.pi, math.rad(20)), Stonework.BONE)
	for _ = 1, 3 do
		decor(
			parent,
			"Bone",
			Vector3.new(0.22, 0.22, 1.5),
			base * CFrame.new((math.random() - 0.5) * 1.8, 0.14, (math.random() - 0.5) * 1.8) * CFrame.Angles(0, math.random() * math.pi, math.rad(90)),
			Stonework.BONE
		)
	end
end

-- One loose stone. `base` sits on the floor.
function Stonework.rubbleStone(parent: Instance, base: CFrame)
	local stone = 0.6 + math.random() * 1.2
	local rock = decor(
		parent,
		"Rubble",
		Vector3.new(stone, stone * 0.6, stone * (0.8 + math.random() * 0.4)),
		base * CFrame.new(0, stone * 0.25, 0) * CFrame.Angles(0, math.random() * math.pi, math.rad(math.random(-15, 15))),
		Stonework.RUBBLE,
		Enum.Material.Slate
	)
	rock.CastShadow = false
end

-- Arms mounted on a wall panel: crossed blades over a shield, crossed axes, or
-- spears behind a helm. `at` sits on the wall's face, looking into the room.
function Stonework.trophy(parent: Instance, at: CFrame, kind: number)
	decor(parent, "TrophyBoard", Vector3.new(5.4, 5.4, 0.3), at, rgb(Palette.shade(Palette.OAK, 0.55)), Enum.Material.Wood)
	for _, y in { 2.7, -2.7 } do
		decor(parent, "TrophyBoardTrim", Vector3.new(5.9, 0.35, 0.45), at * CFrame.new(0, y, 0), Stonework.RUST, Enum.Material.Metal)
	end

	if kind == 1 then
		decor(parent, "TrophyShield", Vector3.new(3.0, 3.6, 0.35), at * CFrame.new(0, -0.2, -0.35), Stonework.DARK_STEEL, Enum.Material.Metal)
		decor(parent, "TrophyShieldBoss", Vector3.new(0.9, 0.9, 0.3), at * CFrame.new(0, 0.1, -0.6), Stonework.GOLD, Enum.Material.Metal)
		for _, sign in { -1, 1 } do
			local blade = at * CFrame.new(0, 0.3, -0.75) * CFrame.Angles(0, 0, sign * math.rad(35))
			decor(parent, "TrophyBlade", Vector3.new(0.35, 5.0, 0.16), blade, Stonework.STEEL, Enum.Material.Metal)
			decor(parent, "TrophyGuard", Vector3.new(1.9, 0.28, 0.3), blade * CFrame.new(0, -1.9, 0), Stonework.IRON, Enum.Material.Metal)
			decor(parent, "TrophyGrip", Vector3.new(0.28, 1.1, 0.28), blade * CFrame.new(0, -2.6, 0), Stonework.LEATHER, Enum.Material.Fabric)
			decor(parent, "TrophyPommel", Vector3.new(0.45, 0.45, 0.45), blade * CFrame.new(0, -3.25, 0), Stonework.GOLD, Enum.Material.Metal)
		end
	elseif kind == 2 then
		for _, sign in { -1, 1 } do
			local haft = at * CFrame.new(0, 0, -0.5) * CFrame.Angles(0, 0, sign * math.rad(30))
			decor(parent, "TrophyHaft", Vector3.new(0.3, 5.2, 0.3), haft, Stonework.OAK, Enum.Material.Wood)
			decor(parent, "TrophyAxeHead", Vector3.new(1.7, 1.5, 0.22), haft * CFrame.new(sign * 0.8, 2.0, -0.1), Stonework.DARK_STEEL, Enum.Material.Metal)
			decor(parent, "TrophyAxeBeard", Vector3.new(0.9, 0.9, 0.22), haft * CFrame.new(sign * 1.1, 1.3, -0.1), Stonework.DARK_STEEL, Enum.Material.Metal)
		end
		decor(parent, "TrophyRoundel", Vector3.new(1.6, 1.6, 0.3), at * CFrame.new(0, 0, -0.8), Stonework.RUST, Enum.Material.Metal)
	else
		for _, sign in { -1, 1 } do
			local shaft = at * CFrame.new(0, 0, -0.4) * CFrame.Angles(0, 0, sign * math.rad(26))
			decor(parent, "TrophyShaft", Vector3.new(0.26, 6.2, 0.26), shaft, Stonework.OAK, Enum.Material.Wood)
			decor(parent, "TrophySpearhead", Vector3.new(0.5, 1.5, 0.2), shaft * CFrame.new(0, 3.5, 0), Stonework.STEEL, Enum.Material.Metal)
		end
		decor(parent, "TrophyHelm", Vector3.new(1.9, 1.7, 1.9), at * CFrame.new(0, -0.3, -1.3), Stonework.DARK_STEEL, Enum.Material.Metal)
		decor(parent, "TrophyHelmVisor", Vector3.new(1.4, 0.3, 0.14), at * CFrame.new(0, -0.1, -2.3), Stonework.VOID)
		decor(parent, "TrophyHelmCrest", Vector3.new(0.3, 0.9, 2.0), at * CFrame.new(0, 0.9, -1.3), Stonework.CRIMSON, Enum.Material.Fabric)
	end
end

--[[ Floor and ceiling ]]

-- Flagstone seams: thin dark strips ruling the floor into slabs, and a few
-- cracked ones. Far cheaper than laying an actual grid of tiles, and from
-- standing height it reads the same.
function Stonework.flagstones(parent: Instance, centre: CFrame, sizeX: number, sizeZ: number)
	local slab = 9
	local alongX = math.max(math.floor(sizeX / slab) - 1, 1)
	local alongZ = math.max(math.floor(sizeZ / slab) - 1, 1)

	for index = 1, alongZ do
		local at = -sizeZ / 2 + (sizeZ / (alongZ + 1)) * index
		decor(parent, "FloorSeam", Vector3.new(sizeX, 0.06, 0.28), centre * CFrame.new(0, 0.02, at), Stonework.MORTAR, Enum.Material.Slate)
	end
	for index = 1, alongX do
		local at = -sizeX / 2 + (sizeX / (alongX + 1)) * index
		decor(parent, "FloorSeam", Vector3.new(0.28, 0.06, sizeZ), centre * CFrame.new(at, 0.02, 0), Stonework.MORTAR, Enum.Material.Slate)
	end

	for _ = 1, math.random(2, 4) do
		local x = (math.random() - 0.5) * math.max(sizeX - 12, 1)
		local z = (math.random() - 0.5) * math.max(sizeZ - 12, 1)
		local cracked = decor(
			parent,
			"CrackedSlab",
			Vector3.new(slab * 0.8, 0.08, slab * 0.8),
			centre * CFrame.new(x, 0.03, z) * CFrame.Angles(0, math.random() * math.pi, 0),
			rgb(Palette.shade(Palette.FLOOR, 0.82)),
			Enum.Material.Slate
		)
		cracked.CastShadow = false
	end
end

-- A ringed figure set into the floor, with spokes and a gilded boss at its
-- centre. Rooms are fought in and halls walked through from the middle
-- outward, so this is the piece of floor most often on screen.
function Stonework.floorInlay(parent: Instance, centre: CFrame, radius: number)
	decor(parent, "InlayOuter", Vector3.new(radius * 2, 0.07, radius * 2), centre * CFrame.new(0, 0.03, 0) * CFrame.Angles(0, math.rad(45), 0), Stonework.TRIM, Enum.Material.Slate)
	decor(parent, "InlayInner", Vector3.new(radius * 1.5, 0.08, radius * 1.5), centre * CFrame.new(0, 0.04, 0), rgb(Palette.shade(Palette.FLOOR, 1.15)), Enum.Material.Slate)
	for _, angle in { 0, 45, 90, 135 } do
		decor(parent, "InlaySpoke", Vector3.new(radius * 1.9, 0.09, 0.5), centre * CFrame.new(0, 0.05, 0) * CFrame.Angles(0, math.rad(angle), 0), Stonework.GOLD, Enum.Material.Metal)
	end
	decor(parent, "InlayBoss", Vector3.new(radius * 0.18 + 1.4, 0.1, radius * 0.18 + 1.4), centre * CFrame.new(0, 0.06, 0) * CFrame.Angles(0, math.rad(45), 0), Stonework.GOLD, Enum.Material.Metal)
end

export type CeilingSpec = {
	-- Underside of the ceiling.
	height: number,
	sizeX: number,
	sizeZ: number,
	-- Roughly how far apart the ribs run.
	ribSpacing: number,
	-- Whether to rib the other axis too and gild the crossings. Off in the
	-- dungeon, where a ceiling only has to close the room off.
	coffered: boolean,
}

-- A ceiling.
--
-- It closes the room overhead, which is what turns a walled yard into a room —
-- and, because it shuts out the sky, it is also what makes every torch in the
-- place matter. It is built as decoration: `CanCollide` off keeps it out of
-- the camera's occlusion test, which only considers solid parts, and
-- `CanQuery` off keeps it out of every other raycast in the game. It does cast
-- a shadow, which is the entire point — an interior lit by fire.
function Stonework.ceiling(parent: Instance, centre: CFrame, spec: CeilingSpec)
	local slab = decor(
		parent,
		"Ceiling",
		Vector3.new(spec.sizeX + 2, 1.6, spec.sizeZ + 2),
		centre * CFrame.new(0, spec.height + 0.8, 0),
		Stonework.WALL_DARK,
		Enum.Material.Cobblestone
	)
	slab.CastShadow = true

	local acrossZ = math.max(math.floor(spec.sizeZ / spec.ribSpacing), 1)
	local acrossX = math.max(math.floor(spec.sizeX / spec.ribSpacing), 1)

	-- Ribs overhead rather than a flat lid. From the floor, the grid is the
	-- only thing that gives a ceiling this high any scale at all.
	for index = 1, acrossZ do
		local z = -spec.sizeZ / 2 + (spec.sizeZ / (acrossZ + 1)) * index
		decor(parent, "CeilingRib", Vector3.new(spec.sizeX + 2, 1.1, 1.6), centre * CFrame.new(0, spec.height - 0.55, z), Stonework.TRIM, Enum.Material.Slate)
		decor(parent, "CeilingRibTrim", Vector3.new(spec.sizeX + 2, 0.35, 2.1), centre * CFrame.new(0, spec.height - 1.2, z), Stonework.PILLAR, Enum.Material.Granite)
	end

	if not spec.coffered then
		return
	end

	for index = 1, acrossX do
		local x = -spec.sizeX / 2 + (spec.sizeX / (acrossX + 1)) * index
		decor(parent, "CeilingRib", Vector3.new(1.6, 1.1, spec.sizeZ + 2), centre * CFrame.new(x, spec.height - 0.55, 0), Stonework.TRIM, Enum.Material.Slate)
		decor(parent, "CeilingRibTrim", Vector3.new(2.1, 0.35, spec.sizeZ + 2), centre * CFrame.new(x, spec.height - 1.2, 0), Stonework.PILLAR, Enum.Material.Granite)
	end

	-- A gilded boss where every second pair of ribs crosses.
	local stepX = spec.sizeX / (acrossX + 1)
	local stepZ = spec.sizeZ / (acrossZ + 1)
	for ix = 1, acrossX do
		for iz = 1, acrossZ do
			if (ix + iz) % 2 ~= 0 then
				continue
			end
			local x = -spec.sizeX / 2 + stepX * ix
			local z = -spec.sizeZ / 2 + stepZ * iz
			decor(parent, "CeilingBoss", Vector3.new(1.8, 0.5, 1.8), centre * CFrame.new(x, spec.height - 1.4, z) * CFrame.Angles(0, math.rad(45), 0), Stonework.GOLD, Enum.Material.Metal)
		end
	end
end

return Stonework
