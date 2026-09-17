--!strict
-- What every rig is made of. Pure data — no Roblox API.
--
-- All rigs share one R15-style skeleton: the same 15 part names and the same
-- joint names as a default Roblox R15 avatar. That shared vocabulary is what
-- lets one animation system drive enemies and players alike, and lets any
-- animation refined in the Animation Editor play on any rig.
--
-- A rig's look is a style over that skeleton: colours, materials, how thick
-- each part is, and welded decorations (ribs, a helm, a sword). Only width and
-- depth can change — never a part's length — so the joints always line up.
-- Real meshes can later replace these parts one-for-one under the same names.
--
-- Coordinates are in rig space: the origin is the centre of the enemy's
-- hitbox (HumanoidRootPart, ROOT_SIZE), +Y is up, -Z is forward, +X is the
-- rig's right. The feet touch the bottom of the hitbox. A decoration's offset
-- is from the centre of the part it hangs on, and its rotation (degrees) is
-- applied after — which is what lets horns sweep back, pauldrons slope off a
-- shoulder, and a tabard hang crooked.
--
-- Colours come from Palette. Every enemy is built from the same bone, iron and
-- rot as the dungeon around it; what separates them is silhouette, not hue.

local Palette = require(script.Parent.Palette)

local RigDefs = {}

export type Vec3 = { number }
export type RGB = { number }

RigDefs.ROOT_SIZE = { 4, 6, 4 }

export type BodyPart = {
	name: string,
	-- The part this one hangs from, and the Motor6D joining them. The joint
	-- lives inside this part, as in a Roblox R15 avatar.
	parent: string,
	joint: string,
	size: Vec3,
	-- Centre of the part, and where it pivots, in rig space.
	center: Vec3,
	pivot: Vec3,
}

-- Parents always come before their children, so building in this order never
-- references a part that doesn't exist yet.
RigDefs.SKELETON = {
	{ name = "LowerTorso", parent = "HumanoidRootPart", joint = "Root", size = { 2, 0.6, 1 }, center = { 0, 0, 0 }, pivot = { 0, 0, 0 } },
	{ name = "UpperTorso", parent = "LowerTorso", joint = "Waist", size = { 2, 1.5, 1 }, center = { 0, 1.05, 0 }, pivot = { 0, 0.3, 0 } },
	{ name = "Head", parent = "UpperTorso", joint = "Neck", size = { 1.2, 1.2, 1.2 }, center = { 0, 2.4, 0 }, pivot = { 0, 1.8, 0 } },

	{ name = "RightUpperArm", parent = "UpperTorso", joint = "RightShoulder", size = { 0.8, 1.2, 0.8 }, center = { 1.4, 1.2, 0 }, pivot = { 1.4, 1.6, 0 } },
	{ name = "RightLowerArm", parent = "RightUpperArm", joint = "RightElbow", size = { 0.7, 1.1, 0.7 }, center = { 1.4, 0.05, 0 }, pivot = { 1.4, 0.6, 0 } },
	{ name = "RightHand", parent = "RightLowerArm", joint = "RightWrist", size = { 0.7, 0.5, 0.7 }, center = { 1.4, -0.75, 0 }, pivot = { 1.4, -0.5, 0 } },

	{ name = "LeftUpperArm", parent = "UpperTorso", joint = "LeftShoulder", size = { 0.8, 1.2, 0.8 }, center = { -1.4, 1.2, 0 }, pivot = { -1.4, 1.6, 0 } },
	{ name = "LeftLowerArm", parent = "LeftUpperArm", joint = "LeftElbow", size = { 0.7, 1.1, 0.7 }, center = { -1.4, 0.05, 0 }, pivot = { -1.4, 0.6, 0 } },
	{ name = "LeftHand", parent = "LeftLowerArm", joint = "LeftWrist", size = { 0.7, 0.5, 0.7 }, center = { -1.4, -0.75, 0 }, pivot = { -1.4, -0.5, 0 } },

	{ name = "RightUpperLeg", parent = "LowerTorso", joint = "RightHip", size = { 0.9, 1.2, 0.9 }, center = { 0.5, -0.9, 0 }, pivot = { 0.5, -0.4, 0 } },
	{ name = "RightLowerLeg", parent = "RightUpperLeg", joint = "RightKnee", size = { 0.8, 1.1, 0.8 }, center = { 0.5, -2.05, 0 }, pivot = { 0.5, -1.5, 0 } },
	{ name = "RightFoot", parent = "RightLowerLeg", joint = "RightAnkle", size = { 0.8, 0.4, 1.2 }, center = { 0.5, -2.8, -0.15 }, pivot = { 0.5, -2.6, 0 } },

	{ name = "LeftUpperLeg", parent = "LowerTorso", joint = "LeftHip", size = { 0.9, 1.2, 0.9 }, center = { -0.5, -0.9, 0 }, pivot = { -0.5, -0.4, 0 } },
	{ name = "LeftLowerLeg", parent = "LeftUpperLeg", joint = "LeftKnee", size = { 0.8, 1.1, 0.8 }, center = { -0.5, -2.05, 0 }, pivot = { -0.5, -1.5, 0 } },
	{ name = "LeftFoot", parent = "LeftLowerLeg", joint = "LeftAnkle", size = { 0.8, 0.4, 1.2 }, center = { -0.5, -2.8, -0.15 }, pivot = { -0.5, -2.6, 0 } },
} :: { BodyPart }

export type PartStyle = {
	color: RGB,
	-- An Enum.Material name.
	material: string?,
	-- Multiplies the part's width (X) and depth (Z). Length is fixed.
	width: number?,
	depth: number?,
}

