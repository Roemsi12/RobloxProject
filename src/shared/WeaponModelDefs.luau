--!strict
-- What each weapon looks like in a player's hands and on its stand, built from
-- plain parts. Pure data — no Roblox API. The server builds the models
-- (WeaponVisuals), so every player sees what everyone else is holding.
--
-- Like RigDefs, these are stand-ins for real meshes: a mesh can later replace
-- a piece one-for-one under the same name without touching the code.
--
-- Coordinates are in the space of the body part a piece hangs from, with the
-- same axes as RigDefs: +Y up, -Z forward, +X the rig's right. A piece on a
-- hand is placed relative to that hand's grip point when the avatar has one
-- (RightGripAttachment / LeftGripAttachment), otherwise the hand's centre. A
-- blade along -Z therefore points forward while the arm hangs, and swings
-- with the arm.
--
-- A Cylinder's axis runs along its own X, so `size` is { length, diameter,
-- diameter } and a rotation aims it: ALONG_BLADE lays it down Z (a grip
-- running toward the point), UPRIGHT stands it along Y (a staff shaft), and
-- no rotation leaves it across X (a disc pommel, seen edge-on from the front).
--
-- Colours come from Palette, never from literals here: a player's sword and
-- the sword a skeleton swings at them are meant to be the same steel.

local Palette = require(script.Parent.Palette)

export type RGB = { number }
export type Vec3 = { number }

export type PieceDef = {
	name: string,
	-- An R15 body part name.
	attachTo: string,
	size: Vec3,
	offset: Vec3,
	-- Degrees, applied after the offset.
	rotation: Vec3?,
	color: RGB,
	-- An Enum.Material name; SmoothPlastic when unset.
	material: string?,
	-- An Enum.PartType name; Block when unset.
	shape: string?,
	transparency: number?,
	-- Lights up and sparkles as the weapon is upgraded.
	glow: boolean?,
}

export type WeaponModelDef = {
	pieces: { PieceDef },
	-- Upgrade glow colour on the `glow` pieces.
	glowColor: RGB,
}

export type UpgradeLook = {
	-- PointLight brightness on each glow piece; 0 means no light.
	lightBrightness: number,
	-- Sparkle particles per second on each glow piece; 0 means none.
	sparkleRate: number,
	-- Whether glow pieces turn to Neon in the glow colour.
	neon: boolean,
}

local WeaponModelDefs = {}

-- The model's name inside a character.
WeaponModelDefs.MODEL_NAME = "EquippedWeapon"
-- The attribute a character carries naming its equipped weapon, so every
-- client can pick that weapon's stance for it.
WeaponModelDefs.WEAPON_ATTRIBUTE = "WeaponId"

local STEEL = Palette.STEEL
local DARK_STEEL = Palette.DARK_STEEL
local IRON = Palette.IRON
local GOLD = Palette.GOLD
local BRIGHT_GOLD = Palette.BRIGHT_GOLD
local LEATHER = Palette.LEATHER
local DARK_LEATHER = Palette.DARK_LEATHER
local OAK = Palette.OAK
local BONE = Palette.BONE
local BOARD = Palette.ROT_WOOD

-- A cylinder laid along the blade axis: grips, wraps, ferrules.
local ALONG_BLADE = { 0, 90, 0 }
-- A cylinder stood upright: a staff shaft.
local UPRIGHT = { 0, 0, 90 }

local function concat(...: { PieceDef }): { PieceDef }
	local out = {}
	for _, list in { ... } do
		for _, piece in list do
			table.insert(out, piece)
		end
	end
	return out
end

--[[ Sword & Shield: an arming sword and a heater shield ]]

