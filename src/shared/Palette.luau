--!strict
-- The one palette every piece of art in the dungeon draws from. Pure data —
-- no Roblox API, so weapon models, rigs and room geometry can all share it.
--
-- The look is grim dark fantasy: cold wet stone, black iron gone to rust,
-- old bone, tarnished gold, and firelight as nearly the only warm thing in
-- the frame. Nothing here is saturated except light sources and the things
-- meant to frighten you — acid, ghost-fire, a wound. That restraint is the
-- whole trick: when every surface is a desaturated grey-brown, a torch or an
-- enemy's eyes carry enormous weight.
--
-- Colours are { r, g, b } in 0-255, the same shape RigDefs and
-- WeaponModelDefs already use. RoomTemplates turns them into Color3.
--
-- Use a named colour rather than a literal. A named colour used in three
-- places is what makes a sword, a skeleton and a wall sconce look like they
-- come from the same world; three hand-picked greys is what makes them look
-- like three people built them.

local Palette = {}

export type RGB = { number }

--[[ Stone: the dungeon itself ]]

-- Floors are darker than walls, so rooms read as lit from the torches up.
--
-- Every stone here is blue-shifted — blue channel highest, red lowest. Warm
-- stone reads as a sunlit castle however dark you make it, and the dusk
-- Lighting the game ships with already lays a warm tint over everything
-- (ColorGrade.TintColor in default.project.json). Cold stone is what lets the
-- torches do the warming, which is the whole look.
Palette.FLOOR = { 74, 72, 80 }
Palette.WALL = { 96, 94, 102 }
-- Cut stone: door surrounds, arch voussoirs, pillar bases and capitals.
Palette.TRIM = { 58, 56, 64 }
Palette.PILLAR = { 112, 110, 120 }
Palette.RUBBLE = { 86, 84, 92 }
-- Damp patches and the grout between flagstones.
Palette.MORTAR = { 54, 52, 60 }
Palette.MOSS = { 62, 76, 54 }

--[[ Metal ]]

-- Black iron: brackets, bands, portcullis bars, the Hollow King's plate.
Palette.IRON = { 45, 42, 44 }
-- Iron that has been in a wet dungeon for a century.
Palette.RUST = { 104, 62, 40 }
-- A blade kept sharp. The brightest non-glowing thing in the game.
Palette.STEEL = { 196, 202, 212 }
-- Armour and blades that have not been kept sharp.
Palette.DARK_STEEL = { 90, 94, 104 }
-- Gold that stopped being polished a long time ago.
Palette.GOLD = { 150, 120, 60 }
-- Gold still bright enough to catch the light: pommels, crowns, reliquaries.
Palette.BRIGHT_GOLD = { 212, 170, 70 }
Palette.COPPER = { 124, 86, 52 }

--[[ Organic ]]

Palette.BONE = { 232, 226, 206 }
-- Bone that has been underground: the enemies, not a fresh skeleton.
Palette.OLD_BONE = { 196, 188, 162 }
Palette.LEATHER = { 86, 56, 38 }
Palette.DARK_LEATHER = { 58, 40, 30 }
Palette.OAK = { 120, 82, 50 }
-- Rotted, waterlogged timber: barrels, cart wheels, a broken door.
Palette.ROT_WOOD = { 82, 62, 44 }
Palette.ROPE = { 158, 132, 88 }
-- Sackcloth and bandage.
Palette.LINEN = { 190, 175, 142 }

--[[ Cloth ]]

-- Banners and tabards. Deep enough to stay dark in torchlight.
Palette.CRIMSON = { 108, 28, 34 }
Palette.DEEP_BLUE = { 40, 52, 86 }
Palette.BLACK_CLOTH = { 34, 32, 36 }
-- The cloth of something that has been hanging in a tomb.
Palette.TATTERED = { 96, 88, 76 }

--[[ Flesh ]]

Palette.ZOMBIE_SKIN = { 118, 150, 92 }
Palette.ROT_FLESH = { 92, 106, 74 }
Palette.SPITTER_HIDE = { 150, 170, 70 }
-- Exposed muscle and open wounds.
Palette.VISCERA = { 122, 44, 44 }

--[[ Light and magic — the only saturated colours in the palette ]]

Palette.TORCH_FIRE = { 255, 150, 70 }
Palette.TORCH_EMBER = { 255, 96, 32 }
-- The Hollow King's colour: cold fire, and everything that belongs to him.
Palette.GHOST_FIRE = { 110, 200, 255 }
Palette.ACID = { 170, 255, 60 }
-- A hostile eye in the dark.
Palette.EYE_GLOW = { 255, 60, 40 }
Palette.ARCANE = { 110, 255, 170 }
Palette.SHADOW_MAGIC = { 200, 110, 255 }

-- Near-black: eye sockets, open mouths, the inside of a helm. Not pure black,
-- which reads as a hole in the world rather than a shadow.
Palette.VOID = { 20, 18, 16 }

--[[ Helpers ]]

local function channel(value: number): number
	return math.clamp(math.round(value), 0, 255)
end

-- The same colour, darker (`amount` < 1) or lighter (> 1). Used to give one
-- material its own shading — a barrel's staves against its bands — without
-- inventing a second colour that might drift from the first.
function Palette.shade(rgb: RGB, amount: number): RGB
	return { channel(rgb[1] * amount), channel(rgb[2] * amount), channel(rgb[3] * amount) }
end

-- `alpha` of the way from `from` to `to`. For weathering: stone toward moss,
-- iron toward rust.
function Palette.mix(from: RGB, to: RGB, alpha: number): RGB
	local a = math.clamp(alpha, 0, 1)
	return {
		channel(from[1] + (to[1] - from[1]) * a),
		channel(from[2] + (to[2] - from[2]) * a),
		channel(from[3] + (to[3] - from[3]) * a),
	}
end

return Palette
