--!strict
-- Attacks built on the spot instead of picked from a list. Pure Luau — no
-- Roblox API, so the server and every client can generate the same attack from
-- the same few numbers, and the whole thing is testable headless.
--
-- Why generate at all: a parry game wants attacks that are never quite the
-- same twice, so players read the fighter rather than memorise a clip. But it
-- also wants every attack to be readable, which memorising a clip is very good
-- at. Those pull against each other, and the split below is what resolves it.
--
--   The TELL is authored and fixed.   The STRIKE is generated.
--
-- An attack wears one of four archetypes. The archetype decides the windup
-- pose — the silhouette the player actually reads — and that pose is the same
-- every single time, down to the degree, on the joints that identify it. What
-- varies is everything after the commit: where the arc travels, how far it
-- carries, how the body leans through it, where it ends up.
--
-- So a player learns four cues, not forty animations, and still never sees the
-- same swing twice. They are reading the grammar instead of the vocabulary,
-- which is the difference between "I know this attack" and "I know this
-- fighter".
--
-- Lead time is an INPUT. `leadTime` is how long the tell is on screen before
-- the hit lands, and the generator builds the attack to fit it rather than
-- reporting whatever fell out. That is what makes "every attack is custom" and
-- "every attack clears the reaction floor" both true at once: an unreadable
-- attack is not something this module can produce.
--
-- The timing skeleton comes from AnimationDefs.strike, the same one the
-- hand-authored attacks use, so generated and authored attacks read as coming
-- from the same body.

local AnimationDefs = require(script.Parent.AnimationDefs)
local KeyframeMath = require(script.Parent.KeyframeMath)

local AttackChoreography = {}

export type Poses = { [string]: KeyframeMath.PoseSpec }

-- The four tells. Three are parryable swings; Plant is the one that means
-- "move", and it is deliberately the most different of the four so the red
-- flash on an unparryable attack confirms a pose the player already knows
-- rather than carrying the whole message on its own.
export type Archetype = "WindBack" | "Raise" | "Coil" | "Plant"

AttackChoreography.ARCHETYPES = { "WindBack", "Raise", "Coil", "Plant" } :: { Archetype }

-- Below this, a player is pressing on prediction rather than on what they saw.
-- Human visual reaction lands around 250 ms; the rest is the margin between
-- noticing and having pressed.
AttackChoreography.REACTION_FLOOR = 0.35

-- How long after the tell lands the player is still deciding. Divergence
-- between two archetypes is measured here — the moment the answer is chosen,
-- not the moment the hit arrives.
AttackChoreography.DECISION_AT = 0.25

type ArchetypeDef = {
	-- The windup pose: what the player reads. Fixed.
	tell: Poses,
	-- Where the arc ends up. Varied within bounds.
	hit: Poses,
	-- The joints that identify this archetype. Never varied, by anything, for
	-- any reason — these are the silhouette.
	diagnostic: { string },
	-- Whether this tell means "parry" or "move".
	parryable: boolean,
	-- Which archetypes flow naturally out of this one, because the body ends
	-- up already loaded for them. This is what makes a low sweep run into a
	-- rising cut without a trip back through neutral.
	follows: { Archetype },
}

--[[ The four ]]