-- Read from the pommel forward: a wheel pommel, a wrapped grip, a swept
-- crossguard with a langet over the blade's shoulder, then a fullered blade
-- stepping down twice to a point. The fuller — the groove down a blade — is a
-- dark strip a hair wider than the blade, so it shows as a line on both flats
-- without needing a part that isn't a box.
local function swordAndShield(): { PieceDef }
	local sword: { PieceDef } = {
		{ name = "SwordPommel", attachTo = "RightHand", size = { 0.14, 0.44, 0.44 }, offset = { 0, 0, 0.52 }, color = BRIGHT_GOLD, material = "Metal", shape = "Cylinder" },
		{ name = "SwordPommelRivet", attachTo = "RightHand", size = { 0.16, 0.16, 0.16 }, offset = { 0, 0, 0.6 }, color = GOLD, material = "Metal", shape = "Ball" },
		{ name = "SwordGrip", attachTo = "RightHand", size = { 0.92, 0.21, 0.21 }, offset = { 0, 0, 0.02 }, rotation = ALONG_BLADE, color = LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = "SwordWrapA", attachTo = "RightHand", size = { 0.07, 0.25, 0.25 }, offset = { 0, 0, 0.3 }, rotation = ALONG_BLADE, color = DARK_LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = "SwordWrapB", attachTo = "RightHand", size = { 0.07, 0.25, 0.25 }, offset = { 0, 0, 0.1 }, rotation = ALONG_BLADE, color = DARK_LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = "SwordWrapC", attachTo = "RightHand", size = { 0.07, 0.25, 0.25 }, offset = { 0, 0, -0.1 }, rotation = ALONG_BLADE, color = DARK_LEATHER, material = "Fabric", shape = "Cylinder" },

		-- Crossguard, with its tips swept forward toward the blade.
		{ name = "SwordGuard", attachTo = "RightHand", size = { 1.05, 0.17, 0.24 }, offset = { 0, 0, -0.46 }, color = GOLD, material = "Metal" },
		{ name = "SwordQuillonRight", attachTo = "RightHand", size = { 0.34, 0.15, 0.2 }, offset = { 0.62, 0, -0.52 }, rotation = { 0, -22, 0 }, color = GOLD, material = "Metal" },
		{ name = "SwordQuillonLeft", attachTo = "RightHand", size = { 0.34, 0.15, 0.2 }, offset = { -0.62, 0, -0.52 }, rotation = { 0, 22, 0 }, color = GOLD, material = "Metal" },
		{ name = "SwordGuardBoss", attachTo = "RightHand", size = { 0.24, 0.24, 0.24 }, offset = { 0, 0, -0.46 }, color = BRIGHT_GOLD, material = "Metal", shape = "Ball" },

		{ name = "SwordLanget", attachTo = "RightHand", size = { 0.19, 0.12, 0.42 }, offset = { 0, 0, -0.76 }, color = GOLD, material = "Metal" },
		{ name = "SwordRicasso", attachTo = "RightHand", size = { 0.15, 0.34, 0.5 }, offset = { 0, 0, -1.02 }, color = DARK_STEEL, material = "Metal" },

		-- The blade is the glow piece, so an upgrade lights the edge itself.
		{ name = "SwordBlade", attachTo = "RightHand", size = { 0.13, 0.32, 2.3 }, offset = { 0, 0, -2.4 }, color = STEEL, material = "Metal", glow = true },
		{ name = "SwordFuller", attachTo = "RightHand", size = { 0.15, 0.09, 2.0 }, offset = { 0, 0, -2.4 }, color = DARK_STEEL, material = "Metal" },
		{ name = "SwordTaper", attachTo = "RightHand", size = { 0.12, 0.24, 0.5 }, offset = { 0, 0, -3.78 }, color = STEEL, material = "Metal" },
		{ name = "SwordPoint", attachTo = "RightHand", size = { 0.1, 0.12, 0.34 }, offset = { 0, 0, -4.16 }, color = STEEL, material = "Metal" },
	}

	-- Strapped to the outside of the left forearm: a heater shield, square
	-- across the top and stepping in to a point below, with an iron rim, a
	-- boss, and a painted device worn down to almost nothing.
	local shield: { PieceDef } = {
		{ name = "ShieldFace", attachTo = "LeftLowerArm", size = { 0.24, 1.5, 1.9 }, offset = { -0.56, 0.35, 0 }, color = BOARD, material = "WoodPlanks" },
		{ name = "ShieldTaperUpper", attachTo = "LeftLowerArm", size = { 0.24, 0.45, 1.5 }, offset = { -0.56, -0.62, 0 }, color = BOARD, material = "WoodPlanks" },
		{ name = "ShieldTaperLower", attachTo = "LeftLowerArm", size = { 0.24, 0.45, 0.85 }, offset = { -0.56, -1.05, 0 }, color = BOARD, material = "WoodPlanks" },
		{ name = "ShieldPoint", attachTo = "LeftLowerArm", size = { 0.24, 0.35, 0.34 }, offset = { -0.56, -1.42, 0 }, color = BOARD, material = "WoodPlanks" },

		{ name = "ShieldRimTop", attachTo = "LeftLowerArm", size = { 0.3, 0.18, 1.98 }, offset = { -0.57, 1.06, 0 }, color = IRON, material = "Metal" },
		{ name = "ShieldRimFront", attachTo = "LeftLowerArm", size = { 0.3, 1.6, 0.18 }, offset = { -0.57, 0.3, -0.96 }, color = IRON, material = "Metal" },
		{ name = "ShieldRimBack", attachTo = "LeftLowerArm", size = { 0.3, 1.6, 0.18 }, offset = { -0.57, 0.3, 0.96 }, color = IRON, material = "Metal" },
		-- The two lower edges, angled in to meet at the point.
		{ name = "ShieldRimFrontLower", attachTo = "LeftLowerArm", size = { 0.3, 1.5, 0.18 }, offset = { -0.57, -0.72, -0.62 }, rotation = { 24, 0, 0 }, color = IRON, material = "Metal" },
		{ name = "ShieldRimBackLower", attachTo = "LeftLowerArm", size = { 0.3, 1.5, 0.18 }, offset = { -0.57, -0.72, 0.62 }, rotation = { -24, 0, 0 }, color = IRON, material = "Metal" },

		{ name = "ShieldDeviceStem", attachTo = "LeftLowerArm", size = { 0.06, 1.5, 0.22 }, offset = { -0.7, 0.3, 0 }, color = Palette.CRIMSON },
		{ name = "ShieldDeviceArm", attachTo = "LeftLowerArm", size = { 0.06, 0.22, 1.1 }, offset = { -0.7, 0.62, 0 }, color = Palette.CRIMSON },

		{ name = "ShieldBoss", attachTo = "LeftLowerArm", size = { 0.62, 0.62, 0.62 }, offset = { -0.74, 0.3, 0 }, color = BRIGHT_GOLD, material = "Metal", shape = "Ball", glow = true },
		-- No rotation: the ring's axis points straight out of the shield face.
		{ name = "ShieldBossRing", attachTo = "LeftLowerArm", size = { 0.12, 0.82, 0.82 }, offset = { -0.72, 0.3, 0 }, color = IRON, material = "Metal", shape = "Cylinder" },

		{ name = "ShieldRivetTopFront", attachTo = "LeftLowerArm", size = { 0.14, 0.14, 0.14 }, offset = { -0.7, 1.06, -0.72 }, color = DARK_STEEL, material = "Metal", shape = "Ball" },
		{ name = "ShieldRivetTopBack", attachTo = "LeftLowerArm", size = { 0.14, 0.14, 0.14 }, offset = { -0.7, 1.06, 0.72 }, color = DARK_STEEL, material = "Metal", shape = "Ball" },
		{ name = "ShieldRivetLowFront", attachTo = "LeftLowerArm", size = { 0.14, 0.14, 0.14 }, offset = { -0.7, -0.5, -0.78 }, color = DARK_STEEL, material = "Metal", shape = "Ball" },
		{ name = "ShieldRivetLowBack", attachTo = "LeftLowerArm", size = { 0.14, 0.14, 0.14 }, offset = { -0.7, -0.5, 0.78 }, color = DARK_STEEL, material = "Metal", shape = "Ball" },

		-- The arm strap, on the inner face against the forearm.
		{ name = "ShieldStrap", attachTo = "LeftLowerArm", size = { 0.5, 0.2, 0.9 }, offset = { -0.3, 0.3, 0 }, color = DARK_LEATHER, material = "Fabric" },
	}

	return concat(sword, shield)
