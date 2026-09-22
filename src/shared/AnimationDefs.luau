--!strict
-- Rough animations for every rig, as data. Pure — no Roblox API.
--
-- These are first drafts meant to be refined. The game plays them as they are
-- until a refined version is published: see AnimationIds, and the workbench
-- (`lune run animation-workbench`), which turns every one of these into a
-- KeyframeSequence to open in the Animation Editor.
--
-- Reading a pose (all rigs share R15 joints, see RigDefs):
--   rx  arms and legs: + swings forward, - swings back
--       torso and head: + leans back / looks up, - leans or nods forward
--       knees: - bends; elbows: + bends
--   rz  right arm: + raises it out sideways; left arm: - does
--   ry  + turns to the rig's left
--   px/py/pz  studs; only used on LowerTorso, which moves the whole body
--       (py - is down, pz - is forward)
--
-- Enemy attacks and player swings carry `impact`: the moment the hit lands.
-- Playback stretches everything before it over the real windup, so the
-- visible strike always meets the server's impact time. Keep a keyframe at
-- exactly that time; the workbench names it "Impact", and a refined version
-- must keep a keyframe with that name for the timing to survive publishing.
--
-- Player stances and guards never pose LowerTorso or the legs, so Roblox's own
-- walk and run keep playing underneath them. Swings, criticals and dodges do:
-- a strike steps into it with the whole body, and walking slows right down
-- while one plays.

local GripSolver = require(script.Parent.GripSolver)
local KeyframeMath = require(script.Parent.KeyframeMath)
local RigDefs = require(script.Parent.RigDefs)

type AnimationDef = KeyframeMath.AnimationDef
type Keyframe = KeyframeMath.Keyframe
type PoseSpec = KeyframeMath.PoseSpec
type Poses = { [string]: PoseSpec }

local AnimationDefs = {}

AnimationDefs.ENEMY_BASICS = { "idle", "walk", "stagger", "death", "hurt" }

-- Players: a snap into the weapon's guard pose, held while blocking.
function AnimationDefs.guard(weaponId: string): string
	return `guard_{weaponId}`
end

-- Players: the weapon's fighting stance, held underneath walking and idling.
function AnimationDefs.stance(weaponId: string): string
	return `stance_{weaponId}`
end

-- Players: the weapon's planted fighting stance, for standing still.
--
-- Separate from `stance` because it is allowed what a stance is not: the hips
-- and the legs. A stance has to leave Roblox's walk cycle alone underneath it,
-- which means the feet are never where a fighter would put them. Standing
-- still there is no walk cycle worth protecting, so the whole body can settle
-- into a real guard — weight back, feet apart, weapon up. PlayerAnimation
-- swaps between the two as the character starts and stops moving.
function AnimationDefs.idle(weaponId: string): string
	return `idle_{weaponId}`
end

-- Players: the weapon's heavy attack.
function AnimationDefs.critical(weaponId: string): string
	return `critical_{weaponId}`
end

AnimationDefs.GUARD_BREAK = "guard_break"
-- Players: the weapon's signature move (AbilityDefs). One animation for all
-- three, because all three are the same shape — gather, then release.
AnimationDefs.ABILITY = "ability"
-- A flinch from a hit that didn't stagger. Enemies and players both have one.
AnimationDefs.HURT = "hurt"

-- Enemies: the animation name for one attack id, as EnemyDefs names it.
function AnimationDefs.attack(attackId: string): string
	return `attack_{attackId}`
end

-- One swing of a weapon's combo (WeaponDefs attack.combo), counted from 1.
function AnimationDefs.swing(weaponId: string, step: number): string
	return `swing_{weaponId}_{step}`
end

-- A move off the combo (WeaponDefs.MoveDef): a thrust, a kick, a shield
-- bash. Named separately from `swing` because a move is not a step -- it has
-- no place in the ladder, and it is chosen by which way the player is
-- holding rather than by how many times they have pressed.
function AnimationDefs.move(weaponId: string, moveId: string): string
	return `move_{weaponId}_{moveId}`
end

-- Players: the dodge roll, in the direction the body is travelling
-- (LocomotionMath.rollDirection). Four rolls rather than one dash, because a
-- roll is the one move in the game that turns the whole body: played in the
-- wrong direction it doesn't just look off, it points the tumble across the
-- way the character is sliding.
AnimationDefs.ROLL_DIRECTIONS = { "forward", "back", "left", "right" }

-- Players: the animation name for one roll direction.
function AnimationDefs.roll(direction: string): string
	return `roll_{direction}`
end

--[[ Building blocks ]]

local function kf(time: number, poses: Poses, easing: KeyframeMath.Easing?): Keyframe
	return { time = time, poses = poses, easing = easing or "Smooth" }
end

-- Several pose tables combined left to right, later ones winning.
--
-- Replaces a part's *whole* pose rather than merging its components, which
-- is the single easiest thing to get wrong in this file: laying a pose
-- carrying only `ry` over a crouch drops the crouch's `py` and drives the
-- feet through the floor. Poses are cloned, so the shared tables the
-- builders return are never written back into.
local function merge(...: Poses): Poses
	local out: Poses = {}
	for _, poses in { ... } do
		for part, pose in poses do
			out[part] = table.clone(pose)
		end
	end
	return out
end

-- The name of the part on the other side: Right<->Left, anything else
-- unchanged.
local function mirrorName(name: string): string
	if string.sub(name, 1, 5) == "Right" then
		return "Left" .. string.sub(name, 6)
	elseif string.sub(name, 1, 4) == "Left" then
		return "Right" .. string.sub(name, 5)
	end
	return name
end

-- The same pose on the other side: sides swap, and sideways and twisting
-- motion flips.
local function mirror(poses: Poses): Poses
	local out: Poses = {}
	for part, pose in poses do
		out[mirrorName(part)] = {
			rx = pose.rx,
			ry = if pose.ry then -pose.ry else nil,
			rz = if pose.rz then -pose.rz else nil,
			px = if pose.px then -pose.px else nil,
			py = pose.py,
			pz = pose.pz,
		}
	end
	return out
end

-- Upper and lower leg lengths, from RigDefs' hip, knee and ankle pivots.
local LEG_LENGTH = 2.2

-- Both legs bent by `angle` degrees at the hip, twice that at the knee, and
-- back at the ankle, with the body lowered so the feet stay on the floor.
local function crouch(angle: number): Poses
	local drop = -LEG_LENGTH * (1 - math.cos(math.rad(angle)))
	return {
		LowerTorso = { py = drop },
		RightUpperLeg = { rx = angle },
		LeftUpperLeg = { rx = angle },
		RightLowerLeg = { rx = -2 * angle },
		LeftLowerLeg = { rx = -2 * angle },
		RightFoot = { rx = angle },
		LeftFoot = { rx = angle },
	}
end

-- Exposed so the workbench can seed a rig standing in a plausible, floor-solved
-- stance rather than on dead straight legs. These solve hip height against the
-- leg angles, which is the one piece of this that is genuinely arithmetic and
-- the easiest to get wrong by hand.
AnimationDefs.crouch = crouch
AnimationDefs.mirror = mirror

-- The ankle angle that leaves a foot `tilt` degrees off flat, given how far
-- the thigh and shin above it have turned. Poses accumulate down a limb, so a
-- foot only lies flat when its own angle cancels everything above it — asking
-- for "flat, plus 8 degrees of toe-up" is far easier to get right by hand than
-- working that sum out at every keyframe. Positive tilt lifts the toe.
local function ankle(thigh: number, shin: number, tilt: number): number
	return -(thigh + shin) + tilt
end

type IdleParams = {
	length: number,
	lean: number,
	breathe: number,
	armForward: number,
	armOut: number,
	elbow: number,
	knee: number,
	headTilt: number,
	sway: number,
}

