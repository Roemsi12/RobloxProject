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

-- Ornament, shared so that "impressive" means the same thing on every weapon
-- rather than whatever each one felt like. A hero weapon in this game reads by
-- three things: a jewel that catches the light, a line of engraving down a
-- flat, and a silhouette that is not symmetrical.
local function jewel(name: string, attachTo: string, at: Vec3, size: number, color: RGB): PieceDef
	return { name = name, attachTo = attachTo, size = { size, size, size }, offset = at, color = color, material = "Neon", shape = "Ball" }
end

-- A thin inlaid line. Slightly proud of the flat it sits on, so it catches a
-- highlight instead of z-fighting with the surface underneath.
local function inlay(name: string, attachTo: string, size: Vec3, at: Vec3, color: RGB, rotation: Vec3?): PieceDef
	return { name = name, attachTo = attachTo, size = size, offset = at, rotation = rotation, color = color, material = "Neon" }
end

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

		-- Ornament. The quillons grew wings, the pommel took a stone, and the
		-- fuller took a line of inlay down it — the three things that separate
		-- a knight's sword from a soldier's, without moving a single edge.
		{ name = "SwordWingRight", attachTo = "RightHand", size = { 0.5, 0.1, 0.34 }, offset = { 0.84, 0, -0.62 }, rotation = { 0, -38, 0 }, color = BRIGHT_GOLD, material = "Metal" },
		{ name = "SwordWingLeft", attachTo = "RightHand", size = { 0.5, 0.1, 0.34 }, offset = { -0.84, 0, -0.62 }, rotation = { 0, 38, 0 }, color = BRIGHT_GOLD, material = "Metal" },
		jewel("SwordPommelStone", "RightHand", { 0, 0, 0.66 }, 0.17, { 120, 190, 255 }),
		jewel("SwordGuardStone", "RightHand", { 0, 0.14, -0.46 }, 0.13, { 120, 190, 255 }),
		inlay("SwordInlay", "RightHand", { 0.17, 0.04, 1.7 }, { 0, 0, -2.4 }, { 120, 190, 255 }),
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

		-- Studding round the rim, and a stone in the boss. The studs are what
		-- make a board read as something that has been made rather than cut.
		{ name = "ShieldStudTopFront", attachTo = "LeftLowerArm", size = { 0.16, 0.16, 0.16 }, offset = { -0.72, 1.06, -0.3 }, color = BRIGHT_GOLD, material = "Metal", shape = "Ball" },
		{ name = "ShieldStudTopBack", attachTo = "LeftLowerArm", size = { 0.16, 0.16, 0.16 }, offset = { -0.72, 1.06, 0.3 }, color = BRIGHT_GOLD, material = "Metal", shape = "Ball" },
		{ name = "ShieldStudMidFront", attachTo = "LeftLowerArm", size = { 0.16, 0.16, 0.16 }, offset = { -0.72, 0.3, -0.88 }, color = BRIGHT_GOLD, material = "Metal", shape = "Ball" },
		{ name = "ShieldStudMidBack", attachTo = "LeftLowerArm", size = { 0.16, 0.16, 0.16 }, offset = { -0.72, 0.3, 0.88 }, color = BRIGHT_GOLD, material = "Metal", shape = "Ball" },
		jewel("ShieldBossStone", "LeftLowerArm", { -0.94, 0.3, 0 }, 0.26, { 120, 190, 255 }),
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

		-- A stone set in the ring, and a line of black down the flat. Assassin
		-- gear that glitters would be a poor assassin's gear, so both are dark
		-- until the blacksmith lights the blade.
		jewel(`{side}DaggerRingStone`, hand, { 0.26 * sign, 0, -0.18 }, 0.13, Palette.SHADOW_MAGIC),
		inlay(`{side}DaggerInlay`, hand, { 0.1, 0.03, 0.72 }, { 0, 0.07, -0.85 }, Palette.SHADOW_MAGIC),
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

		-- Two rings standing around the orb on different axes, so the head
		-- reads as a mechanism holding something rather than a ball on a
		-- stick. They do not turn; at this size they do not need to.
		{ name = "StaffRingOuter", attachTo = "RightHand", size = { 0.09, 1.36, 1.36 }, offset = { 0, 4.3, z }, rotation = { 0, 0, 20 }, color = GOLD, material = "Metal", shape = "Cylinder" },
		{ name = "StaffRingInner", attachTo = "RightHand", size = { 0.08, 1.12, 1.12 }, offset = { 0, 4.3, z }, rotation = UPRIGHT, color = BRIGHT_GOLD, material = "Metal", shape = "Cylinder" },
		jewel("StaffRune", "RightHand", { 0, 5.16, z }, 0.2, Palette.ARCANE),
	}