export type Decoration = {
	name: string,
	attachTo: string,
	size: Vec3,
	-- Relative to the centre of the part it's attached to.
	offset: Vec3,
	-- Degrees, applied after the offset. A piece with no rotation sits square
	-- to its part; a rotation is what lets a horn sweep back, a pauldron slope
	-- off a shoulder, or a strap cross a chest on the diagonal.
	rotation: Vec3?,
	color: RGB,
	material: string?,
	-- An Enum.PartType name; Block when unset.
	shape: string?,
	transparency: number?,
}

export type RigStyle = {
	displayName: string,
	-- Uniform size multiplier for the whole rig: parts, joints, decorations and
	-- the hitbox. Animations stay authored at size 1; their offsets in studs
	-- are scaled when played. 1 when unset.
	scale: number?,
	-- Style for any part not listed in `parts`.
	default: PartStyle,
	parts: { [string]: PartStyle },
	decorations: { Decoration },
}

local BONE = Palette.BONE
local OLD_BONE = Palette.OLD_BONE
local IRON = Palette.IRON
local RUST = Palette.RUST
local STEEL = Palette.STEEL
local DARK_STEEL = Palette.DARK_STEEL
local GOLD = Palette.GOLD
local VOID = Palette.VOID
local ZOMBIE_SKIN = Palette.ZOMBIE_SKIN
local ROT_FLESH = Palette.ROT_FLESH
local SPITTER_HIDE = Palette.SPITTER_HIDE
local WOOD = Palette.OAK
local TATTERED = Palette.TATTERED

-- Both sides of a mirrored pair at once.
local function both(parts: { [string]: PartStyle }, suffix: string, style: PartStyle)
	parts[`Right{suffix}`] = style
	parts[`Left{suffix}`] = style
end

--[[ Training Dummy: a pell — a post bound in straw and sackcloth ]]

local function dummyStyle(): RigStyle
	local sack = Palette.LINEN
	local rope = Palette.ROPE

	-- A rope binding round the post, at `y` on the part it wraps.
	local function binding(name: string, attachTo: string, y: number, width: number): Decoration
		return { name = name, attachTo = attachTo, size = { width, 0.18, width }, offset = { 0, y, 0 }, color = rope, material = "Fabric" }
	end

	-- Straw bursting out of a seam, angled so it doesn't read as a spike.
	local function straw(name: string, attachTo: string, offset: Vec3, rotation: Vec3): Decoration
		return { name = name, attachTo = attachTo, size = { 0.5, 0.45, 0.5 }, offset = offset, rotation = rotation, color = Palette.shade(sack, 0.9), material = "Fabric" }
	end

	return {
		displayName = "Training Dummy",
		default = { color = WOOD, material = "Wood" },
		parts = {
			Head = { color = sack, material = "Fabric" },
			UpperTorso = { color = sack, material = "Fabric", width = 1.05, depth = 1.05 },
		},
		decorations = {
			binding("BindingChest", "UpperTorso", 0.5, 2.2),
			binding("BindingWaist", "UpperTorso", -0.55, 2.15),
			binding("BindingNeck", "Head", -0.62, 1.3),
			binding("BindingArmRight", "RightUpperArm", 0.3, 0.95),
			binding("BindingArmLeft", "LeftUpperArm", 0.3, 0.95),

			straw("StrawNeck", "Head", { 0, -0.5, 0.4 }, { 30, 0, 0 }),
			straw("StrawShoulder", "UpperTorso", { 0.9, 0.6, 0 }, { 0, 0, -35 }),
			straw("StrawWristRight", "RightHand", { 0, -0.2, 0 }, { 0, 0, 20 }),
			straw("StrawWristLeft", "LeftHand", { 0, -0.2, 0 }, { 0, 0, -20 }),

			-- A target painted on the chest, off-centre and worn through.
			{ name = "TargetOuter", attachTo = "UpperTorso", size = { 1.3, 1.3, 0.05 }, offset = { 0.05, 0, -0.55 }, color = Palette.CRIMSON },
			{ name = "TargetMiddle", attachTo = "UpperTorso", size = { 0.85, 0.85, 0.06 }, offset = { 0.05, 0, -0.56 }, color = sack, material = "Fabric" },
			{ name = "TargetInner", attachTo = "UpperTorso", size = { 0.42, 0.42, 0.07 }, offset = { 0.05, 0, -0.57 }, color = Palette.CRIMSON },

			-- A sack head: a crooked stitched mouth and two button eyes.
			{ name = "Stitching", attachTo = "Head", size = { 0.75, 0.08, 0.05 }, offset = { 0, -0.22, -0.61 }, rotation = { 0, 0, 7 }, color = Palette.shade(sack, 0.5) },
			{ name = "EyeRight", attachTo = "Head", size = { 0.16, 0.16, 0.05 }, offset = { 0.25, 0.14, -0.61 }, color = VOID },
			{ name = "EyeLeft", attachTo = "Head", size = { 0.16, 0.16, 0.05 }, offset = { -0.25, 0.18, -0.61 }, color = VOID },

			-- Old blade marks in the post, and the iron ring it hangs from.
			{ name = "GashHigh", attachTo = "UpperTorso", size = { 0.9, 0.09, 0.05 }, offset = { -0.4, 0.42, -0.55 }, rotation = { 0, 0, -28 }, color = Palette.shade(sack, 0.55), material = "Fabric" },
			{ name = "GashLow", attachTo = "UpperTorso", size = { 0.7, 0.09, 0.05 }, offset = { 0.3, -0.5, -0.55 }, rotation = { 0, 0, 34 }, color = Palette.shade(sack, 0.55), material = "Fabric" },
			{ name = "HangingRing", attachTo = "Head", size = { 0.1, 0.42, 0.42 }, offset = { 0, 0.72, 0 }, rotation = { 0, 90, 0 }, color = RUST, material = "Metal", shape = "Cylinder" },
		},
	}