local ARCHETYPE_DEFS: { [Archetype]: ArchetypeDef } = {
	-- Blade drawn across the body to the right, torso wound with it. Sweeps
	-- flat, left to right. The bread-and-butter swing.
	WindBack = {
		tell = {
			UpperTorso = { rx = 4.0, ry = 38.0 },
			Head = { ry = -14.0 },
			RightUpperArm = { rx = 52.6, ry = 34.9, rz = -1.6 },
			RightLowerArm = { rx = 70.0, rz = -9.2 },
			RightHand = { rx = -21.3, ry = 31.2, rz = -2.7 },
			LeftUpperArm = { rx = 15.2, ry = -41.7, rz = -4.1 },
			LeftLowerArm = { rx = 33.5 },
		},
		hit = {
			UpperTorso = { ry = -44, rx = -8 },
			Head = { ry = 16 },
			RightUpperArm = { rx = 10, ry = -26, rz = -48 },
			RightLowerArm = { rx = 12 },
			LeftUpperArm = { rz = 26 },
			LeftLowerArm = { rx = 14 },
		},
		diagnostic = { "UpperTorso", "RightUpperArm" },
		parryable = true,
		follows = { "Raise", "Coil" },
	},

	-- Both arms up, weight rising, everything above the waist stacked over the
	-- head. Comes straight down.
	Raise = {
		tell = {
			LowerTorso = { py = 0.16 },
			UpperTorso = { rx = 16.0 },
			Head = { rx = 10.0 },
			RightUpperArm = { rx = 159.4, ry = -1.8, rz = 11.9 },
			LeftUpperArm = { rx = 157.3, ry = 5.2, rz = -25.8 },
			RightLowerArm = { rx = 27.4, ry = 10.5, rz = -0.6 },
			LeftLowerArm = { rx = 36.5 },
			RightHand = { ry = 19.7 },
			RightUpperLeg = { rx = 11.8, ry = -13.3, rz = 2.7 },
			LeftUpperLeg = { rx = 8.9, ry = 18.4, rz = -3.4 },
			RightLowerLeg = { rx = -13.6, ry = -0.4, rz = -0.1 },
			LeftLowerLeg = { rx = -12.4, ry = 0.4 },
		},
		hit = {
			LowerTorso = { py = -0.12 },
			UpperTorso = { rx = -30 },
			Head = { rx = -12 },
			RightUpperArm = { rx = 42, rz = 6 },
			LeftUpperArm = { rx = 42, rz = -6 },
			RightLowerArm = { rx = 8 },
			LeftLowerArm = { rx = 8 },
		},
		diagnostic = { "RightUpperArm", "LeftUpperArm" },
		parryable = true,
		follows = { "WindBack", "Coil" },
	},

	-- Weight dropped back, elbow folded hard at the hip, shoulders squared to
	-- the target. Goes straight forward. The one that closes distance.
	--
	-- Built in opposition to WindBack on every axis that matters: where that
	-- one opens the torso and swings the arm wide, this one closes the torso
	-- and tucks the arm in. They are the two most confusable tells in the
	-- language — both are "the right arm is loaded" — so the difference is
	-- made structural rather than left to chance.
	Coil = {
		tell = {
			LowerTorso = { ry = -16.0, py = -0.14 },
			UpperTorso = { rx = 14.0, ry = -22.0 },
			Head = { rx = -9.7, ry = 7.9, rz = 1.3 },
			RightUpperArm = { rx = -59.4, ry = -16.0, rz = 50.7 },
			RightLowerArm = { rx = 86.0, ry = -0.1, rz = 0.6 },
			RightHand = { rx = 50.2, ry = -73.2, rz = 64.2 },
			LeftUpperArm = { rx = 18.4, ry = 2.2, rz = -10.1 },
			LeftLowerArm = { rx = 35.5, ry = 15.9, rz = 25.7 },
			LeftHand = { rx = 0.1, ry = 0.7, rz = 30.2 },
			RightUpperLeg = { rx = -10.4, ry = -44.5, rz = -7.3 },
			RightLowerLeg = { rx = 6.5, ry = 11.8 },
		},
		hit = {
			LowerTorso = { ry = 10, pz = -0.34, py = -0.04 },
			UpperTorso = { ry = 14, rx = -16 },
			Head = { ry = -6 },
			RightUpperArm = { rx = 78, rz = 2 },
			RightLowerArm = { rx = 4 },
			LeftUpperArm = { rz = 22, rx = -10 },
		},
		diagnostic = { "UpperTorso", "RightUpperArm", "RightLowerArm" },
		parryable = true,
		follows = { "WindBack", "Raise" },
	},

	-- Feet set wide, hips sunk, both arms spread straight out to the sides.
	-- The whole body goes down and wide, and then drives outward.
	--
	-- This is the one that cannot be parried, so it is the one that must never
	-- be mistaken for anything. Raise is its opposite by construction — that
	-- goes up and narrow, this goes down and wide — because those two are the
	-- pair whose answers differ (parry versus move), and confusing them is the
	-- most expensive mistake the game can ask a player to make.
	Plant = {
		tell = {
			LowerTorso = { rx = 16.0, py = -0.32 },
			UpperTorso = { rx = -10.0 },
			Head = { rx = -8.0 },
			RightUpperArm = { rx = 43.4, ry = -18.8, rz = 78.6 },
			LeftUpperArm = { rx = 57.3, ry = 33.2, rz = -77.1 },
			RightLowerArm = { rx = 8.0, rz = -13.0 },
			LeftLowerArm = { rx = 8.0, rz = 10.0 },
			RightHand = { rx = -31.5, ry = -18.7, rz = -1.3 },
			RightUpperLeg = { rx = -20.0, rz = 20.5 },
			LeftUpperLeg = { rx = -20.0, rz = -23.1 },
			RightLowerLeg = { rz = -8.1 },
			LeftLowerLeg = { rz = 12.2 },
			RightFoot = { rz = -10.8 },
			LeftFoot = { rz = 9.8 },
		},
		hit = {
			LowerTorso = { py = -0.52 },
			UpperTorso = { rx = 22 },
			Head = { rx = 12 },
			RightUpperArm = { rx = 18, rz = 22 },
			LeftUpperArm = { rx = 18, rz = -22 },
			RightLowerArm = { rx = 4 },
			LeftLowerArm = { rx = 4 },
			RightUpperLeg = { rz = 34 },
			LeftUpperLeg = { rz = -34 },
		},
		diagnostic = { "RightUpperArm", "LeftUpperArm", "LowerTorso" },
		parryable = false,
		follows = { "WindBack", "Raise", "Coil" },
	},
}

