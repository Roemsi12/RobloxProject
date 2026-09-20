--!strict
-- What a player's character looks like, and every choice they can make about
-- it. Pure data — no Roblox API — so the menu, the server that applies a look
-- and the tests all read the same list.
--
-- Why this exists at all: a player arrives wearing whatever their Roblox
-- avatar happens to be. One of them is a penguin. In a dungeon built out of
-- one grim palette, a catalogue avatar reads as someone who wandered in from
-- another game, and the fighting stances and tells that the whole combat loop
-- depends on are much harder to read on a silhouette the animations were never
-- authored for.
--
-- So every player gets the same body: the default blocky R15 build, stripped
-- of clothing, accessories and bundles, at fixed proportions. What they choose
-- is what goes *on* it. That keeps one silhouette for combat to read while
-- leaving the part players actually care about wide open.
--
-- The skeleton stays R15. It is the shared vocabulary every animation in the
-- game is authored in (RigDefs), and the 15 joints are what make a player's
-- body as readable as an enemy's.
--
-- A choice is a piece of data, never a branch. Adding a hairstyle is a row in
-- HAIR; nothing in the service or the menu changes. The pieces a choice is
-- built from use the same fields as RigDefs decorations — offset from the
-- centre of the part they hang on, then rotation, in the rig's own space —
-- because they are welded onto a body the same way.

local Palette = require(script.Parent.Palette)

local AppearanceDefs = {}

export type RGB = { number }
export type Vec3 = { number }

-- A welded piece of a look: hair, a jaw, a hood, a pauldron.
export type Piece = {
	name: string,
	-- An R15 part name.
	attachTo: string,
	size: Vec3,
	offset: Vec3,
	rotation: Vec3?,
	-- Which of the look's colours this piece takes. A piece with its own
	-- `color` ignores this.
	tint: ("skin" | "hair" | "garb" | "trim")?,
	color: RGB?,
	material: string?,
	shape: string?,
	transparency: number?,
}

export type Option = {
	id: string,
	label: string,
	pieces: { Piece }?,
}

-- One row of the editor: what it is called, what can be picked, and where the
-- answer is stored on the saved look.
export type Category = {
	id: string,
	label: string,
	-- "option" picks from a list; "color" picks from a swatch row.
	kind: "option" | "color",
	-- Loosely typed on purpose: an option row is usually an Option, but Build
	-- is a choice made of scales rather than pieces. Everything that reads
	-- these needs `id` and `label` and nothing more.
	options: { any }?,
	colors: { { id: string, label: string, rgb: RGB } }?,
}

--[[ The body everyone shares ]]

-- Applied as a HumanoidDescription, which is what actually removes a bundle,
-- a shirt or a hat. Zeroing the body-type and proportion scales is what makes
-- the body blocky: those two are what bend a default R15 toward Rthro's
-- proportions, and at zero the parts are the plain boxes the animations were
-- authored against.
AppearanceDefs.BODY_TYPE_SCALE = 0
AppearanceDefs.PROPORTION_SCALE = 0
AppearanceDefs.HEAD_SCALE = 1

--[[ Choices ]]

local function swatch(id: string, label: string, rgb: RGB)
	return { id = id, label = label, rgb = rgb }
end

-- Deliberately not a spectrum of realistic tones alone. Half the point of a
-- character creator in a game like this is the player who wants to be
-- something that died a while ago.
AppearanceDefs.SKIN_TONES = {
	swatch("pale", "Pale", { 226, 198, 176 }),
	swatch("fair", "Fair", { 205, 170, 142 }),
	swatch("tan", "Tan", { 178, 134, 98 }),
	swatch("olive", "Olive", { 150, 118, 84 }),
	swatch("bronze", "Bronze", { 132, 92, 58 }),
	swatch("umber", "Umber", { 96, 64, 44 }),
	swatch("dark", "Dark", { 66, 44, 32 }),
	swatch("ashen", "Ashen", { 168, 160, 156 }),
	swatch("drowned", "Drowned", { 138, 152, 148 }),
	swatch("corpse", "Corpse", Palette.OLD_BONE),
	swatch("hollow", "Hollow", { 108, 104, 112 }),
	swatch("verdant", "Verdant", Palette.ZOMBIE_SKIN),
}

