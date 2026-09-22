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
-- What goes on it is textures and real meshes, not welded blocks:
--
--   Garb is a classic Shirt and Pants, plus a ShirtGraphic on the chest that
--   carries the trim colour. The art is ours (art/avatar), drawn in greyscale
--   so one texture takes any colour: Roblox multiplies a clothing texture by
--   its Color3.
--
--   Faces and markings are Decals on the head, tinted the same way. The eyes
--   are a decal of their own, so an eye colour tints the eyes and nothing else.
--
--   Hair is a catalogue hair accessory made by Roblox, with its texture taken
--   off so it takes the chosen hair colour.
--
-- Textures are named here and resolved to image ids through AvatarTextures,
-- which the upload script writes. A choice is still a piece of data, never a
-- branch: adding a hairstyle is a row in HAIR.

local Palette = require(script.Parent.Palette)

local AppearanceDefs = {}

export type RGB = { number }

-- The colours a layer can take from the look.
export type Tint = "skin" | "hair" | "garb" | "trim" | "legwear"

export type HairOption = {
	id: string,
	label: string,
	-- A Roblox catalogue hair accessory (HumanoidDescription.HairAccessory).
	hair: number?,
	-- A Roblox catalogue hat, for a hood (HumanoidDescription.HatAccessory).
	hat: number?,
	-- Which of the look's colours the accessory takes. Unset is the hair colour.
	tint: Tint?,
}

export type FaceOption = {
	id: string,
	label: string,
	-- Texture names, drawn in this order: the face, then the eyes over it.
	face: string,
	eyes: string,
	-- The face's tint: a mask takes the trim colour. Unset is untinted.
	faceTint: Tint?,
	-- The eyes' colour. Unset leaves natural eyes their own colours.
	eyeColor: RGB?,
}

export type MarkingOption = {
	id: string,
	label: string,
	texture: string?,
	tint: Tint?,
	color: RGB?,
}

export type GarbOption = {
	id: string,
	label: string,
	shirt: string,
	pants: string,
	-- The chest piece that carries the trim colour.
	overlay: string,
}

export type Category = {
	id: string,
	label: string,
	-- "option" picks from a list; "color" picks from a swatch row.
	kind: "option" | "color",
	-- Loosely typed on purpose: each option list has its own shape.
	-- Everything that reads these needs `id` and `label` and nothing more.
	options: { any }?,
	colors: { { id: string, label: string, rgb: RGB } }?,
}

--[[ The body everyone shares ]]

-- Applied as a HumanoidDescription, which is what actually removes a bundle,
-- a shirt or a hat. Zeroing the body-type and proportion scales is what makes
-- the body blocky: those two are what bend a default R15 toward Rthro's
-- proportions, and at zero the parts are the plain boxes the animations were
-- authored against — and the boxes a classic shirt template is drawn for.
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
	swatch("black", "Black", { 36, 34, 36 }),
	swatch("soot", "Soot", { 70, 66, 68 }),
	swatch("brown", "Brown", { 96, 64, 42 }),
	swatch("chestnut", "Chestnut", { 128, 78, 44 }),
	swatch("auburn", "Auburn", { 150, 70, 38 }),
	swatch("ash", "Ash", { 160, 152, 142 }),
	swatch("white", "White", Palette.BONE),
	swatch("straw", "Straw", { 206, 180, 120 }),
	swatch("ember", "Ember", Palette.TORCH_EMBER),
	swatch("arcane", "Arcane", Palette.ARCANE),
	swatch("shadow", "Shadow", Palette.SHADOW_MAGIC),
	swatch("ghost", "Ghostfire", Palette.GHOST_FIRE),
}

-- Cloth colours. Brighter than the palette's own cloth colours, because a
-- clothing texture multiplies by its colour: the texture's folds and seams
-- already darken it, and the palette values on top of that read as black.
AppearanceDefs.GARB_COLORS = {
	swatch("black", "Black", { 62, 60, 66 }),
	swatch("ash", "Ash", { 150, 140, 126 }),
	swatch("linen", "Linen", { 236, 222, 188 }),
	swatch("leather", "Leather", { 156, 106, 72 }),
	swatch("crimson", "Crimson", { 164, 44, 52 }),
	swatch("deep", "Deep Blue", { 66, 86, 140 }),
	swatch("moss", "Moss", { 100, 122, 84 }),
	swatch("rust", "Rust", { 166, 98, 60 }),
	swatch("iron", "Iron", { 104, 102, 108 }),
	swatch("bone", "Bone", { 230, 222, 196 }),
}