end

--[[ Greataxe: a bearded two-hand axe, head-heavy on purpose ]]

-- The whole point of this weapon is the silhouette, so the head is enormous
-- and sits well off the haft's axis. A symmetrical head would read as a
-- prop; a bearded one — the lower horn hanging below the eye — reads as a
-- thing made for pulling a shield down.
local function greataxe(): { PieceDef }
	local haft = -0.4
	return {
		{ name = "AxeHaft", attachTo = "RightHand", size = { 5.4, 0.3, 0.3 }, offset = { 0, 0.8, haft }, rotation = UPRIGHT, color = Palette.shade(OAK, 0.8), material = "Wood", shape = "Cylinder" },
		{ name = "AxeGrip", attachTo = "RightHand", size = { 1.3, 0.38, 0.38 }, offset = { 0, -0.1, haft }, rotation = UPRIGHT, color = DARK_LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = "AxeButt", attachTo = "RightHand", size = { 0.42, 0.42, 0.42 }, offset = { 0, -1.85, haft }, rotation = UPRIGHT, color = IRON, material = "Metal", shape = "Cylinder" },
		{ name = "AxeCollarLow", attachTo = "RightHand", size = { 0.2, 0.42, 0.42 }, offset = { 0, 0.62, haft }, rotation = UPRIGHT, color = IRON, material = "Metal", shape = "Cylinder" },
		{ name = "AxeCollarHigh", attachTo = "RightHand", size = { 0.2, 0.42, 0.42 }, offset = { 0, 2.5, haft }, rotation = UPRIGHT, color = IRON, material = "Metal", shape = "Cylinder" },

		-- The eye, where the head is wedged onto the haft.
		{ name = "AxeEye", attachTo = "RightHand", size = { 0.46, 0.96, 0.62 }, offset = { 0, 3.2, haft }, color = DARK_STEEL, material = "Metal" },
		{ name = "AxeWedge", attachTo = "RightHand", size = { 0.5, 0.18, 0.66 }, offset = { 0, 3.66, haft }, color = BRIGHT_GOLD, material = "Metal" },

		-- The blade: a wide bit sweeping forward, its beard hanging below.
		{ name = "AxeBit", attachTo = "RightHand", size = { 0.34, 2.1, 1.5 }, offset = { 0, 3.2, haft - 1.1 }, color = DARK_STEEL, material = "Metal", glow = true },
		{ name = "AxeBitUpper", attachTo = "RightHand", size = { 0.3, 0.9, 0.9 }, offset = { 0, 4.0, haft - 1.6 }, rotation = { -18, 0, 0 }, color = DARK_STEEL, material = "Metal" },
		{ name = "AxeBeard", attachTo = "RightHand", size = { 0.3, 1.1, 0.8 }, offset = { 0, 2.2, haft - 1.5 }, rotation = { 22, 0, 0 }, color = DARK_STEEL, material = "Metal" },
		{ name = "AxeEdge", attachTo = "RightHand", size = { 0.16, 2.9, 0.34 }, offset = { 0, 3.2, haft - 1.86 }, color = STEEL, material = "Metal" },
		{ name = "AxeEdgeUpper", attachTo = "RightHand", size = { 0.14, 0.5, 0.5 }, offset = { 0, 4.34, haft - 1.82 }, rotation = { -30, 0, 0 }, color = STEEL, material = "Metal" },
		{ name = "AxeEdgeLower", attachTo = "RightHand", size = { 0.14, 0.6, 0.5 }, offset = { 0, 1.9, haft - 1.78 }, rotation = { 32, 0, 0 }, color = STEEL, material = "Metal" },

		-- A back spike, so the head is not the same thing twice.
		{ name = "AxeSpike", attachTo = "RightHand", size = { 0.26, 0.4, 1.0 }, offset = { 0, 3.3, haft + 0.7 }, color = IRON, material = "Metal" },
		{ name = "AxeSpikeTip", attachTo = "RightHand", size = { 0.18, 0.24, 0.4 }, offset = { 0, 3.42, haft + 1.32 }, rotation = { -14, 0, 0 }, color = STEEL, material = "Metal" },

		inlay("AxeRune", "RightHand", { 0.38, 0.9, 0.09 }, { 0, 3.2, haft - 0.42 }, Palette.TORCH_EMBER),
		jewel("AxeEyeStone", "RightHand", { 0, 2.86, haft + 0.34 }, 0.2, Palette.TORCH_EMBER),
	}