AppearanceDefs.HAIR_COLORS = {
	swatch("black", "Black", { 28, 26, 28 }),
	swatch("soot", "Soot", { 54, 50, 52 }),
	swatch("brown", "Brown", { 78, 52, 34 }),
	swatch("chestnut", "Chestnut", { 108, 66, 38 }),
	swatch("auburn", "Auburn", { 132, 62, 34 }),
	swatch("ash", "Ash", { 150, 142, 132 }),
	swatch("white", "White", Palette.BONE),
	swatch("straw", "Straw", Palette.LINEN),
	swatch("ember", "Ember", Palette.TORCH_EMBER),
	swatch("arcane", "Arcane", Palette.ARCANE),
	swatch("shadow", "Shadow", Palette.SHADOW_MAGIC),
	swatch("ghost", "Ghostfire", Palette.GHOST_FIRE),
}

AppearanceDefs.GARB_COLORS = {
	swatch("black", "Black", Palette.BLACK_CLOTH),
	swatch("ash", "Ash", Palette.TATTERED),
	swatch("linen", "Linen", Palette.LINEN),
	swatch("leather", "Leather", Palette.LEATHER),
	swatch("crimson", "Crimson", Palette.CRIMSON),
	swatch("deep", "Deep Blue", Palette.DEEP_BLUE),
	swatch("moss", "Moss", Palette.MOSS),
	swatch("rust", "Rust", Palette.RUST),
	swatch("iron", "Iron", Palette.IRON),
	swatch("bone", "Bone", Palette.OLD_BONE),
}

AppearanceDefs.TRIM_COLORS = {
	swatch("gold", "Gold", Palette.GOLD),
	swatch("bright", "Bright Gold", Palette.BRIGHT_GOLD),
	swatch("steel", "Steel", Palette.STEEL),
	swatch("dark", "Dark Steel", Palette.DARK_STEEL),
	swatch("copper", "Copper", Palette.COPPER),
	swatch("iron", "Iron", Palette.IRON),
	swatch("crimson", "Crimson", Palette.CRIMSON),
	swatch("arcane", "Arcane", Palette.ARCANE),
	swatch("ghost", "Ghostfire", Palette.GHOST_FIRE),
	swatch("bone", "Bone", Palette.BONE),
}

--[[ Hair ]]

-- Hair is built from slabs sitting on and around the head. The head is a 1.2
-- cube whose centre is the part's origin, so a piece at y = 0.62 caps it and
-- one at z = 0.62 sits across the brow.
local function cap(name: string, size: Vec3, offset: Vec3, rotation: Vec3?): Piece
	return { name = name, attachTo = "Head", size = size, offset = offset, rotation = rotation, tint = "hair" }
end