end

--[[ Daggers: a matched pair of ring-guard parrying daggers ]]

-- `sign` puts each dagger's side-ring on the outside of its own hand: R15
-- hands share one orientation, so the left needs its ring mirrored in X
-- rather than copied straight across.
local function dagger(side: string, sign: number): { PieceDef }
	local hand = `{side}Hand`
	return {
		{ name = `{side}DaggerPommel`, attachTo = hand, size = { 0.12, 0.26, 0.26 }, offset = { 0, 0, 0.34 }, color = IRON, material = "Metal", shape = "Cylinder" },
		{ name = `{side}DaggerGrip`, attachTo = hand, size = { 0.54, 0.17, 0.17 }, offset = { 0, 0, 0.05 }, rotation = ALONG_BLADE, color = DARK_LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = `{side}DaggerWrapA`, attachTo = hand, size = { 0.05, 0.2, 0.2 }, offset = { 0, 0, 0.16 }, rotation = ALONG_BLADE, color = LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = `{side}DaggerWrapB`, attachTo = hand, size = { 0.05, 0.2, 0.2 }, offset = { 0, 0, 0.02 }, rotation = ALONG_BLADE, color = LEATHER, material = "Fabric", shape = "Cylinder" },

		{ name = `{side}DaggerGuard`, attachTo = hand, size = { 0.66, 0.11, 0.14 }, offset = { 0, 0, -0.26 }, color = DARK_STEEL, material = "Metal" },
		-- The side ring that catches an enemy blade. No rotation: its axis
		-- points out of the dagger's flat, so you look through it from the
		-- side, the way a real ring guard sits.
		{ name = `{side}DaggerRing`, attachTo = hand, size = { 0.07, 0.42, 0.42 }, offset = { 0.26 * sign, 0, -0.18 }, color = DARK_STEEL, material = "Metal", shape = "Cylinder" },
		{ name = `{side}DaggerRingHollow`, attachTo = hand, size = { 0.09, 0.26, 0.26 }, offset = { 0.26 * sign, 0, -0.18 }, color = DARK_LEATHER, shape = "Cylinder" },

		{ name = `{side}DaggerBlade`, attachTo = hand, size = { 0.08, 0.22, 1.0 }, offset = { 0, 0, -0.85 }, color = STEEL, material = "Metal", glow = true },
		{ name = `{side}DaggerEdge`, attachTo = hand, size = { 0.1, 0.06, 0.9 }, offset = { 0, 0, -0.85 }, color = DARK_STEEL, material = "Metal" },
		{ name = `{side}DaggerTaper`, attachTo = hand, size = { 0.07, 0.15, 0.36 }, offset = { 0, 0, -1.5 }, color = STEEL, material = "Metal" },
		{ name = `{side}DaggerPoint`, attachTo = hand, size = { 0.06, 0.08, 0.24 }, offset = { 0, 0, -1.78 }, color = STEEL, material = "Metal" },
	}