end

--[[ Skeleton Warrior: a dead soldier still in his kit ]]

-- Thin bone limbs and a hollow ribcage, wearing a rusted helm and a rotted
-- tabard, carrying a notched falchion and a battered buckler. The armour is
-- what separates him from a pile of bones at a glance.
local function skeletonStyle(): RigStyle
	local parts: { [string]: PartStyle } = {
		-- The spine: the torso is mostly air, and the ribs are decorations.
		UpperTorso = { color = OLD_BONE, width = 0.3, depth = 0.4 },
		LowerTorso = { color = OLD_BONE, width = 0.8, depth = 0.6 },
		Head = { color = BONE, width = 0.95, depth = 0.95 },
	}
	for _, suffix in { "UpperArm", "LowerArm", "UpperLeg", "LowerLeg" } do
		both(parts, suffix, { color = OLD_BONE, width = 0.45, depth = 0.45 })
	end
	both(parts, "Hand", { color = OLD_BONE, width = 0.7, depth = 0.7 })
	both(parts, "Foot", { color = OLD_BONE, width = 0.7, depth = 0.9 })

	-- A rib, narrowing down the cage.
	local function rib(name: string, y: number, width: number, depth: number): Decoration
		return { name = name, attachTo = "UpperTorso", size = { width, 0.15, depth }, offset = { 0, y, 0 }, color = OLD_BONE }
	end

	return {
		displayName = "Skeleton Warrior",
		default = { color = OLD_BONE },
		parts = parts,
		decorations = {
			-- A ribcage that tapers, with a sternum down the front.
			rib("RibOne", 0.56, 1.75, 0.85),
			rib("RibTwo", 0.26, 1.8, 0.88),
			rib("RibThree", -0.04, 1.7, 0.84),
			rib("RibFour", -0.34, 1.5, 0.76),
			rib("RibFive", -0.6, 1.25, 0.66),
			{ name = "Sternum", attachTo = "UpperTorso", size = { 0.3, 1.5, 0.12 }, offset = { 0, -0.02, -0.4 }, color = BONE },
			{ name = "CollarRight", attachTo = "UpperTorso", size = { 0.9, 0.14, 0.14 }, offset = { 0.5, 0.72, -0.2 }, rotation = { 0, 0, -12 }, color = BONE },
			{ name = "CollarLeft", attachTo = "UpperTorso", size = { 0.9, 0.14, 0.14 }, offset = { -0.5, 0.72, -0.2 }, rotation = { 0, 0, 12 }, color = BONE },
			{ name = "Pelvis", attachTo = "LowerTorso", size = { 1.45, 0.55, 0.8 }, offset = { 0, -0.12, 0 }, color = OLD_BONE },

			-- A rotted tabard hanging off him, still showing its colour.
			{ name = "Tabard", attachTo = "UpperTorso", size = { 1.05, 1.9, 0.1 }, offset = { 0, -0.35, -0.42 }, rotation = { 0, 0, 4 }, color = Palette.CRIMSON, material = "Fabric" },
			{ name = "TabardTear", attachTo = "UpperTorso", size = { 0.45, 0.7, 0.1 }, offset = { -0.38, -1.25, -0.42 }, rotation = { 0, 0, -16 }, color = Palette.shade(Palette.CRIMSON, 0.7), material = "Fabric" },
			{ name = "Belt", attachTo = "LowerTorso", size = { 1.5, 0.28, 0.9 }, offset = { 0, 0.05, 0 }, color = Palette.DARK_LEATHER, material = "Fabric" },
			{ name = "BeltBuckle", attachTo = "LowerTorso", size = { 0.3, 0.3, 0.1 }, offset = { 0, 0.05, -0.48 }, color = RUST, material = "Metal" },

			-- A rusted kettle helm with a nose guard, and what's under it.
			{ name = "HelmCap", attachTo = "Head", size = { 1.3, 0.62, 1.3 }, offset = { 0, 0.42, 0 }, color = RUST, material = "Metal" },
			{ name = "HelmBrim", attachTo = "Head", size = { 1.5, 0.16, 1.5 }, offset = { 0, 0.14, 0 }, rotation = { 6, 0, 0 }, color = Palette.shade(RUST, 0.85), material = "Metal" },
			{ name = "HelmNasal", attachTo = "Head", size = { 0.18, 0.62, 0.12 }, offset = { 0, -0.02, -0.63 }, color = RUST, material = "Metal" },
			{ name = "HelmDent", attachTo = "Head", size = { 0.34, 0.3, 0.1 }, offset = { 0.45, 0.45, -0.6 }, rotation = { 0, 0, 22 }, color = Palette.shade(RUST, 0.7), material = "Metal" },
			{ name = "EyeRight", attachTo = "Head", size = { 0.28, 0.24, 0.05 }, offset = { 0.27, 0.02, -0.6 }, color = VOID },
			{ name = "EyeLeft", attachTo = "Head", size = { 0.28, 0.24, 0.05 }, offset = { -0.27, 0.02, -0.6 }, color = VOID },
			{ name = "EyeGlowRight", attachTo = "Head", size = { 0.14, 0.1, 0.04 }, offset = { 0.27, 0.02, -0.62 }, color = Palette.EYE_GLOW, material = "Neon" },
			{ name = "EyeGlowLeft", attachTo = "Head", size = { 0.14, 0.1, 0.04 }, offset = { -0.27, 0.02, -0.62 }, color = Palette.EYE_GLOW, material = "Neon" },
			{ name = "Cheekbones", attachTo = "Head", size = { 0.82, 0.16, 0.08 }, offset = { 0, -0.2, -0.58 }, color = BONE },
			{ name = "Teeth", attachTo = "Head", size = { 0.62, 0.14, 0.06 }, offset = { 0, -0.4, -0.59 }, color = BONE },
			{ name = "Jaw", attachTo = "Head", size = { 0.68, 0.16, 0.5 }, offset = { 0, -0.56, -0.36 }, rotation = { -10, 0, 0 }, color = OLD_BONE },

			-- One pauldron: he lost the other a long time ago.
			{ name = "PauldronLeft", attachTo = "LeftUpperArm", size = { 0.95, 0.42, 0.95 }, offset = { -0.12, 0.5, 0 }, rotation = { 0, 0, 14 }, color = RUST, material = "Metal" },
			{ name = "PauldronLeftRidge", attachTo = "LeftUpperArm", size = { 1.0, 0.14, 0.4 }, offset = { -0.12, 0.7, 0 }, rotation = { 0, 0, 14 }, color = Palette.shade(RUST, 0.8), material = "Metal" },
			{ name = "BracerRight", attachTo = "RightLowerArm", size = { 0.6, 0.65, 0.6 }, offset = { 0, 0.1, 0 }, color = RUST, material = "Metal" },

			-- A notched falchion: heavier toward the tip, so it reads as a
			-- chopping blade rather than a needle.
			{ name = "SwordGrip", attachTo = "RightHand", size = { 0.16, 0.16, 0.6 }, offset = { 0, -0.05, 0.05 }, color = Palette.DARK_LEATHER, material = "Fabric" },
			{ name = "SwordPommel", attachTo = "RightHand", size = { 0.24, 0.24, 0.14 }, offset = { 0, -0.05, 0.4 }, color = RUST, material = "Metal" },
			{ name = "Crossguard", attachTo = "RightHand", size = { 0.85, 0.14, 0.16 }, offset = { 0, -0.05, -0.26 }, rotation = { 0, 0, 8 }, color = RUST, material = "Metal" },
			{ name = "Blade", attachTo = "RightHand", size = { 0.11, 0.28, 2.0 }, offset = { 0, -0.05, -1.3 }, color = DARK_STEEL, material = "Metal" },
			{ name = "BladeBelly", attachTo = "RightHand", size = { 0.11, 0.42, 1.1 }, offset = { 0, 0.02, -2.75 }, color = DARK_STEEL, material = "Metal" },
			{ name = "BladeEdge", attachTo = "RightHand", size = { 0.13, 0.08, 2.9 }, offset = { 0, -0.14, -1.85 }, color = STEEL, material = "Metal" },
			{ name = "BladeNotch", attachTo = "RightHand", size = { 0.15, 0.16, 0.16 }, offset = { 0, -0.16, -2.3 }, color = OLD_BONE },
			{ name = "BladeTip", attachTo = "RightHand", size = { 0.1, 0.2, 0.44 }, offset = { 0, 0.1, -3.45 }, color = DARK_STEEL, material = "Metal" },

			-- A buckler strapped to the off hand.
			{ name = "Buckler", attachTo = "LeftLowerArm", size = { 0.18, 1.35, 1.35 }, offset = { -0.45, -0.1, 0 }, color = RUST, material = "Metal" },
			{ name = "BucklerRim", attachTo = "LeftLowerArm", size = { 0.12, 1.55, 1.55 }, offset = { -0.44, -0.1, 0 }, color = IRON, material = "Metal", shape = "Cylinder" },
			{ name = "BucklerBoss", attachTo = "LeftLowerArm", size = { 0.42, 0.42, 0.42 }, offset = { -0.58, -0.1, 0 }, color = Palette.shade(RUST, 1.15), material = "Metal", shape = "Ball" },
		},
	}