AppearanceDefs.HAIR = {
	{ id = "shaved", label = "Shaved", pieces = {} },
	{
		id = "cropped",
		label = "Cropped",
		pieces = {
			cap("HairTop", { 1.26, 0.26, 1.26 }, { 0, 0.54, 0 }),
			cap("HairBack", { 1.24, 0.5, 0.2 }, { 0, 0.3, 0.56 }),
		},
	},
	{
		id = "swept",
		label = "Swept",
		pieces = {
			cap("HairTop", { 1.28, 0.3, 1.28 }, { 0, 0.55, 0 }),
			cap("HairSweep", { 1.3, 0.34, 0.5 }, { 0, 0.6, -0.42 }, { -16, 0, 0 }),
			cap("HairBack", { 1.24, 0.6, 0.22 }, { 0, 0.22, 0.56 }),
		},
	},
	{
		id = "long",
		label = "Long",
		pieces = {
			cap("HairTop", { 1.3, 0.3, 1.3 }, { 0, 0.55, 0 }),
			cap("HairBack", { 1.26, 1.5, 0.3 }, { 0, -0.24, 0.58 }),
			cap("HairSideRight", { 0.26, 1.2, 0.9 }, { 0.6, -0.1, 0.16 }),
			cap("HairSideLeft", { 0.26, 1.2, 0.9 }, { -0.6, -0.1, 0.16 }),
		},
	},
	{
		id = "topknot",
		label = "Topknot",
		pieces = {
			cap("HairTop", { 1.24, 0.22, 1.24 }, { 0, 0.52, 0 }),
			cap("HairKnot", { 0.42, 0.42, 0.42 }, { 0, 0.78, 0.12 }),
			cap("HairTail", { 0.26, 0.24, 0.9 }, { 0, 0.72, 0.6 }, { 28, 0, 0 }),
		},
	},
	{
		id = "braids",
		label = "Braids",
		pieces = {
			cap("HairTop", { 1.28, 0.28, 1.28 }, { 0, 0.54, 0 }),
			cap("HairBack", { 1.22, 0.7, 0.24 }, { 0, 0.18, 0.57 }),
			cap("BraidRight", { 0.24, 1.4, 0.24 }, { 0.58, -0.28, 0.46 }, { 10, 0, -6 }),
			cap("BraidLeft", { 0.24, 1.4, 0.24 }, { -0.58, -0.28, 0.46 }, { 10, 0, 6 }),
		},
	},
	{
		id = "mohawk",
		label = "Mohawk",
		pieces = {
			cap("HairRidge", { 0.3, 0.52, 1.2 }, { 0, 0.66, 0 }),
			cap("HairStubble", { 1.24, 0.16, 1.24 }, { 0, 0.5, 0 }),
		},
	},
	{
		id = "wild",
		label = "Wild",
		pieces = {
			cap("HairTop", { 1.34, 0.42, 1.34 }, { 0, 0.58, 0 }),
			cap("HairTuftRight", { 0.4, 0.4, 0.5 }, { 0.5, 0.74, -0.2 }, { 0, 0, -24 }),
			cap("HairTuftLeft", { 0.36, 0.44, 0.44 }, { -0.52, 0.72, 0.16 }, { 0, 0, 22 }),
			cap("HairBack", { 1.28, 0.9, 0.28 }, { 0, 0.1, 0.58 }),
		},
	},
	{
		id = "hooded",
		label = "Hooded",
		pieces = {
			{ name = "HoodCrown", attachTo = "Head", size = { 1.42, 0.5, 1.44 }, offset = { 0, 0.5, 0.04 }, tint = "garb", material = "Fabric" },
			{ name = "HoodBack", attachTo = "Head", size = { 1.36, 1.3, 0.34 }, offset = { 0, -0.1, 0.64 }, tint = "garb", material = "Fabric" },
			{ name = "HoodSideRight", attachTo = "Head", size = { 0.3, 1.1, 1.2 }, offset = { 0.62, 0.02, 0.1 }, tint = "garb", material = "Fabric" },
			{ name = "HoodSideLeft", attachTo = "Head", size = { 0.3, 1.1, 1.2 }, offset = { -0.62, 0.02, 0.1 }, tint = "garb", material = "Fabric" },
			{ name = "HoodBrow", attachTo = "Head", size = { 1.44, 0.34, 0.5 }, offset = { 0, 0.44, -0.44 }, rotation = { -12, 0, 0 }, tint = "garb", material = "Fabric" },
		},
	},
} :: { Option }

--[[ Faces ]]

-- The face is built, not drawn: a decal would be one more asset to upload and
-- would not read at all under the dungeon's lighting. Eyes are Neon so they
-- carry in the dark, which is where this game is played.
local function eyes(name: string, size: Vec3, y: number, spread: number, color: RGB, material: string?): { Piece }
	return {
		{ name = `{name}Right`, attachTo = "Head", size = size, offset = { spread, y, -0.61 }, color = color, material = material or "Neon" },
		{ name = `{name}Left`, attachTo = "Head", size = size, offset = { -spread, y, -0.61 }, color = color, material = material or "Neon" },
	}
end

-- A matched pair of eyebrows at height `y`, each tilted `tilt` degrees
-- (positive angles them inward, into a scowl). Tinted with the hair
-- colour, so brows always match the head they sit under.
local function brows(y: number, tilt: number): { Piece }
	return {
		{ name = "BrowRight", attachTo = "Head", size = { 0.34, 0.09, 0.06 }, offset = { 0.26, y, -0.6 }, rotation = { 0, 0, -tilt }, tint = "hair" },
		{ name = "BrowLeft", attachTo = "Head", size = { 0.34, 0.09, 0.06 }, offset = { -0.26, y, -0.6 }, rotation = { 0, 0, tilt }, tint = "hair" },
	}
end

-- Several piece lists flattened into one, for a face or a garb built out
-- of more than one helper.
local function join(...: { Piece }): { Piece }
	local out: { Piece } = {}
	for _, list in { ... } do
		for _, piece in list do
			table.insert(out, piece)
		end
	end
	return out
end