AppearanceDefs.TRIM_COLORS = {
	swatch("gold", "Gold", { 214, 170, 84 }),
	swatch("bright", "Bright Gold", { 255, 214, 110 }),
	swatch("steel", "Steel", Palette.STEEL),
	swatch("dark", "Dark Steel", { 112, 116, 126 }),
	swatch("copper", "Copper", { 196, 122, 76 }),
	swatch("iron", "Iron", { 104, 102, 108 }),
	swatch("crimson", "Crimson", { 164, 44, 52 }),
	swatch("arcane", "Arcane", Palette.ARCANE),
	swatch("ghost", "Ghostfire", Palette.GHOST_FIRE),
	swatch("bone", "Bone", Palette.BONE),
}

--[[ Hair ]]

-- All made by Roblox, so none of them can vanish from the catalogue under a
-- player's head, and all sized for the classic head the body wears.
AppearanceDefs.HAIR = {
	{ id = "shaved", label = "Shaved" },
	{ id = "cropped", label = "Cropped", hair = 13655562 }, -- Brooding Black Hair
	{ id = "swept", label = "Swept", hair = 376548738 }, -- Brown Charmer Hair
	{ id = "long", label = "Long", hair = 1772372988 }, -- Black Long and Straight Hair
	{ id = "topknot", label = "Topknot", hair = 343584973 }, -- Man Bun Hair
	{ id = "ponytail", label = "Ponytail", hair = 376527350 }, -- Black Ponytail
	{ id = "braids", label = "Braids", hair = 7193454569 }, -- Braided Hair - Black
	{ id = "mohawk", label = "Mohawk", hair = 11721248 }, -- Mohawk
	{ id = "wild", label = "Wild", hair = 16630147 }, -- Beautiful Hair for Beautiful People
	-- A hood is cloth, so it takes the garb colour, not the hair colour.
	{ id = "hooded", label = "Hooded", hat = 617605556, tint = "garb" }, -- Medieval Hood of Mystery
} :: { HairOption }

--[[ Faces ]]

-- Eyes that glow are drawn white and tinted; natural eyes carry their own
-- whites and irises and are left alone.
AppearanceDefs.FACES = {
	{ id = "steady", label = "Steady", face = "face_steady", eyes = "eyes_natural" },
	{ id = "calm", label = "Calm", face = "face_calm", eyes = "eyes_natural" },
	{ id = "grim", label = "Grim", face = "face_grim", eyes = "eyes_narrow" },
	{ id = "weary", label = "Weary", face = "face_weary", eyes = "eyes_narrow" },
	{ id = "ember", label = "Ember-Eyed", face = "face_fierce", eyes = "eyes_glow", eyeColor = Palette.TORCH_EMBER },
	{ id = "ghostfire", label = "Ghostfire", face = "face_grim", eyes = "eyes_glow", eyeColor = Palette.GHOST_FIRE },
	{ id = "arcane", label = "Arcane", face = "face_calm", eyes = "eyes_glow", eyeColor = Palette.ARCANE },
	{ id = "hollowed", label = "Hollowed", face = "face_hollow", eyes = "eyes_sockets", eyeColor = Palette.EYE_GLOW },
	{ id = "masked", label = "Masked", face = "face_mask", faceTint = "trim", eyes = "eyes_slits" },
} :: { FaceOption }

--[[ Markings ]]

-- Drawn under the face, so a mask covers a marking and the eyes sit on top
-- of both.
AppearanceDefs.MARKINGS = {
	{ id = "none", label = "None" },
	{ id = "warpaint", label = "War Paint", texture = "mark_warpaint", tint = "trim" },
	{ id = "scar", label = "Scar", texture = "mark_scar", color = { 170, 112, 102 } },
	{ id = "brand", label = "Brand", texture = "mark_brand", color = Palette.RUST },
	{ id = "ash", label = "Ash", texture = "mark_ash", color = { 70, 66, 70 } },
	{ id = "tattoo", label = "Tattoo", texture = "mark_tattoo", tint = "trim" },
	{ id = "stitched", label = "Stitched", texture = "mark_stitched" },
} :: { MarkingOption }