end

--[[ Shambler: a villager a long way into rotting ]]

-- Hunched, lopsided and unarmed: the threat reads from the hands, so it gets
-- long clawed fingers and a jaw that no longer closes. A chain still locked to
-- one ankle says what it was before it got up again.
local function shamblerStyle(): RigStyle
	local shirt = { 92, 58, 46 }
	local trousers = { 58, 64, 82 }

	local parts: { [string]: PartStyle } = {
		UpperTorso = { color = shirt, material = "Fabric" },
		LowerTorso = { color = trousers, material = "Fabric" },
		Head = { color = ZOMBIE_SKIN },
	}
	both(parts, "UpperLeg", { color = trousers, material = "Fabric" })
	both(parts, "LowerLeg", { color = ZOMBIE_SKIN })
	both(parts, "Foot", { color = { 40, 35, 30 } })
	both(parts, "UpperArm", { color = shirt, material = "Fabric" })
	both(parts, "LowerArm", { color = ZOMBIE_SKIN, width = 0.9, depth = 0.9 })

	-- A clawed finger off the front of a hand.
	local function claw(name: string, hand: string, x: number, rotation: Vec3): Decoration
		return { name = name, attachTo = hand, size = { 0.12, 0.12, 0.55 }, offset = { x, -0.12, -0.42 }, rotation = rotation, color = Palette.shade(ZOMBIE_SKIN, 0.7) }
	end

	return {
		displayName = "Shambler",
		default = { color = ZOMBIE_SKIN },
		parts = parts,
		decorations = {
			-- A hood fallen back off the head, and the head under it.
			{ name = "Hood", attachTo = "UpperTorso", size = { 1.3, 0.8, 0.9 }, offset = { 0, 0.6, 0.55 }, rotation = { -24, 0, 0 }, color = TATTERED, material = "Fabric" },
			{ name = "EyeRight", attachTo = "Head", size = { 0.22, 0.14, 0.05 }, offset = { 0.26, 0.12, -0.61 }, rotation = { 0, 0, -8 }, color = Palette.EYE_GLOW, material = "Neon" },
			{ name = "EyeLeft", attachTo = "Head", size = { 0.22, 0.14, 0.05 }, offset = { -0.26, 0.16, -0.61 }, rotation = { 0, 0, 12 }, color = Palette.EYE_GLOW, material = "Neon" },
			{ name = "BrowRight", attachTo = "Head", size = { 0.3, 0.1, 0.06 }, offset = { 0.26, 0.26, -0.6 }, rotation = { 0, 0, -18 }, color = Palette.shade(ZOMBIE_SKIN, 0.7) },
			{ name = "BrowLeft", attachTo = "Head", size = { 0.3, 0.1, 0.06 }, offset = { -0.26, 0.3, -0.6 }, rotation = { 0, 0, 18 }, color = Palette.shade(ZOMBIE_SKIN, 0.7) },
			-- A jaw hanging open, with the throat dark behind it.
			{ name = "Mouth", attachTo = "Head", size = { 0.5, 0.34, 0.06 }, offset = { 0, -0.3, -0.6 }, color = VOID },
			{ name = "Jaw", attachTo = "Head", size = { 0.56, 0.2, 0.42 }, offset = { 0, -0.52, -0.4 }, rotation = { -26, 0, 0 }, color = ZOMBIE_SKIN },
			{ name = "Teeth", attachTo = "Head", size = { 0.44, 0.09, 0.05 }, offset = { 0, -0.18, -0.62 }, color = Palette.LINEN },

			-- The shirt has rotted through over the ribs.
			{ name = "RibExposed", attachTo = "UpperTorso", size = { 0.85, 0.13, 0.12 }, offset = { 0.35, 0.18, -0.52 }, rotation = { 0, 0, -8 }, color = Palette.LINEN },
			{ name = "RibExposedLower", attachTo = "UpperTorso", size = { 0.75, 0.13, 0.12 }, offset = { 0.33, -0.12, -0.52 }, rotation = { 0, 0, -8 }, color = Palette.LINEN },
			{ name = "Wound", attachTo = "UpperTorso", size = { 0.55, 0.62, 0.08 }, offset = { 0.34, 0.03, -0.51 }, rotation = { 0, 0, 14 }, color = Palette.VISCERA },
			{ name = "ShirtFlap", attachTo = "UpperTorso", size = { 0.7, 0.72, 0.09 }, offset = { -0.5, -0.7, -0.5 }, rotation = { 0, 0, 22 }, color = shirt, material = "Fabric" },
			{ name = "ShirtFlapBack", attachTo = "UpperTorso", size = { 0.6, 0.6, 0.09 }, offset = { 0.4, -0.78, 0.5 }, rotation = { 0, 0, -18 }, color = Palette.shade(shirt, 0.8), material = "Fabric" },

			claw("ClawRightOuter", "RightHand", 0.2, { -18, 0, 0 }),
			claw("ClawRightInner", "RightHand", -0.02, { -8, 0, 0 }),
			claw("ClawRightThumb", "RightHand", -0.22, { -14, 0, 22 }),
			claw("ClawLeftOuter", "LeftHand", -0.2, { -18, 0, 0 }),
			claw("ClawLeftInner", "LeftHand", 0.02, { -8, 0, 0 }),
			claw("ClawLeftThumb", "LeftHand", 0.22, { -14, 0, -22 }),

			-- Still shackled. The chain hangs from the cuff and goes nowhere.
			{ name = "Shackle", attachTo = "RightLowerLeg", size = { 0.72, 0.26, 0.72 }, offset = { 0, -0.42, 0 }, color = RUST, material = "Metal" },
			{ name = "ChainLinkHigh", attachTo = "RightLowerLeg", size = { 0.14, 0.3, 0.14 }, offset = { 0.26, -0.58, 0.16 }, rotation = { 20, 0, 24 }, color = IRON, material = "Metal" },
			{ name = "ChainLinkLow", attachTo = "RightLowerLeg", size = { 0.14, 0.3, 0.14 }, offset = { 0.36, -0.84, 0.3 }, rotation = { 34, 0, 40 }, color = IRON, material = "Metal" },
			{ name = "TrouserTear", attachTo = "LeftUpperLeg", size = { 0.5, 0.55, 0.1 }, offset = { -0.3, -0.5, -0.45 }, rotation = { 0, 0, -20 }, color = trousers, material = "Fabric" },
		},
	}
