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
local CombatConstants = require(script.Parent.CombatConstants)
local WeaponDefs = require(script.Parent.WeaponDefs)
local KeyframeMath = require(script.Parent.KeyframeMath)

local AttackChoreography = {}

export type Poses = { [string]: KeyframeMath.PoseSpec }

-- The four tells. Three are parryable swings; Plant is the one that means
-- "move", and it is deliberately the most different of the four so the red
-- flash on an unparryable attack confirms a pose the player already knows
-- rather than carrying the whole message on its own.
export type Archetype = "WindBack" | "Raise" | "Coil" | "Plant"

AttackChoreography.ARCHETYPES = { "WindBack", "Raise", "Coil", "Plant" } :: { Archetype }

-- The span of reaction times the game is built to serve: from a quick player
-- to an ordinary one, measured from the tell landing to the key going down.
--
-- These two numbers are the whole basis of what a readable attack is, and they
-- give a *band*, not a floor. That distinction was got wrong once and it is
-- worth spelling out, because a floor alone reads as obviously sufficient and
-- is not:
--
--   The parry window is anchored to impact — [impact - early, impact + late]
--   (ParryMath). Measured from the tell landing, it opens at
--   `leadTime - early`. So a tell that is on screen *too long* pushes the
--   window away from the moment the player reacted to it, and reacting to the
--   tell presses early, whiffs, and eats the parry cooldown.
--
--   A player is punished for doing exactly the thing the tell exists to make
--   them do. Too slow is as unreadable as too fast, and rather more insulting.
--
-- The band itself is not stated here, because it falls out of the weapons'
-- parry windows and the dodge's invulnerability rather than being chosen: see
-- `readableLead` in AttackChoreography.spec, which derives it and enforces it
-- against every attack in the game.
AttackChoreography.REACTION_FAST = 0.22
AttackChoreography.REACTION_SLOW = 0.32

-- How long after the tell lands the player is still deciding. Divergence
-- between two archetypes is measured here — the moment the answer is chosen,
-- not the moment the hit arrives.
AttackChoreography.DECISION_AT = 0.25

type ArchetypeDef = {
	-- The windup pose: what the player reads. Fixed.
	tell: Poses,
	-- Where the arc ends up. Varied within bounds.
	hit: Poses,
	-- Where the body is left once the swing has carried through, and the one
	-- cue a chain gets: an attack that ends here instead of standing up is
	-- visibly unfinished. Authored rather than derived, because a pose that
	-- has to read across a room at a glance is not something to calculate.
	--
	-- Optional while the four are being posed by hand; until an archetype has
	-- one it falls back to the hit pushed past itself, which is what every
	-- carry used to be.
	carry: Poses?,
	-- The joints that identify this archetype. Never varied, by anything, for
	-- any reason — these are the silhouette.
	diagnostic: { string },
	-- Whether this tell means "parry" or "move".
	parryable: boolean,
	-- Which archetypes flow naturally out of this one, because the body ends
	-- up already loaded for them. This is what makes a low sweep run into a
	-- rising cut without a trip back through neutral.
	--
	-- Plant is a destination from all three swings, which it did not used to
	-- be. Measuring carry-pose-to-tell distance across the four says Plant is
	-- the *closest* follow from every one of them — a swing's follow-through
	-- genuinely leaves the body low and spread, which is what a Plant tell is.
	-- Forbidding it was excluding the one transition the body most wants to
	-- make, and it is what lets a chain end on something that has to be dodged.
	follows: { Archetype },
}

-- A per-enemy postural bias, added to whatever the archetype poses.
--
-- The four tells are a shared *grammar* — which answer a player has to give.
-- Shared grammar is what makes reading transfer to an enemy you have never
-- fought, and it is also what made every enemy look the same. An accent is the
-- difference: a Shambler hunches and leads with its head, a skeleton stands
-- square and economical, and they wear the identical WindBack differently.
--
-- Applied only to joints the archetype does not identify itself by, so it
-- cannot make two tells converge however strong it is. Readability is
-- preserved by construction, not by taste.
export type Accent = { [string]: KeyframeMath.PoseSpec }

--[[ The four ]]