end

--[[ Rapier: a swept-hilt with a cup, and a blade like a line ]]

-- Nearly all of this weapon's length is blade and nearly none of it is width,
-- which is the opposite of the greataxe on purpose: side by side in the hub
-- they should read as different answers to the same question.
local function rapier(): { PieceDef }
	return {
		{ name = "RapierPommel", attachTo = "RightHand", size = { 0.2, 0.3, 0.3 }, offset = { 0, 0, 0.62 }, color = BRIGHT_GOLD, material = "Metal", shape = "Cylinder" },
		jewel("RapierPommelStone", "RightHand", { 0, 0, 0.76 }, 0.14, Palette.CRIMSON),
		{ name = "RapierGrip", attachTo = "RightHand", size = { 0.78, 0.15, 0.15 }, offset = { 0, 0, 0.16 }, rotation = ALONG_BLADE, color = DARK_LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = "RapierWireA", attachTo = "RightHand", size = { 0.05, 0.18, 0.18 }, offset = { 0, 0, 0.34 }, rotation = ALONG_BLADE, color = BRIGHT_GOLD, material = "Metal", shape = "Cylinder" },
		{ name = "RapierWireB", attachTo = "RightHand", size = { 0.05, 0.18, 0.18 }, offset = { 0, 0, 0.16 }, rotation = ALONG_BLADE, color = BRIGHT_GOLD, material = "Metal", shape = "Cylinder" },
		{ name = "RapierWireC", attachTo = "RightHand", size = { 0.05, 0.18, 0.18 }, offset = { 0, 0, -0.02 }, rotation = ALONG_BLADE, color = BRIGHT_GOLD, material = "Metal", shape = "Cylinder" },

		-- The cup, and the sweeping bars that make a swept hilt swept.
		{ name = "RapierCup", attachTo = "RightHand", size = { 0.2, 0.86, 0.86 }, offset = { 0, 0, -0.34 }, rotation = ALONG_BLADE, color = GOLD, material = "Metal", shape = "Cylinder" },
		{ name = "RapierCupRim", attachTo = "RightHand", size = { 0.1, 0.96, 0.96 }, offset = { 0, 0, -0.44 }, rotation = ALONG_BLADE, color = BRIGHT_GOLD, material = "Metal", shape = "Cylinder" },
		{ name = "RapierBarRight", attachTo = "RightHand", size = { 0.09, 0.09, 0.8 }, offset = { 0.3, 0.16, -0.1 }, rotation = { 0, 0, -22 }, color = GOLD, material = "Metal" },
		{ name = "RapierBarLeft", attachTo = "RightHand", size = { 0.09, 0.09, 0.8 }, offset = { -0.3, -0.16, -0.1 }, rotation = { 0, 0, 22 }, color = GOLD, material = "Metal" },
		{ name = "RapierQuillon", attachTo = "RightHand", size = { 1.16, 0.1, 0.11 }, offset = { 0, 0, -0.28 }, color = GOLD, material = "Metal" },
		{ name = "RapierKnuckle", attachTo = "RightHand", size = { 0.1, 0.62, 0.62 }, offset = { 0.42, 0, 0.08 }, rotation = { 0, 0, 14 }, color = GOLD, material = "Metal", shape = "Cylinder" },

		-- The blade. Long, and barely there.
		{ name = "RapierForte", attachTo = "RightHand", size = { 0.1, 0.16, 1.5 }, offset = { 0, 0, -1.4 }, color = STEEL, material = "Metal", glow = true },
		{ name = "RapierBlade", attachTo = "RightHand", size = { 0.08, 0.13, 2.6 }, offset = { 0, 0, -3.4 }, color = STEEL, material = "Metal" },
		{ name = "RapierFoible", attachTo = "RightHand", size = { 0.06, 0.1, 0.9 }, offset = { 0, 0, -5.1 }, color = STEEL, material = "Metal" },
		{ name = "RapierPoint", attachTo = "RightHand", size = { 0.05, 0.06, 0.3 }, offset = { 0, 0, -5.68 }, color = BONE, material = "Metal" },
		inlay("RapierInlay", "RightHand", { 0.11, 0.04, 1.2 }, { 0, 0, -1.4 }, Palette.CRIMSON),
	}