end

--[[ Staff: a gnarled stave with an orb caged in gold claws ]]

-- Gripped below the middle, so it stands upright at rest with the orb above
-- the head, and swings through level like a quarterstaff when the arm comes
-- forward. (A hand's +Y runs up the forearm, so a staff reaching only upward
-- from the grip would point back through the body mid-swing.)
local function staff(): { PieceDef }
	local z = -0.5
	return {
		{ name = "StaffShaft", attachTo = "RightHand", size = { 5.6, 0.24, 0.24 }, offset = { 0, 0.9, z }, rotation = UPRIGHT, color = OAK, material = "Wood", shape = "Cylinder" },
		{ name = "StaffFerrule", attachTo = "RightHand", size = { 0.5, 0.3, 0.3 }, offset = { 0, -1.75, z }, rotation = UPRIGHT, color = IRON, material = "Metal", shape = "Cylinder" },

		{ name = "StaffGrip", attachTo = "RightHand", size = { 1.0, 0.32, 0.32 }, offset = { 0, 0, z }, rotation = UPRIGHT, color = DARK_LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = "StaffBandLower", attachTo = "RightHand", size = { 0.16, 0.36, 0.36 }, offset = { 0, 0.58, z }, rotation = UPRIGHT, color = IRON, material = "Metal", shape = "Cylinder" },
		{ name = "StaffBandUpper", attachTo = "RightHand", size = { 0.16, 0.36, 0.36 }, offset = { 0, 2.2, z }, rotation = UPRIGHT, color = IRON, material = "Metal", shape = "Cylinder" },

		-- Knots in the wood, so the stave doesn't read as a dowel.
		{ name = "StaffKnotLow", attachTo = "RightHand", size = { 0.34, 0.3, 0.34 }, offset = { 0.08, 1.35, z }, color = Palette.shade(OAK, 0.85), material = "Wood", shape = "Ball" },
		{ name = "StaffKnotHigh", attachTo = "RightHand", size = { 0.3, 0.26, 0.3 }, offset = { -0.07, 2.9, z }, color = Palette.shade(OAK, 0.85), material = "Wood", shape = "Ball" },

		-- The head: a collar, three claws curving up, and the orb they hold.
		{ name = "StaffCollar", attachTo = "RightHand", size = { 0.34, 0.44, 0.44 }, offset = { 0, 3.66, z }, rotation = UPRIGHT, color = GOLD, material = "Metal", shape = "Cylinder" },
		{ name = "StaffClawRight", attachTo = "RightHand", size = { 0.11, 0.95, 0.11 }, offset = { 0.3, 4.1, z }, rotation = { 0, 0, -26 }, color = GOLD, material = "Metal" },
		{ name = "StaffClawLeft", attachTo = "RightHand", size = { 0.11, 0.95, 0.11 }, offset = { -0.3, 4.1, z }, rotation = { 0, 0, 26 }, color = GOLD, material = "Metal" },
		{ name = "StaffClawBack", attachTo = "RightHand", size = { 0.11, 0.95, 0.11 }, offset = { 0, 4.1, z + 0.3 }, rotation = { 26, 0, 0 }, color = GOLD, material = "Metal" },
		{ name = "StaffOrb", attachTo = "RightHand", size = { 0.82, 0.82, 0.82 }, offset = { 0, 4.3, z }, color = Palette.ARCANE, material = "Glass", shape = "Ball", transparency = 0.25, glow = true },
		{ name = "StaffOrbCore", attachTo = "RightHand", size = { 0.34, 0.34, 0.34 }, offset = { 0, 4.3, z }, color = Palette.ARCANE, material = "Neon", shape = "Ball" },

		-- A bone charm on a cord, hanging off the collar.
		{ name = "StaffCharmCord", attachTo = "RightHand", size = { 0.05, 0.5, 0.05 }, offset = { 0.22, 3.4, z }, color = Palette.ROPE, material = "Fabric" },
		{ name = "StaffCharm", attachTo = "RightHand", size = { 0.12, 0.34, 0.12 }, offset = { 0.22, 3.05, z }, rotation = { 0, 0, 12 }, color = BONE },
	}
end

-- Keyed by WeaponDefs id.
WeaponModelDefs.MODELS = {
	SwordAndShield = {
		glowColor = { 120, 190, 255 },
		pieces = swordAndShield(),
	},

	Daggers = {
		glowColor = Palette.SHADOW_MAGIC,
		pieces = concat(dagger("Right", 1), dagger("Left", -1)),
	},

	Staff = {
		glowColor = Palette.ARCANE,
		pieces = staff(),
	},
} :: { [string]: WeaponModelDef }

-- How an upgraded weapon shows its level. Upgrades are progress you paid for,
-- so they should be visible to everyone standing next to you.
function WeaponModelDefs.upgradeLook(level: number): UpgradeLook
	local l = math.max(math.floor(level), 0)
	return {
		lightBrightness = if l >= 1 then 0.4 * l else 0,
		sparkleRate = if l >= 3 then 4 * (l - 2) else 0,
		neon = l >= 5,
	}
end

return WeaponModelDefs