local ARCHETYPE_DEFS: { [Archetype]: ArchetypeDef } = {
	-- Blade drawn across the body to the right, torso wound with it. Sweeps
	-- flat, left to right. The bread-and-butter swing.
	WindBack = {
		tell = {
			Head = { ry = -14 },
			LeftFoot = { rx = 1.2 },
			LeftLowerArm = { rx = 33.5 },
			LeftLowerLeg = { rx = -5.2 },
			LeftUpperArm = { rx = 15.2, ry = -41.7, rz = -4.1 },
			LeftUpperLeg = { rx = 4 },
			LowerTorso = { ry = 14, py = -0.05 },
			RightFoot = { rx = 21 },
			RightHand = { rx = -21.3, ry = 31.2, rz = -2.7 },
			RightLowerArm = { rx = 70, rz = -9.2 },
			RightLowerLeg = { rx = -7 },
			RightUpperArm = { rx = 52.6, ry = 34.9, rz = -1.6 },
			RightUpperLeg = { rx = -14 },
			UpperTorso = { rx = 4, ry = 38 },
		},
		hit = {
			Head = { ry = 16 },
			LeftFoot = { rx = 7.2 },
			LeftLowerArm = { rx = 14 },
			LeftLowerLeg = { rx = -31.2 },
			LeftUpperArm = { rz = 26 },
			LeftUpperLeg = { rx = 24 },
			LowerTorso = { ry = -20, py = -0.07 },
			RightFoot = { rx = 12 },
			RightHand = {},
			RightLowerArm = { rx = 12 },
			RightLowerLeg = { rx = -4 },
			RightUpperArm = { rx = 10, ry = -26, rz = -48 },
			RightUpperLeg = { rx = -8 },
			UpperTorso = { rx = -8, ry = -44 },
		},
		carry = {
			Head = { ry = 16 },
			LeftFoot = { rx = 4.8 },
			LeftLowerArm = { rx = 14 },
			LeftLowerLeg = { rx = -20.8 },
			LeftUpperArm = { rz = 26 },
			LeftUpperLeg = { rx = 16 },
			LowerTorso = { ry = -8, py = -0.08 },
			RightFoot = { rx = 21 },
			RightHand = {},
			RightLowerArm = { rx = 12 },
			RightLowerLeg = { rx = -7 },
			RightUpperArm = { rx = 10, ry = -26, rz = -48 },
			RightUpperLeg = { rx = -14 },
			UpperTorso = { rx = -8, ry = -44 },
		},
		diagnostic = { "UpperTorso", "RightUpperArm" },
		parryable = true,
		follows = { "Raise", "Coil", "Plant" },
	},

	-- Both arms up, weight rising, everything above the waist stacked over the
	-- head. Comes straight down.
	Raise = {
		tell = {
			Head = { rx = 10 },
			LeftFoot = { rx = 6 },
			LeftLowerArm = { rx = 36.5 },
			LeftLowerLeg = { rx = -12.4, ry = 0.4 },
			LeftUpperArm = { rx = 157.3, ry = 5.2, rz = -25.8 },
			LeftUpperLeg = { rx = 8.9, ry = 18.4, rz = -3.4 },
			LowerTorso = { py = 0.16 },
			RightFoot = { rx = 6 },
			RightHand = { ry = 19.7 },
			RightLowerArm = { rx = 27.4, ry = 10.5, rz = -0.6 },
			RightLowerLeg = { rx = -13.6, ry = -0.4, rz = -0.1 },
			RightUpperArm = { rx = 159.4, ry = -1.8, rz = 11.9 },
			RightUpperLeg = { rx = 11.8, ry = -13.3, rz = 2.7 },
			UpperTorso = { rx = 16 },
		},
		hit = {
			Head = { rx = -12 },
			LeftFoot = { rx = 26 },
			LeftLowerArm = { rx = 8 },
			LeftLowerLeg = { rx = -52 },
			LeftUpperArm = { rx = 42, rz = -6 },
			LeftUpperLeg = { rx = 26 },
			LowerTorso = { py = -0.12 },
			RightFoot = { rx = 26 },
			RightHand = {},
			RightLowerArm = { rx = 8 },
			RightLowerLeg = { rx = -52 },
			RightUpperArm = { rx = 42, rz = 6 },
			RightUpperLeg = { rx = 26 },
			UpperTorso = { rx = -30 },
		},
		carry = {
			Head = { rx = -12 },
			LeftFoot = { rx = 16 },
			LeftLowerArm = { rx = 8 },
			LeftLowerLeg = { rx = -32 },
			LeftUpperArm = { rx = 42, rz = -6 },
			LeftUpperLeg = { rx = 16 },
			LowerTorso = { py = -0.09 },
			RightFoot = { rx = 16 },
			RightHand = {},
			RightLowerArm = { rx = 8 },
			RightLowerLeg = { rx = -32 },
			RightUpperArm = { rx = 42, rz = 6 },
			RightUpperLeg = { rx = 16 },
			UpperTorso = { rx = -30 },
		},
		diagnostic = { "RightUpperArm", "LeftUpperArm" },
		parryable = true,
		follows = { "WindBack", "Coil", "Plant" },
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
			Head = { rx = -9.7, ry = 7.9, rz = 1.3 },
			LeftFoot = { rx = -0.6 },
			LeftHand = { rx = 0.1, ry = 0.7, rz = 30.2 },
			LeftLowerArm = { rx = 35.5, ry = 15.9, rz = 25.7 },
			LeftLowerLeg = { rx = 2.6 },
			LeftUpperArm = { rx = 18.4, ry = 2.2, rz = -10.1 },
			LeftUpperLeg = { rx = -2 },
			LowerTorso = { ry = -16, py = -0.14 },
			RightFoot = { rx = 30 },
			RightHand = { rx = 50.2, ry = -73.2, rz = 64.2 },
			RightLowerArm = { rx = 86, ry = -0.1, rz = 0.6 },
			RightLowerLeg = { rx = 6.5, ry = 11.8 },
			RightUpperArm = { rx = -59.4, ry = -16, rz = 50.7 },
			RightUpperLeg = { rx = -10.4, ry = -44.5, rz = -7.3 },
			UpperTorso = { rx = 14, ry = -22 },
		},
		hit = {
			Head = { ry = -6 },
			LeftFoot = { rx = 9 },
			LeftHand = {},
			LeftLowerArm = {},
			LeftLowerLeg = { rx = -39 },
			LeftUpperArm = { rx = -10, rz = 22 },
			LeftUpperLeg = { rx = 30 },
			LowerTorso = { ry = 10, py = -0.04, pz = -0.34 },
			RightFoot = { rx = 18 },
			RightHand = {},
			RightLowerArm = { rx = 4 },
			RightLowerLeg = { rx = -6 },
			RightUpperArm = { rx = 78, rz = 2 },
			RightUpperLeg = { rx = -12 },
			UpperTorso = { rx = -16, ry = 14 },
		},
		carry = {
			Head = { ry = -6 },
			LeftFoot = { rx = 5.4 },
			LeftHand = {},
			LeftLowerArm = {},
			LeftLowerLeg = { rx = -23.4 },
			LeftUpperArm = { rx = -10, rz = 22 },
			LeftUpperLeg = { rx = 18 },
			LowerTorso = { ry = 6, py = -0.08 },
			RightFoot = { rx = 21 },
			RightHand = {},
			RightLowerArm = { rx = 4 },
			RightLowerLeg = { rx = -7 },
			RightUpperArm = { rx = 78, rz = 2 },
			RightUpperLeg = { rx = -14 },
			UpperTorso = { rx = -16, ry = 14 },
		},
		diagnostic = { "UpperTorso", "RightUpperArm", "RightLowerArm" },
		parryable = true,
		follows = { "WindBack", "Raise", "Plant" },
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
			Head = { rx = -8 },
			LeftFoot = { rz = 9.8 },
			LeftLowerArm = { rx = 8, rz = 10 },
			LeftLowerLeg = { rz = 12.2 },
			LeftUpperArm = { rx = 57.3, ry = 33.2, rz = -77.1 },
			LeftUpperLeg = { rx = -20, rz = -23.1 },
			LowerTorso = { rx = 16, py = -0.32 },
			RightFoot = { rz = -10.8 },
			RightHand = { rx = -31.5, ry = -18.7, rz = -1.3 },
			RightLowerArm = { rx = 8, rz = -13 },
			RightLowerLeg = { rz = -8.1 },
			RightUpperArm = { rx = 43.4, ry = -18.8, rz = 78.6 },
			RightUpperLeg = { rx = -20, rz = 20.5 },
			UpperTorso = { rx = -10 },
		},
		hit = {
			Head = { rx = 12 },
			LeftFoot = { rx = 30 },
			LeftLowerArm = { rx = 4 },
			LeftLowerLeg = { rx = -60 },
			LeftUpperArm = { rx = 18, rz = -22 },
			LeftUpperLeg = { rx = 30, rz = -34 },
			LowerTorso = { py = -0.52 },
			RightFoot = { rx = 30 },
			RightHand = {},
			RightLowerArm = { rx = 4 },
			RightLowerLeg = { rx = -60 },
			RightUpperArm = { rx = 18, rz = 22 },
			RightUpperLeg = { rx = 30, rz = 34 },
			UpperTorso = { rx = 22 },
		},
		carry = {
			Head = { rx = 12 },
			LeftFoot = { rx = 20 },
			LeftLowerArm = { rx = 4 },
			LeftLowerLeg = { rx = -40 },
			LeftUpperArm = { rx = 18, rz = -22 },
			LeftUpperLeg = { rx = 20 },
			LowerTorso = { py = -0.13 },
			RightFoot = { rx = 20 },
			RightHand = {},
			RightLowerArm = { rx = 4 },
			RightLowerLeg = { rx = -40 },
			RightUpperArm = { rx = 18, rz = 22 },
			RightUpperLeg = { rx = 20 },
			UpperTorso = { rx = 22 },
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
local COMPONENTS = { "rx", "ry", "rz", "px", "py", "pz" }

local HASH_MOD = 2147483647
local HASH_MULTIPLIER = 48271

-- A deterministic 0..1 number from a seed and a channel.
--
-- The whole point is that the server and every client get the same answer:
-- one attack's shape travels the wire as a single seed, and each joint and
-- axis asks this for its own variation on its own channel. Two rounds of a
-- Lehmer generator, with every intermediate kept under 2^48 so a double
-- holds it exactly and no two machines can drift apart.
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
-- Was 11, when this was the only thing moving a generated attack's legs.
-- With the archetypes posing their own weight it is a perturbation on top of
-- real choreography rather than a substitute for it, and 11 degrees of splay
-- fights whoever posed the stance.
local STANCE_RANGE = 5

-- How much of the stance shift comes back the other way at the hit.
--
-- The seed picks which way the weight starts, and the strike moves it the
-- other way -- so the legs provably differ between the tell and the hit on
-- every seed. They used to take the identical value at both ends, because
-- this was derived from the seed alone and never looked at `isHit`, which
-- meant the one thing moving the legs actually froze them.
local STANCE_HIT_SHARE = 0.7

-- A deep copy of a pose table, so varying an archetype's poses never
-- writes back into the shared ARCHETYPE_DEFS entry.
local function copyPoses(poses: Poses): Poses
	local out: Poses = {}
	for part, pose in poses do
		out[part] = table.clone(pose)
	end
	return out
end

-- Whether this joint is one of the ones that identify the archetype.
-- Diagnostic joints are never varied, by anything, for any reason: they
-- are the silhouette the player learns to read.
local function isDiagnostic(def: ArchetypeDef, part: string): boolean
	return table.find(def.diagnostic, part) ~= nil
end

-- Scales the rotations of every joint this archetype does not identify itself
-- by, and nudges the lean, head and stance. The diagnostic joints come through
-- untouched, which is the whole contract: a WindBack's torso and sword arm are
-- the same numbers on every seed, so the tell is learnable even though the
-- attack is not repeatable.
local function varied(def: ArchetypeDef, poses: Poses, seed: number, isHit: boolean, accent: Accent?): Poses
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

	-- A weight shift, not a fixed splay: one way in the tell, the other way at
	-- the hit.
	local shift = if isHit then -stance * STANCE_HIT_SHARE else stance
	for _, leg in { "RightUpperLeg", "LeftUpperLeg" } do
		if isDiagnostic(def, leg) then
			continue
		end
		-- Never *creates* a leg. A joint this archetype does not pose is one
		-- the other keyframes will not pose either, and a part that appears in
		-- only some keyframes unwinds to flat in between rather than holding.
		local pose = out[leg]
		if not pose then
			continue
		end
		local sign = if leg == "RightUpperLeg" then 1 else -1
		pose.rz = (pose.rz or 0) + shift * sign
	end

	-- The enemy's own carriage, added last and skipped on every diagnostic
	-- joint. Last so it is not scaled by the seed's amplitude: an accent is who
	-- this fighter is, not something that varies swing to swing.
	--
	-- It biases joints the archetype already poses; it never introduces one.
	-- An accent that added a joint would add it to the tell and the hit alike
	-- and by the same amount, so the joint would sit frozen for the whole
	-- swing -- and on an archetype that poses no legs, the accent was the only
	-- thing touching them, which made it the cause of the dead lower body
	-- rather than a victim of it.
	if accent then
		for part, bias in accent do
			if isDiagnostic(def, part) then
				continue
			end
			local pose = out[part]
			if not pose then
				continue
			end
			for _, axis in COMPONENTS do
				local add = (bias :: any)[axis]
				if add then
					(pose :: any)[axis] = ((pose :: any)[axis] or 0) + add
				end
			end
		end
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
	-- The carriage of the enemy throwing it. Never touches diagnostic joints,
	-- so it cannot change which answer the tell asks for.
	accent: Accent?,
	-- Set when another link follows this one. The attack then ends held in
	-- its carry pose rather than standing back up, which is the only thing
	-- that tells a player the chain is still running.
	carryOut: boolean?,
}