local MOUTH_SET: { Piece } = {
	{ name = "Mouth", attachTo = "Head", size = { 0.36, 0.07, 0.05 }, offset = { 0, -0.3, -0.61 }, color = { 62, 44, 44 } },
}

AppearanceDefs.FACES = {
	{
		id = "steady",
		label = "Steady",
		pieces = join(eyes("Eye", { 0.2, 0.11, 0.05 }, 0.1, 0.26, { 240, 240, 245 }, "SmoothPlastic"), brows(0.26, 6), MOUTH_SET),
	},
	{
		id = "grim",
		label = "Grim",
		pieces = join(eyes("Eye", { 0.22, 0.09, 0.05 }, 0.1, 0.26, { 220, 222, 230 }, "SmoothPlastic"), brows(0.24, 18), MOUTH_SET),
	},
	{
		id = "weary",
		label = "Weary",
		pieces = join(
			eyes("Eye", { 0.2, 0.08, 0.05 }, 0.08, 0.26, { 200, 200, 208 }, "SmoothPlastic"),
			brows(0.26, -10),
			MOUTH_SET,
			{ { name = "HollowRight", attachTo = "Head", size = { 0.24, 0.12, 0.04 }, offset = { 0.26, -0.03, -0.6 }, color = { 92, 78, 74 }, transparency = 0.4 } },
			{ { name = "HollowLeft", attachTo = "Head", size = { 0.24, 0.12, 0.04 }, offset = { -0.26, -0.03, -0.6 }, color = { 92, 78, 74 }, transparency = 0.4 } }
		),
	},
	{
		id = "ember",
		label = "Ember-Eyed",
		pieces = join(eyes("Eye", { 0.22, 0.12, 0.05 }, 0.1, 0.26, Palette.TORCH_EMBER), brows(0.27, 14), MOUTH_SET),
	},
	{
		id = "ghostfire",
		label = "Ghostfire",
		pieces = join(eyes("Eye", { 0.22, 0.12, 0.05 }, 0.1, 0.26, Palette.GHOST_FIRE), brows(0.27, 10), MOUTH_SET),
	},
	{
		id = "arcane",
		label = "Arcane",
		pieces = join(eyes("Eye", { 0.2, 0.14, 0.05 }, 0.1, 0.26, Palette.ARCANE), brows(0.28, 0), MOUTH_SET),
	},
	{
		id = "hollowed",
		label = "Hollowed",
		pieces = join(
			eyes("Socket", { 0.24, 0.18, 0.05 }, 0.09, 0.26, Palette.VOID, "SmoothPlastic"),
			eyes("Glint", { 0.08, 0.08, 0.04 }, 0.09, 0.26, Palette.EYE_GLOW),
			{ { name = "Mouth", attachTo = "Head", size = { 0.44, 0.1, 0.05 }, offset = { 0, -0.3, -0.61 }, color = Palette.VOID } }
		),
	},
	{
		id = "masked",
		label = "Masked",
		pieces = join(
			{ { name = "Mask", attachTo = "Head", size = { 1.16, 0.8, 0.12 }, offset = { 0, 0.02, -0.6 }, tint = "trim", material = "Metal" } },
			eyes("Slit", { 0.26, 0.07, 0.06 }, 0.12, 0.27, Palette.VOID, "SmoothPlastic"),
			{ { name = "MaskRidge", attachTo = "Head", size = { 0.1, 0.72, 0.16 }, offset = { 0, 0, -0.64 }, tint = "trim", material = "Metal" } }
		),
	},
} :: { Option }

--[[ Markings ]]

