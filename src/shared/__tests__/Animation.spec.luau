--!strict
-- Content checks for rigs and animations. These guard the links between data
-- files: an enemy attack with no animation, an animation posing a part no rig
-- has, or a player swing that would freeze the legs, all fail here rather
-- than in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AnimationDefs = require(Shared.AnimationDefs)
local AnimationIds = require(Shared.AnimationIds)
local EnemyDefs = require(Shared.EnemyDefs)
local KeyframeMath = require(Shared.KeyframeMath)
local RigDefs = require(Shared.RigDefs)
local WeaponDefs = require(Shared.WeaponDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local R15_PARTS = {
	"LowerTorso", "UpperTorso", "Head",
	"RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightUpperLeg", "RightLowerLeg", "RightFoot",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
}

local R15_JOINTS = {
	LowerTorso = "Root", UpperTorso = "Waist", Head = "Neck",
	RightUpperArm = "RightShoulder", RightLowerArm = "RightElbow", RightHand = "RightWrist",
	LeftUpperArm = "LeftShoulder", LeftLowerArm = "LeftElbow", LeftHand = "LeftWrist",
	RightUpperLeg = "RightHip", RightLowerLeg = "RightKnee", RightFoot = "RightAnkle",
	LeftUpperLeg = "LeftHip", LeftLowerLeg = "LeftKnee", LeftFoot = "LeftAnkle",
}

local function isPart(name: string): boolean
	return table.find(R15_PARTS, name) ~= nil
end

local function eachAnimation(callback: (label: string, anim: KeyframeMath.AnimationDef) -> ())
	for rigId, animations in AnimationDefs.BY_RIG do
		for name, anim in animations do
			callback(`{rigId}/{name}`, anim)
		end
	end
end

-- expect() on a { label, value } pair, so a failure names what failed.
local function check(label: string, value: boolean)
	expect({ label, value }).toEqual({ label, true })
end

describe("RigDefs skeleton", function()
	-- Real R15 names are what let published animations play on any rig and on
	-- players' avatars.
	it("has exactly the fifteen R15 parts, with R15 joint names", function()
		expect(#RigDefs.SKELETON).toBe(#R15_PARTS)
		for _, part in RigDefs.SKELETON do
			check(part.name, isPart(part.name))
			expect(part.joint).toBe(R15_JOINTS[part.name])
		end
	end)

	it("builds every parent before its children", function()
		local built = { HumanoidRootPart = true }
		for _, part in RigDefs.SKELETON do
			check(`{part.name} after {part.parent}`, built[part.parent] == true)
			built[part.name] = true
		end
	end)

	it("pivots every joint where the two parts meet", function()
		local byName = {}
		for _, part in RigDefs.SKELETON do
			byName[part.name] = part
		end

		for _, part in RigDefs.SKELETON do
			-- The pivot lies inside the child part (with a little slack for
			-- joints that sit on the boundary).
			for axis = 1, 3 do
				local half = part.size[axis] / 2 + 0.11
				local within = math.abs(part.pivot[axis] - part.center[axis]) <= half
				check(`{part.name} pivot axis {axis}`, within)
			end
		end
	end)

	it("keeps the rig inside its hitbox from the feet up", function()
		local rootHalfHeight = RigDefs.ROOT_SIZE[2] / 2
		for _, part in RigDefs.SKELETON do
			local bottom = part.center[2] - part.size[2] / 2
			local top = part.center[2] + part.size[2] / 2
			check(`{part.name} bottom`, bottom >= -rootHalfHeight - 1e-6)
			check(`{part.name} top`, top <= rootHalfHeight + 1e-6)
		end
	end)
end)

describe("RigDefs styles", function()
	it("has a style for every enemy and for the player stand-in", function()
		for enemyId in EnemyDefs do
			check(enemyId, RigDefs.STYLES[enemyId] ~= nil)
		end
		check(RigDefs.PLAYER_RIG, RigDefs.STYLES[RigDefs.PLAYER_RIG] ~= nil)
	end)

	it("only styles parts that exist, and only widens or deepens them", function()
		for rigId, style in RigDefs.STYLES do
			for partName, partStyle in style.parts do
				check(`{rigId}.{partName}`, isPart(partName))
				check(`{rigId}.{partName} width`, (partStyle.width or 1) > 0)
				check(`{rigId}.{partName} depth`, (partStyle.depth or 1) > 0)
			end
		end
	end)

	it("attaches every decoration to a real part", function()
		for rigId, style in RigDefs.STYLES do
			for _, decoration in style.decorations do
				check(`{rigId}.{decoration.name}`, isPart(decoration.attachTo))
			end
		end
	end)

	-- The parry glint plays on these. A rig that answers with nothing would
	-- telegraph a parryable attack with no glint at all, and silently: there is
	-- no error to raise at the point a weapon turns out not to exist.
	it("finds something to glint on every rig that attacks", function()
		for enemyId, def in EnemyDefs do
			local parryable = false
			for _, attack in def.attacks do
				parryable = parryable or attack.parryable
			end
			if not parryable then
				continue
			end

			local parts = RigDefs.weaponParts(enemyId)
			check(`{enemyId} has weapon parts`, #parts > 0)
			for _, name in parts do
				check(`{enemyId}.{name} is a real part`, isPart(name) or name ~= "")
			end
		end
	end)

	-- Claws and bare hands count: they are what those rigs hit with.
	it("falls back to the hands when a rig holds nothing", function()
		for rigId, style in RigDefs.STYLES do
			local held = 0
			for _, decoration in style.decorations do
				if table.find(RigDefs.HANDS, decoration.attachTo) then
					held += 1
				end
			end

			local parts = RigDefs.weaponParts(rigId)
			if held > 0 then
				check(`{rigId} uses what it holds`, #parts == held)
			else
				check(`{rigId} falls back to hands`, #parts == #RigDefs.HANDS)
			end
		end
	end)

	it("gives every colour three channels in range", function()
		local function validColor(rgb: { number }): boolean
			if #rgb ~= 3 then
				return false
			end
			for _, channel in rgb do
				if channel < 0 or channel > 255 then
					return false
				end
			end
			return true
		end

		for rigId, style in RigDefs.STYLES do
			check(`{rigId} default`, validColor(style.default.color))
			for partName, partStyle in style.parts do
				check(`{rigId}.{partName}`, validColor(partStyle.color))
			end
			for _, decoration in style.decorations do
				check(`{rigId}.{decoration.name}`, validColor(decoration.color))
			end
		end
	end)
end)

describe("Animation coverage", function()
	it("gives every enemy its basic set", function()
		for enemyId in EnemyDefs do
			for _, name in AnimationDefs.ENEMY_BASICS do
				check(`{enemyId}/{name}`, AnimationDefs.get(enemyId, name) ~= nil)
			end
		end
	end)

	-- An attack with no animation would telegraph with a rig standing still.
	it("animates every enemy attack", function()
		for enemyId, def in EnemyDefs do
			for attackId in def.attacks do
				local name = AnimationDefs.attack(attackId)
				check(`{enemyId}/{name}`, AnimationDefs.get(enemyId, name) ~= nil)
			end
		end
	end)

	it("animates every weapon's combo, critical, guard and stance, and every roll", function()
		local function has(name: string)
			check(name, AnimationDefs.get(RigDefs.PLAYER_RIG, name) ~= nil)
		end

		for weaponId, def in WeaponDefs do
			for step = 1, #def.attack.combo do
				has(AnimationDefs.swing(weaponId, step))
			end
			has(AnimationDefs.critical(weaponId))
			has(AnimationDefs.guard(weaponId))
			has(AnimationDefs.stance(weaponId))
			-- Without one, standing still falls back to Roblox's own idle and
			-- the character stops looking like they are holding anything.
			has(AnimationDefs.idle(weaponId))
		end
		-- All four: a dodge with no roll for the way the body is going would
		-- fall back to rolling backwards into whatever it was dodging.
		for _, direction in AnimationDefs.ROLL_DIRECTIONS do
			has(AnimationDefs.roll(direction))
		end
		has(AnimationDefs.GUARD_BREAK)
		has(AnimationDefs.HURT)
	end)

	it("only has animations for rigs that exist", function()
		for rigId in AnimationDefs.BY_RIG do
			check(rigId, RigDefs.STYLES[rigId] ~= nil)
		end
	end)

	it("only publishes IDs for animations that exist", function()
		for rigId, published in AnimationIds.PUBLISHED do
			for name in published do
				check(`{rigId}/{name}`, AnimationDefs.get(rigId, name) ~= nil)
			end
		end
	end)
end)

describe("Animation shape", function()
	it("starts at zero with keyframes in strictly increasing order", function()
		eachAnimation(function(label, anim)
			check(`{label} starts at 0`, anim.keyframes[1].time == 0)
			for index = 2, #anim.keyframes do
				check(`{label} keyframe {index} order`, anim.keyframes[index].time > anim.keyframes[index - 1].time)
			end
			check(`{label} ends within its length`, anim.keyframes[#anim.keyframes].time <= anim.length + 1e-9)
		end)
	end)

	-- The sampler doesn't interpolate across the loop point, so a loop must
	-- end exactly where it began.
	it("closes every loop seamlessly", function()
		eachAnimation(function(label, anim)
			if not anim.looped then
				return
			end

			local last = anim.keyframes[#anim.keyframes]
			check(`{label} last keyframe at length`, math.abs(last.time - anim.length) < 1e-9)

			local first = KeyframeMath.sample(anim, 0)
			local final = KeyframeMath.sample(anim, anim.length - 1e-9)
			for part, pose in first do
				for component, value in pose :: any do
					local ends = (final[part] :: any)[component]
					check(`{label} {part}.{component} loops`, math.abs(ends - value) < 1e-3)
				end
			end
		end)
	end)

	it("only poses real R15 parts, with sane values", function()
		eachAnimation(function(label, anim)
			for _, keyframe in anim.keyframes do
				for part, pose in keyframe.poses do
					check(`{label} poses {part}`, isPart(part))
					for component, value in pose :: any do
						local finite = value == value and math.abs(value) < math.huge
						check(`{label} {part}.{component} finite`, finite)
						if string.sub(component, 1, 1) == "r" then
							check(`{label} {part}.{component} within a turn`, math.abs(value) <= 360)
						else
							check(`{label} {part}.{component} within reach`, math.abs(value) <= 4)
						end
					end
				end
			end
		end)
	end)

	-- The impact keyframe is what the game times the strike to, and what the
	-- workbench names "Impact" for refined versions to keep.
	it("puts every strike's impact on a keyframe inside the animation", function()
		eachAnimation(function(label, anim)
			local impact = anim.impact
			if not impact then
				return
			end

			check(`{label} impact after start`, impact > 0)
			check(`{label} impact before end`, impact < anim.length)

			local onKeyframe = false
			for _, keyframe in anim.keyframes do
				if math.abs(keyframe.time - impact) < 1e-9 then
					onKeyframe = true
				end
			end
			check(`{label} impact keyframe`, onKeyframe)
		end)
	end)

	it("gives every attack, swing and critical an impact, and nothing else one", function()
		eachAnimation(function(label, anim)
			local name = string.match(label, "/(.+)$") :: string
			local isStrike = string.sub(name, 1, 7) == "attack_"
				or string.sub(name, 1, 6) == "swing_"
				or string.sub(name, 1, 9) == "critical_"
			check(`{label} impact`, (anim.impact ~= nil) == isStrike)
		end)
	end)

	-- Walking keeps working underneath a stance or a held guard only if they
	-- leave the hips and legs alone. (Strikes and rolls may pose them: those
	-- are short, and slow the player right down while they play. A planted
	-- idle may too, and must — it only plays when there is no walk cycle
	-- underneath to protect.)
	it("never poses a player's hips or legs in a stance or guard", function()
		local lower = { "LowerTorso", "RightUpperLeg", "RightLowerLeg", "RightFoot", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" }
		for name, anim in AnimationDefs.BY_RIG[RigDefs.PLAYER_RIG] do
			local held = string.sub(name, 1, 7) == "stance_"
				or (string.sub(name, 1, 6) == "guard_" and name ~= AnimationDefs.GUARD_BREAK)
			if not held then
				continue
			end
			for _, part in KeyframeMath.partsOf(anim) do
				check(`R15Player/{name} leaves {part} alone`, table.find(lower, part) == nil)
			end
		end
	end)

	-- The rolls are the only animations that turn the whole body, and the
	-- sampler interpolates a pose as plain numbers rather than as a rotation.
	-- So a roll that reaches 285 degrees and then lands on a keyframe holding
	-- 0 does not finish its turn: it unwinds, spinning backwards through every
	-- degree it had just covered, in the few frames it had left to stand up
	-- in. Every keyframe from the tumble onward has to carry the turn.
	it("turns each roll one way, all the way round", function()
		for _, direction in AnimationDefs.ROLL_DIRECTIONS do
			local name = AnimationDefs.roll(direction)
			local anim = AnimationDefs.get(RigDefs.PLAYER_RIG, name) :: any
			check(`{name} exists`, anim ~= nil)

			-- Sampled rather than read off the keyframes, because what matters
			-- is what plays: the turn never reverses between one frame and the
			-- next, and it ends a whole number of turns from where it started.
			local samples = 80
			local previous = 0
			local peak = 0
			local sign = 0
			for index = 0, samples do
				local turn = (KeyframeMath.sample(anim, anim.length * index / samples).LowerTorso or {}).rx or 0
				if sign == 0 and math.abs(turn) > 1e-6 then
					sign = if turn > 0 then 1 else -1
				end
				check(`{name} never unwinds at {index}`, turn * sign >= previous * sign - 1e-6)
				previous = turn
				peak = math.max(peak, math.abs(turn))
			end

			check(`{name} completes a turn (reached {peak})`, math.abs(peak - 360) < 1e-6)
			check(`{name} ends on the turn (at {previous})`, math.abs(math.abs(previous) - 360) < 1e-6)
		end
	end)

	-- A roll is the one player animation that may pose the hips and legs, and
	-- the one that moves the body off the spot it stands on. Both are what the
	-- workbench's floor solve checks; this only guards the offsets staying
	-- inside what a body can reach, since a stray one there is a rig
	-- teleporting rather than rolling.
	it("keeps every roll's hips within reach of the body", function()
		for _, direction in AnimationDefs.ROLL_DIRECTIONS do
			local name = AnimationDefs.roll(direction)
			local anim = AnimationDefs.get(RigDefs.PLAYER_RIG, name) :: any
			for _, keyframe in anim.keyframes do
				local hips = keyframe.poses.LowerTorso
				if hips then
					check(`{name} hip drop`, math.abs(hips.py or 0) <= 2)
					check(`{name} hip slide`, math.abs(hips.px or 0) <= 1 and math.abs(hips.pz or 0) <= 1)
				end
			end
		end
	end)

	-- The other half of the overlay rule. A planted idle that left the legs
	-- alone would be a stance with a longer loop and no reason to exist.
	it("plants the feet in every player idle", function()
		for weaponId in WeaponDefs do
			local name = AnimationDefs.idle(weaponId)
			local anim = AnimationDefs.get(RigDefs.PLAYER_RIG, name)
			if not anim then
				continue
			end

			local parts = KeyframeMath.partsOf(anim)
			check(`{name} poses the hips`, table.find(parts, "LowerTorso") ~= nil)
			for _, leg in { "RightUpperLeg", "LeftUpperLeg", "RightFoot", "LeftFoot" } do
				check(`{name} poses {leg}`, table.find(parts, leg) ~= nil)
			end
		end
	end)

	it("keeps looping and one-shot priorities consistent", function()
		eachAnimation(function(label, anim)
			if anim.looped then
				check(`{label} loops at Idle or Movement`, anim.priority ~= "Action")
			else
				check(`{label} one-shot at Action`, anim.priority == "Action")
			end
		end)
	end)
end)