-- How long the rig takes to snap into the tell from rest. The tell is only
-- "on screen" once it has arrived, so this sits before leadTime rather than
-- inside it — an attack whose windup is still moving is not yet readable.
local SETTLE = 0.12
AttackChoreography.SETTLE = SETTLE

-- The same beat for a link, and shorter, because the rig is not starting
-- from rest: it is already wound into the previous attack's carry pose, so
-- it arrives at the new tell sooner. Not zero -- a tell that teleports into
-- place is a tell nobody can read.
local LINK_SETTLE = 0.06
AttackChoreography.LINK_SETTLE = LINK_SETTLE

-- One archetype's definition. Asserts: the four are fixed, so a miss is a
-- typo rather than missing content.
function AttackChoreography.get(archetype: Archetype): ArchetypeDef
	local def = ARCHETYPE_DEFS[archetype]
	assert(def, `No archetype "{archetype}"`)
	return def
end

-- Whether this archetype's tell means "parry" or "move". The single
-- source for that, so an attack's pose and its answer can never disagree.
function AttackChoreography.isParryable(archetype: Archetype): boolean
	return AttackChoreography.get(archetype).parryable
end

-- The band of lead times a player can actually answer by reacting to what
-- they saw. Returns the lowest and highest lead that works.
--
-- Both ends matter, and the upper one is the less obvious of the two:
--
--   too short   a slower player never arrives. The floor is REACTION_SLOW
--               minus the class's slack for a late press.
--   too long    a player who reacts to the tell presses *early*, before the
--               window has opened, whiffs, and eats the cooldown. The ceiling
--               is REACTION_FAST plus the class's slack for an early press.
--
-- The second one is not a theoretical concern: it is what "the enemies are
-- too slow after they show their tell, I get punished for reacting" turned
-- out to mean. Enforcing only a floor made every attack slow enough to fail
-- that way.
--
-- The band is the intersection across every class, so no class is ever asked
-- to answer something it structurally cannot. Class identity lives in how
-- *wide* a window is, not in whether the attack can be read at all: a class
-- with tight frames has to be precise, and should never be the class that
-- simply cannot answer.
function AttackChoreography.readableLead(parryable: boolean): (number, number)
	if not parryable then
		-- Unparryable attacks are answered by moving. The i-frames cover the
		-- impact rather than opening a window around it, so the arithmetic is
		-- not the same shape.
		return AttackChoreography.REACTION_SLOW, AttackChoreography.REACTION_FAST + CombatConstants.DODGE_IFRAMES
	end

	local lowest, highest = 0, math.huge
	for _, weapon in WeaponDefs do
		lowest = math.max(lowest, AttackChoreography.REACTION_SLOW - weapon.parry.lateTolerance)
		highest = math.min(highest, AttackChoreography.REACTION_FAST + weapon.parry.earlyTolerance)
	end
	return lowest, highest