AppearanceDefs.MARKINGS = {
	{ id = "none", label = "None", pieces = {} },
	{
		id = "warpaint",
		label = "War Paint",
		pieces = {
			{ name = "PaintBand", attachTo = "Head", size = { 1.14, 0.18, 0.04 }, offset = { 0, 0.08, -0.62 }, tint = "trim" },
			{ name = "PaintStreakRight", attachTo = "Head", size = { 0.1, 0.44, 0.04 }, offset = { 0.3, -0.16, -0.62 }, tint = "trim" },
			{ name = "PaintStreakLeft", attachTo = "Head", size = { 0.1, 0.44, 0.04 }, offset = { -0.3, -0.16, -0.62 }, tint = "trim" },
		},
	},
	{
		id = "scar",
		label = "Scar",
		pieces = {
			{ name = "Scar", attachTo = "Head", size = { 0.07, 0.62, 0.04 }, offset = { 0.3, 0.06, -0.62 }, rotation = { 0, 0, 12 }, color = { 158, 108, 98 } },
			{ name = "ScarNotch", attachTo = "Head", size = { 0.16, 0.07, 0.04 }, offset = { 0.34, 0.24, -0.62 }, color = { 158, 108, 98 } },
		},
	},
	{
		id = "brand",
		label = "Brand",
		pieces = {
			{ name = "BrandRing", attachTo = "Head", size = { 0.42, 0.42, 0.04 }, offset = { -0.3, 0.14, -0.62 }, color = Palette.RUST, shape = "Cylinder" },
			{ name = "BrandBar", attachTo = "Head", size = { 0.3, 0.08, 0.05 }, offset = { -0.3, 0.14, -0.63 }, color = Palette.RUST },
		},
	},
	{
		id = "ash",
		label = "Ash",
		pieces = {
			{ name = "AshSmear", attachTo = "Head", size = { 1.1, 0.5, 0.04 }, offset = { 0, -0.18, -0.62 }, color = { 62, 58, 62 }, transparency = 0.25 },
		},
	},
	{
		id = "tattoo",
		label = "Tattoo",
		pieces = {
			{ name = "TattooStem", attachTo = "Head", size = { 0.07, 0.5, 0.04 }, offset = { -0.34, -0.06, -0.62 }, tint = "trim" },
			{ name = "TattooArmUpper", attachTo = "Head", size = { 0.24, 0.07, 0.04 }, offset = { -0.26, 0.1, -0.62 }, rotation = { 0, 0, -30 }, tint = "trim" },
			{ name = "TattooArmLower", attachTo = "Head", size = { 0.24, 0.07, 0.04 }, offset = { -0.26, -0.16, -0.62 }, rotation = { 0, 0, 30 }, tint = "trim" },
		},
	},
	{
		id = "stitched",
		label = "Stitched",
		pieces = {
			{ name = "StitchLine", attachTo = "Head", size = { 0.06, 0.66, 0.04 }, offset = { 0.22, -0.02, -0.62 }, color = { 54, 44, 42 } },
			{ name = "StitchA", attachTo = "Head", size = { 0.22, 0.05, 0.05 }, offset = { 0.22, 0.2, -0.62 }, color = { 54, 44, 42 } },
			{ name = "StitchB", attachTo = "Head", size = { 0.22, 0.05, 0.05 }, offset = { 0.22, 0.02, -0.62 }, color = { 54, 44, 42 } },
			{ name = "StitchC", attachTo = "Head", size = { 0.22, 0.05, 0.05 }, offset = { 0.22, -0.16, -0.62 }, color = { 54, 44, 42 } },
		},
	},
} :: { Option }

--[[ Garb ]]