end

--[[ Spitter: a bloated sac of acid on spindly legs ]]

-- Everything about it is a warning: the sac it fires from is the biggest thing
-- on it, lit from inside, and the limbs are too thin to be anything but fast.
local function spitterStyle(): RigStyle
	local parts: { [string]: PartStyle } = {
		UpperTorso = { color = SPITTER_HIDE, width = 1.2, depth = 1.6 },
		LowerTorso = { color = SPITTER_HIDE, width = 1.1, depth = 1.4 },
		Head = { color = SPITTER_HIDE, width = 0.8, depth = 0.9 },
	}
	for _, suffix in { "UpperArm", "LowerArm", "UpperLeg", "LowerLeg" } do
		both(parts, suffix, { color = Palette.shade(SPITTER_HIDE, 0.85), width = 0.6, depth = 0.6 })
	end
	both(parts, "Hand", { color = ROT_FLESH, width = 0.8, depth = 0.8 })
	both(parts, "Foot", { color = ROT_FLESH, width = 0.75, depth = 1.0 })

	-- A spine down the back, leaning further back the higher it sits.
	local function spine(name: string, y: number, length: number, tilt: number): Decoration
		return { name = name, attachTo = "UpperTorso", size = { 0.16, length, 0.16 }, offset = { 0, y, 0.72 }, rotation = { tilt, 0, 0 }, color = Palette.LINEN }
	end

	return {
		displayName = "Spitter",
		default = { color = SPITTER_HIDE },
		parts = parts,
		decorations = {
			-- The acid sac: the biggest thing on it, lit from inside and left
			-- unskinned so the glow carries at the range it fights from. It
			-- rides high on the back, breaking the silhouette above the
			-- shoulders — the tell that this one shoots.
			{ name = "AcidSac", attachTo = "UpperTorso", size = { 2.2, 2.2, 2.2 }, offset = { 0, 0.5, 1.15 }, color = Palette.ACID, material = "Neon", shape = "Ball", transparency = 0.3 },
			{ name = "AcidSacLower", attachTo = "UpperTorso", size = { 1.5, 1.5, 1.5 }, offset = { 0, -0.5, 0.95 }, color = Palette.ACID, material = "Neon", shape = "Ball", transparency = 0.35 },
			{ name = "SacRight", attachTo = "RightUpperArm", size = { 0.75, 0.75, 0.75 }, offset = { 0.22, 0.42, 0.25 }, color = Palette.ACID, material = "Neon", shape = "Ball", transparency = 0.4 },
			{ name = "SacLeft", attachTo = "LeftUpperArm", size = { 0.75, 0.75, 0.75 }, offset = { -0.22, 0.42, 0.25 }, color = Palette.ACID, material = "Neon", shape = "Ball", transparency = 0.4 },
			-- Veins carrying it forward to the mouth.
			{ name = "SacVeinRight", attachTo = "UpperTorso", size = { 0.16, 1.5, 0.16 }, offset = { 0.42, 0.2, 0.5 }, rotation = { 0, 0, -26 }, color = Palette.ACID, material = "Neon" },
			{ name = "SacVeinLeft", attachTo = "UpperTorso", size = { 0.16, 1.5, 0.16 }, offset = { -0.42, 0.2, 0.5 }, rotation = { 0, 0, 26 }, color = Palette.ACID, material = "Neon" },
			{ name = "Throat", attachTo = "UpperTorso", size = { 0.5, 0.9, 0.3 }, offset = { 0, 0.55, -0.5 }, color = Palette.ACID, material = "Neon", transparency = 0.25 },

			spine("SpineHigh", 0.68, 1.4, 38),
			spine("SpineMid", 0.14, 1.7, 28),
			spine("SpineLow", -0.46, 1.3, 18),
			{ name = "SpineRight", attachTo = "UpperTorso", size = { 0.14, 1.1, 0.14 }, offset = { 0.66, 0.4, 0.6 }, rotation = { 26, 0, -30 }, color = Palette.LINEN },
			{ name = "SpineLeft", attachTo = "UpperTorso", size = { 0.14, 1.1, 0.14 }, offset = { -0.66, 0.4, 0.6 }, rotation = { 26, 0, 30 }, color = Palette.LINEN },

			-- A maw that hangs open, dripping.
			{ name = "Maw", attachTo = "Head", size = { 0.62, 0.42, 0.07 }, offset = { 0, -0.18, -0.55 }, color = VOID },
			{ name = "MawGlow", attachTo = "Head", size = { 0.5, 0.26, 0.05 }, offset = { 0, -0.2, -0.57 }, color = Palette.ACID, material = "Neon" },
			{ name = "FangUpper", attachTo = "Head", size = { 0.4, 0.16, 0.05 }, offset = { 0, -0.02, -0.58 }, color = Palette.LINEN },
			{ name = "FangLower", attachTo = "Head", size = { 0.34, 0.14, 0.05 }, offset = { 0, -0.38, -0.58 }, color = Palette.LINEN },
			{ name = "Drip", attachTo = "Head", size = { 0.12, 0.3, 0.12 }, offset = { 0.14, -0.54, -0.5 }, rotation = { 0, 0, 10 }, color = Palette.ACID, material = "Neon", transparency = 0.2 },
			{ name = "EyeRight", attachTo = "Head", size = { 0.16, 0.16, 0.05 }, offset = { 0.22, 0.22, -0.56 }, color = VOID },
			{ name = "EyeLeft", attachTo = "Head", size = { 0.16, 0.16, 0.05 }, offset = { -0.22, 0.22, -0.56 }, color = VOID },
			{ name = "EyeRidge", attachTo = "Head", size = { 0.7, 0.12, 0.1 }, offset = { 0, 0.36, -0.52 }, rotation = { 14, 0, 0 }, color = Palette.shade(SPITTER_HIDE, 0.75) },
		},
	}