end

-- Which archetypes flow out of this one without a trip back through neutral.
function AttackChoreography.follows(archetype: Archetype): { Archetype }
	return AttackChoreography.get(archetype).follows
end


-- Where this archetype leaves the body once it has carried through.
--
-- Every path that needs a carry pose goes through here -- `carryPose` below,
-- and the poses `generate` and `generateLink` hand to the animation. Two
-- expressions for the same pose is how a chain seam drifts apart.
local function carryPoseOf(def: ArchetypeDef, seed: number, accent: Accent?): Poses
	local authored = def.carry
	if authored then
		return varied(def, authored, seed, true, accent)
	end

	-- No authored carry yet: the hit pushed past itself by the follow-through,
	-- which is what every carry was before they were posed by hand.
	return AnimationDefs.carryOf(varied(def, def.hit, seed, true, accent))
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

	local carry = carryPoseOf(def, spec.seed, spec.accent)

	-- A settle on the way back to rest -- but only when the attack actually
	-- goes back to rest. `strike` inserts its recovery *before* the final
	-- keyframe, so on a held end this would read carry -> settle -> carry: the
	-- one cue a chain gets, dipping and coming back.
	local recovery = if spec.carryOut then nil else AnimationDefs.settleOf(carry)

	return AnimationDefs.strike(
		length,
		impact,
		windupAt,
		varied(def, def.tell, spec.seed, false, spec.accent),
		varied(def, def.hit, spec.seed, true, spec.accent),
		recovery,
		spec.carryOut,
		carry
	)