end

--[[ Longbow: a recurve, held in the off hand ]]

-- Held left so the right hand keeps the draw, which is also what leaves the
-- right arm free to be animated pulling a string that is not simulated. The
-- limbs are built as three straight segments each rather than a curve: at this
-- scale the eye reads the kink as a recurve and nothing is lost.
local function longbow(): { PieceDef }
	local hand = "LeftHand"
	local function limb(name: string, sign: number): { PieceDef }
		return {
			{ name = `Bow{name}Inner`, attachTo = hand, size = { 0.2, 1.5, 0.3 }, offset = { 0, sign * 0.9, -0.1 }, rotation = { sign * 6, 0, 0 }, color = Palette.shade(OAK, 0.9), material = "Wood" },
			{ name = `Bow{name}Outer`, attachTo = hand, size = { 0.18, 1.4, 0.26 }, offset = { 0, sign * 2.2, 0.24 }, rotation = { sign * 20, 0, 0 }, color = Palette.shade(OAK, 0.9), material = "Wood" },
			{ name = `Bow{name}Recurve`, attachTo = hand, size = { 0.16, 0.7, 0.22 }, offset = { 0, sign * 3.0, -0.1 }, rotation = { sign * -34, 0, 0 }, color = Palette.shade(OAK, 0.75), material = "Wood" },
			{ name = `Bow{name}Nock`, attachTo = hand, size = { 0.14, 0.2, 0.18 }, offset = { 0, sign * 3.3, -0.36 }, color = IRON, material = "Metal" },
			{ name = `Bow{name}Band`, attachTo = hand, size = { 0.22, 0.14, 0.32 }, offset = { 0, sign * 1.62, 0.06 }, color = BRIGHT_GOLD, material = "Metal" },
		}
	end

	local body: { PieceDef } = {
		{ name = "BowRiser", attachTo = hand, size = { 0.26, 1.1, 0.42 }, offset = { 0, 0, -0.06 }, color = Palette.shade(OAK, 0.7), material = "Wood" },
		{ name = "BowGrip", attachTo = hand, size = { 0.6, 0.3, 0.3 }, offset = { 0, 0, -0.06 }, rotation = UPRIGHT, color = DARK_LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = "BowShelf", attachTo = hand, size = { 0.34, 0.12, 0.3 }, offset = { 0, 0.34, -0.22 }, color = IRON, material = "Metal" },
		jewel("BowRiserStone", hand, { 0, -0.34, -0.26 }, 0.16, Palette.MOSS),

		-- The string, from nock to nock, passing in front of the grip.
		{ name = "BowString", attachTo = hand, size = { 0.05, 6.7, 0.05 }, offset = { 0, 0, -0.36 }, color = Palette.ROPE, material = "Fabric" },
		{ name = "BowServing", attachTo = hand, size = { 0.08, 0.6, 0.08 }, offset = { 0, 0, -0.36 }, color = Palette.LINEN, material = "Fabric" },

		-- A nocked arrow, so the weapon is never seen empty.
		{ name = "ArrowShaft", attachTo = hand, size = { 0.07, 0.07, 2.6 }, offset = { 0, 0.02, -1.4 }, color = Palette.shade(OAK, 1.1), material = "Wood", shape = "Cylinder" },
		{ name = "ArrowHead", attachTo = hand, size = { 0.1, 0.2, 0.4 }, offset = { 0, 0.02, -2.86 }, color = STEEL, material = "Metal", glow = true },
		{ name = "ArrowFletchRight", attachTo = hand, size = { 0.04, 0.24, 0.5 }, offset = { 0.08, 0.02, -0.34 }, rotation = { 0, 0, -26 }, color = Palette.CRIMSON, material = "Fabric" },
		{ name = "ArrowFletchLeft", attachTo = hand, size = { 0.04, 0.24, 0.5 }, offset = { -0.08, 0.02, -0.34 }, rotation = { 0, 0, 26 }, color = Palette.CRIMSON, material = "Fabric" },
		{ name = "ArrowNock", attachTo = hand, size = { 0.09, 0.12, 0.14 }, offset = { 0, 0.02, -0.08 }, color = IRON },

		-- The quiver, on the back where it belongs rather than on the bow.
		{ name = "Quiver", attachTo = "UpperTorso", size = { 0.62, 1.9, 0.62 }, offset = { -0.7, 0.1, 0.72 }, rotation = { 14, 0, -18 }, color = LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = "QuiverRim", attachTo = "UpperTorso", size = { 0.7, 0.18, 0.7 }, offset = { -0.86, 1.02, 0.6 }, rotation = { 14, 0, -18 }, color = IRON, material = "Metal", shape = "Cylinder" },
		{ name = "QuiverArrowA", attachTo = "UpperTorso", size = { 0.06, 0.8, 0.06 }, offset = { -0.9, 1.4, 0.56 }, rotation = { 14, 0, -18 }, color = Palette.shade(OAK, 1.1) },
		{ name = "QuiverArrowB", attachTo = "UpperTorso", size = { 0.06, 0.9, 0.06 }, offset = { -0.78, 1.44, 0.68 }, rotation = { 14, 0, -24 }, color = Palette.shade(OAK, 1.1) },
		{ name = "QuiverFletching", attachTo = "UpperTorso", size = { 0.3, 0.3, 0.3 }, offset = { -0.86, 1.8, 0.56 }, color = Palette.CRIMSON, material = "Fabric" },
	}

	return concat(body, limb("Upper", 1), limb("Lower", -1))