-- Three things happen at once, on three different clocks, which is what stops
-- a standing rig looking like one rigid piece pumping in time with itself:
--
--   breath   the chest rising and the shoulders opening
--   lag      the same motion reaching the head and arms late (overlap: a limb
--            is dragged by the body, it doesn't move with it)
--   weight   a slow lean from one foot to the other, one full cycle per loop
--            so it returns to where it started and the loop closes
local function idle(p: IdleParams): AnimationDef
	local crouched = crouch(p.knee)
	local drop = (crouched.LowerTorso :: any).py or 0

	-- One frame of the idle, at a given point in each of its three clocks.
	-- `breath` is the chest rising, `lag` the same motion reaching the head
	-- and arms late, and `weight` the slow lean from one foot to the other.
	local function pose(breath: number, lag: number, weight: number): Poses
		return merge(crouched, {
			-- Re-stating py: merge replaces a part's whole pose, so a hips
			-- pose here would otherwise drop the crouch's height correction.
			LowerTorso = { py = drop, rz = weight, ry = weight * 0.4 },
			UpperTorso = { rx = p.lean + breath, ry = breath * p.sway - weight * 0.5, rz = -weight * 0.6 },
			Head = { rx = -p.lean * 0.6 - lag * 0.5, ry = -weight * 0.9, rz = p.headTilt + weight * 0.4 },
			RightUpperArm = { rx = p.armForward + lag * 0.5, ry = -weight * 0.5, rz = p.armOut + lag },
			LeftUpperArm = { rx = p.armForward + lag * 0.5, ry = -weight * 0.5, rz = -(p.armOut + lag) },
			RightLowerArm = { rx = p.elbow + lag * 0.7 },
			LeftLowerArm = { rx = p.elbow + lag * 0.7 },
		})
	end

	local L = p.length
	local b = p.breathe
	-- A rig that already sways a lot shifts its weight further.
	local shift = 0.7 + p.sway * 0.4

	return {
		length = L,
		looped = true,
		priority = "Idle",
		keyframes = {
			kf(0, pose(0, 0, 0)),
			kf(L * 0.25, pose(b * 0.8, b * 0.2, shift)),
			kf(L * 0.5, pose(b, b * 0.7, 0)),
			kf(L * 0.75, pose(b * 0.35, b * 0.9, -shift)),
			kf(L, pose(0, 0, 0)),
		},
	}
end

type WalkParams = {
	length: number,
	stride: number,
	armSwing: number,
	knee: number,
	lean: number,
	bob: number,
	twist: number,
	rock: number,
	armForward: number,
	armOut: number,
	elbow: number,
	-- 0..1: how much the left leg drags instead of stepping.
	limp: number,
}

-- A four-beat cycle: contact, passing, mirrored contact, mirrored passing.
local function walk(p: WalkParams): AnimationDef
	-- Contact: the front heel lands with the toe up, the back foot is still
	-- pushing off with the toe down, and the hips turn against the shoulders.
	local contact: Poses = {
		LowerTorso = { py = -p.bob, rz = p.rock, ry = -p.twist * 0.6 },
		UpperTorso = { rx = p.lean, ry = p.twist },
		Head = { rx = -p.lean * 0.6, ry = -p.twist * 0.4 },
		RightUpperLeg = { rx = p.stride },
		RightLowerLeg = { rx = -5 },
		RightFoot = { rx = ankle(p.stride, -5, 9) },
		LeftUpperLeg = { rx = -p.stride },
		LeftLowerLeg = { rx = -p.knee },
		LeftFoot = { rx = ankle(-p.stride, -p.knee, -16) },
		RightUpperArm = { rx = p.armForward - p.armSwing, rz = p.armOut },
		LeftUpperArm = { rx = p.armForward + p.armSwing, rz = -p.armOut },
		RightLowerArm = { rx = p.elbow },
		-- The arm swinging forward bends at the elbow as it comes through.
		LeftLowerArm = { rx = p.elbow + p.armSwing * 0.3 },
	}

	-- Passing: weight over one flat foot, the other swinging through with the
	-- toe lifted so it clears the floor.
	local passing: Poses = {
		LowerTorso = { py = p.bob },
		UpperTorso = { rx = p.lean },
		Head = { rx = -p.lean * 0.6 },
		RightUpperLeg = { rx = 0 },
		RightLowerLeg = { rx = -5 },
		RightFoot = { rx = ankle(0, -5, 0) },
		LeftUpperLeg = { rx = p.stride * 0.2 },
		LeftLowerLeg = { rx = -p.knee * 1.6 },
		LeftFoot = { rx = ankle(p.stride * 0.2, -p.knee * 1.6, 7) },
		RightUpperArm = { rx = p.armForward, rz = p.armOut },
		LeftUpperArm = { rx = p.armForward, rz = -p.armOut },
		RightLowerArm = { rx = p.elbow },
		LeftLowerArm = { rx = p.elbow },
	}

	-- Mirrored before any limp is applied, so the limp stays on one side.
	local contactMirrored = mirror(contact)
	local passingMirrored = mirror(passing)

	-- A limp: the left leg barely comes forward when it steps, and barely
	-- lifts as it swings through.
	if p.limp > 0 then
		local keep = 1 - p.limp
		local leftStep = contactMirrored.LeftUpperLeg
		leftStep.rx = (leftStep.rx :: number) * keep
		local leftSwing = passing.LeftLowerLeg
		leftSwing.rx = (leftSwing.rx :: number) * keep
	end

	local L = p.length
	return {
		length = L,
		looped = true,
		priority = "Movement",
		keyframes = {
			kf(0, contact),
			kf(L * 0.25, passing),
			kf(L * 0.5, contactMirrored),
			kf(L * 0.75, passingMirrored),
			kf(L, contact),
		},
	}
end

-- Knocked back by a parry, then dazed. One second long; playback stretches it
-- over the real stagger duration.
local function stagger(intensity: number): AnimationDef
	local k = intensity
	local recoil: Poses = merge(crouch(12 * k), {
		UpperTorso = { rx = 24 * k },
		Head = { rx = 20 * k, rz = 12 * k },
		RightUpperArm = { rx = -20 * k, rz = 50 * k },
		LeftUpperArm = { rx = -12 * k, rz = -45 * k },
		RightLowerArm = { rx = 30 * k },
		LeftLowerArm = { rx = 25 * k },
	})

	local dazed: Poses = merge(crouch(18 * k), {
		UpperTorso = { rx = -12 * k },
		Head = { rx = -22 * k, rz = 16 * k },
		RightUpperArm = { rx = 8, rz = 14 * k },
		LeftUpperArm = { rx = 5, rz = -12 * k },
		RightLowerArm = { rx = 10 },
		LeftLowerArm = { rx = 12 },
	})

	return {
		length = 1,
		looped = false,
		priority = "Action",
		keyframes = {
			kf(0, {}),
			kf(0.15, recoil),
			kf(0.5, dazed),
			kf(1, dazed),
		},
	}
end

-- Collapse and lie still; a one-shot that holds its last frame.
--
-- LowerTorso rotates the whole body about the hips, so "forward" for a limb
-- turns with it: on a body lying on its back, a limb swung forward points up;
-- on a body lying face down, it points into the floor. Each fall direction
-- therefore gets its own limb poses. The workbench solves every pose against
-- the floor and fails if anything sinks through it.
local function death(backward: boolean): AnimationDef
	local side = if backward then 1 else -1

	local buckle: Poses = merge(crouch(35), {
		UpperTorso = { rx = -20 },
		Head = { rx = -25 },
		RightUpperArm = { rx = 20, rz = 20 },
		LeftUpperArm = { rx = 15, rz = -20 },
	})

	-- Half over with the hips still high. Dropping the hips before the body has
	-- tipped would drive the still-upright legs through the floor.
	local tipping: Poses = merge(crouch(35), {
		LowerTorso = { py = -0.9, rx = 50 * side, pz = 0.2 * side },
		UpperTorso = { rx = -10 * side },
		Head = { rx = 15 * side },
		RightUpperArm = { rx = if backward then 70 else -30, rz = 50 },
		LeftUpperArm = { rx = if backward then 60 else -30, rz = -50 },
	})

	-- Lying flat: the torso's centre about half a stud off the floor.
	local down: Poses = {
		LowerTorso = { py = -2.5, rx = 88 * side, pz = 0.6 * side },
		UpperTorso = { rx = 6 * side },
		Head = { rx = 10 * side, rz = 20 },
		-- Arms out to the sides, lying along the floor.
		RightUpperArm = { rx = if backward then 40 else -10, rz = 70 },
		LeftUpperArm = { rx = if backward then 30 else -10, rz = -65 },
		RightLowerArm = { rx = if backward then 15 else 0 },
		LeftLowerArm = { rx = if backward then 20 else 0 },
		-- On the back, knees rise; face down, the lower legs lift behind.
		RightUpperLeg = { rx = if backward then 10 else -5 },
		LeftUpperLeg = { rx = if backward then 25 else -10 },
		RightLowerLeg = { rx = if backward then -15 else -30 },
		LeftLowerLeg = { rx = if backward then -40 else -50 },
	}

	local settled = merge(down, {
		Head = { rx = 14 * side, rz = 28 },
		RightUpperArm = { rx = if backward then 45 else -10, rz = 80 },
	})

	return {
		length = 1.2,
		looped = false,
		priority = "Action",
		keyframes = {
			kf(0, {}),
			kf(0.35, buckle),
			kf(0.6, tipping, "Linear"),
			kf(0.8, down),
			kf(1.2, settled),
		},
	}
end

-- The parts a coil or follow-through exaggerates by default.
local UPPER_BODY = {
	UpperTorso = true,
	Head = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
}

-- Everything that carries the body's weight. Scaled separately, and by a
-- different amount, because the two halves of a strike do opposite things at
-- the same moment: the arms gather backwards while the feet are already
-- driving forwards. One factor for both cannot express that, and using one
-- is why generated swings had nothing underneath them.
local LOWER_BODY = {
	LowerTorso = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
}

-- The same poses with the upper body scaled by `upperFactor` and the weight
-- scaled by `lowerFactor`.
--
-- `lowerFactor` defaults to 1, which makes this an exact identity for the
-- lower body and leaves every authored call site byte-identical.
--
-- Note the asymmetry is deliberate and must stay: the lower body is *not*
-- simply added to UPPER_BODY. A shared factor would make the anticipation
-- beat (a negative factor) invert a crouch and lift the hips above standing,
-- and would make the coil (a factor above one) drive the feet through the
-- floor. The whole point is that the two halves scale differently.
--
-- Position is scaled on the lower body but not the upper. `LowerTorso.py` is
-- how far the hips have sunk, and a coil that does not sink the hips is not a
-- coil -- so that one number has to move with the rest of the weight.
local function exaggerate(poses: Poses, upperFactor: number, lowerFactor: number?): Poses
	local lower = lowerFactor or 1
	local out: Poses = {}
	for part, pose in poses do
		local copy = table.clone(pose)
		if UPPER_BODY[part] then
			copy.rx = if copy.rx then copy.rx * upperFactor else nil
			copy.ry = if copy.ry then copy.ry * upperFactor else nil
			copy.rz = if copy.rz then copy.rz * upperFactor else nil
		elseif LOWER_BODY[part] and lower ~= 1 then
			copy.rx = if copy.rx then copy.rx * lower else nil
			copy.ry = if copy.ry then copy.ry * lower else nil
			copy.rz = if copy.rz then copy.rz * lower else nil
			copy.px = if copy.px then copy.px * lower else nil
			copy.py = if copy.py then copy.py * lower else nil
			copy.pz = if copy.pz then copy.pz * lower else nil
		end
		out[part] = copy
	end
	return out
end

-- How much further than the windup the coil pulls back, and how far past the
-- hit pose the follow-through carries.
local COIL = 1.12
local FOLLOW_THROUGH = 1.15
-- How far the other way the body gathers before it draws back, and how early
-- in the windup that happens.
local ANTICIPATE = 0.16
local ANTICIPATE_AT = 0.4

-- How far into its stance the weight already is at the anticipation beat,
-- while the arms are still gathering the other way.
--
-- This one number is most of what "weight" means here. A body does not move
-- all at once: the feet commit first and the arms arrive late, and that lag
-- is the difference between a swing and a puppet being rotated. Before it,
-- the lower body was copied at its *full* windup value into a keyframe 48ms
-- off rest, so a deep stance did not lag -- it popped.
local ANTICIPATE_PLANT = 0.45

-- A little extra sink under the drawn-back weapon. Small on purpose: the coil
-- is a held breath, not a second crouch.
local COIL_LOWER = 1.06

-- Where the body ends up once a strike has carried through: the hit pose,
-- pushed past itself by the follow-through.
--
-- Both sides of a chain seam call this. A link starts at exactly the pose the
-- previous attack finished on, so the crossfade between them is a
-- mathematical no-op and the rig never twitches at the join. Deriving it in
-- one place is what makes that true by construction rather than by two
-- expressions happening to agree.
local function carryOf(hit: Poses): Poses
	return exaggerate(hit, FOLLOW_THROUGH)
end

AnimationDefs.carryOf = carryOf

-- Where the body settles on the way back to rest: mostly released, still
-- low. The shape a hand-authored attack gives its third pose --
-- `merge(crouch(12), ...)` under a `crouch(22)` hit -- derived rather than
-- authored, because a recovery is a beat the player passes through rather
-- than one they read.
local SETTLE_UPPER = 0.45
local SETTLE_LOWER = 0.6

-- The recovery pose for a carry: the same shape, mostly released but
-- still low.
local function settleOf(carry: Poses): Poses
	return exaggerate(carry, SETTLE_UPPER, SETTLE_LOWER)
end

AnimationDefs.settleOf = settleOf

-- An attack or swing: rest, the windup peaking at `windupAt`, a coil that
-- holds the tension, the strike at `impact`, a follow-through carrying past
-- it, an optional recovery pose, and rest by `length`.
--
-- The coil is what the eye reads as "about to hit": the rig eases into the
-- windup, keeps drawing back almost imperceptibly, then snaps. Because the
-- snap is shorter than a straight windup-to-hit swing, the strike reads as
-- faster and heavier without the impact moving at all.
local function strike(
	length: number,
	impact: number,
	windupAt: number,
	windup: Poses,
	hit: Poses,
	recovery: Poses?,
	-- Set when this strike opens a chain: it ends held in its carry pose
	-- instead of standing back up, so the next link can start from exactly
	-- there. See `link` below.
	holdEnd: boolean?,
	-- Where the body is left once the swing has carried through. Authored
	-- attacks leave it out and get the derived one, which is the hit pose
	-- pushed past itself; a generated attack passes its archetype's own, so
	-- the pose a chain is signposted by is chosen rather than calculated.
	carry: Poses?
): AnimationDef
	local coilAt = windupAt + (impact - windupAt) * 0.45
	local followAt = impact + math.min(0.07, (length - impact) * 0.2)
	local carried = carry or carryOf(hit)

	local keyframes = {
		-- A beat the other way first: the upper body gathers before it draws
		-- back, which is what makes a windup read as a decision rather than a
		-- pose the rig teleported into.
		--
		-- The two halves go opposite ways here. The arms counter-move, while
		-- the weight is already ANTICIPATE_PLANT of the way into its stance --
		-- feet first, arms late, which is the order a real strike loads in.
		kf(0, {}, "Out"),
		kf(windupAt * ANTICIPATE_AT, exaggerate(windup, -ANTICIPATE, ANTICIPATE_PLANT)),
		-- Snaps into the windup and settles there...
		kf(windupAt, windup),
		-- ...then accelerates from the coil into the hit, so it lands with
		-- weight, and carries through fast before slowing.
		kf(coilAt, exaggerate(windup, COIL, COIL_LOWER), "In"),
		kf(impact, hit, "Out"),
		kf(followAt, carried),
	}

	if recovery then
		table.insert(keyframes, kf(followAt + (length - followAt) * 0.5, recovery))
	end

	if holdEnd then
		table.insert(keyframes, kf(length, carried))
	else
		table.insert(keyframes, kf(length, {}))
	end

	return {
		length = length,
		looped = false,
		priority = "Action",
		impact = impact,
		keyframes = keyframes,
	}
end

-- Exposed so AttackChoreography can build generated attacks on the same
-- timing skeleton the authored ones use. The anticipation beat, the coil and
-- the follow-through are what make a strike read; a generator that invented
-- its own version of them would drift from the hand-authored attacks, and the
-- player would be reading two different languages.
AnimationDefs.strike = strike

-- The same animation, starting from wherever the body already is.
--
-- This is how one authored clip flows into another. An action that is
-- interrupted part way leaves the rig in some pose the next clip knows
-- nothing about; played normally, the next clip opens at rest, so the body
-- snaps back to neutral and starts over. `from` replaces the opening
-- keyframe's poses with the captured one, and the lead-in the clip already
-- has does the travelling instead.
--
-- **It adds no time, and that is not a stylistic choice.** Playback stretches
-- everything before `impact` to fit the server's real wind-up
-- (`KeyframeMath.alignedTime`), and the parry window is read off that impact.
-- A transition that prepended time would push the visible hit later than the
-- hit the server resolves, so a player would watch the blow land after being
-- told it had. Every other keyframe, `impact` and `length` are therefore left
-- exactly as authored, and a spec says so.
--
-- A part in `startPose` that the clip never poses stays in the animation's
-- part set and eases to rest across it, which is what should happen: the body
-- gives up whatever the last action left it holding and settles into what
-- this one asks for.
--
-- Returns a new def and mutates nothing. `KeyframeMath.partsOf` caches on the
-- def table, so each transition costs one cache miss -- once per interrupted
-- action, not per frame. Do not be tempted to make this return a shared
-- mutable def to avoid that.
function AnimationDefs.from(anim: AnimationDef, startPose: Poses): AnimationDef
	local keyframes = table.clone(anim.keyframes)
	local first = keyframes[1]
	if not first then
		return anim
	end

	local opening = table.clone(first)
	opening.poses = startPose
	keyframes[1] = opening

	local out = table.clone(anim)
	out.keyframes = keyframes
	return out
end

-- The same idle, re-labelled for walking: for a rig that never moves, so
-- every enemy still has the full basic set.
local function standIn(anim: AnimationDef): AnimationDef
	local copy = table.clone(anim)
	copy.priority = "Movement"
	return copy
end

-- Adds to a part's rotation, creating its pose if the part had none.
local function nudge(poses: Poses, part: string, rx: number, ry: number, rz: number)
	local pose = poses[part] or {}
	pose.rx = (pose.rx or 0) + rx
	pose.ry = (pose.ry or 0) + ry
	pose.rz = (pose.rz or 0) + rz
	poses[part] = pose
end

-- A flinch from a hit that didn't stagger: jolts back from the blow and
-- recovers within a third of a second.
--
-- Built over the rig's own idle posture, so a hunched zombie flinches from its
-- hunch instead of straightening up first. Upper body only, so it plays over a
-- walk without the feet sliding, and over a player's own walk the same way.
local function hurt(idleAnim: AnimationDef?, intensity: number): AnimationDef
	local rest: Poses = {}
	if idleAnim then
		for part, pose in idleAnim.keyframes[1].poses do
			if UPPER_BODY[part] then
				rest[part] = table.clone(pose)
			end
		end
	end

	-- The flinch pose at strength `k`, added on top of the rig's own resting
	-- posture — so a hunched zombie flinches from its hunch rather than
	-- straightening up to do it.
	local function jolt(k: number): Poses
		local poses = merge(rest)
		nudge(poses, "UpperTorso", 14 * k, 8 * k, 0)
		nudge(poses, "Head", 14 * k, 0, -10 * k)
		nudge(poses, "RightUpperArm", -12 * k, 0, 20 * k)
		nudge(poses, "LeftUpperArm", -10 * k, 0, -18 * k)
		nudge(poses, "RightLowerArm", 20 * k, 0, 0)
		nudge(poses, "LeftLowerArm", 18 * k, 0, 0)
		return poses
	end

	return {
		length = 0.35,
		looped = false,
		priority = "Action",
		keyframes = {
			kf(0, merge(rest), "Linear"),
			kf(0.05, jolt(intensity)),
			kf(0.16, jolt(intensity * 0.45)),
			kf(0.35, merge(rest)),
		},
	}
end

--[[ Training Dummy: a stiff, wobbly wooden mannequin ]]

local dummyIdle = idle({
	length = 3,
	lean = 0,
	breathe = 2,
	armForward = 0,
	armOut = 8,
	elbow = 5,
	knee = 0,
	headTilt = 0,
	sway = 1,
})

local TrainingDummy: { [string]: AnimationDef } = {
	idle = dummyIdle,
	walk = standIn(dummyIdle),
	stagger = stagger(0.8),
	death = death(true),
	hurt = hurt(dummyIdle, 0.7),

	[AnimationDefs.attack("Overhead")] = strike(1.0, 0.6, 0.45, {
		UpperTorso = { rx = 12 },
		Head = { rx = 8 },
		RightUpperArm = { rx = 165, rz = 10 },
		LeftUpperArm = { rx = 165, rz = -10 },
		RightLowerArm = { rx = 20 },
		LeftLowerArm = { rx = 20 },
	}, {
		LowerTorso = { py = -0.1 },
		UpperTorso = { rx = -22 },
		Head = { rx = -10 },
		RightUpperArm = { rx = 45, rz = 5 },
		LeftUpperArm = { rx = 45, rz = -5 },
		RightLowerArm = { rx = 10 },
		LeftLowerArm = { rx = 10 },
	}),

	[AnimationDefs.attack("GroundSlam")] = strike(1.2, 0.7, 0.5, {
		LowerTorso = { py = 0.2 },
		UpperTorso = { rx = 15 },
		RightUpperArm = { rx = 170, rz = 25 },
		LeftUpperArm = { rx = 170, rz = -25 },
	}, merge(crouch(35), {
		UpperTorso = { rx = -35 },
		Head = { rx = -15 },
		RightUpperArm = { rx = 70, rz = 15 },
		LeftUpperArm = { rx = 70, rz = -15 },
	})),
}

--[[ Skeleton Warrior: stiff and rattling, sword in the right hand ]]

local SkeletonWarrior: { [string]: AnimationDef } = {
	idle = idle({
		length = 2.4,
		lean = -4,
		breathe = 2,
		armForward = 8,
		armOut = 6,
		elbow = 25,
		knee = 8,
		headTilt = 6,
		sway = 2,
	}),
	walk = walk({
		length = 1.0,
		stride = 22,
		armSwing = 12,
		knee = 25,
		lean = -5,
		bob = 0.06,
		twist = 4,
		rock = 0,
		armForward = 8,
		armOut = 6,
		elbow = 20,
		limp = 0,
	}),
	stagger = stagger(1.1),
	death = death(true),

	-- A right-to-left horizontal slash. Short telegraph (0.5 s), so the windup
	-- is compact.
	[AnimationDefs.attack("Slash")] = strike(0.8, 0.35, 0.25, {
		UpperTorso = { ry = -35 },
		RightUpperArm = { rx = 100, rz = 70 },
		RightLowerArm = { rx = 40 },
		LeftUpperArm = { rx = 30, rz = -20 },
	}, {
		UpperTorso = { rx = -12, ry = 30 },
		RightUpperArm = { rx = 80, rz = -10 },
		RightLowerArm = { rx = 10 },
		LeftUpperArm = { rx = 20, rz = -30 },
	}),

	-- Two-handed, sword driven into the floor.
	[AnimationDefs.attack("GroundSlam")] = strike(1.1, 0.6, 0.45, {
		LowerTorso = { py = 0.15 },
		UpperTorso = { rx = 18 },
		RightUpperArm = { rx = 170, rz = 8 },
		LeftUpperArm = { rx = 170, rz = -8 },
		RightLowerArm = { rx = 15 },
		LeftLowerArm = { rx = 15 },
	}, merge(crouch(40), {
		UpperTorso = { rx = -40 },
		Head = { rx = -20 },
		RightUpperArm = { rx = 95, rz = -5 },
		LeftUpperArm = { rx = 95, rz = 5 },
	}), merge(crouch(25), {
		UpperTorso = { rx = -25 },
		RightUpperArm = { rx = 70 },
		LeftUpperArm = { rx = 70 },
	})),
}

SkeletonWarrior.hurt = hurt(SkeletonWarrior.idle, 1.0)

--[[ Shambler: a hunched zombie dragging its left leg, arms reaching out ]]

local Shambler: { [string]: AnimationDef } = {
	idle = idle({
		length = 2.8,
		lean = -18,
		breathe = 3,
		armForward = 70,
		armOut = 8,
		elbow = 15,
		knee = 15,
		headTilt = -12,
		sway = 5,
	}),
	walk = walk({
		length = 1.4,
		stride = 18,
		armSwing = 6,
		knee = 30,
		lean = -20,
		bob = 0.12,
		twist = 8,
		rock = 3,
		armForward = 75,
		armOut = 6,
		elbow = 12,
		limp = 0.6,
	}),
	stagger = stagger(1.0),
	death = death(false),

	-- Both arms rear up and rake down.
	[AnimationDefs.attack("Claw")] = strike(0.9, 0.5, 0.35, {
		UpperTorso = { rx = 10 },
		Head = { rx = 15 },
		RightUpperArm = { rx = 150, rz = 30 },
		LeftUpperArm = { rx = 150, rz = -30 },
		RightLowerArm = { rx = 60 },
		LeftLowerArm = { rx = 60 },
	}, {
		LowerTorso = { pz = -0.3 },
		UpperTorso = { rx = -35 },
		Head = { rx = -10 },
		RightUpperArm = { rx = 60, rz = 10 },
		LeftUpperArm = { rx = 60, rz = -10 },
		RightLowerArm = { rx = 5 },
		LeftLowerArm = { rx = 5 },
	}, {
		UpperTorso = { rx = -18 },
		RightUpperArm = { rx = 70 },
		LeftUpperArm = { rx = 70 },
	}),

	-- Coils low, then springs forward — the body visibly lurches ahead, though
	-- the hitbox itself stays put.
	[AnimationDefs.attack("Lunge")] = strike(1.3, 0.7, 0.55, merge(crouch(40), {
		UpperTorso = { rx = -30 },
		Head = { rx = 20 },
		RightUpperArm = { rx = -40, rz = 20 },
		LeftUpperArm = { rx = -40, rz = -20 },
	}), {
		LowerTorso = { pz = -1.4, py = 0.1 },
		UpperTorso = { rx = -50 },
		Head = { rx = 15 },
		RightUpperArm = { rx = 95, rz = 5 },
		LeftUpperArm = { rx = 95, rz = -5 },
		RightUpperLeg = { rx = -25 },
		LeftUpperLeg = { rx = 30 },
		LeftLowerLeg = { rx = -30 },
	}, {
		LowerTorso = { pz = -0.7 },
		UpperTorso = { rx = -30 },
		RightUpperArm = { rx = 60 },
		LeftUpperArm = { rx = 60 },
	}),
}

Shambler.hurt = hurt(Shambler.idle, 1.2)

--[[ Spitter: bloated, heaving, waddling side to side ]]

local Spitter: { [string]: AnimationDef } = {
	idle = idle({
		length = 2.0,
		lean = 6,
		breathe = 5,
		armForward = 10,
		armOut = 20,
		elbow = 30,
		knee = 12,
		headTilt = 0,
		sway = 0,
	}),
	walk = walk({
		length = 1.0,
		stride = 14,
		armSwing = 8,
		knee = 20,
		lean = 6,
		bob = 0.08,
		twist = 0,
		rock = 10,
		armForward = 10,
		armOut = 25,
		elbow = 30,
		limp = 0,
	}),
	stagger = stagger(0.9),
	death = death(true),

	-- Rears back gathering acid, then snaps forward.
	[AnimationDefs.attack("Spit")] = strike(1.2, 0.75, 0.6, merge(crouch(10), {
		UpperTorso = { rx = 25 },
		Head = { rx = 35 },
		RightUpperArm = { rz = 35 },
		LeftUpperArm = { rz = -35 },
	}), {
		UpperTorso = { rx = -25 },
		Head = { rx = -30 },
		RightUpperArm = { rx = -30, rz = 30 },
		LeftUpperArm = { rx = -30, rz = -30 },
	}),

	-- Swells, then bursts outward in every direction.
	[AnimationDefs.attack("Spray")] = strike(1.1, 0.6, 0.45, merge(crouch(25), {
		UpperTorso = { rx = -10 },
		RightUpperArm = { rx = 40, rz = -20 },
		LeftUpperArm = { rx = 40, rz = 20 },
		RightLowerArm = { rx = 60 },
		LeftLowerArm = { rx = 60 },
	}), {
		LowerTorso = { py = 0.25 },
		UpperTorso = { rx = 20 },
		Head = { rx = 30 },
		RightUpperArm = { rz = 100 },
		LeftUpperArm = { rz = -100 },
	}),
}

Spitter.hurt = hurt(Spitter.idle, 0.9)

--[[ The Hollow King: slow, heavy and deliberate, greatsword in the right hand ]]

local HollowKing: { [string]: AnimationDef } = {
	-- Shoulders heaving, sword arm low and ready.
	idle = idle({
		length = 3.2,
		lean = -6,
		breathe = 2.5,
		armForward = 14,
		armOut = 10,
		elbow = 22,
		knee = 10,
		headTilt = -4,
		sway = 2,
	}),
	-- A heavy stomp: short strides, deep bob, a rolling shoulder.
	walk = walk({
		length = 1.5,
		stride = 18,
		armSwing = 8,
		knee = 28,
		lean = -8,
		bob = 0.12,
		twist = 6,
		rock = 4,
		armForward = 14,
		armOut = 10,
		elbow = 20,
		limp = 0,
	}),
	stagger = stagger(1.2),
	death = death(false),

	-- A wide right-to-left sweep. The quickest thing it does.
	[AnimationDefs.attack("Cleave")] = strike(1.0, 0.45, 0.32, {
		UpperTorso = { rx = 6, ry = -45 },
		Head = { ry = 15 },
		RightUpperArm = { rx = 95, rz = 80 },
		RightLowerArm = { rx = 35 },
		LeftUpperArm = { rx = 35, rz = -25 },
	}, {
		UpperTorso = { rx = -14, ry = 40 },
		Head = { ry = -10 },
		RightUpperArm = { rx = 85, rz = -20 },
		RightLowerArm = { rx = 8 },
		LeftUpperArm = { rx = 15, rz = -40 },
	}, {
		UpperTorso = { rx = -6, ry = 20 },
		RightUpperArm = { rx = 50, rz = 5 },
		RightLowerArm = { rx = 20 },
		LeftUpperArm = { rx = 20, rz = -25 },
	}),

	-- Both hands high over the crown, then straight down.
	[AnimationDefs.attack("Overhead")] = strike(1.5, 0.8, 0.6, {
		LowerTorso = { py = 0.1 },
		UpperTorso = { rx = 18 },
		Head = { rx = 12 },
		RightUpperArm = { rx = 170, rz = 10 },
		LeftUpperArm = { rx = 165, rz = -10 },
		RightLowerArm = { rx = 25 },
		LeftLowerArm = { rx = 30 },
	}, merge(crouch(22), {
		UpperTorso = { rx = -38 },
		Head = { rx = -12 },
		RightUpperArm = { rx = 70, rz = -8 },
		LeftUpperArm = { rx = 70, rz = 8 },
		RightLowerArm = { rx = 5 },
		LeftLowerArm = { rx = 5 },
	}), merge(crouch(12), {
		UpperTorso = { rx = -20 },
		RightUpperArm = { rx = 50 },
		LeftUpperArm = { rx = 45 },
	})),

	-- Rears up and drives the sword into the floor: the room shakes.
	[AnimationDefs.attack("Shockwave")] = strike(1.8, 1.0, 0.75, {
		LowerTorso = { py = 0.2 },
		UpperTorso = { rx = 22 },
		Head = { rx = 18 },
		RightUpperArm = { rx = 175, rz = 20 },
		LeftUpperArm = { rx = 175, rz = -20 },
		RightLowerArm = { rx = 15 },
		LeftLowerArm = { rx = 15 },
	}, merge(crouch(38), {
		UpperTorso = { rx = -42 },
		Head = { rx = -22 },
		RightUpperArm = { rx = 95, rz = -6 },
		LeftUpperArm = { rx = 95, rz = 6 },
	}), merge(crouch(28), {
		UpperTorso = { rx = -30 },
		RightUpperArm = { rx = 80 },
		LeftUpperArm = { rx = 80 },
	})),

	-- Tears a shard of bone from its own ribs with the free hand and hurls it.
	[AnimationDefs.attack("BoneSpear")] = strike(1.4, 0.75, 0.55, {
		UpperTorso = { rx = 8, ry = 35 },
		Head = { ry = -20 },
		LeftUpperArm = { rx = -35, rz = -40 },
		LeftLowerArm = { rx = 70 },
		RightUpperArm = { rx = 20, rz = 20 },
	}, {
		UpperTorso = { rx = -12, ry = -30 },
		Head = { ry = 5 },
		LeftUpperArm = { rx = 105, rz = 5 },
		LeftLowerArm = { rx = 0 },
		RightUpperArm = { rx = 10, rz = 25 },
	}),
}

HollowKing.hurt = hurt(HollowKing.idle, 0.6)

--[[ Players: combat on a real R15 avatar ]]

-- Upper and lower leg lengths from hip to knee and knee to ankle (RigDefs).
local THIGH = 1.1
local SHIN = 1.1

-- A fighting step: the left foot forward and the right back, knees bent, hips
-- dropped so both feet stay on the floor, and the hips turned by `twist`
-- degrees. `front` and `back` are how far each thigh swings. Mirror it for a
-- right-foot-forward step.
local function footwork(front: number, back: number, twist: number): Poses
	-- The front knee bends past the thigh, the back knee a little further back.
	local frontShin = -0.3 * front
	local backShin = -1.5 * back
	local frontHeight = THIGH * math.cos(math.rad(front)) + SHIN * math.cos(math.rad(frontShin))
	local backHeight = THIGH * math.cos(math.rad(back)) + SHIN * math.cos(math.rad(backShin))
	local drop = (THIGH + SHIN) - (frontHeight + backHeight) / 2

	return {
		LowerTorso = { py = -drop, ry = twist },
		LeftUpperLeg = { rx = front },
		LeftLowerLeg = { rx = frontShin - front },
		LeftFoot = { rx = -frontShin },
		RightUpperLeg = { rx = -back },
		RightLowerLeg = { rx = backShin + back },
		RightFoot = { rx = -backShin },
	}
end

AnimationDefs.footwork = footwork

--[[ Rolling ]]

-- A combat roll: plant, tuck, go right over, and come up on your feet.
--
-- The whole body turns, which nothing else in this file does. `LowerTorso`
-- rotates everything hanging off it, so `rx` sweeping to a full turn is the
-- tumble itself, and `py` is the hips' height above where they stand.
--
-- The hips do not stay still while that happens, and getting that wrong is
-- what makes a roll read as a rig spinning on a spit. A tucked body rolls like
-- a wheel: its centre holds roughly one tuck-radius off the floor while the
-- hips orbit that centre, riding up as the shoulders go down and dropping as
-- the body comes over them. Which quarter is which differs between rolling
-- forwards and backwards, so the two carry different height curves — see
-- FORWARD_HIPS. None of those numbers is a guess: the workbench solves every
-- part of every animation against the floor, so a roll that drags a shoulder
-- through the ground fails the build instead of shipping.
--
-- Direction is a turn plus a sign, not four hand-authored rolls. `turn` aims
-- the body (`ry`, applied inside the tumble because CFrame.Angles multiplies
-- Rx * Ry * Rz, so the body is aimed first and then tumbled about the
-- character's own left-right axis), and `sign` picks which way it goes over.
-- Forward and back are the same tuck spun opposite ways, because a spine curls
-- the same way into both; the sideways pair are shoulder rolls, aimed on the
-- diagonal rather than flat, which is how a body actually gets over its own
-- side.

-- How far the sideways rolls turn the body before going over. A flat 90 is a
-- barrel roll, which reads as falling over; on the diagonal it reads as
-- dropping a shoulder and going over it.
local SHOULDER_TURN = 58

-- The curl. Everything is measured from this: the tighter the tuck, the
-- smaller the circle the head and heels travel, and the lower the hips can
-- ride without either of them reaching the floor.
--
-- The spine folds much further than a spine really folds. It has to: the neck
-- alone sits 1.5 studs from the hips, so a merely rounded back still swings
-- the head a full 3 studs below them halfway over — through the floor, at any
-- hip height low enough to look like a roll rather than a pirouette. Folding
-- the chest down onto the thighs brings the head inside 1.7, and the whole
-- tumble fits. It is on screen for about a fifth of a second.
local function tuck(depth: number): Poses
	local d = depth
	return {
		UpperTorso = { rx = -100 * d },
		Head = { rx = -62 * d },
		-- Arms drawn across the chest, out of the way of the floor.
		RightUpperArm = { rx = -18 * d, rz = 38 * d },
		LeftUpperArm = { rx = -18 * d, rz = -38 * d },
		RightLowerArm = { rx = 104 * d },
		LeftLowerArm = { rx = 104 * d },
		-- Knees to the chest, shins folded back under the thighs.
		RightUpperLeg = { rx = 96 * d },
		LeftUpperLeg = { rx = 88 * d },
		RightLowerLeg = { rx = -132 * d },
		LeftLowerLeg = { rx = -126 * d },
		RightFoot = { rx = 40 * d },
		LeftFoot = { rx = 38 * d },
	}
end

-- The tuck, turned and tumbled: `turn` degrees about Y, `angle` degrees of the
-- roll so far, with the hips `height` studs below where they stand.
local function tumble(turn: number, angle: number, height: number, depth: number): Poses
	return merge(tuck(depth), {
		LowerTorso = { rx = angle, ry = turn, py = height },
	})
end

-- A crouched pose with the hips left where `crouch` put them, so the feet stay
-- on the floor. Restating py is not optional: merge replaces a part's whole
-- pose, so any LowerTorso pose laid over a crouch drops its height correction
-- and drives the feet into the ground.
local function crouched(angle: number, extra: Poses): Poses
	local base = crouch(angle)
	local hips = table.clone(extra.LowerTorso or {})
	hips.py = (base.LowerTorso :: any).py
	local out = table.clone(extra)
	out.LowerTorso = hips
	return merge(base, out)
end

-- How far the hips sit below standing at each quarter of the tumble.
--
-- Not the same going forwards and backwards, and this is the part that has to
-- be measured rather than felt: the head passes the bottom of its arc early in
-- a forward roll and late in a backward one, so the hips have to be up out of
-- its way at opposite moments. Getting it wrong puts a head through the floor,
-- which is why the workbench solves every one of these against it.
local FORWARD_HIPS = { -0.62, -1.32, -1.08 }
local BACK_HIPS = { -1.05, -1.12, -0.34 }

-- One of the four rolls. `turn` aims the body before it goes over (0
-- forward and back, positive to the rig's left for a shoulder roll) and
-- `sign` picks which way it tumbles: -1 over the front, +1 over the back.
local function roll(turn: number, sign: number): AnimationDef
	local hips = if sign > 0 then BACK_HIPS else FORWARD_HIPS
	-- The turn, completed. Every pose after the tumble carries it, and so does
	-- the last keyframe, because the sampler interpolates these as plain
	-- numbers: land on 0 and the body unwinds the way it came, spinning 285
	-- degrees backwards over the three frames it had left to stand up in. A
	-- full turn is the identity rotation, so a rig holding 360 is a rig
	-- standing straight.
	local turned = sign * 360

	-- The plant: dropping into it, weight forward over a low, braced body. The
	-- hands are what reach the floor first, so they lead.
	local plant: Poses = crouched(52, {
		LowerTorso = { ry = turn * 0.55 },
		UpperTorso = { rx = -34 },
		Head = { rx = 14 },
		RightUpperArm = { rx = 52, rz = 22 },
		LeftUpperArm = { rx = 52, rz = -22 },
		RightLowerArm = { rx = 26 },
		LeftLowerArm = { rx = 26 },
	})

	-- Landing: feet back under the body, still low, one beat before standing.
	-- Coming out of a roll on straight legs is the single thing that makes one
	-- look weightless.
	local landing: Poses = crouched(44, {
		LowerTorso = { rx = turned, ry = turn * 0.4 },
		UpperTorso = { rx = -24 },
		Head = { rx = 12 },
		RightUpperArm = { rx = -16, rz = 30 },
		LeftUpperArm = { rx = -22, rz = -26 },
		RightLowerArm = { rx = 52 },
		LeftLowerArm = { rx = 46 },
	})

	local rise: Poses = crouched(18, {
		LowerTorso = { rx = turned },
		UpperTorso = { rx = -8 },
		RightUpperArm = { rx = -6, rz = 12 },
		LeftUpperArm = { rx = -8, rz = -12 },
		RightLowerArm = { rx = 22 },
		LeftLowerArm = { rx = 20 },
	})

	return {
		length = 0.62,
		looped = false,
		priority = "Action",
		keyframes = {
			kf(0, {}, "Out"),
			kf(0.07, plant, "In"),
			-- Over the shoulders, the hips riding up as they go: that rise is
			-- what stops a tumble reading as a rig turning on a spit.
			kf(0.15, tumble(turn, sign * 95, hips[1], 0.95), "Linear"),
			-- Inverted and fully curled, the hips at their lowest.
			kf(0.24, tumble(turn, sign * 190, hips[2], 1), "Linear"),
			-- Coming round, the legs already unfolding to find the floor.
			kf(0.33, tumble(turn, sign * 285, hips[3], 0.72), "Out"),
			kf(0.42, landing),
			kf(0.52, rise),
			kf(0.62, { LowerTorso = { rx = turned } }),
		},
	}
end

-- A looping stance: the pose, breathing slightly. Upper body only, so it sits
-- over Roblox's own walk and run.
local function stanceLoop(pose: Poses): AnimationDef
	-- The same three clocks as an enemy idle — breath, a late-arriving lag in
	-- the arms, and a slow sway — but upper body only, so Roblox's own walk
	-- and run keep playing underneath it.
	local function at(breath: number, lag: number, sway: number): Poses
		local poses = merge(pose)
		nudge(poses, "UpperTorso", -2 * breath, sway * 1.4, 0)
		nudge(poses, "Head", -breath, -sway * 1.8, sway * 0.8)
		nudge(poses, "RightUpperArm", 2 * lag, 0, sway)
		nudge(poses, "LeftUpperArm", 2 * lag, 0, sway)
		nudge(poses, "RightLowerArm", 1.5 * lag, 0, 0)
		nudge(poses, "LeftLowerArm", 1.5 * lag, 0, 0)
		return poses
	end

	local L = 2.4
	return {
		length = L,
		looped = true,
		priority = "Idle",
		keyframes = {
			kf(0, at(0, 0, 0)),
			kf(L * 0.25, at(0.8, 0.2, 1)),
			kf(L * 0.5, at(1, 0.8, 0)),
			kf(L * 0.75, at(0.35, 1, -1)),
			kf(L, at(0, 0, 0)),
		},
	}
end

-- A planted idle: a fighting stance with the feet actually in it.
--
-- `front` and `back` are how far each thigh swings (mirrored, so the right
-- foot leads), `twist` how far the hips turn off square, and `pose` the upper
-- body over it. The same three clocks as every other loop in this file —
-- breath, the arms arriving late, a slow shift of weight — but here the weight
-- shift reaches the legs too, because there is no walk cycle underneath to
-- argue with: the knees soften and straighten as the weight moves between the
-- feet, which is what stops a planted stance reading as a statue.
local function idleLoop(pose: Poses, front: number, back: number, twist: number): AnimationDef
	local footing = mirror(footwork(front, back, twist))
	local drop = (footing.LowerTorso :: any).py or 0
	local hipTurn = (footing.LowerTorso :: any).ry or 0

	-- One frame of a planted idle, at a given point in each of its three
	-- clocks. Unlike the walking stance's version this also moves the legs,
	-- softening and straightening the knees as the weight shifts.
	local function at(breath: number, lag: number, sway: number): Poses
		local poses = merge(footing, pose)
		-- Restated: merge replaces a part's whole pose, and the upper-body
		-- pose above carries no hips, so without this the footwork's height
		-- correction and hip turn are lost and the feet sink.
		poses.LowerTorso = {
			py = drop + math.abs(sway) * 0.06,
			ry = hipTurn + sway * 1.2,
			rz = sway * 1.6,
		}

		nudge(poses, "UpperTorso", -2 * breath, sway * 1.8, -sway * 0.8)
		nudge(poses, "Head", -breath, -sway * 2.4, sway * 1.1)
		nudge(poses, "RightUpperArm", 2 * lag, 0, sway)
		nudge(poses, "LeftUpperArm", 2 * lag, 0, sway)
		nudge(poses, "RightLowerArm", 1.5 * lag, 0, 0)
		nudge(poses, "LeftLowerArm", 1.5 * lag, 0, 0)
		-- The weight settling onto one leg and off the other.
		nudge(poses, "RightUpperLeg", -sway * 1.4, 0, 0)
		nudge(poses, "LeftUpperLeg", sway * 1.4, 0, 0)
		nudge(poses, "RightLowerLeg", sway * 1.1, 0, 0)
		nudge(poses, "LeftLowerLeg", -sway * 1.1, 0, 0)
		return poses
	end

	local L = 3.2
	return {
		length = L,
		looped = true,
		priority = "Idle",
		keyframes = {
			kf(0, at(0, 0, 0)),
			kf(L * 0.25, at(0.8, 0.2, 1)),
			kf(L * 0.5, at(1, 0.8, 0)),
			kf(L * 0.75, at(0.35, 1, -1)),
			kf(L, at(0, 0, 0)),
		},
	}
end

-- A snap into a guard pose that holds on its last frame. Upper body only, so
-- the player can still walk while guarding.
local function guardSnap(pose: Poses): AnimationDef
	return {
		length = 0.18,
		looped = false,
		priority = "Action",
		keyframes = {
			kf(0, {}, "Out"),
			kf(0.08, exaggerate(pose, 1.08)),
			kf(0.18, pose),
		},
	}
end

--[[ Weapons in the hand ]]

-- The weapon arms below are written as where the *weapon* goes, and
-- GripSolver works out the shoulder, elbow and wrist that put it there.
--
-- Written in root space: +X the rig's right, +Y up, -Z the way the character
-- faces, the origin at the hips as they stand (the floor is at y = -3). A
-- strike aims at something in front of the character wherever the torso has
-- twisted to on the way, and root space is where "in front" stays put. Each
-- pose is converted through its own hips and waist, so the torso twist that
-- drives a swing is still authored the old way, as angles, around it.
--
-- `at` is the fist, `point` the way the weapon runs from it (head, point or
-- upper limb), `edge` the way its edge or arrow faces, `pole` where the
-- elbow should go.
type Grip = { at: { number }, point: { number }, edge: { number }?, pole: { number }? }

-- `poses` with `side`'s arm holding the weapon as `grip` says.
local function wield(poses: Poses, side: string, grip: Grip): Poses
	local chest = GripSolver.chestFrame(poses)
	local arm = GripSolver.hold(side, {
		at = chest.toPoint(grip.at),
		point = chest.toVector(grip.point),
		edge = if grip.edge then chest.toVector(grip.edge) else nil,
		pole = if grip.pole then chest.toVector(grip.pole) else nil,
	})
	return merge(poses, arm :: any)
end

-- `poses` with only a wrist turned, so the blade the authored arm carries
-- points along `point` (root space). The right hand unless `side` says.
--
-- Every swing of a bladed weapon sets its wrists this way, and has to: a
-- part a swing leaves unposed keeps whatever the stance under it had
-- (RigAnimation), so a swing that said nothing about the wrist was thrown
-- with the stance's resting droop — daggers stabbing with their points at
-- the floor, a sword cutting with its blade at the sky.
local function aimed(poses: Poses, point: { number }, side: string?): Poses
	local hand = side or "Right"
	local chest = GripSolver.chestFrame(poses)
	local wrist = GripSolver.aim(poses :: any, hand, chest.toVector(point))
	return merge(poses, { [`{hand}Hand`] = wrist })
end

-- Where a blade points at each beat of a strike, in root space. `follow`
-- defaults to `hit`, and `recovery` is only used by a strike that has one.
type BladeAims = { windup: { number }, hit: { number }, follow: { number }?, recovery: { number }? }

-- Where a blade points in the anticipation beat: level-ish, at the target.
local READY_POINT = { 0, 0.25, -1 }

-- A strike or guard with its wrists set, so each blade points where the
-- swing is going rather than wherever the arm happens to leave it.
--
-- Applied over the finished keyframes of `strike` (or `guardSnap`), each one
-- aimed from its own arm: that way the anticipation and coil, which `strike`
-- derives by scaling the windup, still carry a blade pointing the windup's
-- way instead of a scaled wrist pointing somewhere new. The rest keyframes at
-- either end are left alone — that is the stance's wrist, faded to.
local function aimBlades(anim: AnimationDef, aims: { Right: BladeAims?, Left: BladeAims? }): AnimationDef
	local keyframes = table.clone(anim.keyframes)
	local last = #keyframes
	for side, spec in aims :: any do
		local byIndex: { [number]: { number } }
		if last == 3 then
			-- A guard: rest, the overshoot, the held pose.
			byIndex = { [2] = spec.hit, [3] = spec.hit }
		else
			-- rest, anticipation, windup, coil, impact, follow, [recovery], rest.
			-- The anticipation points the blade at the target, ready, rather than
			-- the windup's way: it is the windup scaled back past rest, and a blade
			-- aimed backward from an arm that has barely moved would need a wrist
			-- bent double.
			byIndex = { [2] = READY_POINT, [3] = spec.windup, [4] = spec.windup, [5] = spec.hit, [6] = spec.follow or spec.hit }
			if last == 8 then
				byIndex[7] = spec.recovery or spec.hit
			end
		end
		for index, point in byIndex do
			local keyframe = keyframes[index]
			keyframes[index] = {
				time = keyframe.time,
				easing = keyframe.easing,
				poses = aimed(keyframe.poses, point, side),
			}
		end
	end
	local copy = table.clone(anim)
	copy.keyframes = keyframes
	return copy
end

-- The same animation with the left hand put on the haft of whatever the
-- right holds, `along` studs from the right fist (positive toward the head),
-- in every keyframe.
--
-- Done last, over the finished keyframes, because `strike` derives its
-- anticipation and coil by scaling angles: scaling two arms' angles does not
-- keep two fists on one haft, but re-solving the second arm against wherever
-- the first ended up does. Each keyframe is solved near the one before it so
-- the angles stay continuous, and a loop's last frame reuses its first so the
-- loop still closes exactly.
--
-- Solving only at the authored keyframes is not enough: between two of them
-- each joint is interpolated on its own, and two arms interpolated
-- independently drift apart — mid-swing, the second fist came a couple of
-- studs off the haft. So the animation is resampled at TWO_HANDED_RATE, every
-- authored keyframe kept (the impact among them), and the second arm solved
-- at each sample. The samples are joined linearly: they are dense enough to
-- carry the original easing in their spacing.
local TWO_HANDED_RATE = 30

local function twoHanded(anim: AnimationDef, along: number, pole: { number }?): AnimationDef
	local times: { number } = {}
	for _, keyframe in anim.keyframes do
		table.insert(times, keyframe.time)
	end
	local steps = math.ceil(anim.length * TWO_HANDED_RATE)
	for step = 1, steps - 1 do
		local t = anim.length * step / steps
		local near = false
		for _, existing in times do
			if math.abs(existing - t) < 0.2 / TWO_HANDED_RATE then
				near = true
				break
			end
		end
		if not near then
			table.insert(times, t)
		end
	end
	table.sort(times)

	local keyframes = {}
	local previous: Poses? = nil
	for index, t in times do
		local sampled: Poses = KeyframeMath.sample(anim, t) :: any
		local chest = GripSolver.chestFrame(sampled :: any)
		local chestPole = if pole then chest.toVector(pole) else nil
		-- Where the second fist cannot reach its place on the haft — the far
		-- end of a spin, say — it slides up toward the first, which is what
		-- hands on a haft actually do, rather than letting go of it.
		local offHand, shortfall = GripSolver.offHand(sampled :: any, "Right", along, chestPole, previous :: any)
		for _, slide in { 0.7, 0.45, 0.25 } do
			if shortfall <= 0.05 then
				break
			end
			local slid, slidShort = GripSolver.offHand(sampled :: any, "Right", along * slide, chestPole, previous :: any)
			if slidShort < shortfall then
				offHand, shortfall = slid, slidShort
			end
		end
		if anim.looped and index == #times and keyframes[1] then
			offHand = {
				LeftUpperArm = keyframes[1].poses.LeftUpperArm,
				LeftLowerArm = keyframes[1].poses.LeftLowerArm,
				LeftHand = keyframes[1].poses.LeftHand,
			} :: any
		end
		previous = offHand :: any
		table.insert(keyframes, kf(t, merge(sampled, offHand :: any), "Linear"))
	end
	local copy = table.clone(anim)
	copy.keyframes = keyframes
	return copy
end

-- A body pose and where the weapon is in it: one beat of a two-handed strike.
type Held = { body: Poses, grip: Grip }

-- `body` with the weapon at `grip`. The two-handed strikes are written as a
-- run of these; heavyStrike does the arms.
local function held(body: Poses, _side: string, grip: Grip): Held
	return { body = body, grip = grip }
end

local function vlerp(a: { number }, b: { number }, t: number): { number }
	return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

local function vunit(a: { number }): { number }
	local l = math.sqrt(a[1] ^ 2 + a[2] ^ 2 + a[3] ^ 2)
	return { a[1] / l, a[2] / l, a[3] / l }
end

-- Turns direction `a` toward direction `b` by fraction `t` of the angle
-- between them, about the axis they share (t past 1 carries on turning).
-- Unlike blending the vectors, this keeps a steady turning speed and never
-- passes through a zero-length direction when the two are far apart.
local function slerp(a: { number }, b: { number }, t: number): { number }
	local ua, ub = vunit(a), vunit(b)
	local cosine = math.clamp(ua[1] * ub[1] + ua[2] * ub[2] + ua[3] * ub[3], -1, 1)
	local angle = math.acos(cosine)
	if angle < 1e-4 then
		return vunit(vlerp(ua, ub, t))
	end
	local axis = { ua[2] * ub[3] - ua[3] * ub[2], ua[3] * ub[1] - ua[1] * ub[3], ua[1] * ub[2] - ua[2] * ub[1] }
	if math.sqrt(axis[1] ^ 2 + axis[2] ^ 2 + axis[3] ^ 2) < 1e-6 then
		-- Opposite directions: turn over the top.
		axis = { 1, 0, 0 }
	end
	local k = vunit(axis)
	local theta = angle * t
	local c, s = math.cos(theta), math.sin(theta)
	local kxa = { k[2] * ua[3] - k[3] * ua[2], k[3] * ua[1] - k[1] * ua[3], k[1] * ua[2] - k[2] * ua[1] }
	local kda = k[1] * ua[1] + k[2] * ua[2] + k[3] * ua[3]
	return {
		ua[1] * c + kxa[1] * s + k[1] * kda * (1 - c),
		ua[2] * c + kxa[2] * s + k[2] * kda * (1 - c),
		ua[3] * c + kxa[3] * s + k[3] * kda * (1 - c),
	}
end

-- Where the weapon is `t` of the way from `a` to `b`: the fist moving in a
-- straight line, the weapon turning at a steady rate.
local function gripBetween(a: Grip, b: Grip, t: number): Grip
	return {
		at = vlerp(a.at, b.at, t),
		point = slerp(a.point, b.point, t),
		edge = if a.edge and b.edge then slerp(a.edge, b.edge, t) else nil,
	}
end

local ARM_PARTS = {
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
}

-- Resamples how far the second fist sits down the haft from the first.
local HAFT_SPACING = -1.0

-- A strike with a two-handed weapon, keyed by where the *weapon* is.
--
-- `strike` makes a swing by interpolating joint angles between key poses and
-- scaling them for the coil and follow-through. For a weapon held in two
-- fists neither survives: two arms interpolated separately drift off one
-- haft, an arm's angles interpolated between two solved poses can swing the
-- weapon round the long way, and a scaled angle turns the head off the line
-- of the cut. So here the body is still `strike`'s — its anticipation, coil
-- and carry are right for a body — but the weapon moves along its own path:
-- the fist in a straight line and the haft turning steadily between the
-- beats, and both arms solved (GripSolver) at TWO_HANDED_RATE along the way.
--
-- It starts from and returns to `ready`, the weapon at the ready in both
-- hands, rather than rest: rest is arms hanging, which for a haft through
-- both fists puts the head on the floor.
local function heavyStrike(
	length: number,
	impact: number,
	windupAt: number,
	ready: Grip,
	windup: Held,
	hit: Held,
	recovery: Held?
): AnimationDef
	local body = strike(length, impact, windupAt, windup.body, hit.body, if recovery then recovery.body else nil)
	local coilAt = windupAt + (impact - windupAt) * 0.45
	local followAt = impact + math.min(0.07, (length - impact) * 0.2)

	-- The weapon's own beats. The coil draws it a little further back than
	-- the windup, and the follow-through carries it on past the hit along
	-- the line it was travelling.
	type Beat = { time: number, grip: Grip, easing: KeyframeMath.Easing }
	local beats: { Beat } = {
		{ time = 0, grip = ready, easing = "Out" },
		{ time = windupAt * 0.4, grip = gripBetween(ready, windup.grip, 0.3), easing = "Smooth" },
		{ time = windupAt, grip = windup.grip, easing = "Smooth" },
		{ time = coilAt, grip = gripBetween(ready, windup.grip, 1.08), easing = "In" },
		{ time = impact, grip = hit.grip, easing = "Out" },
		{ time = followAt, grip = gripBetween(windup.grip, hit.grip, 1.1), easing = "Smooth" },
	}
	if recovery then
		table.insert(beats, { time = followAt + (length - followAt) * 0.5, grip = recovery.grip, easing = "Smooth" })
	end
	table.insert(beats, { time = length, grip = ready, easing = "Smooth" })

	local function gripAt(t: number): Grip
		for index = 1, #beats - 1 do
			local from, to = beats[index], beats[index + 1]
			if t <= to.time then
				local span = to.time - from.time
				local alpha = if span > 0 then KeyframeMath.ease(from.easing, (t - from.time) / span) else 1
				return gripBetween(from.grip, to.grip, alpha)
			end
		end
		return beats[#beats].grip
	end

	local times: { number } = {}
	for _, beat in beats do
		table.insert(times, beat.time)
	end
	local function addTime(t: number, rate: number)
		for _, existing in times do
			if math.abs(existing - t) < 0.2 / rate then
				return
			end
		end
		table.insert(times, t)
	end
	local steps = math.ceil(length * TWO_HANDED_RATE)
	for step = 1, steps - 1 do
		addTime(length * step / steps, TWO_HANDED_RATE)
	end
	-- The snap from the coil into the hit is the fastest the weapon ever
	-- moves, so it gets three times the samples: that is where two arms
	-- solved a frame apart would otherwise come furthest apart in between.
	local fast = TWO_HANDED_RATE * 3
	local fastSteps = math.ceil((followAt - coilAt) * fast)
	for step = 1, fastSteps - 1 do
		addTime(coilAt + (followAt - coilAt) * step / fastSteps, fast)
	end
	table.sort(times)

	local keyframes = {}
	local previous: Poses = {}
	for _, t in times do
		local poses: Poses = {}
		for part, values in KeyframeMath.sample(body, t) do
			if not ARM_PARTS[part] then
				poses[part] = values
			end
		end
		local grip = gripAt(t)
		local chest = GripSolver.chestFrame(poses :: any)
		local right = GripSolver.hold("Right", {
			at = chest.toPoint(grip.at),
			point = chest.toVector(grip.point),
			edge = if grip.edge then chest.toVector(grip.edge) else nil,
		}, previous :: any)
		poses = merge(poses, right :: any)

		-- Where the second fist cannot reach its place on the haft it slides
		-- up toward the first, which is what hands on a haft do.
		local left, shortfall = GripSolver.offHand(poses :: any, "Right", HAFT_SPACING, nil, previous :: any)
		for _, slide in { 0.7, 0.45, 0.25 } do
			if shortfall <= 0.05 then
				break
			end
			local slid, slidShort = GripSolver.offHand(poses :: any, "Right", HAFT_SPACING * slide, nil, previous :: any)
			if slidShort < shortfall then
				left, shortfall = slid, slidShort
			end
		end
		poses = merge(poses, left :: any)
		previous = poses
		table.insert(keyframes, kf(t, poses, "Linear"))
	end

	return {
		length = length,
		looped = false,
		priority = "Action",
		impact = impact,
		keyframes = keyframes,
	}
end

-- A direction, not yet unit length; GripSolver normalises.
local function dir(x: number, y: number, z: number): { number }
	return { x, y, z }
end

local SHIELD_UP: Poses = {
	LeftUpperArm = { rx = 55, rz = -10 },
	LeftLowerArm = { rx = 80 },
}

local SHIELD_BACK: Poses = {
	LeftUpperArm = { rx = 30, rz = -28 },
	LeftLowerArm = { rx = 70 },
}

-- The shield lowered to the side, carried rather than held up. Only for the
-- resting stance; every guard and swing still raises it.
local SHIELD_DOWN: Poses = {
	LeftUpperArm = { rx = 10, rz = -7 },
	LeftLowerArm = { rx = 28 },
}

--[[ The bow: a shot, rather than a swing ]]

-- A shot is not a strike. `strike` builds a swing out of a windup pose, an
-- exaggerated coil and a hit, by scaling joint angles — which is right for a
-- blade and wrong for a bow, where the thing that must not move while the
-- draw builds is the bow. So a shot is keyed from where the bow and the
-- string hand are, every beat solved (GripSolver) rather than scaled:
--
--   raise    the bow comes up on target, the string hand meets the string
--   draw     the string hand pulls back to the anchor under the jaw
--   release  the impact: still at the anchor — the arrow leaves from there
--   follow   the string hand flicks back off the face; the bow stays up
--   settle   the bow comes down, the string hand drops toward the quiver
--
-- The body is side-on with the **left** shoulder at the target, which is how
-- a bow held in the left hand is shot. The first version had it turned the
-- other way, right shoulder leading, with the bow arm reaching across the
-- chest to a target on the wrong side of it.
--
-- The draw is measured along the arrow, from the bow fist back to the
-- anchor. BowVFX pulls the string back to wherever the right hand is while
-- it is behind the string, and the server's shot is what lets it go.

-- Under the chin, a little to the right: where the string hand anchors.
local BOW_ANCHOR = { 0.1, 1.75, -0.8 }
-- The arrow rests above the fist by this much (WeaponModelDefs.BOW.arrowZ).
local ARROW_RISE = 0.32

-- The bow arm and its fist for a draw of `draw` studs, aimed `lift` degrees
-- above level. The fist is placed so that the arrow line runs back through
-- the anchor, which is what makes the draw read as aimed down the arrow.
local function bowFist(draw: number, lift: number): ({ number }, { number })
	local l = math.rad(lift)
	local forward = { 0, math.sin(l), -math.cos(l) }
	return {
		BOW_ANCHOR[1] + forward[1] * draw,
		BOW_ANCHOR[2] + forward[2] * draw - ARROW_RISE,
		BOW_ANCHOR[3] + forward[3] * draw,
	}, forward
end

-- The bow carried low in front of the left hip, upright, an arrow already on
-- the string. The walking stance, and where every shot starts and settles —
-- a shot keyed from rest would begin and end with the arms hanging, which
-- for a bow means an arrow pointing into the floor.
local BOW_CARRY: Poses = wield({
	UpperTorso = { ry = -12 },
	Head = { ry = 10 },
	RightUpperArm = { rx = 10, rz = 10 },
	RightLowerArm = { rx = 30 },
}, "Left", { at = { -1.3, 0.55, -1.0 }, point = dir(0.25, 1, -0.55), edge = dir(0.15, 0, -1) })

type ShotSpec = {
	length: number,
	impact: number,
	-- How far the string comes back, and how high the shot is aimed.
	draw: number,
	lift: number,
	-- Hips and chest for the whole shot. Side-on: left shoulder forward.
	body: Poses,
	-- How far the string hand flies back off the anchor on release.
	kick: number,
}

local function shot(spec: ShotSpec): AnimationDef
	local fist, forward = bowFist(spec.draw, spec.lift)
	-- The bow stands up with a slight cant, arrow on target.
	local bow: Grip = { at = fist, point = dir(0.12, 1, forward[2] * 0.4), edge = forward, pole = dir(-1, -0.4, 0.2) }
	local elbowOut = dir(1, 0.35, 0.8)

	local function frame(stringHand: Grip, bowGrip: Grip?): Poses
		local poses = wield(spec.body, "Left", bowGrip or bow)
		return wield(poses, "Right", stringHand)
	end

	-- The string at rest is a little in front of the anchor end of the draw.
	local nock = {
		fist[1] - forward[1] * 0.75,
		fist[2] + ARROW_RISE - forward[2] * 0.75,
		fist[3] - forward[3] * 0.75,
	}
	local anchor = { BOW_ANCHOR[1], BOW_ANCHOR[2], BOW_ANCHOR[3] }
	local deep = { anchor[1], anchor[2], anchor[3] + 0.08 }
	local flick = { anchor[1] + 0.5, anchor[2] + 0.2, anchor[3] + spec.kick }

	local raiseAt = spec.impact * 0.3
	local drawAt = spec.impact * 0.72
	local followAt = spec.impact + math.min(0.09, (spec.length - spec.impact) * 0.25)
	local settleAt = followAt + (spec.length - followAt) * 0.5

	-- Coming down: bow lowered and canted, the string hand off toward the
	-- quiver on the back.
	local lowered: Grip = { at = { -0.9, 0.9, -1.9 }, point = dir(0.35, 1, -0.3), edge = forward, pole = bow.pole }

	return {
		length = spec.length,
		looped = false,
		priority = "Action",
		impact = spec.impact,
		keyframes = {
			kf(0, BOW_CARRY, "Out"),
			kf(raiseAt, frame({ at = nock, point = forward, pole = elbowOut })),
			kf(drawAt, frame({ at = anchor, point = forward, pole = elbowOut }), "In"),
			kf(spec.impact, frame({ at = deep, point = forward, pole = elbowOut }), "Out"),
			kf(followAt, frame({ at = flick, point = dir(0.3, 0.4, -1), pole = elbowOut })),
			kf(settleAt, frame({ at = { 0.9, 0.9, -0.9 }, point = dir(0, 0.2, -1) }, lowered)),
			kf(spec.length, BOW_CARRY),
		},
	}
end

-- Side-on for a left-handed bow: the hips turned right and the chest further,
-- left foot leading, head turned back round to look down the arrow.
local function archerBody(twist: number, lean: number): Poses
	return merge(footwork(8, 12, -30), {
		UpperTorso = { rx = lean, ry = twist + 30 },
		Head = { rx = -2, ry = -twist - 4 },
	})
end

-- The two-handed weapons at the ready, held diagonally across the body: what
-- every one of their strikes starts from and settles back into (heavyStrike).
local STAFF_READY: Grip = { at = { 0.35, 1.15, -1.45 }, point = dir(0.5, 0.85, -0.3) }
local AXE_READY: Grip = {
	at = { 0.3, 1.1, -1.4 },
	point = dir(0.5, 0.85, -0.3),
	edge = dir(0.7, 0, -0.7),
}

local R15Player: { [string]: AnimationDef } = {
	--[[ Sword & Shield ]]

	-- At rest: the sword hangs point-down, shield lowered off the arm.
	--
	-- How far a resting weapon can dip is set by its length, not by taste. The
	-- hand sits about 2.3 studs up, and a piece `L` long angled `a` below
	-- horizontal puts its tip at 2.3 - L*sin(a) — so the arming sword, at
	-- roughly 4.5 studs from grip to point, can only drop about 25 degrees
	-- before the tip is through the floor. The wrist does the dipping, because
	-- swinging the shoulder back far enough to aim the blade down reads as
	-- winding up, not resting.
	[AnimationDefs.stance("SwordAndShield")] = stanceLoop(merge(SHIELD_DOWN, {
		UpperTorso = { ry = 8 },
		Head = { ry = -8 },
		RightUpperArm = { rx = 6, rz = 6 },
		RightLowerArm = { rx = 12 },
		-- Sums with the arm above it to about -18: tip clear of the floor, with
		-- room left for a swing to dip it further on the way into its windup.
		RightHand = { rx = -36 },
	})),

	-- Standing still: side-on behind the shield, sword drawn back low and
	-- across the body, ready to come up. The shield leads because that is what
	-- this class is — the first thing an enemy meets is the board.
	[AnimationDefs.idle("SwordAndShield")] = idleLoop(merge(SHIELD_BACK, {
		UpperTorso = { rx = -4, ry = 26 },
		Head = { ry = -30 },
		LeftUpperArm = { rx = 62, rz = -16 },
		LeftLowerArm = { rx = 74 },
		RightUpperArm = { rx = -18, ry = 10, rz = 14 },
		RightLowerArm = { rx = 34 },
		RightHand = { rx = -30 },
	}), 20, 16, 30),

	-- Shield up in front of the face, sword held low and ready.
	[AnimationDefs.guard("SwordAndShield")] = guardSnap({
		UpperTorso = { rx = -6, ry = 18 },
		Head = { ry = -10 },
		LeftUpperArm = { rx = 98, rz = -4 },
		LeftLowerArm = { rx = 95 },
		RightUpperArm = { rx = 30, rz = 25 },
		RightLowerArm = { rx = 60 },
	}),

	-- 1: diagonal cut, high right to low left.
	[AnimationDefs.swing("SwordAndShield", 1)] = strike(0.65, 0.28, 0.17, merge(SHIELD_UP, footwork(8, 6, -15), {
		UpperTorso = { rx = 4, ry = -40 },
		Head = { ry = 25 },
		RightUpperArm = { rx = 155, rz = 55 },
		RightLowerArm = { rx = 50 },
	}), merge(SHIELD_BACK, footwork(30, 20, 20), {
		UpperTorso = { rx = -18, ry = 35 },
		Head = { ry = -15 },
		RightUpperArm = { rx = 55, rz = -30 },
		RightLowerArm = { rx = 10 },
	}), merge(SHIELD_UP, footwork(15, 10, 10), {
		UpperTorso = { rx = -8, ry = 20 },
		RightUpperArm = { rx = 40 },
		RightLowerArm = { rx = 30 },
	})),

	-- 2: rising cut, low left to high right.
	[AnimationDefs.swing("SwordAndShield", 2)] = strike(0.62, 0.26, 0.15, merge(SHIELD_BACK, footwork(18, 14, 15), {
		UpperTorso = { rx = -10, ry = 40 },
		Head = { ry = -15 },
		RightUpperArm = { rx = 45, rz = -40 },
		RightLowerArm = { rx = 60 },
	}), merge(SHIELD_UP, footwork(28, 18, -15), {
		UpperTorso = { rx = 8, ry = -35 },
		Head = { ry = 15 },
		RightUpperArm = { rx = 118, rz = 58 },
		RightLowerArm = { rx = 15 },
	}), merge(SHIELD_UP, footwork(14, 10, -8), {
		UpperTorso = { ry = -15 },
		RightUpperArm = { rx = 60, rz = 25 },
		RightLowerArm = { rx = 35 },
	})),

	-- 3: flat cut, right to left.
	[AnimationDefs.swing("SwordAndShield", 3)] = strike(0.62, 0.26, 0.15, merge(SHIELD_UP, footwork(10, 8, -20), {
		UpperTorso = { ry = -55 },
		Head = { ry = 30 },
		RightUpperArm = { rx = 90, rz = 85 },
		RightLowerArm = { rx = 40 },
	}), merge(SHIELD_BACK, footwork(32, 22, 25), {
		UpperTorso = { rx = -10, ry = 50 },
		Head = { ry = -20 },
		RightUpperArm = { rx = 90, rz = -35 },
		RightLowerArm = { rx = 5 },
	}), merge(SHIELD_UP, footwork(16, 11, 12), {
		UpperTorso = { rx = -4, ry = 22 },
		RightUpperArm = { rx = 55, rz = 5 },
		RightLowerArm = { rx = 30 },
	})),

	-- 4, the finisher: both hands over the head, then a chop straight down.
	[AnimationDefs.swing("SwordAndShield", 4)] = strike(0.9, 0.36, 0.22, merge(footwork(5, 5, 0), {
		UpperTorso = { rx = 16, ry = -12 },
		Head = { rx = 10 },
		RightUpperArm = { rx = 175, rz = 12 },
		RightLowerArm = { rx = 55 },
		LeftUpperArm = { rx = 140, rz = -15 },
		LeftLowerArm = { rx = 40 },
	}), merge(footwork(38, 26, 0), {
		UpperTorso = { rx = -38 },
		Head = { rx = -12 },
		RightUpperArm = { rx = 40, rz = 5 },
		RightLowerArm = { rx = 5 },
		LeftUpperArm = { rx = 30, rz = -20 },
		LeftLowerArm = { rx = 60 },
	}), merge(SHIELD_UP, footwork(20, 14, 0), {
		UpperTorso = { rx = -18 },
		RightUpperArm = { rx = 30 },
		RightLowerArm = { rx = 20 },
	})),

	-- Critical: wound all the way back, then a spinning cleave.
	[AnimationDefs.critical("SwordAndShield")] = strike(1.3, 0.6, 0.4, merge(footwork(12, 20, -35), {
		UpperTorso = { rx = 10, ry = -80 },
		Head = { ry = 45 },
		RightUpperArm = { rx = 100, rz = 90 },
		RightLowerArm = { rx = 60 },
		LeftUpperArm = { rx = 70, rz = -40 },
		LeftLowerArm = { rx = 60 },
	}), merge(footwork(40, 28, 40), {
		UpperTorso = { rx = -15, ry = 75 },
		Head = { ry = -30 },
		RightUpperArm = { rx = 90, rz = -45 },
		RightLowerArm = { rx = 0 },
		LeftUpperArm = { rx = 20, rz = -60 },
		LeftLowerArm = { rx = 40 },
	}), merge(SHIELD_UP, footwork(22, 16, 20), {
		UpperTorso = { rx = -8, ry = 35 },
		RightUpperArm = { rx = 50, rz = 10 },
		RightLowerArm = { rx = 30 },
	})),

	-- The three moves off the combo. Each is authored so its `impact` sits at
	-- the same fraction of its length the combo swings use, because playback
	-- stretches everything before the impact to the server's wind-up and a
	-- clip whose proportions are wildly different gets stretched oddly.

	-- Thrust: the shield comes across to cover, the body turns side-on, and
	-- the sword goes straight out from the hip. Narrow, long, and it carries
	-- the player forward -- the only move here that closes distance.
	[AnimationDefs.move("SwordAndShield", "Thrust")] = strike(0.68, 0.3, 0.18, merge(SHIELD_UP, footwork(6, 16, -30), {
		UpperTorso = { rx = 2, ry = -28 },
		Head = { ry = 20 },
		RightUpperArm = { rx = 25, ry = -20, rz = 10 },
		RightLowerArm = { rx = 95 },
	}), merge(SHIELD_BACK, footwork(34, 14, 18), {
		UpperTorso = { rx = 6, ry = 24 },
		Head = { ry = -8 },
		RightUpperArm = { rx = 78, ry = 10, rz = -6 },
		RightLowerArm = { rx = 6 },
	}), merge(SHIELD_UP, footwork(18, 12, 8), {
		UpperTorso = { rx = 2, ry = 10 },
		RightUpperArm = { rx = 50, rz = -4 },
		RightLowerArm = { rx = 34 },
	})),

	-- Kick: the shield stays up and square -- this is a move you throw
	-- *while* covered -- and the leg does the work. Short, and the recovery
	-- settles the foot back down rather than carrying through, because the
	-- point of it is to still be standing where you were.
	[AnimationDefs.move("SwordAndShield", "Kick")] = strike(0.58, 0.26, 0.15, merge(SHIELD_UP, {
		LowerTorso = { rx = -6, py = -0.08 },
		UpperTorso = { rx = -8 },
		RightUpperArm = { rx = 20, rz = -14 },
		RightLowerArm = { rx = 24 },
		RightUpperLeg = { rx = -28 },
		RightLowerLeg = { rx = 50 },
		LeftUpperLeg = { rx = 10 },
		LeftLowerLeg = { rx = -18 },
	}), merge(SHIELD_UP, {
		LowerTorso = { rx = -14, py = -0.12 },
		UpperTorso = { rx = -16 },
		RightUpperArm = { rx = 16, rz = -18 },
		RightUpperLeg = { rx = 62 },
		RightLowerLeg = { rx = -8 },
		RightFoot = { rx = -20 },
		LeftUpperLeg = { rx = 16 },
		LeftLowerLeg = { rx = -26 },
	}), merge(SHIELD_UP, {
		LowerTorso = { rx = -4, py = -0.06 },
		UpperTorso = { rx = -6 },
		RightUpperArm = { rx = 20, rz = -14 },
		RightUpperLeg = { rx = 14 },
		RightLowerLeg = { rx = -20 },
		LeftUpperLeg = { rx = 8 },
		LeftLowerLeg = { rx = -14 },
	})),

	-- Shield Bash: the whole body winds behind the shield and drives through
	-- it. The sword arm tucks out of the way -- it is doing nothing here,
	-- which is the read: a bash coming is a bash, not a cut.
	[AnimationDefs.move("SwordAndShield", "ShieldBash")] = strike(0.72, 0.31, 0.19, merge(footwork(8, 18, 26), {
		UpperTorso = { rx = 6, ry = 30 },
		Head = { ry = -22 },
		LeftUpperArm = { rx = 48, ry = 18, rz = -16 },
		LeftLowerArm = { rx = 88 },
		RightUpperArm = { rx = 12, ry = 24, rz = -22 },
		RightLowerArm = { rx = 58 },
	}), merge(footwork(32, 12, -30), {
		UpperTorso = { rx = -10, ry = -26 },
		Head = { ry = 16 },
		LeftUpperArm = { rx = 74, ry = -14, rz = 6 },
		LeftLowerArm = { rx = 42 },
		RightUpperArm = { rx = 18, ry = 30, rz = -26 },
		RightLowerArm = { rx = 64 },
	}), merge(SHIELD_UP, footwork(18, 12, -10), {
		UpperTorso = { rx = -4, ry = -10 },
		RightUpperArm = { rx = 22, rz = -18 },
		RightLowerArm = { rx = 50 },
	})),

	--[[ Daggers ]]

	-- Low and forward, both blades ready.
	-- Daggers are short enough (about 1.8 studs) to hang almost straight down
	-- without the points reaching the floor, so they get the full drop.
	[AnimationDefs.stance("Daggers")] = stanceLoop({
		UpperTorso = { rx = -4 },
		Head = { rx = 4 },
		RightUpperArm = { rx = 8, rz = 7 },
		RightLowerArm = { rx = 14 },
		RightHand = { rx = -96 },
		LeftUpperArm = { rx = 8, rz = -7 },
		LeftLowerArm = { rx = 14 },
		LeftHand = { rx = -96 },
	}),

	-- Standing still: low and coiled, nearly side-on, one blade forward at the
	-- hip and the other held back in a reverse grip. Weight on the back foot,
	-- so the whole pose reads as about to leave the spot it is on.
	[AnimationDefs.idle("Daggers")] = idleLoop({
		UpperTorso = { rx = -12, ry = 34 },
		Head = { rx = 8, ry = -40 },
		RightUpperArm = { rx = 26, ry = 16, rz = 10 },
		RightLowerArm = { rx = 58 },
		RightHand = { rx = -80 },
		LeftUpperArm = { rx = -34, ry = -14, rz = -18 },
		LeftLowerArm = { rx = 68 },
		LeftHand = { rx = -104 },
	}, 24, 20, 36),

	-- Blades crossed in front of the face.
	[AnimationDefs.guard("Daggers")] = guardSnap({
		UpperTorso = { rx = -8 },
		RightUpperArm = { rx = 95, rz = -30 },
		LeftUpperArm = { rx = 95, rz = 30 },
		RightLowerArm = { rx = 85 },
		LeftLowerArm = { rx = 85 },
	}),

	-- 1: right jab.
	[AnimationDefs.swing("Daggers", 1)] = strike(0.45, 0.16, 0.09, merge(footwork(8, 8, -10), {
		UpperTorso = { rx = -6, ry = -30 },
		RightUpperArm = { rx = 15, rz = 25 },
		RightLowerArm = { rx = 120 },
		LeftUpperArm = { rx = 55, rz = -20 },
		LeftLowerArm = { rx = 85 },
	}), merge(footwork(30, 22, 20), {
		UpperTorso = { rx = -18, ry = 30 },
		RightUpperArm = { rx = 95, rz = -4 },
		RightLowerArm = { rx = 0 },
		LeftUpperArm = { rx = 20, rz = -30 },
		LeftLowerArm = { rx = 100 },
	})),

	-- 2: left jab, off the other foot.
	[AnimationDefs.swing("Daggers", 2)] = strike(0.45, 0.15, 0.09, mirror(merge(footwork(8, 8, -10), {
		UpperTorso = { rx = -6, ry = -30 },
		RightUpperArm = { rx = 15, rz = 25 },
		RightLowerArm = { rx = 120 },
		LeftUpperArm = { rx = 55, rz = -20 },
		LeftLowerArm = { rx = 85 },
	})), mirror(merge(footwork(30, 22, 20), {
		UpperTorso = { rx = -18, ry = 30 },
		RightUpperArm = { rx = 95, rz = -4 },
		RightLowerArm = { rx = 0 },
		LeftUpperArm = { rx = 20, rz = -30 },
		LeftLowerArm = { rx = 100 },
	}))),

	-- 3: right blade cutting across.
	[AnimationDefs.swing("Daggers", 3)] = strike(0.48, 0.15, 0.09, merge(footwork(10, 10, -15), {
		UpperTorso = { ry = -40 },
		RightUpperArm = { rx = 115, rz = 70 },
		RightLowerArm = { rx = 50 },
		LeftUpperArm = { rx = 60, rz = -15 },
		LeftLowerArm = { rx = 90 },
	}), merge(footwork(30, 20, 20), {
		UpperTorso = { rx = -14, ry = 40 },
		RightUpperArm = { rx = 75, rz = -40 },
		RightLowerArm = { rx = 10 },
		LeftUpperArm = { rx = 40, rz = -30 },
		LeftLowerArm = { rx = 70 },
	})),

	-- 4, the finisher: both blades raised, driven down together.
	[AnimationDefs.swing("Daggers", 4)] = strike(0.7, 0.22, 0.13, merge(footwork(6, 6, 0), {
		UpperTorso = { rx = 12 },
		Head = { rx = 8 },
		RightUpperArm = { rx = 165, rz = 20 },
		LeftUpperArm = { rx = 165, rz = -20 },
		RightLowerArm = { rx = 70 },
		LeftLowerArm = { rx = 70 },
	}), merge(footwork(40, 30, 0), {
		UpperTorso = { rx = -35 },
		Head = { rx = -5 },
		RightUpperArm = { rx = 70, rz = 10 },
		LeftUpperArm = { rx = 70, rz = -10 },
		RightLowerArm = { rx = 10 },
		LeftLowerArm = { rx = 10 },
	}), merge(footwork(20, 15, 0), {
		UpperTorso = { rx = -16 },
		RightUpperArm = { rx = 40, rz = 15 },
		LeftUpperArm = { rx = 40, rz = -15 },
		RightLowerArm = { rx = 50 },
		LeftLowerArm = { rx = 50 },
	})),

	-- Critical: blades crossed high in a crouch, then a leaping X-cut.
	[AnimationDefs.critical("Daggers")] = strike(1.1, 0.42, 0.28, merge(footwork(15, 15, 0), {
		UpperTorso = { rx = 14 },
		RightUpperArm = { rx = 140, rz = -35 },
		LeftUpperArm = { rx = 140, rz = 35 },
		RightLowerArm = { rx = 40 },
		LeftLowerArm = { rx = 40 },
	}), merge(footwork(42, 30, 0), {
		UpperTorso = { rx = -25 },
		RightUpperArm = { rx = 70, rz = 75 },
		LeftUpperArm = { rx = 70, rz = -75 },
		RightLowerArm = { rx = 5 },
		LeftLowerArm = { rx = 5 },
	}), merge(footwork(22, 16, 0), {
		UpperTorso = { rx = -12 },
		RightUpperArm = { rx = 40, rz = 30 },
		LeftUpperArm = { rx = 45, rz = -30 },
		RightLowerArm = { rx = 50 },
		LeftLowerArm = { rx = 60 },
	})),

	--[[ Staff ]]

	-- Every staff and greataxe pose below is two-handed, and written as where
	-- the weapon is: see "Weapons in the hand" above. The right fist sits a
	-- hand's width off the butt and the left goes a stud further down the
	-- haft (`twoHanded`), so both fists are low on the haft and the head does
	-- the travelling — a long mace, swung. The walking stance alone is
	-- one-handed: a stave carried at the side.

	-- Carried upright at the side like a walking stave, orb above the head.
	[AnimationDefs.stance("Staff")] = stanceLoop(wield({
		UpperTorso = { ry = 8 },
		Head = { ry = -7 },
		LeftUpperArm = { rx = 9, rz = -6 },
		LeftLowerArm = { rx = 22 },
	}, "Right", { at = { 1.55, 0.35, -0.95 }, point = dir(0.04, 1, 0.1) })),

	-- Standing still: the staff stood up in front, both hands on it, a little
	-- of the body's weight leant through it. The one idle in the game that is
	-- resting rather than threatening, which is the point of the class.
	[AnimationDefs.idle("Staff")] = twoHanded(idleLoop(wield(merge(mirror(footwork(12, 22, 18)), {
		UpperTorso = { rx = 6, ry = 14 },
		Head = { rx = -8, ry = -30 },
	}), "Right", { at = { 0.75, 1.35, -1.45 }, point = dir(0.05, 1, -0.08) }), 12, 22, 18), -1.0),

	-- Staff raised level in front of the face, orb to the right.
	[AnimationDefs.guard("Staff")] = twoHanded(guardSnap(wield({
		UpperTorso = { rx = -6 },
	}, "Right", { at = { -0.1, 2.25, -1.55 }, point = dir(1, 0.1, 0), edge = dir(0, 1, 0) })), -1.0),

	-- 1: sweep, right to left, the orb out at the end of it.
	[AnimationDefs.swing("Staff", 1)] = heavyStrike(0.62, 0.25, 0.15, STAFF_READY, held(merge(footwork(10, 8, -20), {
		UpperTorso = { rx = 6, ry = -40 },
		Head = { ry = 30 },
	}), "Right", { at = { 1.35, 1.5, -0.7 }, point = dir(0.7, 0.3, 0.65), edge = dir(0, 0, -1) }), held(merge(footwork(30, 20, 25), {
		UpperTorso = { rx = -12, ry = 16 },
		Head = { ry = -24 },
	}), "Right", { at = { 0.25, 1.45, -1.75 }, point = dir(-0.35, 0.05, -1), edge = dir(-1, 0, 0) })),

	-- 2: the sweep back, left to right.
	[AnimationDefs.swing("Staff", 2)] = heavyStrike(0.62, 0.24, 0.14, STAFF_READY, held(merge(footwork(12, 10, 20), {
		UpperTorso = { rx = 4, ry = 36 },
		Head = { ry = -34 },
	}), "Right", { at = { -0.35, 1.5, -1.2 }, point = dir(-0.7, 0.3, 0.6), edge = dir(0, 0, -1) }), held(merge(footwork(30, 20, -25), {
		UpperTorso = { rx = -12, ry = -16 },
		Head = { ry = 24 },
	}), "Right", { at = { 0.2, 1.45, -1.75 }, point = dir(0.4, 0.05, -1), edge = dir(1, 0, 0) })),

	-- 3: thrust, the orb driven straight out from the hip.
	[AnimationDefs.swing("Staff", 3)] = heavyStrike(0.62, 0.24, 0.14, STAFF_READY, held(merge(footwork(8, 10, -15), {
		UpperTorso = { rx = 4, ry = -22 },
		Head = { ry = 20 },
	}), "Right", { at = { 1.15, 1.05, -1.35 }, point = dir(-0.15, 0.08, -1) }), held(merge(footwork(36, 26, 10), {
		UpperTorso = { rx = -18, ry = 4 },
		Head = { ry = -12 },
	}), "Right", { at = { 0.55, 1.45, -2.45 }, point = dir(-0.08, 0.05, -1) })),

	-- 4, the finisher: raised right over the head, then slammed down.
	[AnimationDefs.swing("Staff", 4)] = heavyStrike(0.9, 0.32, 0.2, STAFF_READY, held(merge(footwork(4, 4, 0), {
		UpperTorso = { rx = 18 },
		Head = { rx = 10 },
	}), "Right", { at = { 0.25, 3.35, -0.35 }, point = dir(0, 0.45, 1), edge = dir(0, 1, 0) }), held(merge(footwork(38, 26, 0), {
		UpperTorso = { rx = -36 },
		Head = { rx = -12 },
	}), "Right", { at = { 0.25, 0.85, -2.05 }, point = dir(0, -0.45, -1), edge = dir(0, -1, 0.45) }), held(merge(footwork(20, 14, 0), {
		UpperTorso = { rx = -16 },
	}), "Right", { at = { 0.3, 1.3, -1.7 }, point = dir(0, 0.15, -1) })),

	-- Critical: wound right round, then a full spinning sweep.
	[AnimationDefs.critical("Staff")] = heavyStrike(1.3, 0.55, 0.38, STAFF_READY, held(merge(footwork(14, 22, -40), {
		UpperTorso = { rx = 10, ry = -60 },
		Head = { ry = 60 },
	}), "Right", { at = { 0.7, 1.45, -1.1 }, point = dir(0.75, 0.2, 0.75), edge = dir(-1, 0, 0) }), held(merge(footwork(34, 24, 30), {
		UpperTorso = { rx = -10, ry = 12 },
		Head = { ry = -40 },
	}), "Right", { at = { -0.2, 1.35, -1.8 }, point = dir(-0.55, 0.05, -1), edge = dir(-1, 0, 0.5) }), held(merge(footwork(18, 12, 20), {
		UpperTorso = { ry = 14 },
	}), "Right", { at = { -0.2, 1.1, -1.5 }, point = dir(-0.7, 0.1, -0.7) })),

	--[[ Greataxe: the Berserker ]]

	-- Everything this weapon does is heavy and late. The windups are longer
	-- than anything else in the game and the follow-throughs carry the body
	-- past where it meant to stop, because that overshoot is the only way a
	-- swing reads as weighing something the swinger cannot quite control.
	--
	-- Held like the staff (see above): right fist under the head, left fist
	-- a stud down the haft toward the butt. The bit's edge faces the way
	-- the head is travelling, so every cut leads with the blade.

	-- Carried on the right shoulder: the fist just in front of it, the haft
	-- lying over the top of it, and the head hanging behind the back with the
	-- blade down, which is where a thing this heavy is carried.
	[AnimationDefs.stance("Greataxe")] = stanceLoop(wield({
		UpperTorso = { rx = -6, ry = -14 },
		Head = { ry = 16 },
		LeftUpperArm = { rx = 14, rz = -8 },
		LeftLowerArm = { rx = 30 },
	}, "Right", { at = { 1.3, 1.65, -0.9 }, point = dir(0.05, 0.2, 1), edge = dir(0, -1, 0) })),

	-- Standing still: at the ready in both hands, the haft across the body and
	-- the head up by the right shoulder — the pose every strike starts from and
	-- settles back into (AXE_READY), so stopping to swing never turns the axe
	-- over. It used to stand on its head with both hands on the butt, leaning
	-- on it, which read as holding it upside down.
	[AnimationDefs.idle("Greataxe")] = twoHanded(idleLoop(wield(merge(mirror(footwork(16, 24, 14)), {
		UpperTorso = { rx = -4, ry = 10 },
		Head = { ry = -24 },
	}), "Right", AXE_READY), 16, 24, 14), -1.0),

	-- The haft held across in front of the face, which is all this weapon can
	-- do to block.
	[AnimationDefs.guard("Greataxe")] = twoHanded(guardSnap(wield({
		UpperTorso = { rx = -10, ry = -8 },
	}, "Right", { at = { 0.6, 2.15, -1.55 }, point = dir(1, 0.12, 0), edge = dir(0, 1, 0.2) })), -1.0),

	-- 1: a flat cleave, right to left, off the shoulder.
	[AnimationDefs.swing("Greataxe", 1)] = heavyStrike(1.05, 0.46, 0.3, AXE_READY, held(merge(footwork(10, 16, -34), {
		UpperTorso = { rx = 8, ry = -40 },
		Head = { ry = 40 },
	}), "Right", { at = { 1.3, 2.0, -0.35 }, point = dir(0.55, 0.35, 0.75), edge = dir(0, 0, -1) }), held(merge(footwork(34, 24, 24), {
		UpperTorso = { rx = -14, ry = 18 },
		Head = { ry = -30 },
	}), "Right", { at = { 0.25, 1.35, -1.65 }, point = dir(-0.25, 0.05, -1), edge = dir(-1, 0, 0) })),

	-- 2: the cleave coming back the other way, using where 1 finished.
	[AnimationDefs.swing("Greataxe", 2)] = heavyStrike(1.0, 0.44, 0.28, AXE_READY, held(merge(footwork(12, 16, 38), {
		UpperTorso = { rx = 6, ry = 34 },
		Head = { ry = -44 },
	}), "Right", { at = { -0.8, 1.95, -0.6 }, point = dir(-0.6, 0.35, 0.7), edge = dir(0, 0, -1) }), held(merge(footwork(36, 24, -26), {
		UpperTorso = { rx = -14, ry = -16 },
		Head = { ry = 30 },
	}), "Right", { at = { -0.1, 1.35, -1.9 }, point = dir(0.3, 0.05, -1), edge = dir(1, 0, 0) })),

	-- 3: a rising cut, up through the body from low right.
	[AnimationDefs.swing("Greataxe", 3)] = heavyStrike(0.98, 0.42, 0.26, AXE_READY, held(merge(footwork(10, 20, -26), {
		UpperTorso = { rx = 10, ry = -34 },
		Head = { rx = -10, ry = 34 },
	}), "Right", { at = { 1.3, 0.75, 0.1 }, point = dir(0.35, -0.45, 0.8), edge = dir(0, 1, -0.3) }), held(merge(footwork(34, 22, 20), {
		UpperTorso = { rx = -20, ry = 12 },
		Head = { rx = 10, ry = -20 },
	}), "Right", { at = { 0.35, 2.2, -1.4 }, point = dir(0, 0.8, -0.7), edge = dir(0, 1, -0.2) })),

	-- 4, the finisher: straight up over the head and down like a felled tree.
	[AnimationDefs.swing("Greataxe", 4)] = heavyStrike(1.5, 0.62, 0.38, AXE_READY, held(merge(footwork(6, 8, 0), {
		UpperTorso = { rx = 24 },
		Head = { rx = 14 },
	}), "Right", { at = { 0.3, 3.35, 0 }, point = dir(0, 0.3, 1), edge = dir(0, 1, 0) }), held(merge(footwork(46, 30, 0), {
		UpperTorso = { rx = -40 },
		Head = { rx = -14 },
	}), "Right", { at = { 0.2, 1.65, -2.05 }, point = dir(0, -0.32, -1), edge = dir(0, -1, 0.32) }), held(merge(footwork(26, 18, 0), {
		UpperTorso = { rx = -22 },
		Head = { rx = -8 },
	}), "Right", { at = { 0.35, 1.45, -1.7 }, point = dir(0, -0.1, -1), edge = dir(0, -1, 0) })),

	-- Critical: wind the whole body round and take everything with it.
	[AnimationDefs.critical("Greataxe")] = heavyStrike(1.7, 0.75, 0.48, AXE_READY, held(merge(footwork(12, 26, -56), {
		UpperTorso = { rx = 12, ry = -60 },
		Head = { ry = 70 },
	}), "Right", { at = { 1.1, 1.6, 0.4 }, point = dir(0.35, 0.15, 1), edge = dir(-1, 0, 0.3) }), held(merge(footwork(44, 28, 58), {
		UpperTorso = { rx = -18, ry = 30 },
		Head = { ry = -60 },
	}), "Right", { at = { 0.1, 1.35, -2.0 }, point = dir(-0.3, 0.05, -1), edge = dir(-1, 0, 0) }), held(merge(footwork(24, 16, 26), {
		UpperTorso = { rx = -12, ry = 12 },
	}), "Right", { at = { -0.1, 1.05, -1.6 }, point = dir(-0.6, -0.1, -0.8), edge = dir(-0.6, 0, 0.8) })),

	--[[ Rapier: the Duelist ]]

	-- Side-on to everything, which is what a rapier is for: present as little
	-- of yourself as possible and put the point between you and them.

	[AnimationDefs.stance("Rapier")] = stanceLoop({
		UpperTorso = { ry = 30 },
		Head = { ry = -34 },
		RightUpperArm = { rx = 22, ry = 12, rz = 8 },
		RightLowerArm = { rx = 34 },
		RightHand = { rx = -18 },
		-- The off hand held back and high, the way a fencer carries it.
		LeftUpperArm = { rx = -26, rz = -34 },
		LeftLowerArm = { rx = 64 },
	}),

	-- Standing still: en garde proper. Front foot forward, back knee bent
	-- under the weight, the point already level with where a throat would be.
	[AnimationDefs.idle("Rapier")] = idleLoop({
		UpperTorso = { rx = -6, ry = 40 },
		Head = { rx = 4, ry = -48 },
		RightUpperArm = { rx = 44, ry = 14, rz = 6 },
		RightLowerArm = { rx = 26 },
		RightHand = { rx = -10 },
		LeftUpperArm = { rx = -40, ry = -10, rz = -42 },
		LeftLowerArm = { rx = 88 },
	}, 26, 22, 42),

	-- A circular parry: the cup turned across the line.
	[AnimationDefs.guard("Rapier")] = guardSnap({
		UpperTorso = { rx = -4, ry = 22 },
		Head = { ry = -20 },
		RightUpperArm = { rx = 72, ry = 10, rz = 22 },
		RightLowerArm = { rx = 44 },
		RightHand = { rx = 26 },
		LeftUpperArm = { rx = -30, rz = -40 },
		LeftLowerArm = { rx = 80 },
	}),

	-- 1: a straight thrust off the front foot.
	[AnimationDefs.swing("Rapier", 1)] = strike(0.5, 0.2, 0.12, merge(mirror(footwork(14, 10, 26)), {
		UpperTorso = { ry = 34 },
		Head = { ry = -34 },
		RightUpperArm = { rx = 18, ry = 16, rz = 10 },
		RightLowerArm = { rx = 74 },
		LeftUpperArm = { rx = -30, rz = -36 },
		LeftLowerArm = { rx = 70 },
	}), merge(mirror(footwork(34, 18, 12)), {
		UpperTorso = { rx = -10, ry = 16 },
		Head = { ry = -16 },
		RightUpperArm = { rx = 84, ry = 6, rz = 2 },
		RightLowerArm = { rx = 6 },
		LeftUpperArm = { rx = -46, rz = -48 },
		LeftLowerArm = { rx = 50 },
	})),

	-- 2: the same thrust again, faster, off a recovered guard.
	[AnimationDefs.swing("Rapier", 2)] = strike(0.46, 0.18, 0.1, merge(mirror(footwork(16, 10, 22)), {
		UpperTorso = { ry = 30 },
		RightUpperArm = { rx = 30, ry = 14, rz = 12 },
		RightLowerArm = { rx = 66 },
		LeftUpperArm = { rx = -28, rz = -34 },
		LeftLowerArm = { rx = 68 },
	}), merge(mirror(footwork(36, 18, 10)), {
		UpperTorso = { rx = -12, ry = 14 },
		RightUpperArm = { rx = 88, ry = 4 },
		RightLowerArm = { rx = 4 },
		LeftUpperArm = { rx = -48, rz = -50 },
		LeftLowerArm = { rx = 48 },
	})),

	-- 3: a circular cut off the wrist, in and across.
	[AnimationDefs.swing("Rapier", 3)] = strike(0.55, 0.22, 0.13, merge(mirror(footwork(14, 12, 34)), {
		UpperTorso = { rx = 4, ry = 44 },
		Head = { ry = -34 },
		RightUpperArm = { rx = 48, ry = 20, rz = 30 },
		RightLowerArm = { rx = 58 },
		RightHand = { rx = 40 },
		LeftUpperArm = { rx = -26, rz = -32 },
		LeftLowerArm = { rx = 66 },
	}), merge(mirror(footwork(32, 18, -6)), {
		UpperTorso = { rx = -8, ry = -4 },
		Head = { ry = 8 },
		RightUpperArm = { rx = 72, ry = -12, rz = -22 },
		RightLowerArm = { rx = 12 },
		RightHand = { rx = -24 },
		LeftUpperArm = { rx = -44, rz = -46 },
		LeftLowerArm = { rx = 52 },
	})),

	-- 4, the finisher: a full lunge, the body flat out behind the point.
	[AnimationDefs.swing("Rapier", 4)] = strike(0.78, 0.28, 0.17, merge(mirror(footwork(12, 14, 34)), {
		UpperTorso = { rx = 8, ry = 44 },
		Head = { ry = -40 },
		RightUpperArm = { rx = 10, ry = 20, rz = 14 },
		RightLowerArm = { rx = 88 },
		LeftUpperArm = { rx = -34, rz = -38 },
		LeftLowerArm = { rx = 74 },
	}), merge(mirror(footwork(52, 12, 6)), {
		UpperTorso = { rx = -22, ry = 8 },
		Head = { rx = 6, ry = -8 },
		RightUpperArm = { rx = 92, ry = 2 },
		RightLowerArm = { rx = 0 },
		-- The off arm thrown back along the line of the lunge, which is what
		-- makes a lunge read as a lunge and not a step.
		LeftUpperArm = { rx = -78, rz = -54 },
		LeftLowerArm = { rx = 16 },
	}), merge(mirror(footwork(26, 16, 20)), {
		UpperTorso = { rx = -8, ry = 24 },
		RightUpperArm = { rx = 54, rz = 8 },
		RightLowerArm = { rx = 34 },
		LeftUpperArm = { rx = -36, rz = -40 },
		LeftLowerArm = { rx = 58 },
	})),

	-- Critical: a passing lunge, running them through and walking past.
	[AnimationDefs.critical("Rapier")] = strike(1.1, 0.48, 0.3, merge(mirror(footwork(10, 18, 44)), {
		UpperTorso = { rx = 10, ry = 56 },
		Head = { ry = -50 },
		RightUpperArm = { rx = -6, ry = 24, rz = 18 },
		RightLowerArm = { rx = 96 },
		LeftUpperArm = { rx = -40, rz = -42 },
		LeftLowerArm = { rx = 80 },
	}), merge(mirror(footwork(56, 10, -10)), {
		UpperTorso = { rx = -26, ry = -8 },
		Head = { rx = 8, ry = 10 },
		RightUpperArm = { rx = 96, ry = -6, rz = -4 },
		RightLowerArm = { rx = 0 },
		LeftUpperArm = { rx = -84, rz = -58 },
		LeftLowerArm = { rx = 10 },
	}), merge(mirror(footwork(28, 18, 14)), {
		UpperTorso = { rx = -10, ry = 18 },
		RightUpperArm = { rx = 58, rz = 6 },
		RightLowerArm = { rx = 30 },
		LeftUpperArm = { rx = -40, rz = -44 },
		LeftLowerArm = { rx = 60 },
	})),

	--[[ Longbow: the Ranger ]]

	-- The bow is in the left hand, the string in the right. Every shot is
	-- built by `shot` (see "The bow: a shot, rather than a swing" above), so
	-- the bow stays on target through the whole draw and the arrow line runs
	-- back to the anchor under the jaw.

	-- Walking: the bow carried at the hip (BOW_CARRY).
	[AnimationDefs.stance("Bow")] = stanceLoop(BOW_CARRY),

	-- Standing still: bow down across the front but not slack, string hand
	-- resting on the arrow. Watching something, rather than aiming at it.
	[AnimationDefs.idle("Bow")] = idleLoop(wield(wield(merge(mirror(footwork(18, 20, 30)), {
		UpperTorso = { rx = -4, ry = -10 },
		Head = { ry = 36 },
	}), "Left", { at = { -0.75, 0.75, -1.45 }, point = dir(0.55, 1, -0.4), edge = dir(0.35, 0, -1) }), "Right", {
		at = { 0.15, 0.55, -1.05 },
		point = dir(-0.4, -0.1, -1),
	}), 18, 20, 30),

	-- The bow turned flat across the face, both hands on it. It is a bow;
	-- this is the best it can do, and the parry frames in WeaponDefs say so.
	[AnimationDefs.guard("Bow")] = guardSnap(wield(wield({
		UpperTorso = { rx = -8, ry = -10 },
	}, "Left", { at = { -0.35, 2.3, -1.55 }, point = dir(1, 0.1, 0), edge = dir(0, 0.25, -1) }), "Right", {
		at = { 1.2, 2.4, -1.55 },
		point = dir(0, 1, -0.2),
	})),

	-- 1: draw and loose.
	[AnimationDefs.swing("Bow", 1)] = shot({ length = 0.9, impact = 0.44, draw = 2.75, lift = 2, body = archerBody(-64, -2), kick = 0.55 }),

	-- 2: a shorter draw, snapped off quicker.
	[AnimationDefs.swing("Bow", 2)] = shot({ length = 0.86, impact = 0.42, draw = 2.6, lift = 2, body = archerBody(-62, 0), kick = 0.5 }),

	-- 3: the same again, leaning into it.
	[AnimationDefs.swing("Bow", 3)] = shot({ length = 0.86, impact = 0.42, draw = 2.65, lift = 3, body = archerBody(-65, -6), kick = 0.5 }),

	-- 4, the finisher: drawn all the way and held a beat.
	[AnimationDefs.swing("Bow", 4)] = shot({ length = 1.25, impact = 0.6, draw = 2.85, lift = 3, body = archerBody(-66, -4), kick = 0.75 }),

	-- Critical: a long aimed shot. Everything stops, including the archer.
	[AnimationDefs.critical("Bow")] = shot({ length = 1.5, impact = 0.7, draw = 2.9, lift = 5, body = archerBody(-68, -2), kick = 0.8 }),

	--[[ Arcane Focus: the Mage ]]

	-- Nothing here is a swing in the sense the other weapons mean it. The
	-- Focus is pushed, swept and opened outward, and the hand that is not
	-- holding it is always doing something — which is what keeps a weapon with
	-- no blade from looking like an empty hand.

	[AnimationDefs.stance("Focus")] = stanceLoop({
		UpperTorso = { rx = -4, ry = -10 },
		Head = { ry = 12 },
		RightUpperArm = { rx = 26, ry = 14, rz = 16 },
		RightLowerArm = { rx = 48 },
		LeftUpperArm = { rx = 12, rz = -10 },
		LeftLowerArm = { rx = 38 },
	}),

	-- Standing still: the stone held up at chest height in an open palm, the
	-- other hand turned under it as though warming itself.
	[AnimationDefs.idle("Focus")] = idleLoop({
		UpperTorso = { rx = -6, ry = -16 },
		Head = { rx = -6, ry = 20 },
		RightUpperArm = { rx = 44, ry = 16, rz = 22 },
		RightLowerArm = { rx = 62 },
		RightHand = { rx = 24 },
		LeftUpperArm = { rx = 24, ry = -12, rz = -20 },
		LeftLowerArm = { rx = 74 },
		LeftHand = { rx = -18 },
	}, 14, 18, -20),

	-- The stone held out flat, both hands behind it.
	[AnimationDefs.guard("Focus")] = guardSnap({
		UpperTorso = { rx = -8 },
		RightUpperArm = { rx = 96, rz = 22 },
		RightLowerArm = { rx = 48 },
		LeftUpperArm = { rx = 88, rz = -30 },
		LeftLowerArm = { rx = 58 },
	}),

	-- 1: a sweep across, the stone dragged through the air.
	[AnimationDefs.swing("Focus", 1)] = strike(0.72, 0.28, 0.17, merge(footwork(10, 10, -26), {
		UpperTorso = { rx = 4, ry = -44 },
		Head = { ry = 26 },
		RightUpperArm = { rx = 52, ry = 26, rz = 48 },
		RightLowerArm = { rx = 62 },
		LeftUpperArm = { rx = 20, rz = 18 },
		LeftLowerArm = { rx = 56 },
	}), merge(footwork(30, 20, 30), {
		UpperTorso = { rx = -12, ry = 46 },
		Head = { ry = -22 },
		RightUpperArm = { rx = 86, ry = -22, rz = -30 },
		RightLowerArm = { rx = 16 },
		LeftUpperArm = { rx = 54, rz = -42 },
		LeftLowerArm = { rx = 20 },
	})),

	-- 2: the sweep back, the off hand trailing it.
	[AnimationDefs.swing("Focus", 2)] = strike(0.7, 0.26, 0.16, merge(footwork(12, 10, 28), {
		UpperTorso = { rx = 2, ry = 44 },
		Head = { ry = -24 },
		RightUpperArm = { rx = 82, ry = -20, rz = -28 },
		RightLowerArm = { rx = 58 },
		LeftUpperArm = { rx = 50, rz = -38 },
		LeftLowerArm = { rx = 54 },
	}), merge(footwork(30, 20, -30), {
		UpperTorso = { rx = -12, ry = -20 },
		Head = { ry = 40 },
		RightUpperArm = { rx = 78, ry = 12, rz = 28 },
		RightLowerArm = { rx = 14 },
		LeftUpperArm = { rx = 26, rz = 24 },
		LeftLowerArm = { rx = 18 },
	})),

	-- 3: a two-handed push, straight out from the chest.
	[AnimationDefs.swing("Focus", 3)] = strike(0.7, 0.26, 0.16, merge(footwork(8, 12, -10), {
		UpperTorso = { rx = 14, ry = -14 },
		Head = { rx = 6 },
		RightUpperArm = { rx = -14, ry = -22, rz = 24 },
		RightLowerArm = { rx = 92 },
		LeftUpperArm = { rx = -18, ry = 20, rz = -22 },
		LeftLowerArm = { rx = 96 },
	}), merge(footwork(34, 24, 6), {
		UpperTorso = { rx = -18, ry = 6 },
		Head = { rx = -8 },
		RightUpperArm = { rx = 92, ry = 6, rz = 16 },
		RightLowerArm = { rx = 8 },
		LeftUpperArm = { rx = 90, ry = -6, rz = -16 },
		LeftLowerArm = { rx = 10 },
	})),

	-- 4, the finisher: gathered in low, then thrown wide open.
	[AnimationDefs.swing("Focus", 4)] = strike(1.0, 0.36, 0.22, merge(footwork(8, 10, 18), {
		UpperTorso = { rx = 22, ry = 20 },
		Head = { rx = 12, ry = 10 },
		RightUpperArm = { rx = -28, ry = -34, rz = 20 },
		RightLowerArm = { rx = 104 },
		LeftUpperArm = { rx = -30, ry = 30, rz = -18 },
		LeftLowerArm = { rx = 108 },
	}), merge(footwork(38, 26, 0), {
		UpperTorso = { rx = -26 },
		Head = { rx = -14 },
		RightUpperArm = { rx = 74, ry = 14, rz = 62 },
		RightLowerArm = { rx = 6 },
		LeftUpperArm = { rx = 74, ry = -14, rz = -62 },
		LeftLowerArm = { rx = 6 },
	}), merge(footwork(20, 14, 0), {
		UpperTorso = { rx = -10 },
		RightUpperArm = { rx = 44, rz = 30 },
		RightLowerArm = { rx = 34 },
		LeftUpperArm = { rx = 44, rz = -30 },
		LeftLowerArm = { rx = 34 },
	})),

	-- Critical: turned right round and opened, so it goes out all ways at once.
	[AnimationDefs.critical("Focus")] = strike(1.4, 0.62, 0.4, merge(footwork(12, 20, -44), {
		UpperTorso = { rx = 16, ry = -76 },
		Head = { ry = 44 },
		RightUpperArm = { rx = -22, ry = -30, rz = 26 },
		RightLowerArm = { rx = 112 },
		LeftUpperArm = { rx = -26, ry = 26, rz = -24 },
		LeftLowerArm = { rx = 114 },
	}), merge(footwork(36, 24, 48), {
		UpperTorso = { rx = -18, ry = 78 },
		Head = { ry = -38 },
		RightUpperArm = { rx = 80, ry = 16, rz = 72 },
		RightLowerArm = { rx = 4 },
		LeftUpperArm = { rx = 80, ry = -16, rz = -72 },
		LeftLowerArm = { rx = 4 },
	}), merge(footwork(20, 14, 22), {
		UpperTorso = { rx = -8, ry = 32 },
		RightUpperArm = { rx = 48, rz = 34 },
		RightLowerArm = { rx = 30 },
		LeftUpperArm = { rx = 48, rz = -34 },
		LeftLowerArm = { rx = 30 },
	})),

	--[[ Any weapon ]]

	-- The four rolls. Forward and back go over the same tuck in opposite
	-- directions; left and right drop a shoulder and go over that.
	[AnimationDefs.roll("forward")] = roll(0, -1),
	[AnimationDefs.roll("back")] = roll(0, 1),
	[AnimationDefs.roll("left")] = roll(SHOULDER_TURN, -1),
	[AnimationDefs.roll("right")] = roll(-SHOULDER_TURN, -1),

	-- The guard shattering: arms thrown wide, then dazed.
	[AnimationDefs.GUARD_BREAK] = {
		length = 1.0,
		looped = false,
		priority = "Action",
		keyframes = {
			kf(0, {}, "Out"),
			kf(0.12, merge(crouch(14), {
				UpperTorso = { rx = 22 },
				Head = { rx = 18 },
				RightUpperArm = { rx = -25, rz = 60 },
				LeftUpperArm = { rx = -20, rz = -60 },
				RightLowerArm = { rx = 30 },
				LeftLowerArm = { rx = 30 },
			})),
			kf(0.5, merge(crouch(20), {
				UpperTorso = { rx = -10 },
				Head = { rx = -18, rz = 12 },
				RightUpperArm = { rx = 10, rz = 12 },
				LeftUpperArm = { rx = 8, rz = -12 },
				RightLowerArm = { rx = 10 },
				LeftLowerArm = { rx = 12 },
			})),
			kf(1.0, {}),
		},
	},

	-- An ability: gather in, then drive out. Deliberately upper body only —
	-- the legs keep walking underneath, and nothing here can put a foot
	-- through the floor. Shield Break shoves, Shadowstep lunges and Mending
	-- Pulse opens; one arc covers all three, because all three gather before
	-- they release. Worth giving each its own once they've been seen.
	[AnimationDefs.ABILITY] = {
		length = 0.75,
		looped = false,
		priority = "Action",
		keyframes = {
			kf(0, {}, "In"),
			-- Gather: shoulders round, arms drawn across the chest.
			kf(0.26, {
				LowerTorso = { ry = 14 },
				UpperTorso = { rx = 16, ry = 16 },
				Head = { rx = 10, ry = 8 },
				RightUpperArm = { rx = -20, ry = -30, rz = 18 },
				LeftUpperArm = { rx = -24, ry = 24, rz = -12 },
				RightLowerArm = { rx = 68 },
				LeftLowerArm = { rx = 74 },
			}, "Out"),
			-- Release: the chest opens and both arms drive forward and out.
			kf(0.42, {
				LowerTorso = { ry = -10 },
				UpperTorso = { rx = -14, ry = -12 },
				Head = { rx = -8, ry = -6 },
				RightUpperArm = { rx = -78, ry = 12, rz = 30 },
				LeftUpperArm = { rx = -74, ry = -12, rz = -30 },
				RightLowerArm = { rx = 12 },
				LeftLowerArm = { rx = 14 },
			}, "Out"),
			kf(0.58, {
				UpperTorso = { rx = -4 },
				RightUpperArm = { rx = -34, rz = 16 },
				LeftUpperArm = { rx = -32, rz = -16 },
				RightLowerArm = { rx = 18 },
				LeftLowerArm = { rx = 20 },
			}),
			kf(0.75, {}),
		},
	},

	[AnimationDefs.HURT] = hurt(nil, 1.0),
}

--[[ Where the blades point ]]

-- Every bladed weapon's swings, with the wrist set at each beat (aimBlades).
-- Directions are root space: -Z at the target, +X the rig's right. A cut
-- winds up with the blade back the way it will come from and lands with it
-- out in front, angled along the line of the cut; a thrust keeps the point on
-- the target the whole way.
local BLADE_AIMS: { [string]: { Right: BladeAims?, Left: BladeAims? } } = {
	-- Sword: the edge leads every cut.
	[AnimationDefs.swing("SwordAndShield", 1)] = {
		Right = { windup = dir(0.35, 0.75, 0.55), hit = dir(-0.35, -0.2, -1), follow = dir(-0.8, -0.5, -0.4), recovery = dir(0.1, 0.35, -1) },
	},
	[AnimationDefs.swing("SwordAndShield", 2)] = {
		Right = { windup = dir(-0.6, -0.5, -0.6), hit = dir(0.2, 0.15, -1), follow = dir(0.7, 0.6, -0.3), recovery = dir(0.1, 0.3, -1) },
	},
	[AnimationDefs.swing("SwordAndShield", 3)] = {
		Right = { windup = dir(0.9, 0.15, 0.4), hit = dir(-0.35, 0, -1), follow = dir(-0.9, 0, -0.3), recovery = dir(0, 0.3, -1) },
	},
	[AnimationDefs.swing("SwordAndShield", 4)] = {
		Right = { windup = dir(0, 0.5, 1), hit = dir(0, -0.3, -1), follow = dir(0, -0.3, -1), recovery = dir(0, 0, -1) },
	},
	[AnimationDefs.critical("SwordAndShield")] = {
		Right = { windup = dir(1, 0.1, 0.5), hit = dir(-0.4, 0, -1), follow = dir(-0.9, 0, 0.2), recovery = dir(0, 0.2, -1) },
	},
	[AnimationDefs.guard("SwordAndShield")] = {
		Right = { windup = dir(0.15, 0.55, -1), hit = dir(0.15, 0.55, -1) },
	},

	-- Daggers: the off blade stays up in guard while the other one works.
	[AnimationDefs.swing("Daggers", 1)] = {
		Right = { windup = dir(0, 0.1, -1), hit = dir(0, 0, -1) },
		Left = { windup = dir(0.3, 0.5, -1), hit = dir(0.3, 0.4, -1) },
	},
	[AnimationDefs.swing("Daggers", 2)] = {
		Left = { windup = dir(0, 0.1, -1), hit = dir(0, 0, -1) },
		Right = { windup = dir(-0.3, 0.5, -1), hit = dir(-0.3, 0.4, -1) },
	},
	[AnimationDefs.swing("Daggers", 3)] = {
		Right = { windup = dir(0.9, 0.2, -0.3), hit = dir(-0.5, 0, -1), follow = dir(-0.9, 0, -0.2) },
		Left = { windup = dir(0.3, 0.5, -1), hit = dir(0.3, 0.5, -1) },
	},
	[AnimationDefs.swing("Daggers", 4)] = {
		Right = { windup = dir(0, 0.2, -1), hit = dir(0, -0.7, -0.7), recovery = dir(0, 0.2, -1) },
		Left = { windup = dir(0, 0.2, -1), hit = dir(0, -0.7, -0.7), recovery = dir(0, 0.2, -1) },
	},
	[AnimationDefs.critical("Daggers")] = {
		Right = { windup = dir(-0.5, 0.8, -0.3), hit = dir(0.5, -0.2, -1), follow = dir(1, -0.2, -0.4), recovery = dir(0, 0.2, -1) },
		Left = { windup = dir(0.5, 0.8, -0.3), hit = dir(-0.5, -0.2, -1), follow = dir(-1, -0.2, -0.4), recovery = dir(0, 0.2, -1) },
	},
	[AnimationDefs.guard("Daggers")] = {
		Right = { windup = dir(-0.6, 0.7, -0.4), hit = dir(-0.6, 0.7, -0.4) },
		Left = { windup = dir(0.6, 0.7, -0.4), hit = dir(0.6, 0.7, -0.4) },
	},

	-- Rapier: the point stays on the target. The third swing is a cut off
	-- the wrist and is authored with its own wrist, so it is left alone.
	[AnimationDefs.swing("Rapier", 1)] = { Right = { windup = dir(0, 0.05, -1), hit = dir(0, 0, -1) } },
	[AnimationDefs.swing("Rapier", 2)] = { Right = { windup = dir(0, 0.05, -1), hit = dir(0, 0, -1) } },
	[AnimationDefs.swing("Rapier", 4)] = { Right = { windup = dir(0, 0.05, -1), hit = dir(0, -0.02, -1), recovery = dir(0, 0.1, -1) } },
	[AnimationDefs.critical("Rapier")] = { Right = { windup = dir(0, 0.05, -1), hit = dir(0, -0.02, -1), recovery = dir(0, 0.1, -1) } },
}

for name, aims in BLADE_AIMS do
	R15Player[name] = aimBlades(R15Player[name], aims)
end

-- rigId -> animation name -> animation.
AnimationDefs.BY_RIG = {
	TrainingDummy = TrainingDummy,
	SkeletonWarrior = SkeletonWarrior,
	Shambler = Shambler,
	Spitter = Spitter,
	HollowKing = HollowKing,
	[RigDefs.PLAYER_RIG] = R15Player,
}

-- One animation by rig and name, or nil if that rig has none. Nil is a
-- normal answer — not every rig has every animation — and every caller
-- treats it as "keep doing what you were doing".
function AnimationDefs.get(rigId: string, name: string): AnimationDef?
	local rig = AnimationDefs.BY_RIG[rigId]
	return rig and rig[name]
end

return AnimationDefs