--[[ Garb ]]

-- Each garb is a shirt, the pants under it and the chest piece over it.
-- Textures are painted onto the body rather than hung off it, so nothing a
-- garb adds can clip through a stride or hide a joint an animation moves.
AppearanceDefs.GARB = {
	{ id = "none", label = "Ragged", shirt = "shirt_ragged", pants = "pants_ragged", overlay = "overlay_ragged" },
	{ id = "tunic", label = "Tunic", shirt = "shirt_tunic", pants = "pants_trousers", overlay = "overlay_tunic" },
	{ id = "leathers", label = "Leathers", shirt = "shirt_leathers", pants = "pants_trousers", overlay = "overlay_leathers" },
	{ id = "plate", label = "Plate", shirt = "shirt_plate", pants = "pants_greaves", overlay = "overlay_plate" },
	{ id = "robes", label = "Robes", shirt = "shirt_robes", pants = "pants_robe", overlay = "overlay_robes" },
	{ id = "tabard", label = "Tabard", shirt = "shirt_tabard", pants = "pants_trousers", overlay = "overlay_tabard" },
	{ id = "wrappings", label = "Wrappings", shirt = "shirt_wrappings", pants = "pants_wraps", overlay = "overlay_wrappings" },
	{ id = "cloak", label = "Cloak", shirt = "shirt_cloak", pants = "pants_trousers", overlay = "overlay_cloak" },
} :: { GarbOption }

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
	legwearColor: string,
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
		legwearColor = "black",
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
	{ id = "legwearColor", label = "Legwear", kind = "color", colors = AppearanceDefs.GARB_COLORS },
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

--[[ What a look is made of ]]

-- A texture and the colour it is tinted. White leaves it as drawn.
export type Layer = {
	texture: string,
	color: RGB,
}

-- Everything the server puts on a body for one look, colours resolved.
export type Outfit = {
	skin: RGB,
	-- The catalogue accessory, if any, and the colour it is dyed.
	hair: number?,
	hat: number?,
	hairColor: RGB,
	shirt: Layer,
	pants: Layer,
	overlay: Layer,
	-- Head decals, bottom first: marking, face, eyes.
	decals: { Layer },
}

local WHITE: RGB = { 255, 255, 255 }

-- The whole translation from "what the player chose" to "what the server
-- puts on the body", with every colour already resolved from the look's
-- tints. Pure, so the tests can build every combination.
function AppearanceDefs.outfitFor(look: Look): Outfit
	local tints: { [string]: RGB } = {
		skin = AppearanceDefs.colorOf(AppearanceDefs.SKIN_TONES, look.skin),
		hair = AppearanceDefs.colorOf(AppearanceDefs.HAIR_COLORS, look.hairColor),
		garb = AppearanceDefs.colorOf(AppearanceDefs.GARB_COLORS, look.garbColor),
		legwear = AppearanceDefs.colorOf(AppearanceDefs.GARB_COLORS, look.legwearColor),
		trim = AppearanceDefs.colorOf(AppearanceDefs.TRIM_COLORS, look.trimColor),
	}

	local hair: HairOption = AppearanceDefs.option(AppearanceDefs.HAIR, look.hair)
	local face: FaceOption = AppearanceDefs.option(AppearanceDefs.FACES, look.face)
	local marking: MarkingOption = AppearanceDefs.option(AppearanceDefs.MARKINGS, look.marking)
	local garb: GarbOption = AppearanceDefs.option(AppearanceDefs.GARB, look.garb)

	local decals: { Layer } = {}
	if marking.texture then
		table.insert(decals, {
			texture = marking.texture,
			color = marking.color or (marking.tint and tints[marking.tint]) or WHITE,
		})
	end
	table.insert(decals, { texture = face.face, color = face.faceTint and tints[face.faceTint] or WHITE })
	table.insert(decals, { texture = face.eyes, color = face.eyeColor or WHITE })

	return {
		skin = tints.skin,
		hair = hair.hair,
		hat = hair.hat,
		hairColor = tints[hair.tint or "hair"],
		shirt = { texture = garb.shirt, color = tints.garb },
		pants = { texture = garb.pants, color = tints.legwear },
		overlay = { texture = garb.overlay, color = tints.trim },
		decals = decals,
	}
end

return AppearanceDefs