end

--[[ Arcane Focus: a caged stone that hangs in the hand ]]

-- The only weapon in the game with no blade and no haft. It is a held thing
-- rather than a wielded one, and the rings around it do the work a guard and
-- a fuller do elsewhere — they give the eye something to read the shape by.
local function focus(): { PieceDef }
	local hand = "RightHand"
	return {
		{ name = "FocusHandle", attachTo = hand, size = { 0.7, 0.26, 0.26 }, offset = { 0, 0, 0.16 }, rotation = ALONG_BLADE, color = DARK_LEATHER, material = "Fabric", shape = "Cylinder" },
		{ name = "FocusCollar", attachTo = hand, size = { 0.2, 0.42, 0.42 }, offset = { 0, 0, -0.24 }, rotation = ALONG_BLADE, color = BRIGHT_GOLD, material = "Metal", shape = "Cylinder" },

		-- Four claws holding the stone, off-centre so it does not read as a
		-- perfect sphere in a perfect cage.
		{ name = "FocusClawA", attachTo = hand, size = { 0.1, 0.1, 0.9 }, offset = { 0.3, 0.26, -0.72 }, rotation = { 0, -18, -22 }, color = GOLD, material = "Metal" },
		{ name = "FocusClawB", attachTo = hand, size = { 0.1, 0.1, 0.9 }, offset = { -0.3, 0.26, -0.72 }, rotation = { 0, 18, 22 }, color = GOLD, material = "Metal" },
		{ name = "FocusClawC", attachTo = hand, size = { 0.1, 0.1, 0.9 }, offset = { 0.3, -0.26, -0.72 }, rotation = { 0, -18, 22 }, color = GOLD, material = "Metal" },
		{ name = "FocusClawD", attachTo = hand, size = { 0.1, 0.1, 0.9 }, offset = { -0.3, -0.26, -0.72 }, rotation = { 0, 18, -22 }, color = GOLD, material = "Metal" },

		{ name = "FocusStone", attachTo = hand, size = { 1.15, 1.15, 1.15 }, offset = { 0, 0, -1.3 }, color = Palette.ARCANE, material = "Glass", shape = "Ball", transparency = 0.3, glow = true },
		{ name = "FocusCore", attachTo = hand, size = { 0.5, 0.5, 0.5 }, offset = { 0, 0, -1.3 }, color = Palette.ARCANE, material = "Neon", shape = "Ball" },

		-- Three rings on three axes. Nothing turns; the axes do the work.
		{ name = "FocusRingA", attachTo = hand, size = { 0.1, 1.7, 1.7 }, offset = { 0, 0, -1.3 }, rotation = ALONG_BLADE, color = BRIGHT_GOLD, material = "Metal", shape = "Cylinder" },
		{ name = "FocusRingB", attachTo = hand, size = { 0.09, 1.52, 1.52 }, offset = { 0, 0, -1.3 }, rotation = { 0, 0, 24 }, color = GOLD, material = "Metal", shape = "Cylinder" },
		{ name = "FocusRingC", attachTo = hand, size = { 0.09, 1.38, 1.38 }, offset = { 0, 0, -1.3 }, rotation = UPRIGHT, color = GOLD, material = "Metal", shape = "Cylinder" },

		-- Shards standing off the stone, which is what makes it read as held
		-- together by something rather than simply floating.
		{ name = "FocusShardTop", attachTo = hand, size = { 0.14, 0.44, 0.14 }, offset = { 0, 0.92, -1.3 }, rotation = { 0, 0, 12 }, color = Palette.ARCANE, material = "Neon" },
		{ name = "FocusShardRight", attachTo = hand, size = { 0.14, 0.14, 0.44 }, offset = { 0.9, -0.2, -1.3 }, rotation = { 0, 22, 0 }, color = Palette.ARCANE, material = "Neon" },
		{ name = "FocusShardLeft", attachTo = hand, size = { 0.14, 0.14, 0.4 }, offset = { -0.88, 0.24, -1.3 }, rotation = { 0, -22, 0 }, color = Palette.ARCANE, material = "Neon" },

		-- A tome chained to the wrist, because a Mage with nothing in the
		-- other hand looks unarmed rather than armed differently.
		{ name = "TomeCover", attachTo = "LeftLowerArm", size = { 0.24, 1.2, 0.9 }, offset = { -0.5, -0.1, 0 }, rotation = { 0, 0, -8 }, color = Palette.CRIMSON, material = "Fabric" },
		{ name = "TomePages", attachTo = "LeftLowerArm", size = { 0.2, 1.04, 0.78 }, offset = { -0.38, -0.1, 0 }, rotation = { 0, 0, -8 }, color = Palette.LINEN },
		{ name = "TomeClasp", attachTo = "LeftLowerArm", size = { 0.3, 0.2, 0.2 }, offset = { -0.44, -0.1, -0.44 }, color = BRIGHT_GOLD, material = "Metal" },
		jewel("TomeStone", "LeftLowerArm", { -0.64, 0.24, 0 }, 0.18, Palette.ARCANE),
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

	Greataxe = {
		glowColor = Palette.TORCH_EMBER,
		pieces = greataxe(),
	},

	Rapier = {
		glowColor = Palette.CRIMSON,
		pieces = rapier(),
	},

	Bow = {
		glowColor = Palette.MOSS,
		pieces = longbow(),
	},

	Focus = {
		glowColor = Palette.ARCANE,
		pieces = focus(),
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