--[[ Variation ]]

-- A deterministic value in [0, 1) for one channel of one seed.
--
-- A hash rather than a running generator, because the server and the client
-- have to agree and they do not necessarily ask for the channels in the same
-- order. A sequence would make the answer depend on call order; a hash makes
-- channel 3 of seed 40 the same number everywhere, forever.
--
-- Every intermediate stays under 2^48, so it is exact in a double and the two
-- sides cannot drift.
local HASH_MOD = 2147483647
local HASH_MULTIPLIER = 48271

local function vary(seed: number, channel: number): number
	local x = (math.floor(math.abs(seed)) % 65536) * 127 + (channel % 64) * 977 + 1
	x = (x * HASH_MULTIPLIER) % HASH_MOD
	x = (x * HASH_MULTIPLIER) % HASH_MOD
	return x / HASH_MOD
end

AttackChoreography.vary = vary

-- `vary`, remapped to [-1, 1].
local function signedVary(seed: number, channel: number): number
	return vary(seed, channel) * 2 - 1
end

-- Channels. Named so the same channel always means the same thing, whatever
-- order anything asks in.
local CHANNEL_AMPLITUDE = 1
local CHANNEL_LEAN = 2
local CHANNEL_HEAD = 3
local CHANNEL_STANCE = 4
local CHANNEL_CARRY = 5

-- How far variation may push a non-diagnostic joint. Small on purpose: the
-- point is that no two swings are identical, not that the body does something
-- different. Past about a fifth, an archetype stops reading as one thing.
local AMPLITUDE_RANGE = 0.16
local LEAN_RANGE = 9
local HEAD_RANGE = 7
local STANCE_RANGE = 11

local function copyPoses(poses: Poses): Poses
	local out: Poses = {}
	for part, pose in poses do
		out[part] = table.clone(pose)
	end
	return out
end

local function isDiagnostic(def: ArchetypeDef, part: string): boolean
	return table.find(def.diagnostic, part) ~= nil
end

-- Scales the rotations of every joint this archetype does not identify itself
-- by, and nudges the lean, head and stance. The diagnostic joints come through
-- untouched, which is the whole contract: a WindBack's torso and sword arm are
-- the same numbers on every seed, so the tell is learnable even though the
-- attack is not repeatable.
local function varied(def: ArchetypeDef, poses: Poses, seed: number, isHit: boolean): Poses
	local out = copyPoses(poses)

	local amplitude = 1 + signedVary(seed, CHANNEL_AMPLITUDE) * AMPLITUDE_RANGE
	local lean = signedVary(seed, CHANNEL_LEAN) * LEAN_RANGE
	local head = signedVary(seed, CHANNEL_HEAD) * HEAD_RANGE
	local stance = signedVary(seed, CHANNEL_STANCE) * STANCE_RANGE

	-- The follow-through carries further on some swings than others, so the
	-- recovery is not metronomic.
	if isHit then
		amplitude *= 1 + signedVary(seed, CHANNEL_CARRY) * AMPLITUDE_RANGE * 0.5
	end

	for part, pose in out do
		if isDiagnostic(def, part) then
			continue
		end

		pose.rx = if pose.rx then pose.rx * amplitude else nil
		pose.ry = if pose.ry then pose.ry * amplitude else nil
		pose.rz = if pose.rz then pose.rz * amplitude else nil
	end

	-- The lean and the head lead are added rather than scaled, so an archetype
	-- whose torso sits at zero still varies.
	if not isDiagnostic(def, "UpperTorso") then
		local torso = out.UpperTorso or {}
		torso.ry = (torso.ry or 0) + lean
		out.UpperTorso = torso
	end

	if not isDiagnostic(def, "Head") then
		local headPose = out.Head or {}
		headPose.ry = (headPose.ry or 0) + head
		out.Head = headPose
	end

	for _, leg in { "RightUpperLeg", "LeftUpperLeg" } do
		if isDiagnostic(def, leg) then
			continue
		end
		local sign = if leg == "RightUpperLeg" then 1 else -1
		local pose = out[leg] or {}
		pose.rz = (pose.rz or 0) + stance * sign
		out[leg] = pose
	end

	return out
