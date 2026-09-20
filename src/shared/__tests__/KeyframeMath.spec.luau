--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local KeyframeMath = require(Shared.KeyframeMath)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

-- A two-keyframe animation to sample: one second long, from an empty
-- pose to a posed one, with the given easing.
local function anim(looped: boolean, easing: any?): KeyframeMath.AnimationDef
	return {
		length = 1,
		looped = looped,
		priority = "Action",
		keyframes = {
			{ time = 0, easing = easing or "Linear", poses = { RightUpperArm = { rx = 0 }, Head = { ry = 10 } } },
			{ time = 0.5, easing = easing or "Linear", poses = { RightUpperArm = { rx = 90 } } },
			{ time = 1, easing = easing or "Linear", poses = { RightUpperArm = { rx = 0 }, Head = { ry = 10 } } },
		},
	}
end

describe("KeyframeMath.sample", function()
	it("returns a keyframe's exact pose at its time", function()
		local pose = KeyframeMath.sample(anim(false), 0.5)
		expect(pose.RightUpperArm.rx).toBe(90)
	end)

	it("interpolates linearly between keyframes", function()
		expect(KeyframeMath.sample(anim(false), 0.25).RightUpperArm.rx).toBeCloseTo(45, 6)
	end)

	-- A part the animation poses elsewhere, but not in this keyframe, is at rest
	-- there. That matches what the workbench writes out: an explicit rest pose.
	it("treats a part missing from a keyframe as resting there", function()
		local pose = KeyframeMath.sample(anim(false), 0.5)
		expect(pose.Head.ry).toBe(0)
		expect(KeyframeMath.sample(anim(false), 0.25).Head.ry).toBeCloseTo(5, 6)
	end)

	it("fills every unset component with zero", function()
		local pose = KeyframeMath.sample(anim(false), 0.5).RightUpperArm
		expect(pose).toEqual({ rx = 90, ry = 0, rz = 0, px = 0, py = 0, pz = 0 })
	end)

	it("eases with Smooth, not linearly", function()
		local smooth = KeyframeMath.sample(anim(false, "Smooth"), 0.125).RightUpperArm.rx
		expect(smooth < 22.5).toBe(true)
		expect(smooth > 0).toBe(true)
	end)

	it("holds with Hold until the next keyframe", function()
		expect(KeyframeMath.sample(anim(false, "Hold"), 0.49).RightUpperArm.rx).toBe(0)
		expect(KeyframeMath.sample(anim(false, "Hold"), 0.5).RightUpperArm.rx).toBe(90)
	end)

	it("wraps a looped animation", function()
		local looped = anim(true)
		expect(KeyframeMath.sample(looped, 1.25).RightUpperArm.rx).toBeCloseTo(45, 6)
		expect(KeyframeMath.sample(looped, 7.5).RightUpperArm.rx).toBeCloseTo(90, 6)
	end)

	-- Death and similar animations must stay on their last frame.
	it("holds the last frame of a finished one-shot animation", function()
		local once = anim(false)
		once.keyframes[3].poses.RightUpperArm = { rx = 30 }
		expect(KeyframeMath.sample(once, 5).RightUpperArm.rx).toBe(30)
	end)

	it("clamps negative time to the first frame", function()
		expect(KeyframeMath.sample(anim(false), -1).RightUpperArm.rx).toBe(0)
	end)

	it("returns nothing for an animation without keyframes", function()
		local empty: KeyframeMath.AnimationDef = { length = 1, looped = false, priority = "Idle", keyframes = {} }
		expect(KeyframeMath.sample(empty, 0.5)).toEqual({})
	end)
end)

describe("KeyframeMath.ease", function()
	it("pins both ends for every easing", function()
		for _, easing in { "Linear", "Smooth", "In", "Out" } do
			expect(KeyframeMath.ease(easing :: any, 0)).toBe(0)
			expect(KeyframeMath.ease(easing :: any, 1)).toBe(1)
		end
	end)

	it("is symmetric for Smooth", function()
		expect(KeyframeMath.ease("Smooth", 0.5)).toBeCloseTo(0.5, 9)
		expect(KeyframeMath.ease("Smooth", 0.2) + KeyframeMath.ease("Smooth", 0.8)).toBeCloseTo(1, 9)
	end)

	it("starts slow for In and fast for Out, mirroring each other", function()
		expect(KeyframeMath.ease("In", 0.5) < 0.5).toBe(true)
		expect(KeyframeMath.ease("Out", 0.5) > 0.5).toBe(true)
		expect(KeyframeMath.ease("In", 0.3) + KeyframeMath.ease("Out", 0.7)).toBeCloseTo(1, 9)
	end)

	it("clamps alpha", function()
		expect(KeyframeMath.ease("Linear", 1.5)).toBe(1)
		expect(KeyframeMath.ease("Linear", -0.5)).toBe(0)
	end)
end)

describe("KeyframeMath.alignedTime", function()
	-- An attack's impact keyframe must land exactly when the server resolves
	-- the hit, whatever the telegraph length.
	it("reaches the impact keyframe exactly at the end of the windup", function()
		expect(KeyframeMath.alignedTime(1.8, 0.6, 1.8)).toBeCloseTo(0.6, 9)
		expect(KeyframeMath.alignedTime(0.3, 0.6, 0.3)).toBeCloseTo(0.6, 9)
	end)

	it("scales the windup proportionally", function()
		expect(KeyframeMath.alignedTime(0.9, 0.6, 1.8)).toBeCloseTo(0.3, 9)
	end)

	it("plays the follow-through at normal speed", function()
		expect(KeyframeMath.alignedTime(2.3, 0.6, 1.8)).toBeCloseTo(1.1, 9)
	end)

	it("jumps straight to impact when there is no windup", function()
		expect(KeyframeMath.alignedTime(0, 0.6, 0)).toBe(0.6)
		expect(KeyframeMath.alignedTime(0.2, 0.6, 0)).toBeCloseTo(0.8, 9)
	end)

	it("treats time before the start as the start", function()
		expect(KeyframeMath.alignedTime(-0.5, 0.6, 1.8)).toBe(0)
	end)
end)

describe("KeyframeMath.blend", function()
	local from: KeyframeMath.PoseMap = { Head = KeyframeMath.resolve({ rx = 20 }) }
	local to: KeyframeMath.PoseMap = { Head = KeyframeMath.resolve({ rx = 40 }), Hand = KeyframeMath.resolve({ rz = 10 }) }

	it("returns the source at weight 0 and the target at weight 1", function()
		expect(KeyframeMath.blend(from, to, 0).Head.rx).toBe(20)
		expect(KeyframeMath.blend(from, to, 1).Head.rx).toBe(40)
	end)

	it("mixes at a middle weight", function()
		expect(KeyframeMath.blend(from, to, 0.5).Head.rx).toBe(30)
	end)

	it("fades a part only one side has from or to rest", function()
		expect(KeyframeMath.blend(from, to, 0.5).Hand.rz).toBe(5)
	end)
end)

describe("KeyframeMath.partsOf", function()
	it("lists every posed part once, sorted", function()
		expect(KeyframeMath.partsOf(anim(false))).toEqual({ "Head", "RightUpperArm" })
	end)
end)