-- Worn over the body rather than replacing it, so a garb piece never hides a
-- joint an animation moves. Nothing hangs below the knee: a tabard long enough
-- to reach the ankle clips through its own legs on every stride, and a roll
-- turns the whole body through it.
AppearanceDefs.GARB = {
	{ id = "none", label = "Ragged", pieces = {} },
	{
		id = "tunic",
		label = "Tunic",
		pieces = {
			{ name = "Tunic", attachTo = "UpperTorso", size = { 2.12, 1.6, 1.12 }, offset = { 0, -0.04, 0 }, tint = "garb", material = "Fabric" },
			{ name = "TunicSkirt", attachTo = "LowerTorso", size = { 2.06, 0.9, 1.1 }, offset = { 0, -0.34, 0 }, tint = "garb", material = "Fabric" },
			{ name = "Belt", attachTo = "LowerTorso", size = { 2.14, 0.26, 1.14 }, offset = { 0, 0.06, 0 }, tint = "trim", material = "Fabric" },
			{ name = "BeltBuckle", attachTo = "LowerTorso", size = { 0.28, 0.28, 0.12 }, offset = { 0, 0.06, -0.6 }, tint = "trim", material = "Metal" },
		},
	},
	{
		id = "leathers",
		label = "Leathers",
		pieces = {
			{ name = "Jerkin", attachTo = "UpperTorso", size = { 2.14, 1.56, 1.14 }, offset = { 0, -0.02, 0 }, tint = "garb", material = "Fabric" },
			{ name = "StrapCross", attachTo = "UpperTorso", size = { 2.2, 0.24, 1.18 }, offset = { 0, 0.18, 0 }, rotation = { 0, 0, 22 }, tint = "trim", material = "Fabric" },
			{ name = "Belt", attachTo = "LowerTorso", size = { 2.16, 0.3, 1.16 }, offset = { 0, 0.02, 0 }, tint = "trim", material = "Fabric" },
			{ name = "BracerRight", attachTo = "RightLowerArm", size = { 0.92, 0.66, 0.92 }, offset = { 0, -0.1, 0 }, tint = "garb", material = "Fabric" },
			{ name = "BracerLeft", attachTo = "LeftLowerArm", size = { 0.92, 0.66, 0.92 }, offset = { 0, -0.1, 0 }, tint = "garb", material = "Fabric" },
		},
	},
	{
		id = "plate",
		label = "Plate",
		pieces = {
			{ name = "Cuirass", attachTo = "UpperTorso", size = { 2.18, 1.62, 1.18 }, offset = { 0, -0.02, 0 }, tint = "garb", material = "Metal" },
			{ name = "CuirassRidge", attachTo = "UpperTorso", size = { 0.16, 1.5, 1.22 }, offset = { 0, 0, -0.02 }, tint = "trim", material = "Metal" },
			{ name = "Fauld", attachTo = "LowerTorso", size = { 2.12, 0.72, 1.16 }, offset = { 0, -0.24, 0 }, tint = "garb", material = "Metal" },
			{ name = "PauldronRight", attachTo = "RightUpperArm", size = { 1.04, 0.62, 1.04 }, offset = { 0.08, 0.42, 0 }, rotation = { 0, 0, -10 }, tint = "trim", material = "Metal" },
			{ name = "PauldronLeft", attachTo = "LeftUpperArm", size = { 1.04, 0.62, 1.04 }, offset = { -0.08, 0.42, 0 }, rotation = { 0, 0, 10 }, tint = "trim", material = "Metal" },
			{ name = "GauntletRight", attachTo = "RightLowerArm", size = { 0.94, 0.7, 0.94 }, offset = { 0, -0.14, 0 }, tint = "garb", material = "Metal" },
			{ name = "GauntletLeft", attachTo = "LeftLowerArm", size = { 0.94, 0.7, 0.94 }, offset = { 0, -0.14, 0 }, tint = "garb", material = "Metal" },
		},
	},
	{
		id = "robes",
		label = "Robes",
		pieces = {
			{ name = "Robe", attachTo = "UpperTorso", size = { 2.16, 1.62, 1.16 }, offset = { 0, -0.02, 0 }, tint = "garb", material = "Fabric" },
			{ name = "RobeSkirt", attachTo = "LowerTorso", size = { 2.1, 1.0, 1.12 }, offset = { 0, -0.4, 0 }, tint = "garb", material = "Fabric" },
			{ name = "Stole", attachTo = "UpperTorso", size = { 0.5, 1.64, 1.24 }, offset = { 0, 0, 0 }, tint = "trim", material = "Fabric" },
			{ name = "SleeveRight", attachTo = "RightLowerArm", size = { 1.0, 1.0, 1.0 }, offset = { 0, -0.16, 0 }, tint = "garb", material = "Fabric" },
			{ name = "SleeveLeft", attachTo = "LeftLowerArm", size = { 1.0, 1.0, 1.0 }, offset = { 0, -0.16, 0 }, tint = "garb", material = "Fabric" },
		},
	},
	{
		id = "tabard",
		label = "Tabard",
		pieces = {
			{ name = "Gambeson", attachTo = "UpperTorso", size = { 2.12, 1.58, 1.12 }, offset = { 0, -0.02, 0 }, tint = "garb", material = "Fabric" },
			{ name = "TabardFront", attachTo = "UpperTorso", size = { 1.1, 1.7, 0.1 }, offset = { 0, -0.1, -0.61 }, tint = "trim", material = "Fabric" },
			{ name = "TabardSkirt", attachTo = "LowerTorso", size = { 1.08, 0.86, 0.1 }, offset = { 0, -0.34, -0.58 }, tint = "trim", material = "Fabric" },
			{ name = "TabardBack", attachTo = "UpperTorso", size = { 1.1, 1.7, 0.1 }, offset = { 0, -0.1, 0.61 }, tint = "trim", material = "Fabric" },
			{ name = "Belt", attachTo = "LowerTorso", size = { 2.16, 0.28, 1.16 }, offset = { 0, 0.04, 0 }, tint = "garb", material = "Fabric" },
		},
	},
	{
		id = "wrappings",
		label = "Wrappings",
		pieces = {
			{ name = "Wrap", attachTo = "UpperTorso", size = { 2.1, 1.2, 1.1 }, offset = { 0, -0.2, 0 }, tint = "garb", material = "Fabric" },
			{ name = "WrapStrap", attachTo = "UpperTorso", size = { 2.16, 0.22, 1.16 }, offset = { 0, 0.4, 0 }, rotation = { 0, 0, -18 }, tint = "trim", material = "Fabric" },
			{ name = "WrapRight", attachTo = "RightLowerArm", size = { 0.9, 0.9, 0.9 }, offset = { 0, -0.1, 0 }, tint = "garb", material = "Fabric" },
			{ name = "WrapLeft", attachTo = "LeftLowerArm", size = { 0.9, 0.9, 0.9 }, offset = { 0, -0.1, 0 }, tint = "garb", material = "Fabric" },
			{ name = "Sash", attachTo = "LowerTorso", size = { 2.12, 0.4, 1.12 }, offset = { 0, -0.1, 0 }, rotation = { 0, 0, 8 }, tint = "trim", material = "Fabric" },
		},
	},
	{
		id = "cloak",
		label = "Cloak",
		pieces = {
			{ name = "Jerkin", attachTo = "UpperTorso", size = { 2.12, 1.58, 1.12 }, offset = { 0, -0.02, 0 }, tint = "garb", material = "Fabric" },
			{ name = "Cloak", attachTo = "UpperTorso", size = { 2.1, 2.1, 0.24 }, offset = { 0, -0.34, 0.66 }, tint = "trim", material = "Fabric" },
			{ name = "CloakCollar", attachTo = "UpperTorso", size = { 2.0, 0.44, 0.9 }, offset = { 0, 0.66, 0.2 }, tint = "trim", material = "Fabric" },
			{ name = "ClaspRight", attachTo = "UpperTorso", size = { 0.24, 0.24, 0.16 }, offset = { 0.52, 0.6, -0.56 }, tint = "trim", material = "Metal", shape = "Cylinder" },
			{ name = "ClaspLeft", attachTo = "UpperTorso", size = { 0.24, 0.24, 0.16 }, offset = { -0.52, 0.6, -0.56 }, tint = "trim", material = "Metal", shape = "Cylinder" },
		},
	},
} :: { Option }