end

--[[ R15 Player: a plain stand-in for a real avatar ]]

-- Player animations are refined on it in the workbench; they play on real
-- avatars because the part and joint names match. Deliberately undecorated —
-- anything added here would be a lie about what a player actually looks like.
local function playerStyle(): RigStyle
	return {
		displayName = "R15 Player",
		default = { color = { 163, 162, 165 } },
		parts = {
			Head = { color = { 245, 205, 48 } },
		},
		decorations = {},
	}
end

--[[ The Hollow King: the dungeon's boss ]]

-- A crowned corpse in black iron, half again as big as anything else,
-- dragging a greatsword lit by the same cold fire as his eyes and his hall.
-- Everything gold on him is tarnished; everything that glows is that one blue.
local function hollowKingStyle(): RigStyle
	local ghost = Palette.GHOST_FIRE
	local trim = GOLD

	local parts: { [string]: PartStyle } = {
		UpperTorso = { color = IRON, material = "Metal", width = 1.15, depth = 1.1 },
		LowerTorso = { color = IRON, material = "Metal", width = 1.05 },
		Head = { color = BONE, width = 0.95, depth = 0.95 },
	}
	both(parts, "UpperArm", { color = IRON, material = "Metal", width = 1.1, depth = 1.1 })
	both(parts, "LowerArm", { color = OLD_BONE, width = 0.55, depth = 0.55 })
	both(parts, "Hand", { color = IRON, material = "Metal" })
	both(parts, "UpperLeg", { color = IRON, material = "Metal", width = 0.95, depth = 0.95 })
	both(parts, "LowerLeg", { color = OLD_BONE, width = 0.55, depth = 0.55 })
	both(parts, "Foot", { color = IRON, material = "Metal" })

	-- A crown spike, leaning out from the band.
	local function spike(name: string, offset: Vec3, rotation: Vec3, height: number): Decoration
		return { name = name, attachTo = "Head", size = { 0.16, height, 0.16 }, offset = offset, rotation = rotation, color = trim, material = "Metal" }
	end

	return {
		displayName = "The Hollow King",
		scale = 1.6,
		default = { color = OLD_BONE },
		parts = parts,
		decorations = {
			-- A crown grown into the skull, its spikes splayed outward.
			{ name = "CrownBand", attachTo = "Head", size = { 1.3, 0.28, 1.3 }, offset = { 0, 0.56, 0 }, color = trim, material = "Metal" },
			{ name = "CrownJewel", attachTo = "Head", size = { 0.2, 0.2, 0.08 }, offset = { 0, 0.56, -0.66 }, color = ghost, material = "Neon" },
			spike("CrownSpikeFront", { 0, 0.98, -0.5 }, { -18, 0, 0 }, 0.62),
			spike("CrownSpikeFrontRight", { 0.42, 0.96, -0.36 }, { -12, 0, -16 }, 0.5),
			spike("CrownSpikeFrontLeft", { -0.42, 0.96, -0.36 }, { -12, 0, 16 }, 0.5),
			spike("CrownSpikeRight", { 0.56, 0.94, 0 }, { 0, 0, -24 }, 0.46),
			spike("CrownSpikeLeft", { -0.56, 0.94, 0 }, { 0, 0, 24 }, 0.46),
			spike("CrownSpikeBack", { 0, 0.94, 0.5 }, { 16, 0, 0 }, 0.42),
			{ name = "CrownBroken", attachTo = "Head", size = { 0.16, 0.24, 0.16 }, offset = { 0.3, 0.78, 0.36 }, rotation = { 22, 0, -30 }, color = Palette.shade(trim, 0.7), material = "Metal" },

			-- The skull under it: deep sockets with cold fire in them.
			{ name = "BrowRidge", attachTo = "Head", size = { 1.0, 0.2, 0.14 }, offset = { 0, 0.26, -0.56 }, color = BONE },
			{ name = "EyeSocketRight", attachTo = "Head", size = { 0.34, 0.28, 0.08 }, offset = { 0.26, 0.06, -0.58 }, color = VOID },
			{ name = "EyeSocketLeft", attachTo = "Head", size = { 0.34, 0.28, 0.08 }, offset = { -0.26, 0.06, -0.58 }, color = VOID },
			{ name = "EyeRight", attachTo = "Head", size = { 0.22, 0.16, 0.05 }, offset = { 0.26, 0.06, -0.62 }, color = ghost, material = "Neon" },
			{ name = "EyeLeft", attachTo = "Head", size = { 0.22, 0.16, 0.05 }, offset = { -0.26, 0.06, -0.62 }, color = ghost, material = "Neon" },
			{ name = "Cheekbones", attachTo = "Head", size = { 0.86, 0.16, 0.1 }, offset = { 0, -0.2, -0.58 }, color = BONE },
			{ name = "Teeth", attachTo = "Head", size = { 0.66, 0.16, 0.06 }, offset = { 0, -0.42, -0.58 }, color = BONE },
			{ name = "Jaw", attachTo = "Head", size = { 0.72, 0.18, 0.5 }, offset = { 0, -0.58, -0.36 }, rotation = { -8, 0, 0 }, color = OLD_BONE },

			-- Layered pauldrons with a spike on each, sloping off the shoulder.
			{ name = "PauldronRight", attachTo = "RightUpperArm", size = { 1.15, 0.42, 1.15 }, offset = { 0.12, 0.56, 0 }, rotation = { 0, 0, -12 }, color = IRON, material = "Metal" },
			{ name = "PauldronRightLower", attachTo = "RightUpperArm", size = { 1.0, 0.3, 1.0 }, offset = { 0.16, 0.24, 0 }, rotation = { 0, 0, -16 }, color = Palette.shade(IRON, 1.3), material = "Metal" },
			{ name = "PauldronRightSpike", attachTo = "RightUpperArm", size = { 0.18, 0.7, 0.18 }, offset = { 0.4, 0.86, 0 }, rotation = { 0, 0, -38 }, color = trim, material = "Metal" },
			{ name = "PauldronLeft", attachTo = "LeftUpperArm", size = { 1.15, 0.42, 1.15 }, offset = { -0.12, 0.56, 0 }, rotation = { 0, 0, 12 }, color = IRON, material = "Metal" },
			{ name = "PauldronLeftLower", attachTo = "LeftUpperArm", size = { 1.0, 0.3, 1.0 }, offset = { -0.16, 0.24, 0 }, rotation = { 0, 0, 16 }, color = Palette.shade(IRON, 1.3), material = "Metal" },
			{ name = "PauldronLeftSpike", attachTo = "LeftUpperArm", size = { 0.18, 0.7, 0.18 }, offset = { -0.4, 0.86, 0 }, rotation = { 0, 0, 38 }, color = trim, material = "Metal" },

			-- Breastplate, ribs of iron, and the sigil burning through it.
			{ name = "Gorget", attachTo = "UpperTorso", size = { 1.1, 0.3, 0.95 }, offset = { 0, 0.72, 0 }, color = Palette.shade(IRON, 1.4), material = "Metal" },
			{ name = "ChestRibRight", attachTo = "UpperTorso", size = { 0.9, 0.16, 0.2 }, offset = { 0.42, 0.3, -0.52 }, rotation = { 0, 0, -14 }, color = trim, material = "Metal" },
			{ name = "ChestRibLeft", attachTo = "UpperTorso", size = { 0.9, 0.16, 0.2 }, offset = { -0.42, 0.3, -0.52 }, rotation = { 0, 0, 14 }, color = trim, material = "Metal" },
			{ name = "ChestSigil", attachTo = "UpperTorso", size = { 0.55, 0.55, 0.06 }, offset = { 0, -0.1, -0.58 }, rotation = { 0, 0, 45 }, color = ghost, material = "Neon" },
			{ name = "Faulds", attachTo = "LowerTorso", size = { 2.15, 0.5, 1.15 }, offset = { 0, -0.18, 0 }, color = Palette.shade(IRON, 1.2), material = "Metal" },

			-- A cape, and the chains still holding it on.
			{ name = "Cape", attachTo = "UpperTorso", size = { 2.0, 2.8, 0.12 }, offset = { 0, -0.55, 0.62 }, rotation = { 3, 0, 0 }, color = Palette.CRIMSON, material = "Fabric" },
			{ name = "CapeTail", attachTo = "UpperTorso", size = { 1.5, 1.0, 0.12 }, offset = { -0.2, -2.0, 0.66 }, rotation = { 0, 0, -8 }, color = Palette.shade(Palette.CRIMSON, 0.75), material = "Fabric" },
			{ name = "CapeChain", attachTo = "UpperTorso", size = { 1.5, 0.12, 0.12 }, offset = { 0, 0.66, -0.4 }, color = trim, material = "Metal" },

			-- The greatsword: too big for anything but him, with the same cold
			-- fire down its fuller as burns in his eyes and his braziers.
			{ name = "GreatswordGrip", attachTo = "RightHand", size = { 0.22, 0.22, 1.1 }, offset = { 0, -0.05, 0.3 }, color = Palette.DARK_LEATHER, material = "Fabric" },
			{ name = "GreatswordPommel", attachTo = "RightHand", size = { 0.34, 0.34, 0.22 }, offset = { 0, -0.05, 0.92 }, color = trim, material = "Metal" },
			{ name = "GreatswordGuard", attachTo = "RightHand", size = { 1.5, 0.22, 0.24 }, offset = { 0, -0.05, -0.22 }, color = trim, material = "Metal" },
			{ name = "GreatswordQuillonRight", attachTo = "RightHand", size = { 0.34, 0.2, 0.22 }, offset = { 0.84, -0.05, -0.3 }, rotation = { 0, -26, 0 }, color = trim, material = "Metal" },
			{ name = "GreatswordQuillonLeft", attachTo = "RightHand", size = { 0.34, 0.2, 0.22 }, offset = { -0.84, -0.05, -0.3 }, rotation = { 0, 26, 0 }, color = trim, material = "Metal" },
			-- Kept to roughly the reach the old greatsword had: at 1.6 scale
			-- every extra stud here is 1.6 in the world, and a blade much
			-- longer than this drives through the floor on a ground slam.
			{ name = "Greatsword", attachTo = "RightHand", size = { 0.2, 0.5, 3.2 }, offset = { 0, -0.05, -2.05 }, color = Palette.shade(DARK_STEEL, 0.95), material = "Metal" },
			{ name = "GreatswordFuller", attachTo = "RightHand", size = { 0.22, 0.12, 2.9 }, offset = { 0, -0.05, -2.05 }, color = ghost, material = "Neon" },
			{ name = "GreatswordEdge", attachTo = "RightHand", size = { 0.13, 0.1, 3.1 }, offset = { 0, 0.18, -2.05 }, color = STEEL, material = "Metal" },
			{ name = "GreatswordTaper", attachTo = "RightHand", size = { 0.18, 0.34, 0.6 }, offset = { 0, -0.05, -3.95 }, color = Palette.shade(DARK_STEEL, 0.95), material = "Metal" },
			{ name = "GreatswordPoint", attachTo = "RightHand", size = { 0.14, 0.18, 0.44 }, offset = { 0, -0.05, -4.45 }, color = STEEL, material = "Metal" },
		},
	}
end

RigDefs.PLAYER_RIG = "R15Player"

-- Keyed by rig id. An enemy's rig id is its EnemyDefs id.
RigDefs.STYLES = {
	TrainingDummy = dummyStyle(),
	SkeletonWarrior = skeletonStyle(),
	Shambler = shamblerStyle(),
	Spitter = spitterStyle(),
	HollowKing = hollowKingStyle(),
	R15Player = playerStyle(),
} :: { [string]: RigStyle }

function RigDefs.styleOf(rigId: string): RigStyle
	local style = RigDefs.STYLES[rigId]
	assert(style, `No rig style for "{rigId}"`)
	return style
end

-- How much bigger than standard this rig is built.
function RigDefs.scaleOf(rigId: string): number
	local style = RigDefs.STYLES[rigId]
	return if style and style.scale then style.scale else 1
end

-- The rig's hitbox size, scaled: { x, y, z }.
function RigDefs.rootSize(rigId: string): { number }
	local scale = RigDefs.scaleOf(rigId)
	return { RigDefs.ROOT_SIZE[1] * scale, RigDefs.ROOT_SIZE[2] * scale, RigDefs.ROOT_SIZE[3] * scale }
end

function RigDefs.partStyle(style: RigStyle, partName: string): PartStyle
	return style.parts[partName] or style.default
end

-- The part names of the skeleton, in build order.
function RigDefs.partNames(): { string }
	local names = {}
	for _, part in RigDefs.SKELETON do
		table.insert(names, part.name)
	end
	return names
end

return RigDefs