end

-- A chain link starts here, so this is one half of the seam. It is a pure
-- function of the archetype and the seed, which is why the server only has to
-- send `fromAttackId` and `fromSeed` for the client to rebuild it exactly.
function AttackChoreography.carryPose(archetype: Archetype, seed: number, accent: Accent?): Poses
	return carryPoseOf(AttackChoreography.get(archetype), seed, accent)
end

-- An attack thrown out of another one, without a trip back through neutral.
export type LinkSpec = {
	archetype: Archetype,
	leadTime: number,
	recovery: number,
	seed: number,
	accent: Accent?,
	-- The attack this one flows out of. Its carry pose is where this link
	-- begins, so the two animations meet exactly.
	from: Archetype,
	fromSeed: number,
	carryOut: boolean?,
}

-- The same attack as `generate`, re-cut to start from where the last one
-- finished.
--
-- The tell is identical: same archetype, same seed, same diagnostic joints.
-- Only the approach to it changes, which is the point — a chained Coil has to
-- ask the player the same question a standalone Coil does, or the chain
-- becomes a second language to learn.
function AttackChoreography.generateLink(spec: LinkSpec): KeyframeMath.AnimationDef
	local def = AttackChoreography.get(spec.archetype)

	assert(spec.leadTime > 0, "leadTime must be positive")
	assert(spec.recovery > 0, "recovery must be positive")

	local windupAt = LINK_SETTLE
	local impact = windupAt + spec.leadTime
	local length = impact + spec.recovery

	return AnimationDefs.link(
		length,
		impact,
		windupAt,
		AttackChoreography.carryPose(spec.from, spec.fromSeed, spec.accent),
		varied(def, def.tell, spec.seed, false, spec.accent),
		varied(def, def.hit, spec.seed, true, spec.accent),
		spec.carryOut == true,
		carryPoseOf(def, spec.seed, spec.accent)
	)
end

-- The tell on its own, for anything that needs to compare silhouettes rather
-- than play them — the readability tests, and the workbench's read strips.
function AttackChoreography.tellPose(archetype: Archetype, seed: number, accent: Accent?): Poses
	local def = AttackChoreography.get(archetype)
	return varied(def, def.tell, seed, false, accent)
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