--[[ Build ]]

-- Scales the whole body. Kept narrow on purpose: the parry read depends on
-- silhouettes staying comparable between players, and a body twice as wide as
-- another wearing the same guard pose is a different silhouette.
export type BuildDef = {
	id: string,
	label: string,
	width: number,
	depth: number,
	height: number,
}

AppearanceDefs.BUILDS = {
	{ id = "lean", label = "Lean", width = 0.92, depth = 0.92, height = 1.02 },
	{ id = "standard", label = "Standard", width = 1, depth = 1, height = 1 },
	{ id = "broad", label = "Broad", width = 1.1, depth = 1.08, height = 1 },
	{ id = "heavy", label = "Heavy", width = 1.16, depth = 1.14, height = 0.97 },
} :: { BuildDef }

--[[ The saved look ]]

export type Look = {
	build: string,
	skin: string,
	hair: string,
	hairColor: string,
	face: string,
	marking: string,
	garb: string,
	garbColor: string,
	trimColor: string,
}

-- The look a brand-new character starts with, and the fallback every
-- unrecognised field falls back to. Always a fresh table.
function AppearanceDefs.default(): Look
	return {
		build = "standard",
		skin = "fair",
		hair = "cropped",
		hairColor = "brown",
		face = "steady",
		marking = "none",
		garb = "tunic",
		garbColor = "leather",
		trimColor = "iron",
	}
end

--[[ Lookups ]]

local function findById(list: { any }, id: unknown): any?
	if typeof(id) ~= "string" then
		return nil
	end
	for _, entry in list do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

AppearanceDefs.findById = findById

-- The first entry of a list, which every list is written to make a sane
-- fallback: no marking, a plain face, a standard build.
local function firstOf(list: { any }): any
	return list[1]
end