end

--[[ Generating ]]

export type AttackSpec = {
	archetype: Archetype,
	-- Seconds the tell is on screen before the hit lands. An input: the
	-- generator fits the attack to it.
	leadTime: number,
	-- Seconds of follow-through and settle after the hit.
	recovery: number,
	-- Picks this attack out of every attack this archetype could have been.
	seed: number,
}

-- How long the rig takes to snap into the tell from rest. The tell is only
-- "on screen" once it has arrived, so this sits before leadTime rather than
-- inside it — an attack whose windup is still moving is not yet readable.
local SETTLE = 0.12
AttackChoreography.SETTLE = SETTLE

function AttackChoreography.get(archetype: Archetype): ArchetypeDef
	local def = ARCHETYPE_DEFS[archetype]
	assert(def, `No archetype "{archetype}"`)
	return def
end

function AttackChoreography.isParryable(archetype: Archetype): boolean
	return AttackChoreography.get(archetype).parryable
end

-- Which archetypes flow out of this one without a trip back through neutral.
function AttackChoreography.follows(archetype: Archetype): { Archetype }
	return AttackChoreography.get(archetype).follows
end

-- The whole attack, as the same kind of AnimationDef the authored ones are.
--
-- `impact` sits exactly `leadTime` after the tell lands, every time and for
-- every seed. Playback stretches everything before it to the server's real
-- windup (KeyframeMath.alignedTime), so what the player sees and what the
-- server resolves stay the same event.
function AttackChoreography.generate(spec: AttackSpec): KeyframeMath.AnimationDef
	local def = AttackChoreography.get(spec.archetype)

	assert(spec.leadTime > 0, "leadTime must be positive")
	assert(spec.recovery > 0, "recovery must be positive")

	local windupAt = SETTLE
	local impact = windupAt + spec.leadTime
	local length = impact + spec.recovery

	return AnimationDefs.strike(
		length,
		impact,
		windupAt,
		varied(def, def.tell, spec.seed, false),
		varied(def, def.hit, spec.seed, true)
	)
end

-- The tell on its own, for anything that needs to compare silhouettes rather
-- than play them — the readability tests, and the workbench's read strips.
function AttackChoreography.tellPose(archetype: Archetype, seed: number): Poses
	local def = AttackChoreography.get(archetype)
	return varied(def, def.tell, seed, false)
end

-- How far apart two poses are, as the mean absolute difference in degrees
-- across every joint either of them touches.
--
-- This is the number that decides whether a player can tell two attacks apart
-- at the moment they have to choose. It is deliberately blunt: the eye reads
-- silhouette, and a big difference on one limb matters more than a small one
-- spread over six, which averaging happens to capture well enough.
function AttackChoreography.divergence(a: Poses, b: Poses): number
	local parts: { [string]: boolean } = {}
	for part in a do
		parts[part] = true
	end
	for part in b do
		parts[part] = true
	end

	local total = 0
	local count = 0
	for part in parts do
		local left = a[part] or {}
		local right = b[part] or {}
		for _, axis in { "rx", "ry", "rz" } do
			local one = (left :: any)[axis] or 0
			local two = (right :: any)[axis] or 0
			total += math.abs(one - two)
			count += 1
		end
	end

	return if count > 0 then total / count else 0
end

return AttackChoreography