-- The choice with this id, or the list's first entry when the id is
-- unknown. Every list is ordered so its first entry is a safe fallback:
-- no marking, a plain face, a standard build.
function AppearanceDefs.option(list: { any }, id: unknown): any
	return findById(list, id) or firstOf(list)
end

-- The build with this id, falling back to "standard" (BUILDS[2]) rather
-- than to the first entry, because the first is "lean" and an unknown
-- build should come back at exactly 1.0 on every axis.
function AppearanceDefs.buildOf(id: unknown): BuildDef
	return findById(AppearanceDefs.BUILDS, id) or AppearanceDefs.BUILDS[2]
end

-- The RGB of a swatch by id, falling back to the list's first colour.
function AppearanceDefs.colorOf(list: { any }, id: unknown): RGB
	local entry = findById(list, id) or firstOf(list)
	return entry.rgb
end

-- Every choice the editor offers, in the order it shows them. The menu is
-- built from this and nothing else, so a new row here is a new row there.
AppearanceDefs.CATEGORIES = {
	{ id = "build", label = "Build", kind = "option", options = AppearanceDefs.BUILDS },
	{ id = "skin", label = "Skin", kind = "color", colors = AppearanceDefs.SKIN_TONES },
	{ id = "face", label = "Face", kind = "option", options = AppearanceDefs.FACES },
	{ id = "hair", label = "Hair", kind = "option", options = AppearanceDefs.HAIR },
	{ id = "hairColor", label = "Hair Colour", kind = "color", colors = AppearanceDefs.HAIR_COLORS },
	{ id = "marking", label = "Markings", kind = "option", options = AppearanceDefs.MARKINGS },
	{ id = "garb", label = "Garb", kind = "option", options = AppearanceDefs.GARB },
	{ id = "garbColor", label = "Garb Colour", kind = "color", colors = AppearanceDefs.GARB_COLORS },
	{ id = "trimColor", label = "Trim", kind = "color", colors = AppearanceDefs.TRIM_COLORS },
} :: { Category }

-- The list a category picks from, whichever kind it is.
function AppearanceDefs.choicesFor(category: Category): { any }
	return (category.options or category.colors) :: { any }
end

-- A look with every field replaced by a known id. Anything unrecognised falls
-- back rather than being dropped: a look saved by a newer server may name a
-- hairstyle this one has never heard of, and the player should still get a
-- character.
function AppearanceDefs.sanitize(look: unknown): Look
	local source: { [string]: unknown } = if typeof(look) == "table" then look :: any else {}
	local clean = AppearanceDefs.default()

	for _, category in AppearanceDefs.CATEGORIES do
		local chosen = findById(AppearanceDefs.choicesFor(category), source[category.id])
		if chosen then
			(clean :: any)[category.id] = chosen.id
		end
	end

	return clean
end

-- Every piece a look is built from, with its colour already resolved.
export type ResolvedPiece = {
	piece: Piece,
	color: RGB,
}

-- Every welded piece a look is made of, each with its colour already
-- resolved from the look's four tints.
--
-- This is the whole translation from "what the player chose" to "what the
-- server welds on". Face, hair, markings and garb in that order; a piece
-- with its own `color` keeps it, one with a `tint` takes that colour, and
-- anything with neither falls back to skin.
function AppearanceDefs.piecesFor(look: Look): { ResolvedPiece }
	local tints: { [string]: RGB } = {
		skin = AppearanceDefs.colorOf(AppearanceDefs.SKIN_TONES, look.skin),
		hair = AppearanceDefs.colorOf(AppearanceDefs.HAIR_COLORS, look.hairColor),
		garb = AppearanceDefs.colorOf(AppearanceDefs.GARB_COLORS, look.garbColor),
		trim = AppearanceDefs.colorOf(AppearanceDefs.TRIM_COLORS, look.trimColor),
	}

	local resolved: { ResolvedPiece } = {}
	local sources = {
		AppearanceDefs.option(AppearanceDefs.FACES, look.face),
		AppearanceDefs.option(AppearanceDefs.HAIR, look.hair),
		AppearanceDefs.option(AppearanceDefs.MARKINGS, look.marking),
		AppearanceDefs.option(AppearanceDefs.GARB, look.garb),
	}

	for _, source in sources do
		for _, piece in source.pieces or {} do
			local color = piece.color or (piece.tint and tints[piece.tint]) or tints.skin
			table.insert(resolved, { piece = piece, color = color })
		end
	end

	return resolved
end

return AppearanceDefs
